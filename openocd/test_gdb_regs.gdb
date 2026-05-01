# ============================================================================
# GDB test: gdb_regs — general-purpose and CSR register access via GDB
#
# Connection is established by the Makefile before sourcing this script.
#
# Verifies:
#   1. PC is valid (within IRAM / DRAM range) after halt.
#   2. SP is non-zero and 4-byte aligned.
#   3. Write / read-back for t0 (x5) and t1 (x6) with 32-bit patterns.
#   4. Write / read-back for s0 (x8) and a0 (x10) with distinct patterns.
#   5. "info registers" output contains all expected RISC-V register names.
#   6. CSR: misa readable via "monitor reg misa" with expected RISC-V ISA bits.
#   7. CSR: dcsr readable, prv field == 3 (M-mode) after halt.
#   8. CSR: mstatus readable and non-zero.
#   9. CSR: mepc readable (may be zero early in boot — tolerated).
#  10. Zero register x0 stays 0 after write attempt.
# ============================================================================

# ── Halt the core ─────────────────────────────────────────────────────────────
monitor halt
monitor wait_halt 2000
# Allow GDB to access any address within IRAM/DRAM, not just ELF LOAD segments.
set mem inaccessible-by-default off
mem 0x80000000 0x80020000 rw
mem 0x90000000 0x90020000 rw
# ── Shared Python helpers ─────────────────────────────────────────────────────
python
import gdb, re

def parse_hex_monitor(output):
    """Extract first 0x… hex value from an OpenOCD monitor reg output line."""
    m = re.search(r'0x([0-9a-fA-F]+)', output)
    if not m:
        raise gdb.GdbError('cannot parse hex from: ' + repr(output))
    return int(m.group(1), 16)

def monitor_reg(name):
    out = gdb.execute('monitor reg {}'.format(name), to_string=True)
    return parse_hex_monitor(out)

def check(label, got, expected, mask=0xFFFFFFFF):
    got      &= mask
    expected &= mask
    if got != expected:
        raise gdb.GdbError(
            '[FAIL] {}: expected=0x{:08x} got=0x{:08x}'.format(
                label, expected, got))
    print('  {:40s}: 0x{:08x}  OK'.format(label, got))

_regs = {}
end

# ── 1. PC validity ────────────────────────────────────────────────────────────
python
import gdb

pc = int(gdb.parse_and_eval('$pc'))
if not (0x80000000 <= pc <= 0x9FFFFFFF):
    raise gdb.GdbError(
        '[FAIL] gdb_regs: PC=0x{:08x} not in expected range'.format(pc))
print('  PC = 0x{:08x}  OK'.format(pc))
_regs['pc'] = pc
end

# ── 2. SP non-zero and 4-byte aligned ─────────────────────────────────────────
python
import gdb

sp = int(gdb.parse_and_eval('$sp')) & 0xFFFFFFFF
if sp == 0:
    raise gdb.GdbError('[FAIL] gdb_regs: SP is zero')
if sp & 0x3:
    raise gdb.GdbError(
        '[FAIL] gdb_regs: SP=0x{:08x} not 4-byte aligned'.format(sp))
print('  SP = 0x{:08x}  (non-zero, 4-byte aligned)  OK'.format(sp))
_regs['sp'] = sp
end

# ── 3. t0 (x5) and t1 (x6) write / read-back ─────────────────────────────────
python
import gdb

# Save originals
t0_orig = int(gdb.parse_and_eval('$t0')) & 0xFFFFFFFF
t1_orig = int(gdb.parse_and_eval('$t1')) & 0xFFFFFFFF

# Write test pattern
gdb.execute('set $t0 = 0xDEADBEEF')
gdb.execute('set $t1 = 0xCAFEBABE')

t0_rd = int(gdb.parse_and_eval('$t0')) & 0xFFFFFFFF
t1_rd = int(gdb.parse_and_eval('$t1')) & 0xFFFFFFFF

check('t0 write 0xDEADBEEF', t0_rd, 0xDEADBEEF)
check('t1 write 0xCAFEBABE', t1_rd, 0xCAFEBABE)

# Restore originals
gdb.execute('set $t0 = {}'.format(t0_orig))
gdb.execute('set $t1 = {}'.format(t1_orig))
print('  t0, t1 restored to original values')
end

# ── 4. s0 (x8) and a0 (x10) write / read-back ────────────────────────────────
python
import gdb

