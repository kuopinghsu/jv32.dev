# ===========================================================================
# OpenLane 2 SCL configuration — NangateOpenCellLibrary (FreePDK45 45nm)
# File: <PDK_ROOT>/freepdk45/libs.tech/openlane/NangateOpenCellLibrary/config.tcl
#
# Sourced by OpenLane2 after config.tcl to set standard-cell parameters.
#
# Required env:
#   NANGATE_HOME – path to FreePDK45 NangateOpenCellLibrary root containing:
#     NangateOpenCellLibrary.tech.lef
#     NangateOpenCellLibrary.macro.lef  (std-cell abstract LEF)
#     NangateOpenCellLibrary.gds
#     liberty/NangateOpenCellLibrary_typical.lib  (or _TT_1p10V_25C.lib)
#
# If NANGATE_HOME is not set, the Makefile falls back to the local copy of
# NangateOpenCellLibrary_typical.lib already present in syn/pdk/.
# ===========================================================================

# Resolve NANGATE_HOME — OpenLane2 clears ::env before evaluating PDK configs,
# so OS environment variables cannot be used here.  Resolution order:
#
#   1. A ".nangate_home" file in PDK_ROOT (portable override for any machine)
#   2. The default install location ~/opt/nangate (project convention)
#   3. The legacy path expected by the OpenFlow / OpenLane 1 tree layout
#
# To point to a different Nangate directory on your machine, create:
#   syn/pdk/.nangate_home
# containing the absolute path to the NangateOpenCellLibrary root.

set NANGATE_HOME ""

# 1. File-based override
set _nangate_cfg [file join $::env(PDK_ROOT) ".nangate_home"]
if { [file exists $_nangate_cfg] } {
    set NANGATE_HOME [string trim [exec cat $_nangate_cfg]]
}

# 2. Project-convention default: ~/opt/nangate
if { $NANGATE_HOME eq "" } {
    set _candidate [file normalize "~/opt/nangate"]
    if { [file isdir $_candidate] } {
        set NANGATE_HOME $_candidate
    }
}

# 3. Legacy fallback relative to PDK_ROOT (very rarely correct, kept for completeness)
if { $NANGATE_HOME eq "" } {
    set NANGATE_HOME [file normalize "$::env(PDK_ROOT)/../../"]
    puts "WARNING: NANGATE_HOME could not be found. Using fallback: $NANGATE_HOME"
    puts "         Create syn/pdk/.nangate_home with the path to your Nangate distribution."
}

set NANGATE $NANGATE_HOME

# ── Liberty timing libraries ──────────────────────────────────────────────────
# Try several common distribution layouts.
proc find_lib { base candidates } {
    foreach c $candidates {
        set f [file join $base $c]
        if { [file exists $f] } { return $f }
    }
    return ""
}

set LIB_TT [find_lib $NANGATE {
    liberty/NangateOpenCellLibrary_typical.lib
    NangateOpenCellLibrary_typical.lib
    lib/NangateOpenCellLibrary_typical.lib
}]

# Fall back to the local copy shipped with jv32
if { $LIB_TT eq "" } {
    set LIB_TT [file normalize "$::env(PDK_ROOT)/freepdk45/../NangateOpenCellLibrary_typical.lib"]
}
if { ![file exists $LIB_TT] } {
    error "NangateOpenCellLibrary_typical.lib not found. Set NANGATE_HOME correctly."
}

# LIB maps corner wildcard → list of liberty files
set ::env(LIB) "tt_025C_1v10 $LIB_TT"

# ── LEF files ─────────────────────────────────────────────────────────────────
# Technology LEF (metal layers, via rules)
set TECH_LEF [find_lib $NANGATE {
    NangateOpenCellLibrary.tech.lef
    compiledviews/techLEF/NangateOpenCellLibrary.tech.lef
    lef/NangateOpenCellLibrary.tech.lef
    views/lef/NangateOpenCellLibrary.tech.lef
}]

# Standard-cell abstract LEF
# Prefer the `.macro.mod.lef` variant: it includes the physical-only cells
# such as `TAPCELL_X1` that OpenROAD needs for tap/endcap insertion.
set MACRO_LEF [find_lib $NANGATE {
    NangateOpenCellLibrary.macro.mod.lef
    NangateOpenCellLibrary.macro.lef
    compiledviews/lef/NangateOpenCellLibrary.macro.mod.lef
    compiledviews/lef/NangateOpenCellLibrary.macro.lef
    views/lef/NangateOpenCellLibrary.macro.mod.lef
    views/lef/NangateOpenCellLibrary.macro.lef
    lef/NangateOpenCellLibrary.macro.mod.lef
    lef/NangateOpenCellLibrary.macro.lef
}]

if { $TECH_LEF eq "" || $MACRO_LEF eq "" } {
    error "Nangate LEF files not found under NANGATE_HOME=$NANGATE.\n\
           Expected: NangateOpenCellLibrary.tech.lef + NangateOpenCellLibrary.macro.lef\n\
           Set NANGATE_HOME to the FreePDK45 NangateOpenCellLibrary root."
}

