#!/usr/bin/env python3
"""Normalize net names in a Magic-extracted SPICE file for Netgen LVS.

Two normalization passes are performed:

1. POWER NET NORMALIZATION
   When OpenLane2 is run with FP_PDN_ENABLE_RAILS: false, Magic extracts power
   rail segments with names derived from adjacent cell instances -- e.g.
   'hold63/VDD' or 'FILLER_1850_7787/VSS' -- instead of the canonical global
   nets 'VDD' and 'VSS'.  Any net token matching <word_chars>/VDD -> VDD, etc.

2. BRACKET NET NORMALIZATION
   Magic-extracted SPICE files use SPICE-style backslash escaping for brackets
   in hierarchical net names:  clic_mtime (backslash)[10(backslash)]
   Verilog (as read by Netgen) uses Verilog escaped-identifier format:
   (backslash)clic_mtime[10]  (leading backslash, unescaped brackets, trailing space).
   Netgen does NOT normalise between these two conventions, so every such net
   is reported as an unmatched net.  This pass converts the SPICE-style form
   to the Verilog escaped-identifier form so both circuits use the same names.

SPICE comment lines (starting with '*') and .subckt header lines are left
unchanged (the subckt port list uses the SPICE form and must stay as-is).

Usage:
    python3 normalize_spice_power.py input.spice output.spice
    python3 normalize_spice_power.py input.spice      # overwrites in-place
"""

import os
import re
import sys
import shutil
import tempfile
from pathlib import Path

# ---------------------------------------------------------------------------
# Pass 1 – power rail fragment normalization
# ---------------------------------------------------------------------------
# Match a net name ending in a hierarchical /VDD, /VSS, or /GND suffix.
# Two patterns are needed:
#   a) Simple: word_chars/VDD  (e.g. hold63/VDD, FILLER_xxx/VSS)
#   b) Complex: any non-whitespace path / vdd|vss|gnd (case-insensitive)
#      (e.g. u_jv32.u_iram...g_bank\[0\].u_sub/vdd from SRAM black-box extraction)
# The pattern requires at least one character before the slash so that the
# bare canonical names 'VDD', 'VSS', 'GND' are not themselves matched.
_POWER_RE = re.compile(
    r'\S+/(?:VDD|VSS|GND|vdd|vss|gnd)(?=\s|$)'
)

# Map lowercase-suffix → canonical name (match case-insensitively via suffix check)
_REPLACEMENTS = {
    '/VDD': 'VDD', '/vdd': 'VDD',
    '/VSS': 'VSS', '/vss': 'VSS',
    '/GND': 'VSS', '/gnd': 'VSS',
}

# ---------------------------------------------------------------------------
# Pass 3 – SPICE X-element instance name normalization
# ---------------------------------------------------------------------------
# In SPICE, subcircuit instantiation lines start with X.  When instance names
# contain generate-loop indices such as g_bank[0].u_sub, Magic emits them as
# g_bank\[0\].u_sub  (backslash-escaped brackets, no leading backslash).
# Netgen strips the leading X from the element name but keeps the backslash-
# escaped form.  Verilog instance names use the escaped-identifier form:
#   \u_jv32...g_bank[0].u_sub  (Netgen strips leading \ and trailing space,
#   storing u_jv32...g_bank[0].u_sub).
# Result: SPICE stores u_jv32...g_bank\[0\].u_sub and Verilog stores
# u_jv32...g_bank[0].u_sub — these don't match, so Netgen falls back to
# topology-based matching, confusing bank[0] with bank[1].
# This pass strips the backslash escaping from the instance name token only
# (the first token on an X-line):
#   Xu_jv32...g_bank\[0\].u_sub  →  Xu_jv32...g_bank[0].u_sub
_INST_NAME_RE = re.compile(r'^(X[^\s]+)', re.MULTILINE)
# Matches a SPICE net name token of the form:
#   word\[subscript\]   e.g.  clic_mtime\[10\]  or  u_jv32.core\[0\]\[1\]
# where 'word' starts with a letter or underscore and may contain dots.
# The pattern anchors on word boundaries so it doesn't match inside longer
# identifiers already in Verilog format.
_BRACKET_RE = re.compile(
    r'(?<!\\)'              # not already preceded by a backslash (avoid double-convert)
    r'([A-Za-z_][A-Za-z0-9_.]*)'   # base name (may contain dots for hierarchy)
    r'((?:\\\[[^\]\\]*\\\])+)'      # one or more \[subscript\] groups
    r'(?=\s)'               # followed by whitespace (net name ends here)
)


