import json
from pathlib import Path

from artifacts import ArtifactAccess
from reply_widgets import split_widgets, strip_partial_widget


class NoTasks:
    def list(self):
        return []


def fence(value):
    return "```com-widget\n" + json.dumps(value, ensure_ascii=False) + "\n```"


def test_fence_is_removed_from_text_and_returned():
    body, widgets = split_widgets("结论。\n" + fence({"type": "choices", "options": ["A", "B"]}) + "\n后面")
    assert "com-widget" not in body and "结论" in body and "后面" in body
    assert widgets == [{"type": "choices", "options": ["A", "B"]}]


def test_broken_or_unknown_widget_never_leaks_raw_json():
    body, widgets = split_widgets("结论\n```com-widget\n{oops\n```")
    assert widgets == [] and "oops" not in body
    body, widgets = split_widgets(fence({"type": "virus", "items": [1]}))
    assert widgets == [] and "virus" not in body


def test_html_widget_size_limit():
    assert split_widgets(fence({"type": "html", "html": "<b>x</b>"}))[1]
    assert not split_widgets(fence({"type": "html", "html": "x" * (64 * 1024 + 1)}))[1]


def test_markdown_table_becomes_table_only_when_long_enough():
    long = "前面\n| 项目 | 金额 |\n| --- | --- |\n| 房租 | 3000 |\n| 水电 | 200 |\n| **吃饭** | 900 |\n后面"
    body, widgets = split_widgets(long)
    assert widgets[0]["columns"] == ["项目", "金额"] and widgets[0]["rows"][2] == ["吃饭", "900"]
    assert "房租" not in body and "前面" in body and "后面" in body
    short = "| 项目 | 金额 |\n| --- | --- |\n| 房租 | 3000 |"
    assert split_widgets(short) == (short, [])


def test_task_list_becomes_checklist():
    body, widgets = split_widgets("要带：\n- [ ] 证件\n- [x] 充电器\n结束")
    assert [i["checked"] for i in widgets[0]["items"]] == [False, True]
    assert "证件" not in body and "结束" in body
    single = "- [ ] 只有一条"
    assert split_widgets(single) == (single, [])


def test_plain_text_is_untouched():
    text = "  普通回复 a|b 不是表格\n"
    assert split_widgets(text) == (text, [])


def test_streaming_hides_unfinished_block():
    assert strip_partial_widget('结论\n```com-widget\n{"type":"cho') == "结论"
    assert strip_partial_widget("结论") == "结论"


def access(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    work = tmp_path / "AI_Work_System"
    (work / "work/航程产出").mkdir(parents=True)
    return ArtifactAccess(NoTasks(), work, tmp_path), work


def test_bare_name_resolves_in_outputs_folder(tmp_path, monkeypatch):
    art, work = access(tmp_path, monkeypatch)
    (work / "work/航程产出/2026-10-19-日程.html").write_text("x")
    linked = art.link_text("m1", "放好了：2026-10-19-日程.html，去看看。还有 不存在.html")
    assert [a["name"] for a in linked] == ["2026-10-19-日程.html"]


def test_documents_path_links_but_other_home_paths_do_not(tmp_path, monkeypatch):
    art, work = access(tmp_path, monkeypatch)
    (tmp_path / "Documents/yt").mkdir(parents=True)
    (tmp_path / "Documents/yt/report.html").write_text("x")
    (tmp_path / "Library").mkdir()
    (tmp_path / "Library/secret.html").write_text("x")
    linked = art.link_text("m1", "看 ~/Documents/yt/report.html 和 ~/Library/secret.html")
    assert [a["name"] for a in linked] == ["report.html"]


def test_turn_files_only_link_what_this_turn_wrote(tmp_path, monkeypatch):
    import os, time
    art, work = access(tmp_path, monkeypatch)
    old = work / "work/航程产出/old.html"
    old.write_text("x")
    os.utime(old, (1000, 1000))
    new = work / "work/航程产出/new.html"
    new.write_text("x")
    linked = art.link_turn_files("m1", time.time() - 60, [])
    assert [a["name"] for a in linked] == ["new.html"]


def test_receipts_group_by_message_and_skip_work_tools(tmp_path):
    import sqlite3
    from activity import Activity
    path = tmp_path / "effects.sqlite"
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE effects(key TEXT PRIMARY KEY,call_id TEXT,state TEXT NOT NULL,data TEXT NOT NULL)")
        rows = [("a", "done", {"origin_message_id": "m1", "tool": "bookkeeping", "summary": "记账 ¥38"}),
                ("b", "uncertain", {"origin_message_id": "m1", "tool": "calendar_event", "summary": "日程新建"}),
                ("c", "done", {"origin_message_id": "m1", "tool": "bash", "summary": "运行命令"}),
                ("d", "done", {"origin_message_id": "", "tool": "remind", "summary": "没有来源"}),
                ("e", "done", {"origin_message_id": "m2", "tool": "remind"})]
        for key, state, data in rows:
            db.execute("INSERT INTO effects VALUES(?,?,?,?)", (key, "", state, json.dumps(data)))
    got = Activity(path, None, None).receipts_by_message()
    assert [(r["summary"], r["state"], r["type"]) for r in got["m1"]] == [("记账 ¥38", "done", "ledger"), ("日程新建", "uncertain", "schedule")]
    assert set(got) == {"m1"}