set ::env(TECH_LEF)  $TECH_LEF
set ::env(TECH_LEFS) "tt_025C_1v10 $TECH_LEF"
set ::env(CELL_LEFS) $MACRO_LEF

# ── GDS ───────────────────────────────────────────────────────────────────────
set CELL_GDS [find_lib $NANGATE {
    NangateOpenCellLibrary.gds
    GDS/NangateOpenCellLibrary.gds
    gds/NangateOpenCellLibrary.gds
    compiledviews/gds/NangateOpenCellLibrary.gds
    views/gds/NangateOpenCellLibrary.gds
}]
if { $CELL_GDS ne "" } {
    set ::env(CELL_GDS) $CELL_GDS
}

# ── Placement site ────────────────────────────────────────────────────────────
# Nangate 45nm standard row height site
set ::env(PLACE_SITE) "FreePDK45_38x28_10R_NP_162NW_34O"

# ── Synthesis cell assignments ────────────────────────────────────────────────
set ::env(SYNTH_DRIVING_CELL)     "BUF_X2/A/Z"
set ::env(SYNTH_CLK_DRIVING_CELL) "CLKBUF_X2/A/Z"
set ::env(SYNTH_TIEHI_CELL)       "LOGIC1_X1/Z"
set ::env(SYNTH_TIELO_CELL)       "LOGIC0_X1/Z"
set ::env(SYNTH_BUFFER_CELL)      "BUF_X1/A/Z"

# ── Physical cells ────────────────────────────────────────────────────────────
# Match the Nangate platform's own `tapcell.tcl` settings.
set ::env(WELLTAP_CELL)   "TAPCELL_X1"
set ::env(ENDCAP_CELL)    "TAPCELL_X1"
# FILL_CELL (OpenLane2 name) replaces the old FILL_CELLS
set ::env(FILL_CELL)      "FILLCELL_X32 FILLCELL_X16 FILLCELL_X8 FILLCELL_X4 FILLCELL_X2 FILLCELL_X1"
set ::env(DECAP_CELL)     ""

# ── Antenna diode ─────────────────────────────────────────────────────────────
set ::env(DIODE_CELL) "ANTENNA_X1/A"

# ── Fanout / capacitance constraints ─────────────────────────────────────────
set ::env(MAX_FANOUT_CONSTRAINT)      6
set ::env(MAX_TRANSITION_CONSTRAINT)  1.5

# ── Timing constraints ────────────────────────────────────────────────────────
set ::env(CLOCK_UNCERTAINTY_CONSTRAINT) 0.25
set ::env(CLOCK_TRANSITION_CONSTRAINT)  0.15
set ::env(TIME_DERATING_CONSTRAINT)     5
set ::env(IO_DELAY_CONSTRAINT)          20

# ── Output load / drive strength ──────────────────────────────────────────────
set ::env(OUTPUT_CAP_LOAD) 10.0

# ── SCL power/ground pin names ───────────────────────────────────────────────
set ::env(SCL_POWER_PINS)  "VDD vdd"
set ::env(SCL_GROUND_PINS) "VSS gnd"

# ── Timing corners ────────────────────────────────────────────────────────────
# Single TT corner; extend with SS+FF if you generate those liberty files.
set ::env(STA_CORNERS) "tt_025C_1v10"

# ── Floorplan / routing parameters ───────────────────────────────────────────
# Derive the SCL directory from PDK_ROOT (info script doesn't work in
# OpenLane2's Tcl eval environment because the file is eval'd, not source'd).
set SCL_DIR [file normalize [file join $::env(PDK_ROOT) \
    "freepdk45/libs.tech/openlane/NangateOpenCellLibrary"]]
# Convenience variable for other PDK tech dirs
set PDK_LIB [file normalize [file join $::env(PDK_ROOT) "freepdk45/libs.tech"]]

# Use the repo-local tracks file in the legacy 4-column format expected by
# OpenLane2's `old_to_new_tracks()` helper.  The Nangate distribution's
# `tracks_1.2.0.info` already contains `make_tracks ...` commands and is not
# directly accepted here.
if { [file exists [file join $SCL_DIR "tracks.info"]] } {
    set ::env(FP_TRACKS_INFO) [file normalize [file join $SCL_DIR "tracks.info"]]
} elseif { [file exists [file join $NANGATE "tracks_1.2.0.info"]] } {
    set ::env(FP_TRACKS_INFO) [file normalize [file join $NANGATE "tracks_1.2.0.info"]]
} else {
    error "tracks.info not found for FP_TRACKS_INFO"
}
set ::env(FP_TAPCELL_DIST)  "120"

