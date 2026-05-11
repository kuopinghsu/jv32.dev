#!/usr/bin/env python3
"""
gen_layout_gds.py — Render the post-P&R GDS as a KLayout-style PNG.

Reads the OpenROAD native GDS + final DEF from an OpenLane2 run directory and
produces a colour PNG showing:
  - Per-layer metal routing polygons (metal1-metal9) using the FreePDK45
    layer numbering
  - SRAM macro boundaries (from DEF COMPONENTS)
  - Standard-cell row area (from DEF ROW records)
  - Annotated die outline, scale bar, and layer legend

Coordinate system note
----------------------
The OpenROAD GDS uses coordinates that are 5× the physical µm values.
This is auto-detected by comparing GDS SRAM reference positions to DEF
macro positions.  All rendering is done in physical µm.

Dependencies: gdstk, Pillow (PIL), numpy  — no KLayout required.

Usage
-----
    python3 gen_layout_gds.py <openlane_run_dir> <output.png> [options]

    positional:
      openlane_run_dir   path to the OpenLane2 run directory
                         (must contain final/gds/*.gds and final/def/*.def)
      output_png         output file path

    optional:
      --dpi N            output resolution in dots-per-inch (default 150)
      --width-px W       override output pixel width (default derived from DPI)
      --layers L,...     comma-separated layer numbers to render
                         (default: 35,36,37,38,39,40,41,42 — routing metals)
      --include-device   also render device/cell-internal layers 1-17
                         (very slow: ~25 M polygons for layer 11 alone)
      --title TEXT       figure title (default: inferred from run dir)
      --no-legend        omit the layer legend panel

Examples
--------
    # Fast default (routing metals only, 150 DPI)
    python3 gen_layout_gds.py syn/build/openlane_run syn/build/LAYOUT_gds.png

    # Higher resolution
    python3 gen_layout_gds.py syn/build/openlane_run out.png --dpi 300
"""

from __future__ import annotations

import argparse
import glob
import math
import os
import re
import sys
import time
from collections import defaultdict
from typing import Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Layer definitions — FreePDK45 / Nangate 45 nm GDS layer numbers
# (layer, name, rgb_hex, alpha_on_white_bg)
# ---------------------------------------------------------------------------

# fmt: off
LAYER_DEFS: Dict[int, Tuple[str, str, float]] = {
    # ── Device / standard-cell-internal layers ─────────────────────────────
    #    These are sub-pixel at full-die scale; skip by default.
    1:  ("P-Well",      "#77bb77", 0.30),
    2:  ("Active",      "#55aa55", 0.30),
    3:  ("N-Well",      "#7fbfbf", 0.25),
    4:  ("N+",          "#ffcc55", 0.20),
    5:  ("P+",          "#cc66cc", 0.20),
    6:  ("Poly",        "#ee4444", 0.30),
    9:  ("Contact",     "#404040", 0.45),
    10: ("M0/Li",       "#888888", 0.35),
    11: ("M1-cell",     "#5577ff", 0.35),   # dominant cell layer — blue horizontal
    12: ("V1-cell",     "#555555", 0.25),
    13: ("M2-cell",     "#ff66bb", 0.30),
    14: ("V2-cell",     "#555555", 0.20),
    15: ("M3-cell",     "#44cc44", 0.25),
    16: ("V3-cell",     "#555555", 0.20),
    17: ("M4-cell",     "#ffaa33", 0.20),
    # ── Routing metals (DEF layer map → GDS layer numbers) ─────────────────
    34: ("metal1",      "#2255ff", 0.75),
    35: ("metal2",      "#ff44cc", 0.65),
    36: ("metal3",      "#33bb33", 0.60),
    37: ("metal4",      "#ff9900", 0.80),   # PDN horizontal straps
    38: ("metal5",      "#22cccc", 0.70),
    39: ("metal6",      "#cc3333", 0.60),
    40: ("metal7",      "#8833ff", 0.55),
    41: ("metal8",      "#aaaa00", 0.50),
    42: ("metal9",      "#007799", 0.45),
    # ── Cut / via layers ───────────────────────────────────────────────────
    50: ("via1",        "#444444", 0.45),
    51: ("via2",        "#444444", 0.40),
    52: ("via3",        "#444444", 0.40),
    53: ("via4",        "#444444", 0.40),
    54: ("via5",        "#444444", 0.40),
    55: ("via6",        "#444444", 0.35),
    56: ("via7",        "#444444", 0.35),
    57: ("via8",        "#444444", 0.30),
    # ── Special ────────────────────────────────────────────────────────────
    235: ("prBoundary", "#aaaaaa", 0.08),
    239: ("Label",      "#888888", 0.12),
}
# fmt: on

