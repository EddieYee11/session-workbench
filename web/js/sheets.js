// 菜单与各个弹出面板：记忆 / 账本 / 连接器 / 设置 / 搜索与成果 / 任务详情 / 任务与目标 / 派活 / 事项 / 身体 / 项目看板。
import {
  S, $, html, raw, esc, md, D, api, load, mutate, action, toast, uuid, store, refresh, refreshFlow, setTab, flowItems, decisionCount, staleItems, runningTasks,
  activeRuns, goals, tasks, brokenSources, sourceName, agentName, hostName, relativeTime, clockTime, stampLabel, statusTone, yuan, money, deliver, deliverWork,
  locateMessage, BASE, changed, onChange, nextData, persistOutbox, agencyCards, recomputeFlow,
} from './core.js';
import { icon, act, ACT, stamp, empty, notice, section, kv, rawDetails, openSheet, pushSheet, popSheet, closeSheets, confirmBox, agentAvatar } from './ui.js';
import { eventLabel, stepRow, stepState } from './chat.js';

// ─── 等你拍板的一件（PendingNote） ───
function scopeView(a) {
  if (!a || typeof a !== 'object' || !Object.keys(a).length) return '';
  const args = a.args || a;
  const labels = [['to', '收件人'], ['recipient', '接收方'], ['recipients', '接收方'], ['cc', '抄送'], ['bcc', '密送'], ['amount', '金额'], ['currency', '币种'], ['path', '路径'], ['paths', '路径'], ['id', '对象编号'], ['ids', '对象编号'], ['target', '操作对象'], ['subject', '主题'], ['summary', '事项'], ['body', '正文'], ['content', '内容'], ['command', '具体命令']];
  const rows = labels.filter(([k]) => args[k] != null && args[k] !== '').map(([k, l]) => [l, typeof args[k] === 'string' ? args[k] : JSON.stringify(args[k])]);
  return html`<div class="scope">${rows.map(([l, v]) => html`<div><small>${l}</small><p>${v}</p></div>`)}${rawDetails('查看全部操作参数', a)}</div>`;
}
export function pendingNoteHTML(it) {
  const v = it.value;
  return html`<div class="card ${it.kind === 'proposal' ? 'hl accent' : ''} pending-note" data-pid="${it.id}">
    <div class="meta">${icon(it.kind === 'proposal' ? 'desktop' : 'checklist')}<span>${[it.source, relativeTime(it.time)].filter(Boolean).join(' · ')}</span><span class="grow"></span>${stamp(it.stamp, it.tone, it.stamp === '结果未知')}</div>
    <button class="plain" data-act="pending-detail" data-id="${it.id}"><h3>${it.title}</h3>${it.detail && it.detail !== it.title ? html`<p class="sub clamp${it.kind === 'proposal' ? 4 : 2}">${it.detail}</p>` : ''}</button>
    ${it.kind === 'proposal' ? scopeView(v.actual_action) : ''}
    <div class="row actions">${it.kind === 'proposal'
      ? html`<button class="btn accent" data-act="proposal-approve" data-id="${v.id}">批准</button><button class="btn secondary" data-act="proposal-reject" data-id="${v.id}">先别</button>`
      : html`<button class="btn primary" data-act="open-task" data-id="${v.id}">${it.primary}</button><button class="btn secondary" data-act="task-dismiss" data-id="${v.id}">归档</button>`}</div></div>`;
}
act('pending-detail', (b) => {
  const it = flowItems.find((i) => i.id === b.dataset.id); if (!it) return;
  if (it.kind === 'task') openTask(it.value.id); else pushSheet(proposalView(it.value));
});
function proposalView(p) {
  return { title: '派活', render: () => html`<div class="detail-head"><h2>${p.title}</h2><p>派给 ${agentName(p.agent || 'codex')}</p>${stamp('等待批准', 'warning')}</div>
    <div class="card hl accent"><h3>要你决定</h3><div class="md">${md(p.prompt)}</div>${scopeView(p.actual_action)}
      ${p.expires_at > 0 ? html`<small class="faint">请在 ${clockTime(p.expires_at)} 前确认；过期不会执行。</small>` : ''}
      <div class="row actions"><button class="btn primary" data-act="proposal-approve" data-id="${p.id}">批准这项工作</button><button class="btn secondary" data-act="proposal-reject" data-id="${p.id}">先别</button></div></div>` };
}
act('proposal-approve', async (b) => {
  const p = ((D('/personal/work/proposals?limit=20') || {}).items || []).find((x) => x.id === b.dataset.id); if (!p) return;
  const ok = await confirmBox({ title: '批准这项工作？', message: `派给 ${agentName(p.agent || 'codex')}，在 ${p.cwd || ''} 里以「${p.sandbox || '默认'}」权限执行。`, ok: '批准', detail: html`<pre class="confirm-pre">${p.prompt || ''}</pre>` });
  if (!ok) return;
  b.disabled = true;
  if (await action('/personal/work/proposals/' + encodeURIComponent(p.id) + '/approve', { explicit_authorization: true }, 'today')) { toast('已批准，开始执行'); if (S.sheetPid) popSheet(); }
});
act('proposal-reject', async (b) => { b.disabled = true; if (await action('/personal/work/proposals/' + encodeURIComponent(b.dataset.id) + '/reject', {}, 'today')) toast('已回绝这次派活'); });
act('task-dismiss', async (b) => { b.disabled = true; try { await mutate('/personal/tasks/' + encodeURIComponent(b.dataset.id) + '/dismiss'); await load('/personal/tasks'); toast('已归档，在「已结束」里还能恢复'); } catch { b.disabled = false; } });

// ─── 菜单（点她弹出） ───
function voyageNote() {
  const c = D('/personal/cases') || {};
  if (c.waiting) return `${c.waiting} 段停下来等你`;
  if (c.active) return `${c.active} 段进行中 · 看它每一步怎么做的`;
  return 'Com 自己开的 session 和每一步操作';
}
export function menuHTML() {
  const fin = D('/personal/finance'), m = ((fin || {}).currencies || [])[0];
  const ledger = m ? `${new Date().getMonth() + 1}月已花 ${yuan(m.month_minor)}` : '本月账目';
  const broken = brokenSources();
  const conn = broken.length ? [(broken.length > 1 ? `${broken.length} 个来源` : sourceName(broken[0].name)) + '需要重新授权', true] : ['邮件、日历、账本都在读', false];
  const row = (a, ic, t, sub, warn) => html`<button class="menu-row" data-act="${a}"><i class="badge ${warn ? 'warning' : ''}">${icon(ic)}</i><span><b>${t}</b>${sub ? html`<small class="${warn ? 'warn-text' : ''}">${sub}</small>` : ''}</span></button>`;
  return html`${row('open-memory', 'brain', '记忆', '搜索、分类、纠正它记住的事')}${row('open-finance', 'card', '账本', ledger)}${row('open-connectors', 'link', '连接器', conn[0], conn[1])}${row('cases-open', 'route', '航程', voyageNote(), ((D('/personal/cases') || {}).waiting || 0) > 0)}${row('open-activity', 'checklist', '它做过的事', '记账、日程、提醒…每一步都在这')}${row('open-settings', 'sliders', '设置', '')}`;
}

