proc as_u32 {v} {
    if {[regexp {^0x[0-9a-fA-F]+$} $v]} { scan $v %x n; return $n }
    if {[regexp {^[0-9]+$} $v]} { return [expr {$v + 0}] }
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} { return [expr "0x$hex"] }
    error "Cannot parse: $v"
}
proc check_cmderr {label} {
    set acs [as_u32 [riscv dmi_read 0x16]]
    set err [expr {($acs >> 8) & 0x7}]
    if {$err != 0} {
        riscv dmi_write 0x16 [expr {7 << 8}]
        error "$label: unexpected cmderr=$err"
    }
}
halt
if {[catch {wait_halt 1000}]} { error "hart did not halt" }

set MEM_BASE 0x90000100
set BBASE [expr {$MEM_BASE + 0xC0}]
riscv set_mem_access sysbus
mww $BBASE           0xD4C3B2A1
mww [expr {$BBASE+4}] 0x1807F6E5

proc make_cmd {aamsize postincr write} {
    return [expr {(2 << 24) | ($aamsize << 20) | ($postincr << 19) | (1 << 17) | ($write << 16)}]
}

set CMD_8R [make_cmd 0 1 0]
set exp_bytes [list 0xA1 0xB2 0xC3 0xD4 0xE5 0xF6 0x07 0x18]
riscv dmi_write 0x05 $BBASE

# Read DATA0 before any CMD to see initial state
set d0_init [as_u32 [riscv dmi_read 0x04]]
puts "  INIT: DATA0=[format 0x%08x $d0_init]"

for {set i 0} {$i < 8} {incr i} {
    riscv dmi_write 0x17 $CMD_8R
    after 10
    check_cmderr "8R iter $i"

    # Read DATA0 twice to check consistency
    set d0a [as_u32 [riscv dmi_read 0x04]]
    set d0b [as_u32 [riscv dmi_read 0x04]]
    set d1  [as_u32 [riscv dmi_read 0x05]]
    set exp_d0 [lindex $exp_bytes $i]
    set exp_d1 [expr {$BBASE + $i + 1}]
    puts "  8R\[$i\]: D0a=[format 0x%02x $d0a] D0b=[format 0x%02x $d0b] (exp=[format 0x%02x $exp_d0]) D1=[format 0x%08x $d1] (exp=[format 0x%08x $exp_d1])"
    if {$d0a != $exp_d0} { error "8R\[$i\]: D0a mismatch" }
}
puts "\[PASS\] diag2"
