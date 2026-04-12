puts "\[TEST\] register access"

# Helper: extract numeric value from "reg" return string
# OpenOCD returns eg "a0 (/32): 0x12345678"
proc reg_val {name} {
    set s [reg $name]
    if {[regexp {0x([0-9a-fA-F]+)} $s -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse register value from: $s"
}

halt

# Read pc
set pc_val [reg_val pc]
puts "pc = [format 0x%08x $pc_val]"

# Write/read a0 (x10) and t0 (x5) using ABI names
foreach {rname wval} {a0 0x12345678  t0 0x87654321} {
    set orig [reg_val $rname]
    reg $rname $wval
    set got [reg_val $rname]
    if {$got != $wval} {
        error "$rname write/read mismatch: expected=[format 0x%08x $wval] got=[format 0x%08x $got]"
    }
    reg $rname $orig
}

# Read CSRs
set mstatus [reg_val mstatus]
set mepc    [reg_val mepc]
set mcause  [reg_val mcause]
puts "mstatus=[format 0x%08x $mstatus] mepc=[format 0x%08x $mepc] mcause=[format 0x%08x $mcause]"
puts "\[PASS\] register access"
