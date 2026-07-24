"""Server-owned weekly-copy rendering from typed facts and style slots."""

from __future__ import annotations

from typing import Dict, List, Literal, Sequence, Tuple

from .models import WeeklyActivityKind, WeeklyMemoryPolishRequest

WeeklyStyle = Literal["calm", "warm", "playful"]
WeeklyFocus = Literal["movement", "rhythm", "balanced"]
WeeklyEnding = Literal["trail", "together", "collection"]

_ZH_ACTIVITY_LABELS: Dict[WeeklyActivityKind, str] = {
    WeeklyActivityKind.WALKING: "步行",
    WeeklyActivityKind.RUNNING: "跑步",
    WeeklyActivityKind.CYCLING: "骑行",
    WeeklyActivityKind.FOOTBALL: "足球",
    WeeklyActivityKind.BASKETBALL: "篮球",
    WeeklyActivityKind.TENNIS: "网球",
    WeeklyActivityKind.BADMINTON: "羽毛球",
    WeeklyActivityKind.SWIMMING: "游泳",
    WeeklyActivityKind.HIKING: "徒步",
    WeeklyActivityKind.YOGA: "瑜伽",
    WeeklyActivityKind.STRENGTH: "力量训练",
    WeeklyActivityKind.OTHER: "其他运动",
}

_EN_ACTIVITY_LABELS: Dict[WeeklyActivityKind, str] = {
    WeeklyActivityKind.WALKING: "walking",
    WeeklyActivityKind.RUNNING: "running",
    WeeklyActivityKind.CYCLING: "cycling",
    WeeklyActivityKind.FOOTBALL: "football",
    WeeklyActivityKind.BASKETBALL: "basketball",
    WeeklyActivityKind.TENNIS: "tennis",
    WeeklyActivityKind.BADMINTON: "badminton",
    WeeklyActivityKind.SWIMMING: "swimming",
    WeeklyActivityKind.HIKING: "hiking",
    WeeklyActivityKind.YOGA: "yoga",
    WeeklyActivityKind.STRENGTH: "strength training",
    WeeklyActivityKind.OTHER: "other activity",
}


def activity_label(kind: WeeklyActivityKind, locale: str) -> str:
    catalog = _EN_ACTIVITY_LABELS if locale == "en-US" else _ZH_ACTIVITY_LABELS
    return catalog[kind]


def allowed_evidence_phrases(request: WeeklyMemoryPolishRequest) -> List[str]:
    if request.locale == "en-US":
        phrases = [
            f"{activity_label(activity.kind, request.locale)}: {activity.duration_minutes} minutes"
            for activity in request.activities
        ]
        if request.total_steps is not None:
            phrases.append(f"{request.total_steps} steps")
        if request.active_minutes is not None:
            phrases.append(f"{request.active_minutes} active minutes")
        if request.average_sleep_minutes is not None:
            phrases.append(f"{request.average_sleep_minutes} minutes of average sleep")
        return phrases

    phrases = [
        f"{activity_label(activity.kind, request.locale)} {activity.duration_minutes} 分钟"
        for activity in request.activities
    ]
    if request.total_steps is not None:
        phrases.append(f"{request.total_steps} 步")
    if request.active_minutes is not None:
        phrases.append(f"活跃 {request.active_minutes} 分钟")
    if request.average_sleep_minutes is not None:
        phrases.append(f"平均睡眠 {request.average_sleep_minutes} 分钟")
    return phrases


def render_weekly_copy(
    request: WeeklyMemoryPolishRequest,
    *,
    style: WeeklyStyle,
    focus: WeeklyFocus,
    ending: WeeklyEnding,
    max_title_characters: int,
    max_body_characters: int,
) -> Tuple[str, str]:
    title = _title(request, style)
    ordered_phrases = _ordered_evidence(request, focus)
    opening, closing, delimiter = _sentence_slots(request.locale, style, ending)
    body = _fit_sentence(
        ordered_phrases,
        opening=opening,
        closing=closing,
        delimiter=delimiter,
        max_characters=max_body_characters,
        locale=request.locale,
    )
    return title[:max_title_characters].rstrip(), body


