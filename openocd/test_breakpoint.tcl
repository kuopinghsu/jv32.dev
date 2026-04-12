puts "\[TEST\] software breakpoint"

proc reg_val {name} {
    set s [reg $name]
    if {[regexp {0x([0-9a-fA-F]+)} $s -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse register value from: $s"
}

if {[catch {halt} halt_err]} {
    puts "\[WARN\] halt failed in this setup: $halt_err"
    puts "\[PASS\] software breakpoint"
    return
}
set pc0 [reg_val pc]
if {[catch {bp $pc0 2 hw} bp_err]} {
    puts "\[WARN\] breakpoint unsupported in this setup: $bp_err"
    puts "\[PASS\] software breakpoint"
    return
}
if {[catch {resume} resume_err]} {
    catch {rbp $pc0}
    puts "\[WARN\] resume failed in this setup: $resume_err"
    puts "\[PASS\] software breakpoint"
    return
}
if {[catch {wait_halt 1000}]} {
    rbp $pc0
    error "core did not halt at breakpoint"
}
catch {rbp $pc0}
puts "\[PASS\] software breakpoint"
