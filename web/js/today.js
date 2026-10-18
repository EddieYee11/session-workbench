// 「今天」：日程、提醒、行动台待办和等你拍板的事排成一条时间线（iOS TodayView.swift + BodyViews.swift）。
import {
  S, $, html, raw, esc, D, nextData, flowItems, clockTime, relativeTime, sourceName, WEEK, mutate, load, send, setTab, runningTasks, decisionCount, staleItems,
  refreshNext, store, toast, sleep, onChange,
} from './core.js';
import { icon, act, stamp, empty, openSheet, pushSheet, kv, section, countUp } from './ui.js';
import { pendingNoteHTML } from './sheets.js';
import { todayCasesStrip, threadStrip } from './cases.js';

// ─── 条目（TodayEntry） ───
const settling = new Set();
export const todayData = () => D('/personal/today') || null;
export function todayEntries() {
  const d = todayData() || {}, out = [];
  for (const e of d.events || []) {
    const allDay = !!e.all_day;
    const place = [e.location, sourceName(e.source)].filter(Boolean).join(' · ');
    out.push({ id: 'event:' + e.id, kind: 'event', title: e.title || '', subtitle: allDay ? place : [clockTime(e.start) + (e.end > e.start ? '–' + clockTime(e.end) : ''), e.location].filter(Boolean).join(' · '), start: allDay ? 0 : e.start || 0, end: e.end || 0, overdue: false, done: false, value: e });
  }
  const dayStart = new Date().setHours(0, 0, 0, 0) / 1000;
  for (const r of d.reminders || []) {
    const done = r.status === 'done' || settling.has('reminder:' + r.id);
    if (done && (r.at || 0) < dayStart) continue;
    const overdue = !!r.overdue && !done;
    out.push({ id: 'reminder:' + r.id, kind: 'reminder', title: r.title || '', subtitle: overdue ? '过期没处理 · ' + (r.due || '') : done ? '已完成' : '提醒', start: overdue ? 0 : r.at || 0, end: 0, overdue, done, value: r });
  }
  for (const t of d.todos || []) {
    if (settling.has('todo:' + t.id)) continue;
    out.push({ id: 'todo:' + t.id, kind: 'todo', title: t.title || '', subtitle: [t.overdue ? '已过期 · 计划 ' + t.due : !t.due ? '进行中' : '今天到期', t.next_step].filter(Boolean).join(' · '), start: 0, end: 0, overdue: !!t.overdue, done: false, value: t });
  }
  for (const it of flowItems) if (!it.stale) out.push({ id: 'decision:' + it.id, kind: 'decision', title: it.title, subtitle: [it.stamp, it.source].filter(Boolean).join(' · '), start: 0, end: 0, overdue: false, done: false, value: it.value, pending: it });
  return out;
}
const isPast = (e, now) => (e.kind === 'event' ? e.start > 0 && (e.end > e.start ? e.end : e.start + 1800) < now : e.kind === 'reminder' ? e.done || (e.start > 0 && e.start < now && !e.overdue) : false);
function hue(e) {
  if (e.kind === 'reminder' || e.kind === 'decision') return 'butter';
  if (e.kind === 'todo') return 'pink';
  const cal = String(e.value.calendar || '').toLowerCase();
  if (['工作', 'work', '会议', '公司'].some((k) => cal.includes(k))) return 'lavender';
  if (['个人', '生活', '家', 'personal', 'home'].some((k) => cal.includes(k)) || ['跑', '健身', '攀岩', '运动', '骑'].some((k) => e.title.includes(k))) return 'mint';
  return e.value.source === 'google_calendar' ? 'lavender' : 'sky';
}
function glyph(e) {
  if (e.kind === 'reminder') return 'bell';
  if (e.kind === 'todo') return 'checklist';
  if (e.kind === 'decision') return e.pending && e.pending.kind === 'proposal' ? 'desktop' : 'hand';
  for (const [keys, ic] of [[['跑'], 'run'], [['攀岩'], 'climb'], [['骑', '摩旅'], 'bike'], [['健身', '运动'], 'dumbbell'], [['饭', '餐', '咖啡'], 'fork'], [['航班', '飞', '高铁'], 'plane'], [['电话', '通话'], 'phone'], [['会', '评审', '讨论', '访谈', '面试'], 'people']]) if (keys.some((k) => e.title.includes(k))) return ic;
  return 'calendar';
}
const range = (e) => clockTime(e.start) + (e.end > e.start ? '–' + clockTime(e.end) : '');
const byId = new Map();
const reg = (e) => { byId.set(e.id, e); return e.id; };

export function todaySummary() {
  if (!todayData()) return S.errors['/personal/today'] ? '今天的安排暂时没读到' : '正在看今天的安排…';
  const es = todayEntries();
  const events = es.filter((e) => e.kind === 'event' && !e.value.informational).length;
  const todos = es.filter((e) => (e.kind === 'reminder' && !e.done) || e.kind === 'todo' || e.kind === 'decision').length;
  if (!events && !todos) return '今天没有安排';
  return [events ? `${events} 个日程` : '', todos ? `${todos} 个待办` : ''].filter(Boolean).join(' · ');
}

