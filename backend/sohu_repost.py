from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

SHANGHAI = ZoneInfo("Asia/Shanghai")

PUBLISHED_RE = re.compile(
    r"^\[(?P<ts>[^\]]+)\]\s+published:\s+"
    r"(?:(?P<cat>\[#大有可攀\]|\[非户外\]|\[[^\]]+\])\s+)?"
    r"\[(?P<creator>[^\]]+)\]\s+(?P<copy>.+)$"
)
QUEUE_FETCHED_RE = re.compile(r"^\[(?P<ts>[^\]]+)\]\s+queue fetched:\s+(?P<count>\d+)\s+items")
RUN_DONE_RE = re.compile(r"^\[(?P<ts>[^\]]+)\]\s+run done,\s+published=(?P<count>\d+)")
MONITOR_HB_RE = re.compile(r"^\[(?P<ts>[^\]]+)\]\s+\[monitor\]\s+nas heartbeat ok \((?P<hours>[0-9.]+)h\)")
MONITOR_LOGIN_OK_RE = re.compile(r"^\[(?P<ts>[^\]]+)\]\s+\[monitor\]\s+login check:\s+ok")
MONITOR_LOGIN_FAIL_RE = re.compile(r"^\[(?P<ts>[^\]]+)\]\s+\[monitor\]\s+login (?:expired|check failed|probe failed)")
MENTION_RE = re.compile(r"@([^\s@\[\]]+)")
EMOJI_RE = re.compile(r"(\[[^\s\[\]]{1,8}\])")
ANGLE_RE = re.compile(r"^【角度\s*[ABCabc][^】]*】\s*(.+)$")


def _parse_iso(ts: str) -> float:
    if not ts:
        return 0.0
    text = ts.strip()
    try:
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        elif " " in text and "T" not in text and "+" not in text:
            text = text.replace(" ", "T") + "+00:00"
        return dt.datetime.fromisoformat(text).timestamp()
    except Exception:
        return 0.0


def parse_copy_angles(copy_text: str | None) -> list[str]:
    if not copy_text or "文案生成失败" in copy_text:
        return []
    angles: list[str] = []
    for raw in copy_text.splitlines():
        line = raw.strip()
        m = ANGLE_RE.match(line)
        if m and len(m.group(1).strip()) >= 8:
            angles.append(m.group(1).strip())
    if not angles:
        for raw in copy_text.splitlines():
            line = raw.strip()
            if line and not line.startswith("[推荐理由]") and 8 <= len(line) <= 110:
                angles.append(line)
    return angles[:3]


