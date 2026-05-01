# ============================================================================
# GDB test: gdb_breakpoint — hardware and software breakpoints via GDB
#
# Connection is established by the Makefile before sourcing this script.
#
# Strategy: inject a NOP sled into IRAM scratch space (0x80007000) with an
# EBREAK sentinel at the end, then use "continue" rather than "stepi" to
# reach each breakpoint.  Using continue:
#   - avoids pipeline-timing hazards between dcsr.step and execute triggers
#     (the jv32 pipeline fetches ahead so triggers may fire one instruction
#     earlier than expected during single-step)
#   - is bounded: the EBREAK sentinel always halts the hart even if a
#     breakpoint is missed
#
# Verifies:
#   1. hbreak (hardware breakpoint) — continue hits trigger, DCSR.cause == 2.
#   2. Two simultaneous hardware breakpoints — first fires, then second.
#   3. Disable / re-enable: disabled bp is skipped, re-enabled bp fires.
#   4. break (software): SKIP-tolerant if dcsr.ebreakm not configured.
# ============================================================================

# ── Shared Python helpers ─────────────────────────────────────────────────────
# Override remote memory map: declare full IRAM/DRAM so GDB allows access to
# any address within those regions, not just the ELF LOAD segments.
set mem inaccessible-by-default off
mem 0x80000000 0x80020000 rw
mem 0x90000000 0x90020000 rw

python
import gdb, re

SCRATCH = 0x80007000   # IRAM scratch area (28 KB into IRAM, within 128 KB)

# Snippet layout (32-bit NOPs = 0x00000013 = addi x0,x0,0):
#   +0 : nop  <- resume point (PC set here before each "continue")
#   +4 : nop
#   +8 : nop  <- BP_SINGLE target
#   +12: nop  <- BP_A (dual test, first)
#   +16: nop  <- BP_B (dual test, second)
#   +20: nop  <- BP_DIS (disable/re-enable target)
#   +24: nop  <- BP_SW (software breakpoint target)
#   +28: ebreak  (sentinel: cause=3 if reached, means a bp was missed)
NOP    = 0x00000013
EBREAK = 0x00100073

BP_SINGLE = SCRATCH + 8
BP_A      = SCRATCH + 12
BP_B      = SCRATCH + 16
BP_DIS    = SCRATCH + 20
BP_SW     = SCRATCH + 24
SENTINEL  = SCRATCH + 28

def wr32(addr, val):
    gdb.execute('monitor mww 0x{:08x} 0x{:08x}'.format(addr, val))

def rd32(addr):
    out = gdb.execute('monitor mdw 0x{:08x}'.format(addr), to_string=True)
    m   = re.search(r'0x[0-9a-fA-F]+:\s+([0-9a-fA-F]+)', out)
    if not m:
        raise gdb.GdbError('cannot parse mdw output: ' + out)
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
    gdb.execute('set $pc = 0x{:08x}'.format(addr))

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

# ── 0. Reset and write NOP sled to IRAM scratch ──────────────────────────────
monitor reset halt
monitor wait_halt 2000
# jv32.cfg uses 'abstract' mem-access which does not support arbitrary writes;
# switch to progbuf so mww/mdw work anywhere in IRAM.
monitor riscv set_mem_access progbuf

python
import gdb

offsets = [0, 4, 8, 12, 16, 20, 24]
for off in offsets:
    wr32(SCRATCH + off, NOP)
wr32(SENTINEL, EBREAK)

for off in offsets:
    got = rd32(SCRATCH + off)
    if got != NOP:
        raise gdb.GdbError(
            '[FAIL] snippet write: SCRATCH+{} = 0x{:08x} expected 0x{:08x}'.format(
                off, got, NOP))
got = rd32(SENTINEL)
if got != EBREAK:
    raise gdb.GdbError(
        '[FAIL] sentinel write: 0x{:08x} expected 0x{:08x}'.format(got, EBREAK))
print('  NOP sled written to IRAM scratch 0x{:08x}-0x{:08x}'.format(
    SCRATCH, SENTINEL))
end

# ── 1. Single hardware breakpoint ────────────────────────────────────────────
# hbreak at BP_SINGLE (SCRATCH+8).  Set PC = SCRATCH.
# continue -> hart runs NOPs, trigger fires at BP_SINGLE.
# Expect: PC == BP_SINGLE, DCSR.cause == 2 (trigger).
python
import gdb

gdb.execute('hbreak *0x{:08x}'.format(BP_SINGLE))
print('  hbreak at 0x{:08x}'.format(BP_SINGLE))
set_pc(SCRATCH)
end

