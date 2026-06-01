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
set_false_path -to [get_ports jtag_tmsc_io]

# TDI is captured on the rising edge of TCK.
set_input_delay -clock jtag_tck -max 10.000 [get_ports jtag_tdi_i]
set_input_delay -clock jtag_tck -min -add_delay 0.000 [get_ports jtag_tdi_i]

# TDO is launched on the falling edge of TCK (negedge FF in jtag_tap.sv).
set_output_delay -clock jtag_tck -clock_fall -max 10.000 [get_ports jtag_tdo_o]
set_output_delay -clock jtag_tck -clock_fall -min -add_delay 0.000 [get_ports jtag_tdo_o]

create_debug_core ila_0 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores ila_0]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores ila_0]
set_property C_ADV_TRIGGER false [get_debug_cores ila_0]
set_property C_DATA_DEPTH 1024 [get_debug_cores ila_0]
set_property C_EN_STRG_QUAL false [get_debug_cores ila_0]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores ila_0]
set_property C_TRIGIN_EN false [get_debug_cores ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores ila_0]
set_property port_width 1 [get_debug_ports ila_0/clk]
connect_debug_port ila_0/clk [get_nets [list u_bd/jv32_bd_i/clk_wiz_0/clk_out1]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe0]
set_property port_width 1 [get_debug_ports ila_0/probe0]
connect_debug_port ila_0/probe0 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/u_jtag_tap/u_dtm/cmd_busy_clk]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe1]
set_property port_width 1 [get_debug_ports ila_0/probe1]
connect_debug_port ila_0/probe1 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/u_jtag_tap/haltreq_reg_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe2]
set_property port_width 1 [get_debug_ports ila_0/probe2]
connect_debug_port ila_0/probe2 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/u_jtag_tap/resumereq]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe3]
set_property port_width 1 [get_debug_ports ila_0/probe3]
connect_debug_port ila_0/probe3 [get_nets [list {u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/u_jtag_tap/u_dtm/dcsr_reg[15]_i_1_n_0}]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe4]
set_property port_width 1 [get_debug_ports ila_0/probe4]
connect_debug_port ila_0/probe4 [get_nets [list {u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/u_jtag_tap/u_dtm/dcsr_reg[15]_i_2_n_0}]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe5]
set_property port_width 1 [get_debug_ports ila_0/probe5]
connect_debug_port ila_0/probe5 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/u_jtag_tap/u_dtm/exec_halt_req_i_1_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe6]
set_property port_width 1 [get_debug_ports ila_0/probe6]
connect_debug_port ila_0/probe6 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/u_jtag_tap/u_dtm/exec_halt_req_i_2_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe7]
set_property port_width 1 [get_debug_ports ila_0/probe7]
connect_debug_port ila_0/probe7 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/u_jtag_tap/u_dtm/exec_halt_req_i_3_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe8]
set_property port_width 1 [get_debug_ports ila_0/probe8]
connect_debug_port ila_0/probe8 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/u_jtag_tap/u_dtm/exec_halt_req_i_4_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe9]
set_property port_width 1 [get_debug_ports ila_0/probe9]
connect_debug_port ila_0/probe9 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/u_jtag_tap/u_dtm/exec_halt_req_i_5_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe10]
set_property port_width 1 [get_debug_ports ila_0/probe10]
connect_debug_port ila_0/probe10 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/u_jtag_tap/u_dtm/exec_halt_req_i_6_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe11]
set_property port_width 1 [get_debug_ports ila_0/probe11]
connect_debug_port ila_0/probe11 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/u_jtag_tap/u_dtm/exec_halt_req_i_7_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe12]
set_property port_width 1 [get_debug_ports ila_0/probe12]
connect_debug_port ila_0/probe12 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/u_jtag_tap/u_dtm/exec_halt_req_i_8_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe13]
set_property port_width 1 [get_debug_ports ila_0/probe13]
connect_debug_port ila_0/probe13 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/u_jtag_tap/u_dtm/exec_resume_req_i_1_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe14]
set_property port_width 1 [get_debug_ports ila_0/probe14]
connect_debug_port ila_0/probe14 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/u_rvc/dbg_halted_r_reg]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe15]
set_property port_width 1 [get_debug_ports ila_0/probe15]
connect_debug_port ila_0/probe15 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/gen_jtag.u_jtag/u_jtag_tap/u_dtm/dbg_step_pending_r]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe16]
set_property port_width 1 [get_debug_ports ila_0/probe16]
connect_debug_port ila_0/probe16 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/dbg_halted_r_reg_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe17]
set_property port_width 1 [get_debug_ports ila_0/probe17]
connect_debug_port ila_0/probe17 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/u_csr/dbg_halted_r_reg]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe18]
set_property port_width 1 [get_debug_ports ila_0/probe18]
connect_debug_port ila_0/probe18 [get_nets [list {u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/dbg_halted_r_reg_3[0]}]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe19]
set_property port_width 1 [get_debug_ports ila_0/probe19]
connect_debug_port ila_0/probe19 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/u_rvc/dbg_halted_r_reg]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe20]
set_property port_width 1 [get_debug_ports ila_0/probe20]
connect_debug_port ila_0/probe20 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/dbg_resumeack_r_reg_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe21]
set_property port_width 1 [get_debug_ports ila_0/probe21]
connect_debug_port ila_0/probe21 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/dbg_step_fire_r_reg_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe22]
set_property port_width 1 [get_debug_ports ila_0/probe22]
connect_debug_port ila_0/probe22 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/dbg_step_served_r]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe23]
set_property port_width 1 [get_debug_ports ila_0/probe23]
connect_debug_port ila_0/probe23 [get_nets [list {u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/u_csr/ex_wb_r_reg[exception][0]}]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe24]
set_property port_width 1 [get_debug_ports ila_0/probe24]
connect_debug_port ila_0/probe24 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/trace_valid_r]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe25]
set_property port_width 1 [get_debug_ports ila_0/probe25]
connect_debug_port ila_0/probe25 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/dbg_step_fire_r_reg_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe26]
set_property port_width 1 [get_debug_ports ila_0/probe26]
connect_debug_port ila_0/probe26 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/dbg_step_pending_r_reg_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe27]
set_property port_width 1 [get_debug_ports ila_0/probe27]
connect_debug_port ila_0/probe27 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/dbg_step_served_r]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe28]
set_property port_width 1 [get_debug_ports ila_0/probe28]
connect_debug_port ila_0/probe28 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/u_csr/dbg_step_served_r_i_2_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe29]
set_property port_width 1 [get_debug_ports ila_0/probe29]
connect_debug_port ila_0/probe29 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/u_csr/dbg_step_served_r_reg]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe30]
set_property port_width 1 [get_debug_ports ila_0/probe30]
connect_debug_port ila_0/probe30 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/u_csr/dbg_step_served_r_reg_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe31]
set_property port_width 1 [get_debug_ports ila_0/probe31]
connect_debug_port ila_0/probe31 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/u_csr/dbg_step_served_r_reg_1]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe32]
set_property port_width 1 [get_debug_ports ila_0/probe32]
connect_debug_port ila_0/probe32 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/trace_valid_r]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe33]
set_property port_width 1 [get_debug_ports ila_0/probe33]
connect_debug_port ila_0/probe33 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/u_csr/trace_valid_r_i_2_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe34]
set_property port_width 1 [get_debug_ports ila_0/probe34]
connect_debug_port ila_0/probe34 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/u_csr/trace_valid_r_i_3_n_0]]
create_debug_port ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ila_0/probe35]
set_property port_width 1 [get_debug_ports ila_0/probe35]
connect_debug_port ila_0/probe35 [get_nets [list u_bd/jv32_bd_i/u_soc/inst/u_soc/u_jv32/u_core/dbg_step_served_r]]
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets ila_0_clk_out1]
