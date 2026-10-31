// 聊天消息里的结构化组件（助手消息的 widgets）：只产出 HTML 字符串，不碰 DOM、不发请求，方便单独测试。
// 模型给的文字一律走 html`` 模板转义（等价 textContent），绝不拼进 innerHTML。交互在 chat.js 里接。
import { html, raw, esc } from './core.js';

export const KNOWN = new Set(['checklist', 'choices', 'table', 'chart', 'steps', 'form', 'html']);
export const widgetKey = (messageId, index) => `widget:${messageId}:${index}`;
export const stateful = (w) => w && ['checklist', 'choices', 'form'].includes(w.type);
export const usable = (w) => !!w && typeof w === 'object' && KNOWN.has(w.type);

const str = (v) => (v == null ? '' : String(v));
const optLabel = (o) => (o && typeof o === 'object' ? str(o.label ?? o.text ?? o.value) : str(o));
const submitLabel = (s, dflt) => (typeof s === 'string' && s.trim() ? s.trim() : dflt);

// ─── 表格：数字列按数值排序 ───
const num = (v) => { const s = str(v).replace(/[,\s¥$￥€%]/g, ''); return s !== '' && Number.isFinite(Number(s)) ? Number(s) : null; };
export function numericColumn(rows, c) {
  const cells = rows.map((r) => cell(r, c)).filter((v) => str(v).trim() !== '');
  return cells.length > 0 && cells.every((v) => num(v) !== null);
}
const colLabel = (c) => (c && typeof c === 'object' ? str(c.label ?? c.title ?? c.key) : str(c));
function cell(row, ci, cols) {
  if (Array.isArray(row)) return row[ci];
  if (row && typeof row === 'object') { const c = cols && cols[ci]; const k = c && typeof c === 'object' ? c.key : c; return row[k]; }
  return ci === 0 ? row : '';
}
export function sortedRows(w, sort) {
  const cols = w.columns || [], rows = (w.rows || []).slice();
  if (!sort || sort.col == null || sort.col >= cols.length) return rows;
  const get = (r) => cell(r, sort.col, cols);
  const numeric = rows.length > 0 && rows.map(get).filter((v) => str(v).trim() !== '').every((v) => num(v) !== null);
  const dir = sort.dir === 'desc' ? -1 : 1;
  return rows.sort((a, b) => {
    const x = get(a), y = get(b);
    if (numeric) return dir * ((num(x) ?? -Infinity) - (num(y) ?? -Infinity));
    return dir * str(x).localeCompare(str(y), 'zh-Hans-CN');
  });
}

