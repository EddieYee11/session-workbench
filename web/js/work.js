// 「工作」页：ChatGPT 式原地聊天（iOS WorkHome / WorkChat / WorkSessionModel / WorkApprovalCard）。
import {
  S, $, html, raw, md, D, api, load, mutate, action, toast, store, changed, onChange, refresh, agentName, hostName, relativeTime, clockTime, textContent,
  stampLabel, statusTone, queueWork, deliverWork, seedOf, durationText,
} from './core.js';
import { icon, act, ACT, stamp, notice, rawDetails, agentAvatar, agentMark, agentTint, agentBrand, confirmBox, openSheet } from './ui.js';
import { stepKind, STEP_LIVE, STEP_ICON, stepDone, autosize } from './chat.js';

const ROOT = '/Users/eddiegao/AI_Work_System';
const AGENTS = ['hermes', 'pi', 'claude', 'codex'];
export const W = {
  mode: 'home', generation: 0, sessionID: '', metadata: {}, snapshot: {}, history: [], live: {}, outgoing: [], loaded: false, note: '',
  models: [], modelsFor: '', selection: '', effort: '', directory: store.get('work.dir', ROOT), homeDraft: '', sessionDraft: '',
  lastAgent: store.get('work.lastAgent', 'codex'), host: store.get('work.host', 'mini'), filter: store.get('work.agent', ''),
  sidebar: store.get('work.sidebar', window.innerWidth >= 1180), limit: 40, sending: false, openSteps: new Set(), jump: '',
};
const agent = () => (W.mode === 'home' ? W.lastAgent : W.mode === 'snapshot' ? W.snapshot.agent : W.metadata.agent) || 'codex';
const status = () => W.live.status || W.metadata.status || '';
const running = () => ['running', 'active', 'working', 'starting'].includes(status());
const starting = () => W.mode === 'session' && !W.sessionID;
const canInput = () => !!(W.metadata.capabilities || {}).input;
const dispatchMode = () => (W.mode === 'snapshot' ? 'forked' : canInput() ? 'input' : (W.metadata.capabilities || {}).dispatch_mode || '');
const title = () => (W.mode === 'snapshot' ? W.snapshot.title : W.metadata.display_title || W.metadata.title) || '';
const folder = () => String(W.mode === 'home' ? W.directory : W.metadata.cwd || '').split('/').filter(Boolean).pop() || '';
export function workStatusLabel(s) { return ({ starting: '正在派出', ready: '空闲', history: '历史', active: '进行中', working: '进行中' })[s] || stampLabel(s); }
export const workHead = () => agentName(agent());

function reset(keep) { W.history = []; W.live = {}; W.outgoing = []; W.note = ''; W.loaded = false; if (!keep) { W.selection = ''; W.effort = ''; } W.generation++; }
/** 10-18 会话↔案例互通：这段是某个案例的执行会话，一键回到案例。 */
function caseBanner() {
  if (W.mode !== 'session') return '';
  const owner = ((D('/sessions') || {}).sessions || []).find((x) => x.id === W.sessionID);
  return owner && owner.case_id ? html`<button class="case-banner" data-act="case-open" data-id="${owner.case_id}">${icon('layers')}案例「${owner.case_title}」的执行会话 · 看案例</button>` : '';
}
export function openSession(s) { W.mode = 'session'; W.sessionID = s.id; W.metadata = s; W.snapshot = {}; reset(); W.sessionDraft = store.get('work.draft.' + s.id, '') || ''; poll(true); changed('work'); }
function openSnapshot(item) { W.mode = 'snapshot'; W.sessionID = ''; W.metadata = {}; W.snapshot = item; reset(); poll(true); changed('work'); }
export function newChat() { W.mode = 'home'; W.sessionID = ''; W.metadata = {}; W.snapshot = {}; reset(); changed('work'); }

// ─── 拉取：会话详情 + 实时条目，3 秒一次 ───
let pollTimer = 0, pollKey = '';
async function fetchSession() {
  if (W.mode === 'snapshot') {
    const id = W.snapshot.id, d = await load('/personal/projects/sources/' + encodeURIComponent(id));
    if (d && W.mode === 'snapshot' && W.snapshot.id === id) { W.history = d.messages || []; W.loaded = true; changed('work'); }
    return;
  }
  if (W.mode !== 'session' || !W.sessionID) return;
  const id = W.sessionID;
  try {
    const [detail, live] = await Promise.all([api('/sessions/' + encodeURIComponent(id)), api('/sessions/' + encodeURIComponent(id) + '/live')]);
    if (W.mode !== 'session' || W.sessionID !== id) return;
    if (detail) { const s = { ...(detail.session || {}) }; if (!s.title) s.title = W.metadata.title; W.metadata = s; W.history = detail.messages || []; }
    if (live) W.live = live;
    // 内容没变就不重画（3 秒一次的轮询不打断选字和阅读）。
    const sig = JSON.stringify([W.metadata, W.history.length, W.history[W.history.length - 1], W.live]);
    if (sig === W.sig && W.loaded && !W.note) return;
    W.sig = sig; W.loaded = true; W.note = ''; changed('work');
  } catch (e) { if (W.sessionID === id) { W.note = '历史缓存 · ' + e.message; changed('work'); } }
}
export function poll(now) {
  const key = `${W.mode}-${W.sessionID}-${W.snapshot.id || ''}-${W.generation}`;
  if (key === pollKey && !now) return;
  pollKey = key; clearTimeout(pollTimer);
  if (W.mode === 'home') return;
  const tick = async () => { if (pollKey !== key) return; if (S.active && S.tab === 'work') await fetchSession(); if (pollKey === key) pollTimer = setTimeout(tick, 3000); };
  tick();
}
async function loadModels() {
  const a = agent(); if (W.modelsFor === a) return;
  W.modelsFor = a; const d = await load('/models?agent=' + a);
  W.models = (d && d.models) || [];
  if (!W.models.some((m) => m.id === W.selection)) { W.selection = ''; W.effort = ''; }
  changed('work-composer');
}

