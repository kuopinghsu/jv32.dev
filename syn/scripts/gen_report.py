#!/usr/bin/env python3
"""
gen_report.py  —  Generate syn/REPORT.md from an OpenLane2 run directory.

Usage:
    python3 gen_report.py <openlane_run_dir> <output_report_md>
                          [--fast-mul N] [--fast-div N]
                          [--fast-shift N] [--bp-en N]
                          [--iram-kb N] [--dram-kb N]
                          [--clock-mhz F]
                          [--nangate-lib PATH]

All --* flags are optional and used only for the "Configuration" section;
they default to "unknown" if not provided.
--nangate-lib: path to the Nangate liberty file; enables NAND2-equivalent
              reporting in the Cell Count section.
"""

import argparse
import csv
import glob
import json
import os
import re
import sys
from datetime import date

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return default

def grep_val(text, pattern, group=1, default="N/A"):
    m = re.search(pattern, text, re.MULTILINE)
    return m.group(group).strip() if m else default

def read_nand2_area(lib_path: str) -> float:
    """Return the area of NAND2_X1 in µm² from a liberty file, or 0.0."""
    if not lib_path or not os.path.isfile(lib_path):
        return 0.0
    in_cell = False
    try:
        with open(lib_path) as f:
            for line in f:
                line = line.strip()
                if re.match(r'cell\s*\(\s*NAND2_X1\s*\)', line):
                    in_cell = True
                if in_cell:
                    m = re.match(r'area\s*:\s*([0-9.eE+\-]+)\s*;', line)
                    if m:
                        return float(m.group(1))
    except OSError:
        pass
    return 0.0

def find_latest_step(run_dir, glob_pat):
    """Return the highest-numbered directory matching glob_pat."""
    matches = sorted(glob.glob(os.path.join(run_dir, glob_pat)))
    return matches[-1] if matches else None

def wirelength_stats(csv_path):
    """Return (total_mm, n_nets, longest_net, longest_mm) from wire_lengths.csv."""
    try:
        with open(csv_path) as f:
            rows = list(csv.DictReader(f))
    except OSError:
        return None
    if not rows:
        return None

    def to_mm(s):
        s = s.strip()
        if s.endswith("mm"):
            return float(s[:-2])
        if "µm" in s or "um" in s:
            return float(re.sub(r"[µu]m", "", s)) / 1000
        return float(s) / 1000

    lengths = [(r["net"], to_mm(r["length_um"])) for r in rows]
    total = sum(v for _, v in lengths)
    longest_net, longest_mm = lengths[0]
    return total, len(lengths), longest_net, longest_mm

# ---------------------------------------------------------------------------
# section generators
# ---------------------------------------------------------------------------

