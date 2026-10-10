'use strict';
/* LevelUP: Distinguished Engineer library, AI feeds and Read Later. No build step, no framework. */

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const view = $('#view');
const ICON = {
  settings: '<svg viewBox="0 0 24 24"><path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/></svg>',
  type: '<svg viewBox="0 0 24 24"><path d="M4 18l5-12 5 12M6 14h6M15 18l3-7 3 7M16 16h4"/></svg>',
  refresh: '<svg viewBox="0 0 24 24"><path d="M20 11a8 8 0 10-2.3 5.7M20 5v6h-6"/></svg>',
  bookmark: '<svg viewBox="0 0 24 24"><path d="M7 4h10v16l-5-3.5L7 20z"/></svg>',
  bookmarkOn: '<svg viewBox="0 0 24 24"><path d="M7 4h10v16l-5-3.5L7 20z" fill="currentColor"/></svg>',
  ext: '<svg viewBox="0 0 24 24"><path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 01-1 1H5a1 1 0 01-1-1V7a1 1 0 011-1h5"/></svg>',
  plus: '<svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>',
  check: '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7"/></svg>',
  trash: '<svg viewBox="0 0 24 24"><path d="M5 7h14M10 7V5h4v2M7 7l1 13h8l1-13"/></svg>',
  search: '<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/></svg>',
  shuffle: '<svg viewBox="0 0 24 24"><path d="M4 7h3c5 0 5 10 10 10h3M4 17h3c1.7 0 2.8-1.1 3.7-2.5M13.3 9.5C14.2 8.1 15.3 7 17 7h3M18 4l3 3-3 3M18 14l3 3-3 3"/></svg>',
  paste: '<svg viewBox="0 0 24 24"><path d="M9 4h6v3H9zM8 5H6v15h12V5h-2"/></svg>',
  inbox: '<svg viewBox="0 0 24 24"><path d="M4 13l2.5-8h11L20 13v6H4zM4 13h5l1 2h4l1-2h5"/></svg>',
};

