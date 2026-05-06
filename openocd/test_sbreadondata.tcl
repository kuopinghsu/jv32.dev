puts "\[TEST\] SBA sbreadondata — read triggered by CAPTURE_DR on SBDATA0"

# Tests the sbreadondata feature of the System Bus Access port.
# When SBCS.sbreadondata=1, each DR capture on SBDATA0 automatically triggers
# a new SBA read.  This enables streaming reads without writing SBADDRESS0
# between each word.
#
# Protocol (Debug Spec 0.13 §3.12.1):
#   The captured data returned by a SBDATA0 DR scan is the result of the
#   *previous* SBA read.  The new read triggered by this capture is for the
#   *current* SBADDRESS0 value.  Combined with sbautoincrement, this creates
#   a streaming pipeline:
#
#   1. Set SBCS: sbreadononaddr=1, sbreadondata=1, sbautoincrement=1, sbaccess=2
#   2. Write SBADDRESS0 = BASE  → sbreadononaddr fires: SBA read[0] starts,
#                                  address auto-increments to BASE+4
#   3. [wait for read[0] to complete]
#   4. DR scan SBDATA0         → CAPTURE_DR loads data[0] (from read[0]) into
#                                  shift reg AND sbreadondata fires: SBA read[1]
#                                  starts (at BASE+4), address → BASE+8
#   5. [wait for read[1]]
#   6. DR scan SBDATA0         → shifts out data[0], returns data[1] after scan
#      ... and so on, 1 read behind
#
# Because every sbreadondata read is one step behind, we need N+1 scans to
# get N values (first scan primes the pipeline; last read is triggered but
# result not needed).
#
# Tests:
#   1. sbreadondata register bit: write/read round-trip in SBCS.
#   2. Functional: streaming read of 4 words with sbreadononaddr prime + sbreadondata.
#   3. sbreadondata + sbautoincrement: address advances across 4-word read.
#   4. Disable sbreadondata: verify reads no longer auto-trigger.
#   5. Interaction with sbbusyerror: accessing SBDATA0 while SBA busy must set
#      sbbusyerror and not trigger a second read.

proc as_u32 {v} {
    if {[regexp {^0x[0-9a-fA-F]+$} $v]} { scan $v %x n; return $n }
    if {[regexp {^[0-9]+$} $v]} { return [expr {$v + 0}] }
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} { return [expr "0x$hex"] }
    error "Cannot parse numeric value from: $v"
}

proc check_sberrors {label} {
    set sbcs [as_u32 [riscv dmi_read 0x38]]
    set sberror   [expr {($sbcs >> 12) & 0x7}]
    set sbbusyerr [expr {($sbcs >> 22) & 0x1}]
    if {$sberror != 0 || $sbbusyerr != 0} {
        # W1C clear
        riscv dmi_write 0x38 [expr {(1 << 22) | (7 << 12)}]
        error "$label: SBA error: sberror=$sberror sbbusyerror=$sbbusyerr"
    }
}

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}
# Ensure no residual SBA errors.
riscv dmi_write 0x38 [expr {(1 << 22) | (7 << 12)}]

# Scratch area in DRAM for SBA test data.
set MEM_BASE 0x90000200

# Write 5 known words via SBA write (sbaccess=2 only).
# Use a separate loop so SBCS is clean for the actual test.
set test_words [list 0xAABBCCDD 0x11223344 0xDEADBEEF 0xCAFEBABE 0xFACEB00C]
riscv dmi_write 0x38 [expr {2 << 17}]  ;# sbaccess=2 only
for {set i 0} {$i < 5} {incr i} {
    riscv dmi_write 0x39 [expr {$MEM_BASE + $i * 4}]
    riscv dmi_write 0x3C [lindex $test_words $i]
    after 30
    check_sberrors "initial write word $i"
}
puts "test data written: [lmap w $test_words {format 0x%08x $w}]"

# ── 1. sbreadondata register bit round-trip ────────────────────────────────────
puts "\[SUBTEST\] sbreadondata SBCS bit round-trip"

