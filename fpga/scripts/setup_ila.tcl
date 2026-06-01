# =============================================================================
# File   : setup_ila.tcl
# Project: JV32 RISC-V SoC
# Brief  : Post-synthesis ILA insertion script for single-step debug.
#
# Sourced by create_project.tcl when ILA_DEBUG=1 (after synth_1 is open).
# Creates an ILA and connects an explicit list of debug nets from the
# synthesized netlist.
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

puts ">>> ILA Debug: inserting debug core from explicit net list ..."

# ---------------------------------------------------------------------------
# Truncate any stale ILA content that a previous run appended to the XDC.
# Vivado's save_constraints appends debug core definitions to source XDC files;
# those entries cause Chipscope/Common errors when the file is re-read without
# an ILA present.  Strip everything after the last purely-timing constraint.
# ---------------------------------------------------------------------------
set xdc_files [get_files -quiet -of_objects [get_filesets constrs_1] "*constraints_cjtag.xdc"]
foreach xdc_f $xdc_files {
    if {[catch {
        set fh [open $xdc_f r]
        set lines [split [read $fh] "\n"]
        close $fh
        # Find the last line that belongs to the timing-only section:
        # keep all lines up to (and including) the last line that is either a
        # comment, blank, or a pure timing constraint (no debug_core/debug_port).
        set keep_until -1
        set idx 0
        foreach ln $lines {
            set trimmed [string trim $ln]
            if {$trimmed eq "" ||
                [string match "#*" $trimmed] ||
                ([string match "set_*" $trimmed] && ![string match "*debug*" $trimmed]) ||
                [string match "create_clock*" $trimmed] ||
                [string match "set_clock*" $trimmed] ||
                [string match "set_false_path*" $trimmed] ||
                [string match "set_output_delay*" $trimmed] ||
                [string match "set_input_delay*" $trimmed]} {
                set keep_until $idx
            }
            incr idx
        }
        if {$keep_until >= 0} {
            set clean_lines [lrange $lines 0 $keep_until]
            set fh [open $xdc_f w]
            puts $fh [join $clean_lines "\n"]
            close $fh
            puts ">>> NOTE: truncated stale ILA content from [file tail $xdc_f] (kept [expr {$keep_until + 1}] lines)"
        }
    } err]} {
        puts ">>> WARNING: could not truncate $xdc_f: $err"
    }
}

# ---------------------------------------------------------------------------
# Create the ILA explicitly, then attach debug nets from a curated list.
# implement_debug_core only implements debug cores that already exist, so the
# core must be created and wired up before that step.
# ---------------------------------------------------------------------------
set ila_name "ila_0"
create_debug_core $ila_name ila

# Curated debug signal list with alternate hierarchy patterns.
# The first matching pattern per logical signal is used.
set debug_signal_specs [list \
    [list "halt_req_i"            [list "*u_core/halt_req_i" "*u_jv32/u_core/halt_req_i" "*halt_req_i*"]] \
    [list "resume_req_i"          [list "*u_core/resume_req_i" "*u_jv32/u_core/resume_req_i" "*resume_req_i*"]] \
    [list "dbg_pc_we_i"           [list "*u_core/dbg_pc_we_i" "*u_jv32/u_core/dbg_pc_we_i" "*dbg_pc_we_i*"]] \
    [list "dbg_singlestep_i"      [list "*u_core/dbg_singlestep_i" "*u_jv32/u_core/dbg_singlestep_i" "*dbg_singlestep_i*"]] \
    [list "dbg_halted_r"          [list "*u_core/dbg_halted_r*" "*u_jv32/u_core/dbg_halted_r*" "*dbg_halted_r*"]] \
    [list "dbg_resumeack_r"       [list "*u_core/dbg_resumeack_r*" "*u_jv32/u_core/dbg_resumeack_r*" "*dbg_resumeack_r*"]] \
    [list "dbg_step_pending_r"    [list "*u_core/dbg_step_pending_r*" "*u_jv32/u_core/dbg_step_pending_r*" "*dbg_step_pending_r*"]] \
    [list "dbg_step_served_r"     [list "*u_core/dbg_step_served_r*" "*u_jv32/u_core/dbg_step_served_r*" "*dbg_step_served_r*"]] \
    [list "dbg_step_fire_r"       [list "*u_core/dbg_step_fire_r*" "*u_jv32/u_core/dbg_step_fire_r*" "*dbg_step_fire_r*"]] \
    [list "dbg_resume_flush"      [list "*u_core/dbg_resume_flush*" "*u_jv32/u_core/dbg_resume_flush*" "*dbg_resume_flush*"]] \
    [list "trace_valid_r"         [list "*u_core/trace_valid_r*" "*u_jv32/u_core/trace_valid_r*" "*trace_valid_r*"]] \
    [list "trace_retire"          [list "*u_core/trace_retire*" "*u_jv32/u_core/trace_retire*" "*trace_retire*"]] \
    [list "cmd_busy"              [list "*u_dtm/cmd_busy*" "*u_jtag_tap/u_dtm/cmd_busy*" "*cmd_busy*"]] \
    [list "dcsr_reg"              [list "*u_dtm/dcsr_reg*" "*u_jtag_tap/u_dtm/dcsr_reg*" "*dcsr_reg*"]] \
    [list "halt_req_sync_chain"   [list "*u_dtm/halt_req_sync_chain*" "*u_jtag_tap/u_dtm/halt_req_sync_chain*" "*halt_req_sync_chain*"]] \
    [list "resume_req_sync_chain" [list "*u_dtm/resume_req_sync_chain*" "*u_jtag_tap/u_dtm/resume_req_sync_chain*" "*resume_req_sync_chain*"]] \
]

