"""Strict public and upstream schemas.

The public request is deliberately structured: it prevents arbitrary prompt
injection fields and gives every potentially sensitive collection a hard cap.
"""

from __future__ import annotations

from enum import Enum
from typing import Annotated, Any, Dict, List, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

StrictIdentifier = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=1,
        max_length=64,
        pattern=r"^[A-Za-z0-9_-]+$",
        strict=True,
    ),
]
SourceHash = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=8,
        max_length=128,
        pattern=r"^[A-Za-z0-9._:-]+$",
        strict=True,
    ),
]
ShortText = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=1,
        max_length=160,
        pattern=r"^[^\x00-\x1F\x7F]+$",
        strict=True,
    ),
]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Trigger(str, Enum):
    DAILY_SUMMARY = "daily_summary"
    RULE_HIT = "rule_hit"
    RANDOM_CHECK_IN = "random_check_in"
    RECOVERY_MOMENT = "recovery_moment"
    STORY_PROGRESS = "story_progress"


class PetContext(StrictModel):
    name: Annotated[
        str,
        StringConstraints(
            strip_whitespace=True,
            min_length=1,
            max_length=24,
            pattern=r"^[^\x00-\x1F\x7F]+$",
            strict=True,
        ),
    ]
    mood: Literal["calm", "curious", "cheerful", "sleepy", "concerned"]
    level: int = Field(ge=1, le=100, strict=True)
    bond: int = Field(ge=0, le=100, strict=True)


class SleepContext(StrictModel):
    last_night_minutes: Optional[int] = Field(default=None, ge=0, le=1_440, strict=True)
    efficiency_percent: Optional[float] = Field(
        default=None, ge=0, le=100, strict=True, allow_inf_nan=False
    )
    awakenings: Optional[int] = Field(default=None, ge=0, le=100, strict=True)
    baseline_delta_minutes: Optional[int] = Field(default=None, ge=-720, le=720, strict=True)
    trend_14d: Literal["improving", "stable", "declining", "insufficient"]
    last_night_stages: List["SleepStageContext"] = Field(default_factory=list, max_length=96)

    @model_validator(mode="after")
    def stages_are_ordered_and_non_overlapping(self) -> "SleepContext":
        previous_end = 0
        for segment in self.last_night_stages:
            if segment.start_offset_minutes < previous_end:
                raise ValueError("sleep stages must be ordered and non-overlapping")
            previous_end = segment.start_offset_minutes + segment.duration_minutes
            if previous_end > 1_440:
                raise ValueError("sleep stage timeline cannot exceed 24 hours")
        return self


class SleepStageContext(StrictModel):
    stage: Literal["awake", "core", "deep", "rem", "in_bed", "unknown"]
    start_offset_minutes: int = Field(ge=0, le=1_439, strict=True)
    duration_minutes: int = Field(ge=1, le=1_440, strict=True)


class HeartContext(StrictModel):
    resting_bpm: Optional[float] = Field(
        default=None, ge=20, le=250, strict=True, allow_inf_nan=False
    )
    baseline_resting_bpm: Optional[float] = Field(
        default=None, ge=20, le=250, strict=True, allow_inf_nan=False
    )
    trend: Literal["lower", "stable", "higher", "insufficient"]


class WorkoutContext(StrictModel):
    kind: Annotated[
        str,
        StringConstraints(
            strip_whitespace=True,
            min_length=1,
            max_length=40,
            pattern=r"^[^\x00-\x1F\x7F]+$",
            strict=True,
        ),
    ]
    duration_minutes: int = Field(ge=1, le=1_440, strict=True)


class ActivityContext(StrictModel):
    steps: Optional[int] = Field(default=None, ge=0, le=200_000, strict=True)
    active_minutes: Optional[int] = Field(default=None, ge=0, le=1_440, strict=True)
    workouts: List[WorkoutContext] = Field(default_factory=list, max_length=8)


