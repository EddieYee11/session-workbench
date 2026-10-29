"""微信「已经回了」：同 id+at 从等你列表拿掉；新 at 再出现。"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from waiting_inbox import drop_acked, save_ack


def test_drop_acked_hides_same_stamp_and_returns_on_new_at(tmp_path):
    ack = tmp_path / "waiting-ack.json"
    items = [
        {"id": "wechat:小张", "kind": "wechat", "at": 100.0, "title": "小张"},
        {"id": "case:1", "kind": "case", "at": 50.0, "title": "航程"},
    ]
    assert [i["id"] for i in drop_acked(items, {})] == ["wechat:小张", "case:1"]

    saved = save_ack(ack, "wechat:小张", 100)
    assert saved["ok"] and saved["at"] == 100.0
    assert json.loads(ack.read_text())["wechat:小张"] == 100.0
    assert [i["id"] for i in drop_acked(items, json.loads(ack.read_text()))] == ["case:1"]

    items[0]["at"] = 200.0  # 对方又发了一条
    assert [i["id"] for i in drop_acked(items, json.loads(ack.read_text()))] == ["wechat:小张", "case:1"]


def test_waiting_ack_rejects_non_wechat(tmp_path):
    try:
        save_ack(tmp_path / "waiting-ack.json", "case:1", 1)
        assert False, "expected ValueError"
    except ValueError as e:
        assert "微信" in str(e)
