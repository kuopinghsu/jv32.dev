puts "\[TEST\] strict watchpoint"

set addr 0x800009c0

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}

if {[catch {wp $addr 4 w} wp_err]} {
    puts "\[SKIP\] strict watchpoint unsupported: $wp_err"
    return
}

# Resume and trigger watched write from debugger side.
if {[catch {resume} resume_err]} {
    catch {rwp $addr}
    error "resume failed before watchpoint trigger: $resume_err"
}

# Write to watched address; OpenOCD should report a hit and hart should halt.
if {[catch {mww $addr 0x11223344} wr_err]} {
    catch {rwp $addr}
    error "watchpoint trigger write failed: $wr_err"
}

if {[catch {wait_halt 1000}]} {
    catch {rwp $addr}
    error "hart did not halt on strict watchpoint"
}

catch {rwp $addr}
puts "watchpoint hit on write to [format 0x%08x $addr]"
puts "\[PASS\] strict watchpoint"
