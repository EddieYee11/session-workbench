// 通用 UI：图标、事件委托、弹出面板栈、确认框、常用小组件（印章、Agent 头像、空状态…）。
import { html, raw, esc, $, changed, onChange } from './core.js';

// ─── 图标（24 栅格线条，对应 iOS 用到的 SF Symbols） ───
const I = {
  search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
  refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
  hourglass: '<path d="M6 3h12M6 21h12M7 3c0 5 10 6 10 9s-10 4-10 9M17 3c0 5-10 6-10 9s10 4 10 9"/>',
  sidebar: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M9 4v16"/>',
  compose: '<path d="M12 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-6"/><path d="M17.5 3.5a2.1 2.1 0 0 1 3 3L12 15l-4 1 1-4z"/>',
  up: '<path d="m6 15 6-6 6 6"/>', down: '<path d="m6 9 6 6 6-6"/>', right: '<path d="m9 6 6 6-6 6"/>', left: '<path d="m15 6-6 6 6 6"/>',
  x: '<path d="M6 6l12 12M18 6 6 18"/>', plus: '<path d="M12 5v14M5 12h14"/>',
  mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
  arrowUp: '<path d="M12 19V5M5 12l7-7 7 7"/>', arrowDown: '<path d="M12 5v14M5 12l7 7 7-7"/>', arrowUpRight: '<path d="M7 17 17 7M8 7h9v9"/>',
  stop: '<rect x="7" y="7" width="10" height="10" rx="2" fill="currentColor"/>',
  stopCircle: '<circle cx="12" cy="12" r="9"/><rect x="9" y="9" width="6" height="6" rx="1" fill="currentColor"/>',
  paperclip: '<path d="m21 11-8.5 8.5a5 5 0 0 1-7-7L14 4a3.5 3.5 0 0 1 5 5l-8.5 8.5a2 2 0 0 1-3-3L15 7"/>',
  check: '<path d="m5 12 5 5 9-10"/>', checkCircle: '<circle cx="12" cy="12" r="9"/><path d="m8 12 3 3 5-6"/>',
  bell: '<path d="M6 16V11a6 6 0 0 1 12 0v5l2 2H4z"/><path d="M10 20a2 2 0 0 0 4 0"/>',
  calendar: '<rect x="3" y="5" width="18" height="16" rx="3"/><path d="M3 10h18M8 3v4M16 3v4"/>',
  checklist: '<path d="m4 6 2 2 3-3M4 13l2 2 3-3M12 7h8M12 14h8M12 20h8"/>',
  hand: '<path d="M8 13V5.5a1.5 1.5 0 0 1 3 0V12M11 11V4a1.5 1.5 0 0 1 3 0v7M14 11V5.5a1.5 1.5 0 0 1 3 0V14c0 4-3 7-6.5 7S5 19 4 16l-1-3a1.5 1.5 0 0 1 2.7-1.2L8 15"/>',
  desktop: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>',
  people: '<circle cx="9" cy="8" r="3.5"/><path d="M2 20c0-4 3-6 7-6s7 2 7 6"/><circle cx="17" cy="9" r="2.5"/><path d="M17 14c3 0 5 2 5 5"/>',
  run: '<circle cx="14" cy="4.5" r="2"/><path d="m8 21 3-6 3 2v5M6 12l3-4 5 1 3 4h3M11 15l-2-4"/>',
  climb: '<path d="M3 20 10 8l4 6 3-4 4 10z"/><circle cx="16" cy="5" r="1.6"/>',
  bike: '<circle cx="6" cy="16" r="4"/><circle cx="18" cy="16" r="4"/><path d="M6 16 9 9h6l3 7M9 9 12 16M14 5h3"/>',
  dumbbell: '<path d="M6 7v10M18 7v10M3 10v4M21 10v4M6 12h12"/>',
  fork: '<path d="M7 3v8a2 2 0 0 0 4 0V3M9 11v10M17 3c-2 0-3 2-3 5s1 4 3 4v9"/>',
  plane: '<path d="M10 14 3 12l1-2 7 1 4-7h2l-1 8 5 1 1 2-6 1-1 6h-2z"/>',
  phone: '<path d="M5 3h4l2 5-2.5 1.5a11 11 0 0 0 6 6L16 13l5 2v4a2 2 0 0 1-2 2A17 17 0 0 1 3 5a2 2 0 0 1 2-2"/>',
  envelope: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/>',
  heart: '<path d="M12 20s-7-4.5-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.5-7 10-7 10"/>',
  card: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 10h18M7 15h4"/>',
  link: '<path d="M10 14a4 4 0 0 0 6 .5l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-6-.5l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
  brain: '<path d="M9 4a3 3 0 0 0-3 3 3 3 0 0 0-2 5 3 3 0 0 0 2 5 3 3 0 0 0 6 1V5a2 2 0 0 0-3-1M15 4a3 3 0 0 1 3 3 3 3 0 0 1 2 5 3 3 0 0 1-2 5 3 3 0 0 1-6 1"/>',
  sliders: '<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>',
  layers: '<rect x="3" y="4" width="7" height="16" rx="1.5"/><rect x="14" y="4" width="7" height="7" rx="1.5"/><rect x="14" y="13" width="7" height="7" rx="1.5"/>',
  sparkles: '<path d="M12 3l1.8 4.6L18 9.5l-4.2 1.9L12 16l-1.8-4.6L6 9.5l4.2-1.9z"/><path d="M19 15l.8 2 2 .8-2 .8-.8 2-.8-2-2-.8 2-.8z"/>',
  folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  cpu: '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',
  gauge: '<path d="M4 16a8 8 0 1 1 16 0"/><path d="m12 16 4-5"/>',
  terminal: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3M13 15h4"/>',
  globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18"/>',
  pencil: '<path d="M16 4l4 4L8 20H4v-4z"/>',
  book: '<path d="M4 5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2z"/><path d="M4 19V5M19 19v2H6"/>',
  yen: '<path d="M6 4l6 8 6-8M12 12v8M8 13h8M8 16h8"/>',
  send: '<path d="M4 12 20 4l-6 16-3-7z"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5 19 19M19 5l-1.5 1.5M6.5 17.5 5 19"/>',
  iphone: '<rect x="7" y="2" width="10" height="20" rx="2.5"/><path d="M11 18h2"/>',
  doc: '<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4M9 12h6M9 16h6"/>',
  archive: '<rect x="3" y="4" width="18" height="5" rx="1"/><path d="M5 9v10h14V9M10 13h4"/>',
  scope: '<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3"/>',
  pin: '<path d="M9 3h6l-1 6 4 3v2H6v-2l4-3zM12 14v7"/>',
  eye: '<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12"/><circle cx="12" cy="12" r="3"/>',
  waveform: '<path d="M4 10v4M8 6v12M12 3v18M16 7v10M20 10v4"/>',
  message: '<path d="M4 5h16v11H9l-5 4z"/>',
  tray: '<path d="M3 13h5l1 3h6l1-3h5M5 5h14l2 8v6H3v-6z"/>',
  warning: '<path d="M12 3 2 20h20z"/><path d="M12 10v4M12 17h.01"/>',
  play: '<circle cx="12" cy="12" r="9"/><path d="m10 8 6 4-6 4z"/>',
  smile: '<circle cx="12" cy="12" r="9"/><path d="M8 14s1.5 2 4 2 4-2 4-2M9 9.5h.01M15 9.5h.01"/>',
  timeline: '<rect x="3" y="4" width="18" height="17" rx="3"/><path d="M3 9h18M7 13h5M9 17h7"/>',
  grid: '<rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  repeat: '<path d="M17 2l4 4-4 4M3 11V9a3 3 0 0 1 3-3h15M7 22l-4-4 4-4M21 13v2a3 3 0 0 1-3 3H3"/>',
  copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3"/>',
  reply: '<path d="M10 9 4 14l6 5M4 14h10a6 6 0 0 0 6-6V5"/>',
  macmini: '<rect x="3" y="8" width="18" height="8" rx="2"/><path d="M7 12h.01"/>',
  laptop: '<rect x="5" y="5" width="14" height="10" rx="1.5"/><path d="M3 19h18"/>',
  photo: '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="10" r="2"/><path d="m21 16-5-5-8 9"/>',
  person: '<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4.5 3.5-7 8-7s8 2.5 8 7"/>',
  briefcase: '<rect x="3" y="7" width="18" height="13" rx="2"/><path d="M9 7V5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2M3 13h18"/>',
  video: '<rect x="3" y="6" width="13" height="12" rx="2"/><path d="m16 10 5-3v10l-5-3"/>',
  wrench: '<path d="M14 6a4 4 0 0 0 5 5l-9 9a2 2 0 0 1-3-3l9-9a4 4 0 0 0-2-2z"/>',
  stack: '<path d="m12 3 9 5-9 5-9-5z"/><path d="m3 13 9 5 9-5"/>',
  leaf: '<path d="M5 19c0-9 6-14 15-15-1 9-6 15-15 15zM5 19l7-7"/>',
  moon: '<path d="M20 14A8 8 0 1 1 10 4a6 6 0 0 0 10 10z"/>',
  dots: '<circle cx="5" cy="12" r="1.6" fill="currentColor"/><circle cx="12" cy="12" r="1.6" fill="currentColor"/><circle cx="19" cy="12" r="1.6" fill="currentColor"/>',
  boot: '<path d="M7 3h6v9l6 3a2 2 0 0 1 1 2v2H5V5a2 2 0 0 1 2-2z"/><path d="M5 15h15M9 7h4M9 10h4"/>',
  share: '<path d="M12 3v13M7 8l5-5 5 5M5 14v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5"/>',
  wifiOff: '<path d="M2 8a16 16 0 0 1 5-3M22 8a16 16 0 0 0-9-4M5 12a11 11 0 0 1 4-2.5M19 12a11 11 0 0 0-3-2M8.5 15.5a5 5 0 0 1 7 0M12 19h.01M3 3l18 18"/>',
  cloud: '<path d="M7 18h10a4 4 0 0 0 0-8 6 6 0 0 0-11.5 2A3 3 0 0 0 7 18z"/>',
  route: '<circle cx="6" cy="19" r="2"/><circle cx="18" cy="5" r="2"/><path d="M6 17V11a4 4 0 0 1 4-4h6"/>',
};
export const icon = (name, cls = '') => raw(`<svg class="ic ${cls}" viewBox="0 0 24 24" aria-hidden="true">${I[name] || I.doc}</svg>`);

