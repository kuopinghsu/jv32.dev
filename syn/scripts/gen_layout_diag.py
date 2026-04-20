#!/usr/bin/env python3
"""
gen_layout_diag.py — Generate a floorplan diagram with major module boundaries.

Parses the final DEF + SRAM LEF from an OpenLane2 run and renders a PNG showing:
  - Die and core outlines
  - SRAM macro blocks (IRAM / DRAM banks) with exact geometry
  - Standard-cell (logic) regions derived from DEF row extents
  - Hierarchy legend listing top-level SoC modules

Usage:
    python3 gen_layout_diag.py <openlane_run_dir> <output_png>
                               [--lef-dir <dir>]
                               [--title <string>]
"""

import argparse
import glob
import os
import re
import sys
from collections import defaultdict

# ---------------------------------------------------------------------------
# DEF / LEF parsers
# ---------------------------------------------------------------------------

def parse_def(def_path):
    """Return a dict with die_area, dbu_per_um, macros, rows."""
    result = {
        "dbu_per_um": 1000,
        "die": None,          # (x0, y0, x1, y1) in µm
        "macros": [],         # [{"name", "cell", "x", "y", "orient"}] in µm
        "rows": [],           # [{"x", "y", "width", "height"}] in µm
    }
    with open(def_path) as f:
        text = f.read()

    # UNITS DISTANCE MICRONS N
    m = re.search(r"UNITS DISTANCE MICRONS\s+(\d+)", text)
    if m:
        result["dbu_per_um"] = int(m.group(1))
    dbu = result["dbu_per_um"]

    # DIEAREA ( x0 y0 ) ( x1 y1 )
    m = re.search(r"DIEAREA\s+\(\s*(\d+)\s+(\d+)\s*\)\s+\(\s*(\d+)\s+(\d+)\s*\)", text)
    if m:
        result["die"] = tuple(int(v) / dbu for v in m.groups())

    # COMPONENTS: parse lines of the form
    #   - inst_name cell_name + [SOURCE ...+] PLACED|FIXED ( x y ) orient ;
    comp_pattern = re.compile(
        r"^\s+-\s+(\S+)\s+(\S+)\s+.*?(?:PLACED|FIXED)\s+\(\s*(\d+)\s+(\d+)\s*\)\s+(\w+)",
        re.MULTILINE,
    )
    for m in comp_pattern.finditer(text):
        inst, cell, x, y, orient = m.groups()
        result["macros"].append({
            "name": inst,
            "cell": cell,
            "x": int(x) / dbu,
            "y": int(y) / dbu,
            "orient": orient,
        })

    # ROW  name site x y orient DO n BY 1 STEP sx 0
    row_pattern = re.compile(
        r"^ROW\s+\S+\s+\S+\s+(\d+)\s+(\d+)\s+\S+\s+DO\s+(\d+)\s+BY\s+\d+\s+STEP\s+(\d+)",
        re.MULTILINE,
    )
    site_h_dbu = None
    for m in row_pattern.finditer(text):
        rx, ry, ncells, step = int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4))
        if site_h_dbu is None:
            # Infer row height from spacing between first two rows
            pass
        result["rows"].append({
            "x": rx / dbu,
            "y": ry / dbu,
            "width": ncells * step / dbu,
        })

    # Infer row height from row pitch (distance between consecutive rows)
    if len(result["rows"]) >= 2:
        ys = sorted({r["y"] for r in result["rows"]})
        pitches = [ys[i + 1] - ys[i] for i in range(min(10, len(ys) - 1))]
        pitches = [p for p in pitches if 0 < p < 10]
        if pitches:
            row_h = min(pitches)
            for r in result["rows"]:
                r["height"] = row_h
        else:
            for r in result["rows"]:
                r["height"] = 0.0028  # ~2.8 nm fallback
    else:
        for r in result["rows"]:
            r["height"] = 0.0028

    return result

def get_cell_size(lef_dir, cell_name):
    """Return (width, height) in µm for a given cell from LEF files in lef_dir."""
    if not lef_dir or not os.path.isdir(lef_dir):
        return None
    for lef_path in glob.glob(os.path.join(lef_dir, "**", "*.lef"), recursive=True):
        with open(lef_path) as f:
            text = f.read()
        pat = rf"MACRO\s+{re.escape(cell_name)}\b.*?SIZE\s+([\d.]+)\s+BY\s+([\d.]+)"
        m = re.search(pat, text, re.DOTALL)
        if m:
            return float(m.group(1)), float(m.group(2))
    return None

# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

def compute_row_region(rows):
    """Compute the bounding box of all standard-cell rows."""
    if not rows:
        return None
    xs = [r["x"] for r in rows]
    ys = [r["y"] for r in rows]
    xe = [r["x"] + r["width"] for r in rows]
    ye = [r["y"] + r.get("height", 0) for r in rows]
    return min(xs), min(ys), max(xe), max(ye)

def bbox_of_macros(macros, cell_sizes, die_h):
    """Return a dict mapping group_label → (x0, y0, x1, y1) in µm."""
    groups = defaultdict(list)   # group_label → list of (x0, y0, x1, y1)
    ungrouped = []

    for m in macros:
        cell = m["cell"]
        inst = m["name"]
        x, y = m["x"], m["y"]
        orient = m["orient"]

        # Skip standard filler/tap/antenna cells
        if any(t in cell.upper() for t in
               ("FILLER", "TAPCELL", "TAP_", "DECAP", "ANTENNA", "FILLCELL",
                "INV_", "AND", "OR_", "NAND", "NOR", "BUF", "DFF", "MUX",
                "AOI", "OAI", "FA_", "HA_", "XOR", "XNOR")):
            continue

        size = cell_sizes.get(cell)
        if size is None:
            continue
        w, h = size
        # Apply orientation (N=normal, S=180, E=90CW, W=90CCW, FN/FS/FE/FW=flipped)
        if orient in ("E", "W", "FE", "FW"):
            w, h = h, w

        x1, y1 = x + w, y + h

        # Group by hierarchy prefix
        # inst names look like: u_jv32.u_dram.g_tcm...g_bank\[0\].u_sub
        # strip escapes
        inst_clean = inst.replace("\\", "")
        parts = inst_clean.split(".")
        # Top module → first part
        top = parts[0] if parts else inst_clean
        # Classify
        if "dram" in inst_clean.lower() or "dram" in cell.lower():
            grp = "DRAM"
        elif "iram" in inst_clean.lower() or "iram" in cell.lower():
            grp = "IRAM"
        else:
            grp = top

        groups[grp].append((x, y, x1, y1))

    result = {}
    for grp, boxes in groups.items():
        x0 = min(b[0] for b in boxes)
        y0 = min(b[1] for b in boxes)
        x1 = max(b[2] for b in boxes)
        y1 = max(b[3] for b in boxes)
        result[grp] = (x0, y0, x1, y1)

    return result

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def render(def_data, macro_groups, cell_sizes, output_path, title):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import matplotlib.patches as mpatches
        from matplotlib.patches import FancyBboxPatch
    except ImportError:
        print("ERROR: matplotlib is required. Install it with:  pip install matplotlib",
              file=sys.stderr)
        sys.exit(1)

    die = def_data["die"]          # (x0, y0, x1, y1) µm
    if die is None:
        print("ERROR: could not parse DIEAREA from DEF", file=sys.stderr)
        sys.exit(1)

    die_w = die[2] - die[0]
    die_h = die[3] - die[1]

    # Compute row (logic) region
    row_bbox = compute_row_region(def_data["rows"])

    # ── Colour palette ──────────────────────────────────────────────────────
    COLORS = {
        "DRAM":  ("#4e79a7", "#d0e4f7"),   # (edge, face)
        "IRAM":  ("#f28e2b", "#fde8c8"),
        "logic": ("#59a14f", "#d6edce"),
        "die":   ("#333333", "#f5f5f5"),
        "core":  ("#888888", "none"),
    }

    MODULE_META = {
        "DRAM": "DRAM\n2 × 8 KB SRAM",
        "IRAM": "IRAM\n2 × 8 KB SRAM",
    }

    # Figure size: keep aspect ratio, max ~12 inches tall
    scale = 12.0 / die_h
    fig_w = max(6.0, die_w * scale + 4.0)   # extra width for legend
    fig_h = die_h * scale + 1.5

    fig, ax = plt.subplots(figsize=(fig_w, fig_h))

    def rect(x0, y0, w, h, edge, face, lw=1.5, ls="-", zorder=2, alpha=1.0, label=None):
        p = mpatches.FancyArrow   # unused, just for import check
        patch = mpatches.Rectangle(
            (x0, y0), w, h,
            linewidth=lw, edgecolor=edge, facecolor=face,
            linestyle=ls, zorder=zorder, alpha=alpha, label=label,
        )
        ax.add_patch(patch)
        return patch

    def label(x, y, txt, fontsize=8, ha="center", va="center",
              color="black", zorder=5, rotation=0, bold=False):
        weight = "bold" if bold else "normal"
        ax.text(x, y, txt, fontsize=fontsize, ha=ha, va=va,
                color=color, zorder=zorder, rotation=rotation,
                fontweight=weight,
                bbox=dict(boxstyle="round,pad=0.2", fc="white", ec="none", alpha=0.7))

    # ── Die outline ─────────────────────────────────────────────────────────
    rect(die[0], die[1], die_w, die_h,
         edge=COLORS["die"][0], face=COLORS["die"][1], lw=2.5, zorder=1)

    # ── Standard-cell logic area ─────────────────────────────────────────────
    if row_bbox:
        rx0, ry0, rx1, ry1 = row_bbox
        rect(rx0, ry0, rx1 - rx0, ry1 - ry0,
             edge=COLORS["logic"][0], face=COLORS["logic"][1],
             lw=1.0, ls="--", zorder=2, alpha=0.5)
        # Find rightmost macro X edge to avoid label overlap
        if macro_groups:
            macro_x_end = max(bb[2] for bb in macro_groups.values())
        else:
            macro_x_end = rx0
        # Place label in the right-most clear area
        lx = (macro_x_end + rx1) / 2
        ly = (ry0 + ry1) / 2
        lfs = max(6, int(8 * scale * die_h / 12))
        label(lx, ly,
              "SoC Logic\n(CPU · AXI · UART\n JTAG · CLIC)",
              fontsize=lfs,
              color=COLORS["logic"][0], bold=True, zorder=6)

    # ── SRAM macro blocks ─────────────────────────────────────────────────────
    legend_patches = []
    # Shade alternating banks slightly differently
    BANK_SHADES = {
        "DRAM": [("#4e79a7", "#c9dcee"), ("#4e79a7", "#a9c4e0")],
        "IRAM": [("#f28e2b", "#fde0b0"), ("#f28e2b", "#f8ca80")],
    }
    for grp in sorted(macro_groups.keys()):
        ec_base = COLORS.get(grp, ("#e15759", "#fbd4d4"))[0]
        meta = MODULE_META.get(grp, grp)

        # Find individual banks in this group
        bank_boxes = []
        for m in def_data["macros"]:
            if _macro_in_group(m["name"], grp):
                cs = cell_sizes.get(m["cell"])
                if cs:
                    bw, bh = cs
                    bank_boxes.append((m["x"], m["y"], m["x"] + bw, m["y"] + bh))

        shades = BANK_SHADES.get(grp, [(ec_base, "#fbd4d4")] * 4)
        lfs = max(6, int(7 * scale * die_h / 12))
        for i, (bx0, by0, bx1, by1) in enumerate(sorted(bank_boxes, key=lambda b: b[0])):
            ec, fc = shades[i % len(shades)]
            bw, bh = bx1 - bx0, by1 - by0
            rect(bx0, by0, bw, bh, edge=ec, face=fc, lw=2.0, zorder=4)
            bank_lbl = f"{grp}\nBank {i}"
            label((bx0 + bx1) / 2, (by0 + by1) / 2,
                  bank_lbl, fontsize=lfs, color=ec_base, bold=True, zorder=7,
                  rotation=90 if bh > bw * 1.5 else 0)

        ec0, fc0 = shades[0]
        patch = mpatches.Patch(facecolor=fc0, edgecolor=ec0, lw=2, label=meta)
        legend_patches.append(patch)

    # ── Dimension annotations ────────────────────────────────────────────────
    ax.annotate(
        "", xy=(die[2], die[1] - die_h * 0.02), xytext=(die[0], die[1] - die_h * 0.02),
        arrowprops=dict(arrowstyle="<->", color="black", lw=1.2),
    )
    ax.text((die[0] + die[2]) / 2, die[1] - die_h * 0.04,
            f"{die_w:.1f} µm", ha="center", va="top", fontsize=8)
    ax.annotate(
        "", xy=(die[2] + die_w * 0.02, die[3]), xytext=(die[2] + die_w * 0.02, die[1]),
        arrowprops=dict(arrowstyle="<->", color="black", lw=1.2),
    )
    ax.text(die[2] + die_w * 0.04, (die[1] + die[3]) / 2,
            f"{die_h:.1f} µm", ha="left", va="center", fontsize=8, rotation=-90)

    # ── Legend ───────────────────────────────────────────────────────────────
    logic_patch = mpatches.Patch(
        facecolor=COLORS["logic"][1], edgecolor=COLORS["logic"][0],
        lw=2, linestyle="--", label="SoC Logic\n(CPU · AXI · UART · JTAG · CLIC)"
    )
    legend_patches.insert(0, logic_patch)
    ax.legend(handles=legend_patches, loc="upper left",
              bbox_to_anchor=(1.01, 1.0), fontsize=8,
              title="Module Legend", title_fontsize=9,
              frameon=True, framealpha=0.9)

    # ── Axes cosmetics ───────────────────────────────────────────────────────
    margin_x = die_w * 0.08
    margin_y = die_h * 0.06
    ax.set_xlim(die[0] - margin_x, die[2] + margin_x + die_w * 0.02)
    ax.set_ylim(die[1] - margin_y, die[3] + margin_y)
    ax.set_aspect("equal")
    ax.set_xlabel("X (µm)", fontsize=9)
    ax.set_ylabel("Y (µm)", fontsize=9)
    ax.set_title(title, fontsize=11, fontweight="bold")
    ax.tick_params(labelsize=8)
    ax.grid(True, linestyle=":", linewidth=0.4, alpha=0.5)

    fig.tight_layout()
    fig.savefig(output_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"Layout diagram written to {output_path}")

