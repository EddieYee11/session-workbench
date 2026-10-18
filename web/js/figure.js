// 手绘伙伴「她」：从 iOS Character.swift 的 CharacterPainter 逐行移植（120×132 角色坐标，SVG 路径原样）。
// 8 个状态 idle/read/think/exec/send/ask/done/broken，动作由真实事件驱动；换姿态时只有变了的部分动（PoseBlend）。

const cache = new Map();
const P = (d) => {
  let p = cache.get(d);
  if (!p) { p = new Path2D(d); cache.set(d, p); }
  return p;
};

export function keyframe(values, times, dur, t, begin = 0) {
  if (!(dur > 0) || values.length !== times.length || values.length < 2) return values[0] ?? 0;
  let local = (t - begin) % dur;
  if (local < 0) local += dur;
  const phase = local / dur;
  for (let i = 1; i < times.length; i++) {
    if (phase <= times[i]) {
      const span = times[i] - times[i - 1];
      const f = span > 0 ? (phase - times[i - 1]) / span : 1;
      return values[i - 1] + (values[i] - values[i - 1]) * f;
    }
  }
  return values[values.length - 1];
}
export const even = (values, dur, t, begin = 0) =>
  keyframe(values, values.map((_, i) => i / (values.length - 1)), dur, t, begin);

const FONT = '"SF Pro Rounded", ui-rounded, "PingFang SC", system-ui, sans-serif';

export class Painter {
  constructor(o) {
    this.state = o.state; this.t = o.t; this.moving = o.moving;
    this.ink = o.ink; this.paper = o.paper; this.red = o.red; this.danger = o.danger || '#D5452F';
    this.sign = o.sign || ''; this.quiet = !!o.quiet;
  }
  get time() { return this.moving ? this.t : 0; }
  get bob() {
    const s = this.state, t = this.time;
    return s === 'read' ? even([0, -4, 0], 0.6, t) : s === 'ask' ? even([0, -3, 0], 1.2, t) : even([0, 3, 0], 3.6, t);
  }
  get blinkR() { const r = this.state === 'broken' ? 2 : 3; return keyframe([r, r, 0.4, r], [0, 0.93, 0.96, 1], 4.2, this.time); }
  get headAngle() {
    const s = this.state, t = this.time;
    return s === 'idle' ? even([-6, -11, -6], 3.2, t) : s === 'think' ? even([0, 6, 0], 1.6, t) : 0;
  }
  get eyesClosed() { return this.state === 'idle'; }
  get smiling() { return this.state === 'done'; }
  get look() {
    const s = this.state, t = this.time;
    if (s === 'read') return { x: even([-2, 2, -2], 1.2, t), y: 2 };
    if (s === 'think') return { x: 2, y: -2 };
    if (s === 'send') return { x: 3, y: 0 };
    return { x: 0, y: 0 };
  }
  stroke(c, d, w, color) {
    c.strokeStyle = color || this.ink; c.lineWidth = w; c.lineCap = 'round'; c.lineJoin = 'round';
    c.stroke(P(d));
  }
  fill(c, d, color, w = 0) { c.fillStyle = color; c.fill(P(d)); if (w > 0) this.stroke(c, d, w); }
  text(c, value, size, color, x, y, weight = 800) {
    c.font = `${weight} ${size}px ${FONT}`; c.fillStyle = color; c.textAlign = 'center'; c.textBaseline = 'middle';
    c.fillText(value, x, y);
  }

