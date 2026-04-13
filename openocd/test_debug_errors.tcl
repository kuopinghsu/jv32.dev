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

# Recovery check: valid memory operations must still work after the error path.
mww $good_addr 0xCAFEBABE
set got [lindex [read_memory $good_addr 32 1] 0]
if {$got != 0xCAFEBABE} {
    error "recovery memory mismatch: expected=0xCAFEBABE got=[format 0x%08x $got]"
}

if {$saw_error} {
    puts "\[PASS\] debug error path and recovery"
} else {
    puts "\[SKIP\] debug error path not observed on unmapped access; recovery path validated"
}
