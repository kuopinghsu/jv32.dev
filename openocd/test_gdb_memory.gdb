# ============================================================================
# GDB test: gdb_memory — memory read/write via GDB expressions
#
# Connection is established by the Makefile before sourcing this script.
#
# Uses DRAM (0x90000000) for read/write tests — writable data RAM that is
# separate from the instruction RAM so test writes cannot corrupt the running
# program.
#
# Verifies:
#   1. 32-bit word write + read-back.
#   2. 16-bit halfword write + read-back.
#   3.  8-bit byte write + read-back.
#   4. Byte-level boundary: two adjacent bytes in one word.
#   5. Burst: 8-word block write + read-back (verifies no address wrap).
#   6. Zero-fill: write 0 over a region, verify all zeros.
#   7. IRAM readable: boot instructions are non-zero.
#   8. Write / read-back at DRAM end-of-region (0x90007FF0).
# ============================================================================

# ── Halt before any memory access ────────────────────────────────────────────
monitor halt
monitor wait_halt 2000

# Allow GDB to access any address within IRAM/DRAM, not just ELF LOAD segments.
set mem inaccessible-by-default off
mem 0x80000000 0x80020000 rw
mem 0x90000000 0x90020000 rw

# jv32.cfg uses 'abstract' mem-access which does not support arbitrary memory
# writes via the GDB M packet.  Switch to 'progbuf' so all GDB set/read
# memory operations go through the program buffer path.
monitor riscv set_mem_access progbuf

# ── Shared Python helpers ─────────────────────────────────────────────────────
python
import gdb

BASE  = 0x90000000   # start of writable DRAM
IRAM  = 0x80000000   # start of IRAM (read only for this test)

def wr32(addr, val):
    gdb.execute('set {{unsigned int}}{} = {}'.format(addr, val))

def rd32(addr):
    return int(gdb.parse_and_eval('*(unsigned int*){}'.format(addr))) & 0xFFFFFFFF

def wr16(addr, val):
    gdb.execute('set {{unsigned short}}{} = {}'.format(addr, val))

def rd16(addr):
    return int(gdb.parse_and_eval('*(unsigned short*){}'.format(addr))) & 0xFFFF

def wr8(addr, val):
    gdb.execute('set {{unsigned char}}{} = {}'.format(addr, val))

def rd8(addr):
    return int(gdb.parse_and_eval('*(unsigned char*){}'.format(addr))) & 0xFF

def check(label, got, expected):
    if got != expected:
        raise gdb.GdbError(
            '[FAIL] {}: expected=0x{:08x} got=0x{:08x}'.format(
                label, expected, got))
    print('  {:30s}: 0x{:08x}  OK'.format(label, got))

end

# ── 1. 32-bit word write / read-back ─────────────────────────────────────────
python
import gdb

ADDR = BASE
wr32(ADDR, 0xDEADBEEF)
v = rd32(ADDR)
check('word write/read [0x{:08x}]'.format(ADDR), v, 0xDEADBEEF)

wr32(ADDR, 0x12345678)
v = rd32(ADDR)
check('word overwrite   [0x{:08x}]'.format(ADDR), v, 0x12345678)
end

# ── 2. 16-bit halfword write / read-back ─────────────────────────────────────
python
import gdb

ADDR_LO = BASE + 0x10
ADDR_HI = BASE + 0x12
wr16(ADDR_LO, 0xABCD)
v_lo = rd16(ADDR_LO)
check('halfword lo [0x{:08x}]'.format(ADDR_LO), v_lo, 0xABCD)

wr16(ADDR_HI, 0x1234)
v_hi = rd16(ADDR_HI)
check('halfword hi [0x{:08x}]'.format(ADDR_HI), v_hi, 0x1234)

# Verify the two halfwords coexist correctly in the same word
full = rd32(ADDR_LO)
expected_full = 0x1234ABCD   # little-endian: lo at low address
check('halfword word  [0x{:08x}]'.format(ADDR_LO), full, expected_full)
end

# ── 3. 8-bit byte write / read-back ──────────────────────────────────────────
python
import gdb

for i, bval in enumerate([0xA1, 0xB2, 0xC3, 0xD4]):
    addr = BASE + 0x20 + i
    wr8(addr, bval)
    got = rd8(addr)
    check('byte[{}] [0x{:08x}]'.format(i, addr), got, bval)

# Verify the 4 bytes assembled into one word (little-endian)
word_addr = BASE + 0x20
full = rd32(word_addr)
expected = 0xD4C3B2A1
check('byte->word    [0x{:08x}]'.format(word_addr), full, expected)
end

# ── 4. Byte boundary across a word boundary ──────────────────────────────────
python
import gdb

# Write bytes that straddle two 4-byte words: bytes at offset 3 and 4
ADDR3 = BASE + 0x33   # last byte of first word
ADDR4 = BASE + 0x34   # first byte of second word
wr8(ADDR3, 0x77)
wr8(ADDR4, 0x88)
check('byte boundary @+3 [0x{:08x}]'.format(ADDR3), rd8(ADDR3), 0x77)
check('byte boundary @+4 [0x{:08x}]'.format(ADDR4), rd8(ADDR4), 0x88)
end

# ── 5. 8-word burst write / read-back ────────────────────────────────────────
python
import gdb

BURST_BASE = BASE + 0x40
PATTERN = [0x00112233, 0x44556677, 0x8899AABB, 0xCCDDEEFF,
           0x01020304, 0x05060708, 0x090A0B0C, 0x0D0E0F10]
for i, val in enumerate(PATTERN):
    wr32(BURST_BASE + i * 4, val)

for i, expected in enumerate(PATTERN):
    got = rd32(BURST_BASE + i * 4)
    check('burst[{}] [0x{:08x}]'.format(i, BURST_BASE + i * 4), got, expected)
print('  burst 8-word write/read-back: OK')
end

# ── 6. Zero-fill and verify ───────────────────────────────────────────────────
python
import gdb

ZERO_BASE = BASE + 0x80
for i in range(8):
    wr32(ZERO_BASE + i * 4, 0xFFFFFFFF)
for i in range(8):
    wr32(ZERO_BASE + i * 4, 0x00000000)
for i in range(8):
    got = rd32(ZERO_BASE + i * 4)
    check('zero[{}] [0x{:08x}]'.format(i, ZERO_BASE + i * 4), got, 0x00000000)
print('  zero-fill 8 words: OK')
end

# ── 7. IRAM readable — boot instructions must be non-zero ────────────────────
python
import gdb

non_zero = 0
for i in range(8):
    v = rd32(IRAM + i * 4)
    print('  IRAM[0x{:08x}] = 0x{:08x}'.format(IRAM + i * 4, v))
    if v != 0:
        non_zero += 1
if non_zero == 0:
    raise gdb.GdbError('[FAIL] gdb_memory: all 8 IRAM words at 0x80000000 are zero')
print('  IRAM readable ({}/8 non-zero)  OK'.format(non_zero))
end

# ── 8. Write / read-back near DRAM upper bound ───────────────────────────────
python
import gdb

FAR_ADDR = 0x90007FF0
wr32(FAR_ADDR,     0xFEEDFACE)
wr32(FAR_ADDR + 4, 0xCAFEBABE)
check('far DRAM [0x{:08x}]'.format(FAR_ADDR),     rd32(FAR_ADDR),     0xFEEDFACE)
check('far DRAM [0x{:08x}]'.format(FAR_ADDR + 4), rd32(FAR_ADDR + 4), 0xCAFEBABE)
end

printf "[PASS] gdb_memory\n"
