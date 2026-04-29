# JV32 OpenOCD Debug Interface Tests

This directory contains the OpenOCD configuration files and Tcl test scripts for the JV32 JTAG/cJTAG debug interface.

```
openocd/
├── Makefile                  # Build and run orchestration
├── jv32.cfg                  # OpenOCD config for 4-wire JTAG (jtag_vpi driver)
├── jv32_cjtag.cfg            # OpenOCD config for 2-wire cJTAG (OScan1, jtag_vpi + enable_cjtag)
├── jv32_gdb.cfg              # GDB remote target config (for interactive GDB sessions)
├── test_abstract_regs.tcl    # Abstract command: all 32 GPRs + key CSRs
├── test_abstractauto.tcl     # ABSTRACTAUTO register autoexec behavior
├── test_breakpoint.tcl       # Software and hardware breakpoints
├── test_cjtag.tcl            # cJTAG transport sanity (cJTAG-mode only)
├── test_csr_fields.tcl       # CSR field constraints (mstatus, mtvec, mepc, dpc)
├── test_dcsr.tcl             # DCSR field validation
├── test_debug_errors.tcl     # Error path and recovery after unmapped access
├── test_debug_ext_alias.tcl  # Out-of-TCM alias routing via sysbus path
├── test_dm_status.tcl        # dmstatus halt/resume bit transitions
├── test_dtmcs.tcl            # DMI/TAP preflight (dmstatus, dmcontrol sanity)
├── test_halt_resume.tcl      # Basic halt/resume/re-halt cycle
├── test_havereset.tcl        # DM control: impebreak, havereset, hartreset, quick_access
├── test_memory.tcl           # Memory word/halfword/byte read-write via progbuf
├── test_memory_modes.tcl     # Three memory access modes: abstract, progbuf, sysbus
├── test_misa.tcl             # misa register ISA encoding
├── test_programbuf.tcl       # Program buffer execution
├── test_registers.tcl        # GPR and CSR read/write via abstract commands
├── test_reset.tcl            # ndmreset: PC lands at boot address
├── test_sba.tcl              # System Bus Access raw DMI protocol
├── test_step.tcl             # Single-step instruction advance
├── test_triggers.tcl         # Hardware trigger module (N_TRIGGERS=2)
└── test_watchpoint.tcl       # Data-write watchpoint via trigger
```

---

## Tool Requirements

