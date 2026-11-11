"""全能签免扩展万能投递口（Drop Inbox）。

复用现有 `artifacts.sqlite` 建表 `drop_items`（WAL + 0600，绝不新建独立 sqlite 库）：
- 支持投递 URL（自动识别剪映 capcut / 抖音 / 小红书 / 搜狐 tv.sohu / GitHub / 通用网页并生成动作建议）；
- 支持投递纯文本；
- 支持投递 `data_base64` 文件或图片（安全落盘 CAS 与工作区受管产出目录，并经 `ArtifactAccess` 注册 `/personal/artifacts/art_...`）；
- 当 `auto_chat=True` 时，向主对话写入用户投递记录与带 `picker` 建议按钮的助理响应气泡（如 `[立即处理] [存待办]`）。
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
import mimetypes
import os
import re
import sqlite3
import time
import uuid
from contextlib import closing
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from artifacts import ALLOWED as ALLOWED_ARTIFACT_EXTS
from artifacts import ArtifactAccess
from send_message import IMAGE_EXTS, ContentAddressedStore

MAX_DROP_BYTES = 32 * 1024 * 1024
_SINGLE_URL_RE = re.compile(r"^(https?://[^\s<>\"']+)$", re.I)
_FIRST_URL_RE = re.compile(r"(https?://[^\s<>\"']+)", re.I)
_DATA_URI_RE = re.compile(r"^data:([a-zA-Z0-9.+/-]+)?(?:;charset=[^;,]+)?;base64,(.*)$", re.S | re.I)
_SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9\u4e00-\u9fff._-]+")

_MIME_DEFAULT_EXT = {
    "image/png": ".png",
    "image/jpeg": ".jpg",
    "image/jpg": ".jpg",
    "image/webp": ".webp",
    "image/gif": ".gif",
    "application/pdf": ".pdf",
    "text/plain": ".txt",
    "text/markdown": ".md",
    "text/html": ".html",
    "text/csv": ".csv",
    "video/mp4": ".mp4",
    "video/quicktime": ".mov",
}


def detect_url_platform(url: str) -> dict[str, Any]:
    """根据 URL 域名识别平台并返回定制动作建议与说明。"""
    parsed = urlparse(str(url or "").strip())
    host = (parsed.hostname or "").lower()
    if any(h in host for h in ("capcut.cn", "capcut.com", "ulikecam.com")):
        return {
            "platform": "capcut",
            "platform_label": "剪映云审阅",
            "default_title": "剪映审阅分享视频",
            "hint": "识别到剪映云端审阅链接，可直接解 CENC 下载本地 MP4 或转存待办。",
            "suggestions": ["下载剪映无加密成片", "立即处理", "存待办"],
        }
    if any(h in host for h in ("douyin.com", "iesdouyin.com")):
        return {
            "platform": "douyin",
            "platform_label": "抖音视频",
            "default_title": "抖音视频分享",
            "hint": "识别到抖音链接，可去水印下载成片、拆解脚本或存为选题待办。",
            "suggestions": ["去水印下载抖音视频", "立即处理", "存待办"],
        }
    if any(h in host for h in ("xiaohongshu.com", "xhslink.com")):
        return {
            "platform": "xiaohongshu",
            "platform_label": "小红书笔记",
            "default_title": "小红书笔记分享",
            "hint": "识别到小红书链接，可提取图文要点、查账号粉丝数或归档选题。",
            "suggestions": ["提取小红书图文要点", "立即处理", "存待办"],
        }
    if any(h in host for h in ("tv.sohu.com", "sohu.com")):
        return {
            "platform": "sohu",
            "platform_label": "搜狐视频/关注流",
            "default_title": "搜狐关注流动态",
            "hint": "识别到搜狐视频/关注流链接，可排入关注流转发候选、跨圈层 @ 或核对履约。",
            "suggestions": ["加入搜狐关注流处理", "立即处理", "存待办"],
        }
    if any(h in host for h in ("github.com", "gist.github.com")):
        return {
            "platform": "github",
            "platform_label": "GitHub 仓库/PR",
            "default_title": f"GitHub · {parsed.path.strip('/')[:48] or host}",
            "hint": "识别到 GitHub 链接，可拉取说明审查代码、提炼改动摘要或存待办。",
            "suggestions": ["审查 GitHub 项目/PR", "立即处理", "存待办"],
        }
    return {
        "platform": "web",
        "platform_label": "网页链接",
        "default_title": host or "投递链接",
        "hint": "已收到网页链接，可抓取正文提炼摘要、收藏归档或存待办。",
        "suggestions": ["抓取网页摘要", "立即处理", "存待办"],
    }


def _sanitize_filename(raw_name: str, mime_type: str) -> tuple[str, str]:
    base = Path(str(raw_name or "").strip()).name
    base = _SAFE_NAME_RE.sub("_", base).lstrip("._")
    ext = Path(base).suffix.lower()
    stem = Path(base).stem if ext else base
    if not ext or ext not in ALLOWED_ARTIFACT_EXTS:
        guessed = _MIME_DEFAULT_EXT.get(mime_type.lower()) or mimetypes.guess_extension(mime_type or "") or ""
        if guessed == ".jpe":
            guessed = ".jpg"
        ext = guessed.lower() if guessed.lower() in ALLOWED_ARTIFACT_EXTS else ".png" if mime_type.startswith("image/") else ".txt"
    if not stem:
        stem = "drop_asset"
    final_name = f"{stem[:60]}{ext}"
    resolved_mime = mime_type or mimetypes.guess_type(final_name)[0] or "application/octet-stream"
    return final_name, resolved_mime


def _decode_base64_payload(raw_b64: str, declared_mime: str = "") -> tuple[bytes, str]:
    cleaned = str(raw_b64 or "").strip()
    mime = str(declared_mime or "").strip()
    m = _DATA_URI_RE.match(cleaned)
    if m:
        if m.group(1) and not mime:
            mime = m.group(1).strip()
        cleaned = m.group(2).strip()
    cleaned_compact = re.sub(r"\s+", "", cleaned)
    if not cleaned_compact:
        raise ValueError("data_base64 不能为空")
    try:
        data = base64.b64decode(cleaned_compact, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ValueError("data_base64 不是合法的 Base64 编码") from exc
    if not data:
        raise ValueError("解码后的文件内容为空")
    if len(data) > MAX_DROP_BYTES:
        raise ValueError("投递文件超过 32 MB 上限")
    return data, mime


class DropInbox:
    """复用 `artifacts.sqlite` 的免扩展万能投递收件箱。"""

    def __init__(
        self,
        state: Path | str,
        *,
        artifact_access: ArtifactAccess | None = None,
        conversation: Any = None,
        workspace: Path | None = None,
    ) -> None:
        self.state = Path(state)
        self.state.mkdir(parents=True, exist_ok=True)
        self.db_path = self.state / "artifacts.sqlite"
        self.artifact_access = artifact_access
        self.conversation = conversation
        default_ws = (
            artifact_access.workspace
            if artifact_access is not None
            else Path(workspace or (Path(os.environ.get("WORKBENCH_HOME", str(Path.home()))) / "AI_Work_System")).resolve()
        )
        self.workspace = Path(default_ws).resolve()
        self._init_db()

    def _init_db(self) -> None:
        with closing(sqlite3.connect(self.db_path, timeout=15)) as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS artifacts(id TEXT PRIMARY KEY, data TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS artifact_state(key TEXT PRIMARY KEY, data TEXT NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS drop_items(
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    url TEXT NOT NULL DEFAULT '',
                    title TEXT NOT NULL DEFAULT '',
                    text TEXT NOT NULL DEFAULT '',
                    artifact_id TEXT NOT NULL DEFAULT '',
                    mime_type TEXT NOT NULL DEFAULT '',
                    source TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'received',
                    created_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_drop_items_created_at ON drop_items(created_at DESC);
                """
            )
            db.commit()
        try:
            os.chmod(self.db_path, 0o600)
        except OSError:
            pass

    def _ensure_artifact_access(self) -> ArtifactAccess:
        if self.artifact_access is not None:
            return self.artifact_access
        from tasks import TaskStore

        self.workspace.mkdir(parents=True, exist_ok=True)
        self.artifact_access = ArtifactAccess(TaskStore(self.state), self.workspace, self.state)
        return self.artifact_access

    def _store_binary_artifact(
        self,
        drop_id: str,
        raw_b64: str,
        *,
        filename: str = "",
        mime_type: str = "",
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        raw_bytes, detected_mime = _decode_base64_payload(raw_b64, mime_type)
        safe_name, final_mime = _sanitize_filename(filename, detected_mime)
        digest = hashlib.sha256(raw_bytes).hexdigest()

        access = self._ensure_artifact_access()
        drop_dir = access.workspace / "work" / "航程产出" / "drop_inbox"
        drop_dir.mkdir(parents=True, exist_ok=True)
        dest_path = drop_dir / f"{digest[:12]}_{safe_name}"
        if not dest_path.exists():
            tmp_path = drop_dir / f".tmp_{uuid.uuid4().hex}_{safe_name}"
            tmp_path.write_bytes(raw_bytes)
            os.replace(tmp_path, dest_path)

        cas = ContentAddressedStore(self.state, access.workspace)
        is_image = Path(safe_name).suffix.lower() in IMAGE_EXTS
        cas_meta = cas.ingest_local_file(dest_path.resolve().as_uri(), require_image=False)
        art_record = access.register(drop_id, dest_path)
        art_record["mime"] = final_mime
        art_record["sha256"] = cas_meta["sha256"]
        art_record["is_image"] = is_image
        return art_record, cas_meta

    def _inject_auto_chat(
        self,
        item: dict[str, Any],
        *,
        suggestions: list[str],
        hint: str,
        artifact_record: dict[str, Any] | None = None,
    ) -> dict[str, str]:
        chat = self.conversation
        if chat is None or not hasattr(chat, "db"):
            return {}

        user_mid = "msg_drop_u_" + uuid.uuid4().hex[:18]
        asst_mid = "msg_drop_a_" + uuid.uuid4().hex[:18]
        req_id = "drop-" + item["id"]
        now = time.time()

        parts: list[str] = []
        if item["title"]:
            parts.append(f"【投递】{item['title']}")
        else:
            parts.append("【投递收件】")
        if item["url"]:
            parts.append(item["url"])
        if item["text"] and item["text"] != item["url"]:
            parts.append(item["text"])
        if artifact_record:
            parts.append(f"附件：{artifact_record['name']} ({artifact_record['download_path']})")
        user_text = "\n".join(parts).strip()

        option_labels = list(dict.fromkeys([*suggestions, "立即处理", "存待办"]))[:4]
        picker_widget = {
            "kind": "picker",
            "title": item["title"] or "收到新投递，要怎么处理？",
            "options": [{"id": f"opt_{idx + 1}", "label": label} for idx, label in enumerate(option_labels)],
        }
        lead_text = hint or f"已收入投递箱：{item['title'] or item['kind']}"
        bubble_obj: dict[str, Any] = {
            "type": "widget",
            "content": lead_text,
            "blocking": False,
            "widget": picker_widget,
            "suggestions": option_labels,
        }
        artifacts_list = [artifact_record] if artifact_record else []
        encoded_artifacts = json.dumps(artifacts_list, ensure_ascii=False)

        with chat.db() as db:
            active_ch = "personal"
            if hasattr(chat, "get_active_channel"):
                try:
                    active_ch = str(chat.get_active_channel() or "personal")
                except Exception:
                    active_ch = "personal"
            seq_u = chat._next_seq(db) if hasattr(chat, "_next_seq") else 0
            rev_u = chat._bump(db) if hasattr(chat, "_bump") else 1
            db.execute(
                "INSERT INTO messages("
                "id,request_id,role,text,status,phase,received_at,revision,created_at,updated_at,"
                "artifacts,message_seq,channel"
                ") VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    user_mid,
                    req_id,
                    "user",
                    user_text,
                    "completed",
                    "completed",
                    now,
                    rev_u,
                    now,
                    now,
                    encoded_artifacts,
                    seq_u,
                    active_ch,
                ),
            )
            seq_a = chat._next_seq(db) if hasattr(chat, "_next_seq") else seq_u + 1
            rev_a = chat._bump(db) if hasattr(chat, "_bump") else rev_u + 1
            db.execute(
                "INSERT INTO messages("
                "id,parent_id,role,text,status,phase,revision,created_at,updated_at,"
                "suggestions,artifacts,message_seq,bubble_type,bubble_payload,channel"
                ") VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    asst_mid,
                    user_mid,
                    "assistant",
                    lead_text,
                    "completed",
                    "completed",
                    rev_a,
                    now + 0.001,
                    now + 0.001,
                    json.dumps(option_labels, ensure_ascii=False),
                    encoded_artifacts,
                    seq_a,
                    "widget",
                    json.dumps(bubble_obj, ensure_ascii=False),
                    active_ch,
                ),
            )
        if hasattr(chat, "_notify"):
            chat._notify()
        return {"user_message_id": user_mid, "assistant_message_id": asst_mid, "request_id": req_id}

    def ingest(self, payload: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(payload, dict):
            raise ValueError("投递载荷必须为 JSON 对象")

        raw_url = str(payload.get("url") or "").strip()
        raw_text = str(
            payload.get("text") if payload.get("text") is not None else (payload.get("content") or "")
        ).strip()
        raw_title = str(payload.get("title") or "").strip()
        raw_b64 = str(
            payload.get("data_base64")
            or payload.get("base64")
            or payload.get("file_base64")
            or ""
        ).strip()
        filename = str(payload.get("filename") or payload.get("name") or "").strip()
        declared_mime = str(payload.get("mime_type") or payload.get("content_type") or "").strip()
        source = str(payload.get("source") or "ios_shortcut").strip()[:80] or "ios_shortcut"
        auto_chat = bool(payload.get("auto_chat", False))

        # Auto-extract URL if text itself is a bare URL or contains a URL when url field was omitted
        if not raw_url and raw_text:
            single = _SINGLE_URL_RE.match(raw_text)
            if single:
                raw_url = single.group(1)
            else:
                first_url = _FIRST_URL_RE.search(raw_text)
                if first_url and payload.get("kind") == "url":
                    raw_url = first_url.group(1)

        if raw_url and not raw_url.startswith(("http://", "https://")):
            raise ValueError("URL 必须以 http:// 或 https:// 开头")

        if not raw_url and not raw_text and not raw_b64:
            raise ValueError("投递内容不能为空（需提供 url、text 或 data_base64 之一）")

        drop_id = "drop_" + uuid.uuid4().hex[:20]
        now = time.time()
        artifact_record: dict[str, Any] | None = None
        artifact_id = ""
        mime_type = declared_mime
        platform_meta: dict[str, Any] = {}

        if raw_b64:
            artifact_record, _ = self._store_binary_artifact(
                drop_id,
                raw_b64,
                filename=filename,
                mime_type=declared_mime,
            )
            artifact_id = artifact_record["id"]
            mime_type = artifact_record["mime"]
            kind = "image" if artifact_record.get("is_image") or mime_type.startswith("image/") else "file"
            title = raw_title or artifact_record["name"]
            suggestions = ["立即处理", "提取文字/识别内容", "存待办"]
            hint = f"已接收投递附件「{artifact_record['name']}」并登记为安全成果，可直接处理或存待办。"
        elif raw_url:
            kind = "url"
            platform_meta = detect_url_platform(raw_url)
            title = raw_title or platform_meta["default_title"]
            mime_type = mime_type or "text/uri-list"
            suggestions = list(platform_meta["suggestions"])
            hint = platform_meta["hint"]
        else:
            kind = "text"
            first_line = raw_text.splitlines()[0].strip() if raw_text else ""
            title = raw_title or (first_line[:48] if first_line else "文本投递")
            mime_type = mime_type or "text/plain"
            suggestions = ["立即处理", "存待办", "记入记忆"]
            hint = f"已收到投递文本（{len(raw_text)} 字），可立即交由 Com 处理或存为待办。"

        status = "chatted" if auto_chat and self.conversation is not None else "received"
        with closing(sqlite3.connect(self.db_path, timeout=15)) as db:
            db.execute(
                "INSERT INTO drop_items(id,kind,url,title,text,artifact_id,mime_type,source,status,created_at) "
                "VALUES(?,?,?,?,?,?,?,?,?,?)",
                (
                    drop_id,
                    kind,
                    raw_url[:2000],
                    title[:240],
                    raw_text[:20000],
                    artifact_id,
                    mime_type[:120],
                    source,
                    status,
                    now,
                ),
            )
            db.commit()

        item: dict[str, Any] = {
            "id": drop_id,
            "kind": kind,
            "url": raw_url[:2000],
            "title": title[:240],
            "text": raw_text[:20000],
            "artifact_id": artifact_id,
            "download_path": artifact_record["download_path"] if artifact_record else (f"/personal/artifacts/{artifact_id}" if artifact_id else ""),
            "mime_type": mime_type[:120],
            "source": source,
            "status": status,
            "created_at": now,
            "platform": platform_meta.get("platform", ""),
            "platform_label": platform_meta.get("platform_label", ""),
            "suggestions": suggestions,
            "hint": hint,
        }
        if artifact_record:
            item["artifact"] = artifact_record

        chat_meta: dict[str, str] = {}
        if auto_chat:
            chat_meta = self._inject_auto_chat(
                item,
                suggestions=suggestions,
                hint=hint,
                artifact_record=artifact_record,
            )
            if chat_meta:
                item["chat"] = chat_meta

        return item

    def list(self, *, limit: int = 50, kind: str = "", status: str = "") -> list[dict[str, Any]]:
        cap = max(1, min(int(limit or 50), 200))
        clauses: list[str] = []
        params: list[Any] = []
        if kind:
            clauses.append("kind=?")
            params.append(kind)
        if status:
            clauses.append("status=?")
            params.append(status)
        where_sql = ("WHERE " + " AND ".join(clauses)) if clauses else ""
        query = (
            "SELECT id,kind,url,title,text,artifact_id,mime_type,source,status,created_at "
            f"FROM drop_items {where_sql} ORDER BY created_at DESC LIMIT ?"
        )
        params.append(cap)
        with closing(sqlite3.connect(self.db_path, timeout=15)) as db:
            db.row_factory = sqlite3.Row
            rows = db.execute(query, params).fetchall()

        items: list[dict[str, Any]] = []
        for row in rows:
            entry = dict(row)
            aid = entry.get("artifact_id") or ""
            entry["download_path"] = f"/personal/artifacts/{aid}" if aid else ""
            if entry.get("url"):
                pmeta = detect_url_platform(entry["url"])
                entry["platform"] = pmeta["platform"]
                entry["platform_label"] = pmeta["platform_label"]
                entry["suggestions"] = pmeta["suggestions"]
            else:
                entry["platform"] = ""
                entry["platform_label"] = ""
                entry["suggestions"] = ["立即处理", "存待办"]
            items.append(entry)
        return items
