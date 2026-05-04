puts "\[TEST\] cJTAG transport (IEEE 1149.7 OScan1)"

# ── Helpers ───────────────────────────────────────────────────────────────────
proc as_u32 {v} {
    if {[regexp {^0x[0-9a-fA-F]+$} $v]} {
        scan $v %x n
        return $n
    }
    if {[regexp {^[0-9]+$} $v]} {
        return [expr {$v + 0}]
    }
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} {
        return [expr "0x$hex"]
    }
    # drscan returns bare hex digits (no 0x prefix), e.g. "1dead3ff"
    if {[regexp {^[0-9a-fA-F]+$} $v]} {
        scan $v %x n
        return $n
    }
    error "Cannot parse numeric value from: $v"
}

proc reg_val {name} {
    set s [reg $name]
    if {[regexp {0x([0-9a-fA-F]+)} $s -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse register value from: $s"
}

# ── 1. Verify cJTAG TAP is visible (IDCODE scan via OScan1 path) ──────────────
# If the cJTAG bridge activation or OScan1 encoding were broken, the IDCODE
# scan would return 0x00000000 or 0xFFFFFFFF and OpenOCD would have rejected
# the TAP during 'init'.  Reaching here confirms the OScan1 data path works.
#
# Load IDCODE instruction explicitly before scanning: after a successful target
# examine OpenOCD leaves IR=DMI (not IDCODE), so we must re-select IR=0x01.
irscan jv32.cpu 0x01
set idcode [as_u32 [drscan jv32.cpu 32 0x00000000]]
if {$idcode != 0x1DEAD3FF} {
    error "IDCODE mismatch over cJTAG: got=[format 0x%08x $idcode] expected=0x1DEAD3FF"
}
puts "cJTAG IDCODE OK: [format 0x%08x $idcode]"

# ── 2. Verify DM is reachable through the OScan1 bridge ──────────────────────
# Read dmstatus: version must be 2 (Debug Spec 0.13), authenticated must be 1.
set dmstatus      [as_u32 [riscv dmi_read 0x11]]
set version       [expr {$dmstatus & 0xf}]
set authenticated [expr {($dmstatus >> 7) & 1}]
if {$version != 2} {
    error "dmstatus.version=$version over cJTAG; expected 2"
}
if {!$authenticated} {
    error "dmstatus.authenticated=0 over cJTAG; DM locked"
}
puts "cJTAG DM reachable: dmstatus=[format 0x%08x $dmstatus]"

# ── 3. Halt/resume/re-halt cycle ─────────────────────────────────────────────
halt
if {[catch {wait_halt 1000}]} {
    error "halt failed over cJTAG"
}

# Validate cJTAG data path: read PC and check it is in IRAM
set pc_halt [reg_val pc]
if {$pc_halt < 0x80000000 || $pc_halt > 0x8001FFFF} {
    error "PC=[format 0x%08x $pc_halt] out of expected IRAM range over cJTAG"
}
puts "cJTAG halted: pc=[format 0x%08x $pc_halt]"

resume
sleep 20

# Confirm the hart is actually running via dmstatus
set dmstatus2    [as_u32 [riscv dmi_read 0x11]]
set any_running  [expr {($dmstatus2 >> 10) & 1}]
set all_running  [expr {($dmstatus2 >> 11) & 1}]
if {!$any_running || !$all_running} {
    error "hart did not resume over cJTAG: dmstatus=[format 0x%08x $dmstatus2]"
}

halt
if {[catch {wait_halt 1000}]} {
    error "re-halt failed over cJTAG"
}
set pc_rehalt [reg_val pc]
if {$pc_rehalt < 0x80000000 || $pc_rehalt > 0x8001FFFF} {
    error "PC after re-halt=[format 0x%08x $pc_rehalt] out of IRAM range over cJTAG"
}
puts "cJTAG re-halted: pc=[format 0x%08x $pc_rehalt]"

# ── 4. Register read-back integrity over OScan1 ───────────────────────────────
# Read x0 (always 0) and x2 (sp — nonzero in a running program).
# Note: OpenOCD RISC-V target uses ABI register names (zero, sp, ...).
set x0 [reg_val zero]
if {$x0 != 0} {
    error "x0=[format 0x%08x $x0] over cJTAG; expected 0"
}
set sp [reg_val sp]
if {$sp == 0} {
    error "sp=0 over cJTAG; expected non-zero (stack must be initialised)"
}
puts "cJTAG regs OK: x0=[format 0x%08x $x0] sp=[format 0x%08x $sp]"

# ── 5. Memory read integrity: check IRAM instruction at reset vector ─────────
# The IRAM reset vector (0x8000_0000) must contain a valid RISC-V instruction
# (not 0x00000000 or 0xFFFFFFFF), confirming the memory path through the
# OScan1 bridge is bit-exact.
set instr [as_u32 [read_memory 0x80000000 32 1]]
if {$instr == 0x00000000 || $instr == 0xFFFFFFFF} {
    error "IRAM[0]=[format 0x%08x $instr] over cJTAG looks invalid (all-zeros or all-ones)"
}
puts "cJTAG memory OK: IRAM\[0x80000000\]=[format 0x%08x $instr]"

puts "\[PASS\] cJTAG transport"