// ─── 任务详情（TaskDetailView） ───
export function openTask(id) { const v = taskView(id); if (document.querySelector('#sheet.on')) pushSheet(v); else openSheet(v); }
act('open-task', (b) => openTask(b.dataset.id));
const taskState = { checked: new Set(), allEvents: false };
function taskView(id) {
  taskState.checked = new Set(); taskState.allEvents = false;
  return {
    title: '任务',
    render: () => {
      const t = tasks().find((x) => x.id === id) || (S.conv.tasks || []).find((x) => x.id === id) || flowItems.map((i) => i.value).find((x) => x.id === id);
      if (!t) return empty('这项任务不在列表里了', '可能已经归档。', 'checklist');
      const st = t.status, passed = !!t.acceptance_passed, pending = st === 'execution_finished' && !passed;
      const criteria = t.acceptance_criteria || [];
      const events = t.events || [], shown = taskState.allEvents ? events : events.slice(-5);
      const arts = (t.artifacts && t.artifacts.length ? t.artifacts : (t.structured_result || {}).artifacts) || [];
      const runtime = t.created_at > 0 && ['queued', 'running', 'dispatching', 'waiting'].includes(st) ? (() => { const m = Math.floor((Date.now() / 1000 - t.created_at) / 60); return m < 1 ? '刚开始' : `已跑 ${m} 分钟`; })() : '';
      return html`<div class="detail-head"><h2>${t.title}</h2><p>${[hostName(t.host) || 'Mac mini', agentName(t.agent), t.created_at > 0 ? clockTime(t.created_at) + ' 开始' : '', runtime].filter(Boolean).join(' · ')}</p>
        <div class="row">${stamp(stampLabel(st, passed), statusTone(st, passed), st === 'unknown')}${pending ? stamp('等你验收', 'warning') : ''}</div></div>
        ${pending ? html`<div class="card hl accent"><small class="accent-text label">要你决定</small><h3>核对完成条件，确认这次结果能不能收</h3>
          ${criteria.map((c) => html`<label class="check-line"><input type="checkbox" data-crit="${c.id}" ${taskState.checked.has(c.id) ? raw('checked') : ''}><span>${c.text || c.description || ''}</span></label>`)}
          <textarea class="field" id="taskEvidence" rows="2" placeholder="填写你实际检查的结果或证据位置"></textarea>
          <div class="row actions"><button class="btn accent" data-act="task-verify" data-id="${t.id}">确认验收通过</button>${t.workspace_copy ? html`<button class="btn secondary" data-act="task-cmd" data-cmd="merge" data-id="${t.id}" ${t.verification_status !== 'passed' ? raw('disabled') : ''}>合入成果</button>` : ''}</div></div>` : ''}
        ${events.length ? section('步骤', html`<div class="card">${shown.map((e, i) => { const last = i === shown.length - 1; return stepRow(eventLabel(e), !last ? 'done' : ['completed', 'cancelled', 'failed'].includes(st) || passed ? (st === 'failed' ? 'blocked' : 'done') : stepState(e), clockTime(e.at)); })}
          ${pending ? stepRow('等你验收后收尾', 'blocked') : ['queued', 'running', 'dispatching'].includes(st) ? stepRow('跑完后等你验收', 'pending') : ''}
          ${events.length > 5 ? html`<button class="link" data-act="task-events">${taskState.allEvents ? '收起' : `展开全部 ${events.length} 步`}</button>` : ''}</div>`) : ''}
        ${arts.length || t.result ? section('成果与证据', html`${arts.length ? artifactList(arts) : ''}${t.result ? html`<div class="card md">${md(t.result)}</div>` : ''}`) : ''}
        ${section('补充要求', html`<div class="card"><textarea class="field" id="taskSupplement" rows="2" placeholder="补充新的要求"></textarea>
          <div class="row actions"><button class="btn secondary" data-act="task-input" data-id="${t.id}">补充到这项任务</button><span class="grow"></span>
          ${['paused', 'unknown', 'cancelled', 'failed'].includes(st) ? html`<button class="btn quiet" data-act="task-cmd" data-cmd="resume" data-id="${t.id}">恢复</button>` : !['completed', 'execution_finished'].includes(st) ? html`<button class="btn quiet danger-text" data-act="task-cmd" data-cmd="cancel" data-id="${t.id}">停止</button>` : ''}</div></div>`)}
        <div class="card list">${t.structured_result ? rawDetails('结果与检查记录', t.structured_result) : ''}${rawDetails('来源与约束', { prompt: t.prompt, constraints: t.constraints, work_brief: t.work_brief })}</div>
        ${t.origin_message_id ? html`<button class="btn quiet full" data-act="task-origin" data-id="${t.id}">回到原交办消息</button>` : ''}`;
    },
    mounted: (el) => { el.querySelectorAll('[data-crit]').forEach((c) => c.addEventListener('change', () => { c.checked ? taskState.checked.add(c.dataset.crit) : taskState.checked.delete(c.dataset.crit); })); },
  };
}
act('task-events', () => { taskState.allEvents = !taskState.allEvents; changed('task'); });
async function taskCommand(id, cmd, fields = {}) {
  try { await mutate('/personal/tasks/' + encodeURIComponent(id) + '/' + cmd, fields); await refresh('today'); toast('好了'); return true; } catch { return false; }
}
act('task-cmd', (b) => taskCommand(b.dataset.id, b.dataset.cmd));
act('task-input', async (b) => { const v = $('#taskSupplement').value.trim(); if (!v) return toast('先写补充要求'); if (await taskCommand(b.dataset.id, 'input', { text: v })) $('#taskSupplement').value = ''; });
act('task-verify', async (b) => {
  const t = tasks().find((x) => x.id === b.dataset.id); if (!t) return;
  const ev = $('#taskEvidence').value.trim(), crit = t.acceptance_criteria || [];
  if (!ev) return toast('先写实际检查的结果或证据位置');
  if (taskState.checked.size !== crit.length) return toast('逐条核对完成条件再确认');
  const refs = crit.length ? crit.map((c) => ({ criterion_id: c.id, reference: ev, passed: true })) : [{ reference: ev, passed: true }];
  await taskCommand(t.id, 'verify', { explicit_acceptance: true, evidence: refs });
});
act('task-origin', async (b) => {
  const t = tasks().find((x) => x.id === b.dataset.id); if (!t) return;
  closeSheets();
  const session = t.source_session_id;
  if (session && session !== 'personal-main') ACT['work-open-session']?.({ dataset: { id: session, agent: t.agent || '', jump: t.source_message_id || '' } });
  else locateMessage(t.origin_message_id);
});

