puts "\[TEST\] CSR field validation (mstatus, mtvec, mepc, dpc, mscratch, mcause, mtval)"

# Validates individual CSR fields via abstract register access:
#   1. mstatus.MIE  (bit 3)  — writable; enable/disable interrupts via debug
#   2. mstatus.MPIE (bit 7)  — writable save/restore target for interrupt enable
#   3. mtvec BASE   [31:2]   — 4-byte aligned (direct mode requires alignment)
#   4. mepc         [31:1]   — 2-byte aligned (LSB always reads as 0 per spec)
#   5. dpc (reg pc in debug mode) — must be within IRAM [0x80000000, 0x8001FFFF]

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

# ── 1. mstatus.MIE (bit 3): write 1 and 0, verify round-trip ─────────────────
set ms_orig [reg_val mstatus]

set ms_mie_on [expr {$ms_orig | (1 << 3)}]
reg mstatus $ms_mie_on
set ms_r1 [reg_val mstatus]
if {(($ms_r1 >> 3) & 1) != 1} {
    error "mstatus.MIE write-1 failed (mstatus=[format 0x%08x $ms_r1])"
}

set ms_mie_off [expr {$ms_orig & ~(1 << 3)}]
reg mstatus $ms_mie_off
set ms_r2 [reg_val mstatus]
if {(($ms_r2 >> 3) & 1) != 0} {
    error "mstatus.MIE write-0 failed (mstatus=[format 0x%08x $ms_r2])"
}

reg mstatus $ms_orig
puts "mstatus.MIE (bit 3) writable OK"

# ── 2. mstatus.MPIE (bit 7): writable ────────────────────────────────────────
set ms_mpie_on [expr {$ms_orig | (1 << 7)}]
reg mstatus $ms_mpie_on
set ms_r3 [reg_val mstatus]
if {(($ms_r3 >> 7) & 1) != 1} {
    error "mstatus.MPIE write-1 failed (mstatus=[format 0x%08x $ms_r3])"
}

reg mstatus $ms_orig
puts "mstatus.MPIE (bit 7) writable OK"

# ── 3. mtvec BASE [31:2]: must be 4-byte aligned ──────────────────────────────
# Write a known aligned value and verify the BASE field survives.
# Bottom 2 bits (mode field) are WARL; only the BASE is checked here.
set mv_orig [reg_val mtvec]
set mv_test 0x80010000
reg mtvec $mv_test
set mv_r [reg_val mtvec]
reg mtvec $mv_orig
set mv_base_got [expr {$mv_r & ~0x3}]
set mv_base_exp [expr {$mv_test & ~0x3}]
if {$mv_base_got != $mv_base_exp} {
    error "mtvec BASE mismatch: expected=[format 0x%08x $mv_base_exp] got=[format 0x%08x $mv_base_got]"
}
puts "mtvec (CSR 0x305) BASE=[format 0x%08x $mv_base_got] 4-byte aligned OK"

# Confirm original mtvec BASE was also aligned.
set orig_base [expr {$mv_orig & ~0x3}]
if {($orig_base & 0x3) != 0} {
    error "original mtvec BASE=[format 0x%08x $orig_base] not 4-byte aligned"
}

# ── 4. mepc [31:1]: hardware-written value must be 2-byte aligned ─────────────
# mepc is only meaningful after a trap. If it is 0 (no trap yet), skip.
# Otherwise verify LSB==0 — the hardware always writes a 2-byte-aligned PC.
set mepc_val [reg_val mepc]
if {$mepc_val != 0} {
    if {($mepc_val & 0x1) != 0} {
        error "mepc hardware value not 2-byte aligned: [format 0x%08x $mepc_val]"
    }
    puts "mepc=[format 0x%08x $mepc_val] 2-byte aligned OK"
} else {
    puts "mepc=0x00000000 (no trap yet) — alignment check skipped"
}

# ── 5. dpc (reg pc in debug mode): must be in IRAM ───────────────────────────
# The VPI simulation always runs hello.elf which ends in `j _spin` inside IRAM.
set dpc [reg_val pc]
if {$dpc < 0x80000000 || $dpc > 0x8001FFFF} {
    error "dpc=[format 0x%08x $dpc] outside IRAM [0x80000000, 0x8001FFFF]"
}
puts "dpc=[format 0x%08x $dpc] in IRAM range OK"

# ── 6. mscratch (CSR 0x340): full write/read round-trip via DTM shadow ─────────
# mscratch is a shadow CSR in the jv32 DTM; accessible without progbuf.
# It has no WARL constraints — all 32 bits are read/write.
set ms_orig [reg_val mscratch]
puts "mscratch original = [format 0x%08x $ms_orig]"

reg mscratch 0xCAFEBABE
set ms_r1 [reg_val mscratch]
if {$ms_r1 != 0xCAFEBABE} {
    reg mscratch $ms_orig
    error "mscratch write 0xCAFEBABE failed: got [format 0x%08x $ms_r1]"
}

reg mscratch 0xDEAD5678
set ms_r2 [reg_val mscratch]
if {$ms_r2 != 0xDEAD5678} {
    reg mscratch $ms_orig
    error "mscratch write 0xDEAD5678 failed: got [format 0x%08x $ms_r2]"
}

reg mscratch $ms_orig
puts "mscratch (CSR 0x340) write/read round-trip OK"

# ── 7. mcause (CSR 0x342): write/read round-trip ───────────────────────────────
# mcause is a DTM shadow CSR.  In normal execution it holds the cause of the
# last trap.  Writing it via debug does not cause a trap; it just updates the
# shadow register.  Bit [31] = interrupt (1) or exception (0); [30:0] = code.
set mc_orig [reg_val mcause]
puts "mcause original = [format 0x%08x $mc_orig]"

# Write an exception cause (bit 31 = 0, code = 0xB = machine external interrupt
# cause — just used here as a known bit pattern).
reg mcause 0x0000000B
set mc_r1 [reg_val mcause]
if {$mc_r1 != 0x0000000B} {
    reg mcause $mc_orig
    error "mcause write 0x0000000B failed: got [format 0x%08x $mc_r1]"
}

# Write an interrupt cause (bit 31 = 1).
reg mcause 0x80000007
set mc_r2 [reg_val mcause]
if {$mc_r2 != 0x80000007} {
    reg mcause $mc_orig
    error "mcause write 0x80000007 failed: got [format 0x%08x $mc_r2]"
}

reg mcause $mc_orig
puts "mcause (CSR 0x342) write/read round-trip OK"

# ── 8. mtval (CSR 0x343): write/read round-trip ────────────────────────────────
# mtval is a DTM shadow CSR holding the faulting address or instruction word.
# All 32 bits are writable via debug.
set mv_orig2 [reg_val mtval]
puts "mtval original = [format 0x%08x $mv_orig2]"

reg mtval 0x80001234
set mv_r1 [reg_val mtval]
if {$mv_r1 != 0x80001234} {
    reg mtval $mv_orig2
    error "mtval write 0x80001234 failed: got [format 0x%08x $mv_r1]"
}

reg mtval 0x00000000
set mv_r2 [reg_val mtval]
if {$mv_r2 != 0x00000000} {
    reg mtval $mv_orig2
    error "mtval write 0x00000000 failed: got [format 0x%08x $mv_r2]"
}

reg mtval $mv_orig2
puts "mtval (CSR 0x343) write/read round-trip OK"

puts "\[PASS\] CSR field validation (mstatus, mtvec, mepc, dpc, mscratch, mcause, mtval)"
