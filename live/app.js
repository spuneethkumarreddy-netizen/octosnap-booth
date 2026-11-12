// OctoSnap Live mobile v2.0: the whole AI caricature booth on one Android phone (no laptop, no server).
// Settings + OpenAI key: localStorage (this phone only). Pictures: IndexedDB. AI: OpenAI /v1/images/edits straight from the phone.
// Test mode (default) makes a free cartoon-like picture on the phone, so nothing is spent while testing.
'use strict';
const $ = id => document.getElementById(id);
const VERSION = '2.0.0', COST_INR = 4, MODEL = 'gpt-image-2.6-flare';
const LS = { get: (k, d) => { try { const v = localStorage.getItem('osm_' + k); return v == null ? d : JSON.parse(v); } catch { return d; } }, set: (k, v) => { try { localStorage.setItem('osm_' + k, JSON.stringify(v)); } catch {} } };
const today = () => new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10);
const DEF = { event: 'OctoSnap Live', date: today(), footer: 'OctoSnap Photo Booths · Hyderabad · @octo_snap', copies: 1, drawSec: 25, retakes: 1, limit: '', styles: ['caricature', 'pixar'], mode: 'test', pin: '', eventId: 'ev' + Date.now().toString(36) };
let cfg = Object.assign({}, DEF, LS.get('cfg', {}));
let CAT = null, STY = {};
const st = { style: null, people: 0, facing: 'user', stream: null, photo: null, cur: null, busy: false, signal: null, lastLook: {} };
function toast(t, ms = 2600) { const e = $('toast'); e.textContent = t; e.style.display = 'block'; clearTimeout(toast._t); toast._t = setTimeout(() => e.style.display = 'none', ms); }
const sleep = ms => new Promise(r => setTimeout(r, ms));
const seg = (id, val, fn) => { const box = $(id); box.querySelectorAll('button').forEach(b => { b.classList.toggle('on', b.dataset.v === String(val)); b.onclick = () => { box.querySelectorAll('button').forEach(x => x.classList.toggle('on', x === b)); fn && fn(b.dataset.v); }; }); };
const segVal = id => { const b = $(id).querySelector('button.on'); return b ? b.dataset.v : null; };

// ---------- pictures (IndexedDB) ----------
const DB = { db: null,
  open() { return this.db ? Promise.resolve(this.db) : new Promise((res, rej) => { const r = indexedDB.open('octosnap-mobile', 1); r.onupgradeneeded = () => { const s = r.result.createObjectStore('pics', { keyPath: 'id' }); s.createIndex('ev', 'ev'); }; r.onsuccess = () => res(this.db = r.result); r.onerror = () => rej(r.error); }); },
  async tx(mode, fn) { const db = await this.open(); return new Promise((res, rej) => { const t = db.transaction('pics', mode), s = t.objectStore('pics'); const out = fn(s); t.oncomplete = () => res(out && out.result !== undefined ? out.result : out); t.onerror = () => rej(t.error); }); },
  put(p) { return this.tx('readwrite', s => s.put(p)); },
  get(id) { return this.tx('readonly', s => s.get(id)); },
  event(ev) { return this.tx('readonly', s => s.index('ev').getAll(ev)); }
};

// ---------- styles + prompt (same catalogue and approved identity block as the laptop app) ----------
function fill(t, n, ex = {}) { t = String(t || ''); if (!(n > 0)) t = t.replace(/exactly \{people_count\}/g, 'exactly the same number of').replace(/\{people_count\}/g, 'all the'); else t = t.replace(/\{people_count\}/g, String(n)); return t.replace(/\{(\w+)\}/g, (m, k) => ex[k] != null ? String(ex[k]) : m); }
const compKey = n => !(n > 0) ? null : n === 1 ? 'solo' : n === 2 ? 'couple' : n <= 4 ? 'group' : 'large';
function buildPrompt(styleKey, people, landscapePhoto) {
  const s = STY[styleKey] || STY.caricature, n = +people || 0;
  let looks = s.looks; const prev = st.lastLook[styleKey];
  if (looks.length > 1 && prev) looks = looks.filter(l => l.id !== prev);
  const look = looks[Math.floor(Math.random() * looks.length)]; st.lastLook[styleKey] = look.id;
  const parts = [fill(CAT.basePrompt, n), fill(look.prompt, n)];
  if (s.detail) parts.push(s.detail); if (look.detail) parts.push(look.detail);
  const ck = compKey(n); if (ck) parts.push(fill(CAT.composition[ck], n));
  parts.push(fill(CAT.identityBlock, n));
  const land = n > 0 ? n > CAT.sizes.portraitUpTo : !!landscapePhoto;
  return { prompt: parts.join('\n\n'), size: land ? CAT.sizes.landscape : CAT.sizes.portrait, look: look.id };
}

