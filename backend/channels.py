"""Lightweight conversation channels for Com (personal / work / bookkeeping).

Single personal assistant (Com), three focused conversation threads with
independent history windows and concise scene supplements when enabled.
When the `channels` feature flag is off, callers fall back to legacy behavior.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from superagent_flags import SuperagentFlags

DEFAULT_CHANNEL = "personal"
CHANNEL_IDS: tuple[str, ...] = ("personal", "work", "bookkeeping")


@dataclass(frozen=True)
class ChannelSpec:
    id: str
    label: str
    short_label: str
    history_rows: int
    history_bytes: int
    system_supplement: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "label": self.label,
            "short_label": self.short_label,
            "history_rows": self.history_rows,
            "history_bytes": self.history_bytes,
            "system_supplement": self.system_supplement,
        }


CHANNEL_SPECS: tuple[ChannelSpec, ...] = (
    ChannelSpec(
        id="personal",
        label="个人日常",
        short_label="个人",
        history_rows=12,
        history_bytes=18000,
        system_supplement=(
            "【当前频道：个人日常】侧重生活日程、提醒、旅行出行、健康运动与日常闲聊；"
            "语气像朋友发微信一样自然松弛，先给结论。"
        ),
    ),
    ChannelSpec(
        id="work",
        label="工作与项目",
        short_label="工作",
        history_rows=14,
        history_bytes=22000,
        system_supplement=(
            "【当前频道：工作与项目】侧重搜狐户外业务、选题排期、航程派活与项目待办推进；"
            "结论先行，注重核验依据、交付进度与下一步动作。"
        ),
    ),
    ChannelSpec(
        id="bookkeeping",
        label="记账与财务",
        short_label="记账",
        history_rows=10,
        history_bytes=14000,
        system_supplement=(
            "【当前频道：记账与财务】侧重收支分类、账单检索、订阅到期与精确金额核对；"
            "严格依据账本工具回读核实金额与类目，不猜测、不重复入账。"
        ),
    ),
)

CHANNELS: dict[str, ChannelSpec] = {spec.id: spec for spec in CHANNEL_SPECS}


def is_valid_channel(value: Any) -> bool:
    return isinstance(value, str) and value.strip().lower() in CHANNELS


def normalize_channel(value: Any) -> str:
    if isinstance(value, str):
        candidate = value.strip().lower()
        if candidate in CHANNELS:
            return candidate
    return DEFAULT_CHANNEL


def validate_channel(value: Any) -> str:
    if isinstance(value, str):
        candidate = value.strip().lower()
        if candidate in CHANNELS:
            return candidate
    allowed = ", ".join(CHANNEL_IDS)
    raise ValueError(f"无效的频道标识（仅支持 {allowed}）")


def get_channel_spec(value: Any) -> ChannelSpec:
    return CHANNELS[normalize_channel(value)]


def channels_enabled(state: Path | str) -> bool:
    flags = SuperagentFlags(Path(state))
    checker = getattr(flags, "channels_on", None)
    if callable(checker):
        return bool(checker())
    env = os.environ.get("COM_CHANNELS_MODE", "").strip().lower()
    if env in ("on", "off"):
        return env == "on"
    raw = getattr(flags, "_raw", lambda: {})()
    return str(raw.get("channels", "off")).strip().lower() == "on"
