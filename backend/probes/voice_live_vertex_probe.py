from __future__ import annotations

import asyncio
import base64
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from websockets.asyncio.client import connect  # noqa: E402
from voice_live import GOOGLE_PROXY, fetch_gcp_token  # noqa: E402

PRIMARY_ACC = os.environ.get("ASR_GCP_PRIMARY_ACCOUNT", "eddiegao948@gmail.com")
PRIMARY_PROJ = os.environ.get("ASR_GCP_PRIMARY_PROJECT", "project-816c0481-813e-4353-ab7")
SECONDARY_ACC = os.environ.get("ASR_GCP_SECONDARY_ACCOUNT", "a123456z789z@gmail.com")
SECONDARY_PROJ = os.environ.get("ASR_GCP_SECONDARY_PROJECT", "gen-lang-client-0792759409")

PROBE_TARGETS = (
    {"account": PRIMARY_ACC, "project": PRIMARY_PROJ, "location": "us-central1", "model": "gemini-3.8-live"},
    {"account": SECONDARY_ACC, "project": SECONDARY_PROJ, "location": "us-central1", "model": "gemini-3.8-live"},
    {"account": PRIMARY_ACC, "project": PRIMARY_PROJ, "location": "us-central1", "model": "gemini-live-2.5-flash-native-audio"},
    {"account": SECONDARY_ACC, "project": SECONDARY_PROJ, "location": "us-central1", "model": "gemini-live-2.5-flash-native-audio"},
    {"account": PRIMARY_ACC, "project": PRIMARY_PROJ, "location": "global", "model": "gemini-live-2.5-flash"},
    {"account": SECONDARY_ACC, "project": SECONDARY_PROJ, "location": "global", "model": "gemini-live-2.5-flash"},
)


def build_setup(
    target: dict[str, Any],
    *,
    affective: bool,
    proactive: bool,
    resumption: bool = True,
    compression: bool = True,
) -> dict[str, Any]:
    loc = target["location"]
    gen_cfg: dict[str, Any] = {
        "responseModalities": ["AUDIO"],
        "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": "Aoede"}}},
    }
    if affective:
        gen_cfg["enableAffectiveDialog"] = True

    setup_inner: dict[str, Any] = {
        "model": f"projects/{target['project']}/locations/{loc}/publishers/google/models/{target['model']}",
        "systemInstruction": {"parts": [{"text": "你是Com，简短口语回答，不超过五个字。"}]},
        "generationConfig": gen_cfg,
        "realtimeInputConfig": {
            "automaticActivityDetection": {
                "disabled": False,
                "silenceDurationMs": 650,
                "prefixPaddingMs": 150,
            }
        },
        "inputAudioTranscription": {},
        "outputAudioTranscription": {},
    }
    if proactive:
        setup_inner["proactivity"] = {"proactiveAudio": True}
    if resumption:
        setup_inner["sessionResumption"] = {}
    if compression:
        setup_inner["contextWindowCompression"] = {"slidingWindow": {}}
    return {"setup": setup_inner}


