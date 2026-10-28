// Com! 网页版核心：接口、数据缓存、实时流、发送队列、角色状态机。逻辑对照 iOS AppModel / AgentStageMachine / FlowCards。

export const BASE = location.pathname.replace(/\/web\/.*$/, '').replace(/\/web$/, '');
export const $ = (s, r = document) => r.querySelector(s);
export const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

// ─── 模板：插值一律转义，raw() 才原样输出 ───
const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ESC[c]);
class Raw { constructor(s) { this.s = s; } toString() { return this.s; } }
export const raw = (s) => new Raw(String(s ?? ''));
const fmt = (v) => (v == null || v === false ? '' : v instanceof Raw ? v.s : Array.isArray(v) ? v.map(fmt).join('') : esc(v));
export function html(strings, ...vals) {
  let out = '';
  strings.forEach((s, i) => { out += s; if (i < vals.length) out += fmt(vals[i]); });
  return new Raw(out);
}

// ─── 本地存储（所有读写都包 try，隐私窗口里照样能用） ───
export const store = {
  get(k, d = null) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* noop */ } },
  del(k) { try { localStorage.removeItem(k); } catch { /* noop */ } },
};
export const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => { const r = (Math.random() * 16) | 0; return (c === 'x' ? r : (r & 3) | 8).toString(16); })).toLowerCase();
export const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ─── 文案与格式（DesignSystem.swift） ───
export const agentName = (v) => ({ hermes: 'Hermes', pi: 'Pi', claude: 'Claude Code', codex: 'Codex' })[v] || v || '';
export const hostName = (v) => ({ mini: 'Mac mini', macbook: 'MacBook', mbp: 'MacBook' })[String(v || '').toLowerCase()] || (v || '');
export const sourceName = (s) => ({ gmail: 'Gmail', work_mail: '工作邮箱', github: 'GitHub', apple_calendar: 'Apple 日历', google_calendar: 'Google 日历', phone_calendar: '手机日历', phone_health: '手机健康', accounting: '账本', garmin: 'Garmin', com_task: 'Com 任务', goal: '个人目标', project_board: '工作', phone_reminders: '提醒事项', sms: '短信', plaud: '录音纪要', weather: '天气' })[s] || s || '';
export function textContent(v) {
  if (typeof v === 'string') return v;
  if (Array.isArray(v)) return v.map((p) => (p && p.text) || '').join('\n');
  return (v && v.text) || '';
}
export function relativeTime(sec) {
  if (!(sec > 0)) return '';
  const d = Date.now() / 1000 - sec;
  if (d < 60) return '刚刚';
  if (d < 3600) return `${Math.floor(d / 60)} 分钟前`;
  if (d < 86400) return `${Math.floor(d / 3600)} 小时前`;
  if (d < 86400 * 2) return '昨天';
  const t = new Date(sec * 1000); return `${t.getMonth() + 1}月${t.getDate()}日`;
}
export function clockTime(sec) {
  if (!(sec > 0)) return '';
  const t = new Date(sec * 1000); return `${String(t.getHours()).padStart(2, '0')}:${String(t.getMinutes()).padStart(2, '0')}`;
}
export const WEEK = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
export function dayLabel(d = new Date()) { return `${d.getMonth() + 1}月${d.getDate()}日 ${WEEK[d.getDay()].replace('星期', '周')}`; }
export function stampLabel(status, accepted = false) {
  if (accepted) return '已完成';
  return ({ queued: '执行中', dispatching: '执行中', running: '执行中', sending: '执行中', cancel_requested: '执行中', executing: '执行中', waiting: '等你回应', approval_required: '等待批准', awaiting_review: '等待批准', proposed: '等待批准', pending: '等待批准', paused: '已暂停', unknown: '结果未知', uncertain: '结果未知', execution_finished: '待验收', accepted: '已送达', delivered: '已送达', completed: '已完成', succeeded: '已完成', failed: '失败', rejected: '已拒绝', expired: '已过期', cancelled: '已取消', stopped: '已停止', idle: '空闲', ended: '已结束' })[status] || status || '';
}
export function statusTone(status, accepted = false) {
  if (accepted) return 'success';
  if (['completed', 'succeeded', 'accepted', 'delivered'].includes(status)) return 'success';
  if (['failed', 'rejected'].includes(status)) return 'danger';
  if (['waiting', 'approval_required', 'awaiting_review', 'proposed', 'pending', 'execution_finished', 'paused', 'unknown', 'uncertain'].includes(status)) return 'warning';
  if (['queued', 'dispatching', 'running', 'sending', 'executing', 'cancel_requested', 'active', 'working'].includes(status)) return 'info';
  return 'neutral';
}
export const yuan = (minor) => '¥' + Math.round((Number(minor) || 0) / 100).toLocaleString('zh-CN');
export function money(minor, currency) {
  const n = ((Number(minor) || 0) / 100).toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return (currency === 'CNY' ? '¥' : currency === 'USD' ? '$' : currency === 'UNKNOWN' ? '' : (currency || '') + ' ') + n;
}
export function durationText(seconds) {
  const s = Math.round(seconds);
  if (s < 1) return '不到 1 秒';
  if (s < 60) return `${s} 秒`;
  return s % 60 === 0 ? `${s / 60} 分钟` : `${Math.floor(s / 60)} 分 ${s % 60} 秒`;
}
export const seedOf = (id) => { let n = 0; for (const ch of String(id)) n = ((n * 31 + ch.codePointAt(0)) & 0xffff); return n; };

