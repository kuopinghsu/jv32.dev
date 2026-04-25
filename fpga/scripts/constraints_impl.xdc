# =============================================================================
# File   : constraints_impl.xdc
# Project: JV32 RISC-V SoC
# Brief  : Implementation-only timing constraints (Tcl scripting required).
#          Marked used_in_synthesis=false in create_project.tcl.
#
# Vivado's XDC synthesis parser does NOT support Tcl 'if' statements.
# Anything that needs conditional logic must live here, evaluated only at
# link_design / opt_design during implementation.
# =============================================================================

# -----------------------------------------------------------------------------
# cJTAG tap_tck clock domain
# -----------------------------------------------------------------------------
# In cJTAG mode (USE_CJTAG=1) cjtag_bridge generates a registered TCK pulse
# on tck_int_reg/Q.  Vivado auto-inserts a BUFGCE (net: tck_int_reg_0) and
# routes tap_tck to all 726 JTAG TAP / DTM flip-flops.
# create_clock on the FDRE/Q pin propagates through the auto-inserted BUFGCE
# to all downstream FFs when the constraint is evaluated at link_design.
#
# Detection: u_cjtag_bridge cell exists only when USE_CJTAG=1.
if {[llength [get_cells -hierarchical -quiet \
        -filter {NAME =~ *u_cjtag_bridge}]] > 0} {
    # Exact pin path confirmed from Vivado clock utilization report.
    # Period 100 ns (10 MHz): conservative JTAG budget.
    create_clock -period 100.000 -name tap_tck -waveform {0.000 50.000} \
        [get_pins {u_soc/gen_jtag.u_jtag/gen_pin_mux_cjtag.u_cjtag_bridge/tck_int_reg/Q}]

    # tap_tck is asynchronous to the system clock domain.
    set_clock_groups -asynchronous \
        -group [get_clocks tap_tck] \
        -group [get_clocks -include_generated_clocks clk_50m]
}

# -----------------------------------------------------------------------------
# JTAG / cJTAG I/O timing
# -----------------------------------------------------------------------------
if {[llength [get_cells -hierarchical -quiet \
        -filter {NAME =~ *u_cjtag_bridge}]] == 0} {
    # 4-wire JTAG: TMS/TDI captured on rising TCK; TDO launched on falling TCK.
    set_input_delay  -clock jtag_tck -max 10.0            [get_ports {jtag_tmsc_io jtag_tdi_i}]
    set_input_delay  -clock jtag_tck -min  0.0 -add_delay [get_ports {jtag_tmsc_io jtag_tdi_i}]
    set_output_delay -clock jtag_tck -clock_fall -max 10.0            [get_ports jtag_tdo_o]
    set_output_delay -clock jtag_tck -clock_fall -min  0.0 -add_delay [get_ports jtag_tdo_o]
} else {
    # 2-wire cJTAG (OScan1): TMSC sampled by synchronizer; TDI/TDO unused.
    set_false_path -from [get_ports jtag_tmsc_io]
    set_false_path -to   [get_ports jtag_tmsc_io]
    set_false_path -from [get_ports jtag_tdi_i]
    set_false_path -to   [get_ports jtag_tdo_o]
}
