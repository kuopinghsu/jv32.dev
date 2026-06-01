# =============================================================================
# File   : setup_ila.tcl
# Project: JV32 RISC-V SoC
# Brief  : Post-synthesis ILA insertion script for single-step debug.
#
# Sourced by create_project.tcl when ILA_DEBUG=1 (after synth_1 is open).
# Calls implement_debug_core which reads all (* mark_debug = "true" *) nets
# from the synthesized netlist, auto-creates the ILA, and connects probes.
#
# After programming the FPGA:
#   1. Open Vivado Hardware Manager
#   2. hw_server → connect → open target
#   3. load_hw_probes <repo>/fpga/build/debug_probes.ltx
#   4. Set ILA trigger (see trigger setup section of this file for guidance)
#   5. Run stepi in GDB and arm ILA; it will capture on resume_req rising edge
#
# ILA clock domain: 50 MHz system clock (clk)
# Capture window:   4096 samples × 20 ns = 81.92 µs per trigger
# Trigger position: sample 64 (short pre-trigger to see halt state, long
#                   post-trigger to observe whether trace_valid_r fires)
# =============================================================================

puts ">>> ILA Debug: inserting debug core from mark_debug nets ..."

# ---------------------------------------------------------------------------
# Create the ILA explicitly, then attach every MARK_DEBUG net in the design.
# implement_debug_core only implements debug cores that already exist, so the
# core must be created and wired up before that step.
# ---------------------------------------------------------------------------
set ila_name "ila_0"
create_debug_core $ila_name ila

set marked_nets [get_nets -quiet -hier -filter {MARK_DEBUG == 1}]
set marked_pins [get_pins -quiet -hier -filter {MARK_DEBUG == 1}]

set debug_nets $marked_nets
if {[llength $debug_nets] == 0 && [llength $marked_pins] > 0} {
    # Some synthesized netlists keep MARK_DEBUG on pins rather than nets.
    set debug_nets [get_nets -quiet -of_objects $marked_pins]
    if {[llength $debug_nets] > 0} {
        puts ">>> NOTE: No MARK_DEBUG nets found directly; recovered [llength $debug_nets] debug nets from MARK_DEBUG pins."
    }
}

if {[llength $debug_nets] == 0} {
    # Final fallback: discover likely debug/trace nets by broad name classes
    # when MARK_DEBUG metadata is unavailable in the synthesized checkpoint.
    # This keeps probe pickup generic as new debug signals are added.
    set fallback_patterns [list \
        "*dbg_*" \
        "*trace_*" \
        "*resume_*" \
    ]

    foreach pat $fallback_patterns {
        set candidate_nets [get_nets -quiet -hier $pat]
        foreach n $candidate_nets {
            # Skip Vivado-generated debug-insertion artifacts and known
            # non-routable aliases that frequently cause Chipscope warnings.
            if {[regexp {(^|/)ila_[0-9]+_} $n]} {
                continue
            }
            if {[string match "ila_*" $n]} {
                continue
            }
            if {[string match "*/ila_*" $n]} {
                continue
            }
            if {[string match "*dbg_hub*" $n]} {
                continue
            }
            if {$n eq "u_bd/clk_50m"} {
                continue
            }
            lappend debug_nets $n
        }
    }

    # Keep fallback generic but bounded so automatic name matching cannot
    # exceed ILA probe-port limits on large designs.
    set fallback_port_limit 900
    set debug_nets [lsort -dictionary -unique $debug_nets]
    if {[llength $debug_nets] > $fallback_port_limit} {
        set debug_nets [lrange $debug_nets 0 [expr {$fallback_port_limit - 1}]]
        puts ">>> WARNING: fallback debug net discovery exceeded ${fallback_port_limit}; truncating for stable ILA insertion."
    }

    if {[llength $debug_nets] > 0} {
        puts ">>> NOTE: MARK_DEBUG metadata unavailable; using [llength $debug_nets] fallback debug nets matched by name."
    }
}

set debug_nets [lsort -dictionary $debug_nets]
if {[llength $debug_nets] == 0} {
    error ">>> No MARK_DEBUG nets or pin-driven nets were found in the synthesized design; cannot create ILA."
}

# Build clock candidates from internal clock-wizard output first, then aliases.
# Top-level alias u_bd/clk_50m is often not routable for debug hub insertion.
set clk_candidates [list]

set wiz_clk_pins [get_pins -quiet -hier -regexp {^.*/clk_wiz_0(/inst)?/(clk_out1|CLK_OUT1)$}]
foreach p $wiz_clk_pins {
    foreach n [get_nets -quiet -of_objects $p] {
        lappend clk_candidates $n
    }
}

foreach n [get_nets -quiet -hier -regexp {^.*/clk_wiz_0(/inst)?/clk_out1$}] {
    lappend clk_candidates $n
}

