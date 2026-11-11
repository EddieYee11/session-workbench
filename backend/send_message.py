"""Com! Personal Agent SendMessage-as-tool 机制核心实现。

涵盖：
1. SendMessageValidator：四类气泡（text | attachment | widget | secret-request）枚举与跨字段强校验；
2. ContentAddressedStore：file:// 本地附件安全边界核验与流式 SHA-256 内容寻址存储（不占模型上下文）；
3. SendMessageStore：会话状态机（working -> awaiting_user -> closed）、连续非发消息工具计数（进度提醒中间件）、内部思考归档；
4. Guidance 构建器：每次追加到 user turn 末尾的 <system_reminder> 与中途催报 / 零气泡自愈提醒。
"""
from __future__ import annotations

import hashlib
import json
import mimetypes
import os
import re
import shutil
import sqlite3
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

from artifacts import ALLOWED as ALLOWED_ARTIFACT_EXTS
from artifacts import EXTRA_ROOTS as ARTIFACT_EXTRA_ROOTS

ALLOWED_BUBBLE_TYPES = ("text", "attachment", "widget", "secret-request")
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".gif"}
WIDGET_KIND_ALIASES = {
    "confirm": "confirm",
    "confirmcard": "confirm",
    "confirm_card": "confirm",
    "picker": "picker",
    "quickreplies": "picker",
    "quick_replies": "picker",
    "select": "picker",
    "checklist": "checklist",
    "todo": "checklist",
    "form": "form",
}
SECRET_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]{1,63}$")
MAX_TEXT_CHARS = 12_000
MAX_CAPTION_CHARS = 240
MAX_WIDGET_LEAD_CHARS = 600
MAX_SECRET_REASON_CHARS = 300
MAX_CAS_BYTES = 100 * 1024 * 1024


class SendMessageError(ValueError):
    """SendMessage 校验或会话状态机拒绝基类（映射为工具 isError=True 可读反馈）。"""


class SendMessageValidationError(SendMessageError):
    """Schema 或跨字段校验失败，模型可在下一步修正参数重试。"""


class SendMessageStateError(SendMessageError):
    """会话状态机拦截（例如 awaiting_user 期间禁止继续发消息）。"""


@dataclass
class ValidatedBubble:
    bubble_type: str
    text: str
    bubble: dict[str, Any]
    suggestions: list[str] = field(default_factory=list)
    widgets: list[dict[str, Any]] = field(default_factory=list)
    local_files: list[dict[str, Any]] = field(default_factory=list)
    blocks_turn: bool = False