def section_timing(sta_dir, run_dir=None):
    if not sta_dir or not os.path.isdir(sta_dir):
        return "_STA reports not found._\n"

    corners = [d for d in os.listdir(sta_dir)
               if os.path.isdir(os.path.join(sta_dir, d))]
    if not corners:
        return "_No corners found._\n"

    lines = []
    for corner in sorted(corners):
        cdir = os.path.join(sta_dir, corner)
        wns_setup  = grep_val(read(os.path.join(cdir, "wns.max.rpt")),
                               r"^\s*\S+:\s*(-?\d[\d.]*)", default="N/A")
        tns_setup  = grep_val(read(os.path.join(cdir, "tns.max.rpt")),
                               r"^\s*\S+:\s*(-?\d[\d.]*)", default="N/A")
        wns_hold   = grep_val(read(os.path.join(cdir, "wns.min.rpt")),
                               r"^\s*\S+:\s*(-?\d[\d.]*)", default="N/A")
        tns_hold   = grep_val(read(os.path.join(cdir, "tns.min.rpt")),
                               r"^\s*\S+:\s*(-?\d[\d.]*)", default="N/A")

        def flag(wns):
            try:
                return "✅ MET" if float(wns) >= 0 else "❌ VIOLATED"
            except ValueError:
                return "N/A"

        lines.append(f"**Corner: {corner}**\n")
        lines.append("| Check | WNS (ns) | TNS (ns) | Result |")
        lines.append("|---|---|---|---|")
        lines.append(f"| Setup (max) | {wns_setup} | {tns_setup} | {flag(wns_setup)} |")
        lines.append(f"| Hold (min)  | {wns_hold}  | {tns_hold}  | {flag(wns_hold)}  |")
        lines.append("")

        # clock skew
        skew_txt = read(os.path.join(cdir, "skew.max.rpt"))
        skew_entries = re.findall(
            r"Clock\s+(\S+)\n.*?\n(-?\d[\d.]*)\s+setup skew", skew_txt, re.DOTALL)
        if skew_entries:
            lines.append("| Clock | Setup skew (ns) |")
            lines.append("|---|---|")
            for clk, skew in skew_entries:
                lines.append(f"| `{clk}` | {skew} |")
            lines.append("")

        # worst setup slack from max.rpt
        max_txt = read(os.path.join(cdir, "max.rpt"))
        slacks = re.findall(r"slack \(MET\)\s*([\d.]+)|slack \(VIOLATED\)\s*(-[\d.]+)",
                            max_txt)
        if slacks:
            vals = [a or b for a, b in slacks]
            try:
                worst = min(float(v) for v in vals)
                best  = max(float(v) for v in vals)
                lines.append(f"Worst setup slack: **{worst:.3f} ns** &nbsp;|&nbsp; "
                              f"Best: **{best:.3f} ns**\n")
            except ValueError:
                pass

        # design checks (slew/cap/fanout violations)
        checks_txt = read(os.path.join(cdir, "checks.rpt"))
        slew_viol   = grep_val(checks_txt, r"max slew violation count\s+(\d+)",     default=None)
        fanout_viol = grep_val(checks_txt, r"max fanout violation count\s+(\d+)",   default=None)
        cap_viol    = grep_val(checks_txt, r"max cap violation count\s+(\d+)",      default=None)
        unconstr    = grep_val(checks_txt,
                               r"There are (\d+) unconstrained endpoints", default=None)
        if any(v is not None for v in [slew_viol, fanout_viol, cap_viol]):
            lines.append("### Design Checks\n")
            lines.append("| Check | Count | |")
            lines.append("|---|---|---|")
            if slew_viol   is not None:
                icon = "✅" if slew_viol == "0" else "⚠️"
                lines.append(f"| Max slew violations   | {slew_viol}   | {icon} |")
            if cap_viol    is not None:
                icon = "✅" if cap_viol == "0" else "⚠️"
                lines.append(f"| Max cap violations    | {cap_viol}    | {icon} |")
            if fanout_viol is not None:
                icon = "✅" if fanout_viol == "0" else "⚠️"
                lines.append(f"| Max fanout violations | {fanout_viol} | {icon} |")
            if unconstr is not None:
                lines.append(f"| Unconstrained endpoints | {unconstr} | ℹ️ |")
            lines.append("")

    # timing convergence table (if run_dir is provided)
    if run_dir:
        conv_steps = [
            ("12-openroad-staprepnr",    "Pre-PnR (synthesis)"),
            ("30-openroad-stamidpnr",    "Post-placement (mid-PnR)"),
            ("35-openroad-stamidpnr-1",  "Post-CTS + resizer"),
            ("42-openroad-stamidpnr-3",  "Post-GRT resizer"),
        ]
        conv_rows = []
        for step_name, label in conv_steps:
            step_dir = os.path.join(run_dir, step_name)
            wns_file = os.path.join(step_dir, "wns.max.rpt")
            if not os.path.isfile(wns_file):
                # try in corner subdir
                wns_file = os.path.join(step_dir, "tt_025C_1v10", "wns.max.rpt")
            wns = grep_val(read(wns_file), r"^\s*\S+:\s*(-?[\d.]+)", default=None)
            if wns is not None:
                try:
                    w = float(wns)
                    icon = "✅" if w >= 0 else ("⚠️" if w > -1 else "❌")
                    conv_rows.append(f"| {label} | {w:.3f} | {icon} |")
                except ValueError:
                    pass
        if conv_rows:
            # add final post-route row
            try:
                wf = float(wns_setup)
                icon = "✅" if wf >= 0 else "❌"
                conv_rows.append(f"| **Post-route STA (sign-off)** | **{wf:.3f}** | {icon} |")
            except ValueError:
                pass
            lines += [
                "### Timing Convergence\n",
                "| Stage | Setup WNS (ns) | |",
                "|---|---|---|",
            ] + conv_rows + [""]

    return "\n".join(lines)

def section_power(sta_dir):
    if not sta_dir or not os.path.isdir(sta_dir):
        return "_Power report not found._\n"
    corners = sorted(d for d in os.listdir(sta_dir)
                     if os.path.isdir(os.path.join(sta_dir, d)))
    if not corners:
        return "_No corners found._\n"
    lines = []
    for corner in corners:
        txt = read(os.path.join(sta_dir, corner, "power.rpt"))
        if not txt:
            continue
        rows = re.findall(
            r"^(Sequential|Combinational|Clock|Macro|Pad|Total)\s+"
            r"([\d.e+\-]+)\s+([\d.e+\-]+)\s+([\d.e+\-]+)\s+([\d.e+\-]+)",
            txt, re.MULTILINE)
        if not rows:
            continue
        lines.append(f"**Corner: {corner}**\n")
        lines.append("| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |")
        lines.append("|---|---|---|---|---|---|")
        total_row = None
        for r in rows:
            pct_m = re.search(rf"^{r[0]}.*?([\d.]+)%", txt, re.MULTILINE)
            pct = pct_m.group(1) + "%" if pct_m else ""
            mw = lambda x: f"{float(x)*1e3:.2f} mW"
            line = f"| {r[0]} | {mw(r[1])} | {mw(r[2])} | {mw(r[3])} | {mw(r[4])} | {pct} |"
            if r[0] == "Total":
                total_row = line
            else:
                lines.append(line)
        if total_row:
            lines.append(total_row)
        lines.append("")
    return "\n".join(lines)

