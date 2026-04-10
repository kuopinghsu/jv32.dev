###############################################################################
# run_pnr.tcl — Standalone OpenROAD P&R flow for jv32_soc
#
# Process : Nangate 45nm Open Cell Library (FreePDK45)
# Target  : 100 MHz (10 ns period)
#
# Usage (invoked by 'make pnr' in syn/Makefile):
#   openroad -exit scripts/openroad/run_pnr.tcl
#
# Required environment variables set by Makefile:
#   NANGATE_DIR     – ~/opt/nangate  (platform files)
#   DESIGN          – jv32_soc
#   NETLIST         – path to synthesised gate-level netlist (.v)
#   SDC_FILE        – path to timing constraints (.sdc)
#   RESULTS_DIR     – directory for output DEF/ODB/GDS
#   REPORTS_DIR     – directory for reports
#   SRAM_LEF        – path to sram_1rw_32768x8.lef
#   SRAM_LIB        – path to sram_1rw_32768x8_TT_1p1V_25C.lib
#
# Optional:
#   CORE_UTIL       – core utilisation 0–100  (default 35)
#   MAX_ROUTING_LAYER – topmost routing layer (default metal7)
###############################################################################

set design          $::env(DESIGN)
set netlist         $::env(NETLIST)
set sdc_file        $::env(SDC_FILE)
set results_dir     $::env(RESULTS_DIR)
set reports_dir     $::env(REPORTS_DIR)
set nangate_dir     $::env(NANGATE_DIR)
set sram_lef        $::env(SRAM_LEF)
set sram_lib        $::env(SRAM_LIB)

set core_util       [expr { [info exists ::env(CORE_UTIL)]         ? $::env(CORE_UTIL)         : 35    }]
set max_route_layer [expr { [info exists ::env(MAX_ROUTING_LAYER)] ? $::env(MAX_ROUTING_LAYER) : "metal7" }]
set min_route_layer "metal2"

file mkdir $results_dir
file mkdir $reports_dir

###############################################################################
# 1 – Read technology + standard-cell + SRAM LEF
###############################################################################
puts "\n======================================================"
puts " \[1/9\] Reading LEFs"
puts "======================================================\n"

read_lef $nangate_dir/lef/NangateOpenCellLibrary.tech.lef
read_lef $nangate_dir/lef/NangateOpenCellLibrary.macro.mod.lef
read_lef $sram_lef

###############################################################################
# 2 – Read liberty (std-cell + SRAM macro)
###############################################################################
puts "\n======================================================"
puts " \[2/9\] Reading Liberty timing libraries"
puts "======================================================\n"

read_liberty $nangate_dir/lib/NangateOpenCellLibrary_typical.lib
read_liberty $sram_lib

###############################################################################
# 3 – Read synthesised Verilog netlist
###############################################################################
puts "\n======================================================"
puts " \[3/9\] Reading synthesised netlist: $netlist"
puts "======================================================\n"

read_verilog $netlist
link_design  $design

###############################################################################
# 4 – Timing constraints
###############################################################################
puts "\n======================================================"
puts " \[4/9\] Reading timing constraints: $sdc_file"
puts "======================================================\n"

read_sdc     $sdc_file
set_propagated_clock [all_clocks]

# Wire RC (Nangate 45nm values – signal on Metal3, clock on Metal5)
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

###############################################################################
# 5 – Floorplan
###############################################################################
puts "\n======================================================"
puts " \[5/9\] Floorplan  (util=$core_util%)"
puts "======================================================\n"

initialize_floorplan \
    -site    FreePDK45_38x28_10R_NP_162NW_34O \
    -utilization $core_util \
    -aspect_ratio 1.0 \
    -core_space "10.0 10.0 10.0 10.0"

# Route tracks
source $nangate_dir/tracks_1.2.0.info

# Power distribution network
pdngen::specify_grid stdcell {
    name grid
    rails {
        metal1 {width 0.17 pitch  2.4 offset 0}
    }
    straps {
        metal4 {width 0.48 pitch 56.0 offset 2}
        metal7 {width 1.40 pitch 40.0 offset 2}
    }
    connect {{metal1 metal4} {metal4 metal7}}
}

pdngen::specify_grid macro {
    orient {R0 R180 MX MY}
    power_pins "VDD VDDPE VDDCE"
    ground_pins "VSS VSSE"
    blockages "metal1 metal2 metal3 metal4"
    straps {
        metal5 {width 0.93 pitch 10.0 offset 2}
        metal6 {width 0.93 pitch 10.0 offset 2}
    }
    connect {{metal4_PIN_ver metal5} {metal5 metal6} {metal6 metal7}}
}

set_voltage_domain -name CORE -power VDD -ground VSS
pdngen

# SRAM macro placement: let OpenROAD auto-place (remove to specify manually)
#   Each SRAM (32768×8) ≈ 660 µm in OpenRAM freepdk45.
#   Adjust X/Y below if the auto-placement is not satisfactory.
# place_cell -cell sram_1rw_32768x8 -inst u_jv32_top/g_iram[0]/u_sram -origin {20 20} -orient R0
# ... etc for each of the 8 instances

###############################################################################
# 6 – Placement
###############################################################################
puts "\n======================================================"
puts " \[6/9\] Global + Detailed Placement"
puts "======================================================\n"

global_placement \
    -density [expr $core_util / 100.0] \
    -routability_driven \
    -timing_driven

tapcell \
    -distance 120 \
    -tapcell_master "TAPCELL_X1" \
    -endcap_master  "TAPCELL_X1"