// ---------- camera (live preview needs https; the app is served over https) ----------
async function camStart() {
  camStop(); $('camMsg').textContent = 'Starting camera…'; $('camMsg').style.display = 'flex';
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) { $('camMsg').textContent = 'Live camera not available here. Use 🖼 to pick or take a photo.'; return; }
  try {
    st.stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: st.facing, width: { ideal: 1920 }, height: { ideal: 1440 } } });
    const v = $('video'); v.srcObject = st.stream; v.classList.toggle('mirror', st.facing === 'user'); await v.play().catch(() => {});
    $('camMsg').style.display = 'none';
  } catch (e) { $('camMsg').textContent = 'Camera blocked: allow camera for this app in Chrome (🔒 → Permissions), or use 🖼.'; }
}
function camStop() { if (st.stream) { st.stream.getTracks().forEach(t => t.stop()); st.stream = null; } }
async function snap() {
  if (st.busy) return; const v = $('video');
  if (!st.stream || !v.videoWidth) return $('file').click();
  st.busy = true;
  for (const n of [3, 2, 1]) { $('cd').textContent = n; await sleep(900); }
  $('cd').textContent = ''; $('flash').style.transition = 'none'; $('flash').style.opacity = 1; requestAnimationFrame(() => { $('flash').style.transition = 'opacity .5s'; $('flash').style.opacity = 0; });
  const c = document.createElement('canvas'); c.width = v.videoWidth; c.height = v.videoHeight; const x = c.getContext('2d');
  if (st.facing === 'user') { x.translate(c.width, 0); x.scale(-1, 1); }
  x.drawImage(v, 0, 0); st.busy = false;
  setPhoto(c);
}
async function fromFile(f) { if (!f) return; const img = await loadImg(URL.createObjectURL(f)); const c = document.createElement('canvas'); c.width = img.naturalWidth; c.height = img.naturalHeight; c.getContext('2d').drawImage(img, 0, 0); setPhoto(c); }
function setPhoto(c) {
  st.photo = scaleCanvas(c, 1536);
  $('shot').src = st.photo.toDataURL('image/jpeg', 0.9); $('shot').style.display = 'block'; $('video').style.display = 'none'; $('camMsg').style.display = 'none';
  $('shootBar').style.display = 'none'; $('reviewBar').style.display = 'block';
}
function resetBooth() {
  st.photo = null; $('shot').style.display = 'none'; $('video').style.display = 'block'; $('shootBar').style.display = 'flex'; $('reviewBar').style.display = 'none';
  if (!st.stream) camStart();
}
function scaleCanvas(src, max) { const k = Math.min(1, max / Math.max(src.width, src.height)); if (k === 1) return src; const c = document.createElement('canvas'); c.width = Math.round(src.width * k); c.height = Math.round(src.height * k); c.getContext('2d').drawImage(src, 0, 0, c.width, c.height); return c; }
const loadImg = src => new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = rej; i.src = src; });
const toBlob = (c, type = 'image/jpeg', q = 0.92) => new Promise(r => c.toBlob(r, type, q));

