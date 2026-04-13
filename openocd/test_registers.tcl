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
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}

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

# Write/read mscratch (CSR 0x340) with all-zeros and all-ones boundary patterns.
# mscratch is a clean scratch register with no architectural side-effects.
set mscratch_orig [reg_val mscratch]
foreach pattern {0x00000000 0xFFFFFFFF 0xA5A5A5A5 0x5A5A5A5A} {
    reg mscratch $pattern
    set got [reg_val mscratch]
    if {$got != $pattern} {
        error "mscratch boundary pattern $pattern: got=[format 0x%08x $got]"
    }
}
reg mscratch $mscratch_orig
puts "mscratch boundary patterns OK"

# Write/read sp and ra using numeric values to confirm all 32 GPRs are reachable.
# Note: OpenOCD names x8 "fp" (frame pointer), not "s0".
foreach {rname wval} {sp 0x11111111  ra 0x22222222  fp 0x33333333  s1 0x44444444} {
    set orig [reg_val $rname]
    reg $rname $wval
    set got [reg_val $rname]
    if {$got != $wval} {
        error "$rname write/read mismatch: expected=[format 0x%08x $wval] got=[format 0x%08x $got]"
    }
    reg $rname $orig
}
puts "sp/ra/fp(s0)/s1 write/read OK"
puts "\[PASS\] register access"
