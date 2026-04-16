puts "\[TEST\] DM control: havereset, hartreset, impebreak, nonexistent hart, postexec, quick_access"

# Tests Debug Module control features that are not covered by other tests:
#
#   1. impebreak (dmstatus bit [22]): hardware sets this to 1 to indicate an
#      implicit ebreak is appended to each progbuf execution window.
#   2. anynonexistent / allnonexistent (dmstatus bits [15:14]): selecting a
#      hart index > 0 must report the hart as non-existent.
#   3. havereset sticky (dmstatus bits [19:18]): going high after ndmreset.
#   4. ackhavereset (dmcontrol bit [28]): W1C clears the havereset sticky bit.
#   5. hartreset (dmcontrol bit [29]): resets the hart only; sets havereset.
#   6. CMD_QUICK_ACCESS (cmdtype=1) rejection: must return CMDERR_NOTSUP (4).
#   7. postexec-only command (cmdtype=0, transfer=0, postexec=1): executes
#      the program buffer without a register transfer; must succeed (cmderr=0).
#
# DMCONTROL bit positions (per Debug Spec 0.13 and jv32 RTL):
#   [31] haltreq        [30] resumereq    [29] hartreset
#   [28] ackhavereset   [25:16] hartsel   [1] ndmreset    [0] dmactive

proc as_u32 {v} {
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} { return [expr "0x$hex"] }
    if {[regexp {^[0-9]+$} $v]} { return [expr {$v + 0}] }
    error "Cannot parse numeric value from: $v"
}

proc clear_cmderr {} {
    riscv dmi_write 0x16 [expr {7 << 8}]  ;# W7C: write 111 to bits [10:8]
}

proc check_cmderr {label expected} {
    set acs [as_u32 [riscv dmi_read 0x16]]
    set err [expr {($acs >> 8) & 0x7}]
    if {$err != $expected} {
        clear_cmderr
        error "$label: cmderr expected $expected got $err (abstractcs=[format 0x%08x $acs])"
    }
    if {$expected != 0} { clear_cmderr }
}

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}

# ── 1. impebreak bit (dmstatus bit [22]) ─────────────────────────────────────
# jv32 uses an implicit ebreak (impebreak=1): the progbuf does NOT need to
# contain an explicit ebreak in the last slot.  OpenOCD checks this bit to
# determine how many effective progbuf slots are available for user code.
set dms [as_u32 [riscv dmi_read 0x11]]
set impebreak [expr {($dms >> 22) & 1}]
puts "dmstatus=[format 0x%08x $dms] impebreak=$impebreak"
if {$impebreak != 1} {
    error "impebreak expected 1 (implicit ebreak after progbuf), got $impebreak"
}
puts "impebreak (dmstatus\[22\]) = 1 OK"

# ── 2. anynonexistent: select non-existent hart ───────────────────────────────
# jv32 is single-hart.  Writing hartsel=1 (hartsello[0]=1) selects a hart that
# does not exist.  dmstatus.anynonexistent (bit [15]) must become 1.
set dmc_orig [as_u32 [riscv dmi_read 0x10]]
puts "dmcontrol (original) = [format 0x%08x $dmc_orig]"

set dmc_hart1 [expr {(1 << 16) | 1}]  ;# hartsello=1, dmactive=1
poll off
riscv dmi_write 0x10 $dmc_hart1
set dms_noex [as_u32 [riscv dmi_read 0x11]]
poll on
set anynonexistent [expr {($dms_noex >> 15) & 1}]
set allnonexistent [expr {($dms_noex >> 14) & 1}]
puts "hart1 selected: dmstatus=[format 0x%08x $dms_noex] anynonexistent=$anynonexistent allnonexistent=$allnonexistent"
if {$anynonexistent != 1} {
    riscv dmi_write 0x10 $dmc_orig
    error "anynonexistent expected 1 for non-existent hart 1, got $anynonexistent"
}
if {$allnonexistent != 1} {
    riscv dmi_write 0x10 $dmc_orig
    error "allnonexistent expected 1 for non-existent hart 1, got $allnonexistent"
}

# Restore hart selection to hart 0.
riscv dmi_write 0x10 $dmc_orig
after 10
puts "anynonexistent / allnonexistent for hart 1 OK"

# ── 3. hartreset → havereset sticky = 1 ──────────────────────────────────────
# OpenOCD's internal poll clears havereset the moment it detects a new halt,
# so we must read dmstatus WHILE THE HART IS STILL IN RESET (before OpenOCD
# can process the halt event).
# havereset_r is set in the DTM's TCK domain the instant hartreset=1 is written.
puts "\[SUBTEST\] hartreset → havereset sticky"

