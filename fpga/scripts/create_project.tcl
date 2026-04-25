# =============================================================================
# File   : create_project.tcl
# Project: JV32 RISC-V SoC
# Brief  : Vivado project creation, synthesis, implementation, and bitstream
#          generation script.
#
# Invocation (via fpga/Makefile):
#   vivado -mode batch -notrace -source vivado/create_project.tcl
#
# Environment variables consumed
# --------------------------------
#   PROJ_NAME        project name            (default: jv32_ku5p)
#   PROJ_DIR         project directory       (default: fpga/build)
#                    relative to repo root
#   TOP_MODULE       HDL top module          (default: jv32_fpga_top)
#   FPGA_PART        Xilinx part number      (default: xcku5pffvb676-2)
#   JV32_CLK_HZ      system clock frequency  (default: 50000000)
#   RUN_SYNTH        1 = run synthesis       (default: 0)
#   RUN_IMPL         1 = run impl+bitstream  (default: 0)
# =============================================================================

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
proc getenv {name default} {
    if {[info exists ::env($name)]} {
        return $::env($name)
    }
    return $default
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
set proj_name  [getenv PROJ_NAME  "jv32_ku5p"]
set proj_dir   [getenv PROJ_DIR   "fpga/build"]
set top_module [getenv TOP_MODULE "jv32_fpga_top"]
set fpga_part  [getenv FPGA_PART  "xcku5p-ffvb676-2-i"]
set clk_hz     [getenv JV32_CLK_HZ "50000000"]
set run_synth  [getenv RUN_SYNTH  "0"]
set run_impl   [getenv RUN_IMPL   "0"]
set flash_part [getenv FLASH_PART "mt25ql256-spi-x1_x2_x4"]
set flash_part [getenv FLASH_PART "mt25ql256-spi-x1_x2_x4"]
set use_cjtag  [getenv USE_CJTAG  "0"]

# Derive absolute paths from the script location so the project can be
# created from any working directory.
set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize "${script_dir}/../.."]
set proj_path  [file normalize "${repo_root}/${proj_dir}"]
set rtl_dir    "${repo_root}/rtl"
set fpga_rtl   "${script_dir}"

puts "============================================================"
puts " JV32 Vivado flow"
puts "   Part      : ${fpga_part}"
puts "   Project   : ${proj_path}/${proj_name}"
puts "   Top module: ${top_module}"
puts "   CLK Hz    : ${clk_hz}"
puts "   USE_CJTAG : ${use_cjtag}"
puts "   run_synth : ${run_synth}"
puts "   run_impl  : ${run_impl}"
puts "   flash_part: ${flash_part}"
puts "============================================================"

# ---------------------------------------------------------------------------
# Create project
# ---------------------------------------------------------------------------
create_project -force ${proj_name} ${proj_path} -part ${fpga_part}

set_property target_language    Verilog [current_project]
set_property default_lib        work    [current_project]

# XILINX_URAM selects the UltraRAM inference path in sram_1rw.sv (XCKU5P).
# IFETCH_PREADVANCE pre-advances the fetch address combinatorially for lower CPI.
set_property verilog_define {XILINX_URAM IFETCH_PREADVANCE} [current_fileset]

# USE_CJTAG parameter override: 0=4-wire JTAG (default), 1=2-wire cJTAG.
# Also read by constraints.xdc to select JTAG delays vs cJTAG false-paths.
set_property generic "USE_CJTAG=1'b${use_cjtag}" [current_fileset]

# ---------------------------------------------------------------------------
# Add RTL source files
# ---------------------------------------------------------------------------

# jv32_dbgmsg.svh is marked as a global include so its `define macros are
# visible to every compilation unit regardless of compile order.
set macros_hdr ${rtl_dir}/jv32/jv32_dbgmsg.svh
add_files -norecurse $macros_hdr
set_property file_type {SystemVerilog Header} [get_files $macros_hdr]
set_property is_global_include true           [get_files $macros_hdr]

