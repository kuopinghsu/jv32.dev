#!/usr/bin/env python3
"""Post-formatting fixups for SystemVerilog files after verible-verilog-format.

Two passes are applied in order:
  1. Align consecutive single-line ``localparam`` declarations (type, name, value columns).
  2. Align trailing ``//`` comments within consecutive same-indentation blocks.

Usage:
    python3 scripts/sv_format.py <file> [<file> ...]

Both passes modify files in-place and are idempotent.
"""

import argparse
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def split_comment(line: str) -> Tuple[str, Optional[str]]:
    """Split a line into (code, trailing_comment) respecting string literals."""
    in_string = False
    escaped = False
    for i, ch in enumerate(line):
        if escaped:
            escaped = False
            continue
        if ch == "\\":
            escaped = True
            continue
        if ch == '"':
            in_string = not in_string
            continue
        if not in_string and line[i : i + 2] == "//":
            return line[:i].rstrip(), line[i:].rstrip("\n")
    return line.rstrip("\n"), None

def get_indent(line: str) -> str:
    return line[: len(line) - len(line.lstrip())]

# ---------------------------------------------------------------------------
# Pass 1 – align localparam blocks
# ---------------------------------------------------------------------------

ParsedLP = Tuple[str, str, str, str, Optional[str]]  # indent, type, name, rhs, comment

def _parse_localparam(line: str) -> Optional[ParsedLP]:
    code, comment = split_comment(line)
    stripped = code.strip()
    if not stripped.startswith("localparam ") or not stripped.endswith(";"):
        return None
    indent = code[: len(code) - len(code.lstrip())]
    body = stripped[len("localparam ") : -1].strip()
    if "=" not in body:
        return None
    lhs, rhs = body.split("=", 1)
    lhs = lhs.rstrip()
    rhs = rhs.strip()
    parts = lhs.split()
    if not parts:
        return None
    name = parts[-1]
    type_part = lhs[: -len(name)].rstrip()
    return indent, type_part, name, rhs, comment

def _format_lp_block(block: List[ParsedLP]) -> List[str]:
    max_type = max(len(t) for _, t, _, _, _ in block)
    max_name = max(len(n) for _, _, n, _, _ in block)
    out = []
    for indent, type_part, name, rhs, comment in block:
        line = indent + "localparam "
        if max_type > 0:
            line += type_part.ljust(max_type) + " "
        line += name.ljust(max_name) + " = " + rhs + ";"
        if comment:
            line += "  " + comment.lstrip()
        out.append(line + "\n")
    return out

def _pass_localparams(lines: List[str]) -> Tuple[List[str], bool]:
    out: List[str] = []
    changed = False
    i = 0
    while i < len(lines):
        parsed = _parse_localparam(lines[i])
        if parsed is None:
            out.append(lines[i])
            i += 1
            continue

        start = i
        block: List[ParsedLP] = [parsed]
        i += 1
        while i < len(lines):
            p = _parse_localparam(lines[i])
            if p is None or p[0] != block[0][0]:   # different indent → new group
                break
            block.append(p)
            i += 1

        if len(block) == 1:
            out.append(lines[start])
            continue

        formatted = _format_lp_block(block)
        if formatted != lines[start:i]:
            changed = True
        out.extend(formatted)

    return out, changed

# ---------------------------------------------------------------------------
# Pass 2 – align trailing comments
# ---------------------------------------------------------------------------

def _is_group_breaker(line: str) -> bool:
    s = line.strip()
    return (not s or s.startswith("//") or s.startswith("/*")
            or s.startswith("*") or s.startswith("`"))

def _pass_trailing_comments(lines: List[str]) -> Tuple[List[str], bool]:
    out = list(lines)
    changed = False
    i = 0
    while i < len(lines):
        if _is_group_breaker(lines[i]):
            i += 1
            continue

        group_indent = get_indent(lines[i])
        group: List[int] = []
        while (i < len(lines)
               and not _is_group_breaker(lines[i])
               and get_indent(lines[i]) == group_indent):
            group.append(i)
            i += 1

        commented: List[Tuple[int, str, str]] = []
        for idx in group:
            code, comment = split_comment(lines[idx])
            if comment is not None and code.strip():
                commented.append((idx, code, comment))

        if len(commented) < 2:
            continue

        col = max(len(code) for _, code, _ in commented) + 2
        for idx, code, comment in commented:
            new_line = code.ljust(col) + comment + "\n"
            if new_line != lines[idx]:
                out[idx] = new_line
                changed = True

    return out, changed

# ---------------------------------------------------------------------------
# Top-level file processor
# ---------------------------------------------------------------------------

def format_file(path: Path) -> bool:
    lines = path.read_text().splitlines(keepends=True)

    lines, c1 = _pass_localparams(lines)
    lines, c2 = _pass_trailing_comments(lines)

    if c1 or c2:
        path.write_text("".join(lines))
    return c1 or c2

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Post-verible SV formatting: align localparams and trailing comments."
    )
    parser.add_argument("files", nargs="+", help="SystemVerilog files to format in-place")
    args = parser.parse_args()

    for f in args.files:
        format_file(Path(f))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
