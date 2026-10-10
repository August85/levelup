# Turns the ByteByteGo course screenshots (long page captures saved as PDFs) into reflowed chapters:
# OCR'd headings, paragraphs and bullets, with diagrams and tables cropped as images.
# Runs on your Mac; output stays private (never committed). usage: python3 interview_prep.py RAW_DIR OUT_DIR [slug ...]
import sys, os, glob, json, re, subprocess, tempfile, statistics, html
from multiprocessing import Pool
from PIL import Image
import numpy as np

Image.MAX_IMAGE_PIXELS = None
X0, X1 = 1180, 2920          # content column (full-res pixels), clear of the sidebar
HEADER = 230                 # site header on the first page
INK = 200
BULLET = re.compile(r'^(?:[•·«©®¢\*\-–]+|e)\s+')


def stitch(d):
    pages = [Image.open(p).convert('RGB') for p in sorted(glob.glob(os.path.join(d, '*.jpg')))]
    crops = []
    for i, im in enumerate(pages):
        top = HEADER if i == 0 else 0
        crops.append(im.crop((X0, top, min(X1, im.width), im.height)))
    W = crops[0].width
    H = sum(c.height for c in crops)
    out = Image.new('RGB', (W, H), 'white')
    y = 0
    for c in crops:
        out.paste(c, (0, y)); y += c.height
    return out


def ocr(img, y0):
    """Word boxes for one chunk, shifted by y0."""
    with tempfile.NamedTemporaryFile(suffix='.png', delete=False) as f:
        img.save(f.name)
        name = f.name
    try:
        tsv = subprocess.run(['tesseract', name, 'stdout', '--psm', '3', 'tsv'],
                             capture_output=True, text=True).stdout
    finally:
        os.unlink(name)
    words = []
    for row in tsv.splitlines()[1:]:
        c = row.split('\t')
        if len(c) < 12 or c[0] != '5' or not c[11].strip():
            continue
        conf = float(c[10])
        if conf < 0:
            continue
        words.append(dict(key=(y0, int(c[2]), int(c[3]), int(c[4])), x=int(c[6]), y=int(c[7]) + y0,
                          w=int(c[8]), h=int(c[9]), conf=conf, t=c[11]))
    return words


def lines_from(words):
    by = {}
    for w in words:
        by.setdefault(w['key'], []).append(w)
    lines = []
    for ws in by.values():
        ws.sort(key=lambda w: w['x'])
        x = min(w['x'] for w in ws); y = min(w['y'] for w in ws)
        r = max(w['x'] + w['w'] for w in ws); b = max(w['y'] + w['h'] for w in ws)
        lines.append(dict(x=x, y=y, r=r, b=b, h=b - y,
                          conf=sum(w['conf'] for w in ws) / len(ws),
                          t=' '.join(w['t'] for w in ws)))
    lines.sort(key=lambda l: (l['y'], l['x']))
    return lines