def _replace_power(match: re.Match) -> str:
    token = match.group()
    token_lower = token.lower()
    if token_lower.endswith('/vdd'):
        return 'VDD'
    if token_lower.endswith('/vss') or token_lower.endswith('/gnd'):
        return 'VSS'
    return token  # shouldn't happen


def _replace_brackets(match: re.Match) -> str:
    """Convert SPICE-style name(bs)[n(bs)] to Verilog escaped-identifier (bs)name[n] ."""
    base = match.group(1)
    subscripts = match.group(2)
    # Remove backslash escaping from brackets: \[ → [  and \] → ]
    subscripts_clean = subscripts.replace('\\[', '[').replace('\\]', ']')
    # Return Verilog escaped-identifier form: leading \ + name + subscripts + trailing space.
    # The trailing space is critical: Netgen reads Verilog escaped identifiers as
    # backslash-to-whitespace-inclusive.  If the net name falls at end-of-line in
    # the SPICE file the terminating character would be \n, which Netgen includes in
    # the stored name, producing an identifier with an embedded newline that breaks
    # JSON serialization.  Adding an explicit space here ensures the identifier is
    # always terminated by a space regardless of position in the line.
    return '\\' + base + subscripts_clean + ' '


def _fix_instance_name(match: re.Match) -> str:
    """Strip backslash-bracket escaping from X-element instance names."""
    return match.group(1).replace('\\[', '[').replace('\\]', ']')


def normalize_spice(input_path: Path, output_path: Path) -> tuple[int, int, int]:
    """Normalize SPICE net names.

    Returns (power_count, bracket_count, instance_count) — replacements per pass.
    """
    text = input_path.read_text(encoding='utf-8', errors='replace')
    power_total = 0
    bracket_total = 0
    instance_total = 0

    lines = text.splitlines(keepends=True)
    result = []
    # Track whether we are inside a .subckt definition line (to skip it for
    # bracket normalization — the port list uses SPICE names that must stay as-is).
    for line in lines:
        stripped = line.lstrip()
        # Preserve SPICE comment lines verbatim for both passes
        if stripped.startswith('*'):
            result.append(line)
            continue
        # Pass 1: power rail fragment normalization
        new_line, n = _POWER_RE.subn(_replace_power, line)
        power_total += n
        # Pass 2: bracket normalization on net names — skip .subckt declaration lines
        # (those define the cell interface; Netgen reads them as SPICE names)
        if not stripped.startswith('.subckt') and not stripped.startswith('.ends'):
            new_line, n = _BRACKET_RE.subn(_replace_brackets, new_line)
            bracket_total += n
        # Pass 3: instance name normalization — strip \[ escaping from X-element names.
        # Only X-lines have instance names (lines starting with X or continuation lines
        # that are part of an X-element - but instance name is always on the first line).
        if stripped.startswith('X'):
            new_line, n = _INST_NAME_RE.subn(_fix_instance_name, new_line)
            instance_total += n
        result.append(new_line)

    output_path.write_text(''.join(result), encoding='utf-8')
    return power_total, bracket_total, instance_total


# Keep the old name for backward compatibility
def normalize_power_nets(input_path: Path, output_path: Path) -> int:
    """Normalize fragmented power net names only.  Returns the replacement count."""
    power_count, _, _ = normalize_spice(input_path, output_path)
    return power_count


def main() -> None:
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} input.spice [output.spice]', file=sys.stderr)
        sys.exit(1)

    input_path = Path(sys.argv[1])
    if len(sys.argv) > 2:
        output_path = Path(sys.argv[2])
        in_place = False
    else:
        output_path = input_path
        in_place = True

    if not input_path.exists():
        print(f'ERROR: Input file not found: {input_path}', file=sys.stderr)
        sys.exit(1)

    if in_place:
        # Write to a temporary file first, then atomically replace
        tmp_fd, tmp_name = tempfile.mkstemp(
            suffix='.spice', dir=input_path.parent)
        tmp_path = Path(tmp_name)
        try:
            os.close(tmp_fd)
            power_n, bracket_n, instance_n = normalize_spice(input_path, tmp_path)
            shutil.move(str(tmp_path), str(output_path))
        except Exception:
            tmp_path.unlink(missing_ok=True)
            raise
    else:
        power_n, bracket_n, instance_n = normalize_spice(input_path, output_path)

    print(f'normalize_spice_power: {power_n} fragmented power rail reference(s) '
          f'normalised in {output_path}')
    print(f'normalize_spice_power: {bracket_n} bracket-escaped net name(s) '
          f'converted to Verilog escaped-identifier format in {output_path}')
    print(f'normalize_spice_power: {instance_n} X-element instance name(s) '
          f'had bracket escaping stripped in {output_path}')


if __name__ == '__main__':
    main()
