# ============================================================================
# GDB test: gdb_memory — comprehensive memory access test
#
# Connection is established by the Makefile before sourcing this script.
#
# Tests all three OpenOCD memory access modes:
#   abstract  — abstract command CMD_ACCESS_MEM (Debug Spec §3.7.1.2)
#   progbuf   — program buffer (CPU executes ld/st, then returns to debug mode)
#   sysbus    — System Bus Access port (DMA-style, CPU not involved)
#
# For each mode, verifies the following access widths and patterns:
#   1-byte   (uint8)  — 4 bytes at consecutive offsets → verify byte values and assembled word
#   2-byte   (uint16) — 2 halfwords, adjacent 16-bit aligned offsets → verify and assembled word
#   4-byte   (uint32) — 2 words write/read-back
#   8-byte   (2×uint32) — two consecutive 32-bit writes (simulating 64-bit block)
#   block    — 8-word (32-byte) burst write + read-back
#
# SBA streaming section (raw DMI monitor commands):
#   SBA block write with sbautoincrement — write 8 words without re-writing SBADDRESS0
#   SBA block read  with sbreadononaddr  — trigger each read via SBADDRESS0 write
#
# Cross-mode consistency:
#   Write via abstract, read via sysbus
#   Write via sysbus,   read via progbuf
#   Write via progbuf,  read via abstract
#
# Memory layout (DRAM 0x90000000–0x9001FFFF):
#   ABSTRACT_BASE = 0x90001000
#   PROGBUF_BASE  = 0x90002000
#   SYSBUS_BASE   = 0x90003000
#   STREAM_BASE   = 0x90004000
#   CROSS_BASE    = 0x90005000
# ============================================================================

# ── Halt before any memory access ────────────────────────────────────────────
monitor halt
monitor wait_halt 2000

# Allow GDB to access any address within IRAM/DRAM, not just ELF LOAD segments.
set mem inaccessible-by-default off
mem 0x80000000 0x80020000 rw
mem 0x90000000 0x90020000 rw

# ── Shared Python helpers ─────────────────────────────────────────────────────
# ── Python helper definitions (loaded once; available in all blocks below) ───
python
import gdb
import re

# Memory regions.
IRAM         = 0x80000000   # instruction RAM (read-only during this test)
ABSTRACT_BASE = 0x90001000  # 4 KB page for abstract mode tests
PROGBUF_BASE  = 0x90002000  # 4 KB page for progbuf mode tests
SYSBUS_BASE   = 0x90003000  # 4 KB page for sysbus mode tests
STREAM_BASE   = 0x90004000  # SBA streaming read/write test area
CROSS_BASE    = 0x90005000  # cross-mode consistency test area

# ── Memory read/write helpers ─────────────────────────────────────────────────
def wr8(addr, val):
    gdb.execute('set {{unsigned char}}0x{:08x} = {:d}'.format(addr, val & 0xFF))

def rd8(addr):
    return int(gdb.parse_and_eval('*(unsigned char*)0x{:08x}'.format(addr))) & 0xFF

def wr16(addr, val):
    gdb.execute('set {{unsigned short}}0x{:08x} = {:d}'.format(addr, val & 0xFFFF))

def rd16(addr):
    return int(gdb.parse_and_eval('*(unsigned short*)0x{:08x}'.format(addr))) & 0xFFFF

def wr32(addr, val):
    gdb.execute('set {{unsigned int}}0x{:08x} = {:d}'.format(addr, val & 0xFFFFFFFF))

def rd32(addr):
    return int(gdb.parse_and_eval('*(unsigned int*)0x{:08x}'.format(addr))) & 0xFFFFFFFF

# ── DMI helpers for SBA streaming (via monitor commands) ─────────────────────
def dmi_write(reg, val):
    gdb.execute('monitor riscv dmi_write 0x{:02x} 0x{:08x}'.format(reg, val & 0xFFFFFFFF))

def dmi_read(reg):
    out = gdb.execute('monitor riscv dmi_read 0x{:02x}'.format(reg), to_string=True)
    m = re.search(r'0x([0-9a-fA-F]+)', out)
    if m:
        return int(m.group(1), 16)
    m = re.match(r'^\s*([0-9a-fA-F]+)\s*$', out)
    if m:
        return int(m.group(1), 16)
    raise gdb.GdbError('dmi_read 0x{:02x}: cannot parse output: {!r}'.format(reg, out))

def mon_delay(ms):
    gdb.execute('monitor after {:d}'.format(ms))

# ── Check helper ─────────────────────────────────────────────────────────────
def check(label, got, expected):
    if got != expected:
        raise gdb.GdbError(
            '[FAIL] gdb_memory: {}: expected=0x{:08x} got=0x{:08x}'.format(
                label, expected, got))
    print('  {:<52s} 0x{:08x}  OK'.format(label, got))