class SohuRepostService:
    def __init__(self, bot_dir: Path | None = None) -> None:
        self.bot_dir = bot_dir or (Path.home() / "clawd" / "sohu-repost-bot")
        self._nas_cache: dict[str, dict[str, Any]] = {}
        self._nas_cache_at: float = 0.0

    def _read_json(self, path: Path, default: Any) -> Any:
        try:
            if path.exists():
                return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            pass
        return default

    def _read_jsonl(self, path: Path) -> list[dict[str, Any]]:
        if not path.exists():
            return []
        rows: list[dict[str, Any]] = []
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                text = line.strip()
                if not text:
                    continue
                try:
                    item = json.loads(text)
                    if isinstance(item, dict):
                        rows.append(item)
                except Exception:
                    continue
        except Exception:
            pass
        return rows

    def _write_jsonl_atomic(self, path: Path, rows: list[dict[str, Any]]) -> None:
        tmp = path.with_suffix(path.suffix + ".tmp")
        payload = "\n".join(json.dumps(r, ensure_ascii=False) for r in rows)
        if rows:
            payload += "\n"
        tmp.write_text(payload, encoding="utf-8")
        tmp.replace(path)

    def _tail_lines(self, path: Path, max_bytes: int = 262144) -> list[str]:
        if not path.exists():
            return []
        try:
            size = path.stat().st_size
            with path.open("rb") as f:
                if size > max_bytes:
                    f.seek(size - max_bytes)
                data = f.read()
            text = data.decode("utf-8", errors="replace")
            lines = text.splitlines()
            return lines[1:] if size > max_bytes and len(lines) > 1 else lines
        except Exception:
            return []

    def _creator_lookup_from_logs_and_queue(self, review_rows: list[dict[str, Any]]) -> dict[str, str]:
        uid_to_name: dict[str, str] = {
            "261499995": "Eating爱自由",
            "441261006": "Aries-丁丁",
            "440733755": "施瓦辛格.雪",
            "432172858": "野生老马",
            "444753775": "建良奇睏",
            "440684214": "VickyMa",
            "177298470": "攀岩土豆",
            "289566323": "耀阳环游记",
            "310741521": "暴走兄弟",
            "441164450": "泡饭-climbing",
        }
        for row in review_rows:
            item = row.get("item") if isinstance(row.get("item"), dict) else {}
            uid = str(item.get("uid") or "").strip()
            name = str(item.get("creatorName") or "").strip()
            if uid and name:
                uid_to_name[uid] = name
        for item in self._nas_cache.values():
            uid = str(item.get("uid") or "").strip()
            name = str(item.get("creatorName") or "").strip()
            if uid and name:
                uid_to_name[uid] = name
        return uid_to_name

    def _refresh_nas_tail_if_needed(self, config: dict[str, Any]) -> None:
        now = time.time()
        if now - self._nas_cache_at < 120.0 and self._nas_cache:
            return
        self._nas_cache_at = now
        queue_file = (
            (config.get("nas") or {}).get("queueFile")
            if isinstance(config.get("nas"), dict)
            else "/volume1/docker/sohu-watcher/data/pending_repost.jsonl"
        ) or "/volume1/docker/sohu-watcher/data/pending_repost.jsonl"
        try:
            proc = subprocess.run(
                ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "nas", f"tail -n 80 {queue_file}"],
                capture_output=True,
                text=True,
                timeout=4.5,
                check=False,
            )
            if proc.returncode == 0 and proc.stdout:
                cache: dict[str, dict[str, Any]] = {}
                for line in proc.stdout.splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                        if isinstance(obj, dict) and obj.get("creatorName"):
                            cache[f"{obj.get('creatorName')}::{obj.get('id', '')}"] = obj
                    except Exception:
                        continue
                if cache:
                    self._nas_cache = cache
        except Exception:
            pass

    def status(self) -> dict[str, Any]:
        now = time.time()
        today_str = dt.datetime.now(SHANGHAI).strftime("%Y-%m-%d")

        config = self._read_json(self.bot_dir / "config.json", {})
        state = self._read_json(self.bot_dir / "state.json", {})
        monitor_state = self._read_json(self.bot_dir / "monitor_state.json", {})
        review_rows = self._read_jsonl(self.bot_dir / "review_queue.jsonl")
        self._refresh_nas_tail_if_needed(config)

        quota_cfg = config.get("quota") if isinstance(config.get("quota"), dict) else {}
        daily_max = int(quota_cfg.get("dailyTotal") or 10)
        per_creator_max = int(quota_cfg.get("perCreatorDaily") or 3)
        non_outdoor_max = int(quota_cfg.get("nonOutdoorDaily") or 1)
        non_outdoor_interval_h = float(quota_cfg.get("nonOutdoorMinIntervalHours") or 8.0)

        crash_streak = 0
        try:
            crash_path = self.bot_dir / "crash_streak.txt"
            if crash_path.exists():
                crash_streak = int(crash_path.read_text(encoding="utf-8").strip() or "0")
        except Exception:
            crash_streak = 0

        net_failures = int(state.get("consecutiveNetFailures") or 0)

        # Parse pipeline.log for recent published items, queue count, and last run
        pipeline_lines = self._tail_lines(self.bot_dir / "logs" / "pipeline.log")
        queue_total = len(state.get("processedIds") or {})
        last_run_at = _parse_iso(str(state.get("updatedAt") or ""))
        last_publish_at = 0.0
        published_events: list[dict[str, Any]] = []

        for line in pipeline_lines:
            m_q = QUEUE_FETCHED_RE.match(line)
            if m_q:
                queue_total = int(m_q.group("count"))
                continue
            m_done = RUN_DONE_RE.match(line)
            if m_done:
                ts_val = _parse_iso(m_done.group("ts"))
                if ts_val > last_run_at:
                    last_run_at = ts_val
                continue
            m_pub = PUBLISHED_RE.match(line)
            if m_pub:
                ts_val = _parse_iso(m_pub.group("ts"))
                if ts_val > last_publish_at:
                    last_publish_at = ts_val
                cat_raw = (m_pub.group("cat") or "").strip()
                if cat_raw == "[#大有可攀]":
                    category = "topic_dayoukepan"
                    category_label = "#大有可攀"
                elif cat_raw == "[非户外]":
                    category = "non_outdoor"
                    category_label = "非户外"
                else:
                    category = "outdoor"
                    category_label = "关注流"
                creator = m_pub.group("creator").strip()
                copy_text = m_pub.group("copy").strip()
                mentions = ["@" + m for m in MENTION_RE.findall(copy_text)]
                emojis = EMOJI_RE.findall(copy_text)
                dt_local = dt.datetime.fromtimestamp(ts_val, SHANGHAI) if ts_val > 0 else dt.datetime.now(SHANGHAI)
                date_str = dt_local.strftime("%Y-%m-%d")
                time_text = dt_local.strftime("%H:%M") if date_str == today_str else dt_local.strftime("%m-%d %H:%M")

                # Match optional link/theme from cached NAS queue
                matched_link = ""
                matched_theme = ""
                for obj in reversed(list(self._nas_cache.values())):
                    if obj.get("creatorName") == creator and copy_text in str(obj.get("copy") or ""):
                        matched_link = str(obj.get("link") or "")
                        matched_theme = str(obj.get("theme") or "")
                        break

                published_events.append(
                    {
                        "id": f"pub-{int(ts_val * 1000)}-{len(published_events)}",
                        "at": ts_val,
                        "date": date_str,
                        "time_text": time_text,
                        "creator_name": creator,
                        "category": category,
                        "category_label": category_label,
                        "copy": copy_text,
                        "mentions": mentions,
                        "emojis": emojis,
                        "theme": matched_theme,
                        "link": matched_link,
                    }
                )

        # Parse monitor.log for login & NAS heartbeat status
        monitor_lines = self._tail_lines(self.bot_dir / "logs" / "monitor.log", max_bytes=65536)
        login_ok = True
        last_probe_at = 0.0
        nas_heartbeat_h = 0.0
        nas_ok = True
        for line in monitor_lines:
            m_hb = MONITOR_HB_RE.match(line)
            if m_hb:
                nas_heartbeat_h = float(m_hb.group("hours"))
                nas_ok = nas_heartbeat_h < 2.5
                continue
            m_ok = MONITOR_LOGIN_OK_RE.match(line)
            if m_ok:
                login_ok = True
                last_probe_at = _parse_iso(m_ok.group("ts"))
                continue
            m_fail = MONITOR_LOGIN_FAIL_RE.match(line)
            if m_fail:
                login_ok = False
                last_probe_at = _parse_iso(m_fail.group("ts"))

        daily_map = state.get("daily") if isinstance(state.get("daily"), dict) else {}
        today_entry = daily_map.get(today_str) if isinstance(daily_map.get(today_str), dict) else {}
        daily_total = int(today_entry.get("total") or 0)
        non_outdoor_today = int(today_entry.get("nonOutdoor") or 0)

        # Count today's categories from published_events + processedVids
        topic_today = sum(
            1 for e in published_events if e["date"] == today_str and e["category"] == "topic_dayoukepan"
        )
        non_outdoor_from_log = sum(
            1 for e in published_events if e["date"] == today_str and e["category"] == "non_outdoor"
        )
        if non_outdoor_from_log > non_outdoor_today:
            non_outdoor_today = non_outdoor_from_log
        outdoor_today = max(0, daily_total - topic_today - non_outdoor_today)

        cooldown_remaining = 0.0
        last_non_outdoor_iso = str(state.get("lastNonOutdoorTimestamp") or "")
        if last_non_outdoor_iso:
            last_no_ts = _parse_iso(last_non_outdoor_iso)
            if last_no_ts > 0:
                passed_h = (now - last_no_ts) / 3600.0
                if passed_h < non_outdoor_interval_h:
                    cooldown_remaining = round(non_outdoor_interval_h - passed_h, 1)

        # Build 7-day trend
        week_days: list[dict[str, Any]] = []
        today_dt = dt.datetime.now(SHANGHAI).date()
        for offset in range(6, -1, -1):
            d_obj = today_dt - dt.timedelta(days=offset)
            d_key = d_obj.strftime("%Y-%m-%d")
            d_info = daily_map.get(d_key) if isinstance(daily_map.get(d_key), dict) else {}
            d_tot = int(d_info.get("total") or 0)
            d_topic = sum(1 for e in published_events if e["date"] == d_key and e["category"] == "topic_dayoukepan")
            d_non = max(
                int(d_info.get("nonOutdoor") or 0),
                sum(1 for e in published_events if e["date"] == d_key and e["category"] == "non_outdoor"),
            )
            d_out = max(0, d_tot - d_topic - d_non)
            week_days.append(
                {
                    "date": d_key,
                    "label": "今天" if offset == 0 else d_obj.strftime("%m/%d"),
                    "total": d_tot,
                    "outdoor": d_out,
                    "topic": d_topic,
                    "non_outdoor": d_non,
                }
            )

        # Pending review queue
        pending_reviews: list[dict[str, Any]] = []
        for row in review_rows:
            if row.get("status") != "pending":
                continue
            item = row.get("item") if isinstance(row.get("item"), dict) else {}
            angles = parse_copy_angles(str(item.get("copy") or ""))
            cat = str(item.get("sourceCategory") or "outdoor")
            cat_label = "#大有可攀" if cat == "topic_dayoukepan" else ("非户外" if cat == "non_outdoor" else "关注流")
            pending_reviews.append(
                {
                    "id": str(item.get("id") or ""),
                    "creator_name": str(item.get("creatorName") or "未知播主"),
                    "uid": str(item.get("uid") or ""),
                    "theme": str(item.get("theme") or item.get("text") or "未提取主题"),
                    "text": str(item.get("text") or ""),
                    "link": str(item.get("link") or ""),
                    "category": cat,
                    "category_label": cat_label,
                    "confidence": item.get("copy_confidence"),
                    "angles": angles,
                    "detected_at": str(item.get("detectedAt") or ""),
                    "queued_at": _parse_iso(str(row.get("ts") or "")),
                }
            )

        # Creator stats (last 14 days)
        uid_to_name = self._creator_lookup_from_logs_and_queue(review_rows)
        creator_counts: dict[str, int] = {}
        today_per_uid = today_entry.get("perUid") if isinstance(today_entry.get("perUid"), dict) else {}
        for offset in range(14):
            d_key = (today_dt - dt.timedelta(days=offset)).strftime("%Y-%m-%d")
            d_info = daily_map.get(d_key) if isinstance(daily_map.get(d_key), dict) else {}
            per_u = d_info.get("perUid") if isinstance(d_info.get("perUid"), dict) else {}
            for uid, cnt in per_u.items():
                creator_counts[str(uid)] = creator_counts.get(str(uid), 0) + int(cnt or 0)

        top_creators: list[dict[str, Any]] = []
        for uid, total_cnt in sorted(creator_counts.items(), key=lambda kv: (-kv[1], kv[0]))[:10]:
            top_creators.append(
                {
                    "uid": uid,
                    "name": uid_to_name.get(uid, f"UID {uid}"),
                    "count_14d": total_cnt,
                    "today_count": int(today_per_uid.get(uid) or 0),
                    "daily_limit": per_creator_max,
                }
            )

        recent_mentions: list[str] = []
        for ev in reversed(published_events):
            for m in ev["mentions"]:
                if m not in recent_mentions:
                    recent_mentions.append(m)
            if len(recent_mentions) >= 8:
                break

        pipeline_ok = crash_streak == 0 and net_failures < 3
        parts = [
            "登录正常" if login_ok else "登录态需重扫",
            f"NAS 心跳 {nas_heartbeat_h:.1f}h" if nas_heartbeat_h > 0 else "NAS 在线",
            f"队列 {queue_total} 条",
        ]
        if pending_reviews:
            parts.append(f"待审 {len(pending_reviews)} 条")

        return {
            "available": self.bot_dir.exists(),
            "updated_at": now,
            "health": {
                "login_ok": login_ok,
                "nas_ok": nas_ok,
                "pipeline_ok": pipeline_ok,
                "uid": str((config.get("sohu") or {}).get("myUid") or "376622042"),
                "account_name": "搜狐户外",
                "last_run_at": last_run_at,
                "last_publish_at": last_publish_at,
                "last_probe_at": last_probe_at,
                "nas_heartbeat_hours": nas_heartbeat_h,
                "crash_streak": crash_streak,
                "net_failures": net_failures,
                "queue_total": queue_total,
                "last_reconcile_at": float(monitor_state.get("lastReconcileAt") or 0) / 1000.0,
                "status_text": " · ".join(parts),
            },
            "quota": {
                "date": today_str,
                "daily_total": daily_total,
                "daily_max": daily_max,
                "outdoor_today": outdoor_today,
                "topic_today": topic_today,
                "non_outdoor_today": non_outdoor_today,
                "non_outdoor_max": non_outdoor_max,
                "non_outdoor_cooldown_hours": cooldown_remaining,
                "per_creator_max": per_creator_max,
            },
            "week": week_days,
            "review_queue": pending_reviews,
            "recent": list(reversed(published_events[-30:])),
            "top_creators": top_creators,
            "recent_mentions": recent_mentions,
        }

    def act(self, action: str, item_id: str = "", angle_index: int = 0) -> dict[str, Any]:
        action = (action or "").strip()
        if action in ("approve", "reject"):
            if not item_id:
                raise ValueError("缺少待审核条目 ID")
            review_path = self.bot_dir / "review_queue.jsonl"
            rows = self._read_jsonl(review_path)
            matched = False
            now_iso = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
            for row in rows:
                it = row.get("item") if isinstance(row.get("item"), dict) else {}
                if row.get("status") == "pending" and str(it.get("id") or "") == item_id:
                    if action == "approve":
                        angles = parse_copy_angles(str(it.get("copy") or ""))
                        idx = max(0, min(int(angle_index or 0), max(0, len(angles) - 1)))
                        row["status"] = "approved"
                        row["chosenIdx"] = idx
                        row["reviewedAt"] = now_iso
                    else:
                        row["status"] = "rejected"
                        row["reviewedAt"] = now_iso
                    matched = True
                    break
            if not matched:
                raise KeyError(f"找不到待审核条目：{item_id}")
            self._write_jsonl_atomic(review_path, rows)
            return {"ok": True, "action": action, "id": item_id, "snapshot": self.status()}

        if action == "dry_run":
            proc = subprocess.run(
                ["node", "run_pipeline.js", "--dry-run"],
                cwd=str(self.bot_dir),
                env={**os.environ, "DRY_RUN": "1"},
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
            lines = [ln.strip() for ln in (proc.stdout or "").splitlines() if ln.strip()]
            summary = lines[-1] if lines else ("Dry-Run 执行完成" if proc.returncode == 0 else "Dry-Run 退出异常")
            return {
                "ok": proc.returncode == 0,
                "action": "dry_run",
                "summary": summary,
                "output": "\n".join(lines[-8:]),
                "snapshot": self.status(),
            }

        if action == "run_now":
            lock_file = self.bot_dir / "pipeline.lock"
            if lock_file.exists() and (time.time() - lock_file.stat().st_mtime) < 1800:
                return {
                    "ok": False,
                    "action": "run_now",
                    "summary": "当前已有转发管道在运行中，请稍候再试",
                    "snapshot": self.status(),
                }
            subprocess.Popen(
                ["node", "run_pipeline.js"],
                cwd=str(self.bot_dir),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return {
                "ok": True,
                "action": "run_now",
                "summary": "已触发后台巡检与转发，约 15–30 秒后刷新结果",
                "snapshot": self.status(),
            }

        raise ValueError(f"不支持的操作：{action}")
