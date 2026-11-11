"""Milestone 3 (Phase 3 Restructure) — SSE 增量自愈协议与事件总线。

提供：
1. SQLite 持久化事件日志 (sse_event_log)
2. 内存高速环形队列 (SSERingBuffer, 默认 1000 帧)
3. 跨端事件发布广播器 (SSEBroadcaster)
4. 游标判定、断线续传 (Last-Event-ID)、越界熔断对齐 (resync_required)
"""
from __future__ import annotations

import asyncio
import collections
import json
import logging
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, AsyncIterator, Callable, Optional

logger = logging.getLogger("sse_stream")

TOOL_ACTIVITY_EVENTS: frozenset[str] = frozenset({"tool.started", "tool.completed"})
SEMANTIC_EVENT_TYPES: frozenset[str] = frozenset({
    "update",
    "snapshot",
    "resync_required",
    "task.progress",
    "task.review",
    "agent.push",
    "tool.started",
    "tool.completed",
})


class SSEEvent:
    def __init__(
        self,
        event_seq: int,
        event_type: str,
        data: dict[str, Any],
        created_at: float | None = None,
    ):
        self.event_seq = int(event_seq)
        self.event_type = str(event_type)
        self.data = data
        self.created_at = float(created_at if created_at is not None else time.time())

    def to_sse_frame(self) -> str:
        payload = json.dumps(
            {**self.data, "event_seq": self.event_seq},
            ensure_ascii=False,
            separators=(",", ":"),
        )
        return f"id: {self.event_seq}\nevent: {self.event_type}\ndata: {payload}\n\n"

    def __repr__(self) -> str:
        return f"<SSEEvent seq={self.event_seq} type={self.event_type}>"


class SSERingBuffer:
    """带 SQLite 持久化日志与内存环形缓冲的事件存储"""

    def __init__(self, db_path: Path, capacity: int = 1000, clock=time.time):
        self.db_path = Path(db_path)
        self.capacity = capacity
        self.clock = clock
        self._lock = threading.Lock()
        self.buffer: collections.deque[SSEEvent] = collections.deque(maxlen=capacity)
        self.latest_seq: int = 0
        self.min_retained_seq: int = 1
        self._init_db()

    def _init_db(self) -> None:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(self.db_path, timeout=20) as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("""
                CREATE TABLE IF NOT EXISTS sse_event_log (
                    event_seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_type TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    created_at REAL NOT NULL
                )
            """)
            db.execute("CREATE INDEX IF NOT EXISTS idx_sse_log_seq ON sse_event_log(event_seq)")
            db.commit()

            # 载入最近的最多 capacity 条记录到内存队列中，恢复单调序号状态
            rows = db.execute(
                "SELECT event_seq, event_type, payload, created_at FROM sse_event_log "
                "ORDER BY event_seq DESC LIMIT ?",
                (self.capacity,),
            ).fetchall()

        if rows:
            # 倒序查出，正序插入 deque
            for r in reversed(rows):
                seq, etype, raw_payload, cat = r
                try:
                    payload = json.loads(raw_payload)
                except Exception:
                    payload = {}
                ev = SSEEvent(event_seq=seq, event_type=etype, data=payload, created_at=cat)
                self.buffer.append(ev)
            self.latest_seq = self.buffer[-1].event_seq
            self.min_retained_seq = self.buffer[0].event_seq

            # 启动时若数据库存在历史遗留多余行，修剪使其严格与内存缓冲区同步
            if self.min_retained_seq > 1:
                with sqlite3.connect(self.db_path, timeout=20) as db:
                    db.execute(
                        "DELETE FROM sse_event_log WHERE event_seq <= ?",
                        (self.min_retained_seq - 1,),
                    )
                    db.commit()
        else:
            self.latest_seq = 0
            self.min_retained_seq = 1

    def publish(self, event_type: str, data: dict[str, Any]) -> SSEEvent:
        """发布事件：同步写入 SQLite 并追加进环形缓冲区，超出容量时同步修剪 SQLite 日志"""
        now = self.clock()
        raw_payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
        with self._lock:
            with sqlite3.connect(self.db_path, timeout=20) as db:
                cur = db.execute(
                    "INSERT INTO sse_event_log (event_type, payload, created_at) VALUES (?, ?, ?)",
                    (event_type, raw_payload, now),
                )
                seq = int(cur.lastrowid or 0)

                ev = SSEEvent(event_seq=seq, event_type=event_type, data=data, created_at=now)
                self.buffer.append(ev)
                self.latest_seq = seq
                self.min_retained_seq = self.buffer[0].event_seq

                # 真实修剪：当环形队列挤出最旧条目时，同步删除 SQLite 中超出 retention 的旧日志
                if self.min_retained_seq > 1:
                    db.execute(
                        "DELETE FROM sse_event_log WHERE event_seq <= ?",
                        (self.min_retained_seq - 1,),
                    )
                db.commit()

            return ev

    def is_in_buffer(self, cursor: int) -> bool:
        """判定游标是否在有效重放窗口内"""
        if cursor <= 0:
            return False
        if not self.buffer:
            return cursor == self.latest_seq
        # 客户端拥有的最新序列是 cursor，需要重放 cursor < event_seq <= latest_seq
        # 若 cursor >= min_retained_seq - 1 且 cursor <= latest_seq，说明缺失的数据全部在环形缓冲区内
        return (self.min_retained_seq - 1) <= cursor <= self.latest_seq

    def is_expired(self, cursor: int) -> bool:
        """游标低于缓冲区最早保留帧（过旧越界）"""
        if cursor <= 0:
            return False
        return cursor < (self.min_retained_seq - 1)

    def is_future(self, cursor: int) -> bool:
        """游标超过服务端当前最新序号（超前异常）"""
        return cursor > self.latest_seq

    def get_since(
        self,
        cursor: int,
        *,
        event_types: set[str] | frozenset[str] | None = None,
    ) -> list[SSEEvent]:
        """提取大于 cursor 的所有已缓存事件（可选按 event_types 过滤）"""
        with self._lock:
            if event_types is None:
                return [ev for ev in self.buffer if ev.event_seq > cursor]
            return [
                ev
                for ev in self.buffer
                if ev.event_seq > cursor and ev.event_type in event_types
            ]


