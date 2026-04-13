puts "\[TEST\] abstract register access (all 32 GPRs + key CSRs)"

# Tests the abstract command register-access path exhaustively:
#   1. All 32 GPRs: write a unique pattern, read back, restore.
#   2. Key M-mode CSRs: mscratch (fully writable), mtvec (alignment), mie.
#   3. x0 (zero register): writes must be silently discarded — always reads 0.

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

# ABI register names indexed by x-register number.
# Note: OpenOCD names x8 "fp" (frame pointer), not "s0".
set gpr_names {
    zero ra sp gp tp t0 t1 t2
    fp   s1 a0 a1 a2 a3 a4 a5
    a6   a7 s2 s3 s4 s5 s6 s7
    s8   s9 s10 s11 t3 t4 t5 t6
}

# ── 1. All 32 GPRs ────────────────────────────────────────────────────────────
# Pattern: 0xAB000000 | (regno << 8) | regno  — unique per register.
set fail_count 0
for {set i 1} {$i < 32} {incr i} {
    set name [lindex $gpr_names $i]
    set pattern [expr {0xAB000000 | ($i << 8) | $i}]
    set orig [reg_val $name]
    reg $name $pattern
    set got [reg_val $name]
    reg $name $orig
    if {$got != $pattern} {
        puts "  x$i ($name): MISMATCH expected=[format 0x%08x $pattern] got=[format 0x%08x $got]"
        incr fail_count
    }
}
if {$fail_count > 0} {
    error "$fail_count GPR(s) failed write/read round-trip"
}
puts "all 31 writable GPRs (x1-x31) write/read OK"

# ── 2. x0 (zero): writes discarded ───────────────────────────────────────────
reg zero 0xDEADBEEF
set zero_val [reg_val zero]
if {$zero_val != 0} {
    error "x0 (zero) should always read 0, got=[format 0x%08x $zero_val]"
}
puts "x0 (zero) read-only OK"

# ── 3. CSR: mscratch (fully writable, no side-effects) ───────────────────────
set ms_orig [reg_val mscratch]
foreach pattern {0x00000000 0xFFFFFFFF 0xDEADC0DE 0x01234567} {
    reg mscratch $pattern
    set got [reg_val mscratch]
    if {$got != $pattern} {
        error "mscratch pattern=[format 0x%08x $pattern] got=[format 0x%08x $got]"
    }
}
reg mscratch $ms_orig
puts "mscratch (CSR 0x340) read/write OK"

# ── 4. CSR: mtvec — bottom 2 bits (mode) are implementation-defined ──────────
# Direct mode (mode=0) must be supported; upper bits are the trap base address.
# Write a known-aligned value, mask off the bottom 2 bits for comparison.
set mv_orig [reg_val mtvec]
set test_mtvec 0x80010000
reg mtvec $test_mtvec
set got_mtvec [reg_val mtvec]
reg mtvec $mv_orig
# Only compare the BASE field [31:2]; mode bits may be forced.
set base_got [expr {$got_mtvec & ~0x3}]
set base_exp [expr {$test_mtvec & ~0x3}]
if {$base_got != $base_exp} {
    error "mtvec BASE mismatch: expected=[format 0x%08x $base_exp] got=[format 0x%08x $base_got]"
}
puts "mtvec (CSR 0x305) BASE field read/write OK"

# ── 5. CSR: mie — machine interrupt enable bits ───────────────────────────────
# Bits [11]=MEIE [7]=MTIE [3]=MSIE are writable; others may be WARL 0.
set mie_orig [reg_val mie]
set mie_test [expr {(1 << 11) | (1 << 7) | (1 << 3)}]
reg mie $mie_test
set got_mie [reg_val mie]
reg mie $mie_orig
# Mask to only the standard machine-mode enable bits.
set got_mie_std [expr {$got_mie & $mie_test}]
if {$got_mie_std != $mie_test} {
    error "mie standard enable bits mismatch: expected=[format 0x%08x $mie_test] got=[format 0x%08x $got_mie]"
}
puts "mie (CSR 0x304) MEIE/MTIE/MSIE bits OK"

puts "\[PASS\] abstract register access (all 32 GPRs + key CSRs)"