# Assert hartreset + haltreq in one write; havereset_r latches immediately.
# Use poll off so OpenOCD's background event loop cannot auto-ack havereset
# between the write and our dmstatus read.
poll off
riscv dmi_write 0x10 [expr {(1 << 31) | (1 << 29) | 1}]  ;# haltreq|hartreset|dmac

# Read dmstatus NOW, while hartreset is still asserted (hart is in reset).
# OpenOCD has not seen a halt event yet, so havereset has not been acked.
set dms_in_rst [as_u32 [riscv dmi_read 0x11]]
poll on
set anyhavereset_rst [expr {($dms_in_rst >> 19) & 1}]
puts "dmstatus while hartreset asserted = [format 0x%08x $dms_in_rst] anyhavereset=$anyhavereset_rst"
if {$anyhavereset_rst != 1} {
    riscv dmi_write 0x10 [expr {(1 << 28) | 1}]  ;# ack + release
    error "anyhavereset expected 1 after hartreset assert, got $anyhavereset_rst"
}
puts "anyhavereset = 1 immediately after hartreset assert OK"

# ── 4. ackhavereset W1C clears the sticky bit ─────────────────────────────────
# Write ackhavereset=1 while still in reset (hart cannot interfere).
riscv dmi_write 0x10 [expr {(1 << 31) | (1 << 29) | (1 << 28) | 1}]  ;# hr|ack|da
after 5
set dms_acked [as_u32 [riscv dmi_read 0x11]]
set anyhavereset_acked [expr {($dms_acked >> 19) & 1}]
puts "dmstatus after ackhavereset (still in reset) = [format 0x%08x $dms_acked] anyhavereset=$anyhavereset_acked"
if {$anyhavereset_acked != 0} {
    error "anyhavereset expected 0 after ackhavereset, got $anyhavereset_acked"
}
puts "ackhavereset (dmcontrol bit \[28\]) W1C clear OK"

# Release hartreset; hart restarts and halts due to already-latched haltreq.
riscv dmi_write 0x10 [expr {(1 << 31) | 1}]  ;# haltreq|dmactive, hartreset=0
after 50
set dms_rel [as_u32 [riscv dmi_read 0x11]]
for {set i 0} {$i < 20 && !(($dms_rel >> 9) & 1)} {incr i} {
    after 10; set dms_rel [as_u32 [riscv dmi_read 0x11]]
}
if {!(($dms_rel >> 9) & 1)} {
    error "hart did not halt after hartreset release with haltreq"
}
puts "hartreset + havereset sticky + ackhavereset OK"

# Also verify via raw ndmreset (bit[1] of dmcontrol).
puts "\[SUBTEST\] ndmreset → havereset sticky"

# Assert ndmreset; havereset_r latches immediately in the TCK domain.
# Use poll off so OpenOCD's background event loop cannot auto-ack havereset
# between the write and our dmstatus read.
poll off
riscv dmi_write 0x10 [expr {(1 << 31) | (1 << 1) | 1}]  ;# haltreq|ndmreset|dma

set dms_nrst_on [as_u32 [riscv dmi_read 0x11]]
poll on
set anyhavereset_nrst [expr {($dms_nrst_on >> 19) & 1}]
puts "dmstatus while ndmreset asserted = [format 0x%08x $dms_nrst_on] anyhavereset=$anyhavereset_nrst"
if {$anyhavereset_nrst != 1} {
    riscv dmi_write 0x10 [expr {(1 << 28) | 1}]
    error "anyhavereset expected 1 after ndmreset assert, got $anyhavereset_nrst"
}
# Ackhavereset and release ndmreset in one write.
riscv dmi_write 0x10 [expr {(1 << 31) | (1 << 28) | 1}]  ;# haltreq|ack|dmactive
after 50
set dms_nrst_off [as_u32 [riscv dmi_read 0x11]]
for {set i 0} {$i < 20 && !(($dms_nrst_off >> 9) & 1)} {incr i} {
    after 10; set dms_nrst_off [as_u32 [riscv dmi_read 0x11]]
}
set anyhavereset_after_nrst [expr {($dms_nrst_off >> 19) & 1}]
if {$anyhavereset_after_nrst != 0} {
    error "anyhavereset expected 0 after ndmreset ack, got $anyhavereset_after_nrst"
}
puts "ndmreset → anyhavereset=1 → ackhavereset OK"

