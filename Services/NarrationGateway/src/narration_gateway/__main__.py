"""Local-only development entrypoint."""

import uvicorn


def main() -> None:
    uvicorn.run(
        "narration_gateway.app:create_app",
        host="127.0.0.1",
        port=8787,
        access_log=False,
        factory=True,
    )


if __name__ == "__main__":
    main()