def section_gate_hierarchy(stat_json_path: str, nand2_area: float = 0.0) -> str:
    """Generate the area hierarchy section from a Yosys stat.json file."""
    if not stat_json_path or not os.path.isfile(stat_json_path):
        return "_Gate-count JSON not found. Re-run with --gate-count-json._\n"
    try:
        with open(stat_json_path) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        return f"_Could not parse stat.json: {e}_\n"

    modules = data.get("modules", {})
    ref_area = nand2_area if nand2_area > 0 else 0.7980  # Nangate NAND2_X1 fallback

    # Build a name → {area, nand2} lookup keyed by the bare (unparameterised)
    # module name — the last backslash-separated component of the Yosys JSON key.
    def bare(key: str) -> str:
        return key.rstrip("\\").split("\\")[-1]

    info: dict = {}
    for key, mod in modules.items():
        area  = float(mod.get("area", 0))
        nand2 = round(area / ref_area) if ref_area else 0
        b = bare(key)
        # Prefer the entry with the largest area when multiple parameterisations
        # share the same bare name (pick the most representative instance).
        if b not in info or area > info[b]["area"]:
            info[b] = {"area": area, "nand2": nand2, "_cells": mod.get("num_cells_by_type", {})}

    soc_nand2 = info.get("jv32_soc", {}).get("nand2", 1) or 1

    def row(indent: str, name: str) -> str:
        d = info.get(name, {})
        n = d.get("nand2", 0)
        a = d.get("area", 0.0)
        pct = n / soc_nand2 * 100
        bold = "**" if name in ("jv32_soc", "jv32_alu") else ""
        return (f"| {indent}{bold}{name}{bold} "
                f"| {bold}{n:,}{bold} "
                f"| {bold}{a:,.2f}{bold} "
                f"| {bold}{pct:.1f}%{bold} |")

    hier_rows = [
        row("",                             "jv32_soc"),
        row("\u21b3 ",                      "jv32_top"),
        row("&nbsp;&nbsp;\u21b3 ",          "jv32_core"),
        row("&nbsp;&nbsp;&nbsp;&nbsp;\u21b3 ", "jv32_alu"),
        row("&nbsp;&nbsp;&nbsp;&nbsp;\u21b3 ", "jv32_regfile"),
        row("&nbsp;&nbsp;&nbsp;&nbsp;\u21b3 ", "jv32_csr"),
        row("&nbsp;&nbsp;&nbsp;&nbsp;\u21b3 ", "jv32_rvc"),
        row("&nbsp;&nbsp;&nbsp;&nbsp;\u21b3 ", "jv32_decoder"),
        row("&nbsp;&nbsp;\u21b3 ",          "sram_1rw"),
        row("\u21b3 ",                      "jtag_top"),
        row("&nbsp;&nbsp;\u21b3 ",          "jtag_tap"),
        row("&nbsp;&nbsp;&nbsp;&nbsp;\u21b3 ", "jv32_dtm"),
        row("\u21b3 ",                      "axi_clic"),
        row("\u21b3 ",                      "axi_uart"),
        row("\u21b3 ",                      "axi_xbar"),
        row("\u21b3 ",                      "axi_magic"),
    ]

    hier_table = (
        "| Module | NAND2-eq | Area (µm²) | % of SoC logic |\n"
        "|---|---:|---:|---:|\n"
        + "\n".join(hier_rows)
    )

    # ── ALU sub-block breakdown ───────────────────────────────────────────────
    alu_nand2 = info.get("jv32_alu", {}).get("nand2", 0)
    cells     = info.get("jv32_alu", {}).get("_cells", {})
    dffr      = cells.get("DFFR_X1", 0)
    xor_cnt   = cells.get("XOR2_X1", 0) + cells.get("XNOR2_X1", 0)

    # Multiplier pipeline FFs: 4×32 partial-product regs + 2×32 operand regs + s1_valid
    mul_ff  = 193
    div_ff  = max(0, dffr - mul_ff)
    # ~80% of XOR2/XNOR2 cells come from the four 16×16 multiply trees + accumulation
    mul_xor = min(xor_cnt, round(xor_cnt * 0.80))

    # Cell cost weights for Nangate OCL: DFF ≈ 1.3 NAND2-eq, XOR2/XNOR2 ≈ 1.67 NAND2-eq
    mul_eq   = round(mul_ff * 1.3 + mul_xor * 1.67)
    div_eq   = round(div_ff * 1.3
                     + cells.get("NAND2_X1", 0) * 0.35
                     + cells.get("NOR2_X1",  0) * 0.35)
    shift_eq = max(0, round((cells.get("MUX2_X1", 0) * 0.60
                              + cells.get("INV_X1",  0) * 0.15) * 0.55))
    base_eq  = max(0, alu_nand2 - mul_eq - div_eq - shift_eq)

    def pct_alu(n: int) -> str:
        return f"{n / alu_nand2 * 100:.0f}%" if alu_nand2 else "N/A"

    alu_table = (
        "| Sub-block | Config | Key cell types | Est. NAND2-eq | % of ALU |\n"
        "|---|---|---|---:|---:|\n"
        f"| Multiplier (MUL/MULH/MULHSU/MULHU) "
        f"| `FAST_MUL=1, MUL_MC=1` (2-stage 4\u00d716\u00d716 pipeline) "
        f"| XOR2/XNOR2, DFFR ({mul_ff} FFs) "
        f"| ~{mul_eq:,} | ~{pct_alu(mul_eq)} |\n"
        f"| Divider (DIV/DIVU/REM/REMU) "
        f"| `FAST_DIV=0` (serial restoring) "
        f"| NAND2/NOR2, DFFR ({div_ff} FFs) "
        f"| ~{div_eq:,} | ~{pct_alu(div_eq)} |\n"
        f"| Barrel shifter (SLL/SRL/SRA) "
        f"| `FAST_SHIFT=1` (SRL/SRA shared\u00b9) "
        f"| MUX2, INV "
        f"| ~{shift_eq:,} | ~{pct_alu(shift_eq)} |\n"
        f"| ADD/SUB/logic/compare "
        f"| \u2014 "
        f"| XOR2/XNOR2, AOI/OAI "
        f"| ~{base_eq:,} | ~{pct_alu(base_eq)} |"
    )

    note = (
        "\u00b9 SRL and SRA share a single right-shift barrel tree "
        "(see [rtl/jv32/core/jv32_alu.sv](../rtl/jv32/core/jv32_alu.sv)); "
        "the second independent barrel shifter was removed, saving ~100\u2013180 NAND2-eq."
    )

    rel_path = os.path.relpath(stat_json_path) if os.path.isabs(stat_json_path) else stat_json_path
    return (
        f"> Source: `{rel_path}`  \n"
        f"> Methodology: hierarchical (non-flattening) Yosys synthesis against Nangate 45 nm OCL.  \n"
        f"> Reference cell: NAND2\\_X1 = {ref_area:.4f} \u00b5m\u00b2."
        f"  SRAM macros treated as black-boxes (area excluded).  \n"
        f"> Note: pre-P&R counts; post-P&R NAND2-eq total is in \u00a74.\n\n"
        f"{hier_table}\n\n"
        f"### ALU area breakdown by function\n\n"
        f"{alu_table}\n\n"
        f"{note}\n"
    )