// ---------- AI ----------
async function aiReal(photo, pr) {
  const key = LS.get('key', ''); if (!key) throw new Error('No OpenAI key. Settings → AI → paste the key, or switch to Test mode.');
  const fd = new FormData(); fd.append('model', MODEL); fd.append('prompt', pr.prompt); fd.append('size', pr.size); fd.append('quality', 'high'); fd.append('n', '1');
  fd.append('image', await toBlob(scaleCanvas(photo, 1024), 'image/jpeg', 0.9), 'guest.jpg');
  const ac = new AbortController(), to = setTimeout(() => ac.abort(), 180000);
  let r; try { r = await fetch('https://api.openai.com/v1/images/edits', { method: 'POST', headers: { Authorization: 'Bearer ' + key }, body: fd, signal: ac.signal }); }
  catch (e) { throw new Error(ac.signal.aborted ? 'AI took too long (3 min). Check internet and try again.' : 'No internet / OpenAI not reachable. Check mobile data or Wi-Fi.'); }
  finally { clearTimeout(to); }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) { const m = (j.error && j.error.message) || ('HTTP ' + r.status); throw new Error(r.status === 401 ? 'OpenAI key is wrong or revoked.' : /billing|quota|credit/i.test(m) ? 'OpenAI credits are finished. Add credits at platform.openai.com.' : /safety|moderation/i.test(m) ? 'OpenAI refused this photo (safety). Retake with a different photo.' : m); }
  const b64 = j.data && j.data[0] && j.data[0].b64_json; if (!b64) throw new Error('OpenAI sent no picture.');
  return loadImg('data:image/png;base64,' + b64);
}
// free test picture: cartoon look made on the phone (posterised colour + ink lines from the sketch filter)
async function aiTest(photo, pr) {
  await sleep(2500);
  const [w, h] = pr.size.split('x').map(Number), c = document.createElement('canvas'); c.width = w; c.height = h; const x = c.getContext('2d');
  x.fillStyle = '#fff'; x.fillRect(0, 0, w, h);
  const k = Math.max(w / photo.width, h / photo.height); x.drawImage(photo, (w - photo.width * k) / 2, (h - photo.height * k) / 2, photo.width * k, photo.height * k);
  const d = x.getImageData(0, 0, w, h), a = d.data, sk = Strokes.sketch(a, w, h);
  for (let i = 0, j = 0; i < sk.length; i++, j += 4) { const ink = sk[i] < 200 ? 1 - sk[i] / 200 : 0; for (let q = 0; q < 3; q++) { let v = Math.round(a[j + q] / 52) * 52 + 20; v = v * (1 - ink) + 25 * ink; a[j + q] = Math.min(255, v); } }
  x.putImageData(d, 0, 0);
  x.fillStyle = '#e11d48cc'; x.font = `800 ${Math.round(w / 14)}px system-ui,sans-serif`; x.textAlign = 'center'; x.fillText('TEST', w / 2, h * 0.08);
  return loadImg(c.toDataURL('image/jpeg', 0.92));
}
// the finished picture = AI art + guest name label (drawn by the app, so spelling is always right)
function finalCanvas(art, name) {
  const c = document.createElement('canvas'); c.width = art.naturalWidth || art.width; c.height = art.naturalHeight || art.height; const x = c.getContext('2d');
  x.drawImage(art, 0, 0, c.width, c.height);
  if (name) { const fs = Math.round(c.width / 15); x.font = `800 ${fs}px Georgia,serif`; const tw = x.measureText(name).width, pw = tw + fs * 1.4, ph = fs * 1.6, px = (c.width - pw) / 2, py = c.height - ph - c.height * 0.03;
    x.fillStyle = '#ffffffee'; x.strokeStyle = '#7a1430'; x.lineWidth = Math.max(3, fs / 9); x.beginPath(); x.roundRect(px, py, pw, ph, ph / 2); x.fill(); x.stroke();
    x.fillStyle = '#3a0715'; x.textAlign = 'center'; x.textBaseline = 'middle'; x.fillText(name, c.width / 2, py + ph / 2 + fs * 0.05); }
  return c;
}

