#!/usr/bin/env bash
# normalize_before_lvs.sh — Prepare Magic-extracted SPICE and powered Verilog
# for Netgen LVS.  Safe to call multiple times (all steps are idempotent).
#
# Usage:
#   normalize_before_lvs.sh SPICE_FILE PNL_FILE [PYTHON3]
#
# SPICE_FILE : path to the Magic-extracted .spice (e.g. jv32_soc.spice)
# PNL_FILE   : path to the powered Verilog netlist (e.g. jv32_soc.pnl.v)
# PYTHON3    : python3 binary to use (default: python3)
#
# What this script does:
#   1. Creates .orig backups of SPICE and PNL on the first call.
#   2. Strips physical-only cells (ANTENNA, FILLCELL, TAPCELL) from PNL.
#   3. Normalizes fragmented VDD/VSS rail names in SPICE (hold63/VDD → VDD,
#      wire857/VSS → VSS, FILLER_xxx/VSS → VSS, u_sub/vdd → VDD, …).
#   4. Normalizes bracket-escaped net names (name\[n\] → \name[n] ).
#   5. Normalizes X-element instance names (g_bank\[0\] → g_bank[0]).
#   6. Remaps hierarchical inst/pin net names to the Verilog wire names.
#      Unresolved pins (NC outputs) get synthetic names __INST__PIN__.
#   7. Patches PNL to add explicit .PIN(wire) connections for NC output pins
#      whose synthetic names were generated in step 6.
#
set -euo pipefail

SPICE="${1:?Usage: $0 SPICE_FILE PNL_FILE [PYTHON3]}"
PNL="${2:?Usage: $0 SPICE_FILE PNL_FILE [PYTHON3]}"
PYTHON3="${3:-python3}"

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SPICE" ]; then
    echo "ERROR: SPICE file not found: $SPICE" >&2
    exit 1
fi

echo "======================================="
echo " Pre-LVS normalization"
echo "  SPICE : $SPICE"
echo "  PNL   : $PNL"
echo "======================================="

# ── Step 0: Create .orig backups on first call; restore on subsequent calls ──
if [ ! -f "${SPICE}.orig" ]; then
    cp "$SPICE" "${SPICE}.orig"
    echo " Original SPICE backed up → ${SPICE}.orig"
else
    cp "${SPICE}.orig" "$SPICE"
    echo " Restored SPICE from backup → ${SPICE}.orig"
fi
if [ -f "$PNL" ]; then
    if [ ! -f "${PNL}.orig" ]; then
        cp "$PNL" "${PNL}.orig"
        echo " Original PNL backed up   → ${PNL}.orig"
    else
        cp "${PNL}.orig" "$PNL"
        echo " Restored PNL from backup  → ${PNL}.orig"
    fi
fi

# ── Step 1: Strip physical-only cells from PNL ───────────────────────────────
if [ -f "$PNL" ]; then
    "$PYTHON3" "$SCRIPTS_DIR/strip_physical_cells_verilog.py" "$PNL"
fi

# ── Steps 2-4: Power / bracket / instance-name normalization in SPICE ────────
"$PYTHON3" "$SCRIPTS_DIR/normalize_spice_power.py" "$SPICE"

# ── Step 5-6: Hierarchical inst/pin → Verilog wire name mapping ─────────────
if [ -f "$PNL" ]; then
    "$PYTHON3" "$SCRIPTS_DIR/normalize_spice_hiernames.py" "$SPICE" "$PNL"

    # ── Step 7: Patch PNL for NC output ports (synthetic names) ─────────────
    SYNTH_MAP="${SPICE%.spice}.hiernames_synthetic.json"
    if [ -f "$SYNTH_MAP" ] && [ "$(wc -l < "$SYNTH_MAP")" -gt 2 ]; then
        "$PYTHON3" "$SCRIPTS_DIR/patch_verilog_nc_ports.py" "$SYNTH_MAP" "$PNL"
    fi
fi

echo "======================================="
echo " Pre-LVS normalization complete."
echo "======================================="