// ─── 轻量 Markdown → HTML（先转义；支持标题、粗体、斜体、行内码、代码块、列表、引用、链接、分隔线） ───
const INLINE = /(`[^`]+`)|(\*\*[^*]+\*\*)|(\[[^[\]]+\]\((https?:\/\/[^\s)]+)\))|(https?:\/\/[^\s<>()（）]+)/g;
export function inlineMd(text) {
  const s = String(text ?? '');
  let out = '', last = 0;
  for (const m of s.matchAll(INLINE)) {
    out += esc(s.slice(last, m.index));
    if (m[1]) out += `<code>${esc(m[1].slice(1, -1))}</code>`;
    else if (m[2]) out += `<strong>${esc(m[2].slice(2, -2))}</strong>`;
    else if (m[3]) out += `<a href="${esc(m[4])}" target="_blank" rel="noopener">${esc(m[3].slice(1, m[3].indexOf(']')))}</a>`;
    else out += `<a href="${esc(m[5])}" target="_blank" rel="noopener">${esc(m[5])}</a>`;
    last = m.index + m[0].length;
  }
  return out + esc(s.slice(last));
}
export function md(src) {
  const lines = String(src ?? '').split('\n');
  let out = '', code = null, list = null, quote = [];
  const closeList = () => { if (list) { out += `<${list.kind}>${list.items.map((i) => `<li>${i}</li>`).join('')}</${list.kind}>`; list = null; } };
  const closeQuote = () => { if (quote.length) { out += `<blockquote>${quote.map((q) => `<p>${inlineMd(q)}</p>`).join('')}</blockquote>`; quote = []; } };
  for (const rawLine of lines) {
    if (/^\s*```/.test(rawLine)) {
      if (code) { out += `<pre><code>${esc(code.join('\n'))}</code></pre>`; code = null; } else { closeList(); closeQuote(); code = []; }
      continue;
    }
    if (code) { code.push(rawLine); continue; }
    const h = rawLine.match(/^(#{1,4})\s+(.+)$/), ul = rawLine.match(/^\s*[-*•]\s+(.+)$/), ol = rawLine.match(/^\s*(\d+)[.)、]\s+(.+)$/), q = rawLine.match(/^>\s?(.*)$/);
    if (q) { closeList(); quote.push(q[1]); continue; }
    closeQuote();
    if (h) { closeList(); const lv = Math.min(h[1].length + 1, 4); out += `<h${lv}>${inlineMd(h[2])}</h${lv}>`; continue; }
    if (/^\s*(---+|\*\*\*+)\s*$/.test(rawLine)) { closeList(); out += '<hr>'; continue; }
    if (ul || ol) {
      const kind = ul ? 'ul' : 'ol';
      if (!list || list.kind !== kind) { closeList(); list = { kind, items: [] }; }
      list.items.push(inlineMd(ul ? ul[1] : ol[2]));
      continue;
    }
    closeList();
    if (!rawLine.trim()) continue;
    out += `<p>${inlineMd(rawLine)}</p>`;
  }
  if (code) out += `<pre><code>${esc(code.join('\n'))}</code></pre>`;
  closeList(); closeQuote();
  return raw(out);
}

