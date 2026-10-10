# Packs the OCR'd chapters and the PDF books into LevelUP-private/ for the iOS build (see ios/README.md).
# usage (from the folder holding the chapters): python3 interview_pack.py OUT_DIR ../LevelUP-private
import json, os, re, shutil, html as H, sys
SRC, DST = sys.argv[1], sys.argv[2]
ORDER = [
    ('Foundations', [
        (2, 'scale-from-zero-to-millions-of-users', 'Scale From Zero To Millions Of Users'),
        (3, 'back-of-the-envelope-estimation', 'Back-of-the-envelope Estimation'),
        (4, 'a-framework-for-system-design-interviews', 'A Framework For System Design Interviews')]),
    ('Classic designs', [
        (5, 'design-a-rate-limiter', 'Design A Rate Limiter'),
        (6, 'design-consistent-hashing', 'Design Consistent Hashing'),
        (7, 'design-a-key-value-store', 'Design A Key-value Store'),
        (8, 'design-a-unique-id-generator-in-distributed-systems', 'Design A Unique ID Generator In Distributed Systems'),
        (9, 'design-a-url-shortener', 'Design A URL Shortener'),
        (10, 'design-a-web-crawler', 'Design A Web Crawler'),
        (11, 'design-a-notification-system', 'Design A Notification System'),
        (12, 'design-a-news-feed-system', 'Design A News Feed System'),
        (13, 'design-a-chat-system', 'Design A Chat System'),
        (14, 'design-a-search-autocomplete-system', 'Design A Search Autocomplete System'),
        (15, 'design-youtube', 'Design YouTube'),
        (16, 'design-google-drive', 'Design Google Drive')]),
    ('Advanced designs', [
        (17, 'proximity-service', 'Proximity Service'),
        (18, 'nearby-friends', 'Nearby Friends'),
        (19, 'google-maps', 'Google Maps'),
        (20, 'distributed-message-queue', 'Distributed Message Queue'),
        (21, 'metrics-monitoring-and-alerting-system', 'Metrics Monitoring And Alerting System'),
        (22, 'ad-click-event-aggregation', 'Ad Click Event Aggregation'),
        (23, 'hotel-reservation-system', 'Hotel Reservation System'),
        (24, 'distributed-email-service', 'Distributed Email Service'),
        (25, 's3-like-object-storage', 'S3-like Object Storage'),
        (26, 'real-time-gaming-leaderboard', 'Real-time Gaming Leaderboard'),
        (27, 'payment-system', 'Payment System'),
        (28, 'digital-wallet', 'Digital Wallet'),
        (29, 'stock-exchange', 'Stock Exchange'),
        (30, 'the-learning-continues', 'The Learning Continues')]),
]
BOOKS = [
    ('../ML Pdfs/Reinforcement Learning Sutton.pdf', 'sutton-barto-reinforcement-learning.pdf',
     'Reinforcement Learning: An Introduction', 'Richard S. Sutton and Andrew G. Barto', 548),
    ('../Other Books/Refactoring-Improving-the-Design-of-Existing-Code-Addison-Wesley-Professional-1999.pdf',
     'fowler-refactoring-1999.pdf', 'Refactoring: Improving the Design of Existing Code', 'Martin Fowler (1999)', 337),
]

def slugify(s): return re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')[:50]
def text(h): return re.sub(r'\s+', ' ', H.unescape(re.sub(r'<[^>]+>', ' ', h))).strip()

os.makedirs(f'{DST}/interview/fig', exist_ok=True)
os.makedirs(f'{DST}/books', exist_ok=True)
groups, figs = [], 0
for gtitle, items in ORDER:
    chapters = []
    for n, slug, title in items:
        ch = json.load(open(f'{SRC}/{slug}.json'))
        body = ch['html']
        # OCR sometimes folds the first heading into the title; give it back.
        ocr = re.sub(r'^[0Oo]?\d{1,2}\s+', '', ch['title']).strip()
        if ocr.lower().startswith(title.lower()) and len(ocr) > len(title) + 3:
            body = f'<h2>{H.escape(ocr[len(title):].strip(" -:"))}</h2>\n' + body
        # demote OCR lines that only looked like headings (sentence fragments)
        def demote(m):
            t = text(m.group(2))
            if t[:1].islower() or t[-1:] in ',=;' or len(t) > 95 or len(t.split()) > 14:
                return '<p>' + m.group(2) + (' ' if m.group(3) else '</p>\n')
            return m.group(0)
        body = re.sub(r'<h([23])>(.*?)</h\1>\n(<p>)?', demote, body)
        # heading ids + sections for the contents menu and search
        seen, sections = {}, []
        def hid(m):
            lvl, inner = m.group(1), m.group(2)
            base = f'b{n}-' + slugify(text(inner)); c = seen.get(base, 0); seen[base] = c + 1
            i = base + (f'-{c}' if c else '')
            sections.append({'level': int(lvl), 'id': i, 'title': text(inner), 'start': m.end()})
            return f'<h{lvl} id="{i}">{inner}</h{lvl}>'
        body = re.sub(r'<h([23])>(.*?)</h\1>', hid, body)
        # section text = plain text until the next heading
        heads = [m for m in re.finditer(r'<h[23] id="[^"]+">', body)]
        out_sections = []
        intro_end = heads[0].start() if heads else len(body)
        intro = text(body[:intro_end])
        if intro:
            out_sections.append({'level': 2, 'id': f'b{n}-top', 'title': 'Introduction', 'text': intro})
            body = f'<span id="b{n}-top"></span>' + body
        heads = [m for m in re.finditer(r'<h([23]) id="([^"]+)">(.*?)</h\1>', body)]
        for i, m in enumerate(heads):
            end = heads[i + 1].start() if i + 1 < len(heads) else len(body)
            out_sections.append({'level': int(m.group(1)), 'id': m.group(2), 'title': text(m.group(3)),
                                 'text': text(body[m.end():end])})
        for f in re.findall(r'src="fig/([^"]+)"', body):
            shutil.copyfile(f'{SRC}/fig/{f}', f'{DST}/interview/fig/{f}'); figs += 1
        chapters.append({'slug': slug, 'n': n, 'title': title, 'html': body, 'sections': out_sections,
                         'words': ch['words'], 'figures': ch['figures']})
    groups.append({'title': gtitle, 'chapters': chapters})
books = []
for src, name, title, author, pages in BOOKS:
    if os.path.exists(src):
        shutil.copyfile(src, f'{DST}/books/{name}')
        books.append({'file': name, 'title': title, 'author': author, 'pages': pages})
json.dump({'title': 'System Design Interview', 'source': 'ByteByteGo', 'groups': groups, 'books': books},
          open(f'{DST}/interview/index.json', 'w'))
print(sum(len(g['chapters']) for g in groups), 'chapters', figs, 'figures', len(books), 'books')
