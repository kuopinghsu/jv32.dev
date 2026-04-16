puts "\[TEST\] memory access modes (abstract/progbuf/sysbus)"

proc try_set_mode {mode} {
    if {[catch {riscv set_mem_access $mode} err]} {
        return [list 0 $err]
    }
    return [list 1 ""]
}

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}

set modes {abstract progbuf sysbus}
set supported {}
set skipped {}
set base 0x80000900
set idx 0

foreach mode $modes {
    lassign [try_set_mode $mode] ok msg
    if {!$ok} {
        lappend skipped "$mode: $msg"
        continue
    }

    # Use mode-specific offsets so we verify each path independently.
    set addr [expr {$base + ($idx * 16)}]
    set val  [expr {0xA5000000 | ($idx << 8) | 0x5A}]

    if {[catch {mww $addr $val} wr_err]} {
        lappend skipped "$mode: write failed: $wr_err"
        continue
    }
    if {[catch {set got [lindex [read_memory $addr 32 1] 0]} rd_err]} {
        lappend skipped "$mode: read failed: $rd_err"
        continue
    }
    if {$got != $val} {
        lappend skipped "$mode: mismatch at [format 0x%08x $addr], got=[format 0x%08x $got]"
        continue
    }

    lappend supported $mode
    incr idx
}

if {[llength $supported] == 0} {
    error "no supported memory access mode found"
}

puts "supported modes: $supported"
if {[llength $skipped] > 0} {
    puts "skipped modes: $skipped"
}

# Restore default mode so subsequent tests are not affected.
catch {riscv set_mem_access progbuf}

puts "\[PASS\] memory access modes"
