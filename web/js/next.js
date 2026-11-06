// 「下一步」：三列看板（建议待办 / 待办 / 已完成）与拖拽流转持久化（对照 iOS NextView / BoardKanbanView）。
import {
  S, $, $$, html, raw, nextData, nextItems, brokenSources, sourceName,
  relativeTime, clockTime, nextAction, refreshNext, onChange, D, yuan,
  agentName, hostName, agencyCards, tasks, noteOf, api, patchData, load,
  toast, flowItems
} from './core.js';
import { icon, act, stamp, empty, section, pushSheet, openSheet } from './ui.js';
import { voyageBanner, planCard, nextActions, waitingData, waitingCount } from './cases.js';

const EV_ICON = {
  mail: 'envelope', event: 'calendar', project: 'desktop', task: 'checklist',
  finance: 'card', goal: 'scope', wechat: 'message', health: 'heart',
  todo: 'checklist', inbox: 'tray', reminder: 'bell', sms: 'message',
  plaud: 'waveform', weather: 'cloud'
};
const EV_NAME = {
  mail: '邮件', event: '日程', project: '项目', task: '任务', finance: '账本',
  goal: '目标', wechat: '微信', health: '身体', todo: '行动台', inbox: '速记',
  reminder: '提醒事项', sms: '短信', plaud: '录音纪要', weather: '天气'
};
const evName = (k) => EV_NAME[k] || '资料';
function evWhen(e) {
  const d = e.detail || {}, at = d.at || 0;
  if (!(at > 0)) return '';
  if (e.kind === 'event') {
    const t = new Date(at * 1000);
    return `${t.getMonth() + 1}月${t.getDate()}日 ${clockTime(at)}${d.end > at ? '–' + clockTime(d.end) : ''}`;
  }
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

// ─── 等你（放在页面最上面）与已排程 ───
function waitingBlock() {
  const n = waitingCount();
  const concluded = waitingData().concluded || [];
  if (!n && !concluded.length) return '';
  const rows = [...flowItems.filter((i) => !i.stale), ...(waitingData().items || [])].slice(0, 3);
  return html`${n ? section(`等你 · ${n}`, html`<div class="card list">${rows.map((i) => html`<button class="list-row" data-act="waiting-open"><span class="badge warning">${icon('hand')}</span><span><b>${i.title}</b>${i.why ? html`<small>${i.why}</small>` : ''}</span>${icon('right', 'chev')}</button>`)}
    ${n > rows.length ? html`<button class="list-row" data-act="waiting-open"><span><b>还有 ${n - rows.length} 件，去看全部</b></span>${icon('right', 'chev')}</button>` : ''}</div>`) : ''}
    ${concluded.length ? section('刚拍板的', html`<div class="card list">${concluded.slice(0, 3).map((c) => html`<button class="list-row" data-act="waiting-open"><span class="badge success">${icon('checkCircle')}</span><span><b>${c.title}</b><small>${c.text}</small></span></button>`)}</div>`) : ''}`;
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

// ─── 看板核心状态与流转逻辑（PersonalBoard / Drag & Drop） ───
let loadingBoard = false;
let activeMobileTab = 'suggest'; // 'suggest' | 'todo' | 'done'

export const BOARD_COLUMNS = [
  { key: 'suggest', title: '建议待办', iconName: 'sparkles', desc: '模型与信源归纳的下一步', emptyText: '暂时没有新建议' },
  { key: 'todo', title: '待办', iconName: 'checklist', desc: '行动台与正在做的事', emptyText: '现在没有待办事项' },
  { key: 'done', title: '已完成', iconName: 'checkCircle', desc: '近期已办结与归档', emptyText: '近期还没有完成事项' },
];

export async function ensureBoardData() {
  if (D('/personal/board') || loadingBoard) return;
  loadingBoard = true;
  try {
    await load('/personal/board');
  } finally {
    loadingBoard = false;
  }
}

/**
 * 跨列流转：调用 POST /personal/board/move，支持乐观更新与 409/400 失败回滚。
 */
export async function boardMoveCard(cardId, targetCol, rev) {
  let board = D('/personal/board');
  if (!board) {
    await load('/personal/board');
    board = D('/personal/board');
    if (!board) return;
  }

  // 定位卡片当前所在物理列
  let currentCard = null;
  let sourceCol = null;
  const cols = board.columns || {};
  for (const colKey of ['suggest', 'todo', 'doing', 'done']) {
    const list = cols[colKey] || [];
    const found = list.find((c) => c.id === cardId);
    if (found) {
      currentCard = found;
      sourceCol = colKey;
      break;
    }
  }
  if (!currentCard) return;

  // 映射 UI 列到底层目标（UI 待办组合并了 doing 和 todo）
  const uiSourceCol = sourceCol === 'doing' ? 'todo' : sourceCol;
  if (uiSourceCol === targetCol && targetCol !== 'doing') {
    return; // 同列无须移动
  }

  const cardRev = rev || currentCard.rev || '';
  const snapshot = JSON.parse(JSON.stringify(board));

  // 1. 本地乐观更新（UI 立即响应）
  if (cols[sourceCol]) {
    cols[sourceCol] = cols[sourceCol].filter((c) => c.id !== cardId);
  }
  const movedCard = JSON.parse(JSON.stringify(currentCard));
  movedCard.column = targetCol;
  if (!cols[targetCol]) cols[targetCol] = [];
  cols[targetCol].unshift(movedCard);

  S.data['/personal/board'] = board;
  const root = document.querySelector('#page-next');
  if (root) renderNext(root);

  // 2. 发送 POST /personal/board/move
  const reqBody = {
    request_id: 'op-' + Date.now(),
    card: cardId,
    to: targetCol,
    rev: cardRev,
  };

  try {
    const res = await api('/personal/board/move', { body: reqBody });
    if (res && res.card) {
      patchData('/personal/board', (b) => {
        const cList = b.columns?.[targetCol] || [];
        b.columns[targetCol] = [res.card, ...cList.filter((c) => c.id !== cardId && c.id !== res.card.id)];
        if (res.version) b.version = res.version;
        return b;
      });
    }
    // 后台刷齐数据库与 Markdown 状态
    await load('/personal/board');
    const r = document.querySelector('#page-next');
    if (r) renderNext(r);
  } catch (err) {
    // 3. 失败回滚至快照并给予直观提示
    S.data['/personal/board'] = snapshot;
    const r = document.querySelector('#page-next');
    if (r) renderNext(r);

    if (err.status === 409) {
      toast('卡片版本已失效（已被其他端流转），已自动拉取最新状态');
      await load('/personal/board');
      const r2 = document.querySelector('#page-next');
      if (r2) renderNext(r2);
    } else if (err.status === 400) {
      toast('移动失败：' + (err.message || '非法移动'));
    } else {
      toast('操作未确认：' + (err.message || '网络连接异常'));
    }
  }
}

function renderKanbanCard(card, columnKey, isDoing) {
  const isDone = columnKey === 'done';
  const isUrgent = !isDone && (card.urgency === 'now');
  const whyText = (card.next && card.next.why) || (card.todo && card.todo.next_step) || '';
  const sources = card.sources || [];

  return html`<div class="kanban-card ${isDoing ? 'is-doing' : ''} ${isUrgent ? 'is-urgent' : ''} ${isDone ? 'is-done' : ''} rise"
       draggable="true"
       data-card-id="${card.id}"
       data-col="${columnKey}"
       data-rev="${card.rev || ''}">
    <div class="card-head row between top">
      <div class="card-title-row">
        ${isDone ? html`<span class="badge success">${icon('checkCircle')}</span>` : ''}
        ${isDoing ? html`<span class="badge danger doing-badge">${icon('bolt')} ● 正在做</span>` : ''}
        <h4 class="card-title">${card.title}</h4>
      </div>
      <div class="card-stamps">
        ${!isDone && card.phase === 'waiting' ? stamp('等对方', 'info') : ''}
        ${!isDone && card.phase === 'progress' && !isDoing ? stamp('进展中', 'accent') : ''}
        ${!isDone && isUrgent ? stamp('现在', 'warning') : ''}
        ${card.overdue ? stamp('逾期', 'danger') : ''}
      </div>
    </div>
    ${whyText ? html`<p class="card-why clamp2">${whyText}</p>` : ''}
    ${card.progress ? html`<div class="card-prog row small muted">${icon('right')}${card.progress}</div>` : ''}
    ${card.due ? html`<div class="card-due small muted">${icon('calendar')} 计划结束：${card.due}</div>` : ''}
    ${isDone && card.completed_at > 0 ? html`<div class="card-done-time small muted">${icon('checkCircle')} 完成于 ${relativeTime(card.completed_at)}</div>` : ''}
    ${sources.length ? html`<div class="card-meta-row">${sources.slice(0, 3).map((k) => html`<span class="source-icon" title="${evName(k)}">${icon(EV_ICON[k] || 'doc')}</span>`)}<small class="muted">${sources.map(evName).join(' · ')}</small></div>` : ''}
    <div class="card-actions">
      <div class="card-quick-moves">
        ${columnKey === 'suggest' ? html`
          <button class="btn secondary compact" data-act="board-quick-move" data-id="${card.id}" data-to="todo" title="流转到待办">${icon('checklist')} 待办</button>
          <button class="btn quiet compact" data-act="board-quick-move" data-id="${card.id}" data-to="done" title="直接标记为已完成">${icon('checkCircle')}</button>
        ` : columnKey === 'todo' ? html`
          ${isDoing
            ? html`<button class="btn quiet compact doing-toggle active" data-act="board-toggle-doing" data-id="${card.id}" title="取消正在做">${icon('bolt')} 正在做</button>`
            : html`<button class="btn quiet compact doing-toggle" data-act="board-toggle-doing" data-id="${card.id}" title="设为正在做">${icon('bolt')}</button>`}
          <button class="btn secondary compact" data-act="board-quick-move" data-id="${card.id}" data-to="done" title="标记为完成">${icon('checkCircle')} 完成</button>
          <button class="btn quiet compact" data-act="board-quick-move" data-id="${card.id}" data-to="suggest" title="退回建议待办">${icon('left')} 退回建议</button>
        ` : html`
          <button class="btn quiet compact" data-act="board-quick-move" data-id="${card.id}" data-to="todo" title="撤回至待办">${icon('left')} 回待办</button>
          <button class="btn quiet compact" data-act="board-quick-move" data-id="${card.id}" data-to="suggest" title="流转回建议待办">${icon('sparkles')} 回建议</button>
        `}
      </div>
      <button class="btn quiet small" data-act="board-card-detail" data-id="${card.id}">${icon('doc')} 详情</button>
    </div>
  </div>`;
}

let draggedCardInfo = null;
let activePlaceholder = null;

function getPlaceholder() {
  if (!activePlaceholder) {
    activePlaceholder = document.createElement('div');
    activePlaceholder.className = 'drag-placeholder';
    activePlaceholder.innerHTML = '<span>松开放置到此处</span>';
  }
  return activePlaceholder;
}

function getDragAfterElement(container, y) {
  const draggableElements = [...container.querySelectorAll('.kanban-card:not(.dragging)')];
  return draggableElements.reduce((closest, child) => {
    const box = child.getBoundingClientRect();
    const offset = y - box.top - box.height / 2;
    if (offset < 0 && offset > closest.offset) {
      return { offset: offset, element: child };
    } else {
      return closest;
    }
  }, { offset: Number.NEGATIVE_INFINITY }).element;
}

function bindKanbanDragEvents(container) {
  if (!container || container._kanbanDnDBound) return;
  container._kanbanDnDBound = true;

  container.addEventListener('dragstart', (e) => {
    const cardEl = e.target.closest('.kanban-card');
    if (!cardEl) return;
    const cardId = cardEl.dataset.cardId;
    const col = cardEl.dataset.col;
    const rev = cardEl.dataset.rev;
    draggedCardInfo = { cardId, fromCol: col, rev };
    e.dataTransfer.setData('text/plain', cardId);
    e.dataTransfer.setData('application/json', JSON.stringify(draggedCardInfo));
    e.dataTransfer.effectAllowed = 'move';
    requestAnimationFrame(() => {
      cardEl.classList.add('dragging');
    });
  });

  container.addEventListener('dragend', (e) => {
    const cardEl = e.target.closest('.kanban-card');
    if (cardEl) cardEl.classList.remove('dragging');
    container.querySelectorAll('.kanban-card.dragging').forEach((el) => el.classList.remove('dragging'));
    container.querySelectorAll('.kanban-col.drop-target').forEach((el) => el.classList.remove('drop-target'));
    if (activePlaceholder && activePlaceholder.parentNode) {
      activePlaceholder.remove();
    }
    draggedCardInfo = null;
  });

  container.addEventListener('dragover', (e) => {
    const colEl = e.target.closest('.kanban-col');
    if (!colEl) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';

    container.querySelectorAll('.kanban-col.drop-target').forEach((el) => {
      if (el !== colEl) el.classList.remove('drop-target');
    });
    colEl.classList.add('drop-target');

    const cardsContainer = colEl.querySelector('.kanban-col-cards');
    if (cardsContainer) {
      const placeholder = getPlaceholder();
      const afterElement = getDragAfterElement(cardsContainer, e.clientY);
      if (afterElement == null) {
        cardsContainer.appendChild(placeholder);
      } else {
        cardsContainer.insertBefore(placeholder, afterElement);
      }
    }
  });

  container.addEventListener('dragleave', (e) => {
    const colEl = e.target.closest('.kanban-col');
    if (!colEl) return;
    if (!colEl.contains(e.relatedTarget)) {
      colEl.classList.remove('drop-target');
      if (activePlaceholder && activePlaceholder.parentNode === colEl.querySelector('.kanban-col-cards')) {
        activePlaceholder.remove();
      }
    }
  });

  container.addEventListener('drop', (e) => {
    const colEl = e.target.closest('.kanban-col');
    if (!colEl) return;
    e.preventDefault();

    colEl.classList.remove('drop-target');
    if (activePlaceholder && activePlaceholder.parentNode) {
      activePlaceholder.remove();
    }

    let info = draggedCardInfo;
    if (!info) {
      try {
        const rawJson = e.dataTransfer.getData('application/json');
        if (rawJson) info = JSON.parse(rawJson);
      } catch {
        const id = e.dataTransfer.getData('text/plain');
        if (id) info = { cardId: id };
      }
    }

    if (!info || !info.cardId) return;
    const targetCol = colEl.dataset.col;
    boardMoveCard(info.cardId, targetCol, info.rev);
  });

  // 触控设备移动支持（Touch Drag & Drop）
  let touchStartCard = null;
  let touchGhost = null;
  let touchOffsetX = 0;
  let touchOffsetY = 0;
  let currentTouchTargetCol = null;
  let touchTimer = 0;

  container.addEventListener('touchstart', (e) => {
    const cardEl = e.target.closest('.kanban-card');
    if (!cardEl || e.target.closest('button') || e.target.closest('details')) return;
    const touch = e.touches[0];
    const rect = cardEl.getBoundingClientRect();
    touchOffsetX = touch.clientX - rect.left;
    touchOffsetY = touch.clientY - rect.top;

    touchTimer = setTimeout(() => {
      touchStartCard = cardEl;
      cardEl.classList.add('dragging');
      touchGhost = cardEl.cloneNode(true);
      touchGhost.className = 'kanban-card drag-ghost';
      touchGhost.style.left = `${touch.clientX - touchOffsetX}px`;
      touchGhost.style.top = `${touch.clientY - touchOffsetY}px`;
      touchGhost.style.width = `${rect.width}px`;
      document.body.appendChild(touchGhost);
    }, 280);
  }, { passive: true });

  container.addEventListener('touchmove', (e) => {
    if (!touchStartCard || !touchGhost) {
      clearTimeout(touchTimer);
      return;
    }
    const touch = e.touches[0];
    touchGhost.style.left = `${touch.clientX - touchOffsetX}px`;
    touchGhost.style.top = `${touch.clientY - touchOffsetY}px`;

    const elemBelow = document.elementFromPoint(touch.clientX, touch.clientY);
    const colEl = elemBelow ? elemBelow.closest('.kanban-col') : null;

    container.querySelectorAll('.kanban-col.drop-target').forEach((el) => {
      if (el !== colEl) el.classList.remove('drop-target');
    });

    if (colEl) {
      colEl.classList.add('drop-target');
      currentTouchTargetCol = colEl;
      const cardsContainer = colEl.querySelector('.kanban-col-cards');
      if (cardsContainer) {
        const placeholder = getPlaceholder();
        const afterElement = getDragAfterElement(cardsContainer, touch.clientY);
        if (afterElement == null) {
          cardsContainer.appendChild(placeholder);
        } else {
          cardsContainer.insertBefore(placeholder, afterElement);
        }
      }
    }
  }, { passive: true });

  const endTouch = () => {
    clearTimeout(touchTimer);
    if (touchStartCard) {
      touchStartCard.classList.remove('dragging');
      if (currentTouchTargetCol) {
        currentTouchTargetCol.classList.remove('drop-target');
        const targetCol = currentTouchTargetCol.dataset.col;
        const cardId = touchStartCard.dataset.cardId;
        const rev = touchStartCard.dataset.rev;
        boardMoveCard(cardId, targetCol, rev);
      }
    }
    if (activePlaceholder && activePlaceholder.parentNode) {
      activePlaceholder.remove();
    }
    if (touchGhost) {
      touchGhost.remove();
      touchGhost = null;
    }
    touchStartCard = null;
    currentTouchTargetCol = null;
  };

  container.addEventListener('touchend', endTouch);
  container.addEventListener('touchcancel', endTouch);
}

// ─── 主渲染入口（renderNext） ───
export function renderNext(root) {
  ensureBoardData();

  const data = nextData();
  const board = D('/personal/board');
  const cols = (board && board.columns) || {};

  const suggestCards = cols.suggest || [];
  const doingCards = cols.doing || [];
  const normalTodoCards = cols.todo || [];
  const todoCards = [...doingCards, ...normalTodoCards];
  const doneCards = cols.done || [];

  const fin = D('/personal/finance');
  const note = noteOf('next');
  const totalCards = suggestCards.length + todoCards.length + doneCards.length;

  const headerTitle = S.nextRefreshing
    ? '正在重新整理…'
    : doingCards.length
    ? `正在做：${doingCards[0].title}`
    : suggestCards.length
    ? `建议优先：${suggestCards[0].title}`
    : '看板就绪';

  root.innerHTML = html`<div class="page">
    <div class="page-head rise">
      <div class="row between">
        <p class="sub">${headerTitle}</p>
        <button class="btn quiet compact" data-act="board-refresh" title="重新从信源与模型整理">${icon('sparkles')} 重新整理</button>
      </div>
      ${board && board.updated_at > 0 ? html`<small class="muted">看板快照 ${relativeTime(board.updated_at)}${board.snoozed ? ` · 已推迟 ${board.snoozed} 件` : ''}</small>` : ''}
      ${S.errors['/personal/board'] ? html`<small class="danger-text">看板同步异常：${S.errors['/personal/board']}</small>` : ''}
      ${note ? html`<div class="notice warning inline-note">${icon('warning')}<span>${note}</span></div>` : ''}
    </div>

    ${waitingBlock()}
    ${voyageBanner()}
    ${planCard()}
    ${brokenSources().map(sourceBrokenNote)}
    ${S.nextRefreshing ? buildingCard(data.progress) : ''}

    <!-- 移动端分列标签 -->
    <div class="kanban-mobile-tabs">
      <button class="tab-btn ${activeMobileTab === 'suggest' ? 'active' : ''}" data-act="kanban-switch-tab" data-tab="suggest">${icon('sparkles')} 建议待办 (${suggestCards.length})</button>
      <button class="tab-btn ${activeMobileTab === 'todo' ? 'active' : ''}" data-act="kanban-switch-tab" data-tab="todo">${icon('checklist')} 待办 (${todoCards.length})</button>
      <button class="tab-btn ${activeMobileTab === 'done' ? 'active' : ''}" data-act="kanban-switch-tab" data-tab="done">${icon('checkCircle')} 已完成 (${doneCards.length})</button>
    </div>

    <!-- 3列看板主容器 -->
    <div class="kanban-board" data-active-tab="${activeMobileTab}">
      <!-- 1. 建议待办 (suggest) -->
      <div class="kanban-col" data-col="suggest">
        <div class="kanban-col-head">
          <div class="kanban-col-title">${icon('sparkles')}<span>建议待办</span></div>
          <span class="kanban-col-count">${suggestCards.length}</span>
        </div>
        <div class="kanban-col-desc">模型与信源归纳的下一步</div>
        <div class="kanban-col-cards">
          ${!board && !S.errors['/personal/board']
            ? html`<div class="kanban-skeleton-card"></div><div class="kanban-skeleton-card"></div>`
            : suggestCards.length
            ? suggestCards.map((c) => renderKanbanCard(c, 'suggest', false))
            : html`<div class="kanban-empty">暂时没有新建议</div>`}
        </div>
      </div>

      <!-- 2. 待办 (todo，含正在做) -->
      <div class="kanban-col" data-col="todo">
        <div class="kanban-col-head">
          <div class="kanban-col-title">${icon('checklist')}<span>待办</span></div>
          <span class="kanban-col-count">${todoCards.length}</span>
        </div>
        <div class="kanban-col-desc">行动台与正在做的事</div>
        <div class="kanban-col-cards">
          ${!board && !S.errors['/personal/board']
            ? html`<div class="kanban-skeleton-card"></div>`
            : todoCards.length
            ? todoCards.map((c) => renderKanbanCard(c, 'todo', doingCards.some((dc) => dc.id === c.id)))
            : html`<div class="kanban-empty">现在没有待办事项</div>`}
        </div>
      </div>

      <!-- 3. 已完成 (done) -->
      <div class="kanban-col" data-col="done">
        <div class="kanban-col-head">
          <div class="kanban-col-title">${icon('checkCircle')}<span>已完成</span></div>
          <span class="kanban-col-count">${doneCards.length}</span>
        </div>
        <div class="kanban-col-desc">近期已办结与归档</div>
        <div class="kanban-col-cards">
          ${!board && !S.errors['/personal/board']
            ? html`<div class="kanban-skeleton-card"></div>`
            : doneCards.length
            ? doneCards.map((c) => renderKanbanCard(c, 'done', false))
            : html`<div class="kanban-empty">近期还没有完成事项</div>`}
        </div>
      </div>
    </div>

    ${fin && fin.available ? section('账本', ledgerNote(fin)) : ''}
    ${routinesBlock()}
    <button class="btn quiet" data-act="open-activity">${icon('checklist')}看它替你做过的事</button>
  </div>`.s;

  bindKanbanDragEvents(root);
}

// ─── 动作事件处理（Action Router） ───
act('kanban-switch-tab', (b) => {
  activeMobileTab = b.dataset.tab || 'suggest';
  const root = document.querySelector('#page-next');
  if (root) renderNext(root);
  const targetCol = root?.querySelector(`.kanban-col[data-col="${activeMobileTab}"]`);
  targetCol?.scrollIntoView({ behavior: 'smooth', inline: 'center', block: 'nearest' });
});

act('board-quick-move', async (b) => {
  const cardId = b.dataset.id;
  const targetCol = b.dataset.to;
  const cardEl = b.closest('.kanban-card');
  const rev = cardEl ? cardEl.dataset.rev : '';
  await boardMoveCard(cardId, targetCol, rev);
});

act('board-toggle-doing', async (b) => {
  const cardId = b.dataset.id;
  const cardEl = b.closest('.kanban-card');
  const rev = cardEl ? cardEl.dataset.rev : '';
  const isDoing = cardEl && cardEl.classList.contains('is-doing');
  const targetCol = isDoing ? 'todo' : 'doing';
  await boardMoveCard(cardId, targetCol, rev);
});

act('board-refresh', async () => {
  S.nextRefreshing = true;
  const r = document.querySelector('#page-next');
  if (r) renderNext(r);
  try {
    await mutate('/personal/next/refresh');
    await load('/personal/board');
  } catch (e) {
    toast('刷新失败：' + e.message);
  } finally {
    S.nextRefreshing = false;
    const r2 = document.querySelector('#page-next');
    if (r2) renderNext(r2);
  }
});

act('board-card-detail', (b) => {
  const cardId = b.dataset.id;
  const board = D('/personal/board') || {};
  let card = null;
  for (const list of Object.values(board.columns || {})) {
    const found = (list || []).find((c) => c.id === cardId);
    if (found) { card = found; break; }
  }
  if (!card) return;
  openSheet(cardDetailView(card));
});

function cardDetailView(card) {
  return {
    title: '事项详情',
    render: () => {
      const why = (card.next && card.next.why) || (card.todo && card.todo.next_step) || '';
      const evidence = (card.next && card.next.evidence) || [];
      const sources = card.sources || [];
      return html`<div class="paper-detail land">
        <div class="row">
          ${card.column === 'doing' ? stamp('● 正在做', 'danger') : card.column === 'done' ? stamp('已完成', 'success') : stamp(card.column === 'todo' ? '待办' : '建议', 'accent')}
          ${card.urgency === 'now' ? stamp('现在办', 'warning') : ''}
          <span class="grow"></span>
          <small class="muted">${card.id}</small>
        </div>
        <h2><mark>${card.title}</mark></h2>
        ${why ? html`<div class="card inset rise" style="--d:100ms"><small class="label">背景与说明</small><p class="lined">${why}</p></div>` : ''}
        ${card.due ? html`<div class="kv tight"><span>计划结束</span><b>${card.due}</b></div>` : ''}
        ${card.completed_at > 0 ? html`<div class="kv tight"><span>完成时间</span><b>${relativeTime(card.completed_at)}</b></div>` : ''}
        ${card.todo && card.todo.project ? html`<div class="kv tight"><span>关联项目</span><b>${card.todo.project}</b></div>` : ''}
        ${card.todo && card.todo.url ? html`<div class="pad"><a class="btn secondary compact" href="${card.todo.url}">在 Obsidian 打开</a></div>` : ''}
        ${evidence.length ? section(`依据 (${evidence.length} 份)`, html`<div class="list">
          ${evidence.map((e, idx) => html`<button class="list-row" data-act="evidence-open" data-item="${card.id}" data-idx="${idx}">
            <span class="badge neutral">${icon(EV_ICON[e.kind] || 'doc')}</span>
            <span><b>${evTitle(e)}</b><small>${evSource(e)} · ${evWhen(e)}</small></span>
            ${icon('right', 'chev')}</button>`)}
        </div>`) : sources.length ? html`<p class="muted small">来源：${sources.map(evName).join(' · ')}</p>` : ''}
        <div class="row pad wrap">
          <button class="btn secondary compact" data-act="board-quick-move" data-id="${card.id}" data-to="suggest">移到建议</button>
          <button class="btn secondary compact" data-act="board-quick-move" data-id="${card.id}" data-to="todo">移到待办</button>
          <button class="btn secondary compact" data-act="board-toggle-doing" data-id="${card.id}">切换正在做</button>
          <button class="btn primary compact" data-act="board-quick-move" data-id="${card.id}" data-to="done">标记为完成</button>
        </div>
      </div>`;
    }
  };
}

// ─── 依据详情（EvidenceDetail） ───
act('evidence-open', (b) => {
  const itemId = b.dataset.item;
  const board = D('/personal/board') || {};
  let item = null;
  for (const list of Object.values(board.columns || {})) {
    const found = (list || []).find((c) => c.id === itemId || c.id === 'next:' + itemId);
    if (found) { item = found.next || found; break; }
  }
  if (!item) {
    item = nextItems().find((i) => i.id === itemId);
  }
  if (!item || !item.evidence) return;
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

onChange((keys) => {
  if (S.tab === 'next' && (keys.has('/personal/board') || keys.has('/personal/next') || keys.has('*'))) {
    const el = document.querySelector('#page-next');
    if (el) renderNext(el);
  }
});

export { pushSheet };
