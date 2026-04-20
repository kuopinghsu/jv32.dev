#!/usr/bin/env python3

import argparse
from pathlib import Path
from typing import List, Optional, Tuple

ParsedLine = Tuple[str, str, str, str, Optional[str]]

def split_comment(line: str) -> Tuple[str, Optional[str]]:
    comment_index = line.find("//")
    if comment_index == -1:
        return line.rstrip("\n"), None
    return line[:comment_index].rstrip(), line[comment_index:].rstrip("\n")

def parse_localparam_line(line: str) -> Optional[ParsedLine]:
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
    lhs_parts = lhs.split()
    if not lhs_parts:
        return None

    name = lhs_parts[-1]
    type_part = lhs[: -len(name)].rstrip()
    return indent, type_part, name, rhs, comment

def format_block(parsed_lines: List[ParsedLine]) -> List[str]:
    max_type_width = max(len(type_part) for _, type_part, _, _, _ in parsed_lines)
    max_name_width = max(len(name) for _, _, name, _, _ in parsed_lines)
    formatted = []

    for indent, type_part, name, rhs, comment in parsed_lines:
        line = indent + "localparam "
        if max_type_width > 0:
            line += type_part.ljust(max_type_width) + " "
        line += name.ljust(max_name_width) + " = " + rhs + ";"
        if comment:
            line += "  " + comment.lstrip()
        formatted.append(line + "\n")

    return formatted

def align_file(path: Path) -> bool:
    lines = path.read_text().splitlines(keepends=True)
    updated_lines: List[str] = []
    changed = False
    index = 0

    while index < len(lines):
        parsed = parse_localparam_line(lines[index])
        if parsed is None:
            updated_lines.append(lines[index])
            index += 1
            continue

        block_start = index
        block: List[ParsedLine] = [parsed]
        index += 1

        while index < len(lines):
            parsed = parse_localparam_line(lines[index])
            if parsed is None:
                break
            if parsed[0] != block[0][0]:
                break
            block.append(parsed)
            index += 1

        if len(block) == 1:
            updated_lines.append(lines[block_start])
            continue

        formatted_block = format_block(block)
        original_block = lines[block_start:index]
        if formatted_block != original_block:
            changed = True
        updated_lines.extend(formatted_block)

    if changed:
        path.write_text("".join(updated_lines))
    return changed

def main() -> int:
    parser = argparse.ArgumentParser(description="Align consecutive single-line localparam declarations.")
    parser.add_argument("files", nargs="+", help="Files to process")
    args = parser.parse_args()

    for file_name in args.files:
        align_file(Path(file_name))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())