// ─── 表盘（TodayDial）：半圈刻度 + 日程色带 + 黑弧走到现在 + 呼吸点；拖动读出那一刻 ───
const SPANS = { 眼前: { before: 3600, length: 4 * 3600, label: 1, minor: 900 }, 半天: { before: 3 * 3600, length: 12 * 3600, label: 3, minor: 3600 }, 全天: { before: 0, length: 24 * 3600, label: 6, minor: 3600 } };
let span = store.get('today.span', '眼前'), openedStack = [];
const HEX = { mint: ['--mint-f', '--mint-i'], lavender: ['--lav-f', '--lav-i'], butter: ['--but-f', '--but-i'], pink: ['--pink-f', '--pink-i'], sky: ['--sky-f', '--sky-i'] };
function dialSVG(timed, next, now, W) {
  const sp = SPANS[span] || SPANS['眼前'];
  const R = Math.min(W / 2 - 44, 150), cx = W / 2, cy = R + 30;
  const start = span === '全天' ? new Date(now * 1000).setHours(0, 0, 0, 0) / 1000 : now - sp.before;
  const f = (t) => (t - start) / sp.length, clamp = (x) => Math.min(1, Math.max(0, x));
  const pt = (r, x) => { const a = Math.PI + Math.PI * x; return [cx + Math.cos(a) * r, cy + Math.sin(a) * r]; };
  const arc = (r, a, b) => { const p0 = pt(r, a), p1 = pt(r, b); return `M${p0[0].toFixed(1)} ${p0[1].toFixed(1)} A${r} ${r} 0 0 1 ${p1[0].toFixed(1)} ${p1[1].toFixed(1)}`; };
  let s = `<path d="${arc(R - 30, 0, 1)} Z" class="dial-fill"/>`;
  for (const e of timed.filter((e) => e.end > start && e.start < start + sp.length)) {
    const a = clamp(f(e.start)), b = clamp(f(Math.max(e.end, e.start + 300))), h = hue(e);
    const op = e.end < now ? 0.22 : e.start <= now ? 0.9 : 0.55;
    s += `<path d="${arc(R - 20, a, Math.max(a + 0.004, b))}" class="band" style="stroke:var(${HEX[h][1]});opacity:${op}" pathLength="1"/>`;
  }
  const tz = -new Date().getTimezoneOffset() * 60;
  for (let t = Math.ceil(start / sp.minor) * sp.minor; t <= start + sp.length + 1; t += sp.minor) {
    const x = f(t), local = t + tz, major = local % 3600 === 0, lab = local % (sp.label * 3600) === 0;
    const p0 = pt(R - (lab ? 14 : major ? 11 : 8), x), p1 = pt(R - 4, x);
    s += `<line x1="${p0[0].toFixed(1)}" y1="${p0[1].toFixed(1)}" x2="${p1[0].toFixed(1)}" y2="${p1[1].toFixed(1)}" class="tick ${lab ? 'lab' : major ? 'maj' : ''}"/>`;
    if (lab && x > -0.001 && x < 1.001) { const q = pt(R + 21, x); s += `<text x="${q[0].toFixed(1)}" y="${(q[1] + 3.5).toFixed(1)}" class="tick-label">${clockTime(t)}</text>`; }
  }
  s += `<path d="${arc(R + 4, 0, Math.max(0.0001, clamp(f(now))))}" class="progress" pathLength="1"/>`;
  // 圆点：挤在一起的三个以上并成一摞
  const inWin = timed.filter((e) => e.start >= start && e.start <= start + sp.length).sort((a, b) => a.start - b.start);
  const arcLen = Math.PI * (R + 4), slots = [];
  let run = [];
  const sep = (a, b) => (a / 2 + b / 2 + 4) / arcLen;
  const flush = () => { if (run.length > 2) slots.push({ entries: run.map((r) => r.e), f: run[0].f, size: 40 }); else run.forEach((r) => slots.push({ entries: [r.e], f: r.f, size: r.size })); run = []; };
  for (const e of inWin) { const item = { e, f: f(e.start), size: next && e.id === next.id ? 28 : 22 }; const last = run[run.length - 1]; if (last && item.f - last.f >= sep(last.size, item.size)) flush(); run.push(item); }
  flush();
  for (let i = 1; i < slots.length; i++) { const need = slots[i - 1].f + sep(slots[i - 1].size, slots[i].size); if (slots[i].f < need) slots[i].f = need; }
  let marks = '';
  slots.forEach((sl, i) => {
    const [x, y] = pt(R + 4, clamp(sl.f));
    const e = sl.entries[0], h = hue(e), past = sl.entries.every((q) => isPast(q, now)), isNext = sl.entries.some((q) => next && q.id === next.id);
    const ids = sl.entries.map(reg).join(',');
    if (sl.entries.length > 1) {
      marks += `<button class="dial-mark stack ${past ? 'past' : ''} ${isNext ? 'next' : ''}" style="left:${x}px;top:${y}px;--d:${450 + i * 66}ms;--f:var(${HEX[h][0]});--k:var(${HEX[h][1]})" data-act="dial-stack" data-ids="${ids}" title="${sl.entries.length} 件挤在一起">${icon(glyph(e)).s}<b>${sl.entries.length}</b></button>`;
    } else {
      marks += `<button class="dial-mark ${past ? 'past' : ''} ${isNext ? 'next' : ''}" style="left:${x}px;top:${y}px;--d:${450 + i * 66}ms;--f:var(${HEX[h][0]});--k:var(${HEX[h][1]})" data-act="today-open" data-id="${ids}" title="${esc(clockTime(e.start) + ' ' + e.title)}">${icon(glyph(e)).s}</button>`;
    }
  });
  const [nx, ny] = pt(R + 4, clamp(f(now)));
  marks += `<i class="dial-now" style="left:${nx}px;top:${ny}px"></i>`;
  return { svg: s, marks, height: 196, geo: { cx, cy, R, start, length: sp.length } };
}

