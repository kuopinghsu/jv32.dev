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

def section_timing(sta_dir):
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

        # critical-path slack
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
        return str(int(v)) if v is not None else "N/A"

    # NAND2-equivalent gate count from post-P&R standard-cell area.
    nand2_row = ""
    if nand2_area > 0:
        area_val = d.get("design__instance__area__stdcell")
        if area_val is not None:
            nand2_eq = float(area_val) / nand2_area
            nand2_row = f"| **NAND2 equivalents (post-P&R)** | **{nand2_eq:,.0f}** |"

    lines = [
        "| Category | Count |",
        "|---|---|",
        f"| Total instances | {iv('design__instance__count')} |",
        f"| Standard cells (excl. tap) | {iv('design__instance__count__stdcell')} |",
        f"| Sequential (flip-flops) | {iv('design__instance__count__class:sequential_cell')} |",
        f"| Multi-input combinational | {iv('design__instance__count__class:multi_input_combinational_cell')} |",
        f"| Buffers | {iv('design__instance__count__class:buffer')} |",
        f"| Inverters | {iv('design__instance__count__class:inverter')} |",
        f"| Macros | {iv('design__instance__count__macros')} |",
        f"| Tap cells | {iv('design__instance__count__class:tap_cell')} |",
        f"| I/O ports | {iv('design__io')} |",
    ]
    if nand2_row:
        lines.append(nand2_row)
    return "\n".join(lines) + "\n"

def section_wirelength(wl_csv):
    stats = wirelength_stats(wl_csv)
    if stats is None:
        return "_Wire length data not found._\n"
    total, n_nets, longest_net, longest_mm = stats
    lines = [
        "| Metric | Value |",
        "|---|---|",
        f"| Total nets | {n_nets:,} |",
        f"| Total wirelength | **{total:.2f} mm** |",
        f"| Longest net (`{longest_net}`) | {longest_mm:.3f} mm |",
    ]
    return "\n".join(lines) + "\n"

def section_antenna(mfg_rpt):
    txt = read(mfg_rpt)
    if not txt:
        return "_Manufacturability report not found._\n"
    lines = ["| Check | Result |", "|---|---|"]
    for check in ("Antenna", "LVS", "DRC"):
        m = re.search(rf"\*\s+{check}\n(.+)", txt)
        result = m.group(1).strip() if m else "N/A"
        lines.append(f"| {check} | {result} |")
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
    gate_count_section = section_gate_hierarchy(args.gate_count_json, nand2_area)

    # locate key directories
    sta_dir   = find_latest_step(run_dir, "*-openroad-stapostpnr")
    mfg_dir   = find_latest_step(run_dir, "*-misc-reportmanufacturability")
    wl_dir    = find_latest_step(run_dir, "*-odb-reportwirelength")
    gpl_dir   = find_latest_step(run_dir, "*-openroad-globalplacement")

    mfg_rpt   = os.path.join(mfg_dir, "manufacturability.rpt") if mfg_dir else ""
    wl_csv    = os.path.join(wl_dir,  "wire_lengths.csv")       if wl_dir  else ""
    metrics   = os.path.join(gpl_dir, "or_metrics_out.json")    if gpl_dir else ""

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
| Clock | {args.clock_mhz} MHz |
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

## 4. Cell Count

{section_cells(metrics, nand2_area)}
---

## 5. Timing (Post-PnR STA)

{section_timing(sta_dir)}
---

## 6. Power

{section_power(sta_dir)}
---

## 7. Routing & Wire Length

{section_wirelength(wl_csv)}
---

## 8. Manufacturability

{section_antenna(mfg_rpt)}
---

## 9. Output Files

{section_outputs(run_dir)}
"""

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w") as f:
        f.write(report)
    print(f"Report written to {args.output}")

if __name__ == "__main__":
    main()