  /** 整个角色（身体 + 头 + 手持物）。blend = {from, fromSign, amount}。 */
  figure(c, blend) {
    const a = blend ? blend.amount : 1;
    const prev = blend ? new Painter({ ...this, state: blend.from, sign: blend.fromSign }) : null;
    const mix = (from, to) => (from == null ? to : from + (to - from) * a);
    c.save();
    c.translate(0, mix(prev && prev.bob, this.bob));
    this.fill(c, 'M28 132 Q32 106 60 104 Q88 106 92 132 Z', this.ink, 2);
    // 头：绕 (60,100) 轻轻点头 / 歪头
    c.save();
    c.translate(60, 100); c.rotate((mix(prev && prev.headAngle, this.headAngle) * Math.PI) / 180); c.translate(-60, -100);
    this.stroke(c, 'M30 30 Q10 62 6 112 M27 40 Q14 76 12 120 M33 34 Q18 70 18 118 M31 50 Q22 86 22 124 M35 60 Q28 94 30 122 M24 30 Q4 58 2 96 M36 72 Q32 100 37 120 M90 30 Q110 62 114 112 M93 40 Q106 76 108 120 M87 34 Q102 70 102 118 M89 50 Q98 86 98 124 M85 60 Q92 94 90 122 M96 30 Q116 58 118 96 M84 72 Q88 100 83 120', 3.8);
    this.fill(c, 'M33 54 Q31 99 60 100 Q89 99 87 54 Q80 42 60 42 Q40 42 33 54 Z', this.paper);
    this.stroke(c, 'M33 62 Q32 99 60 100 Q88 99 87 62', 3.4);
    this.stroke(c, 'M24 54 Q20 10 60 8 Q100 10 96 54', 4);
    this.fill(c, 'M30 50 Q30 18 60 15 Q90 18 90 50 L85 44 L82 52 L77 42 L73 52 L68 41 L64 53 L59 41 L54 52 L50 42 L45 52 L41 43 L37 51 L34 45 Z', this.ink, 2);
    this.stroke(c, 'M40 20 L35 50 M80 20 L85 50 M28 30 Q40 14 56 12 M92 30 Q80 14 64 12', 3.4);
    this.stroke(c, 'M52 12 Q46 2 36 2 M66 12 Q72 2 84 4 M58 11 Q58 3 54 -2 M46 14 Q34 6 26 10 M74 14 Q88 6 96 12', 3);
    this.fill(c, 'M34 52 Q33 68 45 69 Q57 69 57 57 Q57 50 46 50 Q38 50 34 52 Z M63 57 Q63 69 75 69 Q86 68 86 57 Q86 50 76 50 Q66 50 63 57 Z', this.paper);
    this.stroke(c, 'M34 52 Q33 68 45 69 Q57 69 57 57 Q57 50 46 50 Q38 50 34 52 Z M34 52 L30 47 L38 50 M63 57 Q63 69 75 69 Q86 68 86 57 Q86 50 76 50 Q66 50 63 57 Z M86 54 L90 49 M57 55 Q60 52 63 55', 3.2);
    if (prev && prev.eyesClosed !== this.eyesClosed) { prev.eyes(c, 1 - a); this.eyes(c, a); }
    else if (prev) {
      const pl = prev.look, l = this.look;
      this.eyes(c, 1, { x: mix(pl.x, l.x), y: mix(pl.y, l.y) }, mix(prev.blinkR, this.blinkR));
    } else this.eyes(c, 1);
    this.stroke(c, 'M60 62 L55 75 L61 75', 3);
    if (prev && prev.smiling !== this.smiling) { prev.mouth(c, 1 - a); this.mouth(c, a); } else this.mouth(c, 1);
    // 出错时额角那滴汗
    const was = prev ? prev.state === 'broken' : this.state === 'broken', now = this.state === 'broken';
    const drop = was && now ? 1 : was ? 1 - a : now ? a : 0;
    if (drop > 0) { c.save(); c.globalAlpha *= drop; this.stroke(c, 'M98 40 Q94 47 98 50 Q102 47 98 40', 2.4); c.restore(); }
    c.restore();
    if (prev && (prev.state !== this.state || prev.sign !== this.sign)) { prev.props(c, 1 - a, null); this.props(c, a, a); }
    else this.props(c, 1, null);
    c.restore();
  }
  eyes(c, opacity, custom, radius) {
    c.save(); c.globalAlpha *= opacity;
    if (this.eyesClosed) { this.stroke(c, 'M41 60 Q45.5 64 50 60 M70 60 Q74.5 64 79 60', 3); c.restore(); return; }
    const look = custom || this.look, r = radius ?? this.blinkR;
    c.fillStyle = this.ink;
    for (const x of [46, 75]) { c.beginPath(); c.ellipse(x + look.x, 59 + look.y, 3, Math.max(0.2, r), 0, 0, Math.PI * 2); c.fill(); }
    c.restore();
  }
  mouth(c, opacity) {
    c.save(); c.globalAlpha *= opacity;
    this.stroke(c, this.smiling ? 'M48 83 Q54 91 62 83' : 'M50 84 Q52.5 89 56 85', 3.2);
    c.restore();
  }
  /** 当前状态拿在手上的东西。entrance 非空 = 正在进场（0…1，已缓动）。 */
  props(c, opacity, entrance) {
    if (opacity <= 0.001) return;
    const t = this.time, s = this.state;
    c.save(); c.globalAlpha *= opacity;
    if (entrance != null) {
      const stamp = s === 'ask' || s === 'broken';
      const pv = stamp ? [144, 32] : [100, 108];
      const scale = stamp ? 1.3 - 0.3 * entrance : 0.86 + 0.14 * entrance;
      c.translate(pv[0], pv[1]);
      if (stamp) c.rotate((-9 * (1 - entrance) * Math.PI) / 180);
      c.scale(scale, scale);
      c.translate(-pv[0], -pv[1]);
    }
    switch (s) {
      case 'read':
        this.stroke(c, 'M34 120 Q40 108 46 104 M86 120 Q80 108 74 104', 3.6);
        this.fill(c, 'M34 88 h52 v34 h-52z', this.paper, 3);
        this.stroke(c, 'M34 88 l26 16 26 -16', 2.6);
        break;
      case 'think': {
        this.stroke(c, 'M86 122 L92 112', 3.6);
        c.save(); c.translate(92, 112); c.rotate((even([0, -16, 0], 0.8, t) * Math.PI) / 180);
        this.stroke(c, 'M0 0 L12 -22', 4); this.stroke(c, 'M12 -22 L14 -27', 2);
        c.restore();
        if (!this.quiet) {
          [[102, 22, 5], [117, 9, 6.5], [135, -2, 8]].forEach((d, i) => {
            const alpha = this.moving ? even([0.15, 1, 0.15], 1.6, t, i * 0.25) : i === 2 ? 1 : 0.15;
            c.save(); c.globalAlpha *= alpha; c.fillStyle = this.ink;
            c.beginPath(); c.arc(d[0], d[1], d[2], 0, Math.PI * 2); c.fill(); c.restore();
          });
        }
        break;
      }
      case 'exec': {
        this.fill(c, 'M92 124 L100 112 L150 112 L158 124 Z', this.paper, 2.4);
        const mark = keyframe([0, 0, 1, 1], [0, 0.4, 0.44, 1], 1.4, t);
        c.save(); c.globalAlpha *= this.moving ? mark : 1; c.fillStyle = this.red;
        c.beginPath(); c.ellipse(125, 118, 12, 3.6, 0, 0, Math.PI * 2); c.fill(); c.restore();
        c.save(); c.translate(0, this.moving ? keyframe([-18, -18, 0, 0, -18], [0, 0.25, 0.42, 0.62, 1], 1.4, t) : 0);
        this.stroke(c, 'M86 120 Q100 104 112 98', 3.6);
        this.fill(c, 'M118 84 q0 -8 7 -8 q7 0 7 8 v8 h-14z', this.ink, 2);
        this.fill(c, 'M110 92 h30 v12 h-30z', this.red, 2.4);
        c.restore();
        break;
      }
      case 'send':
        this.stroke(c, 'M86 120 Q104 100 120 90', 3.6);
        break;
      case 'ask':
      case 'broken': {
        this.stroke(c, 'M88 124 L104 66', 3.6);
        c.save(); c.translate(88, 8);
        const rot = s === 'ask' ? even([-2, 2, -2], 1.2, t) : keyframe([0, -6, 5, -3, 2, 0, 0], [0, 0.12, 0.24, 0.36, 0.48, 0.6, 1], 1.6, t);
        c.translate(30, 48); c.rotate(((this.moving ? rot : 0) * Math.PI) / 180); c.translate(-30, -48);
        this.fill(c, 'M0 0 h112 v48 h-112z', s === 'ask' ? this.red : this.paper, 3);
        const label = this.sign || (s === 'ask' ? '等你点头' : '邮箱断了');
        this.text(c, label, label.length > 4 ? 20 : 26, s === 'ask' ? this.ink : this.danger, 56, 26);
        c.restore();
        break;
      }
      case 'done': {
        c.save();
        const p = this.moving ? keyframe([-6, 0, 34, 50], [0, 0.15, 0.65, 1], 1.6, t) : 0;
        c.globalAlpha *= this.moving ? keyframe([0, 1, 1, 0], [0, 0.15, 0.65, 1], 1.6, t) : 1;
        c.translate(0, p);
        this.stroke(c, 'M86 120 Q96 112 104 104', 3.6);
        this.fill(c, 'M98 90 h44 v30 h-44z', this.paper, 2.6);
        this.stroke(c, 'M105 100 h28 M105 109 h18', 2.2);
        c.restore();
        break;
      }
      case 'idle':
        [[98, 40, 26], [114, 22, 34]].forEach((z, i) => {
          const begin = i * 1.1;
          const alpha = this.moving ? keyframe([0, 1, 0], [0, 0.25, 1], 3.2, t, begin) : 0.5;
          const drift = this.moving ? even([0, 1], 3.2, t, begin) : 0.4;
          c.save(); c.globalAlpha *= alpha;
          this.text(c, 'z', z[2], this.ink, z[0] + drift * 12, z[1] - drift * 18, 600);
          c.restore();
        });
        break;
    }
    c.restore();
  }
  /** 纸飞机：从 origin 起飞，reach = 飞多远。 */
  plane(c, ox, oy, scale, reach = 90) {
    const p = this.moving ? (this.time % 1.8) / 1.8 : 0.5;
    const dx = keyframe([0, (reach * 4) / 9, reach], [0, 0.5, 1], 1, p), dy = keyframe([0, -10, 2], [0, 0.5, 1], 1, p);
    c.save();
    c.globalAlpha *= this.moving ? keyframe([0, 1, 1, 0], [0, 0.1, 0.85, 1], 1, p) : 1;
    c.translate(ox + dx * scale, oy + dy * scale); c.scale(scale, scale);
    this.fill(c, 'M0 0 L12 4 L0 8 L3 4 Z', this.paper, 1.2); this.stroke(c, 'M3 4 L12 4', 1.2);
    c.restore();
  }
}

