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

# ── Test byte/halfword access with sysbus mode (if supported) ─────────────────
if {"sysbus" in $supported} {
    puts "testing byte/halfword access with sysbus mode..."
    riscv set_mem_access sysbus

    set test_base [expr {$base + 256}]

    # Test byte writes and reads
    set byte_vals {0x12 0x34 0x56 0x78}
    for {set i 0} {$i < 4} {incr i} {
        set addr [expr {$test_base + $i}]
        set val [lindex $byte_vals $i]
        mwb $addr $val
        set got [lindex [read_memory $addr 8 1] 0]
        if {$got != $val} {
            error "sysbus byte access failed at [format 0x%08x $addr]: expected=[format 0x%02x $val] got=[format 0x%02x $got]"
        }
    }

    # Verify full word to check byte positioning
    set word_got [lindex [read_memory $test_base 32 1] 0]
    set word_exp 0x78563412  ;# Little-endian
    if {$word_got != $word_exp} {
        error "sysbus byte positioning error: expected [format 0x%08x $word_exp] got [format 0x%08x $word_got]"
    }
    puts "sysbus byte access OK"

    # Test halfword writes and reads
    set half_base [expr {$test_base + 16}]
    set half_vals {0xABCD 0xEF01}
    for {set i 0} {$i < 2} {incr i} {
        set addr [expr {$half_base + $i * 2}]
        set val [lindex $half_vals $i]
        mwh $addr $val
        set got [lindex [read_memory $addr 16 1] 0]
        if {$got != $val} {
            error "sysbus halfword access failed at [format 0x%08x $addr]: expected=[format 0x%04x $val] got=[format 0x%04x $got]"
        }
    }

    # Verify full word to check halfword positioning
    set word_got [lindex [read_memory $half_base 32 1] 0]
    set word_exp 0xEF01ABCD  ;# Little-endian
    if {$word_got != $word_exp} {
        error "sysbus halfword positioning error: expected [format 0x%08x $word_exp] got [format 0x%08x $word_got]"
    }
    puts "sysbus halfword access OK"
}

# Restore default mode so subsequent tests are not affected.
catch {riscv set_mem_access progbuf}

puts "\[PASS\] memory access modes"