class ContentAddressedStore:
    """本地 file:// 引用的流式 SHA-256 内容寻址存储，严格复用工作区安全边界。"""

    def __init__(self, state: Path, workspace: Path | None = None):
        self.state = Path(state)
        default_ws = Path.home() / "AI_Work_System"
        self.workspace = Path(workspace or default_ws).resolve()
        self.extra_roots = [(self.workspace.parent / name).resolve() for name in ARTIFACT_EXTRA_ROOTS]
        self.cas_root = self.state / "cas-blobs"

    def _allowed_roots(self) -> list[Path]:
        return [self.workspace, *self.extra_roots]

    def parse_file_uri(self, uri: str) -> Path:
        parsed = urlparse(uri.strip())
        if parsed.scheme != "file":
            raise SendMessageValidationError("file:// 引用格式无效")
        if parsed.netloc and parsed.netloc not in ("localhost", ""):
            raise SendMessageValidationError("file:// 仅支持本机路径，不支持远程主机")
        raw_path = unquote(parsed.path or "")
        if not raw_path or not raw_path.startswith("/"):
            raise SendMessageValidationError(
                f"SendMessage 校验失败：file:// 必须使用绝对路径（如 file:///Users/...），当前收到 {uri!r}。"
            )
        return Path(raw_path)

    def ingest_local_file(self, uri: str, *, require_image: bool = False) -> dict[str, Any]:
        raw = self.parse_file_uri(uri)
        if raw.is_symlink():
            raise SendMessageValidationError("SendMessage 校验失败：不允许发送符号链接文件。")
        try:
            resolved = raw.resolve(strict=True)
        except FileNotFoundError as exc:
            raise SendMessageValidationError(
                f"SendMessage 校验失败：本地文件不存在（{raw}），请先确认文件已写入后再发送。"
            ) from exc
        except OSError as exc:
            raise SendMessageValidationError(f"SendMessage 校验失败：无法读取文件路径（{raw}）。") from exc

        root = next((r for r in self._allowed_roots() if resolved.is_relative_to(r)), None)
        if root is None:
            raise SendMessageValidationError(
                "SendMessage 校验失败：本地文件不在允许的工作区 / Documents / Downloads 范围内。"
            )
        rel_parts = resolved.relative_to(root).parts
        if any(part.startswith(".") for part in rel_parts):
            raise SendMessageValidationError("SendMessage 校验失败：禁止发送隐藏目录或隐藏文件。")
        if not resolved.is_file():
            raise SendMessageValidationError("SendMessage 校验失败：目标路径不是普通文件。")

        ext = resolved.suffix.lower()
        if ext not in ALLOWED_ARTIFACT_EXTS:
            raise SendMessageValidationError(
                f"SendMessage 校验失败：不支持的文件后缀 {ext or '(无后缀)'}。"
            )
        if require_image and ext not in IMAGE_EXTS:
            raise SendMessageValidationError(
                f"SendMessage 校验失败：images 仅支持图片格式（png/jpg/jpeg/webp/gif），当前为 {ext}。"
            )

        stat_info = resolved.stat()
        if stat_info.st_size > MAX_CAS_BYTES:
            raise SendMessageValidationError("SendMessage 校验失败：附件超过 100 MB 上限。")

        hasher = hashlib.sha256()
        fd = os.open(resolved, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            actual = os.fstat(fd)
            if (actual.st_dev, actual.st_ino) != (stat_info.st_dev, stat_info.st_ino):
                raise SendMessageValidationError("SendMessage 校验失败：文件在校验期间发生变化，请重试。")
            with os.fdopen(fd, "rb") as stream:
                fd = -1
                while chunk := stream.read(65536):
                    hasher.update(chunk)
        finally:
            if fd >= 0:
                os.close(fd)

        digest = hasher.hexdigest()
        shard_dir = self.cas_root / digest[:2]
        shard_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        cas_name = f"{digest}{ext}"
        cas_path = shard_dir / cas_name
        if not cas_path.exists():
            fd_tmp, tmp_name = tempfile.mkstemp(prefix=".cas-", dir=str(shard_dir))
            os.close(fd_tmp)
            tmp_path = Path(tmp_name)
            try:
                shutil.copyfile(resolved, tmp_path)
                os.chmod(tmp_path, 0o600)
                os.replace(tmp_path, cas_path)
            finally:
                if tmp_path.exists():
                    tmp_path.unlink(missing_ok=True)

        mime = mimetypes.guess_type(resolved.name)[0] or "application/octet-stream"
        return {
            "url": f"file://{resolved}",
            "scheme": "file",
            "path": str(resolved),
            "name": resolved.name,
            "mime": mime,
            "size": actual.st_size,
            "sha256": digest,
            "cas_relpath": f"cas-blobs/{digest[:2]}/{cas_name}",
        }


class SendMessageValidator:
    """对标 Grok Bot Zod + superRefine 的跨字段校验器。"""

    @staticmethod
    def _non_empty_str(value: Any) -> str:
        return value.strip() if isinstance(value, str) else ""

    @classmethod
    def _validate_uri_scheme(cls, raw_url: Any, *, field_name: str) -> tuple[str, str]:
        if not isinstance(raw_url, str) or not raw_url.strip():
            raise SendMessageValidationError(
                f"SendMessage 校验失败：{field_name} 不能为空，且必须使用 file:// 或 https:// 协议。"
            )
        url = raw_url.strip()
        parsed = urlparse(url)
        if parsed.scheme not in ("file", "https"):
            hint = (
                f"本地文件请改为 file:///绝对路径（如 file:///Users/.../{Path(url).name}）"
                if not parsed.scheme
                else "仅允许 file:// 或 https://（不支持明文 http:// 或其它协议）"
            )
            raise SendMessageValidationError(
                f"SendMessage 校验失败：{field_name}={url!r} 协议不合法；{hint}。"
            )
        if parsed.scheme == "https" and not parsed.netloc:
            raise SendMessageValidationError(
                f"SendMessage 校验失败：{field_name}={url!r} 缺少有效 https 域名。"
            )
        return url, parsed.scheme

    @classmethod
    def _validate_suggestions(cls, raw: Any) -> list[str]:
        if raw is None or raw == []:
            return []
        if not isinstance(raw, list) or len(raw) > 4:
            raise SendMessageValidationError(
                "SendMessage 校验失败：suggestions 必须是最多 4 项的字符串数组。"
            )
        cleaned: list[str] = []
        for item in raw:
            if not isinstance(item, str) or not item.strip() or len(item.strip()) > 24:
                raise SendMessageValidationError(
                    "SendMessage 校验失败：suggestions 每项必须为 1..24 字的非空短句。"
                )
            text = item.strip()
            if text not in cleaned:
                cleaned.append(text)
        return cleaned

    @classmethod
    def _validate_widget(cls, raw_widget: Any) -> tuple[dict[str, Any], bool]:
        if not isinstance(raw_widget, dict):
            raise SendMessageValidationError(
                "SendMessage 校验失败：type='widget' 必须提供结构化对象 widget={kind, title, ...}。"
            )
        raw_kind = str(raw_widget.get("kind") or raw_widget.get("type") or "").strip()
        kind = WIDGET_KIND_ALIASES.get(raw_kind.lower().replace("-", "_"))
        if not kind:
            raise SendMessageValidationError(
                f"SendMessage 校验失败：widget.kind={raw_kind!r} 无效，仅允许 confirm | picker | checklist | form。"
            )
        title = cls._non_empty_str(raw_widget.get("title"))
        if not title or len(title) > 120:
            raise SendMessageValidationError(
                "SendMessage 校验失败：widget.title 必填且不超过 120 字。"
            )
        normalized: dict[str, Any] = {"kind": kind, "title": title}
        if isinstance(raw_widget.get("id"), str) and raw_widget["id"].strip():
            normalized["id"] = raw_widget["id"].strip()[:64]
        if isinstance(raw_widget.get("subtitle"), str) and raw_widget["subtitle"].strip():
            normalized["subtitle"] = raw_widget["subtitle"].strip()[:200]

        if kind == "confirm":
            if isinstance(raw_widget.get("message"), str) and raw_widget["message"].strip():
                normalized["message"] = raw_widget["message"].strip()[:400]
            confirm_label = cls._non_empty_str(raw_widget.get("confirm_label")) or "确认"
            cancel_label = cls._non_empty_str(raw_widget.get("cancel_label")) or "取消"
            normalized["confirm_label"] = confirm_label[:24]
            normalized["cancel_label"] = cancel_label[:24]
            normalized["confirm_reply"] = (
                cls._non_empty_str(raw_widget.get("confirm_reply")) or confirm_label
            )[:80]
            normalized["cancel_reply"] = (
                cls._non_empty_str(raw_widget.get("cancel_reply")) or cancel_label
            )[:80]
        elif kind == "picker":
            options = raw_widget.get("options")
            if not isinstance(options, list) or not (1 <= len(options) <= 12):
                raise SendMessageValidationError(
                    "SendMessage 校验失败：picker 类型的 widget 必须提供 1..12 项 options 列表。"
                )
            norm_opts: list[dict[str, str]] = []
            for idx, opt in enumerate(options):
                if isinstance(opt, str) and opt.strip():
                    label = opt.strip()[:60]
                    norm_opts.append({"id": f"opt-{idx + 1}", "label": label, "value": label})
                elif isinstance(opt, dict) and cls._non_empty_str(opt.get("label")):
                    label = cls._non_empty_str(opt.get("label"))[:60]
                    val = (cls._non_empty_str(opt.get("value")) or label)[:120]
                    opt_id = (cls._non_empty_str(opt.get("id")) or f"opt-{idx + 1}")[:40]
                    norm_opts.append({"id": opt_id, "label": label, "value": val})
                else:
                    raise SendMessageValidationError(
                        "SendMessage 校验失败：picker.options 每项必须是非空字符串或包含 label 的对象。"
                    )
            normalized["options"] = norm_opts
        elif kind == "checklist":
            items = raw_widget.get("items")
            if not isinstance(items, list) or not (1 <= len(items) <= 20):
                raise SendMessageValidationError(
                    "SendMessage 校验失败：checklist 类型的 widget 必须提供 1..20 项 items 列表。"
                )
            norm_items: list[dict[str, Any]] = []
            for idx, item in enumerate(items):
                if isinstance(item, str) and item.strip():
                    norm_items.append({"id": f"item-{idx + 1}", "label": item.strip()[:120], "checked": False})
                elif isinstance(item, dict) and cls._non_empty_str(item.get("label") or item.get("text")):
                    label = cls._non_empty_str(item.get("label") or item.get("text"))[:120]
                    norm_items.append({
                        "id": (cls._non_empty_str(item.get("id")) or f"item-{idx + 1}")[:40],
                        "label": label,
                        "checked": bool(item.get("checked", False)),
                    })
                else:
                    raise SendMessageValidationError(
                        "SendMessage 校验失败：checklist.items 每项必须是非空字符串或包含 label 的对象。"
                    )
            normalized["items"] = norm_items
        elif kind == "form":
            fields = raw_widget.get("fields")
            if not isinstance(fields, list) or not (1 <= len(fields) <= 10):
                raise SendMessageValidationError(
                    "SendMessage 校验失败：form 类型的 widget 必须提供 1..10 项 fields 列表。"
                )
            norm_fields: list[dict[str, Any]] = []
            for fld in fields:
                if not isinstance(fld, dict):
                    raise SendMessageValidationError("SendMessage 校验失败：form.fields 每项必须是对象。")
                fname = cls._non_empty_str(fld.get("name"))
                flabel = cls._non_empty_str(fld.get("label")) or fname
                if not fname:
                    raise SendMessageValidationError("SendMessage 校验失败：form.fields 每项必须包含非空 name。")
                norm_fields.append({
                    "name": fname[:48],
                    "label": flabel[:60],
                    "required": bool(fld.get("required", True)),
                    "placeholder": cls._non_empty_str(fld.get("placeholder"))[:100],
                })
            normalized["fields"] = norm_fields

        blocking = bool(raw_widget.get("blocking", True))
        return normalized, blocking

    @classmethod
    def validate(
        cls,
        args: dict[str, Any],
        *,
        cas: ContentAddressedStore | None = None,
    ) -> ValidatedBubble:
        if not isinstance(args, dict):
            raise SendMessageValidationError("SendMessage 校验失败：参数必须是 JSON 对象。")
        raw_type = args.get("type")
        if not isinstance(raw_type, str) or not raw_type.strip():
            raise SendMessageValidationError(
                "SendMessage 校验失败：缺少必填字段 type（可选值：text | attachment | widget | secret-request）。"
            )
        bubble_type = raw_type.strip()
        if bubble_type == "cursor-agent":
            raise SendMessageValidationError(
                "SendMessage 校验失败：type='cursor-agent' 当前阶段未启用；请改用 text | attachment | widget | secret-request。"
            )
        if bubble_type not in ALLOWED_BUBBLE_TYPES:
            raise SendMessageValidationError(
                f"SendMessage 校验失败：未知的 type={bubble_type!r}，仅允许 text | attachment | widget | secret-request。"
            )

        for forbidden_secret_key in ("secret_value", "secret", "api_key", "password", "token_value"):
            if args.get(forbidden_secret_key):
                raise SendMessageValidationError(
                    f"SendMessage 校验失败：严禁在消息参数中传入明文密钥字段 {forbidden_secret_key!r}。"
                )

        if bubble_type == "text":
            if cls._non_empty_str(args.get("url")):
                raise SendMessageValidationError(
                    "SendMessage 校验失败：type='text' 不能混带 url；发文件或链接附件请单独调用 type='attachment'。"
                )
            if args.get("widget") is not None:
                raise SendMessageValidationError(
                    "SendMessage 校验失败：type='text' 不能混带 widget；发交互组件请单独调用 type='widget'。"
                )
            if cls._non_empty_str(args.get("secret_name")):
                raise SendMessageValidationError(
                    "SendMessage 校验失败：type='text' 不能混带 secret_name；请求密钥请调用 type='secret-request'。"
                )
            raw_content = args.get("content")
            if not isinstance(raw_content, str) or not raw_content.strip():
                raise SendMessageValidationError(
                    "SendMessage 校验失败：type='text' 必须提供非空的 content 字符串。"
                )
            content = raw_content.strip()
            if len(content) > MAX_TEXT_CHARS:
                raise SendMessageValidationError(
                    f"SendMessage 校验失败：content 长度不能超过 {MAX_TEXT_CHARS} 字，长文档请写入文件后用 type='attachment' 发送。"
                )

            raw_images = args.get("images")
            image_entries: list[dict[str, Any]] = []
            local_files: list[dict[str, Any]] = []
            if raw_images is not None and raw_images != []:
                if not isinstance(raw_images, list) or len(raw_images) > 9:
                    raise SendMessageValidationError(
                        "SendMessage 校验失败：images 必须是最多 9 项的图片 URI 列表。"
                    )
                for img_uri in raw_images:
                    clean_uri, scheme = cls._validate_uri_scheme(img_uri, field_name="images[]")
                    if scheme == "file":
                        if cas is None:
                            raise SendMessageValidationError("本地图片存储未初始化")
                        ingested = cas.ingest_local_file(clean_uri, require_image=True)
                        local_files.append(ingested)
                        image_entries.append({
                            "url": ingested["url"],
                            "scheme": "file",
                            "name": ingested["name"],
                            "mime": ingested["mime"],
                            "size": ingested["size"],
                            "sha256": ingested["sha256"],
                            "cas_relpath": ingested["cas_relpath"],
                        })
                    else:
                        parsed = urlparse(clean_uri)
                        image_entries.append({
                            "url": clean_uri,
                            "scheme": "https",
                            "name": Path(unquote(parsed.path)).name or parsed.netloc,
                        })

            suggestions = cls._validate_suggestions(args.get("suggestions"))
            bubble = {
                "type": "text",
                "content": content,
                "images": image_entries,
                "suggestions": suggestions,
            }
            return ValidatedBubble(
                bubble_type="text",
                text=content,
                bubble=bubble,
                suggestions=suggestions,
                local_files=local_files,
                blocks_turn=False,
            )

        if bubble_type == "attachment":
            if cls._non_empty_str(args.get("content")):
                raise SendMessageValidationError(
                    "SendMessage 校验失败：type='attachment' 禁止传 content（切勿把文件内容塞进消息正文）；请提供合法的 file:// 或 https:// url，简短说明填 caption（≤240字）。"
                )
            if args.get("widget") is not None or cls._non_empty_str(args.get("secret_name")):
                raise SendMessageValidationError(
                    "SendMessage 校验失败：type='attachment' 不能混带 widget 或 secret_name。"
                )
            url, scheme = cls._validate_uri_scheme(args.get("url"), field_name="url")
            caption = cls._non_empty_str(args.get("caption"))
            if len(caption) > MAX_CAPTION_CHARS:
                raise SendMessageValidationError(
                    f"SendMessage 校验失败：attachment.caption 不能超过 {MAX_CAPTION_CHARS} 字。"
                )
            local_files = []
            if scheme == "file":
                if cas is None:
                    raise SendMessageValidationError("本地附件存储未初始化")
                ingested = cas.ingest_local_file(url, require_image=False)
                local_files.append(ingested)
                bubble = {
                    "type": "attachment",
                    "url": ingested["url"],
                    "scheme": "file",
                    "caption": caption,
                    "name": ingested["name"],
                    "mime": ingested["mime"],
                    "size": ingested["size"],
                    "sha256": ingested["sha256"],
                    "cas_relpath": ingested["cas_relpath"],
                }
                fallback_text = caption or f"已附上文件：{ingested['name']}"
            else:
                parsed = urlparse(url)
                name = Path(unquote(parsed.path)).name or parsed.netloc
                mime = mimetypes.guess_type(name)[0] or "text/uri-list"
                bubble = {
                    "type": "attachment",
                    "url": url,
                    "scheme": "https",
                    "caption": caption,
                    "name": name,
                    "mime": mime,
                }
                fallback_text = f"{caption}\n{url}".strip() if caption else url

            return ValidatedBubble(
                bubble_type="attachment",
                text=fallback_text,
                bubble=bubble,
                local_files=local_files,
                blocks_turn=False,
            )

        if bubble_type == "widget":
            if cls._non_empty_str(args.get("url")) or cls._non_empty_str(args.get("secret_name")):
                raise SendMessageValidationError(
                    "SendMessage 校验失败：type='widget' 不能混带 url 或 secret_name。"
                )
            normalized_widget, blocking = cls._validate_widget(args.get("widget"))
            lead = cls._non_empty_str(args.get("content"))
            if len(lead) > MAX_WIDGET_LEAD_CHARS:
                raise SendMessageValidationError(
                    f"SendMessage 校验失败：widget 引导文案 content 不能超过 {MAX_WIDGET_LEAD_CHARS} 字。"
                )
            suggestions: list[str] = []
            if normalized_widget["kind"] == "confirm":
                suggestions = [normalized_widget["confirm_reply"], normalized_widget["cancel_reply"]][:4]
            elif normalized_widget["kind"] == "picker":
                suggestions = [opt["label"][:24] for opt in normalized_widget["options"][:4]]
            bubble = {
                "type": "widget",
                "content": lead,
                "blocking": blocking,
                "widget": normalized_widget,
            }
            return ValidatedBubble(
                bubble_type="widget",
                text=lead or normalized_widget["title"],
                bubble=bubble,
                suggestions=suggestions,
                widgets=[normalized_widget],
                blocks_turn=blocking,
            )

        # bubble_type == "secret-request"
        if cls._non_empty_str(args.get("url")) or args.get("widget") is not None or cls._non_empty_str(args.get("content")):
            raise SendMessageValidationError(
                "SendMessage 校验失败：type='secret-request' 只能传 secret_name / reason / target_env / placeholder，禁止混带 content / url / widget。"
            )
        secret_name = cls._non_empty_str(args.get("secret_name"))
        if not SECRET_NAME_RE.fullmatch(secret_name):
            raise SendMessageValidationError(
                "SendMessage 校验失败：secret_name 必填且只能包含字母、数字、下划线、点或连字符（如 NOTION_API_KEY）。"
            )
        reason = cls._non_empty_str(args.get("reason"))
        if not reason or len(reason) > MAX_SECRET_REASON_CHARS:
            raise SendMessageValidationError(
                f"SendMessage 校验失败：secret-request 必须提供 1..{MAX_SECRET_REASON_CHARS} 字的用途说明 reason。"
            )
        target_env = cls._non_empty_str(args.get("target_env"))[:120]
        placeholder = cls._non_empty_str(args.get("placeholder"))[:80]
        bubble = {
            "type": "secret-request",
            "secret_name": secret_name,
            "reason": reason,
            "target_env": target_env,
            "placeholder": placeholder,
            "masked": True,
        }
        fallback_text = (
            f"需要配置密钥 {secret_name}：{reason}（请在安全凭据入口填写，勿在普通聊天框直接粘贴明文密钥）"
        )
        return ValidatedBubble(
            bubble_type="secret-request",
            text=fallback_text,
            bubble=bubble,
            blocks_turn=True,
        )


def install_send_message_schema(db: sqlite3.Connection) -> None:
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS send_message_turns(
            turn_message_id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            state TEXT NOT NULL,
            awaiting_reason TEXT,
            bubble_count INTEGER NOT NULL DEFAULT 0,
            non_send_tool_streak INTEGER NOT NULL DEFAULT 0,
            reminder_count INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS turn_thinking_logs(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            run_id TEXT,
            step_index INTEGER NOT NULL DEFAULT 0,
            content TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_turn_thinking_message
            ON turn_thinking_logs(message_id, id);
        """
    )


class SendMessageStore:
    """持久化会话状态机、工具静默计数器与内部思考日志。"""

    def __init__(self, db_path: Path):
        self.db_path = Path(db_path)

    @contextmanager
    def _db(self):
        db = sqlite3.connect(self.db_path, timeout=20)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def open_turn(self, mid: str, session_id: str, request_id: str) -> None:
        now = time.time()
        with self._db() as db:
            install_send_message_schema(db)
            db.execute(
                """
                INSERT INTO send_message_turns(
                    turn_message_id, session_id, request_id, state, awaiting_reason,
                    bubble_count, non_send_tool_streak, reminder_count, updated_at
                ) VALUES (?, ?, ?, 'working', NULL, 0, 0, 0, ?)
                ON CONFLICT(turn_message_id) DO UPDATE SET
                    session_id = excluded.session_id,
                    request_id = excluded.request_id,
                    state = 'working',
                    awaiting_reason = NULL,
                    non_send_tool_streak = 0,
                    updated_at = excluded.updated_at
                """,
                (mid, session_id, request_id, now),
            )

    def get_turn(self, mid: str) -> dict[str, Any] | None:
        with self._db() as db:
            row = db.execute(
                "SELECT * FROM send_message_turns WHERE turn_message_id=?",
                (mid,),
            ).fetchone()
        return dict(row) if row else None

    def bubble_count(self, mid: str) -> int:
        turn = self.get_turn(mid)
        return int(turn["bubble_count"]) if turn else 0

    def commit_bubble_in_tx(
        self,
        db: sqlite3.Connection,
        mid: str,
        *,
        session_id: str,
        request_id: str,
        bubble_type: str,
        blocks_turn: bool,
    ) -> dict[str, Any]:
        now = time.time()
        row = db.execute(
            "SELECT * FROM send_message_turns WHERE turn_message_id=?",
            (mid,),
        ).fetchone()
        if row is None:
            db.execute(
                """
                INSERT INTO send_message_turns(
                    turn_message_id, session_id, request_id, state, awaiting_reason,
                    bubble_count, non_send_tool_streak, reminder_count, updated_at
                ) VALUES (?, ?, ?, 'working', NULL, 0, 0, 0, ?)
                """,
                (mid, session_id, request_id, now),
            )
            row = db.execute(
                "SELECT * FROM send_message_turns WHERE turn_message_id=?",
                (mid,),
            ).fetchone()

        state = row["state"]
        reason = row["awaiting_reason"] or ""
        if state == "awaiting_user":
            raise SendMessageStateError(
                f"SendMessage 被拒绝：当前会话已发出 {reason or '交互请求'} 并在等待用户响应（state=awaiting_user）。"
                "请立即停止本轮输出与后续 send_message 调用，等用户下一条回复后再继续。"
            )
        if state == "closed":
            raise SendMessageStateError(
                "SendMessage 被拒绝：当前对话回合已结束（state=closed），不能再追加气泡。"
            )

        new_state = "awaiting_user" if blocks_turn else "working"
        new_reason = bubble_type if blocks_turn else None
        new_count = int(row["bubble_count"]) + 1
        db.execute(
            """
            UPDATE send_message_turns
            SET state=?, awaiting_reason=?, bubble_count=?, non_send_tool_streak=0, updated_at=?
            WHERE turn_message_id=?
            """,
            (new_state, new_reason, new_count, now, mid),
        )
        return {
            "turn_message_id": mid,
            "state": new_state,
            "awaiting_reason": new_reason,
            "bubble_count": new_count,
            "non_send_tool_streak": 0,
        }

    def resume_on_user_input(self, mid: str) -> None:
        now = time.time()
        with self._db() as db:
            db.execute(
                """
                UPDATE send_message_turns
                SET state='working', awaiting_reason=NULL, non_send_tool_streak=0, updated_at=?
                WHERE turn_message_id=? AND state!='closed'
                """,
                (now, mid),
            )

    def note_silent_tool(self, mid: str, *, threshold: int) -> bool:
        """记录一次非 send_message 工具完成；若达到阈值且仍在 working 态则触发一次催报并清零计数。"""
        now = time.time()
        with self._db() as db:
            row = db.execute(
                "SELECT state, non_send_tool_streak, reminder_count FROM send_message_turns WHERE turn_message_id=?",
                (mid,),
            ).fetchone()
            if not row or row["state"] != "working":
                return False
            streak = int(row["non_send_tool_streak"]) + 1
            if streak >= threshold:
                db.execute(
                    """
                    UPDATE send_message_turns
                    SET non_send_tool_streak=0, reminder_count=?, updated_at=?
                    WHERE turn_message_id=?
                    """,
                    (int(row["reminder_count"]) + 1, now, mid),
                )
                return True
            db.execute(
                "UPDATE send_message_turns SET non_send_tool_streak=?, updated_at=? WHERE turn_message_id=?",
                (streak, now, mid),
            )
            return False

    def close_turn(self, mid: str) -> None:
        now = time.time()
        with self._db() as db:
            db.execute(
                "UPDATE send_message_turns SET state='closed', updated_at=? WHERE turn_message_id=?",
                (now, mid),
            )

    def record_thinking(
        self,
        mid: str,
        request_id: str,
        content: str,
        *,
        run_id: str | None = None,
        step_index: int = 0,
    ) -> None:
        cleaned = (content or "").strip()
        if not cleaned:
            return
        with self._db() as db:
            db.execute(
                """
                INSERT INTO turn_thinking_logs(message_id, request_id, run_id, step_index, content, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (mid, request_id, run_id, step_index, cleaned[:16000], time.time()),
            )

    def thinking_logs(self, mid: str) -> list[dict[str, Any]]:
        with self._db() as db:
            rows = db.execute(
                "SELECT id, message_id, request_id, run_id, step_index, content, created_at "
                "FROM turn_thinking_logs WHERE message_id=? ORDER BY id ASC",
                (mid,),
            ).fetchall()
        return [dict(r) for r in rows]


def build_turn_reminder(*, is_supplement: bool = False) -> str:
    """每次追加在 user turn 末尾的 <system_reminder>（不占 SYSTEM_PROMPT）。"""
    prefix = (
        "Eddie 在你处理中途刚追发了上面这条新消息，请在下个 step 一并纳入处理并通过 send_message 回应。\n"
        if is_supplement
        else ""
    )
    return (
        "<system_reminder>\n"
        f"{prefix}"
        "【消息发送机制（硬规则）】\n"
        "1. 你的普通文本输出只是内部思考，Eddie 手机上完全看不到。所有给 Eddie 看的回复必须调用工具 `mcp__com_workbench__send_message`（可直接通过 `tool_call(calls=[{\"name\":\"mcp__com_workbench__send_message\",\"arguments\":{...}}])` 或 `send_message` 调用，无需先 tool_search）。\n"
        "2. 边干边报节奏：\n"
        "   - 只要本轮需要调任何业务/查询/文件工具，第一步必须在同一轮响应里【同时】发起一次简短 `send_message(type=\"text\", content=\"...\")`（1句话确认收到或正去查什么）和第一个工作工具调用，绝不等工具跑完才回话；\n"
        "   - 多步执行中途若有阶段性发现或切换动作，再发一条简短进度气泡；无需调工具的一句话问答只调一次 `send_message` 直接给结果，不拆废话双气泡；\n"
        "   - 发出最终结果气泡后立刻停止本轮，不要再输出重复文本或重复调用 `send_message`。\n"
        "3. 类型与状态约束：\n"
        "   - `type=\"text\"` 必填 `content`（可选 `images`、`suggestions`）；\n"
        "   - `type=\"attachment\"` 必填 `file://` 或 `https://` 的 `url`（可选 `caption`），严禁把文件内容贴进正文；\n"
        "   - `type=\"widget\"` 必填 `widget={kind:\"confirm|picker|checklist|form\", title,...}`，`type=\"secret-request\"` 必填 `secret_name` 与 `reason`；这两类发出后即进入等待用户状态，本轮严禁再调 `send_message`。\n"
        "</system_reminder>"
    )


def build_progress_reminder(streak: int) -> str:
    """连续 N 次非 send_message 工具调用未汇报进度时注入的中间件提醒。"""
    return (
        "<system_reminder>\n"
        f"你已连续执行 {streak} 次工具调用而未向 Eddie 同步进展。下一步请真正发起一次 `mcp__com_workbench__send_message`（type=\"text\"）用一句话交代当前进展或查到的关键结果，同时继续后续操作（必须真正发起工具调用，不要在普通文本里假装已回复）。\n"
        "</system_reminder>"
    )


def build_repair_reminder() -> str:
    """当模型整轮只输出了内部思考文本、0 次调用 send_message 时触发的单次自愈提醒。"""
    return (
        "<system_reminder>\n"
        "你刚才只输出了内部思考文本，尚未调用 `mcp__com_workbench__send_message`，Eddie 手机上什么都没看到。请立即调用一次 `send_message` 把最终答复发给 Eddie，发完后立刻结束本轮。\n"
        "</system_reminder>"
    )
