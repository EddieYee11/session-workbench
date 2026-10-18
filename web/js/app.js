// Com! 网页版外壳：配对、顶栏（她 + 标题 + 玻璃按钮）、浮动 Dock、下拉工作台、菜单、快捷键、轮询。
import {
  S, $, $$, html, raw, api, store, onChange, changed, setUnauthorized, onTab, setTab, refresh, refreshOthers, refreshFlow, startStream, stopStream, recoverOutbox,
  stage, stripState, stripCaption, stripSign, decisionCount, nextUrgentCount, nextData, runningTasks, brokenSources, load, toast, refreshNext, locateMessage,
} from './core.js';
import { FigureCanvas, kick } from './figure.js';
import { icon, act, ACT, closeSheets, sheetOpen } from './ui.js';
import { mountChat, renderChat, workBubble, focusChat } from './chat.js';
import { renderNext } from './next.js';
import { renderToday, setTodayRender } from './today.js';
import { mountWork, renderWork, renderWorkComposer, W, newChat, workHead, titleMenuHTML, poll as pollWork } from './work.js';
import { menuHTML } from './sheets.js';
import { waitingCount } from './cases.js';

const TABS = [
  { id: 'chat', name: 'Com', ic: 'smile', tint: 'var(--accent-text)' },
  { id: 'next', name: '下一步', ic: 'boot', tint: '#8C54F2' },
  { id: 'today', name: '今天', ic: 'timeline', tint: 'var(--info)' },
  { id: 'work', name: '工作', ic: 'grid', tint: 'var(--warning)' },
];
if (!TABS.some((t) => t.id === S.tab)) S.tab = 'chat';

// ─── 主题 ───
const theme = store.get('com.theme', 'system');
if (theme !== 'system') document.documentElement.dataset.theme = theme;

// ─── 配对 ───
function showPair() {
  $('#app').classList.add('hidden'); $('#pair').classList.remove('hidden');
  if (!$('#pairFig').dataset.on) { $('#pairFig').dataset.on = 1; new FigureCanvas($('#pairFig'), { mode: 'full', state: 'think' }); }
  setTimeout(() => $('#pairCode').focus(), 50);
}
setUnauthorized(() => { S.token = ''; store.del('com.token'); stopStream(); showPair(); });
$('#pairForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const code = $('#pairCode').value.trim(), btn = $('#pairBtn'), err = $('#pairErr');
  if (!code) return;
  btn.disabled = true; err.textContent = '';
  try {
    const r = await api('/pair', { body: { code }, auth: false });
    if (!r || !r.token) throw new Error('配对未返回凭据');
    S.token = r.token; store.set('com.token', r.token); boot();
  } catch (x) { err.textContent = x.message; }
  btn.disabled = false;
});
// #token=xxx 一次性写入
if (location.hash.startsWith('#token=')) { S.token = decodeURIComponent(location.hash.slice(7)); store.set('com.token', S.token); history.replaceState(null, '', location.pathname); }

// ─── 顶栏 ───
let fig = null, lastHead = '';
function head() { return S.tab === 'chat' ? 'Com' : S.tab === 'work' ? workHead() : TABS.find((t) => t.id === S.tab).name; }
function trailing() {
  if (S.stageOpen) return { ic: 'up', label: '收起工作台', act: 'stage-close' };
  if (S.tab === 'chat' || S.tab === 'today') return { ic: 'search', label: '搜索聊天与成果（⌘F）', act: 'open-search' };
  if (S.tab === 'next') { const r = !!nextData().running; return { ic: r ? 'hourglass' : 'refresh', label: '让它重新整理', act: 'next-refresh', disabled: r, spin: r }; }
  return { ic: 'compose', label: '新对话', act: 'work-new-top', disabled: W.mode === 'home' };
}
function renderTop() {
  const bar = $('#topbar');
  const wb = workBubble(), bubble = wb === null ? stripCaption() : wb;
  const talking = !!bubble;
  const h = head();
  const titleEl = bar.querySelector('.tb-title');
  if (titleEl.dataset.v !== h) { titleEl.dataset.v = h; titleEl.textContent = h; titleEl.classList.remove('swap'); void titleEl.offsetWidth; titleEl.classList.add('swap'); }
  bar.querySelector('.tb-chev').classList.toggle('on', S.tab === 'work');
  const cap = bar.querySelector('.tb-cap');
  const caption = stripCaption();
  if (cap.dataset.v !== caption) { cap.dataset.v = caption; cap.textContent = caption; }
  cap.classList.toggle('hide', talking);
  const bub = bar.querySelector('.tb-bubble');
  if (talking) { bub.querySelector('span').textContent = bubble; bub.classList.add('on'); } else bub.classList.remove('on');
  bar.querySelector('.tb-side').classList.toggle('on', S.tab === 'work');
  const t = trailing(), b = bar.querySelector('.tb-trail');
  b.dataset.act = t.act; b.setAttribute('aria-label', t.label); b.title = t.label; b.disabled = !!t.disabled;
  if (b.dataset.ic !== t.ic) { b.dataset.ic = t.ic; b.innerHTML = icon(t.ic).s; b.classList.remove('swap'); void b.offsetWidth; b.classList.add('swap'); }
  b.classList.toggle('spinning', !!t.spin);
  if (fig) fig.set(stripState(), stripSign());
  if (S.stageOpen) renderStage();
  document.title = stage.state && ['thinking', 'working', 'searching', 'writing', 'remembering', 'calendar', 'handoff'].includes(stage.state) ? 'Com! · ' + stripCaption() : waitingCount() ? `(${waitingCount()}) Com!` : 'Com!';
}
act('go-tab', (b) => setTab(b.dataset.tab));
act('work-new-top', () => { newChat(); renderWorkComposer(true); });
act('top-sidebar', () => ACT['work-sidebar']());