// ─── 合并与分行（WorkSessionModel.merge / rows） ───
function merge(history, items) {
  const out = [...history], index = new Map();
  out.forEach((m, i) => { if (m.id) index.set(m.id, i); });
  for (const it of items || []) { if (!it.id) continue; if (index.has(it.id)) out[index.get(it.id)] = it; else { index.set(it.id, out.length); out.push(it); } }
  return out;
}
function rows() {
  const merged = merge(W.history, W.live.items), aliases = {}, echoed = new Set();
  const users = merged.filter((m) => m.role === 'user'), requests = new Set(users.map((m) => m.request_id).filter(Boolean));
  for (const o of W.outgoing) {
    if (requests.has(o.requestID)) { echoed.add(o.requestID); continue; }
    const same = users.filter((m) => String(m.text || '').trim() === o.text.trim() && !m.request_id);
    if (same.length > o.baseline) { aliases[same[o.baseline].id] = 'request:' + o.requestID; echoed.add(o.requestID); }
  }
  const out = []; let group = [], last = '';
  const flush = (live) => { if (group.length) { out.push({ id: 'steps:' + group[0].id, kind: 'steps', steps: group, live }); group = []; } };
  for (const m of merged) {
    if (m.role === 'user') {
      flush(false);
      const key = aliases[m.id] || (m.request_id ? 'request:' + m.request_id : m.id);
      out.push({ id: key, kind: 'user', message: m, outgoing: W.outgoing.find((o) => 'request:' + o.requestID === key) }); last = 'user';
    } else if (m.role === 'assistant') {
      if (!textContent(m.text).trim()) continue;
      flush(false); out.push({ id: m.id, kind: 'reply', message: m, header: last !== 'assistant' }); last = 'assistant';
    } else if (m.id) group.push(m);
  }
  flush(running());
  for (const o of W.outgoing) if (!echoed.has(o.requestID)) out.push({ id: 'request:' + o.requestID, kind: 'user', message: { id: 'request:' + o.requestID, role: 'user', text: o.text, time: o.createdAt }, outgoing: o });
  return out;
}

// ─── 渲染 ───
const toolOf = (s) => String(s.title || '').split(' · ')[0] || s.role || '';
const firstLine = (t) => { const l = String(t || '').split('\n')[0] || ''; return l.length > 120 ? l.slice(0, 119) + '…' : l; };
function stepsRow(r) {
  const calls0 = r.steps.filter((s) => toolOf(s) !== '工具输出'), calls = calls0.length ? calls0 : r.steps;
  const open = W.openSteps.has(r.id);
  const lastS = calls[calls.length - 1];
  let head;
  if (r.live && lastS) {
    const k = stepKind(toolOf(lastS)) || 'other';
    head = html`<i class="pulse"></i><span class="cur">${lastS.role === 'progress' ? firstLine(lastS.text) : STEP_LIVE[k][seedOf(lastS.id) % 3]}</span>`;
  } else {
    const times = r.steps.map((s) => s.time).filter((t) => t > 0), span = times.length ? Math.max(...times) - Math.min(...times) : 0;
    head = html`${icon('checkCircle')}<span class="sum">做了 ${calls.length} 步${span >= 1 ? ' · 用时 ' + durationText(span) : ''}</span>`;
  }
  return html`<div class="process ${r.live ? 'live' : ''}"><button class="process-head" data-act="work-steps" data-key="${r.id}">${head}${icon('right', open ? 'rot' : '')}</button>
    ${open ? html`<div class="steps">${calls.map((s, i) => { const k = stepKind(toolOf(s)) || 'other', run = r.live && i === calls.length - 1;
      return html`<div class="step ${run ? 'live' : ''}">${icon(STEP_ICON[k])}<div><b>${s.role === 'progress' ? '进度' : run ? STEP_LIVE[k][0] : stepDone(k, 1)}</b><small>${firstLine(s.text) || toolOf(s)}</small></div></div>`; })}</div>` : ''}</div>`;
}
function rowHTML(r) {
  if (r.kind === 'steps') return stepsRow(r);
  const m = r.message, text = textContent(m.text);
  if (r.kind === 'user') {
    const o = r.outgoing;
    return html`<div class="msg me ${o && o.fresh ? 'fly' : ''}" data-row="${r.id}"><div class="col">
      ${m.reference ? html`<div class="quote"><b>${m.reference.author || ''}</b><span>${m.reference.text || ''}</span></div>` : ''}
      <div class="bubble user">${text}</div>
      ${o && o.state !== 'accepted' ? html`<div class="delivery ${o.state === 'rejected' ? 'danger' : ''}">${o.state === 'sending' ? raw('<i class="spin"></i>') : o.state === 'elsewhere' ? icon('send') : ''}<span>${o.state === 'sending' ? '正在发送' : o.note}</span>${o.state === 'rejected' ? html`<button class="link" data-act="work-restore" data-id="${o.requestID}">回到草稿</button>` : ''}</div>` : ''}
      <div class="msg-tools"><button data-act="work-copy" title="复制">${icon('copy')}</button>${W.mode === 'session' && W.sessionID && m.id && !String(m.id).startsWith('request:') ? html`<button data-act="work-reply" data-id="${m.id}" data-author="你" title="回复">${icon('reply')}</button>` : ''}</div></div></div>`;
  }
  return html`<div class="msg it work-reply" data-row="${r.id}"><div class="col">
    ${r.header ? html`<div class="agent-head">${agentAvatar(agent(), 26)}<b style="color:${raw(agentTint(agent()))}">${agentName(agent())}</b></div>` : ''}
    <div class="reply md">${md(text)}</div>
    <div class="msg-tools"><button data-act="work-copy" title="复制">${icon('copy')}</button>${W.mode === 'session' && W.sessionID ? html`<button data-act="work-reply" data-id="${m.id}" data-author="${agentName(agent())}" title="回复">${icon('reply')}</button>` : ''}<time>${clockTime(m.time)}</time></div></div></div>`;
}
function approvalCard(a) {
  const p = a.params || {}, qs = p.questions || [];
  const decisions = (p.availableDecisions && p.availableDecisions.length ? p.availableDecisions : ['accept', 'decline', 'cancel']);
  const label = (c) => ({ accept: '批准此操作', decline: '拒绝此操作', cancel: '取消', acceptForSession: '批准此会话的同类操作' })[c] || (typeof c === 'string' ? c : JSON.stringify(c));
  return html`<div class="card hl warning approval" data-aid="${a.id}">${stamp('等待你的决定', 'warning')}
    ${p.reason ? html`<p class="lead">${p.reason}</p>` : ''}${p.command ? html`<pre class="code">${p.command}</pre>` : ''}
    ${qs.length ? html`${qs.map((q) => html`<div class="q" data-qid="${q.id}"><h3>${q.question}</h3>${(q.options || []).map((o) => html`<button class="opt" data-act="appr-opt" data-q="${q.id}" data-label="${o.label}"><i></i><span><b>${o.label}</b>${o.description ? html`<small>${o.description}</small>` : ''}</span></button>`)}<input class="field" data-ans="${q.id}" placeholder="你的回答"></div>`)}
      <button class="btn primary full" data-act="appr-answer" data-id="${a.id}">提交这些回答</button>`
      : html`<div class="stack">${decisions.map((c) => (c === 'accept' || c === 'acceptForSession' ? html`<button class="btn primary full" data-act="appr-decide" data-id="${a.id}" data-c="${typeof c === 'string' ? c : JSON.stringify(c)}">${label(c)}</button>` : html`<button class="btn quiet full" data-act="appr-decide" data-id="${a.id}" data-c="${typeof c === 'string' ? c : JSON.stringify(c)}">${label(c)}</button>`))}</div>`}
    ${rawDetails('操作范围与完整参数', p)}</div>`;
}