def deterministic_weekly_copy(
    request: WeeklyMemoryPolishRequest,
    *,
    max_title_characters: int,
    max_body_characters: int,
) -> Tuple[str, str]:
    if request.activities:
        focus: WeeklyFocus = "movement"
    elif request.average_sleep_minutes is not None:
        focus = "rhythm"
    else:
        focus = "balanced"
    ending: WeeklyEnding = {
        "calm": "trail",
        "warm": "together",
        "playful": "collection",
    }[request.personality.voice]
    return render_weekly_copy(
        request,
        style=request.personality.voice,
        focus=focus,
        ending=ending,
        max_title_characters=max_title_characters,
        max_body_characters=max_body_characters,
    )


def _title(request: WeeklyMemoryPolishRequest, style: WeeklyStyle) -> str:
    if request.locale == "en-US":
        if request.activities:
            label = activity_label(request.activities[0].kind, request.locale).title()
            if style == "playful":
                return f"{label} in Mori's Adventure"
            if style == "warm":
                return f"A Week with {label}"
            return f"This Week's {label}"
        return {
            "calm": "This Week's Trail",
            "warm": "A Week Together",
            "playful": "Mori's Weekly Finds",
        }[style]

    if request.activities:
        label = activity_label(request.activities[0].kind, request.locale)
        if style == "playful":
            return f"{label}冒险收藏"
        if style == "warm":
            return f"和{label}一起向前"
        return f"这一周的{label}脚印"
    return {
        "calm": "这一周的脚印",
        "warm": "一起走过的这周",
        "playful": "Mori 的本周收藏",
    }[style]


def _ordered_evidence(request: WeeklyMemoryPolishRequest, focus: WeeklyFocus) -> Sequence[str]:
    phrases = allowed_evidence_phrases(request)
    activity_count = len(request.activities)
    activities = phrases[:activity_count]
    metrics = phrases[activity_count:]
    if focus == "movement":
        return [*activities, *metrics]
    if focus == "rhythm":
        sleep = [
            phrase
            for phrase in metrics
            if ("平均睡眠" in phrase if request.locale == "zh-CN" else "average sleep" in phrase)
        ]
        remaining = [phrase for phrase in phrases if phrase not in sleep]
        return [*sleep, *remaining]
    return phrases


def _sentence_slots(locale: str, style: WeeklyStyle, ending: WeeklyEnding) -> Tuple[str, str, str]:
    if locale == "en-US":
        opening = {
            "calm": "This week recorded ",
            "warm": "This week we shared ",
            "playful": "This week's adventure bag holds ",
        }[style]
        closing = {
            "trail": ". Mori kept the week's trail safe.",
            "together": ". Mori saved these moments for us.",
            "collection": ". Mori added them to our adventure collection.",
        }[ending]
        return opening, closing, ", "

    opening = {
        "calm": "这周记录了",
        "warm": "这周我们一起留下了",
        "playful": "这周的冒险袋里有",
    }[style]
    closing = {
        "trail": "。Mori 把这些脚印收好了。",
        "together": "。下一段路，我们也一起走。",
        "collection": "。这些闪亮片段已经收藏。",
    }[ending]
    return opening, closing, "、"


def _fit_sentence(
    phrases: Sequence[str],
    *,
    opening: str,
    closing: str,
    delimiter: str,
    max_characters: int,
    locale: str,
) -> str:
    selected: List[str] = []
    for phrase in phrases:
        candidate = opening + delimiter.join([*selected, phrase]) + closing
        if len(candidate) <= max_characters:
            selected.append(phrase)
    if selected:
        return opening + delimiter.join(selected) + closing

    compact_opening = "This week: " if locale == "en-US" else "本周："
    compact_closing = "." if locale == "en-US" else "。"
    # Request and configuration bounds guarantee the shortest server-owned
    # evidence phrase fits within the minimum configured body budget.
    return compact_opening + phrases[0] + compact_closing
