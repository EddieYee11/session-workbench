// 「下一步」：它把邮件、日程、项目、任务和账本收拢成几件现在值得做的事（iOS NextView.swift）。
import { S, $, html, raw, nextData, nextItems, brokenSources, sourceName, relativeTime, clockTime, nextAction, refreshNext, onChange, D, yuan, agentName, hostName, agencyCards, tasks, noteOf, api, patchData, load, toast, flowItems } from './core.js';
import { icon, act, stamp, empty, section, pushSheet, openSheet } from './ui.js';
import { voyageBanner, planCard, nextActions, waitingData, waitingCount } from './cases.js';

const EV_ICON = { mail: 'envelope', event: 'calendar', project: 'desktop', task: 'checklist', finance: 'card', goal: 'scope', wechat: 'message', health: 'heart', todo: 'checklist', inbox: 'tray', reminder: 'bell', sms: 'message', plaud: 'waveform', weather: 'cloud' };
const EV_NAME = { mail: '邮件', event: '日程', project: '项目', task: '任务', finance: '账本', goal: '目标', wechat: '微信', health: '身体', todo: '行动台', inbox: '速记', reminder: '提醒事项', sms: '短信', plaud: '录音纪要', weather: '天气' };
const evName = (k) => EV_NAME[k] || '资料';
function evWhen(e) {
  const d = e.detail || {}, at = d.at || 0;
  if (!(at > 0)) return '';
  if (e.kind === 'event') { const t = new Date(at * 1000); return `${t.getMonth() + 1}月${t.getDate()}日 ${clockTime(at)}${d.end > at ? '–' + clockTime(d.end) : ''}`; }
  return relativeTime(at);
}
const evSource = (e) => (e.detail && e.detail.source_label) || (e.label || '').split(' · ')[0] || evName(e.kind);
const evTitle = (e) => (e.detail && e.detail.title) || (e.label || '').split(' · ').pop() || '';

export function sourceBrokenNote(s) {
  const name = sourceName(s.name);
  return html`<div class="card hl danger"><div class="meta danger">${icon('warning')}<span>信源断了${s.updated_at > 0 ? ' · ' + relativeTime(s.updated_at) : ''}</span></div>
    <h3>我读不到 ${name} 了${s.status === 'needs_connection' ? '，授权已过期。重新授权前，我看不到新的内容。' : '。重新连接前，我看不到新的内容。'}</h3>
    <button class="btn primary" data-act="open-connector" data-name="${s.name}">重新授权 ${name}</button></div>`;
}
export function ledgerNote(fin) {
  const money = (fin.currencies || [])[0] || {};
  const top = (money.categories || [])[0];
  const d = new Date();
  return html`<button class="note-surface ledger" data-act="open-finance">
    <span class="badge accent">${icon('card')}</span>
    <span class="grow"><small>账本${fin.stale ? ' · 上次快照' : ''}</small><span>${d.getMonth() + 1}月过了 ${d.getDate()} 天，已花 <b>${yuan(money.month_minor)}</b>${top ? `，${top.name} ${yuan(top.amount_minor)} 最多。` : '。'}</span></span>${icon('right', 'chev')}</button>`;
}

