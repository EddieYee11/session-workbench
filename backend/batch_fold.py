"""Batch 折叠：子任务各自不出回执；截止或可折叠终态就绪后合成一条。"""
from __future__ import annotations

import time

TERMINAL = frozenset({"execution_finished", "failed", "cancelled"})
FOLDABLE = TERMINAL | frozenset({"waiting", "unknown", "paused"})


class BatchFold:
    def __init__(self, router_plan, store, conversation, clock=time.time):
        self.router_plan = router_plan
        self.store = store
        self.conversation = conversation
        self.clock = clock

    def tick(self):
        """扫描未折叠 batch：截止到了或全部进入可折叠态 → 合成回执。"""
        folded = 0
        by_id = {t["id"]: t for t in self.store.list()}
        for batch in self.router_plan.pending_folds():
            if batch.get("folded"):
                continue
            task_ids = __import__("json").loads(batch["task_ids"] or "[]")
            tasks = [by_id[i] for i in task_ids if i in by_id]
            if not tasks:
                continue
            now = self.clock()
            all_foldable = all(t.get("status") in FOLDABLE for t in tasks)
            deadline = float(batch.get("deadline_at") or 0)
            if not all_foldable and now < deadline:
                continue
            # 若仍有真正 running/dispatching 且未到截止，继续等
            busy = [t for t in tasks if t.get("status") in ("running", "dispatching", "queued")]
            if busy and now < deadline:
                continue
            text = self._compose(batch["id"], tasks)
            parent = batch.get("origin_message_id") or ""
            artifacts = []
            for t in tasks:
                for a in t.get("artifacts") or []:
                    artifacts.append(a)
            receipt_id = "batch:" + batch["id"]
            if parent and hasattr(self.conversation, "task_receipt_for_message"):
                self.conversation.task_receipt_for_message(receipt_id, text, parent)
            else:
                self.conversation.task_receipt(receipt_id, text)
            # 挂产物到回执文末已包含路径；若有 artifact linker 再补
            if artifacts and hasattr(self.conversation, "link_artifacts"):
                with __import__("contextlib").suppress(Exception):
                    self.conversation.link_artifacts(receipt_id, artifacts)
            self.router_plan.mark_folded(batch["id"], text)
            folded += 1
        return folded

    def _compose(self, batch_id, tasks):
        lines = [f"【并行批次 {batch_id[-8:]}】合并结果："]
        for t in tasks:
            status = t.get("status")
            label = {
                "execution_finished": "完成",
                "failed": "失败",
                "cancelled": "已取消",
                "waiting": "等待中",
                "unknown": "待核实",
                "paused": "已暂停",
                "running": "仍在跑",
                "queued": "排队中",
            }.get(status, status)
            body = (t.get("result") or "").strip() or "（无正文）"
            art = ""
            paths = [a.get("path") for a in (t.get("artifacts") or []) if a.get("path")]
            if paths:
                art = "\n附件：" + "、".join(paths[:5])
            lines.append(f"\n### {t.get('title') or t['id']}（{t.get('agent')} · {label}）\n{body[:3000]}{art}")
        unfinished = [t for t in tasks if t.get("status") not in TERMINAL]
        if unfinished:
            lines.append("\n（部分结果：仍有子任务未终态，已到截止或可折叠状态。）")
        return "\n".join(lines)
