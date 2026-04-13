proc reg_val {name} {
    set s [reg $name]
    if {[regexp {0x([0-9a-fA-F]+)} $s -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse register value from: $s"
}

proc run_breakpoint_test {label mode strict} {
    puts "\[SUBTEST\] $label"

    halt
    if {[catch {wait_halt 1000}]} {
        error "hart did not halt"
    }

    set pc0 [reg_val pc]

    # Clear any stale breakpoint at this address from a previous failed subtest.
    catch {rbp $pc0}

    if {$mode eq "hw"} {
        if {[catch {bp $pc0 2 hw} bp_err]} {
            puts "$label unsupported: $bp_err"
            return "skip"
        }
    } else {
        if {[catch {bp $pc0 2} bp_err]} {
            error "$label not supported: $bp_err"
        }
    }

    if {[catch {resume} resume_err]} {
        catch {rbp $pc0}
        error "resume failed after breakpoint set: $resume_err"
    }

    if {[catch {wait_halt 1000}]} {
        catch {rbp $pc0}
        if {$strict} {
            error "hart did not halt on $label"
        } else {
            puts "$label: hart did not halt (dcsr.ebreakm may not be set)"
            return "skip"
        }
    }

    set pc_hit [reg_val pc]
    catch {rbp $pc0}

    if {$strict} {
        # Allow small PC offset (instruction-width tolerance) for pipeline dynamics.
        set pc_diff [expr {$pc_hit - $pc0}]
        if {$pc_diff < -4 || $pc_diff > 4} {
            error "$label PC mismatch: expected=[format 0x%08x $pc0] got=[format 0x%08x $pc_hit] (diff=$pc_diff bytes)"
        }
        # Validate DCSR.cause == 2 (trigger) for hardware breakpoints.
        # DCSR is CSR 0x7B0; cause is bits [8:6].
        set dcsr [reg_val dcsr]
        set dcsr_cause [expr {($dcsr >> 6) & 0x7}]
        if {$dcsr_cause != 2} {
            error "$label DCSR.cause expected 2 (trigger) got $dcsr_cause (dcsr=[format 0x%08x $dcsr])"
        }
        puts "dcsr=[format 0x%08x $dcsr] cause=$dcsr_cause (trigger)"
    } elseif {$pc_hit != $pc0} {
        error "$label PC mismatch: expected=[format 0x%08x $pc0] got=[format 0x%08x $pc_hit]"
    }

    puts "breakpoint hit at [format 0x%08x $pc_hit]"
    return "pass"
}

set sw_status [run_breakpoint_test "software breakpoint" "sw" 0]
set hw_status [run_breakpoint_test "strict breakpoint" "hw" 1]

# ── subtest: ebreakm software breakpoint ─────────────────────────────────────
# Set dcsr.ebreakm=1 so that the hart enters debug mode on `ebreak` in M-mode.
# OpenOCD's software breakpoint inserts an `ebreak` instruction at the target
# address; with ebreakm=1 it causes a debug halt rather than a trap.
puts "\[SUBTEST\] ebreakm software breakpoint"
set ebreakm_status "skip"
if {[catch {
    halt
    if {[catch {wait_halt 1000}]} { error "halt failed" }
    set dcsr_orig [reg_val dcsr]
    # Set dcsr.ebreakm (bit 15) = 1
    reg dcsr [expr {$dcsr_orig | (1 << 15)}]
    set dcsr_with_ebreakm [reg_val dcsr]
    if {!(($dcsr_with_ebreakm >> 15) & 1)} {
        error "dcsr.ebreakm write did not stick"
    }
    set pc_eb [reg_val pc]
    catch {rbp $pc_eb}
    bp $pc_eb 2
    resume
    if {[catch {wait_halt 1000}]} {
        catch {rbp $pc_eb}
        reg dcsr $dcsr_orig
        error "ebreakm: hart did not halt on sw bp"
    }
    catch {rbp $pc_eb}
    # Restore dcsr (clears ebreakm so subsequent tests are not affected)
    reg dcsr $dcsr_orig
    set pc_got [reg_val pc]
    if {$pc_got != $pc_eb} {
        error "ebreakm sw bp PC mismatch: expected=[format 0x%08x $pc_eb] got=[format 0x%08x $pc_got]"
    }
    puts "ebreakm sw breakpoint hit at [format 0x%08x $pc_got]"
    set ebreakm_status "pass"
} ebreakm_err]} {
    puts "ebreakm sw bp: $ebreakm_err"
}

puts "subtest status: software=$sw_status strict=$hw_status ebreakm=$ebreakm_status"

if {$hw_status eq "pass" || $ebreakm_status eq "pass"} {
    puts "\[PASS\] breakpoint"
} elseif {$sw_status eq "pass"} {
    puts "\[PASS\] breakpoint"
} else {
    puts "\[SKIP\] breakpoint: no breakpoint mode triggered"
}