function buildingCard(progress) {
  const p = progress || {}, stg = p.stage || '', c = p.counts || {};
  const got = stg === 'think' || stg === 'store';
  const meta = (k, u) => (got ? (c[k] > 0 ? `${c[k]} ${u}` : '没有新的') : '');
  const steps = [
    ['envelope', '读邮件', meta('mail', '封'), got], ['calendar', '看日程', meta('calendar', '个'), got], ['desktop', '对项目进度', meta('projects', '个'), got],
    ['checklist', '看今天的任务', meta('tasks', '件'), got], ['card', '翻账本', got ? (c.finance > 0 ? '本月' : '没接上') : '', got],
    ['waveform', '听会议纪要和短信', got ? ((c.commitments || 0) + (c.sms || 0) > 0 ? `${c.commitments || 0} 场会 · ${c.sms || 0} 条短信` : '没有新的') : '', got],
    ['sparkles', '归纳成下一步', '', stg === 'store'],
  ];
  const active = steps.findIndex((s) => !s[3]);
  const act0 = active < 0 ? steps.length : active;
  const elapsed = p.started_at > 0 ? Date.now() / 1000 - p.started_at : 0;
  const frac = stg === 'store' ? 1 : stg === 'think' ? 0.35 + 0.55 * (1 - Math.exp(-elapsed / 35)) : 0.12;
  return html`<div class="build-card rise">
    <div class="track"><i style="width:${Math.max(4, frac * 100)}%"></i></div>
    <div class="row between"><small class="muted">${stg === 'think' ? '模型在归纳' : stg === 'store' ? '快好了' : '在收集'}</small>${p.started_at > 0 ? html`<small class="accent-text mono" data-since-build="${p.started_at}">已 ${Math.floor(elapsed)} 秒</small>` : ''}</div>
    <div class="build-list">${steps.map((s, i) => html`<div class="build-row ${i < act0 ? 'done' : i === act0 ? 'active' : i === act0 + 1 ? 'next' : 'far'}">${icon(s[0])}<span>${s[1]}</span>${s[2] ? html`<small>${s[2]}</small>` : ''}<em>${s[3] ? icon('checkCircle') : i === act0 ? raw('<i class="spin"></i>') : raw('<i class="ring"></i>')}</em></div>`)}</div>
  </div>`;
}

function pocket(item) {
  const ev = (item.evidence || []).slice(0, 5);
  const kinds = [...new Set(ev.map((e) => evName(e.kind)))].join('、');
  const tilts = [-4, 3.5, -2, 5, -3];
  return html`<div class="pocket" data-pocket="${item.id}" style="--n:${ev.length}">
    <div class="slips">${ev.map((e, i) => html`<button class="slip" style="--i:${i};--tilt:${tilts[i]}deg" data-act="evidence-open" data-item="${item.id}" data-idx="${i}" tabindex="-1">
      <span class="src">${icon(EV_ICON[e.kind] || 'doc')}${evSource(e)}</span><b>${evTitle(e)}</b><small>${evWhen(e)}</small></button>`)}</div>
    <button class="pocket-face" data-act="pocket-toggle">
      <span class="grow"><b class="lbl"><span class="a">依据 · ${(item.evidence || []).length} 份</span><span class="b">点一张看原文</span></b><small>${kinds}</small></span>
      <i class="arrow">${icon('arrowUp')}</i></button>
  </div>`;
}
function nextCard(item, i) {
  return html`<div class="card ${item.urgency === 'now' ? 'hl accent' : ''} next-card rise" style="--d:${i * 50}ms" data-next="${item.id}">
    <div class="row between top"><h3>${item.title}</h3>${item.phase === 'waiting' ? stamp('等对方', 'info') : item.phase === 'progress' ? stamp('进展中', 'accent') : item.urgency === 'now' ? stamp('现在', 'warning') : ''}</div>
    ${item.why ? html`<p class="sub">${item.why}</p>` : ''}
    ${(item.history || []).length ? (() => { const h = item.history[item.history.length - 1]; return html`<small class="muted row">${icon('right')}${h.text} · ${relativeTime(h.at)}</small>`; })() : ''}
    ${(item.evidence || []).length ? pocket(item) : ''}
    ${nextActions(item)}</div>`;
}

