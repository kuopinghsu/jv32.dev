# ============================================================================
# File   : mem_test_dram.gdb
# Project: JV32 RISC-V SoC – FPGA JTAG
# Brief  : DRAM word/halfword/byte access test via abstract memory path (~15 min)
#
# Test regions:
#   Word patterns   : 0x9001E000 – 0x9001EFFF  (4 KB = 1024 words)
#   Byte/hw sub-test: 0x9001F000 – 0x9001F03F  (64 B = 16 words)
#
# Uses GDB native {type}addr memory access (abstract memory command path in
# jv32_dtm).  Byte and halfword accesses exercise the byte-enable generation
# logic (CMD_ACCESS_MEM aamsize=0/1) for all four byte lanes and both
# halfword lanes.
#
# Tests:
#   1. Walking-1       : 32 words
#   2. Walking-0       : 32 words
#   3. Address unique  : 1024 words × 4 passes – catches address-aliasing
#   4. Checkerboard    : 1024 words × 4 passes – inter-cell coupling
#   5. Inv-address     : 1024 words – bitwise complement of address pattern
#   6. Pseudo-random   : 1024 words – XOR-shift hash seeded per word index
#   7. Byte lanes      : write each byte lane individually, verify word;
#                        then read back byte-by-byte  (16 words × 4 lanes)
#   8. Halfword lanes  : write each halfword lane individually, verify word;
#                        then read back halfword-by-halfword  (16 words × 2 lanes)
#
# Usage:
#   # Terminal 1
#   openocd -f fpga/jtag/jv32_fpga_jtag.cfg
#   # Terminal 2
#   riscv64-unknown-elf-gdb -q -x fpga/tests/mem_test_dram.gdb
# ============================================================================

set confirm off
set pagination off

set mem inaccessible-by-default on
mem 0x90000000 0x90020000 rw

target extended-remote :3333

python

import gdb

TEST_BASE     = 0x9001E000    # 4 KB word test window (last 8 KB of DRAM)
BYTE_BASE     = 0x9001F000    # 64 B byte/halfword window (after word region)
WORD_COUNT    = 1024
STRESS_PASSES = 4
MAX_ERRORS    = 8

# ── memory helpers ────────────────────────────────────────────────────────────

def wr32(addr, val):
    gdb.execute("set {int}0x%08x = 0x%08x" % (addr, val), to_string=True)

def rd32(addr):
    return int(gdb.parse_and_eval("{unsigned int}0x%08x" % addr)) & 0xFFFFFFFF

def wr8(addr, val):
    # GDB {char} write – exercises aamsize=0 byte-enable in jv32_dtm
    gdb.execute("set {char}0x%08x = 0x%02x" % (addr, val & 0xFF), to_string=True)

def rd8(addr):
    return int(gdb.parse_and_eval("{unsigned char}0x%08x" % addr)) & 0xFF

def wr16(addr, val):
    # GDB {short} write – exercises aamsize=1 halfword-enable in jv32_dtm
    gdb.execute("set {short}0x%08x = 0x%04x" % (addr, val & 0xFFFF), to_string=True)

def rd16(addr):
    return int(gdb.parse_and_eval("{unsigned short}0x%08x" % addr)) & 0xFFFF

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
    x = xorshift32(x ^ 0x5A5A5A5A)
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
print("       Word region : 0x%08x – 0x%08x  (%d words, %d-pass stress)"
      % (TEST_BASE, TEST_BASE + WORD_COUNT * 4 - 1, WORD_COUNT, STRESS_PASSES))
print("       Byte/hw rgn : 0x%08x – 0x%08x" % (BYTE_BASE, BYTE_BASE + 63))
print("")

# ── Phase 1: Walking-1 ────────────────────────────────────────────────────────
print("[1/8] Walking-1  (32 words, 1 pass) ...")
e = run_phase(lambda i: (1 << (i & 31)) & 0xFFFFFFFF, 32)
print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
total_errors += e

# ── Phase 2: Walking-0 ────────────────────────────────────────────────────────
print("[2/8] Walking-0  (32 words, 1 pass) ...")
e = run_phase(lambda i: (~(1 << (i & 31))) & 0xFFFFFFFF, 32)
print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
total_errors += e

# ── Phase 3: Address-unique (stress) ─────────────────────────────────────────
print("[3/8] Address pattern  (%d words, %d passes) ..." % (WORD_COUNT, STRESS_PASSES))
e = run_phase(lambda i: ((TEST_BASE + i * 4) ^ 0x5A5A5A5A) & 0xFFFFFFFF,
              WORD_COUNT, STRESS_PASSES)
print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
total_errors += e