// ─── 共享一个动画时钟：所有画布登记在这里，按各自帧率重画；页面隐藏或减少动态时停。 ───
const figures = new Set();
let raf = 0;
const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
function loop(now) {
  raf = 0;
  let need = false;
  for (const f of figures) {
    if (!f.canvas.isConnected) { figures.delete(f); continue; }
    if (f.wants(now)) { f.draw(now); }
    if (f.animating()) need = true;
  }
  if (need && !document.hidden) raf = requestAnimationFrame(loop);
}
export function kick() { if (!raf && !document.hidden) raf = requestAnimationFrame(loop); }
document.addEventListener('visibilitychange', kick);

function colors(el) {
  const cs = getComputedStyle(el);
  const v = (n, d) => cs.getPropertyValue(n).trim() || d;
  return { ink: v('--fig-ink', '#1B1C18'), paper: v('--fig-paper', '#fff'), red: v('--accent', '#D1F061'), danger: v('--danger', '#D5452F') };
}

/**
 * 顶栏里的她（也给配对页 / 菜单头像 / 工作台用）。
 * mode: 'strip'（124×56，0.38 缩放）| 'portrait'（只画头的圆形头像）| 'full'（整身）| 'stage'（402×200 工作台场景）
 */
export class FigureCanvas {
  constructor(canvas, { mode = 'strip', size, state = 'idle', sign = '', quiet = false } = {}) {
    this.canvas = canvas; this.mode = mode; this.size = size;
    this.pose = { from: state, fromSign: sign, to: state, toSign: sign, at: -1e9 };
    this.quiet = quiet; this.last = 0; this.extra = {};
    this.resize();
    figures.add(this); this.draw(performance.now()); kick();
  }
  resize() {
    const dpr = Math.min(3, window.devicePixelRatio || 1);
    const r = this.canvas.getBoundingClientRect();
    const w = Math.max(1, r.width || this.size?.[0] || 124), h = Math.max(1, r.height || this.size?.[1] || 56);
    this.w = w; this.h = h;
    this.canvas.width = Math.round(w * dpr); this.canvas.height = Math.round(h * dpr); this.dpr = dpr;
  }
  set(state, sign = '', extra) {
    if (extra) this.extra = extra;
    const p = this.pose;
    if (p.to === state && p.toSign === sign) { kick(); return; }
    const now = performance.now() / 1000;
    const early = now - p.at < 0.16;
    this.pose = { from: early ? p.from : p.to, fromSign: early ? p.fromSign : p.toSign, to: state, toSign: sign, at: now };
    kick();
  }
  blending(now) { return now / 1000 - this.pose.at < 0.32; }
  animating() { return this.blending(performance.now()) || (!reduced() && this.pose.to !== 'done'); }
  wants(now) {
    const fps = this.pose.to === 'idle' && !this.blending(now) ? 12 : 30;
    if (now - this.last < 1000 / fps - 2) return false;
    this.last = now; return true;
  }
  painter(now, state, sign) {
    const col = colors(this.canvas);
    return new Painter({ state, t: now / 1000, moving: !reduced() && !document.hidden, ink: col.ink, paper: col.paper, red: col.red, danger: col.danger, sign, quiet: this.quiet });
  }
  draw(now) {
    const c = this.canvas.getContext('2d');
    if (this.canvas.width !== Math.round(this.w * this.dpr)) this.resize();
    c.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    c.clearRect(0, 0, this.w, this.h);
    const raw = Math.min(1, Math.max(0, (now / 1000 - this.pose.at) / 0.32));
    const blend = raw < 1 ? { from: this.pose.from, fromSign: this.pose.fromSign, amount: 1 - Math.pow(1 - raw, 3) } : null;
    const p = this.painter(now, this.pose.to, this.pose.toSign);
    if (this.mode === 'strip') {
      const k = this.w / 124;
      c.scale(k, k);
      c.save(); c.translate(0, 6); c.scale(0.38, 0.38); p.figure(c, blend); c.restore();
      if (this.pose.to === 'send') { c.save(); c.globalAlpha = blend && this.pose.from !== 'send' ? blend.amount : 1; p.plane(c, 48, 22, 1, 60); c.restore(); }
    } else if (this.mode === 'portrait') {
      const s = this.w / 118;
      c.translate(this.w / 2 - 60 * s, -2 * s); c.scale(s, s);
      const st = this.pose.to === 'idle' ? 'think' : this.pose.to;
      new Painter({ ...p, state: st, moving: false }).figure(c);
    } else if (this.mode === 'full') {
      const s = Math.min(this.w / 160, this.h / 140);
      c.translate(this.w / 2 - 60 * s, this.h / 2 - 66 * s); c.scale(s, s);
      p.figure(c, blend);
    } else if (this.mode === 'stage') {
      drawStage(c, this.w, this.h, p, this.extra);
    }
  }
}