function nextUpCard(timed, events, now) {
  const next = events.find((e) => e.start > now) || timed.find((e) => e.start > now && !e.done) || null;
  const W = Math.min(640, (document.querySelector('#page-today .page')?.clientWidth || 600)) - 32;
  const d = dialSVG(events, next, now, W);
  const stack = openedStack.map((id) => byId.get(id)).filter(Boolean);
  if (next) reg(next);
  return html`<div class="card raised nextup rise" style="--d:120ms">
    <div class="seg end">${Object.keys(SPANS).map((k) => html`<button class="${k === span ? 'on' : ''}" data-act="dial-span" data-span="${k}">${k}</button>`)}</div>
    <div class="dial" style="height:${d.height}px" data-geo="${JSON.stringify(d.geo)}">
      <svg viewBox="0 0 ${W} ${d.height}" width="${W}" height="${d.height}">${raw(d.svg)}</svg>${raw(d.marks)}
      <div class="dial-center" ${next ? raw(`data-act="today-open" data-id="${next.id}"`) : ''}><small>${next ? '下一件' : '现在'}</small><b>${clockTime(next ? next.start : now)}</b>
        ${next ? html`<span class="countdown" data-until="${next.start}"></span>` : html`<span class="muted small">今天之后没有日程了</span>`}</div>
      <div class="dial-scrub hidden"></div>
    </div>
    ${stack.length ? html`<div class="stack-list"><small>这一段挤了 ${stack.length} 件</small>${stack.map((e, i) => html`<button class="stack-row ${isPast(e, now) ? 'past' : ''}" style="--i:${i}" data-act="today-open" data-id="${e.id}"><i class="hue ${hue(e)}">${icon(glyph(e))}</i><span class="mono">${range(e)}</span><b>${e.title}</b>${icon('right', 'chev')}</button>`)}</div>` : ''}
    ${next ? html`<button class="next-row" data-act="today-open" data-id="${next.id}"><i class="hue ${hue(next)} big">${icon(glyph(next))}</i><span class="grow"><b>${next.title}</b><small>${[range(next), next.value.location].filter(Boolean).join(' · ')}</small></span>${icon('right', 'chev')}</button>` : ''}
  </div>`;
}

// ─── 身体卡 ───
const METRICS = [
  ['sleep', '睡眠', 'h', 'lavender', true, (m) => (m.sleep_seconds == null ? null : m.sleep_seconds / 3600)],
  ['hrv', 'HRV', 'ms', 'mint', true, (m) => m.hrv_last_night ?? null], ['readiness', '准备度', '', 'sky', true, (m) => m.readiness_score ?? null],
  ['rhr', '静息心率', 'bpm', 'pink', false, (m) => m.resting_heart_rate ?? null], ['stress', '压力', '', 'butter', false, (m) => m.avg_stress ?? null],
  ['steps', '步数', '', 'mint', true, (m) => m.steps ?? null],
];
const batteryWord = (v) => (v >= 76 ? '精力充沛' : v >= 51 ? '还行' : v >= 26 ? '偏低' : '快没电了');
function spark(series) {
  if (series.length < 2) return '';
  const min = Math.min(...series), max = Math.max(...series), span0 = max - min || 1;
  const pts = series.map((v, i) => `${(i / (series.length - 1)) * 60},${18 - ((v - min) / span0) * 16}`).join(' ');
  return raw(`<svg class="spark" viewBox="0 0 60 20"><polyline points="${pts}"/></svg>`);
}
function bodyCard() {
  const h = (todayData() || {}).health || {};
  const m = (h.today || {}).measurements;
  if (h.today && m) {
    const bb = m.body_battery;
    const curve = (h.today.body_battery_curve || []);
    let curveSVG = '';
    if (curve.length > 2) {
      const t0 = curve[0][0], t1 = curve[curve.length - 1][0] || t0 + 1;
      const pts = curve.map(([t, v]) => `${(((t - t0) / (t1 - t0)) * 300).toFixed(1)},${(52 - (v / 100) * 50).toFixed(1)}`).join(' ');
      curveSVG = raw(`<svg class="bb-curve draw" viewBox="0 0 300 54" preserveAspectRatio="none"><polyline points="${pts}" pathLength="1"/></svg>`);
    }
    const parts = [m.body_battery_at_wake != null ? `起床时 ${Math.round(m.body_battery_at_wake)}` : '', m.body_battery_charged != null ? `充了 ${Math.round(m.body_battery_charged)}` : '', m.body_battery_drained != null ? `用了 ${Math.round(m.body_battery_drained)}` : ''].filter(Boolean).join(' · ');
    const sleep = m.sleep_seconds ? (() => {
      const segs = [['deep_seconds', '深睡', 'lav'], ['light_seconds', '浅睡', 'sky'], ['rem_seconds', 'REM', 'mint'], ['awake_seconds', '清醒', 'pink']].filter(([k]) => m[k] > 0);
      const tot = segs.reduce((n, [k]) => n + m[k], 0) || 1;
      return html`<div class="sleepbar"><div class="bar">${segs.map(([k, , c]) => raw(`<i class="${c}" style="width:${(m[k] / tot) * 100}%"></i>`))}</div>
        <small>${segs.map(([k, n]) => `${n} ${(m[k] / 3600).toFixed(1)}h`).join(' · ')}${m.sleep_score != null ? ` · 睡眠分 ${Math.round(m.sleep_score)}` : ''}</small></div>`;
    })() : '';
    const days = h.days || [];
    return html`<button class="card body-card rise" style="--d:160ms" data-act="open-health">
      <div class="row"><div class="ring" style="--v:${bb == null ? 0 : bb}"><b>${bb == null ? '—' : html`<span data-count="${Math.round(bb)}">${Math.round(bb)}</span>`}</b></div>
        <div class="grow"><small class="muted">身体电量</small>${bb != null ? html`<h3>${batteryWord(bb)}</h3>` : ''}<small class="faint">${parts}</small></div></div>
      ${curveSVG}${sleep}
      <div class="tiles">${METRICS.filter((x) => x[5](m) != null).map(([id, title, unit, hu, , get], i) => {
        const v = get(m); const series = days.map((d) => get(d.measurements || {})).filter((x) => x != null);
        return html`<div class="tile ${hu}" style="--d:${450 + i * 50}ms"><small>${title}</small><b>${id === 'sleep' ? v.toFixed(1) : Math.round(v).toLocaleString()}<em>${unit}</em></b>${spark(series)}</div>`;
      })}</div></button>`;
  }
  if (h.phone) {
    const p = h.phone;
    return html`<div class="card rise" style="--d:160ms"><small class="label">手机健康 · 最近 7 天</small><div class="tiles">${[['步数', 'steps', ''], ['睡眠', 'sleep_hours', 'h'], ['静息心率', 'resting_heart_rate', 'bpm']].map(([t, k, u]) => html`<div class="tile"><small>${t}</small><b>${p[k] == null ? '—' : k === 'sleep_hours' ? Number(p[k]).toFixed(1) : Math.round(p[k])}<em>${u}</em></b></div>`)}</div><small class="faint">今天还没有 Garmin 数据，先看手机健康。</small></div>`;
  }
  const g = (h.sources || {}).garmin || {};
  return html`<div class="card row rise" style="--d:160ms"><i class="hue pink big">${icon('heart')}</i><span class="grow"><b>身体状态还没同步</b><small class="faint">${g.error ? 'Garmin：' + g.error : 'Garmin 每半小时同步一次'}</small></span></div>`;
}