// ---------- one guest: photo -> AI -> drawing animation -> result ----------
async function makePicture(isRetake) {
  if (!st.photo) return;
  if (!st.style) return toast('Pick a style first');
  const lim = +cfg.limit; const pics = await DB.event(cfg.eventId);
  if (cfg.mode === 'real' && lim > 0 && pics.filter(p => p.mode === 'real').length >= lim) return toast(`AI limit reached (${lim}). Change it in Settings.`);
  show('vDraw'); camStop();
  const cv = $('drawCv'), x = cv.getContext('2d'); $('resBar').style.display = 'none'; $('errBar').style.display = 'none';
  const pr = buildPrompt(st.style, st.people, st.photo.width > st.photo.height);
  const [W, H] = pr.size.split('x').map(Number); cv.width = W; cv.height = H; Anim.paper(x, W, H);
  if (st.signal) st.signal.aborted = true; const sig = st.signal = { aborted: false };
  $('drawMsg').textContent = cfg.mode === 'real' ? 'The artist is drawing… (about 30–60 s)' : 'Test mode: making a free sample picture…';
  waitAnim(x, W, H, sig);
  let art;
  try { art = await (cfg.mode === 'real' ? aiReal : aiTest)(st.photo, pr); }
  catch (e) { sig.aborted = true; Anim.paper(x, W, H); $('drawMsg').textContent = '⚠ ' + e.message; $('errBar').style.display = 'block'; return; }
  sig.aborted = true;
  const name = $('gName').value.trim(), fin = finalCanvas(art, name);
  const p = { id: 'p' + Date.now().toString(36) + Math.random().toString(36).slice(2, 5), ev: cfg.eventId, at: Date.now(), style: st.style, look: pr.look, people: st.people, name, mode: cfg.mode,
    cost: cfg.mode === 'real' ? COST_INR : 0, prints: 0, retakes: isRetake && st.cur ? (st.cur.retakes || 0) + 1 : 0, w: W, h: H,
    art: await toBlob(fin === art ? fin : (() => { const c = document.createElement('canvas'); c.width = W; c.height = H; c.getContext('2d').drawImage(art, 0, 0, W, H); return c; })(), 'image/jpeg', 0.93),
    final: await toBlob(fin, 'image/jpeg', 0.93) };
  await DB.put(p); st.cur = p; refreshGallery();
  $('drawMsg').textContent = '';
  const s2 = st.signal = { aborted: false };
  if (cfg.tv && cv.requestFullscreen) cv.requestFullscreen().catch(() => {});
  try { await Anim.play(STY[st.style] && STY[st.style].anim || st.style, { ctx: x, art, final: fin, W, H, seconds: Anim.seconds(STY[st.style] && STY[st.style].anim || st.style, cfg.drawSec), signal: s2 }); } catch {}
  if (document.fullscreenElement) setTimeout(() => document.exitFullscreen().catch(() => {}), 4000);
  if (s2.aborted) return;
  $('drawMsg').textContent = name ? `Ready, ${name}!` : 'Ready!';
  $('resBar').style.display = 'block'; updRetake();
}
async function waitAnim(x, W, H, sig) {           // pencil wiggle while the AI works
  const t0 = performance.now();
  while (!sig.aborted) {
    const t = (performance.now() - t0) / 1000; Anim.paper(x, W, H);
    x.save(); x.translate(W / 2 + Math.sin(t * 2.2) * W * 0.18, H / 2 + Math.cos(t * 3.1) * H * 0.08); x.rotate(-0.7 + Math.sin(t * 6) * 0.08);
    x.fillStyle = '#f2c45a'; x.fillRect(-W * 0.02, -H * 0.12, W * 0.04, H * 0.2); x.fillStyle = '#e8b4a0'; x.beginPath(); x.moveTo(-W * 0.02, H * 0.08); x.lineTo(W * 0.02, H * 0.08); x.lineTo(0, H * 0.12); x.fill(); x.restore();
    x.fillStyle = '#7a1430'; x.font = `600 ${Math.round(W / 22)}px Georgia,serif`; x.textAlign = 'center'; x.fillText('Drawing' + '.'.repeat(1 + (Math.floor(t * 2) % 3)), W / 2, H * 0.78);
    await new Promise(r => requestAnimationFrame(r));
  }
}
function updRetake() { const used = st.cur ? st.cur.retakes || 0 : 0, left = Math.max(0, (+cfg.retakes || 0) - used); $('retake').disabled = !left; $('retake').textContent = left ? `↺ Redraw (${left})` : 'No retakes left'; $('retake').style.opacity = left ? 1 : .5; }

