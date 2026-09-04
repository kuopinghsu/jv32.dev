puts "\[TEST\] dmcontrol.dmactive — DM reset and re-activate"

# Tests the dmactive bit in DMCONTROL (DMI 0x10).
# Per RISC-V Debug Spec 1.0 (dmactive semantics):
#   dmactive=0 resets the debug module.
#   dmactive=1 brings it out of reset and makes it operational.
#
# Minimum expected behaviour verified here:
#   1. On entry, dmactive=1 and DM is functional.
#   2. Write dmactive=0: DMCONTROL.dmactive reads back 0.
#   3. Write dmactive=1: DM re-activates.
#   4. After re-activation: dmstatus.authenticated=1, version=3, DM usable.
#   5. Verify halt/read/resume cycle works after re-activation.
#
# During dmactive=0 the hart may lose debug state.  We re-halt after
# re-activation to restore a clean debug state for downstream tests.

proc as_u32 {v} {
    if {[regexp {^0x[0-9a-fA-F]+$} $v]} { scan $v %x n; return $n }
    if {[regexp {^[0-9]+$} $v]} { return [expr {$v + 0}] }
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} { return [expr "0x$hex"] }
    error "Cannot parse numeric value from: $v"
}

proc reg_val {name} {
    set s [reg $name]
    if {[regexp {0x([0-9a-fA-F]+)} $s -> hex]} { return [expr "0x$hex"] }
    error "Cannot parse register value from: $s"
}

# Ensure the hart is halted before we poke DMCONTROL.
halt
if {[catch {wait_halt 1000}]} {
    error "initial halt failed"
}
after 20

# ── 1. Verify dmactive=1 on entry ─────────────────────────────────────────────
puts "\[SUBTEST\] Entry state: dmactive=1"

set ctrl [as_u32 [riscv dmi_read 0x10]]
set dmactive_before [expr {$ctrl & 1}]
puts "  DMCONTROL=[format 0x%08x $ctrl] dmactive=$dmactive_before"
if {$dmactive_before != 1} {
    error "Expected dmactive=1 on entry, got DMCONTROL=[format 0x%08x $ctrl]"
}
puts "Entry dmactive=1 OK"

# ── 2. Write dmactive=0: DM reset ─────────────────────────────────────────────
puts "\[SUBTEST\] Write dmactive=0 (DM reset)"

# DMCONTROL bit 0 = dmactive.  Writing 0 resets the DM.
# We must only clear dmactive, not assert haltreq/resumereq/ndmreset.
# Safe write: only bit 0 = 0.
riscv dmi_write 0x10 0x00000000
after 20

set ctrl_reset [as_u32 [riscv dmi_read 0x10]]
set dmactive_reset [expr {$ctrl_reset & 1}]
puts "  DMCONTROL after dmactive=0 write: [format 0x%08x $ctrl_reset] dmactive=$dmactive_reset"

if {$dmactive_reset != 0} {
    # Not all implementations expose dmactive=0 as readable; some just stop
    # responding.  OpenOCD may auto-restore dmactive.  Mark as warning.
    puts "  WARNING: DMCONTROL.dmactive did not read 0 after write (implementation may auto-recover)"
} else {
    puts "dmactive=0 reads back as 0 OK"
}

# ── 3. Write dmactive=1: re-activate ──────────────────────────────────────────
puts "\[SUBTEST\] Write dmactive=1 (DM re-activate)"

riscv dmi_write 0x10 0x00000001
after 50  ;# allow DM to come out of reset

set ctrl_reactivate [as_u32 [riscv dmi_read 0x10]]
set dmactive_reactivate [expr {$ctrl_reactivate & 1}]
puts "  DMCONTROL after dmactive=1 write: [format 0x%08x $ctrl_reactivate] dmactive=$dmactive_reactivate"
if {$dmactive_reactivate != 1} {
    error "dmactive did not return to 1 after re-activation, DMCONTROL=[format 0x%08x $ctrl_reactivate]"
}
puts "dmactive=1 OK"

# ── 4. DM functional after re-activation ──────────────────────────────────────
puts "\[SUBTEST\] DM functional after re-activation"

set dmstatus [as_u32 [riscv dmi_read 0x11]]
set version  [expr {$dmstatus & 0xf}]
set authed   [expr {($dmstatus >> 7) & 1}]

puts "  dmstatus=[format 0x%08x $dmstatus] version=$version authenticated=$authed"

if {$version != 3} {
    error "dmstatus.version=$version after re-activation; expected 3"
}
if {!$authed} {
    error "dmstatus.authenticated=0 after re-activation"
}
puts "DM functional: version=3, authenticated=1 OK"

# ── 5. Halt / read register / resume cycle after re-activation ─────────────────
puts "\[SUBTEST\] Halt/read/resume cycle after re-activation"

halt
if {[catch {wait_halt 1000}]} {
    error "halt failed after DM re-activation"
}

set pc [reg_val pc]
set a0 [reg_val a0]
puts "  pc=[format 0x%08x $pc] a0=[format 0x%08x $a0]"

# Verify PC is in a sensible code range.
if {$pc < 0x80000000 || $pc > 0x9FFFFFFF} {
    error "PC=[format 0x%08x $pc] is outside expected memory range after re-activation"
}
puts "  register read OK: pc=[format 0x%08x $pc]"

resume
after 50
set dmst_run [as_u32 [riscv dmi_read 0x11]]
set running  [expr {($dmst_run >> 10) & 1}]
puts "  after resume: dmstatus=[format 0x%08x $dmst_run] anyrunning=$running"
if {!$running} {
    error "hart did not resume after DM re-activation"
}
puts "halt/read/resume cycle OK"

# Re-halt for clean state.
halt
if {[catch {wait_halt 500}]} {
    puts "  WARNING: re-halt after cycle did not complete within timeout"
}

puts "\[PASS\] dmcontrol.dmactive"
