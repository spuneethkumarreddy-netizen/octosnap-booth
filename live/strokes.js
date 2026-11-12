// Turns a finished colour caricature into pen strokes (in the browser, no server work).
// dark outlines -> binary -> Zhang-Suen thinning -> trace paths -> simplify -> order
(function (g) {
  // pencil-sketch filter (colour dodge of gray over blurred inverse): keeps lines and strands,
  // turns big flat dark areas (hair mass, dark shirts) white so the pen draws lines, not blocks
  function sketch(rgba, W, H, radius) {
    const r = radius || Math.max(2, Math.round(Math.max(W, H) / 220));
    const g = new Float32Array(W * H);
    for (let i = 0, j = 0; i < W * H; i++, j += 4) g[i] = 0.299 * rgba[j] + 0.587 * rgba[j + 1] + 0.114 * rgba[j + 2];
    let b = g.slice(); const t = new Float32Array(W * H);
    for (let pass = 0; pass < 3; pass++) {           // 3 box blurs ~ gaussian
      for (let y = 0; y < H; y++) { let acc = 0; const o = y * W; for (let x = -r; x <= r; x++) acc += b[o + Math.min(W - 1, Math.max(0, x))];
        for (let x = 0; x < W; x++) { t[o + x] = acc / (2 * r + 1); acc += b[o + Math.min(W - 1, x + r + 1)] - b[o + Math.max(0, x - r)]; } }
      for (let x = 0; x < W; x++) { let acc = 0; for (let y = -r; y <= r; y++) acc += t[Math.min(H - 1, Math.max(0, y)) * W + x];
        for (let y = 0; y < H; y++) { b[y * W + x] = acc / (2 * r + 1); acc += t[Math.min(H - 1, y + r + 1) * W + x] - t[Math.max(0, y - r) * W + x]; } }
    }
    const out = new Uint8ClampedArray(W * H);
    for (let i = 0; i < W * H; i++) { const v = g[i] * 255 / Math.max(1, b[i]); out[i] = v > 255 ? 255 : v; }
    return out;
  }

  // opt.faces = [{x,y,w,h}] (pixels of this image): inside the faces the threshold is higher and a finer
  // sketch radius is used, so eyes, nose, lips and face contour come out as dense, strong lines (v1.3)
  function extract(rgba, W, H, opt = {}) {
    const thr = opt.threshold || 182, fthr = opt.faceThreshold || 214;
    const sk = sketch(rgba, W, H, opt.radius);
    const faces = (opt.faces || []).map(f => ({ x0: f.x - f.w * 0.22, x1: f.x + f.w * 1.22, y0: f.y - f.h * 0.38, y1: f.y + f.h * 1.18 }));
    const fine = faces.length ? sketch(rgba, W, H, Math.max(1, Math.round((opt.radius || Math.max(2, Math.round(Math.max(W, H) / 220))) * 0.6))) : null;
    const bin = new Uint8Array(W * H), inFace = faces.length ? new Uint8Array(W * H) : null;
    for (const f of faces) for (let y = Math.max(0, f.y0 | 0); y < Math.min(H, f.y1); y++) for (let x = Math.max(0, f.x0 | 0); x < Math.min(W, f.x1); x++) inFace[y * W + x] = 1;
    for (let i = 0; i < W * H; i++) bin[i] = inFace && inFace[i] ? (Math.min(sk[i], fine[i]) < fthr ? 1 : 0) : (sk[i] < thr ? 1 : 0);
    // stroke thickness estimate (before thinning): count dark pixels / skeleton pixels later
    let darkCount = 0; for (let i = 0; i < bin.length; i++) darkCount += bin[i];
    thin(bin, W, H);
    let skel = 0; for (let i = 0; i < bin.length; i++) skel += bin[i];
    const width = Math.max(1.2, Math.min(4, darkCount / Math.max(1, skel)));
    const minLen = opt.minLen || 6, fMin = opt.faceMinLen || 3;
    const faceAt = p => inFace && inFace[p[0][1] * W + p[0][0]];
    let paths = trace(bin, W, H).filter(p => p.length >= (faceAt(p) ? fMin : minLen));
    paths = paths.map(p => rdp(p, faceAt(p) ? Math.min(0.6, opt.eps || 0.9) : (opt.eps || 0.9)));
    return { w: W, h: H, width, strokes: order(paths, W, H) };
  }

  function thin(b, W, H) {
    const idx = (x, y) => y * W + x;
    let changed = true; const del = [];
    while (changed) {
      changed = false;
      for (let pass = 0; pass < 2; pass++) {
        del.length = 0;
        for (let y = 1; y < H - 1; y++) for (let x = 1; x < W - 1; x++) {
          if (!b[idx(x, y)]) continue;
          const p2 = b[idx(x, y - 1)], p3 = b[idx(x + 1, y - 1)], p4 = b[idx(x + 1, y)], p5 = b[idx(x + 1, y + 1)],
            p6 = b[idx(x, y + 1)], p7 = b[idx(x - 1, y + 1)], p8 = b[idx(x - 1, y)], p9 = b[idx(x - 1, y - 1)];
          const B = p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9;
          if (B < 2 || B > 6) continue;
          const A = (!p2 && p3) + (!p3 && p4) + (!p4 && p5) + (!p5 && p6) + (!p6 && p7) + (!p7 && p8) + (!p8 && p9) + (!p9 && p2);
          if (A !== 1) continue;
          if (pass === 0 ? (p2 * p4 * p6 || p4 * p6 * p8) : (p2 * p4 * p8 || p2 * p6 * p8)) continue;
          del.push(idx(x, y));
        }
        if (del.length) { changed = true; for (const i of del) b[i] = 0; }
      }
    }
  }

  const NB = [[1, 0], [0, 1], [-1, 0], [0, -1], [1, 1], [-1, 1], [-1, -1], [1, -1]];
  function trace(b, W, H) {
    const seen = new Uint8Array(W * H), out = [];
    const deg = (x, y) => { let n = 0; for (const [dx, dy] of NB) { const X = x + dx, Y = y + dy; if (X >= 0 && Y >= 0 && X < W && Y < H && b[Y * W + X]) n++; } return n; };
    const walk = (sx, sy) => {
      const pts = [[sx, sy]]; seen[sy * W + sx] = 1; let x = sx, y = sy;
      for (;;) {
        let nx = -1, ny = -1;
        for (const [dx, dy] of NB) { const X = x + dx, Y = y + dy; if (X >= 0 && Y >= 0 && X < W && Y < H && b[Y * W + X] && !seen[Y * W + X]) { nx = X; ny = Y; break; } }
        if (nx < 0) break; seen[ny * W + nx] = 1; pts.push([nx, ny]); x = nx; y = ny;
      }
      return pts;
    };
    // endpoints first so lines run end to end, then loops
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) if (b[y * W + x] && !seen[y * W + x] && deg(x, y) === 1) out.push(walk(x, y));
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) if (b[y * W + x] && !seen[y * W + x]) out.push(walk(x, y));
    return out;
  }

  function rdp(pts, eps) {
    if (pts.length < 3) return pts;
    const [ax, ay] = pts[0], [bx, by] = pts[pts.length - 1];
    const dx = bx - ax, dy = by - ay, L = Math.hypot(dx, dy) || 1;
    let mi = 0, md = 0;
    for (let i = 1; i < pts.length - 1; i++) { const d = Math.abs(dy * pts[i][0] - dx * pts[i][1] + bx * ay - by * ax) / L; if (d > md) { md = d; mi = i; } }
    if (md > eps) return rdp(pts.slice(0, mi + 1), eps).slice(0, -1).concat(rdp(pts.slice(mi), eps));
    return [pts[0], pts[pts.length - 1]];
  }

  const plen = p => { let s = 0; for (let i = 1; i < p.length; i++) s += Math.hypot(p[i][0] - p[i - 1][0], p[i][1] - p[i - 1][1]); return s; };
  // like a real artist: long contour lines first (face/head area first: start top-centre), then details
  function order(paths, W, H) {
    const long = [], short = [];
    for (const p of paths) (plen(p) >= Math.max(W, H) * 0.035 ? long : short).push(p);
    const greedy = (list, start) => {
      const res = []; let cx = start[0], cy = start[1];
      const left = list.slice();
      while (left.length) {
        let bi = 0, bd = Infinity, rev = false;
        for (let i = 0; i < left.length; i++) {
          const p = left[i], a = p[0], z = p[p.length - 1];
          // prefer upper part of the picture early (heads before bodies)
          const bias = 0.35 * Math.max(0, Math.min(a[1], z[1]) - cy);
          const da = Math.hypot(a[0] - cx, a[1] - cy) + bias, dz = Math.hypot(z[0] - cx, z[1] - cy) + bias;
          if (da < bd) { bd = da; bi = i; rev = false; } if (dz < bd) { bd = dz; bi = i; rev = true; }
        }
        let p = left.splice(bi, 1)[0]; if (rev) p = p.slice().reverse();
        res.push(p); const e = p[p.length - 1]; cx = e[0]; cy = e[1];
      }
      return res;
    };
    const a = greedy(long, [W / 2, H * 0.2]);
    const last = a.length ? a[a.length - 1].slice(-1)[0] : [W / 2, H * 0.2];
    return a.concat(greedy(short, last));
  }

  const api = { extract, sketch, plen };
  if (typeof module !== 'undefined') module.exports = api; else g.Strokes = api;
})(this);