/** 下拉工作台场景：左边信箱格，中间桌子和她，右边 mini / Book 两盏灯（StageScene，402×170 设计坐标）。 */
function drawStage(ctx, w, h, p, extra) {
  const s = w / 402;
  ctx.save();
  ctx.translate(0, h - 170 * s); ctx.scale(s, s);
  const ink = p.ink, paper = p.paper, red = p.red, t = p.time, moving = p.moving, state = p.state;
  const line = (d, lw, color = ink, alpha = 1) => { ctx.save(); ctx.globalAlpha *= alpha; p.stroke(ctx, d, lw, color); ctx.restore(); };
  const fillPath = (d, color, lw) => { p.fill(ctx, d, color); line(d, lw); };
  line('M12 160 Q120 157 200 160 Q296 162 392 159', 1.8, ink, 0.55);
  line('M22 160 L22 92 L92 92 L92 160 M57 92 L57 160 M22 126 L92 126', 2.2);
  line('M29 103 h20 v14 h-20z M29 103 l10 7 10 -7', 1.7);
  line('M64 102 h22 v16 h-22z M64 107 h22 M69 100 v4 M81 100 v4', 1.7);
  line('M29 136 h20 v11 h-12 l-5 4 v-4 h-3z', 1.7);
  line('M68 135 l6 7 6 -7 M74 142 v9 M69 145 h10', 1.7);
  if (extra.sourceBroken || state === 'broken') line('M27 100 L51 121 M51 100 L27 121', 3, red);
  if (state === 'read') {
    fillPath('M134 124 L139 115 L169 115 L174 124 Z', paper, 1.7);
    ctx.save(); ctx.translate(134, 124);
    ctx.rotate(((moving ? keyframe([0, 0, -150, 0], [0, 0.5, 0.75, 1], 1.2, t) : 0) * Math.PI) / 180);
    ctx.translate(-134, -124); fillPath('M134 124 L139 115 L169 115 L174 124 Z', paper, 1.7); ctx.restore();
  }
  fillPath('M110 123 Q220 120 332 123 L332 134 Q220 131 110 134 Z', paper, 2.4);
  line('M124 134 L122 160 M318 133 L320 160', 2.4);
  ctx.save(); ctx.translate(158, 20); ctx.scale(0.8, 0.8); p.figure(ctx); ctx.restore();
  if (state === 'send') p.plane(ctx, 252, 100, 1.5);
  if (state === 'done') {
    ctx.save(); ctx.translate(248, 104);
    const grow = moving ? even([0.2, 1.3], 1.6, t) : 1;
    ctx.globalAlpha *= moving ? keyframe([0, 1, 0], [0, 0.3, 1], 1.6, t) : 0.8;
    ctx.scale(grow, grow); line('M0 -6 V6 M-6 0 H6 M-4 -4 L4 4 M4 -4 L-4 4', 1.8); ctx.restore();
  }
  line('M346 160 L346 102 L390 102 L390 160 M352 114 L384 114', 2.2);
  const lit = state === 'send' && moving ? keyframe([0, 0, 1, 1], [0, 0.8, 0.82, 1], 1.8, t) : 0;
  [358, 378].forEach((x, i) => {
    const on = (i === 0 && extra.machine !== 'macbook') || (i === 1 && extra.machine === 'macbook');
    ctx.fillStyle = on && lit > 0.5 ? ink : paper;
    ctx.beginPath(); ctx.arc(x, 130, 4, 0, Math.PI * 2); ctx.fill();
    ctx.strokeStyle = ink; ctx.lineWidth = 1.8; ctx.stroke();
  });
  ctx.font = `500 6.5px ${FONT}`; ctx.fillStyle = extra.tertiary || '#999'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.fillText('mini', 357, 148); ctx.fillText('Book', 380, 148);
  ctx.restore();
}
