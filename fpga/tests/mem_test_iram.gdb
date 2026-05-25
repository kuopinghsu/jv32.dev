# ============================================================================
# File   : mem_test_iram.gdb
# Project: JV32 RISC-V SoC – FPGA JTAG
# Brief  : IRAM word-access memory test via abstract memory path (~2 min)
#
# Test region: 0x8001E000 – 0x8001E3FF  (1 KB = 256 words)
#   Located in the last 8 KB of IRAM (128 KB total) to avoid the firmware
#   code area at the base.  Firmware is never resumed from this script.
#
# Uses GDB native {type}addr memory access, which routes through the RISC-V
# Debug Module abstract memory command (CMD_ACCESS_MEM, §3.5.6).  This is
# a different path from the SBA path tested by mem_connect_check.gdb.
#
# Tests:
#   1. Walking-1     : 32 words  – one word per bit position (SA0/SA1 faults)
#   2. Walking-0     : 32 words  – complement of walking-1
#   3. Address unique: 256 words – word[n] = (BASE+n*4) XOR 0xA5A5A5A5
#                                  catches address-aliasing / stuck addr lines
#   4. Checkerboard  : 256 words – alternating 0xAAAAAAAA / 0x55555555
#                                  catches inter-cell coupling
#
# Usage:
#   # Terminal 1
#   openocd -f fpga/jtag/jv32_fpga_jtag.cfg
#   # Terminal 2
#   riscv64-unknown-elf-gdb -q -x fpga/tests/mem_test_iram.gdb
# ============================================================================

set confirm off
set pagination off

target extended-remote :3333

set mem inaccessible-by-default off
mem 0x80000000 0x80020000 rw

python

import gdb

TEST_BASE  = 0x8001E000    # 1 KB test window at end of IRAM
WORD_COUNT = 256           # words per sweep for address/checkerboard patterns
MAX_ERRORS = 8             # cap reported errors per phase to keep output readable

def wr32(addr, val):
    # GDB native write – routes through abstract memory command in jv32_dtm
    gdb.execute("set {int}0x%08x = 0x%08x" % (addr, val), to_string=True)

def rd32(addr):
    return int(gdb.parse_and_eval("{unsigned int}0x%08x" % addr)) & 0xFFFFFFFF

def run_phase(name, pattern_fn, count):
    """Write all words, then read all back.  Returns error count."""
    errors = 0
    for i in range(count):
        wr32(TEST_BASE + i * 4, pattern_fn(i))
    for i in range(count):
        exp = pattern_fn(i)
        got = rd32(TEST_BASE + i * 4)
        if got != exp:
            addr = TEST_BASE + i * 4
            print("      [FAIL] 0x%08x  exp 0x%08x  got 0x%08x" % (addr, exp, got))
            errors += 1
            if errors >= MAX_ERRORS:
                print("      ... (further errors suppressed for this phase)")
                break
    return errors

total_errors = 0

# ── Halt ─────────────────────────────────────────────────────────────────────
print("[INIT] Halting hart ...")
gdb.execute("monitor halt")
gdb.execute("monitor wait_halt 2000")
pc = int(gdb.parse_and_eval("$pc")) & 0xFFFFFFFF
print("       PC = 0x%08x" % pc)
print("       Test region: 0x%08x – 0x%08x" % (TEST_BASE, TEST_BASE + WORD_COUNT * 4 - 1))
print("")

# ── Phase 1: Walking-1 (32 words) ────────────────────────────────────────────
print("[1/4] Walking-1  (32 words @ 0x%08x) ..." % TEST_BASE)
e = run_phase("walking-1",
              lambda i: (1 << (i & 31)) & 0xFFFFFFFF,
              32)
print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
total_errors += e

# ── Phase 2: Walking-0 (32 words) ────────────────────────────────────────────
print("[2/4] Walking-0  (32 words @ 0x%08x) ..." % TEST_BASE)
e = run_phase("walking-0",
              lambda i: (~(1 << (i & 31))) & 0xFFFFFFFF,
              32)
print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
total_errors += e

# ── Phase 3: Address-unique pattern (256 words) ───────────────────────────────
print("[3/4] Address pattern  (256 words @ 0x%08x) ..." % TEST_BASE)
e = run_phase("address",
              lambda i: ((TEST_BASE + i * 4) ^ 0xA5A5A5A5) & 0xFFFFFFFF,
              WORD_COUNT)
print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
total_errors += e

# ── Phase 4: Checkerboard (256 words) ────────────────────────────────────────
print("[4/4] Checkerboard  (256 words @ 0x%08x) ..." % TEST_BASE)
e = run_phase("checkerboard",
              lambda i: 0xAAAAAAAA if (i & 1) == 0 else 0x55555555,
              WORD_COUNT)
print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
total_errors += e

# ── Result ───────────────────────────────────────────────────────────────────
print("")
if total_errors == 0:
    print("[PASS] IRAM memory test passed  (0 errors)")
else:
    print("[FAIL] IRAM memory test: %d error(s)" % total_errors)
    gdb.execute("quit 1")

end

quit
