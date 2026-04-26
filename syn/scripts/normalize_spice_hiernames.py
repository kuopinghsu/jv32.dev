#!/usr/bin/env python3
"""Rename hierarchical instance/pin net names in a SPICE file to match Verilog.

Magic sometimes names nets using the convention  INSTNAME/PINNAME  when a net
connects to only a single device pin (e.g. a DFF QN output whose only other
connection was an ANTENNA_X1 diode that has since been ignored).

Netgen cannot match these hierarchical names against the flat wire names used
in the Verilog netlist, causing all such nets to collapse into one large
unresolvable partition group.

This script builds a mapping  (instance_name, pin_name) -> verilog_wire_name
from the Verilog netlist, then rewrites the SPICE net tokens from
  INSTNAME/PINNAME  ->  verilog_wire_name
so both circuits use the same net names.

Usage:
    python3 normalize_spice_hiernames.py spice.spice netlist.v [output.spice]
"""

import re
import sys
import os
import shutil
import tempfile
from pathlib import Path

# ---------------------------------------------------------------------------
# Step 1 – Parse Verilog to build (instname, pinname) -> wirename map
# ---------------------------------------------------------------------------

# Matches a complete instance statement across multiple lines.
# Captures: cell_type, instance_name, port_list
# Strategy: read the Verilog line-by-line, accumulate until we see ');'
_PIN_CONN_RE = re.compile(r'\.([A-Za-z0-9_]+)\s*\(\s*([^)]*?)\s*\)')

