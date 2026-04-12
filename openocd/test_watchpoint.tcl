puts "\[TEST\] watchpoint"

# Tests hardware watchpoint halt-on-write.
# SKIPs cleanly if the target does not implement trigger hardware;
# fails hard if the trigger is set but the expected halt does not occur.

set addr 0x80000200

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}

if {[catch {mww $addr 0} init_err]} {
    error "memory init write failed: $init_err"
}

if {[catch {wp $addr 4 w} wp_err]} {
    puts "\[SKIP\] watchpoint unsupported: $wp_err"
    return
}

if {[catch {resume} resume_err]} {
    catch {rwp $addr}
    error "resume failed after watchpoint set: $resume_err"
}

if {[catch {mww $addr 0xdeadbeef} trig_err]} {
    catch {rwp $addr}
    error "watchpoint trigger write failed: $trig_err"
}

if {[catch {wait_halt 200}]} {
    catch {rwp $addr}
    error "hart did not halt on watchpoint"
}

catch {rwp $addr}
puts "\[PASS\] watchpoint"