// ─── 事件委托：data-act="名字"，各模块往 ACT 里登记 ───
export const ACT = {};
export function act(name, fn) { ACT[name] = fn; }
document.addEventListener('click', (e) => {
  const t = e.target.closest('[data-act]');
  if (!t || t.disabled || t.getAttribute('aria-disabled') === 'true') return;
  const fn = ACT[t.dataset.act];
  if (fn) { e.preventDefault(); fn(t, e); }
});

// ─── 弹出面板栈（iOS 的 sheet / NavigationStack）：每层 {title, render, wide, back} ───
const stack = [];
export function openSheet(view) {
  stack.push(view); renderSheet(true);
}
export function pushSheet(view) { if (!stack.length) return openSheet(view); stack.push({ ...view, pushed: true }); renderSheet(true); }
export function popSheet() { stack.pop(); renderSheet(false); if (!stack.length) closeSheets(); }
export function closeSheets() {
  stack.length = 0;
  const host = $('#sheet');
  if (!host.classList.contains('on')) return;
  host.classList.remove('on'); host.classList.add('closing');
  setTimeout(() => { host.classList.remove('closing'); if (!stack.length) host.innerHTML = ''; }, 260);
}
export const sheetOpen = () => stack.length > 0;
export const topSheet = () => stack[stack.length - 1];
export function renderSheet(enter) {
  const host = $('#sheet');
  const v = stack[stack.length - 1];
  if (!v) return;
  const body = host.querySelector('.sheet-body');
  // 输入框正在打字时不整块重画（输入内容和焦点会丢）。
  if (!enter && body && body.contains(document.activeElement) && /INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName)) return;
  const scroll = body ? body.scrollTop : 0;
  host.innerHTML = html`<div class="sheet-scrim" data-act="sheet-close"></div>
    <div class="sheet-panel ${v.wide ? 'wide' : ''} ${enter ? 'enter' : ''}" role="dialog" aria-modal="true" aria-label="${v.title}">
      <header class="sheet-head">
        ${stack.length > 1 ? html`<button class="icon-btn" data-act="sheet-back" aria-label="返回">${icon('left')}</button>` : html`<span class="spacer"></span>`}
        <h2>${v.title}</h2>
        ${v.trailing ? v.trailing() : ''}
        <button class="pill-btn" data-act="sheet-close">完成</button>
      </header>
      <div class="sheet-body">${v.render()}</div>
    </div>`.s;
  host.classList.add('on');
  const nb = host.querySelector('.sheet-body');
  if (!enter) nb.scrollTop = scroll;
  if (v.mounted) v.mounted(nb);
}
act('sheet-close', () => closeSheets());
act('sheet-back', () => popSheet());
onChange(() => { if (stack.length) renderSheet(false); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && stack.length && !document.querySelector('.confirm.on')) { e.preventDefault(); stack.length > 1 ? popSheet() : closeSheets(); } });

