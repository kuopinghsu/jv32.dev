# ============================================================================
# File   : mem_test_iram.gdb
# Project: JV32 RISC-V SoC – FPGA JTAG
# Brief  : IRAM word-access memory test via abstract memory path (~10 min)
#
# Test region: 0x8001E000 – 0x8001EFFF  (4 KB = 1024 words)
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
#   3. Address unique: 1024 words × 4 passes – catches address-aliasing
#   4. Checkerboard  : 1024 words × 4 passes – inter-cell coupling
#   5. Inv-address   : 1024 words – bitwise complement of address pattern
#   6. Pseudo-random : 1024 words – XOR-shift hash seeded per word index
#
# Usage:
#   # Terminal 1
#   openocd -f fpga/jtag/jv32_fpga_jtag.cfg
#   # Terminal 2
#   riscv64-unknown-elf-gdb -q -x fpga/tests/mem_test_iram.gdb
# ============================================================================

set confirm off
set pagination off

set mem inaccessible-by-default on
mem 0x80000000 0x80020000 rw

target extended-remote :3333

python

import gdb

TEST_BASE     = 0x8001E000    # 4 KB test window (last 8 KB of IRAM)
WORD_COUNT    = 1024          # words per sweep
STRESS_PASSES = 4             # repeat count for address-unique and checkerboard
MAX_ERRORS    = 8

def wr32(addr, val):
    # GDB native write – routes through abstract memory command in jv32_dtm
    gdb.execute("set {int}0x%08x = 0x%08x" % (addr, val), to_string=True)

def rd32(addr):
    return int(gdb.parse_and_eval("{unsigned int}0x%08x" % addr)) & 0xFFFFFFFF

def xorshift32(x):
    """One step of a 32-bit XOR-shift PRNG."""
    x ^= (x << 13) & 0xFFFFFFFF
    x ^= (x >> 17) & 0xFFFFFFFF
    x ^= (x <<  5) & 0xFFFFFFFF
    return x & 0xFFFFFFFF

def prand(i):
    """Deterministic pseudo-random word for index i (XOR-shift hash)."""
    x = (i + 1) & 0xFFFFFFFF
    x = xorshift32(x)
    x = xorshift32(x ^ 0xDEADBEEF)
    x = xorshift32(x)
    return x if x != 0 else 0xCAFEBABE

def run_phase(pattern_fn, count, passes=1):
    """Write all words then read all back, repeated <passes> times.
    Returns total error count across all passes."""
    errors = 0
    for p in range(passes):
        for i in range(count):
            wr32(TEST_BASE + i * 4, pattern_fn(i))
        for i in range(count):
            exp = pattern_fn(i)
            got = rd32(TEST_BASE + i * 4)
            if got != exp:
                addr = TEST_BASE + i * 4
                print("      [FAIL] pass %d  0x%08x  exp 0x%08x  got 0x%08x"
                      % (p, addr, exp, got))
                errors += 1
                if errors >= MAX_ERRORS:
                    print("      ... (further errors suppressed)")
                    return errors
    return errors

total_errors = 0

# ── Halt ─────────────────────────────────────────────────────────────────────
print("[INIT] Halting hart ...")
gdb.execute("monitor halt")
gdb.execute("monitor wait_halt 2000")
pc = int(gdb.parse_and_eval("$pc")) & 0xFFFFFFFF
print("       PC = 0x%08x" % pc)
print("       Test region : 0x%08x – 0x%08x  (%d words, %d-pass stress)"
      % (TEST_BASE, TEST_BASE + WORD_COUNT * 4 - 1, WORD_COUNT, STRESS_PASSES))
print("")

# ── Phase 1: Walking-1 ────────────────────────────────────────────────────────
print("[1/6] Walking-1  (32 words, 1 pass) ...")
e = run_phase(lambda i: (1 << (i & 31)) & 0xFFFFFFFF, 32)
print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
total_errors += e

# ── Phase 2: Walking-0 ────────────────────────────────────────────────────────
print("[2/6] Walking-0  (32 words, 1 pass) ...")
e = run_phase(lambda i: (~(1 << (i & 31))) & 0xFFFFFFFF, 32)
print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
total_errors += e

# ── Phase 3: Address-unique (stress) ─────────────────────────────────────────
print("[3/6] Address pattern  (%d words, %d passes) ..." % (WORD_COUNT, STRESS_PASSES))
e = run_phase(lambda i: ((TEST_BASE + i * 4) ^ 0xA5A5A5A5) & 0xFFFFFFFF,
              WORD_COUNT, STRESS_PASSES)
print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
total_errors += e

# ── Phase 4: Checkerboard (stress) ───────────────────────────────────────────
print("[4/6] Checkerboard  (%d words, %d passes) ..." % (WORD_COUNT, STRESS_PASSES))
e = run_phase(lambda i: 0xAAAAAAAA if (i & 1) == 0 else 0x55555555,
              WORD_COUNT, STRESS_PASSES)
print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
total_errors += e

# ── Phase 5: Inverse-address ──────────────────────────────────────────────────
print("[5/6] Inv-address  (%d words, 1 pass) ..." % WORD_COUNT)
e = run_phase(lambda i: (~((TEST_BASE + i * 4) ^ 0xA5A5A5A5)) & 0xFFFFFFFF,
              WORD_COUNT)
print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
total_errors += e

# ── Phase 6: Pseudo-random ───────────────────────────────────────────────────
print("[6/6] Pseudo-random  (%d words, 1 pass) ..." % WORD_COUNT)
e = run_phase(prand, WORD_COUNT)
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