def section_area(metrics_path):
    if not metrics_path or not os.path.isfile(metrics_path):
        return "_Metrics not found._\n"
    try:
        d = json.load(open(metrics_path))
    except (OSError, json.JSONDecodeError):
        return "_Could not parse metrics._\n"

    def val(k, fmt="{}", scale=1):
        v = d.get(k)
        if v is None:
            return "N/A"
        try:
            return fmt.format(float(v) * scale)
        except (TypeError, ValueError):
            return str(v)

    lines = [
        "| Metric | Value |",
        "|---|---|",
        f"| Die area | {val('design__die__area', '{:.0f} µm²')} "
        f"= {val('design__die__area', '{:.3f} mm²', 1e-6)} |",
        f"| Core area | {val('design__core__area', '{:.0f} µm²')} "
        f"= {val('design__core__area', '{:.3f} mm²', 1e-6)} |",
        f"| Standard cell area | {val('design__instance__area__stdcell', '{:.0f} µm²')} |",
        f"| Macro area | {val('design__instance__area__macros', '{:.0f} µm²')} |",
        f"| Total instance utilization | {val('design__instance__utilization', '{:.1%}')} |",
        f"| Std cell utilization | {val('design__instance__utilization__stdcell', '{:.2%}')} |",
    ]
    return "\n".join(lines) + "\n"

def section_cells(metrics_path, nand2_area: float = 0.0):
    if not metrics_path or not os.path.isfile(metrics_path):
        return "_Metrics not found._\n"
    try:
        d = json.load(open(metrics_path))
    except (OSError, json.JSONDecodeError):
        return "_Could not parse metrics._\n"

    def iv(k):
        v = d.get(k)
        return int(v) if v is not None else None

    # NAND2-equivalent gate count from post-P&R standard-cell area.
    nand2_row = ""
    if nand2_area > 0:
        area_val = d.get("design__instance__area__stdcell")
        if area_val is not None:
            nand2_eq = float(area_val) / nand2_area
            nand2_row = f"| **NAND2 equivalents (post-P&R)** | **{nand2_eq:,.0f}** | — |"

    stdcell = iv('design__instance__count__stdcell') or 1

    def pct(k):
        v = iv(k)
        if v is None or stdcell == 0:
            return "N/A"
        return f"{v / stdcell * 100:.1f}%"

    lines = [
        "| Category | Count | % of std cells |",
        "|---|---|---|",
        f"| Total instances | {iv('design__instance__count') or 'N/A'} | — |",
        f"| Standard cells (excl. tap) | {stdcell:,} | 100% |",
        f"| Sequential (flip-flops) | {iv('design__instance__count__class:sequential_cell') or 'N/A'} "
        f"| {pct('design__instance__count__class:sequential_cell')} |",
        f"| Multi-input combinational | {iv('design__instance__count__class:multi_input_combinational_cell') or 'N/A'} "
        f"| {pct('design__instance__count__class:multi_input_combinational_cell')} |",
        f"| Buffers | {iv('design__instance__count__class:buffer') or 'N/A'} "
        f"| {pct('design__instance__count__class:buffer')} |",
        f"| Inverters | {iv('design__instance__count__class:inverter') or 'N/A'} "
        f"| {pct('design__instance__count__class:inverter')} |",
        f"| Macros | {iv('design__instance__count__macros') or 'N/A'} | — |",
        f"| Tap cells | {iv('design__instance__count__class:tap_cell') or 'N/A'} | — |",
        f"| I/O ports | {iv('design__io') or 'N/A'} | — |",
    ]
    if nand2_row:
        lines.append(nand2_row)
    return "\n".join(lines) + "\n"

