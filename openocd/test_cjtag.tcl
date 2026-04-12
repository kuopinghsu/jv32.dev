puts "\[TEST\] cJTAG transport"

halt
if {[catch {wait_halt 1000}]} {
    error "halt failed over cJTAG"
}
puts "\[PASS\] cJTAG transport"
