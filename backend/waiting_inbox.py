"""统一「等你」里微信待回的本地确认：点「已经回了」后，同末条不再进列表。"""
from __future__ import annotations

import json
from pathlib import Path


def load_acks(path: Path) -> dict:
    try:
        return json.loads(path.read_text()) if path.exists() else {}
    except Exception:
        return {}


def save_ack(path: Path, ident: str, at) -> dict:
    ident = str(ident or "")
    if not ident.startswith("wechat:"):
        raise ValueError("只能确认微信待回")
    data = load_acks(path)
    data[ident] = float(at or 0)
    if len(data) > 200:
        data = dict(sorted(data.items(), key=lambda kv: kv[1], reverse=True)[:120])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=0))
    try:
        path.chmod(0o600)
    except OSError:
        pass
    return {"ok": True, "id": ident, "at": data[ident]}


def drop_acked(items: list, acks: dict) -> list:
    out = []
    for item in items:
        stamped = acks.get(item["id"])
        if stamped is None:
            out.append(item)
            continue
        if float(stamped) == float(item.get("at") or 0):
            continue
        out.append(item)
    return out