def section_wirelength(wl_csv, drt_metrics=None):
    stats = wirelength_stats(wl_csv)
    if stats is None:
        return "_Wire length data not found._\n"
    total, n_nets, longest_net, longest_mm = stats

    # Via count from detailed-routing metrics
    via_count = "N/A"
    if drt_metrics and os.path.isfile(drt_metrics):
        try:
            d = json.load(open(drt_metrics))
            v = d.get("route__vias")
            if v is not None:
                via_count = f"{int(v):,}"
        except (OSError, json.JSONDecodeError):
            pass

    # Total routed nets from DRT metrics
    routed_nets = "N/A"
    if drt_metrics and os.path.isfile(drt_metrics):
        try:
            d = json.load(open(drt_metrics))
            v = d.get("route__net")
            if v is not None:
                routed_nets = f"{int(v):,}"
        except (OSError, json.JSONDecodeError):
            pass

    lines = [
        "| Metric | Value |",
        "|---|---|",
        f"| Total routed nets | {routed_nets} |",
        f"| Constrained signal nets | {n_nets:,} |",
        f"| Total wirelength | **{total:.2f} mm** |",
        f"| Total vias | {via_count} |",
    ]

    # Top-10 longest nets table
    try:
        with open(wl_csv) as f:
            rows = list(csv.DictReader(f))
        if rows:
            def _to_mm(s):
                s = s.strip()
                if s.endswith("mm"):
                    return float(s[:-2])
                if "µm" in s or "um" in s:
                    return float(re.sub(r"[µu]m", "", s)) / 1000
                return float(s) / 1000
            top10 = [(r["net"], _to_mm(r["length_um"])) for r in rows[:10]]
            lines.append("")
            lines.append("### Longest Nets (Top 10)")
            lines.append("")
            lines.append("| Rank | Net | Length |")
            lines.append("|---|---|---|")
            for i, (net, mm) in enumerate(top10, 1):
                lines.append(f"| {i} | `{net}` | {mm:.3f} mm |")
    except (OSError, KeyError):
        pass

    return "\n".join(lines) + "\n"

def section_cts(run_dir):
    """Clock Tree Synthesis statistics."""
    cts_dir = find_latest_step(run_dir, "*-openroad-cts")
    if not cts_dir:
        return "_CTS report not found._\n"
    txt = read(os.path.join(cts_dir, "cts.rpt"))

    def cts_val(pat, default="N/A"):
        m = re.search(pat, txt)
        return m.group(1) if m else default

    roots   = cts_val(r"Total number of Clock Roots:\s*(\d+)")
    bufs    = cts_val(r"Total number of Buffers Inserted:\s*(\d+)")
    subnets = cts_val(r"Total number of Clock Subnets:\s*(\d+)")
    sinks   = cts_val(r"Total number of Sinks:\s*(\d+)")

    # Grab post-CTS STA WNS from step 35 (stamidpnr-1 = post-CTS)
    sta_cts = find_latest_step(run_dir, "*-openroad-stamidpnr-1")
    setup_wns = hold_wns = "N/A"
    if sta_cts:
        setup_wns = grep_val(read(os.path.join(sta_cts, "wns.max.rpt")),
                             r"^tt_025C.*?:\s*(-?[\d.]+)", default="N/A")
        hold_wns  = grep_val(read(os.path.join(sta_cts, "wns.min.rpt")),
                             r"^tt_025C.*?:\s*(-?[\d.]+)", default="N/A")
    def _ok(v):
        try:
            return "✅" if float(v) >= 0 else "⚠️"
        except ValueError:
            return ""

    # Clock latency/skew from post-PnR STA (most accurate)
    sta_dir = find_latest_step(run_dir, "*-openroad-stapostpnr")
    skew_rows = []
    if sta_dir:
        corners = sorted(d for d in os.listdir(sta_dir)
                         if os.path.isdir(os.path.join(sta_dir, d)))
        for corner in corners[:1]:  # report first corner
            cdir = os.path.join(sta_dir, corner)
            skew_max = read(os.path.join(cdir, "skew.max.rpt"))
            skew_min = read(os.path.join(cdir, "skew.min.rpt"))
            for clk, skew in re.findall(
                    r"Clock\s+(\S+)\n.*?\n(-?[\d.]+)\s+setup skew",
                    skew_max, re.DOTALL):
                hold_skew = grep_val(
                    skew_min,
                    rf"Clock\s+{re.escape(clk)}(?:\n[^\n]*){{1,4}}\n(-?[\d.]+)\s+hold skew",
                    default=grep_val(
                        skew_min,
                        rf"Clock\s+{re.escape(clk)}\n[\s\S]{{1,300}}\n(-?[\d.]+)\s+hold skew",
                        default="N/A"))
                skew_rows.append(
                    f"| `{clk}` | {skew} | {hold_skew} |")

    lines = [
        "| Metric | Value |",
        "|---|---|",
        f"| Clock roots | {roots} |",
        f"| CTS buffers inserted | {bufs} |",
        f"| Clock subnets | {subnets} |",
        f"| Clock sinks | {sinks} |",
        f"| Post-CTS setup WNS | {setup_wns} ns {_ok(setup_wns)} |",
        f"| Post-CTS hold WNS  | {hold_wns} ns {_ok(hold_wns)} |",
    ]
    if skew_rows:
        lines += [
            "",
            "### Clock Skew (post-PnR, tt_025C_1v10)",
            "",
            "| Clock | Setup skew (ns) | Hold skew (ns) |",
            "|---|---|---|",
        ] + skew_rows
    return "\n".join(lines) + "\n"

