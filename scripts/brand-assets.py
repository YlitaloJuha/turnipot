#!/usr/bin/env python3
"""Generate docs/brand SVGs for Turnipot (banner light/dark, mark). Pixel art mirrors TurnipRig.
The banner is drawn, not rendered from the app: demo data only, and no Apple logo in the menu bar."""
import sys, os

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

LEAVES = [".g..g..g..", ".gg.g.gg..", "..ggggg...", "....G....."]
BULB = ["...pppp...", "..pppppp..", ".wwwwwwww.", ".wwwwwwww.", ".wwwwwwww.",
        "..wwwwww..", "...wwww...", "....ww....", ".....w...."]
POT = ["llllllllllllll", ".oooooooooooo.", ".oooooooooooo.", "..oooooooooo..", "..dddddddddd.."]
HEX = {"g": "#4ade80", "G": "#22a35a", "p": "#a855f7", "w": "#f4efe9",
       "l": "#f0a07f", "o": "#d97757", "d": "#a85a3e"}
TX = 2  # turnip column inside the pot


def turnip(x0, y0, p, sparkles=True):
    """Happy turnip in its pot. (x0, y0) = top-left of pot column 0 / turnip row 0. Rim at row 9."""
    # One path per colour (not one rect per cell), so rasterizers leave no seams between cells.
    groups = {}
    def r(x, y, w, h, fill, op=None):
        X, Y, W, H = x0 + x * p, y0 + y * p, w * p, h * p
        groups.setdefault((fill, op), []).append(f"M{X:.2f} {Y:.2f}h{W:.2f}v{H:.2f}h{-W:.2f}z")
    rows = LEAVES + BULB
    for y, row in enumerate(rows):
        if y >= 11:  # hidden below the rim (clip row = rim + 2)
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
    if sparkles:
        for sx, sy, s in [(-1, -1, 0.8), (11.5, 1, 0.8), (0, 6, 0.6)]:
            r(sx, sy, s, s, "#fde68a")
    return "".join(f'<path d="{"".join(d)}" fill="{fill}"' + (f' opacity="{op}"' if op else "") + "/>"
                   for (fill, op), d in groups.items())


SANS = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', 'Helvetica Neue', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace"


def text(x, y, s, size, fill, weight=400, anchor="start", family=SANS, ls=None, op=None):
    a = f' text-anchor="{anchor}"' if anchor != "start" else ""
    l = f' letter-spacing="{ls}"' if ls is not None else ""
    o = f' opacity="{op}"' if op else ""
    s = s.replace("&", "&amp;").replace("<", "&lt;")
    return f'<text x="{x}" y="{y}" font-family="{family}" font-size="{size}" font-weight="{weight}" fill="{fill}"{a}{l}{o}>{s}</text>'


def mark(size=80, tile="#141414", rx=None):
    rx = size * 0.22 if rx is None else rx
    p = size / 18.5
    # art spans columns -1..14 and rows -1..14 (15 x 15 cells)
    x0 = (size - 15 * p) / 2 + p
    y0 = (size - 15 * p) / 2 + p
    return f'<rect width="{size}" height="{size}" rx="{rx:.1f}" fill="{tile}"/>' + turnip(x0, y0, p)


def defs(dark):
    return ('<defs>'
            '<linearGradient id="wall" x1="0" y1="0" x2="1" y2="1">'
            '<stop offset="0" stop-color="#3b2a5c"/><stop offset="0.55" stop-color="#2a3354"/><stop offset="1" stop-color="#1d4a57"/></linearGradient>'
            '<linearGradient id="lid" x1="0" y1="0" x2="0" y2="1">'
            '<stop offset="0" stop-color="#5a5c62"/><stop offset="0.04" stop-color="#2b2c30"/><stop offset="1" stop-color="#1b1c1f"/></linearGradient>'
            '<filter id="shadow" x="-10%" y="-10%" width="120%" height="140%"><feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="12" result="b"/>'
            f'<feFlood flood-color="rgba(0,0,0,{0.6 if dark else 0.3})"/><feComposite in2="b" operator="in"/><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>'
            '<filter id="soft" x="-10%" y="-10%" width="120%" height="140%"><feGaussianBlur in="SourceAlpha" stdDeviation="8"/><feOffset dy="6" result="b"/>'
            '<feFlood flood-color="rgba(0,0,0,0.5)"/><feComposite in2="b" operator="in"/><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>'
            '</defs>')


