# =============================================================================
# File   : constraints.xdc
# Project: JV32 RISC-V SoC
# Brief  : Physical and timing constraints for XCKU5PFFVB676
#          Used in BOTH synthesis and implementation (no Tcl scripting here).
#
#          Mode-specific implementation-only constraints are in separate files
#          selected by create_project.tcl based on the USE_CJTAG variable:
#            USE_CJTAG=1 -> constraints_cjtag.xdc (tap_tck clock + cJTAG I/O)
#            USE_CJTAG=0 -> constraints_jtag.xdc  (4-wire JTAG I/O delays)
# =============================================================================

# -----------------------------------------------------------------------------
# Clock – 50 MHz on E18, LVCMOS18 (HP bank)
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN E18 [get_ports clk_50m]
set_property IOSTANDARD LVCMOS18 [get_ports clk_50m]

# NOTE: create_clock for clk_50m is intentionally omitted here.
# The clk_wiz IP XDC already defines it; redefining it causes XDCC-1/XDCC-7
# (scoped-clock-constraint-overwritten) methodology warnings.

set_input_jitter clk_50m 0.200

# -----------------------------------------------------------------------------
# JTAG – 3.3 V LVCMOS33 (HR bank)
# TCK is declared as a separate asynchronous clock domain.
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN D11 [get_ports jtag_tck_i]
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tck_i]

set_property PACKAGE_PIN C12 [get_ports jtag_tdi_i]
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tdi_i]

set_property PACKAGE_PIN J12 [get_ports jtag_tdo_o]
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tdo_o]

set_property PACKAGE_PIN E12 [get_ports jtag_tmsc_io]
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tmsc_io]

create_clock -period 100.000 -name jtag_tck [get_ports jtag_tck_i]

# Mark the two clock domains as fully asynchronous to each other.
# -include_generated_clocks ensures the MMCM output
# (clk_out1_jv32_clk_rst_bd_clk_wiz_0_0) is also covered, fixing TIMING-6/7.
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks clk_50m] -group [get_clocks jtag_tck]

# -----------------------------------------------------------------------------
# UART – 3.3 V LVCMOS33 (HR bank)
# These are asynchronous I/Os – use false paths.
# -----------------------------------------------------------------------------

set_property PACKAGE_PIN J14 [get_ports uart_rx_i]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx_i]

set_property PACKAGE_PIN G12 [get_ports uart_tx_o]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx_o]

set_false_path -from [get_ports uart_rx_i]
set_false_path -to [get_ports uart_tx_o]

# -----------------------------------------------------------------------------
# Heartbeat LED – LED6 on H9, 3.3 V LVCMOS33 (HR bank)
# minstret[24]: toggles every 2^24 retired instructions (~420 ms at 80 MHz / CPI 1.25)
# Slow output – false path is appropriate.
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN H9 [get_ports heartbeat_o]
set_property IOSTANDARD LVCMOS33 [get_ports heartbeat_o]
set_false_path -to [get_ports heartbeat_o]

# -----------------------------------------------------------------------------
# 1 Hz blink LED – LED3 on J11, 3.3 V LVCMOS33 (HR bank)
# Generated inside jv32_soc_fpga from clk/rst_n: 1 s high, 1 s low.
# Slow output – false path is appropriate.
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN J11 [get_ports led_o]
set_property IOSTANDARD LVCMOS33 [get_ports led_o]
set_false_path -to [get_ports led_o]

# -----------------------------------------------------------------------------
# Reset synchronizer – LUTAR-1 suppression
# -----------------------------------------------------------------------------
# rst_n_pre = rst_n & ~dbg_ndmreset is a 2-input LUT that drives the async CLR
# of rst_sync_ff1/ff2 in jv32_soc.sv.  This is an intentional asynchronous-
# assert / synchronous-deassert pattern; mark the CLR path as a false path to
# suppress the LUT-drives-async-reset (LUTAR-1) methodology warning.

# -----------------------------------------------------------------------------
# Bitstream / configuration settings
# -----------------------------------------------------------------------------
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 51.0 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pulldown [current_design]

