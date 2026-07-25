#!/usr/bin/env python3
"""Debug-only localhost relay for paired Apple UI tests.

The relay treats every payload as opaque bytes. It intentionally emits no
request log and exposes no endpoint that accepts a filesystem path.
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import hashlib
import hmac
import http.server
import json
import math
import os
import secrets
import sys
import threading
import time
import uuid
from typing import Final
from urllib.parse import urlsplit

HOST: Final = "127.0.0.1"
MAXIMUM_BODY_BYTES: Final = 512 * 1024
CHANNELS: Final = frozenset(("experience", "preferences", "consent"))
ROLES: Final = frozenset(("iphone", "watch"))


def _peer(role: str) -> str:
    return "watch" if role == "iphone" else "iphone"


def _canonical_uuid(value: str) -> str | None:
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError):
        return None
    canonical = str(parsed)
    return canonical if value.lower() == canonical else None


def _valid_digest(value: str) -> bool:
    if len(value) != 64 or value != value.lower():
        return False
    return all(character in "0123456789abcdef" for character in value)


@dataclasses.dataclass
class Transfer:
    transfer_id: str
    channel: str
    sender: str
    recipient: str
    digest: str
    body: bytes
    created_at: float
    expires_at: float
    claimed_until: float = 0
    acknowledgement: bytes | None = None
    acknowledgement_digest: str | None = None


class RelayState:
    """Thread-safe, single-run queue and idempotency authority."""

    def __init__(
        self,
        *,
        ttl_seconds: float,
        delivery_lease_seconds: float,
        maximum_queue_depth: int,
    ) -> None:
        self._ttl_seconds = ttl_seconds
        self._delivery_lease_seconds = delivery_lease_seconds
        self._maximum_queue_depth = maximum_queue_depth
        self._maximum_records = maximum_queue_depth * 2
        self._condition = threading.Condition()
        self._transfers: dict[str, Transfer] = {}
        self._queues: dict[tuple[str, str], collections.deque[str]] = (
            collections.defaultdict(collections.deque)
        )

    def submit(
        self,
        *,
        transfer_id: str,
        channel: str,
        sender: str,
        digest: str,
        body: bytes,
        timeout_seconds: float,
    ) -> tuple[str, bytes | None, str | None]:
        now = time.monotonic()
        deadline = now + timeout_seconds
        with self._condition:
            self._remove_expired(now)
            transfer = self._transfers.get(transfer_id)
            if transfer is not None:
                if (
                    transfer.channel != channel
                    or transfer.sender != sender
                    or transfer.digest != digest
                    or not hmac.compare_digest(transfer.body, body)
                ):
                    return ("conflict", None, None)
            else:
                recipient = _peer(sender)
                queue = self._queues[(channel, recipient)]
                pending_count = sum(
                    1
                    for queued_id in queue
                    if (
                        (queued := self._transfers.get(queued_id)) is not None
                        and queued.acknowledgement is None
                    )
                )
                if pending_count >= self._maximum_queue_depth:
                    return ("queue_full", None, None)
                if len(self._transfers) >= self._maximum_records:
                    return ("queue_full", None, None)
                transfer = Transfer(
                    transfer_id=transfer_id,
                    channel=channel,
                    sender=sender,
                    recipient=recipient,
                    digest=digest,
                    body=body,
                    created_at=now,
                    expires_at=now + self._ttl_seconds,
                )
                self._transfers[transfer_id] = transfer
                queue.append(transfer_id)
                self._condition.notify_all()

            while transfer.acknowledgement is None:
                now = time.monotonic()
                if now >= deadline:
                    return ("timed_out", None, None)
                if now >= transfer.expires_at:
                    self._remove_transfer(transfer_id)
                    return ("expired", None, None)
                self._condition.wait(timeout=min(deadline, transfer.expires_at) - now)
                if self._transfers.get(transfer_id) is None:
                    return ("expired", None, None)

            return (
                "acknowledged",
                transfer.acknowledgement,
                transfer.acknowledgement_digest,
            )

    def poll(
        self, *, channel: str, recipient: str, timeout_seconds: float
    ) -> Transfer | None:
        deadline = time.monotonic() + timeout_seconds
        with self._condition:
            while True:
                now = time.monotonic()
                self._remove_expired(now)
                queue = self._queues[(channel, recipient)]
                next_wake = deadline
                while queue:
                    transfer = self._transfers.get(queue[0])
                    if transfer is None or transfer.acknowledgement is not None:
                        queue.popleft()
                        continue
                    if transfer.claimed_until <= now:
                        transfer.claimed_until = min(
                            transfer.expires_at,
                            now + self._delivery_lease_seconds,
                        )
                        return transfer
                    next_wake = min(
                        next_wake,
                        transfer.claimed_until,
                        transfer.expires_at,
                    )
                    break
                if now >= deadline:
                    return None
                self._condition.wait(timeout=max(0, next_wake - now))

    def acknowledge(
        self,
        *,
        transfer_id: str,
        channel: str,
        recipient: str,
        transfer_digest: str,
        acknowledgement: bytes,
    ) -> str:
        acknowledgement_digest = hashlib.sha256(acknowledgement).hexdigest()
        with self._condition:
            self._remove_expired(time.monotonic())
            transfer = self._transfers.get(transfer_id)
            if transfer is None:
                return "not_found"
            if (
                transfer.channel != channel
                or transfer.recipient != recipient
                or transfer.digest != transfer_digest
            ):
                return "conflict"
            if transfer.acknowledgement is not None:
                if not hmac.compare_digest(transfer.acknowledgement, acknowledgement):
                    return "conflict"
                return "duplicate"
            transfer.acknowledgement = acknowledgement
            transfer.acknowledgement_digest = acknowledgement_digest
            self._remove_from_queue(transfer)
            self._condition.notify_all()
            return "acknowledged"

    def _remove_expired(self, now: float) -> None:
        expired = [
            transfer_id
            for transfer_id, transfer in self._transfers.items()
            if now >= transfer.expires_at
        ]
        for transfer_id in expired:
            self._remove_transfer(transfer_id)
        if expired:
            self._condition.notify_all()

    def _remove_transfer(self, transfer_id: str) -> None:
        transfer = self._transfers.pop(transfer_id, None)
        if transfer is not None:
            self._remove_from_queue(transfer)

    def _remove_from_queue(self, transfer: Transfer) -> None:
        queue = self._queues[(transfer.channel, transfer.recipient)]
        try:
            queue.remove(transfer.transfer_id)
        except ValueError:
            pass


class RelayHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False
    request_queue_size = 16

    def __init__(
        self,
        *,
        run_id: str,
        token: str,
        state: RelayState,
        submit_timeout_seconds: float,
        poll_timeout_seconds: float,
    ) -> None:
        super().__init__((HOST, 0), RelayRequestHandler)
        self.run_id = run_id
        self.token = token
        self.state = state
        self.submit_timeout_seconds = submit_timeout_seconds
        self.poll_timeout_seconds = poll_timeout_seconds

    def handle_error(self, request: object, client_address: tuple[str, int]) -> None:
        del request, client_address


class RelayRequestHandler(http.server.BaseHTTPRequestHandler):
    server: RelayHTTPServer
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        del format, args

    def do_POST(self) -> None:
        route = self._route()
        if route is None:
            self._empty_response(404)
            return
        operation, channel, role = route
        if not self._authorized():
            self._empty_response(401)
            return
        if operation == "submit":
            self._submit(channel=channel, sender=role)
            return
        if operation == "ack":
            self._acknowledge(channel=channel, recipient=role)
            return
        self._empty_response(405)

    def do_GET(self) -> None:
        route = self._route()
        if route is None:
            self._empty_response(404)
            return
        operation, channel, role = route
        if not self._authorized():
            self._empty_response(401)
            return
        if operation != "poll":
            self._empty_response(405)
            return
        transfer = self.server.state.poll(
            channel=channel,
            recipient=role,
            timeout_seconds=self.server.poll_timeout_seconds,
        )
        if transfer is None:
            self._empty_response(204)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(transfer.body)))
        self.send_header("X-Mori-Transfer-ID", transfer.transfer_id)
        self.send_header("X-Mori-Transfer-SHA256", transfer.digest)
        self.send_header("X-Mori-Sender-Role", transfer.sender)
        self.end_headers()
        self.wfile.write(transfer.body)

    def _submit(self, *, channel: str, sender: str) -> None:
        parsed = self._transfer_headers()
        if parsed is None:
            return
        transfer_id, supplied_digest = parsed
        body = self._body()
        if body is None:
            return
        actual_digest = hashlib.sha256(body).hexdigest()
        if not hmac.compare_digest(supplied_digest, actual_digest):
            self._empty_response(422)
            return
        result, acknowledgement, acknowledgement_digest = self.server.state.submit(
            transfer_id=transfer_id,
            channel=channel,
            sender=sender,
            digest=supplied_digest,
            body=body,
            timeout_seconds=self.server.submit_timeout_seconds,
        )
        if result == "conflict":
            self._empty_response(409)
            return
        if result == "queue_full":
            self._empty_response(429)
            return
        if result in ("timed_out", "expired"):
            self._empty_response(504)
            return
        assert acknowledgement is not None
        assert acknowledgement_digest is not None
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(acknowledgement)))
        self.send_header("X-Mori-Acknowledgement-SHA256", acknowledgement_digest)
        self.end_headers()
        self.wfile.write(acknowledgement)

    def _acknowledge(self, *, channel: str, recipient: str) -> None:
        parsed = self._transfer_headers()
        if parsed is None:
            return
        transfer_id, transfer_digest = parsed
        body = self._body()
        if body is None:
            return
        result = self.server.state.acknowledge(
            transfer_id=transfer_id,
            channel=channel,
            recipient=recipient,
            transfer_digest=transfer_digest,
            acknowledgement=body,
        )
        if result == "not_found":
            self._empty_response(404)
        elif result == "conflict":
            self._empty_response(409)
        else:
            self._empty_response(204)

    def _route(self) -> tuple[str, str, str] | None:
        parsed = urlsplit(self.path)
        if parsed.query or parsed.fragment:
            return None
        components = parsed.path.split("/")
        if (
            len(components) != 5
            or components[0] != ""
            or components[1] != "v1"
            or components[2] not in ("submit", "poll", "ack")
            or components[3] not in CHANNELS
            or components[4] not in ROLES
        ):
            return None
        return (components[2], components[3], components[4])

    def _authorized(self) -> bool:
        run_id = self.headers.get("X-Mori-Relay-Run-ID", "")
        authorization = self.headers.get("Authorization", "")
        expected_authorization = f"Bearer {self.server.token}"
        return hmac.compare_digest(run_id, self.server.run_id) and hmac.compare_digest(
            authorization, expected_authorization
        )

    def _transfer_headers(self) -> tuple[str, str] | None:
        transfer_id = self.headers.get("X-Mori-Transfer-ID", "")
        digest = self.headers.get("X-Mori-Transfer-SHA256", "")
        canonical_transfer_id = _canonical_uuid(transfer_id)
        if canonical_transfer_id is None or not _valid_digest(digest):
            self._empty_response(400)
            return None
        return (canonical_transfer_id, digest)

    def _body(self) -> bytes | None:
        if self.headers.get("Transfer-Encoding") is not None:
            self._empty_response(400)
            return None
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            self._empty_response(411)
            return None
        try:
            length = int(raw_length, 10)
        except ValueError:
            self._empty_response(400)
            return None
        if length < 0:
            self._empty_response(400)
            return None
        if length > MAXIMUM_BODY_BYTES:
            self.close_connection = True
            self._empty_response(413)
            return None
        body = self.rfile.read(length)
        if len(body) != length:
            self.close_connection = True
            self._empty_response(400)
            return None
        return body

    def _empty_response(self, status: int) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()


def _bounded_float(value: str, *, maximum: float) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0 or parsed > maximum:
        raise argparse.ArgumentTypeError("outside allowed bounds")
    return parsed


def _bounded_int(value: str, *, maximum: int) -> int:
    parsed = int(value)
    if parsed <= 0 or parsed > maximum:
        raise argparse.ArgumentTypeError("outside allowed bounds")
    return parsed


def _write_control_file(path: str, *, port: int, run_id: str, token: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        payload = {
            "schemaVersion": 1,
            "host": HOST,
            "port": port,
            "runID": run_id,
            "token": token,
            "maximumBodyBytes": MAXIMUM_BODY_BYTES,
        }
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode(
            "utf-8"
        )
        offset = 0
        while offset < len(encoded):
            offset += os.write(descriptor, encoded[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run the Debug UI-test localhost relay."
    )
    parser.add_argument("--control-file", required=True)
    parser.add_argument(
        "--ttl-seconds",
        type=lambda value: _bounded_float(value, maximum=300),
        default=30.0,
    )
    parser.add_argument(
        "--submit-timeout-seconds",
        type=lambda value: _bounded_float(value, maximum=60),
        default=15.0,
    )
    parser.add_argument(
        "--poll-timeout-seconds",
        type=lambda value: _bounded_float(value, maximum=10),
        default=1.0,
    )
    parser.add_argument(
        "--maximum-queue-depth",
        type=lambda value: _bounded_int(value, maximum=64),
        default=32,
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    run_id = str(uuid.uuid4())
    token = secrets.token_hex(32)
    state = RelayState(
        ttl_seconds=arguments.ttl_seconds,
        delivery_lease_seconds=min(
            arguments.ttl_seconds,
            arguments.submit_timeout_seconds,
        ),
        maximum_queue_depth=arguments.maximum_queue_depth,
    )
    server = RelayHTTPServer(
        run_id=run_id,
        token=token,
        state=state,
        submit_timeout_seconds=arguments.submit_timeout_seconds,
        poll_timeout_seconds=arguments.poll_timeout_seconds,
    )
    try:
        _write_control_file(
            arguments.control_file,
            port=server.server_port,
            run_id=run_id,
            token=token,
        )
    except OSError:
        server.server_close()
        print("relay startup failed", file=sys.stderr)
        return 1

    print("relay ready", flush=True)
    try:
        server.serve_forever(poll_interval=0.05)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