async def try_connect_and_turn(
    target: dict[str, Any],
    tok: str,
    *,
    affective: bool,
    proactive: bool,
) -> dict[str, Any]:
    loc = target["location"]
    host = f"{loc}-aiplatform.googleapis.com" if loc != "global" else "aiplatform.googleapis.com"
    uri = f"wss://{host}/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent"
    setup = build_setup(target, affective=affective, proactive=proactive)
    try:
        ws = await connect(
            uri,
            additional_headers={"Authorization": f"Bearer {tok}"},
            proxy=GOOGLE_PROXY if GOOGLE_PROXY else None,
            max_size=16 * 1024 * 1024,
            open_timeout=6,
        )
    except Exception as exc:
        return {"ok": False, "stage": "ws_connect", "error": f"{type(exc).__name__}: {exc}"}

    try:
        await ws.send(json.dumps(setup, ensure_ascii=False))
        raw = await asyncio.wait_for(ws.recv(), timeout=6)
        ack = json.loads(raw.decode("utf-8") if isinstance(raw, bytes) else raw)
        if "setupComplete" not in ack:
            await ws.close()
            return {"ok": False, "stage": "setup_ack", "error": f"non-setupComplete: {ack}"}

        t0 = time.perf_counter()
        turn_msg = {
            "clientContent": {
                "turns": [{"role": "user", "parts": [{"text": "嗨，听得到吗？"}]}],
                "turnComplete": True,
            }
        }
        await ws.send(json.dumps(turn_msg, ensure_ascii=False))

        first_audio_ms: float | None = None
        got_resumption = False
        audio_bytes = 0
        while True:
            raw_ev = await asyncio.wait_for(ws.recv(), timeout=8)
            ev = json.loads(raw_ev.decode("utf-8") if isinstance(raw_ev, bytes) else raw_ev)
            if "sessionResumptionUpdate" in ev:
                got_resumption = True
            sc = ev.get("serverContent") or {}
            mt = sc.get("modelTurn") or {}
            for part in mt.get("parts") or []:
                inline = part.get("inlineData") if isinstance(part, dict) else None
                if isinstance(inline, dict) and inline.get("data"):
                    chunk = base64.b64decode(inline["data"])
                    if chunk:
                        audio_bytes += len(chunk)
                        if first_audio_ms is None:
                            first_audio_ms = round((time.perf_counter() - t0) * 1000, 1)
            if first_audio_ms is not None or sc.get("turnComplete"):
                break
        await ws.close()
        return {
            "ok": True,
            "first_audio_ms": first_audio_ms,
            "audio_bytes": audio_bytes,
            "resumption_update": got_resumption,
        }
    except Exception as exc:
        try:
            await ws.close()
        except Exception:
            pass
        return {"ok": False, "stage": "setup_or_turn", "error": f"{type(exc).__name__}: {exc}"}


async def probe_target(idx: int, target: dict[str, Any]) -> None:
    label = f"[{idx}] {target['account']} | {target['project']} | {target['location']} | {target['model']}"
    tok = await asyncio.to_thread(fetch_gcp_token, target["account"], False)
    if not tok:
        print(f"{label} -> TOKEN_FAILED", flush=True)
        return

    res_full = await try_connect_and_turn(target, tok, affective=True, proactive=True)
    if res_full["ok"]:
        print(
            f"{label} -> setupComplete=True | rejected=none | affective=True proactive=True | "
            f"first_audio_ms={res_full['first_audio_ms']}ms | resumption_update={res_full['resumption_update']}",
            flush=True,
        )
        return

    res_base = await try_connect_and_turn(target, tok, affective=False, proactive=False)
    if not res_base["ok"]:
        print(
            f"{label} -> setupComplete=False | rejected=all | error={res_base.get('error', '')}",
            flush=True,
        )
        return

    res_aff, res_pro = await asyncio.gather(
        try_connect_and_turn(target, tok, affective=True, proactive=False),
        try_connect_and_turn(target, tok, affective=False, proactive=True),
    )
    rejected: list[str] = []
    if not res_aff["ok"]:
        rejected.append("enableAffectiveDialog")
    if not res_pro["ok"]:
        rejected.append("proactivity")
    if not rejected:
        rejected.append("enableAffectiveDialog+proactivity_combo")

    best_ms = (
        res_aff["first_audio_ms"]
        if res_aff["ok"]
        else (res_pro["first_audio_ms"] if res_pro["ok"] else res_base["first_audio_ms"])
    )
    print(
        f"{label} -> setupComplete=True (fallback) | rejected={rejected} | "
        f"affective={res_aff['ok']} proactive={res_pro['ok']} | "
        f"first_audio_ms={best_ms}ms | full_err={res_full.get('error', '')}",
        flush=True,
    )


async def main() -> None:
    for idx, t in enumerate(PROBE_TARGETS, 1):
        await probe_target(idx, t)


if __name__ == "__main__":
    asyncio.run(main())
