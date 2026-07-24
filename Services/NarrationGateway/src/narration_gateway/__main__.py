"""Local-only development entrypoint."""

import os

import uvicorn


def _bind_port() -> int:
    raw = os.environ.get("NARRATION_BIND_PORT", "8790")
    port = int(raw)
    if not 1_024 <= port <= 65_535:
        raise ValueError("NARRATION_BIND_PORT must be between 1024 and 65535")
    return port


def main() -> None:
    uvicorn.run(
        "narration_gateway.app:create_app",
        host="127.0.0.1",
        port=_bind_port(),
        access_log=False,
        factory=True,
    )


if __name__ == "__main__":
    main()
