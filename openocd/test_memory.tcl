puts "\[TEST\] memory access"

# Exercise memory access via abstract command + program buffer path.
riscv set_mem_access progbuf

halt
# Use an address well into the data/BSS region (past all code/rodata)
# 0x80000800 = 2KB into RAM -- safely after text for small test programs
set base 0x80000800

# Use read_memory for TCL-friendly numeric return values
mww $base 0x11223344
set r0 [lindex [read_memory $base 32 1] 0]
if {$r0 != 0x11223344} {
    error "word mismatch: expected=0x11223344 got=[format 0x%08x $r0]"
}

mwh [expr {$base + 4}] 0x5566
set r1 [lindex [read_memory [expr {$base + 4}] 16 1] 0]
if {$r1 != 0x5566} {
    error "halfword mismatch: expected=0x5566 got=[format 0x%04x $r1]"
}

set baddr [expr {$base + 6}]
mwb $baddr 0x77
set r2 [lindex [read_memory $baddr 8 1] 0]
if {$r2 != 0x77} {
    error "byte mismatch: expected=0x77 got=[format 0x%02x $r2]"
}
puts "\[PASS\] memory access"