// ─── 事件总线：数据变了就安排一次重画（同一帧合并） ───
const listeners = new Set();
export const onChange = (fn) => listeners.add(fn);
let pending = false;
const dirty = new Set();
export function changed(key = '*') {
  dirty.add(key);
  if (pending) return;
  pending = true;
  requestAnimationFrame(() => { pending = false; const keys = new Set(dirty); dirty.clear(); for (const fn of listeners) fn(keys); });
}

// ─── 全局状态 ───
export const S = {
  token: store.get('com.token', ''),
  tab: store.get('com.tab', 'chat'),
  conv: { revision: 0, messages: [], tasks: [], runs: [] },
  data: {}, fetchedAt: {}, errors: {},
  pending: (store.get('com.outbox', []) || []).map((e) => (e.state === 'checking' ? { ...e, state: 'uncertain', note: '上次送达待核实，先查询回执' } : e)),
  draft: sessionStorage.getItem('com.draft') || '',
  reference: null, attachments: [],
  sending: false, streaming: false, active: !document.hidden, moreHistory: true,
  banner: '',
};

// ─── 接口 ───
export class APIError extends Error { constructor(status, detail) { super(detail); this.status = status; } }
let onUnauthorized = () => {};
export const setUnauthorized = (fn) => { onUnauthorized = fn; };
export async function api(path, { body, method, headers, raw: rawBody, auth = true, timeout = 60000 } = {}) {
  const h = { Accept: 'application/json', ...(headers || {}) };
  if (auth) h.Authorization = 'Bearer ' + S.token;
  let payload;
  if (rawBody !== undefined) payload = rawBody;
  else if (body !== undefined) { h['Content-Type'] = 'application/json'; payload = JSON.stringify(body); }
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeout);
  let res;
  try {
    res = await fetch(BASE + path, { method: method || (payload !== undefined ? 'POST' : 'GET'), headers: h, body: payload, signal: ctl.signal });
  } catch (e) {
    throw new APIError(0, e.name === 'AbortError' ? '请求超时，Mac mini 暂时没回应' : '网络不通：连不上 Mac mini');
  } finally { clearTimeout(timer); }
  if (res.status === 401 && auth) { onUnauthorized(); throw new APIError(401, '配对已失效，请重新配对'); }
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = null; }
  if (!res.ok) throw new APIError(res.status, (data && data.detail && (typeof data.detail === 'string' ? data.detail : JSON.stringify(data.detail))) || `连接失败（${res.status}）`);
  return data;
}
/** 读一份数据进缓存（datasets）。返回数据或 null（错误记进 S.errors）。 */
const inflight = new Map();
export function load(path, { timeout = 45000 } = {}) {
  if (inflight.has(path)) return inflight.get(path);
  const p = (async () => {
    try {
      const data = await api(path, { timeout });
      const before = JSON.stringify(S.data[path] ?? null);
      S.data[path] = data; S.fetchedAt[path] = Date.now();
      const had = !!S.errors[path]; delete S.errors[path];
      if (had || JSON.stringify(data) !== before) { if (FLOW_PATHS.has(path)) recomputeFlow(); changed(path); }
      return data;
    } catch (e) {
      if (e.status !== 401) { S.errors[path] = e.message; changed(path); }
      return null;
    } finally { inflight.delete(path); }
  })();
  inflight.set(path, p);
  return p;
}
/** 写操作：带 request_id（幂等），失败给提示并抛出。 */
export async function mutate(path, fields = {}) {
  const body = { request_id: uuid(), ...fields };
  try { return await api(path, { body }); }
  catch (e) { toast('操作未确认：' + e.message); throw e; }
}
export async function action(path, fields, refreshTab) {
  try { await mutate(path, fields); if (refreshTab) await refresh(refreshTab); return true; } catch { return false; }
}