def laptop(cx, top, sw, sh, W):
    """MacBook lid top: bezel + screen (wallpaper) + menu bar + notch. Screen centred on cx, width sw."""
    s = []
    bez, rx_out, rx_in = 18, 46, 30
    x0 = cx - sw / 2 - bez
    s.append(f'<g filter="url(#shadow)"><rect x="{x0}" y="{top}" width="{sw + 2 * bez}" height="{sh + bez + 200}" rx="{rx_out}" fill="url(#lid)"/></g>')
    # thin aluminium edge highlight
    s.append(f'<rect x="{x0 + 1}" y="{top + 1}" width="{sw + 2 * bez - 2}" height="{sh + bez + 200}" rx="{rx_out - 1}" fill="none" stroke="#8a8c92" stroke-opacity="0.55" stroke-width="1.5"/>')
    sx, sy = cx - sw / 2, top + bez
    s.append(f'<clipPath id="screen"><rect x="{sx}" y="{sy}" width="{sw}" height="{sh + 200}" rx="{rx_in}"/></clipPath>')
    s.append('<g clip-path="url(#screen)">')
    s.append(f'<rect x="{sx}" y="{sy}" width="{sw}" height="{sh + 200}" fill="url(#wall)"/>')
    # menu bar
    mb = 38
    s.append(f'<rect x="{sx}" y="{sy}" width="{sw}" height="{mb}" fill="#0b0b14" fill-opacity="0.35"/>')
    return s, sx, sy, mb


def menubar_items(s, sx, sy, sw, mb, notch_l, notch_r):
    y = sy + 25
    left = sx + 28
    if left + 60 < notch_l:
        items = [("Terminal", 700), ("Shell", 400), ("Edit", 400), ("View", 400), ("Window", 400)]
        x = left
        for lab, w in items:
            wpx = len(lab) * 8.6 + 22
            if x + wpx > notch_l - 20:
                break
            s.append(text(x, y, lab, 15, "#ffffff", w))
            x += wpx
    r = sx + sw - 28
    if r - 160 > notch_r:
        s.append(text(r, y, "Thu 9:41", 15, "#ffffff", 500, anchor="end"))
        bx = r - 112
        s.append(f'<rect x="{bx}" y="{y - 12}" width="26" height="13" rx="4" fill="none" stroke="#ffffff" stroke-opacity="0.8" stroke-width="1.3"/>'
                 f'<rect x="{bx + 2.5}" y="{y - 9.5}" width="17" height="8" rx="2" fill="#ffffff"/>'
                 f'<rect x="{bx + 27}" y="{y - 8}" width="2" height="5" rx="1" fill="#ffffff" fill-opacity="0.8"/>')


def panel(s, cx, sy, pw, notch_w, notch_h):
    """Expanded Turnipot island: black, flush with the screen top, wider than the notch."""
    ph = 268
    x = cx - pw / 2
    r = 30
    # concave shoulders at the top + convex bottom corners
    sh = 10
    d = (f"M{x - sh} {sy}H{x + pw + sh}a{sh} {sh} 0 0 0 -{sh} {sh}V{sy + ph - r}a{r} {r} 0 0 1 -{r} {r}"
         f"H{x + r}a{r} {r} 0 0 1 -{r} -{r}V{sy + sh}a{sh} {sh} 0 0 0 -{sh} -{sh}Z")
    s.append(f'<g filter="url(#soft)"><path d="{d}" fill="#000"/></g>')
    s.append(f'<circle cx="{cx}" cy="{sy + 14}" r="4.5" fill="#0d1018"/><circle cx="{cx}" cy="{sy + 14}" r="2" fill="#1c2436"/><circle cx="{cx - 0.8}" cy="{sy + 13.2}" r="0.7" fill="#5b6b8c"/>')
    # notch row
    y0 = sy + 26
    s.append(text(x + 30, y0, "SESSIONS", 14, "#8d8d93", 600, ls=2))
    s.append(text(x + 122, y0, "3", 14, "#c9c9ce", 700))
    s.append(turnip(x + 150, sy + 2, 2.2))
    s.append(text(x + pw - 30, y0 + 1, "✕", 15, "#8d8d93", anchor="end"))
    rows = [("#4ade80", "Refactor payment API", "18k", "now", True),
            ("#4ade80", "Hero section copy", "80k", "now", False),
            ("#fbbf24", "Docs cleanup", "10k", "21m", False)]
    y = sy + 76
    for dot, name, tok, t, sub in rows:
        s.append(f'<circle cx="{x + 36}" cy="{y - 6}" r="5.5" fill="{dot}"/>')
        s.append(text(x + 52, y, name, 18, "#ffffff", 700))
        s.append(text(x + 352, y, tok, 16, "#b9b9be", anchor="end"))
        s.append(text(x + 400, y, t, 16, "#b9b9be", anchor="end"))
        y += 32
        if sub:
            for n, a, st in [("build:api", "Bash: npm run build", "3m"), ("Check callers", "Grep: legacy_charge", "1m")]:
                s.append(f'<circle cx="{x + 60}" cy="{y - 5}" r="4" fill="#d97757"/>')
                s.append(text(x + 72, y, n, 14, "#e6e6ea"))
                s.append(text(x + 186, y, a, 13, "#8d8d93", family=MONO))
                s.append(text(x + 400, y, st, 14, "#8d8d93", anchor="end"))
                y += 26
            y += 10
    ux, uw = x + 440, pw - 470
    for i, (lab, pct, f) in enumerate([("Session (5h)", "12%", .12), ("Week · all", "42%", .42), ("Week · Fable", "21%", .21)]):
        uy = sy + 74 + i * 62
        s.append(text(ux, uy, lab, 15, "#ffffff", 600))
        s.append(text(ux + uw, uy, pct, 15, "#ffffff", 600, anchor="end"))
        s.append(f'<rect x="{ux}" y="{uy + 11}" width="{uw}" height="7" rx="3.5" fill="#2c2c30"/>')
        s.append(f'<rect x="{ux}" y="{uy + 11}" width="{max(uw * f, 7):.0f}" height="7" rx="3.5" fill="#d97757"/>')
        s.append(text(ux, uy + 36, "resets Fri 9pm" if i else "resets 12:30am", 12, "#8d8d93"))
    return ph