set debug_nets [list]
foreach sig_spec $debug_signal_specs {
    set sig_name [lindex $sig_spec 0]
    set patterns [lindex $sig_spec 1]
    set sig_matches [list]

    foreach spec $patterns {
        set matches [get_nets -quiet -hier $spec]

        # Fallback: if net names were rewritten, recover via matching pins.
        if {[llength $matches] == 0} {
            set pin_matches [get_pins -quiet -hier $spec]
            if {[llength $pin_matches] > 0} {
                set matches [get_nets -quiet -of_objects $pin_matches]
            }
        }

        if {[llength $matches] > 0} {
            set sig_matches $matches
            break
        }
    }

    if {[llength $sig_matches] == 0} {
        puts ">>> WARNING: debug signal '$sig_name' matched no nets."
        continue
    }

    foreach n $sig_matches {
        # Skip Vivado-generated debug artifacts and known non-routable aliases.
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

set debug_nets [lsort -dictionary -unique $debug_nets]
if {[llength $debug_nets] == 0} {
    error ">>> No debug nets matched the explicit ILA debug list; cannot create ILA."
}

puts ">>> NOTE: explicit debug net list matched [llength $debug_nets] nets."

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
        error ">>> Encountered an empty debug net object while building ILA probes."
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

        # get_nets -segments traverses hierarchy and may return auto-generated
        # ILA bookkeeping aliases (ila_0_*, ila_1_*, …) even when the parent
        # net_obj was already filtered.  connect_debug_port silently rejects
        # those with Chipscope 16-3, leaving probe channels vacant (→ 16-213).
        # Skip them here using the same regex used when building debug_nets.
        if {[regexp {(^|/)ila_[0-9]+_} $seg_name]} {
            continue
        }

        # Size this probe port from the name only.  The outer get_nets -segments
        # call splits vectors; do NOT call get_nets -segments a second time here
        # (that returns hierarchy aliases of the same bit, not additional bits,
        # inflating PORT_WIDTH and producing vacant channels).
        set seg_width 1
        if {[regexp {\[(\d+):(\d+)\]$} $seg_name -> msb lsb]} {
            set seg_width [expr {abs($msb - $lsb) + 1}]
        }

        # probe0 is auto-created by create_debug_core; reuse it for the first
        # segment to avoid leaving it unconnected (Chipscope 16-213).
        if {$probe_idx == 0} {
            set probe_obj [get_debug_ports ${ila_name}/probe0]
        } else {
            set probe_obj [create_debug_port $ila_name probe]
        }
        set_property PORT_WIDTH $seg_width $probe_obj

        if {[catch {connect_debug_port $probe_obj [list $seg_net]} conn_err]} {
            puts ">>> WARNING: skipping segment '$seg_name': $conn_err"
            if {$probe_idx > 0} {
                catch {delete_debug_port $probe_obj}
            }
            continue
        }

        incr probe_idx
        # One probe per logical net is sufficient; stop iterating hierarchy
        # aliases of the same physical bit to avoid duplicate probe ports.
        break
    }

    if {$probe_truncated} {
        break
    }
}

if {$probe_truncated} {
    puts ">>> WARNING: probe creation truncated at ${max_probe_ports} ports to stay below Vivado debug-port limits."
}

puts ">>> ILA probe channels created: $probe_idx"

# save_constraints is required by Vivado before implement_debug_core.
# The stale-content problem is handled above by truncating the XDC at the
# start of this script, so save_constraints only appends fresh probe data.
catch {save_constraints -force}

if {[catch {implement_debug_core} impl_err]} {
    error ">>> implement_debug_core failed after manual probe wiring: $impl_err"
}

# Some Vivado runs leave dbg_hub/clk disconnected even after implement_debug_core.
# Reconnect and verify explicitly against the same net as the ILA.
set dbg_hubs [get_debug_cores -quiet dbg_hub*]
set ila_clk_port [get_debug_ports -quiet ${ila_name}/clk]
set ila_clk_nets [get_nets -quiet -of_objects $ila_clk_port]
set hub_clk_fallback ""
if {[llength $ila_clk_nets] > 0} {
    set hub_clk_fallback [lindex $ila_clk_nets 0]
}

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
        # Fallback: reuse the resolved ILA clock net object/name if available.
        if {$hub_clk_fallback ne ""} {
            catch {disconnect_debug_port $hub_clk_port}
            if {![catch {connect_debug_port $hub_clk_port $hub_clk_fallback} hub_fb_err]} {
                set hub_clk_nets [get_nets -quiet -of_objects $hub_clk_port]
            } else {
                puts ">>> WARNING: ${hub}/clk fallback reconnect to '$hub_clk_fallback' failed: $hub_fb_err"
            }
        }
    }

    if {[llength $hub_clk_nets] == 0} {
        # Some Vivado versions do not reliably report debug-port net objects at
        # this stage; continue and let downstream implementation validate.
        puts ">>> WARNING: ${hub}/clk net is not introspectable after reconnect; continuing."
        continue
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
# Probe description (.ltx) generation is deferred to post-implementation.
# Vivado may not provide stable debug UUIDs at synthesis-time.
# ---------------------------------------------------------------------------
puts ">>> NOTE: LTX generation deferred until after implementation (UUIDs may be unavailable at synth stage)."

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