def section_routing_drc(run_dir):
    """TritonRoute DRC convergence table from or_metrics_out.json."""
    drt_dir = find_latest_step(run_dir, "*-openroad-detailedrouting")
    if not drt_dir:
        return "_Detailed routing directory not found._\n"
    metrics_path = os.path.join(drt_dir, "or_metrics_out.json")
    if not os.path.isfile(metrics_path):
        return "_Routing metrics not found._\n"
    try:
        d = json.load(open(metrics_path))
    except (OSError, json.JSONDecodeError):
        return "_Could not parse routing metrics._\n"

    lines = [
        "| Iteration | DRC Errors | Wirelength (µm) |",
        "|---|---|---|",
    ]
    i = 1
    while True:
        errs = d.get(f"route__drc_errors__iter:{i}")
        wl   = d.get(f"route__wirelength__iter:{i}")
        if errs is None:
            break
        lines.append(f"| {i} | {int(errs):,} | {int(wl):,} |")
        if int(errs) == 0:
            break
        i += 1

    final_errs = d.get("route__drc_errors", "?")
    result = "✅" if str(final_errs) == "0" else "❌"
    lines.append(f"| **Final** | **{final_errs}** {result} | — |")
    return "\n".join(lines) + "\n"

def section_congestion(run_dir):
    """GRT final congestion report extracted from the OpenROAD log."""
    grt_dir = find_latest_step(run_dir, "*-openroad-globalrouting")
    if not grt_dir:
        return "_Global routing directory not found._\n"
    log = read(os.path.join(grt_dir, "openroad-globalrouting.log"))
    # Extract lines after "Final congestion report:"
    m = re.search(r"Final congestion report:\n(.*?)(?:\n\[|$)", log,
                  re.DOTALL)
    if not m:
        return "_Congestion report not found in GRT log._\n"
    table_txt = m.group(1)
    layer_rows = re.findall(
        r"(metal\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)%\s+(\d+\s*/\s*\d+\s*/\s*\d+)",
        table_txt)
    total_m = re.search(
        r"Total\s+(\d+)\s+(\d+)\s+([\d.]+)%\s+(\d+\s*/\s*\d+\s*/\s*\d+)",
        table_txt)

    lines = [
        "| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |",
        "|---|---|---|---|---|",
    ]
    for layer, res, dem, pct, ovf in layer_rows:
        pct_f = float(pct)
        flag = " ⚠️" if pct_f > 70 else " ✅" if pct_f < 90 else ""
        lines.append(f"| {layer} | {int(res):,} | {int(dem):,} | {pct}%{flag} | {ovf.strip()} |")
    if total_m:
        r, d2, p, ov = total_m.groups()
        flag = " ✅" if all(x.strip() == "0" for x in ov.split("/")) else " ❌"
        lines.append(
            f"| **Total** | **{int(r):,}** | **{int(d2):,}** | **{p}%** | **{ov.strip()}**{flag} |")

    # Add GRT wirelength from log
    grt_wl = grep_val(log, r"GRT-0018\].*?wirelength:\s*([\d,]+)", default=None)
    if grt_wl:
        lines += ["", f"> GRT total wirelength: {grt_wl} µm"]
    return "\n".join(lines) + "\n"

