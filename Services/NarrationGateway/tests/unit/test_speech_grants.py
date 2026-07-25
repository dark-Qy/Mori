from narration_gateway.speech_grants import SpeechGrantStore


def test_speech_grant_is_one_time_and_strips_inline_acting_directions() -> None:
    now = [100.0]
    store = SpeechGrantStore(clock=lambda: now[0])

    store.issue("chat-request-001", "（压低声音）我在这里。(short gasp) 慢慢来。")

    assert store.consume("chat-request-001") == "我在这里。 慢慢来。"
    assert store.consume("chat-request-001") is None


def test_speech_grant_strips_nested_and_malformed_acting_directions() -> None:
    store = SpeechGrantStore()

    store.issue(
        "chat-request-001",
        "先听我说（压低声音（然后加速））没事。）继续（不要播放后面的内容",
    )

    assert store.consume("chat-request-001") == "先听我说没事。继续"


def test_speech_grant_expires_without_returning_copy() -> None:
    now = [100.0]
    store = SpeechGrantStore(ttl_seconds=5, clock=lambda: now[0])
    store.issue("chat-request-001", "我在这里。")
    now[0] = 106.0

    assert store.consume("chat-request-001") is None
