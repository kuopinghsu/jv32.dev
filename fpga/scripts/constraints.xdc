# =============================================================================
# File   : constraints.xdc
# Project: JV32 RISC-V SoC
# Brief  : Physical and timing constraints for XCKU5PFFVB676
# =============================================================================

# -----------------------------------------------------------------------------
# Clock – 50 MHz on E18, LVCMOS18 (HP bank)
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN E18 [get_ports clk_50m]
set_property IOSTANDARD  LVCMOS18 [get_ports clk_50m]

# NOTE: create_clock for clk_50m is intentionally omitted here.
# The clk_wiz IP XDC already defines it; redefining it causes XDCC-1/XDCC-7
# (scoped-clock-constraint-overwritten) methodology warnings.

set_input_jitter clk_50m 0.200

# -----------------------------------------------------------------------------
# JTAG – 3.3 V LVCMOS33 (HR bank)
# TCK is declared as a separate asynchronous clock domain.
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN D11 [get_ports jtag_tck_i]
set_property IOSTANDARD  LVCMOS33 [get_ports jtag_tck_i]

set_property PACKAGE_PIN C12 [get_ports jtag_tmsc_io]
set_property IOSTANDARD  LVCMOS33 [get_ports jtag_tmsc_io]

set_property PACKAGE_PIN J12 [get_ports jtag_tdi_i]
set_property IOSTANDARD  LVCMOS33 [get_ports jtag_tdi_i]

set_property PACKAGE_PIN E12 [get_ports jtag_tdo_o]
set_property IOSTANDARD  LVCMOS33 [get_ports jtag_tdo_o]

create_clock -name jtag_tck -period 100.000 \
    [get_ports jtag_tck_i]

# Mark the two clock domains as fully asynchronous to each other.
# -include_generated_clocks ensures the MMCM output
# (clk_out1_jv32_clk_rst_bd_clk_wiz_0_0) is also covered, fixing TIMING-6/7.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks clk_50m] \
    -group [get_clocks jtag_tck]

# Detect USE_CJTAG from the synthesis generic written by create_project.tcl.
# This runs post-synthesis when constraints are applied, so the project
# property is already set.  Fall back to JTAG mode (0) on any error.
set _use_cjtag 0
catch {
    set _gen [get_property GENERIC [get_filesets sources_1]]
    if {[regexp {USE_CJTAG\s*=\s*1'b1} $_gen]} { set _use_cjtag 1 }
}

if {!$_use_cjtag} {
    # -------------------------------------------------------------------------
    # 4-wire JTAG I/O delays
    # -------------------------------------------------------------------------
    # TMS/TDI are captured on the rising edge of TCK.
    set_input_delay -clock jtag_tck -max 10.0            [get_ports {jtag_tmsc_io jtag_tdi_i}]
    set_input_delay -clock jtag_tck -min  0.0 -add_delay [get_ports {jtag_tmsc_io jtag_tdi_i}]
    # TDO is launched on the *falling* edge of TCK (negedge FF in jtag_tap.sv).
    set_output_delay -clock jtag_tck -clock_fall -max 10.0            [get_ports jtag_tdo_o]
    set_output_delay -clock jtag_tck -clock_fall -min  0.0 -add_delay [get_ports jtag_tdo_o]
} else {
    # -------------------------------------------------------------------------
    # 2-wire cJTAG (OScan1) I/O constraints
    # -------------------------------------------------------------------------
    # TMSC is sampled by a 2-stage synchronizer inside cjtag_bridge (clk_core
    # domain), so both directions are asynchronous to any defined clock.
    set_false_path -from [get_ports jtag_tmsc_io]
    set_false_path -to   [get_ports jtag_tmsc_io]
    # TDI (J12) and TDO (E12) are unused in cJTAG mode.
    set_false_path -from [get_ports jtag_tdi_i]
    set_false_path -to   [get_ports jtag_tdo_o]
}

# -----------------------------------------------------------------------------
# UART – 3.3 V LVCMOS33 (HR bank)
# These are asynchronous I/Os – use false paths.
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN J14 [get_ports uart_tx_o]
set_property IOSTANDARD  LVCMOS33 [get_ports uart_tx_o]

set_property PACKAGE_PIN G12 [get_ports uart_rx_i]
set_property IOSTANDARD  LVCMOS33 [get_ports uart_rx_i]

set_false_path -from [get_ports uart_rx_i]
set_false_path -to   [get_ports uart_tx_o]

# -----------------------------------------------------------------------------
# Reset synchronizer – LUTAR-1 suppression
# -----------------------------------------------------------------------------
# rst_n_pre = rst_n & ~dbg_ndmreset is a 2-input LUT that drives the async CLR
# of rst_sync_ff1/ff2 in jv32_soc.sv.  This is an intentional asynchronous-
# assert / synchronous-deassert pattern; mark the CLR path as a false path to
# suppress the LUT-drives-async-reset (LUTAR-1) methodology warning.
set_false_path -to [get_pins -hierarchical \
    -filter {IS_SEQUENTIAL && NAME =~ */rst_sync_ff*_reg/CLR}]

# -----------------------------------------------------------------------------
# Bitstream / configuration settings
# -----------------------------------------------------------------------------
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4    [current_design]
set_property CONFIG_MODE SPIx4                  [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 51.0   [current_design]
set_property BITSTREAM.GENERAL.COMPRESS  TRUE   [current_design]
set_property BITSTREAM.CONFIG.UNUSED