// ─── 确认框 ───
export function confirmBox({ title, message, ok = '确定', cancel = '取消', danger = false, detail }) {
  return new Promise((resolve) => {
    const host = $('#confirm');
    host.innerHTML = html`<div class="confirm-card" role="alertdialog" aria-label="${title}">
      <h3>${title}</h3>${message ? html`<p>${message}</p>` : ''}${detail || ''}
      <div class="row end"><button class="btn secondary" data-c="0">${cancel}</button><button class="btn ${danger ? 'danger' : 'primary'}" data-c="1">${ok}</button></div></div>`.s;
    host.classList.add('on');
    const done = (v) => { host.classList.remove('on'); host.removeEventListener('click', onClick); document.removeEventListener('keydown', onKey, true); resolve(v); };
    const onClick = (e) => { const b = e.target.closest('[data-c]'); if (b) done(b.dataset.c === '1'); else if (e.target === host) done(false); };
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); done(false); } if (e.key === 'Enter') { e.preventDefault(); done(true); } };
    host.addEventListener('click', onClick); document.addEventListener('keydown', onKey, true);
    setTimeout(() => host.querySelector('[data-c="1"]')?.focus(), 30);
  });
}

// ─── 小组件 ───
export const stamp = (text, tone = 'neutral', dashed = false) => text ? html`<span class="stamp ${tone} ${dashed ? 'dashed' : ''}">${text}</span>` : '';
export const empty = (title, desc, ic = 'sparkles') => html`<div class="empty">${icon(ic)}<h3>${title}</h3>${desc ? html`<p>${desc}</p>` : ''}</div>`;
export const notice = (text, tone = 'danger') => text ? html`<div class="notice ${tone}">${icon(tone === 'danger' ? 'warning' : 'sparkles')}<span>${text}</span></div>` : '';
export const section = (title, body, trailing = '') => html`<section class="group"><div class="group-head"><h3>${title}</h3>${trailing}</div>${body}</section>`;
export const kv = (label, value) => value ? html`<div class="kv"><span>${label}</span><b>${value}</b></div>` : '';
export function rawDetails(title, value) {
  if (value == null) return '';
  let text; try { text = typeof value === 'string' ? value : JSON.stringify(value, null, 2); } catch { text = String(value); }
  return html`<details class="raw"><summary>${title}</summary><pre>${text}</pre></details>`;
}

