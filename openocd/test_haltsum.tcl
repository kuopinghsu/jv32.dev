puts "\[TEST\] HALTSUM0 — halt summary register reflects hart halt state"

# Tests the HALTSUM0 register at DMI address 0x40.
# HALTSUM0 contains one bit per hart: bit N = 1 when hart N is halted, 0 when running.
# For a single-hart system (hart 0 only), bit 0 reflects the halt state.
#
# Tests:
#   1. Halted state: halt the hart; read HALTSUM0 → bit 0 must be 1.
#   2. Running state: resume the hart; read HALTSUM0 → bit 0 must be 0.
#   3. Re-halt: halt again; verify HALTSUM0 bit 0 returns to 1.
#   4. High bits: bits 31:1 should be 0 (only hart 0 exists).
#   5. Cross-check with dmstatus.allhalted field: both should agree.

proc as_u32 {v} {
    if {[regexp {^0x[0-9a-fA-F]+$} $v]} { scan $v %x n; return $n }
    if {[regexp {^[0-9]+$} $v]} { return [expr {$v + 0}] }
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} { return [expr "0x$hex"] }
    error "Cannot parse numeric value from: $v"
}

# Convenience: check dmstatus.allhalted (bit 9) and allrunning (bit 11).
proc dmstatus_allhalted {} {
    set s [as_u32 [riscv dmi_read 0x11]]
    return [expr {($s >> 9) & 1}]
}
proc dmstatus_allrunning {} {
    set s [as_u32 [riscv dmi_read 0x11]]
    return [expr {($s >> 11) & 1}]
}

# ── 1. Halted state ────────────────────────────────────────────────────────────
puts "\[SUBTEST\] HALTSUM0 when hart is halted"

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}
after 20  ;# allow HALTSUM0 register to update

set hs0 [as_u32 [riscv dmi_read 0x40]]
set bit0 [expr {$hs0 & 1}]
set dmst [as_u32 [riscv dmi_read 0x11]]
set allhalted [expr {($dmst >> 9) & 1}]

puts "  HALTSUM0=[format 0x%08x $hs0] bit0=$bit0 dmstatus.allhalted=$allhalted"

if {$bit0 != 1} {
    error "HALTSUM0 bit 0 should be 1 when hart is halted, got HALTSUM0=[format 0x%08x $hs0]"
}
if {$allhalted != 1} {
    error "dmstatus.allhalted should be 1 when hart is halted, got dmstatus=[format 0x%08x $dmst]"
}

# HALTSUM0 bits 31:1 should be 0 (only hart 0 in this system).
set high_bits [expr {$hs0 & 0xFFFFFFFE}]
if {$high_bits != 0} {
    error "HALTSUM0 high bits should be 0 for single-hart, got [format 0x%08x $high_bits]"
}
puts "HALTSUM0 halted: bit0=1, high bits=0, matches dmstatus.allhalted OK"

# ── 2. Running state ───────────────────────────────────────────────────────────
puts "\[SUBTEST\] HALTSUM0 when hart is running"

resume
after 100  ;# wait for hart to resume and HALTSUM0 to update

set hs0_run [as_u32 [riscv dmi_read 0x40]]
set bit0_run [expr {$hs0_run & 1}]
set dmst_run [as_u32 [riscv dmi_read 0x11]]
set allrunning [expr {($dmst_run >> 11) & 1}]

puts "  HALTSUM0=[format 0x%08x $hs0_run] bit0=$bit0_run dmstatus.allrunning=$allrunning"

if {$bit0_run != 0} {
    # Hart may have hit a WFI or loop — halt it to confirm state then fail.
    halt
    error "HALTSUM0 bit 0 should be 0 when hart is running, got HALTSUM0=[format 0x%08x $hs0_run]"
}
if {$allrunning != 1} {
    halt
    error "dmstatus.allrunning should be 1 after resume, got dmstatus=[format 0x%08x $dmst_run]"
}
puts "HALTSUM0 running: bit0=0, matches dmstatus.allrunning OK"

# ── 3. Re-halt ─────────────────────────────────────────────────────────────────
puts "\[SUBTEST\] HALTSUM0 returns to 1 on re-halt"

halt
if {[catch {wait_halt 1000}]} {
    error "re-halt: hart did not halt"
}
after 20

set hs0_rehalt [as_u32 [riscv dmi_read 0x40]]
set bit0_rehalt [expr {$hs0_rehalt & 1}]
set dmst_rehalt [as_u32 [riscv dmi_read 0x11]]
set allhalted_rehalt [expr {($dmst_rehalt >> 9) & 1}]

puts "  HALTSUM0=[format 0x%08x $hs0_rehalt] bit0=$bit0_rehalt dmstatus.allhalted=$allhalted_rehalt"

if {$bit0_rehalt != 1} {
    error "HALTSUM0 bit 0 should be 1 after re-halt, got HALTSUM0=[format 0x%08x $hs0_rehalt]"
}
if {$allhalted_rehalt != 1} {
    error "dmstatus.allhalted should be 1 after re-halt, got dmstatus=[format 0x%08x $dmst_rehalt]"
}
puts "HALTSUM0 re-halt: bit0=1 OK"

# ── 4. HALTSUM0 consistency with dmstatus across multiple poll cycles ──────────
puts "\[SUBTEST\] HALTSUM0 consistent with dmstatus across 5 poll cycles"

for {set i 0} {$i < 5} {incr i} {
    set hs0_poll [as_u32 [riscv dmi_read 0x40]]
    set bit0_poll [expr {$hs0_poll & 1}]
    set ah_poll [dmstatus_allhalted]
    if {$bit0_poll != $ah_poll} {
        error "Poll $i: HALTSUM0 bit0=$bit0_poll != dmstatus.allhalted=$ah_poll"
    }
}
puts "HALTSUM0 / dmstatus.allhalted consistent across 5 polls: OK"

puts "\[PASS\] HALTSUM0"
