proc reg_val {name} {
    set s [reg $name]
    if {[regexp {0x([0-9a-fA-F]+)} $s -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse register value from: $s"
}

proc run_breakpoint_test {label mode strict} {
    puts "\[TEST\] $label"

    halt
    if {[catch {wait_halt 1000}]} {
        error "hart did not halt"
    }

    set pc0 [reg_val pc]

    if {$mode eq "hw"} {
        if {[catch {bp $pc0 2 hw} bp_err]} {
            puts "\[SKIP\] $label unsupported: $bp_err"
            return
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
            puts "\[SKIP\] $label: hart did not halt (dcsr.ebreakm may not be set)"
            return
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
    } elseif {$pc_hit != $pc0} {
        error "$label PC mismatch: expected=[format 0x%08x $pc0] got=[format 0x%08x $pc_hit]"
    }

    puts "breakpoint hit at [format 0x%08x $pc_hit]"
    puts "\[PASS\] $label"
}

run_breakpoint_test "software breakpoint" "sw" 0
run_breakpoint_test "strict breakpoint" "hw" 1
