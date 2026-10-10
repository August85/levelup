// Shared helpers: readable-article extraction and an allowlist HTML sanitizer.
import { parseHTML } from 'linkedom';
import { Readability } from '@mozilla/readability';

const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
const MAX = 200_000;

const ALLOWED = new Set(['p', 'br', 'hr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'blockquote', 'pre', 'code',
  'em', 'strong', 'b', 'i', 'u', 's', 'sub', 'sup', 'a', 'img', 'figure', 'figcaption', 'table', 'thead', 'tbody', 'tr',
  'th', 'td', 'dl', 'dt', 'dd', 'span', 'div', 'section', 'article', 'mark', 'small', 'kbd', 'picture']);
const DROP = new Set(['script', 'style', 'iframe', 'object', 'embed', 'form', 'input', 'button', 'noscript', 'svg', 'canvas', 'video', 'audio', 'source', 'link', 'meta']);
const ATTRS = { a: ['href', 'title'], img: ['src', 'alt', 'title'], td: ['colspan', 'rowspan'], th: ['colspan', 'rowspan'] };

export function clean(html, base) {
  if (!html) return '';
  const { document } = parseHTML(`<!doctype html><html><body><div id="r">${html}</div></body></html>`);
  const rootEl = document.getElementById('r');
  const abs = (u) => { try { return new URL(u, base).href; } catch { return ''; } };
  const walk = (el) => {
    for (const child of [...el.children]) {
      const tag = child.tagName.toLowerCase();
      if (DROP.has(tag)) { child.remove(); continue; }
      walk(child);
      if (!ALLOWED.has(tag)) { child.replaceWith(...child.childNodes); continue; }
      const keep = ATTRS[tag] || [];
      for (const a of [...child.attributes]) if (!keep.includes(a.name)) child.removeAttribute(a.name);
      if (tag === 'a') {
        const href = abs(child.getAttribute('href') || '');
        if (/^https?:/.test(href)) { child.setAttribute('href', href); child.setAttribute('target', '_blank'); child.setAttribute('rel', 'noopener'); }
        else child.removeAttribute('href');
      }
      if (tag === 'img') {
        const src = abs(child.getAttribute('src') || '');
        if (/^https:/.test(src)) { child.setAttribute('src', src); child.setAttribute('loading', 'lazy'); } else child.remove();
      }
    }
  };
  walk(rootEl);
  return rootEl.innerHTML.slice(0, MAX);
}

export async function extract(url, ms = 15000) {
  try {
    const res = await fetch(url, { headers: { 'user-agent': UA, accept: 'text/html,*/*' }, signal: AbortSignal.timeout(ms), redirect: 'follow' });
    if (!res.ok || !/html/.test(res.headers.get('content-type') || '')) return null;
    const html = await res.text();
    const { document } = parseHTML(html);
    const art = new Readability(document).parse();
    if (!art || !art.content) return null;
    return {
      title: (art.title || '').trim(), byline: art.byline || '', siteName: art.siteName || '',
      excerpt: (art.excerpt || '').trim().slice(0, 280), content: clean(art.content, res.url || url),
    };
  } catch (e) {
    console.log(`  extract fail ${url}: ${e.message}`);
    return null;
  }
}

export async function mapLimit(list, n, fn) {
  const out = new Array(list.length); let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, list.length) }, async () => {
    while (i < list.length) { const k = i++; out[k] = await fn(list[k], k); }
  }));
  return out;
}
