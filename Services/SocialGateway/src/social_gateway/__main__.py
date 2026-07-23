"""Local-only development entrypoint."""

import uvicorn


def main() -> None:
    uvicorn.run(
        "social_gateway.app:create_app",
        host="127.0.0.1",
        port=8788,
        access_log=False,
        factory=True,
    )


if __name__ == "__main__":
    main()