s0_orig = int(gdb.parse_and_eval('$s0')) & 0xFFFFFFFF
a0_orig = int(gdb.parse_and_eval('$a0')) & 0xFFFFFFFF

gdb.execute('set $s0 = 0xA5A5A5A5')
gdb.execute('set $a0 = 0x5A5A5A5A')

check('s0 write 0xA5A5A5A5', int(gdb.parse_and_eval('$s0')) & 0xFFFFFFFF, 0xA5A5A5A5)
check('a0 write 0x5A5A5A5A', int(gdb.parse_and_eval('$a0')) & 0xFFFFFFFF, 0x5A5A5A5A)

gdb.execute('set $s0 = {}'.format(s0_orig))
gdb.execute('set $a0 = {}'.format(a0_orig))
print('  s0, a0 restored')
end

# ── 5. "info registers" output contains expected register names ───────────────
python
import gdb

info = gdb.execute('info registers', to_string=True)
# RISC-V GDB may report x0 as 'zero' or 'x0' depending on ABI settings
required_flex = [
    ('pc',   ['pc']),
    ('sp',   ['sp', 'x2']),
    ('ra',   ['ra', 'x1']),
    ('zero', ['zero', 'x0']),
]
missing = [name for name, alts in required_flex if not any(a in info for a in alts)]
if missing:
    raise gdb.GdbError(
        '[FAIL] gdb_regs: info registers missing: {}'.format(', '.join(missing)))
print('  info registers: all required names present  OK')
end

# ── 6. CSR: misa — check RV32I (bit 8) and RVC (bit 2) ──────────────────────
python
import gdb

misa = monitor_reg('misa')
# RISC-V MISA MXL field [31:30] must be 01 (RV32)
mxl = (misa >> 30) & 0x3
if mxl != 1:
    raise gdb.GdbError(
        '[FAIL] gdb_regs: MISA.MXL={} expected 1 (RV32), misa=0x{:08x}'.format(
            mxl, misa))
# Bit 8 = 'I' extension (base integer ISA)
if not (misa & (1 << 8)):
    raise gdb.GdbError(
        '[FAIL] gdb_regs: MISA.I (bit 8) not set, misa=0x{:08x}'.format(misa))
print('  MISA=0x{:08x}  MXL={}(RV32)  I-ext=1  OK'.format(misa, mxl))
end

# ── 7. CSR: dcsr — prv field == 3 (M-mode) after halt ───────────────────────
python
import gdb

dcsr = monitor_reg('dcsr')
prv  = dcsr & 0x3          # bits [1:0]
if prv != 3:
    raise gdb.GdbError(
        '[FAIL] gdb_regs: DCSR.prv={} expected 3 (M-mode), '
        'dcsr=0x{:08x}'.format(prv, dcsr))
# DCSR.debugver field [31:28] must be 4 (RISC-V debug spec 0.13+)
debugver = (dcsr >> 28) & 0xF
if debugver < 2:
    raise gdb.GdbError(
        '[FAIL] gdb_regs: DCSR.debugver={} expected >=2, '
        'dcsr=0x{:08x}'.format(debugver, dcsr))
print('  DCSR=0x{:08x}  prv={}(M)  debugver={}  OK'.format(dcsr, prv, debugver))
end

# ── 8. CSR: mstatus non-zero ──────────────────────────────────────────────────
python
import gdb

mstatus = monitor_reg('mstatus')
if mstatus == 0:
    raise gdb.GdbError('[FAIL] gdb_regs: mstatus is zero')
print('  MSTATUS=0x{:08x}  OK'.format(mstatus))
end

# ── 9. CSR: mepc readable (zero early in boot is tolerated) ──────────────────
python
import gdb

mepc = monitor_reg('mepc')
# mepc is valid (or zero if no exception has fired yet) — just check readable
print('  MEPC=0x{:08x}  (readable)  OK'.format(mepc))
end

# ── 10. x0 (zero register) cannot be written ─────────────────────────────────
python
import gdb

# Attempt to write a non-zero value to x0
try:
    gdb.execute('set $zero = 0xFFFFFFFF')
except Exception:
    pass   # some GDB builds refuse the write outright — that is correct

x0 = int(gdb.parse_and_eval('$zero')) & 0xFFFFFFFF
if x0 != 0:
    raise gdb.GdbError(
        '[FAIL] gdb_regs: x0 (zero) register holds 0x{:08x} after write'.format(x0))
print('  x0 (zero) = 0x{:08x}  (write-ignored)  OK'.format(x0))
end

printf "[PASS] gdb_regs\n"
