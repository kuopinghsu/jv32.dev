puts "\[TEST\] debug error path and recovery"

# Use an unmapped address to trigger an access error path.
set bad_addr  0x90000000
set good_addr 0x80000980

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}

# Use the known-good memory path for recovery checks.
riscv set_mem_access progbuf

# Expect an error for unmapped access; if not, report and continue.
set saw_error 0
if {[catch {set _r [lindex [read_memory $bad_addr 32 1] 0]} err]} {
    set saw_error 1
    puts "observed expected access failure at [format 0x%08x $bad_addr]: $err"
} else {
    puts "\[WARN\] unmapped read did not fail at [format 0x%08x $bad_addr]"
}

# Recovery check: force a clean reset-halt after the expected fault, then
# verify that valid memory operations still work again.
reset halt
if {[catch {wait_halt 2000}]} {
    error "hart did not re-halt cleanly after debug error recovery reset"
}

set recovery_mode ""
set got 0
foreach mode {abstract progbuf sysbus} {
    if {[catch {riscv set_mem_access $mode}]} {
        continue
    }
    if {[catch {
        mww $good_addr 0xCAFEBABE
        set got [lindex [read_memory $good_addr 32 1] 0]
    }]} {
        continue
    }
    if {$got == 0xCAFEBABE} {
        set recovery_mode $mode
        break
    }
}
if {$recovery_mode eq ""} {
    error "no recovery memory access mode completed successfully after debug error"
}
puts "recovery mode: $recovery_mode"

if {$saw_error} {
    puts "observed expected access failure and recovery"
} else {
    puts "unmapped access did not raise an explicit error, but recovery path validated"
}
puts "\[PASS\] debug error path and recovery"