# Default layers to render (device layers omitted for speed)
DEFAULT_LAYERS = [35, 36, 37, 38, 39, 40, 41, 42]
DEVICE_LAYERS  = list(range(1, 18))

# ---------------------------------------------------------------------------
# DEF parser
# ---------------------------------------------------------------------------

def parse_def(def_path: str) -> dict:
    """
    Parse the final DEF.  Returns a dict:
      dbu_per_um  int
      die         (x0, y0, x1, y1) in µm
      macros      list of {"name", "cell", "x", "y"} in µm
      rows        list of {"x", "y", "width", "height"} in µm
    """
    result: dict = {"dbu_per_um": 2000, "die": None, "macros": [], "rows": []}

    with open(def_path) as fh:
        text = fh.read()

    m = re.search(r"UNITS DISTANCE MICRONS\s+(\d+)", text)
    if m:
        result["dbu_per_um"] = int(m.group(1))
    dbu = result["dbu_per_um"]

    m = re.search(
        r"DIEAREA\s+\(\s*(\d+)\s+(\d+)\s*\)\s+\(\s*(\d+)\s+(\d+)\s*\)", text
    )
    if m:
        result["die"] = tuple(int(v) / dbu for v in m.groups())

    comp_re = re.compile(
        r"^\s+-\s+(\S+)\s+(\S+)\s+.*?(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)",
        re.MULTILINE,
    )
    for mc in comp_re.finditer(text):
        inst, cell, x, y, orient = mc.groups()
        # Only keep hardened macros (SRAM) — skip all std-cells and fill cells
        if "sram" in cell.lower() or "macro" in cell.lower():
            result["macros"].append(
                {"name": inst, "cell": cell,
                 "x": int(x) / dbu, "y": int(y) / dbu, "orient": orient}
            )

    row_re = re.compile(
        r"^ROW\s+\S+\s+\S+\s+(\d+)\s+(\d+)\s+\S+\s+DO\s+(\d+)\s+BY\s+\d+\s+STEP\s+(\d+)",
        re.MULTILINE,
    )
    for rm in row_re.finditer(text):
        rx, ry, ncells, step = (
            int(rm.group(1)), int(rm.group(2)),
            int(rm.group(3)), int(rm.group(4)),
        )
        result["rows"].append({
            "x": rx / dbu, "y": ry / dbu,
            "width": ncells * step / dbu,
        })

    # Infer row height from pitch
    if len(result["rows"]) >= 2:
        ys = sorted({r["y"] for r in result["rows"]})
        pitches = [ys[i + 1] - ys[i] for i in range(min(20, len(ys) - 1))]
        pitches = [p for p in pitches if 0 < p < 5]
        row_h = min(pitches) if pitches else 0.56
    else:
        row_h = 0.56  # Nangate 45 nm row height

    for r in result["rows"]:
        r["height"] = row_h

    return result

# ---------------------------------------------------------------------------
# GDS loader
# ---------------------------------------------------------------------------

def _detect_gds_scale(lib, def_macros: list) -> float:
    """
    Compare SRAM positions in GDS to DEF to determine the GDS→µm scale factor.
    Returns gds_scale so that:  physical_um = gds_coordinate * gds_scale
    """
    top = lib.top_level()[0]
    sram_refs = [r for r in top.references if "sram" in r.cell.name.lower()]
    if not sram_refs or not def_macros:
        print("  [warn] Cannot auto-detect GDS scale — defaulting to 1/5.", file=sys.stderr)
        return 1.0 / 5.0

    # Filter DEF macros to SRAMs
    sram_defs = [m for m in def_macros if "sram" in m["cell"].lower()]
    if not sram_defs:
        return 1.0 / 5.0

    # Sort both by x position
    gds_xs = sorted(r.origin[0] for r in sram_refs)
    def_xs = sorted(m["x"] for m in sram_defs)

    if len(gds_xs) >= 2 and len(def_xs) >= 2:
        scale = def_xs[1] / gds_xs[1]
    else:
        scale = def_xs[0] / gds_xs[0]

    print(f"  GDS→µm scale = {scale:.6f}  (GDS coord × {scale:.4f} = physical µm)")
    return scale

