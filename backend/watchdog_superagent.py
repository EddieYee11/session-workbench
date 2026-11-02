#!/usr/bin/env python3
"""Super-agent 基础设施 Watchdog：只告警；有 Pi 子进程时禁止 kickstart。

检查：personal-hub sources.attempted_at 冻结、eval/mandate 积压、任务沉默。
配置与状态：~/.session-workbench/；日志写 stderr。可挂 launchd，默认只打印。
"""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

STATE = Path(os.environ.get("SESSION_WORKBENCH_STATE", Path.home() / ".session-workbench"))
HUB = STATE / "personal-hub.sqlite"
TRIGGERS = STATE / "triggers.sqlite"
MANDATES = STATE / "mandates.sqlite"
TASKS = STATE / "tasks.sqlite"
FREEZE_S = 30 * 60
EVAL_BACKLOG = 40
TASK_SILENT_S = 45 * 60


def _pi_children_running() -> bool:
    try:
        out = subprocess.check_output(["pgrep", "-fl", "pi"], text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return False
    # 粗过滤：session-workbench / com 相关 pi worker
    return any("session-workbench" in line or "com-" in line or "pi-hermes" in line for line in out.splitlines())


def check() -> list[str]:
    alerts = []
    now = time.time()
    if HUB.exists():
        db = sqlite3.connect(HUB)
        try:
            rows = db.execute("SELECT name, data FROM sources").fetchall()
        finally:
            db.close()
        stamps = []
        for name, data in rows:
            try:
                attempted = json.loads(data).get("attempted_at") or 0
            except ValueError:
                attempted = 0
            stamps.append(attempted)
        if stamps and max(stamps) and now - max(stamps) > FREEZE_S and len({int(s) for s in stamps if s}) <= 1:
            # 全部停在同一时刻 → 典型 hub 锁卡死指纹
            if len(stamps) >= 3 and max(stamps) - min(s for s in stamps if s) < 120:
                alerts.append(f"hub_sources_frozen attempted_at={max(stamps)}")
    if TRIGGERS.exists():
        db = sqlite3.connect(TRIGGERS)
        try:
            queued = db.execute("SELECT COUNT(*) FROM triggers WHERE disposition='queued'").fetchone()[0]
        finally:
            db.close()
        if queued >= EVAL_BACKLOG:
            alerts.append(f"eval_backlog queued={queued}")
    if MANDATES.exists():
        db = sqlite3.connect(MANDATES)
        try:
            errors = db.execute(
                "SELECT COUNT(*) FROM mandates WHERE status='error' AND created_at>=?",
                (now - 86400,),
            ).fetchone()[0]
        finally:
            db.close()
        if errors >= 10:
            alerts.append(f"mandate_errors_24h={errors}")
    if TASKS.exists():
        db = sqlite3.connect(TASKS)
        try:
            # 兼容不同 schema：尽力读 status/updated
            cols = {r[1] for r in db.execute("PRAGMA table_info(tasks)").fetchall()}
            if "status" in cols and "updated_at" in cols:
                silent = db.execute(
                    "SELECT COUNT(*) FROM tasks WHERE status IN ('running','waiting','unknown') AND updated_at<?",
                    (now - TASK_SILENT_S,),
                ).fetchone()[0]
                if silent:
                    alerts.append(f"silent_tasks={silent}")
        except sqlite3.Error:
            pass
        finally:
            db.close()
    return alerts


def main():
    alerts = check()
    if not alerts:
        print("ok")
        return 0
    for a in alerts:
        print("ALERT:", a, file=sys.stderr)
    if _pi_children_running():
        print("pi_children_running: skip kickstart", file=sys.stderr)
        return 2
    if os.environ.get("WATCHDOG_ALLOW_KICKSTART") == "1":
        subprocess.run(
            ["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/work.eddie.sessions"],
            check=False,
        )
        print("kickstart_attempted", file=sys.stderr)
        return 1
    print("kickstart_disabled_set_WATCHDOG_ALLOW_KICKSTART=1", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
