puts "\[TEST\] reset"

proc reg_val {name} {
    set s [reg $name]
    if {[regexp {0x([0-9a-fA-F]+)} $s -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse register value from: $s"
}

halt
set pc_before [reg_val pc]
reset halt
if {[catch {wait_halt 1000}]} {
    error "core not halted after reset"
}
set pc_after [reg_val pc]
puts "pc_before=$pc_before pc_after=$pc_after"
puts "\[PASS\] reset"
