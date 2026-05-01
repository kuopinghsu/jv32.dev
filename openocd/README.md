# JV32 OpenOCD Debug Interface Tests

This directory contains the OpenOCD configuration files and Tcl test scripts for the JV32 JTAG/cJTAG debug interface.

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

### All tests including GDB suite

```bash
make -C openocd all-with-gdb
```

### Individual transport suites

```bash
make -C openocd test-jtag
make -C openocd test-cjtag
make -C openocd test-gdb
```

### Single test

```bash
make -C openocd jtag-halt_resume
make -C openocd cjtag-halt_resume
make -C openocd jtag-sba
make -C openocd cjtag-abstract_regs
make -C openocd gdb-step
make -C openocd gdb-memory
```

### Override variables

| Variable | Default | Description |
|---|---|---|
| `OPENOCD` | `openocd` | OpenOCD binary path |
| `GDB` | `$(RISCV_PREFIX)gdb` | RISC-V GDB binary path |
| `VPI_PORT` | `5555` | TCP port for the VPI server |
| `GDB_PORT` | `3333` | TCP port for the OpenOCD GDB server |
| `BOOT_ELF` | `build/hello.elf` | ELF loaded into the SoC simulator |

---

## Test Suite

The 22 JTAG tests and 23 cJTAG tests (one extra cJTAG activation check) are listed below in
execution order.  The 6 GDB tests are described separately in the [GDB Test Suite](#gdb-test-suite)
section.

| File | What it tests |
|---|---|
| `test_dtmcs.tcl` | DMI/TAP preflight: dmstatus version, authenticated, dmcontrol dmactive |
| `test_halt_resume.tcl` | halt/resume/re-halt cycle; dmstatus anyrunning/allrunning bits |
| `test_registers.tcl` | GPR (a0, t0) and CSR (mstatus, mepc, mcause, mscratch) read/write via abstract commands |
| `test_abstract_regs.tcl` | All 32 GPRs + mscratch, mtvec BASE alignment, mie — exhaustive abstract command coverage |
| `test_memory.tcl` | Word/halfword/byte write-read-back via progbuf; 4-word burst; DRAM access |
| `test_memory_modes.tcl` | All three access modes: `abstract`, `progbuf`, `sysbus` — each writes a distinct value |
| `test_reset.tcl` | ndmreset: PC must land at `0x80000000` after `reset halt` |
| `test_dm_status.tcl` | dmstatus anyhalted/allhalted/anyrunning/allrunning raw DMI bit transitions |
| `test_programbuf.tcl` | progbufsize ≥ 2; execute `addi a0,a0,1` + `ebreak` via progbuf; verify a0 incremented |
| `test_step.tcl` | 4 × `step` from `0x80000000`; PC advances each time; DCSR.cause=4; step bit cleared on resume |
| `test_debug_errors.tcl` | Unmapped-address access error; DM recovery via `reset halt`; working mode fallback |
| `test_breakpoint.tcl` | sw/hw breakpoints; sw-after-hw; hw-after-sw; DCSR.cause=2; ebreakm sw path |
| `test_watchpoint.tcl` | Write watchpoint via trigger CSRs; progbuf store fires trigger; DCSR.cause=2 |
| `test_misa.tcl` | misa `0x40001105`: MXL=1 (RV32), A/C/I/M bits set, F/D/V bits clear |
| `test_dcsr.tcl` | xdebugver=4, prv=3 (M-mode), cause=3 (halt_req); ebreakm set/clear round-trip |
| `test_triggers.tcl` | tinfo type-2 bit; tselect isolation; trigger 0 execute-match; trigger 1 allocation |
| `test_csr_fields.tcl` | mstatus MIE/MPIE writable; mtvec BASE alignment; mepc LSB=0; dpc within IRAM |
| `test_sba.tcl` | SBA raw DMI: sbversion=1/sbasize=32; SBA write+read; sbreadonaddr; autoincrement burst; sbbusyerror W1C |
| `test_havereset.tcl` | impebreak=1; non-existent hart; havereset sticky; ackhavereset; hartreset; CMD_QUICK_ACCESS rejected; postexec-only |
| `test_abstractauto.tcl` | ABSTRACTAUTO default=0; round-trip; autoexec_data[0] re-executes on DATA0 read; no cmderr accumulation |
| `test_debug_ext_alias.tcl` | Out-of-TCM alias routing: IRAM alias↔canonical and DRAM alias↔canonical via sysbus |
| `test_cjtag.tcl` | cJTAG OScan1 activation: halt/resume/re-halt over 2-wire transport *(cJTAG suite only)* |

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

## GDB Test Suite

The 6 GDB tests are driven by `riscv-gdb --batch` connecting to an OpenOCD GDB server
(`GDB_PORT`, default `3333`) that sits in front of the JTAG VPI simulator. Each test script
emits `[PASS]` / `[SKIP]` on success using the same convention as the Tcl tests.

The GDB server is started by the Makefile before invoking GDB and is killed afterward; no
persistent OpenOCD instance is required. GDB Python scripting is used for all assertions.

| File | What it tests |
|---|---|
| `test_gdb_load.gdb` | ELF download via `load`, entry-point PC check, `stepi`/`nexti` after load, `DCSR.cause` |
| `test_gdb_step.gdb` | `stepi` × 3, `nexti` × 2, source-level `step`/`next` (SKIP-tolerant without DWARF) |
| `test_gdb_breakpoint.gdb` | `hbreak` hit + `DCSR.cause=2`, two simultaneous hw breakpoints, disable/re-enable, sw `break` |
| `test_gdb_memory.gdb` | 32/16/8-bit write-read-back, boundary crossing, 8-word burst, zero-fill, IRAM read, far DRAM |
| `test_gdb_regs.gdb` | PC/SP validity, GPR write-back, `info registers`, CSRs: misa, dcsr, mstatus, mepc, x0 |
| `test_gdb_debug.gdb` | `info registers`, disasm, stepi×4, hw bp, backtrace, write watchpoint injection, resume/re-halt |

### `test_gdb_load.gdb` — ELF download

Verifies that GDB can download an ELF into the target and that execution can begin from the
entry point:

1. `monitor reset halt` — reset and stop the hart.
2. `load` — download all ELF sections; must complete without error.
3. Verify entry-point PC is within IRAM (`0x80000000`–`0x80FFFFFF`).
4. Execute `stepi`; verify PC advanced from the entry point.
5. Execute `nexti`; verify PC advanced again.
6. Verify `DCSR.cause == 4` (step) via `monitor reg dcsr`.

---

### `test_gdb_step.gdb` — stepi / nexti / step / next

Covers all four GDB stepping commands on a bare-metal RISC-V target:

| Command | Semantics on bare-metal | Pass criterion |
|---|---|---|
| `stepi` | Instruction-level step (single instruction) | PC advances; `DCSR.cause == 4` |
| `nexti` | Step-over at instruction level | PC advances; `DCSR.cause == 4` |
| `step` | Source-line step (may be identical to stepi) | PC advances, or SKIP if no DWARF info |
| `next` | Step-over at source level | PC advances, or SKIP if no DWARF info |

Sequence:

1. `monitor reset halt`; force `pc = 0x80000000` for a deterministic start.
2. Three consecutive `stepi` commands; each must advance PC and set `DCSR.cause = 4`.
3. Two consecutive `nexti` commands; same checks.
4. One `step` and one `next`; SKIP-tolerant if no DWARF line info is available.

PC must remain within the expected range (`0x80000000`–`0x8FFFFFFF`) throughout.

---

### `test_gdb_breakpoint.gdb` — hardware and software breakpoints

Exercises the full GDB breakpoint lifecycle:

| Subtest | Command | Description |
|---|---|---|
| Single hw bp | `hbreak *addr` | Set at `pc + 0x10`; continue; verify hit; check `DCSR.cause == 2` |
| Dual hw bp | `hbreak *a` + `hbreak *b` | Two simultaneous; first fires, then second; verify ordering |
| Disable / re-enable | `disable N` / `enable N` | Disabled bp not triggered during stepi; re-enable then delete |
| Software bp | `break *addr` | SKIP-tolerant if `ebreakm` not configured on the target |

After each subtest all breakpoints are deleted and the state is verified clean with
`info breakpoints`.

---

### `test_gdb_memory.gdb` — memory read/write via GDB expressions

Verifies memory access using GDB `set {type}addr` and `*(type*)addr` expressions targeting DRAM
(`0x90000000`) and IRAM (`0x80000000`):

| Check | Width | Address | Description |
|---|---|---|---|
| Word write/read + overwrite | 32-bit | `0x90000000` | Two consecutive writes; verify both |
| Halfword lo + hi | 16-bit | `0x90000010`/`12` | Two adjacent halfwords; verify as one full word |
| Byte × 4 | 8-bit | `0x90000020`–`23` | Four bytes; verify assembled word `0xD4C3B2A1` |
| Byte boundary | 8-bit | `0x90000033`/`34` | Straddles a 4-byte word boundary |
| 8-word burst | 32-bit | `0x90000040` | Write 8 words; read back each individually |
| Zero-fill | 32-bit | `0x90000080` | Write 8 × `0xFFFFFFFF`, then zero-fill; verify all zero |
| IRAM readable | 32-bit | `0x80000000` | At least one of 8 boot words is non-zero |
| Far DRAM bound | 32-bit | `0x90007FF0` | Write/read near DRAM upper boundary |

---

### `test_gdb_regs.gdb` — general-purpose and CSR register access

Validates register access via GDB `$regname` expressions and `monitor reg`:

1. **PC validity** — must be within `0x80000000`–`0x9FFFFFFF` after halt.
2. **SP** — non-zero and 4-byte aligned.
3. **t0 / t1** — write `0xDEADBEEF` / `0xCAFEBABE`, verify read-back, restore originals.
4. **s0 / a0** — write `0xA5A5A5A5` / `0x5A5A5A5A`, verify read-back, restore originals.
5. **`info registers`** — output must contain `pc`, `sp`, `ra`, `zero`.
6. **misa** — `MXL [31:30] == 1` (RV32); `I`-extension bit set.
7. **dcsr** — `prv [1:0] == 3` (M-mode); `debugver [31:28] >= 2`.
8. **mstatus** — readable and non-zero.
9. **mepc** — readable (zero early in boot is tolerated).
10. **x0 (zero)** — write attempt silently ignored; always reads `0`.

---

### `test_gdb_debug.gdb` — comprehensive debug session

Exercises a realistic multi-step debug workflow end-to-end:

1. **`info registers`** — output contains `pc`, `sp`, `ra`, `zero`.
2. **`x/8i $pc`** — disassemble 8 instructions; output must contain ≥ 4 lines.
3. **`stepi` × 4** — PC must advance from the starting value.
4. **Hardware breakpoint** — `hbreak *pc+0x10`; `continue`; verify halt and `DCSR.cause == 2`.
5. **`backtrace`** — must not crash GDB; depth ≥ 1 frame (tolerance for bare-metal frames).
6. **`info breakpoints`** — empty after `delete breakpoints`.
7. **Write watchpoint via code injection**:
   - Write a 3-instruction snippet (`lui x6,0x90000` / `sw x0,0x200(x6)` / `ebreak`) to
     IRAM scratch area (`0x80007000`).
   - Redirect PC to the snippet.
   - Set `watch *(unsigned int*)0x90000200`.
   - `continue` — hart executes the store, watchpoint fires.
   - Verify `DCSR.cause == 2` (trigger) and PC within the snippet range.
8. **Watchpoint cleanup** — `delete breakpoints`; `info watchpoints` must be empty.
9. **Post-watchpoint stepi** — `DCSR.cause` must be `4` (step, not trigger).
10. **Resume / re-halt round-trip** — hart must halt again cleanly after a free run.

---

## Log Files

All test output is written to `build/openocd_logs/`:

```
build/openocd_logs/
├── jtag_dtmcs.ocd.log
├── jtag_halt_resume.ocd.log
├── ...
├── cjtag_cjtag.ocd.log
├── cjtag_dtmcs.ocd.log
├── ...
├── gdb_load.gdb.log
├── gdb_step.gdb.log
├── gdb_breakpoint.gdb.log
├── gdb_memory.gdb.log
├── gdb_regs.gdb.log
└── gdb_debug.gdb.log
```

On failure the log shows the OpenOCD / GDB error output and the assertion message from the failing
test. Pass/fail summary is printed to stdout at the end of each transport or GDB suite run.
