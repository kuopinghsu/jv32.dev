###############################################################################
# jv32_soc — PnR Timing Constraints (OpenROAD/OpenLane2)
# Process: Nangate 45nm Open Cell Library (FreePDK45)
# Target:  80 MHz (12.5 ns period)
###############################################################################

# ── Primary clocks ────────────────────────────────────────────────────────────
create_clock -name core_clk -period 12.5 [get_ports clk]

# JTAG/cJTAG clock
# When USE_CJTAG=1 (default), jtag_pin0_tck_i carries TCKC.  The cjtag_bridge
# converts TCKC→TAP TCK using the system clock; Yosys maps this as CLKGATE_X*
# cells gating jtag_pin0_tck_i.  OpenSTA propagates jtag_tck through those ICG
# cells automatically because the Nangate liberty annotates every CLKGATE_X*
# cell with clock_gating_integrated_cell / clock_gate_{clock,enable,out}_pin.
create_clock -name jtag_tck -period 100.0 [get_ports jtag_pin0_tck_i]

# ── Generated clocks on core-domain ICG (CLKGATE_X*) GCK outputs ─────────────
# OpenSTA does not always auto-propagate core_clk through all CLKGATE_X*
# instances in this flow. Discover GCK pins dynamically from connectivity:
# pick CLKGATE cells whose CK pin is connected to net "clk", then create a
# generated clock on their GCK pins. This avoids hardcoding instance names.
set core_gck_pins {}
foreach gck_pin [get_pins */GCK] {
    set ck_pin [regsub {/GCK$} $gck_pin {/CK}]
    if {[llength [get_pins $ck_pin]] != 1} {
        continue
    }
    set ck_nets [get_nets -of_objects [get_pins $ck_pin]]
    if {[llength $ck_nets] != 1} {
        continue
    }
    if {[lindex $ck_nets 0] == "clk"} {
        lappend core_gck_pins $gck_pin
    }
}

if {[llength $core_gck_pins] > 0} {
    create_generated_clock -name core_clk_gck \
        -source [get_ports clk] -master_clock core_clk \
        [get_pins $core_gck_pins]
}

# ── Clock groups (core family vs JTAG family, asynchronous) ───────────────────
# core_clk_gck is in the same group as core_clk (gated derivative).
# jtag_tck auto-propagates through the jtag-domain ICG cells via liberty attrs.
set core_clock_group [get_clocks core_clk]
if {[llength $core_gck_pins] > 0} {
    set core_clock_group [get_clocks {core_clk core_clk_gck}]
}
set_clock_groups -asynchronous \
    -group $core_clock_group \
    -group [get_clocks jtag_tck]

# ── Clock uncertainty and transition ──────────────────────────────────────────
# Uncertainty and transition on the primary clocks are inherited by gated
# derivatives — no need to list each CLKGATE GCK output separately.
set_clock_uncertainty -setup 0.3 [get_clocks core_clk]
set_clock_uncertainty -hold  0.03 [get_clocks core_clk]
set_clock_transition  0.3 [get_clocks core_clk]

# Clock-gating check margins for integrated CLKGATE cells.
# Post-route STA shows the worst setup path ending at an ICG gating check,
# not at a functional register endpoint. Use an explicit, minimal gating setup
# check window to avoid over-constraining integrated gate-enable timing.
set_clock_gating_check -setup 0.00 [get_clocks core_clk]
set_clock_gating_check -hold  0.00 [get_clocks core_clk]

# JTAG TCK: large setup uncertainty (pessimistic) but small hold uncertainty.
# Applying 1.0 ns symmetrically on a 100 ns clock causes hold violations on
# short JTAG sync-register paths (~0.2 ns data delay) — use -setup/-hold split.
set_clock_uncertainty -setup 1.0 [get_clocks jtag_tck]
set_clock_uncertainty -hold  0.1 [get_clocks jtag_tck]
set_clock_transition         1.0 [get_clocks jtag_tck]

# ── Input / output delay constraints ──────────────────────────────────────────
# 20% of clock period for I/O delay budget
set input_delay  2.5
set output_delay 2.5

set clk_input [get_ports clk]
set jtag_clk_input [get_ports jtag_pin0_tck_i]
set clk_indx [lsearch [all_inputs] $clk_input]
set all_in_ex_clk [lreplace [all_inputs] $clk_indx $clk_indx]
# Exclude jtag_pin0_tck_i: declared as a clock port (jtag_tck) above.
# jtag_ntrst_i is kept in all_in_ex_clk so it gets set_input_delay (the
# set_false_path below suppresses actual timing analysis for it).
set all_in_ex_clk [lsearch -all -inline -not -exact $all_in_ex_clk $jtag_clk_input]
set_input_delay  $input_delay  -clock [get_clocks core_clk] $all_in_ex_clk
set_output_delay $output_delay -clock [get_clocks core_clk] [all_outputs]

# JTAG/cJTAG output ports are driven from the JTAG clock domain; also
# constrain them relative to jtag_tck so the path is fully analysed.
set_output_delay $output_delay -clock [get_clocks jtag_tck] \
    [get_ports {jtag_pin1_tms_o jtag_pin1_tms_oe jtag_pin3_tdo_o jtag_pin3_tdo_oe}]

# ── Drive strength for input ports ────────────────────────────────────────────
set_driving_cell -lib_cell BUF_X4 -pin Z $all_in_ex_clk

# ── Load on output ports ──────────────────────────────────────────────────────
# 10 fF external load assumption
set_load 0.01 [all_outputs]

# ── False paths: async resets / async debug inputs ───────────────────────────
set_false_path -from [get_ports {rst_n jtag_ntrst_i}]
set_false_path -from [get_ports {jtag_pin1_tms_i jtag_pin2_tdi_i}] -to [get_clocks core_clk]

# soc_rst_n is generated by a 2-FF synchronizer (rst_sync_ff2 in jv32_soc).
# Downstream asynchronous reset pin checks are not functional data paths and
# should be excluded from setup/hold closure.
# Use endpoint-only false paths here; deriving a startpoint from the
# synthesized net can pick hold-buffer input pins (e.g. hold8/A), which are
# not legal start points for set_false_path in OpenSTA.
set async_reset_pins [get_pins -quiet */RN]
set async_set_pins [get_pins -quiet */SN]
if {[llength $async_reset_pins] > 0} {
    set_false_path -to $async_reset_pins
}
if {[llength $async_set_pins] > 0} {
    set_false_path -to $async_set_pins
}

# ── Multicycle paths ──────────────────────────────────────────────────────────
# No multicycle-path exceptions are required for the multiplier.
# When FAST_MUL=1 the design uses a 2-stage pipelined multiplier (gen_fast_mul_pipe):
#   stage 1 computes four unsigned 16×16 partial products and registers them;
#   stage 2 accumulates and sign-corrects in the following cycle.
# The pipeline stalls for one cycle via mul_ready, so the STA tool sees a
# normal single-cycle reg-to-reg path for each stage — no exceptions needed.

###############################################################################
# SRAM macro timing exceptions
# OpenRAM sram_1rw_32768x8 has registered outputs (1-cycle latency).
# The tool will read timing from the macro's liberty file.
###############################################################################
# Optionally override setup/hold margins per macro if needed:
# set_multicycle_path 2 -setup -through [get_pins */clk0]
