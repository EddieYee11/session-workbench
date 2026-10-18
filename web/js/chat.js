// 「Com」主对话页：对照 iOS ChatView / WorkProcess / SuggestionChips / ComposerView / VoiceViews。
import {
  S, $, html, raw, esc, md, textContent, clockTime, changed, onChange, send, deliver, restoreRejected, interrupt, loadHistory,
  stage, isBusy, api, uuid, toast, durationText, seedOf, store, setTab, tasks, stampLabel, statusTone,
} from './core.js';
import { icon, act, stamp, openSheet } from './ui.js';

// ─── 工作过程（WorkProcess.swift）：工具名 → 类别 → 口语化说法，同类连续步骤合并 ───
const STEP_TABLE = [
  ['ledger', ['bookkeeping_search', 'finance', 'ledger', 'expense_search']],
  ['money', ['bookkeeping', 'expense', 'business_operation']],
  ['remember', ['memory_save', 'memory_write', 'memory_update', 'retain', 'remember']],
  ['recall', ['memory_recall', 'memory_read', 'memory_search', 'recall', 'memory']],
  ['remind', ['remind', 'reminder', 'alarm']],
  ['calendar', ['calendar', 'schedule', 'event']],
  ['check', ['task_status', 'get_task', 'work_proposal_status', 'recent_work_sessions', 'list_tasks']],
  ['task', ['task_submit', 'create_task', 'propose_work', 'task_send', 'update_task', 'cancel_task', 'dispatch']],
  ['overview', ['personal_overview', 'personal_briefing', 'briefing', 'overview']],
  ['mail', ['gmail', 'mail', 'email']],
  ['device', ['device_call', 'health', 'contacts', 'device']],
  ['web', ['web_search', 'web_extract', 'websearch', 'webfetch', 'browser', 'fetch', 'http', 'url']],
  ['edit', ['edit', 'write', 'patch', 'file_write', 'write_file', 'apply_patch', 'multiedit']],
  ['search', ['grep', 'find', 'glob', 'ls', 'search_files', 'search', 'rg']],
  ['read', ['read', 'read_file', 'context_read', 'cat', 'view', 'open']],
  ['shell', ['bash', 'terminal', 'shell', 'exec', 'run_command', 'command', 'process']],
];
export function stepKind(tool) {
  const name = String(tool || '').toLowerCase().split('__').pop();
  if (['react_to_user_message', 'react', 'think'].includes(name)) return null;
  let hit = STEP_TABLE.find(([, keys]) => keys.includes(name));
  if (!hit) hit = STEP_TABLE.find(([, keys]) => keys.some((k) => k.length > 3 && name.includes(k)));
  return hit ? hit[0] : 'other';
}
export const STEP_LIVE = {
  search: ['正在翻资料', '在资料堆里找线索', '四处翻翻看'], read: ['正在读文件', '打开文件细看', '逐行过一遍'], web: ['上网查一查', '正在搜网页', '去网上找答案'],
  shell: ['在电脑上跑命令', '敲几行命令', '让电脑动起来'], edit: ['正在改文件', '动笔修改', '把改动写进去'], recall: ['翻翻记忆', '想想你说过的', '回忆一下'],
  remember: ['记到小本本上', '把这件事记下', '写进记忆里'], ledger: ['翻账本', '查查花销', '对一下账'], money: ['正在记账', '记上一笔', '拨拉算盘'],
  calendar: ['看看日程', '翻一下日历', '对一下时间'], remind: ['定个提醒', '帮你记着时间', '设一个闹钟'], task: ['派活给电脑', '找帮手接手', '安排任务'],
  check: ['看看进度', '问问帮手做到哪了', '核对进展'], device: ['问问你的手机', '在手机上查', '用一下手机'], overview: ['扫一眼今天', '看看总览', '翻今天的摘要'],
  mail: ['翻邮件', '看看信箱', '拆封邮件'], other: ['动手处理', '在忙这一步', '处理一下'],
};
export function stepDone(kind, n) {
  const c = n === 1 ? '一' : ` ${n} `;
  return ({
    search: `翻了${c}处资料`, read: `读了${c}个文件`, web: `查了${c}个网页`, shell: `跑了${c}条命令`, edit: `改了${c}处文件`,
    recall: n === 1 ? '翻了翻记忆' : `翻了 ${n} 次记忆`, remember: `记下了${c}件事`, ledger: n === 1 ? '查了账本' : `查了 ${n} 次账本`, money: `记了${c}笔账`,
    calendar: n === 1 ? '看了日程' : `看了 ${n} 次日程`, remind: `定了${c}个提醒`, task: `派了${c}件活`, check: n === 1 ? '核对了进度' : `核对了 ${n} 次进度`,
    device: n === 1 ? '用了手机' : `用了 ${n} 次手机`, overview: '看了总览', mail: n === 1 ? '翻了邮箱' : `翻了 ${n} 次邮箱`,
  })[kind] || `做了${c}件事`;
}
export const STEP_ICON = { search: 'search', read: 'doc', web: 'globe', shell: 'terminal', edit: 'pencil', recall: 'book', remember: 'book', ledger: 'yen', money: 'yen', calendar: 'calendar', remind: 'bell', task: 'send', check: 'checklist', device: 'iphone', overview: 'sun', mail: 'envelope', other: 'sparkles' };
const ACTIVE = new Set(['queued', 'sending', 'running']);
export function workProcess(m) {
  if (m.role !== 'user') return null;
  const live = ACTIVE.has(m.status);
  const steps = (m.tasks || []).filter((t) => t.kind === 'tool' || String(t.id || '').startsWith('tool-')).map((t) => ({ id: t.id, tool: t.tool || '', kind: stepKind(t.tool), status: t.status, started: t.started_at || 0, finished: t.finished_at || 0 })).filter((s) => s.kind);
  // 10-17：这一轮的 todo 清单（后端 turn_planner / Hermes turn_plan，tasks 里 kind=plan）。有它就替代工具日志当思考过程。
  const planEntry = (m.tasks || []).find((t) => t.kind === 'plan' && (t.todos || []).length);
  const plan = planEntry ? {
    title: planEntry.title || '',
    steps: planEntry.todos.map((t) => ({ text: t.content, status: { completed: 'done', in_progress: 'doing', blocked: 'blocked', skipped: 'skipped' }[t.status] || 'todo' })),
    active: (planEntry.todos.find((t) => t.status === 'in_progress') || {}).active || '',
  } : null;
  if (plan) plan.done = plan.steps.filter((x) => x.status === 'done').length;
  if (!live && !steps.length && !plan) return null;
  const groups = [];
  for (const s of steps) { const g = groups[groups.length - 1]; if (g && g.kind === s.kind) g.steps.push(s); else groups.push({ kind: s.kind, steps: [s] }); }
  for (const g of groups) {
    g.id = g.steps[0].id; g.running = g.steps.some((s) => s.status === 'running'); g.failures = g.steps.filter((s) => s.status === 'failed').length;
    const seed = seedOf(g.id);
    g.liveText = g.steps.length > 1 ? stepDone(g.kind, g.steps.length) + '…' : STEP_LIVE[g.kind][seed % 3];
    g.doneText = g.failures ? stepDone(g.kind, g.steps.length) + ` · ${g.failures} 步没走通` : stepDone(g.kind, g.steps.length);
    const order = [], counts = {};
    for (const s of g.steps) { const n = s.tool.split('__').pop(); if (!(n in counts)) order.push(n); counts[n] = (counts[n] || 0) + 1; }
    g.detail = order.map((n) => (counts[n] > 1 ? `${n} ×${counts[n]}` : n)).join(' · ');
  }
  const start = m.received_at > 0 ? m.received_at : m.created_at || 0;
  const end = Math.max(0, ...steps.map((s) => s.finished));
  const seed = seedOf(m.id);
  const last = groups[groups.length - 1];
  let current;
  if (plan && live && plan.active) current = plan.active;
  else if (last && last.running) current = last.liveText;
  else if (m.phase === 'responding' || m.phase === 'speaking') current = ['在组织回复', '开始写回复', '把结果理一理'][seed % 3];
  else if (!groups.length) current = ['在想怎么办', '先理一理思路', '琢磨一下'][seed % 3];
  else current = ['想想下一步', '接着往下做', '看看还缺什么'][(seed + groups.length) % 3];
  const secs = (m.summary && m.summary.duration_ms) > 0 ? m.summary.duration_ms / 1000 : Math.max(0, Math.max(end, start) - start);
  const summary = plan ? `${plan.title ? plan.title + ' · ' : ''}${plan.done}/${plan.steps.length} 步 · ` + durationText(secs) : `做了 ${steps.length} 步 · 用时 ` + durationText(secs);
  return { groups, live, start, current, summary, plan, toolCount: steps.length, messageID: m.id, isCase: !!plan && plan.steps.length >= 3 };
}
/** 顶栏人物旁手绘气泡里的字（AppModel.workBubble）。 */
export function workBubble() {
  const m = [...S.conv.messages].reverse().find((x) => x.role === 'user' && ACTIVE.has(x.status));
  const p = m && workProcess(m);
  if (p) return p.current;
  return isBusy(stage.state) ? null : '';
}