// ---------- printing (Android print screen: Epson Print Enabler / Mopria; copies = pages) ----------
async function printCanvas(p) {
  const art = await loadImg(URL.createObjectURL(p.final)), land = art.naturalWidth > art.naturalHeight;
  const w = land ? 6 : 4, h = land ? 4 : 6, D = 300, c = document.createElement('canvas'); c.width = w * D; c.height = h * D; const x = c.getContext('2d');
  x.fillStyle = '#fff'; x.fillRect(0, 0, c.width, c.height);
  const band = Math.round(c.height * (land ? 0.13 : 0.11)), m = Math.round(D * 0.12), aw = c.width - 2 * m, ah = c.height - band - m;
  const k = Math.min(aw / art.naturalWidth, ah / art.naturalHeight), dw = art.naturalWidth * k, dh = art.naturalHeight * k;
  x.drawImage(art, (c.width - dw) / 2, m + (ah - dh) / 2, dw, dh);
  const by = c.height - band; x.fillStyle = '#7a1430'; x.fillRect(m, by, c.width - 2 * m, 4);
  x.textAlign = 'center'; x.fillStyle = '#1a1020'; x.font = `700 ${Math.round(band * 0.3)}px Georgia,serif`; x.fillText(cfg.event || '', c.width / 2, by + band * 0.38, c.width - 2 * m);
  x.font = `500 ${Math.round(band * 0.17)}px system-ui,sans-serif`; x.fillStyle = '#444';
  const dt = cfg.date ? new Date(cfg.date + 'T12:00:00').toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '';
  x.fillText(dt, c.width / 2, by + band * 0.62); x.fillStyle = '#777'; x.font = `500 ${Math.round(band * 0.13)}px system-ui,sans-serif`; x.fillText(cfg.footer || '', c.width / 2, by + band * 0.85, c.width - 2 * m);
  return { c, w, h };
}
async function doPrint(canvas, w, h, copies, label) {
  const url = canvas.toDataURL('image/jpeg', 0.95);
  $('pg').textContent = `@page{size:${w}in ${h}in;margin:0}`;
  $('printArea').innerHTML = Array.from({ length: copies }, () => `<img src="${url}" style="width:${w}in;height:${h}in">`).join('');
  await Promise.all([...$('printArea').querySelectorAll('img')].map(i => i.decode().catch(() => {})));
  return new Promise(res => {
    const o = $('ovl'); o.innerHTML = `<h3>${label}</h3><img src="${url}"><p>${copies} ${copies === 1 ? 'copy' : 'copies'} · ${w}×${h} in. In the print screen: Epson, ${w}×${h} in paper, borderless.</p><div class="btns" id="pAsk" style="display:none"><button class="btn ok" id="pYes">✓ Printed</button><button class="btn g" id="pNo">✗ Not printed</button></div><button class="btn" id="pGo">🖨 Open print screen</button>`;
    o.classList.add('on');
    const end = ok => { o.classList.remove('on'); $('printArea').innerHTML = ''; res(ok); };
    const go = () => { $('pGo').textContent = '🖨 Print again'; try { window.print(); } catch {} setTimeout(() => $('pAsk').style.display = 'grid', 600); };
    $('pGo').onclick = go; $('pYes').onclick = () => end(true); $('pNo').onclick = () => end(false);
    setTimeout(go, 300);
  });
}
async function printPic(p, copies) {
  const { c, w, h } = await printCanvas(p); const ok = await doPrint(c, w, h, copies, p.name ? `Print · ${p.name}` : 'Print');
  if (ok) { p.prints = (p.prints || 0) + copies; await DB.put(p); refreshGallery(); toast('Printed ✓'); }
}
function testPage() {
  const D = 300, c = document.createElement('canvas'); c.width = 4 * D; c.height = 6 * D; const x = c.getContext('2d'), W = c.width, H = c.height, mm = D / 25.4;
  x.fillStyle = '#fff'; x.fillRect(0, 0, W, H); x.strokeStyle = '#e11d48'; x.lineWidth = 6; x.strokeRect(3 * mm, 3 * mm, W - 6 * mm, H - 6 * mm);
  x.strokeStyle = '#111'; x.lineWidth = 4; x.strokeRect(1, 1, W - 2, H - 2);
  x.textAlign = 'center'; x.fillStyle = '#F47B20'; x.font = `800 ${W / 9}px system-ui,sans-serif`; x.fillText('OctoSnap', W / 2, H * 0.2);
  x.fillStyle = '#111'; x.font = `600 ${W / 24}px system-ui,sans-serif`;
  ['Test print · 4 × 6 in · 1200 × 1800 px', 'Black line = paper edge (borderless)', 'Red frame = 3 mm inside the edge', 'Small or in a corner? In the print screen', 'set paper 4×6 in (10×15 cm), borderless.'].forEach((t, i) => x.fillText(t, W / 2, H * 0.35 + i * W / 15, W * 0.9));
  return c;
}

