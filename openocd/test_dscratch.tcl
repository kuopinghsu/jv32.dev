puts "\[TEST\] dscratch0 / dscratch1 CSR read/write (native DTM path)"

# Tests the debug-mode scratch CSRs dscratch0 (0x7b2) and dscratch1 (0x7b3).
# These are owned and stored inside the DTM (not in the CPU register file).
# The DTM handles CMD_ACCESS_REG read/write for 0x7b2 and 0x7b3 natively
# via CMD_CSR_READ / CMD_CSR_WRITE without any CPU involvement.
#
# Tests:
#   1. dscratch0 (CSR 0x7b2): read/write round-trip with multiple patterns.
#   2. dscratch1 (CSR 0x7b3): read/write round-trip with multiple patterns.
#   3. Independence: writing dscratch0 does not affect dscratch1 and vice versa.
#   4. Zero write: verify 0x00000000 is accepted and read back correctly.
#   5. All-ones: verify 0xFFFFFFFF is accepted (full 32-bit writeable).
#   6. Restore original values after test.

proc as_u32 {v} {
    if {[regexp {^0x[0-9a-fA-F]+$} $v]} { scan $v %x n; return $n }
    if {[regexp {^[0-9]+$} $v]} { return [expr {$v + 0}] }
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} { return [expr "0x$hex"] }
    error "Cannot parse numeric value from: $v"
}

proc reg_val {name} {
    set s [reg $name]
    if {[regexp {0x([0-9a-fA-F]+)} $s -> hex]} { return [expr "0x$hex"] }
    error "Cannot parse register value from: $s"
}

proc check_cmderr {label} {
    set acs [as_u32 [riscv dmi_read 0x16]]
    set err [expr {($acs >> 8) & 0x7}]
    if {$err != 0} {
        riscv dmi_write 0x16 [expr {7 << 8}]
        error "$label: unexpected cmderr=$err (abstractcs=[format 0x%08x $acs])"
    }
}

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}
riscv dmi_write 0x16 [expr {7 << 8}]  ;# clear any residual cmderr

# Read original dscratch0 / dscratch1 values for restore.
# OpenOCD accesses them as "dscratch0" / "dscratch1" register names.
set orig_scratch0 [reg_val dscratch0]
set orig_scratch1 [reg_val dscratch1]
puts "original dscratch0=[format 0x%08x $orig_scratch0] dscratch1=[format 0x%08x $orig_scratch1]"
check_cmderr "read originals"

# ── 1. dscratch0 (CSR 0x7b2) round-trip ──────────────────────────────────────
puts "\[SUBTEST\] dscratch0 (CSR 0x7b2) write/read round-trip"

set patterns [list 0xDEADBEEF 0xCAFEBABE 0x00000000 0xFFFFFFFF 0x12345678 0xA5A5A5A5]
foreach val $patterns {
    reg dscratch0 $val
    check_cmderr "dscratch0 write [format 0x%08x $val]"
    set got [reg_val dscratch0]
    check_cmderr "dscratch0 read [format 0x%08x $val]"
    puts "  dscratch0: wrote=[format 0x%08x $val] read=[format 0x%08x $got]"
    if {$got != $val} {
        error "dscratch0 round-trip mismatch: wrote=[format 0x%08x $val] read=[format 0x%08x $got]"
    }
}
puts "dscratch0 round-trip: [llength $patterns] patterns OK"

# ── 2. dscratch1 (CSR 0x7b3) round-trip ──────────────────────────────────────
puts "\[SUBTEST\] dscratch1 (CSR 0x7b3) write/read round-trip"

foreach val $patterns {
    reg dscratch1 $val
    check_cmderr "dscratch1 write [format 0x%08x $val]"
    set got [reg_val dscratch1]
    check_cmderr "dscratch1 read [format 0x%08x $val]"
    puts "  dscratch1: wrote=[format 0x%08x $val] read=[format 0x%08x $got]"
    if {$got != $val} {
        error "dscratch1 round-trip mismatch: wrote=[format 0x%08x $val] read=[format 0x%08x $got]"
    }
}
puts "dscratch1 round-trip: [llength $patterns] patterns OK"