class SSEBroadcaster:
    """跨客户端 SSE 事件广播器，管理活跃长连接与订阅生命周期"""

    def __init__(self, ring_buffer: SSERingBuffer):
        self.ring_buffer = ring_buffer
        self._subscribers: set[asyncio.Queue[SSEEvent]] = set()
        self._lock = asyncio.Lock()

    def publish(self, event_type: str, data: dict[str, Any]) -> SSEEvent:
        """对外统一发布事件，并向所有在线连接推送"""
        ev = self.ring_buffer.publish(event_type, data)
        # 向所有队列派发
        for q in list(self._subscribers):
            try:
                q.put_nowait(ev)
            except asyncio.QueueFull:
                pass
            except Exception:
                pass
        return ev

    def publish_tool_activity(self, event_type: str, data: dict[str, Any]) -> SSEEvent:
        """发布工具活动语义帧（tool.started / tool.completed）进环形缓冲与在线流"""
        if event_type not in TOOL_ACTIVITY_EVENTS:
            raise ValueError(f"Unsupported tool activity event_type: {event_type!r}")
        return self.publish(event_type, data)

    def publish_semantic_batch(self, semantic_events: list[dict[str, Any]]) -> list[SSEEvent]:
        """按顺序将 AgentEventProjector 产出的语义事件批量发布进 SSE"""
        published: list[SSEEvent] = []
        for item in semantic_events:
            if isinstance(item, dict) and item.get("event") and isinstance(item.get("data"), dict):
                published.append(self.publish(str(item["event"]), item["data"]))
        return published

    async def _add_subscriber(self, q: asyncio.Queue[SSEEvent]) -> None:
        async with self._lock:
            self._subscribers.add(q)

    async def _remove_subscriber(self, q: asyncio.Queue[SSEEvent]) -> None:
        async with self._lock:
            self._subscribers.discard(q)

    async def stream_client(
        self,
        cursor: int | None,
        get_snapshot_fn: Callable[[], dict[str, Any]],
        keepalive_seconds: float = 15.0,
    ) -> AsyncIterator[str]:
        """针对单一 SSE 请求的自愈流生成器。

        状态仲裁逻辑：
        1. cursor 为空或 <= 0：首连，下发全量 snapshot。
        2. cursor 命中环形缓冲窗口：补齐缺失的帧 (missed events)。
        3. cursor 过期或超前：下发 resync_required 帧，紧跟 snapshot 全量对齐。
        4. 随后挂入实时订阅队列，每隔 keepalive_seconds 发送保活心跳。
        """
        queue: asyncio.Queue[SSEEvent] = asyncio.Queue(maxsize=500)
        current_seq: int = self.ring_buffer.latest_seq

        # 1. 协商起始状态
        if cursor is None or cursor <= 0:
            # 首连或显式重置
            snap = get_snapshot_fn()
            current_seq = self.ring_buffer.latest_seq
            snap_payload = {**snap, "latest_event_seq": current_seq}
            yield f"id: {current_seq}\nevent: snapshot\ndata: {json.dumps(snap_payload, ensure_ascii=False, separators=(',', ':'))}\n\n"
        elif self.ring_buffer.is_in_buffer(cursor):
            # 命中环形缓冲，按序补齐所有遗漏帧
            missed = self.ring_buffer.get_since(cursor)
            for ev in missed:
                yield ev.to_sse_frame()
                current_seq = max(current_seq, ev.event_seq)
        else:
            # 游标过期 (cursor < min_retained - 1) 或异常超前 (cursor > latest_seq)
            # 严禁静默吞帧，下发 resync_required 告知客户端重置并拉齐
            resync_data = {
                "event_seq": self.ring_buffer.latest_seq,
                "reason": "cursor_expired" if self.ring_buffer.is_expired(cursor) else "cursor_future",
                "min_retained_seq": self.ring_buffer.min_retained_seq,
                "latest_seq": self.ring_buffer.latest_seq,
                "requested_cursor": cursor,
                "message": "游标已过期或不匹配，已重新同步全量快照",
            }
            yield f"id: {self.ring_buffer.latest_seq}\nevent: resync_required\ndata: {json.dumps(resync_data, ensure_ascii=False, separators=(',', ':'))}\n\n"
            snap = get_snapshot_fn()
            current_seq = self.ring_buffer.latest_seq
            snap_payload = {**snap, "latest_event_seq": current_seq}
            yield f"id: {current_seq}\nevent: snapshot\ndata: {json.dumps(snap_payload, ensure_ascii=False, separators=(',', ':'))}\n\n"

        # 2. 挂载实时订阅队列
        await self._add_subscriber(queue)
        try:
            while True:
                try:
                    ev = await asyncio.wait_for(queue.get(), timeout=keepalive_seconds)
                    # 判重门禁：严禁推送小于等于当前已消费序号的帧
                    if ev.event_seq > current_seq:
                        yield ev.to_sse_frame()
                        current_seq = ev.event_seq
                except asyncio.TimeoutError:
                    # 保活心跳帧
                    yield f": keepalive {int(time.time())}\n\n"
        finally:
            await self._remove_subscriber(queue)
