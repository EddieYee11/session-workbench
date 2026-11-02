"""Router batch v1：窄规则命中后拆并行 Worker；服务端建 batch，跳过 Hermes 自由回合。

命中条件（其一）：含「分别」；或明确写出 ≥2 个不同 agent 名。
不认「和/并且」。Magpie 仅在规则命中后调用。
"""
from __future__ import annotations

import hashlib
import json
import re
import time
from pathlib import Path

from hermes_review import direct_json
from operation_policy import POLICY_REVISION, effective_sandbox
from superagent_flags import SuperagentFlags

AGENTS = ("pi", "claude", "codex", "hermes")
AGENT_RE = re.compile(r"\b(pi|claude|codex|hermes)\b", re.I)
SPLIT_RE = re.compile(r"分别")
DELETE_RE = re.compile(r"永久删除|清空|销毁|抹掉|删除|删掉")
BATCH_DEADLINE_S = 8 * 60
BATCH_PARALLEL = 3

SPLIT_INSTRUCTIONS = """把用户一句话拆成可并行的独立子任务。data.text 是用户原文。
每个 worker 指定 agent（pi|claude|codex|hermes）、title（≤12 汉字）、prompt（完整说明）、relative_cwd（相对工作区，默认 "."）。
不同 agent 尽量给不同 relative_cwd，避免同目录串行。不要 depends_on。
只输出 JSON：{"workers":[{"agent":"pi","title":"","prompt":"","relative_cwd":"."}]}
至少 2 个 worker；拆不出就 {"workers":[]}。"""


def rule_hit(text: str) -> bool:
    text = text or ""
    if SPLIT_RE.search(text):
        return True
    names = {m.group(1).lower() for m in AGENT_RE.finditer(text)}
    return len(names) >= 2


def has_deletion(text: str) -> bool:
    return bool(DELETE_RE.search(text or ""))


