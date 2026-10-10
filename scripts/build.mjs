// Builds app/data/library.json from content/catalog.json + content/vol-NN.md,
// and stamps a fresh cache version into app/sw.js so phones pick up new content.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { marked } from 'marked';

const root = new URL('..', import.meta.url).pathname;
const catalog = JSON.parse(readFileSync(root + 'content/catalog.json', 'utf8'));

const slug = (s) => s.toLowerCase().replace(/<[^>]+>/g, '').replace(/&[a-z]+;/g, '')
  .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 60);
const toText = (html) => html.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<')
  .replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/\s+/g, ' ').trim();

// Headings get stable ids so the reader can deep-link and the search can jump to them.
function render(md, n) {
  const seen = new Map();
  const renderer = new marked.Renderer();
  renderer.heading = (text, level) => {
    let id = `v${n}-` + slug(text);
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

const volumes = [];
const allPrinciples = [];
for (const part of catalog.parts) {
  for (const v of part.volumes) {
    const file = `${root}content/vol-${String(v.n).padStart(2, '0')}.md`;
    const vol = { ...v, part: part.id, partTitle: part.title, ready: false };
    if (existsSync(file)) {
      let md = readFileSync(file, 'utf8');
      const summary = (md.match(/^>\s*(.+)$/m) || [])[1] || '';
      md = md.replace(/^# .*\n/, '').replace(/^>\s*.+\n/m, '');
      vol.ready = true;
      vol.summary = summary;
      vol.html = render(md, v.n);
      vol.sections = sections(vol.html);
      vol.words = toText(vol.html).split(' ').length;
      const ps = principles(md, v.n, v.title);
      vol.principleCount = ps.length;
      allPrinciples.push(...ps);
    }
    volumes.push(vol);
  }
}

const library = {
  title: catalog.title, subtitle: catalog.subtitle, howTo: catalog.howTo,
  parts: catalog.parts.map((p) => ({ id: p.id, title: p.title, volumes: p.volumes.map((v) => v.n) })),
  volumes, principles: allPrinciples, builtAt: new Date().toISOString(),
};
const json = JSON.stringify(library);
writeFileSync(root + 'app/data/library.json', json);

const hash = createHash('sha1').update(json).update(
  ['index.html', 'app.css', 'app.js'].map((f) => readFileSync(root + 'app/' + f, 'utf8')).join('')
).digest('hex').slice(0, 10);
const sw = readFileSync(root + 'app/sw.js', 'utf8').replace(/const VERSION = '[^']*';/, `const VERSION = '${hash}';`);
writeFileSync(root + 'app/sw.js', sw);

console.log(`library.json: ${volumes.filter((v) => v.ready).length} ready volumes, ${allPrinciples.length} principles, ${(json.length / 1024).toFixed(0)} KB; sw ${hash}`);