# ── Power distribution network (PDN) — M1-M4-M7 grid strategy ────────────────
# Rails (metal1): width 0.17 µm, from grid_strategy-M1-M4-M7.cfg
set ::env(FP_PDN_RAIL_LAYER)        "metal1"
set ::env(FP_PDN_RAIL_WIDTH)        "0.17"
set ::env(FP_PDN_RAIL_OFFSET)       "0"
# Horizontal stripes on metal4
set ::env(FP_PDN_HORIZONTAL_LAYER)  "metal4"
set ::env(FP_PDN_HWIDTH)            "0.48"
set ::env(FP_PDN_HPITCH)            "56.0"
set ::env(FP_PDN_HOFFSET)           "2.0"
set ::env(FP_PDN_HSPACING)          "1.0"
# Vertical stripes on metal7
set ::env(FP_PDN_VERTICAL_LAYER)    "metal7"
set ::env(FP_PDN_VWIDTH)            "1.40"
set ::env(FP_PDN_VPITCH)            "40.0"
set ::env(FP_PDN_VOFFSET)           "2.0"
set ::env(FP_PDN_VSPACING)          "1.0"
# Core ring dimensions
set ::env(FP_PDN_CORE_RING_VWIDTH)   "1.40"
set ::env(FP_PDN_CORE_RING_HWIDTH)   "0.48"
set ::env(FP_PDN_CORE_RING_VSPACING) "1.0"
set ::env(FP_PDN_CORE_RING_HSPACING) "1.0"
set ::env(FP_PDN_CORE_RING_VOFFSET)  "2.0"
set ::env(FP_PDN_CORE_RING_HOFFSET)  "2.0"

# ── Cell exclusion lists ──────────────────────────────────────────────────────
set ::env(SYNTH_EXCLUDED_CELL_FILE) [file normalize [file join $SCL_DIR "no_synth.cells"]]
set ::env(PNR_EXCLUDED_CELL_FILE)   [file normalize [file join $SCL_DIR "drc_exclude.cells"]]

# ── Cell padding ─────────────────────────────────────────────────────────────
set ::env(CELL_PAD_EXCLUDE) ""

# ── Verilog cell models ───────────────────────────────────────────────────────
# If a Verilog behavioral model exists, add it here (optional for PnR)
set CELL_VERILOG [find_lib $NANGATE {
    NangateOpenCellLibrary.v
    verilog/NangateOpenCellLibrary.v
    views/verilog/NangateOpenCellLibrary.v
}]
if { $CELL_VERILOG ne "" } {
    set ::env(CELL_VERILOG_MODELS) $CELL_VERILOG
}

# ── Global routing capacity adjustments ──────────────────────────────────────
# 10 metal layers (metal1-metal10); metal1 mostly reserved for power rails.
set ::env(GRT_LAYER_ADJUSTMENTS) "0.99,0,0,0,0,0,0,0,0,0"

# ── Placement cell padding ────────────────────────────────────────────────────
set ::env(GPL_CELL_PADDING) "4"
set ::env(DPL_CELL_PADDING) "2"

# ── Clock tree synthesis cells ────────────────────────────────────────────────
set ::env(CTS_ROOT_BUFFER)  "BUF_X4"
set ::env(CTS_CLK_BUFFERS)  "CLKBUF_X1 CLKBUF_X2 CLKBUF_X3"

# ── Antenna heuristic threshold (µm Manhattan distance) ──────────────────────
set ::env(HEURISTIC_ANTENNA_THRESHOLD) "90"

# ── Timing violation corners ──────────────────────────────────────────────────
set ::env(TIMING_VIOLATION_CORNERS) "tt_025C_1v10"

# ── Magic EDA configuration ──────────────────────────────────────────────────
# magic.tech ships with the Nangate distribution; a minimal stub satisfies
# MAGIC_PDK_SETUP and MAGICRC (Magic is not used for synthesis).
set ::env(MAGIC_TECH)      [file normalize [file join $NANGATE "magic.tech"]]
set ::env(MAGICRC)         [file normalize [file join $PDK_LIB "magic/freepdk45.magicrc"]]
set ::env(MAGIC_PDK_SETUP) [file normalize [file join $PDK_LIB "magic/freepdk45.tcl"]]

# ── KLayout configuration ────────────────────────────────────────────────────
# klayout.lyt and klayout.lyp ship with the Nangate distribution.
set ::env(KLAYOUT_TECH)          [file normalize [file join $NANGATE "klayout.lyt"]]
set ::env(KLAYOUT_PROPERTIES)    [file normalize [file join $NANGATE "klayout.lyp"]]
set ::env(KLAYOUT_DEF_LAYER_MAP) [file normalize [file join $PDK_LIB "klayout/freepdk45.map"]]

# ── Netgen LVS ───────────────────────────────────────────────────────────────
set ::env(NETGEN_SETUP) [file normalize [file join $PDK_LIB "netgen/freepdk45.tcl"]]

# ── OpenRCX parasitic extraction rulesets ────────────────────────────────────
# rcx_patterns.rules ships with the Nangate distribution.
set ::env(RCX_RULESETS) \
    "tt_025C_1v10 [file normalize [file join $NANGATE {rcx_patterns.rules}]]"