def permission(s, x, y):
    w, h = 400, 128
    s.append(f'<g filter="url(#soft)"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="22" fill="#000" stroke="#2b2521" stroke-width="1"/></g>')
    s.append(text(x + 22, y + 34, "Docs cleanup", 16, "#ffffff", 700))
    s.append(text(x + 134, y + 34, "wants to run", 16, "#b9b9be"))
    s.append(f'<rect x="{x + 22}" y="{y + 46}" width="{w - 44}" height="30" rx="8" fill="#1a1a1d"/>')
    s.append(text(x + 34, y + 66, "Bash", 14, "#f0a07f", 600, family=MONO))
    s.append(text(x + 80, y + 66, "npm test -- --watch=false", 14, "#e6e6ea", family=MONO))
    bx = x + 22
    for lab, bw, prim in [("Allow  ⌘↩", 110, True), ("Always allow", 116, False), ("Deny", 72, False)]:
        s.append(f'<rect x="{bx}" y="{y + 88}" width="{bw}" height="28" rx="14" fill="{"#d97757" if prim else "#2a2a2e"}"/>')
        s.append(text(bx + bw / 2, y + 107, lab, 13, "#ffffff" if prim else "#e6e6ea", 600, anchor="middle"))
        bx += bw + 8


def palette(dark):
    if dark:
        return dict(bg="#0e0c0b", dots="#211c19", ink="#f3eee9", muted="#a59c94", accent="#f0a07f", glow=0.18)
    return dict(bg="#f7f4f0", dots="#e7e0d8", ink="#1d1a17", muted="#625b54", accent="#b4532f", glow=0.14)


def left_copy(s, c, x=96, top=100, dark=True, chips=("Sessions & usage", "Permissions", "Questions & plans", "Reply reader")):
    s.append(f'<g transform="translate({x} {top})">{mark(84)}</g>')
    s.append(text(x + 106, top + 68, "turnipot", 88, c["ink"], 800, ls=-3))
    for i, l in enumerate(["Claude Code,", "right in your", "MacBook's notch."]):
        s.append(text(x, top + 170 + i * 55, l, 46, c["ink"], 700, ls=-0.6))
    s.append(text(x, top + 330, "Sessions, usage and permissions at a glance. When a", 21, c["muted"]))
    s.append(text(x, top + 359, "turn ends, a turnip springs out of its pot to tell you.", 21, c["muted"]))
    cx = x
    for lab in chips:
        w = len(lab) * 8.6 + 36
        s.append(f'<rect x="{cx}" y="{top + 396}" width="{w:.0f}" height="36" rx="18" fill="#d97757" fill-opacity="{0.16 if dark else 0.13}"/>')
        s.append(text(cx + w / 2, top + 419, lab, 15, c["accent"], 600, anchor="middle"))
        cx += w + 10


def banner(dark):
    """Logo and headline centred on top; the top of a MacBook below (bezel, menu bar, notch), with
    the panel open at the notch and a permission drop-down under it. Cropped at the bottom."""
    W, H = 1600, 760
    c = palette(dark)
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">', defs(dark),
         f'<rect width="{W}" height="{H}" fill="{c["bg"]}"/>']
    # centred wordmark + one-line headline
    s.append(f'<g transform="translate({800 - 220} 48)">{mark(72)}</g>')
    s.append(text(800 - 128, 106, "turnipot", 76, c["ink"], 800, ls=-2.5))
    s.append(text(800, 176, "Claude Code, right in your MacBook's notch.", 40, c["ink"], 700, anchor="middle", ls=-0.5))
    s.append(text(800, 214, "Sessions, usage and permissions at a glance. When a turn ends, a turnip springs out of its pot.", 19, c["muted"], anchor="middle"))
    cx, sw = 800, 1340
    parts, sx, sy, mb = laptop(cx, 262, sw, 600, W)
    s += parts
    menubar_items(s, sx, sy, sw, mb, cx - 330, cx + 330)
    ph = panel(s, cx, sy, 660, 190, 32)
    permission(s, cx - 200, sy + ph + 34)
    s.append('</g></svg>')
    return "".join(s)



with open(os.path.join(OUT, "banner.svg"), "w") as f:
    f.write(banner(False))
with open(os.path.join(OUT, "banner-dark.svg"), "w") as f:
    f.write(banner(True))
with open(os.path.join(OUT, "mark.svg"), "w") as f:
    f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 80 80">{mark(80)}</svg>')
print("ok")
