"""Model-facing constrained input schema, outbound staging hard gate, and stale task archival."""
from __future__ import annotations

import json
import os
import re
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any

from operation_policy import POLICY_REVISION, effective_sandbox, full_access_enabled

OUTBOUND_ACTION_TYPES = ("email_send", "labor_submit", "content_publish")

_ALWAYS_SAFE_TOOLS = frozenset(
    {
        "bookkeeping",
        "bookkeeping_search",
        "calendar_read",
        "calendar_adjust",
        "calendar_event",
        "remind",
        "collect",
        "memory_recall",
        "memory_save",
        "context_read",
        "capability_search",
        "task_status",
        "goal_status",
        "personal_briefing",
        "briefing_refresh",
        "briefing_annotate",
        "matter_link",
        "matter_unlink",
        "personal_observation",
        "wechat_query",
        "read",
        "grep",
        "glob",
        "ls",
        "loaded",
        "tool_result",
        "case_progress",
        "turn_plan",
        "decision_record",
        "artifact_register",
        "react_to_user_message",
        "archive_path",
    }
)

_SAFE_ACTION_MODES = frozenset(
    {
        "draft",
        "create_draft",
        "save_draft",
        "update_draft",
        "prepare",
        "fill",
        "fill_form",
        "preview",
        "dry_run",
        "dry-run",
        "list",
        "get",
        "read",
        "search",
        "query",
        "status",
        "check",
        "inspect",
        "fetch",
        "download",
    }
)

_STOP_BEFORE_SUBMIT_RE = re.compile(
    r"停在(?:最后一步)?(?:提交|发送|发布)?按钮前|停在最后一步|严禁直接点击|禁止最终点击|"
    r"只填(?:好|单|表)?不(?:提交|发送|发布)|先不(?:发|提交|发布)|不要(?:发送|提交|发布)|"
    r"--dry-run\b|\bdry[_-]run\b",
    re.I,
)

_DRAFT_OR_QUERY_ONLY_RE = re.compile(
    r"(?:起草|拟好|写好|生成|保存|创建|修改).{0,10}草稿|草稿箱|\bdrafts?\b|"
    r"填表准备|自动填单|只填好|(?:查询?|查看|读取|检索|搜索|看下|看看).{0,10}(?:邮件|劳务|报销|进度|状态|配额)",
    re.I,
)

_EXPLICIT_FINAL_SEND_RE = re.compile(
    r"(?:立即|直接|正式|点击|确认)(?:发送|发出|提交|打款|发布|发表|群发)|"
    r"--(?:send|submit|publish)\b",
    re.I,
)

_EMAIL_TOOL_NAMES = frozenset(
    {"email_send", "send_email", "gmail_send", "mail_send", "smtp_send", "gmail.send", "mail.send", "sohu_mail.send"}
)
_LABOR_TOOL_NAMES = frozenset(
    {
        "labor_submit",
        "sohu_labor_submit",
        "payment_submit",
        "expense_submit",
        "reimbursement_submit",
        "pr_submit",
        "sohu_pr.submit",
        "labor.submit",
        "expense.submit",
    }
)
_PUBLISH_TOOL_NAMES = frozenset(
    {
        "content_publish",
        "video_publish",
        "channels_publish",
        "sohu_publish",
        "sohu_repost_submit",
        "publish_post",
        "publish_video",
        "wechat_channels.publish",
        "sohu_video.publish",
        "sohu_follow.publish",
        "xiaohongshu.publish",
        "douyin.publish",
    }
)

