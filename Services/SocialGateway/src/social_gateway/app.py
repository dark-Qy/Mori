"""FastAPI composition root for social rendezvous."""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager, suppress
from typing import Annotated, Optional

from fastapi import FastAPI, Path, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .audit import AuditSink, SafeAuditEvent, StructuredAuditSink
from .boundary import RequestBoundaryMiddleware
from .config import GatewayConfig
from .models import (
    CancelRequest,
    CleanupResponse,
    EncounterCredential,
    ErrorResponse,
    HealthResponse,
    JoinSessionRequest,
    PeerCardResponse,
    SessionCredential,
    SessionJoinedResponse,
    SessionStateResponse,
)
from .store import RendezvousStore, StoreError

SessionIDPath = Annotated[
    str,
    Path(
        min_length=32,
        max_length=32,
        pattern=r"^[a-f0-9]{32}$",
    ),
]
SESSION_ERROR_RESPONSES = {
    400: {"model": ErrorResponse},
    404: {"model": ErrorResponse},
    409: {"model": ErrorResponse},
    410: {"model": ErrorResponse},
    413: {"model": ErrorResponse},
    415: {"model": ErrorResponse},
    422: {"model": ErrorResponse},
}


def create_app(
    *,
    config: Optional[GatewayConfig] = None,
    store: Optional[RendezvousStore] = None,
    audit_sink: Optional[AuditSink] = None,
) -> FastAPI:
    runtime_config = config or GatewayConfig.from_environment()
    runtime_store = store or RendezvousStore(runtime_config)
    audit = audit_sink or StructuredAuditSink()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        cleanup_task = asyncio.create_task(
            _periodic_cleanup(
                runtime_store,
                runtime_config.cleanup_interval_seconds,
                audit,
            )
        )
        try:
            yield
        finally:
            cleanup_task.cancel()
            with suppress(asyncio.CancelledError):
                await cleanup_task

    app = FastAPI(
        title="Watch Companion Social Gateway",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
        lifespan=lifespan,
    )
    app.add_middleware(
        RequestBoundaryMiddleware,
        max_request_bytes=runtime_config.max_request_bytes,
    )

    @app.exception_handler(RequestValidationError)
    async def invalid_request_handler(
        request: Request, error: RequestValidationError
    ) -> JSONResponse:
        # Pydantic error snapshots may contain NI tokens or pet cards.
        del request, error
        return _error_response(
            422,
            "invalid_request",
            "Request does not match the social rendezvous schema.",
        )

    @app.exception_handler(StoreError)
    async def store_error_handler(request: Request, error: StoreError) -> JSONResponse:
        del request
        return _error_response(error.status_code, error.code, error.message)

    @app.get("/healthz", response_model=HealthResponse)
    async def health() -> HealthResponse:
        return HealthResponse(status="ok")

    @app.post(
        "/v1/sessions",
        response_model=SessionJoinedResponse,
        status_code=201,
        responses={
            400: {"model": ErrorResponse},
            409: {"model": ErrorResponse},
            413: {"model": ErrorResponse},
            415: {"model": ErrorResponse},
            422: {"model": ErrorResponse},
            503: {"model": ErrorResponse},
        },
    )
    async def join(request: JoinSessionRequest) -> SessionJoinedResponse:
        response = await runtime_store.join(request)
        audit.record(
            SafeAuditEvent(
                action="join",
                outcome=response.status.value,
                session_id=response.session_id,
                encounter_id=response.encounter_id,
            )
        )
        return response

    @app.post(
        "/v1/sessions/{session_id}/status",
        response_model=SessionStateResponse,
        responses=SESSION_ERROR_RESPONSES,
    )
    async def status(
        session_id: SessionIDPath, credential: SessionCredential
    ) -> SessionStateResponse:
        return await runtime_store.status(session_id, credential.participant_id, credential.nonce)

    @app.post(
        "/v1/sessions/{session_id}/proximity-ready",
        response_model=SessionStateResponse,
        responses=SESSION_ERROR_RESPONSES,
    )
    async def proximity_ready(
        session_id: SessionIDPath, credential: EncounterCredential
    ) -> SessionStateResponse:
        response = await runtime_store.mark_proximity_ready(
            session_id,
            credential.participant_id,
            credential.nonce,
            credential.encounter_id,
            credential.encounter_nonce,
        )
        audit.record(
            SafeAuditEvent(
                action="proximity_ready",
                outcome=response.status.value,
                session_id=response.session_id,
                encounter_id=response.encounter_id,
            )
        )
        return response

    @app.post(
        "/v1/sessions/{session_id}/peer-card",
        response_model=PeerCardResponse,
        responses=SESSION_ERROR_RESPONSES,
    )
    async def peer_card(
        session_id: SessionIDPath, credential: EncounterCredential
    ) -> PeerCardResponse:
        response = await runtime_store.peer_card(
            session_id,
            credential.participant_id,
            credential.nonce,
            credential.encounter_id,
            credential.encounter_nonce,
        )
        audit.record(
            SafeAuditEvent(
                action="peer_card",
                outcome="released",
                session_id=session_id,
                encounter_id=response.encounter_id,
            )
        )
        return response

    @app.post(
        "/v1/sessions/{session_id}/confirm",
        response_model=SessionStateResponse,
        responses=SESSION_ERROR_RESPONSES,
    )
    async def confirm(
        session_id: SessionIDPath, credential: EncounterCredential
    ) -> SessionStateResponse:
        response = await runtime_store.confirm(
            session_id,
            credential.participant_id,
            credential.nonce,
            credential.encounter_id,
            credential.encounter_nonce,
        )
        audit.record(
            SafeAuditEvent(
                action="confirm",
                outcome=response.status.value,
                session_id=response.session_id,
                encounter_id=response.encounter_id,
            )
        )
        return response

    @app.post(
        "/v1/sessions/{session_id}/cancel",
        response_model=SessionStateResponse,
        responses=SESSION_ERROR_RESPONSES,
    )
    async def cancel(session_id: SessionIDPath, credential: CancelRequest) -> SessionStateResponse:
        response = await runtime_store.cancel(
            session_id,
            credential.participant_id,
            credential.nonce,
            credential.encounter_id,
            credential.encounter_nonce,
        )
        audit.record(
            SafeAuditEvent(
                action="cancel",
                outcome=response.status.value,
                session_id=response.session_id,
                encounter_id=response.encounter_id,
            )
        )
        return response

    @app.post(
        "/v1/maintenance/cleanup",
        response_model=CleanupResponse,
        include_in_schema=False,
    )
    async def cleanup() -> CleanupResponse:
        # Safe and idempotent: it can only expire/prune records whose TTL elapsed.
        return await runtime_store.cleanup()

    return app


def _error_response(status_code: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content={"error": {"code": code, "message": message}},
    )


async def _periodic_cleanup(
    store: RendezvousStore,
    interval_seconds: float,
    audit: AuditSink,
) -> None:
    while True:
        await asyncio.sleep(interval_seconds)
        result = await store.cleanup()
        if any(result.model_dump().values()):
            audit.record(
                SafeAuditEvent(
                    action="cleanup",
                    outcome="expired_or_purged",
                )
            )