// ─── 选项标记（SuggestionChips.swift） ───
const FULL = /\s*\[\[\s*选项\s*[:：]([^[\]]*)\]\]\s*$/;
export function splitOptions(text) {
  const m = text.match(FULL);
  if (m) {
    const opts = [];
    for (const rawOpt of m[1].split(/[|｜]/)) { const o = rawOpt.trim().replace(/^[「"']+|[」"']+$/g, ''); if (o && o.length <= 16 && !opts.includes(o)) opts.push(o); }
    return [text.slice(0, m.index).trim(), opts.slice(0, 3)];
  }
  const b = text.lastIndexOf('[');
  if (b < 0) return [text, []];
  let start = b; while (start > 0 && text[start - 1] === '[') start--;
  const tail = text.slice(start).replace(/\s/g, '').replace('：', ':');
  if (!tail.includes(']') && ('[[选项'.startsWith(tail) || tail.startsWith('[[选项'))) return [text.slice(0, start).trim(), []];
  return [text, []];
}
const optionsFor = (m) => { const f = (m.suggestions || []).filter(Boolean); return f.length ? f.slice(0, 3) : splitOptions(textContent(m.text))[1]; };
const optionIcon = (o) => (/先不|不用|算了|跳过|不管|取消|以后/.test(o) ? 'hand' : /看|查|详情|日志|明细|展开/.test(o) ? 'eye' : /记|提醒|盯/.test(o) ? 'bell' : 'arrowUpRight');

// ─── 时间线（ChatTimeline.swift）：服务器消息 + 本地还没回声的发送 ───
function timelineRows() {
  const msgs = S.conv.messages;
  const requests = new Set(msgs.filter((m) => m.role === 'user' && m.request_id).map((m) => m.request_id));
  const rows = msgs.map((m) => ({ id: m.role === 'user' && m.request_id ? 'request:' + m.request_id : m.id, message: m, pending: null }));
  for (const e of S.pending) {
    if (e.path !== '/personal/conversation/messages' || requests.has(e.id)) continue;
    const att = (e.body.attachment_ids || []).map((v, i) => ({ id: v, name: '附件 ' + (i + 1) }));
    rows.push({ id: 'request:' + e.id, message: { id: 'request:' + e.id, role: 'user', text: e.text, created_at: e.createdAt, reference: e.body.reference, attachments: att }, pending: e });
  }
  return rows.sort((a, b) => ((a.message.created_at || 0) - (b.message.created_at || 0)) || (a.id < b.id ? -1 : 1));
}

const DELIVERY = { queued: '已送达 · 排队中', sending: '已送达 · 正在处理', running: '已送达 · 执行中', completed: '已送达', failed: '本轮失败', unknown: '结果未知', approval_required: '等待批准', cancelled: '已停止' };
function deliveryLine(m, pending, process) {
  if (pending) {
    const st = pending.state;
    return html`<div class="delivery ${st === 'rejected' ? 'danger' : ''}">${st === 'checking' ? raw('<i class="spin"></i>') : ''}<span>${st === 'delivered' ? '已受理 · 正在同步' : pending.note}</span>
      ${st === 'uncertain' ? html`<button class="link" data-act="chat-receipt" data-id="${pending.id}">查回执</button>` : ''}
      ${st === 'rejected' && !S.draft ? html`<button class="link" data-act="chat-restore" data-id="${pending.id}">回到草稿</button>` : ''}</div>`;
  }
  if (!m.status || (process && process.live && ['sending', 'running'].includes(m.status))) return '';
  const bad = m.status === 'failed' || m.status === 'unknown';
  return html`<div class="delivery ${bad ? 'warn' : ''}">${icon(bad ? 'warning' : 'check')}<span>${DELIVERY[m.status] || '已送达'}</span></div>`;
}
/** todo 清单（航程详情和思考过程共用）。status：todo / doing / done / blocked / skipped。 */
export function checklist(steps, live = true) {
  const mark = { done: 'checkCircle', blocked: 'warning' };
  return html`<div class="checklist">${steps.map((x) => html`<div class="check-step ${x.status} ${live ? 'live' : ''}">${x.status === 'doing' && live ? raw('<i class="pulse"></i>') : x.status in mark ? icon(mark[x.status]) : raw('<i class="ring"></i>')}<span>${x.text}</span></div>`)}</div>`;
}
export function processRow(p, open, key, extra = []) {
  if (p.plan) {
    // todo 清单就是思考过程；工具细节不再露出来
    const body = open ? html`<div class="steps">${checklist(p.plan.steps, p.live)}
      ${p.toolCount ? html`<small class="muted small tool-count">动用了 ${p.toolCount} 次工具</small>` : ''}
      ${p.isCase ? html`<button class="link case-link" data-act="case-open" data-id="turn:${p.messageID}">${icon('layers')}在航程里回看</button>` : ''}${extra}</div>` : '';
    const head = p.live
      ? html`<i class="pulse"></i>${p.plan.title ? html`<b class="plan-title">${p.plan.title}</b><small class="mono muted">${p.plan.done}/${p.plan.steps.length}</small>` : ''}<span class="cur">${p.current}</span><span class="elapsed" data-since="${p.start}"></span>`
      : html`${icon(p.isCase ? 'layers' : 'checkCircle')}<span class="sum">${p.summary}</span>`;
    return html`<div class="process ${p.live ? 'live' : ''}"><button class="process-head" data-act="toggle-process" data-key="${key}">${head}${icon('right', open ? 'rot' : '')}</button>${body}</div>`;
  }
  const steps = open ? html`<div class="steps">${p.groups.map((g, i) => {
    const live = p.live && i === p.groups.length - 1 && g.running;
    const s0 = g.steps[0].started, s1 = Math.max(...g.steps.map((s) => s.finished));
    return html`<div class="step ${live ? 'live' : ''} ${g.failures ? 'warn' : ''}">${icon(STEP_ICON[g.kind])}<div><b>${live ? g.liveText : g.doneText}</b></div>${!live && s0 > 0 && s1 > s0 ? html`<em>${durationText(s1 - s0)}</em>` : ''}</div>`;
  })}${p.groups.length ? '' : html`<p class="muted small">还没动用工具，先在想。</p>`}${extra}</div>` : '';
  const head = p.live
    ? html`<i class="pulse"></i><span class="cur">${p.current}</span><span class="elapsed" data-since="${p.start}"></span>`
    : html`${icon('checkCircle')}<span class="sum">${p.summary}</span>`;
  return html`<div class="process ${p.live ? 'live' : ''}"><button class="process-head" data-act="toggle-process" data-key="${key}">${head}${icon('right', open ? 'rot' : '')}</button>${steps}</div>`;
}
const AGENT_EVENT = (e) => {
  if (e.display_text) return e.display_text;
  const kind = e.kind || e.type || '', st = e.status;
  if (kind.endsWith('.failed') || st === 'failed') return '这一步遇到了问题，查看详情';
  if (['unknown', 'uncertain'].includes(st)) return '结果还在核实';
  if (['approval_required', 'awaiting_review', 'task.review'].includes(kind) || ['approval_required', 'awaiting_review'].includes(st)) return '这一步需要你确认';
  if (kind.endsWith('.completed') || ['completed', 'done', 'execution_finished'].includes(st)) return '这一步已结束，可查看记录';
  if (kind.includes('cancel') || st === 'cancelled') return '正在停止或已停止，查看记录';
  return '正在处理，请稍候';
};
export const eventLabel = AGENT_EVENT;
export function stepRow(text, state, time = '') {
  return html`<div class="steprow ${state}"><i></i><span>${text}</span>${time ? html`<em>${time}</em>` : ''}</div>`;
}
export function stepState(e) {
  const kind = e.kind || e.type || '', st = e.status;
  if (kind.endsWith('.failed') || st === 'failed') return 'blocked';
  if (['approval_required', 'awaiting_review', 'task.review'].includes(kind) || ['approval_required', 'awaiting_review'].includes(st)) return 'blocked';
  if (kind.endsWith('.completed') || ['completed', 'done', 'execution_finished'].includes(st)) return 'done';
  return 'current';
}
export function taskSummary(t) {
  const passed = !!t.acceptance_passed;
  return html`<button class="task-pill" data-act="open-task" data-id="${t.id}">${icon('checklist')}<span>${t.title || '任务'}</span>${stamp(stampLabel(t.status, passed), statusTone(t.status, passed))}</button>`;
}

const openProcess = new Set();
function messageHTML(row, prevAgent) {
  const m = row.message, user = m.role === 'user';
  const text = user ? textContent(m.text ?? m.content) : splitOptions(textContent(m.text ?? m.content))[0];
  const process = workProcess(m);
  const taskEvents = (m.work_events || []).filter((e) => !String(e.id || '').startsWith('tool-') && !['think', 'reply'].includes(e.id));
  const ref = m.reference ? html`<div class="quote"><b>${m.reference.author || ''}</b><span>${m.reference.text || ''}</span></div>` : '';
  const atts = (m.attachments || []).map((a) => html`<span class="att">${icon('paperclip')}${a.name || '附件'}</span>`);
  const bubble = user
    ? html`<div class="bubble user">${text}</div>`
    : html`<div class="bubble agent ${prevAgent ? 'cont' : ''} md">${md(text)}</div>`;
  const evs = !process && taskEvents.length ? html`<details class="note-surface events"><summary>工作过程 · ${taskEvents.length}</summary>${taskEvents.slice(-12).map((e, i, arr) => stepRow(AGENT_EVENT(e), i < arr.length - 1 ? 'done' : stepState(e), clockTime(e.at)))}</details>` : '';
  const arts = (m.artifacts || []).length ? html`<div class="arts">${m.artifacts.map((a) => html`<button class="att art" data-act="open-artifact" data-path="${a.path || ''}" data-id="${a.id || ''}" data-name="${a.name || ''}">${icon(String(a.mime || '').startsWith('image') ? 'photo' : 'doc')}${a.name || String(a.path || '').split('/').pop()}</button>`)}</div>` : '';
  const extra = taskEvents.slice(-8).map((e, i, arr) => stepRow(AGENT_EVENT(e), i < arr.length - 1 ? 'done' : stepState(e), clockTime(e.at)));
  return html`<div class="msg ${user ? 'me' : 'it'}" data-row="${row.id}" data-mid="${m.id}">
    <div class="col">${ref}${bubble}${atts.length ? html`<div class="atts">${atts}</div>` : ''}
      ${user ? deliveryLine(m, row.pending, process) : ''}
      ${m.error ? html`<div class="notice danger small">${icon('warning')}<span>${m.error}</span></div>` : ''}
      ${(m.linked_tasks || []).map(taskSummary)}${evs}${arts}
      <div class="msg-tools"><button data-act="msg-copy" title="复制">${icon('copy')}</button>${row.pending ? '' : html`<button data-act="msg-reply" title="回复">${icon('reply')}</button>`}<time>${clockTime(m.created_at)}</time></div>
    </div>
    ${process ? processRow(process, openProcess.has(m.id) || false, m.id, extra) : ''}
  </div>`;
}

// ─── 页面 ───
let win = 30, rendered = new Map(), unread = new Set(), knownAssist = new Set(), atBottom = true, usedSuggestion = '', mounted = false;
export function mountChat(root) {
  root.innerHTML = html`<div class="chat">
    <div class="chat-scroll" id="chatScroll"><div class="chat-inner" id="chatInner">
      <div id="chatTop"></div><div id="chatList"></div><div id="chatSuggest"></div><div id="chatEnd"></div>
    </div></div>
    <button class="jump glass hidden" id="chatJump" data-act="chat-jump"></button>
    <div class="chat-bottom">
      <div id="interruptRow"></div>
      <div class="composer-wrap" id="composerWrap"></div>
    </div>
  </div>`.s;
  const sc = $('#chatScroll');
  sc.addEventListener('scroll', () => {
    const near = sc.scrollHeight - sc.scrollTop - sc.clientHeight < 70;
    if (near !== atBottom) { atBottom = near; if (near) unread.clear(); renderJump(); }
  }, { passive: true });
  renderComposer();
  mounted = true;
  renderChat(true);
}
function renderJump() {
  const j = $('#chatJump'); if (!j) return;
  j.classList.toggle('hidden', atBottom);
  j.innerHTML = html`${unread.size ? html`<b>${unread.size} 条新回复</b>` : ''}${icon('arrowDown')}`.s;
}
export function scrollBottom(smooth) {
  const sc = $('#chatScroll'); if (!sc) return;
  sc.scrollTo({ top: sc.scrollHeight, behavior: smooth && !matchMedia('(prefers-reduced-motion: reduce)').matches ? 'smooth' : 'auto' });
}
export function renderChat(first = false) {
  if (!mounted) return;
  const list = $('#chatList'), sc = $('#chatScroll');
  const all = timelineRows();
  const rows = all.slice(-win);
  // 新回复：不在底部时记未读
  const assistants = new Set(S.conv.messages.filter((m) => m.role === 'assistant').map((m) => m.id));
  for (const id of assistants) if (!knownAssist.has(id) && !first && !atBottom) unread.add(id);
  knownAssist = assistants;
  const wasBottom = atBottom || first;
  const prevH = sc.scrollHeight, prevTop = sc.scrollTop;
  const firstBefore = list.firstElementChild && list.firstElementChild.dataset.row;
  const seen = new Set();
  let prev = null, prevAgent = false;
  for (const row of rows) {
    const m = row.message;
    const sig = [m.status, m.phase, (m.text || '').length, m.revision, (m.tasks || []).length, JSON.stringify((m.tasks || []).slice(-1)), row.pending && row.pending.state, row.pending && row.pending.note, prevAgent, openProcess.has(m.id), (m.linked_tasks || []).map((t) => t.status).join(), (m.work_events || []).length, m.error].join('|');
    let entry = rendered.get(row.id);
    if (!entry || entry.sig !== sig) {
      const wrap = document.createElement('div');
      wrap.innerHTML = messageHTML(row, prevAgent).s;
      const el = wrap.firstElementChild;
      if (!entry && !first) el.classList.add(m.role === 'user' ? 'fly' : 'arrive');
      if (entry) entry.el.replaceWith(el);
      entry = { el, sig }; rendered.set(row.id, entry);
    }
    seen.add(row.id);
    const want = prev ? prev.nextSibling : list.firstChild;
    if (want !== entry.el) list.insertBefore(entry.el, want);
    prev = entry.el;
    prevAgent = m.role === 'assistant';
  }
  for (const [id, e] of rendered) if (!seen.has(id)) { e.el.remove(); rendered.delete(id); }
  // 顶部：更早的对话 / 空状态
  const top = $('#chatTop');
  const more = (win < all.length || S.moreHistory) && S.conv.messages.length;
  top.innerHTML = (S.conv.messages.length || all.length) ? (more ? html`<button class="btn secondary small center" data-act="chat-older">更早的对话</button>`.s : '')
    : html`<div class="chat-empty"><h2>今天还没有要你管的事</h2><p>邮件、日历、群消息和两台电脑我都在看。有变化，我会先整理好放到这里。</p>
      <div class="chips">${['明天要准备什么', '这个月花了多少', 'Codex 跑完了吗'].map((p) => html`<button class="chip" data-act="chat-prompt" data-text="${p}">${p}</button>`)}</div></div>`.s;
  // 建议卡：只挂在最后一条已完成的助手回复下面
  const last = rows[rows.length - 1];
  const host = last && !last.pending && last.message.role === 'assistant' && !['streaming', 'running', 'failed', 'unknown'].includes(last.message.status) ? last.message : null;
  const opts = host && host.id !== usedSuggestion ? optionsFor(host) : [];
  const sug = $('#chatSuggest');
  const key = host ? host.id + opts.join('|') : '';
  if (sug.dataset.key !== key) {
    sug.dataset.key = key;
    sug.innerHTML = opts.length ? html`<div class="suggest">${opts.map((o, i) => html`<button class="sug" style="--i:${i}" data-act="chat-suggest" data-mid="${host.id}" data-text="${o}">${icon(optionIcon(o))}<span>${o}</span></button>`)}</div>`.s : '';
  }
  // 中断按钮
  $('#interruptRow').innerHTML = isBusy(stage.state) ? html`<button class="interrupt" data-act="chat-interrupt">${icon('stopCircle')}<span>中断</span></button>`.s : '';
  // 滚动：在底部就跟着走；往前加载时保住阅读位置
  if (S.jumpMessage) {
    const target = list.querySelector(`[data-mid="${CSS.escape(S.jumpMessage)}"]`);
    S.jumpMessage = null;
    if (target) { target.scrollIntoView({ block: 'center' }); target.classList.add('flash'); atBottom = false; }
  } else if (wasBottom) scrollBottom(!first);
  else if (firstBefore && list.firstElementChild && list.firstElementChild.dataset.row !== firstBefore) sc.scrollTop = prevTop + (sc.scrollHeight - prevH);
  renderJump();
  tickElapsed();
}
function tickElapsed() {
  for (const el of document.querySelectorAll('.elapsed[data-since]')) {
    const s = Number(el.dataset.since); const e = s > 0 ? Date.now() / 1000 - s : 0;
    el.textContent = e >= 3 && e < 3600 ? durationText(e) : '';
  }
}
setInterval(tickElapsed, 1000);

// ─── 输入框 ───
export function renderComposer() {
  const host = $('#composerWrap'); if (!host) return;
  if (host.contains(document.activeElement) && document.activeElement.tagName === 'TEXTAREA' && !voice.phase) { syncComposerBits(); return; }
  if (voice.phase) { host.innerHTML = voicePanel().s; return; }
  host.innerHTML = html`<div class="composer-extras" id="composerExtras"></div>
    <form class="composer glass" id="composer">
      <div class="plus-wrap"><button type="button" class="round fill" data-act="composer-plus" aria-label="附件与成果">${icon(S.uploading ? 'hourglass' : 'plus')}</button>
        <div class="menu-pop hidden" id="plusMenu"><button type="button" data-act="pick-file">${icon('doc')}选择文件</button><button type="button" data-act="open-search">${icon('tray')}查看成果</button></div></div>
      <textarea id="chatInput" rows="1" placeholder="发消息" aria-label="发消息" title="Enter 发送，Shift+Enter 换行，⌘K 聚焦"></textarea>
      <span id="composerAction"></span>
      <input type="file" id="fileInput" multiple hidden>
    </form>`.s;
  const ta = $('#chatInput');
  ta.value = S.draft;
  autosize(ta);
  ta.addEventListener('input', () => { S.draft = ta.value; try { sessionStorage.setItem('com.draft', S.draft); } catch { /* noop */ } autosize(ta); syncAction(); });
  ta.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); doSend(); }
  });
  ta.addEventListener('paste', (e) => { const files = Array.from(e.clipboardData?.files || []); if (files.length) { e.preventDefault(); upload(files); } });
  $('#composer').addEventListener('submit', (e) => { e.preventDefault(); doSend(); });
  $('#fileInput').addEventListener('change', (e) => { upload(Array.from(e.target.files || [])); e.target.value = ''; });
  syncComposerBits();
}
function syncComposerBits() { syncAction(); syncExtras(); }
function syncAction() {
  const a = $('#composerAction'); if (!a) return;
  const has = S.draft.trim().length > 0;
  const want = has ? 'send' : 'mic';
  if (a.dataset.mode === want && !(has && a.firstElementChild?.disabled !== S.sending)) return;
  a.dataset.mode = want;
  a.innerHTML = has ? html`<button type="submit" class="round ink" aria-label="发送" ${S.sending ? raw('disabled') : ''}>${icon('arrowUp')}</button>`.s
    : html`<button type="button" class="round" data-act="voice-start" aria-label="语音输入">${icon('mic')}</button>`.s;
}
function syncExtras() {
  const x = $('#composerExtras'); if (!x) return;
  x.innerHTML = html`${S.attachments.length ? html`<div class="att-row">${S.attachments.map((a) => html`<span class="att">${icon('paperclip')}${a.name}<button data-act="att-remove" data-id="${a.id}" aria-label="移除附件">${icon('x')}</button></span>`)}</div>` : ''}
    ${S.reference ? html`<div class="ref-chip glass"><i></i><div><b>回复 ${S.reference.author}</b><span>${S.reference.text}</span></div><button data-act="ref-clear" aria-label="取消引用">${icon('x')}</button></div>` : ''}`.s;
}
export function autosize(ta) { ta.style.height = 'auto'; ta.style.height = Math.min(ta.scrollHeight, 8 * 24 + 20) + 'px'; }
async function doSend() {
  if (!S.draft.trim() || S.sending) return;
  atBottom = true;
  await send();
  const ta = $('#chatInput'); if (ta) { ta.value = S.draft; autosize(ta); }
  syncComposerBits();
}
async function upload(files) {
  for (const f of files) {
    if (S.attachments.length >= 8) { toast('每条消息最多八个附件'); break; }
    if (f.size > 20 * 1024 * 1024) { toast('附件超过 20 MB：' + f.name); continue; }
    S.uploading = true; renderComposerSoft();
    try {
      const v = await api('/personal/attachments/' + uuid(), { raw: f, headers: { 'Content-Type': f.type || 'application/octet-stream', 'X-Filename': encodeURIComponent(f.name) }, timeout: 120000 });
      S.attachments.push({ ...v, name: v.name || f.name });
    } catch (e) { toast(e.message); }
    S.uploading = false; renderComposerSoft();
  }
}
function renderComposerSoft() { const b = document.querySelector('[data-act="composer-plus"]'); if (b) b.innerHTML = icon(S.uploading ? 'hourglass' : 'plus').s; syncExtras(); }

