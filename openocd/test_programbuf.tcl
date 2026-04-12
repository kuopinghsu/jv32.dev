puts "\[TEST\] program buffer capability"

# Helper: extract numeric value from "reg" return string
# OpenOCD returns eg "a0 (/32): 0x12345678"
proc reg_val {name} {
    set s [reg $name]
    if {[regexp {0x([0-9a-fA-F]+)} $s -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse register value from: $s"
}

proc as_u32 {v} {
    if {[regexp {^0x[0-9a-fA-F]+$} $v]} {
        scan $v %x n
        return $n
    }
    if {[regexp {^[0-9]+$} $v]} {
        return [expr {$v + 0}]
    }
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse numeric value from: $v"
}

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}

# abstractcs @ DMI 0x16: progbufsize is bits [28:24]
set abstractcs_raw [riscv dmi_read 0x16]
set abstractcs [as_u32 $abstractcs_raw]
set progbufsize [expr {($abstractcs >> 24) & 0x1f}]

if {$progbufsize < 2} {
    error "unexpected progbufsize=$progbufsize (expected >=2), abstractcs=[format 0x%08x $abstractcs]"
}

# Ensure regular abstract register access is still functional.
set orig_a0 [reg_val a0]
set test_a0 0x13579bdf
reg a0 $test_a0
set got_a0 [reg_val a0]
reg a0 $orig_a0

if {$got_a0 != $test_a0} {
    error "abstract register access failed: expected=[format 0x%08x $test_a0] got=[format 0x%08x $got_a0]"
}

# Also verify memory accesses can run through program-buffer path.
riscv set_mem_access progbuf
set base 0x80000840
mww $base 0xA55AA55A
set r0 [lindex [read_memory $base 32 1] 0]
if {$r0 != 0xA55AA55A} {
    error "progbuf memory mismatch: expected=0xA55AA55A got=[format 0x%08x $r0]"
}

puts "abstractcs=[format 0x%08x $abstractcs] progbufsize=$progbufsize"
puts "\[PASS\] program buffer capability"
