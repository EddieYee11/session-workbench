import asyncio
import subprocess

import fleet

NOW = 1_800_000_000.0


def run(coro):
    return asyncio.run(coro)


def sess(sid, status, updated, **kw):
    return {"id": sid, "agent": "pi", "cwd": "/x/proj", "display_title": sid, "updated": updated, "status": status, **kw}


def test_state_mapping():
    rows = {"sessions": [sess("a", "waiting", NOW), sess("b", "running", NOW), sess("c", "failed", NOW), sess("d", "completed", NOW), sess("e", "ended", NOW), sess("f", "ready", NOW), sess("g", "history", NOW)]}
    got = {i["session_id"]: i["state"] for i in fleet.from_sessions(rows)}
    assert got == {"a": "needs_you", "b": "running", "c": "failed", "d": "done", "e": "done", "f": "idle", "g": "idle"}
    cases = {"items": [{"id": "t1", "state": "waiting", "waiting": {"question": "删吗"}, "updated_at": NOW}, {"id": "t2", "state": "attention", "updated_at": NOW},
                       {"id": "t3", "state": "queued", "updated_at": NOW}, {"id": "t4", "state": "cancelled", "updated_at": NOW}]}
    cs = fleet.from_cases(cases)
    assert [i["state"] for i in cs] == ["needs_you", "needs_you", "running", "idle"]
    assert cs[0]["waiting_reason"] == "删吗"
    h = fleet.from_herdr({"at": NOW, "items": [{"id": "1", "status": "blocked"}, {"id": "2", "status": "working"}, {"id": "3", "status": "unknown"}]})
    assert [i["state"] for i in h] == ["needs_you", "running", "idle"]
    r = fleet.from_rex({"at": NOW, "items": [{"id": "b", "status": "running", "block_id": "block:1"}, {"id": "w", "status": "idle"}]})
    assert [i["state"] for i in r] == ["running", "idle"] and r[0]["rex"]["block_id"] == "block:1"


def test_sort_window_cap_and_dedup():
    old = NOW - 8 * 86400
    rows = {"sessions": [sess("idle1", "ready", NOW - 10), sess("run-old", "running", NOW - 100), sess("run-new", "running", NOW - 5), sess("fail", "failed", NOW - 500),
                         sess("need", "waiting", NOW - 900), sess("stale", "waiting", old), sess("dup", "running", NOW, case_id="t9")]}
    cases = {"items": [{"id": "t9", "state": "running", "updated_at": NOW - 1, "title": "航程"}]}
    out = run(fleet.build({"sessions": (lambda: rows, fleet.from_sessions), "cases": (lambda: cases, fleet.from_cases)}, now=NOW))
    ids = [i["id"] for i in out["items"]]
    assert ids == ["session:need", "session:fail", "case:t9", "session:run-new", "session:run-old", "session:idle1"]
    many = {"sessions": [sess(f"s{n}", "running", NOW - n) for n in range(60)]}
    out = run(fleet.build({"sessions": (lambda: many, fleet.from_sessions)}, now=NOW))
    assert len(out["items"]) == 40


def test_failed_source_does_not_sink_others():
    def boom():
        raise RuntimeError("db locked")

    async def async_ok():
        return {"sessions": [sess("a", "running", NOW)]}

    out = run(fleet.build({
        "sessions": (async_ok, fleet.from_sessions),
        "cases": (boom, fleet.from_cases),
        "rex": (lambda: {"ok": False, "error": "unreachable", "detail": "refused", "items": []}, fleet.from_rex),
        "herdr": (lambda: {"ok": False, "error": "server_not_running", "detail": "no herdr server", "items": []}, fleet.from_herdr),
    }, now=NOW))
    assert [i["id"] for i in out["items"]] == ["session:a"]
    by = {s["name"]: s for s in out["sources"]}
    assert by["sessions"]["ok"] is True
    assert by["cases"]["ok"] is False and "db locked" in by["cases"]["detail"]
    assert by["rex"]["ok"] is False and by["herdr"]["error"] == "server_not_running"


def git(cwd, *a):
    subprocess.run(["git", "-C", str(cwd), "-c", "user.email=t@t", "-c", "user.name=t", *a], check=True, capture_output=True)


def test_changes_real_repo(tmp_path):
    git(tmp_path, "init", "-q")
    (tmp_path / "a.txt").write_text("one\n")
    git(tmp_path, "add", ".")
    git(tmp_path, "commit", "-qm", "init")
    (tmp_path / "a.txt").write_text("one\ntwo\n")
    (tmp_path / "new.txt").write_text("x")
    out = fleet.changes(str(tmp_path))
    assert out["git"] is True and out["truncated"] is False
    assert {(f["status"], f["path"]) for f in out["files"]} == {("M", "a.txt"), ("??", "new.txt")}
    assert "a.txt" in out["stat"] and "+two" in out["diff"]
    assert (tmp_path / "a.txt").read_text() == "one\ntwo\n"


def test_changes_non_git_and_missing(tmp_path):
    assert fleet.changes(str(tmp_path))["git"] is False
    assert fleet.changes(str(tmp_path / "nope"))["git"] is False
    assert fleet.changes("")["git"] is False


def test_changes_truncates(tmp_path, monkeypatch):
    git(tmp_path, "init", "-q")
    (tmp_path / "a.txt").write_text("x\n")
    git(tmp_path, "add", ".")
    git(tmp_path, "commit", "-qm", "init")
    (tmp_path / "a.txt").write_text("x\n" + "line\n" * 500)
    monkeypatch.setattr(fleet, "DIFF_LIMIT", 300)
    out = fleet.changes(str(tmp_path))
    assert out["truncated"] is True and len(out["diff"].encode()) <= 300


def test_internal_markup_never_shows_as_title():
    from fleet import _clean_title
    assert _clean_title('<local-command-caveat>x</local-command-caveat>') == '未命名会话'
    assert _clean_title('修 bug') == '修 bug'