class BaselineContext(StrictModel):
    days: int = Field(ge=0, le=30, strict=True)
    average_sleep_minutes: Optional[int] = Field(default=None, ge=0, le=1_440, strict=True)
    average_resting_bpm: Optional[float] = Field(
        default=None, ge=20, le=250, strict=True, allow_inf_nan=False
    )
    average_steps: Optional[int] = Field(default=None, ge=0, le=200_000, strict=True)


class DailyHealthSummary(StrictModel):
    day_offset: int = Field(ge=0, le=13, strict=True)
    sleep_minutes: Optional[int] = Field(default=None, ge=0, le=1_440, strict=True)
    resting_bpm: Optional[float] = Field(
        default=None, ge=20, le=250, strict=True, allow_inf_nan=False
    )
    steps: Optional[int] = Field(default=None, ge=0, le=200_000, strict=True)
    active_minutes: Optional[int] = Field(default=None, ge=0, le=1_440, strict=True)


class HealthContext(StrictModel):
    sleep: SleepContext
    heart: HeartContext
    activity: ActivityContext
    baseline: BaselineContext
    daily_history: List[DailyHealthSummary] = Field(default_factory=list, max_length=14)

    @model_validator(mode="after")
    def history_has_unique_offsets(self) -> "HealthContext":
        offsets = [day.day_offset for day in self.daily_history]
        if len(offsets) != len(set(offsets)):
            raise ValueError("daily history day offsets must be unique")
        if offsets != sorted(offsets):
            raise ValueError("daily history must be ordered from newest to oldest")
        return self


class RuleHit(StrictModel):
    rule_id: StrictIdentifier
    kind: Literal["encouragement", "attention", "achievement", "recovery"]
    summary: ShortText


class StoryContext(StrictModel):
    mainline_chapter: int = Field(ge=1, le=10_000, strict=True)
    recent_event: Optional[ShortText] = None
    side_quest: Optional[ShortText] = None


class NarrationRequest(StrictModel):
    request_id: StrictIdentifier
    locale: Literal["zh-CN", "en-US"] = "zh-CN"
    trigger: Trigger
    pet: PetContext
    health: HealthContext
    rule_hits: List[RuleHit] = Field(default_factory=list, max_length=8)
    story: StoryContext
    schedule_context: Optional[ShortText] = None


class WeeklyActivityKind(str, Enum):
    WALKING = "walking"
    RUNNING = "running"
    CYCLING = "cycling"
    FOOTBALL = "football"
    BASKETBALL = "basketball"
    TENNIS = "tennis"
    BADMINTON = "badminton"
    SWIMMING = "swimming"
    HIKING = "hiking"
    YOGA = "yoga"
    STRENGTH = "strength"
    OTHER = "other"


class WeeklyActivityFact(StrictModel):
    kind: WeeklyActivityKind
    duration_minutes: int = Field(ge=1, le=10_080, strict=True)


class PersonalityTheme(str, Enum):
    OUTDOOR = "outdoor"
    BALL_SPORTS = "ball_sports"
    RACKET_SPORTS = "racket_sports"
    WATER_SPORTS = "water_sports"
    MINDFUL = "mindful"
    STRENGTH = "strength"
    EXPLORATION = "exploration"


class CompactPersonalityProjection(StrictModel):
    """Non-sensitive expression controls; never a diagnosis or user profile."""

    voice: Literal["calm", "warm", "playful"] = "warm"
    pace: Literal["gentle", "balanced", "brisk"] = "balanced"
    themes: List[PersonalityTheme] = Field(default_factory=list, max_length=3)
    is_personalized: bool = False

    @model_validator(mode="after")
    def themes_are_unique(self) -> "CompactPersonalityProjection":
        if len(self.themes) != len(set(self.themes)):
            raise ValueError("personality themes must be unique")
        return self


ChatMessageText = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=1,
        max_length=500,
        pattern=r"^[^\x00-\x1F\x7F]+$",
        strict=True,
    ),
]


class ChatMessage(StrictModel):
    role: Literal["user", "assistant"]
    content: ChatMessageText