detailed_placement

check_placement -verbose

write_def $results_dir/${design}_place.def

###############################################################################
# 7 – Clock Tree Synthesis
###############################################################################
puts "\n======================================================"
puts " \[7/9\] Clock Tree Synthesis (CTS)"
puts "======================================================\n"

set_wire_rc -signal -layer metal3
set_wire_rc -clock  -layer metal5

clock_tree_synthesis \
    -root_buf      CLKBUF_X3 \
    -buf_list     {CLKBUF_X1 CLKBUF_X2 CLKBUF_X3} \
    -sink_clustering_enable   1 \
    -sink_clustering_size    50 \
    -sink_clustering_max_diameter 50

set_propagated_clock [all_clocks]

estimate_parasitics -placement

repair_timing -setup -hold
detailed_placement
check_placement -verbose

write_def $results_dir/${design}_cts.def

###############################################################################
# 8 – Global + Detailed Routing
###############################################################################
puts "\n======================================================"
puts " \[8/9\] Routing"
puts "======================================================\n"

set_global_routing_layer_adjustment metal2 0.8
set_global_routing_layer_adjustment metal3 0.7
set_global_routing_layer_adjustment metal4-$max_route_layer 0.25

set_routing_layers \
    -signal  ${min_route_layer}-${max_route_layer} \
    -clock   metal5-${max_route_layer}

set_macro_extension 2

global_route \
    -guide_file $results_dir/${design}_route.guide

estimate_parasitics -global_routing

repair_timing -setup -hold -max_buffer_percent 40

detailed_route \
    -input_guide_file  $results_dir/${design}_route.guide \
    -verbose           1

check_antennas -report_file $reports_dir/antenna.rpt

write_def $results_dir/${design}_route.def

###############################################################################
# 9 – Final STA + write outputs
###############################################################################
puts "\n======================================================"
puts " \[9/9\] Post-Route STA + Write Views"
puts "======================================================\n"

estimate_parasitics -global_routing

# -----------------------------------------------------------------------------
# Timing reports
# -----------------------------------------------------------------------------
set timestamp [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]

proc write_timing_header {fp design corner ts} {
    puts $fp "# ================================================================"
    puts $fp "# jv32_soc Post-Route Static Timing Analysis"
    puts $fp "# Design  : $design"
    puts $fp "# Corner  : $corner"
    puts $fp "# Date    : $ts"
    puts $fp "# ================================================================"
    puts $fp ""
}

# Setup (max path delay)
set fp [open $reports_dir/timing_setup.rpt w]
write_timing_header $fp $design TT $timestamp
close $fp
report_checks \
    -path_delay max \
    -sort_by_slack \
    -fields {slew cap input nets fanout} \
    -format full_clock_expanded \
    -group_count 30 \
    >> $reports_dir/timing_setup.rpt

# Hold (min path delay)
set fp [open $reports_dir/timing_hold.rpt w]
write_timing_header $fp $design TT $timestamp
close $fp
report_checks \
    -path_delay min \
    -sort_by_slack \
    -fields {slew cap input nets fanout} \
    -format full_clock_expanded \
    -group_count 30 \
    >> $reports_dir/timing_hold.rpt

# Worst negative slack
set fp [open $reports_dir/timing_wns.rpt w]
write_timing_header $fp $design TT $timestamp
close $fp
report_wns  >> $reports_dir/timing_wns.rpt
report_tns  >> $reports_dir/timing_wns.rpt
report_worst_slack -max >> $reports_dir/timing_wns.rpt
report_worst_slack -min >> $reports_dir/timing_wns.rpt

# DRV: slew / capacitance / fanout violations
set fp [open $reports_dir/timing_drv.rpt w]
write_timing_header $fp $design TT $timestamp
close $fp
report_check_types \
    -max_slew -max_capacitance -max_fanout -violators \
    >> $reports_dir/timing_drv.rpt

# Power estimate
set fp [open $reports_dir/power.rpt w]
write_timing_header $fp $design TT $timestamp
close $fp
report_power >> $reports_dir/power.rpt

# Area
set fp [open $reports_dir/area.rpt w]
write_timing_header $fp $design TT $timestamp
close $fp
report_design_area >> $reports_dir/area.rpt

# Cell usage
set fp [open $reports_dir/cells.rpt w]
write_timing_header $fp $design TT $timestamp
close $fp
report_cell_usage >> $reports_dir/cells.rpt

# Unconstrained paths (should be empty on a well-constrained design)
report_checks -unconstrained -fields {slew cap input nets fanout} \
    >> $reports_dir/timing_setup.rpt

# Clock analysis
report_clock_skew >> $reports_dir/timing_setup.rpt

# -----------------------------------------------------------------------------
# Write final views
# -----------------------------------------------------------------------------
write_def       $results_dir/${design}_final.def
write_verilog   $results_dir/${design}_final.v
write_db        $results_dir/${design}_final.odb

puts "\n======================================================"
puts " P&R complete.  Results in: $results_dir/"
puts " Reports     : $reports_dir/"
puts "======================================================"
puts ""
puts "  Netlist   : $results_dir/${design}_final.v"
puts "  DEF       : $results_dir/${design}_final.def"
puts "  Database  : $results_dir/${design}_final.odb"
puts "  Timing    : $reports_dir/timing_setup.rpt"
puts "              $reports_dir/timing_hold.rpt"
puts "              $reports_dir/timing_wns.rpt"
