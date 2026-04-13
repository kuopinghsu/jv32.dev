puts "\[TEST\] halt/resume"

proc as_u32 {v} {
    if {[regexp {^0x[0-9a-fA-F]+$} $v]} {
        scan $v %x n
        return $n
    }
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse numeric value from: $v"
}

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}
set pc_before [reg pc]
resume

# Verify the hart is actually running by checking dmstatus.allrunning / anyrunning.
# sleep 20 ms gives the hart time to start executing after resume.
sleep 20
set dmstatus [as_u32 [riscv dmi_read 0x11]]
set any_running [expr {($dmstatus >> 10) & 1}]
set all_running [expr {($dmstatus >> 11) & 1}]
if {!$any_running || !$all_running} {
    error "hart did not resume: dmstatus=[format 0x%08x $dmstatus]"
}

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt after resume"
}
set pc_after [reg pc]

# Note: if the hart is spinning (j _spin), pc_before == pc_after is expected and correct.
# The key test is that halt/resume/halt all succeeded and dmstatus confirmed running.
puts "pc_before=$pc_before pc_after=$pc_after dmstatus=[format 0x%08x $dmstatus]"
puts "\[PASS\] halt/resume"
