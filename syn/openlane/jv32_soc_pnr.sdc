###############################################################################
# jv32_soc — PnR Timing Constraints (OpenROAD/OpenLane2)
# Process: Nangate 45nm Open Cell Library (FreePDK45)
# Target:  100 MHz (10 ns period)
###############################################################################

# ── Primary clock ─────────────────────────────────────────────────────────────
create_clock -name core_clk -period 10.0 [get_ports clk]

# Clock uncertainty and transition (10% of period typical for 45nm)
set_clock_uncertainty 0.5 [get_clocks core_clk]
set_clock_transition  0.3 [get_clocks core_clk]

# ── Input / output delay constraints ──────────────────────────────────────────
# 20% of clock period for I/O delay budget
set input_delay  2.0
set output_delay 2.0

set all_in_ex_clk [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay  $input_delay  -clock [get_clocks core_clk] $all_in_ex_clk
set_output_delay $output_delay -clock [get_clocks core_clk] [all_outputs]

# ── Drive strength for input ports ────────────────────────────────────────────
set_driving_cell -lib_cell BUF_X4 -pin Z $all_in_ex_clk

# ── Load on output ports ──────────────────────────────────────────────────────
# 10 fF external load assumption
set_load 0.01 [all_outputs]

# ── False paths: async reset ───────────────────────────────────────────────────
set_false_path -from [get_ports rst_n]

# ── Multicycle paths: none (fully-pipelined design) ───────────────────────────
# Add here if any multicycle paths are identified post-synthesis.

###############################################################################
# SRAM macro timing exceptions
# OpenRAM sram_1rw_32768x8 has registered outputs (1-cycle latency).
# The tool will read timing from the macro's liberty file.
###############################################################################
# Optionally override setup/hold margins per macro if needed:
# set_multicycle_path 2 -setup -through [get_pins */clk0]
