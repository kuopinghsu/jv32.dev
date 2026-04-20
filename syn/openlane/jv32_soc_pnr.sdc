###############################################################################
# jv32_soc — PnR Timing Constraints (OpenROAD/OpenLane2)
# Process: Nangate 45nm Open Cell Library (FreePDK45)
# Target:  80 MHz (12.5 ns period)
###############################################################################

# ── Primary clocks ────────────────────────────────────────────────────────────
create_clock -name core_clk -period 12.5 [get_ports clk]

# JTAG TCK is asynchronous to the core clock domain; give it a conservative
# 10 MHz constraint so the TAP/DTM logic is analyzed without coupling it to the
# core timing domain.
create_clock -name jtag_tck -period 100.0 [get_ports jtag_pin0_tck_i]
set_clock_groups -asynchronous \
    -group [get_clocks core_clk] \
    -group [get_clocks jtag_tck]

# Clock uncertainty and transition.
# Keep conservative setup uncertainty while using a realistic hold uncertainty
# to avoid over-constraining short FF->FF hold paths.
set_clock_uncertainty -setup 0.5 [get_clocks core_clk]
set_clock_uncertainty -hold  0.05 [get_clocks core_clk]
set_clock_transition  0.3 [get_clocks core_clk]
# JTAG TCK: large setup uncertainty (pessimistic) but small hold uncertainty.
# Applying 1.0ns symmetrically on a 100ns clock causes hold violations on
# short JTAG sync-register paths (~0.2ns data delay) — use -setup/-hold split.
set_clock_uncertainty -setup 1.0 [get_clocks jtag_tck]
set_clock_uncertainty -hold  0.1 [get_clocks jtag_tck]
set_clock_transition         1.0 [get_clocks jtag_tck]

# ── Input / output delay constraints ──────────────────────────────────────────
# 20% of clock period for I/O delay budget
set input_delay  2.5
set output_delay 2.5

set clk_input [get_ports clk]
set jtag_clk_input [get_ports jtag_pin0_tck_i]
set jtag_rst_input [get_ports jtag_ntrst_i]
set clk_indx [lsearch [all_inputs] $clk_input]
set all_in_ex_clk [lreplace [all_inputs] $clk_indx $clk_indx]
set all_in_ex_clk [lsearch -all -inline -not -exact $all_in_ex_clk $jtag_clk_input]
set all_in_ex_clk [lsearch -all -inline -not -exact $all_in_ex_clk $jtag_rst_input]
set_input_delay  $input_delay  -clock [get_clocks core_clk] $all_in_ex_clk
set_output_delay $output_delay -clock [get_clocks core_clk] [all_outputs]

# ── Drive strength for input ports ────────────────────────────────────────────
set_driving_cell -lib_cell BUF_X4 -pin Z $all_in_ex_clk

# ── Load on output ports ──────────────────────────────────────────────────────
# 10 fF external load assumption
set_load 0.01 [all_outputs]

# ── False paths: async resets / async debug inputs ───────────────────────────
set_false_path -from [get_ports {rst_n jtag_ntrst_i}]
set_false_path -from [get_ports {jtag_pin1_tms_i jtag_pin2_tdi_i}] -to [get_clocks core_clk]

# ── Multicycle paths: none (fully-pipelined design) ───────────────────────────
# Add here if any multicycle paths are identified post-synthesis.

###############################################################################
# SRAM macro timing exceptions
# OpenRAM sram_1rw_32768x8 has registered outputs (1-cycle latency).
# The tool will read timing from the macro's liberty file.
###############################################################################
# Optionally override setup/hold margins per macro if needed:
# set_multicycle_path 2 -setup -through [get_pins */clk0]
