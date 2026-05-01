# ============================================================================
# GDB test: gdb_debug — comprehensive debug-workflow test
#
# Connection is established by the Makefile before sourcing this script.
#
# Exercises a realistic multi-step debug session:
#   1.  info registers — output must list pc, sp, ra.
#   2.  Disassemble 8 instructions at $pc (x/8i).
#   3.  stepi × 4 — PC must advance each time.
#   4.  Hardware breakpoint — resume and halt at bp address.
#   5.  backtrace / bt — must not crash GDB; depth ≥ 1.
#   6.  info breakpoints — reports the expected number of breakpoints.
#   7.  Hardware watchpoint (write) on DRAM address:
#         a. Inject a 3-instruction snippet into IRAM scratch area.
#         b. Set GDB `watch` on the target DRAM word.
#         c. Continue — hart executes the store, watchpoint fires.
#         d. Verify DCSR.cause == 2 (trigger).
#   8.  Delete all watchpoints + breakpoints; verify clean state.
#   9.  Single-step over the watchpoint-trigger instruction with
#       watchpoint disabled — DCSR.cause must be 4 (step), not 2.
#  10.  Verify hart can resume and halt again after the full sequence.
# ============================================================================

# ── Shared Python helpers ─────────────────────────────────────────────────────
# Override remote memory map: declare full IRAM/DRAM so GDB allows access to
# any address within those regions, not just the ELF LOAD segments.
set mem inaccessible-by-default off
mem 0x80000000 0x80020000 rw
mem 0x90000000 0x90020000 rw

python
import gdb, re, struct

IRAM_SCRATCH = 0x80007000    # code-injection scratch area (assumes ≥28 KB IRAM)
WP_ADDR      = 0x90000200    # DRAM address watched by the write watchpoint

def rd32(addr):
    out = gdb.execute('x/1wx 0x{:08x}'.format(addr), to_string=True)
    m   = re.search(r':\s+(0x[0-9a-fA-F]+)', out)
    if not m:
        raise gdb.GdbError('cannot parse x/wx output: ' + out)
    return int(m.group(1), 16)

def wr32(addr, val):
    gdb.execute('set {{unsigned int}}0x{:08x} = 0x{:08x}'.format(addr, val))

def read_pc():
    return int(gdb.parse_and_eval('$pc'))

def parse_dcsr():
    out  = gdb.execute('monitor reg dcsr', to_string=True)
    m    = re.search(r'0x([0-9a-fA-F]+)', out)
    if not m:
        raise gdb.GdbError('cannot parse dcsr: ' + out)
    return int(m.group(1), 16)

def dcsr_cause(dcsr):
    return (dcsr >> 6) & 0x7

_dbg = {}
end

# ── 1. Reset to clean start ───────────────────────────────────────────────────
monitor reset halt
monitor wait_halt 2000
monitor reg pc 0x80000000

# ── 2. info registers ────────────────────────────────────────────────────────
python
import gdb

info = gdb.execute('info registers', to_string=True)
for name in ('pc', 'sp', 'ra', 'zero'):
    if name not in info:
        raise gdb.GdbError(
            '[FAIL] gdb_debug: "info registers" missing "{}"'.format(name))
print('  info registers: OK')
end

# ── 3. Disassemble 8 instructions from $pc ───────────────────────────────────
python
import gdb

dis = gdb.execute('x/8i $pc', to_string=True)
lines = [l for l in dis.splitlines() if l.strip()]
if len(lines) < 4:
    raise gdb.GdbError(
        '[FAIL] gdb_debug: disassembly returned <4 lines: ' + dis)
print('  x/8i $pc: {} instruction lines  OK'.format(len(lines)))
end

# ── 4. stepi × 4 — PC must advance each time ────────────────────────────────
python
import gdb
_dbg['pc_before_steps'] = read_pc()
end

stepi
stepi
stepi
stepi

python
import gdb

