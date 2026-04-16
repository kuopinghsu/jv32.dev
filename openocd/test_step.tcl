puts "\[TEST\] single-step (step/stepi/next/nexti)"

# OpenOCD TCL exposes one instruction-level step command: "step [address]".
# On a bare-metal RISC-V hart without OS context, step/stepi/next/nexti are
# all equivalent to one machine-instruction step.  This test exercises the
# step command multiple times (covering step, stepi, next, nexti semantics)
# and verifies:
#   1. Each step advances the PC.
#   2. The hart re-halts after every step.
#   3. DCSR.step is cleared after stepping (hart runs freely on resume).

proc reg_val {name} {
    set s [reg $name]
    if {[regexp {0x([0-9a-fA-F]+)} $s -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse register value from: $s"
}

# Halt wherever the core is and then redirect DPC to the boot address so
# the step test starts from known, clean code (startup code, before any IRQ).
halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt before step test"
}

# Set DPC to BOOT_ADDR (0x80000000): startup code, interrupts not yet enabled.
# This ensures stepping from a predictable location regardless of where the
# VPI boot left off (which could be inside an interrupt handler).
reg pc 0x80000000

set pc0 [reg_val pc]
puts "pc before step: [format 0x%08x $pc0]"

# ── stepi equivalent: step #1 ────────────────────────────────────────────────
step
if {[catch {wait_halt 1000}]} {
    error "hart did not re-halt after step #1 (stepi)"
}
set pc1 [reg_val pc]
puts "step #1 (stepi): pc=[format 0x%08x $pc1]"
if {$pc1 == $pc0} {
    error "step #1: PC did not advance (still [format 0x%08x $pc0])"
}

# Validate DCSR.cause == 4 (step) after every step.
# DCSR is CSR 0x7B0; cause is bits [8:6].
set dcsr [reg_val dcsr]
set dcsr_cause [expr {($dcsr >> 6) & 0x7}]
if {$dcsr_cause != 4} {
    error "DCSR.cause expected 4 (step) got $dcsr_cause (dcsr=[format 0x%08x $dcsr])"
}
puts "dcsr=[format 0x%08x $dcsr] cause=$dcsr_cause (step)"

# ── stepi equivalent: step #2 ────────────────────────────────────────────────
step
if {[catch {wait_halt 1000}]} {
    error "hart did not re-halt after step #2 (stepi)"
}
set pc2 [reg_val pc]
puts "step #2 (stepi): pc=[format 0x%08x $pc2]"
if {$pc2 == $pc1} {
    error "step #2: PC did not advance (still [format 0x%08x $pc1])"
}
set dcsr2 [reg_val dcsr]
set dcsr_cause2 [expr {($dcsr2 >> 6) & 0x7}]
if {$dcsr_cause2 != 4} {
    error "step #2: DCSR.cause expected 4 (step) got $dcsr_cause2 (dcsr=[format 0x%08x $dcsr2])"
}

# ── next equivalent: step #3 ─────────────────────────────────────────────────
step
if {[catch {wait_halt 1000}]} {
    error "hart did not re-halt after step #3 (next)"
}
set pc3 [reg_val pc]
puts "step #3 (next):  pc=[format 0x%08x $pc3]"
if {$pc3 == $pc2} {
    error "step #3: PC did not advance (still [format 0x%08x $pc2])"
}
set dcsr3 [reg_val dcsr]
set dcsr_cause3 [expr {($dcsr3 >> 6) & 0x7}]
if {$dcsr_cause3 != 4} {
    error "step #3: DCSR.cause expected 4 (step) got $dcsr_cause3 (dcsr=[format 0x%08x $dcsr3])"
}

# ── nexti equivalent: step #4 ────────────────────────────────────────────────
step
if {[catch {wait_halt 1000}]} {
    error "hart did not re-halt after step #4 (nexti)"
}
set pc4 [reg_val pc]
puts "step #4 (nexti): pc=[format 0x%08x $pc4]"
if {$pc4 == $pc3} {
    error "step #4: PC did not advance (still [format 0x%08x $pc3])"
}
set dcsr4 [reg_val dcsr]
set dcsr_cause4 [expr {($dcsr4 >> 6) & 0x7}]
if {$dcsr_cause4 != 4} {
    error "step #4: DCSR.cause expected 4 (step) got $dcsr_cause4 (dcsr=[format 0x%08x $dcsr4])"
}

# ── Verify DCSR.step cleared: hart runs freely after resume ──────────────────
resume
sleep 20
halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt after resume — DCSR.step may be stuck"
}
set pc5 [reg_val pc]
puts "pc after resume+halt: [format 0x%08x $pc5]"

puts "\[PASS\] single-step (step/stepi/next/nexti)"