// ─── 任务与目标（TaskHubView） ───
let hubFilter = '全部';
act('open-taskhub', () => { hubFilter = '全部'; const v = { title: '任务与目标', wide: true, render: hubRender }; document.querySelector('#sheet.on') ? pushSheet(v) : openSheet(v); refresh('today'); });
act('hub-filter', (b) => { hubFilter = b.dataset.f; changed('hub'); });
function hubRender() {
  const decisions = flowItems.filter((i) => !i.stale), stale = staleItems();
  const finished = tasks().filter((t) => t.acceptance_passed || ['failed', 'cancelled', 'rejected', 'expired', 'completed'].includes(t.status)).sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0));
  const f = hubFilter, show = (k) => f === '全部' || f === k;
  const jobs = (D('/personal/automations') || {}).jobs || [];
  return html`<div class="chips seg-chips">${['全部', '等我决定', '正在跑', '目标', '已结束', '定时'].map((k) => html`<button class="chip ${k === f ? 'on' : ''}" data-act="hub-filter" data-f="${k}">${k}</button>`)}</div>
    ${show('等我决定') ? section(`等我决定 · ${decisions.length}`, html`${!decisions.length && !stale.length ? empty('眼下没有要你拍板的事', '派活待批准、停下来等你回应或验收的任务会排在这里；邮件和日程的建议在「下一步」。', 'checkCircle') : ''}
      ${decisions.map(pendingNoteHTML)}
      ${stale.length ? html`<div class="card inset"><div class="row"><i class="badge">${icon('archive')}</i><span class="grow"><b>${stale.length} 件超过一周的旧任务</b><small class="sub">${stale.slice(0, 2).map((s) => s.title).join('、')}${stale.length > 2 ? '…' : ''}</small></span></div>
        <div class="row actions"><button class="btn primary compact" data-act="archive-stale">全部归档</button></div></div>` : ''}`) : ''}
    ${show('正在跑') ? section(`正在跑 · ${runningTasks().length}`, runningTasks().length || activeRuns().length ? html`<div class="card list">
      ${activeRuns().map((r) => html`<div class="run-row"><b>主对话 · ${r.phase === 'executing' ? '正在执行工具' : '正在思考'}</b><small>Mac mini · Hermes</small><i class="ticks"></i></div>`)}
      ${runningTasks().map((t) => html`<button class="run-row" data-act="open-task" data-id="${t.id}"><span class="row between"><b>${t.title}</b><small class="faint">${t.created_at > 0 ? (() => { const m = Math.floor((Date.now() / 1000 - t.created_at) / 60); return m < 1 ? '刚开始' : m < 60 ? `已跑 ${m} 分钟` : `已跑 ${Math.floor(m / 60)} 小时 ${m % 60} 分`; })() : ''}</small></span>
        <small>${[hostName(t.host) || 'Mac mini', agentName(t.agent), (t.events || []).length ? eventLabel(t.events[t.events.length - 1]) : ''].filter((x) => x && x !== '正在处理，请稍候').join(' · ')}</small><i class="ticks"></i></button>`)}</div>` : html`<p class="sub">没有在跑的任务。</p>`) : ''}
    ${show('目标') ? section('目标', goals().length ? html`<div class="card list">${goals().map((g) => html`<div class="goal-row"><span class="row between"><b>${g.title}</b><small class="${g.status === 'blocked' ? 'warn-text' : 'faint'}">${g.status === 'blocked' ? '卡住了' : g.next_step ? '下一步 · ' + g.next_step : '持续跟进'}</small></span>${g.completion_condition ? html`<small class="sub">${g.completion_condition}</small>` : ''}</div>`)}</div>`
      : html`<div class="card row"><i class="badge accent">${icon('scope')}</i><span class="grow"><b>把一件在意的事交给我记挂</b><small class="sub">在对话里说「帮我盯着…」，它会设成目标持续跟进。</small></span></div>`) : ''}
    ${f === '已结束' ? section('已结束', finished.length ? html`<div class="card list">${finished.slice(0, 40).map((t) => html`<button class="list-row" data-act="open-task" data-id="${t.id}">${icon('checklist')}<span><b>${t.title}</b><small>${[agentName(t.agent), t.completion_condition].filter(Boolean).join(' · ')}</small></span>${stamp(stampLabel(t.status, t.acceptance_passed), statusTone(t.status, t.acceptance_passed))}</button>`)}</div>` : html`<p class="sub">还没有结束的任务。</p>`) : ''}
    ${f === '定时' ? section('定时', jobs.length ? html`${jobs.map((j) => html`<div class="card"><div class="row"><i class="badge">${icon('clock')}</i><h3>${j.name || j.title}</h3><span class="grow"></span>${stamp(j.enabled || j.status === 'active' ? '已启用' : stampLabel(j.state || j.status || 'unknown'))}</div>
      <details class="raw"><summary class="clamp2 sub">${j.prompt || ''}</summary><pre>${j.prompt || ''}</pre></details>
      <div class="row faint small">${j.schedule_display || (j.schedule && j.schedule.display) || ''}${j.next_run_at ? html`<span class="grow"></span>${icon('clock')}下次 ${new Date(j.next_run_at).toLocaleString('zh-CN', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })}` : ''}</div>
      ${j.last_error ? notice(j.last_error) : ''}</div>`)}` : html`<p class="sub">当前没有读取到定时工作。</p>`) : ''}`;
}
act('archive-stale', async (b) => {
  b.disabled = true; b.textContent = '归档中…';
  for (const it of staleItems()) { try { await mutate('/personal/tasks/' + encodeURIComponent(it.value.id) + '/dismiss'); } catch { /* toast */ } }
  await load('/personal/tasks'); toast('旧任务已归档，在「已结束」里还能恢复');
});

// ─── 事项（MatterDetailView） ───
act('open-matter', (b) => {
  let e = {}; try { e = JSON.parse(b.dataset.ev || '{}'); } catch { /* noop */ }
  import('./next.js').then((m) => pushSheet(matterView(m.matterFromEvidence(b.dataset.id, e))));
});
export function matterView(mt) {
  return {
    title: '事项',
    render: () => html`<div class="detail-head"><h2>${mt.title}</h2>${mt.what ? html`<p>${mt.what}</p>` : ''}${stamp(sourceName(mt.source))}</div>
      ${mt.next_step && mt.next_step !== '结合资料分析并提出下一步' ? html`<div class="card"><small class="label">它准备的下一步</small><p class="lined">${mt.next_step}</p></div>` : ''}
      <div class="card"><textarea class="field" id="matterGoal" rows="2" placeholder="补充要求（可选）"></textarea>
        <button class="btn primary full" data-act="matter-hand" data-id="${mt.id}">交给 Com</button>
        <div class="row">${[['关注', 'follow'], ['稍后', 'later'], ['已处理', 'handled']].map(([t, a]) => html`<button class="btn secondary compact" data-act="matter-feedback" data-a="${a}" data-id="${mt.id}">${t}</button>`)}</div></div>
      <details class="card"><summary>纠正或关闭提醒</summary><textarea class="field" id="matterFix" rows="3" placeholder="更正事实"></textarea>
        <div class="row actions"><button class="btn secondary" data-act="matter-correct" data-id="${mt.id}">保存更正</button><button class="btn quiet" data-act="matter-feedback" data-a="mute" data-id="${mt.id}">不再提醒</button></div></details>
      <div class="card list">${mt.why ? html`<details><summary>背景说明</summary><div class="md">${md(mt.why)}</div></details>` : ''}${rawDetails('查看来源事实', mt.facts)}${mt.action_context ? rawDetails('关联背景', mt.action_context) : ''}</div>
      <button class="btn quiet danger-text full" data-act="matter-unlink" data-id="${mt.id}">解除事项关联</button>`,
  };
}
act('matter-hand', async (b) => { try { await mutate('/personal/matters/' + encodeURIComponent(b.dataset.id) + '/action', { goal: $('#matterGoal').value.trim() || '分析这件事并给出下一步' }); closeSheets(); setTab('chat'); refresh('chat'); } catch { /* toast */ } });
act('matter-feedback', async (b) => { if (await action('/personal/matters/' + encodeURIComponent(b.dataset.id) + '/feedback', { action: b.dataset.a })) { refreshFlow(); toast('好了'); if (b.dataset.a !== 'follow') popSheet(); } });
act('matter-correct', async (b) => { const v = $('#matterFix').value.trim(); if (!v) return; if (await action('/personal/matters/' + encodeURIComponent(b.dataset.id) + '/feedback', { action: 'correct', text: v }, 'chat')) { refreshFlow(); toast('已保存更正'); } });
act('matter-unlink', async (b) => { if (await action('/personal/matters/' + encodeURIComponent(b.dataset.id) + '/unlink')) { refreshFlow(); popSheet(); } });

// ─── 成果（ArtifactList） ───
export function artifactList(arts) {
  return html`<div class="card list">${arts.map((a) => html`<button class="list-row" data-act="open-artifact" data-id="${a.id || ''}" data-path="${a.path || ''}" data-name="${a.name || ''}">${icon(String(a.mime || '').startsWith('image') ? 'photo' : 'doc')}<span><b>${a.name || String(a.path || '').split('/').pop()}</b><small>${a.availability === 'available' ? '预览与下载' : a.availability === 'missing' ? '文件已移动或不存在' : '核对登记后预览'}</small></span>${icon('arrowUpRight', 'chev')}</button>`)}</div>`;
}
act('open-artifact', async (b) => {
  const win = window.open('', '_blank');
  try {
    let id = b.dataset.id, name = b.dataset.name;
    if (!id.startsWith('art_')) {
      const cat = await api('/personal/artifacts');
      const found = (cat.items || []).find((x) => x.path === b.dataset.path || x.reference === b.dataset.path);
      if (!found) throw new Error('成果尚未登记，不能直接读取任意路径');
      id = found.id; name = found.name;
    }
    const res = await fetch(BASE + '/personal/artifacts/' + encodeURIComponent(id), { headers: { Authorization: 'Bearer ' + S.token } });
    if (!res.ok) throw new Error('读取失败（' + res.status + '）');
    const url = URL.createObjectURL(await res.blob());
    if (win) win.location.href = url; else { const a = document.createElement('a'); a.href = url; a.download = name || '成果'; a.click(); }
    setTimeout(() => URL.revokeObjectURL(url), 60000);
  } catch (e) { if (win) win.close(); toast(e.message); }
});

