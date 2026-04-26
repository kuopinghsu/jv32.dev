# =============================================================================
# File   : constraints_cjtag.xdc
# Project: JV32 RISC-V SoC
# Brief  : Implementation-only timing constraints for USE_CJTAG=1 (2-wire cJTAG).
#          Added to the project and marked used_in_synthesis=false only when
#          USE_CJTAG=1 in create_project.tcl.  No Tcl 'if' needed.
# =============================================================================

# -----------------------------------------------------------------------------
# tap_tck clock domain
# -----------------------------------------------------------------------------
# cjtag_bridge generates TCK as a registered pulse on tck_int_reg/Q, routed
# through an explicit BUFG (u_bufg_tck) instantiated under `ifdef SYNTHESIS.
# Creating the primary clock on the BUFG/O (a primitive output with no timing
# arc) avoids TIMING-1 "inappropriate pin" and is the Xilinx-recommended
# approach for internally-generated clocks (UG949).
#
# Full path includes the BD wrapper hierarchy:
#   u_bd              – jv32_bd_wrapper instance in jv32_fpga_top.sv
#   jv32_bd_i         – BD internal instance
#   u_soc/inst        – jv32_soc_fpga BD module reference (Vivado adds /inst)
#   u_soc             – jv32_soc instance inside jv32_soc_fpga.v
create_clock -period 100.000 -name tap_tck -waveform {0.000 50.000} \
    [get_pins {u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/gen_pin_mux_cjtag.u_cjtag_bridge/u_bufg_tck/O}]

# tap_tck is asynchronous to the system clock domain.
set_clock_groups -asynchronous \
    -group [get_clocks tap_tck] \
    -group [get_clocks -include_generated_clocks clk_50m]

# Suppress TIMING-3 "Invalid clock redefinition on a clock tree":
# The BUFG input is driven by tck_int_reg (clocked by the MMCM-derived system
# clock), so Vivado sees tap_tck as downstream of clk_out1_*.
# Declaring them physically_exclusive tells Vivado these two clocks cannot
# simultaneously drive the same clock-tree node, which is the correct
# semantic for an internally-generated emulated clock (UG949 / AR#63774).
set_clock_groups -physically_exclusive \
    -group [get_clocks -include_generated_clocks clk_50m] \
    -group [get_clocks tap_tck]

# -----------------------------------------------------------------------------
# cJTAG I/O – false paths (TMSC bidirectional, TDI/TDO unused)
# -----------------------------------------------------------------------------
set_false_path -from [get_ports jtag_tmsc_io]
set_false_path -to   [get_ports jtag_tmsc_io]
set_false_path -from [get_ports jtag_tdi_i]
set_false_path -to   [get_ports jtag_tdo_o]
