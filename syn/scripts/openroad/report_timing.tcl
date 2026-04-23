###############################################################################
# report_timing.tcl — Post-route Static Timing Analysis for jv32_soc
#
# Reads a finished routed database (ODB or DEF) and generates
# a full set of timing, power, and area reports using OpenROAD/OpenSTA.
#
# Usage (invoked by 'make timing-report' in syn/Makefile):
#   openroad -exit scripts/openroad/report_timing.tcl
#
# Required environment variables (set by Makefile):
#   NANGATE_DIR   – ~/opt/nangate
#   DESIGN        – jv32_soc
#   ODB_FILE      – results/<design>_final.odb  (or use DEF_FILE below)
#   SDC_FILE      – openlane/jv32_soc_pnr.sdc
#   REPORTS_DIR   – directory to write .rpt files into
#   SRAM_LEF      – path/to/sram_1rw_32768x8.lef
#   SRAM_LIB_TT   – TT corner liberty
#   SRAM_LIB_FF   – FF corner liberty (leave empty to skip)
#   SRAM_LIB_SS   – SS corner liberty (leave empty to skip)
#
# Optional:
#   DEF_FILE      – use this DEF instead of ODB (ODB takes priority)
#   CORNER        – label string for report headers (default "TT_1p1V_25C")
###############################################################################

# ---------------------------------------------------------------------------
# Helper: safely get an env variable; return default if unset.
# ---------------------------------------------------------------------------
proc env_or_default {var default} {
    if {[info exists ::env($var)] && $::env($var) ne ""} {
        return $::env($var)
    }
    return $default
}

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------
set design      $::env(DESIGN)
set nangate_dir $::env(NANGATE_DIR)
set sdc_file    $::env(SDC_FILE)
set reports_dir $::env(REPORTS_DIR)
set sram_lef    $::env(SRAM_LEF)
set sram_lib_tt $::env(SRAM_LIB_TT)
set sram_lib_ff [env_or_default SRAM_LIB_FF ""]
set sram_lib_ss [env_or_default SRAM_LIB_SS ""]

set corner      [env_or_default CORNER "TT_1p1V_25C"]
set odb_file    [env_or_default ODB_FILE ""]
set def_file    [env_or_default DEF_FILE ""]

if {$odb_file eq "" && $def_file eq ""} {
    error "ERROR: set ODB_FILE or DEF_FILE environment variable before running this script."
}

file mkdir $reports_dir

set timestamp [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]

###############################################################################
# read_lefs
###############################################################################
puts "\n===================================================="
puts " \[1/5\] Reading LEFs"
puts "====================================================\n"

read_lef $nangate_dir/lef/NangateOpenCellLibrary.tech.lef
read_lef $nangate_dir/lef/NangateOpenCellLibrary.macro.mod.lef
read_lef $sram_lef

###############################################################################
# read_liberty
###############################################################################
puts "\n===================================================="
puts " \[2/5\] Reading Liberty files  (corner: $corner)"
puts "====================================================\n"

read_liberty $nangate_dir/lib/NangateOpenCellLibrary_typical.lib
read_liberty $sram_lib_tt
if {$sram_lib_ff ne ""} { read_liberty $sram_lib_ff }
if {$sram_lib_ss ne ""} { read_liberty $sram_lib_ss }

###############################################################################
# Read design database (ODB preferred, DEF fallback)
###############################################################################
puts "\n===================================================="
puts " \[3/5\] Reading design database"
puts "====================================================\n"

if {$odb_file ne ""} {
    puts "  Using ODB: $odb_file"
    read_db $odb_file
    # ODB already contains the fully linked P&R database; link_design is not
    # needed (and will error STA-1000 if called on an ODB-loaded design).
} else {
    puts "  Using DEF: $def_file"
    read_def $def_file
    link_design $design
}

###############################################################################
# Constraints + wire RC
###############################################################################
puts "\n===================================================="
puts " \[4/5\] Applying SDC constraints"
puts "====================================================\n"

read_sdc $sdc_file
set_propagated_clock [all_clocks]

# Nangate 45nm layer RC
set_layer_rc -layer metal1 -resistance 5.4286e-03 -capacitance 7.41819e-02
set_layer_rc -layer metal2 -resistance 3.5714e-03 -capacitance 6.74606e-02
set_layer_rc -layer metal3 -resistance 3.5714e-03 -capacitance 8.88758e-02
set_layer_rc -layer metal4 -resistance 1.5000e-03 -capacitance 1.07121e-01
set_layer_rc -layer metal5 -resistance 1.5000e-03 -capacitance 1.08964e-01
set_layer_rc -layer metal6 -resistance 1.5000e-03 -capacitance 1.02044e-01
set_layer_rc -layer metal7 -resistance 1.8750e-04 -capacitance 1.10436e-01
set_layer_rc -layer metal8 -resistance 1.8750e-04 -capacitance 9.69714e-02
set_wire_rc -signal -layer metal3
set_wire_rc -clock  -layer metal5

# For a routed design, use global-routing parasitic estimation.
# Falls back gracefully if the design is placement-only (no guides).
if {[catch {estimate_parasitics -global_routing} err]} {
    puts "WARNING: global_routing parasitics unavailable, using placement: $err"
    estimate_parasitics -placement
}

###############################################################################
# Reports
###############################################################################
puts "\n===================================================="
puts " \[5/5\] Generating reports → $reports_dir/"
puts "====================================================\n"

# ---------------------------------------------------------------------------
# Helper: write a banner header into a file
# ---------------------------------------------------------------------------
proc write_rpt_header {path title design corner ts} {
    set fp [open $path w]
    puts $fp "#=================================================================="
    puts $fp "# jv32_soc Static Timing Analysis"
    puts $fp "# $title"
    puts $fp "# Design  : $design"
    puts $fp "# Corner  : $corner"
    puts $fp "# Date    : $ts"
    puts $fp "#=================================================================="
    puts $fp ""
    close $fp
    return $path
}

