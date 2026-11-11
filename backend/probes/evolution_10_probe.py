"""Post-evolution 10-prompt latency retest probe (default_safe + fast_classifier_on) without touching superagent-flags.json."""
from __future__ import annotations

import asyncio
import datetime as dt
import json
import os
import sys
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

PROBE_DIR = Path(__file__).resolve().parent
BACKEND_DIR = Path(os.environ.get("COM_BACKEND_DIR") or PROBE_DIR.parent)
for p in (str(PROBE_DIR), str(BACKEND_DIR)):
    if p not in sys.path:
        sys.path.insert(0, p)

from baseline_10_probe import PROMPTS, run_single_prompt  # noqa: E402


async def run_suite(state: Path, mode_name: str, env_overrides: dict[str, str]) -> list[dict[str, Any]]:
    saved = {k: os.environ.get(k) for k in env_overrides}
    try:
        for k, v in env_overrides.items():
            if v == "":
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        print(f"=== RUNNING SUITE [{mode_name}] overrides={env_overrides} ===", flush=True)
        rows: list[dict[str, Any]] = []
        for label, category, prompt in PROMPTS:
            try:
                item = await run_single_prompt(state, label, category, prompt)
                rows.append(item)
                print(
                    f"[{mode_name}:{label}] route={item['route_level']}/{item['route_group']} "
                    f"tier={item['model_tier']} mem_chars={item.get('memory_chars', 0)} "
                    f"prebound={item.get('prebound_tools', [])} "
                    f"first_bubble={item['first_bubble_ms']}ms "
                    f"router_first={item.get('router_first_text_ms')}ms "
                    f"elapsed={item['elapsed_ms']}ms discovery={item['discovery_calls']} tools={item['tools']}",
                    flush=True,
                )
            except Exception as exc:
                err_item = {"label": label, "category": category, "prompt": prompt, "error": repr(exc)}
                rows.append(err_item)
                print(f"[{mode_name}:{label}] ERROR: {exc!r}", flush=True)
        return rows
    finally:
        for k, old in saved.items():
            if old is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = old


async def main() -> None:
    state = Path(os.environ.get("WORKBENCH_STATE") or (Path.home() / ".session-workbench"))
    modes = [m.strip() for m in os.environ.get("EVOLUTION_MODES", "default_safe,fast_classifier_on").split(",") if m.strip()]
    payload: dict[str, Any] = {
        "timestamp": dt.datetime.now(ZoneInfo("Asia/Shanghai")).isoformat(),
        "suites": {},
    }
    if "default_safe" in modes:
        payload["suites"]["default_safe"] = await run_suite(
            state,
            "default_safe",
            {
                "COM_FAST_CLASSIFIER_MODE": "",
                "COM_CHANNELS_MODE": "",
                "COM_TRIGGERS_MODE": "",
                "COM_VOICE_NARRATION_MODE": "",
            },
        )
    if "fast_classifier_on" in modes:
        fc_log = state / "fast-classifier.ndjson"
        existed_before = fc_log.exists()
        payload["suites"]["fast_classifier_on"] = await run_suite(
            state,
            "fast_classifier_on",
            {
                "COM_FAST_CLASSIFIER_MODE": "on",
                "COM_CHANNELS_MODE": "on",
            },
        )
        if fc_log.exists():
            kept_lines: list[str] = []
            probe_audits: list[dict[str, Any]] = []
            for raw_line in fc_log.read_text(encoding="utf-8").splitlines():
                if not raw_line.strip():
                    continue
                try:
                    obj = json.loads(raw_line)
                except ValueError:
                    kept_lines.append(raw_line)
                    continue
                if str(obj.get("request_id", "")).startswith("probe10-req-"):
                    probe_audits.append(obj)
                else:
                    kept_lines.append(raw_line)
            payload["fast_classifier_audit"] = probe_audits
            if kept_lines:
                fc_log.write_text("\n".join(kept_lines) + "\n", encoding="utf-8")
                os.chmod(fc_log, 0o600)
            elif not existed_before:
                fc_log.unlink(missing_ok=True)
            else:
                fc_log.write_text("", encoding="utf-8")
                os.chmod(fc_log, 0o600)
    print("=== EVOLUTION_JSON_BEGIN ===", flush=True)
    print(json.dumps(payload, ensure_ascii=False), flush=True)
    print("=== EVOLUTION_JSON_END ===", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
