from __future__ import annotations

import concurrent.futures
import hashlib
import http.client
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]
SERVER_SCRIPT = REPOSITORY_ROOT / "Scripts" / "support" / "mori-experience-relay.py"


class RelayProcess:
    def __init__(
        self,
        *,
        ttl_seconds: float = 2.0,
        submit_timeout_seconds: float = 1.0,
        poll_timeout_seconds: float = 0.1,
        maximum_queue_depth: int = 8,
    ) -> None:
        self._temporary_directory = tempfile.TemporaryDirectory()
        self.control_file = (
            pathlib.Path(self._temporary_directory.name) / "relay-control.json"
        )
        self.process = subprocess.Popen(
            [
                sys.executable,
                str(SERVER_SCRIPT),
                "--control-file",
                str(self.control_file),
                "--ttl-seconds",
                str(ttl_seconds),
                "--submit-timeout-seconds",
                str(submit_timeout_seconds),
                "--poll-timeout-seconds",
                str(poll_timeout_seconds),
                "--maximum-queue-depth",
                str(maximum_queue_depth),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 5
        while not self.control_file.exists() and time.monotonic() < deadline:
            if self.process.poll() is not None:
                stdout, stderr = self.process.communicate()
                raise AssertionError(
                    f"relay exited before readiness: {stdout!r} {stderr!r}"
                )
            time.sleep(0.01)
        if not self.control_file.exists():
            self.stop()
            raise AssertionError("relay did not publish its control file")
        self.control = json.loads(self.control_file.read_text(encoding="utf-8"))

    @property
    def host(self) -> str:
        return self.control["host"]

    @property
    def port(self) -> int:
        return self.control["port"]

    @property
    def run_id(self) -> str:
        return self.control["runID"]

    @property
    def token(self) -> str:
        return self.control["token"]

    def request(
        self,
        method: str,
        path: str,
        *,
        body: bytes = b"",
        headers: dict[str, str] | None = None,
        timeout: float = 3,
    ) -> tuple[int, dict[str, str], bytes]:
        connection = http.client.HTTPConnection(self.host, self.port, timeout=timeout)
        request_headers = self.authorization_headers()
        request_headers.update(headers or {})
        connection.request(method, path, body=body, headers=request_headers)
        response = connection.getresponse()
        response_body = response.read()
        response_headers = {key.lower(): value for key, value in response.getheaders()}
        status = response.status
        connection.close()
        return status, response_headers, response_body

    def authorization_headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.token}",
            "X-Mori-Relay-Run-ID": self.run_id,
        }

    def transfer_headers(self, transfer_id: str, body: bytes) -> dict[str, str]:
        return {
            "Content-Type": "application/octet-stream",
            "X-Mori-Transfer-ID": transfer_id,
            "X-Mori-Transfer-SHA256": hashlib.sha256(body).hexdigest(),
        }

    def submit(
        self,
        *,
        role: str,
        channel: str,
        transfer_id: str,
        body: bytes,
    ) -> tuple[int, dict[str, str], bytes]:
        return self.request(
            "POST",
            f"/v1/submit/{channel}/{role}",
            body=body,
            headers=self.transfer_headers(transfer_id, body),
        )

    def poll(self, *, role: str, channel: str) -> tuple[int, dict[str, str], bytes]:
        return self.request("GET", f"/v1/poll/{channel}/{role}")

    def acknowledge(
        self,
        *,
        role: str,
        channel: str,
        transfer_id: str,
        transfer_digest: str,
        body: bytes,
    ) -> tuple[int, dict[str, str], bytes]:
        return self.request(
            "POST",
            f"/v1/ack/{channel}/{role}",
            body=body,
            headers={
                "Content-Type": "application/octet-stream",
                "X-Mori-Transfer-ID": transfer_id,
                "X-Mori-Transfer-SHA256": transfer_digest,
            },
        )

    def stop(self) -> tuple[str, str]:
        if self.process.poll() is None:
            self.process.terminate()
        try:
            stdout, stderr = self.process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            stdout, stderr = self.process.communicate(timeout=3)
        self._temporary_directory.cleanup()
        return stdout, stderr


class MoriExperienceRelayProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.relay = RelayProcess()

    def tearDown(self) -> None:
        if self.relay is not None:
            self.relay.stop()

    def test_control_file_is_private_loopback_and_content_free(self) -> None:
        mode = stat.S_IMODE(os.stat(self.relay.control_file).st_mode)
        self.assertEqual(mode, 0o600)
        self.assertEqual(self.relay.host, "127.0.0.1")
        self.assertGreater(self.relay.port, 0)
        self.assertLessEqual(self.relay.port, 65535)
        self.assertEqual(str(uuid.UUID(self.relay.run_id)), self.relay.run_id)
        self.assertEqual(len(bytes.fromhex(self.relay.token)), 32)
        self.assertEqual(
            set(self.relay.control),
            {
                "schemaVersion",
                "host",
                "port",
                "runID",
                "token",
                "maximumBodyBytes",
            },
        )
        self.assertEqual(self.relay.control["maximumBodyBytes"], 512 * 1024)

        token = self.relay.token
        arbitrary_body = b"private-health-like-test-payload"
        stdout, stderr = self.relay.stop()
        self.relay = None
        self.assertNotIn(token, stdout)
        self.assertNotIn(token, stderr)
        self.assertNotIn(arbitrary_body.decode(), stdout)
        self.assertNotIn(arbitrary_body.decode(), stderr)

    def test_auth_routes_digest_and_body_limit_fail_closed(self) -> None:
        headers = self.relay.authorization_headers()
        headers["Authorization"] = "Bearer wrong"
        status, _, _ = self.relay.request(
            "GET", "/v1/poll/experience/watch", headers=headers
        )
        self.assertEqual(status, 401)

        status, _, _ = self.relay.request("GET", "/v1/poll/private/watch")
        self.assertEqual(status, 404)
        status, _, _ = self.relay.request("GET", "/v1/poll/experience/arbitrary")
        self.assertEqual(status, 404)
        status, _, _ = self.relay.request(
            "GET", "/v1/poll/experience/watch?path=/tmp/secret"
        )
        self.assertEqual(status, 404)

        transfer_id = str(uuid.uuid4())
        status, _, _ = self.relay.request(
            "POST",
            "/v1/submit/experience/iphone",
            body=b"body",
            headers={
                "X-Mori-Transfer-ID": transfer_id,
                "X-Mori-Transfer-SHA256": "0" * 64,
            },
        )
        self.assertEqual(status, 422)

        connection = http.client.HTTPConnection(
            self.relay.host, self.relay.port, timeout=3
        )
        connection.putrequest("POST", "/v1/submit/experience/iphone")
        for key, value in self.relay.authorization_headers().items():
            connection.putheader(key, value)
        for key, value in self.relay.transfer_headers(str(uuid.uuid4()), b"").items():
            connection.putheader(key, value)
        connection.putheader("Content-Length", str(512 * 1024 + 1))
        connection.endheaders()
        response = connection.getresponse()
        self.assertEqual(response.status, 413)
        response.read()
        connection.close()

    def test_duplicate_submit_and_ack_are_idempotent_but_conflicts_fail(self) -> None:
        transfer_id = str(uuid.uuid4())
        payload = b"opaque-experience"
        acknowledgement = b"opaque-acknowledgement"
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(
                self.relay.submit,
                role="iphone",
                channel="experience",
                transfer_id=transfer_id,
                body=payload,
            )
            poll_status, poll_headers, poll_body = self.relay.poll(
                role="watch", channel="experience"
            )
            self.assertEqual(poll_status, 200)
            self.assertEqual(poll_body, payload)
            self.assertEqual(poll_headers["x-mori-transfer-id"], transfer_id)

            duplicate = pool.submit(
                self.relay.submit,
                role="iphone",
                channel="experience",
                transfer_id=transfer_id,
                body=payload,
            )
            ack_status, _, _ = self.relay.acknowledge(
                role="watch",
                channel="experience",
                transfer_id=transfer_id,
                transfer_digest=poll_headers["x-mori-transfer-sha256"],
                body=acknowledgement,
            )
            self.assertEqual(ack_status, 204)
            first_result = first.result(timeout=3)
            duplicate_result = duplicate.result(timeout=3)

        for result in (first_result, duplicate_result):
            self.assertEqual(result[0], 200)
            self.assertEqual(result[2], acknowledgement)
            self.assertEqual(
                result[1]["x-mori-acknowledgement-sha256"],
                hashlib.sha256(acknowledgement).hexdigest(),
            )

        repeated_ack, _, _ = self.relay.acknowledge(
            role="watch",
            channel="experience",
            transfer_id=transfer_id,
            transfer_digest=hashlib.sha256(payload).hexdigest(),
            body=acknowledgement,
        )
        self.assertEqual(repeated_ack, 204)
        conflicting_ack, _, _ = self.relay.acknowledge(
            role="watch",
            channel="experience",
            transfer_id=transfer_id,
            transfer_digest=hashlib.sha256(payload).hexdigest(),
            body=b"different-acknowledgement",
        )
        self.assertEqual(conflicting_ack, 409)
        conflict_status, _, _ = self.relay.submit(
            role="iphone",
            channel="experience",
            transfer_id=transfer_id,
            body=b"different-body",
        )
        self.assertEqual(conflict_status, 409)

    def test_independent_pumps_support_simultaneous_two_way_exchange(self) -> None:
        def pump_once(role: str) -> bytes:
            status, headers, body = self.relay.poll(role=role, channel="experience")
            self.assertEqual(status, 200)
            acknowledgement = b"received:" + body
            ack_status, _, _ = self.relay.acknowledge(
                role=role,
                channel="experience",
                transfer_id=headers["x-mori-transfer-id"],
                transfer_digest=headers["x-mori-transfer-sha256"],
                body=acknowledgement,
            )
            self.assertEqual(ack_status, 204)
            return body

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            watch_pump = pool.submit(pump_once, "watch")
            phone_pump = pool.submit(pump_once, "iphone")
            phone_submit = pool.submit(
                self.relay.submit,
                role="iphone",
                channel="experience",
                transfer_id=str(uuid.uuid4()),
                body=b"from-phone",
            )
            watch_submit = pool.submit(
                self.relay.submit,
                role="watch",
                channel="experience",
                transfer_id=str(uuid.uuid4()),
                body=b"from-watch",
            )
            self.assertEqual(watch_pump.result(timeout=3), b"from-phone")
            self.assertEqual(phone_pump.result(timeout=3), b"from-watch")
            self.assertEqual(phone_submit.result(timeout=3)[2], b"received:from-phone")
            self.assertEqual(watch_submit.result(timeout=3)[2], b"received:from-watch")

    def test_concurrent_polls_claim_one_transfer_until_acknowledged(self) -> None:
        transfer_id = str(uuid.uuid4())
        payload = b"claim-once"
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            submitted = pool.submit(
                self.relay.submit,
                role="iphone",
                channel="experience",
                transfer_id=transfer_id,
                body=payload,
            )
            first_poll = pool.submit(
                self.relay.poll,
                role="watch",
                channel="experience",
            )
            second_poll = pool.submit(
                self.relay.poll,
                role="watch",
                channel="experience",
            )
            poll_results = [
                first_poll.result(timeout=3),
                second_poll.result(timeout=3),
            ]
            self.assertEqual(sorted(result[0] for result in poll_results), [200, 204])
            delivered = next(result for result in poll_results if result[0] == 200)
            self.assertEqual(delivered[2], payload)
            ack_status, _, _ = self.relay.acknowledge(
                role="watch",
                channel="experience",
                transfer_id=transfer_id,
                transfer_digest=delivered[1]["x-mori-transfer-sha256"],
                body=b"ack",
            )
            self.assertEqual(ack_status, 204)
            self.assertEqual(submitted.result(timeout=3)[2], b"ack")

    def test_all_channels_remain_separate_opaque_byte_queues(self) -> None:
        for channel in ("experience", "preferences", "consent"):
            transfer_id = str(uuid.uuid4())
            payload = f"{channel}-bytes".encode()
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                submitted = pool.submit(
                    self.relay.submit,
                    role="iphone",
                    channel=channel,
                    transfer_id=transfer_id,
                    body=payload,
                )
                status, headers, body = self.relay.poll(role="watch", channel=channel)
                self.assertEqual(status, 200)
                self.assertEqual(body, payload)
                self.assertEqual(headers["x-mori-sender-role"], "iphone")
                self.relay.acknowledge(
                    role="watch",
                    channel=channel,
                    transfer_id=transfer_id,
                    transfer_digest=headers["x-mori-transfer-sha256"],
                    body=b"ack",
                )
                self.assertEqual(submitted.result(timeout=3)[2], b"ack")


