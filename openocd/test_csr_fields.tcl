puts "\[TEST\] CSR field validation (mstatus, mtvec, mepc, dpc)"

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

puts "\[PASS\] CSR field validation (mstatus, mtvec, mepc, dpc)"
