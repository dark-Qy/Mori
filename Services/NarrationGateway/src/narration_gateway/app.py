"""FastAPI composition root."""

from __future__ import annotations

from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .audit import AuditSink, StructuredAuditSink
from .config import GatewayConfig
from .middleware import RequestBoundaryMiddleware
from .models import ErrorResponse, HealthResponse, NarrationRequest, NarrationResponse
from .service import NarrationService
from .transport import ChatCompletionTransport, HttpxChatCompletionTransport


def create_app(
    *,
    config: Optional[GatewayConfig] = None,
    transport: Optional[ChatCompletionTransport] = None,
    audit_sink: Optional[AuditSink] = None,
) -> FastAPI:
    runtime_config = config or GatewayConfig.from_environment()
    runtime_transport = transport
    owns_transport = False
    if runtime_transport is None and runtime_config.upstream_ready:
        runtime_transport = HttpxChatCompletionTransport(
            runtime_config.chat_completions_url,
            runtime_config.upstream_api_key or "",
        )
        owns_transport = True

    service = NarrationService(
        config=runtime_config,
        transport=runtime_transport,
        audit_sink=audit_sink or StructuredAuditSink(),
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        yield
        if owns_transport and runtime_transport is not None:
            close = getattr(runtime_transport, "aclose", None)
            if callable(close):
                await close()

    app = FastAPI(
        title="Watch Companion Narration Gateway",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
        lifespan=lifespan,
    )
    app.add_middleware(
        RequestBoundaryMiddleware,
        max_request_bytes=runtime_config.max_request_bytes,
        access_token=runtime_config.gateway_access_token,
        rate_limit_requests=runtime_config.rate_limit_requests,
        rate_limit_window_seconds=runtime_config.rate_limit_window_seconds,
    )

    @app.exception_handler(RequestValidationError)
    async def invalid_request_handler(
        request: Request, error: RequestValidationError
    ) -> JSONResponse:
        # Do not return Pydantic's input snapshots: they can contain health data.
        del request, error
        return JSONResponse(
            status_code=422,
            content={
                "error": {
                    "code": "invalid_request",
                    "message": "Request does not match the narration schema.",
                }
            },
        )

    @app.get("/healthz", response_model=HealthResponse)
    def health() -> HealthResponse:
        return HealthResponse(
            status="ok",
            upstream_configured=runtime_config.upstream_ready,
        )

    @app.post(
        "/v1/narrations",
        response_model=NarrationResponse,
        responses={
            401: {"model": ErrorResponse},
            413: {"model": ErrorResponse},
            415: {"model": ErrorResponse},
            422: {"model": ErrorResponse},
            429: {"model": ErrorResponse},
            503: {"model": ErrorResponse},
        },
    )
    async def narrate(request: NarrationRequest) -> NarrationResponse:
        return await service.generate(request)

    return app