// ─── 待办 | 等你决定 ───
function todoCard(todos) {
  return html`<div class="card raised todo-card rise" style="--d:200ms">
    <div class="row between"><h3>待办</h3><small class="faint mono">${todos.length}</small></div>
    ${todos.length ? '' : html`<small class="faint">没有要办的</small>`}
    <div class="todo-rows">${todos.slice(0, 4).map((e, i) => html`<div class="todo-row" style="--i:${i}" data-row="${reg(e)}">
      <button class="check ${e.overdue ? 'warn' : ''} hue-${hue(e)}" data-act="today-check" data-id="${e.id}" aria-label="完成：${e.title}"><i></i>${raw('<svg viewBox="0 0 10 8"><path d="M1 4.2 3.8 7 9 1"/></svg>')}</button>
      <button class="todo-text" data-act="today-open" data-id="${e.id}"><b>${e.title}</b><small class="${e.overdue ? 'warn-text' : ''}">${e.overdue ? '过期' : e.start > 0 ? clockTime(e.start) : e.kind === 'todo' ? '行动台' : '提醒'}</small></button>
      <button class="mini-act" data-act="today-postpone" data-id="${e.id}" title="${e.kind === 'todo' ? '改到明天' : '晚 1 小时'}">${icon('repeat')}</button>
    </div>`)}</div>
    ${todos.length > 4 ? html`<button class="link accent-text" data-act="today-all-todos">全部 ${todos.length} 件</button>` : ''}
  </div>`;
}
function decisionCard(decisions) {
  const first = decisions[0];
  const h = first ? 'butter' : 'mint';
  if (first) reg(first);
  return html`<button class="card decision ${h} rise" style="--d:200ms" data-act="${first ? 'today-open' : 'open-taskhub'}" data-id="${first ? first.id : ''}">
    <div class="row"><i class="dot-ic">${icon(first ? 'hand' : 'check')}</i><h3>${first ? '等你决定' : '都拍板了'}</h3></div><span class="grow"></span>
    <b class="huge" data-count="${decisions.length}">${decisions.length}</b>
    <span class="t">${first ? first.title : '没有要你拍板的事'}</span>
    ${decisions.length > 1 ? html`<small>还有 ${decisions.length - 1} 件 · 在任务与目标里</small>` : ''}</button>`;
}
function wechatCard(card) {
  const chats = card.chats || [];
  return html`<button class="card wechat mint rise" style="--d:280ms" data-act="open-wechat">
    <div class="row"><i class="dot-ic">${icon('message')}</i><h3>微信</h3><span class="grow"></span><small>${card.subtitle || ''}</small></div>
    ${chats.slice(0, 3).map((c) => html`<div class="wx"><div class="row">${c.mention ? html`<em class="at">@我</em>` : ''}<b>${c.name}</b><span class="grow"></span><small>${c.sender || ''}</small></div><p>${c.summary || ''}</p></div>`)}
    ${chats.length > 3 ? html`<small><b>还有 ${chats.length - 3} 个聊天</b></small>` : ''}</button>`;
}

