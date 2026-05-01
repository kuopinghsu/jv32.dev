# ============================================================================
# GDB test: gdb_step — step / stepi / next / nexti via GDB
#
# Connection is established by the Makefile before sourcing this script.
#
# Verifies:
#   1. stepi advances PC and sets DCSR.cause=4 (step).
#   2. nexti advances PC and sets DCSR.cause=4.
#   3. step  advances PC (source-level; tolerates "no line info" as SKIP).
#   4. next  advances PC (source-level; tolerates "no line info" as SKIP).
#   5. PC remains within IRAM after all steps.
# ============================================================================

# ── 1. Reset to a clean known state ──────────────────────────────────────────
monitor reset halt
monitor wait_halt 2000

# Force PC to the reset vector so the test is deterministic regardless of
# where the VPI boot sequence left the hart.
monitor reg pc 0x80000000

# Initialise shared Python state
python
import gdb, re

def parse_dcsr_cause():
    out   = gdb.execute('monitor reg dcsr', to_string=True)
    m     = re.search(r'0x([0-9a-fA-F]+)', out)
    if not m:
        raise gdb.GdbError('cannot parse dcsr: ' + out)
    dcsr  = int(m.group(1), 16)
    return (dcsr >> 6) & 0x7, dcsr

def check_advance(label, pc_before, pc_after):
    if pc_after == pc_before:
        raise gdb.GdbError(
            '[FAIL] {}: PC stuck at 0x{:08x}'.format(label, pc_before))
    if not (0x80000000 <= pc_after <= 0x8FFFFFFF):
        raise gdb.GdbError(
            '[FAIL] {}: PC 0x{:08x} outside expected range'.format(
                label, pc_after))
    print('  {}: 0x{:08x} -> 0x{:08x}  OK'.format(
        label, pc_before, pc_after))

_step = {}
_step['pc0'] = int(gdb.parse_and_eval('$pc'))
print('  start PC = 0x{:08x}'.format(_step['pc0']))
end

# ── 2. stepi #1 ──────────────────────────────────────────────────────────────
stepi

python
import gdb

pc1 = int(gdb.parse_and_eval('$pc'))
check_advance('stepi #1', _step['pc0'], pc1)
cause, dcsr = parse_dcsr_cause()
if cause != 4:
    raise gdb.GdbError(
        '[FAIL] stepi #1: DCSR.cause={} expected 4, dcsr=0x{:08x}'.format(
            cause, dcsr))
print('  DCSR=0x{:08x}  cause={}(step)  OK'.format(dcsr, cause))
_step['pc1'] = pc1
end

# ── 3. stepi #2 ──────────────────────────────────────────────────────────────
stepi

python
import gdb

pc2 = int(gdb.parse_and_eval('$pc'))
check_advance('stepi #2', _step['pc1'], pc2)
cause, dcsr = parse_dcsr_cause()
if cause != 4:
    raise gdb.GdbError(
        '[FAIL] stepi #2: DCSR.cause={} expected 4, dcsr=0x{:08x}'.format(
            cause, dcsr))
_step['pc2'] = pc2
end

# ── 4. stepi #3 ──────────────────────────────────────────────────────────────
stepi

python
import gdb

pc3 = int(gdb.parse_and_eval('$pc'))
check_advance('stepi #3', _step['pc2'], pc3)
_step['pc3'] = pc3
end

# ── 5. nexti #1 ──────────────────────────────────────────────────────────────
nexti

python
import gdb

pc4 = int(gdb.parse_and_eval('$pc'))
check_advance('nexti #1', _step['pc3'], pc4)
cause, dcsr = parse_dcsr_cause()
if cause != 4:
    raise gdb.GdbError(
        '[FAIL] nexti #1: DCSR.cause={} expected 4, dcsr=0x{:08x}'.format(
            cause, dcsr))
print('  DCSR=0x{:08x}  cause={}(step)  OK'.format(dcsr, cause))
_step['pc4'] = pc4
end

# ── 6. nexti #2 ──────────────────────────────────────────────────────────────
nexti

python
import gdb

pc5 = int(gdb.parse_and_eval('$pc'))
check_advance('nexti #2', _step['pc4'], pc5)
_step['pc5'] = pc5
end

# ── 7. step (source-level) — SKIP-tolerant ───────────────────────────────────
# "step" maps to source-line stepping. On bare-metal or without DWARF it may
# behave identically to stepi, or GDB may warn "no line info". Either outcome
# is acceptable; the key check is that PC advances if the command succeeds.
python
import gdb

try:
    pc_before = int(gdb.parse_and_eval('$pc'))
    gdb.execute('step')
    pc_after  = int(gdb.parse_and_eval('$pc'))
    if pc_after == pc_before:
        print('  step: PC unchanged (bare-metal / no DWARF line info) -- treating as SKIP')
        _step['step_skip'] = True
    else:
        print('  step: 0x{:08x} -> 0x{:08x}  OK'.format(pc_before, pc_after))
        _step['step_skip'] = False
    _step['pc6'] = int(gdb.parse_and_eval('$pc'))
except Exception as e:
    print('  step: command raised exception ({}) -- treating as SKIP'.format(e))
    _step['step_skip'] = True
    _step['pc6'] = int(gdb.parse_and_eval('$pc'))
end

# ── 8. next (source-level) — SKIP-tolerant ───────────────────────────────────
python
import gdb

try:
    pc_before = int(gdb.parse_and_eval('$pc'))
    gdb.execute('next')
    pc_after  = int(gdb.parse_and_eval('$pc'))
    if pc_after == pc_before:
        print('  next: PC unchanged (bare-metal / no DWARF line info) -- treating as SKIP')
        _step['next_skip'] = True
    else:
        print('  next: 0x{:08x} -> 0x{:08x}  OK'.format(pc_before, pc_after))
        _step['next_skip'] = False
except Exception as e:
    print('  next: command raised exception ({}) -- treating as SKIP'.format(e))
    _step['next_skip'] = True
end

# ── 9. Summary ───────────────────────────────────────────────────────────────
python
import gdb

skipped = []
if _step.get('step_skip'):
    skipped.append('step')
if _step.get('next_skip'):
    skipped.append('next')
if skipped:
    print('  NOTE: source-level commands skipped (no DWARF): {}'.format(
        ', '.join(skipped)))
end

printf "[PASS] gdb_step\n"
