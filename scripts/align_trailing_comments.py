#!/usr/bin/env python3

import argparse
from pathlib import Path
from typing import Dict, List, Optional, Tuple

def split_trailing_comment(line: str) -> Tuple[str, Optional[str]]:
    in_string = False
    escaped = False

    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char == '"':
            in_string = not in_string
            continue
        if not in_string and line[index:index + 2] == "//":
            return line[:index].rstrip(), line[index:].rstrip("\n")

    return line.rstrip("\n"), None

def get_indent(line: str) -> str:
    return line[: len(line) - len(line.lstrip())]

def is_group_breaker(line: str) -> bool:
    """Return True if this line ends the current alignment group."""
    stripped = line.strip()
    if not stripped:
        return True
    if stripped.startswith("//"):
        return True
    if stripped.startswith("/*") or stripped.startswith("*"):
        return True
    if stripped.startswith("`"):
        return True
    return False

def align_file(path: Path) -> bool:
    lines = path.read_text().splitlines(keepends=True)
    updated_lines: List[str] = list(lines)
    changed = False
    index = 0

    while index < len(lines):
        if is_group_breaker(lines[index]):
            index += 1
            continue

        # Collect a group: consecutive non-breaker lines with the same indentation.
        group_indent = get_indent(lines[index])
        group_indices: List[int] = []
        while index < len(lines) and not is_group_breaker(lines[index]) and get_indent(lines[index]) == group_indent:
            group_indices.append(index)
            index += 1

        # Within the group, find lines that have trailing comments.
        commented: List[Tuple[int, str, str]] = []  # (line_index, code, comment)
        for idx in group_indices:
            code, comment = split_trailing_comment(lines[idx])
            if comment is not None and code.strip():
                commented.append((idx, code, comment))

        if len(commented) < 2:
            continue

        comment_col = max(len(code) for _, code, _ in commented) + 2
        for idx, code, comment in commented:
            new_line = code.ljust(comment_col) + comment + "\n"
            if new_line != lines[idx]:
                updated_lines[idx] = new_line
                changed = True

    if changed:
        path.write_text("".join(updated_lines))
    return changed

def main() -> int:
    parser = argparse.ArgumentParser(description="Align trailing // comments in consecutive same-indentation blocks.")
    parser.add_argument("files", nargs="+", help="Files to process")
    args = parser.parse_args()

    for file_name in args.files:
        align_file(Path(file_name))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
