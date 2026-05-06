proc as_u32 {v} {
    if {[regexp {^0x[0-9a-fA-F]+$} $v]} { scan $v %x n; return $n }
    if {[regexp {^[0-9]+$} $v]} { return [expr {$v + 0}] }
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} { return [expr "0x$hex"] }
    error "Cannot parse: $v"
}
proc make_cmd {aamsize postincr write} {
    return [expr {(2 << 24) | ($aamsize << 20) | ($postincr << 19) | (1 << 17) | ($write << 16)}]
}
proc check_cmderr {label} {
    set acs [as_u32 [riscv dmi_read 0x16]]
    set err [expr {($acs >> 8) & 0x7}]
    if {$err != 0} { riscv dmi_write 0x16 [expr {7 << 8}]; error "$label: cmderr=$err" }
}
halt
if {[catch {wait_halt 1000}]} { error "halt failed" }

set MEM_BASE 0x90000100
set RBASE $MEM_BASE
riscv set_mem_access sysbus
mww $RBASE 0x11223344
mww [expr {$RBASE+4}] 0x55667788
mww [expr {$RBASE+8}] 0xAABBCCDD
mww [expr {$RBASE+12}] 0xEEFF0011

# --- 32R subtest ---
set CMD_32R [make_cmd 2 1 0]
riscv dmi_write 0x05 $RBASE
for {set i 0} {$i < 4} {incr i} {
    riscv dmi_write 0x17 $CMD_32R
    after 10
    check_cmderr "32R.$i"
    riscv dmi_read 0x04  ;# read DATA0
    riscv dmi_read 0x05  ;# read DATA1
}
puts "After 32R: DATA0=[format 0x%08x [as_u32 [riscv dmi_read 0x04]]]"

# --- 32W subtest ---
set WBASE [expr {$MEM_BASE + 0x40}]
set CMD_32W [make_cmd 2 1 1]
set write_vals [list 0xDECAFBAD 0xFEEDF00D 0xB16B00B5 0x0BADFACE]
riscv dmi_write 0x05 $WBASE
for {set i 0} {$i < 4} {incr i} {
    riscv dmi_write 0x04 [lindex $write_vals $i]
    riscv dmi_write 0x17 $CMD_32W
    after 10
    check_cmderr "32W.$i"
    riscv dmi_read 0x05
}
riscv set_mem_access sysbus
for {set i 0} {$i < 4} {incr i} {
    read_memory [expr {$WBASE + $i*4}] 32 1
}
puts "After 32W: DATA0=[format 0x%08x [as_u32 [riscv dmi_read 0x04]]]"

# --- 16R subtest ---
set HBASE [expr {$MEM_BASE + 0x80}]
riscv set_mem_access sysbus
mww $HBASE 0x12345678
mww [expr {$HBASE+4}] 0x9ABCDEF0
set CMD_16R [make_cmd 1 1 0]
riscv dmi_write 0x05 $HBASE
for {set i 0} {$i < 4} {incr i} {
    riscv dmi_write 0x17 $CMD_16R
    after 10
    check_cmderr "16R.$i"
    riscv dmi_read 0x04
    riscv dmi_read 0x05
}
puts "After 16R: DATA0=[format 0x%08x [as_u32 [riscv dmi_read 0x04]]]"

# --- 8R subtest ---
set BBASE [expr {$MEM_BASE + 0xC0}]
riscv set_mem_access sysbus
mww $BBASE 0xD4C3B2A1
mww [expr {$BBASE+4}] 0x1807F6E5
set CMD_8R [make_cmd 0 1 0]
set exp_bytes [list 0xA1 0xB2 0xC3 0xD4 0xE5 0xF6 0x07 0x18]
riscv dmi_write 0x05 $BBASE
puts "Before 8R: DATA0=[format 0x%08x [as_u32 [riscv dmi_read 0x04]]]"
for {set i 0} {$i < 8} {incr i} {
    riscv dmi_write 0x17 $CMD_8R
    after 10
    check_cmderr "8R.$i"
    set d0 [as_u32 [riscv dmi_read 0x04]]
    set d1 [as_u32 [riscv dmi_read 0x05]]
    set exp [lindex $exp_bytes $i]
    puts "  8R\[$i\]: D0=[format 0x%02x $d0] (exp=[format 0x%02x $exp]) D1=[format 0x%08x $d1]"
    if {$d0 != $exp} { error "8R\[$i\] FAIL" }
}
puts "\[PASS\]"