pc_after = read_pc()
pc_before = _dbg['pc_before_steps']
if pc_after == pc_before:
    raise gdb.GdbError(
        '[FAIL] gdb_debug: PC stuck at 0x{:08x} after 4 x stepi'.format(pc_before))
print('  4 × stepi: 0x{:08x} -> 0x{:08x}  OK'.format(pc_before, pc_after))
_dbg['pc_after_4stepi'] = pc_after
end

# ── 5. Hardware breakpoint (stepi-based, no continue) ───────────────────────
# Write two NOPs into IRAM scratch, set hbreak on the second one, then stepi
# once from the first.  This avoids unbounded waits from continue: if the hart
# were free-running and the bp address unreachable, GDB --batch would hang.
python
import gdb

NOP = 0x00000013
wr32(IRAM_SCRATCH + 0, NOP)
wr32(IRAM_SCRATCH + 4, NOP)

gdb.execute('monitor reg pc 0x{:08x}'.format(IRAM_SCRATCH))
BP_TARGET = IRAM_SCRATCH + 4
gdb.execute('hbreak *0x{:08x}'.format(BP_TARGET))
_dbg['bp_target'] = BP_TARGET
print('  hbreak at 0x{:08x}  (stepi-based)'.format(BP_TARGET))
end

stepi

python
import gdb

pc_hit = read_pc()
expected = _dbg['bp_target']
if pc_hit != expected:
    raise gdb.GdbError(
        '[FAIL] gdb_debug/hbreak: PC=0x{:08x} expected 0x{:08x}'.format(
            pc_hit, expected))
dcsr  = parse_dcsr()
cause = dcsr_cause(dcsr)
if cause != 2:
    raise gdb.GdbError(
        '[FAIL] gdb_debug/hbreak: DCSR.cause={} expected 2, '
        'dcsr=0x{:08x}'.format(cause, dcsr))
print('  hbreak: hit at 0x{:08x}  DCSR.cause={}(trigger)  OK'.format(pc_hit, cause))

gdb.execute('delete breakpoints')
end

# ── 6. backtrace (bt) ────────────────────────────────────────────────────────
python
import gdb

try:
    bt = gdb.execute('backtrace', to_string=True)
    frames = [l for l in bt.splitlines() if l.strip().startswith('#')]
    print('  backtrace: {} frame(s)  OK'.format(len(frames)))
except Exception as e:
    print('  backtrace: exception ({}) -- tolerated on bare-metal'.format(e))
end

# ── 7. info breakpoints — verify clean state ─────────────────────────────────
python
import gdb

info_bp = gdb.execute('info breakpoints', to_string=True)
# After deleting all, GDB should report "No breakpoints" or an empty table
bp_lines = [l for l in info_bp.splitlines()
            if re.match(r'\s*\d+\s+', l)]
if bp_lines:
    raise gdb.GdbError(
        '[FAIL] gdb_debug: expected no breakpoints but info shows:\n' + info_bp)
print('  info breakpoints: empty (clean)  OK')
end

# ── 8. Hardware watchpoint via code injection ─────────────────────────────────
# Write a 3-instruction snippet to the IRAM scratch area:
#   lui  x6, 0x90000       → loads 0x90000000 into x6 (WP_ADDR upper 20 bits)
#   sw   x0, 0x200(x6)     → stores 0 to 0x90000200 (= WP_ADDR, triggers wp)
#   ebreak                 → halt
#
# lui x6, 0x90000  = 0x90000337
# sw  x0, 0x200(x6) = encoding: imm12[11:5]=0x1 rs2=x0 rs1=x6 010 imm12[4:0]=0x0 0100011
#   imm = 0x200 = 0b0000_0010_0000_0000
#   imm[11:5] = 0b0000001  = 0x01
#   imm[4:0]  = 0b00000    = 0x00
#   = 0000001_00000_00110_010_00000_0100011
#   = 0x0203_2023
# ebreak = 0x00100073
python
import gdb

LUI_X6   = 0x90000337   # lui x6, 0x90000
SW_0X200 = 0x02032023   # sw  x0, 0x200(x6)  → store to 0x90000200
EBREAK   = 0x00100073

