puts "\[TEST\] DMI / TAP preflight (dtmcs)"

proc as_u32 {v} {
    if {[regexp {^0x[0-9a-fA-F]+$} $v]} {
        scan $v %x n
        return $n
    }
    if {[regexp {^[0-9]+$} $v]} {
        return [expr {$v + 0}]
    }
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse numeric value from: $v"
}

# ── dmstatus (DMI 0x11) ────────────────────────────────────────────────────
# Bits [3:0] = version: 2 means Debug Spec 0.13 compliant.
# Bit 7      = authenticated: must be 1 for any debug operations to work.
set dmstatus [as_u32 [riscv dmi_read 0x11]]
set version       [expr {$dmstatus & 0xf}]
set authenticated [expr {($dmstatus >> 7) & 1}]

if {$version != 2} {
    error "dmstatus.version=$version; expected 2 (Debug Spec 0.13)"
}
if {!$authenticated} {
    error "dmstatus.authenticated=0; debug module is locked"
}
puts "dmstatus=[format 0x%08x $dmstatus] version=$version authenticated=$authenticated"

# ── dmcontrol (DMI 0x10) ─────────────────────────────────────────────────
# Bit 0 = dmactive: must be 1 after OpenOCD activates the DM.
set dmcontrol [as_u32 [riscv dmi_read 0x10]]
set dmactive  [expr {$dmcontrol & 1}]
if {!$dmactive} {
    error "dmcontrol.dmactive=0; debug module is not active"
}
puts "dmcontrol=[format 0x%08x $dmcontrol] dmactive=$dmactive"

# ── hartinfo (DMI 0x12) ──────────────────────────────────────────────────
# Read-only; just confirms the DMI path can reach a non-critical register.
set hartinfo [as_u32 [riscv dmi_read 0x12]]
puts "hartinfo=[format 0x%08x $hartinfo]"

# ── abstractcs (DMI 0x16) ────────────────────────────────────────────────
# Bits [28:24] = progbufsize (should be >= 2 for progbuf operations).
# Bits [10:8]  = cmderr (should be 0 at startup, no pending error).
set abstractcs  [as_u32 [riscv dmi_read 0x16]]
set progbufsize [expr {($abstractcs >> 24) & 0x1f}]
set cmderr      [expr {($abstractcs >> 8) & 0x7}]
if {$progbufsize < 2} {
    error "abstractcs.progbufsize=$progbufsize; expected >= 2 for progbuf support"
}
if {$cmderr != 0} {
    error "abstractcs.cmderr=$cmderr at startup; expected 0 (no pending error)"
}
puts "abstractcs=[format 0x%08x $abstractcs] progbufsize=$progbufsize cmderr=$cmderr"

puts "\[PASS\] DMI / TAP preflight (dtmcs)"
