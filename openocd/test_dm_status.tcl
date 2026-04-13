puts "\[TEST\] dmstatus halt/resume transitions"

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

proc read_dmstatus {} {
    set raw [riscv dmi_read 0x11]
    return [as_u32 $raw]
}

proc check_halted {dm label} {
    set any_halted [expr {($dm >> 8) & 1}]
    set all_halted [expr {($dm >> 9) & 1}]
    if {!$any_halted || !$all_halted} {
        error "$label: expected halted state in dmstatus=[format 0x%08x $dm]"
    }
}

proc check_running {dm label} {
    set any_running [expr {($dm >> 10) & 1}]
    set all_running [expr {($dm >> 11) & 1}]
    if {!$any_running || !$all_running} {
        error "$label: expected running state in dmstatus=[format 0x%08x $dm]"
    }
}

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}

set dm_halt_0 [read_dmstatus]
check_halted $dm_halt_0 "after initial halt"

resume
sleep 20
set dm_run [read_dmstatus]
check_running $dm_run "after resume"

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not re-halt"
}
set dm_halt_1 [read_dmstatus]
check_halted $dm_halt_1 "after second halt"

# Validate dmstatus.version == 2 (Debug Spec 0.13)
set version [expr {$dm_halt_0 & 0xf}]
if {$version != 2} {
    error "dmstatus.version expected 2 (debug spec 0.13) got $version"
}
# Validate authenticated bit is set
set authenticated [expr {($dm_halt_0 >> 7) & 1}]
if {!$authenticated} {
    error "dmstatus.authenticated not set (debug module not authenticated)"
}
puts "dmstatus halt0=[format 0x%08x $dm_halt_0] run=[format 0x%08x $dm_run] halt1=[format 0x%08x $dm_halt_1]"
puts "dmstatus.version=$version authenticated=$authenticated"
puts "\[PASS\] dmstatus halt/resume transitions"