# Collect all .sv files from the RTL tree
set rtl_files [list ${rtl_dir}/jv32/core/jv32_pkg.sv]
set rtl_files [concat $rtl_files \
    [glob -nocomplain ${rtl_dir}/*.sv          ] \
    [glob -nocomplain ${rtl_dir}/axi/*.sv      ] \
    [glob -nocomplain ${rtl_dir}/jv32/*.sv     ] \
    [glob -nocomplain ${rtl_dir}/jv32/core/*.sv] \
    [glob -nocomplain ${rtl_dir}/jv32/core/jtag/*.sv] \
    [glob -nocomplain ${rtl_dir}/memories/*.sv ] \
]

# FPGA-specific top-level wrapper
lappend rtl_files ${fpga_rtl}/jv32_fpga_top.sv

add_files -norecurse $rtl_files

# Mark files as SystemVerilog explicitly
foreach f $rtl_files {
    set_property file_type SystemVerilog [get_files $f]
}

# Plain Verilog BD wrapper for jv32_soc – must be Verilog (not SystemVerilog)
# so Vivado accepts it as a BD RTL module reference (-type module -reference).
add_files -norecurse ${fpga_rtl}/jv32_soc_fpga.v
set_property file_type Verilog [get_files jv32_soc_fpga.v]

# ---------------------------------------------------------------------------
# Add constraints
# ---------------------------------------------------------------------------
add_files -fileset constrs_1 -norecurse ${fpga_rtl}/constraints.xdc
set_property PROCESSING_ORDER NORMAL [get_files constraints.xdc]

# Mode-specific implementation-only constraints: add only the file that
# matches USE_CJTAG.  These contain no Tcl 'if' — the selection is done here
# in Tcl where it is fully supported, so each XDC is plain constraint commands.
if {$use_cjtag == "1"} {
    add_files -fileset constrs_1 -norecurse ${fpga_rtl}/constraints_cjtag.xdc
    set_property used_in_synthesis false [get_files constraints_cjtag.xdc]
    set_property PROCESSING_ORDER NORMAL [get_files constraints_cjtag.xdc]
} else {
    add_files -fileset constrs_1 -norecurse ${fpga_rtl}/constraints_jtag.xdc
    set_property used_in_synthesis false [get_files constraints_jtag.xdc]
    set_property PROCESSING_ORDER NORMAL [get_files constraints_jtag.xdc]
}

# ---------------------------------------------------------------------------
# Create block design (sources create_bd.tcl which also sets the top)
# ---------------------------------------------------------------------------
source ${fpga_rtl}/create_bd.tcl

# ---------------------------------------------------------------------------
# Synthesis strategy
# ---------------------------------------------------------------------------
set_property strategy "Vivado Synthesis Defaults" [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt [get_runs synth_1]

# ---------------------------------------------------------------------------
# Implementation strategy
# ---------------------------------------------------------------------------
set_property strategy "Performance_ExplorePostRoutePhysOpt" [get_runs impl_1]
set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true          [get_runs impl_1]

# ---------------------------------------------------------------------------
# Run synthesis (optional)
# ---------------------------------------------------------------------------
if {$run_synth == "1"} {
    puts ">>> Starting synthesis ..."
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1

    set synth_status [get_property STATUS [get_runs synth_1]]
    if {[string match "*ERROR*" $synth_status] || \
        [get_property PROGRESS [get_runs synth_1]] ne "100%"} {
        error "Synthesis failed – status: ${synth_status}"
    }
    puts ">>> Synthesis complete."
    open_run synth_1 -name synth_1
    report_timing_summary -file ${proj_path}/${proj_name}.runs/synth_1/timing_summary.rpt
    report_utilization    -file ${proj_path}/${proj_name}.runs/synth_1/utilization.rpt
}

# ---------------------------------------------------------------------------
# Run implementation + generate bitstream (optional)
# ---------------------------------------------------------------------------
if {$run_impl == "1"} {
    if {$run_synth != "1"} {
        puts ">>> Synthesis not run yet – launching it first ..."
        launch_runs synth_1 -jobs 4
        wait_on_run synth_1
        set synth_status [get_property STATUS [get_runs synth_1]]
        if {[string match "*ERROR*" $synth_status] || \
            [get_property PROGRESS [get_runs synth_1]] ne "100%"} {
            error "Synthesis failed – status: ${synth_status}"
        }
    }

    puts ">>> Starting implementation ..."
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1

    set impl_status [get_property STATUS [get_runs impl_1]]
    if {[string match "*ERROR*" $impl_status] || \
        [get_property PROGRESS [get_runs impl_1]] ne "100%"} {
        error "Implementation failed – status: ${impl_status}"
    }
    puts ">>> Implementation complete."

    open_run impl_1
    report_timing_summary -file ${proj_path}/${proj_name}.runs/impl_1/timing_summary_routed.rpt
    report_utilization    -file ${proj_path}/${proj_name}.runs/impl_1/utilization_placed.rpt
    report_io             -file ${proj_path}/${proj_name}.runs/impl_1/io_report.rpt

    # Show bitstream location
    set bit_file "${proj_path}/${proj_name}.runs/impl_1/${top_module}.bit"
    if {[file exists $bit_file]} {
        puts ">>> Bitstream: ${bit_file}"

        # Copy .bit to project root (fpga/build/)
        set bit_dest "${proj_path}/${top_module}.bit"
        file copy -force $bit_file $bit_dest
        puts ">>> Copied bitstream to: ${bit_dest}"

        # Generate .mcs configuration memory file
        set mcs_file "${proj_path}/${top_module}.mcs"
        write_cfgmem \
            -format mcs \
            -interface SPIx4 \
            -size 256 \
            -loadbit "up 0x0 ${bit_file}" \
            -file $mcs_file \
            -force
        puts ">>> MCS file: ${mcs_file}"
    }
}

puts ">>> Done."
