# ============================================================================
# GDB test: gdb_zcmp — verify zcmp.elf ran successfully via the magic exit
#                      register, then optionally confirm the exit code.
#
# Connection is established by the Makefile before sourcing this script.
#
# The VPI testbench starts zcmp.elf at simulation time zero.  By the time
# GDB connects (after OpenOCD starts up), the program has run to completion
# and the hart is spinning in jv_exit's while(1){nop} loop.
#
# This script:
#   1. Halts the core.
#   2. Reads the magic exit register at 0x40000004 via the system-bus
#      (monitor mdw) to obtain the jv_exit() argument.
#   3. exit_val == 1  → jv_exit(0) was called → [PASS]
#      exit_val == 0  → jv_exit not reached   → [FAIL]
#      exit_val > 1   → jv_exit(n_fail) called → [FAIL]
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

pc       = int(gdb.parse_and_eval('$pc'))
exit_val = rd32(JV_MAGIC_EXIT)

print('  zcmp: PC=0x{:08x}  magic_exit=0x{:08x}'.format(pc, exit_val))

if exit_val == 1:
    print('  zcmp: jv_exit(0) confirmed — all Zcmp instruction tests passed')
    print('[PASS] gdb_zcmp')
elif exit_val == 0:
    raise gdb.GdbError(
        '[FAIL] gdb_zcmp: magic exit register not written '
        '(PC=0x{:08x}) — zcmp.elf may have faulted before jv_exit'.format(pc))
else:
    n_fail = exit_val >> 1
    raise gdb.GdbError(
        '[FAIL] gdb_zcmp: {} Zcmp test(s) failed '
        '(exit_val=0x{:08x})'.format(n_fail, exit_val))
end
