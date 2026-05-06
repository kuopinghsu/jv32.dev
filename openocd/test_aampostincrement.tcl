puts "\[TEST\] CMD_ACCESS_MEM aampostincrement — address auto-advance after each access"

# Tests the aampostincrement feature of CMD_ACCESS_MEM (abstract command type 2).
# When bit 19 of COMMAND is set, the address in DATA1 is automatically incremented
# by the access size (1/2/4 bytes for aamsize=0/1/2) after each completed operation.
#
# CMD_ACCESS_MEM COMMAND encoding (Debug Spec 0.13 §3.7.1.2):
#   [31:24] = 0x02   cmdtype = memory access
#   [22:20] = aamsize: 0=byte, 1=halfword, 2=word
#   [19]    = aampostincrement
#   [17]    = transfer: 1=perform the memory access
#   [16]    = write: 0=read memory→DATA0, 1=write DATA0→memory
#
# The incremented address is written back to DATA1 via a CDC-safe path in the DTM
# (data1_result / data1_result_valid signals, two-stage TCK sync chain).
#
# Tests:
#   1. 32-bit read  (aamsize=2): 4 word reads;       DATA1 advances by 4.
#   2. 32-bit write (aamsize=2): 4 word writes;      DATA1 advances by 4; SBA verify.
#   3. 16-bit write (aamsize=1): 4 halfword writes;  DATA1 advances by 2; SBA verify.
#   4. 8-bit  write (aamsize=0): 8 byte writes;      DATA1 advances by 1; SBA verify.
#   5. 16-bit read  (aamsize=1): 4 halfword reads;   DATA1 advances by 2.
#   6. 8-bit  read  (aamsize=0): 8 byte reads;       DATA1 advances by 1.
#   7. No postincrement (aamsize=2): DATA1 must NOT change after reads.

proc as_u32 {v} {
    if {[regexp {^0x[0-9a-fA-F]+$} $v]} { scan $v %x n; return $n }
    if {[regexp {^[0-9]+$} $v]} { return [expr {$v + 0}] }
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} { return [expr "0x$hex"] }
    error "Cannot parse numeric value from: $v"
}

proc clear_cmderr {} {
    riscv dmi_write 0x16 [expr {7 << 8}]
}

proc check_cmderr {label} {
    set acs [as_u32 [riscv dmi_read 0x16]]
    set err [expr {($acs >> 8) & 0x7}]
    if {$err != 0} {
        clear_cmderr
        error "$label: unexpected cmderr=$err (abstractcs=[format 0x%08x $acs])"
    }
}

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}
clear_cmderr
# Disable background polling for the duration of this test.
# OpenOCD's poll() issues CMD_ACCESS_REG(DPC) which overwrites DATA0;
# without this guard the DATA0 result from CMD_ACCESS_MEM is occasionally
# replaced by DPC=0x80000000 before the test reads it.
poll off

# Scratch area in DRAM (data RAM, offset 0x100 to avoid boot data).
set MEM_BASE 0x90000100

# Prime test data in DRAM via SBA write (mode=2, sbaccess=2).
# This avoids D-cache coherency concerns (SBA bypasses the CPU cache).
riscv set_mem_access sysbus  ;# let OpenOCD use sysbus for mww
mww $MEM_BASE 0x11223344
mww [expr {$MEM_BASE + 4}]  0x55667788
mww [expr {$MEM_BASE + 8}]  0xAABBCCDD
mww [expr {$MEM_BASE + 12}] 0xEEFF0011
mww [expr {$MEM_BASE + 16}] 0xDEADBEEF
mww [expr {$MEM_BASE + 20}] 0xCAFEBABE
mww [expr {$MEM_BASE + 24}] 0x01020304
mww [expr {$MEM_BASE + 28}] 0x05060708
puts "test data written via sysbus"

# CMD constants (values in TCL expressions)
# (0x02 << 24) | (aamsize << 20) | (aampostincrement << 19) | (transfer << 17) | (write << 16)
proc make_cmd {aamsize postincr write} {
    return [expr {(2 << 24) | ($aamsize << 20) | ($postincr << 19) | (1 << 17) | ($write << 16)}]
}

# ── 1. 32-bit read with aampostincrement ──────────────────────────────────────
puts "\[SUBTEST\] 32-bit read aampostincrement"

set CMD_32R [make_cmd 2 1 0]
set expected_words [list 0x11223344 0x55667788 0xAABBCCDD 0xEEFF0011]

