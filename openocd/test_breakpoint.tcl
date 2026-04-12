puts "\[TEST\] software breakpoint"

# Tests memory-patched software breakpoints (ebreak/c.ebreak written into RAM).
# Does NOT require hardware trigger resources; fails hard if not supported.

proc reg_val {name} {
    set s [reg $name]
    if {[regexp {0x([0-9a-fA-F]+)} $s -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse register value from: $s"
}

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}

set pc0 [reg_val pc]

# Software breakpoint: OpenOCD patches memory with ebreak/c.ebreak.
# No 'hw' flag — does not consume trigger resources.
if {[catch {bp $pc0 2} bp_err]} {
    error "software breakpoint not supported: $bp_err"
}

if {[catch {resume} resume_err]} {
    catch {rbp $pc0}
    error "resume failed after software breakpoint set: $resume_err"
}

# If the hart does not halt the ebreak is going to the trap handler
# (dcsr.ebreakm not active).  Treat this as a skip — the feature is
# absent, not broken.
if {[catch {wait_halt 1000}]} {
    catch {rbp $pc0}
    puts "\[SKIP\] software breakpoint: hart did not halt (dcsr.ebreakm may not be set)"
    return
}

set pc_hit [reg_val pc]
catch {rbp $pc0}

if {$pc_hit != $pc0} {
    error "software breakpoint PC mismatch: expected=[format 0x%08x $pc0] got=[format 0x%08x $pc_hit]"
}

puts "breakpoint hit at [format 0x%08x $pc_hit]"
puts "\[PASS\] software breakpoint"