# ── Per-mode test function ────────────────────────────────────────────────────
def test_mode(mode, base):
    """Run 1B/2B/4B/8B/block subtests at 'base' using mem-access mode 'mode'."""
    gdb.execute('monitor riscv set_mem_access {}'.format(mode))
    print('\n[MODE] {} @ 0x{:08x}'.format(mode.upper(), base))

    # ── Subtest 1B: 4 bytes at consecutive offsets, then check assembled word ─
    print('  [1B] byte accesses')
    b_base = base + 0x000
    byte_vals = [0xAA, 0xBB, 0xCC, 0xDD]
    for i, bv in enumerate(byte_vals):
        wr8(b_base + i, bv)
        check('1B wr/rd[{}] @0x{:08x}'.format(i, b_base + i), rd8(b_base + i), bv)
    # Little-endian word: byte0 in bits[7:0], byte3 in bits[31:24]
    check('1B→word32    @0x{:08x}'.format(b_base), rd32(b_base), 0xDDCCBBAA)

    # Byte spanning a word boundary (last byte of word0, first byte of word1)
    wr8(b_base + 3, 0x77)
    wr8(b_base + 4, 0x88)
    check('1B boundary  @0x{:08x}+3'.format(b_base), rd8(b_base + 3), 0x77)
    check('1B boundary  @0x{:08x}+4'.format(b_base), rd8(b_base + 4), 0x88)

    # ── Subtest 2B: 2 halfwords, verify assembled word ─────────────────────
    print('  [2B] halfword accesses')
    h_base = base + 0x010
    wr16(h_base,     0x1234)
    wr16(h_base + 2, 0x5678)
    check('2B lo  @0x{:08x}'.format(h_base),     rd16(h_base),     0x1234)
    check('2B hi  @0x{:08x}'.format(h_base + 2), rd16(h_base + 2), 0x5678)
    # Little-endian: lo halfword at low address → bits[15:0]
    check('2B→word32    @0x{:08x}'.format(h_base), rd32(h_base), 0x56781234)

    # Additional halfword patterns
    wr16(h_base,     0xDEAD)
    wr16(h_base + 2, 0xBEEF)
    check('2B lo2 @0x{:08x}'.format(h_base),     rd16(h_base),     0xDEAD)
    check('2B hi2 @0x{:08x}'.format(h_base + 2), rd16(h_base + 2), 0xBEEF)
    check('2B→word32b   @0x{:08x}'.format(h_base), rd32(h_base), 0xBEEFDEAD)

    # ── Subtest 4B: two consecutive word write/read-back ─────────────────
    print('  [4B] word accesses')
    w_base = base + 0x020
    wr32(w_base,     0xDEADBEEF)
    wr32(w_base + 4, 0xCAFEBABE)
    check('4B word0 @0x{:08x}'.format(w_base),     rd32(w_base),     0xDEADBEEF)
    check('4B word1 @0x{:08x}'.format(w_base + 4), rd32(w_base + 4), 0xCAFEBABE)
    # Overwrite and re-verify
    wr32(w_base, 0x00000000)
    wr32(w_base, 0xFFFFFFFF)
    check('4B all-ones  @0x{:08x}'.format(w_base), rd32(w_base), 0xFFFFFFFF)
    wr32(w_base, 0xA5A5A5A5)
    check('4B walk0     @0x{:08x}'.format(w_base), rd32(w_base), 0xA5A5A5A5)

    # ── Subtest 8B: two 32-bit writes forming a 64-bit value ─────────────
    print('  [8B] 8-byte (2×word) access')
    q_base = base + 0x030
    # 64-bit value 0x0123456789ABCDEF in little-endian:
    #   word[0] (low) = 0x89ABCDEF, word[1] (high) = 0x01234567
    wr32(q_base,     0x89ABCDEF)
    wr32(q_base + 4, 0x01234567)
    check('8B lo32 @0x{:08x}'.format(q_base),     rd32(q_base),     0x89ABCDEF)
    check('8B hi32 @0x{:08x}'.format(q_base + 4), rd32(q_base + 4), 0x01234567)
    # All-zeros and all-ones
    wr32(q_base, 0x00000000);  wr32(q_base + 4, 0x00000000)
    check('8B zero lo  @0x{:08x}'.format(q_base),     rd32(q_base),     0x00000000)
    check('8B zero hi  @0x{:08x}'.format(q_base + 4), rd32(q_base + 4), 0x00000000)
    wr32(q_base, 0xFFFFFFFF);  wr32(q_base + 4, 0xFFFFFFFF)
    check('8B ones lo  @0x{:08x}'.format(q_base),     rd32(q_base),     0xFFFFFFFF)
    check('8B ones hi  @0x{:08x}'.format(q_base + 4), rd32(q_base + 4), 0xFFFFFFFF)

    # ── Subtest block: 8-word (32-byte) burst write + read-back ──────────
    print('  [block] 8-word burst')
    blk_base = base + 0x040
    pattern  = [0x00112233, 0x44556677, 0x8899AABB, 0xCCDDEEFF,
                0x01020304, 0x05060708, 0x090A0B0C, 0x0D0E0F10]
    for i, v in enumerate(pattern):
        wr32(blk_base + i * 4, v)
    for i, v in enumerate(pattern):
        check('block[{}]     @0x{:08x}'.format(i, blk_base + i * 4),
              rd32(blk_base + i * 4), v)

    # Zero-fill the block and re-verify
    for i in range(8):
        wr32(blk_base + i * 4, 0x00000000)
    for i in range(8):
        check('block0[{}]    @0x{:08x}'.format(i, blk_base + i * 4),
              rd32(blk_base + i * 4), 0x00000000)

    print('[MODE] {} all subtests PASS'.format(mode.upper()))

