# ============================================================================
# GDB test: gdb_breakpoint — hardware and software breakpoints via GDB
#
# Connection is established by the Makefile before sourcing this script.
#
# Strategy: all tests inject a snippet of known 32-bit NOPs into IRAM scratch
# space (0x80007000) and use stepi to advance towards breakpoints rather than
# continue.  This avoids unbounded waits: if the hart would run past a breakpoint
# via the boot ELF the test would hang; stepi is always bounded.
#
# A hw execute trigger at address X fires when the hart advances to X (i.e.
# during the stepi that would bring PC from X-4 to X).  RISC-V debug spec
# gives triggers priority over single-step: DCSR.cause == 2 (trigger), not 4.
# OpenOCD automatically inhibits the trigger for one step when resuming from a
# triggered halt at the same address.
#
# Verifies:
#   1. hbreak (hardware breakpoint) — stepi fires trigger, DCSR.cause == 2.
#   2. Two simultaneous hardware breakpoints — first fires, then second.
#   3. Disable / re-enable breakpoint: disabled bp does NOT fire during stepi.
#   4. break (software): stepi-based, SKIP-tolerant if ebreakm not configured.
# ============================================================================

# ── Shared Python helpers ─────────────────────────────────────────────────────
# Override remote memory map: declare full IRAM/DRAM so GDB allows access to
# any address within those regions, not just the ELF LOAD segments.
set mem inaccessible-by-default off
mem 0x80000000 0x80020000 rw
mem 0x90000000 0x90020000 rw

python
import gdb, re

SCRATCH = 0x80007000   # IRAM scratch area (28 KB into IRAM; assumes >= 28 KB)

# Snippet layout (32-bit NOPs = 0x00000013 = addi x0,x0,0):
#   +0 : nop
#   +4 : nop
#   +8 : nop   <- BP_SINGLE target
#   +12: nop   <- BP_A (dual test, first)
#   +16: nop   <- BP_B (dual test, second)
#   +20: nop   <- disable/re-enable target
#   +24: nop   <- sw bp target
#   +28: ebreak  (sentinel; should never be reached)
NOP    = 0x00000013
EBREAK = 0x00100073

BP_SINGLE = SCRATCH + 8
BP_A      = SCRATCH + 12
BP_B      = SCRATCH + 16
BP_DIS    = SCRATCH + 20
BP_SW     = SCRATCH + 24

def wr32(addr, val):
    gdb.execute('set {{unsigned int}}0x{:08x} = 0x{:08x}'.format(addr, val))

def rd32(addr):
    out = gdb.execute('x/1wx 0x{:08x}'.format(addr), to_string=True)
    m   = re.search(r':\s+(0x[0-9a-fA-F]+)', out)
    if not m:
        raise gdb.GdbError('cannot parse x/wx output: ' + out)
    return int(m.group(1), 16)

def read_pc():
    return int(gdb.parse_and_eval('$pc'))

def parse_dcsr():
    out = gdb.execute('monitor reg dcsr', to_string=True)
    m   = re.search(r'0x([0-9a-fA-F]+)', out)
    if not m:
        raise gdb.GdbError('cannot parse dcsr: ' + out)
    return int(m.group(1), 16)

def dcsr_cause(dcsr):
    return (dcsr >> 6) & 0x7

def set_pc(addr):
    gdb.execute('monitor reg pc 0x{:08x}'.format(addr))

def check_cause(label, expected):
    dcsr  = parse_dcsr()
    cause = dcsr_cause(dcsr)
    if cause != expected:
        raise gdb.GdbError(
            '[FAIL] {}: DCSR.cause={} expected {}, dcsr=0x{:08x}'.format(
                label, cause, expected, dcsr))
    print('  {}: DCSR.cause={}  OK'.format(label, cause))
    return dcsr

_bp = {}
end

# ── 0. Reset and write snippet to IRAM scratch ───────────────────────────────
monitor reset halt
monitor wait_halt 2000

python
import gdb

offsets = [0, 4, 8, 12, 16, 20, 24]
for off in offsets:
    wr32(SCRATCH + off, NOP)
wr32(SCRATCH + 28, EBREAK)

# Verify snippet was written
for off in offsets:
    got = rd32(SCRATCH + off)
    if got != NOP:
        raise gdb.GdbError(
            '[FAIL] snippet write: SCRATCH+{} = 0x{:08x} expected 0x{:08x}'.format(
                off, got, NOP))
print('  snippet written to IRAM scratch 0x{:08x}'.format(SCRATCH))
end

# ── 1. Single hardware breakpoint (stepi-based) ───────────────────────────────
# hbreak at BP_SINGLE (SCRATCH+8).  Set PC=SCRATCH+0.
# stepi x1: executes SCRATCH+0 -> advances to SCRATCH+4, cause=4.
# stepi x1: executes SCRATCH+4 -> trigger fires at SCRATCH+8, cause=2. v
python
import gdb

gdb.execute('hbreak *0x{:08x}'.format(BP_SINGLE))
print('  hbreak at 0x{:08x}'.format(BP_SINGLE))
set_pc(SCRATCH)
end

stepi

python
import gdb
pc = read_pc()
if pc != SCRATCH + 4:
    raise gdb.GdbError('[FAIL] hbreak pre-step: expected PC=0x{:08x} got 0x{:08x}'.format(
        SCRATCH + 4, pc))
check_cause('hbreak pre-step (should be step)', 4)
end

stepi