riscv dmi_write 0x05 $MEM_BASE  ;# DATA1 = start address
for {set i 0} {$i < 4} {incr i} {
    riscv dmi_write 0x17 $CMD_32R
    after 10
    check_cmderr "32R iter $i"

    set d0  [as_u32 [riscv dmi_read 0x04]]  ;# DATA0 = read value
    set d1  [as_u32 [riscv dmi_read 0x05]]  ;# DATA1 = next address (postincremented)
    set exp_d0 [lindex $expected_words $i]
    set exp_d1 [expr {$MEM_BASE + ($i + 1) * 4}]

    puts "  32R\[$i\]: DATA0=[format 0x%08x $d0] (exp=[format 0x%08x $exp_d0]) DATA1=[format 0x%08x $d1] (exp=[format 0x%08x $exp_d1])"

    if {$d0 != $exp_d0} {
        error "32R\[$i\]: DATA0 mismatch: expected=[format 0x%08x $exp_d0] got=[format 0x%08x $d0]"
    }
    if {$d1 != $exp_d1} {
        error "32R\[$i\]: DATA1 (postincrement) mismatch: expected=[format 0x%08x $exp_d1] got=[format 0x%08x $d1]"
    }
}
puts "32-bit read aampostincrement: 4 words with DATA1+4 advance OK"

# ── 2. 32-bit write with aampostincrement ─────────────────────────────────────
puts "\[SUBTEST\] 32-bit write aampostincrement"

set CMD_32W [make_cmd 2 1 1]
set WBASE [expr {$MEM_BASE + 0x40}]
set write_vals [list 0xDECAFBAD 0xFEEDF00D 0xB16B00B5 0x0BADFACE]

riscv dmi_write 0x05 $WBASE  ;# DATA1 = start address
for {set i 0} {$i < 4} {incr i} {
    riscv dmi_write 0x04 [lindex $write_vals $i]  ;# DATA0 = write value
    riscv dmi_write 0x17 $CMD_32W
    after 10
    check_cmderr "32W iter $i"

    set d1 [as_u32 [riscv dmi_read 0x05]]  ;# DATA1 = next address
    set exp_d1 [expr {$WBASE + ($i + 1) * 4}]

    puts "  32W\[$i\]: wrote=[format 0x%08x [lindex $write_vals $i]] DATA1=[format 0x%08x $d1] (exp=[format 0x%08x $exp_d1])"

    if {$d1 != $exp_d1} {
        error "32W\[$i\]: DATA1 (postincrement) mismatch: expected=[format 0x%08x $exp_d1] got=[format 0x%08x $d1]"
    }
}

# Verify written values via SBA independent read-back.
riscv set_mem_access sysbus
for {set i 0} {$i < 4} {incr i} {
    set addr [expr {$WBASE + $i * 4}]
    set got [lindex [read_memory $addr 32 1] 0]
    set exp [lindex $write_vals $i]
    puts "  32W verify\[$i\] @[format 0x%08x $addr]: [format 0x%08x $got] (exp=[format 0x%08x $exp])"
    if {$got != $exp} {
        error "32W verify\[$i\]: expected=[format 0x%08x $exp] got=[format 0x%08x $got]"
    }
}
puts "32-bit write aampostincrement: 4 words written + verified OK"

# ── 3. 16-bit write with aampostincrement ─────────────────────────────────────
puts "\[SUBTEST\] 16-bit write aampostincrement"

set CMD_16W [make_cmd 1 1 1]  ;# aamsize=1 (16-bit), postincr=1, write=1
set HWBASE [expr {$MEM_BASE + 0x80}]
set hw_write_vals [list 0xAA11 0xBB22 0xCC33 0xDD44]

riscv dmi_write 0x05 $HWBASE  ;# DATA1 = start address
for {set i 0} {$i < 4} {incr i} {
    riscv dmi_write 0x04 [lindex $hw_write_vals $i]  ;# DATA0 = write value
    riscv dmi_write 0x17 $CMD_16W
    after 10
    check_cmderr "16W iter $i"

    set d1 [as_u32 [riscv dmi_read 0x05]]
    set exp_d1 [expr {$HWBASE + ($i + 1) * 2}]

    puts "  16W\[$i\]: wrote=[format 0x%04x [lindex $hw_write_vals $i]] DATA1=[format 0x%08x $d1] (exp=[format 0x%08x $exp_d1])"

    if {$d1 != $exp_d1} {
        error "16W\[$i\]: DATA1 (postincrement by 2) mismatch: expected=[format 0x%08x $exp_d1] got=[format 0x%08x $d1]"
    }
}

