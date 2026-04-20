#!/usr/bin/env python3
"""Snap OpenRAM LEF RECT coordinates to manufacturing grid.

OpenROAD detailed routing enforces that terminal geometries are aligned to the
manufacturing grid. Some OpenRAM LEFs use 0.0025um coordinates, which can trip
DRT-0416 when the manufacturing grid is 0.005um.
"""

from __future__ import annotations

import argparse
import re
from decimal import Decimal, ROUND_HALF_UP, getcontext
from pathlib import Path

getcontext().prec = 28

RECT_RE = re.compile(
    r"^(?P<indent>\s*RECT\s+)"
    r"(?P<x1>-?\d+(?:\.\d+)?)\s+"
    r"(?P<y1>-?\d+(?:\.\d+)?)\s+"
    r"(?P<x2>-?\d+(?:\.\d+)?)\s+"
    r"(?P<y2>-?\d+(?:\.\d+)?)"
    r"(?P<suffix>\s*;\s*)$"
)

def snap(v: Decimal, grid: Decimal) -> Decimal:
    return (v / grid).quantize(Decimal("1"), rounding=ROUND_HALF_UP) * grid

def fmt(v: Decimal) -> str:
    s = format(v.normalize(), "f")
    if "." not in s:
        s += ".0"
    return s

def fix_lef(path: Path, grid_um: Decimal) -> tuple[int, int]:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    out: list[str] = []
    rect_total = 0
    rect_changed = 0

    for line in lines:
        m = RECT_RE.match(line.rstrip("\n"))
        if not m:
            out.append(line)
            continue

        rect_total += 1
        coords = [Decimal(m.group(k)) for k in ("x1", "y1", "x2", "y2")]
        snapped = [snap(c, grid_um) for c in coords]
        if snapped != coords:
            rect_changed += 1

        new_line = (
            f"{m.group('indent')}{fmt(snapped[0])} {fmt(snapped[1])} "
            f"{fmt(snapped[2])} {fmt(snapped[3])}{m.group('suffix')}"
        )
        out.append(new_line + ("\n" if line.endswith("\n") else ""))

    if rect_changed:
        path.write_text("".join(out), encoding="utf-8")

    return rect_total, rect_changed

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("lef", type=Path, help="Path to LEF file")
    ap.add_argument(
        "--grid-um",
        type=Decimal,
        default=Decimal("0.005"),
        help="Manufacturing grid in microns (default: 0.005)",
    )
    args = ap.parse_args()

    rect_total, rect_changed = fix_lef(args.lef, args.grid_um)
    print(
        f"[fix_openram_lef_grid] {args.lef}: scanned {rect_total} RECTs, "
        f"updated {rect_changed}"
    )
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
