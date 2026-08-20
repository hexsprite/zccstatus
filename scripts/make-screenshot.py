#!/usr/bin/env python3
"""Render the zccstatus demo to a PNG.

The bar is ANSI true-color and every glyph occupies exactly one cell, so this
draws it cell by cell with the Nerd Font itself. Doing it directly beats
screenshotting a terminal: the result is deterministic and any size we want.

    python3 scripts/make-screenshot.py assets/demo.png
"""
import os
import re
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

BIN = os.environ.get("ZCC_BIN", "./zig-out/bin/zccstatus")
COLS = os.environ.get("ZCC_COLS", "112")
SCALE = int(os.environ.get("ZCC_SCALE", "2"))
OUT = sys.argv[1] if len(sys.argv) > 1 else "assets/demo.png"

ANSI = re.compile(r"\x1b\[([0-9;]*)m")

BG = (11, 11, 16)
PANEL = (17, 17, 23)
INK = (232, 230, 240)
MUTED = (138, 135, 160)
LABEL = (111, 108, 133)
ACCENT = (255, 42, 109)

FONTS = [
    "~/Library/Fonts/HackNerdFontMono-Regular.ttf",
    "~/Library/Fonts/HackNerdFont-Regular.ttf",
    "/Library/Fonts/HackNerdFontMono-Regular.ttf",
]
BOLDS = [
    "~/Library/Fonts/HackNerdFontMono-Bold.ttf",
    "~/Library/Fonts/HackNerdFont-Bold.ttf",
]


def find(paths):
    for p in paths:
        q = os.path.expanduser(p)
        if os.path.exists(q):
            return q
    sys.exit("no Nerd Font found; install one (brew install --cask font-hack-nerd-font)")


def parse(line):
    """ANSI line -> [(char, fg, bg)] with one entry per cell."""
    cells, fg, bg, pos = [], INK, None, 0
    for m in ANSI.finditer(line):
        for ch in line[pos:m.start()]:
            cells.append((ch, fg, bg))
        code = m.group(1)
        if code in ("", "0"):
            fg, bg = INK, None
        else:
            p = code.split(";")
            if len(p) == 5 and p[1] == "2":
                rgb = tuple(int(x) for x in p[2:5])
                if p[0] == "38":
                    fg = rgb
                elif p[0] == "48":
                    bg = rgb
        pos = m.end()
    for ch in line[pos:]:
        cells.append((ch, fg, bg))
    return cells


env = dict(os.environ, COLUMNS=COLS)
raw = subprocess.run([BIN, "--demo"], capture_output=True, text=True, env=env).stdout

rows = []  # ("bar", cells) | ("label", text) | ("gap", None)
for line in raw.split("\n"):
    plain = ANSI.sub("", line)
    if not plain.strip():
        rows.append(("gap", None))
    elif "\x1b" not in line:
        rows.append(("label", plain.strip().upper()))
    else:
        rows.append(("bar", parse(line.rstrip())))

# Collapse runs of blank lines.
squashed = []
for r in rows:
    if r[0] == "gap" and squashed and squashed[-1][0] == "gap":
        continue
    squashed.append(r)
rows = [r for r in squashed if not (r[0] == "gap" and r is squashed[0])]

FS = 26 * SCALE
mono = ImageFont.truetype(find(FONTS), FS)
title_f = ImageFont.truetype(find(BOLDS), 40 * SCALE)
sub_f = ImageFont.truetype(find(FONTS), 19 * SCALE)
label_f = ImageFont.truetype(find(FONTS), 16 * SCALE)

CELL_W = round(mono.getlength("M"))
ROW_H = round(FS * 1.52)
PAD = 52 * SCALE
GAP_H = 14 * SCALE
LABEL_H = round(28 * SCALE)

width_cells = max((len(c) for k, c in rows if k == "bar"), default=40)
head_h = round(52 * SCALE) + round(34 * SCALE) + round(26 * SCALE)

body_h = 0
for kind, val in rows:
    body_h += {"bar": ROW_H, "label": LABEL_H, "gap": GAP_H}[kind]

W = width_cells * CELL_W + PAD * 2
H = head_h + body_h + PAD * 2

img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)
d.rounded_rectangle([PAD // 3, PAD // 3, W - PAD // 3, H - PAD // 3],
                    radius=14 * SCALE, fill=PANEL)

x0, y = PAD, PAD
d.text((x0, y), "zccstatus", font=title_f, fill=ACCENT)
y += round(52 * SCALE)
d.text((x0, y), "cyberpunk powerline status line for Claude Code",
       font=sub_f, fill=MUTED)
y += round(28 * SCALE)
d.text((x0, y), "one static Zig binary  ·  ~3ms per render  ·  no config files",
       font=sub_f, fill=MUTED)
y += round(32 * SCALE)

for kind, val in rows:
    if kind == "gap":
        y += GAP_H
    elif kind == "label":
        d.text((x0, y + LABEL_H // 5), " ".join(val), font=label_f, fill=LABEL)
        y += LABEL_H
    else:
        for i, (ch, fg, bg) in enumerate(val):
            cx = x0 + i * CELL_W
            if bg:
                # One rect per cell, edge to edge, so separators seam cleanly.
                d.rectangle([cx, y, cx + CELL_W, y + ROW_H], fill=bg)
            if ch != " ":
                d.text((cx, y + (ROW_H - FS) // 2 - FS // 8), ch, font=mono, fill=fg)
        y += ROW_H

# Rendered oversized, then reduced: supersampling keeps the glyph edges clean
# at a size that is actually postable.
MAX_W = int(os.environ.get("ZCC_MAX_W", "2400"))
if W > MAX_W:
    img = img.resize((MAX_W, round(H * MAX_W / W)), Image.LANCZOS)

os.makedirs(os.path.dirname(OUT) or ".", exist_ok=True)
img.save(OUT)
print(f"wrote {OUT}  {img.width}x{img.height}  (rendered {W}x{H}, {width_cells} cols)")
