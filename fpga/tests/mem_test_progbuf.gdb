# mem_test_progbuf.gdb – IRAM and DRAM memory test via program buffer path
#
# Brief  : Word-access memory test using the Debug Module program buffer (~20 min)
#
# Test regions (both IRAM and DRAM):
#   IRAM : 0x8001E000 – 0x8001EFFF  (4 KB = 1024 words)
#   DRAM : 0x9001E000 – 0x9001EFFF  (4 KB = 1024 words)
#
# The progbuf path differs from both the SBA (mem_connect_check.gdb) and
# abstract-command (mem_test_iram/dram.gdb) paths: OpenOCD writes a
# lw/sw + ebreak pair into the 2-word program buffer and executes it via
# the hart.  This exercises the jv32 execute-via-progbuf pipeline.
#
# The script forces progbuf-only mode after halting via:
#   monitor riscv set_mem_access progbuf
# and restores sysbus+abstract on exit.
#
# Tests (6 phases per region):
#   1. Walking-1     : 32 words  – one word per bit position (SA0/SA1 faults)
#   2. Walking-0     : 32 words  – complement of walking-1
#   3. Address unique: 1024 words × 4 passes – catches address-aliasing
#   4. Checkerboard  : 1024 words × 4 passes – inter-cell coupling
#   5. Inv-address   : 1024 words – bitwise complement of address pattern
#   6. Pseudo-random : 1024 words – XOR-shift hash seeded per word index

set confirm off
set pagination off

# Memory access declarations must precede target connect to prevent GDB from
# probing unmapped addresses (PC=0x0 without firmware → poisons DM state).
set mem inaccessible-by-default on
mem 0x80000000 0x80020000 rw
mem 0x90000000 0x90020000 rw

target extended-remote :3333

python

import gdb

IRAM_BASE     = 0x8001E000
DRAM_BASE     = 0x9001E000
WORD_COUNT    = 1024
STRESS_PASSES = 4
MAX_ERRORS    = 8

# ── memory helpers ────────────────────────────────────────────────────────────

def wr32(addr, val):
    # GDB native write – routes through program buffer when progbuf mode active
    gdb.execute("set {int}0x%08x = 0x%08x" % (addr, val), to_string=True)

def rd32(addr):
    return int(gdb.parse_and_eval("{unsigned int}0x%08x" % addr)) & 0xFFFFFFFF

def xorshift32(x):
    """One step of a 32-bit XOR-shift PRNG."""
    x ^= (x << 13) & 0xFFFFFFFF
    x ^= (x >> 17) & 0xFFFFFFFF
    x ^= (x <<  5) & 0xFFFFFFFF
    return x & 0xFFFFFFFF

def prand(base, i):
    """Deterministic pseudo-random word for (base, index) pair."""
    seed = ((base >> 12) ^ 0xBEEFCAFE) & 0xFFFFFFFF
    x = (i + 1) & 0xFFFFFFFF
    x = xorshift32(x ^ seed)
    x = xorshift32(x ^ 0xDEAD1234)
    x = xorshift32(x)
    return x if x != 0 else 0xCAFEBABE

def run_phase(base, pattern_fn, count, passes=1):
    """Write all words then read all back, repeated <passes> times.
    Returns total error count across all passes."""
    errors = 0
    for p in range(passes):
        for i in range(count):
            wr32(base + i * 4, pattern_fn(i))
        for i in range(count):
            exp = pattern_fn(i)
            got = rd32(base + i * 4)
            if got != exp:
                addr = base + i * 4
                print("      [FAIL] pass %d  0x%08x  exp 0x%08x  got 0x%08x"
                      % (p, addr, exp, got))
                errors += 1
                if errors >= MAX_ERRORS:
                    print("      ... (further errors suppressed)")
                    return errors
    return errors

def test_region(label, base):
    """Run all 6 memory test phases for a given region base address.
    Returns total error count for the region."""
    print("=" * 60)
    print("[%s] Test region : 0x%08x – 0x%08x  (%d words, %d-pass stress)"
          % (label, base, base + WORD_COUNT * 4 - 1, WORD_COUNT, STRESS_PASSES))
    print("=" * 60)

    errs = 0

    print("[1/6] Walking-1  (32 words, 1 pass) ...")
    e = run_phase(base, lambda i: (1 << (i & 31)) & 0xFFFFFFFF, 32)
    print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
    errs += e

    print("[2/6] Walking-0  (32 words, 1 pass) ...")
    e = run_phase(base, lambda i: (~(1 << (i & 31))) & 0xFFFFFFFF, 32)
    print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
    errs += e

    print("[3/6] Address pattern  (%d words, %d passes) ..."
          % (WORD_COUNT, STRESS_PASSES))
    e = run_phase(base,
                  lambda i: ((base + i * 4) ^ 0xA5A5A5A5) & 0xFFFFFFFF,
                  WORD_COUNT, STRESS_PASSES)
    print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
    errs += e

    print("[4/6] Checkerboard  (%d words, %d passes) ..."
          % (WORD_COUNT, STRESS_PASSES))
    e = run_phase(base,
                  lambda i: 0xAAAAAAAA if (i & 1) == 0 else 0x55555555,
                  WORD_COUNT, STRESS_PASSES)
    print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
    errs += e

    print("[5/6] Inv-address  (%d words, 1 pass) ..." % WORD_COUNT)
    e = run_phase(base,
                  lambda i: (~((base + i * 4) ^ 0xA5A5A5A5)) & 0xFFFFFFFF,
                  WORD_COUNT)
    print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
    errs += e

    print("[6/6] Pseudo-random  (%d words, 1 pass) ..." % WORD_COUNT)
    e = run_phase(base, lambda i: prand(base, i), WORD_COUNT)
    print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
    errs += e

    print("")
    return errs

# ── Halt ─────────────────────────────────────────────────────────────────────
print("[INIT] Halting hart ...")
gdb.execute("monitor halt")
gdb.execute("monitor wait_halt 2000")
pc = int(gdb.parse_and_eval("$pc")) & 0xFFFFFFFF
print("       PC = 0x%08x" % pc)
print("       Forcing program-buffer-only memory access path ...")
gdb.execute("monitor riscv set_mem_access progbuf")
print("")

total_errors = 0

total_errors += test_region("IRAM", IRAM_BASE)
total_errors += test_region("DRAM", DRAM_BASE)

# ── Restore default access methods ───────────────────────────────────────────
print("[DONE] Restoring memory access methods to sysbus + abstract ...")
gdb.execute("monitor riscv set_mem_access sysbus abstract")

# ── Result ───────────────────────────────────────────────────────────────────
if total_errors == 0:
    print("[PASS] Program-buffer memory test passed  (0 errors)")
else:
    print("[FAIL] Program-buffer memory test: %d error(s)" % total_errors)
    gdb.execute("quit 1")

end

quit