_FINAL_EMAIL_CMD_RE = re.compile(
    r"gws\s+gmail\b.*?(?:\+send|\bsend\b|发送)|"
    r"gmail[\s._/-]*(?:users[\s._/-]*messages[\s._/-]*)?send\b|"
    r"\bsendmail\b|\bsmtp[_\s.-]*send\b|"
    r"(?:点击|直接|立即|正式)(?:发送|寄出).{0,16}(?:邮件|email|mail)|"
    r"(?:发送|寄出)外部邮件",
    re.I,
)
_FINAL_LABOR_CMD_RE = re.compile(
    r"(?:点击|直接|立即|正式|确认)(?:提交|申报|发起).{0,20}(?:搜狐\s*PR|PR\s*系统|劳务(?:费|报酬|单|付款)?|报销(?:单|申请)?)|"
    r"(?:劳务(?:费|报酬|单|付款)?|报销(?:单|申请)?|pr\.sohu\.com).{0,20}(?:点击提交|直接提交|正式提交|确认提交|\bsubmit\b)|"
    r"\b(?:sohu[_-]?labor|labor[_-]?pay|sohu[_-]?pr|reimbursement)[_.-]*submit\b",
    re.I,
)
_FINAL_PUBLISH_CMD_RE = re.compile(
    r"(?:点击|直接|立即|正式)(?:发布|发表|群发|投递|上线).{0,24}(?:视频号|关注流|搜狐(?:视频)?|小红书|抖音|B站|bilibili|微博|公众号|成片|视频|动态)|"
    r"(?:视频号|关注流|搜狐(?:视频)?|小红书|抖音|B站|微博|公众号).{0,20}(?:点击发布|点击发表|直接发布|正式发布|立即发布|\bpublish\b)|"
    r"--publish\b",
    re.I,
)


def _infer_target_url(action_type: str, args: dict[str, Any], blob: str) -> str:
    for key in ("target_url", "url", "page_url", "review_url", "draft_url"):
        val = str(args.get(key) or "").strip()
        if val.startswith(("http://", "https://")):
            return val
    low = blob.lower()
    if action_type == "email_send":
        if "sohu" in low or "搜狐邮箱" in blob:
            return "https://mail.sohu.com/"
        return "https://mail.google.com/"
    if action_type == "labor_submit":
        return "https://pr.sohu.com/"
    if "关注流" in blob or "tv.sohu" in low or "搜狐" in blob:
        return "https://tv.sohu.com/s/follow"
    if "小红书" in blob or "xiaohongshu" in low:
        return "https://creator.xiaohongshu.com/"
    if "抖音" in blob or "douyin" in low:
        return "https://creator.douyin.com/"
    return "https://channels.weixin.qq.com/"


def build_staging_review_widget(
    *,
    action_type: str,
    title: str,
    summary: str,
    target_url: str = "",
    staging_id: str = "",
    confirm_label: str = "打开页面我去点",
    cancel_label: str = "打回重改",
) -> dict[str, Any]:
    if action_type not in OUTBOUND_ACTION_TYPES:
        raise ValueError(f"Unsupported staging action_type: {action_type}")
    widget: dict[str, Any] = {
        "kind": "staging_review",
        "title": str(title or "").strip()[:120] or "外发内容已就绪，请人工确认点击",
        "summary": str(summary or "").strip()[:400] or "参数已暂存，系统已按规则停在最终按钮前。",
        "action_type": action_type,
        "confirm_label": str(confirm_label or "打开页面我去点").strip()[:40],
        "cancel_label": str(cancel_label or "打回重改").strip()[:40],
        "target_url": str(target_url or "").strip(),
    }
    if staging_id:
        widget["staging_id"] = staging_id
    return widget


