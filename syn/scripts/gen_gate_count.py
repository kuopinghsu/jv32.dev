#!/usr/bin/env python3
"""
gen_gate_count.py — Report NAND2-equivalent gate counts with module hierarchy.

Parses the Yosys stat.json produced by a hierarchical (non-flattening)
OpenLane2 synthesis pass and reports per-module gate counts in NAND2-
equivalent units with a full hierarchy breakdown.

Usage:
    gen_gate_count.py <stat_json> <liberty_lib> [--output <rpt>]

Positional arguments:
    stat_json     Path to Yosys stat.json (from hierarchical synthesis).
    liberty_lib   Path to Nangate liberty file (to obtain NAND2_X1 area).

Options:
    --output RPT  Write report to RPT instead of stdout.
"""

import argparse
import json
import os
import re
import sys
from typing import Dict, List, Set, Tuple

def read_cell_areas(lib_path: str) -> Dict[str, float]:
    """Return {cell_name: area_um2} parsed from a liberty .lib file."""
    areas: Dict[str, float] = {}
    current_cell = None
    try:
        with open(lib_path) as f:
            for line in f:
                line = line.strip()
                m = re.match(r'cell\s*\(\s*(\w+)\s*\)', line)
                if m:
                    current_cell = m.group(1)
                m = re.match(r'area\s*:\s*([0-9.eE+\-]+)\s*;', line)
                if m and current_cell:
                    areas[current_cell] = float(m.group(1))
                    current_cell = None   # consume — one area per cell
    except OSError as exc:
        print(f"ERROR: cannot read liberty file: {exc}", file=sys.stderr)
        sys.exit(1)
    return areas

def clean_name(raw: str) -> str:
    """Strip Yosys module-name decorations.

    Examples::
        \\jv32_soc                               → jv32_soc
        $paramod$7932...\\jv32_top               → jv32_top
        $paramod\\jv32_rvc\\RVM23_EN=1'1         → jv32_rvc
    """
    name = raw.lstrip("\\")
    if name.startswith("$paramod"):
        parts = name.split("\\")
        if len(parts) >= 2:
            return parts[1]
    return name

def build_hierarchy(
    modules: dict,
    lib_cells: Set[str],
) -> Tuple[Dict[str, List[Tuple[str, int]]], Dict[str, float]]:
    """Return (children, direct_area) for all design modules.

    children[clean_name]    = [(child_clean_name, instance_count), ...]
    direct_area[clean_name] = µm² of directly-instantiated std cells only
    """
    children: Dict[str, List[Tuple[str, int]]] = {}
    direct_area: Dict[str, float] = {}

    for raw_name, mod in modules.items():
        cname = clean_name(raw_name)
        direct_area[cname] = mod.get("area", 0.0)

        kids: List[Tuple[str, int]] = []
        for cell_type, count in mod.get("num_cells_by_type", {}).items():
            ct_clean = clean_name(cell_type)
            # Submodule instances are NOT library cells.
            if ct_clean not in lib_cells:
                kids.append((ct_clean, int(count)))
        children[cname] = kids

    return children, direct_area

def compute_inclusive(
    mod: str,
    children: Dict[str, List[Tuple[str, int]]],
    direct_area: Dict[str, float],
    cache: Dict[str, float],
) -> float:
    """Recursively sum the area of std cells in mod and all its submodules."""
    if mod in cache:
        return cache[mod]
    area = direct_area.get(mod, 0.0)
    for child, cnt in children.get(mod, []):
        area += compute_inclusive(child, children, direct_area, cache) * cnt
    cache[mod] = area
    return area

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Report NAND2-equivalent gate counts with module hierarchy."
    )
    ap.add_argument("stat_json",   help="Yosys stat.json from hierarchical synthesis")
    ap.add_argument("liberty_lib", help="Nangate liberty .lib file (for NAND2_X1 area)")
    ap.add_argument("--output", "-o", default=None,
                    help="Output file path (default: stdout)")
    args = ap.parse_args()

    # ── load data ────────────────────────────────────────────────────────────
    try:
        with open(args.stat_json) as f:
            stat = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: cannot read stat.json: {exc}", file=sys.stderr)
        sys.exit(1)

    cell_areas = read_cell_areas(args.liberty_lib)
    nand2_area = cell_areas.get("NAND2_X1")
    if not nand2_area:
        print("ERROR: NAND2_X1 not found or has zero area in liberty file",
              file=sys.stderr)
        sys.exit(1)

    modules = stat.get("modules", {})
    lib_cells: Set[str] = set(cell_areas.keys())

    children, direct_area = build_hierarchy(modules, lib_cells)

    # Design modules = all modules minus pure standard-cell library modules.
    design_modules: Set[str] = {
        clean_name(m) for m in modules
        if clean_name(m) not in lib_cells
    }

    # Top-level modules = design modules that are not instantiated by any other.
    all_referenced: Set[str] = {
        child for kids in children.values() for child, _ in kids
    }
    top_modules = sorted(design_modules - all_referenced)

    # ── compute inclusive areas ──────────────────────────────────────────────
    cache: Dict[str, float] = {}
    for m in design_modules:
        compute_inclusive(m, children, direct_area, cache)

    # ── format report ────────────────────────────────────────────────────────
    SEP  = "=" * 74
    SEP2 = "-" * 74

    lines = [
        SEP,
        "  jv32_soc Gate Count Report — NAND2-equivalent units",
        "  Technology  : Nangate 45nm Open Cell Library (FreePDK45)",
        f"  NAND2_X1 area = {nand2_area:.4f} µm²  (reference cell for equivalence)",
        SEP,
        "",
        f"  {'Module':<46}  {'NAND2 eq':>9}  {'Area (µm²)':>12}",
        f"  {'-'*46}  {'-'*9}  {'-'*12}",
    ]

    visited: Set[str] = set()

    def add_rows(mod: str, depth: int = 0) -> None:
        if mod in visited:
            return
        visited.add(mod)

        inc  = cache.get(mod, 0.0)
        nand2 = inc / nand2_area
        indent = "  " * depth
        label  = indent + mod
        lines.append(
            f"  {label:<46}  {nand2:>9,.0f}  {inc:>12,.2f}"
        )
        # Recurse: children sorted by descending inclusive area (largest first)
        kids_sorted = sorted(
            children.get(mod, []),
            key=lambda kc: -cache.get(kc[0], 0.0),
        )
        for child, _ in kids_sorted:
            if child in design_modules:
                add_rows(child, depth + 1)

    for top in top_modules:
        add_rows(top)

    total_area  = sum(cache.get(t, 0.0) for t in top_modules)
    total_nand2 = total_area / nand2_area

    lines += [
        f"  {'-'*46}  {'-'*9}  {'-'*12}",
        f"  {'TOTAL (logic, excl. SRAM macros)':<46}  {total_nand2:>9,.0f}  {total_area:>12,.2f}",
        SEP,
        "",
        "  Notes:",
        "    - Gate counts use hierarchical (non-flattening) synthesis.",
        "    - Each module is optimised independently; cross-module sharing",
        "      (as in the main flat synthesis) may differ by ±5–10%.",
        "    - SRAM macros (sram_1rw_2048x32) are treated as black-boxes",
        "      and their area is not included in the NAND2 equivalent count.",
        SEP,
    ]

    report = "\n".join(lines)

    if args.output:
        os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
        with open(args.output, "w") as f:
            f.write(report + "\n")
        print(f"Gate count report: {args.output}")
    else:
        print(report)

if __name__ == "__main__":
    main()