end

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 1: ABSTRACT memory access mode
# ═══════════════════════════════════════════════════════════════════════════════
python
test_mode('abstract', ABSTRACT_BASE)
end

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 2: PROGBUF memory access mode
# ═══════════════════════════════════════════════════════════════════════════════
python
test_mode('progbuf', PROGBUF_BASE)
end

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 3: SYSBUS memory access mode
# ═══════════════════════════════════════════════════════════════════════════════
python
test_mode('sysbus', SYSBUS_BASE)
end

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 4: SBA streaming — block read/write with sbautoincrement (raw DMI)
# ═══════════════════════════════════════════════════════════════════════════════
#
# Uses raw DMI commands (via OpenOCD 'monitor' interface) to exercise:
#   A. SBA block WRITE with sbautoincrement:
#      Write SBADDRESS0 once, then write SBDATA0 eight times.  Address advances
#      by 4 after each completed write (SBCS.sbautoincrement=1, sbaccess=2).
#   B. SBA block READ with sbreadononaddr:
#      Write SBADDRESS0 for each word to trigger a read, then read SBDATA0.
#      Verify all eight words match those written in step A.
#
# SBCS register layout (Debug Spec 0.13 §3.12.8):
#   Bit 31:29 = sbversion (R)
#   Bit 22    = sbbusyerror (W1C)
#   Bit 21    = sbbusy (R)
#   Bit 20    = sbreadononaddr
#   Bit 19:17 = sbaccess (2 = 32-bit)
#   Bit 16    = sbautoincrement
#   Bit 15    = sbreadondata
#   Bit 14:12 = sberror (W1C)

python
import gdb

NWORDS = 8
STREAM_PATTERN = [0xDECAFBAD + i * 0x01010101 for i in range(NWORDS)]

# ── DMI address constants ─────────────────────────────────────────────────────
SBCS_ADDR   = 0x38   # DMI SBCS
SBADDR0     = 0x39   # DMI SBADDRESS0
SBDATA0     = 0x3C   # DMI SBDATA0

def check_sba(label):
    sbcs = dmi_read(SBCS_ADDR)
    sberr    = (sbcs >> 12) & 0x7
    sbusyerr = (sbcs >> 22) & 0x1
    if sberr != 0 or sbusyerr != 0:
        # W1C clear errors
        dmi_write(SBCS_ADDR, (1 << 22) | (7 << 12))
        raise gdb.GdbError(
            '[FAIL] SBA error at {}: sberror={} sbbusyerror={} sbcs=0x{:08x}'.format(
                label, sberr, sbusyerr, sbcs))

# ── A. SBA block write with sbautoincrement ───────────────────────────────────
print('\n[SBA] block write with sbautoincrement')

# Clear any previous SBA state.
dmi_write(SBCS_ADDR, (1 << 22) | (7 << 12))

# SBCS: sbautoincrement=1 (bit16), sbaccess=2 (bits19:17=010 → 2<<17=0x40000)
# SBCS write value: 0x00050000
SBCS_AUTOINCR_W = (2 << 17) | (1 << 16)   # sbaccess=2, sbautoincrement=1
dmi_write(SBCS_ADDR, SBCS_AUTOINCR_W)

# Write starting address once; sbautoincrement advances it automatically.
dmi_write(SBADDR0, STREAM_BASE)

for i, v in enumerate(STREAM_PATTERN):
    dmi_write(SBDATA0, v)
    mon_delay(50)   # wait for SBA write to complete before writing next
    check_sba('SBA write[{}] @0x{:08x}'.format(i, STREAM_BASE + i * 4))
    print('  SBA write[{}] @0x{:08x}: 0x{:08x} OK'.format(i, STREAM_BASE + i * 4, v))

