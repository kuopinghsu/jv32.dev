puts "\[TEST\] strict breakpoint"

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
if {[catch {bp $pc0 2 hw} bp_err]} {
    puts "\[SKIP\] strict breakpoint unsupported: $bp_err"
    return
}

if {[catch {resume} resume_err]} {
    catch {rbp $pc0}
    error "resume failed after breakpoint set: $resume_err"
}

if {[catch {wait_halt 1000}]} {
    catch {rbp $pc0}
    error "hart did not halt on strict breakpoint"
}

set pc_hit [reg_val pc]
catch {rbp $pc0}

if {$pc_hit != $pc0} {
    error "strict breakpoint PC mismatch: expected=[format 0x%08x $pc0] got=[format 0x%08x $pc_hit]"
}

puts "breakpoint hit at [format 0x%08x $pc_hit]"
puts "\[PASS\] strict breakpoint"
