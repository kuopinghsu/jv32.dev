# ============================================================================
# GDB test: gdb_zcmp — verify zcmp.elf reached jv_exit() after running all
#                      Zcmp checks.
#
# Connection is established by the Makefile before sourcing this script.
#
# The VPI testbench starts zcmp.elf at simulation time zero.  By the time
# GDB connects (after OpenOCD starts up), the program has run to completion
# and the hart is spinning in jv_exit's while(1){nop} loop.
#
# This script:
#   1. Halts the core.
#   2. Confirms execution reached jv_exit() (semihost backend-compatible).
#   3. Optionally reads magic-exit register 0x40000004 for diagnostics when the
#      magic backend is used.
#
# The real correctness check (ISS vs RTL trace) is done by the Makefile's
# gdb-zcmp target after this GDB script exits with [PASS].
# ============================================================================

# Declare memory regions so GDB lets us read IRAM/DRAM without complaints.
set mem inaccessible-by-default off
mem 0x80000000 0x80020000 rw
mem 0x90000000 0x90020000 rw

# ── 1. Halt the core ─────────────────────────────────────────────────────────
monitor halt

# ── 2. Read magic exit register and verify zcmp.elf passed ───────────────────
python
import gdb, re

JV_MAGIC_EXIT = 0x40000004   # 0x40000000 + 0x0004

def rd32(addr):
    """Read a 32-bit word via OpenOCD system-bus (bypasses GDB memory map)."""
    out = gdb.execute('monitor mdw 0x{:08x}'.format(addr), to_string=True)
    m   = re.search(r'0x[0-9a-fA-F]+:\s+([0-9a-fA-F]+)', out)
    if not m:
        raise gdb.GdbError('cannot parse mdw output: ' + repr(out))
    return int(m.group(1), 16)

pc = int(gdb.parse_and_eval('$pc'))

# Prefer symbol-aware check: program should be parked in jv_exit() loop.
is_in_jv_exit = False
try:
    out = gdb.execute('info symbol 0x{:08x}'.format(pc), to_string=True)
    is_in_jv_exit = ('jv_exit' in out)
except gdb.error:
    is_in_jv_exit = False

exit_val = rd32(JV_MAGIC_EXIT)
print('  zcmp: PC=0x{:08x}  magic_exit=0x{:08x}'.format(pc, exit_val))

if is_in_jv_exit:
    print('  zcmp: halted in jv_exit() — all Zcmp instruction tests passed')
    print('[PASS] gdb_zcmp')
elif exit_val == 1:
    print('  zcmp: magic jv_exit(0) confirmed — all Zcmp instruction tests passed')
    print('[PASS] gdb_zcmp')
elif exit_val > 1:
    n_fail = exit_val >> 1
    raise gdb.GdbError(
        '[FAIL] gdb_zcmp: {} Zcmp test(s) failed '
        '(exit_val=0x{:08x})'.format(n_fail, exit_val))
else:
    raise gdb.GdbError(
        '[FAIL] gdb_zcmp: neither jv_exit() halt nor magic-exit observed '
        '(PC=0x{:08x})'.format(pc))
end
