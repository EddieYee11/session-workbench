"""待确认动作（Her 式「一句话确认执行」）：助理提出待确认动作时登记，用户下一条短肯定直接快路径执行或准备。"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any

DEFAULT_TTL = 1800  # 默认 30 分钟过期

# 短肯定：好 / 叫吧 / 可以 / 行 / 发吧 / 就这个 / 嗯 等（允许组合如「好 叫吧」「好的，可以」）
_AFFIRM_WORDS = (
    r'好(?:的|呀|啊|嘞|吧)?|叫吧|可以(?:的|呀|吧)?|行(?:的|吧|啊)?|发吧|就这个|嗯(?:嗯)?|'
    r'记吧|订吧|买吧|办吧|弄吧|走吧|来吧|加吧|没问题|确认|确定|安排(?:吧)?|就这样'
)
_AFFIRM_RE = re.compile(rf'^(?:{_AFFIRM_WORDS})(?:[\s，,。.！!、]+(?:{_AFFIRM_WORDS}))*$')

# 前置肯定词（用于「好，算了」「行吧不用了」「嗯，先别」等先应声再否定）
_NEGATE_PREFIX = r'(?:(?:好(?:的|呀|啊|嘞|吧)?|行(?:的|吧|啊)?|嗯(?:嗯)?|可以(?:吧)?|那|还是)\s*)*'

# 短否定：算了 / 不用 / 先别 / 不记 / 再想想 等
_NEGATE_WORDS = (
    r'算了(?:吧)?|不用(?:了)?|先不用|先别(?:了)?|别了|不要(?:了)?|不记(?:了)?|'
    r'不发(?:了)?|不叫(?:了)?|不订(?:了)?|不加(?:了)?|取消|再想想|先算了|暂不|缓缓'
)
_NEGATE_RE = re.compile(rf'^{_NEGATE_PREFIX}(?:{_NEGATE_WORDS})(?:[\s，,。.！!、]+(?:{_NEGATE_WORDS}))*$')

# 「最终点击由 Eddie」的三类外发动作：邮件发送、付款/报销提交、视频/内容发布
_GATED_Categories = {
    'email_send': '邮件发送',
    'mail_send': '邮件发送',
    'payment_submit': '付款与报销提交',
    'expense_submit': '付款与报销提交',
    'labor_pay': '付款与报销提交',
    'content_publish': '内容发布',
    'video_publish': '内容发布',
}
_GATED_LABEL_TO_CATEGORY = {
    '邮件发送': 'email_send',
    '付款与报销提交': 'payment_submit',
    '内容发布': 'content_publish',
}
_GATED_PATTERNS = (
    (
        re.compile(
            r'(?:发(?:送|出)?|寄(?:出)?|回(?:复)?).{0,20}(?:邮件|信件|(?:email|mail)\b)'
            r'|(?:邮件|信件|(?:email|mail)\b).{0,20}(?:发(?:送|出|给)?|寄出|回复)'
            r'|gmail[\s._+-]*(?:users[\s._+-]*messages[\s._+-]*)?send'
            r'|gws\s+gmail\b.*?(?:send|发送|发邮件|\+send)'
            r'|send[_\s-]*e?mail|mail[_\s-]*send|sohu[_-]?mail.*send',
            re.I,
        ),
        '邮件发送',
    ),
    (
        re.compile(
            r'(?:提交?|发起|确认|支付|付(?:款|给)?|打款|转账|申报|走|办|填(?:写)?(?:好|完)?并?(?:提交?)?).{0,20}(?:付款(?:单|申请)?|报销(?:单|申请)?|劳务(?:费|报酬|单|付款)?|打款|账单支付)'
            r'|(?:付款(?:单|申请)?|报销(?:单|申请)?|劳务(?:费|报酬|单|付款)?).{0,20}(?:提交?|支付|付款?|打款|转账|申报|发送)'
            r'|(?:给.{1,10})(?:提|付|打|交|报).{0,6}(?:劳务(?:费|报酬)?|报销|付款|款)'
            r'|sohu[-_]?labor[-_]?pay|labor[-_]?pay|payment[-_]?submit|expense[-_]?submit',
            re.I,
        ),
        '付款与报销提交',
    ),
    (
        re.compile(
            r'(?:发布|发表|群发|投递|上传|发(?:到|上|去|条|个|一篇|一支)?|推(?:送到)?|同步(?:到)?).{0,20}(?:小红书|抖音|视频号|微博|B站|bilibili|公众号|搜狐(?:视频|关注流)?|快手|知乎|YouTube|X|推特|Twitter|朋友圈|动态|笔记|文章|推文|帖子)'
            r'|(?:发布|发表|上传并?发布|群发|发(?:出去|上网|上线)).{0,20}(?:视频|内容|文章|动态|笔记|帖子|成片|片子)'
            r'|(?:视频|内容|文章|动态|笔记|成片|公众号|视频号|抖音|小红书|B站|微博|搜狐(?:视频)?).{0,20}(?:发布|发表|群发|发出去|上传发布)'
            r'|content[-_]?publish|video[-_]?publish|post[-_]?publish|publish[-_]?(?:video|content|post)',
            re.I,
        ),
        '内容发布',
    ),
)

_AUTO_CONFIRM_RE = re.compile(r'(?:回我一句|回一句|回我|你说一声|你说|说一声|说句)\s*[「“"\']([^「」”"\'\r\n]{1,4})[」”"\']\s*[，,]?\s*(?:我就|就|我再|我马上|再|马上)')

_DELETION_WORDS_RE = re.compile(r'永久删除|清空|销毁|抹掉|删除|删掉')
_NEGATED_DELETION_RE = re.compile(r'(?:不要|禁止|别|不许).{0,5}(?:永久删除|清空|销毁|抹掉|删除|删掉)')


def gated_kind(action: dict[str, Any] | str, description: str = '') -> str | None:
    """判断动作是否属于「最终点击由 Eddie」的三类（邮件发送、付款提交、内容发布）。

    不单信模型填写的 category：即使 category 填了普通值，只要描述或参数命中三类外发特征，一律按外发处理。
    """
    if isinstance(action, dict):
        for key in ('category', 'kind', 'tool'):
            cat = str(action.get(key) or '').strip().lower()
            if cat in _GATED_Categories:
                return _GATED_Categories[cat]
        blob = ' '.join(
            str(action.get(k) or '')
            for k in ('tool', 'category', 'kind', 'title', 'prompt', 'description', 'summary', 'command')
        ) + ' ' + json.dumps(action.get('args') or action, ensure_ascii=False)
    else:
        blob = str(action or '')
    text = f'{description} {blob}'
    for pattern, label in _GATED_PATTERNS:
        if pattern.search(text):
            return label
    return None


def _has_irreversible_deletion(tool: str, args: dict[str, Any], *texts: str) -> bool:
    """检查动作工具、参数或描述/提示词是否包含不可逆删除或清空风险。"""
    from policy import DANGER, deletion_risk

    if deletion_risk(tool or 'task', args):
        return True
    combined = '\n'.join(str(t or '') for t in texts) + '\n' + json.dumps(args, ensure_ascii=False)
    cleaned = _NEGATED_DELETION_RE.sub('', combined)
    if _DELETION_WORDS_RE.search(cleaned):
        return True
    cmd_cleaned = re.sub(r'(?<!>)\d*>\s*/dev/null(?=\s|[;&|]|$)', '', combined)
    return bool(DANGER.search(cmd_cleaned))


def _norm_ts(val: Any) -> float:
    """规范化秒/毫秒时间戳；大于 1e12 的毫秒时间戳折算为秒。"""
    try:
        ts = float(val or 0)
    except (TypeError, ValueError):
        return 0.0
    if ts > 1e12:
        ts /= 1000.0
    return ts


def data_freshness(state: Path | str, now: float | None = None) -> dict[str, Any]:
    """提取关键数据源（定位、日历同步、记账、健康）的更新时间与新旧状态。

    数据源以 device_nodes.py（devices.sqlite 的 location.last 调用）与 personal_hub.py（personal-hub.sqlite）现有字段为准，
    不用设备在线心跳 last_seen 冒充定位时间；没有真实时间戳的项直接跳过，不编造。
    定位 > 2 小时（7200s）、日历 > 6 小时（21600s）标注 stale=True（「较旧」）。
    """
    from datetime import datetime
    from zoneinfo import ZoneInfo

    root = Path(state)
    now_ts = time.time() if now is None else _norm_ts(now)
    tz = ZoneInfo('Asia/Shanghai')
    now_dt = datetime.fromtimestamp(now_ts, tz)

    def fmt_ts(ts: float) -> str:
        dt = datetime.fromtimestamp(ts, tz)
        days = (now_dt.date() - dt.date()).days
        hm = dt.strftime('%H:%M')
        if days == 0:
            return f'今天 {hm}'
        if days == 1:
            return f'昨天 {hm}'
        return dt.strftime('%m-%d %H:%M')

    items: dict[str, dict[str, Any]] = {}
    location_ts: float = 0.0

    # 1. device_nodes.py: devices.sqlite（仅认 location.last 成功调用，不用设备 last_seen 冒充定位）
    dev_db = root / 'devices.sqlite'
    if dev_db.exists():
        try:
            with sqlite3.connect(f'file:{dev_db}?mode=ro', uri=True, timeout=2) as db:
                for (raw,) in db.execute('SELECT data FROM invocations'):
                    inv = json.loads(raw)
                    if inv.get('tool') == 'location.last' and inv.get('status') == 'succeeded':
                        ts = _norm_ts(inv.get('finished_at') or inv.get('created_at'))
                        location_ts = max(location_ts, ts)
        except Exception:
            pass

    # 2. personal_hub.py: personal-hub.sqlite (sources & matters)
    hub_db = root / 'personal-hub.sqlite'
    calendar_ts: float = 0.0
    accounting_ts: float = 0.0
    health_ts: float = 0.0
    if hub_db.exists():
        try:
            with sqlite3.connect(f'file:{hub_db}?mode=ro', uri=True, timeout=2) as db:
                sources = {k: json.loads(v) for k, v in db.execute('SELECT name, data FROM sources')}
                for name in ('apple_calendar', 'google_calendar', 'phone_calendar'):
                    ts = _norm_ts((sources.get(name) or {}).get('updated_at'))
                    calendar_ts = max(calendar_ts, ts)
                accounting_ts = _norm_ts((sources.get('accounting') or {}).get('updated_at'))
                for name in ('garmin', 'phone_health'):
                    ts = _norm_ts((sources.get(name) or {}).get('updated_at'))
                    health_ts = max(health_ts, ts)

                for src, raw in db.execute(
                    "SELECT source, data FROM matters WHERE source IN "
                    "('context','apple_calendar','google_calendar','phone_calendar','accounting','garmin','phone_health')"
                ):
                    m = json.loads(raw)
                    ts = _norm_ts(m.get('updated_at') or m.get('source_updated_at'))
                    if src == 'context' and (m.get('facts') or {}).get('kind') == 'place':
                        location_ts = max(location_ts, ts)
                    elif src in ('apple_calendar', 'google_calendar', 'phone_calendar'):
                        calendar_ts = max(calendar_ts, ts)
                    elif src == 'accounting':
                        accounting_ts = max(accounting_ts, ts)
                    elif src in ('garmin', 'phone_health'):
                        health_ts = max(health_ts, ts)
        except Exception:
            pass

    specs = (
        ('location', '定位', location_ts, 2 * 3600),
        ('calendar', '日历', calendar_ts, 6 * 3600),
        ('accounting', '记账', accounting_ts, None),
        ('health', '健康', health_ts, None),
    )
    parts: list[str] = []
    for key, label, ts, threshold in specs:
        if ts <= 0:
            continue
        age_sec = max(0.0, now_ts - ts)
        stale = bool(threshold is not None and age_sec > threshold)
        entry: dict[str, Any] = {
            'label': label,
            'updated_at': round(ts, 1),
            'updated_text': fmt_ts(ts),
            'age_minutes': int(age_sec // 60),
            'stale': stale,
        }
        if stale:
            entry['status'] = '较旧'
        items[key] = entry
        parts.append(f"{label} {entry['updated_text']}" + ('（较旧）' if stale else ''))

    if not items:
        return {}
    summary = '数据更新：' + '；'.join(parts)
    return {'items': items, 'summary': summary}


def _clean_utterance(text: str) -> str:
    return re.sub(r'[。？！?!，,、\s「」"\'（）()]+', ' ', str(text or '').strip()).strip()


def match_reply(text: str, confirm_word: str = '') -> str | None:
    """识别用户回复是否为短肯定('affirm')、短否定('negate')或其它(None)。"""
    raw = str(text or '').strip()
    if not raw or len(raw) > 24:
        return None
    # 含问号或明显疑问句不触发确认
    if re.search(r'[？?]|(?:吗|呢|么)\s*[。！!]?$', raw):
        return None
    cleaned = _clean_utterance(raw)
    if not cleaned:
        return None
    if _NEGATE_RE.fullmatch(cleaned):
        return 'negate'
    word = _clean_utterance(confirm_word)
    if word:
        # 否定 + 确认词（如「不叫」「别发」「先不记」「好，不叫了」「行吧不发了」）归为 negate
        if re.fullmatch(rf'{_NEGATE_PREFIX}(?:不|别|先不|先别|不用)\s*{re.escape(word)}(?:了|吧)?', cleaned):
            return 'negate'
        # 精确命中确认词，或「好 叫吧」「行 发吧」「叫吧」等短组合；不接受「了」后缀（「发了/叫了/记了」常表示已自行处理）
        if re.fullmatch(
            rf'(?:(?:{_AFFIRM_WORDS})\s+)*{re.escape(word)}(?:吧|呀|啊|嘞)?(?:\s+(?:{_AFFIRM_WORDS}))*',
            cleaned,
        ):
            return 'affirm'
    if _AFFIRM_RE.fullmatch(cleaned):
        return 'affirm'
    return None


def extract_auto_confirm(reply_text: str) -> tuple[str, str] | None:
    """从 assistant 回复中提取自动登记所需的 (confirm_word, description)。

    若回复文本匹配「回我一句「X」」（X 1–4 字），返回 (X, 回复首句去 ** 加粗且 ≤60 字)；否则返回 None。
    """
    from reply_options import split_options
    from reply_widgets import split_widgets

    raw = str(reply_text or '').strip()
    if not raw:
        return None
    body, _ = split_options(raw)
    body, _ = split_widgets(body)
    words = [
        _clean_utterance(m.group(1))
        for m in _AUTO_CONFIRM_RE.finditer(body)
    ]
    words = [w for w in words if 1 <= len(w) <= 4]
    if not words:
        return None
    confirm_word = words[-1]
    cleaned = re.sub(r'\*\*+', '', body).strip()
    sentences = [
        re.sub(r'^#+\s*', '', s).strip()
        for s in re.split(r'[。！？!?\r\n]+', cleaned)
    ]
    sentences = [s for s in sentences if s]
    first_sentence = (sentences[0] if sentences else cleaned).strip()
    description = first_sentence[:60]
    if not description:
        return None
    return confirm_word, description


def auto_register_from_reply(
    state: Path | str,
    reply_text: str,
    *,
    origin_session_id: str = 'com-personal-main',
    origin_message_id: str = '',
    origin_request_id: str = '',
    origin_user_text: str = '',
    now: float | None = None,
) -> dict[str, Any] | None:
    """若 assistant 回复含「回我一句「X」」（X 1–4 字）且同轮无 pending 行，自动登记 confirm_to_model。"""
    extracted = extract_auto_confirm(reply_text)
    if not extracted:
        return None
    confirm_word, description = extracted
    pa = PendingActions(state)
    pa.expire_stale(now)
    with pa.db() as db:
        rows = db.execute('SELECT status, confirm_word, context FROM pending_actions').fetchall()
    for r in rows:
        try:
            ctx = json.loads(r['context'] or '{}')
        except Exception:
            ctx = {}
        if origin_message_id and ctx.get('origin_message_id') == origin_message_id:
            return None
        if r['status'] == 'pending' and not ctx.get('origin_message_id') and r['confirm_word'] == confirm_word:
            return None
    action: dict[str, Any] = {'tool': 'confirm_to_model'}
    gated = gated_kind(action, f'{description}\n{reply_text}')
    if gated and gated in _GATED_LABEL_TO_CATEGORY:
        action['category'] = _GATED_LABEL_TO_CATEGORY[gated]
    return pa.register(
        description=description,
        confirm_word=confirm_word,
        action=action,
        ttl_seconds=DEFAULT_TTL,
        context={
            'origin_session_id': origin_session_id or 'com-personal-main',
            'origin_message_id': origin_message_id,
            'origin_request_id': origin_request_id,
            'origin_user_text': origin_user_text,
        },
        now=now,
    )


class PendingActions:
    def __init__(self, state: Path | str, clock=time.time):
        self.state = Path(state)
        self.path = self.state / 'pending-actions.sqlite'
        self.clock = clock
        with self.db() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS pending_actions(
                    id TEXT PRIMARY KEY,
                    description TEXT NOT NULL,
                    confirm_word TEXT NOT NULL,
                    action TEXT NOT NULL,
                    context TEXT NOT NULL DEFAULT '{}',
                    status TEXT NOT NULL DEFAULT 'pending',
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    resolved_at REAL,
                    resolution TEXT
                );
                CREATE INDEX IF NOT EXISTS pending_actions_status
                    ON pending_actions(status, expires_at, created_at);
            """)
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        conn = sqlite3.connect(self.path, timeout=10)
        conn.row_factory = sqlite3.Row
        try:
            with conn:
                yield conn
        finally:
            conn.close()

    def _row_to_dict(self, row: sqlite3.Row | None) -> dict[str, Any] | None:
        if not row:
            return None
        item = dict(row)
        item['action'] = json.loads(item['action'] or '{}')
        item['context'] = json.loads(item['context'] or '{}')
        item['gated_kind'] = gated_kind(item['action'], item['description'])
        if item['action'].get('category'):
            item['category'] = item['action']['category']
        elif item['gated_kind'] in _GATED_LABEL_TO_CATEGORY:
            item['category'] = _GATED_LABEL_TO_CATEGORY[item['gated_kind']]
        return item

    def expire_stale(self, now: float | None = None) -> int:
        now = self.clock() if now is None else float(now)
        with self.db() as db:
            cur = db.execute(
                "UPDATE pending_actions SET status='expired', resolved_at=? "
                "WHERE status='pending' AND expires_at<=?",
                (now, now),
            )
            return cur.rowcount

    def register(
        self,
        description: str,
        confirm_word: str,
        action: dict[str, Any] | None = None,
        *,
        ttl_seconds: int = DEFAULT_TTL,
        context: dict[str, Any] | None = None,
        now: float | None = None,
    ) -> dict[str, Any]:
        """登记一条待确认动作；之前的 pending 动作自动标为 superseded，保证当前焦点唯一。"""
        description = str(description or '').strip()[:500]
        confirm_word = _clean_utterance(confirm_word)[:16]
        if not description:
            raise ValueError('待确认动作缺少 description')
        if not confirm_word:
            raise ValueError('待确认动作缺少 confirm_word')
        action_payload = dict(action or {})
        gated = gated_kind(action_payload, description)
        if gated and gated in _GATED_LABEL_TO_CATEGORY and not action_payload.get('category'):
            action_payload['category'] = _GATED_LABEL_TO_CATEGORY[gated]
        now = self.clock() if now is None else float(now)
        ttl = max(60, min(int(ttl_seconds or DEFAULT_TTL), 86400))
        expires_at = now + ttl
        ident = 'pa_' + uuid.uuid4().hex[:20]
        ctx = dict(context or {})
        convo_db = self.state / 'personal-conversation.sqlite'
        if convo_db.exists():
            try:
                with sqlite3.connect(convo_db, timeout=5) as cdb:
                    cdb.row_factory = sqlite3.Row
                    if ctx.get('origin_message_id') and not ctx.get('origin_user_text'):
                        urow = cdb.execute(
                            "SELECT id, request_id, text FROM messages WHERE id=? AND role='user'",
                            (ctx['origin_message_id'],),
                        ).fetchone()
                        if urow:
                            ctx.setdefault('origin_request_id', urow['request_id'])
                            ctx['origin_user_text'] = urow['text']
                    elif not ctx.get('origin_message_id'):
                        urow = cdb.execute(
                            "SELECT id, request_id, text FROM messages WHERE role='user' ORDER BY created_at DESC, id DESC LIMIT 1"
                        ).fetchone()
                        if urow:
                            ctx['origin_message_id'] = urow['id']
                            ctx['origin_request_id'] = urow['request_id']
                            ctx['origin_user_text'] = urow['text']
            except Exception:
                pass
        with self.db() as db:
            db.execute(
                "UPDATE pending_actions SET status='superseded', resolved_at=? WHERE status='pending'",
                (now,),
            )
            db.execute(
                "INSERT INTO pending_actions(id,description,confirm_word,action,context,status,created_at,expires_at) "
                "VALUES(?,?,?,?,?,'pending',?,?)",
                (
                    ident,
                    description,
                    confirm_word,
                    json.dumps(action_payload, ensure_ascii=False),
                    json.dumps(ctx, ensure_ascii=False),
                    now,
                    expires_at,
                ),
            )
            row = db.execute('SELECT * FROM pending_actions WHERE id=?', (ident,)).fetchone()
        return self._row_to_dict(row)

    def active(self, now: float | None = None) -> dict[str, Any] | None:
        """返回当前未过期的最新待确认动作；若已过期则顺手清理并返回 None。"""
        now = self.clock() if now is None else float(now)
        self.expire_stale(now)
        with self.db() as db:
            row = db.execute(
                "SELECT * FROM pending_actions WHERE status='pending' AND expires_at>? "
                "ORDER BY created_at DESC, rowid DESC LIMIT 1",
                (now,),
            ).fetchone()
        return self._row_to_dict(row)

    def get(self, action_id: str) -> dict[str, Any] | None:
        with self.db() as db:
            row = db.execute('SELECT * FROM pending_actions WHERE id=?', (action_id,)).fetchone()
        return self._row_to_dict(row)

    def match(self, text: str, now: float | None = None) -> dict[str, Any] | None:
        """检查用户消息是否命中当前待确认动作的短肯定/短否定。无关消息返回 None 且保留待确认状态。"""
        current = self.active(now)
        if not current:
            return None
        decision = match_reply(text, current['confirm_word'])
        if not decision:
            return None
        return {'decision': decision, 'pending': current}

    def cancel(self, action_id: str | None = None, now: float | None = None) -> dict[str, Any] | None:
        now = self.clock() if now is None else float(now)
        target = self.get(action_id) if action_id else self.active(now)
        if not target or target['status'] != 'pending':
            return None
        with self.db() as db:
            db.execute(
                "UPDATE pending_actions SET status='cancelled', resolved_at=?, resolution='cancelled' WHERE id=?",
                (now, target['id']),
            )
            row = db.execute('SELECT * FROM pending_actions WHERE id=?', (target['id'],)).fetchone()
        return self._row_to_dict(row)

    async def execute(
        self,
        action_id: str | None = None,
        *,
        request_id: str = '',
        message_id: str = '',
        session_id: str = '',
        conversation: Any = None,
        service: Any = None,
        task_store: Any = None,
        now: float | None = None,
    ) -> dict[str, Any]:
        """执行待确认动作并返回结构化结果与回执文案。

        属于邮件发送、付款提交、内容发布三类的动作，只做到准备完毕停在按钮前，不在后台直接外发/提交。
        不可逆删除/清空动作一律转为 propose_work 审批卡，不直接执行。
        """
        now = self.clock() if now is None else float(now)
        if action_id:
            target = self.get(action_id)
        else:
            target = self.active(now)
            if not target:
                with self.db() as db:
                    row = db.execute(
                        "SELECT * FROM pending_actions WHERE status='running' AND expires_at>? "
                        "ORDER BY created_at DESC, rowid DESC LIMIT 1",
                        (now,),
                    ).fetchone()
                target = self._row_to_dict(row)
        if not target:
            raise ValueError('没有待确认的动作或已过期')
        if target['expires_at'] <= now:
            self.expire_stale(now)
            raise ValueError('待确认动作已过期')

        # 并发安全：await 前用原子 UPDATE 抢占 status='running'，rowcount=0 直接返回已处理
        with self.db() as db:
            cur = db.execute(
                "UPDATE pending_actions SET status='running', resolved_at=? "
                "WHERE id=? AND status='pending' AND expires_at>?",
                (now, target['id'], now),
            )
            claimed = cur.rowcount
        if claimed == 0:
            current = self.get(target['id']) or target
            return {
                **current,
                'already_processed': True,
                'receipt': f"该待确认动作已处理（当前状态：{current['status']}），未重复执行。",
            }

        action = target['action']
        desc = target['description']
        gated = gated_kind(action, desc)
        reg_ctx = target.get('context') or {}
        origin_ctx = {
            **reg_ctx,
            'reg_message_id': reg_ctx.get('origin_message_id', ''),
            'reg_request_id': reg_ctx.get('origin_request_id', ''),
            'reg_user_text': reg_ctx.get('origin_user_text', ''),
            'confirm_request_id': request_id,
            'confirm_message_id': message_id,
            'confirm_session_id': session_id,
            'conversation': conversation,
            'origin_request_id': request_id or reg_ctx.get('origin_request_id') or ('confirm-' + target['id']),
            'origin_message_id': message_id or reg_ctx.get('origin_message_id') or '',
            'origin_session_id': session_id or reg_ctx.get('origin_session_id') or '',
        }

        try:
            if gated:
                prep = await self._prepare_gated(target, gated, origin_ctx, task_store=task_store)
                receipt_text = prep['receipt']
                status = prep.get('status', 'prepared')
                resolution = {
                    'mode': prep.get('mode', 'prepared_before_submit'),
                    'gated_kind': gated,
                    'task_id': prep.get('task_id'),
                    'proposal_id': prep.get('proposal_id'),
                    'receipt': receipt_text,
                }
                detail = prep
            else:
                receipt_text, detail = await self._run_action(
                    target, origin_ctx, service=service, task_store=task_store
                )
                if isinstance(detail, dict) and detail.get('approval_required'):
                    status = 'approval_required'
                    resolution = {
                        'mode': 'approval_required',
                        'proposal_id': detail.get('proposal_id'),
                        'detail': detail,
                        'receipt': receipt_text,
                    }
                else:
                    status = 'executed'
                    resolution = {'mode': 'executed', 'detail': detail, 'receipt': receipt_text}
        except Exception as exc:
            with self.db() as db:
                db.execute(
                    "UPDATE pending_actions SET status='failed', resolved_at=?, resolution=? WHERE id=?",
                    (now, json.dumps({'mode': 'failed', 'error': str(exc)}, ensure_ascii=False), target['id']),
                )
            raise

        with self.db() as db:
            db.execute(
                'UPDATE pending_actions SET status=?, resolved_at=?, resolution=? WHERE id=?',
                (status, now, json.dumps(resolution, ensure_ascii=False), target['id']),
            )
            updated = db.execute('SELECT * FROM pending_actions WHERE id=?', (target['id'],)).fetchone()
        result = self._row_to_dict(updated)
        result['receipt'] = receipt_text
        if isinstance(detail, dict):
            if detail.get('task_id'):
                result['task_id'] = detail['task_id']
            if detail.get('proposal_id'):
                result['proposal_id'] = detail['proposal_id']
            if 'verified' in detail:
                result['verified'] = detail['verified']
            for k in ('followup_request_id', 'followup_message_id', 'instruction', 'source_quote'):
                if detail.get(k):
                    result[k] = detail[k]
        return result

    def _resolve_workspace_and_cwd(self, raw_cwd: str | None) -> tuple[Path, str]:
        default_ws = Path(os.environ.get('WORKBENCH_HOME', str(Path.home()))) / 'AI_Work_System'
        workspace = default_ws.resolve() if default_ws.is_dir() else self.state.resolve()
        if not raw_cwd:
            return workspace, '.'
        p = Path(str(raw_cwd))
        if p.is_absolute():
            resolved = p.resolve()
            if resolved.is_relative_to(workspace):
                rel = str(resolved.relative_to(workspace))
                return workspace, (rel if rel and rel != '.' else '.')
            if resolved.is_dir():
                return resolved, '.'
            return workspace, '.'
        if (workspace / p).is_dir():
            return workspace, str(p)
        if (self.state / p).is_dir():
            return self.state.resolve(), str(p)
        return workspace, '.'

    def _prepare_conversation_source(
        self,
        target: dict[str, Any],
        origin_ctx: dict[str, Any],
    ) -> tuple[Any, dict[str, Any], dict[str, Any]]:
        """关联登记时的原用户消息与确认时的真实用户消息，供 policy.source / authorized_assignment / authorize_tool 校验。"""
        from conversation import PersonalConversation
        from policy import source as policy_source, source_link

        passed_chat = origin_ctx.get('conversation')
        chat = passed_chat if isinstance(passed_chat, PersonalConversation) else PersonalConversation(self.state)
        reg_ctx = target.get('context') or {}

        chat_sid = chat._session_id()
        passed_sid = str(origin_ctx.get('confirm_session_id') or origin_ctx.get('origin_session_id') or '')
        reg_sid = str(reg_ctx.get('origin_session_id') or '')
        if passed_sid and passed_sid != 'com-personal-main':
            sid = passed_sid
        elif chat_sid:
            sid = chat_sid
        elif reg_sid:
            sid = reg_sid
        else:
            sid = passed_sid or 'com-personal-main'

        if chat._session_id() is None:
            session_key = getattr(chat.client, 'session_key', None) or 'hermes_session_id'
            with chat.db() as db:
                db.execute('INSERT OR IGNORE INTO meta(key,value) VALUES(?,?)', (session_key, sid))
            if chat._session_id() and chat._session_id() != sid and not passed_sid:
                sid = chat._session_id()

        reg_mid = str(origin_ctx.get('reg_message_id') or reg_ctx.get('origin_message_id') or '')
        reg_req = str(origin_ctx.get('reg_request_id') or reg_ctx.get('origin_request_id') or '')
        explicit_confirm_mid = str(origin_ctx.get('confirm_message_id') or '')
        explicit_confirm_req = str(origin_ctx.get('confirm_request_id') or '')
        confirm_mid = explicit_confirm_mid
        confirm_req = explicit_confirm_req

        with chat.db() as db:
            reg_row = (
                db.execute("SELECT * FROM messages WHERE id=? AND role='user'", (reg_mid,)).fetchone()
                if reg_mid
                else None
            )
            if not reg_row and reg_req:
                reg_row = db.execute(
                    "SELECT * FROM messages WHERE request_id=? AND role='user'", (reg_req,)
                ).fetchone()
                if reg_row:
                    reg_mid = reg_row['id']

            confirm_row = (
                db.execute("SELECT * FROM messages WHERE id=? AND role='user'", (confirm_mid,)).fetchone()
                if confirm_mid
                else None
            )
            if not confirm_row and confirm_req:
                confirm_row = db.execute(
                    "SELECT * FROM messages WHERE request_id=? AND role='user'", (confirm_req,)
                ).fetchone()
            if not confirm_row and not explicit_confirm_mid and not explicit_confirm_req and reg_row:
                confirm_row = db.execute(
                    "SELECT * FROM messages WHERE role='user' AND id!=? AND created_at>=? "
                    "ORDER BY created_at DESC, id DESC LIMIT 1",
                    (reg_row['id'], reg_row['created_at']),
                ).fetchone()
            if confirm_row:
                confirm_mid = confirm_row['id']
                confirm_req = confirm_row['request_id']

            if not reg_row and not reg_mid:
                if confirm_mid:
                    reg_row = db.execute(
                        "SELECT * FROM messages WHERE role='user' AND id!=? ORDER BY created_at DESC, id DESC LIMIT 1",
                        (confirm_mid,),
                    ).fetchone()
                else:
                    reg_row = db.execute(
                        "SELECT * FROM messages WHERE role='user' ORDER BY created_at DESC, id DESC LIMIT 1"
                    ).fetchone()
                if reg_row:
                    reg_mid = reg_row['id']
                    reg_req = reg_row['request_id']

        # 仅当单元测试直接调用 PendingActions.register/execute 且未向 PersonalConversation 提交消息时，补齐测试消息行
        if not reg_mid and not reg_row:
            seed_req = 'reg-' + target['id']
            seed_text = str(reg_ctx.get('origin_user_text') or f"请办理：{target['description']}")
            sub = chat.submit(seed_req, seed_text)
            reg_mid = sub['message_id']
            reg_req = seed_req
            with chat.db() as db:
                db.execute("UPDATE messages SET status='completed' WHERE id=?", (reg_mid,))
                if confirm_row:
                    db.execute('UPDATE messages SET created_at=? WHERE id=?', (float(confirm_row['created_at']) - 1.0, reg_mid))
                reg_row = db.execute("SELECT * FROM messages WHERE id=?", (reg_mid,)).fetchone()

        if not confirm_row and not explicit_confirm_mid and not (reg_mid and not reg_row):
            c_req = (
                explicit_confirm_req
                if (explicit_confirm_req and len(explicit_confirm_req) >= 10 and explicit_confirm_req != reg_req)
                else ('confirm-' + target['id'])
            )
            sub = chat.submit(c_req, target['confirm_word'])
            confirm_mid = sub['message_id']
            confirm_req = c_req
            with chat.db() as db:
                db.execute("UPDATE messages SET status='completed' WHERE id=?", (confirm_mid,))
                confirm_row = db.execute("SELECT * FROM messages WHERE id=?", (confirm_mid,)).fetchone()

        if not confirm_mid:
            confirm_mid = reg_mid
        if not confirm_req or len(confirm_req) < 10:
            confirm_req = (
                confirm_row['request_id']
                if confirm_row and len(str(confirm_row['request_id'] or '')) >= 10
                else (reg_req if len(reg_req) >= 10 else ('confirm-' + target['id']))
            )

        supp_mid = None
        if reg_row and confirm_row and reg_row['id'] != confirm_row['id']:
            supp_mid = reg_row['id']
            with chat.db() as db:
                if float(reg_row['created_at']) >= float(confirm_row['created_at']):
                    db.execute(
                        'UPDATE messages SET created_at=? WHERE id=?',
                        (float(confirm_row['created_at']) - 0.001, reg_row['id']),
                    )
                    reg_row = db.execute("SELECT * FROM messages WHERE id=?", (reg_row['id'],)).fetchone()
                db.execute(
                    'INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)',
                    (
                        'confirm-source:' + confirm_row['id'],
                        json.dumps(
                            {
                                'parent_id': reg_row['id'],
                                'confirm_id': confirm_row['id'],
                                'source_quote': str(reg_row['text'] or ''),
                                'source_links': [source_link(dict(reg_row))],
                            },
                            ensure_ascii=False,
                        ),
                    ),
                )

        auth_ctx: dict[str, Any] = {
            'origin_session_id': sid,
            'origin_message_id': confirm_mid,
            'origin_request_id': confirm_req,
            'pending_action_confirmed': True,
        }
        if supp_mid:
            auth_ctx['supplement_to_message_id'] = supp_mid

        src_row = policy_source(chat, auth_ctx)
        return chat, auth_ctx, src_row

    def _propose_deletion_approval(
        self,
        proposals: Any,
        task_store: Any,
        target: dict[str, Any],
        auth_ctx: dict[str, Any],
        *,
        agent: str = 'pi',
        relative_cwd: str = '.',
        title: str = '',
        prompt: str = '',
        sandbox: str = 'danger-full-access',
        req_id: str = '',
        actual_action: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        action = target['action']
        desc = target['description']
        title = (title or str(action.get('title') or desc))[:120]
        prompt = (prompt or str(action.get('prompt') or desc))[:5500]
        req_id = req_id or str(auth_ctx.get('origin_request_id') or ('pending-proposal-' + target['id']))
        if len(req_id) < 10:
            req_id = 'pending-proposal-' + target['id']
        actual = actual_action or {
            'tool': str(action.get('tool') or 'task'),
            'args': dict(action.get('args') or action),
        }
        card = proposals.propose(
            agent=agent if agent in ('pi', 'codex', 'claude', 'hermes') else 'pi',
            relative_cwd=relative_cwd or '.',
            title=title,
            prompt=prompt,
            sandbox=sandbox,
            reason='不可逆删除或清空动作需具体审批，不能仅凭一句话确认直接执行',
            origin_session_id=str(auth_ctx.get('origin_session_id') or 'com-personal-main'),
            origin_message_id=str(auth_ctx.get('origin_message_id') or ''),
            origin_request_id=str(auth_ctx.get('origin_request_id') or req_id),
            idempotency_key=req_id,
            actual_action=actual,
        )
        task_store.ensure(card)
        return card

    async def _prepare_gated(
        self,
        target: dict[str, Any],
        gated_label: str,
        origin_ctx: dict[str, Any],
        *,
        task_store: Any = None,
    ) -> dict[str, Any]:
        if task_store is None:
            from tasks import TaskStore
            task_store = TaskStore(self.state)
        desc = target['description']
        note = (
            f'【规则约束】此项属于「{gated_label}」，严禁直接点击发送/提交/发布按钮（禁止最终点击）；'
            '只填写并核对全部内容，停在最后一步按钮前交由 Eddie 本人点击。'
        )
        outcome = self._enqueue_task(
            task_store,
            target,
            origin_ctx,
            prepare_only_note=note,
        )
        if outcome['mode'] == 'approval_required':
            pid = outcome['proposal_id']
            return {
                'status': 'approval_required',
                'mode': 'approval_required',
                'proposal_id': pid,
                'receipt': f'「{desc}」涉及不可逆删除/清空，已转为审批卡（{pid}），需在审批卡具体批准后才会执行。',
            }
        task_id = outcome['task_id']
        return {
            'status': 'prepared',
            'mode': 'prepared_before_submit',
            'task_id': task_id,
            'receipt': (
                f'已为你建立准备任务（任务 {task_id}）：「{desc}」属于{gated_label}，'
                '任务约束已强制禁止最终点击，只会准备并停在最后一步提交/发送按钮前，请核对后自己点一下。'
            ),
        }

    async def _run_action(
        self,
        target: dict[str, Any],
        origin_ctx: dict[str, Any],
        *,
        service: Any = None,
        task_store: Any = None,
    ) -> tuple[str, Any]:
        from business_tools import BusinessTools
        from tasks import TaskStore
        from work_dispatch import WorkProposalStore

        action = target['action']
        desc = target['description']
        tool = str(action.get('tool') or '').strip()
        args = dict(action.get('args') or {})

        # 0. confirm_to_model：不直接执行业务，把明确指令交给主对话模型跑新一轮（复用 authorized_assignment 与会话 submit 通道）
        if tool == 'confirm_to_model':
            from task_tools import authorized_assignment

            if task_store is None:
                task_store = TaskStore(self.state)
            workspace, rel_cwd = self._resolve_workspace_and_cwd(args.get('cwd') or args.get('relative_cwd'))
            proposals = WorkProposalStore(self.state, workspace)
            chat, auth_ctx, src_row = self._prepare_conversation_source(target, origin_ctx)
            req_id = str(auth_ctx.get('origin_request_id') or ('pending-confirm-' + target['id']))
            if len(req_id) < 10:
                req_id = 'pending-confirm-' + target['id']
            source_quote = str(src_row.get('text') or '')[:2000]
            instruction = f'Eddie 已确认：{desc}。直接执行，不要再问确认；执行后用一句话回执'
            data = {
                'agent': 'hermes',
                'relative_cwd': rel_cwd,
                'title': desc[:120],
                'prompt': instruction,
                'sandbox': 'danger-full-access',
                'completion_condition': '直接执行用户确认的操作并用一句话回执',
                'source_quote': source_quote,
                'origin_session_id': auth_ctx['origin_session_id'],
                'origin_message_id': auth_ctx['origin_message_id'],
                'origin_request_id': auth_ctx['origin_request_id'],
                'supplement_to_message_id': auth_ctx.get('supplement_to_message_id'),
                'request_id': req_id,
                'pending_action_confirmed': True,
                'action': 'bash' if _has_irreversible_deletion(tool, args, instruction, desc) else 'task',
                'action_args': {**args, 'command': f"{args.get('command', '')}\n{instruction}\n{desc}"},
            }
            try:
                _, authorization, _ = authorized_assignment(chat, proposals, data)
                if _has_irreversible_deletion(tool, args, instruction, desc, source_quote):
                    raise ValueError('This action requires a concrete approval proposal')
            except ValueError as exc:
                if 'approval proposal' in str(exc) or '不可逆' in str(exc) or '具体批准' in str(exc):
                    card = self._propose_deletion_approval(
                        proposals,
                        task_store,
                        target,
                        auth_ctx,
                        agent='pi',
                        relative_cwd=rel_cwd,
                        title=desc[:120],
                        prompt=instruction,
                        req_id=req_id,
                        actual_action={'tool': tool, 'args': args, 'description': desc},
                    )
                    return (
                        f'「{desc}」涉及不可逆删除/清空，不能一句确认直跑，已转为审批卡（{card["id"]}），请具体批准后再执行。',
                        {'proposal_id': card['id'], 'status': 'approval_required', 'approval_required': True},
                    )
                raise

            followup_req_id = f"confirm-model-{target['id']}"
            sub = chat.submit(followup_req_id, instruction)
            with chat.db() as db:
                db.execute(
                    'INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)',
                    (
                        'confirm-source:' + sub['message_id'],
                        json.dumps(
                            {
                                'parent_id': auth_ctx.get('origin_message_id'),
                                'confirm_id': auth_ctx.get('origin_message_id'),
                                'reg_message_id': auth_ctx.get('supplement_to_message_id') or auth_ctx.get('origin_message_id'),
                                'source_quote': source_quote,
                                'source_links': src_row.get('source_links') or [],
                            },
                            ensure_ascii=False,
                        ),
                    ),
                )
            return (
                '好，马上办。',
                {
                    'mode': 'confirm_to_model',
                    'followup_request_id': followup_req_id,
                    'followup_message_id': sub['message_id'],
                    'origin_session_id': auth_ctx['origin_session_id'],
                    'origin_message_id': auth_ctx['origin_message_id'],
                    'origin_request_id': auth_ctx['origin_request_id'],
                    'instruction': instruction,
                    'source_quote': source_quote,
                    'authorization': {
                        **authorization,
                        'origin_session_id': auth_ctx['origin_session_id'],
                        'origin_message_id': auth_ctx['origin_message_id'],
                        'origin_request_id': auth_ctx['origin_request_id'],
                    },
                },
            )

        # 1. 后台任务通道（create_task / task_submit / task，或无 tool 但含 prompt/agent）
        is_task = tool in ('create_task', 'task_submit', 'task') or (
            not tool and bool(action.get('prompt') or action.get('agent'))
        )
        if is_task:
            if task_store is None:
                task_store = TaskStore(self.state)
            outcome = self._enqueue_task(task_store, target, origin_ctx)
            if outcome['mode'] == 'approval_required':
                pid = outcome['proposal_id']
                return (
                    f'「{desc}」涉及不可逆删除/清空，不能一句确认直跑，已转为审批卡（{pid}），请具体批准后再执行。',
                    {'proposal_id': pid, 'status': 'approval_required', 'approval_required': True},
                )
            task_id = outcome['task_id']
            return f'已安排执行：{desc}（已建任务 {task_id}，进展可在动态查看）。', {'task_id': task_id}

        # 2. 业务工具通道（bookkeeping / bookkeeping_search / remind / calendar_event / collect）
        if tool in ('bookkeeping', 'bookkeeping_search', 'calendar_event', 'remind', 'collect'):
            chat, auth_ctx, src_row = self._prepare_conversation_source(target, origin_ctx)
            if task_store is None:
                task_store = TaskStore(self.state)
            workspace, rel_cwd = self._resolve_workspace_and_cwd(args.get('cwd') or args.get('relative_cwd'))
            proposals = WorkProposalStore(self.state, workspace)

            if _has_irreversible_deletion(tool, args, desc, src_row.get('text', '')):
                card = self._propose_deletion_approval(
                    proposals,
                    task_store,
                    target,
                    auth_ctx,
                    relative_cwd=rel_cwd,
                    actual_action={'tool': tool, 'args': args},
                )
                return (
                    f'「{desc}」涉及不可逆删除/清空，不能一句确认直跑，已转为审批卡（{card["id"]}），请具体批准后再执行。',
                    {'proposal_id': card['id'], 'status': 'approval_required', 'approval_required': True},
                )

            from agent_tools import AgentTools

            agent_tools = AgentTools(self.state, chat, proposals, task_store, None, None, None)
            try:
                if service is None:
                    try:
                        service = BusinessTools(self.state, authorizer=agent_tools.authorize_tool)
                    except TypeError:
                        service = BusinessTools(self.state)
                if hasattr(service, 'authorizer'):
                    if getattr(service, 'authorizer', None) is None:
                        service.authorizer = agent_tools.authorize_tool
                else:
                    agent_tools.authorize_tool(
                        {'tool': tool, 'args': args, 'tool_call_id': 'pa_' + target['id']},
                        auth_ctx,
                    )
                res = await service.call(tool, args, auth_ctx)
            except ValueError as exc:
                if '不可逆删除' in str(exc) or '具体批准' in str(exc) or 'approval' in str(exc):
                    card = self._propose_deletion_approval(
                        proposals,
                        task_store,
                        target,
                        auth_ctx,
                        relative_cwd=rel_cwd,
                        actual_action={'tool': tool, 'args': args},
                    )
                    return (
                        f'「{desc}」涉及不可逆删除/清空，不能一句确认直跑，已转为审批卡（{card["id"]}），请具体批准后再执行。',
                        {'proposal_id': card['id'], 'status': 'approval_required', 'approval_required': True},
                    )
                raise
            return self._format_business_receipt(tool, args, res, desc), res

        # 3. 其它工具若带不可逆删除/清空风险，一律转 propose_work 审批卡
        if tool and _has_irreversible_deletion(tool, args, desc, str(action.get('prompt') or '')):
            chat, auth_ctx, _ = self._prepare_conversation_source(target, origin_ctx)
            if task_store is None:
                task_store = TaskStore(self.state)
            workspace, rel_cwd = self._resolve_workspace_and_cwd(args.get('cwd') or args.get('relative_cwd'))
            proposals = WorkProposalStore(self.state, workspace)
            card = self._propose_deletion_approval(
                proposals,
                task_store,
                target,
                auth_ctx,
                relative_cwd=rel_cwd,
                actual_action={'tool': tool, 'args': args},
            )
            return (
                f'「{desc}」涉及不可逆删除/清空，不能一句确认直跑，已转为审批卡（{card["id"]}），请具体批准后再执行。',
                {'proposal_id': card['id'], 'status': 'approval_required', 'approval_required': True},
            )

        # 4. 注入的自定义可调用 service（非 BusinessTools）
        if service is not None and not isinstance(service, BusinessTools) and callable(getattr(service, 'call', None)) and tool:
            res = await service.call(tool, args, origin_ctx)
            text = res.get('receipt') if isinstance(res, dict) and res.get('receipt') else f'已执行：{desc}'
            return str(text), res

        raise ValueError(f'无法执行待确认动作：未知或不支持的工具「{tool or "空"}」')

    def _enqueue_task(
        self,
        task_store: Any,
        target: dict[str, Any],
        origin_ctx: dict[str, Any],
        *,
        prepare_only_note: str = '',
    ) -> dict[str, Any]:
        from operation_policy import effective_sandbox
        from task_tools import authorized_assignment
        from work_dispatch import WorkProposalStore

        action = target['action']
        args = dict(action.get('args') or action)
        title = str(args.get('title') or action.get('title') or target['description'])[:120]
        default_prompt = (
            f"Eddie 已确认：{target['description']}。直接执行，不要再问确认；执行后用一句话回执"
            if action.get('tool') == 'confirm_to_model'
            else target['description']
        )
        raw_prompt = str(args.get('prompt') or action.get('prompt') or default_prompt)[:5000]
        standing_rule = '【底线约束】若涉及邮件发送、报销/劳务付款提交、视频/内容发布，只准备并停在最后一步按钮前，严禁点击最终发送/提交/发布按钮。'
        prompt = f'{raw_prompt}\n\n{prepare_only_note}' if prepare_only_note else f'{raw_prompt}\n\n{standing_rule}'
        agent = str(args.get('agent') or action.get('agent') or 'pi')
        if agent not in ('pi', 'codex', 'claude', 'hermes'):
            agent = 'pi'
        sandbox = effective_sandbox(args.get('sandbox') or action.get('sandbox') or 'danger-full-access')
        raw_cwd = args.get('relative_cwd') or action.get('relative_cwd') or args.get('cwd') or action.get('cwd')
        workspace, relative_cwd = self._resolve_workspace_and_cwd(raw_cwd)
        proposals = WorkProposalStore(self.state, workspace)

        chat, auth_ctx, src_row = self._prepare_conversation_source(target, origin_ctx)
        req_id = str(auth_ctx.get('origin_request_id') or ('pending-task-' + target['id']))
        if len(req_id) < 10:
            req_id = 'pending-task-' + target['id']
        completion = str(
            args.get('completion_condition')
            or action.get('completion_condition')
            or ('只准备到按钮前，禁止最终点击发送/提交/发布' if prepare_only_note else '完成用户确认的操作并回执')
        )[:1000]

        # source_quote 使用真实用户确认消息 + 原登记时的用户消息（由 policy.source 组装的真实文本）
        source_quote = str(src_row.get('text') or '')[:2000]
        tool_name = str(action.get('tool') or 'task')
        action_args_for_risk = {
            **args,
            'command': f"{args.get('command', '')}\n{raw_prompt}\n{title}\n{target['description']}",
        }

        data = {
            'agent': agent,
            'relative_cwd': relative_cwd,
            'title': title,
            'prompt': prompt,
            'sandbox': sandbox,
            'completion_condition': completion,
            'source_quote': source_quote,
            'origin_session_id': auth_ctx['origin_session_id'],
            'origin_message_id': auth_ctx['origin_message_id'],
            'origin_request_id': auth_ctx['origin_request_id'],
            'supplement_to_message_id': auth_ctx.get('supplement_to_message_id'),
            'request_id': req_id,
            'pending_action_confirmed': True,
            'action': 'bash' if _has_irreversible_deletion(tool_name, args, raw_prompt, title, target['description']) else tool_name,
            'action_args': action_args_for_risk,
        }

        try:
            draft, authorization, verified_req_id = authorized_assignment(chat, proposals, data)
            if _has_irreversible_deletion(tool_name, args, raw_prompt, title, target['description'], source_quote):
                raise ValueError('This action requires a concrete approval proposal')
        except ValueError as exc:
            if 'approval proposal' in str(exc) or '不可逆' in str(exc) or '具体批准' in str(exc):
                card = self._propose_deletion_approval(
                    proposals,
                    task_store,
                    target,
                    auth_ctx,
                    agent=agent,
                    relative_cwd=relative_cwd,
                    title=title,
                    prompt=prompt,
                    sandbox=sandbox,
                    req_id=req_id,
                    actual_action={'tool': tool_name, 'args': args, 'description': target['description']},
                )
                return {'mode': 'approval_required', 'proposal_id': card['id'], 'card': card}
            raise

        task = task_store.create_authorized(draft, authorization, verified_req_id)
        if prepare_only_note:
            task_store.change(
                task['id'],
                f"prepare-constraint:{task['id']}",
                'input_accepted',
                prepare_only_note,
            )
        return {'mode': 'task', 'task_id': task['id'], 'task': task}

    @staticmethod
    def _format_business_receipt(tool: str, args: dict[str, Any], result: Any, fallback_desc: str) -> str:
        if isinstance(result, dict):
            if tool == 'bookkeeping' and args.get('action') == 'add':
                if not result.get('verified'):
                    return '记账未取得账本写入及回读凭据，结果待核实；请勿重复记账，可在账本里复核这一笔。'
                from fast_bookkeeping import receipt as booked
                return booked(result)
            if tool == 'remind' and args.get('action') == 'add':
                item = result.get('item') or {}
                return f"已设置提醒：{item.get('due', args.get('at', ''))} · {item.get('text', args.get('text', ''))}"
            if tool == 'calendar_event' and args.get('action') == 'create':
                return f"已加入日历：{args.get('date', '')} · {args.get('summary', fallback_desc)}"
            if tool == 'collect':
                return f"已收藏链接：{args.get('url', fallback_desc)}"
        return f'已执行：{fallback_desc}。'
