# =============================================================================
# File   : create_bd.tcl
# Project: JV32 RISC-V SoC
# Brief  : IP Integrator block design for clock and reset generation.
#
# Block design: jv32_clk_rst_bd
# --------------------------------
#   clk_wiz_0        – Clocking Wizard (MMCM): 50 MHz in → 50 MHz out + locked
#   proc_sys_reset_0 – Processor System Reset: peripheral_aresetn (active-low)
#                      held low until MMCM is locked
#
# The generated wrapper (jv32_clk_rst_bd_wrapper) is instantiated inside
# jv32_fpga_top.sv.  jv32_fpga_top remains the synthesis/implementation top.
# =============================================================================

puts ">>> Creating block design jv32_clk_rst_bd ..."

create_bd_design "jv32_clk_rst_bd"
current_bd_design "jv32_clk_rst_bd"

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

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant xlconstant_0
set_property -dict [list \
    CONFIG.CONST_VAL   {0} \
    CONFIG.CONST_WIDTH {1} \
] [get_bd_cells xlconstant_0]
connect_bd_net [get_bd_pins xlconstant_0/dout] \
               [get_bd_pins proc_sys_reset_0/ext_reset_in]

# ---------------------------------------------------------------------------
# External ports
#   clk_in1   – 50 MHz raw clock in  (from FPGA pin E18)
#   clk_out1  – 50 MHz clean clock   (to jv32_soc)
#   rst_n     – active-low reset out (to jv32_soc)
# ---------------------------------------------------------------------------
create_bd_port -dir I -type clk -freq_hz 50000000 clk_in1
create_bd_port -dir O -type clk clk_out1
create_bd_port -dir O rst_n

# ---------------------------------------------------------------------------
# Connections
# ---------------------------------------------------------------------------
connect_bd_net [get_bd_ports clk_in1] \
               [get_bd_pins  clk_wiz_0/clk_in1]

connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
               [get_bd_ports clk_out1] \
               [get_bd_pins  proc_sys_reset_0/slowest_sync_clk]

connect_bd_net [get_bd_pins clk_wiz_0/locked] \
               [get_bd_pins proc_sys_reset_0/dcm_locked]

connect_bd_net [get_bd_pins  proc_sys_reset_0/peripheral_aresetn] \
               [get_bd_ports rst_n]

# ---------------------------------------------------------------------------
# Validate and save
# ---------------------------------------------------------------------------
validate_bd_design -quiet
save_bd_design

# ---------------------------------------------------------------------------
# Generate HDL wrapper
# jv32_fpga_top.sv instantiates jv32_clk_rst_bd_wrapper.
# The synthesis top remains jv32_fpga_top.
# ---------------------------------------------------------------------------
set wrapper_files [make_wrapper -files [get_files jv32_clk_rst_bd.bd] -top]
add_files -norecurse $wrapper_files
update_compile_order -fileset sources_1
set_property top jv32_fpga_top [current_fileset]

puts ">>> Block design complete. Synthesis top: jv32_fpga_top"
