#!/usr/bin/env python3
"""Strip physical-only cell instantiations from a post-route Verilog netlist.

OpenLane2 writes these cell types into the powered netlist (pnl.v):
  - ANTENNA_X1   — antenna-rule fix diodes inserted by OpenROAD
  - FILLCELL_X*  — decap/filler cells inserted by fill insertion step
  - TAPCELL_X1   — well-tap cells
  - PHY_EDGE_ROW_X* — edge row filler cells

Netgen LVS handles FILLCELL/TAPCELL correctly via ``ignore class`` because
those cells have only VDD/VSS pins and the matching algorithm can collapse all
instances to a single template.  ANTENNA_X1 has a functional signal pin ``A``
(the net being protected), which prevents ``ignore class`` from cleanly
collapsing instances — leaving 23 000+ unmatched instances that account for
most of the ~2428 LVS errors.

Stripping these cells from the Verilog (circuit2) before Netgen runs is the
correct approach: the ``ignore class`` in freepdk45.tcl then handles the
layout-side (circuit1) instances cleanly, just as it does for fill/tap cells
that are only in the layout.

The function and topology of the logical circuit is unchanged — antenna diodes
and fill cells are verified separately (antenna DRC check, not LVS).

Usage:
    python3 strip_physical_cells_verilog.py input.pnl.v [output.pnl.v]
    python3 strip_physical_cells_verilog.py input.pnl.v          # in-place

Only removes INSTANCE DECLARATIONS — module/endmodule wrappers and wire
declarations are preserved.
"""

import os
import re
import sys
import shutil
import tempfile
from pathlib import Path

# Cell type names (or prefixes) that are physical-only and should be stripped.
# Each entry is either an exact name or a prefix ending with '*'.
_PHYSICAL_CELL_PATTERNS = [
    "ANTENNA_X1",
    "FILLCELL_X1",
    "FILLCELL_X2",
    "FILLCELL_X4",
    "FILLCELL_X8",
    "FILLCELL_X16",
    "FILLCELL_X32",
    "TAPCELL_X1",
    "PHY_EDGE_ROW_X1",
    "PHY_EDGE_ROW_X2",
    "PHY_EDGE_ROW_X4",
    "PHY_EDGE_ROW_X8",
]

# Pre-compiled regex: matches the first line of a physical-only cell
# instantiation, e.g.:
#   " ANTENNA_X1 ANTENNA__42679__A (.A(net), "
#   " FILLCELL_X32 FILLER_1850_4725 (.VDD(VDD),"
_CELL_ALT = "|".join(re.escape(c) for c in _PHYSICAL_CELL_PATTERNS)
_INSTANCE_START_RE = re.compile(
    r"^\s+(?:" + _CELL_ALT + r")\s+\S+\s*\(",
)

def strip_physical_cells(input_path: Path, output_path: Path) -> dict:
    """Strip physical-only cell instances.

    Returns a dict mapping cell type → count of stripped instances.
    """
    lines = input_path.read_text(encoding="utf-8", errors="replace").splitlines(
        keepends=True
    )

    result = []
    counts: dict[str, int] = {}
    in_phys_block = False
    current_cell_type = ""

    for line in lines:
        if in_phys_block:
            # Skip continuation lines; detect end of instance (closing ");")
            # Instance ends at the first occurrence of ");" on a line.
            if re.search(r"\)\s*;", line):
                in_phys_block = False
            # Either way, don't emit this line.
            continue

        m = _INSTANCE_START_RE.match(line)
        if m:
            # Identify which cell type matched
            tok = line.split()[0]  # first non-space token = cell type
            current_cell_type = tok
            counts[tok] = counts.get(tok, 0) + 1
            # Check if the instance closes on the same line
            if re.search(r"\)\s*;", line):
                in_phys_block = False  # single-line instance — already closed
            else:
                in_phys_block = True  # multi-line instance — skip until ");"
            # Don't emit this line (it's the stripped instance's opening)
            continue

        result.append(line)

    output_path.write_text("".join(result), encoding="utf-8")
    return counts

def main() -> None:
    if len(sys.argv) < 2:
        print(
            f"Usage: {sys.argv[0]} input.pnl.v [output.pnl.v]",
            file=sys.stderr,
        )
        sys.exit(1)

    input_path = Path(sys.argv[1])
    if len(sys.argv) > 2:
        output_path = Path(sys.argv[2])
        in_place = False
    else:
        output_path = input_path
        in_place = True

    if not input_path.exists():
        print(f"ERROR: Input file not found: {input_path}", file=sys.stderr)
        sys.exit(1)

    if in_place:
        # Write to a temp file first, then atomically replace
        tmp_fd, tmp_name = tempfile.mkstemp(suffix=".v", dir=input_path.parent)
        tmp_path = Path(tmp_name)
        try:
            os.close(tmp_fd)
            counts = strip_physical_cells(input_path, tmp_path)
            shutil.move(str(tmp_path), str(output_path))
        except Exception:
            tmp_path.unlink(missing_ok=True)
            raise
    else:
        counts = strip_physical_cells(input_path, output_path)

    total = sum(counts.values())
    print(
        f"strip_physical_cells_verilog: {total} physical-only instance(s) "
        f"stripped from {output_path}"
    )
    for cell_type, n in sorted(counts.items()):
        print(f"  {cell_type:30s}: {n}")

if __name__ == "__main__":
    main()
