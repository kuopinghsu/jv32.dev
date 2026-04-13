puts "\[TEST\] cJTAG transport"

proc reg_val {name} {
    set s [reg $name]
    if {[regexp {0x([0-9a-fA-F]+)} $s -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse register value from: $s"
}

halt
if {[catch {wait_halt 1000}]} {
    error "halt failed over cJTAG"
}

# Validate cJTAG data path: read PC and check it's in IRAM
set pc_halt [reg_val pc]
if {$pc_halt < 0x80000000 || $pc_halt > 0x8001FFFF} {
    error "PC=[format 0x%08x $pc_halt] out of expected IRAM range over cJTAG"
}

# Validate resume/re-halt cycle works over cJTAG
resume
sleep 20
halt
if {[catch {wait_halt 1000}]} {
    error "re-halt failed over cJTAG"
}
set pc_rehalt [reg_val pc]
if {$pc_rehalt < 0x80000000 || $pc_rehalt > 0x8001FFFF} {
    error "PC after re-halt=[format 0x%08x $pc_rehalt] out of IRAM range"
}

puts "cJTAG halt/resume OK, pc_halt=[format 0x%08x $pc_halt] pc_rehalt=[format 0x%08x $pc_rehalt]"
puts "\[PASS\] cJTAG transport"