// ─── 横向时间轴 ───
function timeline(entries, allDay, now) {
  const HW = 112, MIN = 124, LANE = 108, COMPACT = 62, RULER = 30, GAP = 10, PAD = 4;
  const dayStart = new Date(now * 1000).setHours(0, 0, 0, 0) / 1000;
  const starts = entries.map((e) => e.start).concat(now), ends = entries.map((e) => Math.max(e.end, e.start + 1800)).concat(now);
  let lo = Math.max(0, Math.floor((Math.min(...starts) - dayStart) / 3600)), hi = Math.min(24, Math.max(Math.ceil((Math.max(...ends) - dayStart) / 3600), lo + 6));
  const x = (t) => PAD + ((t - dayStart) / 3600 - lo) * HW;
  const ordered = [...entries].sort((a, b) => a.start - b.start || (b.end - b.start) - (a.end - a.start));
  const laneEnds = [], slots = [];
  for (const e of ordered) {
    const left = x(e.start), w = Math.max(MIN, e.end > e.start ? ((e.end - e.start) / 3600) * HW - 6 : 0);
    let lane = laneEnds.findIndex((r) => r + 8 <= left); if (lane < 0) { lane = laneEnds.length; laneEnds.push(0); }
    laneEnds[lane] = left + w; slots.push({ e, left, w, lane });
  }
  const lanes = Math.max(1, laneEnds.length), compact = lanes >= 4, ch = compact ? COMPACT : LANE;
  const width = Math.max(x(dayStart + hi * 3600), ...slots.map((s) => s.left + s.w)) + PAD, height = RULER + lanes * (ch + GAP);
  const nowX = x(now);
  let hours = '';
  for (let hh = lo; hh <= hi; hh++) { const hx = x(dayStart + hh * 3600); const hide = hx + 36 > nowX - 44 && hx < nowX + 44; hours += `<div class="tl-hour" style="left:${hx}px;height:${height}px"><span style="opacity:${hide ? 0 : 1}">${String(hh).padStart(2, '0')}:00</span><i></i></div>`; }
  return html`<section class="group rise" style="--d:300ms"><div class="group-head"><h3>时间线</h3><button class="link accent-text" data-act="tl-now">${icon('scope')}现在</button></div>
    ${allDay.length ? html`<div class="allday"><span class="tag">全天</span>${allDay.map((e) => html`<button class="pill ${hue(e)} ${e.value.informational ? 'info' : ''}" data-act="today-open" data-id="${reg(e)}"><i>${icon(glyph(e))}</i>${e.title}</button>`)}</div>` : ''}
    <div class="tl-scroll" id="tlScroll" data-now="${nowX}"><div class="tl" style="width:${width}px;height:${height}px">${raw(hours)}
      ${slots.map((s, i) => { const e = s.e, h = hue(e), past = isPast(e, now); const place = e.kind === 'event' ? e.value.location : e.kind === 'reminder' ? '提醒' : '';
        return html`<button class="tl-card ${h} ${compact ? 'compact' : ''} ${past ? 'past' : ''} ${e.done ? 'done' : ''}" style="left:${s.left}px;top:${RULER + s.lane * (ch + GAP)}px;width:${s.w}px;height:${ch}px;--d:${350 + i * 50}ms" data-act="today-open" data-id="${reg(e)}">
          ${compact ? html`<span class="row"><i class="mini">${icon(glyph(e))}</i><b>${e.title}</b></span><em>${range(e)}</em>`
            : html`<span class="row between"><i class="mini">${icon(glyph(e))}</i><i class="o ${past || e.done ? 'f' : ''}"></i></span><b>${e.title}</b><span class="grow"></span><span class="when"><i class="bar"></i><span><em>${range(e)}</em>${place ? html`<small>${place}</small>` : ''}</span></span>`}</button>`; })}
      <div class="tl-now" style="left:${nowX - 1}px;height:${height}px"><span>现在 ${clockTime(now)}</span><i></i></div></div></div>
    ${entries.length ? '' : html`<small class="faint">今天没有定时的安排</small>`}</section>`;
}

