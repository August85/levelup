// Read Later inbox: every GitHub issue in this repo whose body holds a link is a saved page
// (the iOS Shortcut creates them from Safari's share sheet). Extracts readable text for each
// and writes app/data/inbox.json. Reuses text already published so pages are fetched once.
import { writeFileSync } from 'node:fs';
import './proxy.mjs';
import { extract, mapLimit } from './readable.mjs';

const root = new URL('..', import.meta.url).pathname;
const repo = process.env.GITHUB_REPOSITORY;
const token = process.env.GITHUB_TOKEN;
const site = process.env.PAGES_URL; // e.g. https://august85.github.io/levelup/

const out = { fetchedAt: new Date().toISOString(), items: [] };
if (!repo) {
  console.log('GITHUB_REPOSITORY not set; writing empty inbox');
  writeFileSync(root + 'app/data/inbox.json', JSON.stringify(out));
  process.exit(0);
}

const gh = async (path) => {
  const res = await fetch(`https://api.github.com${path}`, {
    headers: { accept: 'application/vnd.github+json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
  });
  if (!res.ok) throw new Error(`${res.status} ${path}`);
  return res.json();
};

const issues = [];
for (let page = 1; page < 20; page++) {
  const batch = await gh(`/repos/${repo}/issues?state=all&per_page=100&page=${page}`);
  issues.push(...batch.filter((i) => !i.pull_request));
  if (batch.length < 100) break;
}

let previous = new Map();
if (site) {
  try {
    const prev = await (await fetch(new URL('data/inbox.json', site), { signal: AbortSignal.timeout(10000) })).json();
    previous = new Map(prev.items.map((i) => [i.id, i]));
  } catch { /* first deploy */ }
}

const urlIn = (s) => (s || '').match(/https?:\/\/[^\s<>()"']+/)?.[0];
out.items = (await mapLimit(issues, 5, async (iss) => {
  const url = urlIn(iss.body) || urlIn(iss.title);
  if (!url) return null;
  const id = `gh-${iss.number}`;
  const prev = previous.get(id);
  const base = {
    id, url, addedAt: iss.created_at, source: (() => { try { return new URL(url).hostname.replace(/^www\./, ''); } catch { return ''; } })(),
    title: iss.title && !/^https?:\/\//.test(iss.title) ? iss.title : '',
  };
  if (prev?.content) return { ...prev, ...base, title: base.title || prev.title };
  const r = await extract(url);
  return { ...base, title: base.title || r?.title || url, excerpt: r?.excerpt || '', byline: r?.byline || '', content: r?.content || '' };
})).filter(Boolean);

writeFileSync(root + 'app/data/inbox.json', JSON.stringify(out));
console.log(`inbox.json: ${out.items.length} items`);