// 拖文件进对话页就上传
document.addEventListener('dragover', (e) => { if (S.tab === 'chat' && e.dataTransfer?.types?.includes('Files')) { e.preventDefault(); document.body.classList.add('dropping'); } });
document.addEventListener('dragleave', (e) => { if (!e.relatedTarget) document.body.classList.remove('dropping'); });
document.addEventListener('drop', (e) => { document.body.classList.remove('dropping'); if (S.tab === 'chat' && e.dataTransfer?.files?.length) { e.preventDefault(); upload(Array.from(e.dataTransfer.files)); } });

// ─── 语音（VoiceRecorder）：浏览器录成 16k 单声道 WAV → /voice/transcribe → 转写好后自动发出 ───
const voice = { phase: '', seconds: 0, level: 0, levels: [], transcript: '', error: '', id: '', stream: null, ctx: null, node: null, chunks: [], rate: 48000, timer: 0, sendTimer: 0 };
function voicePanel() {
  const bars = voice.levels.slice(-40);
  const label = { recording: `正在听 · ${voice.seconds}s`, transcribing: '正在转写…', ready: '转写好了，马上发出', failed: voice.error || '没听清' }[voice.phase];
  return html`<div class="voice glass ${voice.phase}">
    <div class="voice-bars">${bars.map((v) => raw(`<i style="height:${Math.round(6 + v * 30)}px"></i>`))}</div>
    <div class="voice-text">${voice.transcript ? html`<p class="reveal">${voice.transcript}</p>` : html`<p class="muted">${label}</p>`}</div>
    <div class="row">
      <button class="btn secondary small" data-act="voice-cancel">${voice.phase === 'ready' ? '先别发' : '取消'}</button>
      ${voice.phase === 'recording' ? html`<button class="btn primary small" data-act="voice-stop">${icon('check')}说完了</button>` : ''}
      ${voice.phase === 'failed' ? html`<button class="btn primary small" data-act="voice-retry">重试转写</button>` : ''}
    </div></div>`;
}
async function voiceStart() {
  if (voice.phase) return;
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true } });
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    const src = ctx.createMediaStreamSource(stream);
    const node = ctx.createScriptProcessor(4096, 1, 1);
    Object.assign(voice, { phase: 'recording', seconds: 0, levels: [], transcript: '', error: '', id: uuid(), stream, ctx, node, chunks: [], rate: ctx.sampleRate });
    node.onaudioprocess = (e) => {
      const d = e.inputBuffer.getChannelData(0); voice.chunks.push(new Float32Array(d));
      let sum = 0; for (let i = 0; i < d.length; i += 16) sum += d[i] * d[i];
      voice.levels.push(Math.min(1, Math.sqrt(sum / (d.length / 16)) * 6));
      const bars = $('.voice-bars'); if (bars) bars.innerHTML = voice.levels.slice(-40).map((v) => `<i style="height:${Math.round(6 + v * 30)}px"></i>`).join('');
    };
    src.connect(node); node.connect(ctx.destination);
    voice.timer = setInterval(() => { voice.seconds++; const p = $('.voice-text .muted'); if (p && voice.phase === 'recording') p.textContent = `正在听 · ${voice.seconds}s`; if (voice.seconds >= 120) voiceStop(); }, 1000);
    renderComposer();
  } catch (e) { toast('拿不到麦克风：' + (e.message || '请在浏览器里允许麦克风')); }
}
function stopTracks() {
  clearInterval(voice.timer);
  try { voice.node && voice.node.disconnect(); voice.stream && voice.stream.getTracks().forEach((t) => t.stop()); voice.ctx && voice.ctx.close(); } catch { /* noop */ }
  voice.node = voice.stream = voice.ctx = null;
}
function encodeWav() {
  const total = voice.chunks.reduce((n, c) => n + c.length, 0);
  const ratio = voice.rate / 16000, outLen = Math.floor(total / ratio);
  const pcm = new Int16Array(outLen);
  const flat = new Float32Array(total); let o = 0; for (const c of voice.chunks) { flat.set(c, o); o += c.length; }
  for (let i = 0; i < outLen; i++) { const s = Math.max(-1, Math.min(1, flat[Math.floor(i * ratio)])); pcm[i] = s < 0 ? s * 0x8000 : s * 0x7fff; }
  const buf = new ArrayBuffer(44 + pcm.length * 2), v = new DataView(buf);
  const w = (p, s) => { for (let i = 0; i < s.length; i++) v.setUint8(p + i, s.charCodeAt(i)); };
  w(0, 'RIFF'); v.setUint32(4, 36 + pcm.length * 2, true); w(8, 'WAVE'); w(12, 'fmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
  v.setUint32(24, 16000, true); v.setUint32(28, 32000, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true); w(36, 'data'); v.setUint32(40, pcm.length * 2, true);
  new Int16Array(buf, 44).set(pcm);
  return new Blob([buf], { type: 'audio/wav' });
}
async function voiceStop() {
  if (voice.phase !== 'recording') return;
  stopTracks();
  voice.wav = encodeWav(); voice.chunks = [];
  await voiceTranscribe();
}
async function voiceTranscribe() {
  voice.phase = 'transcribing'; renderComposer();
  try {
    const r = await api('/voice/transcribe/' + voice.id, { raw: voice.wav, headers: { 'Content-Type': 'audio/wav' }, timeout: 100000 });
    voice.transcript = (r && r.text) || ''; voice.phase = 'ready'; renderComposer();
    voice.sendTimer = setTimeout(async () => {
      if (voice.phase !== 'ready') return;
      const text = voice.transcript; voiceReset();
      atBottom = true; await send({ textOverride: text });
    }, 1200);
  } catch (e) { voice.phase = 'failed'; voice.error = e.message; renderComposer(); }
}
function voiceReset() { clearTimeout(voice.sendTimer); stopTracks(); Object.assign(voice, { phase: '', transcript: '', error: '', wav: null, chunks: [], levels: [] }); renderComposer(); }
act('voice-start', voiceStart);
act('voice-stop', voiceStop);
act('voice-retry', voiceTranscribe);
act('voice-cancel', () => { if (voice.phase === 'ready' && voice.transcript) { S.draft = voice.transcript; } voiceReset(); });

// ─── 动作 ───
act('chat-jump', () => { atBottom = true; unread.clear(); scrollBottom(true); renderJump(); });
act('chat-older', async (b) => {
  b.disabled = true; b.textContent = '正在读取…';
  const all = timelineRows().length;
  if (win < all) win += 30; else { const n = await loadHistory(); win += n; }
  renderChat();
});
act('chat-prompt', (b) => { atBottom = true; send({ textOverride: b.dataset.text }); });
act('chat-suggest', (b) => {
  b.classList.add('picked');
  setTimeout(() => { usedSuggestion = b.dataset.mid; $('#chatSuggest').dataset.key = ''; renderChat(); atBottom = true; send({ textOverride: b.dataset.text }); }, 200);
});
act('chat-interrupt', () => interrupt());
act('chat-receipt', (b) => deliver(b.dataset.id));
act('chat-restore', (b) => { restoreRejected(b.dataset.id); renderComposer(); });
act('toggle-process', (b) => { const k = b.dataset.key; openProcess.has(k) ? openProcess.delete(k) : openProcess.add(k); changed('conversation'); });
act('composer-plus', () => $('#plusMenu')?.classList.toggle('hidden'));
act('pick-file', () => { $('#plusMenu')?.classList.add('hidden'); $('#fileInput')?.click(); });
act('att-remove', (b) => { S.attachments = S.attachments.filter((a) => a.id !== b.dataset.id); syncExtras(); });
act('ref-clear', () => { S.reference = null; syncExtras(); });
act('msg-copy', (b) => {
  const msg = b.closest('.msg'); const bubble = msg && msg.querySelector('.bubble');
  navigator.clipboard?.writeText(bubble ? bubble.innerText : '').then(() => toast('已复制'), () => toast('复制失败'));
});
act('msg-reply', (b) => {
  const msg = b.closest('.msg'); const m = S.conv.messages.find((x) => x.id === msg.dataset.mid); if (!m) return;
  const user = m.role === 'user';
  S.reference = { id: m.id, source_session_id: 'personal-main', mode: 'reply', author: user ? '你' : 'Com', text: textContent(m.text).slice(0, 2000) };
  syncExtras(); $('#chatInput')?.focus();
});
document.addEventListener('click', (e) => { if (!e.target.closest('.plus-wrap')) $('#plusMenu')?.classList.add('hidden'); });

onChange((keys) => {
  if (!mounted) return;
  if (keys.has('conversation') || keys.has('pending') || keys.has('stage') || keys.has('*')) renderChat();
  if (keys.has('composer')) renderComposer();
  else if (keys.has('pending')) syncAction();
});
export function focusChat() { const ta = $('#chatInput'); if (ta) ta.focus(); }
export { store, setTab, tasks };