# -- Setup (max) -----------------------------------------------------------
set rpt $reports_dir/timing_setup.rpt
write_rpt_header $rpt "Setup (max path delay)" $design $corner $timestamp

report_checks \
    -path_delay max \
    -sort_by_slack \
    -fields {slew cap input nets fanout} \
    -format full_clock_expanded \
    -group_count 30 \
    >> $rpt

report_clock_skew \
    >> $rpt

report_checks -unconstrained \
    -fields {slew cap input nets fanout} \
    >> $rpt

puts "  Written: $rpt"

# -- Hold (min) ------------------------------------------------------------
set rpt $reports_dir/timing_hold.rpt
write_rpt_header $rpt "Hold (min path delay)" $design $corner $timestamp

report_checks \
    -path_delay min \
    -sort_by_slack \
    -fields {slew cap input nets fanout} \
    -format full_clock_expanded \
    -group_count 30 \
    >> $rpt

puts "  Written: $rpt"

# -- WNS / TNS summary -----------------------------------------------------
set rpt $reports_dir/timing_summary.rpt
write_rpt_header $rpt "WNS / TNS summary" $design $corner $timestamp

set fp [open $rpt a]
puts $fp "# --- Setup ---"
close $fp
report_worst_slack -max >> $rpt
report_wns >> $rpt
report_tns >> $rpt

set fp [open $rpt a]
puts $fp ""
puts $fp "# --- Hold ---"
close $fp
report_worst_slack -min >> $rpt

puts "  Written: $rpt"

# -- DRV: slew / cap / fanout violations -----------------------------------
set rpt $reports_dir/timing_drv.rpt
write_rpt_header $rpt "Design Rule Violations" $design $corner $timestamp

report_check_types \
    -max_slew -max_capacitance -max_fanout \
    -violators \
    >> $rpt

puts "  Written: $rpt"

# -- Power -----------------------------------------------------------------
set rpt $reports_dir/power.rpt
write_rpt_header $rpt "Power estimate" $design $corner $timestamp
report_power >> $rpt
puts "  Written: $rpt"

# ---------------------------------------------------------------------------
# Helper: run a command and append its captured output to a report file.
# OpenROAD-native commands (report_cts, report_cell_usage, report_congestion,
# report_design_area) write through the C++ logger or OpenSTA reporter rather
# than plain Tcl stdout, so plain Tcl '>> file' redirection does not work.
# We try three mechanisms in order:
#   1. ord::redirect_file_begin / ord::redirect_file_end  (OpenROAD ≥ 2.x)
#   2. sta_redirect_file_begin / sta_redirect_file_end    (OpenSTA built-in)
#   3. Bare execution – output lands in timing_run.log via the Makefile tee;
#      a post-processing script (extract_from_log.py) recovers it afterward.
# ---------------------------------------------------------------------------
proc openroad_rpt {rpt_file cmd} {
    set tmp "${rpt_file}.tmp"

    # Method 1: ord::redirect_file_begin (captures logger + OpenSTA reporter)
    if {![catch {
        ord::redirect_file_begin $tmp
        catch {eval $cmd}
        ord::redirect_file_end
    }]} {
        if {[file exists $tmp] && [file size $tmp] > 0} {
            set fi [open $tmp r]; set data [read $fi]; close $fi
            set fo [open $rpt_file a]; puts -nonewline $fo $data; close $fo
        }
        catch {file delete $tmp}
        return
    }
    catch {ord::redirect_file_end}
    catch {file delete $tmp}

    # Method 2: sta_redirect_file_begin (OpenSTA reporter only)
    if {![catch {
        sta_redirect_file_begin $tmp
        catch {eval $cmd}
        sta_redirect_file_end
    }]} {
        if {[file exists $tmp] && [file size $tmp] > 0} {
            set fi [open $tmp r]; set data [read $fi]; close $fi
            set fo [open $rpt_file a]; puts -nonewline $fo $data; close $fo
        }
        catch {file delete $tmp}
        return
    }
    catch {sta_redirect_file_end}
    catch {file delete $tmp}

    # Fallback: bare execution – output goes to timing_run.log
    set fp [open $rpt_file a]
    puts $fp "# Output written to timing_run.log (redirect unavailable)"
    close $fp
    catch {eval $cmd}
}

# -- Area ------------------------------------------------------------------
set rpt $reports_dir/area.rpt
write_rpt_header $rpt "Design area" $design $corner $timestamp
openroad_rpt $rpt { report_design_area }
puts "  Written: $rpt"

# -- Clock tree ------------------------------------------------------------
set rpt $reports_dir/cts.rpt
write_rpt_header $rpt "Clock tree" $design $corner $timestamp
openroad_rpt $rpt { report_cts }
puts "  Written: $rpt"

# -- Cell usage ------------------------------------------------------------
set rpt $reports_dir/cells.rpt
write_rpt_header $rpt "Cell usage" $design $corner $timestamp
openroad_rpt $rpt { report_cell_usage }
puts "  Written: $rpt"

# -- Routing congestion (may be absent for pre-route databases) -----------
set rpt $reports_dir/congestion.rpt
write_rpt_header $rpt "Routing congestion" $design $corner $timestamp
if {[catch { openroad_rpt $rpt { report_congestion } } err]} {
    puts "NOTE: report_congestion skipped ($err)"
}
puts "  Written: $rpt"

# Done
puts "\n===================================================="
puts " Timing analysis complete."
puts " Reports written to: $reports_dir/"
puts "===================================================="
