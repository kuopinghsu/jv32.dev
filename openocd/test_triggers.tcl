puts "\[TEST\] trigger module"

# Tests the hardware trigger module (N_TRIGGERS=2):
#   1. tinfo: mcontrol (type-2) is the only supported type.
#   2. tselect isolation: tdata2[0] and tdata2[1] are independent banks.
#   3. Trigger 0 execute match: fires on the spin-loop PC.
#   4. Trigger 1 execute match: force OpenOCD to allocate trigger 1 by
#      occupying trigger 0 with an unreachable dummy bp first.
#
# Why `halt` (not `reset halt`) for sections 3 & 4:
#   `reset halt` stops the hart at an *arbitrary* instruction in the first
#   few boot instructions (JTAG synchronisation latency).  A one-shot
#   execute trigger at a higher address will then never fire if the PC has
#   already advanced past it.  The spin-loop is a safe, stable, repeatedly-
#   executed address that a trigger can fire on reliably regardless of when
#   the hart was halted.

proc reg_val {name} {
    set s [reg $name]
    if {[regexp {0x([0-9a-fA-F]+)} $s -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse register value from: $s"
}

# ── 1. tinfo ─────────────────────────────────────────────────────────────────
halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}

set tinfo [reg_val tinfo]
puts "tinfo=[format 0x%08x $tinfo]"
if {!($tinfo & 0x4)} {
    error "tinfo bit 2 (mcontrol / type-2) not set — expected type-2 trigger support"
}
puts "tinfo type-2 (mcontrol) supported OK"

# ── 2. tselect isolation ─────────────────────────────────────────────────────
# Program trigger 0 and trigger 1 to distinct unreachable addresses using
# OpenOCD's `bp ... hw` (so OpenOCD's internal state stays consistent).
# Then read tdata2 back via tselect to confirm the two banks are independent.
set iso_addr0 0x80008000
set iso_addr1 0x8000C000

catch {rbp $iso_addr0}; catch {rbp $iso_addr1}
if {[catch {bp $iso_addr0 4 hw} e0]} { error "isolation bp0 failed: $e0" }
if {[catch {bp $iso_addr1 4 hw} e1]} {
    catch {rbp $iso_addr0}
    error "isolation bp1 failed: $e1"
}

reg tselect 0x0
set t0_tdata2 [reg_val tdata2]
reg tselect 0x1
set t1_tdata2 [reg_val tdata2]

puts "tdata2\[0\]=[format 0x%08x $t0_tdata2] (expected [format 0x%08x $iso_addr0])"
puts "tdata2\[1\]=[format 0x%08x $t1_tdata2] (expected [format 0x%08x $iso_addr1])"
catch {rbp $iso_addr0}; catch {rbp $iso_addr1}

if {$t0_tdata2 != $iso_addr0} {
    error "tdata2\[0\] mismatch: expected=[format 0x%08x $iso_addr0] got=[format 0x%08x $t0_tdata2]"
}
if {$t1_tdata2 != $iso_addr1} {
    error "tdata2\[1\] mismatch: expected=[format 0x%08x $iso_addr1] got=[format 0x%08x $t1_tdata2]"
}
puts "tselect isolation OK"

# ── 3. Trigger 0 execute match ───────────────────────────────────────────────
# Hart is still halted at the spin-loop.  Set hw bp: OpenOCD allocates trigger 0.
set spin_pc [reg_val pc]
puts "spin_pc=[format 0x%08x $spin_pc]"

catch {rbp $spin_pc}
if {[catch {bp $spin_pc 2 hw} e3]} {
    error "trigger 0 bp failed: $e3"
}
resume
if {[catch {wait_halt 1000}]} {
    catch {rbp $spin_pc}
    error "trigger 0: hart did not halt on execute match"
}
set pc0    [reg_val pc]
set dcsr0  [reg_val dcsr]
set cause0 [expr {($dcsr0 >> 6) & 0x7}]
catch {rbp $spin_pc}

if {[expr {abs($pc0 - $spin_pc)}] > 4} {
    error "trigger 0 PC mismatch: expected=[format 0x%08x $spin_pc] got=[format 0x%08x $pc0]"
}
if {$cause0 != 2} {
    error "trigger 0: DCSR.cause expected 2 (trigger) got $cause0"
}
puts "trigger 0 fired at [format 0x%08x $pc0] DCSR.cause=$cause0 OK"

# ── 4. Trigger 1 execute match ───────────────────────────────────────────────
# Occupy trigger 0 with a dummy bp at an unreachable IRAM address so that
# OpenOCD is forced to allocate trigger 1 for the real spin-loop bp.
set dummy_addr 0x8000FF00

catch {rbp $dummy_addr}; catch {rbp $spin_pc}
if {[catch {bp $dummy_addr 4 hw} ed]} {
    error "dummy bp (occupy trigger 0) failed: $ed"
}
if {[catch {bp $spin_pc 2 hw} e4]} {
    catch {rbp $dummy_addr}
    error "trigger 1 bp failed: $e4"
}
resume
if {[catch {wait_halt 1000}]} {
    catch {rbp $dummy_addr}; catch {rbp $spin_pc}
    error "trigger 1: hart did not halt on execute match"
}
set pc1    [reg_val pc]
set dcsr1  [reg_val dcsr]
set cause1 [expr {($dcsr1 >> 6) & 0x7}]
catch {rbp $dummy_addr}; catch {rbp $spin_pc}

if {[expr {abs($pc1 - $spin_pc)}] > 4} {
    error "trigger 1 PC mismatch: expected=[format 0x%08x $spin_pc] got=[format 0x%08x $pc1]"
}
if {$cause1 != 2} {
    error "trigger 1: DCSR.cause expected 2 (trigger) got $cause1"
}
puts "trigger 1 fired at [format 0x%08x $pc1] DCSR.cause=$cause1 OK"

puts "\[PASS\] trigger module"

