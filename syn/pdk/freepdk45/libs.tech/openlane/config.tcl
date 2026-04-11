# ===========================================================================
# OpenLane 2 PDK configuration — Nangate 45nm Open Cell Library (FreePDK45)
# File: <PDK_ROOT>/freepdk45/libs.tech/openlane/config.tcl
# ===========================================================================

set ::env(PDK) "freepdk45"
set ::env(STD_CELL_LIBRARY) "NangateOpenCellLibrary"

# ── Power / ground nets ───────────────────────────────────────────────────────
set ::env(VDD_PIN)  "VDD"
set ::env(GND_PIN)  "VSS"
set ::env(VDD_NETS) "VDD"
set ::env(GND_NETS) "VSS"

# ── Nominal supply (1.1 V) ────────────────────────────────────────────────────
set ::env(VDD_PIN_VOLTAGE)  "1.1"
set ::env(SYNTH_CAP_LOAD)   "10.0"

# ── Default timing corner ─────────────────────────────────────────────────────
set ::env(DEFAULT_CORNER) "tt_025C_1v10"

# ── GDSII stream-out tool ─────────────────────────────────────────────────────
set ::env(PRIMARY_GDSII_STREAMOUT_TOOL) "klayout"

# ── Routing layers ────────────────────────────────────────────────────────────
# metal1 reserved for power rails; route signals on metal2-metal10
set ::env(RT_MIN_LAYER) "metal2"
set ::env(RT_MAX_LAYER) "metal10"

# IO pin layers (horizontal on metal3, vertical on metal2 for Nangate)
set ::env(FP_IO_HLAYER) "metal3"
set ::env(FP_IO_VLAYER) "metal2"