class ChatReplyRequest(StrictModel):
    """A short conversation window; system/developer messages are server-owned."""

    request_id: StrictIdentifier
    locale: Literal["zh-CN", "en-US"] = "zh-CN"
    messages: List[ChatMessage] = Field(min_length=1, max_length=12)
    personality: CompactPersonalityProjection

    @model_validator(mode="after")
    def conversation_is_alternating_and_awaits_a_reply(self) -> "ChatReplyRequest":
        if self.messages[0].role != "user" or self.messages[-1].role != "user":
            raise ValueError("chat must start and end with a user message")
        for previous, current in zip(self.messages, self.messages[1:]):
            if previous.role == current.role:
                raise ValueError("chat message roles must alternate")
        return self


class WeeklyMemoryPolishRequest(StrictModel):
    """A typed weekly snapshot; no prompt or arbitrary free text is accepted."""

    request_id: StrictIdentifier
    source_hash: SourceHash
    locale: Literal["zh-CN", "en-US"] = "zh-CN"
    activities: List[WeeklyActivityFact] = Field(default_factory=list, max_length=12)
    total_steps: Optional[int] = Field(default=None, ge=0, le=1_400_000, strict=True)
    active_minutes: Optional[int] = Field(default=None, ge=0, le=10_080, strict=True)
    average_sleep_minutes: Optional[int] = Field(default=None, ge=0, le=1_440, strict=True)
    personality: CompactPersonalityProjection = Field(default_factory=CompactPersonalityProjection)

    @model_validator(mode="after")
    def facts_are_usable_and_activities_are_unique(self) -> "WeeklyMemoryPolishRequest":
        activity_kinds = [activity.kind for activity in self.activities]
        if len(activity_kinds) != len(set(activity_kinds)):
            raise ValueError("weekly activity kinds must be unique")
        if (
            not self.activities
            and self.total_steps is None
            and self.active_minutes is None
            and self.average_sleep_minutes is None
        ):
            raise ValueError("at least one weekly fact is required")
        return self


class FallbackReason(str, Enum):
    MISSING_CONFIGURATION = "missing_configuration"
    UNAUTHORIZED = "upstream_unauthorized"
    RATE_LIMITED = "upstream_rate_limited"
    SERVER_ERROR = "upstream_server_error"
    CLIENT_ERROR = "upstream_client_error"
    TIMEOUT = "upstream_timeout"
    NETWORK_ERROR = "upstream_network_error"
    MALFORMED = "malformed_upstream_response"
    UNSAFE = "unsafe_upstream_response"
    UNSAFE_INPUT = "unsafe_user_input"
    RESPONSE_TOO_LARGE = "upstream_response_too_large"
    INTERNAL_ERROR = "internal_error"


class NarrationResponse(StrictModel):
    request_id: StrictIdentifier
    narration: Annotated[
        str,
        StringConstraints(
            strip_whitespace=True,
            min_length=1,
            max_length=300,
            pattern=r"^[^\x00-\x1F\x7F]+$",
            strict=True,
        ),
    ]
    source: Literal["upstream", "fallback"]
    fallback_reason: Optional[FallbackReason]
    safe: Literal[True] = True

    @model_validator(mode="after")
    def source_matches_fallback_reason(self) -> "NarrationResponse":
        if self.source == "upstream" and self.fallback_reason is not None:
            raise ValueError("upstream narration cannot include a fallback reason")
        if self.source == "fallback" and self.fallback_reason is None:
            raise ValueError("fallback narration requires a fallback reason")
        return self


ChatReplyText = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=1,
        max_length=240,
        pattern=r"^[^\x00-\x1F\x7F]+$",
        strict=True,
    ),
]


class ChatReplyResponse(StrictModel):
    request_id: StrictIdentifier
    reply: ChatReplyText
    source: Literal["upstream", "fallback"]
    fallback_reason: Optional[FallbackReason]
    passed_output_checks: Literal[True] = True

    @model_validator(mode="after")
    def source_matches_fallback_reason(self) -> "ChatReplyResponse":
        if self.source == "upstream" and self.fallback_reason is not None:
            raise ValueError("upstream chat reply cannot include a fallback reason")
        if self.source == "fallback" and self.fallback_reason is None:
            raise ValueError("fallback chat reply requires a fallback reason")
        return self