// ---------- share / save ----------
async function sharePic(p) {
  const f = new File([p.final], `OctoSnap-${(p.name || 'caricature').replace(/[^\w-]+/g, '_')}.jpg`, { type: 'image/jpeg' });
  if (navigator.canShare && navigator.canShare({ files: [f] })) { try { await navigator.share({ files: [f], title: cfg.event, text: `${cfg.event} · OctoSnap` }); } catch {} }
  else savePic(p);
}
function savePic(p) { const a = document.createElement('a'); a.href = URL.createObjectURL(p.final); a.download = `OctoSnap-${p.name || p.id}.jpg`; document.body.appendChild(a); a.click(); a.remove(); }

// ---------- gallery ----------
async function refreshGallery() {
  const pics = (await DB.event(cfg.eventId)).sort((a, b) => b.at - a.at);
  $('kPics').textContent = pics.length; $('kPrints').textContent = pics.reduce((s, p) => s + (p.prints || 0), 0); $('kCost').textContent = '₹' + pics.reduce((s, p) => s + (p.cost || 0), 0);
  $('gTitle').textContent = cfg.event || 'This event'; $('gEmpty').style.display = pics.length ? 'none' : 'block';
  const g = $('grid'); g.querySelectorAll('img').forEach(i => URL.revokeObjectURL(i.src)); g.innerHTML = '';
  for (const p of pics) { const i = new Image(); i.src = URL.createObjectURL(p.final); i.onclick = () => openPic(p); g.appendChild(i); }
}
function openPic(p) {
  const o = $('ovl'), url = URL.createObjectURL(p.final);
  o.innerHTML = `<h3>${p.name || 'Picture'}</h3><img src="${url}"><p>${STY[p.style] ? STY[p.style].name : p.style} · ${p.prints || 0} printed${p.mode === 'test' ? ' · test' : ''}</p><div class="btns"><button class="btn" id="oP">🖨 Print</button><button class="btn g" id="oS">📤 Share</button></div><button class="btn g" id="oC">Close</button>`;
  o.classList.add('on'); $('oC').onclick = () => o.classList.remove('on'); $('oS').onclick = () => sharePic(p); $('oP').onclick = () => { o.classList.remove('on'); printPic(p, 1); };
}
async function exportEvent() {
  const pics = await DB.event(cfg.eventId); if (!pics.length) return toast('No pictures yet');
  const files = pics.map((p, i) => new File([p.final], `${String(i + 1).padStart(3, '0')}-${(p.name || 'guest').replace(/[^\w-]+/g, '_')}.jpg`, { type: 'image/jpeg' }));
  if (navigator.canShare && navigator.canShare({ files })) { try { await navigator.share({ files, title: cfg.event }); return; } catch {} }
  for (const p of pics) { savePic(p); await sleep(400); }
}