// ─── 图表：内联 SVG，不引库 ───
const PALETTE = ['var(--info)', 'var(--success)', 'var(--warning)', 'var(--coral)', 'var(--lav-i)', 'var(--pink-i)'];
const nice = (v) => (Math.abs(v) >= 1e4 ? (v / 1e4).toFixed(1).replace(/\.0$/, '') + '万' : Number.isInteger(v) ? String(v) : String(Math.round(v * 100) / 100));
const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + '…' : s);
export function chartSVG(w) {
  const labels = (w.labels || []).map(str);
  const series = (w.series || []).map((s, i) => ({ name: str(s && s.name) || `系列 ${i + 1}`, values: ((s && s.values) || []).map((v) => (Number.isFinite(Number(v)) ? Number(v) : 0)) }));
  if (!series.length || !labels.length) return html`<p class="muted small">没有可画的数据。</p>`;
  const unit = str(w.unit);
  const W = 320, H = 180, L = 34, R = 8, T = 10, B = 28, pw = W - L - R, ph = H - T - B;
  const legend = series.length > 1 || w.kind === 'pie'
    ? html`<div class="w-legend">${(w.kind === 'pie' ? labels : series.map((s) => s.name)).map((n, i) => html`<span><i style="background:${raw(PALETTE[i % PALETTE.length])}"></i>${n}</span>`)}</div>` : '';
  if (w.kind === 'pie') {
    const vals = series[0].values.slice(0, labels.length).map((v) => Math.max(0, v)), total = vals.reduce((a, b) => a + b, 0);
    if (!(total > 0)) return html`<p class="muted small">没有可画的数据。</p>`;
    const cx = 80, cy = 80, r = 70; let a0 = -Math.PI / 2;
    const slices = vals.map((v, i) => {
      const a1 = a0 + (v / total) * Math.PI * 2, big = a1 - a0 > Math.PI ? 1 : 0;
      const pt = (a) => `${(cx + r * Math.cos(a)).toFixed(2)} ${(cy + r * Math.sin(a)).toFixed(2)}`;
      const d = vals.length === 1 || v / total > 0.9999 ? `M${cx - r} ${cy}a${r} ${r} 0 1 0 ${2 * r} 0a${r} ${r} 0 1 0 ${-2 * r} 0` : `M${cx} ${cy}L${pt(a0)}A${r} ${r} 0 ${big} 1 ${pt(a1)}Z`;
      a0 = a1;
      return html`<path d="${d}" style="fill:${raw(PALETTE[i % PALETTE.length])}"><title>${labels[i]}：${nice(v)}${unit}（${Math.round((v / total) * 100)}%）</title></path>`;
    });
    return html`<svg class="w-chart" viewBox="0 0 160 160" role="img" aria-label="${str(w.title)}">${slices}</svg>${legend}`;
  }
  const all = series.flatMap((s) => s.values), max = Math.max(0, ...all), min = Math.min(0, ...all), span = max - min || 1;
  const y = (v) => T + ph - ((v - min) / span) * ph, y0 = y(0);
  const n = labels.length, step = pw / n;
  const grid = [0, 0.5, 1].map((f) => { const v = min + span * f, yy = y(v); return html`<line x1="${L}" x2="${W - R}" y1="${yy.toFixed(1)}" y2="${yy.toFixed(1)}" class="w-grid"/><text x="${L - 4}" y="${(yy + 3).toFixed(1)}" text-anchor="end" class="w-tick">${nice(v)}</text>`; });
  const xl = labels.map((l, i) => (n > 8 && i % Math.ceil(n / 8) ? '' : html`<text x="${(L + step * (i + 0.5)).toFixed(1)}" y="${H - 10}" text-anchor="middle" class="w-tick">${clip(l, 5)}</text>`));
  let marks;
  if (w.kind === 'line') {
    marks = series.map((s, si) => {
      const pts = s.values.slice(0, n).map((v, i) => [L + step * (i + 0.5), y(v), v]);
      const col = PALETTE[si % PALETTE.length];
      return html`<polyline points="${pts.map((p) => p[0].toFixed(1) + ',' + p[1].toFixed(1)).join(' ')}" class="w-line" style="stroke:${raw(col)}"/>${pts.map((p, i) => html`<circle cx="${p[0].toFixed(1)}" cy="${p[1].toFixed(1)}" r="3" style="fill:${raw(col)}"><title>${labels[i]}：${nice(p[2])}${unit}</title></circle>`)}`;
    });
  } else {
    const bw = Math.max(2, Math.min(28, (step * 0.7) / series.length));
    marks = series.map((s, si) => s.values.slice(0, n).map((v, i) => {
      const x = L + step * (i + 0.5) - (bw * series.length) / 2 + bw * si, yy = y(v);
      return html`<rect x="${x.toFixed(1)}" y="${Math.min(yy, y0).toFixed(1)}" width="${bw.toFixed(1)}" height="${Math.max(1, Math.abs(y0 - yy)).toFixed(1)}" rx="2" style="fill:${raw(PALETTE[si % PALETTE.length])}"><title>${labels[i]}：${nice(v)}${unit}</title></rect>`;
    }));
  }
  return html`<svg class="w-chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${str(w.title)}">${grid}${xl}${marks}</svg>${legend}${unit ? html`<small class="muted">单位：${unit}</small>` : ''}`;
}

// ─── html 组件：沙箱 iframe + CSP + Com.send 桥 ───
export const FRAME_MIN = 44, FRAME_MAX = 560;
export const clampHeight = (h) => Math.max(FRAME_MIN, Math.min(FRAME_MAX, Math.round(Number(h) || FRAME_MIN)));
export const CSP = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:";
export function srcdocFor(w, key) {
  // key 经 JSON 序列化并转义 <，不会提前结束 script。
  const k = JSON.stringify(String(key)).replace(/</g, '\\u003c');
  const bridge = `(function(){var K=${k};window.Com={send:function(t){parent.postMessage({com:'send',key:K,text:String(t==null?'':t)},'*');}};`
    + `function h(){parent.postMessage({com:'height',key:K,height:Math.ceil(document.documentElement.scrollHeight)},'*');}`
    + `addEventListener('load',h);if(window.ResizeObserver)new ResizeObserver(h).observe(document.documentElement);else setInterval(h,500);h();})();`;
  return `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${CSP}">`
    + `<meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body{margin:0}body{font:14px/1.5 -apple-system,system-ui,sans-serif;color:#1b1c18;padding:2px}</style>`
    + `<script>${bridge}</script></head><body>${str(w.html)}</body></html>`;
}

