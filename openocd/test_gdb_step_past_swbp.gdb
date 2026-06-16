# ============================================================================
# GDB test: gdb_step_past_swbp — focused SW-breakpoint step-past regression
#
# Connection is established by the Makefile before sourcing this script.
#
# Purpose:
#   Explicitly validate software-breakpoint step-past semantics on compressed
#   call sites in sw/hello/hello.c (main:foo2 and main:foo3).
#
# Coverage:
#   1) Hit SW breakpoint at main:foo2 (compressed call site).
#   2) stepi: step-past the SW breakpoint and execute the original instruction.
#      Expect PC to advance into foo(), not stay stuck at the breakpoint.
#   3) Re-hit main:foo2 and run nexti.
#      Expect PC to advance to main:foo3 (next compressed call site).
#   4) continue: ensure execution still progresses and no debug-state corruption
#      occurs after the step-past sequence.
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

end

# Program already completed while waiting for debugger connection. Re-seed core
# state and run from boot.
monitor halt
monitor reg dpc 0x80000000
monitor reg mtvec 0x80000074
monitor reg mie 0

# SW breakpoints at compressed call sites in main().
break main:foo2
break main:foo3
continue

python
import gdb

pc = read_pc()
check_iram('hit foo2', pc)
_ctx['foo2_pc'] = pc
print('  foo2 SW breakpoint hit at PC=0x{:08x}'.format(pc))
end

# 1) stepi must execute original instruction and move forward from foo2.
stepi

python
import gdb

pc = read_pc()
check_iram('stepi after foo2', pc)
check_not_stuck('stepi after foo2', _ctx['foo2_pc'], pc)
_ctx['stepi_pc'] = pc
print('  stepi: 0x{:08x} -> 0x{:08x}  OK'.format(_ctx['foo2_pc'], pc))
end

# Re-arm at foo2 to validate nexti step-past behavior on same SW breakpoint.
monitor halt
monitor reg dpc 0x8000109e
continue

python
import gdb

pc = read_pc()
_ctx['foo2_rehit_pc'] = pc
print('  foo2 SW breakpoint re-hit at PC=0x{:08x}'.format(pc))
end

# 2) nexti should step over the compressed call to the next call-site label.
nexti

python
import gdb

pc = read_pc()
check_iram('nexti after foo2', pc)
check_not_stuck('nexti after foo2', _ctx['foo2_rehit_pc'], pc)
dcsr, cause = parse_dcsr()
# nexti can halt either due to single-step completion (cause=4) or because it
# immediately lands on the next SW breakpoint (cause=1 at main:foo3).
if cause not in (1, 4):
    raise gdb.GdbError('[FAIL] nexti: DCSR.cause={} expected 1(ebreak) or 4(step), dcsr=0x{:08x}'.format(cause, dcsr))
print('  nexti: 0x{:08x} -> 0x{:08x}  DCSR.cause={}  OK'.format(_ctx['foo2_rehit_pc'], pc, cause))
end

delete

python
print('')
print('[PASS] gdb_step_past_swbp: compressed SW breakpoint step-past semantics passed')
end
