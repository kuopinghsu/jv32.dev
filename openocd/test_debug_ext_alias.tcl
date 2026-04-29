puts "\[TEST\] debug out-of-TCM alias routing"

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}

# This test must use a direct debug memory mode (not progbuf) so accesses
# originate from the debug memory request path in RTL.
if {[catch {riscv set_mem_access sysbus} err]} {
    puts "\[SKIP\] sysbus memory mode unavailable: $err"
    return
}

set iram_alias 0x60000420
set iram_tcm   0x80000420
set dram_alias 0x70000600
set dram_tcm   0x90000600

# Write via out-of-TCM alias, then read via canonical TCM address.
mww $iram_alias 0xA1B2C3D4
set iram_from_tcm [lindex [read_memory $iram_tcm 32 1] 0]
if {$iram_from_tcm != 0xA1B2C3D4} {
    error "IRAM alias->TCM mismatch: expected=0xA1B2C3D4 got=[format 0x%08x $iram_from_tcm]"
}

mww $dram_alias 0x1122EE44
set dram_from_tcm [lindex [read_memory $dram_tcm 32 1] 0]
if {$dram_from_tcm != 0x1122EE44} {
    error "DRAM alias->TCM mismatch: expected=0x1122EE44 got=[format 0x%08x $dram_from_tcm]"
}

# Write via canonical TCM address, then read back via out-of-TCM alias.
mww $iram_tcm 0x55AA7788
set iram_from_alias [lindex [read_memory $iram_alias 32 1] 0]
if {$iram_from_alias != 0x55AA7788} {
    error "IRAM TCM->alias mismatch: expected=0x55AA7788 got=[format 0x%08x $iram_from_alias]"
}

mww $dram_tcm 0xDEADBEEF
set dram_from_alias [lindex [read_memory $dram_alias 32 1] 0]
if {$dram_from_alias != 0xDEADBEEF} {
    error "DRAM TCM->alias mismatch: expected=0xDEADBEEF got=[format 0x%08x $dram_from_alias]"
}

puts "IRAM alias [format 0x%08x $iram_alias] <-> TCM [format 0x%08x $iram_tcm] OK"
puts "DRAM alias [format 0x%08x $dram_alias] <-> TCM [format 0x%08x $dram_tcm] OK"
puts "\[PASS\] debug out-of-TCM alias routing"
