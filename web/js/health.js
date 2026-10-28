// 「健康」Tab：与 iOS HealthView.swift 同一结构——恢复环 + 四个维度小环 → 建议卡堆 → 六格指标 → 最近活动。
// 数据：/personal/health?days=30（Garmin 每天一条）、/personal/health/insight（模型评估，恢复分是 Garmin 准备度）。
import { S, html, raw, D, load, clockTime, relativeTime, onChange } from './core.js';
import { icon, act, stamp, empty, notice, section, openSheet, countUp } from './ui.js';

const HEALTH = '/personal/health?days=30';
const INSIGHT = '/personal/health/insight';
const LEVEL = { good: { label: '好', ink: '#2F8F5B', wash: '#E6F3EA' }, fair: { label: '一般', ink: '#85662A', wash: '#F7EEDF' }, low: { label: '偏低', ink: '#BD493E', wash: '#F8E6E3' } };
const DIM = { recovery: ['恢复', 'heart'], sleep: ['睡眠', 'moon'], stress: ['压力', 'gauge'], load: ['负荷', 'run'] };
const pct = (x) => Math.max(0, Math.min(1, x));

function days() { return (D(HEALTH) || {}).days || []; }
function today() { const d = D(HEALTH) || {}; return d.today || days().at(-1) || {}; }
function m() { return today().measurements || {}; }

// 恢复分环（准备度）：大环 + 一句话，和 iOS HealthHero 一致
function heroRing(insight, mm) {
  const score = Number(insight.score ?? mm.readiness_score ?? 0);
  const has = insight.score != null || mm.readiness_score != null;
  const c = 2 * Math.PI * 52, dash = has ? c * pct(score / 100) : 0;
  return html`<div class="health-hero rise">
    <div class="hero-ring"><svg viewBox="0 0 120 120"><circle cx="60" cy="60" r="52" class="ring-track"/><circle cx="60" cy="60" r="52" class="ring-fill" style="stroke-dasharray:${dash} ${c}"/></svg>
      <div class="hero-num"><b class="mono">${has ? Math.round(score) : '—'}</b><small>恢复</small></div></div>
    <div class="hero-text"><b>${insight.headline || (has ? '今天的身体数据已读到' : '还没有今天的 Garmin 数据')}</b>
      ${insight.summary ? html`<p>${insight.summary}</p>` : ''}
      ${insight.running ? html`<small class="faint">正在重新评估…</small>` : insight.updated_at ? html`<small class="faint">评估于 ${relativeTime(insight.updated_at)}</small>` : ''}</div>
  </div>`;
}

// 四个维度小环：颜色 = 好 / 一般 / 偏低；点开看说明（iOS 是冒一个气泡）
function dimensionRow(insight) {
  const dims = insight.dimensions || [];
  if (!dims.length) return '';
  return html`<div class="dim-row rise" style="--d:80ms">${dims.map((d) => {
    const [name, ic] = DIM[d.key] || [d.key, 'sparkles'];
    const lv = LEVEL[d.level] || LEVEL.fair, fill = d.level === 'good' ? 1 : d.level === 'low' ? 0.34 : 0.67;
    const c = 2 * Math.PI * 22;
    return html`<button class="dim" data-act="health-dim" data-key="${d.key}" title="${d.note || name}">
      <svg viewBox="0 0 56 56"><circle cx="28" cy="28" r="22" class="ring-track"/><circle cx="28" cy="28" r="22" class="ring-fill" style="stroke:${lv.ink};stroke-dasharray:${c * fill} ${c}"/></svg>
      <i style="color:${lv.ink}">${icon(ic)}</i><small>${name}</small><em style="color:${lv.ink}">${lv.label}</em></button>`;
  })}</div>`;
}

// 建议卡堆（iOS ActionStack）
function actionStack(insight) {
  const acts = insight.actions || [];
  if (!acts.length) return '';
  return section('今天可以这样做', html`<div class="stack">${acts.slice(0, 3).map((a, i) => html`<div class="card action rise" style="--d:${120 + i * 50}ms">
    <div class="row between"><b>${a.title || a.text}</b>${a.done ? stamp('已做', 'success') : ''}</div>
    ${a.detail || a.why ? html`<p class="sub">${a.detail || a.why}</p>` : ''}
    ${a.note ? html`<small class="faint">${a.note}</small>` : ''}</div>`)}</div>`);
}

// 六格指标（iOS MetricGrid）：睡眠 / 静息心率 / HRV / 身体电量 / 压力 / 步数
function metricGrid(mm) {
  const cells = [
    ['睡眠', mm.sleep_seconds != null ? (mm.sleep_seconds / 3600).toFixed(1) + ' h' : '—', 'moon', 'sleep'],
    ['静息心率', mm.resting_heart_rate != null ? mm.resting_heart_rate + ' bpm' : '—', 'heart', 'hr'],
    ['HRV', mm.hrv_last_night != null ? mm.hrv_last_night + ' ms' : '—', 'gauge', 'hrv'],
    ['身体电量', mm.body_battery != null ? mm.body_battery : '—', 'cpu', 'battery'],
    ['压力', mm.avg_stress != null ? mm.avg_stress : '—', 'wrench', 'stress'],
    ['步数', mm.steps != null ? mm.steps.toLocaleString('zh-CN') : '—', 'run', 'steps'],
  ];
  return html`<div class="metric-grid rise" style="--d:200ms">${cells.map(([t, v, ic, k]) => html`<button class="metric" data-act="health-metric" data-key="${k}">${icon(ic)}<small>${t}</small><b class="mono">${v}</b></button>`)}</div>`;
}