// ─── 单个组件的 HTML ───
/** ctx：{ icon(name), height }；st：持久化状态（可为 undefined）；sort：表格排序（本地）。 */
export function widgetHTML(w, mid, index, st, ctx, sort) {
  if (!usable(w)) return '';
  const key = widgetKey(mid, index);
  const state = st && typeof st === 'object' ? st : {};
  const head = w.title ? html`<h4 class="w-title">${str(w.title)}</h4>` : '';
  const wrap = (body) => html`<div class="widget w-${w.type}" data-wk="${key}" data-mid="${mid}" data-wi="${index}">${head}${body}</div>`;
  switch (w.type) {
    case 'checklist': {
      const checked = state.checked || {}, done = !!state.submitted;
      const items = (w.items || []).map((it) => ({ id: str(it && it.id), text: str(it && it.text), on: it.id in checked ? !!checked[it.id] : !!(it && it.checked) }));
      return wrap(html`<div class="w-checks">${items.map((it) => html`<button class="w-check ${it.on ? 'on' : ''}" data-act="w-check" data-wk="${key}" data-item="${it.id}" role="checkbox" aria-checked="${it.on ? "true" : "false"}" ${done ? raw('disabled') : ''}><i>${it.on ? ctx.icon('check') : ''}</i><span>${it.text}</span></button>`)}</div>
        ${w.submit ? (done ? html`<small class="muted">已提交</small>` : html`<button class="btn primary compact" data-act="w-submit" data-wk="${key}">${submitLabel(w.submit, '提交')}</button>`) : ''}`);
    }
    case 'choices': {
      const picked = Array.isArray(state.picked) ? state.picked : [], done = !!state.submitted, multi = !!w.multi;
      return wrap(html`<div class="w-options">${(w.options || []).map((o, i) => { const l = optLabel(o); return html`<button class="w-opt ${picked.includes(l) ? 'on' : ''}" data-act="w-pick" data-wk="${key}" data-i="${i}" ${done ? raw('disabled') : ''}>${l}</button>`; })}</div>
        ${multi ? (done ? html`<small class="muted">已提交</small>` : html`<button class="btn primary compact" data-act="w-submit" data-wk="${key}" ${picked.length ? '' : raw('disabled')}>${submitLabel(w.submit, '确定')}</button>`) : done ? html`<small class="muted">已选：${picked.join('、')}</small>` : ''}`);
    }
    case 'table': {
      const cols = w.columns || [], rows = sortedRows(w, sort);
      const arrow = (i) => (sort && sort.col === i ? (sort.dir === 'desc' ? ' ↓' : ' ↑') : '');
      return wrap(html`<div class="w-scroll"><table><thead><tr>${cols.map((c, i) => html`<th><button data-act="w-sort" data-wk="${key}" data-col="${i}">${colLabel(c)}${arrow(i)}</button></th>`)}</tr></thead>
        <tbody>${rows.map((r) => html`<tr>${cols.map((_, i) => html`<td>${str(cell(r, i, cols))}</td>`)}</tr>`)}</tbody></table></div>`);
    }
    case 'chart': return wrap(chartSVG(w));
    case 'steps': {
      const norm = (s) => ({ done: 'done', completed: 'done', complete: 'done', doing: 'doing', running: 'doing', in_progress: 'doing', active: 'doing', blocked: 'blocked', failed: 'blocked', skipped: 'skipped' })[str(s)] || 'todo';
      return wrap(html`<div class="checklist">${(w.items || []).map((it) => { const s = norm(it && it.state); return html`<div class="check-step ${s}">${s === 'done' ? ctx.icon('checkCircle') : s === 'blocked' ? ctx.icon('warning') : s === 'doing' ? raw('<i class="pulse"></i>') : raw('<i class="ring"></i>')}<span><b>${str(it && it.title)}</b>${it && it.detail ? html`<small class="muted block">${str(it.detail)}</small>` : ''}</span></div>`; })}</div>`);
    }
    case 'form': {
      const values = state.values || {}, done = !!state.submitted;
      const field = (f) => {
        const id = str(f && f.id), kind = str(f && f.kind), val = id in values ? values[id] : f && f.value;
        const common = `data-fid="${esc(id)}" ${done ? 'disabled' : ''}`;
        let ctl;
        if (kind === 'select' || (Array.isArray(f.options) && f.options.length && kind !== 'radio')) ctl = html`<select ${raw(common)}>${(f.options || []).map((o) => { const l = optLabel(o); return html`<option value="${l}" ${str(val) === l ? raw('selected') : ''}>${l}</option>`; })}</select>`;
        else if (kind === 'toggle' || kind === 'checkbox' || kind === 'boolean') ctl = html`<input type="checkbox" ${raw(common)} ${val === true || val === 'true' ? raw('checked') : ''}>`;
        else if (kind === 'number' || kind === 'range' || kind === 'slider') ctl = html`<input type="${kind === 'number' ? 'number' : 'range'}" ${raw(common)} ${f.min != null ? raw(`min="${esc(f.min)}"`) : ''} ${f.max != null ? raw(`max="${esc(f.max)}"`) : ''} value="${str(val)}">${kind === 'number' ? '' : html`<output>${str(val)}</output>`}`;
        else if (kind === 'textarea' || kind === 'longtext') ctl = html`<textarea rows="3" ${raw(common)}>${str(val)}</textarea>`;
        else ctl = html`<input type="${kind === 'date' ? 'date' : 'text'}" ${raw(common)} value="${str(val)}">`;
        return html`<label class="w-field"><span>${str(f && f.label) || id}</span>${ctl}</label>`;
      };
      return wrap(html`<div class="w-form" data-wk="${key}">${(w.fields || []).map(field)}</div>
        ${done ? html`<small class="muted">已提交</small>` : html`<button class="btn primary compact" data-act="w-submit" data-wk="${key}">${submitLabel(w.submit, '提交')}</button>`}`);
    }
    case 'html': {
      const h = clampHeight(ctx.height || 120);
      return wrap(html`<iframe class="widget-frame" sandbox="allow-scripts" data-wk="${key}" style="height:${h}px" title="${str(w.title) || '组件'}" srcdoc="${srcdocFor(w, key)}"></iframe>`);
    }
    default: return '';
  }
}