class RouterPlan:
    def __init__(self, state, store, conversation, flags=None, workspace=None, judge=None, clock=time.time):
        self.state = Path(state)
        self.store = store
        self.conversation = conversation
        self.flags = flags or SuperagentFlags(state)
        self.workspace = Path(workspace or Path.home() / "AI_Work_System")
        self.judge = judge
        self.clock = clock
        self.path = self.state / "batches.sqlite"
        self._ensure()

    def _ensure(self):
        import sqlite3
        self.state.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.path)
        try:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS batches(
                    id TEXT PRIMARY KEY,
                    origin_message_id TEXT NOT NULL,
                    origin_request_id TEXT NOT NULL,
                    status TEXT NOT NULL,
                    task_ids TEXT NOT NULL,
                    ack TEXT NOT NULL DEFAULT '',
                    folded INTEGER NOT NULL DEFAULT 0,
                    deadline_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    result TEXT NOT NULL DEFAULT ''
                );
                """
            )
            db.commit()
        finally:
            db.close()
        self.path.chmod(0o600)

    def maybe_dispatch(self, row) -> dict | None:
        """若命中并成功建 batch，返回 {batch_id, ack, task_ids}；否则 None（走 Hermes）。"""
        if not self.flags.router_on():
            return None
        text = row.get("text") or ""
        if not rule_hit(text) or has_deletion(text):
            return None
        workers = self._plan_workers(text)
        if len(workers) < 2:
            return None
        return self._create_batch(row, workers)

    def _plan_workers(self, text: str):
        # 快路径：文中点名了 ≥2 agent 时按出现顺序各建一个壳，再交给 Magpie 填细节；失败则用规则壳
        named = []
        for m in AGENT_RE.finditer(text):
            agent = m.group(1).lower()
            if agent not in named:
                named.append(agent)
        planned = None
        if self.judge:
            try:
                import asyncio
                result = self.judge({"text": text})
                if asyncio.iscoroutine(result):
                    # sync helper path expects sync judge in tests; app uses async wrapper
                    planned = None
                else:
                    planned = result
            except Exception:
                planned = None
        workers = []
        if isinstance(planned, dict):
            for item in planned.get("workers") or []:
                agent = str(item.get("agent") or "pi").lower()
                if agent not in AGENTS:
                    continue
                title = str(item.get("title") or agent)[:40]
                prompt = str(item.get("prompt") or text)[:4000]
                cwd = str(item.get("relative_cwd") or ".")
                workers.append({"agent": agent, "title": title, "prompt": prompt, "relative_cwd": cwd})
        if len(workers) < 2 and len(named) >= 2:
            for i, agent in enumerate(named[:BATCH_PARALLEL]):
                workers.append({
                    "agent": agent,
                    "title": f"{agent}子任务",
                    "prompt": f"用户要求分别处理。本子任务由 {agent} 负责。用户原文：\n{text}\n\n请只做与你相关的那部分，只读优先，完成后简述结果。",
                    "relative_cwd": f".batch/{agent}-{i}",
                })
        elif len(workers) < 2 and SPLIT_RE.search(text):
            # 「分别」但未点名：默认 pi + hermes 异目录
            workers = [
                {"agent": "pi", "title": "分别-甲", "prompt": f"用户要求分别处理（第一部分）。原文：\n{text}", "relative_cwd": ".batch/part-a"},
                {"agent": "hermes", "title": "分别-乙", "prompt": f"用户要求分别处理（第二部分）。原文：\n{text}", "relative_cwd": ".batch/part-b"},
            ]
        # 去重 agent+cwd，至少 2
        seen = set()
        out = []
        for w in workers:
            key = (w["agent"], w["relative_cwd"])
            if key in seen:
                continue
            seen.add(key)
            out.append(w)
        return out[:BATCH_PARALLEL]

    async def plan_workers_async(self, text: str):
        if not rule_hit(text):
            return []
        planned = None
        try:
            planned = await direct_json(SPLIT_INSTRUCTIONS, {"text": text}, 45)
        except Exception:
            planned = None
        # temporarily stash judge result via sync path shape
        workers = []
        if isinstance(planned, dict):
            for item in planned.get("workers") or []:
                agent = str(item.get("agent") or "pi").lower()
                if agent not in AGENTS:
                    continue
                workers.append({
                    "agent": agent,
                    "title": str(item.get("title") or agent)[:40],
                    "prompt": str(item.get("prompt") or text)[:4000],
                    "relative_cwd": str(item.get("relative_cwd") or "."),
                })
        if len(workers) >= 2:
            return workers[:BATCH_PARALLEL]
        return self._plan_workers(text)

    async def maybe_dispatch_async(self, row) -> dict | None:
        if not self.flags.router_on():
            return None
        text = row.get("text") or ""
        if not rule_hit(text) or has_deletion(text):
            return None
        workers = await self.plan_workers_async(text)
        if len(workers) < 2:
            return None
        return self._create_batch(row, workers)

    def _create_batch(self, row, workers):
        import sqlite3

        mid = row["id"]
        req = row["request_id"]
        batch_id = "batch_" + hashlib.sha256(f"{req}:{mid}".encode()).hexdigest()[:20]
        import sqlite3 as sq
        db = sq.connect(self.path)
        try:
            if db.execute("SELECT 1 FROM batches WHERE id=?", (batch_id,)).fetchone():
                existing = db.execute("SELECT * FROM batches WHERE id=?", (batch_id,)).fetchone()
                return {
                    "batch_id": batch_id,
                    "ack": existing[4] if existing else "已受理",
                    "task_ids": json.loads(existing[3]) if existing else [],
                    "idempotent": True,
                }
        finally:
            db.close()

        quote = row["text"]
        task_ids = []
        for i, w in enumerate(workers):
            cwd = (self.workspace / w["relative_cwd"]).resolve()
            cwd.mkdir(parents=True, exist_ok=True)
            request_id = f"{req}:batch:{i}:{w['agent']}"
            sandbox = effective_sandbox("danger-full-access")
            draft = {
                "agent": w["agent"],
                "cwd": str(cwd),
                "title": w["title"][:40],
                "prompt": (
                    f"用户明确交办原文：\n{quote}\n\n任务说明：\n{w['prompt']}\n\n"
                    f"完成条件：\n给出可读结论\n\n授权范围：\nbatch 子任务；不做不可逆删除"
                ),
                "sandbox": sandbox,
                "requested_sandbox": "danger-full-access",
                "operation_policy_revision": POLICY_REVISION,
                "origin_session_id": "personal-main",
                "origin_message_id": mid,
                "origin_request_id": req,
                "owner_conversation_id": "personal-main",
                "completion_condition": "给出可读结论",
                "source_links": [{"message_id": mid, "text": quote[:500]}],
                "source_message_ids": [mid],
                "context_revision": 1,
                "latest_user_message_id": mid,
                "batch_id": batch_id,
                "batch_suppress_receipt": True,
                "interactive": False,
                "work_brief": {
                    "goal": w["title"],
                    "completion_condition": "给出可读结论",
                    "authorized_cwd": str(cwd),
                    "sandbox": sandbox,
                    "source_links": [],
                    "latest_instruction": quote,
                    "constraints": [],
                    "context_revision": 1,
                    "batch_id": batch_id,
                },
            }
            authorization = {
                "request_id": request_id,
                "cwd": str(cwd),
                "sandbox": sandbox,
                "source_message_id": mid,
                "source_request_id": req,
                "source_quote": quote[:2000],
                "scope": "Router batch 子任务；来自用户原话；不做不可逆删除",
                "entry": "router_batch",
                "batch_id": batch_id,
                "source_links": draft["source_links"],
            }
            task = self.store.create_authorized(draft, authorization, request_id)
            task_ids.append(task["id"])

        now = self.clock()
        ack = f"已分别派给 {len(task_ids)} 路并行处理，完成后合并回你。"
        db = sq.connect(self.path)
        try:
            db.execute(
                "INSERT INTO batches(id,origin_message_id,origin_request_id,status,task_ids,ack,folded,deadline_at,created_at,updated_at) "
                "VALUES(?,?,?,?,?,?,0,?,?,?)",
                (batch_id, mid, req, "running", json.dumps(task_ids), ack, now + BATCH_DEADLINE_S, now, now),
            )
            db.commit()
        finally:
            db.close()
        return {"batch_id": batch_id, "ack": ack, "task_ids": task_ids}

    def pending_folds(self):
        import sqlite3

        db = sqlite3.connect(self.path)
        db.row_factory = sqlite3.Row
        try:
            return [dict(r) for r in db.execute("SELECT * FROM batches WHERE folded=0").fetchall()]
        finally:
            db.close()

    def mark_folded(self, batch_id, result_text):
        import sqlite3

        db = sqlite3.connect(self.path)
        try:
            db.execute(
                "UPDATE batches SET folded=1, status='folded', result=?, updated_at=? WHERE id=?",
                (result_text[:12000], self.clock(), batch_id),
            )
            db.commit()
        finally:
            db.close()