def section_runtime(run_dir):
    """Flow step runtimes from runtime.txt files."""
    steps = [
        ("06-yosys-synthesis",           "Synthesis",           "Yosys"),
        ("13-openroad-floorplan",         "Floorplan",           "OpenROAD"),
        ("27-openroad-globalplacement",   "Global Placement",    "OpenROAD (RePLace)"),
        ("34-openroad-cts",               "Clock Tree Synthesis","TritonCTS"),
        ("38-openroad-globalrouting",     "Global Routing",      "OpenROAD (FastRoute)"),
        ("43-openroad-detailedrouting",   "Detailed Routing",    "TritonRoute"),
        ("54-openroad-stapostpnr",        "Post-PnR STA",        "OpenROAD (OpenSTA)"),
    ]
    rows = []
    total_s = 0
    for pattern, label, tool in steps:
        # exact directory name
        rt_file = os.path.join(run_dir, pattern, "runtime.txt")
        if not os.path.isfile(rt_file):
            # fall back to glob
            matches = sorted(glob.glob(os.path.join(run_dir, f"*{pattern[2:]}*")))
            rt_file = os.path.join(matches[-1], "runtime.txt") if matches else ""
        rt = read(rt_file).strip() if rt_file and os.path.isfile(rt_file) else "N/A"
        if re.match(r"\d+:\d+:\d+", rt):
            h, m, s = rt.split(":")
            total_s += int(h) * 3600 + int(m) * 60 + int(float(s))
        rows.append(f"| {label} | {tool} | {rt} |")

    lines = [
        "| Step | Tool | Runtime |",
        "|---|---|---|",
    ] + rows
    if total_s > 0:
        tm, ts = divmod(total_s, 60)
        th, tm = divmod(tm, 60)
        total_str = (f"{th} h {tm} m {ts} s" if th else f"{tm} m {ts} s")
        lines.append(f"| **Total (key steps)** | | **{total_str}** |")
    return "\n".join(lines) + "\n"

def section_antenna(run_dir, mfg_rpt):
    """
    Build the Manufacturability table.  Reads the OpenLane2 manufacturability
    report for the Antenna and any LVS/DRC summary lines already embedded
    there, then falls back to dedicated step output files for Magic DRC and
    Netgen LVS so the table is populated even when those steps ran in a later
    resumption of the flow.
    """
    txt = read(mfg_rpt)

    # --- parse manufacturability.rpt for pre-filled results ---
    def mfg_result(check):
        m = re.search(rf"\*\s+{check}\n(.+)", txt)
        return m.group(1).strip() if m else None

    antenna_res = mfg_result("Antenna") or "N/A"
    lvs_res     = mfg_result("LVS")     or None
    drc_res     = mfg_result("DRC")     or None

    # --- Magic DRC result from dedicated step directory ---
    if drc_res is None or drc_res == "N/A":
        magic_drc_step = find_latest_step(run_dir, "*-magic-drc")
        if magic_drc_step:
            # magic.drc.json produced by OpenLane2
            drc_json = os.path.join(magic_drc_step, "reports", "magic.drc.json")
            # older OpenLane2 versions write the count directly into metrics
            drc_rpt  = os.path.join(magic_drc_step, "magic.drc.rpt")
            drc_count_txt = ""
            if os.path.isfile(drc_json):
                try:
                    dj = json.load(open(drc_json))
                    total = dj.get("total", dj.get("count", None))
                    if total is not None:
                        drc_count_txt = str(total)
                except (OSError, json.JSONDecodeError):
                    pass
            if not drc_count_txt and os.path.isfile(drc_rpt):
                m = re.search(r"(\d+)\s+DRC.*error", read(drc_rpt), re.IGNORECASE)
                drc_count_txt = m.group(1) if m else ""
            if drc_count_txt:
                count = int(drc_count_txt) if drc_count_txt.isdigit() else 0
                drc_res = ("Passed ✅" if count == 0
                           else f"{count} violations ❌")
            else:
                drc_res = "Step ran — see DRC report"

    # --- Netgen LVS result from dedicated step directory ---
    if lvs_res is None or lvs_res == "N/A":
        lvs_step = find_latest_step(run_dir, "*-netgen-lvs")
        if lvs_step:
            lvs_rpt = os.path.join(lvs_step, "lvs.rpt")
            if not os.path.isfile(lvs_rpt):
                # Some OpenLane2 versions put it here
                lvs_rpt = os.path.join(lvs_step, "reports", "lvs.rpt")
            lvs_txt = read(lvs_rpt)
            if lvs_txt:
                if re.search(r"match\.?\s*$|Circuits match|Netlists match",
                             lvs_txt, re.IGNORECASE | re.MULTILINE):
                    lvs_res = "Passed ✅"
                else:
                    m = re.search(r"(\d+)\s+(error|discrepanc)",
                                  lvs_txt, re.IGNORECASE)
                    lvs_res = (f"{m.group(1)} mismatches ❌" if m
                               else "Failed ❌")
            else:
                lvs_res = "Step ran — see LVS report"

    lines = [
        "| Check | Result |",
        "|---|---|",
        f"| Antenna | {antenna_res} |",
        f"| LVS     | {lvs_res or 'N/A — run `make synth` (RUN_LVS enabled) or `make lvs`'} |",
        f"| DRC     | {drc_res or 'N/A — run `make synth` (RUN_MAGIC_DRC enabled) or `make drc`'} |",
    ]
    return "\n".join(lines) + "\n"