WeeklyTitle = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=1,
        max_length=32,
        pattern=r"^[^\x00-\x1F\x7F]+$",
        strict=True,
    ),
]
WeeklyBody = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=1,
        max_length=180,
        pattern=r"^[^\x00-\x1F\x7F]+$",
        strict=True,
    ),
]


class WeeklyMemoryPolishResponse(StrictModel):
    request_id: StrictIdentifier
    source_hash: SourceHash
    title: WeeklyTitle
    body: WeeklyBody
    source: Literal["upstream", "fallback"]
    fallback_reason: Optional[FallbackReason]
    safe: Literal[True] = True

    @model_validator(mode="after")
    def source_matches_fallback_reason(self) -> "WeeklyMemoryPolishResponse":
        if self.source == "upstream" and self.fallback_reason is not None:
            raise ValueError("upstream weekly copy cannot include a fallback reason")
        if self.source == "fallback" and self.fallback_reason is None:
            raise ValueError("fallback weekly copy requires a fallback reason")
        return self


class ErrorDetail(StrictModel):
    code: Literal[
        "invalid_request",
        "request_too_large",
        "unsupported_media_type",
        "unauthorized",
        "rate_limited",
        "service_unavailable",
    ]
    message: Annotated[str, StringConstraints(min_length=1, max_length=120)]


class ErrorResponse(StrictModel):
    error: ErrorDetail


class HealthResponse(StrictModel):
    status: Literal["ok"]
    upstream_configured: bool


class GeneratedNarration(StrictModel):
    """The model selects presentation style; it cannot supply health-facing copy."""

    tone: Literal["calm", "warm", "playful"]


class GeneratedWeeklyMemoryStyle(StrictModel):
    """The model chooses presentation slots; it never supplies visible copy."""

    style: Literal["calm", "warm", "playful"]
    focus: Literal["movement", "rhythm", "balanced"]
    ending: Literal["trail", "together", "collection"]


class GeneratedChatReply(StrictModel):
    """The only provider-authored text allowed onto the chatbot surface."""

    reply: ChatReplyText


class UpstreamMessage(StrictModel):
    role: Literal["assistant"]
    content: Annotated[
        str,
        StringConstraints(
            min_length=1,
            max_length=4_096,
            pattern=r"^[^\x00-\x1F\x7F]+$",
            strict=True,
        ),
    ]
    refusal: Optional[str] = None
    # StepFun reasoning models can return these provider-owned metadata fields
    # beside content. They are never logged, rendered, or used for decisions.
    reasoning: Optional[str] = None
    reasoning_content: Optional[str] = None


class UpstreamChoice(StrictModel):
    index: Literal[0]
    message: UpstreamMessage
    finish_reason: Literal["stop"]
    logprobs: Literal[None] = None


class UpstreamUsage(StrictModel):
    prompt_tokens: int = Field(ge=0, strict=True)
    completion_tokens: int = Field(ge=0, strict=True)
    total_tokens: int = Field(ge=0, strict=True)
    # StepFun includes these accounting details on current reasoning models.
    # They are accepted for provider compatibility but never logged or used to
    # influence user-facing copy.
    cached_tokens: Optional[int] = Field(default=None, ge=0, strict=True)
    prompt_tokens_details: Optional[Dict[str, Any]] = None
    completion_tokens_details: Optional[Dict[str, Any]] = None


class UpstreamChatCompletionResponse(StrictModel):
    id: str
    object: Literal["chat.completion"]
    created: int = Field(ge=0, strict=True)
    model: str
    choices: List[UpstreamChoice] = Field(min_length=1, max_length=1)
    usage: Optional[UpstreamUsage] = None
    system_fingerprint: Optional[str] = None
    service_tier: Optional[str] = None
    # StepFun can attach an agent descriptor to an otherwise standard response.
    # Keep the envelope strict for unknown fields while explicitly ignoring this
    # documented provider metadata.
    agent: Optional[Any] = None
