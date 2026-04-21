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

create_clock -name clk_50m -period 20.000 -waveform {0.000 10.000} \
    [get_ports clk_50m]

set_input_jitter clk_50m 0.200

# -----------------------------------------------------------------------------
# JTAG – 3.3 V LVCMOS33 (HR bank)
# TCK is declared as a separate asynchronous clock domain.
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN D11 [get_ports jtag_tck_i]
set_property IOSTANDARD  LVCMOS33 [get_ports jtag_tck_i]

set_property PACKAGE_PIN C12 [get_ports jtag_tms_i]
set_property IOSTANDARD  LVCMOS33 [get_ports jtag_tms_i]

set_property PACKAGE_PIN J12 [get_ports jtag_tdi_i]
set_property IOSTANDARD  LVCMOS33 [get_ports jtag_tdi_i]

set_property PACKAGE_PIN E12 [get_ports jtag_tdo_o]
set_property IOSTANDARD  LVCMOS33 [get_ports jtag_tdo_o]

create_clock -name jtag_tck -period 100.000 \
    [get_ports jtag_tck_i]

# Mark the two clock domains as fully asynchronous to each other.
set_clock_groups -asynchronous \
    -group [get_clocks clk_50m] \
    -group [get_clocks jtag_tck]

# Constrain JTAG I/O relative to TCK
set_input_delay  -clock jtag_tck -max  10.0 [get_ports {jtag_tms_i jtag_tdi_i}]
set_input_delay  -clock jtag_tck -min   0.0 [get_ports {jtag_tms_i jtag_tdi_i}]
set_output_delay -clock jtag_tck -max  10.0 [get_ports jtag_tdo_o]
set_output_delay -clock jtag_tck -min   0.0 [get_ports jtag_tdo_o]

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
# Bitstream / configuration settings
# -----------------------------------------------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS  TRUE   [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4    [current_design]