def process(args):
    raw, out, slug = args
    img = stitch(os.path.join(raw, slug))
    W, H = img.size
    gray = np.asarray(img.convert('L'))
    ink_rows = (gray < INK).any(axis=1)

    # OCR in chunks cut at blank rows
    words, y = [], 0
    while y < H:
        end = min(H, y + 5000)
        if end < H:
            cut = end
            while cut > y + 2000 and ink_rows[cut]:
                cut -= 1
            end = cut if cut > y + 2000 else end
        words += ocr(img.crop((0, y, W, end)), y)
        y = end
    lines = lines_from(words)
    if not lines:
        return slug, None

    # left text edge = most common left x among confident lines
    lefts = [round(l['x'] / 8) * 8 for l in lines if l['conf'] > 80 and len(l['t']) > 40]
    L = max(set(lefts), key=lefts.count) if lefts else min(l['x'] for l in lines)
    colw = W - 2 * L if W - 2 * L > 600 else W - L
    body = statistics.median([l['h'] for l in lines if l['conf'] > 80 and abs(l['x'] - L) < 12 and len(l['t']) > 40] or [30])

    def leftish(l): return L - 12 <= l['x'] <= L + 140
    for l in lines:
        wide = (l['r'] - l['x']) >= 0.35 * colw
        l['bullet'] = bool(BULLET.match(l['t'])) and l['x'] > L + 10
        l['head'] = l['h'] >= 1.25 * body and l['conf'] >= 70 and abs(l['x'] - L) < 14
        bodyish = 0.75 * body <= l['h'] <= 1.2 * body and abs(l['x'] - L) < 14 and l['conf'] >= 82
        l['text'] = leftish(l) and l['conf'] >= 72 and (wide or l['head'] or l['bullet'] or bodyish)
        if re.match(r'^(Figure|Table)\s*\d+', l['t']):
            l['text'] = False; l['head'] = False
    # short last lines of paragraphs: accept when they hug an accepted line
    for _ in range(2):
        for i, l in enumerate(lines):
            if l['text'] or not leftish(l) or l['conf'] < 72:
                continue
            prev = lines[i - 1] if i else None
            if prev and prev['text'] and l['y'] - prev['b'] < 1.2 * body:
                l['text'] = True

    text = [l for l in lines if l['text']]
    # chapter number and title
    n = None
    big = [l for l in text[:4] if l['h'] >= 1.9 * body]
    for l in big:
        m = re.match(r'^0?(\d{1,2})$', l['t'].strip())
        if m:
            n = int(m.group(1)); l['text'] = False
    text = [l for l in text if l['text']]
    title_lines = [l for l in text[:4] if l['h'] >= 1.6 * body]
    title = ' '.join(l['t'] for l in title_lines) or slug.replace('-', ' ').title()
    for l in title_lines:
        l['text'] = False
    text = [l for l in text if l['text']]

    # blocks: text lines plus figures found in the gaps between them
    figdir = os.path.join(out, 'fig'); os.makedirs(figdir, exist_ok=True)
    start = (title_lines[-1]['b'] if title_lines else 0) + 4
    blocks, figs = [], 0
    bounds = [l for l in text] + [None]
    cursor = start
    for l in bounds:
        top = l['y'] - 6 if l else H
        if top - cursor > 2.2 * body:
            seg = gray[cursor:top]
            rows = np.where((seg < INK).sum(axis=1) > 2)[0]
            if len(rows) and rows[-1] - rows[0] > 1.5 * body and (seg < INK).sum() > 1500:
                y0, y1 = cursor + rows[0], cursor + rows[-1]
                cols = np.where((gray[y0:y1 + 1] < INK).sum(axis=0) > 1)[0]
                x0, x1 = max(0, cols[0] - 16), min(W, cols[-1] + 16)
                crop = img.crop((x0, max(0, y0 - 14), x1, min(H, y1 + 14)))
                if crop.width > 1170:
                    crop = crop.resize((1170, round(crop.height * 1170 / crop.width)), Image.LANCZOS)
                figs += 1
                name = f'{slug}-{figs:02d}.jpg'
                crop.save(os.path.join(figdir, name), quality=74, optimize=True)
                cap = ' '.join(x['t'] for x in lines if not x['text'] and y0 - 10 <= x['y'] <= y1 + 10
                               and re.match(r'^(Figure|Table)\s*\d+', x['t']))
                blocks.append(('fig', name, cap))
        if l:
            blocks.append(('line', l))
            cursor = l['b'] + 4

    # reflow lines into headings, paragraphs and lists
    tl = [b[1] for b in blocks if b[0] == 'line']
    gaps = [b['y'] - a['b'] for a, b in zip(tl, tl[1:]) if 0 <= b['y'] - a['b'] < body]
    lgap = statistics.median(gaps) if gaps else body * 0.4
    parts, plain, para, items = [], [], [], []
    last = None

    def flush_para():
        if para:
            t = ' '.join(para); parts.append(f'<p>{html.escape(t)}</p>'); plain.append(t); para.clear()

    def flush_list():
        if items:
            parts.append('<ul>' + ''.join(f'<li>{html.escape(i)}</li>' for i in items) + '</ul>')
            plain.extend(items); items.clear()

    for b in blocks:
        if b[0] == 'fig':
            flush_para(); flush_list()
            cap = f'<figcaption>{html.escape(b[2])}</figcaption>' if b[2] else ''
            parts.append(f'<figure class="shot"><img src="fig/{b[1]}" loading="lazy" alt="{html.escape(b[2] or "Diagram")}">{cap}</figure>')
            last = None
            continue
        l = b[1]
        t = l['t'].strip()
        gap = (l['y'] - last['b']) if last else 999
        if l['head']:
            flush_para(); flush_list()
            if last is not None and last['head'] and gap < 0.6 * l['h'] and parts and parts[-1].startswith('<h'):
                tag = parts[-1][:4]
                parts[-1] = parts[-1][:-5] + ' ' + html.escape(t) + parts[-1][-5:]
                plain[-1] += ' ' + t
            else:
                tag = 'h2' if l['h'] >= 1.45 * body else 'h3'
                parts.append(f'<{tag}>{html.escape(t)}</{tag}>'); plain.append(t)
        elif l['bullet']:
            flush_para()
            items.append(BULLET.sub('', t))
        elif items and l['x'] > L + 20 and gap < 1.6 * lgap + 4:
            items[-1] += ' ' + t
        else:
            flush_list()
            if para and gap > 1.6 * lgap + 4:
                flush_para()
            para.append(t)
        last = l
    flush_para(); flush_list()
    text_all = '\n'.join(plain)
    body_html = '\n'.join(parts)
    # tidy hyphenation at line joins and doubled spaces
    body_html = re.sub(r'(\w)- (\w)', r'\1-\2', body_html)
    return slug, dict(slug=slug, n=n, title=title, html=body_html, text=text_all, figures=figs,
                      words=len(text_all.split()))


if __name__ == '__main__':
    raw, out = sys.argv[1], sys.argv[2]
    slugs = sys.argv[3:] or sorted(os.listdir(raw))
    os.makedirs(out, exist_ok=True)
    with Pool(max(1, (os.cpu_count() or 2) - 1)) as pool:
        for slug, ch in pool.imap_unordered(process, [(raw, out, s) for s in slugs]):
            if ch:
                with open(os.path.join(out, f'{slug}.json'), 'w') as f:
                    json.dump(ch, f)
                print(slug, ch['n'], ch['title'], ch['figures'], 'figs', ch['words'], 'words', flush=True)
            else:
                print(slug, 'NO TEXT', flush=True)