// ─── 页面 ───
export function renderToday(root) {
  byId.clear();
  const now = Date.now() / 1000;
  const es = todayEntries();
  const timed = es.filter((e) => e.start > 0).sort((a, b) => a.start - b.start);
  const events = timed.filter((e) => e.kind === 'event' && !e.value.informational);
  const todos = es.filter((e) => (e.kind === 'reminder' || e.kind === 'todo') && !e.done).sort((a, b) => (a.overdue ? 0 : 1) - (b.overdue ? 0 : 1) || (a.start || 1e12) - (b.start || 1e12));
  const decisions = es.filter((e) => e.kind === 'decision');
  const upcoming = events.filter((e) => e.start > now);
  const d = new Date();
  const nd = nextData(), running = !!nd.running, headline = nd.headline || '';
  const tl = root.querySelector('#tlScroll'), tlLeft = tl ? tl.scrollLeft : null;
  const errs = Object.keys((todayData() || {}).errors || {});
  root.innerHTML = html`<div class="page today">
    <div class="today-head"><div><h1 class="beam">${d.getMonth() + 1}月${d.getDate()}日</h1><h2 class="beam" style="--d:60ms">${todaySummary()}</h2></div><span class="weekday">${WEEK[d.getDay()]}</span></div>
    ${upcoming.length ? html`<div class="upcoming">${upcoming.slice(0, 5).map((e, i) => html`<button class="hue ${hue(e)} xl stamp-in" style="--d:${100 + i * 66}ms" data-act="today-open" data-id="${reg(e)}" title="${clockTime(e.start)} ${e.title}">${icon(glyph(e))}</button>`)}${upcoming.length > 5 ? html`<span class="hue xl more">+${upcoming.length - 5}</span>` : ''}</div>` : ''}
    ${S.errors['/personal/today'] && !todayData() ? html`<div class="notice danger">${icon('warning')}<span>今天的安排读取失败：${S.errors['/personal/today']}</span><button class="link" data-act="today-retry">重试</button></div>` : ''}
    <div class="card brief rise" style="--d:80ms"><i class="spark-ic">${icon('sparkles')}</i><div class="grow"><p class="${running ? 'dim' : ''}">${headline || (running ? '正在看今天…' : '今天还没整理')}</p>
      <small class="faint">${running ? '重新整理中' : nd.updated_at > 0 ? '整理于 ' + relativeTime(nd.updated_at) : '从日程、身体、邮件和微信里看'}</small></div>
      <button class="round fill small ${running ? 'spinning' : ''}" data-act="next-refresh" ${running ? raw('disabled') : ''} aria-label="重新整理今天">${icon('refresh')}</button></div>
    ${nextUpCard(timed, events, now)}
    ${todayCasesStrip()}
    ${bodyCard()}
    <div class="duo">${todoCard(todos)}${decisionCard(decisions)}</div>
    <div class="quick-add rise" style="--d:240ms"><form class="qa" id="quickAdd">${icon('plus')}<input id="quickInput" placeholder="记一件事，或让 Com 去办…" autocomplete="off"><button class="round ink small hidden" id="quickSend" aria-label="交给 Com">${icon('arrowUp')}</button></form><p class="qa-sent" id="qaSent"></p></div>
    ${(todayData() || {}).wechat ? wechatCard(todayData().wechat) : ''}
    ${timeline(timed, es.filter((e) => e.kind === 'event' && e.start === 0), now)}
    ${errs.length ? html`<div class="notice neutral">${icon('warning')}<span>有来源没读到：${errs.map((k) => ({ events: '日程', reminders: '提醒', todos: '行动台', wechat: '微信' })[k] || k).join('、')}</span></div>` : ''}
    <button class="hub-link rise" style="--d:340ms" data-act="open-taskhub">${icon('layers')}<span class="grow"><b>任务与目标</b><small>${['在跑 ' + runningTasks().length, '等你 ' + decisionCount(), staleItems().length ? '旧任务 ' + staleItems().length : ''].filter(Boolean).join(' · ')}</small></span>${icon('right', 'chev')}</button>
  </div>`.s;
  countUp(root);
  const qa = $('#quickAdd'), qi = $('#quickInput');
  qi.addEventListener('input', () => $('#quickSend').classList.toggle('hidden', !qi.value.trim()));
  qa.addEventListener('submit', async (e) => {
    e.preventDefault(); const v = qi.value.trim(); if (!v) return;
    qi.value = ''; $('#quickSend').classList.add('hidden'); qa.classList.add('pulse');
    setTimeout(() => qa.classList.remove('pulse'), 160);
    const sent = $('#qaSent'); sent.innerHTML = html`${icon('checkCircle')}已交给 Com：${v}`.s; sent.classList.add('on');
    await send({ textOverride: v });
    setTimeout(() => sent.classList.remove('on'), 5000);
  });
  const sc = $('#tlScroll');
  if (sc) { if (tlLeft != null) sc.scrollLeft = tlLeft; else sc.scrollLeft = Math.max(0, Number(sc.dataset.now) - sc.clientWidth / 3); }
  bindDial(root, events);
  tickCountdown();
}
function tickCountdown() {
  for (const el of document.querySelectorAll('.countdown[data-until]')) {
    const s = Math.max(0, Math.floor(Number(el.dataset.until) - Date.now() / 1000));
    el.textContent = `还有 ${String(Math.floor(s / 3600)).padStart(2, '0')}:${String(Math.floor((s % 3600) / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
  }
}
setInterval(tickCountdown, 1000);
function bindDial(root, events) {
  const dial = root.querySelector('.dial'); if (!dial) return;
  const g = JSON.parse(dial.dataset.geo), scrub = dial.querySelector('.dial-scrub');
  const show = (ev) => {
    const r = dial.getBoundingClientRect(), x = ev.clientX - r.left, y = ev.clientY - r.top;
    let a = Math.atan2(y - g.cy, x - g.cx); if (a > 0) a = x < g.cx ? -Math.PI : 0;
    const f = Math.min(1, Math.max(0, (a + Math.PI) / Math.PI));
    const t = g.start + f * g.length, hit = events.find((e) => e.start <= t && t < Math.max(e.end, e.start + 300));
    const ang = Math.PI + Math.PI * f, px = g.cx + Math.cos(ang) * (g.R + 4), py = g.cy + Math.sin(ang) * (g.R + 4);
    scrub.classList.remove('hidden');
    scrub.innerHTML = html`<i class="dot" style="left:${px}px;top:${py}px"></i><span class="cap" style="left:${px}px;top:${Math.max(18, py - 34)}px"><b>${clockTime(t)}</b><small>${hit ? hit.title : '空闲'}</small></span>`.s;
  };
  dial.addEventListener('pointermove', (e) => { if (e.target.closest('.dial-mark,.dial-center')) { scrub.classList.add('hidden'); return; } show(e); });
  dial.addEventListener('pointerleave', () => scrub.classList.add('hidden'));
}

// ─── 动作 ───
act('dial-span', (b) => { span = b.dataset.span; openedStack = []; store.set('today.span', span); renderTodayIfShown(); });
act('dial-stack', (b) => { const ids = b.dataset.ids.split(','); openedStack = openedStack.join() === ids.join() ? [] : ids; renderTodayIfShown(); });
act('tl-now', () => { const sc = $('#tlScroll'); if (sc) sc.scrollTo({ left: Math.max(0, Number(sc.dataset.now) - sc.clientWidth / 3), behavior: 'smooth' }); });
act('today-retry', () => load('/personal/today', { timeout: 60000 }));
act('today-open', (b) => { const e = byId.get(b.dataset.id); if (e) openSheet(todayDetail(e)); });
act('today-all-todos', () => {
  const todos = todayEntries().filter((e) => (e.kind === 'reminder' || e.kind === 'todo') && !e.done);
  openSheet({ title: '今天的待办', render: () => html`<div class="list">${todos.map((e) => html`<button class="list-row" data-act="today-open" data-id="${reg(e)}">${icon(glyph(e))}<span><b>${e.title}</b><small class="${e.overdue ? 'warn-text' : ''}">${e.overdue ? '过期' : e.start > 0 ? clockTime(e.start) : e.subtitle}</small></span>${icon('right', 'chev')}</button>`)}</div>` });
});
act('open-wechat', () => {
  const card = (todayData() || {}).wechat || {};
  openSheet({ title: card.title || '微信', render: () => html`${(card.chats || []).map((c) => html`<div class="wx-chat"><div class="row"><span class="tag">${c.is_group ? (c.mention ? '@我' : '群聊') : '私聊'}</span><b>${c.name}</b></div>
    ${(c.keywords || []).filter(Boolean).length ? html`<small class="faint">${c.keywords.filter(Boolean).join(' · ')}</small>` : ''}
    <div class="list">${(c.messages || []).map((m) => html`<div class="wx-line"><span>${m.sender}</span><p>${m.text}</p><em>${clockTime(m.at)}</em></div>`)}</div></div>`)}` });
});

// 打勾：圆点填满 + 勾 → 划线 → 停一拍收起 → 底部 4 秒撤销（提醒在撤销窗口过后才写回）
let check = null, checkTimer = 0;
act('today-check', (b) => {
  const e = byId.get(b.dataset.id); if (!e) return;
  const row = b.closest('.todo-row'); row.classList.add('checked'); b.disabled = true;
  setTimeout(() => { row.classList.add('collapse'); setTimeout(() => complete(e), 300); }, matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : 560);
});
function complete(e) {
  settle();
  const key = e.kind === 'todo' ? 'todos' : 'reminders';
  const data = { ...(todayData() || {}) }, rows = [...(data[key] || [])], index = rows.findIndex((r) => r.id === e.value.id);
  if (index < 0) return;
  settling.add(e.id);
  if (e.kind === 'todo') rows.splice(index, 1); else rows[index] = { ...rows[index], status: 'done' };
  data[key] = rows; S.data['/personal/today'] = data;
  check = { entry: e, index, write: null };
  if (e.kind === 'todo') check.write = mutate('/personal/today/todos/done', { path: e.value.path }).then((r) => r && r.undo).catch(() => { load('/personal/today'); return null; }).finally(() => settling.delete(e.id));
  showUndo(e.title);
  renderTodayIfShown();
  checkTimer = setTimeout(settle, 4000);
}
function showUndo(title) {
  const t = $('#undoToast'); if (!t) return;
  t.innerHTML = html`<i class="ok">${icon('check')}</i><span>已完成 · ${title}</span><button data-act="today-undo">撤销</button>`.s;
  t.classList.add('on');
}
async function settle() {
  clearTimeout(checkTimer);
  const c = check; check = null; $('#undoToast')?.classList.remove('on');
  if (!c || c.entry.kind !== 'reminder') return;
  try { await mutate('/personal/reminders/' + encodeURIComponent(c.entry.value.id) + '/action', { action: 'confirm', expected: { due: c.entry.value.due, status: c.entry.value.status } }); } catch { /* toast */ }
  settling.delete(c.entry.id); load('/personal/today');
}
act('today-undo', async () => {
  clearTimeout(checkTimer);
  const c = check; check = null; $('#undoToast')?.classList.remove('on'); if (!c) return;
  const e = c.entry, key = e.kind === 'todo' ? 'todos' : 'reminders';
  settling.delete(e.id);
  const data = { ...(todayData() || {}) }, rows = [...(data[key] || [])];
  const i = rows.findIndex((r) => r.id === e.value.id);
  if (i >= 0) rows[i] = e.value; else rows.splice(Math.min(c.index, rows.length), 0, e.value);
  data[key] = rows; S.data['/personal/today'] = data; renderTodayIfShown();
  if (c.write) { const undo = await c.write; if (undo) { try { await mutate('/personal/today/todos/undo', { path: e.value.path, undo }); } catch { load('/personal/today'); } } }
});
act('today-postpone', async (b) => {
  const e = byId.get(b.dataset.id); if (!e) return;
  if (e.kind === 'reminder') return reminderAction(e.value, 'snooze60');
  const data = { ...(todayData() || {}) }; data.todos = (data.todos || []).filter((t) => t.id !== e.value.id); S.data['/personal/today'] = data; renderTodayIfShown();
  try { await mutate('/personal/today/todos/postpone', { path: e.value.path }); toast('已改到明天'); } catch { load('/personal/today'); }
});
async function reminderAction(r, a) {
  try { await mutate('/personal/reminders/' + encodeURIComponent(r.id) + '/action', { action: a, expected: { due: r.due, status: r.status } }); await load('/personal/today'); toast({ confirm: '已完成', snooze10: '晚 10 分钟再提醒', snooze60: '晚 1 小时再提醒', cancel: '已取消这条提醒' }[a] || '好了'); } catch { /* toast */ }
}

// ─── 详情（TodayDetail） ───
function todayDetail(e) {
  const v = e.value;
  const title = { event: '日程', reminder: '提醒', todo: '待办', decision: '等你决定' }[e.kind];
  return {
    title,
    render: () => {
      if (e.kind === 'event') {
        const allDay = !!v.all_day;
        const t = new Date((v.start || 0) * 1000);
        return html`<div class="detail-head"><h2>${e.title}</h2><p>${allDay ? '全天' : clockTime(v.start) + (v.end > v.start ? ' – ' + clockTime(v.end) : '')}</p>${stamp(sourceName(v.source))}</div>
          <div class="card list">${kv('地点', v.location)}${kv('日历', v.calendar)}${kv('日期', `${t.getMonth() + 1}月${t.getDate()}日 ${WEEK[t.getDay()].replace('星期', '周')}`)}</div>
          ${v.notes ? html`<div class="card md">${raw(String(v.notes).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c]).replace(/\n/g, '<br>'))}</div>` : ''}
          <button class="btn primary full" data-act="hand-to-com" data-text="${`帮我准备今天的「${e.title}」（${allDay ? '全天' : clockTime(v.start)}${v.location ? '，' + v.location : ''}）：列出要带的材料、要确认的问题，有相关邮件就一起看。`}">交给 Com 准备</button>
          ${v.link ? html`<a class="btn quiet full" href="${v.link}" target="_blank" rel="noopener">在日历里打开</a>` : ''}`;
      }
      if (e.kind === 'reminder') {
        const pending = v.status === 'pending';
        return html`<div class="detail-head"><h2>${e.title}</h2><p>${v.due || ''}${v.repeat && v.repeat !== 'once' ? ' · 重复' : ''}</p>${stamp(v.overdue ? '过期没处理' : pending ? '待提醒' : '已完成', v.overdue ? 'warning' : pending ? 'neutral' : 'success')}</div>
          ${pending ? html`<div class="stack"><button class="btn primary full" data-act="rem-act" data-a="confirm" data-id="${v.id}">完成了</button>
            <div class="row"><button class="btn secondary grow" data-act="rem-act" data-a="snooze10" data-id="${v.id}">晚 10 分钟</button><button class="btn secondary grow" data-act="rem-act" data-a="snooze60" data-id="${v.id}">晚 1 小时</button></div>
            <button class="btn quiet danger-text" data-act="rem-act" data-a="cancel" data-id="${v.id}">取消这条提醒</button></div>` : ''}
          <p class="faint small">来自 Pi 网关的提醒记录，改动会直接写回那里。</p>`;
      }
      if (e.kind === 'todo') {
        return html`<div class="detail-head"><h2>${e.title}</h2><p>${[v.start ? '开始 ' + v.start : '', v.due ? '截止 ' + v.due : ''].filter(Boolean).join(' · ')}</p>${v.overdue ? stamp('已过期', 'warning') : stamp('今天')}</div>
          ${v.path ? threadStrip('todo:' + v.path) : ''}
          ${v.next_step ? html`<div class="card"><small class="label">下一步</small><p class="lined">${v.next_step}</p></div>` : ''}
          <div class="card list">${kv('项目', v.project)}${kv('备注', v.note)}${kv('来源', 'Obsidian 行动台')}</div>
          <button class="btn primary full" data-act="todo-delegate" data-path="${v.path || ''}">交给 Com（开一个案例）</button>
          <p class="mono faint small">${v.path || ''}</p>`;
      }
      const cur = flowItems.find((i) => e.pending && i.id === e.pending.id);
      return cur ? pendingNoteHTML(cur) : empty('这件事已经处理了', '', 'checkCircle');
    },
  };
}
act('rem-act', async (b) => {
  const r = ((todayData() || {}).reminders || []).find((x) => x.id === b.dataset.id); if (!r) return;
  b.disabled = true; await reminderAction(r, b.dataset.a);
  import('./ui.js').then((m) => m.closeSheets());
});
act('hand-to-com', async (b) => { b.disabled = true; await send({ textOverride: b.dataset.text }); import('./ui.js').then((m) => m.closeSheets()); setTab('chat'); });

let renderHook = () => {};
export const setTodayRender = (fn) => { renderHook = fn; };
function renderTodayIfShown() { renderHook(); }
onChange(() => {});
export { sleep };