// ---------- settings ----------
function fillSettings() {
  $('sEvent').value = cfg.event; $('sDate').value = cfg.date; $('sFooter').value = cfg.footer; $('sLimit').value = cfg.limit; $('sPin').value = cfg.pin;
  $('sKey').value = LS.get('key', '') ? '••••••••••••' : '';
  seg('sCopies', cfg.copies); seg('sDrawSec', cfg.drawSec); seg('sRetakes', cfg.retakes); seg('sMode', cfg.mode);
  const box = $('sStyles'); box.innerHTML = ''; let grp = '';
  for (const s of CAT.styles) {
    if (s.group !== grp) { grp = s.group; const hd = document.createElement('small'); hd.textContent = grp; hd.style.marginTop = '10px'; box.appendChild(hd); }
    const l = document.createElement('label'); l.className = 'chk'; l.innerHTML = `<input type="checkbox" value="${s.key}" ${cfg.styles.includes(s.key) ? 'checked' : ''}> ${s.name}`; box.appendChild(l);
  }
}
function saveSettings() {
  const styles = [...$('sStyles').querySelectorAll('input:checked')].map(i => i.value); if (!styles.length) return toast('Pick at least 1 style');
  const k = $('sKey').value.trim(); if (k && !/^•+$/.test(k)) LS.set('key', k); if (!k) LS.set('key', '');
  const mode = segVal('sMode'); if (mode === 'real' && !LS.get('key', '')) return toast('Paste the OpenAI key first, or keep Test mode');
  Object.assign(cfg, { event: $('sEvent').value.trim() || 'OctoSnap Live', date: $('sDate').value || today(), footer: $('sFooter').value.trim(), limit: $('sLimit').value.trim(),
    pin: $('sPin').value.trim(), copies: +segVal('sCopies') || 1, drawSec: +segVal('sDrawSec') || 25, retakes: +segVal('sRetakes') || 0, mode, styles });
  LS.set('cfg', cfg); applyCfg(); toast('Saved ✓'); show('vBooth');
}
async function checkKey() {
  const k = /^•+$/.test($('sKey').value.trim()) ? LS.get('key', '') : $('sKey').value.trim(); if (!k) return $('sKeyMsg').textContent = 'Paste the key first.';
  $('sKeyMsg').textContent = 'Checking…';
  try { const r = await fetch('https://api.openai.com/v1/models/' + MODEL, { headers: { Authorization: 'Bearer ' + k } }); $('sKeyMsg').textContent = r.ok ? '✓ Key works and the image model is available. (Credits are not checked here.)' : r.status === 401 ? '✗ Key is wrong or revoked.' : r.status === 404 ? '⚠ Key works, but this account cannot see ' + MODEL + '.' : '⚠ OpenAI answered ' + r.status; }
  catch { $('sKeyMsg').textContent = '✗ No internet / OpenAI not reachable.'; }
}
function applyCfg() {
  $('evName').textContent = cfg.event; $('modeTag').textContent = cfg.mode === 'real' ? 'REAL AI' : 'TEST'; $('modeTag').classList.toggle('real', cfg.mode === 'real');
  const box = $('styleChips'); box.innerHTML = '';
  if (!cfg.styles.includes(st.style)) st.style = cfg.styles[0];
  for (const k of cfg.styles) { const s = STY[k]; if (!s) continue; const b = document.createElement('button'); b.className = 'chip' + (k === st.style ? ' on' : ''); b.textContent = s.name; b.onclick = () => { st.style = k; box.querySelectorAll('.chip').forEach(x => x.classList.toggle('on', x === b)); }; box.appendChild(b); }
  $('tvBtn').style.opacity = cfg.tv ? 1 : .45;
}
function askPin() { return new Promise(res => {
  if (!cfg.pin) return res(true);
  const o = $('ovl'); o.innerHTML = `<h3>Operator PIN</h3><input class="t" id="pinIn" inputmode="numeric" type="password" style="max-width:240px;text-align:center;font-size:24px"><div class="btns"><button class="btn g" id="pinX">Cancel</button><button class="btn" id="pinOk">Open</button></div>`;
  o.classList.add('on'); $('pinIn').focus();
  $('pinX').onclick = () => { o.classList.remove('on'); res(false); };
  $('pinOk').onclick = () => { const ok = $('pinIn').value === cfg.pin; o.classList.remove('on'); if (!ok) toast('Wrong PIN'); res(ok); };
}); }