// ─── 搜索与成果 ───
let searchQ = '', searchResults = [], searchNote = '', searchTimer = 0;
act('open-search', () => { $('#plusMenu')?.classList.add('hidden'); searchQ = ''; searchResults = []; searchNote = ''; openSheet(searchView()); load('/personal/artifacts'); });
function searchView() {
  return {
    title: '搜索与成果',
    render: () => html`<label class="search-field">${icon('search')}<input id="searchInput" placeholder="聊天、任务或成果名称" value="${searchQ}" autocomplete="off"></label>
      ${searchNote ? notice(searchNote, 'neutral') : ''}
      ${!searchQ ? section('成果', ((D('/personal/artifacts') || {}).items || []).length ? artifactList(D('/personal/artifacts').items) : empty('还没有成果', 'Agent 交付的文件、图片和报告会收在这里；也可以直接搜聊天和任务。', 'tray'))
        : html`<div class="stack">${searchResults.map((r) => r.kind === 'artifact' ? artifactList([r]) : html`<button class="card result" data-act="search-open" data-kind="${r.kind}" data-id="${r.id}">${icon(r.kind === 'task' ? 'checklist' : 'message')}<span><p class="clamp4">${r.text}</p><small class="faint">${r.source || ''} · ${new Date((r.created_at || 0) * 1000).toLocaleString('zh-CN')}</small></span></button>`)}</div>`}`,
    mounted: (el) => {
      const inp = el.querySelector('#searchInput');
      inp.focus(); inp.setSelectionRange(inp.value.length, inp.value.length);
      inp.addEventListener('input', () => {
        searchQ = inp.value; clearTimeout(searchTimer);
        if (!searchQ.trim()) { searchResults = []; searchNote = ''; return; }
        searchTimer = setTimeout(async () => {
          try { const r = await api('/personal/search?q=' + encodeURIComponent(searchQ)); searchResults = r.items || []; searchNote = searchResults.length ? '' : '未找到匹配内容'; }
          catch (e) { searchNote = e.message; }
          inp.blur(); changed('search'); setTimeout(() => { const i = $('#searchInput'); if (i) { i.focus(); i.setSelectionRange(i.value.length, i.value.length); } }, 0);
        }, 300);
      });
    },
  };
}
act('search-open', async (b) => { closeSheets(); if (b.dataset.kind === 'task') { await refresh('today'); openTask(b.dataset.id); } else locateMessage(b.dataset.id); });

