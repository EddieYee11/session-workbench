// 「今天」：日程、提醒、行动台待办和等你拍板的事排成一条时间线（iOS TodayView.swift + BodyViews.swift）。
import {
  S, $, html, raw, esc, D, nextData, flowItems, clockTime, relativeTime, sourceName, WEEK, mutate, load, send, setTab, runningTasks, decisionCount, staleItems,
  refreshNext, store, toast, sleep, onChange,
} from './core.js';
import { icon, act, stamp, empty, openSheet, pushSheet, kv, section, countUp } from './ui.js';
import { pendingNoteHTML } from './sheets.js';
import { threadStrip } from './cases.js';

// ─── 条目（TodayEntry） ───
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
    const done = r.status === 'done';
    if (done && (r.at || 0) < dayStart) continue;
    const overdue = !!r.overdue && !done;
    out.push({ id: 'reminder:' + r.id, kind: 'reminder', title: r.title || '', subtitle: overdue ? '过期没处理 · ' + (r.due || '') : done ? '已完成' : '提醒', start: overdue ? 0 : r.at || 0, end: 0, overdue, done, value: r });
  }
  for (const t of d.todos || []) {
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
  const events = todayEntries().filter((e) => e.kind === 'event' && !e.value.informational).length;
  return events ? `${events} 个日程` : '今天没有日程';
}

const WEEK_ZH = ['日', '一', '二', '三', '四', '五', '六'];
/** 本周七天（周一起），今天高亮；后端只给今天的数据，所以其它天不能点（iOS WeekStrip）。 */
function weekStrip(now) {
  const t = new Date(now * 1000), mon = new Date(t); mon.setDate(t.getDate() - ((t.getDay() + 6) % 7));
  return html`<div class="week-strip rise" style="--d:60ms">${[0, 1, 2, 3, 4, 5, 6].map((i) => { const d = new Date(mon); d.setDate(mon.getDate() + i); const on = d.toDateString() === t.toDateString();
    return html`<div class="wk ${on ? 'on' : ''}" ${on ? raw('aria-current="date"') : ''}><small>周${WEEK_ZH[d.getDay()]}</small><b>${d.getDate()}</b></div>`; })}</div>`;
}
/** 左边时刻、右边色条卡；「现在」插在最近一件未开始的日程前面，全天的排最前（iOS ScheduleTimeline）。 */
function scheduleTimeline(rows, now) {
  if (!rows.length) return html`<div class="card sched-empty rise" style="--d:120ms">今天没有日程</div>`;
  const nowIndex = rows.findIndex((e) => e.start > now) >= 0 ? rows.findIndex((e) => e.start > now) : (rows.some((e) => e.start > 0) ? rows.length : -1);
  const marker = html`<div class="sched-now"><span>现在 ${clockTime(now)}</span><i></i></div>`;
  return html`<div class="sched rise" style="--d:120ms">${rows.map((e, i) => html`${i === nowIndex ? marker : ''}<div class="sched-row"><time>${e.start > 0 ? clockTime(e.start) : '全天'}</time>
    <button class="sched-card hue-edge ${hue(e)} ${isPast(e, now) ? 'past' : ''}" data-act="today-open" data-id="${reg(e)}"><i class="hue ${hue(e)} big">${icon(glyph(e))}</i>
      <span class="grow"><b class="${e.done ? 'done' : ''}">${e.title}</b>${(e.kind === 'reminder' ? '提醒' : [e.value.calendar, e.value.location].filter(Boolean).join(' · ')) ? html`<small>${e.kind === 'reminder' ? '提醒' : [e.value.calendar, e.value.location].filter(Boolean).join(' · ')}</small>` : ''}
        ${e.start > 0 ? html`<small class="faint">${icon('clock')} ${range(e)}</small>` : ''}</span></button></div>`)}${nowIndex === rows.length ? marker : ''}</div>`;
}
/** 「下一步」整理时顺手写的、关于日程松紧和安排的几条建议（简报里 kind = event 的要点）。 */
function scheduleAdvice() {
  const nd = nextData(), running = !!nd.running, tips = (nd.brief || []).filter((b) => b.kind === 'event' && b.text);
  return html`<section class="group rise" style="--d:180ms"><div class="group-head"><h3>日程建议</h3>
    <button class="round fill small ${running ? 'spinning' : ''}" data-act="next-refresh" ${running ? raw('disabled') : ''} aria-label="重新整理日程建议">${icon('refresh')}</button></div>
    ${tips.length ? tips.map((t) => html`<div class="card advice"><i class="hue butter big">${icon('sparkles')}</i><p>${t.text}</p></div>`) : html`<div class="card sched-empty">${running ? '正在看今天的安排…' : '还没有日程建议，点右上角让 Com 看一眼今天。'}</div>`}</section>`;
}

export function renderToday(root) {
  byId.clear();
  const now = Date.now() / 1000, d = new Date();
  const rows = todayEntries().filter((e) => (e.kind === 'event' && !e.value.informational) || (e.kind === 'reminder' && e.start > 0))
    .sort((a, b) => a.start - b.start || a.title.localeCompare(b.title));
  const allDay = todayEntries().filter((e) => e.kind === 'event' && !e.value.informational && e.start === 0);
  const timed = [...allDay, ...rows.filter((e) => e.start > 0)];
  const errs = Object.keys((todayData() || {}).errors || {}).filter((k) => k === 'events' || k === 'reminders');
  root.innerHTML = html`<div class="page today">
    <div class="today-head"><div><h1 class="beam">${d.getFullYear()}年${d.getMonth() + 1}月</h1><h2 class="beam" style="--d:60ms">${todaySummary()}</h2></div>
      <button class="round fill" data-act="open-taskhub" aria-label="任务与目标">${icon('layers')}${decisionCount() ? html`<em class="badge-count">${decisionCount()}</em>` : ''}</button></div>
    ${S.errors['/personal/today'] && !todayData() ? html`<div class="notice danger">${icon('warning')}<span>今天的安排读取失败：${S.errors['/personal/today']}</span><button class="link" data-act="today-retry">重试</button></div>` : ''}
    ${weekStrip(now)}
    ${scheduleTimeline(timed, now)}
    ${scheduleAdvice()}
    ${errs.length ? html`<div class="notice neutral">${icon('warning')}<span>有来源没读到：${errs.map((k) => ({ events: '日程', reminders: '提醒' })[k]).join('、')}</span></div>` : ''}
  </div>`.s;
}

// ─── 动作 ───
act('today-retry', () => load('/personal/today', { timeout: 60000 }));
act('today-open', (b) => { const e = byId.get(b.dataset.id); if (e) openSheet(todayDetail(e)); });
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
          <button class="btn primary full" data-act="todo-delegate" data-path="${v.path || ''}">交给 Com（开一段航程）</button>
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
onChange(() => {});
export { sleep };