// ─── 提示 ───
let toastTimer = 0;
export function toast(msg, ms = 3200) {
  const el = $('#toast'); if (!el) return;
  el.textContent = msg; el.classList.add('on');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => el.classList.remove('on'), ms);
}

// ─── 等你拍板的事（FlowCards.swift） ───
export const FLOW_PATHS = new Set(['/personal/agency', '/personal/work/proposals?limit=20', '/personal/tasks', '/personal/connectors']);
export const D = (p) => S.data[p];
export const proposals = () => {
  const d = D('/personal/work/proposals?limit=20') || {};
  return (d.items || d.proposals || []).filter((r) => ['proposed', 'pending', 'approval_required'].includes(r.status));
};
export const tasks = () => (D('/personal/tasks') || {}).items || [];
export const goals = () => ((D('/personal/agency') || {}).goals || []).filter((g) => ['active', 'blocked', 'waiting_acceptance'].includes(g.status));
export const agencyCards = () => ((D('/personal/agency') || {}).cards || []).filter((c) => !['context', 'finance'].includes(c.kind));
export const decisionTasks = () => tasks().filter((t) => !t.interactive && (['waiting', 'approval_required', 'unknown', 'paused'].includes(t.status) || (t.status === 'execution_finished' && !t.acceptance_passed)));
export const runningTasks = () => tasks().filter((t) => ['queued', 'dispatching', 'running', 'cancel_requested'].includes(t.status));
export const brokenSources = () => ((D('/personal/connectors') || {}).sources || []).filter((s) => ['gmail', 'work_mail', 'google_calendar', 'apple_calendar'].includes(s.name) && ['needs_connection', 'unavailable'].includes(s.status) && s.enabled !== false);
export let flowItems = [];
export function recomputeFlow() {
  const items = [];
  for (const row of proposals()) {
    items.push({ id: 'proposal:' + row.id, kind: 'proposal', value: row, title: row.title, detail: row.prompt, source: '派活给 ' + agentName(row.agent || 'codex'), stamp: '等待批准', tone: 'warning', time: row.created_at || 0, primary: '批准' });
  }
  for (const row of decisionTasks().sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0))) {
    items.push({ id: 'task:' + row.id, kind: 'task', value: row, title: row.title, detail: row.completion_condition || '', source: agentName(row.agent), stamp: stampLabel(row.status), tone: statusTone(row.status), time: row.updated_at || 0, primary: row.status === 'execution_finished' ? '验收' : '看详情' });
  }
  const now = Date.now() / 1000;
  for (const it of items) it.stale = it.kind === 'task' && it.time > 0 && now - it.time > 7 * 86400;
  flowItems = items;
}
export const decisionCount = () => flowItems.filter((i) => (i.kind === 'proposal' || i.kind === 'task') && !i.stale).length;
export const staleItems = () => flowItems.filter((i) => i.stale);
export const nextData = () => D('/personal/next') || {};
export const nextItems = () => nextData().items || [];
export const nextUrgentCount = () => nextItems().filter((i) => i.urgency === 'now').length;
export const activeRuns = () => S.conv.runs.filter((r) => ['queued', 'sending', 'running'].includes(r.status));

