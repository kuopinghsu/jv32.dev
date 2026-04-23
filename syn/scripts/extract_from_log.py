#!/usr/bin/env python3
"""
extract_from_log.py — Post-process timing_run.log to fill report files whose
content is missing because the OpenROAD Tcl redirect mechanism was unavailable.

Usage:
    python3 extract_from_log.py <reports_dir>

For each of area.rpt, cts.rpt, cells.rpt, congestion.rpt: if the file exists
but contains only header lines (lines starting with '#') and/or the
"redirect unavailable" fallback message, the relevant section is extracted
from timing_run.log and appended to the file.
"""

import os
import re
import sys

def read_text(path):
    with open(path) as f:
        return f.read()

def content_missing(rpt_path):
    """Return True when the report has no useful data (only header / fallback lines)."""
    if not os.path.exists(rpt_path):
        return False  # don't create files we weren't asked to create
    text = read_text(rpt_path)
    useful = [l for l in text.splitlines()
              if l.strip() and not l.startswith('#')]
    return len(useful) == 0

def append_content(rpt_path, content):
    with open(rpt_path, 'a') as f:
        f.write(content.rstrip('\n') + '\n')

# ---------------------------------------------------------------------------
# Extraction helpers
# ---------------------------------------------------------------------------

def extract_area(log, reports_dir=None):
    """Return a detailed area breakdown.

    Combines the OpenROAD report_design_area output from the log with
    metrics.json data (when available) to produce a complete picture of
    die, core, macro, standard-cell, and fill-cell areas.
    """
    m = re.search(r'^Design area .+$', log, re.MULTILINE)
    raw_line = m.group(0) if m else None

    # Try to load metrics.json from the OpenLane run directory
    metrics = {}
    if reports_dir:
        # metrics.json lives in the openlane_run/final/ directory.
        # reports_dir is typically <build>/pnr/reports/; walk up to <build>.
        build_dir = os.path.normpath(os.path.join(reports_dir, '..', '..'))
        for candidate in [
            os.path.join(build_dir, 'openlane_run', 'final', 'metrics.json'),
            os.path.join(reports_dir, '..', 'metrics.json'),
            os.path.join(reports_dir, '..', '..', 'metrics.json'),
        ]:
            candidate = os.path.normpath(candidate)
            if os.path.exists(candidate):
                try:
                    import json
                    metrics = json.load(open(candidate))
                except Exception:
                    pass
                break

    lines = []

    if metrics:
        die_area  = metrics.get('design__die__area',  None)   # µm²
        core_area = metrics.get('design__core__area', None)   # µm²
        inst_area = metrics.get('design__instance__area',          None)  # µm² non-fill
        macro_area= metrics.get('design__instance__area__macros',  None)  # µm²
        sc_area   = metrics.get('design__instance__area__stdcell', None)  # µm²
        util      = metrics.get('design__instance__utilization',   None)  # 0-1
        sc_util   = metrics.get('design__instance__utilization__stdcell', None)
        die_bbox  = metrics.get('design__die__bbox',  None)   # "x0 y0 x1 y1"
        core_bbox = metrics.get('design__core__bbox', None)
        fill_cnt  = metrics.get('design__instance__count__class:fill_cell', None)

        def fmt_area(v):
            return f'{v:,.2f}' if v is not None else 'n/a'
        def fmt_pct(v):
            return f'{v*100:.1f}%' if v is not None else 'n/a'

        # Compute fill area from cells.rpt if possible
        fill_area = None
        if inst_area is not None and die_area is not None:
            # Total cell area = inst_area + fill; fill_area can be estimated
            # inst_area already excludes fill per OpenROAD semantics
            pass

        def bbox_dims(s):
            """'x0 y0 x1 y1' → 'W × H µm'"""
            if not s:
                return 'n/a'
            try:
                x0, y0, x1, y1 = map(float, str(s).split())
                return f'{x1-x0:.2f} × {y1-y0:.2f} µm'
            except Exception:
                return str(s)

        lines += [
            f'Die area    : {fmt_area(die_area)} µm²',
            f'Die bbox    : {bbox_dims(die_bbox)}',
            f'Core area   : {fmt_area(core_area)} µm²',
            f'Core bbox   : {bbox_dims(core_bbox)}',
            f'',
            f'Instance area (excl. fill cells):',
            f'  Macros    : {fmt_area(macro_area)} µm²',
            f'  Std cells : {fmt_area(sc_area)} µm²',
            f'  Total     : {fmt_area(inst_area)} µm²',
            f'',
            f'Core utilization (excl. fill): {fmt_pct(util)}',
            f'  (std-cell only)            : {fmt_pct(sc_util)}',
        ]
        if fill_cnt is not None:
            lines.append(f'Fill cells inserted          : {fill_cnt:,}')
        lines.append('')
        if raw_line:
            lines += [f'OpenROAD report_design_area  : {raw_line}']
        lines += [
            '',
            '# Note: "instance area" = sum of cell bounding boxes for non-filler',
            '# cells only (macros + std cells, excl. FILL/TAPCELL). Fill cells are',
            '# interleaved throughout all placement rows to satisfy DRC and LVS.',
            '# The circuit bounding box = core bbox above; fill cells do NOT',
            '# represent empty space — they complete every row for power integrity.',
        ]
    elif raw_line:
        lines.append(raw_line)

    return '\n'.join(lines) + '\n' if lines else None