| Tool | Notes |
|---|---|
| [OpenOCD](https://github.com/kuopinghsu/openocd) | **Patched fork required** for VPI-based cJTAG simulation support |

Standard OpenOCD does not include the `jtag_vpi` cJTAG extension. Use the patched fork:

```bash
git clone https://github.com/kuopinghsu/openocd
cd openocd
./bootstrap
./configure --enable-jtag_vpi --enable-cjtag_vpi
make -j$(nproc)
sudo make install    # or set OPENOCD= in env.config
```

Set the binary in `env.config` if it is not in `PATH`:

```ini
OPENOCD=$(HOME)/opt/openocd/bin/openocd
```

---

## How the VPI Testbench Works

`make openocd-test` builds two Verilator testbench variants and runs all Tcl scripts against both:

| Mode | Transport | Simulator binary |
|---|---|---|
| JTAG | 4-wire IEEE 1149.1 | `build/jv32vpi_jtag` |
| cJTAG | 2-wire OScan1 (IEEE 1149.7) | `build/jv32vpi_cjtag` |

The VPI testbench starts `build/hello.elf` on the simulated SoC; the hello test prints its output,
calls `_exit`, then spins in a `_spin: j _spin` loop. The VPI layer ignores the `sim_request_exit()`
magic, so the hart stays alive in the spin loop and OpenOCD can halt, examine, and resume it at will.

OpenOCD connects to the VPI testbench over a TCP socket (`VPI_PORT`, default `5555`) using the
`jtag_vpi` adapter driver. The `jv32.cfg` and `jv32_cjtag.cfg` configs share the same IR/DR settings:

| Setting | Value |
|---|---|
| Adapter driver | `jtag_vpi` |
| Transport | `jtag` |
| IDCODE | `0x1DEAD3FF` |
| IR length | 5 bits |
| DTMCS IR | `0x10` |
| DMI IR | `0x11` |
| Default memory access | `abstract` |
| cJTAG | `jtag_vpi enable_cjtag on` (cJTAG config only) |

---

## Running Tests

### All tests (JTAG then cJTAG)

```bash
make openocd-test           # from project root
# or
cd openocd && make all
```

### Individual transport suites

```bash
make -C openocd test-jtag
make -C openocd test-cjtag
```

### Single test

```bash
make -C openocd jtag-halt_resume
make -C openocd cjtag-halt_resume
make -C openocd jtag-sba
make -C openocd cjtag-abstract_regs
```

### Override variables

| Variable | Default | Description |
|---|---|---|
| `OPENOCD` | `openocd` | OpenOCD binary path |
| `VPI_PORT` | `5555` | TCP port for the VPI server |
| `BOOT_ELF` | `build/hello.elf` | ELF loaded into the SoC simulator |

---

## Test Suite

The 22 JTAG tests and 23 cJTAG tests (one extra cJTAG activation check) are listed below in
execution order.

### `test_dtmcs.tcl` — DMI/TAP preflight

Pre-flight checks before any halt operation. Reads raw DMI registers to validate Debug Module
activation:

- **dmstatus** (DMI `0x11`) `version [3:0]` must be `2` (Debug Spec 0.13 compliant).
- **dmstatus** `authenticated [7]` must be `1` (debug module is not locked).
- **dmcontrol** (DMI `0x10`) `dmactive [0]` must be `1` (DM is active).

---

### `test_halt_resume.tcl` — halt/resume

Basic stop-and-go cycle:

1. Issue `halt`; wait up to 1 000 ms for the hart to stop.
2. Read `pc`.
3. Issue `resume`; after 20 ms sleep read **dmstatus** bits `anyrunning [10]` and `allrunning [11]`
   directly from DMI to confirm the hart is actually executing (not just OpenOCD thinking it resumed).
4. Issue `halt` again; verify re-halt succeeds.

A spinning hart (`j _spin`) is expected to produce `pc_before == pc_after`, which is treated as
correct behaviour.

---

### `test_registers.tcl` — register access

Reads and writes GPRs and CSRs via abstract commands:

- **pc**: read and print current value.
- **a0** / **t0**: save original → write test value → read back → verify → restore.
- **mstatus**, **mepc**, **mcause**: read and print.
- **mscratch**: write all-zeros then all-ones boundary patterns and verify round-trip (no
  architectural side-effects).

---

### `test_abstract_regs.tcl` — abstract register access (all 32 GPRs + key CSRs)

Exhaustive abstract-command register test:

1. **All 32 GPRs** — for `x1`..`x31`: write pattern `0xAB000000 | (regno << 8) | regno`, read
   back, verify, restore. Uses ABI names (`ra`, `sp`, … `t6`); OpenOCD names `x8` as `fp`.
2. **x0 (zero register)** — writes must be silently discarded; verify always reads `0`.
3. **mscratch** — fully writable CSR; write/read round-trip with a distinct pattern.
4. **mtvec BASE `[31:2]`** — must be 4-byte aligned; write misaligned value, read back, check low
   bits are masked.
5. **mie** — write a pattern, read back, verify bits match what the implementation supports.

---

### `test_memory.tcl` — memory read/write

Exercises memory access via the program-buffer path (`riscv set_mem_access progbuf`):

- **Word** (32-bit): write `0x11223344`, read back, verify.
- **Halfword** (16-bit): write `0x5566`, read back, verify.
- **Byte** (8-bit): write `0x77`, read back, verify.
- **Multi-word burst**: write four consecutive 32-bit words at `base + 0x10`, then read back
  individually to verify each location.

Base address used: `0x80000800` (well into the data region, past text/rodata for small test programs).

---

### `test_memory_modes.tcl` — memory access modes

Tests each of the three OpenOCD memory access modes independently:

| Mode | Description |
|---|---|
| `abstract` | Debug module abstract command `ACCESS_MEMORY` (no hart execution) |
| `progbuf` | Execute load/store instructions via program buffer (default JV32 mode) |
| `sysbus` | System Bus Access port — DMA-style reads/writes bypassing the hart |

Each mode writes a mode-unique value to a distinct address in IRAM and reads it back. Modes that
fail to initialise are logged as skipped (not a failure).

---

### `test_reset.tcl` — ndmreset

Verifies the system reset path:

1. Halt the hart.
2. Issue `reset halt` (ndmreset followed by halt request).
3. Wait up to 1 000 ms for re-halt.
4. Read `pc`; must equal `0x80000000` (the configured `BOOT_ADDR` / reset vector).

---

### `test_dm_status.tcl` — dmstatus halt/resume transitions

Validates the Debug Module status register bit transitions via raw DMI reads, rather than relying
solely on OpenOCD's internal state:

- After `halt`: `anyhalted [8]` and `allhalted [9]` must both be `1`.
- After `resume`: `anyrunning [10]` and `allrunning [11]` must both be `1`.
- After re-`halt`: halted bits must be `1` again.

---

### `test_programbuf.tcl` — program buffer capability

Checks the program buffer size and exercises executing arbitrary instructions via the progbuf:

1. Read **abstractcs** (DMI `0x16`) field `progbufsize [28:24]`; must be ≥ 2 (JV32 implements 2
   program-buffer slots).
2. Construct a two-instruction program buffer sequence (`addi a0, a0, 1` + `ebreak`) and verify
   the hart executes it cleanly with `cmderr = 0`.
3. Verify the `a0` register was incremented by the progbuf execution.

---

### `test_step.tcl` — single-step

Verifies instruction-level stepping (covers `step`, `stepi`, `next`, `nexti` semantics — all
equivalent on a bare-metal RISC-V hart):

1. Halt and redirect `dpc` to `0x80000000` (boot address, before IRQs are enabled) for a
   predictable starting point.
2. Execute four `step` operations.
3. After each step, verify:
   - The hart re-halted (within 1 000 ms).
   - `pc` advanced from the previous value.
4. After four steps, issue `resume` and verify **dcsr** `step [2]` is cleared (hart executes
   freely after resume).

---

### `test_debug_errors.tcl` — debug error path and recovery

Tests that the debug path survives and recovers from a faulting memory access:

1. Set memory mode to `progbuf`.
2. Attempt a read from an unmapped address (`0x90000000` — write-only DRAM in this context); expect
   an error (or log a warning if the access unexpectedly succeeds).
3. Issue `reset halt` to recover the DM to a clean state.
4. Try each memory mode (`abstract`, `progbuf`, `sysbus`) in turn; the first working mode must
   successfully write `0xCAFEBABE` to and read it back from a valid IRAM address.

---

### `test_breakpoint.tcl` — breakpoints

Tests both software and hardware breakpoints across multiple subtests:

| Subtest | Mode | Description |
|---|---|---|
| `sw basic` | Software (`ebreak`) | Insert breakpoint at current PC; resume; verify halt at same PC |
| `hw basic` | Hardware (trigger type-2) | Insert `bp ... hw` at current PC; resume; verify halt |
| `sw after hw` | Software after hardware | Verify SW breakpoints still work after an HW breakpoint was used |
| `hw after sw` | Hardware after software | Verify HW breakpoints still work after a SW breakpoint was used |

Each subtest: halt → read `pc` → set breakpoint → resume → wait for halt → verify `pc` matches.
Hardware breakpoints are skipped (not failed) if the target reports no available hardware trigger
slots.

---

### `test_watchpoint.tcl` — data-write watchpoint

Tests a store watchpoint using the hardware trigger module directly via DMI, so the test is
independent of startup side-effects:

1. Select trigger 0 (`tselect = 0`).
2. Write **tdata2** with the watchpoint address `0x90000000` (DRAM base).
3. Configure **tdata1** as a store-match trigger (`mcontrol`: `dmode=1`, `action=1`
   enter-debug-mode, `store=1`).
4. Execute a `sw` instruction to the watchpoint address via progbuf.
5. Verify the hart halted with **dcsr** `cause [8:6] = 2` (trigger).
6. Clear the trigger and verify the hart can resume cleanly.

---

### `test_misa.tcl` — misa ISA register

Reads and validates the `misa` CSR which is hard-wired to `0x40001105` (RV32IMAC):

| Field | Expected | Meaning |
|---|---|---|
| `[31:30]` MXL | `1` | 32-bit base ISA |
| bit 0 | `1` | A — atomic extension |
| bit 2 | `1` | C — compressed extension |
| bit 8 | `1` | I — base integer ISA |
| bit 12 | `1` | M — multiply/divide extension |
| bit 5 (F) | `0` | no single-precision float |
| bit 3 (D) | `0` | no double-precision float |
| bit 21 (V) | `0` | no vector extension |

---

### `test_dcsr.tcl` — DCSR field validation

Validates the `dcsr` register after a halt request:

| Field | Bits | Expected | Meaning |
|---|---|---|---|
| `xdebugver` | `[31:28]` | `4` | External debug spec 0.13 |
| `prv` | `[1:0]` | `3` | M-mode at debug entry |
| `cause` | `[8:6]` | `3` | Halt request (`halt_req`) |
| `ebreakm` | `[15]` | `0` (default) | `ebreak` in M-mode does not enter debug mode by default |

Also verifies the `ebreakm` bit can be set and cleared via abstract register write, and that
a subsequent `ebreak` instruction (inserted via progbuf) triggers debug entry when `ebreakm=1`.

---

### `test_triggers.tcl` — hardware trigger module

Tests the trigger module with `N_TRIGGERS=2`:

1. **tinfo** — read `tinfo` CSR; bit 2 (type-2 / `mcontrol`) must be set.
2. **tselect isolation** — program distinct unreachable addresses into `tdata2[0]` and `tdata2[1]`;
   switch back and forth via `tselect` and verify each bank retains its own value.
3. **Trigger 0 execute-match** — set an execute trigger on the spin-loop PC; resume; verify halt
   with `dcsr.cause = 2` (trigger).
4. **Trigger 1 execute-match** — occupy trigger 0 with an unreachable dummy breakpoint first;
   let OpenOCD allocate trigger 1 for the real breakpoint; verify trigger 1 fires correctly.

The test uses `halt` (not `reset halt`) to ensure the hart is stopped inside the spin loop, which
is a stable, repeatedly-executed address that triggers can fire on reliably regardless of JTAG
synchronisation latency.

---

### `test_csr_fields.tcl` — CSR field constraints

Validates individual CSR field constraints via abstract register access:

| CSR | Field | Check |
|---|---|---|
| `mstatus` | `MIE [3]` | Writable: write `1`, verify set; write `0`, verify clear |
| `mstatus` | `MPIE [7]` | Writable: write `1`, verify set; write `0`, verify clear |
| `mtvec` | `BASE [31:2]` | 4-byte aligned: write misaligned value, verify low 2 bits masked |
| `mepc` | `[31:1]` | 2-byte aligned: LSB always reads as `0` per spec |
| `dpc` | (= `pc` in debug mode) | Must be within IRAM range `[0x80000000, 0x8001FFFF]` |

All original values are restored at the end of each check.

---

### `test_sba.tcl` — System Bus Access raw DMI protocol

Tests the System Bus Access port by talking to DMI registers directly (bypassing OpenOCD's `sysbus`
abstraction layer). JV32 advertises `sbversion=1`, `sbasize=32`, `sbaccess32` only.

DMI registers used:

| Address | Register | Purpose |
|---|---|---|
| `0x38` | `SBCS` | Control/status |
| `0x39` | `SBADDRESS0` | Target address (32-bit) |
| `0x3C` | `SBDATA0` | Read/write data (32-bit) |

Checks:

1. **SBCS read-only fields** — `sbversion=1`, `sbasize=32`, `sbaccess32` capability bit set.
2. **SBA write** — write `SBADDRESS0` then `SBDATA0` to trigger a bus write; verify the written
   value is visible via a progbuf memory read.
3. **SBA read (sbreadonaddr)** — write `SBADDRESS0` to trigger an auto-read; read back via
   `SBDATA0`.
4. **sbautoincrement + sbreadondata streaming** — set `autoincrement` and `sbreadondata`; read
   four consecutive words as a burst.
5. **sbbusyerror W1C** — artificially provoke and then clear the sticky error bit.
6. **SBCS writable bits round-trip** — verify the writable control bits retain written values.

---

### `test_havereset.tcl` — DM control features

Tests Debug Module control features not covered by other tests:

1. **impebreak** (`dmstatus [22]`) — must be `1`: hardware appends an implicit `ebreak` to each
   progbuf execution window; OpenOCD relies on this to detect progbuf completion.
2. **nonexistent hart** (`anynonexistent [15]` / `allnonexistent [14]`) — selecting `hartsel > 0`
   must report the hart as non-existent; selecting `hartsel = 0` must clear those bits.
3. **havereset sticky** (`dmstatus [19:18]`) — after `ndmreset`, both `anyhavereset` and
   `allhavereset` must go high.
4. **ackhavereset** (`dmcontrol [28]`) — write-1-to-clear the havereset sticky bits; verify they
   clear.
5. **hartreset** (`dmcontrol [29]`) — reset the hart only (not the DM); verify `havereset` is set
   again afterward.
6. **CMD_QUICK_ACCESS (cmdtype=1) rejection** — must return `cmderr = 4` (`CMDERR_NOTSUP`);
   JV32 does not implement quick-access.
7. **postexec-only command** (`cmdtype=0`, `transfer=0`, `postexec=1`) — execute the program buffer
   without a register transfer; must succeed (`cmderr = 0`).

---

### `test_abstractauto.tcl` — ABSTRACTAUTO register

Tests the ABSTRACTAUTO register (DMI `0x18`) which enables automatic re-execution of the last
abstract command on DMI data or program-buffer register access.

JV32 implements `data0`, `data1`, `progbuf0`, `progbuf1`, so the active bits are `[1:0]`
(autoexec_data) and `[17:16]` (autoexec_pbuf).

Checks:

1. **Default value** — ABSTRACTAUTO reads `0` at reset.
2. **Round-trip** — write a pattern covering supported bits, read back, verify retention.
3. **autoexec_data[0]** — set bit 0; read `DATA0` several times in sequence; verify `mcycle`
   advances across reads (each `DATA0` access re-executes the last abstract read-CSR command,
   advancing the cycle counter).
4. **No cmderr accumulation** — `abstractcs.cmderr` must remain `0` throughout autoexec activity.
5. **Restore** — ABSTRACTAUTO is restored to `0` at end of test.

---

### `test_debug_ext_alias.tcl` — out-of-TCM alias routing

Tests that the debug System Bus Access port correctly routes writes and reads through the SoC's
out-of-TCM alias apertures as well as the canonical TCM addresses.

Uses `sysbus` memory mode so accesses originate from the debug memory-request path in RTL (not the
hart's load/store path).

| Alias address | Canonical TCM address | Description |
|---|---|---|
| `0x60000420` | `0x80000420` | IRAM out-of-TCM alias |
| `0x70000600` | `0x90000600` | DRAM out-of-TCM alias |

Four checks:

1. Write via IRAM alias → read via canonical IRAM → verify match.
2. Write via DRAM alias → read via canonical DRAM → verify match.
3. Write via canonical IRAM → read via IRAM alias → verify match.
4. Write via canonical DRAM → read via DRAM alias → verify match.

This test is skipped if `sysbus` mode is unavailable.

---

### `test_cjtag.tcl` — cJTAG transport sanity *(cJTAG mode only)*

Validates that the 2-wire OScan1 transport is correctly activated and functional:

1. Issue `halt` over cJTAG; verify the hart stops within 1 000 ms.
2. Read `pc`; verify it falls within IRAM range `[0x80000000, 0x8001FFFF]`.
3. Issue `resume`; sleep 20 ms; issue `halt`; verify re-halt succeeds.
4. Read `pc` again; verify it is still within IRAM range.

This test only runs in the cJTAG suite (`make test-cjtag`). It is the first test in the cJTAG
execution order to catch transport-level failures before running the full common test suite.

---

## Log Files

All test output is written to `build/openocd_logs/`:

```
build/openocd_logs/
├── jtag_dtmcs.log
├── jtag_halt_resume.log
├── ...
├── cjtag_cjtag.log
├── cjtag_dtmcs.log
└── ...
```

On failure the log shows the OpenOCD error output and the Tcl `error` message from the failing
test. Pass/fail summary is printed to stdout at the end of each transport run.
