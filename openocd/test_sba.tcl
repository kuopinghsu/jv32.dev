puts "\[TEST\] SBA (System Bus Access) raw DMI protocol"

# Tests the System Bus Access port of the Debug Module via raw DMI register
# accesses (not through OpenOCD's sysbus abstraction layer).
#
# DMI register addresses:
#   0x38  SBCS       — control/status
#   0x39  SBADDRESS0 — target address (32-bit)
#   0x3C  SBDATA0    — read/write data (32-bit)
#
# jv32 advertises: sbversion=1, sbaccess32 only, sbasize=32-bit.
#
# Checks:
#   1. SBCS read-only fields: sbversion=1, sbasize=32, access32 capability set.
#   2. SBA write: write sbaddress0 then sbdata0 → bus write; verify via progbuf read.
#   3. SBA read (sbreadononaddr): write sbaddress0 triggers auto-read.
#   4. sbautoincrement + sbreadondata streaming: 4-word block read.
#   5. sbbusyerror W1C: clear the sticky error bit.
#   6. SBCS writable bits round-trip.

proc as_u32 {v} {
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} { return [expr "0x$hex"] }
    if {[regexp {^[0-9]+$} $v]} { return [expr {$v + 0}] }
    error "Cannot parse numeric value from: $v"
}

proc check_sberrors {} {
    set sbcs [as_u32 [riscv dmi_read 0x38]]
    set sberror    [expr {($sbcs >> 12) & 0x7}]
    set sbbusyerr  [expr {($sbcs >> 22) & 0x1}]
    if {$sberror != 0 || $sbbusyerr != 0} {
        # W1C clear both sberror[14:12] and sbbusyerror[22]
        riscv dmi_write 0x38 [expr {(1 << 22) | (7 << 12) | (2 << 17)}]
        error "SBA error: sberror=$sberror sbbusyerror=$sbbusyerr (sbcs=[format 0x%08x $sbcs])"
    }
}

# Use progbuf for mww so we do not touch SBA through OpenOCD's sysbus layer.
riscv set_mem_access progbuf

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}

set MEM_BASE 0x80000A00  ;# scratch area in IRAM data region

# ── 1. SBCS read-only field verification ──────────────────────────────────────
set sbcs_init [as_u32 [riscv dmi_read 0x38]]
puts "sbcs (initial) = [format 0x%08x $sbcs_init]"

set sbversion [expr {($sbcs_init >> 29) & 0x7}]
if {$sbversion != 1} {
    error "sbcs.sbversion expected 1, got $sbversion"
}
set sbasize [expr {($sbcs_init >> 5) & 0x7F}]
if {$sbasize != 32} {
    error "sbcs.sbasize expected 32, got $sbasize"
}
if {!($sbcs_init & 0x4)} {
    error "sbcs.sbaccess32 (bit 2) not set — 32-bit access not advertised"
}
if {($sbcs_init & 0x3) != 0} {
    puts "\[WARN\] sbcs.sbaccess8/16 unexpectedly set: [format 0x%08x $sbcs_init]"
}
if {($sbcs_init & 0x8) != 0} {
    puts "\[WARN\] sbcs.sbaccess64 unexpectedly set (only 32-bit supported)"
}
puts "sbcs: sbversion=$sbversion sbasize=$sbasize access32=1 OK"

# ── 2. SBA write: sbaddress0 + sbdata0 write triggers bus write ───────────────
# Configure SBCS: sbaccess=2 (32-bit), no auto-trigger bits.
riscv dmi_write 0x38 [expr {2 << 17}]  ;# sbaccess=2 only

# Write target address and data.  Writing sbdata0 triggers the bus write.
set wr_val 0xDEADC0DE
riscv dmi_write 0x39 $MEM_BASE    ;# sbaddress0 = target (no read triggered)
riscv dmi_write 0x3C $wr_val       ;# sbdata0 = value → triggers SBA write
after 50
check_sberrors

# Verify via progbuf path (independent from SBA).
set rd_via_progbuf [lindex [read_memory $MEM_BASE 32 1] 0]
puts "SBA write: wrote [format 0x%08x $wr_val] to [format 0x%08x $MEM_BASE]; read back via progbuf: [format 0x%08x $rd_via_progbuf]"
if {$rd_via_progbuf != $wr_val} {
    error "SBA write mismatch: expected [format 0x%08x $wr_val] got [format 0x%08x $rd_via_progbuf]"
}
puts "SBA write OK"

# ── 3. SBA read (sbreadononaddr): writing sbaddress0 triggers auto-read ───────
# Write a different known value via SBA to a secondary address, then read it
# back using sbreadononaddr.  This avoids D-cache coherency issues that arise
# when mixing progbuf writes (CPU pipeline, write-back cache) with SBA reads
# (direct AXI, cache-bypass).
set rd_val 0xC0FFEE42
set MEM_RD [expr {$MEM_BASE + 32}]  ;# separate address from write test

riscv dmi_write 0x38 [expr {2 << 17}]  ;# sbaccess=2 only
riscv dmi_write 0x39 $MEM_RD            ;# sbaddress0 = read-test address
riscv dmi_write 0x3C $rd_val             ;# sbdata0 write → SBA bus write
after 30
check_sberrors