# Verify via SBA read-back: two halfwords packed per word
riscv set_mem_access sysbus
set word0 [lindex [read_memory $HWBASE           32 1] 0]
set word1 [lindex [read_memory [expr {$HWBASE+4}] 32 1] 0]
# little-endian: [hw0] in lower half, [hw1] in upper half of first word
set exp_w0 [expr {([lindex $hw_write_vals 1] << 16) | [lindex $hw_write_vals 0]}]
set exp_w1 [expr {([lindex $hw_write_vals 3] << 16) | [lindex $hw_write_vals 2]}]
puts "  16W verify: word0=[format 0x%08x $word0] (exp=[format 0x%08x $exp_w0])"
puts "  16W verify: word1=[format 0x%08x $word1] (exp=[format 0x%08x $exp_w1])"
if {$word0 != $exp_w0} { error "16W verify word0: expected=[format 0x%08x $exp_w0] got=[format 0x%08x $word0]" }
if {$word1 != $exp_w1} { error "16W verify word1: expected=[format 0x%08x $exp_w1] got=[format 0x%08x $word1]" }
puts "16-bit write aampostincrement: 4 halfwords written + verified OK"

# ── 4. 8-bit write with aampostincrement ──────────────────────────────────────
puts "\[SUBTEST\] 8-bit write aampostincrement"

set CMD_8W [make_cmd 0 1 1]  ;# aamsize=0 (8-bit), postincr=1, write=1
set BYBASE [expr {$MEM_BASE + 0xA0}]
set byte_write_vals [list 0x11 0x22 0x33 0x44 0x55 0x66 0x77 0x88]

riscv dmi_write 0x05 $BYBASE  ;# DATA1 = start address
for {set i 0} {$i < 8} {incr i} {
    riscv dmi_write 0x04 [lindex $byte_write_vals $i]  ;# DATA0 = write value
    riscv dmi_write 0x17 $CMD_8W
    after 10
    check_cmderr "8W iter $i"

    set d1 [as_u32 [riscv dmi_read 0x05]]
    set exp_d1 [expr {$BYBASE + $i + 1}]

    puts "  8W\[$i\]: wrote=[format 0x%02x [lindex $byte_write_vals $i]] DATA1=[format 0x%08x $d1] (exp=[format 0x%08x $exp_d1])"

    if {$d1 != $exp_d1} {
        error "8W\[$i\]: DATA1 (postincrement by 1) mismatch: expected=[format 0x%08x $exp_d1] got=[format 0x%08x $d1]"
    }
}

# Verify via SBA read-back: 8 bytes packed as two 32-bit words
riscv set_mem_access sysbus
set word0 [lindex [read_memory $BYBASE           32 1] 0]
set word1 [lindex [read_memory [expr {$BYBASE+4}] 32 1] 0]
# little-endian: byte0 in bits[7:0], byte1 in bits[15:8], etc.
set exp_w0 [expr {([lindex $byte_write_vals 3] << 24) | ([lindex $byte_write_vals 2] << 16) | ([lindex $byte_write_vals 1] << 8) | [lindex $byte_write_vals 0]}]
set exp_w1 [expr {([lindex $byte_write_vals 7] << 24) | ([lindex $byte_write_vals 6] << 16) | ([lindex $byte_write_vals 5] << 8) | [lindex $byte_write_vals 4]}]
puts "  8W verify: word0=[format 0x%08x $word0] (exp=[format 0x%08x $exp_w0])"
puts "  8W verify: word1=[format 0x%08x $word1] (exp=[format 0x%08x $exp_w1])"
if {$word0 != $exp_w0} { error "8W verify word0: expected=[format 0x%08x $exp_w0] got=[format 0x%08x $word0]" }
if {$word1 != $exp_w1} { error "8W verify word1: expected=[format 0x%08x $exp_w1] got=[format 0x%08x $word1]" }
puts "8-bit write aampostincrement: 8 bytes written + verified OK"

# ── 6. 16-bit read with aampostincrement ──────────────────────────────────────
puts "\[SUBTEST\] 16-bit read aampostincrement"

# Write known halfword pattern at HBASE via SBA byte writes.
# Word at HBASE+0: 0x12345678  →  halfwords: lo=0x5678, hi=0x1234 (little-endian)
# Word at HBASE+4: 0x9ABCDEF0  →  halfwords: lo=0xDEF0, hi=0x9ABC
set HBASE [expr {$MEM_BASE + 0x80}]
riscv set_mem_access sysbus
mww $HBASE       0x12345678
mww [expr {$HBASE + 4}] 0x9ABCDEF0