let renderedGen = -1;
export function mountWork(root) {
  root.innerHTML = html`<div class="work">
    <aside class="work-sidebar" id="workSidebar"></aside>
    <div class="work-main">
      <div class="work-scroll" id="workScroll"><div class="work-inner" id="workInner"></div></div>
      <div class="work-composer" id="workComposer"></div>
    </div>
    <div class="work-scrim" data-act="work-sidebar"></div></div>`.s;
  $('#workScroll').addEventListener('scroll', () => { const sc = $('#workScroll'); W.nearBottom = sc.scrollHeight - sc.scrollTop - sc.clientHeight < 90; }, { passive: true });
  W.nearBottom = true;
  renderWork(true);
  renderWorkComposer(true);
}
export function renderWork(first) {
  const root = $('#page-work .work'); if (!root) return;
  root.classList.toggle('side-open', !!W.sidebar);
  root.style.setProperty('--wash', agentBrand(agent()) ? agentBrand(agent()).wash : 'transparent');
  renderSidebar();
  const inner = $('#workInner'), sc = $('#workScroll');
  const gen = W.generation;
  const wasBottom = W.nearBottom || first || gen !== renderedGen;
  if (W.mode === 'home') {
    inner.innerHTML = html`<div class="work-home ${gen !== renderedGen ? 'enter' : ''}"><div class="avatar-pick"><button class="avatar-btn" data-act="work-agent-menu">${agentAvatar(W.lastAgent, 64, W.lastAgent)}</button>
      <div class="menu-pop hidden" id="agentMenu">${AGENTS.map((a) => html`<button data-act="work-pick-agent" data-a="${a}" class="${a === W.lastAgent ? 'on' : ''}">${agentMark(a, 16)}${agentName(a)}</button>`)}</div></div>
      <h2>让 ${agentName(W.lastAgent)} 做点什么</h2><small class="faint">在 Mac mini 上执行 · ${folder()}</small></div>`.s;
  } else {
    const rs = rows();
    const firstUser = rs.find((r) => r.kind === 'user');
    const showTitle = title() && !(firstUser && textContent(firstUser.message.text).startsWith(title()));
    let live = '';
    if (W.mode === 'session' && running()) {
      const last = rs[rs.length - 1];
      if (starting()) live = '正在派给 ' + agentName(agent()) + '…';
      else if (!(last && last.kind === 'steps' && last.live)) live = last && last.kind === 'reply' ? '在写回复' : '在想怎么办';
    }
    inner.innerHTML = html`<div class="work-chat ${gen !== renderedGen ? 'enter' : ''}">
      <div class="work-head">${showTitle ? html`<h2>${title()}</h2>` : ''}<div class="row wrap"><span class="agent-chip" style="background:${raw(agentBrand(agent()) ? agentBrand(agent()).wash : 'var(--fill)')};color:${raw(agentTint(agent()))}">${agentMark(agent(), 13)}${agentName(agent())}</span>
        ${W.mode === 'snapshot' ? html`${stamp(({ active: '进行中', pending: '未收尾', completed: '已完成' })[W.snapshot.status] || '待核对')}<small class="faint">${icon('doc')}摘录</small>` : html`${stamp(workStatusLabel(status()), statusTone(status()), status() === 'unknown')}${folder() ? html`<small class="faint">${icon('folder')}${folder()}</small>` : ''}${W.metadata.pinned ? html`<small class="faint">${icon('pin')}</small>` : ''}`}</div>
        ${W.mode === 'snapshot' && W.snapshot.evidence_quote ? html`<div class="card hl accent"><h3 class="accent-text">会话中的依据</h3><p class="lined">${W.snapshot.evidence_quote}</p><small class="faint">是具体事项的会话报告，仍可能需要实际验收。</small></div>` : ''}</div>
      ${caseBanner()}
      ${W.note ? notice(W.note) : ''}
      ${!rs.length && W.loaded ? html`<p class="faint small">${W.mode === 'snapshot' ? '这段还没有可看的摘录。' : '会话已打开。回看历史不会启动执行器。'}</p>` : ''}
      ${!W.loaded && !rs.length ? html`<div class="skeleton"></div>` : ''}
      ${rs.map(rowHTML)}
      ${live ? html`<div class="live-line"><i class="pulse"></i><span>${live}</span></div>` : ''}
      ${(W.live.approvals || []).map(approvalCard)}
    </div>`.s;
    for (const o of W.outgoing) o.fresh = false;
  }
  renderedGen = gen;
  if (W.jump) { const t = inner.querySelector(`[data-row="${CSS.escape(W.jump)}"]`); W.jump = ''; if (t) { t.scrollIntoView({ block: 'center' }); t.classList.add('flash'); return; } }
  if (wasBottom) sc.scrollTop = sc.scrollHeight;
}