# Restore clean halted state for the remaining subtests.
reset halt
if {[catch {wait_halt 2000}]} {
    error "hart did not re-halt after cleanup reset halt"
}
riscv dmi_write 0x10 [expr {(1 << 28) | 1}]  ;# ack OpenOCD's reset-halt havereset
after 10

# ── 5. hartreset re-verify (after clean reset) ────────────────────────────────
puts "\[SUBTEST\] hartreset re-verify"
poll off
riscv dmi_write 0x10 [expr {(1 << 31) | (1 << 29) | 1}]  ;# haltreq|hartreset|dmac
set dms_rev [as_u32 [riscv dmi_read 0x11]]
poll on
if {(($dms_rev >> 19) & 1) != 1} {
    error "hartreset re-verify: anyhavereset expected 1, got [expr {($dms_rev >> 19) & 1}]"
}
# Release hartreset; hart restarts and halts.
riscv dmi_write 0x10 [expr {(1 << 31) | 1}]; after 50
set dms_rev2 [as_u32 [riscv dmi_read 0x11]]
for {set i 0} {$i < 20 && !(($dms_rev2 >> 9) & 1)} {incr i} {
    after 10; set dms_rev2 [as_u32 [riscv dmi_read 0x11]]
}
if {!(($dms_rev2 >> 9) & 1)} {
    error "hartreset re-verify: hart did not halt"
}
riscv dmi_write 0x10 [expr {(1 << 28) | 1}]; after 10
puts "hartreset re-verify OK"

# Restore once more for CMD_QUICK_ACCESS and postexec tests.
reset halt
if {[catch {wait_halt 2000}]} {
    error "hart did not re-halt after second cleanup reset halt"
}
riscv dmi_write 0x10 [expr {(1 << 28) | 1}]; after 10

# ── 6. CMD_QUICK_ACCESS rejection (cmdtype=1) → CMDERR_NOTSUP (4) ────────────
# The jv32 debug module does not implement quick access (cmdtype=1).
# Writing a quick-access command must result in CMDERR_NOTSUP=2.
check_cmderr "pre-quick-access" 0  ;# ensure no leftover error
riscv dmi_write 0x17 [expr {1 << 24}]  ;# COMMAND with cmdtype=1, rest=0
after 30
check_cmderr "CMD_QUICK_ACCESS" 2  ;# expect CMDERR_NOTSUP (2)
puts "CMD_QUICK_ACCESS (cmdtype=1) → CMDERR_NOTSUP=2 OK"

# ── 7. postexec-only command (transfer=0, postexec=1) ─────────────────────────
# Execute the program buffer without a register read/write transfer.
# Load mhartid (always 0) into a0 via progbuf, then verify a0 = 0 via a
# separate abstract register read (confirming the progbuf actually executed).
#
# Instruction: csrrs a0, mhartid(0xF14), x0
#   = (0xF14 << 20) | (2 << 12) | (10 << 7) | 0x73
set csrrs_mhartid [expr {(0xF14 << 20) | (2 << 12) | (10 << 7) | 0x73}]
riscv dmi_write 0x20 $csrrs_mhartid  ;# PROGBUF0
riscv dmi_write 0x21 0x00100073       ;# PROGBUF1 = ebreak (safety; impebreak would also work)

# postexec-only command: cmdtype=0, aarsize=2, postexec=1, transfer=0.
# COMMAND = (aarsize=2 << 20) | (postexec=1 << 18) = 0x00240000
riscv dmi_write 0x17 [expr {(2 << 20) | (1 << 18)}]
after 30
check_cmderr "postexec-only execute" 0
puts "postexec-only execute: cmderr=0 OK"

# Read a0 (x10, regno=0x100A) to confirm progbuf actually wrote to it.
# COMMAND for register read: aarsize=2, transfer=1, write=0, regno=0x100A.
riscv dmi_write 0x17 [expr {(2 << 20) | (1 << 17) | 0x100A}]
after 20
check_cmderr "postexec a0 readback" 0
set a0_val [as_u32 [riscv dmi_read 0x04]]
puts "postexec-only: a0 (mhartid) = [format 0x%08x $a0_val] (expected 0x00000000)"
if {$a0_val != 0} {
    error "postexec-only: a0 expected 0 (mhartid), got [format 0x%08x $a0_val]"
}
puts "postexec-only command (transfer=0, postexec=1) OK"

puts "\[PASS\] DM control: havereset, hartreset, impebreak, nonexistent hart, postexec, quick_access"
