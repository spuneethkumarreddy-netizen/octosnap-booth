// Per-style drawing animations for the drawing TV (code only, no extra AI cost).
// Anim.play(style, { ctx, art, final, W, H, seconds }) -> Promise, resolves when the clean final picture is on the canvas.
//   art   = the AI picture (Image) used to find lines and colour regions
//   final = the finished picture (canvas/Image, art + name/message) that the animation ends on
// Anim.seconds(style, drawSeconds) -> suggested total length. Needs strokes.js (Strokes) loaded first.
(function (g) {
  const TAU = Math.PI * 2;
  const mk = (W, H) => { const c = document.createElement('canvas'); c.width = Math.max(1, Math.round(W)); c.height = Math.max(1, Math.round(H)); return c; };
  const clamp = (v, a = 0, b = 1) => v < a ? a : v > b ? b : v;
  const ease = t => { t = clamp(t); return t * t * (3 - 2 * t); };
  const easeOut = t => 1 - Math.pow(1 - clamp(t), 3);
  const backOut = t => { t = clamp(t); const c = 1.9; return 1 + (c + 1) * Math.pow(t - 1, 3) + c * Math.pow(t - 1, 2); };
  const seg = (t, a, b) => clamp((t - a) / (b - a));
  const rnd = (a, b) => a + Math.random() * (b - a);
  // v1.5: every animation step can be stopped: o.signal = { aborted } (set by the screen when the guest / picture changed)
  const ABORT = new Error('anim aborted'); ABORT.aborted = true;
  const run = (o, ms, fn) => new Promise((res, rej) => {
    const t0 = performance.now(), sig = o && o.signal;
    const f = now => { if (sig && sig.aborted) return rej(ABORT); const t = Math.min(1, (now - t0) / Math.max(1, ms)); fn(t, now - t0); t < 1 ? requestAnimationFrame(f) : res(); };
    if (sig && sig.aborted) return rej(ABORT);
    requestAnimationFrame(f);
  });

  // ---------- shared layers ----------
  let paperPat = null;
  function paper(ctx, W, H) {
    if (!paperPat) {
      const c = mk(160, 160), x = c.getContext('2d'), d = x.createImageData(160, 160);
      for (let i = 0; i < d.data.length; i += 4) { const n = 252 + Math.random() * 6 - 3; d.data[i] = n; d.data[i + 1] = n - 2; d.data[i + 2] = n - 6; d.data[i + 3] = 255; }
      x.putImageData(d, 0, 0); paperPat = c;
    }
    ctx.save(); ctx.fillStyle = ctx.createPattern(paperPat, 'repeat'); ctx.fillRect(0, 0, W, H); ctx.restore();
  }
  function pixels(img, w, h) { const c = mk(w, h), x = c.getContext('2d', { willReadFrequently: true }); x.drawImage(img, 0, 0, w, h); return x.getImageData(0, 0, w, h).data; }
  // dark lines of the art as ink of one colour (alpha from the pencil-sketch filter)
  function inkLayer(o, rgb, gain) {
    const { art, W, H } = o, c = mk(W, H), x = c.getContext('2d'); x.drawImage(art, 0, 0, W, H);
    const d = x.getImageData(0, 0, W, H), a = d.data, sk = Strokes.sketch(a, W, H);
    const fb = (o.faces || []).map(f => [f.x - f.w * .22, f.y - f.h * .38, f.x + f.w * 1.22, f.y + f.h * 1.18]);
    for (let i = 0, j = 0; i < sk.length; i++, j += 4) {
      let gn = gain, lim = 240;
      if (fb.length) { const X = i % W, Y = (i / W) | 0; for (const b of fb) if (X > b[0] && X < b[2] && Y > b[1] && Y < b[3]) { gn = gain * 1.8; lim = 250; break; } }
      a[j] = rgb[0]; a[j + 1] = rgb[1]; a[j + 2] = rgb[2]; a[j + 3] = clamp((lim - sk[i]) * gn, 0, 255);
    }
    x.putImageData(d, 0, 0); return c;
  }
  function strokesOf(o) {
    if (o._strokes) return o._strokes;
    const k = Math.min(1, 760 / o.W), w = Math.round(o.W * k), h = Math.round(o.H * k);
    const faces = (o.faces || []).map(f => ({ x: f.x * k, y: f.y * k, w: f.w * k, h: f.h * k }));
    const res = Strokes.extract(pixels(o.art, w, h), w, h, { faces });
    return (o._strokes = { width: res.width / k, list: res.strokes.map(s => s.map(([x, y]) => [x / k, y / k])) });
  }

  // colour regions on a small grid: 0 background, 1 skin, 2 hair, 3..8 colours by hue, 9 other dark
  function regions(o) {
    if (o._reg) return o._reg;
    const gw = 96, gh = Math.max(8, Math.round(96 * o.H / o.W)), px = pixels(o.art, gw, gh);
    const lab = new Uint8Array(gw * gh), col = [];
    for (let i = 0, j = 0; i < gw * gh; i++, j += 4) {
      const r = px[j], gg = px[j + 1], b = px[j + 2], y = Math.floor(i / gw);
      const L = 0.299 * r + 0.587 * gg + 0.114 * b, mx = Math.max(r, gg, b), mn = Math.min(r, gg, b), ch = mx - mn;
      const cb = 128 - 0.1687 * r - 0.3313 * gg + 0.5 * b, cr = 128 + 0.5 * r - 0.4187 * gg - 0.0813 * b;
      let l;
      if (L > 215 && ch < 45) l = 0;
      else if (L < 70) l = y < gh * 0.5 ? 2 : 9;
      else if (cb > 77 && cb < 127 && cr > 135 && cr < 175 && r > gg && L > 70) l = 1;
      else { let hue = 0; if (ch) { hue = mx === r ? ((gg - b) / ch + 6) % 6 : mx === gg ? (b - r) / ch + 2 : (r - gg) / ch + 4; } l = 3 + Math.min(5, Math.floor(hue)); }
      lab[i] = l; col.push([r, gg, b]);
    }
    return (o._reg = { gw, gh, lab, col, cw: o.W / gw, ch: o.H / gh });
  }
  // brush order: skin -> hair -> clothes (biggest colours first) -> dark rest -> background
  function regionOrder(R, withBg) {
    const cnt = new Array(10).fill(0); for (const l of R.lab) cnt[l]++;
    const cols = [3, 4, 5, 6, 7, 8].filter(l => cnt[l] > 4).sort((a, b) => cnt[b] - cnt[a]);
    return [1, 2, ...cols, 9, ...(withBg ? [0] : [])].filter(l => cnt[l] > 4);
  }
  // back-and-forth hatch paths of dabs over one region (grid cells)
  function dabPath(R, labels, step) {
    const set = new Set(labels), out = [], { gw, gh, lab } = R;
    let dir = 1;
    for (let y = 0; y < gh; y += step) {
      const row = [];
      for (let x = 0; x < gw; x++) {
        let hit = -1;
        for (let dy = 0; dy < step && hit < 0; dy++) { const yy = y + dy; if (yy < gh && set.has(lab[yy * gw + x])) hit = yy; }
        if (hit >= 0) row.push([x, hit]);
      }
      if (!row.length) continue;
      if (dir < 0) row.reverse(); dir = -dir;
      row.forEach(([x, yy], i) => out.push({ x: (x + 0.5 + rnd(-.3, .3)) * R.cw, y: (yy + 0.5 + Math.sin(i * 0.9) * 0.6) * R.ch, c: R.col[yy * gw + x] }));
    }
    return out;
  }
  function regionMask(R, labels) {     // small alpha mask of a region, drawn scaled up later
    const c = mk(R.gw, R.gh), x = c.getContext('2d'), d = x.createImageData(R.gw, R.gh), set = new Set(labels);
    for (let i = 0; i < R.lab.length; i++) if (set.has(R.lab[i])) d.data[i * 4 + 3] = 255;
    x.putImageData(d, 0, 0); return c;
  }
  const spriteCache = {};
  function sprite(r, hard) {           // soft round brush dab (white alpha), slightly ragged like watercolour
    const k = Math.round(r) + ':' + hard; if (spriteCache[k]) return spriteCache[k];
    const c = mk(r * 2, r * 2), x = c.getContext('2d'), gr = x.createRadialGradient(r, r, 0, r, r, r);
    gr.addColorStop(0, 'rgba(0,0,0,1)'); gr.addColorStop(hard, 'rgba(0,0,0,.85)'); gr.addColorStop(1, 'rgba(0,0,0,0)');
    x.fillStyle = gr; x.beginPath(); x.arc(r, r, r, 0, TAU); x.fill();
    x.globalCompositeOperation = 'destination-out';
    for (let i = 0; i < 18; i++) { x.fillStyle = `rgba(0,0,0,${rnd(.1, .35)})`; x.beginPath(); x.arc(r + rnd(-r, r) * .8, r + rnd(-r, r) * .8, rnd(1, r * .25), 0, TAU); x.fill(); }
    return (spriteCache[k] = c);
  }
  // draw `src` through `mask` onto ctx (tmp is a scratch canvas of the same size)
  function through(ctx, tmp, mask, src, W, H, op) {
    const t = tmp.getContext('2d'); t.globalCompositeOperation = 'copy'; t.drawImage(mask, 0, 0, W, H);
    t.globalCompositeOperation = 'source-in'; t.drawImage(src, 0, 0, W, H); t.globalCompositeOperation = 'source-over';
    if (op) { ctx.save(); ctx.globalCompositeOperation = op; ctx.drawImage(tmp, 0, 0); ctx.restore(); } else ctx.drawImage(tmp, 0, 0);
  }
  async function settle(o, ms, under) {     // crossfade to the clean final picture
    const { ctx, W, H, final } = o;
    await run(o, ms, t => { under ? under(t) : null; ctx.globalAlpha = ease(t); ctx.drawImage(final, 0, 0, W, H); ctx.globalAlpha = 1; });
    ctx.drawImage(final, 0, 0, W, H);
  }

  // ---------- tools (cursors) ----------
  const tools = {
    pencil(ctx, x, y, s) { ctx.save(); ctx.translate(x, y); ctx.rotate(-0.6); ctx.fillStyle = '#f2d2a0'; ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(9 * s, -24 * s); ctx.lineTo(-9 * s, -24 * s); ctx.fill(); ctx.fillStyle = '#333'; ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(3 * s, -8 * s); ctx.lineTo(-3 * s, -8 * s); ctx.fill(); ctx.fillStyle = '#f2b705'; ctx.fillRect(-9 * s, -130 * s, 18 * s, 106 * s); ctx.fillStyle = '#e88'; ctx.fillRect(-9 * s, -150 * s, 18 * s, 14 * s); ctx.fillStyle = '#aaa'; ctx.fillRect(-9 * s, -138 * s, 18 * s, 8 * s); ctx.restore(); },
    nib(ctx, x, y, s) { ctx.save(); ctx.translate(x, y); ctx.rotate(-0.5); ctx.fillStyle = '#222'; ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(7 * s, -26 * s); ctx.lineTo(-7 * s, -26 * s); ctx.fill(); ctx.fillStyle = '#c33'; ctx.fillRect(-10 * s, -140 * s, 20 * s, 114 * s); ctx.fillStyle = '#ddd'; ctx.fillRect(-10 * s, -60 * s, 20 * s, 6 * s); ctx.restore(); },
    charcoal(ctx, x, y, s) { ctx.save(); ctx.translate(x, y); ctx.rotate(-0.9); ctx.fillStyle = '#2a2a2a'; ctx.beginPath(); ctx.moveTo(-8 * s, 0); ctx.lineTo(8 * s, -4 * s); ctx.lineTo(9 * s, -90 * s); ctx.lineTo(-9 * s, -90 * s); ctx.closePath(); ctx.fill(); ctx.fillStyle = '#ddd'; ctx.fillRect(-10 * s, -80 * s, 20 * s, 40 * s); ctx.restore(); },
    brush(ctx, x, y, s, c) { ctx.save(); ctx.translate(x, y); ctx.rotate(-0.7); ctx.fillStyle = c ? `rgb(${c[0]},${c[1]},${c[2]})` : '#c55'; ctx.beginPath(); ctx.ellipse(0, -14 * s, 9 * s, 18 * s, 0, 0, TAU); ctx.fill(); ctx.fillStyle = '#bbb'; ctx.fillRect(-8 * s, -46 * s, 16 * s, 16 * s); ctx.fillStyle = '#7a4a22'; ctx.beginPath(); ctx.moveTo(-7 * s, -46 * s); ctx.lineTo(7 * s, -46 * s); ctx.lineTo(4 * s, -170 * s); ctx.lineTo(-4 * s, -170 * s); ctx.fill(); ctx.restore(); },
    airbrush(ctx, x, y, s, c) { ctx.save(); ctx.translate(x + 30 * s, y - 30 * s); ctx.rotate(-0.8); ctx.fillStyle = '#9aa3ad'; ctx.fillRect(-8 * s, -10 * s, 16 * s, 110 * s); ctx.beginPath(); ctx.moveTo(-8 * s, -10 * s); ctx.lineTo(8 * s, -10 * s); ctx.lineTo(0, -34 * s); ctx.fill(); ctx.fillStyle = '#556'; ctx.fillRect(-14 * s, 20 * s, 28 * s, 10 * s); ctx.fillStyle = c ? `rgb(${c[0]},${c[1]},${c[2]})` : '#888'; ctx.beginPath(); ctx.arc(18 * s, 40 * s, 14 * s, 0, TAU); ctx.fill(); ctx.restore(); },
    can(ctx, x, y, s, c) { ctx.save(); ctx.translate(x + 50 * s, y - 40 * s); ctx.rotate(0.5); const col = c ? `rgb(${c[0]},${c[1]},${c[2]})` : '#e33'; ctx.fillStyle = '#ccc'; ctx.fillRect(-26 * s, -20 * s, 52 * s, 130 * s); ctx.fillStyle = col; ctx.fillRect(-26 * s, 10 * s, 52 * s, 70 * s); ctx.fillStyle = '#eee'; ctx.beginPath(); ctx.ellipse(0, -20 * s, 26 * s, 10 * s, 0, 0, TAU); ctx.fill(); ctx.fillStyle = '#222'; ctx.fillRect(-7 * s, -40 * s, 14 * s, 18 * s); ctx.restore(); }
  };

  // ---------- building blocks ----------
  // stroke-by-stroke line drawing (pen speed constant). bg(ctx) draws what is under the ink each frame.
  async function outline(o, ms, opt = {}) {
    const { ctx, W, H } = o, s = W / 1024, st = strokesOf(o);
    const ink = inkLayer(o, opt.rgb || [20, 20, 20], opt.gain || 3);
    const mask = mk(W, H), mx = mask.getContext('2d'), tmp = mk(W, H);
    mx.lineCap = mx.lineJoin = 'round'; mx.strokeStyle = '#000'; mx.lineWidth = st.width * (opt.widthMul || 1.6) + 5;
    const segs = []; let total = 0;
    for (const p of st.list) for (let i = 1; i < p.length; i++) { const L = Math.hypot(p[i][0] - p[i - 1][0], p[i][1] - p[i - 1][1]); segs.push([p[i - 1], p[i], total, L]); total += L; }
    const bg = opt.bg || (c => paper(c, W, H));
    let si = 0, tip = null;
    await run(o, ms, t => {
      const reach = ease(t * 0.97 + 0.03) * total;   // a bit slower at start and end, like a hand
      mx.beginPath();
      while (si < segs.length && segs[si][2] + segs[si][3] <= reach) { const [A, B] = segs[si]; mx.moveTo(A[0], A[1]); mx.lineTo(B[0], B[1]); tip = B; si++; }
      if (si < segs.length && segs[si][2] < reach) { const [A, B, s0, L] = segs[si]; const f = (reach - s0) / L; tip = [A[0] + (B[0] - A[0]) * f, A[1] + (B[1] - A[1]) * f]; mx.moveTo(A[0], A[1]); mx.lineTo(tip[0], tip[1]); }
      mx.stroke();
      bg(ctx); if (total) through(ctx, tmp, mask, ink, W, H); else { ctx.globalAlpha = t; ctx.drawImage(ink, 0, 0); ctx.globalAlpha = 1; }
      if (tip && t < 1) (tools[opt.tool] || tools.pencil)(ctx, tip[0], tip[1], s);
    });
    bg(ctx); ctx.drawImage(ink, 0, 0);
    return ink;
  }
  // colour revealed by brush dabs region by region. base(ctx) = what is under the paint (paper + ink...)
  async function paint(o, ms, opt = {}) {
    const { ctx, W, H, final } = o, s = W / 1024, R = regions(o);
    const order = regionOrder(R, opt.bg !== false), step = opt.step || 2;
    const dabs = []; for (const l of order) dabs.push(...dabPath(R, [l], step));
    const r = (opt.radius || 2.2) * Math.max(R.cw, R.ch), spr = sprite(r, opt.hard || 0.45);
    const mask = mk(W, H), mx = mask.getContext('2d'), tmp = mk(W, H);
    let di = 0, cur = null;
    await run(o, ms, t => {
      const want = Math.floor(easeOut(t * 1.02) * dabs.length);
      mx.globalAlpha = opt.alpha || 0.6;
      while (di < want && di < dabs.length) { const d = dabs[di++]; mx.drawImage(spr, d.x - r + rnd(-2, 2), d.y - r + rnd(-2, 2)); cur = d; }
      mx.globalAlpha = 1;
      opt.base(ctx); through(ctx, tmp, mask, final, W, H);
      if (opt.inkOver) { ctx.globalAlpha = 0.35; ctx.drawImage(opt.inkOver, 0, 0); ctx.globalAlpha = 1; }
      if (cur && t < 1) (tools[opt.tool] || tools.brush)(ctx, cur.x, cur.y, s, cur.c);
    });
    return mask;
  }
  function star(ctx, x, y, r, a) {
    ctx.save(); ctx.globalAlpha = a; ctx.translate(x, y); ctx.fillStyle = '#fff'; ctx.shadowColor = '#fff8b0'; ctx.shadowBlur = r;
    ctx.beginPath(); for (let i = 0; i < 8; i++) { const rr = i % 2 ? r * 0.18 : r, an = i * Math.PI / 4; ctx.lineTo(Math.cos(an) * rr, Math.sin(an) * rr); } ctx.closePath(); ctx.fill(); ctx.restore();
  }
  function brightSpots(o, n) {            // places for sparkles/glints: bright, non-background cells
    const R = regions(o), out = [];
    for (let i = 0; i < R.lab.length; i++) { const c = R.col[i], L = (c[0] + c[1] + c[2]) / 3; if (R.lab[i] && L > 170) out.push([(i % R.gw + .5) * R.cw, (Math.floor(i / R.gw) + .5) * R.ch]); }
    const pick = []; for (let i = 0; i < n; i++) pick.push(out.length ? out[Math.floor(Math.random() * out.length)] : [rnd(0, o.W), rnd(0, o.H)]);
    return pick;
  }
  const snap = (W, H, draw) => { const c = mk(W, H); draw(c.getContext('2d')); return c; };

  // ---------- styles ----------
  const S = {};

  // Caricature: pencil outline, then brush paint region by region (skin, hair, clothes, rest)
  S.caricature = async (o, T) => {
    const { W, H } = o, tPaint = Math.min(15, T * 0.34), tLine = T - tPaint - 1;
    const ink = await outline(o, tLine * 1000, { tool: 'pencil' });
    const base = snap(W, H, c => { paper(c, W, H); c.drawImage(ink, 0, 0); });
    await paint(o, tPaint * 1000, { base: c => c.drawImage(base, 0, 0), inkOver: ink, tool: 'brush' });
    await settle(o, 900);
  };

  // Headshot: charcoal sketch + hatch shading, then soft airbrush colour
  S.headshot = async (o, T) => {
    const { ctx, W, H, art } = o, s = W / 1024;
    const ink = await outline(o, T * 0.45 * 1000, { tool: 'charcoal', rgb: [34, 31, 30], gain: 3.1, widthMul: 2.3 });
    // hatch layer: diagonal charcoal lines only where the picture is dark
    const sh = mk(96, Math.round(96 * H / W)), sx = sh.getContext('2d'); sx.drawImage(art, 0, 0, sh.width, sh.height);
    const d = sx.getImageData(0, 0, sh.width, sh.height);
    for (let i = 0; i < d.data.length; i += 4) { const L = (d.data[i] + d.data[i + 1] + d.data[i + 2]) / 3; d.data[i + 3] = clamp((190 - L) * 1.6, 0, 200); }
    sx.putImageData(d, 0, 0);
    const hatch = mk(W, H), hx = hatch.getContext('2d'); hx.drawImage(sh, 0, 0, W, H); hx.globalCompositeOperation = 'source-in';
    hx.strokeStyle = 'rgba(45,42,40,.55)'; hx.lineWidth = 2 * s;
    for (let k = -H; k < W + H; k += 9 * s) { hx.beginPath(); hx.moveTo(k, 0); hx.lineTo(k - H * 0.6, H); hx.stroke(); }
    const tmp = mk(W, H);
    const wipe = mk(W, H), wx = wipe.getContext('2d');
    await run(o, T * 0.2 * 1000, t => {
      const y = ease(t) * H * 1.05; wx.clearRect(0, 0, W, H); const gr = wx.createLinearGradient(0, y - 80 * s, 0, y);
      gr.addColorStop(0, '#000'); gr.addColorStop(1, 'rgba(0,0,0,0)'); wx.fillStyle = gr; wx.fillRect(0, 0, W, y);
      paper(ctx, W, H); ctx.drawImage(ink, 0, 0); through(ctx, tmp, wipe, hatch, W, H);
      if (t < 1) tools.charcoal(ctx, (Math.sin(t * 60) * .45 + .5) * W, y - 20 * s, s);
    });
    const base = snap(W, H, c => { paper(c, W, H); c.drawImage(ink, 0, 0); c.drawImage(hatch, 0, 0); });
    await paint(o, T * 0.3 * 1000, { base: c => c.drawImage(base, 0, 0), tool: 'airbrush', radius: 4, alpha: 0.28, hard: 0.1, step: 2, inkOver: ink });
    await settle(o, 900);
  };

  // 3D cartoon: grey clay version sharpens out of blur, light sweep brings colour + shine
  S.pixar = async (o, T) => {
    const { ctx, W, H, final } = o, s = W / 1024;
    const grey = snap(W, H, c => { c.filter = 'grayscale(1) contrast(.85) brightness(1.08)'; c.drawImage(final, 0, 0, W, H); c.filter = 'none'; });
    await run(o, T * 0.4 * 1000, t => {
      const e = ease(t); paper(ctx, W, H); ctx.save(); ctx.globalAlpha = clamp(t * 3);
      ctx.filter = `blur(${(1 - e) * 26 * s}px)`; const z = 1.08 - 0.08 * e; ctx.translate(W / 2, H / 2); ctx.scale(z, z); ctx.drawImage(grey, -W / 2, -H / 2); ctx.restore();
    });
    const D = W + H * 0.5;
    await run(o, T * 0.45 * 1000, t => {
      const p = -0.15 * D + ease(t) * D * 1.3;
      ctx.drawImage(grey, 0, 0);
      ctx.save(); ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(p, 0); ctx.lineTo(p - H * 0.5, H); ctx.lineTo(0, H); ctx.closePath(); ctx.clip(); ctx.drawImage(final, 0, 0, W, H); ctx.restore();
      ctx.save(); ctx.globalCompositeOperation = 'lighter'; const gr = ctx.createLinearGradient(p - 140 * s, 0, p + 40 * s, -H * 0.1);
      gr.addColorStop(0, 'rgba(255,250,230,0)'); gr.addColorStop(0.8, 'rgba(255,250,230,.55)'); gr.addColorStop(1, 'rgba(255,250,230,0)');
      ctx.fillStyle = gr; ctx.beginPath(); ctx.moveTo(p - 160 * s, 0); ctx.lineTo(p + 40 * s, 0); ctx.lineTo(p + 40 * s - H * 0.5, H); ctx.lineTo(p - 160 * s - H * 0.5, H); ctx.closePath(); ctx.fill(); ctx.restore();
    });
    const pts = brightSpots(o, 9);
    await run(o, T * 0.15 * 1000, t => {
      ctx.drawImage(final, 0, 0, W, H);
      pts.forEach(([x, y], i) => { const f = seg(t, i * 0.07, i * 0.07 + 0.35); if (f > 0 && f < 1) star(ctx, x, y, 34 * s * Math.sin(f * Math.PI), Math.sin(f * Math.PI)); });
    });
    ctx.drawImage(final, 0, 0, W, H);
  };

  // Anime: clean ink lines, flat colour pops per region (bucket fill), sparkles
  S.anime = async (o, T) => {
    const { ctx, W, H, final } = o, s = W / 1024;
    const ink = await outline(o, T * 0.5 * 1000, { tool: 'nib', gain: 4, widthMul: 1.3 });
    const R = regions(o), order = regionOrder(R, true);
    const acc = mk(W, H), ax = acc.getContext('2d'), tmp = mk(W, H), tx = tmp.getContext('2d');
    const per = (T * 0.38 * 1000) / Math.max(1, order.length);
    for (const l of order) {
      const m = regionMask(R, [l]); let sx = 0, sy = 0, n = 0;
      for (let i = 0; i < R.lab.length; i++) if (R.lab[i] === l) { sx += i % R.gw; sy += Math.floor(i / R.gw); n++; }
      const cx = (sx / n + .5) * R.cw, cy = (sy / n + .5) * R.ch, maxR = Math.hypot(W, H);
      await run(o, per, t => {
        const rr = easeOut(t / 0.7) * maxR * 0.75;
        tx.globalCompositeOperation = 'copy'; tx.drawImage(m, 0, 0, W, H);
        tx.globalCompositeOperation = 'destination-in'; tx.beginPath(); tx.arc(cx, cy, rr, 0, TAU); tx.fill();
        tx.globalCompositeOperation = 'source-in'; tx.drawImage(final, 0, 0, W, H); tx.globalCompositeOperation = 'source-over';
        paper(ctx, W, H); ctx.drawImage(acc, 0, 0); ctx.drawImage(tmp, 0, 0); ctx.drawImage(ink, 0, 0);
        if (t < 0.5) { ctx.save(); ctx.globalAlpha = 0.5 * (1 - t * 2); ctx.globalCompositeOperation = 'lighter'; ctx.drawImage(tmp, 0, 0); ctx.restore(); }  // pop flash
      });
      ax.drawImage(tmp, 0, 0);
    }
    const pts = brightSpots(o, 14).concat(Array.from({ length: 8 }, () => [rnd(0, W), rnd(0, H * 0.4)]));
    await run(o, T * 0.12 * 1000, t => {
      ctx.drawImage(final, 0, 0, W, H); ctx.globalAlpha = 1 - ease(t); ctx.drawImage(acc, 0, 0); ctx.drawImage(ink, 0, 0); ctx.globalAlpha = 1;
      ctx.globalAlpha = ease(t); ctx.drawImage(final, 0, 0, W, H); ctx.globalAlpha = 1;
      pts.forEach(([x, y], i) => { const f = seg(t, (i % 7) * 0.08, (i % 7) * 0.08 + 0.45); if (f > 0 && f < 1) star(ctx, x, y, 30 * s * Math.sin(f * Math.PI), Math.sin(f * Math.PI)); });
    });
    ctx.drawImage(final, 0, 0, W, H);
  };

  // Graffiti: brick wall, spray-can mist reveal with drips
  function bricks(W, H) {
    return snap(W, H, c => {
      c.fillStyle = '#8f8a84'; c.fillRect(0, 0, W, H);
      const bh = H / 22, bw = W / 7;
      for (let r = 0; r * bh < H; r++) for (let k = -1; k * bw < W; k++) {
        const x = k * bw + (r % 2 ? bw / 2 : 0), y = r * bh, v = rnd(-18, 18);
        c.fillStyle = `rgb(${172 + v},${84 + v * .6},${62 + v * .5})`; c.fillRect(x + 3, y + 3, bw - 6, bh - 6);
        for (let i = 0; i < 30; i++) { c.fillStyle = `rgba(0,0,0,${rnd(0, .12)})`; c.fillRect(x + rnd(3, bw - 6), y + rnd(3, bh - 6), rnd(2, 8), rnd(1, 4)); }
      }
      const gr = c.createRadialGradient(W / 2, H / 2, H * 0.2, W / 2, H / 2, H * 0.8); gr.addColorStop(0, 'rgba(0,0,0,0)'); gr.addColorStop(1, 'rgba(0,0,0,.35)'); c.fillStyle = gr; c.fillRect(0, 0, W, H);
    });
  }
  S.graffiti = async (o, T) => {
    const { ctx, W, H, final } = o, s = W / 1024, wall = bricks(W, H), R = regions(o);
    const white = snap(W, H, c => { c.fillStyle = '#fff'; c.fillRect(0, 0, W, H); c.drawImage(final, 0, 0, W, H); });   // paint over the wall
    await run(o, T * 0.08 * 1000, t => { ctx.drawImage(wall, 0, 0); ctx.fillStyle = `rgba(0,0,0,${0.6 * (1 - t)})`; ctx.fillRect(0, 0, W, H); });
    const dabs = []; for (const l of regionOrder(R, false)) dabs.push(...dabPath(R, [l], 2));
    const mask = mk(W, H), mx = mask.getContext('2d'), tmp = mk(W, H), drip = mk(W, H), dx = drip.getContext('2d'), drips = [];
    const r = 2.6 * R.cw; let di = 0, cur = null;
    await run(o, T * 0.8 * 1000, t => {
      const want = Math.floor(ease(t) * dabs.length);
      while (di < want) {
        const d = dabs[di++]; cur = d;
        for (let i = 0; i < 26; i++) { const a = rnd(0, TAU), q = Math.abs(rnd(-1, 1) + rnd(-1, 1)) / 2 * r; mx.fillStyle = `rgba(0,0,0,${rnd(.3, .8)})`; mx.beginPath(); mx.arc(d.x + Math.cos(a) * q, d.y + Math.sin(a) * q, rnd(1.5, 4.5) * s, 0, TAU); mx.fill(); }
        if (Math.random() < 0.03 && d.c && d.c[0] + d.c[1] + d.c[2] > 240) drips.push({ x: d.x + rnd(-r / 2, r / 2), y: d.y, len: rnd(40, 150) * s, p: 0, c: d.c, w: rnd(3, 6) * s });
      }
      dx.clearRect(0, 0, W, H);
      for (const k of drips) { k.p = Math.min(1, k.p + 0.012); const L = k.len * easeOut(k.p); dx.fillStyle = `rgba(${k.c[0]},${k.c[1]},${k.c[2]},.85)`; dx.fillRect(k.x - k.w / 2, k.y, k.w, L); dx.beginPath(); dx.arc(k.x, k.y + L, k.w * 0.9, 0, TAU); dx.fill(); }
      ctx.drawImage(wall, 0, 0); through(ctx, tmp, mask, white, W, H); ctx.drawImage(drip, 0, 0);
      if (cur && t < 1) {
        const c = cur.c || [255, 255, 255], gr = ctx.createRadialGradient(cur.x, cur.y, 0, cur.x, cur.y, r * 2.2);
        gr.addColorStop(0, `rgba(${c[0]},${c[1]},${c[2]},.35)`); gr.addColorStop(1, `rgba(${c[0]},${c[1]},${c[2]},0)`); ctx.fillStyle = gr; ctx.fillRect(cur.x - r * 2.2, cur.y - r * 2.2, r * 4.4, r * 4.4);
        tools.can(ctx, cur.x, cur.y, s, c);
      }
    });
    const snapC = snap(W, H, c => { c.drawImage(ctx.canvas, 0, 0); });
    await settle(o, T * 0.12 * 1000, () => ctx.drawImage(snapC, 0, 0));
  };

  // Superhero: comic halftone, flash burst + POW, panel slam
  S.superhero = async (o, T) => {
    const { ctx, W, H, final } = o, s = W / 1024;
    const step = W / 70, gw = Math.ceil(W / step), gh = Math.ceil(H / step), px = pixels(final, gw, gh);
    const half = snap(W, H, c => {
      c.fillStyle = '#fff6d8'; c.fillRect(0, 0, W, H);
      for (let y = 0; y < gh; y++) for (let x = 0; x < gw; x++) { const j = (y * gw + x) * 4, L = (px[j] + px[j + 1] + px[j + 2]) / 765; c.fillStyle = `rgb(${px[j]},${px[j + 1]},${px[j + 2]})`; c.beginPath(); c.arc((x + (y % 2) * .5) * step, (y + .5) * step, step * 0.62 * Math.sqrt(1 - L * 0.85), 0, TAU); c.fill(); }
    });
    const rays = (rot, col1, col2) => { ctx.fillStyle = col1; ctx.fillRect(0, 0, W, H); ctx.save(); ctx.translate(W / 2, H * 0.45); ctx.rotate(rot); ctx.fillStyle = col2; for (let i = 0; i < 18; i++) { ctx.beginPath(); ctx.moveTo(0, 0); ctx.arc(0, 0, H * 1.2, i * TAU / 18, i * TAU / 18 + TAU / 36); ctx.fill(); } ctx.restore(); };
    await run(o, T * 0.3 * 1000, (t, ms) => {
      rays(ms / 4000, '#ffd23f', '#ffb000');
      ctx.save(); ctx.beginPath(); ctx.arc(W / 2, H * 0.45, easeOut(t) * Math.hypot(W, H) * 0.6, 0, TAU); ctx.clip(); ctx.drawImage(half, 0, 0); ctx.restore();
    });
    const burst = (x, y, r, n) => { ctx.beginPath(); for (let i = 0; i < n * 2; i++) { const rr = i % 2 ? r * 0.55 : r * rnd(.9, 1.1), a = i * Math.PI / n; ctx.lineTo(x + Math.cos(a) * rr, y + Math.sin(a) * rr); } ctx.closePath(); };
    await run(o, T * 0.2 * 1000, t => {
      ctx.drawImage(half, 0, 0);
      const k = backOut(seg(t, 0.05, 0.5)); ctx.save(); ctx.translate(W / 2, H * 0.42); ctx.rotate(-0.18); ctx.scale(k, k);
      ctx.fillStyle = '#e8202a'; ctx.strokeStyle = '#111'; ctx.lineWidth = 10 * s; burst(0, 0, W * 0.42, 14); ctx.fill(); ctx.stroke();
      ctx.fillStyle = '#ffe14d'; burst(0, 0, W * 0.3, 12); ctx.fill();
      ctx.font = `900 ${Math.round(190 * s)}px Impact, "Arial Black", sans-serif`; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.lineWidth = 16 * s; ctx.strokeStyle = '#111'; ctx.strokeText('POW!', 0, 0); ctx.fillStyle = '#fff'; ctx.fillText('POW!', 0, 0); ctx.restore();
      const fl = Math.max(0, 1 - t * 4); if (fl) { ctx.fillStyle = `rgba(255,255,255,${fl})`; ctx.fillRect(0, 0, W, H); }
    });
    await run(o, T * 0.25 * 1000, t => {
      ctx.drawImage(half, 0, 0); ctx.fillStyle = `rgba(0,0,0,${0.3 * t})`; ctx.fillRect(0, 0, W, H);
      const k = 1.6 - 0.6 * backOut(seg(t, 0, 0.35)), sh = t > 0.3 ? Math.max(0, 1 - (t - 0.3) * 4) * 18 * s : 0, m = W * 0.05;
      ctx.save(); ctx.translate(W / 2 + rnd(-sh, sh), H / 2 + rnd(-sh, sh)); ctx.scale(k, k); ctx.rotate((1 - seg(t, 0, .35)) * -0.08);
      ctx.fillStyle = '#111'; ctx.fillRect(-W / 2 + m - 12 * s, -H / 2 + m - 12 * s, W - 2 * m + 24 * s, H - 2 * m + 24 * s);
      ctx.drawImage(final, m, m, W - 2 * m, H - 2 * m, -W / 2 + m, -H / 2 + m, W - 2 * m, H - 2 * m); ctx.restore();
    });
    await run(o, T * 0.25 * 1000, t => {
      const m = W * 0.05 * (1 - ease(seg(t, 0.3, 1)));
      ctx.drawImage(half, 0, 0); ctx.fillStyle = '#111'; ctx.fillRect(m - 12 * s, m - 12 * s, W - 2 * m + 24 * s, H - 2 * m + 24 * s);
      ctx.drawImage(final, m, m, W - 2 * m, H - 2 * m, m, m, W - 2 * m, H - 2 * m);
    });
    ctx.drawImage(final, 0, 0, W, H);
  };

  // Maharaja: gold frame draws itself, sepia old paper turns to colour, gold dust
  S.maharaja = async (o, T) => {
    const { ctx, W, H, final } = o, s = W / 1024, m = W * 0.045, m2 = m + W * 0.035;
    const gold = () => { const gr = ctx.createLinearGradient(0, 0, W, H); ['#8a6212', '#f7d77a', '#b8860b', '#fff1b8', '#9a7016'].forEach((c, i) => gr.addColorStop(i / 4, c)); return gr; };
    const bg = () => { const gr = ctx.createRadialGradient(W / 2, H / 2, 0, W / 2, H / 2, H * 0.8); gr.addColorStop(0, '#5a0f1c'); gr.addColorStop(1, '#1d0207'); ctx.fillStyle = gr; ctx.fillRect(0, 0, W, H); };
    const per = 2 * (W - 2 * m + H - 2 * m), per2 = 2 * (W - 2 * m2 + H - 2 * m2);
    const frame = f => {
      ctx.save(); ctx.strokeStyle = gold(); ctx.lineCap = 'round';
      ctx.lineWidth = 16 * s; ctx.setLineDash([per * f, per * 2]); ctx.strokeRect(m, m, W - 2 * m, H - 2 * m);
      ctx.lineWidth = 5 * s; ctx.setLineDash([per2 * f, per2 * 2]); ctx.strokeRect(m2 - 10 * s, m2 - 10 * s, W - 2 * m2 + 20 * s, H - 2 * m2 + 20 * s); ctx.setLineDash([]);
      const c = seg(f, 0.85, 1); if (c > 0) { ctx.fillStyle = gold(); [[m, m], [W - m, m], [m, H - m], [W - m, H - m]].forEach(([x, y]) => { ctx.beginPath(); ctx.arc(x, y, 26 * s * backOut(c), 0, TAU); ctx.fill(); ctx.beginPath(); ctx.fillStyle = '#5a0f1c'; ctx.arc(x, y, 10 * s * c, 0, TAU); ctx.fill(); ctx.fillStyle = gold(); }); }
      ctx.restore();
    };
    const pic = (sep, a, mi = m2) => { ctx.save(); ctx.globalAlpha = a; if (sep > 0) ctx.filter = `sepia(${sep}) contrast(${1 - .1 * sep}) brightness(${1 - .05 * sep})`; const ar = (W - 2 * mi) / (H - 2 * mi), sw0 = Math.min(W, H * ar), sh0 = sw0 / ar; ctx.drawImage(final, (W - sw0) / 2, (H - sh0) / 2, sw0, sh0, mi, mi, W - 2 * mi, H - 2 * mi); ctx.restore();
      if (sep > 0) { const gr = ctx.createRadialGradient(W / 2, H / 2, H * 0.25, W / 2, H / 2, H * 0.6); gr.addColorStop(0, 'rgba(60,30,0,0)'); gr.addColorStop(1, `rgba(60,30,0,${.45 * sep * a})`); ctx.fillStyle = gr; ctx.fillRect(mi, mi, W - 2 * mi, H - 2 * mi); } };
    const dust = Array.from({ length: 140 }, () => ({ x: rnd(0, W), y: rnd(0, H), v: rnd(.2, 1), r: rnd(1, 3.5), p: rnd(0, TAU) }));
    const sparkle = (ms, amt) => { ctx.save(); ctx.globalCompositeOperation = 'lighter'; for (const d of dust) { const y = (d.y - ms * 0.03 * d.v * s + H * 10) % H, a = amt * (0.5 + 0.5 * Math.sin(ms / 300 + d.p)); ctx.fillStyle = `rgba(255,215,110,${a})`; ctx.beginPath(); ctx.arc(d.x + Math.sin(ms / 900 + d.p) * 12 * s, y, d.r * s, 0, TAU); ctx.fill(); } ctx.restore(); };
    await run(o, T * 0.25 * 1000, (t, ms) => { bg(); frame(ease(t)); sparkle(ms, 0.4 * t); });
    await run(o, T * 0.2 * 1000, (t, ms) => { bg(); pic(1, ease(t)); frame(1); sparkle(ms + T * 250, 0.4); });
    await run(o, T * 0.4 * 1000, (t, ms) => { bg(); pic(1 - ease(t), 1); frame(1); sparkle(ms + T * 450, 0.4 + 0.5 * Math.sin(t * Math.PI)); });
    await run(o, T * 0.15 * 1000, (t, ms) => {
      const e = ease(t); bg(); ctx.save(); ctx.globalAlpha = 1 - e; frame(1); ctx.restore(); pic(0, 1, m2 * (1 - e)); sparkle(ms + T * 850, 0.6 * (1 - e));
    });
    ctx.drawImage(final, 0, 0, W, H);
  };

  // Telugu movie poster: film leader 3-2-1, reveal with lens flare sweep, title slam + glow
  S.poster = async (o, T) => {
    const { ctx, W, H, final, art } = o, s = W / 1024;
    const lead = Math.max(3, T * 0.2) * 1000, R = Math.min(W, H) * 0.36;
    await run(o, lead, (t, ms) => {
      const sec = ms / (lead / 3), n = 3 - Math.floor(sec), f = sec % 1;
      ctx.fillStyle = '#6d6a64'; ctx.fillRect(0, 0, W, H);
      for (let i = 0; i < 260; i++) { ctx.fillStyle = `rgba(${Math.random() < .5 ? '0,0,0' : '255,255,255'},${rnd(.05, .25)})`; ctx.fillRect(rnd(0, W), rnd(0, H), rnd(1, 3) * s, rnd(1, 3) * s); }
      if (Math.random() < 0.3) { ctx.fillStyle = 'rgba(0,0,0,.4)'; ctx.fillRect(rnd(0, W), 0, 2 * s, H); }
      ctx.save(); ctx.translate(W / 2, H / 2); ctx.fillStyle = 'rgba(30,30,30,.55)'; ctx.beginPath(); ctx.moveTo(0, 0); ctx.arc(0, 0, R * 1.6, -Math.PI / 2, -Math.PI / 2 + f * TAU); ctx.fill();
      ctx.strokeStyle = '#eee'; ctx.lineWidth = 6 * s; ctx.beginPath(); ctx.arc(0, 0, R, 0, TAU); ctx.stroke(); ctx.beginPath(); ctx.arc(0, 0, R * 0.82, 0, TAU); ctx.stroke();
      ctx.lineWidth = 3 * s; ctx.beginPath(); ctx.moveTo(-W / 2, 0); ctx.lineTo(W / 2, 0); ctx.moveTo(0, -H / 2); ctx.lineTo(0, H / 2); ctx.stroke();
      ctx.fillStyle = '#fff'; ctx.font = `900 ${Math.round(R * 1.15)}px Impact, "Arial Black", sans-serif`; ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.fillText(String(Math.max(1, n)), 0, R * 0.05); ctx.restore();
    });
    const flare = (x, y, a) => {
      ctx.save(); ctx.globalCompositeOperation = 'lighter';
      const st = ctx.createLinearGradient(0, y, W, y); st.addColorStop(0, 'rgba(80,160,255,0)'); st.addColorStop(clamp(x / W), `rgba(170,220,255,${.75 * a})`); st.addColorStop(1, 'rgba(80,160,255,0)');
      ctx.fillStyle = st; ctx.fillRect(0, y - 5 * s, W, 10 * s);
      const g0 = ctx.createRadialGradient(x, y, 0, x, y, 180 * s); g0.addColorStop(0, `rgba(255,245,220,${a})`); g0.addColorStop(1, 'rgba(255,200,120,0)'); ctx.fillStyle = g0; ctx.fillRect(x - 180 * s, y - 180 * s, 360 * s, 360 * s);
      [0.4, 0.7, 1.2, 1.6].forEach((k, i) => { const fx = x + (W / 2 - x) * k * 2, fy = y + (H / 2 - y) * k * 2, rr = [40, 22, 60, 30][i] * s; ctx.fillStyle = `rgba(${['255,180,90', '120,200,255', '255,120,60', '200,255,180'][i]},${.22 * a})`; ctx.beginPath(); ctx.arc(fx, fy, rr, 0, TAU); ctx.fill(); });
      ctx.restore();
    };
    await run(o, T * 0.45 * 1000, t => {
      const e = ease(t); ctx.fillStyle = '#000'; ctx.fillRect(0, 0, W, H);
      ctx.save(); ctx.filter = `brightness(${0.15 + 0.85 * e}) contrast(${1.25 - .25 * e})`; const z = 1.18 - 0.18 * e; ctx.translate(W / 2, H / 2); ctx.scale(z, z); ctx.drawImage(art, -W / 2, -H / 2, W, H); ctx.restore();
      flare(-0.2 * W + t * 1.4 * W, H * 0.3, Math.sin(t * Math.PI));
    });
    const y0 = H * 0.72;
    await run(o, T * 0.17 * 1000, t => {
      ctx.drawImage(art, 0, 0, W, H); const k = backOut(seg(t, 0, 0.5)), z = 2 - k, sh = Math.max(0, 1 - (t - 0.4) * 4) * (t > .4 ? 14 * s : 0);
      ctx.save(); ctx.globalAlpha = clamp(t * 4); ctx.translate(W / 2 + rnd(-sh, sh), (y0 + H) / 2 + rnd(-sh, sh)); ctx.scale(z, z);
      ctx.drawImage(final, 0, y0, W, H - y0, -W / 2, -(H - y0) / 2, W, H - y0); ctx.restore();
    });
    const glow = snap(W, H, c => { c.filter = `blur(${18 * s}px) brightness(1.3)`; c.drawImage(final, 0, 0, W, H); });
    await run(o, T * 0.18 * 1000, t => {
      ctx.drawImage(final, 0, 0, W, H); ctx.save(); ctx.globalCompositeOperation = 'screen'; ctx.globalAlpha = 0.55 * Math.sin(t * Math.PI); ctx.drawImage(glow, 0, 0); ctx.restore();
      flare(W * (1.1 - t * 0.5), y0 + 40 * s, 0.6 * Math.sin(t * Math.PI));
    });
    ctx.drawImage(final, 0, 0, W, H);
  };

  // v1.5 p3: catalogue styles reuse one of these animations (styles-catalogue.json 'anim'), unknown -> caricature
  const alias = st => { try { const a = g.OS && g.OS.state && g.OS.state.styles && g.OS.state.styles[st]; return a && a.anim && S[a.anim] ? a.anim : null; } catch { return null; } };
  const key = st => S[st] ? st : alias(st) || 'caricature';
  const DEF = { caricature: 45, headshot: 30, pixar: 20, anime: 25, graffiti: 22, superhero: 18, maharaja: 22, poster: 20 };
  const Anim = {
    styles: Object.keys(S),
    has: k => !!S[k] || !!alias(k),
    // caricature: outline = drawSeconds (Admin "Drawing time") + ~15 s paint; others fixed, scaled a little with drawSeconds
    seconds(style, drawSeconds) {
      const k = key(style), d = +drawSeconds || 30;
      if (k === 'caricature') return clamp(d, 10, 90) + 15;
      return Math.round(DEF[k] * clamp(d / 35, 0.6, 1.5));
    },
    // v1.5: one animation per canvas: a new play() on the same canvas stops the old one (it never draws again)
    async play(style, o) {
      const k = key(style);
      o.W = o.W || o.ctx.canvas.width; o.H = o.H || o.ctx.canvas.height;
      const T = Math.max(4, o.seconds || DEF[k]);
      const cv = o.ctx.canvas; if (cv._osSig && cv._osSig !== o.signal) cv._osSig.aborted = true;
      o.signal = o.signal || { aborted: false }; cv._osSig = o.signal;
      o.ctx.save();
      let stopped = false;
      try { await S[k](o, T); }
      catch (e) { if (e && e.aborted) stopped = true; else { console.error('anim', k, e); o.ctx.globalAlpha = 1; o.ctx.drawImage(o.final, 0, 0, o.W, o.H); } }
      finally {
        o.ctx.restore(); o.ctx.filter = 'none'; o.ctx.globalAlpha = 1; o.ctx.globalCompositeOperation = 'source-over';
        if (!stopped && !o.signal.aborted) o.ctx.drawImage(o.final, 0, 0, o.W, o.H);
        if (cv._osSig === o.signal) cv._osSig = null;
      }
      return !stopped;
    },
    // v1.5: find lines / colour regions before the animation (and the reel recording) starts
    prepare(style, o) { try { o.W = o.W || o.ctx.canvas.width; o.H = o.H || o.ctx.canvas.height; strokesOf(o); regions(o); } catch (e) { console.warn('anim prepare', e); } return o; },
    paper
  };
  g.Anim = Anim;
})(this);