// ─── 等你（放在页面最上面）与已排程 ───
function waitingBlock() {
  const n = waitingCount(); if (!n) return '';
  const rows = [...flowItems.filter((i) => !i.stale), ...(waitingData().items || [])].slice(0, 3);
  return section(`等你 · ${n}`, html`<div class="card list">${rows.map((i) => html`<button class="list-row" data-act="waiting-open"><span class="badge warning">${icon('hand')}</span><span><b>${i.title}</b>${i.why ? html`<small>${i.why}</small>` : ''}</span>${icon('right', 'chev')}</button>`)}
    ${n > rows.length ? html`<button class="list-row" data-act="waiting-open"><span><b>还有 ${n - rows.length} 件，去看全部</b></span>${icon('right', 'chev')}</button>` : ''}</div>`);
}
let routinesOpen = false;
const routineBusy = new Set();
const whenText = (sec) => { if (!(sec > 0)) return ''; const t = new Date(sec * 1000); return `${t.getMonth() + 1}月${t.getDate()}日 ${clockTime(sec)}`; };
function routinesBlock() {
  const d = D('/personal/routines'), err = S.errors['/personal/routines'];
  const items = (d && d.items) || [];
  const head = html`<button class="list-row" data-act="routines-toggle">${icon('calendar')}<span><b>已排程${items.length ? ' · ' + items.length : ''}</b><small>${err ? '没读到' : d && d.paused ? '已全部暂停' : '定时在跑的事'}</small></span>${icon('right', routinesOpen ? 'rot' : 'chev')}</button>`;
  if (!routinesOpen) return html`<div class="card list routines">${head}</div>`;
  const row = (r) => html`<div class="routine-row ${r.enabled === false ? 'off' : ''}">
    <span class="grow"><b>${r.title}</b><small>${[r.group, r.trigger].filter(Boolean).join(' · ')}</small>
      <small>${[r.next_run_at > 0 ? '下次 ' + whenText(r.next_run_at) : '', r.last_run_at > 0 ? '上次 ' + relativeTime(r.last_run_at) + (r.last_status ? '（' + r.last_status + '）' : '') : ''].filter(Boolean).join(' · ')}</small>
      ${r.note ? html`<small class="muted">${r.note}</small>` : ''}</span>
    ${r.controllable === false ? stamp('只读', 'neutral') : html`<button class="btn secondary compact" data-act="routine-toggle" data-id="${r.id}" data-a="${r.enabled === false ? 'resume' : 'pause'}" ${routineBusy.has(r.id) ? raw('disabled') : ''}>${r.enabled === false ? '恢复' : '暂停'}</button>`}</div>`;
  return html`<div class="card list routines">${head}
    ${err ? html`<div class="notice warning inline-note">${icon('warning')}<span>排程清单没读上：${err}</span></div>` : ''}
    ${d ? html`<div class="routine-all"><small class="muted">${d.paused ? '全部排程已暂停' : '全部排程在跑'}</small>
      <button class="btn quiet compact" data-act="routine-toggle" data-id="_all" data-a="${d.paused ? 'resume' : 'pause'}" ${routineBusy.has('_all') ? raw('disabled') : ''}>${d.paused ? '全部恢复' : '全部暂停'}</button></div>` : ''}
    ${items.length ? items.map(row) : d && !err ? html`<p class="muted small">现在没有排程。</p>` : ''}</div>`;
}
act('routines-toggle', () => { routinesOpen = !routinesOpen; if (routinesOpen) load('/personal/routines'); renderRoutines(); });
function renderRoutines() { const el = document.querySelector('#page-next .routines'); if (el) { const w = document.createElement('div'); w.innerHTML = routinesBlock().s; el.replaceWith(w.firstElementChild); } }
act('routine-toggle', async (b) => {
  const id = b.dataset.id, a = b.dataset.a; if (routineBusy.has(id)) return;
  const prev = D('/personal/routines'); if (!prev) return;
  const snapshot = JSON.parse(JSON.stringify(prev));
  routineBusy.add(id);
  patchData('/personal/routines', (x) => { if (id === '_all') x.paused = a === 'pause'; else (x.items || []).forEach((r) => { if (r.id === id) r.enabled = a === 'resume'; }); return x; });
  renderRoutines();
  try {
    await api('/personal/routines/' + encodeURIComponent(id), { body: { action: a } });
    await load('/personal/routines');
  } catch (e) {
    patchData('/personal/routines', () => snapshot);
    toast('没改成，已恢复原样：' + e.message);
  } finally { routineBusy.delete(id); renderRoutines(); }
});

