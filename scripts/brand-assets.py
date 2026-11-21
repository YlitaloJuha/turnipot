#!/usr/bin/env python3
"""Generate docs/brand SVGs for Turnipot (banner light/dark, mark). Pixel art mirrors TurnipRig."""
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


def banner(dark):
    W, H = 1600, 600
    if dark:
        bg, dots, ink, muted, accent, chip, glow, line = "#0e0c0b", "#211c19", "#f3eee9", "#a59c94", "#f0a07f", "#d97757", 0.18, "#2b2521"
    else:
        bg, dots, ink, muted, accent, chip, glow, line = "#f7f4f0", "#e7e0d8", "#1d1a17", "#625b54", "#b4532f", "#d97757", 0.14, "#2b2521"
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
         '<defs>',
         f'<pattern id="dots" width="26" height="26" patternUnits="userSpaceOnUse"><circle cx="13" cy="13" r="1.3" fill="{dots}"/></pattern>',
         f'<radialGradient id="glow" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(1180 120) scale(900 620)"><stop offset="0" stop-color="#d97757" stop-opacity="{glow}"/><stop offset="1" stop-color="#d97757" stop-opacity="0"/></radialGradient>',
         '<filter id="shadow" x="-10%" y="-10%" width="120%" height="140%"><feGaussianBlur in="SourceAlpha" stdDeviation="10"/><feOffset dy="8" result="b"/>'
         f'<feFlood flood-color="rgba(0,0,0,{0.55 if dark else 0.28})"/><feComposite in2="b" operator="in"/><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>',
         '</defs>',
         f'<rect width="{W}" height="{H}" fill="{bg}"/><rect width="{W}" height="{H}" fill="url(#dots)"/><rect width="{W}" height="{H}" fill="url(#glow)"/>']

    # Left: mark + wordmark, headline, sub, chips
    s.append(f'<g transform="translate(96 100)">{mark(84)}</g>')
    s.append(text(202, 168, "turnipot", 88, ink, 800, ls=-3))
    for i, line_ in enumerate(["Claude Code,", "right in your", "MacBook's notch."]):
        s.append(text(96, 270 + i * 55, line_, 46, ink, 700, ls=-0.6))
    s.append(text(96, 430, "Sessions, usage and permissions at a glance. When a", 21, muted))
    s.append(text(96, 459, "turn ends, a turnip springs out of its pot to tell you.", 21, muted))
    x = 96
    for label in ["Sessions & usage", "Permissions", "Questions & plans", "Reply reader"]:
        w = len(label) * 8.6 + 36
        s.append(f'<rect x="{x}" y="496" width="{w:.0f}" height="36" rx="18" fill="{chip}" fill-opacity="{0.16 if dark else 0.13}"/>')
        s.append(text(x + w / 2, 519, label, 15, accent, 600, anchor="middle"))
        x += w + 10

    # Right: the expanded notch panel, hanging from the top edge
    PX, PW, PH = 790, 740, 318
    s.append(f'<g filter="url(#shadow)"><path d="M{PX} 0H{PX + PW}V{PH - 36}a36 36 0 0 1-36 36H{PX + 36}a36 36 0 0 1-36-36Z" fill="#000" stroke="{line}" stroke-width="{1.5 if dark else 0}"/></g>')
    s.append(text(PX + 40, 48, "SESSIONS", 16, "#8d8d93", 600, ls=2.2))
    s.append(text(PX + 142, 48, "3", 16, "#c9c9ce", 700))
    s.append(turnip(PX + 236, 8, 3.4))
    # top-right icons: gear-ish dot, pin, close
    s.append(text(PX + PW - 40, 50, "✕", 18, "#8d8d93", 400, anchor="end"))

    rows = [
        ("#4ade80", "Refactor payment API", "18k", "now", True),
        ("#4ade80", "Hero section copy", "80k", "now", False),
        ("#fbbf24", "Docs cleanup", "10k", "21m", False),
    ]
    y = 104
    for dot, name, tok, t, sub in rows:
        s.append(f'<circle cx="{PX + 48}" cy="{y - 7}" r="6.5" fill="{dot}"/>')
        s.append(text(PX + 68, y, name, 22, "#ffffff", 700))
        s.append(text(PX + 400, y, tok, 20, "#b9b9be", 400, anchor="end"))
        s.append(text(PX + 462, y, t, 20, "#b9b9be", 400, anchor="end"))
        y += 40
        if sub:
            for sname, act, st in [("build:api", "Bash: npm run build", "3m"), ("Check callers", "Grep: legacy_charge", "1m")]:
                s.append(f'<circle cx="{PX + 76}" cy="{y - 6}" r="5" fill="#d97757"/>')
                s.append(text(PX + 92, y, sname, 17, "#e6e6ea", 400))
                s.append(text(PX + 232, y, act, 16, "#8d8d93", 400, family=MONO))
                s.append(text(PX + 462, y, st, 17, "#8d8d93", 400, anchor="end"))
                y += 32
            y += 14
    # usage column
    ux, uw = PX + 512, 190
    for i, (lab, pct, frac) in enumerate([("Session (5h)", "12%", 0.12), ("Week · all", "42%", 0.42), ("Week · Fable", "21%", 0.21)]):
        uy = 98 + i * 76
        s.append(text(ux, uy, lab, 19, "#ffffff", 600))
        s.append(text(ux + uw, uy, pct, 19, "#ffffff", 600, anchor="end"))
        s.append(f'<rect x="{ux}" y="{uy + 14}" width="{uw}" height="9" rx="4.5" fill="#2c2c30"/>')
        s.append(f'<rect x="{ux}" y="{uy + 14}" width="{max(uw * frac, 9):.0f}" height="9" rx="4.5" fill="#d97757"/>')
        s.append(text(ux, uy + 42, "resets Fri 9pm" if i else "resets 12:30am", 14, "#8d8d93"))

    # Permission drop-down card
    CX, CY, CW, CH = 900, 356, 460, 150
    s.append(f'<g filter="url(#shadow)"><rect x="{CX}" y="{CY}" width="{CW}" height="{CH}" rx="26" fill="#000" stroke="{line}" stroke-width="{1.5 if dark else 0}"/></g>')
    s.append(text(CX + 28, CY + 40, "Docs cleanup", 19, "#ffffff", 700))
    s.append(text(CX + 160, CY + 40, "wants to run", 19, "#b9b9be"))
    s.append(f'<rect x="{CX + 28}" y="{CY + 54}" width="{CW - 56}" height="34" rx="9" fill="#1a1a1d"/>')
    s.append(text(CX + 42, CY + 77, "Bash", 16, "#f0a07f", 600, family=MONO))
    s.append(text(CX + 96, CY + 77, "npm test -- --watch=false", 16, "#e6e6ea", 400, family=MONO))
    bx = CX + 28
    for lab, w, primary in [("Allow  ⌘↩", 128, True), ("Always allow", 132, False), ("Deny", 84, False)]:
        s.append(f'<rect x="{bx}" y="{CY + 102}" width="{w}" height="32" rx="16" fill="{"#d97757" if primary else "#2a2a2e"}"/>')
        s.append(text(bx + w / 2, CY + 123, lab, 15, "#ffffff" if primary else "#e6e6ea", 600, anchor="middle"))
        bx += w + 10
    s.append("</svg>")
    return "".join(s)


with open(os.path.join(OUT, "banner.svg"), "w") as f:
    f.write(banner(False))
with open(os.path.join(OUT, "banner-dark.svg"), "w") as f:
    f.write(banner(True))
with open(os.path.join(OUT, "mark.svg"), "w") as f:
    f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 80 80">{mark(80)}</svg>')
print("ok")