# ── 3. Independence: scratch0 write must not affect scratch1 ──────────────────
puts "\[SUBTEST\] dscratch0 / dscratch1 independence"

reg dscratch0 0x11111111
reg dscratch1 0x22222222
check_cmderr "independence init"

# Write scratch0, verify scratch1 unchanged.
reg dscratch0 0x33333333
check_cmderr "scratch0 second write"
set s1 [reg_val dscratch1]
if {$s1 != 0x22222222} {
    error "Independence: writing dscratch0 changed dscratch1 to [format 0x%08x $s1]"
}
puts "  write dscratch0 did not affect dscratch1: OK"

# Write scratch1, verify scratch0 unchanged.
reg dscratch1 0x44444444
check_cmderr "scratch1 second write"
set s0 [reg_val dscratch0]
if {$s0 != 0x33333333} {
    error "Independence: writing dscratch1 changed dscratch0 to [format 0x%08x $s0]"
}
puts "  write dscratch1 did not affect dscratch0: OK"
puts "dscratch0 / dscratch1 independence OK"

# ── 4. Verify via raw DMI (CMD_ACCESS_REG) ────────────────────────────────────
puts "\[SUBTEST\] dscratch0/1 via raw DMI abstract register command"

# Write dscratch0 to 0xABCD1234 via raw DMI COMMAND write (cmdtype=0, aarsize=2,
# transfer=1, write=1, regno=0x7b2).
set SCRATCH0_REGNO 0x07b2
set SCRATCH1_REGNO 0x07b3
set CMD_WRITE_REG [expr {(0 << 24) | (2 << 20) | (1 << 17) | (1 << 16)}]
set CMD_READ_REG  [expr {(0 << 24) | (2 << 20) | (1 << 17) | (0 << 16)}]

riscv dmi_write 0x04 0xABCD1234
riscv dmi_write 0x17 [expr {$CMD_WRITE_REG | $SCRATCH0_REGNO}]
after 5
check_cmderr "raw DMI write dscratch0"

riscv dmi_write 0x17 [expr {$CMD_READ_REG | $SCRATCH0_REGNO}]
after 5
check_cmderr "raw DMI read dscratch0"
set raw_d0 [as_u32 [riscv dmi_read 0x04]]
if {$raw_d0 != 0xABCD1234} {
    error "raw DMI dscratch0 round-trip: expected 0xABCD1234 got [format 0x%08x $raw_d0]"
}
puts "  raw DMI dscratch0 round-trip: [format 0x%08x $raw_d0] OK"

riscv dmi_write 0x04 0x5678DCBA
riscv dmi_write 0x17 [expr {$CMD_WRITE_REG | $SCRATCH1_REGNO}]
after 5
check_cmderr "raw DMI write dscratch1"

riscv dmi_write 0x17 [expr {$CMD_READ_REG | $SCRATCH1_REGNO}]
after 5
check_cmderr "raw DMI read dscratch1"
set raw_d1 [as_u32 [riscv dmi_read 0x04]]
if {$raw_d1 != 0x5678DCBA} {
    error "raw DMI dscratch1 round-trip: expected 0x5678DCBA got [format 0x%08x $raw_d1]"
}
puts "  raw DMI dscratch1 round-trip: [format 0x%08x $raw_d1] OK"
puts "raw DMI dscratch0/1 round-trip OK"

# ── Restore original values ───────────────────────────────────────────────────
reg dscratch0 $orig_scratch0
reg dscratch1 $orig_scratch1
check_cmderr "restore"
puts "dscratch0/1 restored to originals"

puts "\[PASS\] dscratch0 / dscratch1 CSR read/write"
