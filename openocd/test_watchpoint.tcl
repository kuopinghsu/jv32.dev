puts "\[TEST\] watchpoint"

# Strategy: configure triggers directly, then execute a controlled store via
# debug progbuf execution so the test is independent of startup-side effects.
set wp_store_addr 0x90000000

proc reg_val {name} {
    set s [reg $name]
    if {[regexp {0x([0-9a-fA-F]+)} $s -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse register value from: $s"
}

proc as_u32 {v} {
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} { return [expr "0x$hex"] }
    if {[regexp {^[0-9]+$} $v]} { return [expr {$v + 0}] }
    error "Cannot parse numeric value from: $v"
}

proc clear_cmderr {} {
    riscv dmi_write 0x16 [expr {7 << 8}]
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

proc write_gpr {gpr val} {
    # Write val into DATA0, then abstract write DATA0 -> x[gpr].
    riscv dmi_write 0x04 $val
    set regno [expr {0x1000 + ($gpr & 0x1F)}]
    riscv dmi_write 0x17 [expr {(2 << 20) | (1 << 17) | (1 << 16) | $regno}]
    after 10
    check_cmderr "write_gpr x$gpr" 0
}

# ── subtest: write watchpoint ─────────────────────────────────────────────────
puts "\[SUBTEST\] write watchpoint"
reset halt
if {[catch {wait_halt 2000}]} {
    error "hart did not halt after reset"
}

# Program an exact-address store watchpoint directly through the trigger CSRs.
# This exercises the actual mcontrol hardware path without relying on OpenOCD's
# higher-level wp translation policy.
set trig_store_cfg 0x08001042
reg tselect 0x0
reg tdata1 $trig_store_cfg
reg tdata2 $wp_store_addr
set cfg_rd  [reg_val tdata1]
set addr_rd [reg_val tdata2]
if {($cfg_rd & 0x00001042) != 0x00001042} {
    error "write watchpoint config did not stick: tdata1=[format 0x%08x $cfg_rd]"
}
if {$addr_rd != $wp_store_addr} {
    error "write watchpoint address did not stick: expected=[format 0x%08x $wp_store_addr] got=[format 0x%08x $addr_rd]"
}

# Prepare and execute one explicit store instruction via progbuf:
#   sw x11, 0(x10)
# with x10=wp_store_addr.
write_gpr 10 $wp_store_addr
riscv dmi_write 0x20 0x00B52023   ;# sw x11,0(x10)
riscv dmi_write 0x21 0x00100073   ;# ebreak

# postexec-only command executes the progbuf without transfer.
riscv dmi_write 0x17 [expr {(2 << 20) | (1 << 18)}]
after 50
check_cmderr "write watchpoint postexec" 0

# Disable trigger 0 after the hit so the rest of the test can continue.
reg tdata1 0x0

# Validate DCSR.cause == 2 (trigger) after watchpoint fires.
set dcsr [reg_val dcsr]
set dcsr_cause [expr {($dcsr >> 6) & 0x7}]
if {$dcsr_cause != 2} {
    error "write wp: DCSR.cause expected 2 (trigger) after watchpoint got $dcsr_cause (dcsr=[format 0x%08x $dcsr])"
}
puts "write watchpoint hit on [format 0x%08x $wp_store_addr] dcsr.cause=$dcsr_cause OK"

# ── subtest: read watchpoint ──────────────────────────────────────────────────
# Use a controlled debug progbuf load (lw) from the watched address so the test
# is deterministic and independent of OpenOCD halt-request timing.
puts "\[SUBTEST\] read watchpoint"
halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt for read wp test"
}
set rwp_addr $wp_store_addr

set trig_load_cfg 0x08001041
reg tselect 0x1
reg tdata1 $trig_load_cfg
reg tdata2 $rwp_addr

# Execute one explicit load instruction via progbuf:
#   lw x12, 0(x10)
# with x10=rwp_addr.
write_gpr 10 $rwp_addr
riscv dmi_write 0x20 0x00052603   ;# lw x12,0(x10)
riscv dmi_write 0x21 0x00100073   ;# ebreak

riscv dmi_write 0x17 [expr {(2 << 20) | (1 << 18)}]
after 50
check_cmderr "read watchpoint postexec" 0

# Disable trigger 1 after the hit.
reg tselect 0x1
reg tdata1 0x0

set dcsr2 [reg_val dcsr]
set cause2 [expr {($dcsr2 >> 6) & 0x7}]
if {$cause2 != 2} {
    error "read wp: DCSR.cause expected 2 (trigger) got $cause2"
}
puts "read watchpoint hit at [format 0x%08x $rwp_addr] dcsr.cause=$cause2 OK"

puts "\[PASS\] watchpoint"