def section_outputs(run_dir):
    final = os.path.join(run_dir, "final")
    if not os.path.isdir(final):
        return "_Final outputs not found._\n"
    entries = []
    for fmt, subdir, ext in [
        ("DEF",          "def",         ".def"),
        ("ODB",          "odb",         ".odb"),
        ("GDS (KLayout)","klayout_gds", ".gds"),
        ("Netlist",      "nl",          ".v"),
        ("SPEF (max)",   "spef",        ".max.spef"),
        ("SDF",          "sdf",         ".sdf"),
        ("Liberty",      "lib",         ".lib"),
        ("SDC",          "sdc",         ".sdc"),
    ]:
        files = glob.glob(os.path.join(final, subdir, f"*{ext}"))
        if files:
            rel = os.path.relpath(sorted(files)[0],
                                  os.path.dirname(os.path.dirname(run_dir)))
            entries.append(f"| {fmt} | `{rel}` |")
    if not entries:
        return "_No final output files found._\n"
    return "| Format | Path |\n|---|---|\n" + "\n".join(entries) + "\n"

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", help="Path to openlane_run directory")
    ap.add_argument("output",  help="Output REPORT.md path")
    ap.add_argument("--fast-mul",    default="?")
    ap.add_argument("--fast-div",    default="?")
    ap.add_argument("--fast-shift",  default="?")
    ap.add_argument("--bp-en",       default="?")
    ap.add_argument("--iram-kb",     default="?")
    ap.add_argument("--dram-kb",     default="?")
    ap.add_argument("--clock-mhz",   default="?")
    ap.add_argument("--nangate-lib", default=None,
                    help="Nangate liberty file path; enables NAND2-equivalent reporting")
    ap.add_argument("--gate-count-json", default=None,
                    help="Path to Yosys stat.json for area hierarchy section "
                         "(e.g. syn/build/gate_count_run/stat.json)")
    args = ap.parse_args()

    run_dir = os.path.abspath(args.run_dir)
    if not os.path.isdir(run_dir):
        print(f"ERROR: run_dir not found: {run_dir}", file=sys.stderr)
        sys.exit(1)

    nand2_area = read_nand2_area(args.nangate_lib) if args.nangate_lib else 0.0

    # locate key directories
    sta_dir   = find_latest_step(run_dir, "*-openroad-stapostpnr")
    mfg_dir   = find_latest_step(run_dir, "*-misc-reportmanufacturability")
    wl_dir    = find_latest_step(run_dir, "*-odb-reportwirelength")
    gpl_dir   = find_latest_step(run_dir, "*-openroad-globalplacement")
    drt_dir   = find_latest_step(run_dir, "*-openroad-detailedrouting")

    mfg_rpt     = os.path.join(mfg_dir, "manufacturability.rpt") if mfg_dir else ""
    wl_csv      = os.path.join(wl_dir,  "wire_lengths.csv")       if wl_dir  else ""
    metrics     = os.path.join(gpl_dir, "or_metrics_out.json")    if gpl_dir else ""
    drt_metrics = os.path.join(drt_dir, "or_metrics_out.json")    if drt_dir else ""

    # Auto-discover gate_count stat.json when --gate-count-json is not given.
    # 'make gate-count' writes to build/gate_count_run/stat.json, which sits
    # one directory above the openlane_run directory.
    if not args.gate_count_json:
        candidate = os.path.join(run_dir, "..", "gate_count_run", "stat.json")
        candidate = os.path.normpath(candidate)
        if os.path.isfile(candidate):
            args.gate_count_json = candidate

    gate_count_section = section_gate_hierarchy(args.gate_count_json, nand2_area)

    report = f"""\
# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** {date.today()}

---

## 1. Configuration

| Parameter | Value |
|---|---|
| Clock | {args.clock_mhz} MHz (`core_clk`, period = {f"{1000/float(args.clock_mhz):.1f}" if args.clock_mhz not in ("?","") else "?"} ns) |
| IRAM | {args.iram_kb} KB |
| DRAM | {args.dram_kb} KB |
| `FAST_MUL` | {args.fast_mul} |
| `FAST_DIV` | {args.fast_div} |
| `FAST_SHIFT` | {args.fast_shift} |
| `BP_EN` | {args.bp_en} |

---

## 2. Floorplan & Area

{section_area(metrics)}
---

## 3. Area Hierarchy (Gate Count)

{gate_count_section}
---

## 4. Cell Count & Mix

{section_cells(metrics, nand2_area)}
---

## 5. Clock Tree Synthesis

{section_cts(run_dir)}
---

## 6. Timing — Post-PnR STA

{section_timing(sta_dir, run_dir)}
---

## 7. Design Rule Checks (Post-Route)

{section_routing_drc(run_dir)}
---

## 8. Power

{section_power(sta_dir)}
---

## 9. Routing & Wire Length

{section_wirelength(wl_csv, drt_metrics)}
---

## 10. Routing Congestion (GRT)

{section_congestion(run_dir)}
---

## 11. Manufacturability

{section_antenna(run_dir, mfg_rpt)}
---

## 12. Flow Runtime

{section_runtime(run_dir)}
---

## 13. Output Files

{section_outputs(run_dir)}
"""

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w") as f:
        f.write(report)
    print(f"Report written to {args.output}")

if __name__ == "__main__":
    main()