# Verify SBADDRESS0 advanced to STREAM_BASE + NWORDS*4.
exp_addr = STREAM_BASE + NWORDS * 4
got_addr = dmi_read(SBADDR0)
if got_addr != exp_addr:
    raise gdb.GdbError(
        '[FAIL] SBA write autoincrement: expected SBADDRESS0=0x{:08x} got=0x{:08x}'.format(
            exp_addr, got_addr))
print('  SBADDRESS0 auto-advanced to 0x{:08x} after {} writes OK'.format(got_addr, NWORDS))

# ── B. SBA block read with sbreadononaddr ─────────────────────────────────────
print('\n[SBA] block read with sbreadononaddr + sbautoincrement')

# SBCS: sbreadononaddr=1 (bit20), sbaccess=2, sbautoincrement=1 (bit16)
SBCS_READON = (1 << 20) | (2 << 17) | (1 << 16)
dmi_write(SBCS_ADDR, SBCS_READON)

sba_read_results = []
for i in range(NWORDS):
    addr = STREAM_BASE + i * 4
    # Writing SBADDRESS0 triggers sbreadononaddr → SBA read of 'addr' starts.
    # sbautoincrement advances SBADDRESS0 by 4 after the read completes.
    dmi_write(SBADDR0, addr)
    mon_delay(50)   # wait for SBA read to complete
    check_sba('SBA read[{}] @0x{:08x}'.format(i, addr))
    val = dmi_read(SBDATA0)
    sba_read_results.append(val)
    print('  SBA read[{}] @0x{:08x}: 0x{:08x}'.format(i, addr, val))

# Verify read-back matches what was written.
for i, (got, exp) in enumerate(zip(sba_read_results, STREAM_PATTERN)):
    check('SBA rd[{}] @0x{:08x}'.format(i, STREAM_BASE + i * 4), got, exp)
print('[SBA] block read/write with sbautoincrement: PASS')

# Disable SBA features.
dmi_write(SBCS_ADDR, 0x00000000)

end

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 5: Cross-mode consistency
# — Write in one mode, read in another; data must be identical.
# ═══════════════════════════════════════════════════════════════════════════════
python
import gdb

CROSS_PATTERN = [0x11223344, 0x55667788, 0xAABBCCDD, 0xEEFF0011,
                 0xDEADBEEF, 0xCAFEBABE, 0xFACEB00C, 0xB16B00B5]

def write_block(mode, base, data):
    gdb.execute('monitor riscv set_mem_access {}'.format(mode))
    for i, v in enumerate(data):
        wr32(base + i * 4, v)

def read_block(mode, base, n):
    gdb.execute('monitor riscv set_mem_access {}'.format(mode))
    return [rd32(base + i * 4) for i in range(n)]

def verify_block(label, got_list, exp_list):
    for i, (g, e) in enumerate(zip(got_list, exp_list)):
        check('{} [{}]'.format(label, i), g, e)

print('\n[CROSS] cross-mode consistency')

# Write abstract → read sysbus
write_block('abstract', CROSS_BASE + 0x000, CROSS_PATTERN)
verify_block('abstract→sysbus', read_block('sysbus', CROSS_BASE + 0x000, 8), CROSS_PATTERN)
print('  abstract write → sysbus read: PASS')

# Write sysbus → read progbuf
write_block('sysbus', CROSS_BASE + 0x040, CROSS_PATTERN)
verify_block('sysbus→progbuf', read_block('progbuf', CROSS_BASE + 0x040, 8), CROSS_PATTERN)
print('  sysbus write → progbuf read: PASS')

# Write progbuf → read abstract
write_block('progbuf', CROSS_BASE + 0x080, CROSS_PATTERN)
verify_block('progbuf→abstract', read_block('abstract', CROSS_BASE + 0x080, 8), CROSS_PATTERN)
print('  progbuf write → abstract read: PASS')

print('[CROSS] all cross-mode consistency checks: PASS')

end

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 6: IRAM read-only sanity and DRAM far-address test
# ═══════════════════════════════════════════════════════════════════════════════
python
import gdb

gdb.execute('monitor riscv set_mem_access progbuf')
print('\n[MISC] IRAM readable sanity')
non_zero = sum(1 for i in range(8) if rd32(IRAM + i * 4) != 0)
if non_zero == 0:
    raise gdb.GdbError('[FAIL] gdb_memory: all 8 IRAM words at 0x80000000 are zero')
print('  IRAM[0x80000000..+0x1C]: {}/8 non-zero  OK'.format(non_zero))

print('[MISC] DRAM far-address write/read-back')
FAR = 0x90007FF0
wr32(FAR,     0xFEEDFACE)
wr32(FAR + 4, 0xDECAF00D)
check('far DRAM @0x{:08x}'.format(FAR),     rd32(FAR),     0xFEEDFACE)
check('far DRAM @0x{:08x}'.format(FAR + 4), rd32(FAR + 4), 0xDECAF00D)

end

printf "[PASS] gdb_memory\n"