def load_layer_polygons(
    gds_path: str,
    layers: list,
    gds_scale: float,
    die_um: Tuple[float, float, float, float],
    verbose: bool = True,
) -> Dict[int, list]:
    """
    Load and scale polygons for the requested layers from the GDS.
    Returns dict: layer → list of numpy (N,2) arrays in physical µm.
    Polygons outside the die bounding box are discarded.
    """
    try:
        import gdstk
    except ImportError:
        print("ERROR: gdstk is not installed.  Run:  pip install gdstk",
              file=sys.stderr)
        sys.exit(1)
    try:
        import numpy as np
    except ImportError:
        print("ERROR: numpy is not installed.  Run:  pip install numpy",
              file=sys.stderr)
        sys.exit(1)

    dx0, dy0, dx1, dy1 = die_um
    lib = gdstk.read_gds(gds_path)
    top = lib.top_level()[0]

    result: Dict[int, list] = defaultdict(list)

    layer_set = set(layers)
    t0 = time.time()

    for layer in sorted(layer_set):
        name = LAYER_DEFS.get(layer, (f"layer{layer}", "#888888", 0.5))[0]
        if verbose:
            print(f"  Loading layer {layer:3d} ({name}) … ", end="", flush=True)
        t1 = time.time()

        polys = top.get_polygons(layer=layer, datatype=0)

        kept = 0
        for p in polys:
            pts = p.points * gds_scale  # scale to physical µm
            # Bounding-box clip: discard if entirely outside die
            px_min, py_min = pts.min(axis=0)
            px_max, py_max = pts.max(axis=0)
            if px_max < dx0 or px_min > dx1 or py_max < dy0 or py_min > dy1:
                continue
            result[layer].append(pts)
            kept += 1

        if verbose:
            print(f"{kept:,} polygons  ({time.time()-t1:.1f}s)")

    if verbose:
        print(f"  Total load time: {time.time()-t0:.1f}s")
    return result

# ---------------------------------------------------------------------------
# Rasteriser
# ---------------------------------------------------------------------------

def _hex_to_rgb(h: str) -> Tuple[int, int, int]:
    h = h.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)

def rasterize_layers(
    layer_polys: Dict[int, list],
    die_um: Tuple[float, float, float, float],
    img_w: int,
    img_h: int,
    render_order: list,
) -> "Image":
    """
    Rasterize all layers onto a white PIL Image using alpha compositing.
    Layer order in render_order determines Z-order (first = bottom).
    """
    try:
        from PIL import Image, ImageDraw
        import numpy as np
    except ImportError:
        print("ERROR: Pillow not installed.  Run:  pip install Pillow",
              file=sys.stderr)
        sys.exit(1)

    dx0, dy0, dx1, dy1 = die_um
    die_w = dx1 - dx0
    die_h = dy1 - dy0

    def um_to_px(x_um: float, y_um: float) -> Tuple[int, int]:
        px = int((x_um - dx0) / die_w * img_w)
        py = int(img_h - 1 - (y_um - dy0) / die_h * img_h)   # flip Y
        return px, py

    # Composite image (RGBA)
    canvas = Image.new("RGBA", (img_w, img_h), (255, 255, 255, 255))

    for layer in render_order:
        if layer not in layer_polys or not layer_polys[layer]:
            continue

        meta = LAYER_DEFS.get(layer, (f"layer{layer}", "#888888", 0.5))
        color_hex, alpha = meta[1], meta[2]
        r, g, b = _hex_to_rgb(color_hex)
        fill = (r, g, b, int(alpha * 255))

        # Draw each polygon onto a per-layer RGBA overlay, then composite
        overlay = Image.new("RGBA", (img_w, img_h), (0, 0, 0, 0))
        draw = ImageDraw.Draw(overlay)

        t0 = time.time()
        n = len(layer_polys[layer])
        for i, pts in enumerate(layer_polys[layer]):
            # Convert to pixel coords
            px_pts = [um_to_px(x, y) for x, y in pts]
            if len(px_pts) < 3:
                continue
            draw.polygon(px_pts, fill=fill)

        canvas = Image.alpha_composite(canvas, overlay)
        name = meta[0]
        elapsed = time.time() - t0
        print(f"  Rendered layer {layer:3d} ({name:12s}): {n:,} polys in {elapsed:.1f}s")

    return canvas.convert("RGB")

