puts "\[TEST\] misa ISA register"

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

# misa for this core is hard-wired to 0x40001105 (RV32IMAC).
# [31:30] = 01  → MXL = 32-bit
# bit 0  = A    → Atomic extension
# bit 2  = C    → Compressed extension
# bit 8  = I    → Base integer ISA
# bit 12 = M    → Multiply/divide extension
set misa [reg_val misa]
puts "misa=[format 0x%08x $misa]"

# MXL [31:30]: 01 = 32-bit
set mxl [expr {($misa >> 30) & 0x3}]
if {$mxl != 1} {
    error "misa.MXL expected 1 (32-bit) got $mxl"
}

# Required extensions for RV32IMAC
foreach {ext_name bit} {A 0  C 2  I 8  M 12} {
    set present [expr {($misa >> $bit) & 1}]
    if {!$present} {
        error "misa.$ext_name (bit $bit) not set — expected RV32IMAC"
    }
}

# Unexpected extensions: F D V must be absent
foreach {ext_name bit} {F 5  D 3  V 21} {
    set present [expr {($misa >> $bit) & 1}]
    if {$present} {
        error "misa.$ext_name (bit $bit) unexpectedly set (core is RV32IMAC only)"
    }
}

puts "misa MXL=32-bit extensions: A C I M confirmed; F D V absent"
puts "\[PASS\] misa ISA register"
