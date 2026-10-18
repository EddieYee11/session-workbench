// 案例 + 下一步闭环 + 线索 + 统一「等你」（2026-10-17/18，对应 iOS CasesViews.swift / ThreadsViews.swift）。
// 后端：/personal/cases、/personal/plan、/personal/thread、/personal/waiting（backend/cases.py、tomorrow_plan.py、threads.py）。
import { S, html, raw, D, load, mutate, changed, setTab, send, relativeTime, clockTime, toast, md, decisionCount, flowItems, locateMessage } from './core.js';
import { icon, act, stamp, empty, section, openSheet, pushSheet, closeSheets, confirmBox } from './ui.js';
import { checklist } from './chat.js';
import { pendingNoteHTML } from './sheets.js';

const ACTIVE = new Set(['running', 'queued', 'waiting', 'attention']);
const TONE = { running: 'accent', queued: 'accent', waiting: 'warning', attention: 'warning', failed: 'danger', done: 'success' };
const pathOf = (id) => '/personal/cases/' + encodeURIComponent(id);
export const casesData = () => D('/personal/cases') || {};
export const planData = () => D('/personal/plan') || {};
export const waitingData = () => D('/personal/waiting') || {};
/** 全局「等你」数：审批卡 + 后端汇总（案例等你、微信在等回话、过期待办）。 */
export const waitingCount = () => decisionCount() + (waitingData().count || 0);
function day(offset) {
  const d = new Date(Date.now() + offset * 86400000);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
const progressBar = (p, live) => p && p.total > 0 ? html`<div class="case-progress ${live ? 'live' : ''}"><i style="width:${Math.max(4, (100 * p.done) / p.total)}%"></i></div><small class="mono faint">${p.done}/${p.total}</small>` : '';

// ─── 入口 ───
export function casesEntry() {
  const c = (D('/personal/next') || {}).cases || casesData();
  const waiting = c.waiting || 0, active = c.active || 0;
  return html`<button class="cases-entry ${waiting ? 'warn' : ''}" data-act="cases-open">${active ? raw('<i class="pulse"></i>') : icon('layers')}${waiting ? `案例 · ${waiting} 等你` : active ? `案例 · ${active} 进行中` : '案例'}</button>`;
}

// ─── 列表 ───
function caseRow(c) {
  const live = ACTIVE.has(c.state);
  const line = c.waiting && c.waiting.question ? '等你：' + c.waiting.question : c.now || `${c.source_label} · ${relativeTime(c.updated_at)}`;
  return html`<button class="card case-row ${c.state === 'waiting' ? 'hl warning' : ''}" data-act="case-open" data-id="${c.id}">
    <div class="row between top"><h3>${c.title}</h3>${stamp(c.state_label, TONE[c.state] || 'neutral')}</div>
    <div class="row">${progressBar(c.progress, live)}</div>
    <small class="${c.state === 'waiting' ? 'warn-text' : 'muted'} row">${c.state === 'running' ? raw('<i class="pulse"></i>') : ''}${line}</small></button>`;
}
function casesView() {
  return {
    title: '案例', wide: true,
    render: () => {
      const items = casesData().items || [];
      const active = items.filter((c) => ACTIVE.has(c.state)), done = items.filter((c) => !ACTIVE.has(c.state));
      return html`${!items.length ? empty('还没有案例', '在「下一步」或待办里点「交给 Com」，或者在聊天里让它办一件复杂的事，它会单独开一个案例，在这里看它一步步怎么做的。', 'layers') : ''}
        ${active.length ? section(`进行中 · ${active.length}`, html`<div class="stack">${active.map(caseRow)}</div>`) : ''}
        ${done.length ? section('做过的', html`<div class="stack">${done.slice(0, 40).map(caseRow)}</div><p class="foot">简单的事不进这里，只留在聊天里。</p>`) : ''}`;
    },
    mounted: () => poll('/personal/cases', () => (casesData().active || 0) > 0 ? 4000 : 20000),
  };
}
let pollTimer = 0;
function poll(path, every) {
  clearTimeout(pollTimer);
  const tick = async () => { if (!document.querySelector('#sheet.on')) return; await load(path); pollTimer = setTimeout(tick, every()); };
  pollTimer = setTimeout(tick, 200);
}
export function openCases() { load('/personal/cases'); document.querySelector('#sheet.on') ? pushSheet(casesView()) : openSheet(casesView()); }
act('cases-open', () => openCases());

// ─── 详情 ───
const TL = { step_doing: '开始：', step_done: '完成：', assumption: '拿了个主意：', waiting: '停下等你：', you: '你说：', failed: '没做成：' };
function caseView(id) {
  return {
    title: '案例', wide: true,
    render: () => {
      const d = D(pathOf(id));
      if (!d) return html`<div class="skeleton"></div><div class="skeleton"></div>`;
      const live = ACTIVE.has(d.state);
      const steps = (d.steps || []).map((x) => ({ text: x.title, status: x.status }));
      const tl = d.timeline || [];
      return html`<div class="detail-head">${stamp(d.state_label, TONE[d.state] || 'neutral')}<small class="faint"> ${d.source_label} · ${relativeTime(d.created_at)}</small>
          <h2>${d.title}</h2>${d.goal ? html`<p>${d.goal}</p>` : ''}
          ${d.now && live ? html`<p class="row now-line"><i class="pulse"></i><b>${d.now}</b></p>` : ''}
          <div class="row">${progressBar(d.progress, live)}</div></div>
        ${threadStrip('case:' + id)}
        ${d.session_id ? html`<button class="link" data-act="thread-go" data-kind="session" data-id="${d.session_id}" data-agent="${d.agent || 'pi'}">${icon('terminal')}在工作页打开执行会话</button>` : ''}
        ${d.state === 'waiting' ? html`<div class="card hl warning"><h3>等你批准</h3><p class="sub">${(d.waiting || {}).question || '它停在一个需要你批准的操作上。'}</p>
          <div class="row actions"><button class="btn primary compact" data-act="case-reply" data-id="${id}" data-text="同意，按你说的删，继续做完。">可以删，继续</button>
          <button class="btn secondary compact" data-act="case-reply" data-id="${id}" data-text="不要删，跳过这一步，把其余的做完。">不用删</button><span class="grow"></span>
          <button class="btn quiet" data-act="case-resolve" data-id="${id}">算了，标完成</button></div></div>` : ''}
        ${d.state === 'failed' && d.outcome && d.outcome.reason ? html`<div class="notice warning">${icon('warning')}<span>没做成：${d.outcome.reason}</span></div>` : ''}
        ${steps.length ? section('步骤', html`<div class="card">${checklist(steps, live)}</div>`) : ''}
        ${d.result ? section('结果', html`<div class="card md">${raw(md(d.result))}</div>`) : ''}
        ${(d.assumptions || []).length ? section('它自己拿主意的地方', html`<div class="card inset">${d.assumptions.map((a) => html`<p class="row">${icon('sparkles')}<span>${a.text}</span></p>`)}</div><p class="foot">信息不够时它选了最稳妥的做法继续；不对的话在下面直接说。</p>`) : ''}
        ${(d.artifacts || []).filter(Boolean).length ? section('产出', html`<div class="card list">${d.artifacts.filter(Boolean).map((p) => html`<div class="kv"><span>${icon(p.startsWith('http') ? 'link' : 'doc')}</span><b class="mono">${p}</b></div>`)}</div>`) : ''}
        ${tl.length ? section('过程', html`<div class="card inset timeline">${tl.slice(-30).map((e) => html`<div class="tl-row ${e.kind === 'you' ? 'you' : ''}"><em class="mono">${clockTime(e.at)}</em><span>${(TL[e.kind] || '') + e.text}</span></div>`)}</div>
          ${d.tool_calls ? html`<p class="foot">Pi 一共动用了 ${d.tool_calls} 次工具。</p>` : ''}`) : ''}
        ${d.can_send || (d.state === 'done' && d.kind !== 'turn') ? html`<div class="case-composer"><textarea id="case-draft" rows="2" placeholder="${d.state === 'done' ? '还要它接着做什么？' : '插一句：补充要求、改方向…'}"></textarea>
          <button class="btn primary compact" data-act="case-send" data-id="${id}">${icon('arrowUp')}</button></div>` : ''}
        ${d.can_cancel ? html`<button class="btn quiet danger-text full" data-act="case-cancel" data-id="${id}">停止这个案例</button>` : ''}`;
    },
    mounted: () => poll(pathOf(id), () => { const d = D(pathOf(id)); return d && ACTIVE.has(d.state) && d.state !== 'waiting' ? 3000 : 15000; }),
  };
}
export function openCase(id) { load(pathOf(id)); document.querySelector('#sheet.on') ? pushSheet(caseView(id)) : openSheet(caseView(id)); }
act('case-open', (b) => openCase(b.dataset.id));
async function caseSend(id, text) {
  try { await mutate(pathOf(id) + '/send', { text }); await load(pathOf(id)); toast('已经告诉它了'); return true; } catch { return false; }
}
act('case-send', async (b) => {
  const box = document.querySelector('#case-draft'); const text = (box?.value || '').trim(); if (!text) return;
  b.disabled = true; if (await caseSend(b.dataset.id, text)) box.value = ''; b.disabled = false;
});
act('case-reply', async (b) => { b.disabled = true; await caseSend(b.dataset.id, b.dataset.text); });
act('case-resolve', async (b) => { b.disabled = true; try { await mutate(pathOf(b.dataset.id) + '/resolve'); await load(pathOf(b.dataset.id)); } catch { /* toast */ } });
act('case-cancel', async (b) => {
  if (!(await confirmBox({ title: '停止这个案例？', message: '停止后 Pi 会中断当前这一步，已经做的不会撤回。', ok: '停止', danger: true }))) return;
  try { await mutate(pathOf(b.dataset.id) + '/cancel'); await load(pathOf(b.dataset.id)); } catch { /* toast */ }
});

// ─── 线索条 ───
const KIND_ICON = { msg: 'message', next: 'boot', todo: 'checklist', case: 'layers', session: 'terminal', project: 'folder' };
const loadingThreads = new Set();
export function threadStrip(key) {
  const path = '/personal/thread?key=' + encodeURIComponent(key);
  const data = D(path);
  if (!data && !loadingThreads.has(path)) { loadingThreads.add(path); load(path).finally(() => loadingThreads.delete(path)); }
  const nodes = (data && data.nodes) || [];
  if (nodes.length < 2) return '';
  return html`<div class="thread-strip"><small class="faint">线索</small><div class="thread-chips">${nodes.map((n, i) => html`${i ? icon('right', 'sep') : ''}<button class="thread-chip ${n.current ? 'current' : ''}" ${n.current ? raw('disabled') : ''} data-act="thread-go" data-kind="${n.kind}" data-id="${n.id}" data-url="${n.url || ''}" data-agent="${n.agent || ''}">
      ${icon(KIND_ICON[n.kind] || 'doc')}<span><small>${n.label || n.kind}</small><b>${n.title}</b></span>${n.state && !n.current ? html`<em>${n.state}</em>` : ''}</button>`)}</div></div>`;
}
act('thread-go', async (b) => {
  const { kind, id, url, agent } = b.dataset;
  if (kind === 'case') { closeSheets(); setTimeout(() => openCase(id), 280); return; }
  if (kind === 'next') { closeSheets(); setTab('next'); return; }
  if (kind === 'msg') { closeSheets(); await locateMessage(id); return; }
  if (kind === 'session') {
    closeSheets(); setTab('work');
    const work = await import('./work.js');
    if (work.openSession) work.openSession({ id, agent: agent || 'pi' }); else toast('到工作页的历史里打开这段会话');
    return;
  }
  if (url) window.open(url, '_blank', 'noopener');
});

// ─── 统一「等你」 ───
function waitingView() {
  return {
    title: '等你', wide: true,
    render: () => {
      const decisions = flowItems.filter((i) => !i.stale);
      const items = (waitingData().items || []).filter((i) => !hiddenWaiting.has(i.id));
      const of = (k) => items.filter((i) => i.kind === k);
      const row = (i, ic, tone, actAttr) => html`<button class="list-row" ${raw(actAttr)}><span class="badge ${tone}">${icon(ic)}</span><span><b>${i.title}</b><small>${i.why}</small></span>${icon('right', 'chev')}</button>`;
      return html`${!decisions.length && !items.length ? empty('没有在等你的事', '要你拍板的审批、停下来等你批准的案例、微信里有人在等回话、过期的待办，都会汇到这里。', 'checkCircle') : ''}
        ${decisions.length ? section(`要你拍板 · ${decisions.length}`, html`<div class="stack">${decisions.map((d) => pendingNoteHTML(d))}</div>`) : ''}
        ${of('case').length ? section(`案例停下来等你 · ${of('case').length}`, html`<div class="card list">${of('case').map((i) => row(i, 'layers', 'warning', `data-act="case-open" data-id="${i.case_id}"`))}</div>`) : ''}
        ${of('wechat').length ? section(`微信在等你回 · ${of('wechat').length}`, html`<div class="card list">${of('wechat').map((i) => html`<div class="wx-wait"><div class="row"><span class="badge info">${icon('message')}</span><span class="grow"><b>${i.title}</b><small>${i.why}</small></span></div>
            <div class="row actions"><button class="btn secondary compact" data-act="wx-draft" data-title="${i.title}" data-why="${i.why}">让 Com 起草回复</button><button class="btn quiet" data-act="wx-done" data-id="${i.id}">已经回了</button></div></div>`)}</div>`) : ''}
        ${of('todo').length ? section(`过期的待办 · ${of('todo').length}`, html`<div class="card list">${of('todo').map((i) => html`<div class="todo-wait"><span class="badge warning">${icon('checklist')}</span><span class="grow"><b>${i.title}</b><small>${i.why}</small></span>
            <button class="btn quiet compact" data-act="waiting-todo" data-a="postpone" data-path="${i.path}">改到明天</button><button class="btn quiet compact" data-act="waiting-todo" data-a="done" data-path="${i.path}">完成</button>
            <button class="btn secondary compact" data-act="todo-delegate" data-path="${i.path}">交给 Com</button></div>`)}</div>`) : ''}`;
    },
    mounted: () => { load('/personal/waiting'); },
  };
}
const hiddenWaiting = new Set();
export function openWaiting() { document.querySelector('#sheet.on') ? pushSheet(waitingView()) : openSheet(waitingView()); }
act('waiting-open', () => openWaiting());
act('wx-draft', async (b) => {
  closeSheets(); setTab('chat');
  await send({ textOverride: `帮我起草一条回复给「${b.dataset.title}」的微信，对方最后说：${b.dataset.why}。先给我看草稿，不要替我发。` });
});
act('wx-done', (b) => { hiddenWaiting.add(b.dataset.id); changed('/personal/waiting'); });
act('waiting-todo', async (b) => {
  b.disabled = true;
  try { await mutate('/personal/today/todos/' + b.dataset.a, { path: b.dataset.path }); toast(b.dataset.a === 'done' ? '已完成' : '已改到明天'); await Promise.all([load('/personal/waiting'), load('/personal/today')]); } catch { b.disabled = false; }
});

// ─── 交给 Com / 加到待办 / 稍后再说 ───
export async function delegateNext(item) {
  try {
    const r = await mutate('/personal/next/' + encodeURIComponent(item.id), { action: 'delegate' });
    await Promise.all([load('/personal/next'), load('/personal/cases')]);
    if (r.mode === 'chat') { setTab('chat'); return; }
    if (r.task_id) openCase(r.task_id);
  } catch { /* toast */ }
}
act('next-delegate', async (b) => {
  const item = ((D('/personal/next') || {}).items || []).find((i) => i.id === b.dataset.id); if (!item) return;
  b.closest('.next-card')?.querySelectorAll('button').forEach((x) => (x.disabled = true));
  await delegateNext(item);
});
act('next-todo', async (b) => {
  const offset = Number(b.dataset.day || 1), when = day(offset);
  const card = b.closest('.next-card'); card?.classList.add('leaving');
  try {
    await mutate('/personal/next/' + encodeURIComponent(b.dataset.id), { action: 'todo', day: when, ...(b.dataset.remind ? { remind_at: when + ' ' + b.dataset.remind } : {}) });
    toast(b.dataset.remind ? `已加到待办，${b.dataset.remind} 提醒你` : '已加到待办');
    await Promise.all([load('/personal/next'), load('/personal/today')]);
  } catch { card?.classList.remove('leaving'); }
});
act('next-snooze', async (b) => {
  b.closest('.next-card')?.classList.add('leaving');
  try { await mutate('/personal/next/' + encodeURIComponent(b.dataset.id), { action: 'snooze' }); toast('明天再提'); await load('/personal/next'); } catch { /* toast */ }
});
act('todo-delegate', async (b) => {
  b.disabled = true;
  try {
    const r = await mutate('/personal/today/todos/delegate', { path: b.dataset.path });
    await load('/personal/cases');
    closeSheets();
    if (r.mode === 'chat') { setTab('chat'); return; }
    if (r.task_id) setTimeout(() => openCase(r.task_id), 280);
  } catch { b.disabled = false; }
});
/** 下一步卡片底部的按钮行。 */
export function nextActions(item) {
  const inTodo = item.in_todo;
  return html`${inTodo ? html`<small class="muted row in-todo">${icon('checklist')}已在待办 · ${inTodo.due ? inTodo.due.slice(5) : '未定日期'}</small>` : ''}
    <div class="row actions"><button class="btn primary compact" data-act="next-delegate" data-id="${item.id}">交给 Com</button>
    ${inTodo ? html`<button class="btn secondary compact" data-act="next-do" data-a="done" data-id="${item.id}">已经做了</button>` : html`<details class="menu"><summary class="btn secondary compact">加到待办</summary><div class="menu-pop">
      <button data-act="next-todo" data-day="0" data-id="${item.id}">今天</button><button data-act="next-todo" data-day="1" data-id="${item.id}">明天</button><button data-act="next-todo" data-day="2" data-id="${item.id}">后天</button>
      <hr><button data-act="next-todo" data-day="1" data-remind="09:00" data-id="${item.id}">明天 9:00 提醒我</button><button data-act="next-todo" data-day="0" data-remind="20:00" data-id="${item.id}">今晚 20:00 提醒我</button></div></details>`}
    <span class="grow"></span><button class="btn quiet" data-act="next-snooze" data-id="${item.id}" title="今天不提，明天再出现">稍后再说</button>
    <button class="btn quiet" data-act="next-do" data-a="dismiss" data-id="${item.id}">不用</button></div>`;
}

// ─── 明天建议 ───
const planPick = { day: '', set: new Set() };
let planHidden = '';
export function planCard() {
  const p = planData(), items = p.items || [];
  if (p.state !== 'open' || !items.length || p.day < day(0) || planHidden === p.day) return '';
  if (planPick.day !== p.day) { planPick.day = p.day; planPick.set = new Set(items.filter((i) => i.checkable && i.checked).map((i) => i.id)); }
  const ic = { todo: 'checklist', next: 'sparkles', event: 'calendar', case: 'layers' };
  const checkable = items.filter((i) => i.checkable);
  return html`<div class="card hl accent plan-card rise"><div class="row between"><h3>明天（周${p.weekday}）</h3><button class="icon-btn" data-act="plan-hide" aria-label="先不看">${icon('x')}</button></div>
    <p class="sub">${p.headline}</p>
    <div class="plan-rows">${items.map((i) => html`<button class="plan-row ${i.checkable ? '' : 'ref'} ${planPick.set.has(i.id) ? 'on' : ''}" data-act="plan-toggle" data-id="${i.id}" data-kind="${i.kind}" data-case="${i.case_id || ''}">
      <i>${i.checkable ? icon(planPick.set.has(i.id) ? 'checkCircle' : 'doc') : icon(ic[i.kind] || 'doc')}</i><span><b>${i.title}</b>${i.why ? html`<small>${i.why}</small>` : ''}</span></button>`)}</div>
    ${checkable.length ? html`<button class="btn primary full" data-act="plan-apply">${planPick.set.size ? `放进明天的待办（${planPick.set.size}）` : '都不用，收起'}</button>` : ''}</div>`;
}
act('plan-toggle', (b) => {
  const item = (planData().items || []).find((i) => i.id === b.dataset.id); if (!item) return;
  if (!item.checkable) { if (item.case_id) openCase(item.case_id); return; }
  planPick.set.has(item.id) ? planPick.set.delete(item.id) : planPick.set.add(item.id);
  changed('/personal/plan');
});
act('plan-hide', () => { planHidden = planData().day; changed('/personal/plan'); });
act('plan-apply', async (b) => {
  b.disabled = true;
  try { await mutate('/personal/plan/apply', { day: planData().day, selected: [...planPick.set] }); toast('放进明天的待办了'); await Promise.all([load('/personal/plan'), load('/personal/next'), load('/personal/today')]); } catch { b.disabled = false; }
});

// ─── 今天页：Com 正在办 ───
export function todayCasesStrip() {
  const active = (casesData().items || []).filter((c) => ACTIVE.has(c.state));
  if (!active.length) return '';
  return html`<div class="card cases-strip rise" style="--d:170ms"><div class="row between"><small class="label">Com 正在办</small><button class="link" data-act="cases-open">全部</button></div>
    ${active.slice(0, 3).map((c) => html`<button class="strip-row" data-act="case-open" data-id="${c.id}">${c.state === 'running' ? raw('<i class="pulse"></i>') : icon('hand')}<b>${c.title}</b><span class="grow"></span>
      <small class="mono ${c.state === 'waiting' ? 'warn-text' : 'faint'}">${c.state === 'waiting' ? '等你' : c.progress && c.progress.total ? `${c.progress.done}/${c.progress.total}` : c.state_label}</small></button>`)}</div>`;
}
export { S };
