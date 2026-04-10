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

# Resolve NANGATE_HOME (must be set before invoking OpenLane2)
if { ![info exists ::env(NANGATE_HOME)] } {
    # Fall back: assume the lib file lives next to PDK_ROOT
    set ::env(NANGATE_HOME) [file normalize "$::env(PDK_ROOT)/../../"]
    puts "WARNING: NANGATE_HOME not set. Using fallback: $::env(NANGATE_HOME)"
    puts "         Set NANGATE_HOME to the FreePDK45 NangateOpenCellLibrary root."
}

set NANGATE $::env(NANGATE_HOME)

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
set MACRO_LEF [find_lib $NANGATE {
    NangateOpenCellLibrary.macro.lef
    NangateOpenCellLibrary.macro.mod.lef
    compiledviews/lef/NangateOpenCellLibrary.macro.lef
    views/lef/NangateOpenCellLibrary.macro.mod.lef
    lef/NangateOpenCellLibrary.macro.lef
}]

if { $TECH_LEF eq "" || $MACRO_LEF eq "" } {
    error "Nangate LEF files not found under NANGATE_HOME=$NANGATE.\n\
           Expected: NangateOpenCellLibrary.tech.lef + NangateOpenCellLibrary.macro.lef\n\
           Set NANGATE_HOME to the FreePDK45 NangateOpenCellLibrary root."
}

set ::env(TECH_LEF)  $TECH_LEF
set ::env(CELL_LEFS) $MACRO_LEF

# ── GDS ───────────────────────────────────────────────────────────────────────
set CELL_GDS [find_lib $NANGATE {
    NangateOpenCellLibrary.gds
    GDS/NangateOpenCellLibrary.gds
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
set ::env(WELLTAP_CELL)   "TAPCELL_X1"
set ::env(ENDCAP_CELL)    "FILLCELL_X4"
set ::env(FILL_CELLS)     "FILLCELL_X32 FILLCELL_X16 FILLCELL_X8 FILLCELL_X4 FILLCELL_X2 FILLCELL_X1"
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

# ── Exclude lists (no cells to exclude for basic Nangate flow) ────────────────
set ::env(SYNTH_EXCLUDED_CELL_FILE)  ""
set ::env(PNR_EXCLUDED_CELL_FILE)    ""

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
