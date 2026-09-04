#!/usr/bin/env python3
"""Draw the static ground of docs/social-preview.gif: the brand cream with the
56 px rule grid and the orange glow of tokenclimate.com, the name in Clash Display,
the tagline in Owners. Writes the PNG given as argv[1]. Needs Pillow; falls back
to Arial when the brand fonts are not installed."""
import os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1280, 640
CREAM, INK, STONE, RULE, ORANGE = "#faf8f5", "#1d1d1f", "#7a6e63", "#e5e2d9", (245, 92, 15)
FONTS = os.path.expanduser("~/Library/Fonts")

def font(candidates, size):
    for c in candidates:
        p = c if os.path.isabs(c) else os.path.join(FONTS, c)
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", size)

img = Image.new("RGB", (W, H), CREAM)
d = ImageDraw.Draw(img)

# Rule grid, 56 px, offset -1 px like the site.
for x in range(-1, W, 56):
    d.line([(x, 0), (x, H)], fill=RULE, width=1)
for y in range(-1, H, 56):
    d.line([(0, y), (W, y)], fill=RULE, width=1)

# Orange glow, top right: radial from 8% alpha to 0, blurred.
glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
g = ImageDraw.Draw(glow)
cx, cy, r = 1130, 60, 450
for i in range(r, 0, -6):
    a = int(0x14 * (1 - i / r))
    g.ellipse([cx - i, cy - i, cx + i, cy + i], fill=ORANGE + (a,))
glow = glow.filter(ImageFilter.GaussianBlur(40))
img = Image.alpha_composite(img.convert("RGBA"), glow).convert("RGB")
d = ImageDraw.Draw(img)

title = font(["ClashDisplay-Semibold.otf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf"], 96)
body = font(["Owners-Regular.otf", "Owners-Medium.otf"], 34)

def centered(text, f, y, fill):
    w = d.textlength(text, font=f)
    d.text(((W - w) / 2, y), text, font=f, fill=fill)

centered("claude-carbon", title, 138, INK)
centered("Track the carbon footprint of your Claude Code sessions", body, 258, STONE)

img.save(sys.argv[1], "PNG")
