from __future__ import annotations

import asyncio
import json
import sqlite3
import stat
import sys
import time
from pathlib import Path
from unittest.mock import AsyncMock

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from context_working_set import MARKER
from fast_classifier import (
    CONFIDENCE_THRESHOLD,
    FastClassification,
    classify_fast,
)
from hermes_runtime import HermesRuntime
from message_router import MessageRouter
from superagent_flags import DEFAULTS, VALID, SuperagentFlags


def test_superagent_flags_backward_compatible_and_env_overrides(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    assert DEFAULTS == {
        "router": "off",
        "mandate": "off",
        "herdr_write": "off",
        "send_message": "off",
        "fast_classifier": "off",
        "triggers": "off",
        "channels": "off",
        "voice_narration": "off",
    }
    for key in ("fast_classifier", "triggers", "channels", "voice_narration"):
        assert VALID[key] == {"off", "on"}

    for env_key in (
        "COM_FAST_CLASSIFIER_MODE",
        "COM_TRIGGERS_MODE",
        "COM_CHANNELS_MODE",
        "COM_VOICE_NARRATION_MODE",
    ):
        monkeypatch.delenv(env_key, raising=False)

    flags = SuperagentFlags(tmp_path)
    assert flags.fast_classifier_on() is False
    assert flags.triggers_on() is False
    assert flags.channels_on() is False
    assert flags.voice_narration_on() is False

    (tmp_path / "superagent-flags.json").write_text(
        json.dumps({"fast_classifier": "on", "triggers": "invalid", "channels": "on", "voice_narration": "on"}),
        encoding="utf-8",
    )
    assert flags.fast_classifier_on() is True
    assert flags.triggers_on() is False
    assert flags.channels_on() is True
    assert flags.voice_narration_on() is True

    monkeypatch.setenv("COM_FAST_CLASSIFIER_MODE", "off")
    monkeypatch.setenv("COM_TRIGGERS_MODE", "on")
    monkeypatch.setenv("COM_CHANNELS_MODE", "off")
    monkeypatch.setenv("COM_VOICE_NARRATION_MODE", "off")
    assert flags.fast_classifier_on() is False
    assert flags.triggers_on() is True
    assert flags.channels_on() is False
    assert flags.voice_narration_on() is False


def test_classify_fast_accepts_valid_high_confidence_and_writes_0600_ndjson(tmp_path: Path) -> None:
    async def fake_caller(text: str, timeout_s: float) -> str:
        assert "攀岩" in text
        assert timeout_s <= 0.48
        return '```json\n{"intent": "query", "confidence": 0.88, "tools": ["memory_recall", "unknown_tool", "context_read"], "level": "L2"}\n```'

    res = asyncio.run(classify_fast(tmp_path, "req-ok-1", "帮我查一下攀岩记忆", caller=fake_caller))
    assert isinstance(res, FastClassification)
    assert res.accepted is True
    assert res.fallback == ""
    assert res.intent == "query"
    assert res.confidence == pytest.approx(0.88)
    assert res.tools == ["memory_recall", "context_read"]
    assert res.level == "L2"
    assert res.elapsed_ms < 500.0

    log_file = tmp_path / "fast-classifier.ndjson"
    assert log_file.exists()
    assert stat.S_IMODE(log_file.stat().st_mode) == 0o600
    rows = [json.loads(line) for line in log_file.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert len(rows) == 1
    row = rows[0]
    for required_key in ("at", "request_id", "elapsed_ms", "intent", "confidence", "tools", "accepted", "fallback"):
        assert required_key in row
    assert row["request_id"] == "req-ok-1"
    assert row["accepted"] is True
    assert row["fallback"] == ""
    assert row["tools"] == ["memory_recall", "context_read"]


def test_classify_fast_bookkeeping_and_chat_normalization(tmp_path: Path) -> None:
    async def book_caller(_text: str, _timeout: float) -> dict:
        return {"intent": "bookkeeping", "confidence": CONFIDENCE_THRESHOLD, "tools": [], "level": "L1"}

    async def chat_caller(_text: str, _timeout: float) -> dict:
        return {"intent": "chat", "confidence": 0.95, "tools": ["memory_recall"], "level": "L1"}

    book_res = asyncio.run(classify_fast(tmp_path, "req-book", "这个月花了多少", caller=book_caller))
    assert book_res.accepted is True
    assert book_res.tools == ["business_operation"]

    chat_res = asyncio.run(classify_fast(tmp_path, "req-chat", "今天有点累陪我聊两句", caller=chat_caller))
    assert chat_res.accepted is True
    assert chat_res.tools == []


def test_classify_fast_low_confidence_timeout_and_invalid_json_fallbacks(tmp_path: Path) -> None:
    async def low_conf(_text: str, _timeout: float) -> str:
        return '{"intent":"action","confidence":0.59,"tools":["trigger_manage"],"level":"L2"}'

    async def slow_caller(_text: str, _timeout: float) -> str:
        await asyncio.sleep(2.0)
        return '{"intent":"chat","confidence":0.99,"tools":[],"level":"L1"}'

    async def broken_json(_text: str, _timeout: float) -> str:
        return "抱歉，这不是 JSON 输出"

    async def bad_schema(_text: str, _timeout: float) -> str:
        return '{"intent":"unknown_intent","confidence":true,"tools":"not_a_list","level":"L9"}'

    r_low = asyncio.run(classify_fast(tmp_path, "r-low", "随便看看", caller=low_conf))
    assert r_low.accepted is False and r_low.fallback == "low_confidence"
    assert r_low.intent == "action" and r_low.confidence == pytest.approx(0.59)

    started = time.monotonic()
    r_timeout = asyncio.run(classify_fast(tmp_path, "r-timeout", "测试超时", timeout_s=0.08, caller=slow_caller))
    wall_ms = (time.monotonic() - started) * 1000
    assert wall_ms < 450.0
    assert r_timeout.accepted is False and r_timeout.fallback == "timeout"

    r_bad_json = asyncio.run(classify_fast(tmp_path, "r-bad-json", "测试坏JSON", caller=broken_json))
    assert r_bad_json.accepted is False and r_bad_json.fallback == "invalid_json"

    r_bad_schema = asyncio.run(classify_fast(tmp_path, "r-bad-schema", "测试坏结构", caller=bad_schema))
    assert r_bad_schema.accepted is False and r_bad_schema.fallback == "invalid_schema"

    rows = [
        json.loads(line)
        for line in (tmp_path / "fast-classifier.ndjson").read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    assert [r["request_id"] for r in rows] == ["r-low", "r-timeout", "r-bad-json", "r-bad-schema"]
    assert all(r["accepted"] is False for r in rows)


def test_classify_fast_http_transport_success_and_error_fallbacks(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    models_json = tmp_path / "models.json"
    models_json.write_text(
        json.dumps({"providers": {"magpie": {"baseUrl": "http://127.0.0.1:3425/v1", "apiKey": "test-local-token"}}}),
        encoding="utf-8",
    )
    monkeypatch.delenv("COM_FAST_CLASSIFIER_MODEL", raising=False)
    monkeypatch.delenv("COM_FAST_CLASSIFIER_BASE_URL", raising=False)

    captured_bodies: list[dict] = []

    def ok_handler(request: httpx.Request) -> httpx.Response:
        assert str(request.url) == "http://127.0.0.1:3425/v1/chat/completions"
        body = json.loads(request.content.decode("utf-8"))
        captured_bodies.append(body)
        content = json.dumps(
            {"intent": "action", "confidence": 0.91, "tools": ["trigger_manage"], "level": "L2"},
            ensure_ascii=False,
        )
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})

    ok_res = asyncio.run(
        classify_fast(
            tmp_path,
            "r-http-ok",
            "每天早上8点给我发早安简报",
            transport=httpx.MockTransport(ok_handler),
            models_path=models_json,
        )
    )
    assert ok_res.accepted is True
    assert ok_res.tools == ["trigger_manage"]
    assert captured_bodies[0]["thinking"] == {"type": "disabled"}
    assert captured_bodies[0]["response_format"] == {"type": "json_object"}

    def err_502(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(502, text="bad gateway")

    err_res = asyncio.run(
        classify_fast(
            tmp_path,
            "r-http-502",
            "每天早上8点给我发早安简报",
            transport=httpx.MockTransport(err_502),
            models_path=models_json,
        )
    )
    assert err_res.accepted is False
    assert err_res.fallback == "http_502"


def test_message_router_decide_async_l0_bypass_upgrade_and_fallback(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("COM_FAST_CLASSIFIER_MODE", "on")
    router = MessageRouter(tmp_path)
    calls: list[str] = []

    async def spy_caller(text: str, _timeout: float) -> dict:
        calls.append(text)
        return {"intent": "action", "confidence": 0.85, "tools": ["trigger_manage"], "level": "L2"}

    # 确定性 L0 直接毫秒级返回，绝不调 fast_classifier
    l0 = asyncio.run(router.decide_async("req-l0", "查最近账单", caller=spy_caller))
    assert l0.level == "L0" and l0.tool == "bookkeeping"
    assert calls == []

    # 模拟 conversation.py 先同步调 decide()，随后 HermesRuntime.stream_chat 调 decide_async()
    sync_route = router.decide("req-upgrade", "每天早上八点半给我发日程简报")
    assert sync_route.prebound_tools is None
    upgraded = asyncio.run(router.decide_async("req-upgrade", "每天早上八点半给我发日程简报", caller=spy_caller))
    assert len(calls) == 1
    assert upgraded.level == "L2"
    assert upgraded.prebound_tools == ["trigger_manage"]

    # 同一 request_id 幂等复用，不重复调用模型
    again = asyncio.run(router.decide_async("req-upgrade", "每天早上八点半给我发日程简报", caller=spy_caller))
    assert len(calls) == 1
    assert again == upgraded

    # 超时或低置信度无感回退到原有 MessageRouter.decide() 结果
    async def low_caller(_text: str, _timeout: float) -> dict:
        return {"intent": "chat", "confidence": 0.3, "tools": [], "level": "L1"}

    fallback_route = asyncio.run(router.decide_async("req-fallback", "提醒我下午三点交周报", caller=low_caller))
    assert fallback_route.level == "L1"
    assert fallback_route.group == "reminder"
    assert fallback_route.prebound_tools is None


def test_hermes_runtime_uses_fast_classifier_when_flag_enabled(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("COM_FAST_CLASSIFIER_MODE", "on")

    def handler(request: httpx.Request) -> httpx.Response:
        if str(request.url).endswith("/chat/completions"):
            return httpx.Response(
                200,
                json={
                    "choices": [
                        {
                            "message": {
                                "content": json.dumps(
                                    {
                                        "intent": "action",
                                        "confidence": 0.92,
                                        "tools": ["trigger_manage"],
                                        "level": "L2",
                                    }
                                )
                            }
                        }
                    ]
                },
            )
        return httpx.Response(200, json={"run_id": "run_fc_test"})

    real_async_client = httpx.AsyncClient
    monkeypatch.setattr(
        httpx,
        "AsyncClient",
        lambda **kwargs: real_async_client(
            **{**kwargs, "transport": httpx.MockTransport(handler)}
        ),
    )

    async def scenario() -> None:
        client = HermesRuntime(tmp_path)
        client.create_session = AsyncMock()
        client.key = lambda: "fixture"
        client.request = AsyncMock(return_value={"status": "completed", "output": "已创建触发器"})

        async def events(_run_id: str):
            yield "run.completed", {"status": "completed", "output": "已创建触发器"}

        client._events = events
        wrapped = (
            MARKER
            + json.dumps({"origin_request_id": "req-fc-rt", "origin_message_id": "m-fc-rt"})
            + "\n用户消息：\n每天早上 8 点推早安简报"
        )
        out = [ev async for ev in client.stream_chat("main", wrapped)]
        assert out

    asyncio.run(scenario())
    with sqlite3.connect(tmp_path / "hermes-runs.sqlite") as db:
        metrics = json.loads(
            db.execute("SELECT data FROM context_metrics WHERE request_id=?", ("req-fc-rt",)).fetchone()[0]
        )
    assert metrics["prebound_tools"] == ["trigger_manage"]
    assert (tmp_path / "fast-classifier.ndjson").exists()


def test_fast_classifier_and_direct_tools_have_zero_banned_model_references() -> None:
    backend_dir = Path(__file__).resolve().parents[1]
    banned = "clau" + "de"
    for rel in ("fast_classifier.py", "direct_tools.py"):
        src = (backend_dir / rel).read_text(encoding="utf-8").lower()
        assert banned not in src, f"Forbidden model reference found in {rel}"
