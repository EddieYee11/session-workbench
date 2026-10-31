// 航程 + 下一步闭环 + 线索 + 统一「等你」（2026-10-17/18，对应 iOS CasesViews.swift / ThreadsViews.swift）。
// 后端：/personal/cases、/personal/plan、/personal/thread、/personal/waiting（backend/cases.py、tomorrow_plan.py、threads.py）。
import { S, BASE, html, raw, D, load, mutate, changed, setTab, send, relativeTime, clockTime, toast, md, decisionCount, flowItems, locateMessage, setNote, noteOf, wasDelivered, afterWrite, patchData, agencyCards, reload } from './core.js';
import { icon, act, stamp, empty, section, openSheet, pushSheet, closeSheets, confirmBox } from './ui.js';
import { checklist } from './chat.js';
import { pendingNoteHTML } from './sheets.js';

const ACTIVE = new Set(['running', 'queued', 'waiting', 'attention']);
const TONE = { running: 'accent', queued: 'accent', waiting: 'warning', attention: 'warning', failed: 'danger', done: 'success' };
const pathOf = (id) => '/personal/cases/' + encodeURIComponent(id);
export const casesData = () => D('/personal/cases') || {};
export const planData = () => D('/personal/plan') || {};
export const waitingData = () => D('/personal/waiting') || {};
/** 全局「等你」数：审批卡 + 后端汇总（航程等你、微信在等回话、过期待办）。 */
export const waitingCount = () => decisionCount() + (waitingData().count || 0);
function day(offset) {
  const d = new Date(Date.now() + offset * 86400000);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
const progressBar = (p, live) => p && p.total > 0 ? html`<div class="case-progress ${live ? 'live' : ''}"><i style="width:${Math.max(4, (100 * p.done) / p.total)}%"></i></div><small class="mono faint">${p.done}/${p.total}</small>` : '';

// ─── 下一步页入口：航程大卡（10-18 重做，原来是右上角一颗小胶囊）───
// 有在跑 / 等你的：反色大卡（最要紧那段的标题、此刻在做什么、进度条）；只有做过的：缩成一行；从没有过：不占位（头像菜单里始终有入口）。
export function voyageBanner() {
  const items = casesData().items || [];
  const live = items.filter((c) => ACTIVE.has(c.state));
  if (!live.length) {
    return items.length ? html`<button class="voyage-quiet" data-act="cases-open">${icon('route')}<b>航程</b><small>看做过的 ${items.length} 段</small>${icon('right', 'chev')}</button>` : '';
  }
  const top = live[0], waiting = live.filter((c) => c.state === 'waiting').length, running = live.length - waiting;
  const p = top.progress || {};
  const line = top.state === 'waiting' ? '等你：' + ((top.waiting || {}).question || '') : top.now || '正在准备';
  return html`<button class="voyage-banner rise" data-act="cases-open" id="voyage-banner">
    <span class="vb-top">${icon('route')}<b>航程</b><span class="grow"></span>${running ? html`<em class="on">${running} 段进行中</em>` : ''}${waiting ? html`<em class="warn">${waiting} 段等你</em>` : ''}</span>
    <span class="vb-title">${top.title}</span>
    <span class="vb-line ${top.state === 'waiting' ? 'warn' : ''}">${top.state === 'running' ? raw('<i class="pulse"></i>') : ''}${line}</span>
    ${p.total > 0 ? html`<span class="vb-bar"><span class="trk"><i style="width:${Math.max(4, (100 * p.done) / p.total)}%"></i></span><small class="mono">${p.done}/${p.total}</small></span>` : ''}
    <span class="vb-more">${live.length > 1 ? `还有 ${live.length - 1} 段 · 全部航程` : '全部航程'}${icon('right')}</span>
  </button>`;
}

// ─── 列表 ───
const isChat = (c) => c.kind === 'turn' || c.source === 'chat';
const FILTERS = [['delegated', '交办', (c) => !isChat(c)], ['chat', '对话', isChat], ['failed', '没做成', (c) => ['failed', 'cancelled'].includes(c.state)], ['all', '全部', () => true]];
const caseUI = { query: '', filter: '', expanded: new Set() };
const AVATAR = ['#6B9EF2', '#EE7389', '#9E73EE', '#4DB88C', '#F59E4D', '#59B3D9'];
const bucketOf = (at) => { const d = new Date(at * 1000), t = new Date(), y = new Date(); y.setDate(t.getDate() - 1); return d.toDateString() === t.toDateString() ? '今天' : d.toDateString() === y.toDateString() ? '昨天' : Date.now() / 1000 - at < 7 * 86400 ? '本周' : '更早'; };
// 一行航程：等你的左边一颗点 · 首字头像 · 标题和时间 · 状态行 · 一句在做什么 / 等你的问题（iOS CaseRow）
function caseRow(c) {
  const waiting = ['waiting', 'attention'].includes(c.state), p = c.progress || {};
  const status = (c.state_label || '') + (p.total > 0 ? ` · ${p.done}/${p.total} 步` : '') + (c.source_label ? ' · 来自' + c.source_label : '');
  const line = waiting && c.waiting && c.waiting.question ? '等你：' + c.waiting.question : c.now || relativeTime(c.created_at) + '开始';
  const title = (c.title || '').trim(), tint = AVATAR[[...title].reduce((n, ch) => n + ch.codePointAt(0), 0) % AVATAR.length];
  return html`<button class="case-line" data-act="case-open" data-id="${c.id}"><i class="dot ${waiting ? 'warn' : c.state === 'running' ? 'run' : ''}"></i>
    <span class="avatar" style="background:${tint}">${[...title][0] || ''}</span>
    <span class="grow"><span class="row between"><b>${title}</b><small class="faint mono">${relativeTime(c.updated_at)}</small></span>
      <small class="st ${TONE[c.state] || ''}">${c.state === 'running' ? raw('<i class="pulse"></i>') : ''}${status}</small><small class="muted clip">${line}</small></span></button>`;
}
function caseGroup(title, ic, rows, limit) {
  const open = caseUI.expanded.has(title) || rows.length <= limit, shown = open ? rows : rows.slice(0, limit);
  return html`<section class="case-group"><div class="group-head sm">${icon(ic)}<span>${title}</span>${limit !== Infinity ? html`<small class="faint mono">${rows.length}</small>` : ''}</div>
    <div class="card list tight">${shown.map(caseRow)}${!open || (caseUI.expanded.has(title) && rows.length > limit) ? html`<button class="link more" data-act="case-more" data-t="${title}">${open ? '收起' : `查看全部（${rows.length}）`}</button>` : ''}</div></section>`;
}
function casesBody() {
  const items = casesData().items || [];
  if (!items.length) return empty('还没有航程', '在「下一步」或待办里点「交给 Com」，或者在聊天里让它办一件复杂的事，它会单独开一段航程，在这里看它一步步怎么做的。', 'layers');
  const cur = caseUI.filter || (items.some((c) => !isChat(c)) ? 'delegated' : 'all'), q = caseUI.query.trim().toLowerCase();
  const live = items.filter((c) => ACTIVE.has(c.state)).sort((a, b) => (['waiting', 'attention'].includes(a.state) ? 0 : 1) - (['waiting', 'attention'].includes(b.state) ? 0 : 1));
  const match = FILTERS.find((f) => f[0] === cur)[2];
  const history = items.filter((c) => !ACTIVE.has(c.state)).filter((c) => (q ? [c.title, c.now, c.result, c.source_label].some((t) => String(t || '').toLowerCase().includes(q)) : match(c))).sort((a, b) => b.updated_at - a.updated_at);
  const buckets = ['今天', '昨天', '本周', '更早'].map((n) => [n, history.filter((c) => bucketOf(c.updated_at) === n)]).filter(([, r]) => r.length);
  return html`${live.length && !q ? caseGroup(`正在办 · ${live.length}`, 'bolt', live, Infinity) : ''}
    ${q ? '' : html`<div class="filters">${FILTERS.map(([k, t, fn]) => { const n = items.filter((c) => !ACTIVE.has(c.state) && fn(c)).length; return html`<button class="chip ${cur === k ? 'on' : ''}" data-act="case-filter" data-k="${k}">${t}${n ? html`<em class="${k === 'failed' ? 'bad' : ''}">${n}</em>` : ''}</button>`; })}</div>`}
    ${buckets.length ? buckets.map(([n, r]) => caseGroup(n, n === '更早' ? 'tray' : 'clock', r, q ? Infinity : n === '更早' ? 0 : 3)) : html`<p class="foot">${q ? `没有搜到「${caseUI.query}」。` : '这一类里还没有做过的航程。'}</p>`}
    ${!q && cur !== 'chat' && items.some(isChat) ? html`<p class="foot">聊天里顺手办的多步任务收在「对话」里。</p>` : ''}`;
}
function casesView() {
  return {
    title: '航程', wide: true,
    render: () => html`${(casesData().items || []).length ? html`<label class="search-field">${icon('search')}<input id="caseSearch" type="search" placeholder="搜全部航程：标题、在做的事、结果" value="${caseUI.query}" autocomplete="off"></label>` : ''}<div id="caseBody">${casesBody()}</div>`,
    mounted: () => poll('/personal/cases', () => (casesData().active || 0) > 0 ? 4000 : 20000),
  };
}
document.addEventListener('input', (e) => {
  if (e.target.id !== 'caseSearch') return;
  caseUI.query = e.target.value; const body = document.getElementById('caseBody'); if (body) body.innerHTML = casesBody().s;
});
act('case-filter', (b) => { caseUI.filter = b.dataset.k; caseUI.expanded = new Set(); document.getElementById('caseBody').innerHTML = casesBody().s; });
act('case-more', (b) => { const t = b.dataset.t; caseUI.expanded.has(t) ? caseUI.expanded.delete(t) : caseUI.expanded.add(t); document.getElementById('caseBody').innerHTML = casesBody().s; });
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
    title: '航程', wide: true,
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
        ${(d.artifacts || []).length ? section('产出', html`<div class="card list">${d.artifacts.map((a) => { const isHtml = /\.html$/i.test(a.name || a.path || ''); return html`<button class="kv art" data-act="case-artifact" data-id="${a.id || ''}" data-name="${a.name || ''}"><span>${icon(isHtml ? 'sparkles' : 'doc')}</span><b>${a.name || a.path}</b><small class="faint">${isHtml ? '点开直接看' : '下载'}</small></button>`; })}</div>`) : ''}
        ${tl.length ? section('过程', html`<div class="card inset timeline">${tl.slice(-30).map((e) => html`<div class="tl-row ${e.kind === 'you' ? 'you' : ''}"><em class="mono">${clockTime(e.at)}</em><span>${(TL[e.kind] || '') + e.text}</span></div>`)}</div>
          ${d.tool_calls ? html`<p class="foot">Pi 一共动用了 ${d.tool_calls} 次工具。</p>` : ''}`) : ''}
        ${d.can_send || (d.state === 'done' && d.kind !== 'turn') ? html`<div class="case-composer"><textarea id="case-draft" rows="2" placeholder="${d.state === 'done' ? '还要它接着做什么？' : '插一句：补充要求、改方向…'}"></textarea>
          <button class="btn primary compact" data-act="case-send" data-id="${id}">${icon('arrowUp')}</button></div>` : ''}
        ${d.can_cancel ? html`<button class="btn quiet danger-text full" data-act="case-cancel" data-id="${id}">停止这段航程</button>` : ''}`;
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
async function refreshAfterCaseChange(id, head) {
  await load(pathOf(id));
  const ok = await afterWrite(['/personal/cases', '/personal/waiting'], {
    noteKey: 'waiting',
    failNote: head + '，等你/航程列表没刷齐——可再拉开等你。不会假装角标已更新。',
    onFail: () => {
      patchData('/personal/cases', (d) => {
        d.items = (d.items || []).map((c) => (c.id === id ? { ...c, state: 'done', state_label: '已完成' } : c));
        d.active = (d.items || []).filter((c) => ACTIVE.has(c.state)).length;
        d.waiting = (d.items || []).filter((c) => c.state === 'waiting').length;
        return d;
      });
      patchData('/personal/waiting', (d) => {
        d.items = (d.items || []).filter((i) => i.case_id !== id && i.id !== 'case:' + id);
        d.count = (d.items || []).length;
        return d;
      });
    },
  });
  return ok;
}
act('case-resolve', async (b) => {
  b.disabled = true;
  try {
    await mutate(pathOf(b.dataset.id) + '/resolve');
    await refreshAfterCaseChange(b.dataset.id, '航程已标完成');
  } catch { b.disabled = false; }
});
act('case-cancel', async (b) => {
  if (!(await confirmBox({ title: '停止这段航程？', message: '停止后 Pi 会中断当前这一步，已经做的不会撤回。', ok: '停止', danger: true }))) return;
  b.disabled = true;
  try {
    await mutate(pathOf(b.dataset.id) + '/cancel');
    await refreshAfterCaseChange(b.dataset.id, '已请它停下');
  } catch { b.disabled = false; }
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

// ─── 统一「等你」（对照 iOS WaitingSheet：一卡一件、ack、agency 整理） ───
function agencyCardHTML(c, hi) {
  const pack = c.preparation;
  return html`<div class="card agency-wait ${hi ? 'wait-first' : ''}" data-aid="${c.id}">
    <div class="meta">${icon('sparkles')}<span>${c.source_label || '事项'}</span><span class="grow"></span>${stamp('等你', 'warning')}</div>
    <h3>${c.title}</h3>${c.why ? html`<p class="sub">${c.why}</p>` : ''}
    ${pack ? html`<div class="card inset"><small class="label">资料已整理</small><p>${pack.summary || ''}</p></div>` : ''}
    <div class="row actions">
      <button class="btn primary compact" data-act="agency-act" data-a="discuss" data-id="${c.id}">交给我办</button>
      ${pack ? html`<button class="btn secondary compact" data-act="agency-act" data-a="later" data-id="${c.id}">晚点</button>`
        : html`<button class="btn secondary compact" data-act="agency-act" data-a="prepare" data-id="${c.id}">先整理资料</button>`}
    </div></div>`;
}
function waitingView() {
  return {
    title: '等你', wide: true,
    render: () => {
      const decisions = flowItems.filter((i) => !i.stale);
      const cards = agencyCards();
      const items = waitingData().items || [];
      const of = (k) => items.filter((i) => i.kind === k);
      const total = decisions.length + cards.length + items.length;
      const tip = decisions[0]?.title || cards[0]?.title || items[0]?.title || '';
      const intro = !total ? '' : tip
        ? html`<p class="wait-intro">先看这件：「${tip}」——一卡一个动作，办完再说下一件。</p>`
        : html`<p class="wait-intro">我先把要你点头的放最上面——一卡看一件。</p>`;
      const note = noteOf('waiting') || noteOf('agency');
      const firstKind = decisions.length ? 'decision' : cards.length ? 'agency' : of('case').length ? 'case' : of('wechat').length ? 'wechat' : of('todo').length ? 'todo' : '';
      const row = (i, ic, tone, actAttr, hi) => html`<button class="list-row ${hi ? 'wait-first' : ''}" ${raw(actAttr)}><span class="badge ${tone}">${icon(ic)}</span><span><b>${i.title}</b><small>${i.why}</small></span>${icon('right', 'chev')}</button>`;
      return html`${note ? html`<div class="notice warning inline-note">${icon('warning')}<span>${note}</span></div>` : ''}
        ${!total ? empty('眼下没有要你拍板的', '审批、航程停顿、微信待回、过期待办会汇到这里。有事我会先整理好再找你。', 'checkCircle') : intro}
        ${decisions.length ? section(`要你拍板 · ${decisions.length}`, html`<div class="stack">${decisions.map((d, i) => html`<div class="${firstKind === 'decision' && i === 0 ? 'wait-first' : ''}">${pendingNoteHTML(d)}</div>`)}</div>`) : ''}
        ${cards.length ? section(`要跟进的事 · ${cards.length}`, html`<div class="stack">${cards.map((c, i) => agencyCardHTML(c, firstKind === 'agency' && i === 0))}</div>`) : ''}
        ${of('case').length ? section(`航程停下来等你 · ${of('case').length}`, html`<div class="card list">${of('case').map((i, n) => row(i, 'layers', 'warning', `data-act="case-open" data-id="${i.case_id}"`, firstKind === 'case' && n === 0))}</div>`) : ''}
        ${of('wechat').length ? section(`微信在等你回 · ${of('wechat').length}`, html`<div class="card list">${of('wechat').map((i, n) => html`<div class="wx-wait ${firstKind === 'wechat' && n === 0 ? 'wait-first' : ''}" data-wid="${i.id}"><div class="row"><span class="badge info">${icon('message')}</span><span class="grow"><b>${i.title}</b><small>${i.why}</small></span></div>
            <div class="row actions"><button class="btn secondary compact" data-act="wx-draft" data-title="${i.title}" data-why="${i.why}">让 Com 起草回复</button><button class="btn quiet" data-act="wx-done" data-id="${i.id}" data-at="${i.at || 0}">已经回了</button></div></div>`)}</div>`) : ''}
        ${of('todo').length ? section(`过期的待办 · ${of('todo').length}`, html`<div class="card list">${of('todo').map((i, n) => html`<div class="todo-wait ${firstKind === 'todo' && n === 0 ? 'wait-first' : ''}" data-path="${i.path}"><span class="badge warning">${icon('checklist')}</span><span class="grow"><b>${i.title}</b><small>${i.why}</small></span>
            <button class="btn quiet compact" data-act="waiting-todo" data-a="postpone" data-path="${i.path}">改到明天</button><button class="btn quiet compact" data-act="waiting-todo" data-a="done" data-path="${i.path}">完成</button>
            <button class="btn secondary compact" data-act="todo-delegate" data-path="${i.path}">交给我办</button></div>`)}</div>`) : ''}`;
    },
    mounted: async () => {
      setNote('waiting', '');
      const r = await reload('/personal/waiting');
      if (!r.ok) setNote('waiting', S.errors['/personal/waiting'] ? `等你清单没读上：${S.errors['/personal/waiting']}——下面仍可能是上一版。` : '等你清单没读上——下面仍可能是上一版。可再拉开。');
      load('/personal/agency'); load('/personal/work/proposals?limit=20'); load('/personal/tasks');
    },
  };
}
export function openWaiting() { document.querySelector('#sheet.on') ? pushSheet(waitingView()) : openSheet(waitingView()); }
act('waiting-open', () => openWaiting());
act('agency-act', async (b) => {
  const id = b.dataset.id, a = b.dataset.a;
  const card = agencyCards().find((c) => c.id === id); if (!card) return;
  b.disabled = true;
  const wrap = b.closest('.agency-wait');
  try {
    const fields = { action: a, ...(card.version != null ? { version: card.version } : card.updated_at != null ? { version: card.updated_at } : {}), ...(a === 'later' ? { hours: 24 } : {}) };
    const result = await mutate('/personal/agency/actions/' + encodeURIComponent(id), fields);
    if (a === 'discuss') {
      await afterWrite(['/personal/agency', '/personal/waiting'], {
        noteKey: 'waiting',
        failNote: '已交给 Com，等你列表没刷齐——可再拉开等你。不会假装角标已更新。',
        onFail: () => patchData('/personal/agency', (d) => { d.cards = (d.cards || []).filter((c) => c.id !== id); return d; }),
      });
      closeSheets(); setTab('chat');
      return;
    }
    if (a === 'prepare') {
      const pack = result && result.result;
      await afterWrite(['/personal/agency'], {
        noteKey: 'agency',
        failNote: '资料已整理，卡片列表没刷齐——可下拉等你或重开详情。不会假装列表已是最新。',
        onFail: () => {
          if (!pack) return;
          patchData('/personal/agency', (d) => {
            d.cards = (d.cards || []).map((c) => (c.id === id ? { ...c, preparation: pack } : c));
            return d;
          });
        },
      });
      toast('资料已整理');
      return;
    }
    // later / handled / mute：乐观收卡
    wrap?.classList.add('leaving');
    await afterWrite(['/personal/agency'], {
      noteKey: 'waiting',
      failNote: (a === 'later' ? '已留到稍后' : '已记下') + '，卡片列表没刷齐——可再拉开等你。不会假装列表已是最新。',
      onFail: () => patchData('/personal/agency', (d) => { d.cards = (d.cards || []).filter((c) => c.id !== id); return d; }),
    });
  } catch { b.disabled = false; wrap?.classList.remove('leaving'); setNote('waiting', '没成，卡还在——可以再试'); }
});
act('wx-draft', async (b) => {
  b.disabled = true;
  const entry = await send({ textOverride: `帮我起草一条回复给「${b.dataset.title}」的微信，对方最后说：${b.dataset.why}。先给我看草稿，不要替我发。` });
  if (!wasDelivered(entry && entry.id)) { b.disabled = false; setNote('waiting', '草稿没送进对话，卡还在——再说一次。'); return; }
  setNote('waiting', ''); closeSheets(); setTab('chat');
});
act('wx-done', async (b) => {
  const id = b.dataset.id, at = Number(b.dataset.at || 0);
  const card = b.closest('.wx-wait');
  b.disabled = true; card?.classList.add('leaving');
  try {
    await mutate('/personal/waiting/ack', { id, at });
    await afterWrite(['/personal/waiting'], {
      noteKey: 'waiting',
      failNote: '已经记下你回了，但列表没刷齐——可再拉开等你。不会假装角标已更新。',
      onFail: () => patchData('/personal/waiting', (d) => {
        d.items = (d.items || []).filter((i) => i.id !== id);
        d.count = (d.items || []).length;
        return d;
      }),
    });
  } catch { card?.classList.remove('leaving'); b.disabled = false; }
});
act('waiting-todo', async (b) => {
  b.disabled = true;
  const wrap = b.closest('.todo-wait'); wrap?.classList.add('leaving');
  const path = b.dataset.path;
  try {
    await mutate('/personal/today/todos/' + b.dataset.a, { path });
    toast(b.dataset.a === 'done' ? '已完成' : '已改到明天');
    const ok = await afterWrite(['/personal/waiting', '/personal/today'], {
      noteKey: 'waiting',
      failNote: '待办改了，但等你/今天没刷齐——可再拉开。不会假装列表已是最新。',
      onFail: () => {
        patchData('/personal/waiting', (d) => {
          d.items = (d.items || []).filter((i) => i.path !== path);
          d.count = (d.items || []).length;
          return d;
        });
        setNote('today', '待办已改，今天页没刷上——可下拉再试。');
      },
    });
    if (!ok) { wrap?.classList.remove('leaving'); b.disabled = false; }
  } catch { wrap?.classList.remove('leaving'); b.disabled = false; }
});

// ─── 交给我办 / 加到待办 / 稍后再说（成功才消卡/跳页；刷失败开口） ───
export async function delegateNext(item) {
  try {
    const r = await mutate('/personal/next/' + encodeURIComponent(item.id), { action: 'delegate' });
    await afterWrite(['/personal/next', '/personal/cases', '/personal/waiting'], {
      noteKey: 'next',
      failNote: '已交给我办，但列表没刷齐——角标可能还在。不会假装列表已是最新。',
      onFail: () => patchData('/personal/next', (d) => { d.items = (d.items || []).filter((x) => x.id !== item.id); return d; }),
    });
    if (r.mode === 'chat') { setTab('chat'); return true; }
    if (r.task_id) { openCase(r.task_id); return true; }
    return true;
  } catch { return false; }
}
act('next-run', async (b) => {
  const item = ((D('/personal/next') || {}).items || []).find((i) => i.id === b.dataset.id); if (!item || !item.action) return;
  const a = item.action, card = b.closest('.next-card');
  card?.querySelectorAll('button').forEach((x) => (x.disabled = true));
  const fail = () => { card?.classList.remove('leaving'); card?.querySelectorAll('button').forEach((x) => (x.disabled = false)); };
  const done = async (kind) => {
    await mutate('/personal/next/' + encodeURIComponent(item.id), { action: kind });
    await afterWrite(['/personal/next'], {
      noteKey: 'next',
      failNote: '办了，但下一步列表没刷齐。不会假装列表已是最新。',
      onFail: () => patchData('/personal/next', (d) => { d.items = (d.items || []).filter((x) => x.id !== item.id); return d; }),
    });
  };
  try {
    if (a.type === 'reply_wechat') {
      try { await navigator.clipboard.writeText(a.draft || ''); toast('草稿已复制，去微信粘贴发送'); } catch { toast('复制失败，请在草稿里手动复制'); fail(); return; }
      card?.classList.add('leaving'); await done('drafted');
    } else if (a.type === 'reply_mail') {
      const q = new URLSearchParams({ subject: a.subject || '', body: a.draft || '' }).toString().replace(/\+/g, '%20');
      window.open('mailto:' + encodeURIComponent(a.to || '') + '?' + q, '_blank');
      card?.classList.add('leaving'); await done('drafted');
    } else if (a.type === 'bookkeep' || a.type === 'calendar') {
      const text = a.type === 'bookkeep'
        ? ('记一笔 ' + amount(a.amount) + ' 元' + (a.note ? ' ' + a.note : ''))
        : ('加个日程：' + a.title + ' ' + a.start + (a.end ? ' 到 ' + a.end : ''));
      const entry = await send({ textOverride: text });
      if (!wasDelivered(entry && entry.id)) { fail(); setNote('next', '没送进对话，卡还在——再点一次。'); return; }
      card?.classList.add('leaving'); await done('done'); setTab('chat');
    }
  } catch { fail(); }
});
act('next-delegate', async (b) => {
  const item = ((D('/personal/next') || {}).items || []).find((i) => i.id === b.dataset.id); if (!item) return;
  const card = b.closest('.next-card');
  card?.querySelectorAll('button').forEach((x) => (x.disabled = true));
  card?.classList.add('leaving');
  if (!(await delegateNext(item))) { card?.classList.remove('leaving'); card?.querySelectorAll('button').forEach((x) => (x.disabled = false)); }
});
act('next-todo', async (b) => {
  const offset = Number(b.dataset.day || 1), when = day(offset);
  const id = b.dataset.id;
  const card = b.closest('.next-card'); card?.classList.add('leaving');
  try {
    await mutate('/personal/next/' + encodeURIComponent(id), { action: 'todo', day: when, ...(b.dataset.remind ? { remind_at: when + ' ' + b.dataset.remind } : {}) });
    toast(b.dataset.remind ? `已加到待办，${b.dataset.remind} 提醒你` : '已加到待办');
    await afterWrite(['/personal/next', '/personal/today'], {
      noteKey: 'next',
      failNote: '已加到待办，但下一步/今天没刷齐。不会假装列表已是最新。',
      onFail: () => {
        patchData('/personal/next', (d) => { d.items = (d.items || []).filter((x) => x.id !== id); return d; });
        setNote('today', '已加到待办，今天页没刷上——可下拉再试。');
      },
    });
  } catch { card?.classList.remove('leaving'); }
});
act('next-snooze', async (b) => {
  const id = b.dataset.id;
  const card = b.closest('.next-card'); card?.classList.add('leaving');
  try {
    await mutate('/personal/next/' + encodeURIComponent(id), { action: 'snooze' });
    toast('明天再提');
    await afterWrite(['/personal/next'], {
      noteKey: 'next',
      failNote: '已稍后，但列表没刷齐。不会假装列表已是最新。',
      onFail: () => patchData('/personal/next', (d) => { d.items = (d.items || []).filter((x) => x.id !== id); return d; }),
    });
  } catch { card?.classList.remove('leaving'); }
});
act('todo-delegate', async (b) => {
  b.disabled = true;
  const wrap = b.closest('.todo-wait'); wrap?.classList.add('leaving');
  const path = b.dataset.path;
  try {
    const r = await mutate('/personal/today/todos/delegate', { path });
    await afterWrite(['/personal/cases', '/personal/waiting', '/personal/today'], {
      noteKey: 'waiting',
      failNote: '已接进航程，但等你角标可能还在。不会假装角标已更新。',
      onFail: () => patchData('/personal/waiting', (d) => {
        d.items = (d.items || []).filter((i) => i.path !== path);
        d.count = (d.items || []).length;
        return d;
      }),
    });
    closeSheets();
    if (r.mode === 'chat') { setTab('chat'); return; }
    if (r.task_id) setTimeout(() => openCase(r.task_id), 280);
  } catch { wrap?.classList.remove('leaving'); b.disabled = false; }
});
/** 下一步：一卡一主动作，其余收进「更多」（对照 iOS NextView 10-29）。 */
export function nextActions(item) {
  const inTodo = item.in_todo;
  const hasAction = !!(item.action && item.action.type);
  return html`${inTodo ? html`<small class="muted row in-todo">${icon('checklist')}已在待办 · ${inTodo.due ? inTodo.due.slice(5) : '未定日期'}</small>` : ''}
    ${nextDraft(item.action)}
    <div class="row actions">
      ${hasAction
        ? html`<button class="btn primary compact" data-act="next-run" data-id="${item.id}">${nextActionTitle(item.action)}</button>`
        : html`<button class="btn primary compact" data-act="next-delegate" data-id="${item.id}">跟我说怎么办</button>`}
      <details class="menu next-more"><summary class="btn secondary compact" aria-label="更多">${icon('dots')}</summary><div class="menu-pop">
        ${hasAction ? html`<button data-act="next-delegate" data-id="${item.id}">交给我办</button>` : ''}
        ${inTodo ? html`<button data-act="next-do" data-a="done" data-id="${item.id}">已经做了</button>` : html`
          <button data-act="next-todo" data-day="0" data-id="${item.id}">加到今天待办</button>
          <button data-act="next-todo" data-day="1" data-id="${item.id}">加到明天待办</button>
          <button data-act="next-todo" data-day="1" data-remind="09:00" data-id="${item.id}">明天 9:00 提醒我</button>
          <button data-act="next-do" data-a="done" data-id="${item.id}">已经做了</button>`}
        <button data-act="next-snooze" data-id="${item.id}">稍后再说</button>
        <hr>
        ${DISMISS_REASONS.map(([k, t]) => html`<button data-act="next-do" data-a="dismiss" data-reason="${k}" data-id="${item.id}">${t}</button>`)}
        <button data-act="next-do" data-a="dismiss" data-id="${item.id}">只是划掉</button>
      </div></details>
      <span class="grow"></span>
    </div>`;
}
// 划掉的理由（后端 next_steps.REASONS）：「已经办了」算做完；「别人在负责」不静音整个项目话题
const DISMISS_REASONS = [['elsewhere', '已经办了'], ['others', '别人在负责'], ['unimportant', '不重要'], ['not_mine', '不是我的事']];
const amount = (v) => String(Math.round(Number(v || 0) * 100) / 100);
export function nextActionTitle(a) {
  return ({ reply_wechat: '复制草稿去微信', reply_mail: '用邮件回', bookkeep: '记这笔 ¥' + amount(a.amount), calendar: '加到日程' })[a.type] || '现在去办';
}
// 替他写好的回复草稿 / 要记的账 / 要加的日程，点开看全文
function nextDraft(a) {
  if (!a || !a.type) return '';
  const label = a.type === 'reply_wechat' ? `回「${a.to || ''}」的草稿` : a.type === 'reply_mail' ? `回 ${a.to_name || a.to || ''} 的草稿` : a.type === 'bookkeep' ? '要记的账' : '要加的日程';
  const body = a.type === 'bookkeep' ? `¥${amount(a.amount)}${a.note ? ' · ' + a.note : ''}` : a.type === 'calendar' ? `${a.title || ''} · ${a.start || ''}${a.end ? '–' + String(a.end).slice(-5) : ''}` : (a.draft || '');
  return html`<details class="draft"><summary>${icon(a.type === 'bookkeep' ? 'card' : a.type === 'calendar' ? 'calendar' : a.type === 'reply_mail' ? 'envelope' : 'message')}<b>${label}</b></summary><p>${body}</p></details>`;
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
  const dayKey = planData().day;
  try {
    await mutate('/personal/plan/apply', { day: dayKey, selected: [...planPick.set] });
    toast('放进明天的待办了');
    await afterWrite(['/personal/plan', '/personal/next', '/personal/today'], {
      noteKey: 'next',
      failNote: '已放进待办，但计划/下一步没刷齐。不会假装列表已是最新。',
      onFail: () => patchData('/personal/plan', (d) => { if (d.day === dayKey) d.state = 'closed'; return d; }),
    });
  } catch { b.disabled = false; }
});

export { S };

// 航程产出：HTML 在沙箱 iframe 里直接交互（不给同源权限、不联网），其它文件走下载
act('case-artifact', async (b) => {
  const { id, name } = b.dataset;
  if (!id) return toast('这个产出还没登记，打不开');
  try {
    const res = await fetch(BASE + '/personal/artifacts/' + encodeURIComponent(id), { headers: { Authorization: 'Bearer ' + S.token } });
    if (!res.ok) throw new Error('打不开（' + res.status + '）');
    if (/\.html$/i.test(name)) {
      const text = await res.text();
      openSheet({ title: name.replace(/\.html$/i, ''), render: () => html`<iframe class="art-frame" sandbox="allow-scripts" referrerpolicy="no-referrer" srcdoc="${text}"></iframe>` });
    } else {
      const url = URL.createObjectURL(await res.blob());
      Object.assign(document.createElement('a'), { href: url, download: name }).click();
      setTimeout(() => URL.revokeObjectURL(url), 10000);
    }
  } catch (e) { toast(e.message || '打不开'); }
});