// ─── 角色状态机（AgentStageMachine.swift）：快照定基线，送达是瞬时的，心跳只证明连接 ───
const STAGE_KINDS = new Set(['idle', 'thinking', 'working', 'review', 'delivered', 'failed', 'offline', 'searching', 'writing', 'remembering', 'calendar', 'handoff', 'waiting']);
export const isBusy = (s) => ['thinking', 'working', 'searching', 'writing', 'remembering', 'calendar', 'handoff'].includes(s);
export const stage = {
  state: 'offline', deliveryID: '', preview: '', activity: 'idle', baselined: false, seen: [],
  lastTraffic: 0, lastProgress: 0, deliveryStarted: 0,
  receive(name, data) {
    const now = Date.now() / 1000;
    this.lastTraffic = now;
    if (name === 'snapshot' || name === 'update') {
      if (name === 'snapshot' || !this.baselined) {
        this.baselined = true;
        this.seen = (data.messages || []).filter((m) => m.role === 'assistant' && m.status === 'completed').map((m) => m.id).slice(-200);
      }
      if (data.activity) this.apply(data.activity, now);
    } else if (name === 'task.progress' || name === 'task.review') this.apply(data, now);
    else if (name === 'agent.push') {
      const id = data.message_id || '';
      if (!id || this.seen.includes(id)) return this.tick();
      this.seen = [...this.seen, id].slice(-200);
      this.deliveryID = id; this.preview = data.preview || ''; this.deliveryStarted = now;
    }
    this.tick();
  },
  apply(data, now) { this.activity = STAGE_KINDS.has(data.kind) ? data.kind : 'working'; this.lastProgress = now; },
  disconnect() { this.set('offline'); },
  tick() {
    const now = Date.now() / 1000;
    let s;
    if (now - this.lastTraffic > 35) s = 'offline';
    else if (this.activity === 'review') s = 'review';
    else if (now - this.deliveryStarted < 2.8) s = 'delivered';
    else if (isBusy(this.activity) && now - this.lastProgress > 30) s = 'waiting';
    else s = this.activity;
    this.set(s);
  },
  set(s) { if (s !== this.state) { this.state = s; changed('stage'); } },
};
const STRIP = { idle: 'idle', thinking: 'think', waiting: 'think', working: 'exec', writing: 'exec', searching: 'read', remembering: 'read', calendar: 'read', handoff: 'send', review: 'ask', delivered: 'done', failed: 'broken', offline: 'broken' };
export function stripState() {
  if (!S.token) return 'idle';
  const st = stage.state;
  if (st === 'offline' || st === 'failed') return 'broken';
  if (st === 'review') return 'ask';
  if (st === 'delivered') return 'done';
  if (st === 'idle' || st === 'waiting') {
    if (decisionCount() > 0) return 'ask';
    if (brokenSources().length) return 'broken';
    return st === 'waiting' ? 'think' : 'idle';
  }
  return STRIP[st] || 'idle';
}
export function stripCaption() {
  if (!S.token) return '先连上 Mac mini';
  const st = stage.state, dc = decisionCount(), broken = brokenSources(), run = runningTasks().length;
  switch (st) {
    case 'offline': return '正在恢复连接';
    case 'failed': return '遇到了问题，看流里的说明';
    case 'delivered': return '已送达，在下面';
    case 'review': return '这一步等你点头';
    case 'idle': case 'waiting':
      if (dc + ((D('/personal/waiting') || {}).count || 0) > 0) return `${dc + ((D('/personal/waiting') || {}).count || 0)} 件等你`;  // 10-18 统一「等你」
      if (broken.length) return '读不到 ' + sourceName(broken[0].name) + ' 了';
      if (st === 'waiting') return '还在等新进展';
      if (nextUrgentCount() > 0) return `有 ${nextUrgentCount()} 件现在就该做`;
      return '在这儿，随时叫我';
    case 'searching': return '在翻找相关资料';
    case 'remembering': return '在想之前记下的事';
    case 'calendar': return '在看你的日程';
    case 'handoff': return '交给电脑上的伙伴';
    case 'thinking': return '在想怎么帮你办';
    default: return run ? `正在处理 · ${run} 件在跑` : '正在处理这件事';
  }
}
export function stripSign() {
  const st = stage.state;
  if (st === 'offline') return '连不上';
  if (st === 'failed') return '出错了';
  if (st === 'review' || decisionCount() > 0) return '等你点头';
  const b = brokenSources()[0];
  if (b) return b.name.includes('calendar') ? '日历断了' : '邮箱断了';
  return '';
}

// ─── 对话（ConversationState.swift） ───
export function mergeMessages(old, fresh) {
  const rows = new Map(old.filter((m) => m.id).map((m) => [m.id, m]));
  for (const m of fresh || []) {
    if (!m || !m.id) continue;
    const prev = rows.get(m.id);
    if (prev && (prev.revision || 0) > (m.revision || 0)) continue;
    rows.set(m.id, m);
  }
  return Array.from(rows.values()).sort((a, b) => ((a.created_at || 0) - (b.created_at || 0)) || (a.id < b.id ? -1 : 1));
}
export function applyConversation(data, snapshot) {
  if (!data) return;
  const next = data.revision || 0;
  if (next < S.conv.revision) return;
  S.conv.messages = mergeMessages(S.conv.messages, data.messages);
  S.conv.tasks = snapshot ? (data.tasks || []) : mergeMessages(S.conv.tasks, data.changed_tasks);
  if (data.runs) S.conv.runs = data.runs;
  S.conv.revision = next;
  changed('conversation');
}