// 点她 / 标题：菜单（工作页标题是会话菜单）
act('figure-menu', (b, e) => { toggleMenu('main'); });
act('title-menu', () => toggleMenu(S.tab === 'work' ? 'work' : 'main'));
function toggleMenu(kind) {
  const m = $('#menu');
  if (!m.classList.contains('hidden') && m.dataset.kind === kind) return m.classList.add('hidden');
  m.dataset.kind = kind;
  m.classList.toggle('title-menu', kind === 'work');
  m.innerHTML = (kind === 'work' ? titleMenuHTML() : menuHTML()).s;
  m.classList.remove('hidden');
}
document.addEventListener('click', (e) => {
  const m = $('#menu'); if (!m || m.classList.contains('hidden')) return;
  if (e.target.closest('#menu') && e.target.closest('[data-act]')) { setTimeout(() => m.classList.add('hidden'), 0); return; }
  if (!e.target.closest('#menu, .tb-figure, .tb-titlebox')) m.classList.add('hidden');
});

// ─── 下拉工作台（StagePanel）：按住她往下拉，或从菜单打开 ───
let stageFig = null;
function renderStage() {
  const p = $('#stage');
  const dc = waitingCount(), run = runningTasks().length, broken = brokenSources().length;
  p.querySelector('.stage-stats').innerHTML = html`<button class="schip ${dc ? 'warning' : ''}" data-act="waiting-open">${icon('hand')}等你 ${dc}</button>
    <button class="schip ${run ? 'info' : ''}" data-act="stage-go" data-tab="today">${icon('play')}在跑 ${run}</button>
    <button class="schip ${broken ? 'danger' : 'success'}" data-act="stage-conn">${icon(broken ? 'warning' : 'checkCircle')}${broken ? '信源断了 ' + broken : '信源正常'}</button>
    ${stripState() === 'done' && stage.deliveryID ? html`<button class="schip accent" data-act="stage-reply">${icon('message')}看回复</button>` : ''}`.s;
  p.querySelector('.stage-cap').textContent = stripCaption();
  if (stageFig) stageFig.set(stripState(), stripSign(), { sourceBroken: broken > 0, machine: (runningTasks()[0] || {}).host || '', tertiary: getComputedStyle(document.documentElement).getPropertyValue('--text-3') });
}
function openStage() {
  S.stageOpen = true; $('#menu').classList.add('hidden');
  document.body.classList.add('stage-on');
  if (!stageFig) stageFig = new FigureCanvas($('#stageCanvas'), { mode: 'stage', state: stripState() });
  else stageFig.resize();
  renderStage(); renderTop(); kick();
}
function closeStage() { S.stageOpen = false; document.body.classList.remove('stage-on'); renderTop(); }
act('open-stage', openStage);
act('stage-close', closeStage);
act('stage-go', (b) => { closeStage(); setTab(b.dataset.tab); });
act('stage-conn', () => { closeStage(); ACT['open-connectors'](); });
act('stage-reply', () => { closeStage(); locateMessage(stage.deliveryID); });
function bindPull() {
  const zone = $('#topbar');
  let y0 = null, dragging = false;
  zone.addEventListener('pointerdown', (e) => { if (e.button !== 0 || e.target.closest('button:not(.tb-figure)')) return; y0 = e.clientY; dragging = false; });
  window.addEventListener('pointermove', (e) => {
    if (y0 == null) return;
    const dy = e.clientY - y0;
    if (!dragging && dy > 10) { dragging = true; document.body.classList.add('stage-drag'); }
    if (dragging) $('#stage').style.setProperty('--pull', Math.min(1.1, Math.max(0, dy / 276)));
  });
  window.addEventListener('pointerup', (e) => {
    if (y0 == null) return;
    const dy = e.clientY - y0; y0 = null;
    if (dragging) {
      document.body.classList.remove('stage-drag'); $('#stage').style.removeProperty('--pull');
      if (dy / 276 > 0.3) openStage();
      const swallow = (ev) => { ev.stopPropagation(); ev.preventDefault(); window.removeEventListener('click', swallow, true); };
      window.addEventListener('click', swallow, true); setTimeout(() => window.removeEventListener('click', swallow, true), 50);
    }
  });
}

