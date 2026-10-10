// Offline support: the app shell and library are precached; feeds and the read-later inbox
// are network-first with the last copy kept for offline use.
const VERSION = '1dbe0fedb6';
const SHELL = `levelup-shell-${VERSION}`;
const DATA = 'levelup-data';
const ASSETS = ['./', 'index.html', 'app.css', 'app.js', 'manifest.webmanifest', 'data/library.json',
  'icons/icon-192.png', 'icons/icon-512.png', 'icons/apple-touch-icon.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(SHELL).then((c) => c.addAll(ASSETS.map((a) => new Request(a, { cache: 'reload' })))).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k.startsWith('levelup-shell-') && k !== SHELL).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;
  const path = url.pathname;
  if (/\/data\/(feeds|inbox)\.json$/.test(path)) {
    e.respondWith(fetch(e.request).then((res) => {
      if (res.ok) { const copy = res.clone(); caches.open(DATA).then((c) => c.put(path, copy)); }
      return res;
    }).catch(() => caches.open(DATA).then((c) => c.match(path)).then((r) => r || Response.json({ items: [], offline: true }))));
    return;
  }
  e.respondWith(caches.match(e.request, { ignoreSearch: true }).then((hit) => hit || fetch(e.request).catch(() =>
    e.request.mode === 'navigate' ? caches.match('index.html') : Response.error())));
});
