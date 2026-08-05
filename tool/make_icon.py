#!/usr/bin/env python3
"""Generates the BranchPilot app icon: a commit-graph / branch-fork glyph on
a dark rounded square.

    python3 tool/make_icon.py [--sizes 16,32,48,64,128,256,512]
                               [--out-dir assets/icon]

Design (flat, no text):
  - 1024x1024 rounded square (corner radius ~180 at that scale), background
    a dark charcoal (#14171D — the same tone as lib/app.dart's dark theme
    `scaffoldBackgroundColor`).
  - Three filled circles (commit nodes), in the app's primary blue (#4C8DFF
    — lib/app.dart's ColorScheme seed colour), laid out like a small commit
    graph: an older commit at the bottom, a newer one directly above it on
    the same lane, and a third node on a side lane in between them.
  - A straight line connects bottom -> top directly (the main lane
    continuing straight through), and two curves connect
    bottom -> side -> top (a second lane forking off the bottom commit and
    merging back into the top one) — the same fork+merge shape
    BranchPilot's own commit graph view (lib/ui/graph/commit_graph_view.dart)
    draws for a real branch/merge, just simplified to three nodes.

Renders at a supersampled resolution and downsamples with LANCZOS so the
curves and node edges stay smooth at every exported size — same technique as
the sibling DroidDeck project's tool/make_icon.py. Requires Pillow (this
machine has been verified against 10.2.0).
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw

BG = (20, 23, 29, 255)  # #14171D
BLUE = (76, 141, 255, 255)  # #4C8DFF
TRANSPARENT = (0, 0, 0, 0)

BASE = 1024  # design canvas the geometry below is tuned for
RADIUS = 180  # corner radius at BASE scale
SS = 8  # supersample factor — draw big, downscale for antialiasing

# Node centres and connecting-line geometry, all BASE-relative.
MAIN_X = 380.0
SIDE_X = 664.0
BOTTOM = (MAIN_X, 748.0)  # oldest commit, main lane
TOP = (MAIN_X, 276.0)  # newest commit, main lane (the merge point)
SIDE = (SIDE_X, 486.0)  # side-lane commit (the forked branch)
NODE_R = 72.0
STROKE = 50.0


def _s(v: float, scale: int) -> float:
    """Scales a BASE-relative measurement into the supersampled canvas."""
    return v * scale / BASE


def _pt(p: tuple[float, float], scale: int) -> tuple[float, float]:
    return (_s(p[0], scale), _s(p[1], scale))


def rounded_mask(size: int, radius: float) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def _quad_bezier(
    p0: tuple[float, float],
    p1: tuple[float, float],
    p2: tuple[float, float],
    steps: int,
) -> list[tuple[float, float]]:
    pts = []
    for i in range(steps + 1):
        t = i / steps
        mt = 1 - t
        x = mt * mt * p0[0] + 2 * mt * t * p1[0] + t * t * p2[0]
        y = mt * mt * p0[1] + 2 * mt * t * p1[1] + t * t * p2[1]
        pts.append((x, y))
    return pts


def _cap(draw: ImageDraw.ImageDraw, x: float, y: float, r: float, fill) -> None:
    draw.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def draw_graph(draw: ImageDraw.ImageDraw, scale: int) -> None:
    """Draws the fork+merge glyph: a straight main-lane line plus two curves
    that fork off the bottom node and merge back into the top node, then the
    three commit-node circles on top of everything (so their edges are
    clean, unbroken by the line joins underneath)."""
    bottom = _pt(BOTTOM, scale)
    top = _pt(TOP, scale)
    side = _pt(SIDE, scale)
    stroke = _s(STROKE, scale)
    r = stroke / 2

    # Main lane: bottom commit straight up to the top (merge) commit.
    draw.line([bottom, top], fill=BLUE, width=round(stroke), joint="curve")

    # Side lane: forks off the bottom commit, curves out to the side node,
    # then curves back in to merge into the top commit. Control points sit
    # at the side lane's x and each endpoint's y, giving a smooth
    # quarter-circle-like turn rather than a sharp corner.
    fork_ctrl = (_s(SIDE_X, scale), bottom[1])
    merge_ctrl = (_s(SIDE_X, scale), top[1])
    fork_curve = _quad_bezier(bottom, fork_ctrl, side, 40)
    merge_curve = _quad_bezier(side, merge_ctrl, top, 40)
    draw.line(fork_curve, fill=BLUE, width=round(stroke), joint="curve")
    draw.line(merge_curve, fill=BLUE, width=round(stroke), joint="curve")
    for x, y in (bottom, top, side):
        _cap(draw, x, y, r, BLUE)

    # Commit nodes, drawn last so they sit cleanly on top of the line joins.
    node_r = _s(NODE_R, scale)
    for x, y in (bottom, side, top):
        _cap(draw, x, y, node_r, BLUE)


def build(size: int) -> Image.Image:
    scale = size * SS
    radius = _s(RADIUS, scale)

    canvas = Image.new("RGBA", (scale, scale), TRANSPARENT)
    bg = Image.new("RGBA", (scale, scale), BG)
    canvas.paste(bg, (0, 0), rounded_mask(scale, radius))

    draw = ImageDraw.Draw(canvas)
    draw_graph(draw, scale)

    return canvas.resize((size, size), Image.LANCZOS)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", default="16,32,48,64,128,256,512")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "assets/icon",
    )
    args = parser.parse_args()

    sizes = [int(s) for s in args.sizes.split(",") if s.strip()]
    args.out_dir.mkdir(parents=True, exist_ok=True)

    for size in sizes:
        icon = build(size)
        out = args.out_dir / f"branchpilot_{size}.png"
        icon.save(out, "PNG", optimize=True)
        print(f"wrote {out} ({size}x{size})")


if __name__ == "__main__":
    main()
