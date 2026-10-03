"""Pi 能力清单：只读 settings.json 登记的条目，不被目录里的备份文件污染。"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import capabilities


def _fixture(tmp_path):
    skills = tmp_path / "skills"
    collect = skills / "collect"
    collect.mkdir(parents=True)
    (collect / "SKILL.md").write_text(
        "---\nname: collect\ndescription: >\n  收藏链接到 Obsidian 收藏库。\n"
        "  触发词：收藏、存一下。\nmetadata:\n  version: 3.0.0\n---\n\n正文\n",
        encoding="utf-8",
    )
    extensions = tmp_path / "extensions"
    extensions.mkdir()
    (extensions / "bookkeeping.ts").write_text(
        'export default function (pi) {\n pi.registerTool({\n name: "bookkeeping",\n'
        ' label: "记账",\n promptSnippet: "记账：add 记一笔 / delete 删一笔",\n'
        " parameters: Type.Object({}),\n })\n}\n",
        encoding="utf-8",
    )
    # 基础设施扩展（HIDE）与目录里的备份文件都不该进清单
    (extensions / "bash-guard.ts").write_text(
        'pi.registerTool({name: "bash_guard", label: "守卫", promptSnippet: "内部"})\n',
        encoding="utf-8",
    )
    (extensions / "stale.ts.bak-20260101-120000").write_text(
        'pi.registerTool({name: "ghost", label: "幽灵", promptSnippet: "不该出现"})\n',
        encoding="utf-8",
    )
    settings = tmp_path / "settings.json"
    settings.write_text(json.dumps({
        "skills": [str(skills)],
        # 只登记两个 .ts；备份文件没登记，即使同目录也不该被读
        "extensions": [str(extensions / "bookkeeping.ts"), str(extensions / "bash-guard.ts")],
    }), encoding="utf-8")
    return settings


def test_manifest_reads_only_registered_entries(tmp_path, monkeypatch):
    monkeypatch.setattr(capabilities, "PI_SETTINGS", _fixture(tmp_path))
    items = {i["id"]: i for i in capabilities.manifest()}
    assert set(items) == {"bookkeeping", "collect"}
    assert items["bookkeeping"]["label"] == "记账"
    assert items["bookkeeping"]["kind"] == "extension"
    assert items["collect"]["kind"] == "skill"


def test_yaml_folded_description_is_flattened(tmp_path, monkeypatch):
    monkeypatch.setattr(capabilities, "PI_SETTINGS", _fixture(tmp_path))
    text = next(i["text"] for i in capabilities.manifest() if i["id"] == "collect")
    assert text.startswith("收藏链接到 Obsidian 收藏库。")
    assert "触发词：收藏、存一下。" in text
    assert "version" not in text


def test_render_lists_pi_capabilities_and_hides_infrastructure(tmp_path, monkeypatch):
    monkeypatch.setattr(capabilities, "PI_SETTINGS", _fixture(tmp_path))
    text = capabilities.render()
    assert "记账" in text and "bookkeeping" in text and "收藏链接" in text
    assert "幽灵" not in text and "守卫" not in text
    assert "Codex" in text


def test_missing_settings_renders_nothing(tmp_path, monkeypatch):
    monkeypatch.setattr(capabilities, "PI_SETTINGS", tmp_path / "absent.json")
    assert capabilities.manifest() == [] and capabilities.render() == ""


def test_search_is_read_only_and_missing_metadata_is_honest(tmp_path,monkeypatch):
    import sqlite3
    monkeypatch.setattr(capabilities,'PI_SETTINGS',tmp_path/'absent.json')
    registry=capabilities.CapabilityRegistry(tmp_path,host='fixture')
    before=registry.path.read_bytes()
    found=registry.search('runtime:pi')
    assert registry.path.read_bytes()==before
    assert found[0]['state']=='discovered'
    assert found[0]['last_verified_at'] is None
    assert found[0]['description'] is None
    assert found[0]['provider']=='pi'