// ─── 刷新（AppModel.refresh） ───
export async function refreshFlow() {
  await Promise.all(['/personal/agency', '/personal/work/proposals?limit=20', '/personal/tasks', '/personal/finance', '/personal/connectors'].map((p) => load(p)));
}
export async function refresh(tab) {
  load('/personal/waiting');  // 10-18：「等你」角标全局可见
  switch (tab) {
    case 'chat': { const d = await load('/personal/conversation'); if (d) applyConversation(d, true); break; }
    case 'next': await Promise.all([load('/personal/next'), load('/personal/connectors'), load('/personal/finance'), load('/personal/plan'), load('/personal/cases')]); break;
    case 'today': await Promise.all([refreshFlow(), load('/personal/today', { timeout: 60000 }), load('/personal/automations'), load('/personal/cases')]); break;
    case 'health': await Promise.all([load('/personal/health?days=30'), load('/personal/health/insight'), load('/personal/today'), load('/personal/next')]); break;
    case 'work': await Promise.all([load('/personal/projects'), load('/sessions')]); break;
  }
}
export async function refreshOthers() {
  await Promise.all([refreshFlow(), refresh('work'), load('/personal/next'), load('/health', {}), load('/personal/memory'), load('/personal/automations')]);
}

// ─── 实时流：fetch + ReadableStream 手写解析（EventSource 带不上 Authorization） ───
let streamCtl = null, failures = 0, reconnectTimer = 0;
export function stopStream() { if (streamCtl) { try { streamCtl.abort(); } catch { /* noop */ } streamCtl = null; } clearTimeout(reconnectTimer); }
export function startStream() {
  stopStream();
  const ctl = new AbortController(); streamCtl = ctl;
  const headers = { Authorization: 'Bearer ' + S.token, Accept: 'text/event-stream' };
  if (S.conv.revision > 0) headers['Last-Event-ID'] = String(S.conv.revision);
  let watchdog = 0;
  const arm = () => { clearTimeout(watchdog); watchdog = setTimeout(() => { try { ctl.abort(); } catch { /* noop */ } schedule(); }, 45000); };
  const schedule = () => {
    if (streamCtl !== ctl) return;
    S.streaming = false; stage.disconnect(); S.errors['/personal/conversation'] = '实时连接中断，正在恢复'; changed('conn');
    failures++; clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(() => { if (S.active && S.token) startStream(); }, Math.min(30000, 1000 * 2 ** Math.min(failures, 5)));
  };
  fetch(BASE + '/personal/conversation/stream', { headers, signal: ctl.signal }).then(async (res) => {
    if (res.status === 401) { onUnauthorized(); return; }
    if (!res.ok || !res.body) throw new Error('stream ' + res.status);
    failures = 0; arm();
    const reader = res.body.getReader(), dec = new TextDecoder();
    let buf = '';
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      arm();
      buf += dec.decode(value, { stream: true });
      if (buf.includes('\r')) buf = buf.replace(/\r\n/g, '\n');
      let i;
      while ((i = buf.indexOf('\n\n')) >= 0) { frame(buf.slice(0, i)); buf = buf.slice(i + 2); }
    }
    throw new Error('closed');
  }).catch(() => { clearTimeout(watchdog); if (!ctl.signal.aborted || streamCtl === ctl) schedule(); });
}
function frame(rawFrame) {
  let ev = 'message', data = '';
  for (const line of rawFrame.split('\n')) {
    if (!line || line[0] === ':') continue;
    const c = line.indexOf(':'), k = c < 0 ? line : line.slice(0, c), v = c < 0 ? '' : line.slice(c + 1).replace(/^ /, '');
    if (k === 'event') ev = v; else if (k === 'data') data += v;
  }
  let value = null;
  try { value = data ? JSON.parse(data) : {}; } catch { return; }
  if (['heartbeat', 'task.progress', 'task.review', 'agent.push'].includes(ev)) {
    stage.receive(ev, value || {});
    if (ev === 'agent.push' || ev === 'task.review') notifyLive(ev, value || {});
    if (!S.streaming) { S.streaming = true; changed('conn'); }
    return;
  }
  if (ev !== 'snapshot' && ev !== 'update') return;
  stage.receive(ev, value);
  applyConversation(value, ev === 'snapshot');
  S.streaming = true; delete S.errors['/personal/conversation']; changed('conn');
}
function notifyLive(name, value) {
  if (!document.hidden && S.tab === 'chat') return;
  try {
    if ('Notification' in window && Notification.permission === 'granted') {
      new Notification('Com', { body: value.preview || (name === 'task.review' ? '有一步等你确认' : '有新回复'), tag: 'com-' + (value.message_id || name) });
    }
  } catch { /* noop */ }
}

