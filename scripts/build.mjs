// Builds app/data/library.json from content/catalog.json + content/vol-NN.md,
// and stamps a fresh cache version into app/sw.js so phones pick up new content.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { marked } from 'marked';
import { parseHTML } from 'linkedom';

const root = new URL('..', import.meta.url).pathname;
const catalog = JSON.parse(readFileSync(root + 'content/catalog.json', 'utf8'));

const slug = (s) => s.toLowerCase().replace(/<[^>]+>/g, '').replace(/&[a-z]+;/g, '')
  .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 60);
const toText = (html) => html.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<')
  .replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/\s+/g, ' ').trim();

// Headings get stable ids so the reader can deep-link and the search can jump to them.
function render(md, prefix) {
  const seen = new Map();
  const renderer = new marked.Renderer();
  renderer.heading = (text, level) => {
    let id = prefix + slug(text);
    const c = seen.get(id) || 0; seen.set(id, c + 1);
    if (c) id += '-' + c;
    return `<h${level} id="${id}">${text}</h${level}>\n`;
  };
  // Checklist items become tappable, persisted checkboxes.
  renderer.checkbox = () => '';
  renderer.listitem = (text, task, checked) => task
    ? `<li class="task"><label><input type="checkbox" data-task>${text.replace(/^<p>|<\/p>$/g, '')}</label></li>\n`
    : `<li>${text}</li>\n`;
  renderer.table = (header, body) => `<div class="table-wrap"><table><thead>${header}</thead><tbody>${body}</tbody></table></div>\n`;
  renderer.link = (href, title, text) => `<a href="${href}" target="_blank" rel="noopener">${text}</a>`;
  return marked.parse(md, { renderer, gfm: true });
}

// Split rendered HTML into sections at h2/h3 for the TOC and search index.
function sections(html) {
  const out = [];
  const re = /<h([23]) id="([^"]+)">([\s\S]*?)<\/h\1>/g;
  let m, last = null;
  while ((m = re.exec(html))) {
    if (last) last.text = toText(html.slice(last.start, m.index));
    last = { level: +m[1], id: m[2], title: toText(m[3]), start: m.index + m[0].length };
    out.push(last);
  }
  if (last) last.text = toText(html.slice(last.start));
  return out.map(({ start, ...s }) => s);
}

function extractSection(md, name) {
  const m = md.match(new RegExp(`^## ${name}\\s*\\n([\\s\\S]*?)(?=^## |$(?![\\s\\S]))`, 'm'));
  return m ? m[1].trim() : '';
}

// "- **Name** explanation" bullets from Design Principles become principle cards.
function principles(md, n, title) {
  const body = extractSection(md, 'Design Principles');
  const items = [];
  for (const line of body.split('\n')) {
    const m = line.match(/^[-*]\s+\*\*(.+?)\*\*[\s:.—-]*(.*)$/);
    if (m) items.push({ vol: n, volTitle: title, name: m[1].replace(/[.:]$/, ''), body: m[2].trim() });
    else if (items.length && /^\s{2,}\S/.test(line)) items[items.length - 1].body += ' ' + line.trim();
  }
  return items.map((p) => ({ ...p, html: marked.parseInline(p.body) }));
}

