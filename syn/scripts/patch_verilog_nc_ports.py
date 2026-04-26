#!/usr/bin/env python3
"""Add explicit wire connections for NC (unconnected) output ports in a Verilog
netlist, guided by a synthetic-name mapping produced by normalize_spice_hiernames.py.

When Magic extracts a SPICE netlist from layout, some cell output pins that drive
only ANTENNA diodes end up as hierarchical nets like `clkload90/Z`.  The Verilog
netlist (which was already stripped of ANTENNA cells) never names these outputs
because they were left NC.  Netgen cannot match the SPICE net name to the Verilog
circuit because c2 has no named wire for that pin.

normalize_spice_hiernames.py generates a JSON mapping
  { "clkload90/Z": {"inst": "clkload90", "pin": "Z", "wire": "__clkload90__Z__"} }
for every such unresolved hier net.  This script reads that mapping and patches
the Verilog to add the corresponding .PIN(wire) connection to each instance.

Usage:
    python3 patch_verilog_nc_ports.py synthetic_map.json netlist.v [output.v]
"""

import json
import os
import re
import shutil
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

# ---------------------------------------------------------------------------
# Build {inst_name: {pin_name: wire_name}} from the synthetic map
# ---------------------------------------------------------------------------

def load_patch_map(json_path: Path) -> dict:
    """Return {inst_name: {pin_name: wire_name}}."""
    data = json.loads(json_path.read_text(encoding='utf-8'))
    patch = defaultdict(dict)
    for _hier, entry in data.items():
        inst = entry['inst']
        pin = entry['pin']
        wire = entry['wire']
        patch[inst][pin] = wire
    return dict(patch)

# ---------------------------------------------------------------------------
# Patch the Verilog netlist
# ---------------------------------------------------------------------------

# Matches the opening of an instance connection list: CELLTYPE INSTNAME (
_INST_HDR_RE = re.compile(
    r'^(\s*)([A-Za-z_][A-Za-z0-9_]*)\s+\\?([A-Za-z_][A-Za-z0-9_.\[\]\\]*)\s*\('
)

def patch_verilog(verilog_path: Path, patch_map: dict, output_path: Path) -> int:
    """Patch instance declarations in the Verilog netlist.

    For each instance in patch_map, scan for its declaration and append the
    missing .PIN(WIRE) connections before the closing ');'.

    Returns the count of port connections added.
    """
    lines = verilog_path.read_text(encoding='utf-8', errors='replace').splitlines(keepends=True)
    out_lines = []
    added = 0

    i = 0
    while i < len(lines):
        line = lines[i]
        m = _INST_HDR_RE.match(line)
        if m:
            indent = m.group(1)
            # Normalise escaped identifiers in instance names
            raw_iname = m.group(3)
            inst_name = raw_iname.replace('\\', '').rstrip()

            if inst_name in patch_map:
                pins_to_add = patch_map[inst_name]
                # Collect the full instance statement until ');'
                inst_lines = [line]
                j = i + 1
                while j < len(lines) and ');' not in lines[j - 1] if j > i else True:
                    # keep reading until we find the line containing ');'
                    if ');' in lines[i]:
                        break
                    if j >= len(lines):
                        break
                    inst_lines.append(lines[j])
                    if ');' in lines[j]:
                        j += 1
                        break
                    j += 1

                # Find which pins are already connected
                full_text = ''.join(inst_lines)
                already_connected = set(re.findall(r'\.([A-Za-z_][A-Za-z0-9_]*)\s*\(', full_text))

                # Build the extra .PIN(WIRE) fragments
                extra = []
                for pin, wire in sorted(pins_to_add.items()):
                    if pin not in already_connected:
                        extra.append(f'{indent}    .{pin}({wire}),')
                        added += 1

                if extra:
                    # Insert extra ports before the line that contains ');'
                    # The ')' that closes the port list is on the last line
                    close_idx = len(inst_lines) - 1
                    close_line = inst_lines[close_idx]

                    # Find where ');' is in the closing line
                    close_pos = close_line.index(');')

                    # The part before ');'  may be just whitespace or a trailing ','
                    before = close_line[:close_pos].rstrip()
                    # If there was a last .PIN(x) connection it may not have a comma;
                    # we need to add commas properly.
                    # Replace the closing line with: comma-add the previous port +
                    # our new ports + closing ');\n'
                    if before and not before.rstrip().endswith(','):
                        inst_lines[close_idx] = before + ',\n'
                    else:
                        inst_lines[close_idx] = before + '\n' if before else ''

                    out_lines.extend(inst_lines)
                    for ep in extra:
                        # Remove trailing comma from last extra port
                        if ep is extra[-1]:
                            ep = ep.rstrip(',')
                        out_lines.append(ep + '\n')
                    out_lines.append(f'{indent});\n')
                else:
                    out_lines.extend(inst_lines)

                i = j
                continue

        out_lines.append(line)
        i += 1

    output_path.write_text(''.join(out_lines), encoding='utf-8')
    return added

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 3:
        print(f'Usage: {sys.argv[0]} synthetic_map.json netlist.v [output.v]',
              file=sys.stderr)
        sys.exit(1)

    json_in = Path(sys.argv[1])
    verilog_in = Path(sys.argv[2])
    if len(sys.argv) > 3:
        verilog_out = Path(sys.argv[3])
        in_place = False
    else:
        verilog_out = verilog_in
        in_place = True

    if not json_in.exists():
        print(f'ERROR: JSON map not found: {json_in}', file=sys.stderr)
        sys.exit(1)
    if not verilog_in.exists():
        print(f'ERROR: Verilog not found: {verilog_in}', file=sys.stderr)
        sys.exit(1)

    print('Loading synthetic pin map...', flush=True)
    patch_map = load_patch_map(json_in)
    print(f'  {len(patch_map)} instances need port additions')

    if in_place:
        tmp_fd, tmp_name = tempfile.mkstemp(suffix='.v', dir=verilog_in.parent)
        tmp_path = Path(tmp_name)
        try:
            os.close(tmp_fd)
            n = patch_verilog(verilog_in, patch_map, tmp_path)
            shutil.move(str(tmp_path), str(verilog_out))
        except Exception:
            tmp_path.unlink(missing_ok=True)
            raise
    else:
        n = patch_verilog(verilog_in, patch_map, verilog_out)

    print(f'patch_verilog_nc_ports: {n} port connection(s) added to {verilog_out}')

if __name__ == '__main__':
    main()