// ─── 侧栏 ───
function cleanTitle(t, fb) {
  t = String(t || '').trim();
  if (t && !t.startsWith('<') && !t.startsWith('Caveat')) return t;
  const first = fb.find((x) => x && x !== '等待下一轮整理') || '未命名对话';
  const line = first.split(/[。；\n]/)[0] || first;
  return line.length > 30 ? line.slice(0, 29) + '…' : line;
}
function threads() {
  const board = D('/personal/projects') || {}, sessions = (D('/sessions') || {}).sessions || [];
  const byID = new Map(sessions.map((s) => [s.id, s])), seen = new Set(), out = [];
  for (const p of board.projects || []) for (const it of p.items || []) {
    const key = it.host + ':' + it.native_id; if (seen.has(key)) continue; seen.add(key);
    const session = byID.get(it.native_id);
    out.push({ id: it.id, host: it.host, agent: it.agent, title: cleanTitle(it.title, [it.summary, p.title]), project: p.title, summary: it.summary === '等待下一轮整理' ? '' : it.summary || '', status: it.status, updated: it.updated_at || 0, session, item: it });
    if (session) seen.add('mini:' + it.native_id);
  }
  for (const s of sessions) {
    if (seen.has('mini:' + s.id)) continue;
    const cwd = String(s.cwd || '').split('/').pop();
    out.push({ id: 'session:' + s.id, host: 'mini', agent: s.agent, title: cleanTitle(s.display_title || s.title, [s.snippet, cwd]), project: cwd, summary: s.snippet || '', status: s.status, updated: s.updated || 0, session: s, item: null });
  }
  return out.sort((a, b) => b.updated - a.updated);
}
const tone = (s) => (['active', 'running', 'working'].includes(s) ? 'success' : ['pending', 'waiting', 'approval_required', 'interrupted'].includes(s) ? 'warning' : 'neutral');
const toneLabel = (s) => ({ success: '进行中', warning: '未收尾' })[tone(s)] || (s === 'completed' ? '已完成' : '');
function dayOf(t) {
  const d = new Date(t * 1000), today = new Date(); today.setHours(0, 0, 0, 0);
  if (d >= today) return '今天';
  if (d >= new Date(today - 86400000)) return '昨天';
  return Date.now() / 1000 - t < 7 * 86400 ? '这一周' : '更早';
}
function renderSidebar() {
  const el = $('#workSidebar'); if (!el) return;
  const scroll = el.querySelector('.side-list')?.scrollTop || 0;
  const all = threads(), hostT = all.filter((t) => t.host === W.host), shown = hostT.filter((t) => !W.filter || t.agent === W.filter);
  const present = new Set(hostT.map((t) => t.agent)), agents = AGENTS.filter((a) => present.has(a) || W.host === 'mini');
  const hosts = (D('/personal/projects') || {}).hosts || [];
  const current = W.mode === 'session' ? W.sessionID : W.mode === 'snapshot' ? W.snapshot.id : '';
  const loading = !D('/personal/projects') && !D('/sessions');
  const days = []; for (const t of shown.slice(0, W.limit)) { const d = dayOf(t.updated); if (days.length && days[days.length - 1][0] === d) days[days.length - 1][1].push(t); else days.push([d, [t]]); }
  el.innerHTML = html`<div class="side-head"><h3>历史对话</h3><button class="icon-btn" data-act="work-sidebar" aria-label="收起历史对话">${icon('x')}</button></div>
    <div class="hosts">${['mini', 'macbook'].map((h) => { const row = hosts.find((x) => x.host === h); const fresh = row && Date.now() / 1000 - row.collected_at < 3600; const run = all.filter((t) => t.host === h && tone(t.status) === 'success').length;
      return html`<button class="host ${h === W.host ? 'on' : ''}" data-act="work-host" data-h="${h}">${icon(h === 'mini' ? 'macmini' : 'laptop')}<span><b>${hostName(h)}</b><small><i class="dot ${fresh ? 'ok' : ''}"></i>${run ? '在跑 ' + run : h === 'mini' ? '可派活' : '只读同步'}</small></span></button>`; })}</div>
    <div class="agent-chips"><button class="chip ${!W.filter ? 'on ink' : ''}" data-act="work-filter" data-a="">全部 <em>${hostT.length}</em></button>
      ${agents.map((a) => { const n = hostT.filter((t) => t.agent === a).length, live = hostT.some((t) => t.agent === a && tone(t.status) === 'success');
        return html`<button class="chip ${W.filter === a ? 'on brand' : ''}" style="${raw(W.filter === a && agentBrand(a) ? `background:${agentBrand(a).wash};color:${agentBrand(a).ink}` : '')}" data-act="work-filter" data-a="${a}">${agentMark(a, 14)}${agentName(a).replace(' Code', '')}${n ? html`<em>${n}</em>` : ''}${live ? raw('<i class="live-dot"></i>') : ''}</button>`; })}
      <button class="chip quiet" data-act="open-board" data-host="${W.host}">${icon('layers')}项目</button></div>
    <div class="side-list">${!shown.length ? html`<p class="faint small pad">${loading ? '正在汇总两台电脑的会话…' : S.errors['/sessions'] ? '会话列表没读到：' + S.errors['/sessions'] : W.host === 'macbook' ? 'MacBook 的会话每 15 分钟同步一次。' : '这里还没有对话。'}</p>` : ''}
      ${days.map(([d, ts]) => html`<h4>${d}</h4>${ts.map((t) => html`<button class="thread ${current && ((t.session && t.session.id === current) || (t.item && t.item.id === current)) ? 'on' : ''}" data-act="work-open-thread" data-id="${t.id}">${agentAvatar(t.agent, 34)}
        <span class="grow"><span class="row between"><b>${t.title}</b><small class="faint">${relativeTime(t.updated)}</small></span>${t.summary || t.project ? html`<small class="sub clamp2">${t.summary || t.project}</small>` : ''}
        <small class="faint meta">${toneLabel(t.status) ? html`<span class="st ${tone(t.status)}"><i></i>${toneLabel(t.status)}</span>` : ''}${!W.filter ? html`<span>${agentName(t.agent)}</span>` : ''}${t.project && t.summary ? html`<span>${t.project}</span>` : ''}${!t.session ? html`<span>${icon('eye')}只读</span>` : ''}</small>${t.session && t.session.case_title ? html`<small class="case-tag">${icon('layers')}案例 · ${t.session.case_title}</small>` : ''}</span></button>`)}`)}
      ${shown.length > W.limit ? html`<button class="btn quiet full" data-act="work-more">再看更早的 ${shown.length - W.limit} 段</button>` : ''}</div>`.s;
  const list = el.querySelector('.side-list'); if (list) list.scrollTop = scroll;
}