# ---------------------------------------------------------------------------
# Annotation helpers
# ---------------------------------------------------------------------------

def annotate(
    img: "Image",
    die_um: Tuple[float, float, float, float],
    def_data: dict,
    macro_sizes: Dict[str, Tuple[float, float]],  # cell → (w, h) in µm
    title: str,
    render_layers: list,
    show_legend: bool,
) -> "Image":
    """Draw die outline, SRAM boxes, scale bar, and legend onto the image."""
    from PIL import Image, ImageDraw, ImageFont
    import numpy as np

    dx0, dy0, dx1, dy1 = die_um
    die_w = dx1 - dx0
    die_h = dy1 - dy0
    img_w, img_h = img.size

    def um_to_px(x_um: float, y_um: float) -> Tuple[int, int]:
        px = int((x_um - dx0) / die_w * img_w)
        py = int(img_h - 1 - (y_um - dy0) / die_h * img_h)
        return px, py

    # Widen canvas for legend if requested
    LEGEND_W = 200 if show_legend else 0
    canvas = Image.new("RGB", (img_w + LEGEND_W, img_h), (245, 245, 245))
    canvas.paste(img, (0, 0))
    draw = ImageDraw.Draw(canvas)

    # Try to load a font; fall back to default
    try:
        from PIL import ImageFont
        font_sm = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 14)
        font_md = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 16)
        font_lg = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 22)
    except Exception:
        font_sm = font_md = font_lg = None

    # ── Die outline ─────────────────────────────────────────────────────────
    tl = um_to_px(dx0, dy1)
    br = um_to_px(dx1, dy0)
    draw.rectangle([tl, br], outline=(35, 95, 220), width=5)

    # ── Standard-cell row region: salmon background fill ────────────────────
    if def_data["rows"]:
        rows = def_data["rows"]
        rx0 = min(r["x"] for r in rows)
        ry0 = min(r["y"] for r in rows)
        rx1 = max(r["x"] + r["width"] for r in rows)
        ry1 = max(r["y"] + r.get("height", 0.56) for r in rows)
        overlay = Image.new("RGBA", (img_w + LEGEND_W, img_h), (0, 0, 0, 0))
        od = ImageDraw.Draw(overlay)
        tl2 = um_to_px(rx0, ry1)
        br2 = um_to_px(rx1, ry0)
        # Salmon background (matches KLayout dense-routing appearance at full die scale)
        od.rectangle([tl2, br2], fill=(230, 150, 120, 140))
        canvas = Image.alpha_composite(canvas.convert("RGBA"), overlay).convert("RGB")
        draw = ImageDraw.Draw(canvas)

    # ── SRAM macro boundaries ───────────────────────────────────────────────
    SRAM_COLOR = (40, 170, 70)

    missing = sorted(
        cell for cell in {macro["cell"] for macro in def_data["macros"]}
        if cell not in macro_sizes
    )
    if missing:
        raise RuntimeError(
            "Missing SRAM macro dimensions for: " + ", ".join(missing) +
            ". Pass --lef-dir pointing to the OpenRAM/Nangate LEF directory."
        )

    for macro in def_data["macros"]:
        cell = macro["cell"]
        size = macro_sizes[cell]
        mw, mh = size
        mx0, my0 = macro["x"], macro["y"]
        mx1, my1 = mx0 + mw, my0 + mh

        tl3 = um_to_px(mx0, my1)
        br3 = um_to_px(mx1, my0)
        # White fill (SRAM interior is blank — no routing through macros)
        draw.rectangle([tl3, br3], fill=(255, 255, 255), outline=SRAM_COLOR, width=5)

        # Label in centre
        cx_px, cy_px = um_to_px((mx0 + mx1) / 2, (my0 + my1) / 2)
        lbl = "SRAM"
        draw.text((cx_px, cy_px), lbl, fill=SRAM_COLOR, font=font_sm, anchor="mm" if font_sm else None)

    # ── Scale bar ───────────────────────────────────────────────────────────
    bar_um = 200.0  # 200 µm scale bar
    bar_px = int(bar_um / die_w * img_w)
    margin = 20
    bar_y = img_h - margin - 15
    bar_x0 = margin
    bar_x1 = bar_x0 + bar_px
    draw.rectangle([bar_x0, bar_y, bar_x1, bar_y + 8], fill=(40, 40, 40))
    draw.text(
        ((bar_x0 + bar_x1) // 2, bar_y - 6),
        f"{bar_um:.0f} µm",
        fill=(40, 40, 40), font=font_sm,
        anchor="mb" if font_sm else None,
    )

    # ── Title ───────────────────────────────────────────────────────────────
    draw.text(
        (img_w // 2, 14),
        title,
        fill=(30, 30, 30), font=font_lg,
        anchor="mt" if font_lg else None,
    )

    # ── Legend ──────────────────────────────────────────────────────────────
    if show_legend and LEGEND_W > 0:
        lx = img_w + 10
        ly = 20
        draw.text((lx, ly), "Layer Legend", fill=(30, 30, 30), font=font_md)
        ly += 28

        for layer in render_layers:
            if layer not in LAYER_DEFS:
                continue
            name, hex_color, _ = LAYER_DEFS[layer]
            r, g, b = _hex_to_rgb(hex_color)
            # Swatch
            draw.rectangle([lx, ly, lx + 18, ly + 14], fill=(r, g, b), outline=(80, 80, 80))
            draw.text((lx + 24, ly), f"{layer}: {name}", fill=(40, 40, 40), font=font_sm)
            ly += 20
            if ly > img_h - 20:
                break

        # SRAM legend entries
        draw.rectangle([lx, ly, lx + 18, ly + 14], outline=SRAM_COLOR, width=2)
        draw.text((lx + 24, ly), "SRAM macro", fill=(40, 40, 40), font=font_sm)
        ly += 20

    return canvas

# ---------------------------------------------------------------------------
# LEF macro-size lookup
# ---------------------------------------------------------------------------

def find_macro_sizes(lef_dir: Optional[str], cells: list) -> Dict[str, Tuple[float, float]]:
    """Return {cell_name: (width_µm, height_µm)} from LEF files in lef_dir."""
    sizes: Dict[str, Tuple[float, float]] = {}
    if not lef_dir or not os.path.isdir(lef_dir):
        return sizes
    for lef_path in glob.glob(os.path.join(lef_dir, "**", "*.lef"), recursive=True):
        try:
            with open(lef_path) as fh:
                text = fh.read()
        except OSError:
            continue
        for cell in cells:
            if cell in sizes:
                continue
            pat = rf"MACRO\s+{re.escape(cell)}\b.*?SIZE\s+([\d.]+)\s+BY\s+([\d.]+)"
            mc = re.search(pat, text, re.DOTALL)
            if mc:
                sizes[cell] = (float(mc.group(1)), float(mc.group(2)))
    return sizes

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="Render OpenROAD GDS as a KLayout-style PNG.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("openlane_run_dir", help="OpenLane2 run directory")
    ap.add_argument("output_png", help="Output PNG path")
    ap.add_argument("--dpi", type=int, default=150, help="Output DPI (default: 150)")
    ap.add_argument("--width-px", type=int, default=None,
                    help="Override output pixel width")
    ap.add_argument(
        "--layers",
        default=None,
        help=(
            "Comma-separated layer numbers to render "
            "(default: 35,36,37,38,39,40,41,42)"
        ),
    )
    ap.add_argument(
        "--include-device",
        action="store_true",
        help="Also render device/cell-internal layers 1-17 (very slow)",
    )
    ap.add_argument("--lef-dir", default=None,
                    help="Directory containing LEF files for macro sizes")
    ap.add_argument("--title", default=None, help="Figure title")
    ap.add_argument("--no-legend", action="store_true", help="Omit layer legend")
    args = ap.parse_args()

    run_dir = args.openlane_run_dir

    # ── Locate GDS and DEF ──────────────────────────────────────────────────
    gds_candidates = glob.glob(os.path.join(run_dir, "final", "gds", "*.gds"))
    if not gds_candidates:
        gds_candidates = glob.glob(os.path.join(run_dir, "**", "*.gds"),
                                   recursive=True)
    if not gds_candidates:
        print(f"ERROR: No .gds file found under {run_dir}", file=sys.stderr)
        sys.exit(1)
    gds_path = sorted(gds_candidates)[0]

    def_candidates = glob.glob(os.path.join(run_dir, "final", "def", "*.def"))
    if not def_candidates:
        def_candidates = glob.glob(os.path.join(run_dir, "**", "*.def"),
                                   recursive=True)
    if not def_candidates:
        print(f"ERROR: No .def file found under {run_dir}", file=sys.stderr)
        sys.exit(1)
    def_path = sorted(def_candidates)[0]

    print(f"GDS : {gds_path}")
    print(f"DEF : {def_path}")

    # ── Parse DEF ───────────────────────────────────────────────────────────
    print("Parsing DEF …")
    def_data = parse_def(def_path)
    if def_data["die"] is None:
        print("ERROR: Could not parse DIEAREA from DEF", file=sys.stderr)
        sys.exit(1)
    die_um = def_data["die"]
    die_w_um = die_um[2] - die_um[0]
    die_h_um = die_um[3] - die_um[1]
    print(f"  Die: {die_w_um:.1f} µm × {die_h_um:.1f} µm")
    print(f"  Macros: {len(def_data['macros'])}")
    print(f"  Rows: {len(def_data['rows'])}")

    # ── Layer selection ─────────────────────────────────────────────────────
    if args.layers:
        render_layers = [int(x) for x in args.layers.split(",")]
    else:
        render_layers = list(DEFAULT_LAYERS)
    if args.include_device:
        render_layers = DEVICE_LAYERS + render_layers

    # Remove duplicates, preserve order
    seen: set = set()
    render_layers = [l for l in render_layers if not (l in seen or seen.add(l))]

    print(f"Rendering layers: {render_layers}")

    # ── Load GDS ────────────────────────────────────────────────────────────
    print("Loading GDS …")
    try:
        import gdstk
    except ImportError:
        print("ERROR: gdstk not installed.  pip install gdstk", file=sys.stderr)
        sys.exit(1)

    lib = gdstk.read_gds(gds_path)
    top = lib.top_level()[0]
    gds_scale = _detect_gds_scale(lib, def_data["macros"])

    # ── Compute image size ──────────────────────────────────────────────────
    aspect = die_h_um / die_w_um
    if args.width_px:
        img_w = args.width_px
    else:
        # Target physical width in inches at the given DPI
        # Keep image roughly A4-portrait proportion
        target_w_in = min(10.0, 3000 / args.dpi)
        img_w = int(target_w_in * args.dpi)
    img_h = int(img_w * aspect)

    print(f"Output image: {img_w} × {img_h} px  ({img_w / args.dpi:.1f}\" × {img_h / args.dpi:.1f}\" at {args.dpi} DPI)")

    # ── Load polygons ────────────────────────────────────────────────────────
    print("Loading polygons …")
    layer_polys = load_layer_polygons(
        gds_path, render_layers, gds_scale, die_um, verbose=True
    )

    # ── Rasterise ────────────────────────────────────────────────────────────
    print("Rasterising …")
    img = rasterize_layers(layer_polys, die_um, img_w, img_h, render_layers)

    # ── Annotations ─────────────────────────────────────────────────────────
    print("Annotating …")
    macro_cells = list({m["cell"] for m in def_data["macros"]})
    lef_dir = args.lef_dir or os.path.join(
        os.path.dirname(run_dir), "lib", "openram"
    )
    macro_sizes = find_macro_sizes(lef_dir, macro_cells)

    title = args.title or os.path.basename(os.path.abspath(run_dir)).replace("_", " ")
    img = annotate(
        img, die_um, def_data, macro_sizes,
        title=title,
        render_layers=render_layers,
        show_legend=not args.no_legend,
    )

    # ── Save ─────────────────────────────────────────────────────────────────
    img.save(args.output_png, dpi=(args.dpi, args.dpi))
    print(f"Saved: {args.output_png}  ({os.path.getsize(args.output_png) // 1024} KB)")

if __name__ == "__main__":
    main()
