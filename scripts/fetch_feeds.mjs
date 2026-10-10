// Fetches the AI blogs in feeds.config.json plus "hot" AI stories from Hacker News,
// pulls readable full text where the feed doesn't carry it, and writes app/data/feeds.json.
import { readFileSync, writeFileSync } from 'node:fs';
import './proxy.mjs';
import { XMLParser } from 'fast-xml-parser';
import { extract, clean, mapLimit } from './readable.mjs';

const root = new URL('..', import.meta.url).pathname;
const cfg = JSON.parse(readFileSync(root + 'feeds.config.json', 'utf8'));
const UA = 'LevelUP-reader/1.0 (+personal feed reader)';
const parser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '@', textNodeName: '#text', cdataPropName: false });

const text = (v) => (v == null ? '' : typeof v === 'object' ? (v['#text'] ?? '') : String(v)).trim();
const arr = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);
const stripTags = (s) => s.replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&#39;|&apos;/g, "'").replace(/&quot;/g, '"').replace(/\s+/g, ' ').trim();

async function get(url, ms = 15000) {
  const res = await fetch(url, { headers: { 'user-agent': UA, accept: '*/*' }, signal: AbortSignal.timeout(ms), redirect: 'follow' });
  if (!res.ok) throw new Error(`${res.status} ${url}`);
  return res.text();
}

function parseFeed(xml, blog) {
  const doc = parser.parse(xml);
  const items = [];
  if (doc.rss || doc['rdf:RDF']) {
    const ch = doc.rss ? doc.rss.channel : doc['rdf:RDF'];
    for (const it of arr(ch.item || doc['rdf:RDF']?.item)) {
      items.push({
        title: stripTags(text(it.title)), url: text(it.link) || text(it.guid),
        date: text(it.pubDate) || text(it['dc:date']),
        content: text(it['content:encoded']), summary: text(it.description),
      });
    }
  } else if (doc.feed) {
    for (const e of arr(doc.feed.entry)) {
      const links = arr(e.link);
      const alt = links.find((l) => !l['@rel'] || l['@rel'] === 'alternate') || links[0] || {};
      items.push({
        title: stripTags(text(e.title)), url: alt['@href'] || text(e.id),
        date: text(e.published) || text(e.updated),
        content: text(e.content), summary: text(e.summary),
      });
    }
  }
  return items.map((i) => ({ ...i, source: blog.name, kind: 'blog' }));
}

async function blogs() {
  const cutoff = Date.now() - cfg.maxAgeDays * 864e5;
  const results = await mapLimit(cfg.blogs, 6, async (b) => {
    try {
      const items = parseFeed(await get(b.url), b)
        .map((i) => ({ ...i, ts: Date.parse(i.date) || 0 }))
        .filter((i) => i.url && i.title && (!i.ts || i.ts > cutoff))
        .sort((a, z) => z.ts - a.ts).slice(0, cfg.maxPerBlog);
      console.log(`ok   ${b.name}: ${items.length}`);
      return items;
    } catch (e) { console.log(`fail ${b.name}: ${e.message}`); return []; }
  });
  return results.flat();
}

async function hackerNews() {
  const hn = cfg.hackerNews; const since = Math.floor(Date.now() / 1000) - hn.days * 86400;
  const byId = new Map();
  await mapLimit(hn.queries, 4, async (q) => {
    const u = `https://hn.algolia.com/api/v1/search?tags=story&query=${encodeURIComponent(q)}&numericFilters=created_at_i>${since},points>${hn.minPoints}&hitsPerPage=30`;
    try {
      for (const h of JSON.parse(await get(u)).hits) {
        if (!h.url) continue;
        byId.set(h.objectID, {
          title: h.title, url: h.url, ts: h.created_at_i * 1000, date: h.created_at, source: 'Hacker News',
          kind: 'hn', points: h.points, comments: h.num_comments,
          discuss: `https://news.ycombinator.com/item?id=${h.objectID}`, summary: '', content: '',
        });
      }
    } catch (e) { console.log(`fail HN "${q}": ${e.message}`); }
  });
  console.log(`ok   Hacker News: ${byId.size}`);
  return [...byId.values()];
}

// "Hot" = points decayed by age (HN-style gravity); blogs get a baseline so fresh posts surface too.
const hotness = (i) => {
  const hours = Math.max(1, (Date.now() - (i.ts || Date.now())) / 36e5);
  const base = i.kind === 'hn' ? i.points : 60;
  return base / Math.pow(hours + 2, 1.5);
};

const id = (url) => Buffer.from(url).toString('base64url').slice(-24);
let items = [...await blogs(), ...await hackerNews()];
const seen = new Set();
items = items.filter((i) => !seen.has(i.url) && seen.add(i.url));

for (const i of items) {
  i.id = id(i.url);
  i.hot = +hotness(i).toFixed(4);
  i.content = clean(i.content || '');
  i.excerpt = stripTags(i.summary || i.content).slice(0, 280);
  if (i.excerpt.toLowerCase() === i.title.toLowerCase()) i.excerpt = stripTags(i.content).slice(0, 280);
  if (i.excerpt.toLowerCase().startsWith(i.title.toLowerCase())) i.excerpt = i.excerpt.slice(i.title.length).trim();
  delete i.summary;
}

// Fill in readable text for the hottest items whose feed has no real body, so "Save" works offline.
const needText = items.filter((i) => stripTags(i.content).length < 800).sort((a, z) => z.hot - a.hot).slice(0, cfg.extractFullText);
await mapLimit(needText, 6, async (i) => {
  const r = await extract(i.url);
  if (r?.content) { i.content = r.content; if (!i.excerpt) i.excerpt = r.excerpt || ''; }
});

items.sort((a, z) => z.ts - a.ts);
writeFileSync(root + 'app/data/feeds.json', JSON.stringify({
  fetchedAt: new Date().toISOString(),
  sources: cfg.blogs.map((b) => b.name).concat('Hacker News'),
  items,
}));
console.log(`feeds.json: ${items.length} items, ${items.filter((i) => i.content).length} with full text`);