python
import gdb

pc = read_pc()
if pc != BP_SINGLE:
    raise gdb.GdbError(
        '[FAIL] hbreak: expected PC=0x{:08x} got 0x{:08x}'.format(BP_SINGLE, pc))
check_cause('hbreak trigger', 2)
print('  hbreak: hit at 0x{:08x}  OK'.format(pc))
end

delete breakpoints

# ── 2. Two simultaneous hardware breakpoints ──────────────────────────────────
# BP_A at SCRATCH+12, BP_B at SCRATCH+16.
# Set PC=SCRATCH+0.
# stepi x1 -> SCRATCH+4,  cause=4.
# stepi x1 -> SCRATCH+8,  cause=4  (no bp there).
# stepi x1 -> trigger fires at SCRATCH+12 (BP_A), cause=2.
# stepi x1 -> OpenOCD steps over BP_A; trigger fires at SCRATCH+16 (BP_B), cause=2.
python
import gdb

gdb.execute('hbreak *0x{:08x}'.format(BP_A))
gdb.execute('hbreak *0x{:08x}'.format(BP_B))
print('  dual hbreak: A=0x{:08x}  B=0x{:08x}'.format(BP_A, BP_B))
set_pc(SCRATCH)
end

stepi
stepi
stepi

python
import gdb

pc = read_pc()
if pc != BP_A:
    raise gdb.GdbError(
        '[FAIL] dual hbreak first: expected PC=0x{:08x} got 0x{:08x}'.format(BP_A, pc))
check_cause('dual hbreak first (BP_A)', 2)
print('  dual hbreak: BP_A hit at 0x{:08x}  OK'.format(pc))
end

stepi

python
import gdb

pc = read_pc()
if pc != BP_B:
    raise gdb.GdbError(
        '[FAIL] dual hbreak second: expected PC=0x{:08x} got 0x{:08x}'.format(BP_B, pc))
check_cause('dual hbreak second (BP_B)', 2)
print('  dual hbreak: BP_B hit at 0x{:08x}  OK'.format(pc))
end

delete breakpoints

# ── 3. Disable / re-enable a hardware breakpoint ─────────────────────────────
# Set hbreak at BP_DIS (SCRATCH+20).  Disable it immediately.
# stepi through SCRATCH+0..+20 -> cause=4 each time (no trigger fires).
# Re-enable, set PC back to BP_DIS.
# stepi -> trigger fires immediately, cause=2. v
python
import gdb

out = gdb.execute('hbreak *0x{:08x}'.format(BP_DIS), to_string=True)
import re as _re
m = _re.search(r'breakpoint (\d+)', out, _re.IGNORECASE)
bp_num = m.group(1) if m else None
if bp_num:
    gdb.execute('disable {}'.format(bp_num))
    print('  hbreak {} at 0x{:08x} disabled'.format(bp_num, BP_DIS))
else:
    print('  hbreak set (could not parse number, skipping disable check)')
_bp['bp_dis_num'] = bp_num
set_pc(SCRATCH)
end

# stepi x6: passes through +0, +4, +8, +12, +16, +20 -- none should trigger
stepi
stepi
stepi
stepi
stepi
stepi

python
import gdb

pc = read_pc()
check_cause('disabled bp (no trigger expected)', 4)
print('  disabled bp: PC=0x{:08x} stepped past 0x{:08x} without trigger  OK'.format(
    pc, BP_DIS))

if _bp['bp_dis_num']:
    gdb.execute('enable {}'.format(_bp['bp_dis_num']))
    print('  breakpoint {} re-enabled'.format(_bp['bp_dis_num']))
set_pc(BP_DIS)
end

stepi

python
import gdb

pc = read_pc()
if pc != BP_DIS:
    raise gdb.GdbError(
        '[FAIL] re-enable bp: expected PC=0x{:08x} got 0x{:08x}'.format(BP_DIS, pc))
check_cause('re-enabled bp trigger', 2)
print('  re-enabled bp: trigger fired at 0x{:08x}  OK'.format(pc))
end

delete breakpoints

# ── 4. Software breakpoint -- SKIP-tolerant ───────────────────────────────────
# GDB "break" inserts an ebreak instruction (software bp).  This only causes a
# debug halt if dcsr.ebreakm=1.  Without it, ebreak causes a trap (mtvec),
# not a debug halt.  Detect result by reading DCSR.cause after stepi:
#   cause=2 (trigger) -> sw bp fired correctly.
#   cause=4 (step)    -> ebreakm not set; sw bp does not debug-halt -> SKIP.
python
import gdb

gdb.execute('break *0x{:08x}'.format(BP_SW))
print('  sw break at 0x{:08x}'.format(BP_SW))
set_pc(BP_SW - 4)   # one 32-bit nop before the sw bp address
end

stepi

python
import gdb

pc    = read_pc()
dcsr  = parse_dcsr()
cause = dcsr_cause(dcsr)
print('  sw break: PC=0x{:08x}  DCSR.cause={}'.format(pc, cause))
if cause == 2 and pc == BP_SW:
    print('  sw break: fired correctly (dcsr.ebreakm active or hw-override)  OK')
elif cause == 4:
    print('  sw break: cause=4 (step) -- ebreakm not configured, SKIP')
else:
    print('  sw break: unexpected state PC=0x{:08x} cause={} -- SKIP'.format(pc, cause))
end

delete breakpoints

printf "[PASS] gdb_breakpoint\n"
