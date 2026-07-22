import pytest

from narration_gateway.fallback import approved_narration, local_fallback
from narration_gateway.models import Trigger


@pytest.mark.parametrize("locale", ["zh-CN", "en-US"])
@pytest.mark.parametrize("trigger", list(Trigger))
@pytest.mark.parametrize("tone", ["calm", "warm", "playful"])
def test_every_model_selectable_result_is_server_owned_and_bounded(
    locale: str, trigger: Trigger, tone: str
) -> None:
    narration = approved_narration(trigger, locale, tone, 180)

    assert narration
    assert len(narration) <= 180
    assert "http" not in narration.lower()


@pytest.mark.parametrize("locale", ["zh-CN", "en-US"])
@pytest.mark.parametrize("trigger", list(Trigger))
def test_fallback_obeys_even_the_smallest_configured_budget(locale: str, trigger: Trigger) -> None:
    narration = local_fallback(trigger, locale, 40)

    assert narration
    assert len(narration) <= 40
