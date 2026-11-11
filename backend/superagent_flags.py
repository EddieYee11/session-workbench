"""Com Super-agent 开关配置。文件不进仓库：~/.session-workbench/superagent-flags.json

router: off | on
mandate: off | shadow | on   （shadow = 跑 direct_json 只落库，不写「已备好」卡）
herdr_write: off | on
send_message: off | on       （Personal Agent SendMessage-as-tool + 中途追发事件队列，默认 off）
send_message_remind_after: int (2..12，默认 4)
fast_classifier: off | on    （回合前 <500ms 轻量 JSON 意图分类与工具预绑定，默认 off）
triggers: off | on           （Scheduled Triggers 定时/事件触发器，默认 off）
channels: off | on           （轻量话题分流 personal/work/bookkeeping，默认 off）
voice_narration: off | on    （服务端 TTS 语音播报合成，默认 off）
"""
from __future__ import annotations

import json
import os
from pathlib import Path

DEFAULTS = {
    "router": "off",
    "mandate": "off",
    "herdr_write": "off",
    "send_message": "off",
    "fast_classifier": "off",
    "triggers": "off",
    "channels": "off",
    "voice_narration": "off",
}
VALID = {
    "router": {"off", "on"},
    "mandate": {"off", "shadow", "on"},
    "herdr_write": {"off", "on"},
    "send_message": {"off", "on"},
    "fast_classifier": {"off", "on"},
    "triggers": {"off", "on"},
    "channels": {"off", "on"},
    "voice_narration": {"off", "on"},
}
DEFAULT_SEND_MESSAGE_REMIND_AFTER = 4


class SuperagentFlags:
    def __init__(self, state: Path):
        self.path = Path(state) / "superagent-flags.json"

    def _raw(self) -> dict:
        try:
            raw = json.loads(self.path.read_text())
        except (OSError, ValueError):
            raw = {}
        return raw if isinstance(raw, dict) else {}

    def load(self) -> dict:
        raw = self._raw()
        out = dict(DEFAULTS)
        for key, allowed in VALID.items():
            value = str(raw.get(key, DEFAULTS[key])).lower()
            out[key] = value if value in allowed else DEFAULTS[key]
        return out

    def get(self, key: str) -> str:
        return self.load()[key]

    def _mode_on(self, key: str, env_var: str) -> bool:
        env = os.environ.get(env_var, "").strip().lower()
        if env in VALID[key]:
            return env == "on"
        return self.get(key) == "on"

    def router_on(self) -> bool:
        return self.get("router") == "on"

    def mandate_mode(self) -> str:
        return self.get("mandate")

    def herdr_write_on(self) -> bool:
        return self.get("herdr_write") == "on"

    def send_message_on(self) -> bool:
        return self._mode_on("send_message", "COM_SENDMESSAGE_MODE")

    def fast_classifier_on(self) -> bool:
        return self._mode_on("fast_classifier", "COM_FAST_CLASSIFIER_MODE")

    def triggers_on(self) -> bool:
        return self._mode_on("triggers", "COM_TRIGGERS_MODE")

    def channels_on(self) -> bool:
        return self._mode_on("channels", "COM_CHANNELS_MODE")

    def voice_narration_on(self) -> bool:
        return self._mode_on("voice_narration", "COM_VOICE_NARRATION_MODE")

    def send_message_remind_after(self) -> int:
        env = os.environ.get("COM_SENDMESSAGE_REMIND_AFTER", "").strip()
        candidate = env if env else self._raw().get("send_message_remind_after", DEFAULT_SEND_MESSAGE_REMIND_AFTER)
        try:
            val = int(candidate)
        except (TypeError, ValueError):
            val = DEFAULT_SEND_MESSAGE_REMIND_AFTER
        return max(2, min(12, val))