class MoriExperienceRelayBoundTests(unittest.TestCase):
    def test_server_refuses_to_replace_an_existing_control_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            control_file = pathlib.Path(directory) / "existing-control.json"
            original = b"do-not-replace"
            control_file.write_bytes(original)
            process = subprocess.run(
                [
                    sys.executable,
                    str(SERVER_SCRIPT),
                    "--control-file",
                    str(control_file),
                ],
                capture_output=True,
                text=True,
                timeout=3,
                check=False,
            )
            self.assertEqual(process.returncode, 1)
            self.assertEqual(control_file.read_bytes(), original)
            self.assertEqual(process.stdout, "")
            self.assertEqual(process.stderr, "relay startup failed\n")
            self.assertNotIn(str(control_file), process.stderr)

    def test_server_configuration_values_are_bounded(self) -> None:
        for flag, value in (
            ("--ttl-seconds", "301"),
            ("--submit-timeout-seconds", "61"),
            ("--poll-timeout-seconds", "11"),
            ("--maximum-queue-depth", "65"),
            ("--ttl-seconds", "nan"),
            ("--ttl-seconds", "inf"),
        ):
            with (
                self.subTest(flag=flag),
                tempfile.TemporaryDirectory() as directory,
            ):
                control_file = pathlib.Path(directory) / "control.json"
                process = subprocess.run(
                    [
                        sys.executable,
                        str(SERVER_SCRIPT),
                        "--control-file",
                        str(control_file),
                        flag,
                        value,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=3,
                    check=False,
                )
                self.assertEqual(process.returncode, 2)
                self.assertFalse(control_file.exists())
                self.assertNotIn(str(control_file), process.stderr)

    def test_submit_and_poll_time_out_and_expired_transfer_is_removed(self) -> None:
        relay = RelayProcess(
            ttl_seconds=0.2,
            submit_timeout_seconds=0.08,
            poll_timeout_seconds=0.04,
        )
        try:
            status, _, _ = relay.submit(
                role="iphone",
                channel="experience",
                transfer_id=str(uuid.uuid4()),
                body=b"will-expire",
            )
            self.assertEqual(status, 504)
            time.sleep(0.25)
            poll_status, _, _ = relay.poll(role="watch", channel="experience")
            self.assertEqual(poll_status, 204)
        finally:
            relay.stop()

    def test_queue_depth_is_bounded(self) -> None:
        relay = RelayProcess(maximum_queue_depth=1)
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                first_id = str(uuid.uuid4())
                first = pool.submit(
                    relay.submit,
                    role="iphone",
                    channel="experience",
                    transfer_id=first_id,
                    body=b"first",
                )
                status, headers, _ = relay.poll(role="watch", channel="experience")
                self.assertEqual(status, 200)
                second_status, _, _ = relay.submit(
                    role="iphone",
                    channel="experience",
                    transfer_id=str(uuid.uuid4()),
                    body=b"second",
                )
                self.assertEqual(second_status, 429)
                relay.acknowledge(
                    role="watch",
                    channel="experience",
                    transfer_id=first_id,
                    transfer_digest=headers["x-mori-transfer-sha256"],
                    body=b"ack",
                )
                self.assertEqual(first.result(timeout=3)[0], 200)
        finally:
            relay.stop()


if __name__ == "__main__":
    unittest.main()
