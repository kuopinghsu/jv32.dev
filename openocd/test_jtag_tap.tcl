puts "\[TEST\] JTAG TAP IR instructions — IDCODE and BYPASS"

# Tests JTAG TAP instruction register instructions in JTAG mode (not cJTAG).
#   IR=0x01  IDCODE   — 32-bit read-only JTAG device identification register.
#   IR=0x1F  BYPASS   — 1-bit pass-through shift register.
#
# JTAG IR width for jv32: 5 bits (values 0x00-0x1F).
# Expected IDCODE: 0x1DEAD3FF (see README.md §JTAG section).
#
# BYPASS behaviour (IEEE 1149.1 §6.1):
#   CAPTURE_DR loads 0 into the 1-bit register.
#   SHIFT_DR passes data through the register with a 1-clock delay.
#   For an N-bit DR scan with input value V, the output value R is:
#       R = (V << 1) & ((1 << N) - 1)
#   i.e. the input is delayed by 1 bit, and the LSB of output is always 0.
#
# Note: drscan returns bare hex digits without a "0x" prefix.
# Note: This test is JTAG-mode only; a compatible cJTAG IDCODE test exists
#       in test_cjtag.tcl.
#
# After testing BYPASS, the test restores DMI IR (0x11) so subsequent
# OpenOCD DMI operations function correctly.

proc as_u32 {v} {
    if {[regexp {^0x[0-9a-fA-F]+$} $v]} { scan $v %x n; return $n }
    if {[regexp {^[0-9]+$} $v]} { return [expr {$v + 0}] }
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} { return [expr "0x$hex"] }
    # drscan returns bare hex (no 0x prefix)
    if {[regexp {^[0-9a-fA-F]+$} $v]} { scan $v %x n; return $n }
    error "Cannot parse numeric value from: $v"
}

# ── 1. IDCODE (IR=0x01) ───────────────────────────────────────────────────────
puts "\[SUBTEST\] IDCODE (IR=0x01)"

# OpenOCD leaves IR=DMI (0x11) after target examine.  Load IDCODE explicitly.
irscan jv32.cpu 0x01
set idcode [as_u32 [drscan jv32.cpu 32 0x00000000]]

puts "  IDCODE scan result: [format 0x%08x $idcode]"

if {$idcode != 0x1DEAD3FF} {
    error "IDCODE mismatch: expected=0x1DEAD3FF got=[format 0x%08x $idcode]"
}
puts "IDCODE=0x1DEAD3FF OK"

# Verify IDCODE format (IEEE 1149.1 §11.4.1):
#   bit  0        = 1  (mandatory, marks start of IDCODE)
#   bits 11:1     = manufacturer continuation bits
#   bits 27:12    = part number
#   bits 31:28    = version
set bit0     [expr {$idcode & 1}]
if {$bit0 != 1} {
    error "IDCODE bit 0 should be 1 per IEEE 1149.1, got [format 0x%08x $idcode]"
}
puts "IDCODE bit 0 = 1 (IEEE 1149.1 conformant) OK"

# Read IDCODE a second time to confirm it is stable.
irscan jv32.cpu 0x01
set idcode2 [as_u32 [drscan jv32.cpu 32 0x00000000]]
if {$idcode2 != $idcode} {
    error "IDCODE not stable: first=[format 0x%08x $idcode] second=[format 0x%08x $idcode2]"
}
puts "IDCODE stable on second scan OK"

# ── 2. BYPASS (IR=0x1F) ───────────────────────────────────────────────────────
puts "\[SUBTEST\] BYPASS (IR=0x1F)"

# Select the BYPASS instruction.
irscan jv32.cpu 0x1F

# BYPASS is a 1-bit register.  CAPTURE_DR initialises it to 0.
# Each DR scan captures 0 first (bit 0 of return = 0), then shifts input
# through the 1-bit register with a 1-clock delay.
# For an N-bit scan: return = (input << 1) & mask(N)
#
# Verification strategy: 4-bit scans with several input patterns.
set N 4
set mask [expr {(1 << $N) - 1}]

set test_inputs [list 0x0 0x5 0xA 0xF 0x3 0xC 0x7 0x8 0x1 0x6]
foreach inp $test_inputs {
    irscan jv32.cpu 0x1F
    set raw [drscan jv32.cpu $N [format 0x%X $inp]]
    set got [as_u32 $raw]
    set exp [expr {($inp << 1) & $mask}]
    puts "  BYPASS $N-bit: input=[format 0x%X $inp] got=[format 0x%X $got] expected=[format 0x%X $exp]"
    if {$got != $exp} {
        # Restore DMI before erroring.
        irscan jv32.cpu 0x11
        error "BYPASS mismatch for input=[format 0x%X $inp]: expected=[format 0x%X $exp] got=[format 0x%X $got]"
    }
}
puts "BYPASS 4-bit scan: [llength $test_inputs] patterns OK"

# Verify the constant property: bit 0 of return is always 0 (CAPTURE_DR loads 0).
# Use 1-bit scans to confirm the captured value is 0 regardless of input.
foreach inp {0 1} {
    irscan jv32.cpu 0x1F
    set raw [drscan jv32.cpu 1 $inp]
    set got [as_u32 $raw]
    puts "  BYPASS 1-bit: input=$inp got=$got (expected 0 — capture value)"
    if {$got != 0} {
        irscan jv32.cpu 0x11
        error "BYPASS 1-bit: CAPTURE_DR should load 0; got $got for input=$inp"
    }
}
puts "BYPASS 1-bit capture = 0 OK"

# ── 3. Transition IDCODE → BYPASS → IDCODE: verify IR switching works ─────────
puts "\[SUBTEST\] IDCODE → BYPASS → IDCODE transition"

irscan jv32.cpu 0x01
set id_before [as_u32 [drscan jv32.cpu 32 0x00000000]]

# Switch to BYPASS and back.
irscan jv32.cpu 0x1F
irscan jv32.cpu 0x01
set id_after [as_u32 [drscan jv32.cpu 32 0x00000000]]

if {$id_before != 0x1DEAD3FF || $id_after != 0x1DEAD3FF} {
    irscan jv32.cpu 0x11
    error "IDCODE mismatch after IR transition: before=[format 0x%08x $id_before] after=[format 0x%08x $id_after]"
}
puts "IDCODE stable after BYPASS→IDCODE transition OK"

# ── 4. Restore DMI instruction (IR=0x11) ──────────────────────────────────────
# CRITICAL: Must restore IR to DMI (0x11) before any OpenOCD DMI commands.
irscan jv32.cpu 0x11
puts "restored IR=0x11 (DMI)"

# Verify DM is reachable after IR restore.
set dmstatus [as_u32 [riscv dmi_read 0x11]]
set version  [expr {$dmstatus & 0xf}]
set authed   [expr {($dmstatus >> 7) & 1}]
if {$version != 2 || !$authed} {
    error "DM not reachable after IR restore: dmstatus=[format 0x%08x $dmstatus]"
}
puts "DM reachable after IR=0x11 restore: OK"

puts "\[PASS\] JTAG TAP IR instructions"