export function renderNext(root) {
  const data = nextData();
  const items = nextItems();
  const groups = [['现在', 'now'], ['今天', 'today'], ['这周', 'week']].map(([t, k]) => [t, items.filter((i) => i.urgency === k)]).filter(([, r]) => r.length);
  const fin = D('/personal/finance');
  const week = data.week || {};
  const open = new Set([...root.querySelectorAll('.pocket.open')].map((p) => p.dataset.pocket));
  const head = items[0];
  const note = noteOf('next');
  let n = 0;
  root.innerHTML = html`<div class="page">
    <div class="page-head rise"><div class="row between"><p class="sub">${S.nextRefreshing ? '正在重新整理…' : head ? `先办这一件：${head.title}` : '没什么要推的'}</p></div>
      ${data.updated_at > 0 ? html`<small class="muted">上次整理 ${relativeTime(data.updated_at)}${data.source === 'rule' ? ' · 模型没接上，先按规则排' : ''}</small>` : ''}
      ${S.errors['/personal/next'] ? html`<small class="danger-text">${S.errors['/personal/next']}</small>` : ''}
      ${note ? html`<div class="notice warning inline-note">${icon('warning')}<span>${note}</span></div>` : ''}</div>
    ${waitingBlock()}
    ${voyageBanner()}
    ${planCard()}
    ${brokenSources().map(sourceBrokenNote)}
    ${S.nextRefreshing ? buildingCard(data.progress) : !items.length && D('/personal/next') ? empty('没什么要推的', '我每小时会自己再看一遍；有新邮件、新日程或项目有进展，会整理成下一步放在这里。', 'sparkles') : ''}
    ${!D('/personal/next') && !S.errors['/personal/next'] ? html`<div class="skeleton"></div><div class="skeleton"></div>` : ''}
    ${groups.map(([t, rows]) => section(t === '现在' ? '现在 · 先办' : t, html`${rows.map((r) => nextCard(r, n++))}`))}
    ${fin && fin.available ? section('账本', ledgerNote(fin)) : ''}
    ${week.shown > 0 ? html`<p class="foot">这周提了 ${week.shown} 件，你用上 ${week.acted || 0} 件、划掉 ${week.dismissed || 0} 件${week.precision != null ? '，准确率 ' + Math.round(week.precision * 100) + '%' : ''}${week.resolved > 0 ? '；群里已经办完、我自动收起 ' + week.resolved + ' 件' : ''}。${Object.keys(week.reasons || {}).length ? '划掉的理由：' + Object.entries(week.reasons).sort((a, b) => b[1] - a[1]).map(([k, n]) => k + ' ' + n).join(' · ') + '。' : ''}</p>` : ''}
    ${routinesBlock()}
    <button class="btn quiet" data-act="open-activity">${icon('checklist')}看它替你做过的事</button>
  </div>`.s;
  for (const id of open) root.querySelector(`.pocket[data-pocket="${CSS.escape(id)}"]`)?.classList.add('open', 'instant');
}
setInterval(() => { for (const el of document.querySelectorAll('[data-since-build]')) el.textContent = `已 ${Math.floor(Date.now() / 1000 - Number(el.dataset.sinceBuild))} 秒`; }, 1000);

act('next-do', async (b) => {
  const item = nextItems().find((i) => i.id === b.dataset.id); if (!item) return;
  const card = b.closest('.next-card');
  card?.querySelectorAll('button').forEach((x) => (x.disabled = true));
  if (b.dataset.a !== 'discuss') card?.classList.add('leaving');
  const ok = await nextAction(item, b.dataset.a, b.dataset.reason);
  if (!ok && b.dataset.a !== 'discuss') {
    card?.classList.remove('leaving');
    card?.querySelectorAll('button').forEach((x) => (x.disabled = false));
  }
});
act('pocket-toggle', (b) => { const p = b.closest('.pocket'); p.classList.remove('instant'); p.classList.toggle('open'); });
act('next-refresh', () => refreshNext());

