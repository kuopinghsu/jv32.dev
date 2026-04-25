#!/usr/bin/env python3
"""
fix_spice_power_nets.py  –  merge fragmented VDD/VSS net segments in a
Magic DEF-mode extracted SPICE.

Background
----------
When Magic extracts a DEF+LEF netlists where the power-distribution network
(PDN) only has upper-metal stripes (Metal5+), it cannot see the continuous
Metal-1 VDD/VSS rails inside the standard-cell abstract views.  Each cell
row segment therefore gets a unique power-net name such as

    hold63/VDD   FILLER_1477_7787/VDD   wire777/VDD   ...

instead of the single global net "VDD".  The same happens for VSS / gnd.

This script replaces every such fragment with the canonical name so that
Netgen LVS sees one global VDD and one global VSS, matching the schematic.

Usage
-----
    python3 fix_spice_power_nets.py <extracted.spice>          # edit in-place
    python3 fix_spice_power_nets.py <extracted.spice> <out.spice>
"""

import re
import sys
from pathlib import Path

# Net tokens that end in one of these suffixes (case-insensitive) map to
# a canonical power name.
_SUFFIX_MAP = {
    "/vdd":  "VDD",
    "/vdd!": "VDD",
    "/vpwr": "VDD",
    "/vss":  "VSS",
    "/vss!": "VSS",
    "/vgnd": "VSS",
    "/gnd":  "VSS",
    "/gnd!": "VSS",
}

# Compiled: token is the whole net name (no spaces); replace if it matches.
_FRAGMENT_RE = re.compile(
    r'(?i)\S+/(?:VDD!?|VPWR|VSS!?|VGND|GND!?)'
)

def _replace_token(match: re.Match) -> str:
    tok = match.group(0)
    lower = tok.lower()
    for suffix, canonical in _SUFFIX_MAP.items():
        if lower.endswith(suffix):
            return canonical
    return tok          # should not happen given the regex, but be safe

def fix_power_nets(src: Path, dst: Path) -> None:
    text = src.read_text(encoding="utf-8")

    # Only transform lines that are SPICE instance calls (start with X)
    # or continuation lines (start with +).  Leave subcircuit definitions
    # (.subckt / .ends) and comments untouched.
    lines = text.splitlines(keepends=True)
    out_lines: list[str] = []
    vdd_count = 0
    vss_count = 0

    for line in lines:
        stripped = line.lstrip()
        if stripped and stripped[0] in ('X', '+', 'x'):
            def _rep(m: re.Match) -> str:
                r = _replace_token(m)
                return r
            new_line = _FRAGMENT_RE.sub(_rep, line)
            # count replacements for reporting
            orig_vdd = line.upper().count('/VDD') + line.upper().count('/VPWR')
            orig_vss = (line.upper().count('/VSS') + line.upper().count('/VGND')
                        + line.upper().count('/GND'))
            if new_line != line:
                vdd_count += orig_vdd
                vss_count += orig_vss
            out_lines.append(new_line)
        else:
            out_lines.append(line)

    dst.write_text("".join(out_lines), encoding="utf-8")
    print(f"fix_spice_power_nets: merged {vdd_count} VDD fragments and "
          f"{vss_count} VSS fragments → {dst}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    src_path = Path(sys.argv[1]).resolve()
    dst_path = Path(sys.argv[2]).resolve() if len(sys.argv) >= 3 else src_path

    fix_power_nets(src_path, dst_path)