# ── Phase 4: Checkerboard (stress) ───────────────────────────────────────────
print("[4/8] Checkerboard  (%d words, %d passes) ..." % (WORD_COUNT, STRESS_PASSES))
e = run_phase(lambda i: 0xAAAAAAAA if (i & 1) == 0 else 0x55555555,
              WORD_COUNT, STRESS_PASSES)
print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
total_errors += e

# ── Phase 5: Inverse-address ──────────────────────────────────────────────────
print("[5/8] Inv-address  (%d words, 1 pass) ..." % WORD_COUNT)
e = run_phase(lambda i: (~((TEST_BASE + i * 4) ^ 0x5A5A5A5A)) & 0xFFFFFFFF,
              WORD_COUNT)
print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
total_errors += e

# ── Phase 6: Pseudo-random ───────────────────────────────────────────────────
print("[6/8] Pseudo-random  (%d words, 1 pass) ..." % WORD_COUNT)
e = run_phase(prand, WORD_COUNT)
print("      %s  (%d error(s))" % ("OK" if e == 0 else "FAIL", e))
total_errors += e

# ── Phase 7: Byte lanes (all four lanes, 16 word addresses) ──────────────────
# For each word address and each byte lane:
#   a) zero the word, write one byte via wr8, read back the full word and
#      confirm only that lane changed.
#   b) read back the byte via rd8 and confirm it matches what was written.
print("[7/8] Byte lane access  (4 lanes × 16 addrs @ 0x%08x) ..." % BYTE_BASE)
byte_err = 0
BYTE_VALS = [0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
             0x29, 0x3A, 0x4B, 0x5C, 0x6D, 0x7E, 0x8F, 0x90]
for i in range(16):
    word_addr = BYTE_BASE + i * 4
    for lane in range(4):
        bv = (BYTE_VALS[i] + lane * 0x11) & 0xFF
        byte_addr = word_addr + lane
        wr32(word_addr, 0x00000000)
        wr8(byte_addr, bv)
        word = rd32(word_addr)
        exp_word = bv << (lane * 8)
        if word != exp_word:
            print("      [FAIL] byte @ 0x%08x lane=%d  wr 0x%02x  "
                  "word=0x%08x  exp 0x%08x" % (byte_addr, lane, bv, word, exp_word))
            byte_err += 1
        got_byte = rd8(byte_addr)
        if got_byte != bv:
            print("      [FAIL] rd8  @ 0x%08x lane=%d  wr 0x%02x  rd 0x%02x"
                  % (byte_addr, lane, bv, got_byte))
            byte_err += 1
print("      %s  (%d error(s))" % ("OK" if byte_err == 0 else "FAIL", byte_err))
total_errors += byte_err

# ── Phase 8: Halfword lanes (both lanes, 16 word addresses) ──────────────────
# For each word address and each halfword lane (offset 0 = bits[15:0],
# offset 2 = bits[31:16]):
#   a) zero the word, write one halfword via wr16, verify word.
#   b) read back halfword via rd16 and verify.
print("[8/8] Halfword lane access  (2 lanes × 16 addrs @ 0x%08x) ..." % BYTE_BASE)
hw_err = 0
HW_VALS = [0x1234, 0x5678, 0x9ABC, 0xDEF0, 0xFEDC, 0xBA98, 0x7654, 0x3210,
           0x1111, 0x2222, 0x3333, 0x4444, 0x5555, 0x6666, 0x7777, 0x8888]
for i in range(16):
    word_addr = BYTE_BASE + i * 4
    for lane in range(2):
        hv = (HW_VALS[i] ^ (lane * 0x1111)) & 0xFFFF
        hw_addr = word_addr + lane * 2
        wr32(word_addr, 0x00000000)
        wr16(hw_addr, hv)
        word = rd32(word_addr)
        exp_word = hv << (lane * 16)
        if word != exp_word:
            print("      [FAIL] hw   @ 0x%08x lane=%d  wr 0x%04x  "
                  "word=0x%08x  exp 0x%08x" % (hw_addr, lane, hv, word, exp_word))
            hw_err += 1
        got_hw = rd16(hw_addr)
        if got_hw != hv:
            print("      [FAIL] rd16 @ 0x%08x lane=%d  wr 0x%04x  rd 0x%04x"
                  % (hw_addr, lane, hv, got_hw))
            hw_err += 1
print("      %s  (%d error(s))" % ("OK" if hw_err == 0 else "FAIL", hw_err))
total_errors += hw_err

# ── Result ───────────────────────────────────────────────────────────────────
print("")
if total_errors == 0:
    print("[PASS] DRAM memory test passed  (0 errors)")
else:
    print("[FAIL] DRAM memory test: %d error(s)" % total_errors)
    gdb.execute("quit 1")

end

quit
