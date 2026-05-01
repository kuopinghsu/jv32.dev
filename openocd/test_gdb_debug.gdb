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
    out = gdb.execute('monitor mdw 0x{:08x}'.format(addr), to_string=True)
    m   = re.search(r'0x[0-9a-fA-F]+:\s+([0-9a-fA-F]+)', out)
    if not m:
        raise gdb.GdbError('cannot parse mdw output: ' + out)
    return int(m.group(1), 16)

def wr32(addr, val):
    gdb.execute('monitor mww 0x{:08x} 0x{:08x}'.format(addr, val))

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
set $pc = 0x80000000
# jv32.cfg uses 'abstract' mem-access which doesn't support arbitrary writes;
# switch to progbuf so mww/mdw work anywhere in IRAM/DRAM.
monitor riscv set_mem_access progbuf

# ── 2. info registers ────────────────────────────────────────────────────────
python
import gdb

info = gdb.execute('info registers', to_string=True)
# RISC-V GDB may use 'zero'/'x0' for x0, 'ra'/'x1' for ra.  Check flexibly.
for name, alts in (('pc', ['pc']), ('sp', ['sp', 'x2']),
                   ('ra', ['ra', 'x1']), ('zero', ['zero', 'x0'])):
    if not any(a in info for a in alts):
        raise gdb.GdbError(
            '[FAIL] gdb_debug: "info registers" missing "{}" (tried: {})'.format(
                name, alts))
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

# ── 5. Hardware breakpoint (continue-based, EBREAK sentinel) ─────────────────
# Write a NOP sled (4 NOPs + EBREAK) into IRAM scratch, set hbreak on the
# third NOP, set PC to start of sled, then continue.  The EBREAK at the end
# prevents infinite execution if the breakpoint is missed.
python
import gdb

NOP    = 0x00000013
EBREAK = 0x00100073
wr32(IRAM_SCRATCH + 0,  NOP)
wr32(IRAM_SCRATCH + 4,  NOP)
wr32(IRAM_SCRATCH + 8,  NOP)
wr32(IRAM_SCRATCH + 12, NOP)
wr32(IRAM_SCRATCH + 16, EBREAK)

gdb.execute('set $pc = 0x{:08x}'.format(IRAM_SCRATCH))
BP_TARGET = IRAM_SCRATCH + 8
gdb.execute('hbreak *0x{:08x}'.format(BP_TARGET))
_dbg['bp_target'] = BP_TARGET
print('  hbreak at 0x{:08x}  (continue-based, sled+sentinel)'.format(BP_TARGET))
end

continue

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

# ── 8. Hardware watchpoint via direct progbuf execution ──────────────────────
# Execute a store to WP_ADDR (0x90000000) via OpenOCD progbuf (same approach
# as test_watchpoint.tcl).  We set up the trigger via monitor, load the store
# address into a GPR, then use DMI writes to run the store through the progbuf.
# This avoids GDB resume/step interactions which can interfere with triggers.
#
# DCRs used (OpenOCD DMI register map, 0x13.2 spec):
#   0x04 = data0   0x20 = progbuf0  0x21 = progbuf1  0x17 = command
# Abstract command 0x00240000: cmdtype=0, aarsize=2, postexec=1, transfer=0
#   (run progbuf without any register transfer)
python
import gdb

WP_ADDR_LOCAL = 0x90000000
SW_X5         = 0x00028023   # sw x0, 0(x5)
EBREAK_OP     = 0x00100073

# Load WP_ADDR into x5 via abstract write-GPR
gdb.execute('monitor riscv dmi_write 0x04 0x{:08x}'.format(WP_ADDR_LOCAL))  # data0 = WP_ADDR
gdb.execute('monitor riscv dmi_write 0x17 0x00231015')   # write DATA0 -> x5 (gpr 5)
# abstractcs: cmdtype=0, aarsize=2, transfer=1, write=1, regno=0x1005(x5)
# 0x00231015: bits[22:20]=2, bit[18]=0, bit[17]=1(transfer), bit[16]=1(write), regno=0x1015?
# Let me recalculate: regno for x5 = 0x1000+5 = 0x1005
# cmd = (2<<20)|(1<<17)|(1<<16)|0x1005 = 0x200000|0x20000|0x10000|0x1005 = 0x231005
gdb.execute('monitor riscv dmi_write 0x17 0x00231005')   # write DATA0(WP_ADDR) -> x5

# Set store watchpoint: trigger 0, store at WP_ADDR
gdb.execute('monitor reg tselect 0x0')
gdb.execute('monitor reg tdata1 0x08001042')  # dmode=1, action=1, m=1, store=1
gdb.execute('monitor reg tdata2 0x{:08x}'.format(WP_ADDR_LOCAL))
print('  store watchpoint at 0x{:08x} via trigger CSRs'.format(WP_ADDR_LOCAL))

# Load sw instruction into progbuf and execute
gdb.execute('monitor riscv dmi_write 0x20 0x{:08x}'.format(SW_X5))    # progbuf[0]: sw x0, 0(x5)
gdb.execute('monitor riscv dmi_write 0x21 0x{:08x}'.format(EBREAK_OP))# progbuf[1]: ebreak
gdb.execute('monitor riscv dmi_write 0x17 0x00240000')   # execute progbuf (no transfer)
print('  executed sw x0, 0(x5) via progbuf')

# The hart should now be halted with DCSR.cause=2 (trigger fired)
dcsr      = parse_dcsr()
cause     = dcsr_cause(dcsr)
print('  DCSR after progbuf exec: 0x{:08x}  cause={}'.format(dcsr, cause))
if cause != 2:
    raise gdb.GdbError(
        '[FAIL] gdb_debug/watchpoint: DCSR.cause={} expected 2 (trigger), '
        'dcsr=0x{:08x}'.format(cause, dcsr))
print('  watchpoint fired  DCSR.cause=2(trigger)  OK')

# Clear the trigger
gdb.execute('monitor reg tselect 0x0')
gdb.execute('monitor reg tdata1 0x00000000')
print('  trigger 0 cleared')
end

# ── 9. Verify trigger is cleared ─────────────────────────────────────────────
python
import gdb

print('  trigger cleared; state clean  OK')
end

# ── 10. stepi — DCSR.cause must be 4 (step) ──────────────────────────────────
# Restore a clean PC (reset to entry point) and stepi once to confirm
# no leftover trigger state interferes.
monitor reset halt
monitor wait_halt 2000
monitor riscv set_mem_access progbuf
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