/* ---------- persistence ---------- */
const ls = {
  get(k, d) { try { const v = localStorage.getItem('lu:' + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('lu:' + k, JSON.stringify(v)); } catch { /* private mode */ } },
};
const db = (() => {
  let p;
  const open = () => p || (p = new Promise((res, rej) => {
    const r = indexedDB.open('levelup', 1);
    r.onupgradeneeded = () => { r.result.createObjectStore('saved', { keyPath: 'id' }); r.result.createObjectStore('later', { keyPath: 'id' }); };
    r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
  }));
  const tx = async (store, mode, fn) => {
    const d = await open();
    return new Promise((res, rej) => { const t = d.transaction(store, mode); const r = fn(t.objectStore(store)); t.oncomplete = () => res(r?.result); t.onerror = () => rej(t.error); });
  };
  return {
    all: (s) => tx(s, 'readonly', (o) => o.getAll()).catch(() => []),
    get: (s, id) => tx(s, 'readonly', (o) => o.get(id)).catch(() => undefined),
    put: (s, v) => tx(s, 'readwrite', (o) => o.put(v)),
    del: (s, id) => tx(s, 'readwrite', (o) => o.delete(id)),
  };
})();
if (navigator.storage?.persist) navigator.storage.persist().catch(() => {});

/* ---------- preferences ---------- */
const prefs = Object.assign({ theme: 'auto', fs: 19, font: 'serif' }, ls.get('prefs', {}));
function applyPrefs() {
  const r = document.documentElement;
  if (prefs.theme === 'auto') r.removeAttribute('data-theme'); else r.dataset.theme = prefs.theme;
  r.style.setProperty('--fs', prefs.fs + 'px');
  r.style.setProperty('--read-font', prefs.font === 'sans' ? 'var(--sans)' : 'var(--serif)');
  ls.set('prefs', prefs);
}
applyPrefs();

/* ---------- data ---------- */
const cache = {};
async function getJSON(path, { fresh = false } = {}) {
  if (cache[path] && !fresh) return cache[path];
  const res = await fetch(path, { cache: fresh ? 'no-cache' : 'default' });
  if (!res.ok) throw new Error(res.status);
  return (cache[path] = await res.json());
}
const library = () => getJSON('data/library.json');
const vol = async (n) => (await library()).volumes.find((v) => v.n === +n);

function repoSlug() {
  const s = ls.get('settings', {});
  if (s.repo) return s.repo;
  const m = location.hostname.match(/^([^.]+)\.github\.io$/);
  if (m) { const seg = location.pathname.split('/').filter(Boolean)[0]; return seg ? `${m[1]}/${seg}` : `${m[1]}/${m[1]}.github.io`; }
  return '';
}

/* ---------- ui helpers ---------- */
let toastT;
function toast(msg) { const t = $('#toast'); t.textContent = msg; t.classList.add('show'); clearTimeout(toastT); toastT = setTimeout(() => t.classList.remove('show'), 2200); }
function setTop(title, { back = false, actions = '' } = {}) {
  $('#title').textContent = title; $('#back').hidden = !back; $('#top-actions').innerHTML = actions;
  document.title = title === 'Library' ? 'LevelUP' : `${title} · LevelUP`;
}
function setTab(tab) { $$('.tabbar a').forEach((a) => a.classList.toggle('active', a.dataset.tab === tab)); }
function setProgress(p) { $('#progress div').style.width = p == null ? '0' : Math.round(p * 100) + '%'; }
const ago = (t) => {
  const s = (Date.now() - new Date(t)) / 1000; if (!t || isNaN(s)) return '';
  if (s < 3600) return Math.max(1, Math.round(s / 60)) + 'm ago'; if (s < 86400) return Math.round(s / 3600) + 'h ago';
  if (s < 86400 * 30) return Math.round(s / 86400) + 'd ago';
  return new Date(t).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
};
const host = (u) => { try { return new URL(u).hostname.replace(/^www\./, ''); } catch { return ''; } };
const readMins = (words) => Math.max(1, Math.round(words / 230));
const textOf = (html) => { const d = document.createElement('div'); d.innerHTML = html || ''; return d.textContent.replace(/\s+/g, ' ').trim(); };

function openSheet(html, onMount) {
  const sh = $('#sheet'), bd = $('#sheet-backdrop');
  sh.innerHTML = html; sh.hidden = false; bd.hidden = false;
  const close = () => { sh.hidden = true; bd.hidden = true; };
  bd.onclick = close;
  onMount?.(sh, close);
  return close;
}
function typeSheet() {
  const btns = (key, opts) => opts.map(([v, label, cls = '']) => `<button class="${cls} ${prefs[key] == v ? 'on' : ''}" data-k="${key}" data-v="${v}">${label}</button>`).join('');
  const render = () => `<h3>Reading</h3>
    <div class="opt-group">${btns('fs', [[16, '<span style="font-size:14px">A</span>'], [18, '<span style="font-size:16px">A</span>'], [19, '<span style="font-size:18px">A</span>'], [21, '<span style="font-size:20px">A</span>'], [23, '<span style="font-size:23px">A</span>']])}</div>
    <div class="opt-group">${btns('font', [['serif', '<span style="font-family:var(--serif)">Serif</span>'], ['sans', 'Sans']])}</div>
    <div class="opt-group">${btns('theme', [['auto', 'Auto'], ['light', 'Light', 'swatch-light'], ['sepia', 'Sepia', 'swatch-sepia'], ['dark', 'Dark', 'swatch-dark']])}</div>`;
  openSheet(render(), (sh) => {
    sh.addEventListener('click', (e) => {
      const b = e.target.closest('button[data-k]'); if (!b) return;
      prefs[b.dataset.k] = b.dataset.k === 'fs' ? +b.dataset.v : b.dataset.v; applyPrefs(); sh.innerHTML = render();
    });
  });
}

/* ---------- router ---------- */
const routes = [];
const route = (re, fn) => routes.push([re, fn]);
let cleanup = null;
async function router() {
  cleanup?.(); cleanup = null; setProgress(null);
  const [path, qs] = location.hash.slice(1).split('?');
  const q = new URLSearchParams(qs || '');
  for (const [re, fn] of routes) {
    const m = (path || '/').match(re);
    if (m) {
      try { await fn(m, q); } catch (e) { console.error(e); view.innerHTML = `<div class="wrap"><div class="empty">Couldn't load this page.<br><span class="small">${esc(e.message)}</span></div></div>`; }
      return;
    }
  }
  location.hash = '#/';
}
window.addEventListener('hashchange', () => { router(); });
$('#back').onclick = () => (history.length > 1 ? history.back() : (location.hash = '#/'));
document.addEventListener('click', (e) => {
  const b = e.target.closest('[data-action]'); if (b) actions[b.dataset.action]?.(b, e);
});
const actions = {};

/* ---------- Library ---------- */
route(/^\/$/, async () => {
  setTab('library'); setTop('Library', { actions: `<button class="icon-btn" data-action="type" aria-label="Reading settings">${ICON.type}</button><a class="icon-btn" href="#/settings" aria-label="Settings">${ICON.settings}</a>` });
  const lib = await library();
  const prog = ls.get('progress', {});
  const last = ls.get('lastVol');
  const lastVol = last && lib.volumes.find((v) => v.n === last && v.ready);
  const ready = lib.volumes.filter((v) => v.ready).length;
  const day = Math.floor(Date.now() / 864e5);
  const catalogP = (lib.principleCatalog || []).flatMap((c) => c.items.map((i) => ({ ...i, cat: c.title })));
  const algos = (lib.algorithms || []).flatMap((c) => c.items);
  const nPrinciples = catalogP.length + lib.principles.length;
  const p = catalogP.length ? catalogP[day % catalogP.length] : null;
  const vp = !p && lib.principles.length ? lib.principles[day % lib.principles.length] : null;
  const idea = lib.keyIdeas?.length ? lib.keyIdeas[(day * 7) % lib.keyIdeas.length] : null;
  const row = (v) => {
    const pr = prog[v.n] || 0;
    return `<a class="row" href="#/vol/${v.n}"><div class="badge ${v.ready ? '' : 'dim'}">${v.n}</div><div class="body">
      <div class="t">${esc(v.title)} ${v.ready ? (pr > .97 ? '<span class="pill ok">Read</span>' : '') : '<span class="pill">Queued</span>'}</div>
      <div class="s">${esc(v.scope)}</div>
      ${v.ready && pr > .02 && pr <= .97 ? `<div class="bar"><div style="width:${Math.round(pr * 100)}%"></div></div>` : ''}</div></a>`;
  };
  const coll = (href, badge, title, sub) => `<a class="row" href="${href}"><div class="badge">${badge}</div><div class="body"><div class="t">${title}</div><div class="s">${sub}</div></div></a>`;
  view.innerHTML = `<div class="wrap">
    <div class="hero"><div class="eyebrow">Knowledge Library</div><h2>${esc(lib.title)}</h2><p>${esc(lib.subtitle)}</p>
      <div class="meta"><span>${ready} of ${lib.volumes.length} volumes ready</span><span>·</span><span>${nPrinciples} principles</span><span>·</span><span>${algos.length} algorithms</span></div></div>
    ${lastVol ? `<div class="section-title"><h3>Continue reading</h3></div>
      <a class="card row" style="border-top:1px solid var(--line)" href="#/vol/${lastVol.n}"><div class="badge">${lastVol.n}</div><div class="body"><div class="t">${esc(lastVol.title)}</div>
      <div class="bar"><div style="width:${Math.round((prog[lastVol.n] || 0) * 100)}%"></div></div><div class="meta">${Math.round((prog[lastVol.n] || 0) * 100)}% · ${readMins(lastVol.words)} min total</div></div></a>` : ''}
    ${p ? `<div class="section-title"><h3>Principle of the day</h3><a href="#/principles">All principles</a></div>
      <a class="card principle" style="display:block;text-decoration:none;color:inherit" href="#/principle/${p.id}"><div class="eyebrow">${esc(p.cat)}</div><div class="name">${esc(p.name)}</div><div class="txt">${esc(p.summary)}</div></a>` : ''}
    ${vp ? `<div class="section-title"><h3>Principle of the day</h3><a href="#/principles">All principles</a></div>
      <a class="card principle" style="display:block;text-decoration:none;color:inherit" href="#/principles?tab=vol&vol=${vp.vol}"><div class="name">${esc(vp.name)}</div><div class="txt">${vp.html}</div><div class="src muted">Vol ${vp.vol} · ${esc(vp.volTitle)}</div></a>` : ''}
    ${idea ? `<div class="section-title"><h3>Key idea</h3><a href="#/vol/${idea.vol}">Vol ${idea.vol}</a></div>
      <div class="card principle"><div class="txt" style="color:var(--ink)">${idea.html}</div><div class="src muted">${esc(idea.volTitle)} · ten sentences to retain</div></div>` : ''}
    <div class="section-title"><h3>Collections</h3></div>
    <div class="list">
      ${coll('#/principles', 'P', 'Design Principles', `${nPrinciples} principles: a cross-cutting catalog plus those drawn from each volume`)}
      ${coll('#/algorithms', 'A', 'Algorithms', algos.length ? `${algos.length} algorithms across ${lib.algorithms.length} areas, from Raft to HNSW` : 'Being written')}
      ${coll('#/review', 'R', 'Review Mode', `${(lib.probes || []).length} DE probe sets and every review checklist, for prep before an architecture review`)}
    </div>
    ${lib.parts.map((part) => `<div class="section-title"><h3>Part ${part.id} · ${esc(part.title)}</h3></div>
      <div class="list">${part.volumes.map((n) => row(lib.volumes.find((v) => v.n === n))).join('')}</div>`).join('')}
    <p class="small muted" style="margin-top:24px">${esc(lib.howTo)}</p>
  </div>`;
});

/* ---------- Practice ---------- */
// Flash cards: the question card sits on top; tapping it flips the answer card below.
function practiceDecks(lib) {
  const decks = [...(lib.practice || [])];
  const cat = (lib.principleCatalog || []).flatMap((c) => c.items);
  if (cat.length) decks.push({ id: 'd-principle-catalog', title: 'Principle catalog', cards: cat.map((i) => ({ id: 'q-' + i.id, q: `What does “${i.name}” say?`, a: `<p>${esc(i.summary)}</p>` })) });
  const al = (lib.algorithms || []).flatMap((c) => c.items);
  if (al.length) decks.push({ id: 'd-algorithm-catalog', title: 'Algorithm catalog', cards: al.map((i) => ({ id: 'q-' + i.id, q: `What is ${i.name}, and when do you use it?`, a: `<p>${esc(i.summary)}</p>` })) });
  return decks;
}
let practice = null; // { deck, order, i }
route(/^\/practice$/, async () => {
  setTab('practice');
  setTop('Practice', { actions: `<button class="icon-btn" data-action="pShuffle" aria-label="Shuffle">${ICON.shuffle}</button>` });
  const lib = await library();
  const decks = practiceDecks(lib);
  const deckId = ls.get('pDeck', 'all');
  const deck = decks.find((d) => d.id === deckId);
  const pool = deck ? deck.cards : decks.flatMap((d) => d.cards);
  const known = new Set(ls.get('pKnown', []));
  const hide = ls.get('pHide', false);
  if (!practice || practice.deck !== deckId || practice.hide !== hide || practice.n !== pool.length) {
    practice = { deck: deckId, hide, n: pool.length, order: pool.filter((c) => !hide || !known.has(c.id)).map((c) => c.id), i: 0 };
  }
  const byId = new Map(decks.flatMap((d) => d.cards.map((c) => [c.id, { ...c, deck: d.title }])));
  const card = byId.get(practice.order[practice.i]);
  const nKnown = pool.filter((c) => known.has(c.id)).length;
  view.innerHTML = `<div class="wrap practice">
    <div class="chips">${[['all', 'All decks'], ...decks.map((d) => [d.id, d.title])].map(([id, t]) => `<button class="chip ${id === deckId ? 'on' : ''}" data-action="pDeck" data-id="${id}">${esc(t)}</button>`).join('')}</div>
    <div class="p-meta"><span>${nKnown} of ${pool.length} known</span><span>${practice.order.length ? `${practice.i + 1} of ${practice.order.length}` : ''}</span></div>
    <div class="bar"><div style="width:${pool.length ? Math.round(nKnown / pool.length * 100) : 0}%;background:var(--ok)"></div></div>
    ${card ? `
    <button class="p-q" data-action="pFlip"><span class="eyebrow">${esc(card.deck)}</span><span class="q">${esc(card.q)}</span><span class="hint">${known.has(card.id) ? '✓ Known · ' : ''}Tap to reveal</span></button>
    <div class="p-flip" data-action="pFlip"><div class="p-inner">
      <div class="p-face p-back"><span>Say your answer out loud, then tap the question.</span></div>
      <div class="p-face p-front">${card.a || ''}</div>
    </div></div>
    <div class="p-ctl">
      <button class="icon-btn" data-action="pStep" data-d="-1" aria-label="Previous" ${practice.i ? '' : 'disabled'}>‹</button>
      <button class="btn again" data-action="pMark" data-k="0">Again</button>
      <button class="btn got" data-action="pMark" data-k="1">Got it</button>
      <button class="icon-btn" data-action="pStep" data-d="1" aria-label="Next" ${practice.i < practice.order.length - 1 ? '' : 'disabled'}>›</button>
    </div>
    <label class="small muted p-hide"><input type="checkbox" data-action="pHide" ${hide ? 'checked' : ''}> Hide cards I know</label>`
    : `<div class="empty">${hide && pool.length ? 'You know every card in this deck.' : 'No cards yet.'}<br><label class="small"><input type="checkbox" data-action="pHide" ${hide ? 'checked' : ''}> Hide cards I know</label></div>`}
  </div>`;
  let x0 = null;
  const area = $('.practice');
  area.addEventListener('touchstart', (e) => { x0 = e.touches[0].clientX; }, { passive: true });
  area.addEventListener('touchend', (e) => { if (x0 == null) return; const dx = e.changedTouches[0].clientX - x0; x0 = null; if (Math.abs(dx) > 70) pStep(dx < 0 ? 1 : -1); });
});
function pStep(d) { const n = practice.i + d; if (n >= 0 && n < practice.order.length) { practice.i = n; router(); } }
actions.pFlip = () => $('.p-flip')?.classList.toggle('open');
actions.pStep = (b) => pStep(+b.dataset.d);
actions.pDeck = (b) => { ls.set('pDeck', b.dataset.id); practice = null; router(); };
actions.pShuffle = () => { if (!practice) return; practice.order.sort(() => Math.random() - 0.5); practice.i = 0; router(); };
actions.pHide = (b) => { ls.set('pHide', b.checked); practice = null; router(); };
actions.pMark = (b) => {
  const id = practice.order[practice.i]; const k = new Set(ls.get('pKnown', []));
  if (b.dataset.k === '1') k.add(id); else k.delete(id);
  ls.set('pKnown', [...k]);
  if (practice.i < practice.order.length - 1) practice.i++; router();
};

/* ---------- Volume reader ---------- */
// Each volume has the author's text and, for some, Claude's companion notes (principles, trade-offs, probes).
const COMPANION_JUMPS = [['Principles', 'design-principles'], ['Trade-offs', 'trade-offs-and-decision-frameworks'], ['Failure modes', 'failure-modes-and-war-stories'], ['DE probes', 'what-a-de-probes'], ['Checklist', 'review-checklist']];
const MAIN_JUMPS = [['Checklist', /checklist/i], ['Summary', /summary/i], ['Reading', /reading/i]];
route(/^\/vol\/(\d+)(?:\/(.+))?$/, async ([, n, anchor], q) => {
  setTab('library');
  const lib = await library(); const v = await vol(n);
  if (!v) { location.hash = '#/'; return; }
  setTop(`Vol ${v.n} · ${v.title}`, { back: true, actions: `<button class="icon-btn" data-action="type" aria-label="Reading settings">${ICON.type}</button>` });
  const idx = lib.volumes.indexOf(v); const prev = lib.volumes[idx - 1], next = lib.volumes[idx + 1];
  const pager = `<div class="pager">${prev ? `<a href="#/vol/${prev.n}"><div class="card"><div class="dir">← Vol ${prev.n}</div><div class="nm">${esc(prev.title)}</div></div></a>` : '<span style="flex:1"></span>'}
    ${next ? `<a href="#/vol/${next.n}" style="text-align:right"><div class="card"><div class="dir">Vol ${next.n} →</div><div class="nm">${esc(next.title)}</div></div></a>` : '<span style="flex:1"></span>'}</div>`;
  const comp = !!v.companion && (anchor === 'companion' || (anchor || '').startsWith(`c${v.n}-`));
  const doc = comp ? v.companion : v;
  const head = `<div class="vol-head"><div class="eyebrow">Part ${v.part} · ${esc(v.partTitle)}</div><h2>${esc(v.title)}</h2>
    ${v.summary ? `<p class="summary">${esc(v.summary)}</p>` : ''}
    <div class="meta">${v.ready ? `<span class="pill ok">Ready</span><span>${readMins(doc.words)} min read</span>${v.principleCount ? `<span>·</span><span>${v.principleCount} principles</span>` : ''}` : '<span class="pill">Queued</span>'}</div></div>`;
  if (!v.ready) {
    view.innerHTML = `<div class="wrap">${head}<div class="reader"><h3>Scope</h3><ul>${v.scope.split(/,\s*|;\s*/).map((s) => `<li>${esc(s)}</li>`).join('')}</ul></div>
      <div class="queued-note">This volume hasn't been written yet. It will appear here automatically once it's added to the library.</div>${pager}</div>`;
    return;
  }
  ls.set('lastVol', v.n);
  let jumps;
  if (comp) {
    const ids = new Set(doc.sections.map((s) => s.id));
    jumps = COMPANION_JUMPS.filter(([, id]) => ids.has(`c${v.n}-${id}`)).map(([l, id]) => [l, `#/vol/${v.n}/c${v.n}-${id}`]);
  } else {
    jumps = MAIN_JUMPS.map(([l, re]) => [l, doc.sections.find((s) => s.level === 2 && re.test(s.title))]).filter(([, s]) => s).map(([l, s]) => [l, `#/vol/${v.n}/${s.id}`]);
    if ((lib.probes || []).some((p) => p.vol === v.n)) jumps.unshift(['DE probes', `#/review?vol=${v.n}`]);
  }
  const tidy = (t) => t.replace(/^\d+(\.\d+)*\.?\s+/, '');
  view.innerHTML = `<div class="wrap">${head}
    ${v.companion ? `<div class="seg"><button class="${comp ? '' : 'on'}" data-action="go" data-href="#/vol/${v.n}">Volume</button><button class="${comp ? 'on' : ''}" data-action="go" data-href="#/vol/${v.n}/companion">Companion notes</button></div>` : ''}
    ${jumps.length ? `<div class="chips jump">${jumps.map(([label, href]) => `<a class="chip" href="${href}">${label}</a>`).join('')}</div>` : ''}
    <details class="toc-box"><summary>Contents</summary><div class="toc">${doc.sections.map((s) => `<a class="l${s.level}" href="#/vol/${v.n}/${s.id}">${esc(tidy(s.title))}</a>`).join('')}</div></details>
    ${comp ? '<p class="small muted">Companion notes: design principles, trade-offs, failure modes and review probes written to sit alongside your volume.</p>' : ''}
    <article class="reader" id="reader">${doc.html}</article>${pager}</div>`;

  // Persisted checklist ticks.
  const ck = comp ? `c${v.n}` : `${v.n}`;
  const checks = ls.get('checks', {});
  $$('#reader input[data-task]').forEach((cb, i) => {
    const key = `${ck}:${i}`; cb.checked = !!checks[key];
    cb.onchange = () => { const c = ls.get('checks', {}); if (cb.checked) c[key] = 1; else delete c[key]; ls.set('checks', c); };
  });

  // Reading progress, saved per volume; restored when opened without a section.
  const article = $('#reader');
  const posKey = 'pos:' + ck;
  const measure = () => {
    const r = article.getBoundingClientRect(); const h = r.height - innerHeight * .6;
    return Math.min(1, Math.max(0, -r.top / Math.max(1, h)));
  };
  let raf = 0;
  const onScroll = () => {
    cancelAnimationFrame(raf);
    raf = requestAnimationFrame(() => {
      const p = measure(); setProgress(p);
      if (!comp) { const all = ls.get('progress', {}); if (p > (all[v.n] || 0) || p < (all[v.n] || 0) - .02) { all[v.n] = p; ls.set('progress', all); } }
      ls.set(posKey, scrollY);
    });
  };
  addEventListener('scroll', onScroll, { passive: true });
  cleanup = () => removeEventListener('scroll', onScroll);

  if (anchor && anchor !== 'companion') {
    const el = document.getElementById(decodeURIComponent(anchor));
    if (el) { el.scrollIntoView(); el.classList.add('flash'); }
    const term = q.get('hl'); if (term) highlight(article, term);
  } else {
    scrollTo(0, ls.get(posKey, 0));
  }
  onScroll();
});
actions.go = (b) => { location.hash = b.dataset.href; };

function highlight(root, query) {
  const terms = query.toLowerCase().split(/\s+/).filter((t) => t.length > 1);
  if (!terms.length) return;
  const re = new RegExp(`(${terms.map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')})`, 'gi');
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const nodes = []; while (walker.nextNode()) if (re.test(walker.currentNode.nodeValue)) nodes.push(walker.currentNode);
  let first;
  nodes.slice(0, 200).forEach((n) => {
    const span = document.createElement('span'); span.innerHTML = esc(n.nodeValue).replace(re, '<mark>$1</mark>'); n.replaceWith(span);
    first ||= span;
  });
}

/* ---------- Principles, Algorithms, Review Mode ---------- */
const catList = (cats, base) => cats.map((c) => `<div class="section-title"><h3>${esc(c.title)}</h3><span class="small muted">${c.items.length}</span></div>
  <div class="list">${c.items.map((i) => `<a class="row" href="${base}${i.id}"><div class="body"><div class="t">${esc(i.name)}</div><div class="s">${esc(i.summary)}</div></div></a>`).join('')}</div>`).join('');

route(/^\/principles$/, async (m, q) => {
  setTab('library');
  const lib = await library();
  const hasCat = (lib.principleCatalog || []).length;
  const tab = q.get('tab') || (hasCat ? 'cat' : 'vol');
  setTop('Design Principles', { back: true, actions: `<button class="icon-btn" data-action="shuffle" aria-label="Random principle">${ICON.shuffle}</button>` });
  const seg = hasCat ? `<div class="seg"><button class="${tab === 'cat' ? 'on' : ''}" data-action="go" data-href="#/principles">Catalog</button><button class="${tab === 'vol' ? 'on' : ''}" data-action="go" data-href="#/principles?tab=vol">From the volumes</button></div>` : '';
  if (tab === 'cat') {
    view.innerHTML = `<div class="wrap" id="plist">${seg}${catList(lib.principleCatalog, '#/principle/')}</div>`;
    return;
  }
  const only = q.get('vol');
  const vols = lib.volumes.filter((v) => v.principleCount);
  const list = lib.principles.filter((p) => !only || p.vol === +only);
  view.innerHTML = `<div class="wrap">${seg}
    <div class="chips" style="margin-bottom:10px"><a class="chip ${!only ? 'on' : ''}" href="#/principles?tab=vol">All</a>${vols.map((v) => `<a class="chip ${+only === v.n ? 'on' : ''}" href="#/principles?tab=vol&vol=${v.n}">${v.n} · ${esc(v.title)}</a>`).join('')}</div>
    <div id="plist">${list.map((p, i) => `<div class="card principle" id="p${i}"><div class="eyebrow">Vol ${p.vol} · ${esc(p.volTitle)}</div><div class="name">${esc(p.name)}</div><div class="txt">${p.html}</div>
      <div class="src"><a href="#/vol/${p.vol}/c${p.vol}-design-principles">Read in context →</a></div></div>`).join('') || '<div class="empty">No principles yet.</div>'}</div></div>`;
});
actions.shuffle = async () => {
  const lib = await library();
  const ids = (lib.principleCatalog || []).flatMap((c) => c.items.map((i) => i.id));
  if (location.hash.includes('tab=vol') || !ids.length) {
    const cards = $$('#plist .card'); if (!cards.length) return;
    const c = cards[Math.floor(Math.random() * cards.length)];
    c.scrollIntoView({ block: 'center', behavior: 'smooth' }); c.style.animation = 'none'; void c.offsetWidth; c.style.animation = 'flash 1.6s ease-out';
    return;
  }
  location.hash = '#/principle/' + ids[Math.floor(Math.random() * ids.length)];
};

function collectionItem(cats, id) {
  for (const c of cats || []) { const k = c.items.findIndex((i) => i.id === id); if (k !== -1) return { cat: c, item: c.items[k], prev: c.items[k - 1], next: c.items[k + 1] }; }
  return null;
}
function itemPage({ cat, item, prev, next }, base, kind) {
  const nav = (i, dir) => i ? `<a href="${base}${i.id}"${dir === 'next' ? ' style="text-align:right"' : ''}><div class="card"><div class="dir">${dir === 'next' ? 'Next →' : '← Previous'}</div><div class="nm">${esc(i.name)}</div></div></a>` : '<span style="flex:1"></span>';
  return `<div class="wrap"><div class="vol-head"><div class="eyebrow">${kind} · ${esc(cat.title)}</div><h2>${esc(item.name)}</h2>
    ${item.summary ? `<p class="summary">${esc(item.summary)}</p>` : ''}</div>
    <article class="reader item-body" id="reader">${item.html}</article><div class="pager">${nav(prev, 'prev')}${nav(next, 'next')}</div></div>`;
}
route(/^\/principle\/(.+)$/, async ([, id]) => {
  setTab('library'); const lib = await library();
  const found = collectionItem(lib.principleCatalog, id); if (!found) { location.hash = '#/principles'; return; }
  setTop('Design Principle', { back: true, actions: `<button class="icon-btn" data-action="shuffle" aria-label="Random principle">${ICON.shuffle}</button><button class="icon-btn" data-action="type" aria-label="Reading settings">${ICON.type}</button>` });
  view.innerHTML = itemPage(found, '#/principle/', 'Principle'); scrollTo(0, 0);
});

route(/^\/algorithms$/, async () => {
  setTab('library'); setTop('Algorithms', { back: true });
  const lib = await library(); const cats = lib.algorithms || [];
  view.innerHTML = `<div class="wrap">${cats.length ? `<p class="muted small" style="margin-top:0">Each entry covers how it works, its costs, where you meet it, how it fails, and the judgment call a DE makes about it.</p>
    <div class="chips">${cats.map((c, i) => `<a class="chip" href="#/algorithms" data-action="jumpCat" data-i="${i}">${esc(c.title)}</a>`).join('')}</div>${catList(cats, '#/algo/')}`
    : '<div class="empty">The algorithms collection is being written and will appear here.</div>'}</div>`;
});
actions.jumpCat = (b, e) => { e.preventDefault(); $$('.section-title')[+b.dataset.i]?.scrollIntoView({ behavior: 'smooth' }); };
route(/^\/algo\/(.+)$/, async ([, id]) => {
  setTab('library'); const lib = await library();
  const found = collectionItem(lib.algorithms, id); if (!found) { location.hash = '#/algorithms'; return; }
  setTop('Algorithm', { back: true, actions: `<button class="icon-btn" data-action="type" aria-label="Reading settings">${ICON.type}</button>` });
  view.innerHTML = itemPage(found, '#/algo/', 'Algorithm'); scrollTo(0, 0);
});

route(/^\/review$/, async (m, q) => {
  setTab('library'); setTop('Review Mode', { back: true, actions: `<button class="icon-btn" data-action="type" aria-label="Reading settings">${ICON.type}</button>` });
  const lib = await library(); const only = +q.get('vol') || 0;
  const vols = lib.volumes.filter((v) => v.ready);
  const shown = vols.filter((v) => !only || v.n === only);
  view.innerHTML = `<div class="wrap">
    <p class="muted small" style="margin-top:0">The questions that expose weak designs, and each volume's checklist. Read these before an architecture review.</p>
    <div class="chips" style="margin-bottom:6px"><a class="chip ${!only ? 'on' : ''}" href="#/review">All</a>${vols.map((v) => `<a class="chip ${only === v.n ? 'on' : ''}" href="#/review?vol=${v.n}">${v.n} · ${esc(v.title)}</a>`).join('')}</div>
    <div class="reader">${shown.map((v) => {
      const ps = (lib.probes || []).filter((p) => p.vol === v.n);
      const check = v.sections.find((s) => s.level === 2 && /checklist/i.test(s.title));
      const compProbe = v.companion?.sections.find((s) => /what-a-de-probes$/.test(s.id));
      return `<h2 id="r${v.n}">Vol ${v.n} · ${esc(v.title)}</h2>
        ${ps.map((p) => `<div class="callout de">${p.section ? `<div class="eyebrow" style="margin-bottom:6px">${esc(p.section)}</div>` : ''}${p.html}<div class="small" style="margin-top:8px"><a href="#/vol/${v.n}/${p.id}">Open in volume →</a></div></div>`).join('')}
        <p class="small">${check ? `<a href="#/vol/${v.n}/${check.id}">Review checklist (${v.checklistCount || ''} items) →</a>` : ''}${compProbe ? ` &nbsp;·&nbsp; <a href="#/vol/${v.n}/${compProbe.id}">More probes in the companion notes →</a>` : ''}</p>`;
    }).join('')}</div></div>`;
});
actions.type = typeSheet;

/* ---------- Search ---------- */
let searchIndex = null;
async function buildIndex() {
  const lib = await library();
  const docs = [];
  for (const v of lib.volumes) {
    if (!v.ready) { docs.push({ kind: 'vol', title: v.title, where: `Vol ${v.n} · Queued`, text: v.scope, href: `#/vol/${v.n}` }); continue; }
    for (const s of v.sections) docs.push({ kind: 'vol', title: s.title, where: `Vol ${v.n} · ${v.title}`, text: s.text, href: `#/vol/${v.n}/${s.id}` });
  }
  for (const v of lib.volumes) if (v.companion) for (const s of v.companion.sections) docs.push({ kind: 'vol', title: s.title, where: `Vol ${v.n} · Companion notes`, text: s.text, href: `#/vol/${v.n}/${s.id}` });
  for (const p of lib.principles) docs.push({ kind: 'principle', title: p.name, where: `Principle · Vol ${p.vol}`, text: textOf(p.html), href: `#/principles?tab=vol&vol=${p.vol}` });
  for (const c of lib.principleCatalog || []) for (const i of c.items) docs.push({ kind: 'principle', title: i.name, where: `Design Principle · ${c.title}`, text: i.summary + ' ' + i.text, href: `#/principle/${i.id}` });
  for (const c of lib.algorithms || []) for (const i of c.items) docs.push({ kind: 'algo', title: i.name, where: `Algorithm · ${c.title}`, text: i.summary + ' ' + i.text, href: `#/algo/${i.id}` });
  for (const s of await db.all('saved')) docs.push({ kind: 'saved', title: s.title, where: `Saved · ${s.source || host(s.url)}`, text: textOf(s.content) || s.excerpt || '', href: `#/read/saved/${encodeURIComponent(s.id)}` });
  for (const l of await laterItems()) docs.push({ kind: 'later', title: l.title || l.url, where: `Read Later · ${host(l.url)}`, text: textOf(l.content) || l.excerpt || '', href: `#/read/later/${encodeURIComponent(l.id)}` });
  for (const d of docs) { d.lt = d.title.toLowerCase(); d.lx = d.text.toLowerCase(); }
  return docs;
}
function search(docs, query) {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return [];
  const out = [];
  for (const d of docs) {
    let score = 0, ok = true;
    for (const t of terms) {
      const inTitle = d.lt.includes(t); let n = 0, i = -1;
      while ((i = d.lx.indexOf(t, i + 1)) !== -1 && n < 30) n++;
      if (!inTitle && !n) { ok = false; break; }
      score += (inTitle ? 12 : 0) + Math.log2(1 + n) * 2;
    }
    if (!ok) continue;
    if (d.lt.includes(query.toLowerCase())) score += 10;
    if (d.lx.includes(query.toLowerCase())) score += 4;
    if (d.kind === 'principle' || d.kind === 'algo') score += 2;
    out.push({ d, score });
  }
  return out.sort((a, b) => b.score - a.score).slice(0, 80);
}
function snippet(text, terms) {
  const lx = text.toLowerCase(); let at = -1;
  for (const t of terms) { at = lx.indexOf(t); if (at !== -1) break; }
  const start = Math.max(0, at - 70); let s = (start ? '…' : '') + text.slice(start, start + 220) + (text.length > start + 220 ? '…' : '');
  s = esc(s);
  const re = new RegExp(`(${terms.map((t) => esc(t).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')})`, 'gi');
  return s.replace(re, '<mark>$1</mark>');
}
route(/^\/search$/, async (m, q) => {
  setTab('search'); setTop('Search');
  const recent = ls.get('recent', []);
  view.innerHTML = `<div class="wrap">
    <label class="field search-field">${ICON.search}<input id="q" type="search" inputmode="search" autocomplete="off" autocorrect="off" spellcheck="false" placeholder="Search volumes, principles, algorithms, saved" value="${esc(q.get('q') || '')}"></label>
    <div id="results" style="margin-top:14px"></div></div>`;
  const input = $('#q'), out = $('#results');
  searchIndex = await buildIndex();
  const run = () => {
    const query = input.value.trim();
    history.replaceState(null, '', '#/search' + (query ? '?q=' + encodeURIComponent(query) : ''));
    if (!query) {
      const r = ls.get('recent', []);
      out.innerHTML = r.length ? `<div class="section-title" style="margin-top:4px"><h3>Recent</h3><button class="link-btn" data-action="clearRecent">Clear</button></div><div class="chips" style="flex-wrap:wrap">${r.map((t) => `<button class="chip" data-action="setq" data-q="${esc(t)}">${esc(t)}</button>`).join('')}</div>`
        : `<div class="empty">${ICON.search}<div>Search across all volumes, design principles,<br>saved feed articles and your Read Later list.</div></div>`;
      return;
    }
    const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
    const res = search(searchIndex, query);
    const hl = (href) => (href.includes('/vol/') ? href + '?hl=' + encodeURIComponent(query) : href);
    out.innerHTML = res.length ? `<div class="small muted" style="margin:0 2px 8px">${res.length}${res.length === 80 ? '+' : ''} results</div><div class="list">${res.map(({ d }) => `<a class="result" href="${hl(d.href)}" data-action="remember">
      <div class="where">${esc(d.where)}</div><div class="t">${snippet(d.title, terms)}</div><div class="snip">${snippet(d.text, terms)}</div></a>`).join('')}</div>`
      : `<div class="empty">No matches for “${esc(query)}”.</div>`;
  };
  let t; input.oninput = () => { clearTimeout(t); t = setTimeout(run, 120); };
  input.onkeydown = (e) => { if (e.key === 'Enter') { input.blur(); actions.remember(); } };
  run();
  if (!input.value) setTimeout(() => input.focus(), 50);
});
actions.remember = () => {
  const v = $('#q')?.value.trim(); if (!v) return;
  ls.set('recent', [v, ...ls.get('recent', []).filter((x) => x !== v)].slice(0, 10));
};
actions.setq = (b) => { const i = $('#q'); i.value = b.dataset.q; i.oninput(); };
actions.clearRecent = () => { ls.set('recent', []); $('#q').oninput(); };

/* ---------- AI Feeds ---------- */
const feedState = { tab: 'hot', source: '' };
route(/^\/feeds$/, async () => {
  setTab('feeds'); setTop('AI Feeds', { actions: `<button class="icon-btn" data-action="refreshFeeds" aria-label="Refresh">${ICON.refresh}</button>` });
  view.innerHTML = '<div class="wrap"><div class="empty">Loading feeds…</div></div>';
  let data;
  try { data = await getJSON('data/feeds.json'); } catch { data = null; }
  const saved = await db.all('saved'); const savedIds = new Set(saved.map((s) => s.id));
  const readIds = new Set(ls.get('readFeed', []));
  const render = () => {
    const { tab, source } = feedState;
    let items = tab === 'saved' ? saved.sort((a, b) => (b.savedAt || '').localeCompare(a.savedAt || '')) : (data?.items || []).slice();
    if (tab === 'hot') items.sort((a, b) => b.hot - a.hot);
    if (tab === 'latest') items.sort((a, b) => b.ts - a.ts);
    const sources = [...new Set(items.map((i) => i.source))];
    if (source) items = items.filter((i) => i.source === source);
    items = items.slice(0, 150);
    view.innerHTML = `<div class="wrap">
      <div class="seg">${[['hot', 'Top & Hot'], ['latest', 'Latest'], ['saved', `Saved${saved.length ? ' (' + saved.length + ')' : ''}`]].map(([k, l]) => `<button class="${tab === k ? 'on' : ''}" data-action="feedTab" data-k="${k}">${l}</button>`).join('')}</div>
      ${sources.length > 1 ? `<div class="chips" style="margin-bottom:12px"><button class="chip ${!source ? 'on' : ''}" data-action="feedSrc" data-s="">All</button>${sources.map((s) => `<button class="chip ${source === s ? 'on' : ''}" data-action="feedSrc" data-s="${esc(s)}">${esc(s)}</button>`).join('')}</div>` : ''}
      ${items.length ? `<div class="list">${items.map((i) => feedItem(i, tab === 'saved' || savedIds.has(i.id), readIds.has(i.id), tab === 'saved')).join('')}</div>`
        : `<div class="empty">${tab === 'saved' ? 'Nothing saved yet. Tap the bookmark on any article to keep it on this phone.' : data ? 'No articles.' : 'Feeds aren\'t available yet. They appear after the first scheduled fetch.'}</div>`}
      ${data && tab !== 'saved' ? `<p class="small muted" style="margin-top:14px">Updated ${ago(data.fetchedAt)} · ${data.sources.length} sources</p>` : ''}</div>`;
  };
  feedRender = render; feedCtx = { data, saved, savedIds, readIds };
  render();
});
let feedRender = null, feedCtx = null;
function feedItem(i, isSaved, isRead, savedTab) {
  const kind = savedTab ? 'saved' : 'feed';
  return `<div class="item ${isRead ? 'read' : ''}">
    <div class="src"><b>${esc(i.source)}</b><span>${ago(i.date || i.ts || i.savedAt)}</span>${i.points ? `<span>· ${i.points} points</span>` : ''}${i.content ? '<span class="pill acc">Full text</span>' : ''}</div>
    <a class="t" href="#/read/${kind}/${encodeURIComponent(i.id)}">${esc(i.title)}</a>
    ${i.excerpt ? `<div class="x">${esc(i.excerpt)}</div>` : ''}
    <div class="acts">
      <button class="btn sm save-btn ${isSaved ? 'on' : ''}" data-action="toggleSave" data-id="${esc(i.id)}">${isSaved ? ICON.bookmarkOn + ' Saved' : ICON.bookmark + ' Save'}</button>
      ${i.discuss ? `<a class="btn sm" href="${esc(i.discuss)}" target="_blank" rel="noopener">Discuss</a>` : ''}
      <span class="spacer"></span>
      <a class="btn sm" href="${esc(i.url)}" target="_blank" rel="noopener" aria-label="Open original">${ICON.ext}</a>
    </div></div>`;
}
actions.feedTab = (b) => { feedState.tab = b.dataset.k; feedState.source = ''; feedRender?.(); scrollTo(0, 0); };
actions.feedSrc = (b) => { feedState.source = b.dataset.s; feedRender?.(); };
actions.refreshFeeds = async (b) => {
  b.querySelector('svg').classList.add('spin');
  try { await getJSON('data/feeds.json', { fresh: true }); toast('Feeds updated'); } catch { toast("Offline: showing what's on this phone"); }
  router();
};
actions.toggleSave = async (b) => {
  const id = b.dataset.id;
  if (await db.get('saved', id)) {
    await db.del('saved', id); toast('Removed from Saved');
  } else {
    const i = (cache['data/feeds.json']?.items || []).find((x) => x.id === id); if (!i) return;
    await db.put('saved', { ...i, savedAt: new Date().toISOString() });
    toast(i.content ? 'Saved on this phone' : 'Saved (link only, no full text available)');
  }
  if (location.hash.startsWith('#/feeds')) router(); else router();
};

/* ---------- Article reader (feed, saved, read later) ---------- */
route(/^\/read\/(feed|saved|later)\/(.+)$/, async ([, kind, rawId]) => {
  const id = decodeURIComponent(rawId);
  setTab(kind === 'later' ? 'later' : 'feeds');
  let a;
  if (kind === 'saved') a = await db.get('saved', id);
  if (kind === 'feed') { try { a = (await getJSON('data/feeds.json')).items.find((x) => x.id === id); } catch { /* offline */ } a ||= await db.get('saved', id); }
  if (kind === 'later') a = (await laterItems()).find((x) => x.id === id);
  if (!a) { view.innerHTML = '<div class="wrap"><div class="empty">This article isn\'t available offline.</div></div>'; setTop('Article', { back: true }); return; }
  setTop(a.source || host(a.url), { back: true, actions: `<button class="icon-btn" data-action="type" aria-label="Reading settings">${ICON.type}</button>` });
  if (kind !== 'later') ls.set('readFeed', [id, ...ls.get('readFeed', []).filter((x) => x !== id)].slice(0, 500));
  else setLater(id, { read: true });
  const isSaved = kind !== 'later' && !!(await db.get('saved', id));
  view.innerHTML = `<div class="wrap"><div class="article-head"><div class="eyebrow">${esc(a.source || host(a.url))}${a.byline ? ' · ' + esc(a.byline) : ''}</div>
    <h2>${esc(a.title || a.url)}</h2><div class="meta">${ago(a.date || a.addedAt || a.savedAt)}${a.content ? ` · ${readMins(textOf(a.content).split(' ').length)} min read` : ''}</div></div>
    <div class="article-actions">
      <a class="btn" href="${esc(a.url)}" target="_blank" rel="noopener">${ICON.ext} Original</a>
      ${kind !== 'later' ? `<button class="btn save-btn ${isSaved ? 'on' : ''}" data-action="toggleSave" data-id="${esc(id)}">${isSaved ? ICON.bookmarkOn + ' Saved' : ICON.bookmark + ' Save'}</button>` : `<button class="btn" data-action="archiveLater" data-id="${esc(id)}">${ICON.check} Done</button>`}
      ${a.discuss ? `<a class="btn" href="${esc(a.discuss)}" target="_blank" rel="noopener">Discussion</a>` : ''}
    </div>
    <article class="reader" id="reader">${a.content || `<p class="muted">${esc(a.excerpt || '')}</p><div class="queued-note">The full text isn't available in the app for this one. Tap <b>Original</b> to read it on the web.</div>`}</article></div>`;
  scrollTo(0, 0);
  const article = $('#reader'); let raf;
  const onScroll = () => { cancelAnimationFrame(raf); raf = requestAnimationFrame(() => { const r = article.getBoundingClientRect(); setProgress(Math.min(1, Math.max(0, -r.top / Math.max(1, r.height - innerHeight * .6)))); }); };
  addEventListener('scroll', onScroll, { passive: true }); cleanup = () => removeEventListener('scroll', onScroll);
});

/* ---------- Read Later ---------- */
const laterState = () => ls.get('laterState', {});
function setLater(id, patch) { const s = laterState(); s[id] = { ...(s[id] || {}), ...patch }; ls.set('laterState', s); }

async function githubOpenIssues(repo) {
  try {
    const res = await fetch(`https://api.github.com/repos/${repo}/issues?state=all&per_page=50`, { headers: { accept: 'application/vnd.github+json' } });
    if (!res.ok) return [];
    return (await res.json()).filter((i) => !i.pull_request).map((i) => {
      const url = (i.body || i.title || '').match(/https?:\/\/[^\s<>()"']+/)?.[0];
      return url && { id: `gh-${i.number}`, url, title: /^https?:\/\//.test(i.title) ? '' : i.title, addedAt: i.created_at, source: host(url), content: '', pending: true };
    }).filter(Boolean);
  } catch { return []; }
}
let laterCache = null;
async function laterItems({ fresh = false } = {}) {
  if (laterCache && !fresh) return laterCache;
  let inbox = [];
  try { inbox = (await getJSON('data/inbox.json', { fresh })).items; } catch { /* offline or not deployed */ }
  const byId = new Map(inbox.map((i) => [i.id, i]));
  const repo = repoSlug();
  if (repo && navigator.onLine) for (const i of await githubOpenIssues(repo)) if (!byId.has(i.id)) byId.set(i.id, i);
  for (const l of await db.all('later')) byId.set(l.id, { ...byId.get(l.id), ...l });
  const st = laterState();
  laterCache = [...byId.values()].filter((i) => !st[i.id]?.deleted).map((i) => ({ ...i, ...(st[i.id] || {}) }))
    .sort((a, b) => (b.addedAt || '').localeCompare(a.addedAt || ''));
  // Keep a copy of every item's text on the phone so Read Later works offline.
  for (const i of laterCache) if (i.content && i.id.startsWith('gh-')) db.put('later', { id: i.id, url: i.url, title: i.title, addedAt: i.addedAt, source: i.source, content: i.content, excerpt: i.excerpt, byline: i.byline }).catch(() => {});
  return laterCache;
}
let laterTab = 'unread';
route(/^\/later$/, async () => {
  setTab('later'); setTop('Read Later', { actions: `<button class="icon-btn" data-action="refreshLater" aria-label="Refresh">${ICON.refresh}</button><button class="icon-btn" data-action="addLater" aria-label="Add link">${ICON.plus}</button>` });
  const items = await laterItems();
  const list = items.filter((i) => (laterTab === 'done' ? i.archived : !i.archived));
  view.innerHTML = `<div class="wrap">
    <div class="seg">${[['unread', `To read (${items.filter((i) => !i.archived).length})`], ['done', 'Done']].map(([k, l]) => `<button class="${laterTab === k ? 'on' : ''}" data-action="laterTab" data-k="${k}">${l}</button>`).join('')}</div>
    ${list.length ? `<div class="list">${list.map((i) => `<div class="item ${i.read ? 'read' : ''}">
        <div class="src"><b>${esc(i.source || host(i.url))}</b><span>${ago(i.addedAt)}</span>${i.content ? '<span class="pill acc">Offline</span>' : i.pending ? '<span class="pill">Fetching text…</span>' : ''}</div>
        <a class="t" href="${i.content ? `#/read/later/${encodeURIComponent(i.id)}` : esc(i.url)}" ${i.content ? '' : 'target="_blank" rel="noopener"'}>${esc(i.title || i.url)}</a>
        ${i.excerpt ? `<div class="x">${esc(i.excerpt)}</div>` : ''}
        <div class="acts"><button class="btn sm" data-action="archiveLater" data-id="${esc(i.id)}">${i.archived ? 'Move back' : ICON.check + ' Done'}</button>
          <button class="btn sm" data-action="deleteLater" data-id="${esc(i.id)}" aria-label="Delete">${ICON.trash}</button><span class="spacer"></span>
          <a class="btn sm" href="${esc(i.url)}" target="_blank" rel="noopener" aria-label="Open original">${ICON.ext}</a></div></div>`).join('')}</div>`
      : `<div class="empty">${ICON.inbox}<div>${laterTab === 'done' ? 'Nothing marked done yet.' : 'Your reading list is empty.'}</div></div>`}
    <div class="card" style="margin-top:18px"><b>Add pages from Safari</b><p class="small muted" style="margin:6px 0 10px">Share any page to LevelUP in one tap with an iOS Shortcut, or copy a link and tap +.</p>
      <a class="btn sm" href="#/shortcut">Set up the Shortcut</a></div></div>`;
});
actions.laterTab = (b) => { laterTab = b.dataset.k; router(); };
actions.refreshLater = async (b) => { b.querySelector('svg').classList.add('spin'); await laterItems({ fresh: true }); router(); };
actions.archiveLater = async (b) => {
  const id = b.dataset.id; const cur = laterState()[id]?.archived; setLater(id, { archived: !cur });
  laterCache = null; toast(cur ? 'Moved back to To read' : 'Marked done');
  if (location.hash.startsWith('#/read/')) history.back(); else router();
};
actions.deleteLater = async (b) => {
  const id = b.dataset.id; setLater(id, { deleted: true }); await db.del('later', id).catch(() => {}); laterCache = null; toast('Deleted'); router();
};
actions.addLater = () => {
  openSheet(`<h3>Add to Read Later</h3>
    <div class="form-row"><label for="addurl">Link</label><input id="addurl" type="url" inputmode="url" placeholder="https://…" autocomplete="off"></div>
    <div style="display:flex;gap:8px"><button class="btn" id="pastebtn">${ICON.paste} Paste</button><span style="flex:1"></span><button class="btn primary" id="addbtn">Add</button></div>
    <p class="small muted" style="margin-top:14px">${ls.get('settings', {}).token ? 'The page text is fetched for offline reading within a couple of minutes.' : 'Without a GitHub token in Settings, links added here stay on this phone and open on the web.'}</p>`,
  (sh, close) => {
    const inp = $('#addurl', sh);
    $('#pastebtn', sh).onclick = async () => { try { inp.value = (await navigator.clipboard.readText()).trim(); } catch { toast('Long-press the field and choose Paste'); inp.focus(); } };
    $('#addbtn', sh).onclick = async () => { const ok = await addLater(inp.value.trim()); if (ok) close(); };
  });
};
async function addLater(url, title = '') {
  if (!/^https?:\/\/\S+$/.test(url)) { toast('That doesn\'t look like a link'); return false; }
  const { token } = ls.get('settings', {}); const repo = repoSlug();
  if (token && repo) {
    try {
      const res = await fetch(`https://api.github.com/repos/${repo}/issues`, {
        method: 'POST', headers: { accept: 'application/vnd.github+json', authorization: `Bearer ${token}`, 'content-type': 'application/json' },
        body: JSON.stringify({ title: title || url, body: url, labels: ['read-later'] }),
      });
      if (!res.ok) throw new Error(res.status);
      const i = await res.json();
      await db.put('later', { id: `gh-${i.number}`, url, title, addedAt: i.created_at, source: host(url), content: '', pending: true });
      laterCache = null; toast('Added. Text arrives shortly'); router(); return true;
    } catch (e) { toast(`Couldn't reach GitHub (${e.message}); saved on this phone`); }
  }
  await db.put('later', { id: 'local-' + Date.now(), url, title, addedAt: new Date().toISOString(), source: host(url), content: '' });
  laterCache = null; toast('Added to Read Later'); router(); return true;
}
// Lets a link like #/add?url=…&title=… add straight to the list (bookmarklet or Shortcut opening the app).
route(/^\/add$/, async (m, q) => { const url = q.get('url'); history.replaceState(null, '', '#/later'); if (url) await addLater(url, q.get('title') || ''); else router(); });

route(/^\/shortcut$/, async () => {
  setTab('later'); setTop('Share from Safari', { back: true });
  const repo = repoSlug() || 'OWNER/REPO';
  view.innerHTML = `<div class="wrap reader" style="--fs:17px">
    <p>iPhone keeps home-screen apps separate from Safari, so pages reach LevelUP through a tiny inbox: the Shortcut files the link in your GitHub repo, the repo fetches a clean, readable copy, and the app pulls it down and keeps it offline.</p>
    <h3>1. Make a token (once)</h3>
    <ol class="steps"><li>On GitHub: Settings → Developer settings → Fine-grained tokens → Generate new token.</li>
      <li>Repository access: <b>Only select repositories</b> → <span class="kbd">${esc(repo)}</span>.</li>
      <li>Permissions: <b>Issues → Read and write</b>. Nothing else.</li>
      <li>Copy the token. Paste it in this app's <a href="#/settings">Settings</a> too, so the + button works the same way.</li></ol>
    <h3>2. Build the Shortcut (2 minutes)</h3>
    <ol class="steps"><li>Open <b>Shortcuts</b> → + → name it <b>Send to LevelUP</b>.</li>
      <li>Tap the ⓘ button → turn on <b>Show in Share Sheet</b>, and set it to receive <b>URLs</b> and <b>Safari web pages</b>.</li>
      <li>Add action <b>Get Contents of URL</b>:
        <ul><li>URL: <span class="kbd">https://api.github.com/repos/${esc(repo)}/issues</span></li>
        <li>Method: <b>POST</b></li>
        <li>Headers: <span class="kbd">Authorization</span> = <span class="kbd">Bearer YOUR_TOKEN</span>, and <span class="kbd">Accept</span> = <span class="kbd">application/vnd.github+json</span></li>
        <li>Request Body: <b>JSON</b> with <span class="kbd">title</span> = <i>Shortcut Input</i>, <span class="kbd">body</span> = <i>Shortcut Input</i>, and <span class="kbd">labels</span> = an Array holding the text <span class="kbd">read-later</span></li></ul></li>
      <li>Add action <b>Show Notification</b>: “Saved to LevelUP”.</li></ol>
    <h3>3. Use it</h3>
    <p>In Safari tap Share → <b>Send to LevelUP</b>. The page shows up in Read Later right away and becomes readable offline within a couple of minutes.</p>
    <p class="small muted">Saved links are GitHub issues in your repo. If the repo is public, so is the list of links you save.</p></div>`;
});

/* ---------- Settings ---------- */
route(/^\/settings$/, async () => {
  setTab('library'); setTop('Settings', { back: true });
  const s = ls.get('settings', {}); const lib = await library().catch(() => null);
  view.innerHTML = `<div class="wrap">
    <div class="card"><b>Reading</b><p class="small muted" style="margin:4px 0 10px">Text size, font and theme.</p><button class="btn sm" data-action="type">${ICON.type} Reading settings</button></div>
    <div class="card"><b>Read Later inbox</b>
      <div class="form-row"><label for="repo">GitHub repo</label><input id="repo" placeholder="${esc(repoSlug() || 'owner/repo')}" value="${esc(s.repo || '')}" autocapitalize="off" autocorrect="off"></div>
      <div class="form-row"><label for="tok">Token (Issues: read and write)</label><input id="tok" type="password" value="${esc(s.token || '')}" autocomplete="off"></div>
      <div style="display:flex;gap:8px"><button class="btn primary sm" id="savecfg">Save</button><a class="btn sm" href="#/shortcut">Shortcut setup</a></div>
      <p class="small muted" style="margin-bottom:0">The token stays on this phone and is only sent to api.github.com.</p></div>
    <div class="card"><b>Offline</b><p class="small muted" style="margin:4px 0 10px">The library, search and saved articles work without a connection.</p>
      <button class="btn sm" data-action="update">${ICON.refresh} Check for updates</button></div>
    <p class="small muted">${lib ? `Library built ${ago(lib.builtAt)}.` : ''}</p></div>`;
  $('#savecfg').onclick = () => { ls.set('settings', { repo: $('#repo').value.trim(), token: $('#tok').value.trim() }); laterCache = null; toast('Saved'); };
});
actions.update = async () => {
  const reg = await navigator.serviceWorker?.getRegistration(); await reg?.update();
  for (const k of Object.keys(cache)) delete cache[k];
  try { await getJSON('data/library.json', { fresh: true }); toast('Up to date'); } catch { toast('Offline'); }
};

/* ---------- boot ---------- */
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('sw.js').catch(() => {});
  let reloaded = false;
  navigator.serviceWorker.addEventListener('controllerchange', () => { if (!reloaded && !document.hidden) { reloaded = true; cache['data/library.json'] = null; router(); } });
}
router();