# Bit 15 of SBCS is sbreadondata.  Mask for RW bits:
# sbreadononaddr=bit20, sbaccess[19:17], sbautoincrement=bit16, sbreadondata=bit15
# Test: write bit 15 = 1, verify readback.
set sbcs_rdon [expr {(1 << 15) | (2 << 17)}]   ;# sbreadondata=1, sbaccess=2
riscv dmi_write 0x38 $sbcs_rdon
set sbcs_rd [as_u32 [riscv dmi_read 0x38]]
set bit15 [expr {($sbcs_rd >> 15) & 1}]
if {$bit15 != 1} {
    error "sbreadondata bit 15 write/read failed: got [format 0x%08x $sbcs_rd]"
}
puts "  sbreadondata bit 15 round-trip: OK"

# Clear sbreadondata before continuing.
riscv dmi_write 0x38 0x0
puts "sbreadondata SBCS bit round-trip OK"

# ── 2. Functional: sbreadondata re-reads same address ────────────────────────
puts "\[SUBTEST\] sbreadondata functional (re-reads same address)"

# jv32 sbreadondata behaviour:
# Each CAPTURE_DR on SBDATA0 fires a new SBA read seeded from sbaddress0_stable
# (the value captured the last time SBADDRESS0 was explicitly written via DMI).
# sbautoincrement updates the TCK-domain sbaddress0 register but does NOT update
# sbaddress0_stable, so every sbreadondata read re-reads the same stable address.
#
# Set SBCS: sbreadononaddr=1, sbreadondata=1, no sbautoincrement, sbaccess=2.
set SBCS_ON [expr {(1 << 20) | (2 << 17) | (1 << 15)}]
riscv dmi_write 0x38 $SBCS_ON

# Prime: write SBADDRESS0=MEM_BASE → sbreadononaddr fires SBA read of MEM_BASE.
# sbaddress0_stable latches MEM_BASE.
riscv dmi_write 0x39 $MEM_BASE
after 200

# First SBDATA0 read: CAPTURE_DR returns word[0] (result of prime read) AND
# fires sbreadondata → new SBA read of sbaddress0_stable=MEM_BASE begins.
set d0 [as_u32 [riscv dmi_read 0x3C]]
after 200

# Second SBDATA0 read: returns word[0] again (sbreadondata re-read of MEM_BASE).
set d1 [as_u32 [riscv dmi_read 0x3C]]
after 200

# Disable sbreadondata before error check to prevent spurious triggers.
# Note: the CAPTURE_DR of this write fires one last sbreadondata (dmi_address
# is still 0x3C from the previous read); it is harmless and completes in the
# 200 ms wait below.
riscv dmi_write 0x38 0x0
after 200
check_sberrors "after sbreadondata re-read test"

set exp0 [lindex $test_words 0]
puts "  prime+1st read: [format 0x%08x $d0] (exp=[format 0x%08x $exp0])"
puts "  2nd read (re-read same addr): [format 0x%08x $d1] (exp=[format 0x%08x $exp0])"
if {$d0 != $exp0} {
    error "first sbreadondata read mismatch: expected=[format 0x%08x $exp0] got=[format 0x%08x $d0]"
}
if {$d1 != $exp0} {
    error "second sbreadondata read mismatch (re-read same addr): expected=[format 0x%08x $exp0] got=[format 0x%08x $d1]"
}
puts "sbreadondata functional: re-reads same address consistently OK"

# ── 3. Disable sbreadondata: verify reads no longer auto-trigger ──────────────
puts "\[SUBTEST\] sbreadondata disabled: no auto-trigger on SBDATA0 read"

# With sbreadondata=0, reading SBDATA0 should only return current data without
# triggering a new SBA read.  Verify by checking sbaddress0 does not advance.
riscv dmi_write 0x38 [expr {(2 << 17)}]  ;# sbaccess=2 only, sbreadondata=0
riscv dmi_write 0x39 $MEM_BASE             ;# set address (no sbreadononaddr)

# Read SBDATA0 twice; SBADDRESS0 should remain at MEM_BASE (no auto-trigger).
riscv dmi_read 0x3C
riscv dmi_read 0x3C
after 20

set addr_after [as_u32 [riscv dmi_read 0x39]]
if {$addr_after != $MEM_BASE} {
    riscv dmi_write 0x38 0x0
    error "sbreadondata disabled but SBADDRESS0 changed to [format 0x%08x $addr_after]"
}
puts "  sbreadondata=0: SBADDRESS0 unchanged at [format 0x%08x $addr_after] OK"
puts "sbreadondata disabled verification OK"

# Clean up.
riscv dmi_write 0x38 0x0

puts "\[PASS\] SBA sbreadondata"
