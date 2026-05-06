puts "\[TEST\] debug alias routing - SYSBUS MODE ONLY"
puts "=========================================="

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}

# Force sysbus mode
riscv set_mem_access sysbus

# Test addresses
set iram_alias_base 0x60000800
set iram_tcm_base   0x80000800

set test_passed 1

puts "Testing IRAM alias (0x6xxx → 0x8xxx) with SYSBUS mode"
puts "=========================================="

# Test 1: Write via alias, read via canonical
puts "→ Write word via alias [format 0x%08x $iram_alias_base]"
if {[catch {mww $iram_alias_base 0xDEADBEEF} err]} {
    puts "✗ Write failed: $err"
    set test_passed 0
} else {
    puts "  Read word via canonical [format 0x%08x $iram_tcm_base]"
    set val [mrw $iram_tcm_base]
    if {$val != 0xDEADBEEF} {
        puts "✗ FAIL: expected=0xDEADBEEF got=[format 0x%08x $val]"
        set test_passed 0
    } else {
        puts "✓ PASS: alias→canonical"
    }
}

# Test 2: Write via canonical, read via alias
puts "→ Write word via canonical [format 0x%08x $iram_tcm_base]"
if {[catch {mww $iram_tcm_base 0xCAFEBABE} err]} {
    puts "✗ Write failed: $err"
    set test_passed 0
} else {
    puts "  Read word via alias [format 0x%08x $iram_alias_base]"
    set val [mrw $iram_alias_base]
    if {$val != 0xCAFEBABE} {
        puts "✗ FAIL: expected=0xCAFEBABE got=[format 0x%08x $val]"
        set test_passed 0
    } else {
        puts "✓ PASS: canonical→alias"
    }
}

puts "=========================================="
if {$test_passed} {
    puts "✓✓✓ SYSBUS MODE: ALL TESTS PASSED ✓✓✓"
    exit 0
} else {
    puts "✗✗✗ SYSBUS MODE: TESTS FAILED ✗✗✗"
    exit 1
}