set CMD_16R [make_cmd 1 1 0]  ;# aamsize=1 (16-bit)
# Expected: reads 0x5678, 0x1234, 0xDEF0, 0x9ABC (little-endian halfwords)
set exp_hw [list 0x00005678 0x00001234 0x0000DEF0 0x00009ABC]

riscv dmi_write 0x05 $HBASE  ;# DATA1 = start
for {set i 0} {$i < 4} {incr i} {
    riscv dmi_write 0x17 $CMD_16R
    after 10
    check_cmderr "16R iter $i"

    set d0 [as_u32 [riscv dmi_read 0x04]]
    set d1 [as_u32 [riscv dmi_read 0x05]]
    set exp_d0 [lindex $exp_hw $i]
    set exp_d1 [expr {$HBASE + ($i + 1) * 2}]

    puts "  16R\[$i\]: DATA0=[format 0x%08x $d0] (exp=[format 0x%08x $exp_d0]) DATA1=[format 0x%08x $d1] (exp=[format 0x%08x $exp_d1])"

    if {$d0 != $exp_d0} {
        error "16R\[$i\]: DATA0 mismatch: expected=[format 0x%08x $exp_d0] got=[format 0x%08x $d0]"
    }
    if {$d1 != $exp_d1} {
        error "16R\[$i\]: DATA1 (postincrement by 2) mismatch: expected=[format 0x%08x $exp_d1] got=[format 0x%08x $d1]"
    }
}
puts "16-bit read aampostincrement: 4 halfwords with DATA1+2 advance OK"

# ── 7. 8-bit read with aampostincrement ───────────────────────────────────────
puts "\[SUBTEST\] 8-bit read aampostincrement"

# Write known byte pattern at BBASE.
# Bytes (little-endian in word): 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18
set BBASE [expr {$MEM_BASE + 0xC0}]
riscv set_mem_access sysbus
mww $BBASE           0xD4C3B2A1  ;# bytes 0-3: 0xA1,0xB2,0xC3,0xD4
mww [expr {$BBASE+4}] 0x1807F6E5  ;# bytes 4-7: 0xE5,0xF6,0x07,0x18

set CMD_8R [make_cmd 0 1 0]  ;# aamsize=0 (8-bit)
set exp_bytes [list 0xA1 0xB2 0xC3 0xD4 0xE5 0xF6 0x07 0x18]

riscv dmi_write 0x05 $BBASE  ;# DATA1 = start
for {set i 0} {$i < 8} {incr i} {
    riscv dmi_write 0x17 $CMD_8R
    after 10
    check_cmderr "8R iter $i"

    set d0 [as_u32 [riscv dmi_read 0x04]]
    set d1 [as_u32 [riscv dmi_read 0x05]]
    set exp_d0 [lindex $exp_bytes $i]
    set exp_d1 [expr {$BBASE + $i + 1}]

    puts "  8R\[$i\]: DATA0=[format 0x%02x $d0] (exp=[format 0x%02x $exp_d0]) DATA1=[format 0x%08x $d1] (exp=[format 0x%08x $exp_d1])"

    if {$d0 != $exp_d0} {
        error "8R\[$i\]: DATA0 mismatch: expected=[format 0x%02x $exp_d0] got=[format 0x%02x $d0]"
    }
    if {$d1 != $exp_d1} {
        error "8R\[$i\]: DATA1 (postincrement by 1) mismatch: expected=[format 0x%08x $exp_d1] got=[format 0x%08x $d1]"
    }
}
puts "8-bit read aampostincrement: 8 bytes with DATA1+1 advance OK"

# ── 8. No postincrement (control): DATA1 must NOT change ──────────────────────
puts "\[SUBTEST\] No aampostincrement: DATA1 must not change"

# CMD_ACCESS_MEM without postincrement
set CMD_32R_NOPI [make_cmd 2 0 0]

riscv dmi_write 0x05 $MEM_BASE  ;# DATA1 = fixed address
for {set i 0} {$i < 4} {incr i} {
    riscv dmi_write 0x17 $CMD_32R_NOPI
    after 10
    check_cmderr "no-postincr iter $i"

    set d1 [as_u32 [riscv dmi_read 0x05]]
    if {$d1 != $MEM_BASE} {
        error "No-postincr\[$i\]: DATA1 changed unexpectedly to [format 0x%08x $d1] (expected [format 0x%08x $MEM_BASE])"
    }
}
puts "No aampostincrement: DATA1 remained at [format 0x%08x $MEM_BASE] OK"

poll on
puts "\[PASS\] CMD_ACCESS_MEM aampostincrement"