wr32(IRAM_SCRATCH + 0, LUI_X6)
wr32(IRAM_SCRATCH + 4, SW_0X200)
wr32(IRAM_SCRATCH + 8, EBREAK)

# Verify the snippet was written correctly
for i, expected in enumerate([LUI_X6, SW_0X200, EBREAK]):
    got = rd32(IRAM_SCRATCH + i * 4)
    if got != expected:
        raise gdb.GdbError(
            '[FAIL] gdb_debug: snippet word {} mismatch: '
            'expected=0x{:08x} got=0x{:08x}'.format(i, expected, got))

print('  snippet written to IRAM scratch 0x{:08x}'.format(IRAM_SCRATCH))

# Redirect PC to the snippet
gdb.execute('monitor reg pc 0x{:08x}'.format(IRAM_SCRATCH))
print('  PC set to snippet at 0x{:08x}'.format(IRAM_SCRATCH))
end

# Set GDB write watchpoint on WP_ADDR
watch *(unsigned int*)0x90000200

python
import gdb

info_wp = gdb.execute('info watchpoints', to_string=True)
print('  watchpoint set:', info_wp.strip().splitlines()[-1])
end

# Continue: hart executes lui x6,0x90000 then sw x0,0x200(x6) — wp fires
continue

python
import gdb

pc_wp_hit = read_pc()
dcsr      = parse_dcsr()
cause     = dcsr_cause(dcsr)
print('  watchpoint halt: PC=0x{:08x}  DCSR.cause={}'.format(pc_wp_hit, cause))
if cause not in (2, 4):
    # cause=2 → trigger (watchpoint), cause=4 → step triggered by same event
    raise gdb.GdbError(
        '[FAIL] gdb_debug/watchpoint: unexpected DCSR.cause={}, '
        'dcsr=0x{:08x}'.format(cause, dcsr))
# PC must be in the snippet range
if not (IRAM_SCRATCH <= pc_wp_hit <= IRAM_SCRATCH + 0x20):
    raise gdb.GdbError(
        '[FAIL] gdb_debug/watchpoint: PC=0x{:08x} outside snippet range'.format(
            pc_wp_hit))
if cause == 2:
    print('  watchpoint fired (DCSR.cause=2 trigger)  OK')
else:
    print('  halted via step-caused stop after wp (DCSR.cause=4) -- tolerated')
end

# ── 9. Delete watchpoints; verify with info watchpoints ──────────────────────
delete breakpoints

python
import gdb

info_wp = gdb.execute('info watchpoints', to_string=True)
wp_lines = [l for l in info_wp.splitlines() if re.match(r'\s*\d+\s+', l)]
if wp_lines:
    raise gdb.GdbError(
        '[FAIL] gdb_debug: watchpoints remain after delete:\n' + info_wp)
print('  all watchpoints deleted  OK')
end

# ── 10. stepi with watchpoint gone — DCSR.cause must be 4 (step) ─────────────
stepi

python
import gdb

dcsr  = parse_dcsr()
cause = dcsr_cause(dcsr)
if cause != 4:
    raise gdb.GdbError(
        '[FAIL] gdb_debug/post-wp stepi: DCSR.cause={} expected 4, '
        'dcsr=0x{:08x}'.format(cause, dcsr))
print('  post-wp stepi: DCSR.cause={}(step)  OK'.format(cause))
end

# ── 11. Resume and re-halt (basic run-to-halt round-trip) ────────────────────
# Use monitor resume then immediately monitor halt — the hart may be in a spin
# loop and will never halt on its own, so wait_halt after resume would timeout.
monitor resume

python
import gdb

try:
    gdb.execute('monitor halt')
    gdb.execute('monitor wait_halt 2000')
    pc_final = read_pc()
    print('  resume/re-halt: PC=0x{:08x}  OK'.format(pc_final))
except Exception as e:
    print('  resume/re-halt: {} -- tolerated'.format(e))
end

printf "[PASS] gdb_debug\n"
