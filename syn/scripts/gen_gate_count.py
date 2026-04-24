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

def count_icg_dff_direct(
    modules: dict,
    lib_cells: Set[str],
) -> Dict[str, Tuple[int, int, int]]:
    """Return {clean_module_name: (icg_count, dff_count, sdff_count)} for direct cells only.

    ICG cells  : names containing 'CLKGATE' (CLKGATE_X1, CLKGATETST_X1, …)
    DFF cells  : names starting with 'DFF'  (DFF_X1, DFFR_X1, DFFS_X1, …)
    SDFF cells : names starting with 'SDFF' (SDFF_X1, SDFFR_X1, …) — scan FFs
    """
    result: Dict[str, Tuple[int, int, int]] = {}
    for raw_name, mod in modules.items():
        cname = clean_name(raw_name)
        icg = dff = sdff = 0
        for cell_type, cnt in mod.get("num_cells_by_type", {}).items():
            ct = clean_name(cell_type)
            if ct not in lib_cells:
                continue  # skip sub-module instances
            ctu = ct.upper()
            if "CLKGATE" in ctu:
                icg += int(cnt)
            elif ctu.startswith("SDFF"):
                sdff += int(cnt)
            elif ctu.startswith("DFF"):
                dff += int(cnt)
        result[cname] = (icg, dff, sdff)
    return result

def compute_inclusive_counts(
    mod: str,
    children: Dict[str, List[Tuple[str, int]]],
    direct_counts: Dict[str, Tuple[int, int, int]],
    cache: Dict[str, Tuple[int, int, int]],
) -> Tuple[int, int, int]:
    """Recursively sum ICG, DFF, and SDFF counts for mod and all its submodules."""
    if mod in cache:
        return cache[mod]
    icg, dff, sdff = direct_counts.get(mod, (0, 0, 0))
    for child, cnt in children.get(mod, []):
        c_icg, c_dff, c_sdff = compute_inclusive_counts(child, children, direct_counts, cache)
        icg  += c_icg  * cnt
        dff  += c_dff  * cnt
        sdff += c_sdff * cnt
    cache[mod] = (icg, dff, sdff)
    return (icg, dff, sdff)