def _macro_in_group(inst_name, grp):
    inst = inst_name.replace("\\", "").lower()
    if grp == "DRAM":
        return "u_dram" in inst or ".dram" in inst
    if grp == "IRAM":
        return "u_iram" in inst or ".iram" in inst
    return inst.startswith(grp.lower())

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", help="Path to openlane_run directory")
    ap.add_argument("output",  help="Output PNG path")
    ap.add_argument("--lef-dir", default=None,
                    help="Directory to search for LEF files (default: auto-detect)")
    ap.add_argument("--title", default="jv32_soc — Layout Floorplan",
                    help="Diagram title")
    args = ap.parse_args()

    run_dir = os.path.abspath(args.run_dir)
    if not os.path.isdir(run_dir):
        print(f"ERROR: run_dir not found: {run_dir}", file=sys.stderr)
        sys.exit(1)

    # Locate final DEF
    def_files = glob.glob(os.path.join(run_dir, "final", "def", "*.def"))
    if not def_files:
        print("ERROR: no DEF found in <run_dir>/final/def/", file=sys.stderr)
        sys.exit(1)
    def_path = def_files[0]
    print(f"Reading DEF: {def_path}")

    def_data = parse_def(def_path)
    print(f"  Die: {def_data['die'][2]:.1f} × {def_data['die'][3]:.1f} µm")
    print(f"  Components: {len(def_data['macros'])}")
    print(f"  Rows: {len(def_data['rows'])}")

    # Locate LEF files
    lef_dir = args.lef_dir
    if not lef_dir:
        # Default: search the run_dir ancestor for a lib/ directory
        candidates = [
            os.path.join(os.path.dirname(run_dir), "lib", "openram"),
            os.path.join(os.path.dirname(run_dir), "..", "lib", "openram"),
        ]
        for c in candidates:
            if os.path.isdir(c):
                lef_dir = c
                break

    # Build cell-size cache for known macro cells
    cell_sizes = {}
    if lef_dir:
        # Gather all unique cell names from placed macros
        cells_to_check = {m["cell"] for m in def_data["macros"]}
        for cell in cells_to_check:
            size = get_cell_size(lef_dir, cell)
            if size:
                cell_sizes[cell] = size
        print(f"  Cell sizes resolved from LEF: {len(cell_sizes)}")

    # Compute macro group bounding boxes
    macro_groups = bbox_of_macros(def_data["macros"], cell_sizes, def_data["die"][3])
    if macro_groups:
        print("  Macro groups found:")
        for grp, bb in sorted(macro_groups.items()):
            print(f"    {grp}: ({bb[0]:.1f}, {bb[1]:.1f}) → ({bb[2]:.1f}, {bb[3]:.1f}) µm")

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    render(def_data, macro_groups, cell_sizes, args.output, args.title)

if __name__ == "__main__":
    main()