// 最近 7 天活动条（iOS ActivityStrip）：每天一条，高度按活动分钟
function activityStrip() {
  const recent = days().slice(-7);
  if (!recent.length) return '';
  const max = Math.max(1, ...recent.map((d) => (d.activities || []).reduce((a, x) => a + (x.minutes || 0), 0)));
  return section('最近活动', html`<div class="card activity">${recent.map((d) => {
    const mins = (d.activities || []).reduce((a, x) => a + (x.minutes || 0), 0);
    const label = String(d.date || '').slice(5);
    return html`<div class="act-col"><i style="height:${Math.max(6, (mins / max) * 100)}%"></i><small class="mono faint">${label}</small></div>`;
  })}</div>`);
}

function trendPanel(key) {
  const rows = days().slice(-14);
  const pick = { sleep: (d) => (d.measurements || {}).sleep_seconds / 3600, hrv: (d) => (d.measurements || {}).hrv_last_night, battery: (d) => (d.measurements || {}).body_battery, steps: (d) => (d.measurements || {}).steps, hr: (d) => (d.measurements || {}).resting_heart_rate, stress: (d) => (d.measurements || {}).avg_stress };
  const f = pick[key] || pick.sleep;
  const vals = rows.map(f).filter((v) => Number.isFinite(v));
  if (!vals.length) return html`<p class="faint">这一项还没有足够的数据。</p>`;
  const lo = Math.min(...vals), hi = Math.max(...vals), span = hi - lo || 1;
  return html`<div class="trend">${rows.map((d) => { const v = f(d); return html`<div class="trend-col"><i style="height:${Number.isFinite(v) ? 12 + ((v - lo) / span) * 88 : 4}%"></i><small class="mono faint">${String(d.date || '').slice(8)}</small></div>`; })}</div>`;
}
const METRIC_TITLE = { sleep: '睡眠', hr: '静息心率', hrv: 'HRV', battery: '身体电量', stress: '压力', steps: '步数' };
act('health-metric', (b) => {
  const key = b.dataset.key;
  openSheet({ title: METRIC_TITLE[key] || '指标', render: () => html`<div class="detail-head"><h2>${METRIC_TITLE[key]}</h2><p>最近 14 天</p></div>${trendPanel(key)}` });
});
act('health-dim', (b) => {
  const dim = (((D(INSIGHT) || {}).dimensions) || []).find((d) => d.key === b.dataset.key) || {};
  const [name] = DIM[b.dataset.key] || [b.dataset.key];
  openSheet({ title: name, render: () => html`<div class="detail-head"><h2>${name}：${(LEVEL[dim.level] || LEVEL.fair).label}</h2></div><p>${dim.note || dim.detail || '这一项的说明还没有生成。'}</p>` });
});

export function renderHealth(root) {
  const insight = D(INSIGHT) || {};
  const mm = m();
  const empty0 = !mm || !Object.keys(mm).length;
  root.innerHTML = html`<div class="page health">
    <div class="page-head rise"><p class="sub">${empty0 ? '还没有今天的 Garmin 数据' : '身体状态与建议'}</p></div>
    ${empty0 ? notice('还没有今天的 Garmin 数据：手表同步后这里会出评估。', 'neutral') : ''}
    ${heroRing(insight, mm)}
    ${dimensionRow(insight)}
    ${actionStack(insight)}
    ${metricGrid(mm)}
    ${activityStrip()}
    ${healthBrief()}
    ${bodyCard()}
    ${S.errors[HEALTH] ? notice(S.errors[HEALTH]) : ''}
  </div>`.s;
  countUp(root);
}

// ─── 身体卡（10-27 起从「今天」搬来，iOS BodyCard） ───
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
  const h = (D('/personal/today') || {}).health || {};
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

// 简报里的身体要点（「下一步」整理时顺手写的，kind = health）
function healthBrief() {
  const pts = ((D('/personal/next') || {}).brief || []).filter((x) => x.kind === 'health' && x.text);
  return pts.length ? html`<div class="health-brief">${pts.map((p) => html`<div class="card advice"><i class="hue pink big">${icon('heart')}</i><p>${p.text}</p></div>`)}</div>` : '';
}

/** 切到「健康」时拉数据；数据变了就重画。 */
export function refreshHealth() { load(HEALTH); load(INSIGHT); load('/personal/today'); load('/personal/next'); }
export { icon, empty };
