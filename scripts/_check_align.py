#!/usr/bin/env python3
import sys
from pathlib import Path

def is_breaker(line):
    s = line.strip()
    return not s or s.startswith("//") or s.startswith("/*") or s.startswith("*") or s.startswith("`")

def get_indent(line):
    return line[:len(line) - len(line.lstrip())]

def find_col(line):
    for i in range(len(line) - 1):
        if line[i:i+2] == "//":
            code = line[:i].rstrip()
            if code.strip():
                return i, code
    return None, None

for filepath in sys.argv[1:]:
    lines = Path(filepath).read_text().splitlines()
    i, n = 0, len(lines)
    misaligned = []
    while i < n:
        if is_breaker(lines[i]):
            i += 1
            continue
        indent = get_indent(lines[i])
        group = []
        while i < n and not is_breaker(lines[i]) and get_indent(lines[i]) == indent:
            col, code = find_col(lines[i])
            if col is not None:
                group.append((i + 1, col, code))
            i += 1
        if len(group) >= 2:
            cols = set(g[1] for g in group)
            if len(cols) > 1:
                misaligned.append(group)
    if misaligned:
        for g in misaligned:
            print("MISALIGNED lines %d-%d:" % (g[0][0], g[-1][0]))
            for ln, col, code in g:
                print("  line %d col %d: %s" % (ln, col, code))
    else:
        print("%s: all comment groups aligned" % filepath)
