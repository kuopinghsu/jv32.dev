# =============================================================================
# File   : constraints_jtag.xdc
# Project: JV32 RISC-V SoC
# Brief  : Implementation-only timing constraints for USE_CJTAG=0 (4-wire JTAG).
#          Added to the project and marked used_in_synthesis=false only when
#          USE_CJTAG=0 in create_project.tcl.  No Tcl 'if' needed.
# =============================================================================

# -----------------------------------------------------------------------------
# 4-wire JTAG I/O delays
# -----------------------------------------------------------------------------
# TMS (jtag_tmsc_io) passes through an IOBUF synchronizer in the SoC and is
# re-sampled on TCK inside the TAP; treat as a false path at the port.
set_false_path -from [get_ports jtag_tmsc_io]
set_false_path -to   [get_ports jtag_tmsc_io]

# TDI is captured on the rising edge of TCK.
set_input_delay  -clock jtag_tck -max 10.0            [get_ports jtag_tdi_i]
set_input_delay  -clock jtag_tck -min  0.0 -add_delay [get_ports jtag_tdi_i]

# TDO is launched on the falling edge of TCK (negedge FF in jtag_tap.sv).
set_output_delay -clock jtag_tck -clock_fall -max 10.0            [get_ports jtag_tdo_o]
set_output_delay -clock jtag_tck -clock_fall -min  0.0 -add_delay [get_ports jtag_tdo_o]