def extract_cts(log):
    lines = re.findall(r'^\[INFO CTS-\d+\].*$', log, re.MULTILINE)
    return ('\n'.join(lines) + '\n') if lines else None

def extract_cells(log):
    """Return the full Cell-type-report table (header through Total line)."""
    start = log.find('Cell type report:')
    if start < 0:
        return None
    # Find the start of that line
    bol = log.rfind('\n', 0, start) + 1
    # Find the "Total" summary line after the header
    m = re.search(r'^\s+Total\s+[\d,]+\s+[\d,.]+', log[start:], re.MULTILINE)
    if not m:
        return None
    end = start + m.end()
    # Extend to end of line
    eol = log.find('\n', end)
    end = eol if eol >= 0 else len(log)
    return log[bol:end].rstrip('\n') + '\n'

def extract_congestion(log):
    """Return a congestion summary built from GRT-0026 warnings.

    OpenROAD's report_congestion writes nothing when loaded from a
    detailed-route ODB (global-routing guides are not persisted).  The only
    routing-quality data available is the set of GRT-0026 "Missing route to
    pin" warnings emitted by estimate_parasitics -global_routing.
    """
    warnings = re.findall(r'^\[WARNING GRT-0026\] Missing route to pin (.+)\.$',
                          log, re.MULTILINE)
    if not warnings:
        return (
            "# report_congestion produced no output.\n"
            "# No GRT-0026 missing-route warnings found in timing_run.log.\n"
        )

    lines = [
        f"# report_congestion produced no output (detailed-route ODB; no",
        f"# global-routing guides available).",
        f"",
        f"# GRT-0026 Missing route warnings from estimate_parasitics:",
        f"#   Total missing routes : {len(warnings)}",
        f"",
    ]
    for pin in warnings:
        lines.append(f"[WARNING GRT-0026] Missing route to pin {pin}.")
    return '\n'.join(lines) + '\n'

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {os.path.basename(sys.argv[0])} <reports_dir>",
              file=sys.stderr)
        sys.exit(1)

    reports_dir = sys.argv[1]
    log_file = os.path.join(reports_dir, 'timing_run.log')

    if not os.path.exists(log_file):
        print(f"  extract_from_log: {log_file} not found, skipping.")
        return

    log = read_text(log_file)

    targets = [
        ('area.rpt',        extract_area(log, reports_dir)),
        ('cts.rpt',         extract_cts(log)),
        ('cells.rpt',       extract_cells(log)),
        ('congestion.rpt',  extract_congestion(log)),
    ]

    any_fixed = False
    for fname, content in targets:
        rpt_path = os.path.join(reports_dir, fname)
        if content and content_missing(rpt_path):
            append_content(rpt_path, content)
            print(f"  Extracted from log → {fname}")
            any_fixed = True

    if any_fixed:
        print(f"  (source: {log_file})")

if __name__ == '__main__':
    main()