/** 勾选 / 选项 / 表单提交时发出去的那句用户消息。 */
export function submitText(w, st) {
  const state = st || {};
  const t = str(w.title);
  if (w.type === 'checklist') {
    const checked = state.checked || {};
    const on = (w.items || []).filter((it) => (it.id in checked ? checked[it.id] : it.checked)).map((it) => str(it.text));
    return `${t ? `「${t}」` : '清单'}我勾了：${on.length ? on.join('、') : '一项都没勾'}`;
  }
  if (w.type === 'choices') return `${t ? `「${t}」` : ''}我选：${(state.picked || []).join('、')}`;
  if (w.type === 'form') {
    const values = state.values || {};
    return `${t ? `「${t}」` : '表单'}我填好了：${(w.fields || []).map((f) => `${str(f.label) || str(f.id)}=${str(values[f.id] ?? f.value)}`).join('；')}`;
  }
  return '';
}

// ─── 回执 / 主动消息 / 成果卡 ───
export const RECEIPT_STATE = { done: ['已办', 'success'], uncertain: ['待核实', 'warning'], disputed: ['有争议', 'warning'], failed: ['没成', 'danger'] };
export const RECEIPT_ICON = { ledger: 'yen', schedule: 'calendar', outbound: 'send' };
export function receiptHTML(r, mid, i, ctx) {
  const [label, tone] = RECEIPT_STATE[r.state] || ['已记录', 'neutral'];
  return html`<div class="receipt ${tone}" data-rid="${mid}:${i}">${ctx.icon(RECEIPT_ICON[r.type] || 'checkCircle')}<span class="grow">${str(r.summary)}</span><span class="stamp ${tone}">${label}</span><button class="link" data-act="receipt-undo" data-mid="${mid}" data-i="${i}">让它撤销</button></div>`;
}
export const undoText = (r) => `把刚才这步撤销：${str(r.summary)}`;

const RID = [['case-wait:', '去拍板', 'next'], ['nudge:', '看今天的安排', 'today'], ['plan:', '看明天的计划', 'next'], ['task-result:', '看结果', 'task'], ['task_', '看结果', 'task'], ['event:', '看下一步', 'next'], ['observation', '看下一步', 'next']];
/** 主动消息（按 request_id 前缀）该给哪个按钮；没有就返回 null。 */
export function proactiveButton(m) {
  const rid = str(m && m.request_id);
  if (!rid || (m.role && m.role !== 'assistant')) return null;
  const hit = RID.find(([p]) => rid.startsWith(p));
  return hit ? { label: hit[1], to: hit[2] } : null;
}
export const isHtmlArtifact = (a) => /\.html?$/i.test(str(a && (a.name || a.path))) || str(a && a.mime) === 'text/html';
export function artifactsHTML(arts, ctx) {
  const name = (a) => str(a.name) || str(a.path).split('/').pop();
  const attr = (a) => `data-act="open-artifact" data-path="${esc(a.path || '')}" data-id="${esc(a.id || '')}" data-name="${esc(a.name || '')}"`;
  const big = arts.filter(isHtmlArtifact), rest = arts.filter((a) => !isHtmlArtifact(a));
  return html`${big.map((a) => html`<button class="art-card" ${raw(attr(a))}>${ctx.icon('globe')}<span class="grow"><b>${name(a)}</b><small>网页 · 点开就能看</small></span>${ctx.icon('arrowUpRight')}</button>`)}
    ${rest.length ? html`<div class="arts">${rest.map((a) => html`<button class="att art" ${raw(attr(a))}>${ctx.icon(str(a.mime).startsWith('image') ? 'photo' : 'doc')}${name(a)}</button>`)}</div>` : ''}`;
}