def classify_outbound_action(
    tool: str,
    args: dict[str, Any] | None = None,
    *,
    description: str = "",
) -> dict[str, Any] | None:
    """确定性识别三类必须「停在按钮前」的高危最终外发动作；草稿/填表/dry-run/查询/日常工具一律放行。"""
    params = dict(args or {}) if isinstance(args, dict) else {}
    tool_norm = str(tool or "").strip().lower()
    if not tool_norm or tool_norm in _ALWAYS_SAFE_TOOLS:
        return None

    # Unwrap nested business_call / personal_autonomy / device_call envelopes
    if tool_norm in ("business_call", "personal_autonomy", "device_call") and isinstance(params.get("tool"), str):
        inner_tool = str(params.get("tool") or "").strip()
        inner_args = params.get("args") if isinstance(params.get("args"), dict) else {k: v for k, v in params.items() if k != "tool"}
        nested = classify_outbound_action(
            inner_tool,
            inner_args,
            description=f"{description} {params.get('reason', '')}".strip(),
        )
        if nested is not None:
            return nested

    # Explicit safe flags always pass through
    if any(bool(params.get(flag)) is True for flag in ("dry_run", "draft", "is_draft", "prepare_only", "stop_before_submit", "preview_only")):
        return None
    action_mode = str(params.get("action") or params.get("mode") or params.get("operation") or "").strip().lower()
    if action_mode in _SAFE_ACTION_MODES:
        return None

    serialized = json.dumps(params, ensure_ascii=False, default=str)
    blob = f"{tool_norm} {description} {serialized}".strip()
    if _STOP_BEFORE_SUBMIT_RE.search(blob):
        return None

    action_type = ""
    if tool_norm in _EMAIL_TOOL_NAMES or tool_norm.endswith((".send_email", "mail.send", "gmail.send")):
        action_type = "email_send"
    elif tool_norm in _LABOR_TOOL_NAMES or tool_norm.endswith(("labor.submit", "expense.submit", "pr.submit", "reimbursement.submit")):
        action_type = "labor_submit"
    elif tool_norm in _PUBLISH_TOOL_NAMES or (
        tool_norm.endswith(".publish") and any(k in tool_norm for k in ("video", "channel", "sohu", "post", "content", "douyin", "xhs", "xiaohongshu"))
    ):
        action_type = "content_publish"
    elif tool_norm in ("email", "mail", "gmail", "sohu_mail") and action_mode in ("send", "send_now", "deliver", "reply_and_send"):
        action_type = "email_send"
    elif tool_norm in ("sohu_labor", "labor_pay", "sohu_pr", "reimbursement", "expense", "payment") and action_mode in (
        "submit",
        "confirm_submit",
        "final_submit",
        "pay",
    ):
        action_type = "labor_submit"
    elif tool_norm in (
        "wechat_channels",
        "channels",
        "sohu_video",
        "sohu_follow",
        "sohu_repost",
        "douyin",
        "xiaohongshu",
        "bilibili",
        "weibo",
    ) and action_mode in ("publish", "post", "repost_now", "submit", "submit_publish", "final_publish"):
        action_type = "content_publish"
    else:
        if _DRAFT_OR_QUERY_ONLY_RE.search(blob) and not _EXPLICIT_FINAL_SEND_RE.search(blob):
            return None
        if _FINAL_EMAIL_CMD_RE.search(blob):
            action_type = "email_send"
        elif _FINAL_LABOR_CMD_RE.search(blob):
            action_type = "labor_submit"
        elif _FINAL_PUBLISH_CMD_RE.search(blob):
            action_type = "content_publish"

    if not action_type:
        return None

    target_url = _infer_target_url(action_type, params, blob)
    if action_type == "email_send":
        recipient = str(params.get("to") or params.get("recipient") or "收件人").strip()
        subject = str(params.get("subject") or params.get("title") or "外部邮件").strip()
        title = f"邮件已备好 · 待你点击发送（{subject[:36]}）"
        summary = f"收件人：{recipient[:60]}｜主题：{subject[:80]}。系统已拦截自动外发，请打开邮箱页面人工复核后点击发送。"
    elif action_type == "labor_submit":
        payee = str(params.get("guest") or params.get("payee") or params.get("name") or params.get("applicant") or "收款人").strip()
        amount = params.get("amount") or params.get("total") or ""
        amt_str = f" · ¥{amount}" if amount != "" else ""
        title = f"劳务/报销单已就绪 · 待你点击提交（{payee[:24]}{amt_str}）"
        summary = f"单据对象：{payee[:40]}{amt_str}。表单参数已暂存，系统严格停在提交按钮前，请打开搜狐 PR 页面核对后本人点击提交。"
    else:
        platform = str(params.get("platform") or ("关注流" if "关注流" in blob or "sohu" in blob.lower() else "视频号")).strip()
        headline = str(params.get("title") or params.get("caption") or params.get("text") or "待发布内容").strip()
        title = f"{platform}内容已就绪 · 待你点击发布"
        summary = f"标题/文案：{headline[:90]}。系统已拦截自动最终发布，请打开平台页面复核封面与文案后本人点击发布。"

    return {
        "action_type": action_type,
        "title": title,
        "summary": summary,
        "target_url": target_url,
    }


