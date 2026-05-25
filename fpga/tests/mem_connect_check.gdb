# ============================================================================
# File   : mem_connect_check.gdb
# Project: JV32 RISC-V SoC – FPGA JTAG
# Brief  : Quick JTAG connection smoke test (~30 s)
#
# Tests the System Bus Access (SBA) path through jv32_dtm via OpenOCD
# monitor commands.  Run this first after programming the bitstream.
#
# Verifies:
#   1. Hart halts on command
#   2. misa == 0x40001105 (RV32IMAC), mhartid == 0x00000000
#   3. IRAM word read/write – 8 patterns @ 0x8001FF00 (SBA path)
#   4. DRAM word read/write – 8 patterns @ 0x9001FF00 (SBA path)
#
# Usage:
#   # Terminal 1 – start OpenOCD
#   openocd -f fpga/jtag/jv32_fpga_jtag.cfg        # 4-wire JTAG
#   # or
#   openocd -f fpga/jtag/jv32_fpga_cjtag.cfg       # cJTAG
#
#   # Terminal 2 – run this script
#   riscv64-unknown-elf-gdb -q -x fpga/tests/mem_connect_check.gdb
# ============================================================================

set confirm off
set pagination off

target extended-remote :3333

set mem inaccessible-by-default off
mem 0x80000000 0x80020000 rw
mem 0x90000000 0x90020000 rw

python

import gdb, re, sys

IRAM_SMOKE = 0x8001FF00    # last 256 B of IRAM (safe scratch)
DRAM_SMOKE = 0x9001FF00    # last 256 B of DRAM (safe scratch)

PATTERNS = [
    0xDEADBEEF, 0xCAFEBABE, 0xA5A5A5A5, 0x5A5A5A5A,
    0x12345678, 0xFEDCBA98, 0x00000000, 0xFFFFFFFF,
]


def sba_wr32(addr, val):
    gdb.execute("monitor mww 0x%08x 0x%08x" % (addr, val), to_string=True)


def sba_rd32(addr):
    out = gdb.execute("monitor mdw 0x%08x" % addr, to_string=True)
    m = re.search(r'0x[0-9a-fA-F]+:\s+([0-9a-fA-F]+)', out)
    if not m:
        raise gdb.GdbError("mdw parse failed: " + out.strip())
    return int(m.group(1), 16)


def read_csr(name):
    out = gdb.execute("monitor reg " + name, to_string=True)
    m = re.search(r'0x([0-9a-fA-F]+)', out)
    if not m:
        raise gdb.GdbError("reg parse failed for " + name + ": " + out.strip())
    return int(m.group(1), 16)


total_errors = 0

# ── 1. Halt ───────────────────────────────────────────────────────────────────
print("[1/4] Halting hart ...")
try:
    gdb.execute("monitor halt")
    gdb.execute("monitor wait_halt 2000")
    pc = int(gdb.parse_and_eval("$pc")) & 0xFFFFFFFF
    print("      OK  PC = 0x%08x" % pc)
except Exception as e:
    print("[FAIL] Hart did not halt: %s" % e)
    print("       Check JTAG wiring and that the FPGA is programmed.")
    gdb.execute("quit 1")

# ── 2. CSR sanity ────────────────────────────────────────────────────────────
print("[2/4] CSR sanity check ...")
try:
    misa    = read_csr("misa")
    mhartid = read_csr("mhartid")
    misa_ok    = "OK" if misa    == 0x40001105 else "WARN"
    hartid_ok  = "OK" if mhartid == 0x00000000 else "WARN"
    print("      misa    = 0x%08x  expect 0x40001105 (RV32IMAC)  [%s]" % (misa,    misa_ok))
    print("      mhartid = 0x%08x  expect 0x00000000              [%s]" % (mhartid, hartid_ok))
    if misa    != 0x40001105: total_errors += 1
    if mhartid != 0x00000000: total_errors += 1
except Exception as e:
    print("      [FAIL] CSR read error: %s" % e)
    total_errors += 1

# ── 3. IRAM smoke – SBA path ─────────────────────────────────────────────────
print("[3/4] IRAM SBA smoke  @ 0x%08x ..." % IRAM_SMOKE)
iram_err = 0
for i, p in enumerate(PATTERNS):
    addr = IRAM_SMOKE + i * 4
    sba_wr32(addr, p)
    got = sba_rd32(addr)
    if got != p:
        print("      [FAIL] +0x%02x  wrote 0x%08x  read 0x%08x" % (i * 4, p, got))
        iram_err += 1
status = "OK  (%d words)" % len(PATTERNS) if iram_err == 0 else "FAIL  (%d error(s))" % iram_err
print("      %s" % status)
total_errors += iram_err

# ── 4. DRAM smoke – SBA path ─────────────────────────────────────────────────
print("[4/4] DRAM SBA smoke  @ 0x%08x ..." % DRAM_SMOKE)
dram_err = 0
for i, p in enumerate(PATTERNS):
    addr = DRAM_SMOKE + i * 4
    sba_wr32(addr, p)
    got = sba_rd32(addr)
    if got != p:
        print("      [FAIL] +0x%02x  wrote 0x%08x  read 0x%08x" % (i * 4, p, got))
        dram_err += 1
status = "OK  (%d words)" % len(PATTERNS) if dram_err == 0 else "FAIL  (%d error(s))" % dram_err
print("      %s" % status)
total_errors += dram_err

# ── Result ───────────────────────────────────────────────────────────────────
print("")
if total_errors == 0:
    print("[PASS] JTAG connection check passed.")
else:
    print("[FAIL] %d error(s) — see above." % total_errors)
    gdb.execute("quit 1")

end

quit