// ─── 依据详情（EvidenceDetail） ───
act('evidence-open', (b) => {
  const item = nextItems().find((i) => i.id === b.dataset.item); if (!item) return;
  const e = item.evidence[Number(b.dataset.idx)];
  b.classList.add('lifted');
  setTimeout(() => { b.classList.remove('lifted'); openSheet(evidenceView(e, item.title)); }, 200);
});
export function evidenceView(e, itemTitle) {
  return {
    title: '依据',
    render: () => {
      const d = e.detail || {}, kind = e.kind, title = evTitle(e);
      const meta = [['时间', evWhen(e)], [kind === 'wechat' ? '谁说的' : '发件人', d.sender], ['聊天', d.group], ['地点', d.location], ['日历', d.calendar], ['在哪', [hostName(d.host), agentName(d.agent)].filter(Boolean).join(' · ')]].filter((x) => x[1]);
      const link = d.link || e.link || '';
      const matterID = e.matter_id || '';
      const task = tasks().find((t) => t.id === e.task_id);
      const project = e.item_id || (kind === 'project' ? String(e.ref || '').replace(/^project:/, '') : '');
      return html`<div class="paper-detail land">
        <div class="row">${stamp(evName(kind), 'accent')}${evSource(e) !== title ? html`<small class="muted">${evSource(e)}</small>` : ''}<span class="grow"></span>${icon(EV_ICON[kind] || 'doc')}</div>
        <h2><mark>${title}</mark></h2>
        ${meta.map(([k, v]) => html`<div class="kv tight"><span>${k}</span><b>${v}</b></div>`)}</div>
        ${d.summary ? html`<div class="card rise" style="--d:120ms"><small class="label">${kind === 'mail' ? '原文摘要' : '摘要'}</small><p>${d.summary}</p></div>` : ''}
        ${kind === 'wechat' && (d.messages || []).length ? html`<div class="card rise" style="--d:140ms"><small class="label">最近几句</small>${d.messages.map((m) => html`<div class="wx-line"><span>${m.sender}</span><p>${m.text}</p></div>`)}</div>` : ''}
        ${d.next_step ? html`<div class="card inset rise" style="--d:160ms"><small class="label">那边记的下一步</small><p class="lined">${d.next_step}</p></div>` : ''}
        ${!e.detail ? html`<p class="muted small">这条依据只记了标题，原始来源已经不在了。</p>` : ''}
        ${matterID || task || project || link ? section('继续看', html`<div class="list">
          ${matterID ? html`<button class="list-row" data-act="open-matter" data-id="${matterID}" data-ev="${JSON.stringify(e)}">${icon('doc')}<span><b>${kind === 'event' ? '看这个日程' : kind === 'wechat' ? '看这条微信' : '看这封邮件'}</b><small>事项详情：交给 Com、标记处理、纠正</small></span>${icon('right', 'chev')}</button>` : ''}
          ${task ? html`<button class="list-row" data-act="open-task" data-id="${task.id}">${icon('checklist')}<span><b>看任务</b><small>${task.title}</small></span>${icon('right', 'chev')}</button>` : ''}
          ${project ? html`<button class="list-row" data-act="open-board-item" data-id="${project}">${icon('desktop')}<span><b>看项目进展</b><small>会话里的原话和进展快照</small></span>${icon('right', 'chev')}</button>` : ''}
          ${link ? html`<a class="list-row" href="${link}" target="_blank" rel="noopener">${icon('arrowUpRight')}<span><b>打开原文</b><small>${(() => { try { return new URL(link).host; } catch { return link; } })()}</small></span></a>` : ''}
        </div>`) : ''}
        <p class="muted small">支撑的建议：${itemTitle}</p>`;
    },
  };
}
export function matterFromEvidence(id, e) {
  const card = agencyCards().find((c) => c.id === id);
  if (card) return card;
  const d = e.detail || {}, facts = {};
  for (const [k, n] of [['sender', e.kind === 'wechat' ? '谁说的' : '发件人'], ['group', '聊天'], ['location', '地点'], ['calendar', '日历'], ['summary', '摘要']]) if (d[k]) facts[n] = d[k];
  return { id, title: d.title || e.label, what: d.summary, source: d.source, facts };
}
onChange(() => {});
export { pushSheet };