def _persist_staged_outbound(
    state_dir: Path,
    *,
    action_type: str,
    tool: str,
    title: str,
    summary: str,
    target_url: str,
    payload: dict[str, Any],
) -> str:
    state_dir.mkdir(parents=True, exist_ok=True)
    db_path = state_dir / "business-operations.sqlite"
    staging_id = "stg_" + uuid.uuid4().hex[:20]
    now = time.time()
    conn = sqlite3.connect(db_path, timeout=10)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        with conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS staged_outbound_actions(
                    id TEXT PRIMARY KEY,
                    action_type TEXT NOT NULL,
                    tool TEXT NOT NULL,
                    title TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    target_url TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'staged',
                    created_at REAL NOT NULL
                )
                """
            )
            conn.execute(
                "INSERT INTO staged_outbound_actions(id,action_type,tool,title,summary,target_url,payload,status,created_at) "
                "VALUES(?,?,?,?,?,?,?,'staged',?)",
                (
                    staging_id,
                    action_type,
                    str(tool or ""),
                    title,
                    summary,
                    target_url,
                    json.dumps(payload, ensure_ascii=False, default=str),
                    now,
                ),
            )
    finally:
        conn.close()
    try:
        os.chmod(db_path, 0o600)
    except OSError:
        pass
    return staging_id


def emit_staging_bubble(
    conversation: Any,
    *,
    widget: dict[str, Any],
    content: str = "",
    parent_message_id: str = "",
) -> str:
    """将 staging_review 卡片直接作为 assistant widget 气泡写入主对话（兼容现有 conversation 投影）。"""
    if conversation is None or not hasattr(conversation, "db"):
        return ""
    lead_text = str(content or "").strip() or f"已为你准备就绪并停在按钮前：{widget.get('title', '')}"
    bubble_id = "msg_stg_" + uuid.uuid4().hex[:20]
    bubble_obj = {
        "type": "widget",
        "content": lead_text,
        "blocking": True,
        "widget": widget,
    }
    now = time.time()
    try:
        with conversation.db() as db:
            root_mid = str(parent_message_id or "").strip()
            parent_channel = "personal"
            if root_mid:
                urow = db.execute(
                    "SELECT id, channel FROM messages WHERE id=?",
                    (root_mid,),
                ).fetchone()
                if urow and "channel" in urow.keys() and urow["channel"]:
                    parent_channel = str(urow["channel"])
            else:
                urow = db.execute(
                    "SELECT id, channel FROM messages WHERE role='user' ORDER BY created_at DESC LIMIT 1"
                ).fetchone()
                if urow:
                    root_mid = str(urow["id"])
                    if "channel" in urow.keys() and urow["channel"]:
                        parent_channel = str(urow["channel"])
            seq = conversation._next_seq(db) if hasattr(conversation, "_next_seq") else 0
            revision = conversation._bump(db) if hasattr(conversation, "_bump") else 1
            db.execute(
                "INSERT INTO messages("
                "id,parent_id,role,text,status,phase,revision,created_at,updated_at,"
                "suggestions,artifacts,message_seq,bubble_type,bubble_payload,channel"
                ") VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    bubble_id,
                    root_mid or None,
                    "assistant",
                    lead_text,
                    "completed",
                    "completed",
                    revision,
                    now,
                    now,
                    json.dumps([widget["confirm_label"], widget["cancel_label"]], ensure_ascii=False),
                    "[]",
                    seq,
                    "widget",
                    json.dumps(bubble_obj, ensure_ascii=False),
                    parent_channel,
                ),
            )
        if hasattr(conversation, "_notify"):
            conversation._notify()
        return bubble_id
    except Exception:
        return ""


def stage_outbound_action(
    state: Path | str,
    *,
    tool: str,
    args: dict[str, Any] | None = None,
    context: dict[str, Any] | None = None,
    conversation: Any = None,
    description: str = "",
) -> dict[str, Any] | None:
    """若命中外发硬闸门，写入 business-operations.sqlite 暂存表并产出 staging_review widget，绝不直接执行最终外发。"""
    matched = classify_outbound_action(tool, args, description=description)
    if matched is None:
        return None
    state_dir = Path(state)
    staging_id = _persist_staged_outbound(
        state_dir,
        action_type=matched["action_type"],
        tool=tool,
        title=matched["title"],
        summary=matched["summary"],
        target_url=matched["target_url"],
        payload={"tool": tool, "args": args or {}, "context": context or {}, "description": description},
    )
    widget = build_staging_review_widget(
        action_type=matched["action_type"],
        title=matched["title"],
        summary=matched["summary"],
        target_url=matched["target_url"],
        staging_id=staging_id,
    )
    parent_mid = str((context or {}).get("origin_message_id") or "")
    bubble_mid = emit_staging_bubble(
        conversation,
        widget=widget,
        content=f"已准备就绪并停在按钮前：{matched['title']}",
        parent_message_id=parent_mid,
    )
    return {
        "ok": True,
        "authorized": False,
        "staged": True,
        "blocked": True,
        "executed": False,
        "status": "staged_before_submit",
        "staging_id": staging_id,
        "action_type": matched["action_type"],
        "message_id": bubble_mid,
        "widget": widget,
        "bubble": {
            "type": "widget",
            "content": f"已准备就绪并停在按钮前：{matched['title']}",
            "blocking": True,
            "widget": widget,
        },
    }


def archive_stale_tasks(
    store_or_state: Any = None,
    days: float = 7,
    *,
    now: float | None = None,
) -> dict[str, Any]:
    """归档超过 days 天无人验收的 waiting/unknown/execution_finished 历史僵尸单（记 archived_stale 事件并置 dismissed，不删行）。"""
    from tasks import TaskStore

    if store_or_state is None:
        state_dir = Path(os.environ.get("WORKBENCH_STATE", str(Path.home() / ".session-workbench")))
        store = TaskStore(state_dir)
    elif isinstance(store_or_state, (str, Path)):
        store = TaskStore(Path(store_or_state))
    else:
        store = store_or_state

    now_ts = float(now if now is not None else time.time())
    threshold_days = max(0.0, float(days))
    cutoff = now_ts - threshold_days * 86400.0
    stale_statuses = {"waiting", "unknown", "execution_finished"}
    archived_ids: list[str] = []

    with store.db() as db:
        rows = db.execute("SELECT id, data FROM tasks").fetchall()
        for row in rows:
            task = json.loads(row["data"] if isinstance(row, sqlite3.Row) else row[1])
            status = str(task.get("status") or "")
            if status not in stale_statuses:
                continue
            if str(task.get("verification_status") or "") == "passed":
                continue
            last_ts = float(task.get("updated_at") or task.get("created_at") or 0.0)
            if last_ts >= cutoff:
                continue
            tid = str(task["id"])
            event_key = f"archived_stale:{tid}"
            existing_ev = db.execute(
                "SELECT 1 FROM events WHERE request_id=?",
                (event_key,),
            ).fetchone()
            task["previous_status_before_archive"] = status
            task["status"] = "dismissed"
            task["archived_stale"] = True
            task["archived_at"] = now_ts
            task["updated_at"] = now_ts
            store._save(db, task)
            if not existing_ev:
                db.execute(
                    "INSERT INTO events(task_id,request_id,kind,text,at) VALUES (?,?,?,?,?)",
                    (
                        tid,
                        event_key,
                        "archived_stale",
                        f"超过 {threshold_days:g} 天无人验收自动归档（原状态：{status}）",
                        now_ts,
                    ),
                )
            archived_ids.append(tid)

    return {
        "ok": True,
        "days": threshold_days,
        "archived_count": len(archived_ids),
        "archived_ids": archived_ids,
    }


def approval_source(conversation, proposal):
    """Keep the actual human origin across approval -> worker handoff."""
    from policy import source
    context={key:proposal.get(key) for key in
             ('origin_session_id','origin_message_id','origin_request_id')}
    row=source(conversation,context)
    links=row['source_links']
    return {'source_links':links,'source_message_ids':[link['message_id'] for link in links],
            'latest_user_message_id':row['id'],
            'authorization':{'source_message_id':row['id'],'source_request_id':row['request_id'],
                             'source_quote':row['text'],'source_links':links}}


def authorized_assignment(conversation, proposals, data):
    """Validate a direct human assignment, not a model-supplied permission flag.

    A model may delegate only actual requested work, never a greeting, wish or quotation.
    All agents execute with full access. Irreversible deletion still needs an exact
    approval proposal; source validity and action intent remain separate from permissions.
    """
    from policy import source, assignment, deletion_risk,readonly_restriction,RESTRICTION_ONLY
    row = source(conversation, data)
    if row.get('continuation_unresolved'):
        raise ValueError('这句补充尚未关联真实原交办；请引用具体任务')
    origin = row['id']
    quote = proposals._text(data.get('source_quote'), 'source_quote', 2000)
    if quote not in row['text']:
        raise ValueError('Task authorization quote must be copied exactly from the user message')
    if row.get('supplement'):
        parent_text=(row.get('source_links') or [{}])[0].get('text','')
        clauses=re.split(r'[,，。；;\n]',row['raw_text'])
        def actual_clause(clause):
            clause=clause.strip()
            if re.match(r'^(?:请|帮我|给我|先)?\s*(?:不要|别|禁止|不许|不改|不修改)',clause):return False
            if not readonly_restriction(clause) and not RESTRICTION_ONLY.match(clause):return True
            return bool(re.search(r'检查|查看|查询|读取|统计|查找|处理|排查|诊断',clause))
        current_action=' '.join(clause for clause in clauses if actual_clause(clause))
        if not data.get('pending_action_confirmed') and not assignment(parent_text,parent_text) and not assignment(current_action,current_action):
            raise ValueError('This message is not an explicit assignment; keep it as a candidate')
    if not data.get('pending_action_confirmed') and not assignment(row['text'], quote) and not (row.get('authorization_parent_message_id') and quote in row['raw_text'] and assignment(row['text'],row['text'])):
        raise ValueError('This message is not an explicit assignment; keep it as a candidate')
    effective_quote=row['text'] if row.get('authorization_parent_message_id') else quote
    action_quote=re.sub(r'(?:不要|禁止|别|不许).{0,5}(?:永久删除|清空|销毁|抹掉|删除|删掉)', '', effective_quote)
    if deletion_risk(data.get('action', 'task'), data.get('action_args', {})) or re.search(r'永久删除|清空|销毁|抹掉|删除|删掉', action_quote):
        raise ValueError('This action requires a concrete approval proposal')
    agent, requested = data.get('agent'), data.get('sandbox')
    if agent not in ('pi','codex','claude','hermes'):
        raise ValueError('Automatic tasks support pi or codex, and claude')
    sandbox=effective_sandbox(requested)
    request_id = proposals._text(data.get('request_id'), 'request_id', 120)
    if len(request_id) < 10:
        raise ValueError('Invalid task request ID')
    cwd = proposals._cwd(data.get('relative_cwd'))
    task = {
        'agent':agent, 'cwd':cwd, 'title':proposals._text(data.get('title'),'title',120),
        'prompt':proposals._text(data.get('prompt'),'prompt',6000), 'sandbox':sandbox,
        'requested_sandbox':requested,'operation_policy_revision':POLICY_REVISION,
        'origin_session_id':data['origin_session_id'], 'origin_message_id':origin,
        'origin_request_id':row['request_id'], 'owner_conversation_id':'personal-main',
        'completion_condition':proposals._text(data.get('completion_condition'),'completion_condition',1000),
    }
    authorization = {'request_id':request_id, 'cwd':cwd, 'sandbox':sandbox,
                     'source_message_id':origin, 'source_request_id':row['request_id'], 'source_quote':quote,
                     'scope':'原始明确交办范围；不扩展权限，不做严重不可逆删除；执行前按真实动作及可恢复性检查'}
    task['source_links']=row.get('source_links',[])
    task['source_message_ids']=[link['message_id'] for link in task['source_links']]
    task['context_revision']=1
    task['latest_user_message_id']=origin
    authorization['source_links']=task['source_links']
    task['work_brief']={'goal':task['title'],'completion_condition':task['completion_condition'],
                        'authorized_cwd':cwd,'sandbox':sandbox,'source_links':task['source_links'],
                        'latest_instruction':row['raw_text'],'constraints':[],'context_revision':1}
    criteria=data.get('acceptance_criteria') or []
    if not isinstance(criteria,list) or len(criteria)>8:
        raise ValueError('Invalid acceptance criteria')
    if criteria:
        cleaned=[]
        for item in criteria:
            if not isinstance(item,dict):raise ValueError('Invalid acceptance criterion')
            ident=proposals._text(item.get('id'),'criterion id',80)
            description=proposals._text(item.get('description'),'criterion description',1000)
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*',ident) or any(c['id']==ident for c in cleaned):
                raise ValueError('Acceptance criterion IDs must be distinct')
            cleaned.append({'id':ident,'description':description})
        task['acceptance_criteria']=cleaned
    if row.get('authorization_parent_message_id'):
        authorization['parent_message_id']=row['authorization_parent_message_id']
        authorization['resolved_instruction']=row['text']
        quote=row['text']
    # Worker receives the original clause and completion boundary, not only the model's paraphrase.
    task['prompt'] = ('用户明确交办原文：\n'+quote+'\n\n任务说明：\n'+task['prompt']+
                      '\n\n完成条件：\n'+task['completion_condition']+'\n\n授权范围：\n'+authorization['scope'])
    return task, authorization, request_id


def record_constraint(store, task_id, text, request_id, constraint_type='note',source_context=None):
    tasks = {t['id']:t for t in store.list()}
    if task_id not in tasks:
        raise ValueError('Unknown task ID; ask the user which task')
    task = tasks[task_id]
    if constraint_type == 'read_only':
        instruction = '只读约束：不要修改、删除、发布或外发任何内容。'
        policy = 'restriction'
    elif constraint_type == 'preserve_style':
        instruction = '保持现有界面样式、布局、颜色、图标和动效；只处理原任务已授权的功能，不改视觉设计。'
        policy = 'restriction'
    elif constraint_type == 'forbid_path':
        if not isinstance(text,str) or not text.strip() or len(text)>300 or any(c in text for c in '\n\r\x00'):
            raise ValueError('Invalid restricted path')
        raw = Path(text)
        path = (Path(task['cwd']) / raw).resolve()
        if raw.is_absolute() or not path.is_relative_to(Path(task['cwd']).resolve()):
            raise ValueError('Restricted path must be inside the authorized project')
        # Serialize data to prevent path contents becoming model instruction syntax.
        import json
        instruction = '禁止访问或修改以下项目内路径：' + json.dumps(str(path),ensure_ascii=False)
        policy = 'restriction'
    elif constraint_type == 'note':
        instruction, policy = text, 'unreviewed'
    else:
        raise ValueError('Unsupported constraint type')
    command = store.enqueue(task_id,instruction,request_id,source='mcp',policy=policy,source_context=source_context)
    if constraint_type=='read_only' and full_access_enabled(task):
        store.transition_input(request_id,('pending_start','queued'),'revoked','用户已撤销 Com 的全部只读限制；只保留审计，不投递执行')
        command={**command,'state':'revoked'}
    return {'task_id':task_id,'request_id':request_id,'delivery':command['state'],
            'work_started':False}