// ─── Dock ───
function renderDock() {
  const badges = { today: waitingCount(), next: nextUrgentCount() };
  $('#dock').innerHTML = TABS.map((t, i) => html`<button class="dock-item ${S.tab === t.id ? 'on' : ''}" style="--tint:${raw(t.tint)}" data-act="go-tab" data-tab="${t.id}" aria-label="${t.name}" title="${t.name}（⌘${i + 1}）">
    ${icon(t.ic)}${S.tab === t.id ? html`<span class="dock-name">${t.name}</span>` : ''}${S.tab !== t.id && badges[t.id] ? html`<b class="badge-count">${Math.min(99, badges[t.id])}</b>` : ''}</button>`).join('');
}

// ─── 页面切换 ───
const pages = {};
function showTab(tab, again) {
  for (const t of TABS) $('#page-' + t.id).classList.toggle('on', t.id === tab);
  document.body.dataset.tab = tab;
  const el = $('#page-' + tab);
  if (!again) { el.classList.remove('enter'); void el.offsetWidth; el.classList.add('enter'); clearTimeout(el._t); el._t = setTimeout(() => el.classList.remove('enter'), 1600); }
  renderPage(tab);
  renderDock(); renderTop();
  if (tab === 'work') pollWork(true);
  if (tab === 'chat' && again) focusChat();
}
function renderPage(tab) {
  const el = $('#page-' + tab);
  if (tab === 'chat') { if (!pages.chat) { mountChat(el); pages.chat = 1; } else renderChat(); return; }
  if (tab === 'work') { if (!pages.work) { mountWork(el); pages.work = 1; } else { renderWork(); renderWorkComposer(); } return; }
  // 正在输入框里打字时不整页重画
  if (el.contains(document.activeElement) && /INPUT|TEXTAREA/.test(document.activeElement.tagName)) return;
  const sc = el.scrollTop;
  if (tab === 'next') renderNext(el); else if (tab === 'today') renderToday(el);
  el.scrollTop = sc;
}
onTab(showTab);
setTodayRender(() => { if (S.tab === 'today') renderPage('today'); });
onChange((keys) => {
  if (!S.token) return;
  renderTop(); renderDock();
  if (S.tab === 'next' || S.tab === 'today') {
    const relevant = ['/personal/next', '/personal/today', '/personal/connectors', '/personal/finance', '/personal/agency', '/personal/tasks', '/personal/work/proposals?limit=20', '/personal/automations', 'stage', '*'];
    if (relevant.some((k) => keys.has(k))) renderPage(S.tab);
  }
});

// ─── 启动 / 前后台 ───
let pollTimer = 0, ticks = 0, booted = false;
async function boot() {
  $('#pair').classList.add('hidden'); $('#app').classList.remove('hidden');
  if (!fig) { fig = new FigureCanvas($('#figure'), { mode: 'strip', state: stripState(), quiet: false }); bindPull(); }
  showTab(S.tab, false);
  await setActive(true);
}
async function setActive(on) {
  S.active = on; clearInterval(pollTimer); clearInterval(stageTimer);
  if (!on) { stopStream(); return; }
  if (!S.token) return;
  stageTimer = setInterval(() => stage.tick(), 1000);
  await refresh('chat');
  if (!S.active) return;
  startStream();
  recoverOutbox();
  refreshOthers().then(() => { if (S.tab !== 'chat' && S.tab !== 'work') renderPage(S.tab); });
  pollTimer = setInterval(async () => {
    if (!S.active) return;
    ticks++;
    if (ticks % 4 === 0) { refreshFlow(); load('/personal/next'); }
    if (S.tab === 'chat' && S.streaming) return;
    refresh(S.tab);
  }, 15000);
  booted = true;
}
let stageTimer = 0, hiddenAt = 0;
document.addEventListener('visibilitychange', () => {
  if (!S.token) return;
  if (document.hidden) { hiddenAt = Date.now(); setTimeout(() => { if (document.hidden && Date.now() - hiddenAt >= 5 * 60000) setActive(false); }, 5 * 60000); }
  else if (!S.active) setActive(true);
  else refresh(S.tab);
});
window.addEventListener('online', () => { if (S.token && S.active) { startStream(); refresh(S.tab); } });
window.addEventListener('resize', () => { if (fig) fig.resize(); if (stageFig) stageFig.resize(); if (S.tab === 'today') renderPage('today'); });

// ─── 快捷键 ───
document.addEventListener('keydown', (e) => {
  if (!S.token) return;
  const mod = e.metaKey || e.ctrlKey;
  if (mod && e.key.toLowerCase() === 'k') { e.preventDefault(); if (S.tab !== 'chat') setTab('chat'); setTimeout(focusChat, 30); }
  else if (mod && ['1', '2', '3', '4'].includes(e.key)) { e.preventDefault(); setTab(TABS[Number(e.key) - 1].id); }
  else if (mod && e.key.toLowerCase() === 'f' && !sheetOpen()) { e.preventDefault(); ACT['open-search'](); }
  else if (e.key === 'Escape') { if (S.stageOpen) closeStage(); $('#menu').classList.add('hidden'); }
});

if (S.token) boot(); else showPair();