// ─── 账本（FinanceDetail） ───
const COLORS = ['#82A32B', '#6394D9', '#DB8C5E', '#A178C2', '#4FAB9E', '#CCA34A', '#C26B8F'];
const catColor = (c) => { const i = c.color_index || 0; return i < COLORS.length ? COLORS[Math.max(0, i)] : `hsl(${((i * 0.618) % 1) * 360} 40% 60%)`; };
const fin = { offset: 0, period: '本月', currency: '', data: null, loading: false };
const monthKey = (off) => { const d = new Date(); d.setDate(1); d.setMonth(d.getMonth() + off); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`; };
async function loadFinance() {
  fin.loading = true; changed('fin');
  fin.data = await load(fin.offset === 0 ? '/personal/finance' : '/personal/finance?month=' + monthKey(fin.offset));
  fin.loading = false; changed('fin');
}
act('open-finance', () => { fin.offset = 0; fin.period = '本月'; fin.data = D('/personal/finance'); openSheet(financeView()); loadFinance(); });
act('fin-month', (b) => { fin.offset = Math.min(0, fin.offset + Number(b.dataset.d)); fin.period = '本月'; loadFinance(); });
act('fin-period', (b) => { fin.period = b.dataset.p; changed('fin'); });
act('fin-currency', (b) => { fin.currency = b.dataset.c; changed('fin'); });
function finRows() {
  const d = fin.data || {}, cur = (d.currencies || []).find((c) => c.id === fin.currency) || (d.currencies || [])[0] || {};
  const today = new Date(); const ds = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
  const rows = (d.items || []).filter((r) => r.currency === cur.id && (fin.period !== '今天' || r.date === ds));
  const cats = (cur.categories || []).map((c) => { const items = rows.filter((r) => r.category_id === c.id); return items.length ? { ...c, amount_minor: items.reduce((n, r) => n + (r.amount_minor || 0), 0), count: items.length, items } : null; }).filter(Boolean).sort((a, b) => b.amount_minor - a.amount_minor);
  return { d, cur, rows, cats };
}
function financeView() {
  return {
    title: '支出明细',
    render: () => {
      const { d, cur, rows, cats } = finRows();
      const total = rows.reduce((n, r) => n + (r.amount_minor || 0), 0);
      let acc = 0; const pos = cats.filter((c) => c.amount_minor > 0), sum = pos.reduce((n, c) => n + c.amount_minor, 0) || 1;
      const ring = pos.map((c) => { const a = (acc / sum) * 360; acc += c.amount_minor; return `${catColor(c)} ${a + 1}deg ${(acc / sum) * 360 - 1}deg`; }).join(',');
      return html`<div class="row between month-nav"><button class="icon-btn" data-act="fin-month" data-d="-1" aria-label="上个月">${icon('left')}</button><b class="mono">${monthKey(fin.offset)}</b><button class="icon-btn" data-act="fin-month" data-d="1" ${fin.offset >= 0 ? raw('disabled') : ''} aria-label="下个月">${icon('right')}</button></div>
        ${fin.offset === 0 ? html`<div class="seg full">${['今天', '本月'].map((p) => html`<button class="${p === fin.period ? 'on' : ''}" data-act="fin-period" data-p="${p}">${p}</button>`)}</div>` : ''}
        ${(d.currencies || []).length > 1 ? html`<div class="seg">${d.currencies.map((c) => html`<button class="${c.id === cur.id ? 'on' : ''}" data-act="fin-currency" data-c="${c.id}">${c.id}</button>`)}</div>` : ''}
        ${fin.loading && !fin.data ? html`<div class="skeleton"></div>` : !d.available ? empty('暂时未读到账本', d.note || S.errors['/personal/finance'] || '', 'wifiOff') : html`
          <div class="card row fin-top"><div class="donut ${pos.length ? '' : 'none'}" style="background:${raw(pos.length ? `conic-gradient(${ring})` : 'var(--fill)')}"><span><small>${pos.length ? '花在哪里' : '还未记账'}</small><em>${cats.length} 个分类</em></span></div>
            <div><small class="muted">${fin.period === '今天' ? '今日花销' : '本月花销'}</small><h2 class="mono">${money(total, cur.id)}</h2><small class="muted">${rows.length} 笔支出</small></div></div>
          ${section('分类排行', cats.length ? html`${cats.map((c, i) => html`<button class="card cat" data-act="fin-cat" data-id="${c.id}"><div class="row"><small class="mono faint">${String(i + 1).padStart(2, '0')}</small><i class="dot" style="background:${catColor(c)}"></i><b>${c.name}</b><span class="grow"></span><b class="mono">${money(c.amount_minor, cur.id)}</b>${icon('right', 'chev')}</div>
            <div class="bar"><i style="width:${(c.amount_minor / Math.max(1, cats[0].amount_minor)) * 100}%;background:${catColor(c)}"></i></div><small class="faint">${c.count} 笔 · ${c.group || ''}</small></button>`)}` : empty('这段时间还没有支出', '在聊天中记一笔，账本会自动更新到这里。', 'tray'))}
          <p class="faint small">${d.stale ? '当前是上次读取的账本，暂未更新。' : d.coverage || ''}</p>`}`;
    },
  };
}
act('fin-cat', (b) => {
  const { cur, cats } = finRows(); const c = cats.find((x) => x.id === b.dataset.id); if (!c) return;
  const groups = {}; for (const r of c.items) (groups[r.date] = groups[r.date] || []).push(r);
  pushSheet({ title: c.name, render: () => html`<div class="row"><i class="dot" style="background:${catColor(c)}"></i><span>${c.count} 笔支出</span><span class="grow"></span><h2 class="mono">${money(c.amount_minor, cur.id)}</h2></div>
    ${Object.keys(groups).sort().reverse().map((day) => section(day, html`<div class="card list">${groups[day].map((r) => html`<div class="tx"><span class="row between"><b>${r.comment || r.category}</b><b class="mono">${money(r.amount_minor, cur.id)}</b></span><small class="faint">${String(r.time || '').slice(11, 16)} · ${r.account || ''}</small></div>`)}</div>`))}` });
});

// ─── 连接器 ───
const CONN_STATUS = { connected: '已连接', disconnected: '已断开', needs_connection: '未连接', not_synced: '未检查', unavailable: '暂不可用' };
const CONN_ICON = { gmail: 'envelope', work_mail: 'envelope', github: 'desktop', apple_calendar: 'calendar', phone_calendar: 'calendar', google_calendar: 'calendar', accounting: 'card', garmin: 'heart', phone_health: 'heart', phone_reminders: 'bell', sms: 'message', plaud: 'waveform', weather: 'cloud' };
const sources = () => (D('/personal/connectors') || {}).sources || [];
act('open-connectors', () => { openSheet({ title: '数据连接', render: () => html`<p class="sub">连接你的数据，让 Com 更了解你。</p>
  <div class="card list">${sources().map((s) => html`<button class="list-row" data-act="open-connector" data-name="${s.name}"><i class="badge ${s.status === 'connected' ? 'success' : ''}">${icon(CONN_ICON[s.name] || 'link')}</i><span><b>${sourceName(s.name)}</b><small>${s.status === 'connected' ? '查看连接与同步' : '点击配置或重试'}</small></span>${stamp(CONN_STATUS[s.status] || '待核实', s.status === 'connected' ? 'success' : 'neutral')}${icon('right', 'chev')}</button>`)}</div>
  ${notice(S.errors['/personal/connectors'])}` }); load('/personal/connectors'); });
const connForm = { kind: 'ews', note: '', busy: false };
act('open-connector', (b) => {
  const name = b.dataset.name; connForm.note = ''; connForm.kind = 'ews';
  const v = { title: sourceName(name), render: () => connectorRender(name) };
  document.querySelector('#sheet.on') ? pushSheet(v) : openSheet(v);
});
function connectorRender(name) {
  const cur = sources().find((s) => s.name === name) || { name };
  const ok = cur.status === 'connected';
  const creds = !ok && ['work_mail', 'garmin'].includes(name) && cur.status !== 'disconnected';
  return html`<div class="card row"><i class="badge ${ok ? 'success' : ''}">${icon(CONN_ICON[name] || 'link')}</i><h2 class="grow">${sourceName(name)}</h2>${stamp(CONN_STATUS[cur.status] || '待核实', ok ? 'success' : 'neutral')}</div>
    ${connForm.note ? notice(connForm.note, 'neutral') : ''}
    ${creds ? section('账号', html`<div class="card form">
      ${name === 'work_mail' ? html`<div class="seg full">${[['ews', 'Exchange（OWA）'], ['imap', 'IMAP']].map(([k, t]) => html`<button class="${connForm.kind === k ? 'on' : ''}" data-act="conn-kind" data-k="${k}">${t}</button>`)}</div>
        <input class="field" id="cHost" value="mail.sohu-inc.com" placeholder="${connForm.kind === 'ews' ? '服务器，如 mail.sohu-inc.com' : 'IMAP 服务器'}">
        ${connForm.kind === 'ews' ? html`<input class="field" id="cEmail" placeholder="邮箱地址，如 name@sohu-inc.com" autocomplete="off">` : ''}`
        : html`<select class="field" id="cRegion"><option value="garmin.cn">中国区</option><option value="garmin.com">国际区</option></select>`}
      <input class="field" id="cUser" placeholder="${name === 'work_mail' && connForm.kind === 'ews' ? '域账号（登录 OWA 用的那个）' : '账号'}" autocomplete="off">
      <input class="field" id="cPass" type="password" placeholder="${name === 'work_mail' ? (connForm.kind === 'ews' ? '邮箱密码' : '邮箱专用密码') : '密码'}" autocomplete="new-password">
      ${name === 'work_mail' && connForm.kind === 'ews' ? html`<small class="faint">搜狐邮箱不开 IMAP，走 Exchange 的 EWS 接口读收件箱邮件头，不改已读状态。密码直接发给 mini 保存，不进聊天记录。</small>` : ''}
      <button class="btn primary full" data-act="conn-update" data-name="${name}" data-creds="1">连接</button></div>`)
      : !ok ? html`${name === 'gmail' || name === 'google_calendar' ? html`<p class="sub">首次连接需在 Mac mini 完成 Google 授权，然后点击检查连接。</p>` : ''}<button class="btn primary full" data-act="conn-update" data-name="${name}">${cur.status === 'disconnected' ? '重新连接' : '检查连接'}</button>` : ''}
    ${ok ? html`<button class="btn secondary danger-text full" data-act="conn-update" data-name="${name}" data-off="1">断开同步</button><small class="faint">停止 Com 后续读取；保留既有资料及其他 App 的授权。</small>` : ''}
    ${connForm.busy ? html`<p class="sub"><i class="spin"></i> 正在核验连接</p>` : ''}
    ${cur.error ? html`<details class="raw"><summary>诊断详情</summary><pre>${cur.error}</pre></details>` : ''}
    ${cur.coverage ? html`<p class="faint small">${cur.coverage}${cur.updated_at ? ' · 更新于 ' + relativeTime(cur.updated_at) : ''}</p>` : ''}`;
}
act('conn-kind', (b) => { connForm.kind = b.dataset.k; changed('conn-form'); });
act('conn-update', async (b) => {
  const name = b.dataset.name, enabled = !b.dataset.off, fields = { enabled };
  if (b.dataset.creds) {
    fields.username = $('#cUser').value.trim(); fields.password = $('#cPass').value;
    if (!fields.username || !fields.password) return toast('先填账号和密码');
    if (name === 'work_mail') { fields.host = $('#cHost').value.trim(); fields.protocol = connForm.kind; if (connForm.kind === 'ews') fields.email = $('#cEmail').value.trim(); }
    else fields.domain = $('#cRegion').value;
  }
  if (!enabled && !(await confirmBox({ title: '断开 ' + sourceName(name) + '？', message: '停止 Com 后续读取；保留既有资料及其他 App 的授权。', ok: '断开', danger: true }))) return;
  connForm.busy = true; changed('conn-form');
  try {
    await api('/personal/connectors/' + encodeURIComponent(name), { body: fields });
    if (enabled) await mutate('/personal/sync', { group: name });
    await load('/personal/connectors'); load('/personal/briefing');
    const now = sources().find((s) => s.name === name);
    connForm.note = enabled ? (now && now.status === 'connected' ? '连接已核验' : '尚未连接，请检查授权或账号') : '已停止此来源同步';
  } catch (e) { connForm.note = '操作未完成：' + e.message; }
  connForm.busy = false; changed('conn-form');
});

// ─── 设置 ───
act('open-settings', () => openSheet({ title: '设置', render: settingsRender }));
function settingsRender() {
  const theme = store.get('com.theme', 'system');
  const h = D('/health') || {};
  const perm = 'Notification' in window ? Notification.permission : 'unsupported';
  return html`${section('外观', html`<div class="card"><div class="row between"><span>主题</span><div class="seg">${[['system', '跟随系统'], ['light', '浅色'], ['dark', '深色']].map(([k, t]) => html`<button class="${k === theme ? 'on' : ''}" data-act="set-theme" data-t="${k}">${t}</button>`)}</div></div><small class="faint">减少动态效果跟随系统设置。</small></div>`)}
    ${section('新消息通知', html`<div class="card"><div class="row between"><span>${perm === 'granted' ? '已开启：这页在后台时，有新回复或要你确认会弹系统通知' : perm === 'denied' ? '浏览器拒绝了通知，请在地址栏左侧的网站设置里允许' : perm === 'unsupported' ? '这个浏览器不支持通知' : '开启后，这页在后台时有新回复会提醒你'}</span>
      ${perm === 'default' ? html`<button class="btn secondary compact" data-act="enable-notify">开启</button>` : ''}</div></div>`)}
    ${section('连接', html`<div class="card list">${kv('服务', location.origin + BASE)}${kv('实时对话', S.streaming ? '已连接' : '缓存模式')}${kv('后端版本', h.version ? `${h.version} · ${String(h.build_commit || '').slice(0, 7)}` : '')}${kv('执行模式', h.main_operation_mode)}
      <button class="list-row" data-act="refresh-all">${icon('refresh')}<span><b>刷新连接</b></span></button></div>`)}
    ${section('数据来源', html`<div class="card list"><button class="list-row" data-act="open-connector-list">${icon('link')}<span><b>管理数据连接</b></span>${icon('right', 'chev')}</button></div>`)}
    ${section('发送记录', S.pending.length ? html`<div class="card list">${[...S.pending].reverse().slice(0, 30).map((e) => html`<div class="outbox"><p class="clamp3">${e.text || '恢复工作会话'}</p><small class="faint">${e.note} · ${new Date(e.createdAt * 1000).toLocaleString('zh-CN')}</small>
      ${['uncertain', 'checking'].includes(e.state) ? html`<button class="link" data-act="outbox-receipt" data-id="${e.id}">查询原请求回执</button>` : ''}
      ${e.state === 'rejected' ? html`<button class="link" data-act="outbox-restore" data-id="${e.id}">恢复文字到聊天草稿</button>` : ''}</div>`)}</div>` : html`<p class="sub">还没有本机发送记录</p>`)}
    ${section('快捷键', html`<div class="card list">${kv('聚焦输入框', '⌘K')}${kv('切换四页', '⌘1 – ⌘4')}${kv('搜索与成果', '⌘F')}${kv('关闭面板', 'Esc')}</div>`)}
    <button class="btn secondary danger-text full" data-act="unpair">解除本机配对</button>`;
}
act('set-theme', (b) => { store.set('com.theme', b.dataset.t); document.documentElement.dataset.theme = b.dataset.t === 'system' ? '' : b.dataset.t; if (b.dataset.t === 'system') delete document.documentElement.dataset.theme; changed('theme'); });
act('enable-notify', async () => { try { await Notification.requestPermission(); } catch { /* noop */ } changed('settings'); });
act('refresh-all', async () => { toast('正在刷新…'); await Promise.all([refresh('chat'), refresh(S.tab)]); toast('已刷新'); });
act('open-connector-list', () => ACT['open-connectors']());
act('outbox-receipt', (b) => { const e = S.pending.find((x) => x.id === b.dataset.id); if (e) (e.path.startsWith('/sessions') ? deliverWork : deliver)(e.id); });
act('outbox-restore', (b) => { const e = S.pending.find((x) => x.id === b.dataset.id); if (!e) return; S.draft = e.text; S.pending = S.pending.filter((x) => x.id !== e.id); persistOutbox(); closeSheets(); setTab('chat'); changed('composer'); });

// ─── 身体详情 ───
act('open-health', () => { openSheet({ title: '身体', render: healthRender }); load('/personal/health?days=7'); });
function healthRender() {
  const h = D('/personal/health?days=7') || ((D('/personal/today') || {}).health) || {};
  const days = h.days || [];
  const rows = [['睡眠', (m) => (m.sleep_seconds ? (m.sleep_seconds / 3600).toFixed(1) + 'h' : '—')], ['睡眠分', (m) => m.sleep_score ?? '—'], ['HRV', (m) => m.hrv_last_night ?? '—'], ['准备度', (m) => m.readiness_score ?? '—'], ['静息心率', (m) => m.resting_heart_rate ?? '—'], ['压力', (m) => m.avg_stress ?? '—'], ['步数', (m) => (m.steps != null ? Math.round(m.steps).toLocaleString() : '—')], ['起床电量', (m) => (m.body_battery_at_wake != null ? Math.round(m.body_battery_at_wake) : '—')]];
  if (!days.length) return S.errors['/personal/health?days=7'] ? notice(S.errors['/personal/health?days=7']) : html`<div class="skeleton"></div>`;
  return html`<div class="card scroll-x"><table class="htable"><thead><tr><th></th>${days.map((d) => html`<th>${String(d.date || '').slice(5)}</th>`)}</tr></thead>
    <tbody>${rows.map(([t, f]) => html`<tr><th>${t}</th>${days.map((d) => html`<td>${f(d.measurements || {})}</td>`)}</tr>`)}</tbody></table></div>
    <p class="faint small">Garmin 每半小时同步一次${((h.sources || {}).garmin || {}).updated_at ? ' · 更新于 ' + relativeTime(h.sources.garmin.updated_at) : ''}</p>`;
}

// ─── 记忆（MemoryView） ───
const FOLDER = { 关于我: ['ABOUT ME', 'person', '#6B8C1A'], 工作: ['WORK', 'briefcase', '#2F6BD8'], 创作: ['CREATIVE', 'video', '#F06E57'], 技能: ['SKILLS', 'wrench', '#8C54F2'], 设备: ['DEVICES', 'desktop', '#338C99'], 项目: ['PROJECTS', 'stack', '#DB8C14'], 生活: ['LIFE', 'leaf', '#2E9A58'], 财务: ['MONEY', 'yen', '#2E9959'], 健康: ['HEALTH', 'heart', '#2E9A58'], 兴趣: ['HOBBIES', 'leaf', '#2E9A58'], 人物关系: ['PEOPLE', 'people', '#D9618C'], 人物: ['PEOPLE', 'people', '#D9618C'], 偏好: ['TASTE', 'heart', '#E65C66'], 习惯: ['HABITS', 'repeat', '#4080D9'] };
const BLURB = { 关于我: '身份、称呼和协作偏好', 工作: '搜狐、求职与职业发展', 创作: '视频号、素材与发布口径', 技能: '自动化、工程与排障方法', 设备: '电脑、手机、NAS 与网络', 项目: 'Agent 系统与在做的工程', 生活: '记账、提醒、健康与兴趣' };
const folderOf = (m) => m.folder || ({ 兴趣: '生活', 健康: '生活', 财务: '生活' })[m.category] || m.category || '生活';
const memPreview = (m) => m.preview || String(m.summary || m.content || '').replace(/\*\*|`/g, '').split('\n').map((l) => l.trim().replace(/^[-*#> ]+/, '')).filter(Boolean).join(' ');
const memTitle = (m) => { if (m.title) return m.title; const f = (memPreview(m).split(/[。；！？\n]/)[0] || ''); return f.length > 24 ? f.slice(0, 23) + '…' : f; };
const MARK = { learned: ['自动学到', 'check'], pending: ['待确认', 'dots'], corrected: ['已纠正', 'pencil'], shared: ['共享知识', 'doc'], plain: ['对话中记住', 'message'] };
const memState = { filter: '全部', q: '', hidden: new Set(), undo: null, timers: {}, editing: '' };
function papers() {
  const items = (D('/personal/memory') || {}).items || [], inbox = D('/personal/memory-inbox') || {};
  const learnedIDs = new Set((inbox.learned || []).map((x) => x.memory_id).filter(Boolean));
  const out = items.map((m) => ({ id: m.id, title: memTitle(m), folder: folderOf(m), updated: m.updated_at || 0, value: m,
    mark: m.read_only || m.kind === 'knowledge' ? 'shared' : (m.version > 1 || (m.history || []).length) ? 'corrected' : ((m.source || {}).type === 'auto_learned' || learnedIDs.has(m.id)) ? 'learned' : 'plain' }));
  for (const p of inbox.pending || []) out.push({ id: p.id, title: p.content, folder: folderOf(p), updated: p.created_at || 0, value: p, mark: 'pending' });
  return out.filter((p) => !memState.hidden.has(p.id)).sort((a, b) => b.updated - a.updated);
}
const keeps = (p) => memState.filter === '全部' || (memState.filter === '自动学到' ? p.mark === 'learned' : p.mark === 'pending');
act('open-memory', () => { memState.filter = '全部'; memState.q = ''; openSheet({ title: '记忆', wide: true, render: memoryHome, mounted: bindMemSearch }); load('/personal/memory'); load('/personal/memory-inbox'); });
act('mem-filter', (b) => { memState.filter = b.dataset.f; changed('mem'); });
function bindMemSearch(el) {
  const i = el.querySelector('#memSearch'); if (!i) return;
  i.addEventListener('input', () => { memState.q = i.value; const box = el.querySelector('#memResults'); if (box) box.innerHTML = memResults().s; });
}
function memResults() {
  const q = memState.q.trim().toLowerCase(); if (!q) return html``;
  const hits = papers().filter((p) => (p.title + ' ' + memPreview(p.value)).toLowerCase().includes(q)).slice(0, 40);
  return hits.length ? html`<div class="card list">${hits.map(paperRow)}</div>` : html`<p class="sub">没找到「${memState.q}」</p>`;
}
const paperRow = (p) => html`<button class="list-row paper ${p.mark}" data-act="${p.mark === 'pending' ? 'mem-learned' : 'mem-item'}" data-id="${p.id}"><i class="mark ${p.mark}">${icon(MARK[p.mark][1])}</i><span><b>${p.title}</b><small>${[p.folder, MARK[p.mark][0], relativeTime(p.updated)].filter(Boolean).join(' · ')}</small></span>${icon('right', 'chev')}</button>`;
function memoryHome() {
  const all = papers(), shown = all.filter(keeps), groups = {};
  for (const p of shown) (groups[p.folder] = groups[p.folder] || []).push(p);
  const remote = ((D('/personal/memory') || {}).folders || []).map((f) => f.name);
  const order = (remote.length ? remote : Object.keys(BLURB)).concat(Object.keys(groups).filter((k) => !(remote.length ? remote : Object.keys(BLURB)).includes(k)).sort());
  const inbox = D('/personal/memory-inbox') || {};
  const nL = (inbox.learned || []).filter((x) => !memState.hidden.has(x.id)).length, nP = (inbox.pending || []).filter((x) => !memState.hidden.has(x.id)).length;
  if (!D('/personal/memory')) return S.errors['/personal/memory'] ? notice('记忆没读到：' + S.errors['/personal/memory']) : html`<p class="sub">正在读取记忆…</p><div class="skeleton"></div><div class="skeleton"></div>`;
  return html`<div class="row between mem-head"><h2>${all.length} 条</h2></div>
    <div class="chips">${['全部', '自动学到', '待确认'].map((k) => html`<button class="chip ${k === memState.filter ? 'on' : ''}" data-act="mem-filter" data-f="${k}">${k}</button>`)}</div>
    <label class="search-field">${icon('search')}<input id="memSearch" placeholder="搜索记忆" value="${memState.q}"></label>
    <div id="memResults">${memResults()}</div>
    ${!memState.q && (nL || nP) ? html`<button class="card tip" data-act="mem-learned">${icon('sparkles')}<span class="grow">最近自动学到 <mark>${nL}</mark> 条${nP ? html`，<mark>${nP}</mark> 条等你确认` : ''}</span><b class="accent-text">去过目</b>${icon('right', 'chev')}</button>` : ''}
    ${memState.q ? '' : shown.length ? html`<div class="folders">${order.filter((n) => groups[n]).map((n, i) => { const f = FOLDER[n] || ['NOTES', 'leaf', '#2E9A58']; const ps = groups[n];
      return html`<button class="folder" style="--tint:${f[2]};--i:${i}" data-act="mem-folder" data-name="${n}"><span class="papers">${ps.slice(0, 3).map((p, j) => html`<i class="pp ${p.mark}" style="--j:${j}"></i>`)}</span><span class="face"><em>${f[0]}</em><i class="sticker">${icon(f[1])}</i></span><span class="name"><b>${n}</b><small>${ps.length} 条${BLURB[n] ? ' · ' + BLURB[n] : ''}</small></span></button>`; })}</div>`
      : empty(memState.filter === '待确认' ? '没有等你确认的' : memState.filter === '自动学到' ? '还没有自动学到的' : '还没有记忆', '聊到新的偏好、习惯或在做的事，它会自动记下，再放到这里给你过目。', 'checkCircle')}
    ${notice(S.errors['/personal/memory'])}`;
}
act('mem-folder', (b) => { const n = b.dataset.name; pushSheet({ title: n, render: () => { const ps = papers().filter((p) => p.folder === n && keeps(p)); return ps.length ? html`<div class="card list">${ps.map(paperRow)}</div>` : empty('这个文件夹空了', '', 'folder'); } }); });
act('mem-item', (b) => { memState.editing = ''; const id = b.dataset.id; pushSheet({ title: '记忆', render: () => memItem(id) }); });
function memItem(id) {
  const m = ((D('/personal/memory') || {}).items || []).find((x) => x.id === id);
  if (!m) return empty('这条记忆不在了', '可能刚被整理或归档。', 'folder');
  const f = FOLDER[folderOf(m)] || ['NOTES', 'leaf', '#2E9A58'];
  const ro = m.read_only || m.kind === 'knowledge';
  const src = m.source || {};
  return html`<div class="row"><span class="folder-chip" style="--tint:${f[2]}">${icon(f[1])}${folderOf(m)}</span>${stamp(ro ? '共享知识' : '对话中记住', ro ? 'neutral' : 'accent')}</div>
    ${m.kind === 'knowledge' || String(m.content || '').length > 60 ? html`<h2>${memTitle(m)}</h2>` : ''}
    ${m.updated_at ? html`<small class="faint">更新于 ${relativeTime(m.updated_at)}</small>` : ''}
    ${memState.editing === id ? html`<textarea class="field big" id="memEdit" rows="10">${m.content || ''}</textarea><div class="row actions"><button class="btn secondary" data-act="mem-edit-cancel">取消</button><button class="btn primary" data-act="mem-save" data-id="${id}">保存纠正</button></div>`
      : html`<div class="card md">${md(m.content)}</div>${ro ? '' : html`<button class="btn secondary" data-act="mem-edit" data-id="${id}">${icon('pencil')}纠正这条记忆</button>`}`}
    <small class="faint">${ro ? '来自共享知识库，来源文件更新后会自动同步。' : '保存时核对版本，旧内容与来源会保留。'}</small>
    <div class="card list">${src.path ? html`<details><summary>原始来源</summary><pre class="code">${src.path}</pre></details>` : src.quote ? html`<details><summary>你当时说的</summary><p class="lined">${src.quote}</p></details>` : rawDetails('原始来源', src)}
      ${(m.history || []).length ? html`<details><summary>历史版本</summary>${m.history.map((o) => html`<small class="faint">历史版本 ${o.version}</small><div class="md">${md(o.content)}</div>`)}</details>` : ''}</div>`;
}
act('mem-edit', (b) => { memState.editing = b.dataset.id; changed('mem'); setTimeout(() => $('#memEdit')?.focus(), 30); });
act('mem-edit-cancel', () => { memState.editing = ''; changed('mem'); });
act('mem-save', async (b) => {
  const m = ((D('/personal/memory') || {}).items || []).find((x) => x.id === b.dataset.id); const text = $('#memEdit').value.trim(); if (!m || !text) return;
  b.disabled = true;
  try { await mutate('/personal/memory/' + encodeURIComponent(m.id), { content: text, expected_version: m.version }); memState.editing = ''; await load('/personal/memory'); toast('已保存纠正'); popSheet(); } catch { b.disabled = false; }
});
// 自动学到 / 待确认：没错（记住）· 纠正 · 删掉（不用，4 秒内可撤销）
act('mem-learned', () => { memState.editing = ''; pushSheet({ title: '自动记忆', render: learnedRender }); load('/personal/memory-inbox'); });
function learnedRender() {
  const inbox = D('/personal/memory-inbox') || {};
  const card = (x, pending) => html`<div class="card paper-card ${pending ? 'pending' : ''}" data-lid="${x.id}"><small class="faint">${folderOf(x)} · ${relativeTime(x.created_at)}</small>
    ${memState.editing === x.id ? html`<textarea class="field" id="learnEdit" rows="3">${x.content}</textarea><div class="row actions"><button class="btn secondary compact" data-act="mem-edit-cancel">取消</button><button class="btn primary compact" data-act="learn-act" data-a="correct" data-id="${x.id}">改好了</button></div>`
      : html`<p class="lead">${x.content}</p>${x.quote ? html`<p class="lined faint">「${x.quote}」</p>` : ''}
      <div class="row actions"><button class="btn primary compact" data-act="learn-act" data-a="confirm" data-id="${x.id}">${icon('check')}${pending ? '记住' : '没错'}</button><button class="btn secondary compact" data-act="learn-edit" data-id="${x.id}">${icon('pencil')}纠正</button><span class="grow"></span><button class="btn quiet" data-act="learn-del" data-id="${x.id}">${pending ? '不用' : '删掉'}</button></div>`}</div>`;
  const pend = (inbox.pending || []).filter((x) => !memState.hidden.has(x.id)), learned = (inbox.learned || []).filter((x) => !memState.hidden.has(x.id));
  return html`${pend.length ? section('等你确认 · ' + pend.length, html`${pend.map((x) => card(x, true))}`) : ''}
    ${learned.length ? section('最近自动学到 · ' + learned.length, html`${learned.map((x) => card(x, false))}`) : ''}
    ${!pend.length && !learned.length ? empty('都过目了', '聊到新的偏好、习惯，它会自动记下，再放到这里给你过目。', 'checkCircle') : ''}
    ${memState.undo ? html`<div class="undo-inline"><span>已删掉 · ${memState.undo.title}</span><button data-act="learn-undo">撤销</button></div>` : ''}`;
}
act('learn-edit', (b) => { memState.editing = b.dataset.id; changed('mem'); setTimeout(() => $('#learnEdit')?.focus(), 30); });
async function learnAct(id, a, content = '') {
  try { await mutate('/personal/memory-inbox/' + encodeURIComponent(id), { action: a, content }); } catch { /* toast */ }
  await Promise.all([load('/personal/memory-inbox'), load('/personal/memory')]);
}
act('learn-act', async (b) => {
  const id = b.dataset.id, a = b.dataset.a, content = a === 'correct' ? ($('#learnEdit')?.value || '').trim() : '';
  if (a === 'correct' && !content) return;
  const el = b.closest('.paper-card'); el?.classList.add('stamped'); el?.setAttribute('data-stamp', a === 'correct' ? '改好了' : '记住了');
  memState.editing = '';
  setTimeout(async () => { memState.hidden.add(id); changed('mem'); await learnAct(id, a, content); memState.hidden.delete(id); changed('mem'); }, 520);
});
act('learn-del', (b) => {
  const id = b.dataset.id, inbox = D('/personal/memory-inbox') || {};
  const x = (inbox.learned || []).concat(inbox.pending || []).find((y) => y.id === id); if (!x) return;
  const ids = [id, x.memory_id].filter(Boolean); ids.forEach((i) => memState.hidden.add(i));
  memState.undo = { id, title: x.content, ids }; changed('mem');
  clearTimeout(memState.timers[id]);
  memState.timers[id] = setTimeout(async () => { if (memState.undo && memState.undo.id === id) memState.undo = null; await learnAct(id, 'delete'); ids.forEach((i) => memState.hidden.delete(i)); changed('mem'); }, 4000);
});
act('learn-undo', () => { const u = memState.undo; if (!u) return; clearTimeout(memState.timers[u.id]); u.ids.forEach((i) => memState.hidden.delete(i)); memState.undo = null; changed('mem'); });

// ─── 项目看板 ───
act('open-board', (b) => openSheet({ title: '项目看板', wide: true, render: () => boardRender(b.dataset.host || 'mini') }));
function boardRender(host) {
  const d = D('/personal/projects') || {};
  const projects = (d.projects || []).map((p) => ({ ...p, items: (p.items || []).filter((i) => i.host === host) })).filter((p) => p.items.length).sort((a, b) => (b.updated_at || 0) - (a.updated_at || 0));
  if (!projects.length) return D('/personal/projects') ? empty('这台电脑上还没有整理过的项目', '', 'layers') : html`<div class="skeleton"></div>`;
  return html`${projects.slice(0, 40).map((p) => html`<div class="card"><div class="row between"><h3>${p.title}</h3><small class="faint">${relativeTime(p.updated_at)}</small></div>
    ${p.items.slice(0, 4).map((i) => html`<button class="list-row" data-act="work-open-item" data-id="${i.id}">${agentAvatar(i.agent, 28)}<span><b>${String(i.title || '').startsWith('<') ? (i.summary || p.title) : i.title}</b><small>${i.summary && i.summary !== '等待下一轮整理' ? i.summary : ''}${i.next_step ? ' · 下一步：' + i.next_step : ''}</small></span>${icon('right', 'chev')}</button>`)}</div>`)}`;
}
act('open-board-item', (b) => ACT['work-open-item']?.(b));

onChange((keys) => { if (keys.has('/personal/memory') || keys.has('/personal/memory-inbox')) recomputeFlow; });
export { esc, uuid, raw, nextData, decisionCount, agencyCards };

// ─── 它做过的事（ActivityView）：结果不确定的点一下告诉它 ───
const ACT_STATE = { completed: ['checkCircle', 'success', '做成了'], confirmed: ['checkCircle', 'success', '你确认做成了'], failed: ['x', 'danger', '失败'], not_done: ['warning', 'neutral', '你说没做成'], disputed: ['warning', 'danger', '你标了做错'] };
function activityView() {
  return {
    title: '它做过的事',
    render: () => {
      const d = D('/personal/activity') || {}, items = d.items || [], pushes = d.wechat || [];
      return html`<p class="muted small">记账、日程、提醒、改文件……每一步都在这。结果不确定的点一下告诉它，做错的标出来，它会记住。</p>
        ${!D('/personal/activity') ? html`<div class="skeleton"></div>` : items.length ? html`<div class="card list">${items.map((e) => {
          const [ic, tone, label] = ACT_STATE[e.state] || ['hourglass', 'warning', '结果不确定'];
          return html`<div class="list-row act-row"><i class="badge ${tone}">${icon(ic)}</i><span class="grow"><b>${e.summary}</b><small>${[e.at > 0 ? relativeTime(e.at) : '', e.source ? '来自：' + e.source : ''].filter(Boolean).join(' · ')}</small>
            <span class="row actions">${[['done', '做成了'], ['not_done', '没做成'], ['wrong', '做错了']].map(([v, t]) => html`<button class="btn quiet compact" data-act="activity-verdict" data-key="${e.key}" data-v="${v}">${t}</button>`)}</span></span>${stamp(label, tone)}</div>`;
        })}</div>` : empty('还没有记录', '它替你动手做过的事会按时间列在这里。', 'checklist')}
        ${pushes.length ? section('发到微信的提醒', html`<div class="card list">${pushes.map((p) => html`<div class="list-row"><i class="badge ${p.state === 'sent' ? 'success' : 'warning'}">${icon('message')}</i><span class="grow"><b>${String(p.text || '').split('\n')[0]}</b><small>${relativeTime(p.at)}${p.state === 'sent' ? '' : ' · 没发出去'}</small></span></div>`)}</div>`) : ''}`;
    },
  };
}
act('open-activity', () => { closeSheets(); setTimeout(() => { openSheet(activityView()); load('/personal/activity'); }, 280); });
act('activity-verdict', async (b) => {
  b.disabled = true;
  try { await mutate('/personal/activity/' + encodeURIComponent(b.dataset.key), { verdict: b.dataset.v }); await load('/personal/activity'); toast('记下了'); } catch { b.disabled = false; }
});
