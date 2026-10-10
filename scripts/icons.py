# Draws the app icon: three rising bars and an arrow on deep blue.
from PIL import Image, ImageDraw
import sys
out = sys.argv[1]
S = 1024
img = Image.new('RGB', (S, S), (10, 77, 140))
d = ImageDraw.Draw(img)
for i in range(S):  # subtle vertical gradient
    t = i / S
    d.line([(0, i), (S, i)], fill=(int(14 - 6 * t), int(90 - 30 * t), int(160 - 40 * t)))
white = (251, 250, 247)
base, w, gap = 760, 150, 60
x0 = (S - (3 * w + 2 * gap)) // 2
for k, h in enumerate([200, 330, 460]):
    x = x0 + k * (w + gap)
    d.rounded_rectangle([x, base - h, x + w, base], radius=28, fill=white)
d.line([(x0 - 10, 520), (x0 + 3 * w + 2 * gap - 40, 210)], fill=(255, 196, 77), width=46)
tip = (x0 + 3 * w + 2 * gap + 10, 175)
d.polygon([tip, (tip[0] - 150, tip[1] + 20), (tip[0] - 40, tip[1] + 140)], fill=(255, 196, 77))
for size, name in [(512, 'icon-512.png'), (192, 'icon-192.png'), (180, 'apple-touch-icon.png')]:
    img.resize((size, size), Image.LANCZOS).save(f'{out}/{name}')
