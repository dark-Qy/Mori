"""Strict public DTOs for the v1 social rendezvous API."""

from __future__ import annotations

import base64
import binascii
import re
from datetime import datetime
from enum import Enum
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

PARTICIPANT_PATTERN = re.compile(r"^[A-Za-z0-9_-]{16,128}$")
JOIN_REQUEST_PATTERN = re.compile(r"^[A-Za-z0-9_-]{16,128}$")
NONCE_PATTERN = re.compile(r"^[A-Za-z0-9_-]{32,128}$")
ENCOUNTER_ID_PATTERN = re.compile(r"^[a-f0-9]{32}$")
ASSET_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
MAX_DISCOVERY_TOKEN_BYTES = 2_048
MAX_DISCOVERY_TOKEN_BASE64_CHARACTERS = 4_096


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class SessionStatus(str, Enum):
    WAITING = "waiting"
    MATCHED = "matched"
    PROXIMITY_READY = "proximity_ready"
    CONFIRMED = "confirmed"
    CANCELLED = "cancelled"
    EXPIRED = "expired"


class SocialState(str, Enum):
    GREETING = "greeting"
    WALK = "walk"
    QUIET_COMPANY = "quiet_company"


class PublicPetCardV1(StrictModel):
    """Allowlisted game-only card. Health, mood inference, and free text are absent."""

    schema_version: Literal["public_pet_card_v1"]
    pet_name: str = Field(min_length=1, max_length=32)
    character_id: str = Field(min_length=1, max_length=64)
    outfit_id: Optional[str] = Field(default=None, min_length=1, max_length=64)
    background_id: Optional[str] = Field(default=None, min_length=1, max_length=64)
    social_state: SocialState

    @field_validator("pet_name")
    @classmethod
    def validate_pet_name(cls, value: str) -> str:
        if any(ord(character) < 32 or ord(character) == 127 for character in value):
            raise ValueError("pet_name contains control characters")
        return value

    @field_validator("character_id", "outfit_id", "background_id")
    @classmethod
    def validate_asset_id(cls, value: Optional[str]) -> Optional[str]:
        if value is not None and not ASSET_ID_PATTERN.fullmatch(value):
            raise ValueError("asset id contains unsupported characters")
        return value


class JoinSessionRequest(StrictModel):
    participant_id: str = Field(min_length=16, max_length=128)
    join_request_id: str = Field(min_length=16, max_length=128)
    discovery_token: str = Field(min_length=4, max_length=MAX_DISCOVERY_TOKEN_BASE64_CHARACTERS)
    public_card: PublicPetCardV1

    @field_validator("participant_id")
    @classmethod
    def validate_participant_id(cls, value: str) -> str:
        if not PARTICIPANT_PATTERN.fullmatch(value):
            raise ValueError("participant_id must be an opaque URL-safe value")
        return value

    @field_validator("join_request_id")
    @classmethod
    def validate_join_request_id(cls, value: str) -> str:
        if not JOIN_REQUEST_PATTERN.fullmatch(value):
            raise ValueError("join_request_id must be an opaque URL-safe value")
        return value

    @field_validator("discovery_token")
    @classmethod
    def validate_discovery_token(cls, value: str) -> str:
        try:
            encoded = value.encode("ascii")
            decoded = base64.b64decode(encoded, validate=True)
        except (UnicodeEncodeError, binascii.Error, ValueError) as error:
            raise ValueError("discovery_token must be canonical base64") from error
        if not 1 <= len(decoded) <= MAX_DISCOVERY_TOKEN_BYTES:
            raise ValueError("discovery_token decoded size is out of bounds")
        if base64.b64encode(decoded).decode("ascii") != value:
            raise ValueError("discovery_token must be canonical base64")
        return value


class SessionCredential(StrictModel):
    participant_id: str = Field(min_length=16, max_length=128)
    nonce: str = Field(min_length=32, max_length=128)

    @field_validator("participant_id")
    @classmethod
    def validate_participant_id(cls, value: str) -> str:
        if not PARTICIPANT_PATTERN.fullmatch(value):
            raise ValueError("participant_id must be an opaque URL-safe value")
        return value

    @field_validator("nonce")
    @classmethod
    def validate_nonce(cls, value: str) -> str:
        if not NONCE_PATTERN.fullmatch(value):
            raise ValueError("nonce has an invalid format")
        return value


class EncounterCredential(SessionCredential):
    encounter_id: str = Field(min_length=32, max_length=32)
    encounter_nonce: str = Field(min_length=32, max_length=128)

    @field_validator("encounter_id")
    @classmethod
    def validate_encounter_id(cls, value: str) -> str:
        if not ENCOUNTER_ID_PATTERN.fullmatch(value):
            raise ValueError("encounter_id has an invalid format")
        return value

    @field_validator("encounter_nonce")
    @classmethod
    def validate_encounter_nonce(cls, value: str) -> str:
        if not NONCE_PATTERN.fullmatch(value):
            raise ValueError("encounter_nonce has an invalid format")
        return value


class CancelRequest(SessionCredential):
    encounter_id: Optional[str] = Field(default=None, min_length=32, max_length=32)
    encounter_nonce: Optional[str] = Field(default=None, min_length=32, max_length=128)

    @field_validator("encounter_id")
    @classmethod
    def validate_encounter_id(cls, value: Optional[str]) -> Optional[str]:
        if value is not None and not ENCOUNTER_ID_PATTERN.fullmatch(value):
            raise ValueError("encounter_id has an invalid format")
        return value

    @field_validator("encounter_nonce")
    @classmethod
    def validate_encounter_nonce(cls, value: Optional[str]) -> Optional[str]:
        if value is not None and not NONCE_PATTERN.fullmatch(value):
            raise ValueError("encounter_nonce has an invalid format")
        return value

    @model_validator(mode="after")
    def validate_generation_pair(self) -> "CancelRequest":
        if (self.encounter_id is None) != (self.encounter_nonce is None):
            raise ValueError("encounter_id and encounter_nonce must be supplied together")
        return self


class SessionStateResponse(StrictModel):
    session_id: str
    status: SessionStatus
    expires_at: datetime
    encounter_id: Optional[str] = None
    encounter_nonce: Optional[str] = None
    peer_discovery_token: Optional[str] = None
    self_proximity_ready: bool = False
    peer_proximity_ready: bool = False
    proximity_verified: bool = False
    proximity_verified_at: Optional[datetime] = None
    self_preview_released: bool = False
    peer_preview_released: bool = False
    self_confirmed: bool = False
    peer_confirmed: bool = False


class SessionJoinedResponse(SessionStateResponse):
    nonce: str


class PeerCardResponse(StrictModel):
    encounter_id: str
    encounter_nonce: str
    public_card: PublicPetCardV1


class CleanupResponse(StrictModel):
    expired_sessions: int
    expired_encounters: int
    purged_sessions: int
    purged_encounters: int


class HealthResponse(StrictModel):
    status: Literal["ok"]


class ErrorDetail(StrictModel):
    code: str
    message: str


class ErrorResponse(StrictModel):
    error: ErrorDetail