// Author-supplied HTML volumes are the primary text: strip page chrome, give headings ids,
// mark DE-probe and war-story boxes, and turn the review checklist into tappable tasks.
function htmlVolume(src, n) {
  const { document } = parseHTML(src);
  const body = document.body;
  body.querySelector('h1')?.remove();
  const subs = [...body.querySelectorAll('p.sub')];
  const meta = subs[0]?.textContent.trim() || '';
  subs.forEach((s) => s.remove());
  for (const el of body.querySelectorAll('[style]')) if (!el.closest('svg')) el.removeAttribute('style');
  const seen = new Map();
  for (const h of body.querySelectorAll('h2, h3')) {
    let id = `v${n}-` + slug(h.textContent);
    const c = seen.get(id) || 0; seen.set(id, c + 1); if (c) id += '-' + c;
    h.setAttribute('id', id);
  }
  const probes = [];
  body.querySelectorAll('.de').forEach((box, i) => {
    box.setAttribute('class', 'callout de'); box.setAttribute('id', `v${n}-probe-${i + 1}`);
    const sec = box.previousElementSibling && [...body.querySelectorAll('h2')].filter((h) => h.compareDocumentPosition(box) & 4).pop();
    probes.push({ vol: n, id: `v${n}-probe-${i + 1}`, section: sec ? sec.textContent.replace(/^\d+\.\s*/, '') : '', html: box.innerHTML });
  });
  body.querySelectorAll('.warstory').forEach((b) => b.setAttribute('class', 'callout warstory'));
  body.querySelectorAll('table').forEach((t) => { const w = document.createElement('div'); w.setAttribute('class', 'table-wrap'); t.replaceWith(w); w.appendChild(t); });
  body.querySelectorAll('a[href]').forEach((a) => { a.setAttribute('target', '_blank'); a.setAttribute('rel', 'noopener'); });
  let checklist = [], keyIdeas = [];
  for (const h of body.querySelectorAll('h2')) {
    const t = h.textContent.toLowerCase(); const list = h.nextElementSibling;
    if (!list || !/^(OL|UL)$/.test(list.tagName)) continue;
    if (t.includes('checklist')) {
      list.setAttribute('class', 'tasks');
      for (const li of list.querySelectorAll(':scope > li')) {
        checklist.push(li.innerHTML);
        li.setAttribute('class', 'task');
        li.innerHTML = `<label><input type="checkbox" data-task><span>${li.innerHTML}</span></label>`;
      }
    }
    if (t.includes('summary')) keyIdeas = [...list.querySelectorAll(':scope > li')].map((li) => li.innerHTML);
  }
  const firstP = body.querySelector('h2 + p');
  const summary = firstP ? (firstP.textContent.match(/^.*?[.!?](\s|$)/) || [firstP.textContent])[0].trim() : '';
  return { html: body.innerHTML.trim(), meta, summary, probes, checklist, keyIdeas };
}

