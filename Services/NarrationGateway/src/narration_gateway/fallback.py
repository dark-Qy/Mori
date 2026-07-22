"""Deterministic, non-medical local narration fallbacks."""

from __future__ import annotations

from typing import Dict, Tuple

from .models import Trigger

_ZH_FALLBACKS: Dict[Trigger, str] = {
    Trigger.DAILY_SUMMARY: "今天的记录我先替你收好。等线索更完整时，我们再一起看看节奏。",
    Trigger.RULE_HIT: "我注意到你的节奏有一点变化。先照顾好当下，我们晚些再一起回顾。",
    Trigger.RANDOM_CHECK_IN: "我只是路过来看看你。现在不必完成什么，按自己的节奏继续吧。",
    Trigger.RECOVERY_MOMENT: "先给自己留一点缓冲吧。我会安静陪着你，休息好了再出发。",
    Trigger.STORY_PROGRESS: "这一页旅程我已经收好了。等准备好，我们再一起翻开下一页。",
}

_EN_FALLBACKS: Dict[Trigger, str] = {
    Trigger.DAILY_SUMMARY: (
        "I saved today's notes for you. We can look at the pattern when the picture is clearer."
    ),
    Trigger.RULE_HIT: (
        "I noticed a small change in your rhythm. Take care of the moment; we can reflect later."
    ),
    Trigger.RANDOM_CHECK_IN: (
        "I just stopped by to see you. Nothing is due right now; keep your own pace."
    ),
    Trigger.RECOVERY_MOMENT: (
        "Let's leave a little room to recover. I will stay nearby until you are ready."
    ),
    Trigger.STORY_PROGRESS: (
        "I saved this page of our journey. We can turn the next page when you are ready."
    ),
}

_ZH_TONE_VARIANTS: Dict[Tuple[Trigger, str], str] = {
    (
        Trigger.DAILY_SUMMARY,
        "warm",
    ): "今天的线索已经收好啦。我们不用急着下结论，慢慢看见自己的节奏就好。",
    (Trigger.DAILY_SUMMARY, "playful"): "今日线索入袋！先不急着解谜，等图案更清楚时再一起看看。",
    (Trigger.RULE_HIT, "warm"): "我看见节奏有一点变化。先照顾此刻的自己，晚些我们再温柔地回顾。",
    (Trigger.RULE_HIT, "playful"): "节奏好像晃了一下，我先把这个小线索收进口袋，之后再一起研究。",
    (Trigger.RANDOM_CHECK_IN, "warm"): "我只是想来陪你一会儿。现在没有任务，照自己的步调继续就好。",
    (
        Trigger.RANDOM_CHECK_IN,
        "playful",
    ): "路过，探头，确认你还在按自己的节奏冒险。今天不用向我交作业。",
    (Trigger.RECOVERY_MOMENT, "warm"): "给自己留一点缓冲吧。我会待在这里，等你觉得可以了再继续。",
    (
        Trigger.RECOVERY_MOMENT,
        "playful",
    ): "冒险队申请短暂停靠。我们先把力气放回口袋，准备好再启程。",
    (
        Trigger.STORY_PROGRESS,
        "warm",
    ): "我把这一页旅程好好收起来了。等你准备好，我们再一起走向下一页。",
    (Trigger.STORY_PROGRESS, "playful"): "新的一页已经盖章收藏！下一段路不会跑掉，准备好再出发。",
}

_EN_TONE_VARIANTS: Dict[Tuple[Trigger, str], str] = {
    (Trigger.DAILY_SUMMARY, "warm"): (
        "Today's clues are safe with me. We do not need a conclusion yet; the pattern can emerge."
    ),
    (Trigger.DAILY_SUMMARY, "playful"): (
        "Today's clues are in the bag. We can solve the pattern when more pieces appear."
    ),
    (Trigger.RULE_HIT, "warm"): (
        "I noticed a small shift in the rhythm. Care for this moment; we can reflect later."
    ),
    (Trigger.RULE_HIT, "playful"): (
        "The rhythm wobbled a little, so I tucked the clue away for us to inspect later."
    ),
    (Trigger.RANDOM_CHECK_IN, "warm"): (
        "I only came to keep you company. Nothing is due; continue at your own pace."
    ),
    (Trigger.RANDOM_CHECK_IN, "playful"): (
        "Just popping in to confirm your adventure is still moving at your own pace."
    ),
    (Trigger.RECOVERY_MOMENT, "warm"): (
        "Leave yourself a little breathing room. I will stay nearby until you feel ready."
    ),
    (Trigger.RECOVERY_MOMENT, "playful"): (
        "The adventure team requests a short pause. We can set off again when you are ready."
    ),
    (Trigger.STORY_PROGRESS, "warm"): (
        "I kept this page of our journey safe. We can continue when you are ready."
    ),
    (Trigger.STORY_PROGRESS, "playful"): (
        "This page is stamped and saved. The next part will wait until we are ready."
    ),
}


def _within_budget(text: str, max_characters: int) -> str:
    return text[:max_characters].rstrip()


def approved_narration(trigger: Trigger, locale: str, tone: str, max_characters: int) -> str:
    fallback_catalog = _EN_FALLBACKS if locale == "en-US" else _ZH_FALLBACKS
    variant_catalog = _EN_TONE_VARIANTS if locale == "en-US" else _ZH_TONE_VARIANTS
    selected = fallback_catalog[trigger] if tone == "calm" else variant_catalog[(trigger, tone)]
    return _within_budget(selected, max_characters)


def local_fallback(trigger: Trigger, locale: str, max_characters: int = 180) -> str:
    catalog = _EN_FALLBACKS if locale == "en-US" else _ZH_FALLBACKS
    return _within_budget(catalog[trigger], max_characters)