// ─── 输入框 ───
function placeholder() {
  if (W.mode === 'home') return `让 ${agentName(W.lastAgent)} 做点什么（Enter 发送）`;
  return ({ injected: '会打进电脑上正在跑的终端', resumed: '发出去会先接上原会话', adopted: '发出去会先接上原会话', forked: W.mode === 'snapshot' ? '接着这段，在 mini 上开新会话做' : '接不上原会话，会带着前情开新会话' })[dispatchMode()] || '继续这项工作';
}
function routeHint() {
  if (W.mode === 'home' || starting()) return null;
  return ({ injected: ['这段正开在电脑的终端里', 'terminal'], resumed: ['会先接上原会话', 'refresh'], adopted: ['会先接上原会话', 'refresh'], forked: [W.mode === 'snapshot' ? 'MacBook 上的会话 · 会在 mini 上接着做' : '原会话被占着 · 会带着前情开新会话', 'send'] })[dispatchMode()] || null;
}
export function renderWorkComposer(force) {
  const host = $('#workComposer'); if (!host) return;
  const ta = host.querySelector('textarea');
  if (!force && ta && document.activeElement === ta) { syncWorkAction(); return; }
  loadModels();
  const efforts = (W.models.find((m) => m.id === W.selection) || {}).efforts || [];
  const modelLabel = W.selection ? ((W.models.find((m) => m.id === W.selection) || {}).label || W.selection) : '执行器默认';
  const hint = routeHint();
  const ref = S.workReference && W.mode === 'session' && S.workReference.source_session_id === W.sessionID ? S.workReference : null;
  host.innerHTML = html`${W.note && W.mode === 'home' ? html`<small class="danger-text pad">${icon('warning')}${W.note}</small>` : ''}
    ${ref ? html`<div class="ref-chip glass"><i></i><div><b>回复 ${ref.author}</b><span>${ref.text}</span></div><button data-act="work-ref-clear" aria-label="取消引用">${icon('x')}</button></div>` : ''}
    ${hint ? html`<span class="route-hint">${icon(hint[1])}${hint[0]}</span>` : ''}
    <form class="composer glass" id="workForm">
      <div class="plus-wrap"><button type="button" class="round fill" data-act="work-plus" aria-label="项目目录、模型和推理强度">${icon('plus')}</button>
        <div class="menu-pop up hidden" id="workPlus">
          <button type="button" ${W.mode === 'home' ? raw('data-act="work-dir"') : raw('disabled')}>${icon('folder')}项目目录：${folder()}</button>
          <label>${icon('cpu')}<span>模型</span><select id="workModel"><option value="">执行器默认</option>${W.models.map((m) => html`<option value="${m.id}" ${m.id === W.selection ? raw('selected') : ''}>${m.label || m.id}</option>`)}</select></label>
          ${efforts.length ? html`<label>${icon('gauge')}<span>推理强度</span><select id="workEffort"><option value="">默认</option>${efforts.map((e) => html`<option ${e === W.effort ? raw('selected') : ''}>${e}</option>`)}</select></label>` : ''}
          <small class="faint">当前：${modelLabel}${W.effort ? ' · ' + W.effort : ''}</small></div></div>
      <textarea id="workInput" rows="1" placeholder="${placeholder()}"></textarea>
      <span id="workAction"></span></form>`.s;
  const t = $('#workInput');
  t.value = W.mode === 'home' ? W.homeDraft : W.sessionDraft; autosize(t);
  t.addEventListener('input', () => { if (W.mode === 'home') W.homeDraft = t.value; else { W.sessionDraft = t.value; if (W.sessionID) store.set('work.draft.' + W.sessionID, t.value); } autosize(t); syncWorkAction(); });
  t.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); workSend(); } });
  $('#workForm').addEventListener('submit', (e) => { e.preventDefault(); workSend(); });
  $('#workModel').addEventListener('change', (e) => { W.selection = e.target.value; W.effort = ''; renderWorkComposer(true); $('#workPlus').classList.remove('hidden'); });
  $('#workEffort')?.addEventListener('change', (e) => { W.effort = e.target.value; });
  syncWorkAction();
}
function syncWorkAction() {
  const a = $('#workAction'); if (!a) return;
  const draft = (W.mode === 'home' ? W.homeDraft : W.sessionDraft).trim();
  if (!draft && W.mode === 'session' && running() && !starting()) a.innerHTML = html`<button type="button" class="round ink" data-act="work-stop" aria-label="停止执行">${icon('stop')}</button>`.s;
  else a.innerHTML = html`<button type="submit" class="round ink ${draft ? '' : 'dim'}" ${!draft || W.sending || starting() ? raw('disabled') : ''} aria-label="${W.mode === 'home' ? '派出去' : '发送'}">${icon(W.sending ? 'hourglass' : 'arrowUp')}</button>`.s;
}
async function workSend() {
  const text = (W.mode === 'home' ? W.homeDraft : W.sessionDraft).trim();
  if (!text || W.sending) return;
  if (W.mode !== 'home' && dispatchMode() === 'injected' && !store.get('work.injectConfirmed', false)) {
    const ok = await confirmBox({ title: '打进电脑上的终端？', message: '这段会话正开在 mini 的终端里。发的话会像你在电脑前打字一样送进去；如果此刻电脑前也有人在打字，两边会混在一起。', ok: '打进去，以后不用问' });
    if (!ok) return; store.set('work.injectConfirmed', true);
  }
  if (W.mode === 'home') return start(text);
  W.sending = true; syncWorkAction();
  await submit(text);
  W.sending = false; renderWorkComposer(true);
}
async function start(text) {
  const a = W.lastAgent, cwd = W.directory;
  let entry;
  try { entry = queueWork('/sessions', text, { agent: a, cwd, prompt: text, model: W.selection, effort: W.effort, sandbox: 'danger-full-access' }); }
  catch (e) { W.note = e.message; renderWorkComposer(true); return; }
  W.homeDraft = '';
  W.mode = 'session'; W.sessionID = ''; W.snapshot = {}; reset(true);
  W.metadata = { agent: a, cwd, title: text.slice(0, 60), status: 'starting' };
  W.outgoing = [{ requestID: entry.id, text, createdAt: Date.now() / 1000, baseline: 0, state: 'sending', note: '', fresh: true }];
  W.sessionDraft = ''; W.sending = true;
  changed('work'); renderWorkComposer(true);
  const r = await deliverWork(entry.id);
  W.sending = false;
  if (r && r.sid) {
    if (W.mode === 'session' && !W.sessionID) { W.sessionID = r.sid; W.metadata = { ...W.metadata, id: r.sid, status: 'running' }; const o = W.outgoing[W.outgoing.length - 1]; if (o) o.state = 'accepted'; poll(true); }
    refresh('work');
  } else {
    const o = W.outgoing[W.outgoing.length - 1];
    if (o) { o.state = r && r.status === 'rejected' ? 'rejected' : 'uncertain'; o.note = r && r.status === 'rejected' ? r.error || '没派出去' : '送达待核实。要求已保存，可在设置的发送记录里查询回执。'; }
    W.metadata.status = r && r.status === 'rejected' ? 'failed' : 'unknown';
  }
  changed('work'); renderWorkComposer(true);
}
async function submit(text) {
  if (!(W.mode === 'snapshot' || (W.mode === 'session' && W.sessionID))) return;
  const id = W.mode === 'snapshot' ? W.snapshot.id : W.sessionID;
  const cur = () => (W.mode === 'snapshot' ? W.snapshot.id : W.sessionID);
  const fields = { model: W.selection, effort: W.effort };
  if (S.workReference && S.workReference.source_session_id === id) fields.reference = S.workReference;
  let entry;
  try { entry = queueWork('/sessions/' + encodeURIComponent(id) + (dispatchMode() === 'input' ? '/input' : '/dispatch'), text, fields); }
  catch (e) { W.note = e.message; changed('work'); return; }
  const baseline = merge(W.history, W.live.items).filter((m) => m.role === 'user' && m.text === text).length;
  const o = { requestID: entry.id, text, createdAt: Date.now() / 1000, baseline, state: 'sending', note: '', fresh: true };
  W.outgoing.push(o); W.sessionDraft = ''; if (W.sessionID) store.del('work.draft.' + W.sessionID); S.workReference = null;
  W.nearBottom = true; changed('work');
  const r = await deliverWork(entry.id);
  if (cur() !== id) return;
  const sid = (r && r.sid) || '';
  if (r && r.status === 'accepted' && r.mode === 'forked' && sid) {
    const a = agent(), cwd = W.mode === 'snapshot' ? W.snapshot.cwd : W.metadata.cwd, oldTitle = title();
    W.mode = 'session'; W.sessionID = sid; W.snapshot = {}; reset(true);
    W.metadata = { id: sid, agent: a, cwd, title: oldTitle, status: 'running' };
    W.outgoing = [{ ...o, state: 'elsewhere', note: `接不上原会话，带着《${oldTitle}》的前情开了新会话` }];
    poll(true);
  } else if (r && r.status === 'accepted' && ['resumed', 'adopted'].includes(r.mode) && sid) {
    W.sessionID = sid; W.metadata = { ...W.metadata, id: sid, capabilities: { ...(W.metadata.capabilities || {}), input: true } }; o.state = 'accepted'; poll(true);
  } else if (r && r.status === 'accepted' && r.mode === 'injected') { o.state = 'elsewhere'; o.note = '已打进电脑上正在跑的终端'; fetchSession(); }
  else if (r && r.status === 'accepted') { o.state = 'accepted'; fetchSession(); }
  else if (r && r.status === 'rejected') { o.state = 'rejected'; o.note = r.error || '没送出去'; }
  else { o.state = 'uncertain'; o.note = '送达待核实，要求已保存'; }
  changed('work');
}