const BRAND = {
  claude: { mark: 'assets/agent-claude.png', ink: 'var(--b-claude)', wash: 'var(--w-claude)', inset: 0.22 },
  codex: { mark: 'assets/agent-codex.png', ink: 'var(--b-codex)', wash: 'var(--w-codex)', inset: 0.22 },
  hermes: { mark: 'assets/agent-hermes.png', ink: 'var(--b-hermes)', wash: 'var(--w-hermes)', inset: 0.1 },
  pi: { mark: 'assets/agent-pi.png', ink: 'var(--b-pi)', wash: 'var(--w-pi)', inset: 0.27 },
};
export const agentBrand = (a) => BRAND[a];
export function agentMark(agent, size = 14) {
  const b = BRAND[agent];
  if (!b) return icon('grid');
  return raw(`<i class="agent-mark" style="width:${size}px;height:${size}px;background:${b.ink};-webkit-mask-image:url(${b.mark});mask-image:url(${b.mark})"></i>`);
}
export function agentAvatar(agent, size = 36, stampKey = '') {
  const b = BRAND[agent];
  const pad = size * (b ? b.inset : 0.28);
  return raw(`<span class="agent-avatar ${stampKey ? 'stamp-in' : ''}" data-k="${esc(stampKey)}" style="width:${size}px;height:${size}px;background:${b ? b.wash : 'var(--fill)'}">${agentMark(agent, size - pad * 2)}</span>`);
}
export const agentTint = (a) => (BRAND[a] ? BRAND[a].ink : 'var(--text-2)');

/** 数字从 0 爬到终值（13-leaderboard-counter）。 */
export function countUp(root) {
  if (!root) return;
  for (const el of root.querySelectorAll('[data-count]')) {
    const to = Number(el.dataset.count) || 0;
    if (matchMedia('(prefers-reduced-motion: reduce)').matches || !root.closest('.enter')) { el.textContent = to; continue; }
    const t0 = performance.now(), dur = 700, delay = 400;
    const step = (now) => {
      const p = Math.min(1, Math.max(0, (now - t0 - delay) / dur));
      el.textContent = Math.round(to * (1 - Math.pow(1 - p, 2)));
      if (p < 1) requestAnimationFrame(step);
    };
    el.textContent = '0'; requestAnimationFrame(step);
  }
}
export { changed };
