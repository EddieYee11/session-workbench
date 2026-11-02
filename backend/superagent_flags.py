"""Com Super-agent 三线开关。文件不进仓库：~/.session-workbench/superagent-flags.json

router: off | on
mandate: off | shadow | on   （shadow = 跑 direct_json 只落库，不写「已备好」卡）
herdr_write: off | on
"""
from __future__ import annotations

import json
from pathlib import Path

DEFAULTS = {"router": "off", "mandate": "off", "herdr_write": "off"}
VALID = {
    "router": {"off", "on"},
    "mandate": {"off", "shadow", "on"},
    "herdr_write": {"off", "on"},
}


class SuperagentFlags:
    def __init__(self, state: Path):
        self.path = Path(state) / "superagent-flags.json"

    def load(self) -> dict:
        try:
            raw = json.loads(self.path.read_text())
        except (OSError, ValueError):
            raw = {}
        if not isinstance(raw, dict):
            raw = {}
        out = dict(DEFAULTS)
        for key, allowed in VALID.items():
            value = str(raw.get(key, DEFAULTS[key])).lower()
            out[key] = value if value in allowed else DEFAULTS[key]
        return out

    def get(self, key: str) -> str:
        return self.load()[key]

    def router_on(self) -> bool:
        return self.get("router") == "on"

    def mandate_mode(self) -> str:
        return self.get("mandate")

    def herdr_write_on(self) -> bool:
        return self.get("herdr_write") == "on"