// ─── 顶栏标题菜单（WorkTitleMenu）——由 app.js 调用 ───
export function titleMenuHTML() {
  if (W.mode === 'home') return html`<small class="menu-label">派给谁</small>${AGENTS.map((a) => html`<button class="menu-row ${a === W.lastAgent ? 'on' : ''}" data-act="work-pick-agent" data-a="${a}">${agentMark(a, 16)}<span><b>${agentName(a)}</b></span>${a === W.lastAgent ? icon('check') : ''}</button>`)}`;
  if (W.mode === 'session') return html`<small class="menu-label">${agentName(agent())} · ${workStatusLabel(status())}</small>
    ${running() && !starting() ? html`<button class="menu-row" data-act="work-stop">${icon('stopCircle')}<span><b>停止执行</b></span></button>` : ''}
    ${W.sessionID ? html`<button class="menu-row" data-act="work-pin">${icon('pin')}<span><b>${W.metadata.pinned ? '取消置顶' : '置顶'}</b></span></button><button class="menu-row danger" data-act="work-end">${icon('x')}<span><b>结束会话</b></span></button>` : ''}
    <button class="menu-row" data-act="work-new">${icon('compose')}<span><b>新对话</b></span></button>`;
  return html`<small class="menu-label">${hostName(W.snapshot.host)} 上的只读摘录</small><button class="menu-row" data-act="work-new">${icon('compose')}<span><b>新对话</b></span></button>`;
}