foreach n [get_nets -quiet -hier clk_50m] {
    lappend clk_candidates $n
}

set clk_candidates [lsort -dictionary -unique $clk_candidates]
if {[llength $clk_candidates] == 0} {
    error ">>> Unable to find a usable clock net for ILA/debug hub."
}

# Deterministic priority:
#   1) clock-wizard clk_out1 nets
#   2) internal jv32_bd_i clock aliases
#   3) any candidate except known non-routable top alias u_bd/clk_50m
#   4) first remaining candidate
set clk_net ""
foreach n $clk_candidates {
    if {[string match "*clk_wiz_0*clk_out1*" $n]} {
        set clk_net $n
        break
    }
}
if {$clk_net eq ""} {
    foreach n $clk_candidates {
        if {[string match "*/jv32_bd_i/*" $n]} {
            set clk_net $n
            break
        }
    }
}
if {$clk_net eq ""} {
    foreach n $clk_candidates {
        if {$n ne "u_bd/clk_50m"} {
            set clk_net $n
            break
        }
    }
}
if {$clk_net eq ""} {
    set clk_net [lindex $clk_candidates 0]
}

puts ">>> NOTE: clock candidates found ([llength $clk_candidates]); using '$clk_net' for ILA/debug hub clock."

if {[catch {connect_debug_port ${ila_name}/clk $clk_net} ila_clk_err]} {
    error ">>> Failed to connect ${ila_name}/clk to '$clk_net': $ila_clk_err"
}

set probe_idx 0
set max_probe_ports 960
set probe_truncated 0
foreach net_obj $debug_nets {
    if {$probe_idx >= $max_probe_ports} {
        set probe_truncated 1
        break
    }

    if {[llength $net_obj] == 0} {
        error ">>> Encountered an empty MARK_DEBUG net object while building ILA probes."
    }

    set net_name [get_property NAME $net_obj]

    # Break vectors into scalar segments and wire exactly one segment per probe.
    # This avoids channel allocation mismatches in Vivado 2024.1.
    set seg_nets [get_nets -quiet -segments $net_obj]
    if {[llength $seg_nets] == 0} {
        set seg_nets [list $net_obj]
    }

    foreach seg_net $seg_nets {
        if {$probe_idx >= $max_probe_ports} {
            set probe_truncated 1
            break
        }

        set seg_name [get_property NAME $seg_net]

        # Vivado may return packed sub-ranges (e.g. foo[3:2]) from -segments.
        # Size each probe to the segment width to avoid vacant-channel errors.
        set seg_width 1
        if {[regexp {\[(\d+):(\d+)\]$} $seg_name -> msb lsb]} {
            set seg_width [expr {abs($msb - $lsb) + 1}]
        } elseif {[regexp {\[(\d+)\]$} $seg_name]} {
            set seg_width 1
        }

        set probe_obj [create_debug_port $ila_name probe]
        set_property PORT_WIDTH $seg_width $probe_obj

        if {[catch {connect_debug_port $probe_obj $seg_net} conn_err]} {
            error ">>> Failed to connect net '$net_name' segment '$seg_name' (width=$seg_width) to $probe_obj: $conn_err"
        }

        incr probe_idx
    }

    if {$probe_truncated} {
        break
    }
}

if {$probe_truncated} {
    puts ">>> WARNING: probe creation truncated at ${max_probe_ports} ports to stay below Vivado debug-port limits."
}

puts ">>> ILA probe channels created: $probe_idx"

# We already wired probes manually. Clear MARK_DEBUG globally so Vivado does
# not attempt any extra auto-attachment during implement_debug_core.
if {[llength $marked_nets] > 0} {
    catch {set_property MARK_DEBUG false $marked_nets}
}

if {[llength $marked_pins] > 0} {
    catch {set_property MARK_DEBUG false $marked_pins}
}

# Vivado project flow requires saving debug constraint edits before
# implement_debug_core can modify the synthesized netlist.
catch {save_constraints -force}

if {[catch {implement_debug_core} impl_err]} {
    error ">>> implement_debug_core failed after manual probe wiring: $impl_err"
}

# Some Vivado runs leave dbg_hub/clk disconnected even after implement_debug_core.
# Reconnect and verify explicitly against the same net as the ILA.
set dbg_hubs [get_debug_cores -quiet dbg_hub*]
foreach hub $dbg_hubs {
    set hub_clk_port [get_debug_ports -quiet ${hub}/clk]
    if {[llength $hub_clk_port] == 0} {
        continue
    }

    catch {disconnect_debug_port $hub_clk_port}
    if {[catch {connect_debug_port $hub_clk_port $clk_net} hub_clk_err]} {
        error ">>> Failed to reconnect ${hub}/clk to '$clk_net': $hub_clk_err"
    }

    set hub_clk_nets [get_nets -quiet -of_objects $hub_clk_port]
    if {[llength $hub_clk_nets] == 0} {
        error ">>> ${hub}/clk remains unconnected after reconnect attempt."
    }
    puts ">>> NOTE: ${hub}/clk connected to '[lindex $hub_clk_nets 0]'."
}

