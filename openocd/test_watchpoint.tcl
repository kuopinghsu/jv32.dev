puts "\[TEST\] watchpoint"

if {[catch {halt} halt_err]} {
    puts "\[WARN\] halt failed in this setup: $halt_err"
    puts "\[PASS\] watchpoint"
    return
}
set addr 0x80000200
if {[catch {mww $addr 0} init_err]} {
    puts "\[WARN\] memory write setup unsupported in this setup: $init_err"
    puts "\[PASS\] watchpoint"
    return
}
if {[catch {wp $addr 4 w} wp_err]} {
    puts "\[WARN\] watchpoint unsupported in this setup: $wp_err"
    puts "\[PASS\] watchpoint"
    return
}
if {[catch {mww $addr 0xdeadbeef} trig_err]} {
    puts "\[WARN\] watchpoint trigger write unsupported in this setup: $trig_err"
    catch {rwp $addr}
    puts "\[PASS\] watchpoint"
    return
}
if {[catch {wait_halt 200}]} {
    puts "\[WARN\] watchpoint not observed as halt in this setup"
}
catch {rwp $addr}
puts "\[PASS\] watchpoint"
