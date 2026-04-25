# =============================================================================
# File   : create_bd.tcl
# Project: JV32 RISC-V SoC
# Brief  : IP Integrator block design for the JV32 FPGA subsystem.
#
# Block design: jv32_bd
# --------------------------------
#   clk_wiz_0        – Clocking Wizard (MMCM): 50 MHz in → 50 MHz out + locked
#   proc_sys_reset_0 – Processor System Reset: peripheral_aresetn (active-low)
#                      held low until MMCM is locked
#   u_soc            – jv32_soc_fpga (plain Verilog BD wrapper for jv32_soc)
#                      Vivado requires a plain Verilog (.v) top file for BD
#                      RTL module references; jv32_soc_fpga.v wraps jv32_soc.sv
#                      and ties off all unused FPGA ports internally.
#
# Not in this BD:
#   IOBUF u_tmsc_iobuf  – bidirectional TMSC pad (Xilinx primitive)
#   USE_CJTAG I/O mux   – these stay in jv32_fpga_top.sv
#
# BD external ports (seen by jv32_fpga_top.sv via jv32_bd_wrapper):
#   clk_in1        I  50 MHz raw clock  (from FPGA pin E18)
#   jtag_tck_i     I  TCK (JTAG) / TCKC (cJTAG)
#   jtag_tmsc_in   I  TMS/TMSC pad data in  (from IOBUF in jv32_fpga_top.sv)
#   jtag_tdi_i     I  TDI (JTAG; muxed to 0 inside jv32_soc_fpga when USE_CJTAG=1)
#   soc_tms_o      O  TMSC drive data   (cJTAG mode; to IOBUF in jv32_fpga_top.sv)
#   soc_tms_oe     O  TMSC output-enable (cJTAG mode; to IOBUF T pin)
#   soc_tdo_o      O  TDO output         (JTAG mode;  to jtag_tdo_o via top)
#   uart_rx_i      I  UART RX
#   uart_tx_o      O  UART TX
#
# clk_out1 and rst_n are internal BD nets (no longer BD ports).
#
# The generated wrapper (jv32_bd_wrapper) is instantiated inside
# jv32_fpga_top.sv.  jv32_fpga_top remains the synthesis/implementation top.
# =============================================================================

puts ">>> Creating block design jv32_bd ..."

# Resolve all RTL sources so jv32_soc_fpga is visible as a module reference.
update_compile_order -fileset sources_1

create_bd_design "jv32_bd"
current_bd_design "jv32_bd"

# ---------------------------------------------------------------------------
# Clocking Wizard – 50 MHz in, 50 MHz out (MMCM for clean distribution)
# USE_RESET=false: no dedicated reset pin; MMCM locks autonomously.
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_0
set_property -dict [list \
    CONFIG.PRIMITIVE                   {MMCM}   \
    CONFIG.USE_RESET                   {false}  \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ  {50.000} \
    CONFIG.USE_LOCKED                  {true}   \
    CONFIG.CLKIN1_JITTER_PS            {200.0}  \
] [get_bd_cells clk_wiz_0]

# ---------------------------------------------------------------------------
# Processor System Reset
# ext_reset_in is active-HIGH; tie to 0 (no external reset button).
# peripheral_aresetn goes high once MMCM is locked.
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset proc_sys_reset_0
set_property CONFIG.C_NUM_PERP_ARESETN {1} [get_bd_cells proc_sys_reset_0]

# ---------------------------------------------------------------------------
# Constant: proc_sys_reset ext_reset_in (active-HIGH) – deasserted
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant xlconstant_0
set_property -dict [list \
    CONFIG.CONST_VAL   {0} \
    CONFIG.CONST_WIDTH {1} \
] [get_bd_cells xlconstant_0]
connect_bd_net [get_bd_pins xlconstant_0/dout] \
               [get_bd_pins proc_sys_reset_0/ext_reset_in]

# ---------------------------------------------------------------------------
# JV32 SoC – plain Verilog BD module reference (jv32_soc_fpga.v)
#   CLK_FREQ is hardcoded to 50 MHz inside jv32_soc_fpga.v.
#   USE_CJTAG is set from $use_cjtag (derived from USE_CJTAG env var).
# ---------------------------------------------------------------------------
create_bd_cell -type module -reference jv32_soc_fpga u_soc
set_property CONFIG.USE_CJTAG $use_cjtag [get_bd_cells u_soc]