def count_gated_dff_from_netlist(
    netlist_path: str,
) -> Dict[str, Tuple[int, int]]:
    """Parse a Yosys write_json netlist and return per-module gated/total DFF counts.

    For each module, identify DFF cells (DFF_X1, DFFR_X1, …) whose clock (CK)
    is driven by the GCK output of a CLKGATE_X1 / CLKGATETST_X1 cell.
    Returns {clean_module_name: (gated_dff_count, total_dff_count)}.
    """
    try:
        with open(netlist_path) as f:
            netlist = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"WARNING: cannot read netlist JSON: {exc}; falling back to ICG count",
              file=sys.stderr)
        return {}

    result: Dict[str, Tuple[int, int]] = {}
    for raw_mod, mod_data in netlist.get("modules", {}).items():
        cells = mod_data.get("cells", {})

        # Collect all signal IDs that come from a CLKGATE GCK output.
        gck_signals: Set[int] = set()
        for cell in cells.values():
            ctype = cell.get("type", "").upper()
            if "CLKGATE" in ctype:
                for sig in cell.get("connections", {}).get("GCK", []):
                    if isinstance(sig, int):
                        gck_signals.add(sig)

        gated = 0
        total = 0
        for cell in cells.values():
            ctype = cell.get("type", "").upper()
            # Match DFF_X1, DFFR_X1, DFFS_X1 but not SDFF_X1 / CLKGATE_X1
            if not (ctype.startswith("DFF") and not ctype.startswith("SDFF")):
                continue
            total += 1
            ck_sigs = cell.get("connections", {}).get("CK", [])
            if any(isinstance(s, int) and s in gck_signals for s in ck_sigs):
                gated += 1

        cname = clean_name(raw_mod)
        result[cname] = (gated, total)
    return result

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Report NAND2-equivalent gate counts with module hierarchy."
    )
    ap.add_argument("stat_json",   help="Yosys stat.json from hierarchical synthesis")
    ap.add_argument("liberty_lib", help="Nangate liberty .lib file (for NAND2_X1 area)")
    ap.add_argument("--output", "-o", default=None,
                    help="Output file path (default: stdout)")
    ap.add_argument("--netlist", default=None,
                    help="Yosys write_json netlist (enables connectivity-based gated-FF counting)")
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

    # Optional netlist-based gated-DFF counts (connectivity analysis).
    # Populated after hierarchy is built (needs children + design_modules).
    netlist_cg_direct: Dict[str, Tuple[int, int]] = {}  # {module: (gated_dff, total_dff)} direct only
    if args.netlist:
        netlist_cg_direct = count_gated_dff_from_netlist(args.netlist)

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

    # ── compute inclusive ICG + DFF + SDFF counts ──────────────────────────
    direct_counts = count_icg_dff_direct(modules, lib_cells)
    count_cache: Dict[str, Tuple[int, int, int]] = {}
    for m in design_modules:
        compute_inclusive_counts(m, children, direct_counts, count_cache)

    # ── build inclusive netlist-based gated-DFF counts ───────────────────────
    netlist_cg: Dict[str, Tuple[int, int]] = {}   # inclusive

    def _inclusive_cg(mod: str) -> Tuple[int, int]:
        if mod in netlist_cg:
            return netlist_cg[mod]
        gated, total = netlist_cg_direct.get(mod, (0, 0))
        for child, cnt in children.get(mod, []):
            if child in design_modules:
                cg, ct = _inclusive_cg(child)
                gated += cg * cnt
                total += ct * cnt
        netlist_cg[mod] = (gated, total)
        return (gated, total)

    if netlist_cg_direct:
        for m in design_modules:
            _inclusive_cg(m)

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

    # ── Clock gating section (only when ICG cells are present) ───────────────
    total_icg = sum(count_cache.get(t, (0, 0, 0))[0] for t in top_modules)
    if total_icg > 0:
        use_netlist = bool(netlist_cg_direct)
        if use_netlist:
            method_note = "  Method   : connectivity analysis (gated FF = CK driven by CLKGATE GCK)"
        else:
            method_note = "  Method   : ICG cell count (fallback — no netlist provided)"
        lines += [
            "",
            SEP,
            "  Clock Gating Summary",
            "  ICG cell : CLKGATE_X1 / CLKGATETST_X1 (Nangate 45nm)",
            "  Gated%   = Gated_FFs / Total_FFs",
            method_note,
            SEP,
            "",
            f"  {'Module':<40}  {'Total FFs':>9}  {'Gated FFs':>9}  {'Gated%':>7}",
            f"  {'-'*40}  {'-'*9}  {'-'*9}  {'-'*7}",
        ]

        cg_visited: Set[str] = set()

        def add_cg_rows(mod: str, depth: int = 0) -> None:
            if mod in cg_visited:
                return
            cg_visited.add(mod)
            icg, dff, _sdff = count_cache.get(mod, (0, 0, 0))
            if use_netlist:
                gated, total_ff = netlist_cg.get(mod, (0, dff))
            else:
                # Fallback: old 1-ICG-per-bit era; ICG count == gated FF count
                gated    = icg
                total_ff = dff
            pct = (100.0 * gated / total_ff) if total_ff > 0 else 0.0
            indent = "  " * depth
            label  = indent + mod
            lines.append(
                f"  {label:<40}  {total_ff:>9,}  {gated:>9,}  {pct:>6.1f}%"
            )
            kids_sorted = sorted(
                children.get(mod, []),
                key=lambda kc: -cache.get(kc[0], 0.0),
            )
            for child, _ in kids_sorted:
                if child in design_modules:
                    add_cg_rows(child, depth + 1)

        for top in top_modules:
            add_cg_rows(top)

        if use_netlist:
            total_gated_all = sum(netlist_cg.get(t, (0, 0))[0] for t in top_modules)
            total_dff_all   = sum(netlist_cg.get(t, (0, 0))[1] for t in top_modules)
        else:
            total_gated_all = total_icg
            total_dff_all   = sum(count_cache.get(t, (0, 0, 0))[1] for t in top_modules)
        total_pct = (100.0 * total_gated_all / total_dff_all) if total_dff_all > 0 else 0.0
        lines += [
            f"  {'-'*40}  {'-'*9}  {'-'*9}  {'-'*7}",
            f"  {'TOTAL':<40}  {total_dff_all:>9,}  {total_gated_all:>9,}  {total_pct:>6.1f}%",
            SEP,
            "",
            "  Notes:",
            "    - Gated% = Gated_FFs / Total_FFs, where Gated_FFs = DFF cells whose",
            "      clock (CK) is driven by a CLKGATE_X1/CLKGATETST_X1 GCK output.",
            "    - Clock gating uses multi-bit techmap (clockgate_hier_map.v): one ICG",
            "      per logical register group ($dffe/$adffe before dfflegalize).",
            "    - FFs with async reset but NO enable stay as $_DFF_PN0_ → DFFR_X1;",
            "      no enable signal exists so a clock gate cannot be inserted.",
            SEP,
        ]

    # ── Scan coverage section (only when SDFF cells are present) ─────────────
    total_sdff = sum(count_cache.get(t, (0, 0, 0))[2] for t in top_modules)
    if total_sdff > 0:
        lines += [
            "",
            SEP,
            "  DFT Scan Coverage Summary",
            "  Scan cells : SDFF_X1 (no reset) / SDFFR_X1 (async reset)",
            "  Coverage%  = SDFF / (SDFF + DFF)  — per-module inclusive counts",
            SEP,
            "",
            f"  {'Module':<40}  {'All FFs':>7}  {'SDFF':>7}  {'DFF':>7}  {'Cover%':>7}",
            f"  {'-'*40}  {'-'*7}  {'-'*7}  {'-'*7}  {'-'*7}",
        ]

        sc_visited: Set[str] = set()

        def add_sc_rows(mod: str, depth: int = 0) -> None:
            if mod in sc_visited:
                return
            sc_visited.add(mod)
            _icg, dff, sdff = count_cache.get(mod, (0, 0, 0))
            total_ff = sdff + dff
            pct = (100.0 * sdff / total_ff) if total_ff > 0 else 0.0
            indent = "  " * depth
            label  = indent + mod
            lines.append(
                f"  {label:<40}  {total_ff:>7,}  {sdff:>7,}  {dff:>7,}  {pct:>6.1f}%"
            )
            kids_sorted = sorted(
                children.get(mod, []),
                key=lambda kc: -cache.get(kc[0], 0.0),
            )
            for child, _ in kids_sorted:
                if child in design_modules:
                    add_sc_rows(child, depth + 1)

        for top in top_modules:
            add_sc_rows(top)

        total_dff_noscan = sum(count_cache.get(t, (0, 0, 0))[1] for t in top_modules)
        total_all_ff     = total_sdff + total_dff_noscan
        total_cov        = (100.0 * total_sdff / total_all_ff) if total_all_ff > 0 else 0.0
        lines += [
            f"  {'-'*40}  {'-'*7}  {'-'*7}  {'-'*7}  {'-'*7}",
            f"  {'TOTAL':<40}  {total_all_ff:>7,}  {total_sdff:>7,}  {total_dff_noscan:>7,}  {total_cov:>6.1f}%",
            SEP,
            "",
            "  Notes:",
            "    - Coverage% = SDFF / (SDFF + DFF): fraction of FFs replaced by scan cells.",
            "    - SDFF_X1 maps $_DFF_P_ (ICG output FFs + direct enabled FFs).",
            "    - SDFFR_X1 maps $_DFF_PN0_ (active-low async-reset FFs).",
            "    - SI/SE are tied to 0 for area analysis; scan chain stitching",
            "      (connecting SI/Q) is performed by OpenROAD ScanInsert during P&R.",
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
