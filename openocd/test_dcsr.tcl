puts "\[TEST\] DCSR field validation"

# DCSR layout (Debug Spec 0.13, §4.8.1):
#   [31:28] xdebugver  — 4 = Debug Module (external debug spec 0.13)
#   [15]    ebreakm    — ebreak in M-mode enters debug mode when set
#   [8:6]   cause      — why hart entered debug mode (3=halt_req, 4=step, 2=trigger)
#   [1:0]   prv        — privilege mode at debug entry (3 = M-mode)
#
# RTL: dcsr_reg reset = 0x40000003 (xdebugver=4, prv=3)
#       dcsr read = {4'd4, dcsr_reg[27:9], dcsr_cause_r, dcsr_reg[5:0]}

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

set dcsr [reg_val dcsr]
puts "dcsr after halt=[format 0x%08x $dcsr]"

# ── xdebugver [31:28] must be 4 (Debug Spec 0.13 external debug) ─────────────
set xdebugver [expr {($dcsr >> 28) & 0xf}]
if {$xdebugver != 4} {
    error "dcsr.xdebugver expected 4 got $xdebugver"
}
puts "xdebugver=$xdebugver (Debug Spec 0.13) OK"

# ── prv [1:0] must be 3 (M-mode) ─────────────────────────────────────────────
set prv [expr {$dcsr & 0x3}]
if {$prv != 3} {
    error "dcsr.prv expected 3 (M-mode) got $prv"
}
puts "prv=$prv (M-mode) OK"

# ── cause [8:6] must be 3 (halt_req / debugrequest) after plain halt ──────────
set cause [expr {($dcsr >> 6) & 0x7}]
if {$cause != 3} {
    error "dcsr.cause expected 3 (halt_req) after halt got $cause"
}
puts "cause=$cause (halt_req) OK"

# ── ebreakm [15]: verify writable ────────────────────────────────────────────
# Write ebreakm=1 and read back.
set dcsr_ebreakm_on [expr {$dcsr | (1 << 15)}]
reg dcsr $dcsr_ebreakm_on
set dcsr_r1 [reg_val dcsr]
set ebreakm_r1 [expr {($dcsr_r1 >> 15) & 1}]
if {$ebreakm_r1 != 1} {
    error "dcsr.ebreakm write 1 did not stick (read back=[format 0x%08x $dcsr_r1])"
}
puts "ebreakm=1 write/read OK"

# Write ebreakm=0 and read back (restore).
set dcsr_ebreakm_off [expr {$dcsr & ~(1 << 15)}]
reg dcsr $dcsr_ebreakm_off
set dcsr_r2 [reg_val dcsr]
set ebreakm_r2 [expr {($dcsr_r2 >> 15) & 1}]
if {$ebreakm_r2 != 0} {
    error "dcsr.ebreakm write 0 did not clear (read back=[format 0x%08x $dcsr_r2])"
}
puts "ebreakm=0 restore OK"

# ── xdebugver is read-only: writing should not change it ─────────────────────
# Try writing 0 to xdebugver field; read back should still be 4.
set dcsr_corrupt [expr {$dcsr_r2 & 0x0FFFFFFF}]
reg dcsr $dcsr_corrupt
set dcsr_r3 [reg_val dcsr]
set xdebugver_r3 [expr {($dcsr_r3 >> 28) & 0xf}]
if {$xdebugver_r3 != 4} {
    error "dcsr.xdebugver should be read-only=4 but became $xdebugver_r3"
}
puts "xdebugver read-only OK (stays 4 after write attempt)"

puts "dcsr final=[format 0x%08x $dcsr_r3]"
puts "\[PASS\] DCSR field validation"