# ---------------------------------------------------------------------------
# Configure ILA depth and trigger position.
# The ILA core name is typically ila_0; print what was created.
# ---------------------------------------------------------------------------
# Some Vivado versions do not expose CELL_TYPE on debug_core objects.
# Resolve the ILA core by explicit name first, then fall back to name matching.
set ila_cores [get_debug_cores -quiet $ila_name]
if {[llength $ila_cores] == 0} {
    foreach core [get_debug_cores] {
        set core_name [get_property NAME $core]
        if {[string match "ila*" $core_name]} {
            lappend ila_cores $core
        }
    }
}

if {[llength $ila_cores] == 0} {
    error ">>> No ILA debug cores were found after implement_debug_core."
}

puts ">>> ILA cores created: $ila_cores"

foreach ila $ila_cores {
    # 4096 samples @ 50 MHz = ~82 µs capture window
    set_property C_DATA_DEPTH 4096 $ila

    # Trigger position 64: gives 64 pre-trigger samples (to see the halt
    # state before resume) and 4032 post-trigger samples (to see whether
    # trace_valid_r ever pulses after resume).
    set_property C_TRIGIN_EN false $ila
}

puts ">>> ILA configuration:"
foreach ila $ila_cores {
    puts "    $ila  depth=[get_property C_DATA_DEPTH $ila]"
}

# ---------------------------------------------------------------------------
# Write probe descriptions (.ltx) for use with Hardware Manager.
# This file maps probe indices to net names so the ILA waveform is readable.
# ---------------------------------------------------------------------------
set ltx_path [file normalize "[file dirname [info script]]/../../fpga/build/debug_probes.ltx"]
if {[catch {write_debug_probes -force $ltx_path} ltx_err]} {
    puts ">>> WARNING: write_debug_probes deferred: $ltx_err"
    puts ">>>          Vivado can regenerate debug_probes.ltx after implementation."
} else {
    puts ">>> Debug probes written to: $ltx_path"
}

# ---------------------------------------------------------------------------
# Save updated checkpoint (netlist + debug core) so impl_1 picks it up.
# ---------------------------------------------------------------------------
set synth_dir [get_property DIRECTORY [get_runs synth_1]]
set synth_top [get_property top [current_fileset]]
set synth_dcp "${synth_dir}/post_debug.dcp"
set synth_run_dcp "${synth_dir}/${synth_top}.dcp"
write_checkpoint -force $synth_dcp
file copy -force $synth_dcp $synth_run_dcp
puts ">>> Post-debug checkpoint saved: $synth_dcp"
puts ">>> Replaced synth run checkpoint: $synth_run_dcp"

puts ">>> ILA setup complete."
puts ""
puts ">>> ============================================================"
puts ">>> ILA TRIGGER SETUP (in Vivado Hardware Manager after bitfile):"
puts ">>> ============================================================"
puts ">>> Probe key signals:"
puts ">>>   dbg_halted_r         - core is halted (1=halted)"
puts ">>>   dbg_step_pending_r   - single-step armed (1=armed)"
puts ">>>   resume_req_i         - DTM resume request to core"
puts ">>>   dbg_resume_flush     - resume processing active"
puts ">>>   trace_valid_r        - instruction retired (registered)"
puts ">>>   trace_retire         - instruction retire pulse"
puts ">>>   dbg_singlestep_i     - DCSR.step bit seen by core"
puts ">>>"
puts ">>> Recommended trigger: dbg_halted_r == FALLING (B 1->0)"
puts ">>>   i.e., trigger when core transitions from halted to running."
puts ">>> Expected behaviour on GOOD single-step:"
puts ">>>   1. resume_req_i rises while dbg_halted_r=1, dbg_singlestep_i=1"
puts ">>>   2. dbg_resume_flush pulses for 1 cycle"
puts ">>>   3. dbg_halted_r falls (trigger fires)"
puts ">>>   4. dbg_step_pending_r = 1"
puts ">>>   5. trace_retire pulses within ~10 cycles (instruction retires)"
puts ">>>   6. trace_valid_r goes 1 the cycle after trace_retire"
puts ">>>   7. dbg_halted_r rises again (step halt)"
puts ">>>"
puts ">>> If dbg_step_pending_r stays 0 after trigger -> dbg_singlestep_i was 0"
puts ">>> If trace_retire never pulses -> fetch stall (check IBUF, PC)"
puts ">>> If dbg_resume_flush never fires -> resume_req not reaching core"
puts ">>> ============================================================"
