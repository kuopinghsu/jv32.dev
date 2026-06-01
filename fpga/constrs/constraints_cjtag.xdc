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
create_clock -period 100.000 -name tap_tck -waveform {0.000 50.000} [get_pins u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/gen_pin_mux_cjtag.u_cjtag_bridge/u_bufg_tck/O]

# tap_tck is asynchronous to the system clock domain.
set_clock_groups -asynchronous -group [get_clocks tap_tck] -group [get_clocks -include_generated_clocks clk_50m]

# Suppress TIMING-3 "Invalid clock redefinition on a clock tree":
# The BUFG input is driven by tck_int_reg (clocked by the MMCM-derived system
# clock), so Vivado sees tap_tck as downstream of clk_out1_*.
# Declaring them physically_exclusive tells Vivado these two clocks cannot
# simultaneously drive the same clock-tree node, which is the correct
# semantic for an internally-generated emulated clock (UG949 / AR#63774).
set_clock_groups -physically_exclusive -group [get_clocks -include_generated_clocks clk_50m] -group [get_clocks tap_tck]

# In cJTAG mode, constraints.xdc (always loaded) defines jtag_tck on port
# jtag_tck_i.  jtag_tck feeds only the cjtag_bridge 2-FF synchronizer inputs
# and is therefore asynchronous to (and physically exclusive from) tap_tck.
# Without this declaration Vivado may generate spurious TIMING-10 warnings for
# paths between the two clocks.
set_clock_groups -physically_exclusive -group [get_clocks jtag_tck] -group [get_clocks tap_tck]

# -----------------------------------------------------------------------------
# cJTAG I/O – false paths (TMSC bidirectional, TDI/TDO unused)
# -----------------------------------------------------------------------------
# TDI (C12): not used in cJTAG – no timing relationship.
set_false_path -from [get_ports jtag_tdi_i]

# TMSC (E12): async w.r.t. clk_50m; re-sampled on tap_tck inside cjtag_bridge.
# Input is a CDC path (2-FF synchronizer in bridge) – false path is correct.
set_false_path -from [get_ports jtag_tmsc_io]

# TMSC output (E12): data path (IOBUF I-pin) is driven combinationally from
# tap_tdo, which is negedge-registered by tap_tck in jtag_tap.sv.
# The OE path (IOBUF T-pin = tmsc_oe_n) is clocked by the system clock and
# is already excluded by set_clock_groups asynchronous above.
set_output_delay -clock tap_tck -clock_fall -max 10.000 [get_ports jtag_tmsc_io]
set_output_delay -clock tap_tck -clock_fall -min -add_delay 0.000 [get_ports jtag_tmsc_io]

# TDO/J12 (cJTAG: TMSC-out mirror): same launch FF as jtag_tmsc_io data path –
# negedge tap_tck registered tap_tdo via the combinational tmsc_o assign.
set_output_delay -clock tap_tck -clock_fall -max 10.000 [get_ports jtag_tdo_o]
set_output_delay -clock tap_tck -clock_fall -min -add_delay 0.000 [get_ports jtag_tdo_o]