// Collections (algorithms, principles): "## Category" then "### Item" blocks with a "> one-liner".
function collection(md, prefix) {
  const cats = []; let cat = null, item = null;
  const flush = () => { if (item) { item.html = render(item.body.join('\n'), `${item.id}-`).replace(/<p><strong>([^<]+?)\.<\/strong>/g, '<p><strong>$1</strong>'); item.text = toText(item.html); delete item.body; } };
  for (const line of md.split('\n')) {
    let m;
    if ((m = line.match(/^## (.+)/))) { flush(); item = null; cat = { title: m[1].trim(), items: [] }; cats.push(cat); continue; }
    if ((m = line.match(/^### (.+)/)) && cat) { flush(); item = { id: prefix + slug(m[1]), name: m[1].trim(), summary: '', body: [] }; cat.items.push(item); continue; }
    if (!item) continue;
    if (!item.summary && (m = line.match(/^>\s*(.+)/))) { item.summary = m[1].trim(); continue; }
    item.body.push(line);
  }
  flush();
  return cats;
}
// Practice decks: "## Deck" with a "> one-liner", then "### Question" with the answer below it.
function practice(md) {
  const decks = []; let deck = null, card = null;
  const flush = () => { if (card) { card.md = card.body.join('\n').trim(); card.a = render(card.md, `${card.id}-`); delete card.body; } };
  for (const line of md.split('\n')) {
    let m;
    if ((m = line.match(/^## (.+)/))) { flush(); card = null; deck = { id: 'd-' + slug(m[1]), title: m[1].trim(), summary: '', cards: [] }; decks.push(deck); continue; }
    if ((m = line.match(/^### (.+)/)) && deck) { flush(); card = { id: 'q-' + slug(m[1]), q: m[1].trim(), body: [] }; deck.cards.push(card); continue; }
    if (deck && !card && !deck.summary && (m = line.match(/^>\s*(.+)/))) { deck.summary = m[1].trim(); continue; }
    if (card) card.body.push(line);
  }
  flush();
  return decks;
}
const readIf = (f) => (existsSync(root + 'content/' + f) ? readFileSync(root + 'content/' + f, 'utf8') : '');

const volumes = [];
const volPrinciples = [];
const probes = [];
const keyIdeas = [];
for (const part of catalog.parts) {
  for (const v of part.volumes) {
    const nn = String(v.n).padStart(2, '0');
    const vol = { ...v, part: part.id, partTitle: part.title, ready: false };
    const html = readIf(`vol-${nn}.html`), md = readIf(`vol-${nn}.md`), comp = readIf(`companion-${nn}.md`);
    if (html) {
      const h = htmlVolume(html, v.n);
      Object.assign(vol, { ready: true, html: h.html, meta: h.meta, summary: h.summary, checklistCount: h.checklist.length });
      probes.push(...h.probes.map((p) => ({ ...p, volTitle: v.title })));
      keyIdeas.push(...h.keyIdeas.map((html) => ({ vol: v.n, volTitle: v.title, html })));
    } else if (md) {
      Object.assign(vol, { ready: true, summary: (md.match(/^>\s*(.+)$/m) || [])[1] || '', html: render(md.replace(/^# .*\n/, '').replace(/^>\s*.+\n/m, ''), `v${v.n}-`) });
    }
    if (vol.ready) { vol.sections = sections(vol.html); vol.words = toText(vol.html).split(' ').length; }
    if (comp) {
      const body = comp.replace(/^# .*\n/, '').replace(/^>\s*.+\n/m, '');
      const chtml = render(body, `c${v.n}-`);
      vol.companion = { html: chtml, sections: sections(chtml), words: toText(chtml).split(' ').length, summary: (comp.match(/^>\s*(.+)$/m) || [])[1] || '' };
      if (!vol.ready) Object.assign(vol, { ready: true, html: chtml, sections: vol.companion.sections, words: vol.companion.words, summary: vol.companion.summary, companion: undefined });
      if (vol.meta && vol.companion.summary) vol.summary = vol.companion.summary;
      volPrinciples.push(...principles(body, v.n, v.title));
    }
    vol.principleCount = volPrinciples.filter((p) => p.vol === v.n).length;
    volumes.push(vol);
  }
}

const algoMd = ['algorithms-a.md', 'algorithms-b.md', 'algorithms-c.md'].map(readIf).join('\n');
const algorithms = collection(algoMd, 'a-');
const principleCatalog = collection(readIf('principles.md'), 'p-');
const practiceDecks = practice(readIf('practice.md'));

const library = {
  title: catalog.title, subtitle: catalog.subtitle, howTo: catalog.howTo,
  parts: catalog.parts.map((p) => ({ id: p.id, title: p.title, volumes: p.volumes.map((v) => v.n) })),
  volumes, principles: volPrinciples, principleCatalog, algorithms, practice: practiceDecks, probes, keyIdeas, builtAt: new Date().toISOString(),
};
const json = JSON.stringify(library);
writeFileSync(root + 'app/data/library.json', json);

const hash = createHash('sha1').update(json).update(
  ['index.html', 'app.css', 'app.js'].map((f) => readFileSync(root + 'app/' + f, 'utf8')).join('')
).digest('hex').slice(0, 10);
const sw = readFileSync(root + 'app/sw.js', 'utf8').replace(/const VERSION = '[^']*';/, `const VERSION = '${hash}';`);
writeFileSync(root + 'app/sw.js', sw);

const count = (cats) => cats.reduce((a, c) => a + c.items.length, 0);
console.log(`library.json: ${volumes.filter((v) => v.ready).length} ready volumes, ${volPrinciples.length} volume principles, ${count(principleCatalog)} catalog principles, ${count(algorithms)} algorithms, ${practiceDecks.reduce((a, d) => a + d.cards.length, 0)} practice cards, ${probes.length} probe boxes, ${keyIdeas.length} key ideas, ${(json.length / 1024).toFixed(0)} KB; sw ${hash}`);