// ─── 动作 ───
act('work-sidebar', () => { W.sidebar = !W.sidebar; store.set('work.sidebar', W.sidebar); renderWork(); });
act('work-host', (b) => { W.host = b.dataset.h; store.set('work.host', W.host); W.limit = 40; renderSidebar(); });
act('work-filter', (b) => { W.filter = b.dataset.a; store.set('work.agent', W.filter); W.limit = 40; renderSidebar(); });
act('work-more', () => { W.limit += 60; renderSidebar(); });
act('work-open-thread', (b) => {
  const t = threads().find((x) => x.id === b.dataset.id); if (!t) return;
  if (t.session) openSession(t.session); else if (t.item) openSnapshot(t.item);
  if (window.innerWidth < 1180) { W.sidebar = false; }
  renderWork(); renderWorkComposer(true);
});
act('work-open-item', (b) => {
  const t = threads().find((x) => x.id === b.dataset.id || (x.item && x.item.id === b.dataset.id)); if (!t) return toast('这段会话还没同步过来');
  import('./ui.js').then((m) => m.closeSheets());
  if (t.session) openSession(t.session); else openSnapshot(t.item);
  ACT['go-tab']?.({ dataset: { tab: 'work' } }); renderWorkComposer(true);
});
act('work-open-session', (b) => {
  const id = b.dataset.id, s = ((D('/sessions') || {}).sessions || []).find((x) => x.id === id) || { id, agent: b.dataset.agent };
  openSession(s); W.jump = b.dataset.jump || '';
  ACT['go-tab']?.({ dataset: { tab: 'work' } }); renderWorkComposer(true);
});
act('work-new', () => { newChat(); document.querySelector('.title-menu')?.classList.add('hidden'); renderWorkComposer(true); });
act('work-pick-agent', (b) => { W.lastAgent = b.dataset.a; store.set('work.lastAgent', W.lastAgent); W.modelsFor = ''; $('#agentMenu')?.classList.add('hidden'); document.querySelector('.title-menu')?.classList.add('hidden'); changed('work'); renderWorkComposer(true); });
act('work-agent-menu', () => $('#agentMenu')?.classList.toggle('hidden'));
act('work-plus', () => $('#workPlus')?.classList.toggle('hidden'));
act('work-steps', (b) => { const k = b.dataset.key; W.openSteps.has(k) ? W.openSteps.delete(k) : W.openSteps.add(k); renderWork(); });
act('work-stop', async () => { document.querySelector('.title-menu')?.classList.add('hidden'); if (await action('/sessions/' + encodeURIComponent(W.sessionID) + '/stop')) { toast('已停止'); fetchSession(); } });
act('work-pin', async () => { document.querySelector('.title-menu')?.classList.add('hidden'); if (await action('/sessions/' + encodeURIComponent(W.sessionID) + '/labels', { pinned: !W.metadata.pinned }, 'work')) fetchSession(); });
act('work-end', async () => {
  document.querySelector('.title-menu')?.classList.add('hidden');
  if (!(await confirmBox({ title: '结束这段会话？', message: '执行器会退出；历史还能回看，之后再发话会带着前情开新会话。', ok: '结束会话', danger: true }))) return;
  if (await action('/sessions/' + encodeURIComponent(W.sessionID) + '/end', {}, 'work')) fetchSession();
});
act('work-restore', (b) => {
  const o = W.outgoing.find((x) => x.requestID === b.dataset.id && x.state === 'rejected'); if (!o) return;
  if (!W.sessionID) { newChat(); W.homeDraft = o.text; } else { W.outgoing = W.outgoing.filter((x) => x !== o); W.sessionDraft = o.text; }
  changed('work'); renderWorkComposer(true);
});
act('work-copy', (b) => { const el = b.closest('.msg').querySelector('.bubble,.reply'); navigator.clipboard?.writeText(el ? el.innerText : '').then(() => toast('已复制')); });
act('work-reply', (b) => {
  const m = merge(W.history, W.live.items).find((x) => x.id === b.dataset.id); if (!m) return;
  S.workReference = { id: m.id, source_session_id: W.sessionID, mode: 'reply', author: b.dataset.author, text: textContent(m.text).slice(0, 2000) };
  renderWorkComposer(true); $('#workInput')?.focus();
});
act('work-ref-clear', () => { S.workReference = null; renderWorkComposer(true); });
act('work-dir', () => { $('#workPlus')?.classList.add('hidden'); openDirPicker(W.directory); });
function openDirPicker(start0) {
  let data = null, path = start0;
  const go = async (p) => { path = p; data = await load('/directories?path=' + encodeURIComponent(p)); changed('dir'); };
  openSheet({ title: '工作目录', render: () => !data ? html`<div class="skeleton"></div>` : html`<pre class="code">${data.path}</pre>
    ${data.parent != null || (data.directories || []).length ? html`<div class="card list">${data.parent ? html`<button class="list-row" data-act="dir-go" data-p="${data.parent}">${icon('up')}<span><b>上一级</b></span></button>` : ''}${(data.directories || []).map((d) => html`<button class="list-row" data-act="dir-go" data-p="${d}">${icon('folder')}<span><b>${d.split('/').pop()}</b></span>${icon('right', 'chev')}</button>`)}</div>` : ''}
    ${(data.recent || []).length ? html`<h4 class="label">最近使用</h4><div class="card list">${data.recent.map((d) => html`<button class="list-row" data-act="dir-go" data-p="${d}">${icon('clock')}<span><b>${d.split('/').pop()}</b></span></button>`)}</div>` : ''}
    <button class="btn primary full" data-act="dir-use" data-p="${data.path}">使用这里</button>` });
  ACT['dir-go'] = (b) => go(b.dataset.p);
  ACT['dir-use'] = (b) => { W.directory = b.dataset.p; store.set('work.dir', W.directory); import('./ui.js').then((m) => m.closeSheets()); renderWorkComposer(true); changed('work'); };
  go(path);
}
// 审批卡
act('appr-opt', (b) => { const q = b.closest('.q'); q.querySelectorAll('.opt').forEach((o) => o.classList.toggle('on', o === b)); q.querySelector('[data-ans]').value = b.dataset.label; });
act('appr-answer', async (b) => {
  const card = b.closest('.approval'), answers = {};
  for (const inp of card.querySelectorAll('[data-ans]')) { if (!inp.value.trim()) return toast('每个问题都要有回答'); answers[inp.dataset.ans] = inp.value.trim(); }
  b.disabled = true; try { await mutate('/approvals/' + encodeURIComponent(b.dataset.id), { answers }); card.classList.add('done'); fetchSession(); } catch { b.disabled = false; }
});
act('appr-decide', async (b) => {
  let c = b.dataset.c; try { c = JSON.parse(c); } catch { /* string */ }
  b.disabled = true; try { await mutate('/approvals/' + encodeURIComponent(b.dataset.id), { decision: c }); b.closest('.approval').classList.add('done'); fetchSession(); } catch { b.disabled = false; }
});
document.addEventListener('click', (e) => { if (!e.target.closest('.plus-wrap')) $('#workPlus')?.classList.add('hidden'); if (!e.target.closest('.avatar-pick')) $('#agentMenu')?.classList.add('hidden'); });

onChange((keys) => {
  if (!$('#page-work .work')) return;
  if (keys.has('work') || keys.has('/personal/projects') || keys.has('/sessions') || keys.has('*')) { renderWork(); poll(); }
  if (keys.has('work') || keys.has('work-composer')) renderWorkComposer();
});
export { workSend };
