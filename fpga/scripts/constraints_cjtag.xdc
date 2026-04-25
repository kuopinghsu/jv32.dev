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
# cjtag_bridge generates TCK as a registered pulse on tck_int_reg/Q.
# Vivado auto-inserts a BUFGCE for fan-out; create_clock on the FDRE/Q pin
# propagates through BUFGCE/I -> BUFGCE/O to all JTAG TAP / DTM FFs.
#
# Full path includes the BD wrapper hierarchy:
#   u_bd              – jv32_bd_wrapper instance in jv32_fpga_top.sv
#   jv32_bd_i         – BD internal instance
#   u_soc/inst        – jv32_soc_fpga BD module reference (Vivado adds /inst)
#   u_soc             – jv32_soc instance inside jv32_soc_fpga.v
create_clock -period 100.000 -name tap_tck -waveform {0.000 50.000} \
    [get_pins {u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/gen_pin_mux_cjtag.u_cjtag_bridge/tck_int_reg/Q}]

# tap_tck is asynchronous to the system clock domain.
set_clock_groups -asynchronous \
    -group [get_clocks tap_tck] \
    -group [get_clocks -include_generated_clocks clk_50m]

# -----------------------------------------------------------------------------
# cJTAG I/O – false paths (TMSC bidirectional, TDI/TDO unused)
# -----------------------------------------------------------------------------
set_false_path -from [get_ports jtag_tmsc_io]
set_false_path -to   [get_ports jtag_tmsc_io]
set_false_path -from [get_ports jtag_tdi_i]
set_false_path -to   [get_ports jtag_tdo_o]