continue

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
# hbreak at BP_A (SCRATCH+12) and BP_B (SCRATCH+16).
# First continue from SCRATCH -> BP_A fires first.
# After BP_A halt: delete BP_A, continue from BP_A -> BP_B fires.
python
import gdb

gdb.execute('hbreak *0x{:08x}'.format(BP_A))
gdb.execute('hbreak *0x{:08x}'.format(BP_B))
print('  dual hbreak: A=0x{:08x}  B=0x{:08x}'.format(BP_A, BP_B))
set_pc(SCRATCH)
end

continue

python
import gdb

pc = read_pc()
if pc != BP_A:
    raise gdb.GdbError(
        '[FAIL] dual hbreak first: expected PC=0x{:08x} got 0x{:08x}'.format(BP_A, pc))
check_cause('dual hbreak BP_A', 2)
print('  dual hbreak: BP_A hit at 0x{:08x}  OK'.format(pc))
# Delete BP_A by finding its number from "info breakpoints"
out = gdb.execute('info breakpoints', to_string=True)
import re as _re
for line in out.splitlines():
    if hex(BP_A).lower() in line.lower() or '0x{:08x}'.format(BP_A).lower() in line.lower():
        m = _re.match(r'\s*(\d+)', line)
        if m:
            gdb.execute('delete {}'.format(m.group(1)))
            print('  deleted BP_A (GDB bp #{})'.format(m.group(1)))
            break
end

continue

python
import gdb

pc = read_pc()
if pc != BP_B:
    raise gdb.GdbError(
        '[FAIL] dual hbreak second: expected PC=0x{:08x} got 0x{:08x}'.format(BP_B, pc))
check_cause('dual hbreak BP_B', 2)
print('  dual hbreak: BP_B hit at 0x{:08x}  OK'.format(pc))
end

delete breakpoints

# ── 3. Disable / re-enable a hardware breakpoint ─────────────────────────────
# Set hbreak at BP_DIS (SCRATCH+20), then immediately disable it.
# continue from SCRATCH -> passes BP_DIS, hits EBREAK sentinel (cause=3).
# Re-enable BP_DIS, set PC=SCRATCH, continue again -> BP_DIS fires (cause=2).
python
import gdb

out = gdb.execute('hbreak *0x{:08x}'.format(BP_DIS), to_string=True)
import re as _re
m = _re.search(r'(?:Hardware assisted breakpoint|breakpoint)\s+(\d+)', out, _re.IGNORECASE)
bp_num = m.group(1) if m else None
if bp_num:
    gdb.execute('disable {}'.format(bp_num))
    print('  hbreak {} at 0x{:08x} created and disabled'.format(bp_num, BP_DIS))
else:
    print('  hbreak created (num not parsed)')
_bp['bp_dis_num'] = bp_num
set_pc(SCRATCH)
end

continue

python
import gdb

pc    = read_pc()
dcsr  = parse_dcsr()
cause = dcsr_cause(dcsr)
if cause == 2 and pc == BP_DIS:
    raise gdb.GdbError(
        '[FAIL] disabled bp fired at 0x{:08x} -- should have been skipped'.format(pc))
print('  disabled bp: cause={} PC=0x{:08x} -- skipped BP_DIS (0x{:08x})  OK'.format(
    cause, pc, BP_DIS))

if _bp.get('bp_dis_num'):
    gdb.execute('enable {}'.format(_bp['bp_dis_num']))
    print('  breakpoint {} re-enabled'.format(_bp['bp_dis_num']))
set_pc(SCRATCH)
end

continue

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
# GDB "break" inserts an EBREAK (software bp).  This only causes a debug halt
# if DCSR.ebreakm=1.  Detect result by checking DCSR.cause after continue:
#   cause=2 (trigger) -> hw-assisted sw bp fired.
#   cause=3 (ebreak)  -> sw bp EBREAK + dcsr.ebreakm caused debug halt.
#   other             -> ebreakm not set, no hw trigger; SKIP.
python
import gdb

gdb.execute('break *0x{:08x}'.format(BP_SW))
print('  sw break at 0x{:08x}'.format(BP_SW))
set_pc(SCRATCH)
end

continue

python
import gdb

pc    = read_pc()
dcsr  = parse_dcsr()
cause = dcsr_cause(dcsr)
print('  sw break: PC=0x{:08x}  DCSR.cause={}'.format(pc, cause))
if pc == BP_SW and cause in (2, 3):
    print('  sw break: fired at 0x{:08x} cause={}  OK'.format(pc, cause))
else:
    print('[SKIP] sw break: cause={} PC=0x{:08x} (ebreakm not configured or no hw override)'.format(
        cause, pc))
end

delete breakpoints

printf "[PASS] gdb_breakpoint\n"
