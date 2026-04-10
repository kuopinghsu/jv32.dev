# ===========================================================================
# OpenLane 2 PDK configuration — Nangate 45nm Open Cell Library (FreePDK45)
# File: <PDK_ROOT>/freepdk45/libs.tech/openlane/config.tcl
#
# This file is sourced by OpenLane2 as the PDK-level config.
# It sets the default standard-cell library and top-level PDK parameters.
#
# Required environment variables (set in env.config or on command line):
#   NANGATE_HOME – root of the Nangate 45nm distribution, e.g.:
#                  /path/to/FreePDK45/NangateOpenCellLibrary
#                  Must contain:
#                    NangateOpenCellLibrary.tech.lef
#                    NangateOpenCellLibrary.macro.lef  (or .macro.mod.lef)
#                    NangateOpenCellLibrary.gds
# ===========================================================================

set ::env(PDK) "freepdk45"
set ::env(STD_CELL_LIBRARY) "NangateOpenCellLibrary"

# ── Power / ground nets ───────────────────────────────────────────────────────
set ::env(VDD_PIN) "VDD"
set ::env(GND_PIN) "VSS"
set ::env(VDD_NETS) "VDD"
set ::env(GND_NETS) "VSS"

# ── Nominal supply (1.1 V) ────────────────────────────────────────────────────
set ::env(SYNTH_CAP_LOAD) "10.0"

# ── Default timing corner ─────────────────────────────────────────────────────
set ::env(DEFAULT_CORNER) "tt_025C_1v10"