// ─── 发送队列（outbox）：先落本地，再按 request_id 幂等提交；结果不确定时只查回执，绝不重复提交 ───
export function persistOutbox() { store.set('com.outbox', S.pending.slice(-60)); }
const issuing = new Set();
function updatePending(id, patch) { const e = S.pending.find((x) => x.id === id); if (e) Object.assign(e, patch); persistOutbox(); changed('pending'); }
const receiptPath = (e) => (e.path === '/personal/conversation/messages' ? '/personal/conversation/receipts/' + encodeURIComponent(e.id) : '/receipts/' + encodeURIComponent(e.id));
export function queueMessage(text, extra = {}, path = '/personal/conversation/messages', requestID) {
  const id = requestID || uuid();
  const entry = { id, text, path, body: { ...extra, request_id: id, text }, state: 'queued', note: '等待发送', createdAt: Date.now() / 1000 };
  S.pending.push(entry); persistOutbox();
  return entry;
}
export async function send({ textOverride, matter } = {}) {
  const text = (textOverride ?? S.draft).trim();
  if (!text || (S.sending && textOverride == null)) return null;
  const extra = {};
  if (S.reference) extra.reference = S.reference;
  if (S.attachments.length) extra.attachment_ids = S.attachments.map((a) => a.id);
  if (matter) extra.matter_id = matter;
  const entry = queueMessage(text, extra);
  if (textOverride == null) { S.draft = ''; try { sessionStorage.removeItem('com.draft'); } catch { /* noop */ } }
  S.reference = null; S.attachments = [];
  S.lastSubmitted = entry.id;
  changed('pending'); changed('composer');
  await deliver(entry.id);
  return entry;
}
export async function deliver(id) {
  const entry = S.pending.find((e) => e.id === id);
  if (!entry || issuing.has(id) || entry.state === 'delivered') return;
  issuing.add(id); S.sending = true; changed('pending');
  try {
    if (entry.state !== 'queued') {
      try {
        const r = await api(receiptPath(entry));
        if (r && r.status === 'unknown') { updatePending(id, { note: '服务端结果待核实，不会重复提交' }); return; }
        updatePending(id, { state: 'delivered', note: '已受理' }); await refresh('chat'); return;
      } catch (e) { if (e.status !== 404) throw e; }
    }
    updatePending(id, { state: 'checking', note: '正在发送' });
    const r = await api(entry.path, { body: entry.body });
    if (r && r.status === 'unknown') updatePending(id, { state: 'uncertain', note: '送达待核实' });
    else if (r && r.status === 'rejected') updatePending(id, { state: 'rejected', note: r.error || '没送出去' });
    else updatePending(id, { state: 'delivered', note: '已受理' });
    await refresh('chat');
  } catch (e) {
    const rejected = e.status >= 400 && e.status < 500 && e.status !== 408 && e.status !== 429;
    updatePending(id, { state: rejected ? 'rejected' : 'uncertain', note: e.message });
  } finally {
    issuing.delete(id); S.sending = issuing.size > 0; changed('pending');
  }
}
export async function deliverWork(id) {
  const entry = S.pending.find((e) => e.id === id);
  if (!entry || issuing.has(id)) return null;
  issuing.add(id);
  try {
    let r;
    if (entry.state === 'queued') { updatePending(id, { state: 'checking' }); r = await api(entry.path, { body: entry.body, timeout: 90000 }); }
    else r = await api(receiptPath(entry));
    if (r && r.status === 'accepted') updatePending(id, { state: 'delivered', note: '已受理' });
    else if (r && r.status === 'rejected') updatePending(id, { state: 'rejected', note: r.error || '没送出去' });
    else updatePending(id, { state: 'uncertain', note: '结果待核实，不会重复提交' });
    refresh('work');
    return r;
  } catch (e) {
    updatePending(id, { state: 'uncertain', note: e.message });
    return null;
  } finally { issuing.delete(id); }
}
export function queueWork(path, text, fields) {
  if (S.pending.some((e) => e.path === path && ['queued', 'checking', 'uncertain'].includes(e.state))) throw new APIError(409, '此会话还有送达待核实的请求，请先在设置的发送记录里查询回执');
  return queueMessage(text, fields, path);
}
export async function recoverOutbox() {
  for (const e of S.pending.filter((x) => ['queued', 'uncertain', 'checking'].includes(x.state))) {
    if (e.path.startsWith('/sessions')) await deliverWork(e.id); else await deliver(e.id);
  }
}
export function removeRejected(id) { S.pending = S.pending.filter((e) => !(e.id === id && e.state === 'rejected')); persistOutbox(); changed('pending'); }
export function restoreRejected(id) {
  const e = S.pending.find((x) => x.id === id && x.state === 'rejected');
  if (!e || S.draft) return;
  S.draft = e.text; S.reference = e.body.reference || null;
  S.attachments = (e.body.attachment_ids || []).map((v, i) => ({ id: v, name: '附件 ' + (i + 1) }));
  removeRejected(id); changed('composer');
}
export async function interrupt() {
  if (!isBusy(stage.state)) return;
  try { await api('/personal/conversation/interrupt', { body: {} }); stage.receive('task.progress', { kind: 'idle' }); toast('已中断'); }
  catch (e) { toast('中断失败：' + e.message); }
}
export async function loadHistory() {
  const first = S.conv.messages[0];
  if (!S.moreHistory || !first) return 0;
  const page = await load('/personal/conversation/history?before=' + encodeURIComponent(first.id) + '&limit=60');
  if (!page) return 0;
  const before = S.conv.messages.length;
  S.conv.messages = mergeMessages(S.conv.messages, page.messages || page.items);
  S.moreHistory = !!page.has_more; changed('conversation');
  return S.conv.messages.length - before;
}
export async function locateMessage(id) {
  if (!S.conv.messages.some((m) => m.id === id)) {
    const page = await load('/personal/conversation/history?around=' + encodeURIComponent(id) + '&limit=60');
    if (page) { S.conv.messages = mergeMessages(S.conv.messages, page.messages || page.items); changed('conversation'); }
  }
  S.jumpMessage = id; setTab('chat');
}

// ─── 切页 ───
let tabHandler = () => {};
export const onTab = (fn) => { tabHandler = fn; };
export function setTab(tab) {
  if (S.tab === tab) { tabHandler(tab, true); return; }
  S.tab = tab; store.set('com.tab', tab);
  tabHandler(tab, false);
  refresh(tab);
}

// ─── 下一步（NextView.swift） ───
export async function nextAction(item, act, reason) {
  try {
    await mutate('/personal/next/' + encodeURIComponent(item.id), { action: act, ...(reason ? { reason } : {}) });
    await load('/personal/next');
    if (act === 'discuss') { setTab('chat'); await refresh('chat'); }
  } catch { /* toast already */ }
}
export async function refreshNext() {
  try {
    await mutate('/personal/next/refresh');
    const d = { ...(nextData()), running: true }; S.data['/personal/next'] = d; changed('/personal/next');
    for (let i = 0; i < 60; i++) {
      await sleep(2000);
      const data = await load('/personal/next');
      if (data && !data.running) break;
    }
  } catch { /* toast already */ }
}