def build_pin_map(verilog_path: Path) -> dict:
    """Return {(inst_name, pin_name): wire_name} from a Verilog netlist."""
    pin_map = {}
    text = verilog_path.read_text(encoding='utf-8', errors='replace')

    # Join logical lines: find instance declarations by accumulating tokens
    # between two consecutive non-comment identifiers followed by '(' and ');'
    # Simpler approach: scan for CELLTYPE INSTNAME ( ... );  blocks
    # We'll do a single-pass accumulator
    lines = iter(text.splitlines())
    accum = ''
    inst_header_re = re.compile(
        r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s+([A-Za-z_\\][A-Za-z0-9_\[\]\\. ]*?)\s*\('
    )
    in_inst = False
    inst_name = None

    for raw_line in lines:
        line = raw_line.strip()
        # Skip comments and wire/module declarations
        if not line or line.startswith('//') or line.startswith('`') \
                or line.startswith('module') or line.startswith('endmodule') \
                or line.startswith('wire') or line.startswith('input') \
                or line.startswith('output'):
            continue

        if not in_inst:
            # Try to start a new instance
            m = inst_header_re.match(raw_line)
            if m:
                cell_type = m.group(1)
                # Strip Verilog escaped identifier syntax: leading \ and trailing space
                raw_iname = m.group(2).strip()
                if raw_iname.startswith('\\'):
                    raw_iname = raw_iname[1:].rstrip()
                inst_name = raw_iname
                accum = raw_line
                in_inst = True
                if ');' in raw_line:
                    # Single-line instance
                    for pm in _PIN_CONN_RE.finditer(accum):
                        pin = pm.group(1)
                        wire = pm.group(2).strip()
                        if wire.startswith('\\'):
                            wire = wire[1:].rstrip()
                        pin_map[(inst_name, pin)] = wire
                    in_inst = False
                    accum = ''
        else:
            accum += ' ' + line
            if ');' in line:
                for pm in _PIN_CONN_RE.finditer(accum):
                    pin = pm.group(1)
                    wire = pm.group(2).strip()
                    if wire.startswith('\\'):
                        wire = wire[1:].rstrip()
                    pin_map[(inst_name, pin)] = wire
                in_inst = False
                accum = ''

    return pin_map

# ---------------------------------------------------------------------------
# Step 2 – Find all INST/PIN tokens in SPICE and build a replacement map
# ---------------------------------------------------------------------------

_HIER_NET_RE = re.compile(r'([A-Za-z0-9_.]+)/([A-Za-z0-9]+)(?=\s)')

def build_spice_rename_map(spice_path: Path, pin_map: dict) -> dict:
    """Return {spice_hier_name: verilog_wire_name} by scanning SPICE for X/Y patterns.

    For hier nets that cannot be found in the Verilog pin_map (because the port is
    unconnected in the Verilog), a synthetic wire name is generated using the
    pattern  __INST__PIN__  so that callers can later add these as explicit port
    connections to the Verilog netlist.
    """
    rename = {}
    not_found = {}   # hier_name -> (inst, pin)

    with open(spice_path, encoding='utf-8', errors='replace') as f:
        for line in f:
            if line.startswith('*') or line.startswith('.'):
                continue
            for m in _HIER_NET_RE.finditer(line):
                hier = m.group(0)
                inst = m.group(1)
                pin = m.group(2)
                if hier in rename or hier in not_found:
                    continue
                key = (inst, pin)
                if key in pin_map:
                    wire = pin_map[key]
                    rename[hier] = wire
                else:
                    not_found[hier] = (inst, pin)

    # For unresolved hiers, generate synthetic names so both SPICE and Verilog
    # can use the same wire name after the Verilog is patched.
    synthetic = {}
    for hier, (inst, pin) in not_found.items():
        # Keep only alphanumeric and underscore; replace everything else with _
        safe_inst = re.sub(r'[^A-Za-z0-9_]', '_', inst)
        safe_pin = re.sub(r'[^A-Za-z0-9_]', '_', pin)
        syn_name = f'__{safe_inst}__{safe_pin}__'
        rename[hier] = syn_name
        synthetic[hier] = (inst, pin, syn_name)

    return rename, not_found, synthetic

# ---------------------------------------------------------------------------
# Step 3 – Apply the renaming to the SPICE file
# ---------------------------------------------------------------------------

def apply_rename(spice_path: Path, rename: dict, output_path: Path) -> int:
    """Replace hierarchical net names in SPICE.  Returns replacement count."""
    if not rename:
        return 0

    # Build a single regex that matches any of the hier names (as whole tokens)
    # Sort longest-first to avoid partial matches
    escaped = [re.escape(k) for k in sorted(rename.keys(), key=len, reverse=True)]
    pattern = re.compile(r'(?<!\S)(' + '|'.join(escaped) + r')(?=\s)')

    total = 0

    def _repl(m):
        nonlocal total
        old = m.group(1)
        new_name = rename[old]
        # If the new name needs Verilog escaped-identifier format (contains brackets)
        # convert it.  Plain underscore names are used as-is.
        if '[' in new_name and not new_name.startswith('\\'):
            result = '\\' + new_name + ' '
        else:
            result = new_name
        total += 1
        return result

    text = spice_path.read_text(encoding='utf-8', errors='replace')
    new_text = pattern.sub(_repl, text)
    output_path.write_text(new_text, encoding='utf-8')
    return total

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 3:
        print(f'Usage: {sys.argv[0]} input.spice netlist.v [output.spice]',
              file=sys.stderr)
        sys.exit(1)

    spice_in = Path(sys.argv[1])
    verilog = Path(sys.argv[2])
    if len(sys.argv) > 3:
        spice_out = Path(sys.argv[3])
        in_place = False
    else:
        spice_out = spice_in
        in_place = True

    if not spice_in.exists():
        print(f'ERROR: SPICE file not found: {spice_in}', file=sys.stderr)
        sys.exit(1)
    if not verilog.exists():
        print(f'ERROR: Verilog file not found: {verilog}', file=sys.stderr)
        sys.exit(1)

    print('Building pin map from Verilog...', flush=True)
    pin_map = build_pin_map(verilog)
    print(f'  {len(pin_map)} (instance, pin) -> wire entries loaded')

    print('Scanning SPICE for hierarchical net names...', flush=True)
    rename, not_found, synthetic = build_spice_rename_map(spice_in, pin_map)
    resolved = len(rename) - len(synthetic)
    print(f'  {resolved} hier nets mapped from Verilog, '
          f'{len(synthetic)} unresolved (synthetic names generated)')
    if synthetic:
        print(f'  Synthetic examples: {list(synthetic.keys())[:5]}')

    # Write the synthetic mapping for patch_verilog_nc_ports.py
    synth_map_path = spice_in.with_suffix('.hiernames_synthetic.json')
    import json as _json
    synth_data = {hier: {'inst': inst, 'pin': pin, 'wire': syn}
                  for hier, (inst, pin, syn) in synthetic.items()}
    synth_map_path.write_text(_json.dumps(synth_data, indent=2), encoding='utf-8')
    print(f'  Synthetic map written to: {synth_map_path}')

    if in_place:
        tmp_fd, tmp_name = tempfile.mkstemp(suffix='.spice', dir=spice_in.parent)
        tmp_path = Path(tmp_name)
        try:
            os.close(tmp_fd)
            n = apply_rename(spice_in, rename, tmp_path)
            shutil.move(str(tmp_path), str(spice_out))
        except Exception:
            tmp_path.unlink(missing_ok=True)
            raise
    else:
        n = apply_rename(spice_in, rename, spice_out)

    print(f'normalize_spice_hiernames: {n} hierarchical net name(s) renamed in {spice_out}')

if __name__ == '__main__':
    main()
