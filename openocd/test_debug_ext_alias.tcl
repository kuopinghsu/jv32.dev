puts "\[TEST\] debug out-of-TCM alias routing - ALL ACCESS MODES"
puts "=========================================="
puts "Testing: abstract, progbuf, sysbus"
puts "=========================================="

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}

# Test addresses (non-overlapping, properly aligned)
# IRAM: alias 0x6000_xxxx → canonical 0x8000_xxxx
# DRAM: alias 0x7000_xxxx → canonical 0x9000_xxxx
set iram_alias_base 0x60000800
set iram_tcm_base   0x80000800
set dram_alias_base 0x70000A00
set dram_tcm_base   0x90000A00

set all_modes_passed 1
set modes_tested 0
set modes_passed 0

# Helper procedure to test a specific access mode
proc test_mode {mode_name test_addr_alias test_addr_tcm} {
    global all_modes_passed

    puts ""
    puts "=========================================="
    puts "  Testing mode: $mode_name"
    puts "=========================================="

    # Try to set the memory access mode
    if {[catch {riscv set_mem_access $mode_name} err]} {
        puts "⚠ SKIP $mode_name mode: $err"
        return 0
    }

    set mode_passed 1

    # Test 1: Write word via alias, read via canonical
    puts "→ Write word via alias [format 0x%08x $test_addr_alias]"
    if {[catch {mww $test_addr_alias 0xA1B2C3D4} err]} {
        puts "✗ Write failed: $err"
        set mode_passed 0
    } else {
        puts "  Read word via canonical [format 0x%08x $test_addr_tcm]"
        set val [lindex [read_memory $test_addr_tcm 32 1] 0]
        if {$val != 0xA1B2C3D4} {
            puts "✗ FAIL: expected=0xA1B2C3D4 got=[format 0x%08x $val]"
            set mode_passed 0
        } else {
            puts "✓ PASS: alias→canonical"
        }
    }

    # Test 2: Write word via canonical, read via alias
    puts "→ Write word via canonical [format 0x%08x $test_addr_tcm]"
    if {[catch {mww $test_addr_tcm 0x55AA7788} err]} {
        puts "✗ Write failed: $err"
        set mode_passed 0
    } else {
        puts "  Read word via alias [format 0x%08x $test_addr_alias]"
        set val [lindex [read_memory $test_addr_alias 32 1] 0]
        if {$val != 0x55AA7788} {
            puts "✗ FAIL: expected=0x55AA7788 got=[format 0x%08x $val]"
            set mode_passed 0
        } else {
            puts "✓ PASS: canonical→alias"
        }
    }

    # Test 3: Halfword access (offset +4)
    set addr_alias [expr {$test_addr_alias + 4}]
    set addr_tcm   [expr {$test_addr_tcm + 4}]
    puts "→ Write halfword via alias [format 0x%08x $addr_alias]"
    if {[catch {mwh $addr_alias 0xABCD} err]} {
        puts "✗ Write failed: $err"
        set mode_passed 0
    } else {
        puts "  Read halfword via canonical [format 0x%08x $addr_tcm]"
        set val [lindex [read_memory $addr_tcm 16 1] 0]
        if {$val != 0xABCD} {
            puts "✗ FAIL: expected=0xABCD got=[format 0x%04x $val]"
            set mode_passed 0
        } else {
            puts "✓ PASS: halfword alias→canonical"
        }
    }

    # Test 4: Byte access (offset +8)
    set addr_alias [expr {$test_addr_alias + 8}]
    set addr_tcm   [expr {$test_addr_tcm + 8}]
    puts "→ Write byte via alias [format 0x%08x $addr_alias]"
    if {[catch {mwb $addr_alias 0xA5} err]} {
        puts "✗ Write failed: $err"
        set mode_passed 0
    } else {
        puts "  Read byte via canonical [format 0x%08x $addr_tcm]"
        set val [lindex [read_memory $addr_tcm 8 1] 0]
        if {$val != 0xA5} {
            puts "✗ FAIL: expected=0xA5 got=[format 0x%02x $val]"
            set mode_passed 0
        } else {
            puts "✓ PASS: byte alias→canonical"
        }
    }

    if {$mode_passed} {
        puts ""
        puts "✓✓✓ MODE $mode_name: ALL TESTS PASSED ✓✓✓"
    } else {
        puts ""
        puts "✗✗✗ MODE $mode_name: TESTS FAILED ✗✗✗"
        set all_modes_passed 0
    }

    return $mode_passed
}

# Test all three modes with IRAM addresses
puts "\n==========================================\n"
puts "  IRAM Alias Testing (0x6xxx → 0x8xxx)"
puts "\n=========================================="

foreach mode {abstract progbuf sysbus} {
    incr modes_tested
    if {[test_mode $mode $iram_alias_base $iram_tcm_base]} {
        incr modes_passed
    }
}

# Test all three modes with DRAM addresses
puts "\n==========================================\n"
puts "  DRAM Alias Testing (0x7xxx → 0x9xxx)"
puts "\n=========================================="

foreach mode {abstract progbuf sysbus} {
    incr modes_tested
    if {[test_mode $mode $dram_alias_base $dram_tcm_base]} {
        incr modes_passed
    }
}

# Final summary
puts ""
puts "=========================================="
puts "  FINAL SUMMARY"
puts "=========================================="
puts "Modes tested: $modes_tested"
puts "Modes passed: $modes_passed"
puts "Modes failed: [expr {$modes_tested - $modes_passed}]"
puts ""

if {$all_modes_passed && $modes_passed == $modes_tested} {
    puts "✓✓✓ ALL MODES PASSED ✓✓✓"
    puts "  • abstract mode: ✓"
    puts "  • progbuf mode: ✓"
    puts "  • sysbus mode: ✓"
    puts "  • IRAM alias (0x6xxx → 0x8xxx): ✓"
    puts "  • DRAM alias (0x7xxx → 0x9xxx): ✓"
    puts "  • All data widths (8/16/32-bit): ✓"
    puts "=========================================="
    puts "\[PASS\] debug out-of-TCM alias routing - ALL MODES"
} else {
    puts "✗✗✗ SOME MODES FAILED ✗✗✗"
    puts "=========================================="
    error "\[FAIL\] debug out-of-TCM alias routing - check failures above"
}