// ---------- navigation ----------
async function show(v) {
  if (v === 'vSet' && !(await askPin())) return;
  document.querySelectorAll('.view').forEach(s => s.classList.toggle('on', s.id === v));
  document.querySelectorAll('nav button').forEach(b => b.classList.toggle('on', b.dataset.v === v));
  if (v === 'vSet') fillSettings();
  if (v === 'vGallery') refreshGallery();
  if (v === 'vBooth' && st.cur && $('resBar').style.display !== 'none') { st.cur = null; $('gName').value = ''; resetBooth(); }   // picture finished -> fresh booth for the next guest
  if (v === 'vBooth' && !st.photo) camStart(); else if (v !== 'vBooth') { if (v !== 'vDraw') camStop(); }
}
let wake = null; async function keepAwake() { try { if (navigator.wakeLock && document.visibilityState === 'visible') wake = await navigator.wakeLock.request('screen'); } catch {} }

(async () => {
  CAT = await (await fetch('styles.json')).json();
  for (const s of CAT.styles) STY[s.key] = s;
  window.OS = { state: { styles: STY } };              // lets anim.js pick each style's animation
  cfg.styles = cfg.styles.filter(k => STY[k]); if (!cfg.styles.length) cfg.styles = ['caricature'];
  applyCfg();
  document.querySelectorAll('nav button').forEach(b => b.onclick = () => show(b.dataset.v));
  seg('people', 0, v => st.people = +v);
  $('snap').onclick = snap; $('pick').onclick = () => $('file').click(); $('file').onchange = e => { fromFile(e.target.files[0]); e.target.value = ''; };
  $('flip').onclick = () => { st.facing = st.facing === 'user' ? 'environment' : 'user'; camStart(); };
  $('again').onclick = resetBooth; $('go').onclick = () => makePicture(false);
  $('tryAgain').onclick = () => makePicture(false); $('cancel').onclick = () => { show('vBooth'); resetBooth(); };
  $('print').onclick = () => st.cur && printPic(st.cur, +cfg.copies || 1);
  $('share').onclick = () => st.cur && sharePic(st.cur); $('save').onclick = () => st.cur && savePic(st.cur);
  $('retake').onclick = async () => { if (cfg.mode === 'real' && !confirm('New drawing costs about ₹4. Continue?')) return; makePicture(true); };
  $('next').onclick = () => { if (st.signal) st.signal.aborted = true; $('gName').value = ''; st.cur = null; show('vBooth'); resetBooth(); };
  $('tvBtn').onclick = () => { cfg.tv = !cfg.tv; LS.set('cfg', cfg); applyCfg(); toast(cfg.tv ? 'TV mode ON: the drawing goes full screen. Cast this phone to the TV (Android Quick settings → Cast / Smart View).' : 'TV mode OFF', 4500); };
  $('sSave').onclick = saveSettings; $('sTest').onclick = checkKey;
  $('sTestPrint').onclick = () => doPrint(testPage(), 4, 6, 1, 'Test page');
  $('sExport').onclick = exportEvent;
  $('sNewEvent').onclick = () => { if (!confirm('Start a new event? Counters go back to 0. Old pictures stay on this phone.')) return; cfg.eventId = 'ev' + Date.now().toString(36); cfg.date = today(); LS.set('cfg', cfg); refreshGallery(); toast('New event started'); };
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') { keepAwake(); if ($('vBooth').classList.contains('on') && !st.photo) camStart(); } else camStop(); });
  keepAwake(); camStart(); refreshGallery();
  if ('serviceWorker' in navigator && location.protocol === 'https:') navigator.serviceWorker.register('sw.js').catch(() => {});
})();
