puts "\[TEST\] halt/resume"

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}
set pc_before [reg pc]
resume
sleep 50
halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt after resume"
}
set pc_after [reg pc]
if {$pc_after == $pc_before} {
    puts "\[WARN\] PC unchanged across resume window"
}
puts "\[PASS\] halt/resume"
