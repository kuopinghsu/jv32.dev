# ============================================================================
# GDB test: gdb_step_past_swbp — focused SW-breakpoint step-past regression
#
# Connection is established by the Makefile before sourcing this script.
#
# Purpose:
#   Explicitly validate software-breakpoint step-past semantics at
#   sw/include/jv_platform.h:181, which should compile to a compressed
#   16-bit store in this build.
#
# Coverage:
#   1) Hit SW breakpoint at jv_platform.h:181.
#   2) stepi: execute original instruction once and advance by exactly 2 bytes.
#   3) Verify the original instruction at breakpoint PC is a store mnemonic
#      (`sw` / `c.sw` / `c.swsp`) and encoded as a compressed 16-bit op.
# ============================================================================

set pagination off
set confirm off
set remotetimeout 120
set riscv use-compressed-breakpoints yes

# Override remote memory map so arbitrary IRAM/DRAM accesses are allowed.
set mem inaccessible-by-default off
mem 0x80000000 0x80020000 rw
mem 0x90000000 0x90020000 rw

python
import gdb
import re

_ctx = {}

def read_pc():
    return int(gdb.parse_and_eval('$pc'))

def parse_dcsr():
    out = gdb.execute('monitor reg dcsr', to_string=True)
    m = re.search(r'0x([0-9a-fA-F]+)', out)
    if not m:
        raise gdb.GdbError('cannot parse dcsr: ' + out)
    dcsr = int(m.group(1), 16)
    cause = (dcsr >> 6) & 0x7
    return dcsr, cause

def check_iram(label, pc):
    if not (0x80000000 <= pc <= 0x8FFFFFFF):
        raise gdb.GdbError('[FAIL] {}: PC 0x{:08x} outside IRAM'.format(label, pc))

def check_not_stuck(label, before_pc, after_pc):
    if after_pc == before_pc:
        raise gdb.GdbError('[FAIL] {}: PC stuck at 0x{:08x}'.format(label, after_pc))

def read_u16(addr):
    mem = bytes(gdb.selected_inferior().read_memory(addr, 2))
    b0 = mem[0]
    b1 = mem[1]
    return b0 | (b1 << 8)

def check_line_181(label, pc):
    out = gdb.execute('info line *0x{:08x}'.format(pc), to_string=True)
    if 'jv_platform.h' not in out or 'line 181' not in out.lower():
        raise gdb.GdbError('[FAIL] {}: expected jv_platform.h:181, got: {}'.format(label, out.strip()))

def check_store_mnemonic(addr):
    out = gdb.execute('x/i 0x{:08x}'.format(addr), to_string=True).lower()
    if all(tok not in out for tok in (' c.sw', ' c.swsp', '\tsw')):
        raise gdb.GdbError('[FAIL] expected store mnemonic at 0x{:08x}, disasm: {}'.format(addr, out.strip()))
    return out.strip()

def find_line181_store_pc(start_pc):
    # Line 181 can expand to multiple instructions at one location. Find the
    # first store instruction mapped to that source line near current PC.
    for off in range(0, 24, 2):
        addr = start_pc + off
        try:
            li = gdb.execute('info line *0x{:08x}'.format(addr), to_string=True).lower()
        except gdb.error:
            continue
        if 'jv_platform.h' not in li or 'line 181' not in li:
            continue
        di = gdb.execute('x/i 0x{:08x}'.format(addr), to_string=True).lower()
        if any(tok in di for tok in (' c.sw', ' c.swsp', '\tsw')):
            return addr, di.strip()
    raise gdb.GdbError('[FAIL] could not locate line-181 store instruction near PC 0x{:08x}'.format(start_pc))

end

# Program already completed while waiting for debugger connection. Re-seed core
# state and run from boot.
monitor halt
monitor reg dpc 0x80000000
monitor reg mtvec 0x80000074
monitor reg mie 0

# SW breakpoint at the target source line containing the raw console store.
tbreak sw/include/jv_platform.h:181
continue

python
import gdb

pc = read_pc()
check_iram('hit jv_platform.h:181', pc)
check_line_181('hit jv_platform.h:181', pc)
_ctx['line181_pc'] = pc
store_pc, store_dis = find_line181_store_pc(pc)
_ctx['bp_pc'] = store_pc
gdb.set_convenience_variable('store_pc', store_pc)
print('  SW breakpoint hit at jv_platform.h:181 PC=0x{:08x}'.format(pc))
print('  selected line-181 store PC=0x{:08x}: {}'.format(store_pc, store_dis))
end

# Move the SW breakpoint to the exact store instruction on line 181, then
# validate stepi from there.
tbreak *$store_pc
continue

python
import gdb

pc = read_pc()
if pc != _ctx['bp_pc']:
    raise gdb.GdbError('[FAIL] expected store breakpoint at 0x{:08x}, got PC=0x{:08x}'.format(_ctx['bp_pc'], pc))
print('  store SW breakpoint hit at PC=0x{:08x}'.format(pc))
end

# stepi must execute original instruction and advance by exactly one
# compressed instruction (2 bytes).
stepi

python
import gdb

pc = read_pc()
check_iram('stepi after jv_platform.h:181', pc)
check_not_stuck('stepi after jv_platform.h:181', _ctx['bp_pc'], pc)
if pc != (_ctx['bp_pc'] + 2):
    raise gdb.GdbError('[FAIL] stepi expected PC+2 from compressed instruction: before=0x{:08x} after=0x{:08x}'.format(_ctx['bp_pc'], pc))

# After one-shot breakpoint fires, memory at old PC is restored. Validate
# original instruction shape and mnemonic at that address.
insn16 = read_u16(_ctx['bp_pc'])
if (insn16 & 0x3) == 0x3:
    raise gdb.GdbError('[FAIL] expected compressed 16-bit instruction at 0x{:08x}, got halfword=0x{:04x}'.format(_ctx['bp_pc'], insn16))
dis = check_store_mnemonic(_ctx['bp_pc'])

dcsr, cause = parse_dcsr()
if cause != 4:
    raise gdb.GdbError('[FAIL] stepi: DCSR.cause={} expected 4(step), dcsr=0x{:08x}'.format(cause, dcsr))

print('  stepi: 0x{:08x} -> 0x{:08x} (delta=2)  OK'.format(_ctx['bp_pc'], pc))
print('  restored insn @0x{:08x}: {}  halfword=0x{:04x}  OK'.format(_ctx['bp_pc'], dis, insn16))
print('  DCSR.cause={} (step)  OK'.format(cause))
end

python
print('')
print('[PASS] gdb_step_past_swbp: stepi stepped over jv_platform.h:181 compressed store')
end
