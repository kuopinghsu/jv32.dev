# ============================================================================
# GDB test: gdb_load — download ELF via GDB, verify PC at entry point
#
# Connection is established by the Makefile before sourcing this script:
#   gdb --batch
#       -ex "set pagination off"
#       -ex "set confirm off"
#       -ex "set remotetimeout 30"
#       -ex "target extended-remote :PORT"
#       -x test_gdb_load.gdb  <elf>
#
# Verifies:
#   1. GDB "load" downloads all ELF sections without error.
#   2. PC after load is within IRAM (0x80000000–0x80FFFFFF).
#   3. At least one stepi succeeds and advances PC.
#   4. At least one nexti succeeds and advances PC.
# ============================================================================

# ── 1. Reset and halt the core ───────────────────────────────────────────────
monitor reset halt
monitor wait_halt 2000

# ── 2. Download ELF sections to target memory ────────────────────────────────
load

# ── 3. Verify PC is at the ELF entry point (within IRAM) ────────────────────
python
import gdb, re

pc = int(gdb.parse_and_eval('$pc'))
IRAM_LO, IRAM_HI = 0x80000000, 0x80FFFFFF
if not (IRAM_LO <= pc <= IRAM_HI):
    raise gdb.GdbError(
        '[FAIL] gdb_load: entry PC 0x{:08x} not in IRAM '
        '[0x80000000..0x80FFFFFF]'.format(pc))
print('  load: entry PC = 0x{:08x}  OK'.format(pc))
_gdb_load = {'pc_entry': pc}
end

# ── 4. stepi — verify instruction-level step after load ─────────────────────
stepi

python
import gdb

pc1 = int(gdb.parse_and_eval('$pc'))
pc0 = _gdb_load['pc_entry']
if pc1 == pc0:
    raise gdb.GdbError(
        '[FAIL] gdb_load/stepi: PC stuck at 0x{:08x} after stepi'.format(pc0))
print('  stepi after load: 0x{:08x} -> 0x{:08x}  OK'.format(pc0, pc1))
_gdb_load['pc_after_stepi'] = pc1
end

# ── 5. nexti — verify step-over at instruction level ─────────────────────────
nexti

python
import gdb, re

pc2  = int(gdb.parse_and_eval('$pc'))
pc1  = _gdb_load['pc_after_stepi']
if pc2 == pc1:
    raise gdb.GdbError(
        '[FAIL] gdb_load/nexti: PC stuck at 0x{:08x} after nexti'.format(pc1))
print('  nexti after load: 0x{:08x} -> 0x{:08x}  OK'.format(pc1, pc2))
end

# ── 6. Verify DCSR.cause == 4 (step) via monitor ────────────────────────────
python
import gdb, re

out   = gdb.execute('monitor reg dcsr', to_string=True)
m     = re.search(r'0x([0-9a-fA-F]+)', out)
if not m:
    raise gdb.GdbError('[FAIL] gdb_load: could not parse dcsr from: ' + out)
dcsr  = int(m.group(1), 16)
cause = (dcsr >> 6) & 0x7
if cause != 4:
    raise gdb.GdbError(
        '[FAIL] gdb_load: DCSR.cause={} expected 4 (step), '
        'dcsr=0x{:08x}'.format(cause, dcsr))
print('  DCSR=0x{:08x}  cause={}(step)  OK'.format(dcsr, cause))
end

printf "[PASS] gdb_load\n"