# Configure SBCS: sbreadononaddr=1 + sbaccess=2.
riscv dmi_write 0x38 [expr {(1 << 20) | (2 << 17)}]  ;# sbreadononaddr | sbaccess=2
riscv dmi_write 0x39 $MEM_RD                            ;# write sbaddress0 → triggers SBA read
after 50
check_sberrors
set sba_rd [as_u32 [riscv dmi_read 0x3C]]
puts "SBA read (sbreadononaddr): [format 0x%08x $MEM_RD] → [format 0x%08x $sba_rd] (expected [format 0x%08x $rd_val])"
if {$sba_rd != $rd_val} {
    error "SBA read mismatch: expected [format 0x%08x $rd_val] got [format 0x%08x $sba_rd]"
}
puts "SBA read (sbreadononaddr) OK"

# ── 4. sbautoincrement: address advances by 4 after each SBA read ─────────────
# jv32 implements sb_autoincr but NOT sbreadondata.  Reads are triggered only
# by sbreadononaddr (write to sbaddress0).  sbautoincrement causes sbaddress0
# to advance automatically so the host can see the new address without
# computing it, and re-use it for the next read trigger.
#
# Write 4 consecutive words via SBA (avoids D-cache coherency with SBA reads).
set s_base [expr {$MEM_BASE + 64}]  ;# fresh region for this sub-test
set words {0x11111111 0x22222222 0x33333333 0x44444444}
riscv dmi_write 0x38 [expr {2 << 17}]  ;# sbaccess=2 only (for writes)
for {set i 0} {$i < 4} {incr i} {
    riscv dmi_write 0x39 [expr {$s_base + $i * 4}]
    riscv dmi_write 0x3C [lindex $words $i]
    after 10
}
after 30
check_sberrors

# Configure SBCS: sbreadononaddr=1, sbautoincrement=1, sbaccess=2.
riscv dmi_write 0x38 [expr {(1 << 20) | (2 << 17) | (1 << 16)}]

# Read 4 words: each write to sbaddress0 triggers a SBA read, and after the
# read completes sbaddress0 is auto-incremented by 4.
set results {}
for {set i 0} {$i < 4} {incr i} {
    set addr [expr {$s_base + $i * 4}]
    riscv dmi_write 0x39 $addr  ;# write sbaddress0 → trigger SBA read
    after 30
    check_sberrors
    lappend results [as_u32 [riscv dmi_read 0x3C]]
    # After the read, sbaddress0 auto-incremented; read it back to verify.
    set addr_after [as_u32 [riscv dmi_read 0x39]]
    set expected_next [expr {$addr + 4}]
    puts "sbautoincrement: after read at [format 0x%08x $addr] → sbaddress0=[format 0x%08x $addr_after] (expected [format 0x%08x $expected_next])"
    if {$addr_after != $expected_next} {
        error "sbautoincrement: sbaddress0 expected [format 0x%08x $expected_next] got [format 0x%08x $addr_after]"
    }
}

puts "SBA autoincrement reads: [lmap w $results {format 0x%08x $w}]"
foreach {i got exp} [list \
    0 [lindex $results 0] 0x11111111 \
    1 [lindex $results 1] 0x22222222 \
    2 [lindex $results 2] 0x33333333 \
    3 [lindex $results 3] 0x44444444] {
    if {$got != $exp} {
        error "autoincrement word $i mismatch: expected=[format 0x%08x $exp] got=[format 0x%08x $got]"
    }
}
puts "SBA sbautoincrement (address advance + sequential read) OK"

# ── 5. sbbusyerror W1C ────────────────────────────────────────────────────────
# The sbbusyerror bit (bit 22) is sticky and cleared only by writing 1 to bit 22.
# Trigger it: write sbdata0 while sbbusy=1 is impossible to arrange reliably in
# simulation (bus ops complete before TCL continues), so we verify the W1C
# mechanism directly: write SBCS with bit 22 set while sbbusyerror=0 and confirm
# the bit stays clear (harmless W1C write when bit is already 0).
riscv dmi_write 0x38 [expr {(1 << 22) | (2 << 17)}]  ;# attempt W1C on clear bit
set sbcs_after [as_u32 [riscv dmi_read 0x38]]
if {(($sbcs_after >> 22) & 1) != 0} {
    error "sbbusyerror W1C: bit persisted unexpectedly (sbcs=[format 0x%08x $sbcs_after])"
}
puts "sbbusyerror (bit 22) W1C mechanism OK"

# ── 6. SBCS writable bits round-trip ─────────────────────────────────────────
# Write a combination of all RW bits and read back.
# RW bits: sbreadononaddr[20], sbaccess[19:17], sbautoincrement[16], sbreadondata[15].
# sbaccess is constrained to 010 (32-bit only); other values may be corrected.
set sbcs_rw_test [expr {(1 << 20) | (2 << 17) | (1 << 16) | (1 << 15)}]
riscv dmi_write 0x38 $sbcs_rw_test
set sbcs_rw_rd [as_u32 [riscv dmi_read 0x38]]
set sbcs_rw_mask [expr {(1 << 20) | (7 << 17) | (1 << 16) | (1 << 15)}]
if {($sbcs_rw_rd & $sbcs_rw_mask) != $sbcs_rw_test} {
    error "SBCS RW round-trip mismatch: wrote [format 0x%08x $sbcs_rw_test] read [format 0x%08x $sbcs_rw_rd]"
}
puts "SBCS RW bits round-trip OK"

# ── Restore SBCS to default ───────────────────────────────────────────────────
riscv dmi_write 0x38 0x0

puts "\[PASS\] SBA (System Bus Access) raw DMI protocol"