# ---------------------------------------------------------------------------
# External ports
# ---------------------------------------------------------------------------
create_bd_port -dir I -type clk -freq_hz 50000000 clk_in1
create_bd_port -dir I                              jtag_tck_i
create_bd_port -dir I                              jtag_tmsc_in
create_bd_port -dir I                              jtag_tdi_i
create_bd_port -dir O                              soc_tms_o
create_bd_port -dir O                              soc_tms_oe
create_bd_port -dir O                              soc_tdo_o
create_bd_port -dir I                              uart_rx_i
create_bd_port -dir O                              uart_tx_o

# ---------------------------------------------------------------------------
# Clock chain:  clk_in1 → clk_wiz_0 → proc_sys_reset_0 / u_soc
# clk_out1 is an internal net (not a BD port).
# ---------------------------------------------------------------------------
connect_bd_net [get_bd_ports clk_in1] \
               [get_bd_pins  clk_wiz_0/clk_in1]

connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
               [get_bd_pins proc_sys_reset_0/slowest_sync_clk] \
               [get_bd_pins u_soc/clk]

# ---------------------------------------------------------------------------
# Reset chain: locked → proc_sys_reset → u_soc
# rst_n is an internal net (not a BD port).
# ---------------------------------------------------------------------------
connect_bd_net [get_bd_pins clk_wiz_0/locked] \
               [get_bd_pins proc_sys_reset_0/dcm_locked]

connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
               [get_bd_pins u_soc/rst_n]

# ---------------------------------------------------------------------------
# JTAG / cJTAG
#   jtag_tck_i   → u_soc/jtag_pin0_tck_i
#   jtag_tmsc_in → u_soc/jtag_pin1_tms_i  (data from IOBUF in jv32_fpga_top)
#   jtag_tdi_i   → u_soc/jtag_pin2_tdi_i  (jv32_soc_fpga muxes to 0 if USE_CJTAG=1)
#   u_soc/jtag_pin1_tms_o  → soc_tms_o    (TMSC drive;  cJTAG mode)
#   u_soc/jtag_pin1_tms_oe → soc_tms_oe   (TMSC OE;     cJTAG mode)
#   u_soc/jtag_pin3_tdo_o  → soc_tdo_o    (TDO output;  JTAG mode)
# ---------------------------------------------------------------------------
connect_bd_net [get_bd_ports jtag_tck_i]   [get_bd_pins u_soc/jtag_pin0_tck_i]
connect_bd_net [get_bd_ports jtag_tmsc_in] [get_bd_pins u_soc/jtag_pin1_tms_i]
connect_bd_net [get_bd_ports jtag_tdi_i]   [get_bd_pins u_soc/jtag_pin2_tdi_i]

connect_bd_net [get_bd_pins u_soc/jtag_pin1_tms_o]  [get_bd_ports soc_tms_o]
connect_bd_net [get_bd_pins u_soc/jtag_pin1_tms_oe] [get_bd_ports soc_tms_oe]
connect_bd_net [get_bd_pins u_soc/jtag_pin3_tdo_o]  [get_bd_ports soc_tdo_o]

# ---------------------------------------------------------------------------
# UART
# ---------------------------------------------------------------------------
connect_bd_net [get_bd_ports uart_rx_i]      [get_bd_pins u_soc/uart_rx_i]
connect_bd_net [get_bd_pins u_soc/uart_tx_o] [get_bd_ports uart_tx_o]

# ---------------------------------------------------------------------------
# Validate and save
# ---------------------------------------------------------------------------
validate_bd_design -quiet
save_bd_design

# ---------------------------------------------------------------------------
# Generate HDL wrapper
# jv32_fpga_top.sv instantiates jv32_bd_wrapper.
# The synthesis top remains jv32_fpga_top.
# ---------------------------------------------------------------------------
set wrapper_files [make_wrapper -files [get_files jv32_bd.bd] -top]
# Note: jv32_soc_fpga.v and jv32_fpga_top.sv are added as regular RTL sources
# in create_project.tcl; jv32_soc.sv is picked up by the RTL glob patterns.
add_files -norecurse $wrapper_files
update_compile_order -fileset sources_1
set_property top jv32_fpga_top [current_fileset]

puts ">>> Block design complete. Synthesis top: jv32_fpga_top"
