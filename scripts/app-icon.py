#!/usr/bin/env python3
"""Generate the app icon (Resources/AppIcon.icns) and the editor extension icon (vscode-extension/icon.png).

The turnip-in-a-pot pixel art mirrors brand-assets.py (and TurnipRig). Needs Pillow and macOS iconutil.
Both outputs are committed; rerun this only when the artwork changes:  python3 scripts/app-icon.py
"""
import os, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SS = 4  # supersampling factor

LEAVES = [".g..g..g..", ".gg.g.gg..", "..ggggg...", "....G....."]
BULB = ["...pppp...", "..pppppp..", ".wwwwwwww.", ".wwwwwwww.", ".wwwwwwww.",
        "..wwwwww..", "...wwww...", "....ww....", ".....w...."]
POT = ["llllllllllllll", ".oooooooooooo.", ".oooooooooooo.", "..oooooooooo..", "..dddddddddd.."]
HEX = {"g": "#4ade80", "G": "#22a35a", "p": "#a855f7", "w": "#f4efe9",
       "l": "#f0a07f", "o": "#d97757", "d": "#a85a3e"}
TX = 2


def rgba(h, a=1.0):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), round(a * 255))


def turnip(img, x0, y0, p):
    """Same cells as brand-assets.turnip(); (x0, y0) = top-left of pot column 0 / turnip row 0."""
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    def r(x, y, w, h, fill, op=1.0):
        box = [x0 + x * p, y0 + y * p, x0 + (x + w) * p - 1, y0 + (y + h) * p - 1]
        if op < 1.0:
            over = Image.new("RGBA", img.size, (0, 0, 0, 0))
            ImageDraw.Draw(over).rectangle(box, fill=rgba(fill, op))
            layer.alpha_composite(over)
        else:
            d.rectangle(box, fill=rgba(fill))

    for y, row in enumerate(LEAVES + BULB):
        if y >= 11:  # hidden below the rim
            break
        for x, ch in enumerate(row):
            if ch != ".":
                r(x + TX, y, 1, 1, HEX[ch])
    for ex, ey in [(3, 7), (6, 7)]:  # ^ ^
        x = ex + TX
        r(x - 0.2, ey + 0.2, 0.5, 0.4, "#141414"); r(x + 0.25, ey - 0.15, 0.5, 0.4, "#141414"); r(x + 0.7, ey + 0.2, 0.5, 0.4, "#141414")
    for bx, by in [(2, 8), (7, 8)]:
        r(bx + TX, by, 1, 0.6, "#f9a8b4", 0.85)
    r(4 + TX, 9, 2, 0.5, "#141414")
    r(4.5 + TX, 9.5, 1, 0.5, "#e0607a")
    for y, row in enumerate(POT):
        for x, ch in enumerate(row):
            if ch != ".":
                r(x, y + 9, 1, 1, HEX[ch])
    for sx, sy, s in [(-1, -1, 0.8), (11.5, 1, 0.8), (0, 6, 0.6)]:
        r(sx, sy, s, s, "#fde68a")
    img.alpha_composite(layer)


def tile_icon(size, inset, radius, shadow):
    """A dark rounded tile with the turnip centred on it. inset/radius as fractions of size."""
    S = size * SS
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    x0, x1 = round(S * inset), round(S * (1 - inset))
    w = x1 - x0
    rad = round(S * radius)
    if shadow:
        sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle([x0, x0 + S * 0.012, x1, x1 + S * 0.012], rad, fill=(0, 0, 0, 110))
        img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(S * 0.014)))
    # Tile: a soft top-to-bottom gradient on the mark's #141414, with a faint top highlight edge.
    grad = Image.new("RGBA", (1, w))
    top, bottom = rgba("#2e2b33"), rgba("#141414")
    for i in range(w):
        t = i / max(1, w - 1)
        grad.putpixel((0, i), tuple(round(top[k] + (bottom[k] - top[k]) * t) for k in range(4)))
    grad = grad.resize((w, w))
    mask = Image.new("L", (w, w), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, w - 1], rad, fill=255)
    img.paste(grad, (x0, x0), mask)
    edge = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle([x0, x0, x1 - 1, x1 - 1], rad, outline=(255, 255, 255, 28), width=max(1, round(S * 0.003)))
    img.alpha_composite(edge)
    # Art spans columns -1..14 and rows -1..14 (15 x 15 cells), on an 18.5-cell grid like mark().
    p = w / 18.5
    ax = x0 + (w - 15 * p) / 2 + p
    turnip(img, ax, ax, p)
    return img.resize((size, size), Image.LANCZOS)


def main():
    # macOS app icon: Apple's grid puts the 824-pt body inside a 1024 canvas, with a drop shadow.
    master = tile_icon(1024, inset=100 / 1024, radius=185 / 1024, shadow=True)
    out_dir = os.path.join(ROOT, "Resources")
    os.makedirs(out_dir, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for pt in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = pt * scale
                name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
                master.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
        icns = os.path.join(out_dir, "AppIcon.icns")
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    master.save(os.path.join(ROOT, "docs", "brand", "app-icon-1024.png"))

    # Editor extension icon (VS Code wants a square PNG, at least 128 px): the full-bleed mark.
    tile_icon(256, inset=0, radius=0.22, shadow=False).save(os.path.join(ROOT, "vscode-extension", "icon.png"))
    print("ok")


if __name__ == "__main__":
    sys.exit(main())
