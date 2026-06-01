# ============================================================================
# GDB test: gdb_csr — CSR read/write regression via GDB monitor interface
#
# Connection is established by the Makefile before sourcing this script.
#
# Verifies:
#   1. Core CSRs are readable (misa, mstatus, mie, mscratch, mtvec).
#   2. Writable machine CSRs round-trip correctly (mscratch, mie, mstatus).
#   3. Each modified CSR is restored to its original value.
# ============================================================================

monitor halt
monitor wait_halt 2000

python
import gdb
import re

_csr = {}

def parse_hex_monitor(output):
    m = re.search(r'0x([0-9a-fA-F]+)', output)
    if not m:
        raise gdb.GdbError('cannot parse monitor output: ' + repr(output))
    return int(m.group(1), 16) & 0xFFFFFFFF

def csr_read(name):
    out = gdb.execute('monitor reg {}'.format(name), to_string=True)
    return parse_hex_monitor(out)

def csr_write(name, value):
    gdb.execute('monitor reg {} 0x{:08x}'.format(name, value & 0xFFFFFFFF))

def check_eq(label, got, expected, mask=0xFFFFFFFF):
    got_m = got & mask
    exp_m = expected & mask
    if got_m != exp_m:
        raise gdb.GdbError('[FAIL] {}: expected=0x{:08x} got=0x{:08x} mask=0x{:08x}'.format(
            label, exp_m, got_m, mask & 0xFFFFFFFF))
    print('  {:36s}: 0x{:08x}  OK'.format(label, got_m))

end

# ── 1) Read baseline CSR values ──────────────────────────────────────────────
python
import gdb

for name in ('misa', 'mstatus', 'mie', 'mscratch', 'mtvec'):
    _csr[name] = csr_read(name)
    print('  {:36s}: 0x{:08x}  OK'.format('read ' + name, _csr[name]))

mxl = (_csr['misa'] >> 30) & 0x3
if mxl != 1:
    raise gdb.GdbError('[FAIL] misa.mxl expected 1 (RV32), got {} (misa=0x{:08x})'.format(mxl, _csr['misa']))
if (_csr['misa'] & (1 << 8)) == 0:
    raise gdb.GdbError('[FAIL] misa.I bit is not set (misa=0x{:08x})'.format(_csr['misa']))
print('  misa fields validated (RV32 + I)  OK')
end

# ── 2) mscratch write/read/restore ───────────────────────────────────────────
python
import gdb

orig = _csr['mscratch']
pat1 = 0xA5A55A5A
pat2 = 0x5AA5C33C

csr_write('mscratch', pat1)
rd1 = csr_read('mscratch')
check_eq('mscratch write/read #1', rd1, pat1)

csr_write('mscratch', pat2)
rd2 = csr_read('mscratch')
check_eq('mscratch write/read #2', rd2, pat2)

csr_write('mscratch', orig)
rd_restore = csr_read('mscratch')
check_eq('mscratch restore', rd_restore, orig)
end

# ── 3) mie write/read/restore (standard machine interrupt bits) ─────────────
python
import gdb

orig = _csr['mie']
# Standard writable machine interrupt-enable bits: MEIE(11), MTIE(7), MSIE(3)
mask = 0x00000888
trial = (orig & ~mask) | ((~orig) & mask)

csr_write('mie', trial)
rd = csr_read('mie')
check_eq('mie write/read (masked)', rd, trial, mask)

csr_write('mie', orig)
rd_restore = csr_read('mie')
check_eq('mie restore (masked)', rd_restore, orig, mask)
end

# ── 4) mstatus write/read/restore (MIE/MPIE bits) ───────────────────────────
python
import gdb

orig = _csr['mstatus']
# Toggle MIE(3) and MPIE(7). These are architecturally writable bits.
mask = 0x00000088
trial = (orig & ~mask) | ((~orig) & mask)

csr_write('mstatus', trial)
rd = csr_read('mstatus')
check_eq('mstatus write/read (masked)', rd, trial, mask)

csr_write('mstatus', orig)
rd_restore = csr_read('mstatus')
check_eq('mstatus restore (masked)', rd_restore, orig, mask)
end

printf "[PASS] gdb_csr\n"
