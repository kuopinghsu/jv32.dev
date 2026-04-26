# J<sub>V</sub>32 RISC-V SoC

<p align="center">
  <img src="docs/jv32-logo.svg" alt="JV32 logo" width="260">
</p>

J<sub>V</sub>32 is a compact **RV32IMAC** RISC-V system-on-chip for RTL simulation, software bring-up, and ASIC/FPGA experimentation. The project includes a 3-stage in-order core, tightly-coupled memories, AXI peripherals, JTAG debug support, verification flows, and an OpenRAM/OpenLane-based synthesis path.

## Highlights

- **ISA:** RV32IMAC with `Zicsr` / `Zifencei`
- **Core:** 3-stage single-issue pipeline (`IF → EX → WB`)
- **Memory:** tightly-coupled `IRAM` and `DRAM`
- **Peripherals:** UART, CLIC/CLINT-style interrupt block, simulation magic device
- **Debug:** JTAG / cJTAG debug transport integration
- **Flows:** Verilator RTL simulation, trace comparison, arch tests, synthesis/P&R

## Repository Layout

```text
rtl/        SystemVerilog RTL for the core, SoC, AXI peripherals, and memories
sw/         Bare-metal software tests and demos
testbench/  Verilator testbench wrapper and support code
sim/        C++ simulation utilities and disassembler support
verif/      RISC-V arch-test integration and verification flow
rtos/       FreeRTOS port and samples
docs/       Datasheet and project documentation
fpga/       Vivado FPGA flow (Kintex UltraScale+ KU5P)
syn/        OpenRAM + OpenLane2 synthesis and physical-design flow
```

## Quick Start

### 1) Clone the repository

> **Do not** use `git clone --recurse-submodules`. It would recursively pull
> `riscv-arch-test` → `riscv-unified-db` → `llvm-project` (~4 GB, not needed).

```bash
git clone https://github.com/kuoping/jv32.dev.git
cd jv32.dev
make submodule-init   # initializes submodules safely, skipping llvm-project
```

### 2) Configure the environment

```bash
cp env.config.template env.config
# edit env.config to point to your RISC-V tools / Verilator / ASIC flow tools
```

### 3) Build and run RTL simulation

```bash
make build-rtl
make rtl-hello
```

### 4) Run lint and regression checks

```bash
make lint
make compare-all
```

### 5) Run synthesis / P&R

```bash
cd syn
make openram-setup
make gen-mem
make synth
```

## Useful Targets

| Command | Purpose |
|---|---|
| `make submodule-init` | Initialize submodules safely (skips `llvm-project`) |
| `make build-rtl` | Build the Verilator SoC simulator |
| `make rtl-hello` | Run the `hello` bare-metal test on RTL |
| `make lint` | Run Verilator + style / declaration / reset checks |
| `make compare-all` | Compare RTL traces against the software model |
| `make arch-test-run` | Run the RISC-V architectural compliance suite |
| `cd syn && make synth` | Launch the OpenLane2 synthesis / P&R flow |

## Core Configuration

Hardware parameters are set in `Makefile.cfg` and can be overridden on the command line, e.g. `make FAST_MUL=0 rtl-hello`.

### ISA / Extensions

#### RV32EC minimum-area preset

Setting `RV32EC=1` activates the minimum-area configuration. It overrides all individual extension flags below with the following fixed values:

| Condition | Value | Effect |
|---|:---:|---|
| `RV32E_EN` | `1` | 16 GPRs (E-class register file) instead of 32 |
| `RV32M_EN` | `0` | M-extension disabled; MUL/DIV trap as illegal instruction |
| `AMO_EN` | `0` | A-extension disabled; all AMO instructions trap as illegal |
| `JTAG_EN` | `0` | JTAG debug transport removed from synthesis |
| `TRACE_EN` | `0` | Trace output registers removed (outputs tied to 0) |
| `BP_EN` | `0` | Branch predictor disabled; always-not-taken prediction |
| `FAST_SHIFT` | `0` | 1-bit-per-cycle serial barrel shifter (area-minimal) |

Use `make RV32EC=1 build-rtl` or set `RV32EC=1` in `Makefile.cfg`.

#### Individual extension flags

When `RV32EC=0` (the default), each flag can be set independently:

| Parameter | Default | Description |
|---|:---:|---|
| `RV32E_EN` | `0` | `1` = RV32E (16 GPRs); `0` = RV32I (32 GPRs) |
| `RV32M_EN` | `1` | `1` = include M-extension (MUL/DIV); `0` = illegal trap on MUL/DIV |
| `AMO_EN` | `1` | `1` = include A-extension (atomic ops); `0` = illegal trap on AMO |
| `JTAG_EN` | `1` | `1` = include JTAG debug interface; `0` = remove from synthesis |
| `TRACE_EN` | `1` | `1` = trace output registers present; `0` = outputs tied to 0 |

### Pipeline

| Parameter | Default | Description |
|---|---|---|
| `FAST_MUL` | `1` | `1` = fast multiplier (see `MUL_MC`); `0` = serial shift-and-add (variable latency) |
| `MUL_MC` | `1` | `1` = 2-stage pipelined multiply (2 cycles, better timing); `0` = 1-cycle combinatorial (requires `FAST_MUL=1`) |
| `FAST_DIV` | `0` | `1` = combinatorial divider; `0` = serial restoring divider (variable latency) |
| `FAST_SHIFT` | `1` | `1` = barrel shifter (1 cycle); `0` = 1-bit-per-cycle serial shifter |
| `BP_EN` | `1` | `1` = enable branch predictor; `0` = always-not-taken |

#### Multiplier configuration guide (Nangate 45 nm / FreePDK45)

The multiplier has three modes, selectable via `FAST_MUL` and `MUL_MC`:

| Mode | `FAST_MUL` | `MUL_MC` | Latency | Critical path | Recommendation |
|---|:---:|:---:|---|---|---|
| Serial shift-and-add | `0` | — | variable (up to 32 cycles) | minimal (FF-chain) | area-critical designs |
| 1-cycle combinatorial | `1` | `0` | 1 cycle | full 32×32 multiply tree | ≤ 75 MHz |
| 2-stage pipelined | `1` | `1` | 2 cycles | 16×16 partial-product stage | > 75 MHz |

**Selection advice:**

- **≤ 75 MHz target** — use `FAST_MUL=1 MUL_MC=0`.  The single-cycle combinatorial 32×32 multiply fits comfortably within a ~13 ns period and requires no pipeline stall overhead for most MUL instructions.
- **> 75 MHz target** — use `FAST_MUL=1 MUL_MC=1` (default).  Splitting the multiply into four 16×16 partial products halves the combinatorial depth; the pipeline absorbs the extra cycle as a 1-stall bubble.  No `set_multicycle_path` SDC exception is needed because each pipeline stage closes timing independently.
- The exact crossover frequency depends on place-and-route results; always run `make -C syn synth` for both settings and compare the post-PnR WNS/TNS reports to determine which is best for your target clock period.

### Memory Map

| Parameter | Default | Description |
|---|---|---|
| `IRAM_SIZE` | `131072` | Instruction SRAM size in bytes (power-of-2, max 512 KB) |
| `DRAM_SIZE` | `131072` | Data SRAM size in bytes (power-of-2, max 512 KB) |
| `BOOT_ADDR` | `0x80000000` | Reset vector address |
| `IRAM_BASE` | `0x80000000` | Instruction SRAM base address (normally == `BOOT_ADDR`) |
| `DRAM_BASE` | `0xC0000000` | Data SRAM base address |

### Simulation

| Parameter | Default | Description |
|---|---|---|
| `CLK_FREQ` | `80000000` | Simulation clock frequency in Hz |
| `TIMEOUT` | `120` | Wall-clock timeout in seconds (`0` = no limit); increase when using serial mul/div/shift |
| `MAX_CYCLES` | `0` | Stop RTL simulation after N cycles (`0` = unlimited) |
| `MAX_INSNS` | `0` | Stop software simulator after N instructions (`0` = unlimited) |
| `WAVE` | _(none)_ | Waveform format: `fst` or `vcd` |
| `TRACE` | _(none)_ | `1` = print RTL instruction trace to stdout |
| `DEBUG` | _(none)_ | `1` = level-1 messages; `2` = per-group messages |
| `DEBUG_GROUP` | _(none)_ | Bitmask of module groups to print (used with `DEBUG=2`) |

## Area Reference

Gate counts use hierarchical (non-flattening) synthesis on **Nangate 45 nm Open Cell Library (FreePDK45)**.
Reference cell: NAND2\_X1 = 0.7980 µm².
SRAM macros (`sram_1rw_2048x32`) are treated as black-boxes and excluded from the NAND2 equivalent count.

> Each module is optimised independently; cross-module sharing (as in a flat synthesis) may differ by ±5–10%.

### RV32EC=1 (minimum configuration)

`RV32E_EN=1, RV32M_EN=0, AMO_EN=0, JTAG_EN=0, TRACE_EN=0, BP_EN=0, FAST_SHIFT=0`

| Module | NAND2 eq | Area (µm²) |
|---|---:|---:|
| `jv32_soc` | 37,137 | 29,635.59 |
| ↳ `jv32_top` | 27,531 | 21,969.47 |
| &nbsp;&nbsp;↳ `jv32_core` | 23,833 | 19,018.73 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_regfile` | 5,779 | 4,611.91 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_csr` | 5,073 | 4,048.52 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_rvc` | 2,023 | 1,614.35 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_alu` | 1,636 | 1,305.79 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_decoder` | 308 | 246.05 |
| &nbsp;&nbsp;↳ `sram_1rw` _(black-box)_ | 84 | 66.77 |
| ↳ `axi_clic` | 5,257 | 4,195.35 |
| ↳ `axi_uart` | 3,774 | 3,011.65 |
| ↳ `axi_xbar` | 562 | 448.48 |
| ↳ `axi_magic` | 0 | 0.00 |
| **TOTAL** (logic, excl. SRAM macros) | **37,137** | **29,635.59** |

> The ~9,014 NAND2 gap between `jv32_core` (23,833) and the sum of its submodules (14,819) is pipeline logic
> instantiated directly in `jv32_core.sv`: pipeline registers (`if_ex_r`, `ex_wb_r`), PC control, forwarding
> muxes, branch evaluation/redirect, hazard control, load/store alignment, exception detection, and debug FSM.

#### Clock Gating — RV32EC=1

| Module | Total FFs | Gated FFs | Gated% |
|---|---:|---:|---:|
| `jv32_soc` | 2,548 | 2,234 | **87.7%** |
| ↳ `jv32_top` | 1,720 | 1,477 | 85.9% |
| &nbsp;&nbsp;↳ `jv32_core` | 1,372 | 1,206 | 87.9% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_regfile` | 480 | 480 | 100.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_csr` | 336 | 208 | 61.9% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_rvc` | 51 | 51 | 100.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_alu` | 79 | 78 | 98.7% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_decoder` | 0 | 0 | 0.0% |
| &nbsp;&nbsp;↳ `sram_1rw` | 1 | 0 | 0.0% |
| ↳ `axi_clic` | 361 | 297 | 82.3% |
| ↳ `axi_uart` | 396 | 393 | 99.2% |
| ↳ `axi_xbar` | 69 | 67 | 97.1% |
| ↳ `axi_magic` | 0 | 0 | 0.0% |

### RV32EC=0 (full / default configuration)

`RV32E_EN=0, RV32M_EN=1, AMO_EN=1, JTAG_EN=1, TRACE_EN=1, BP_EN=1, FAST_SHIFT=1, FAST_MUL=1, MUL_MC=1, IFETCH_PREADVANCE=1`

> Numbers below are from pre-P&R hierarchical synthesis (`make gate-count`).
> The post-P&R flat-optimised count is **80,386 NAND2-eq** (OpenLane2 run, 2026-04-26).

| Module | NAND2 eq | Area (µm²) |
|---|---:|---:|
| `jv32_soc` | 76,658 | 61,173.08 |
| ↳ `jv32_top` | 49,253 | 39,303.89 |
| &nbsp;&nbsp;↳ `jv32_core` | 45,554 | 36,351.83 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_alu` | 15,265 | 12,181.47 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_regfile` | 12,188 | 9,726.02 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_csr` | 5,020 | 4,005.96 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_rvc` | 2,046 | 1,632.97 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_decoder` | 313 | 250.04 |
| &nbsp;&nbsp;↳ `sram_1rw` _(black-box)_ | 84 | 66.77 |
| ↳ `jtag_top` | 15,837 | 12,637.66 |
| &nbsp;&nbsp;↳ `jtag_tap` | 15,837 | 12,637.66 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_dtm` | 15,624 | 12,468.22 |
| ↳ `axi_clic` | 5,281 | 4,214.24 |
| ↳ `axi_uart` | 3,772 | 3,010.06 |
| ↳ `axi_xbar` | 562 | 448.48 |
| ↳ `axi_magic` | 0 | 0.00 |
| **TOTAL** (logic, excl. SRAM macros) | **76,658** | **61,173.08** |

### Clock Gating — RV32EC=0

Clock gating uses `CLKGATE_X1` (Nangate 45 nm ICG cell).
The synthesis flow applies **multi-bit hierarchical clock gating**: one ICG cell per logical register group (`$adffe`/`$dffe` at the abstract-cell level, before bit-blasting), so a 32-bit pipeline register maps to 1 ICG + 32 DFFs rather than 32 ICG + 32 DFFs.

**Gated%** = Gated FFs / Total FFs, where Gated FFs are flip-flop cells whose clock is driven by a CLKGATE GCK output.

| Module | Total FFs | Gated FFs | Gated% |
|---|---:|---:|---:|
| `jv32_soc` | 5,498 | 4,466 | **81.2%** |
| ↳ `jv32_top` | 2,788 | 2,540 | 91.1% |
| &nbsp;&nbsp;↳ `jv32_core` | 2,440 | 2,269 | 93.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_regfile` | 992 | 992 | 100.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_alu` | 403 | 402 | 99.8% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_rvc` | 51 | 51 | 100.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_csr` | 336 | 208 | 61.9% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_decoder` | 0 | 0 | 0.0% |
| &nbsp;&nbsp;↳ `sram_1rw` | 1 | 0 | 0.0% |
| ↳ `jtag_top` | 1,772 | 1,061 | 59.9% |
| &nbsp;&nbsp;↳ `jtag_tap` | 1,772 | 1,061 | 59.9% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_dtm` | 1,756 | 1,050 | 59.8% |
| ↳ `axi_clic` | 361 | 297 | 82.3% |
| ↳ `axi_uart` | 396 | 393 | 99.2% |
| ↳ `axi_xbar` | 69 | 67 | 97.1% |
| ↳ `axi_magic` | 0 | 0 | 0.0% |

The overall 81.2% gating rate is close to the theoretical maximum given the architecturally ungatable registers below.

#### Why `jv32_csr` is lower (~62%)

The two performance counters — `mcycle_cnt` (64-bit) and `minstret_cnt` (64-bit) — account for the 128 ungated bits.  Their "enable" signal (`!mcountinhibit_cy` / `instret_inc`) is asserted almost every cycle during normal program execution, so the clock gate is perpetually open and synthesis may omit it:

```systemverilog
if (!mcountinhibit_cy) mcycle_cnt   <= mcycle_cnt + 64'd1;  // 64 ungated FFs
if (instret_inc && !mcountinhibit_ir) minstret_cnt <= minstret_cnt + 64'd1;  // 64 ungated FFs
```

All other CSR registers (`mepc`, `mtvec`, `mstatus`, `mie`, etc.) are gated under `exception || irq_pending || mret || csr_we`.  This is **architecturally correct** — a continuously-incrementing cycle counter is inherently always-active.

#### Why `jv32_dtm` is lower (~60%)

The DTM bridges two asynchronous clock domains (system `clk` ↔ JTAG `tck_i`).  CDC multi-stage synchronizer chains **must sample on every clock edge** to guarantee metastability resolution; gating their clock would defeat their purpose.  The ~703 ungated bits are entirely synchronizer pipeline stages:

| Synchronizer | Dir | Bits | Purpose |
|---|---|---:|---|
| `halt_req_sync_chain[3]`, `resume_req_sync_chain[3]` | TCK→CLK | 6 | JTAG halt/resume requests |
| `halted_tck_chain[3]`, `resumeack_tck_chain[3]` | CLK→TCK | 6 | core status back to JTAG |
| `sba_busy_tck_chain[3]`, `busy_tck_chain[3]` | CLK→TCK | 6 | SBA / cmd-busy back to JTAG |
| `sb_err_tck_chain[3×3]` | CLK→TCK | 9 | SBA error bits |
| `data0_result_sync[3]` (×32 b) | CLK→TCK | 96 | Abstract-command read-back |
| `sbdata0_result_sync[3]` (×32 b) | CLK→TCK | 96 | SBA read-data result |
| `sbaddress0_result_sync[3]` (×32 b) | CLK→TCK | 96 | SBA address result |
| Various `_valid_sync[3]` + `_r` | CLK→TCK | ~12 | handshake valid bits |

These ~327 bits toggle continuously during debug accesses.  This is **architecturally correct** — CDC synchronizers require free-running clocks.

## Documentation

- Datasheet source: `docs/jv32_soc_datasheet.adoc`
- Generated PDF: `docs/jv32_soc_datasheet.pdf`
- FPGA implementation notes: [fpga/README.md](fpga/README.md)
- ASIC flow notes: [syn/README.md](syn/README.md)
- Full P&R results report: [syn/REPORT.md](syn/REPORT.md)

## Synthesis & P&R Results (RV32EC=0)

**PDK:** FreePDK45 / Nangate 45 nm Open Cell Library — **Flow:** OpenLane2 (Classic) — **Date:** 2026-04-26

Configuration: `RV32EC=0`, `RV32M_EN=1`, `AMO_EN=1`, `JTAG_EN=1`, `TRACE_EN=1`, `FAST_MUL=1 (MUL_MC=1)`, `FAST_SHIFT=1`, `BP_EN=1`, 80 MHz clock, 16 KB IRAM + 16 KB DRAM.

> For the full hierarchy, timing, power, and DRC detail see [syn/REPORT.md](syn/REPORT.md).
> For gate counts and clock gating breakdown see [syn/README.md](syn/README.md).

### Floorplan

| Metric | Value |
|---|---|
| Die area | 4.500 mm² |
| Core area | 4.407 mm² |
| Standard cell area | 64,148 µm² |
| Macro area (SRAM) | 2,183,510 µm² |
| Std cell utilization | 2.89% |

### Logic area (pre-P&R hierarchical synthesis)

| Metric | Value |
|---|---|
| **jv32_soc** total | **76,658 NAND2-eq** (61,173 µm²) |
| ↳ jv32_core (logic only) | 45,554 NAND2-eq |
| ↳ jtag_top | 15,837 NAND2-eq |
| Post-P&R flat total | **80,386 NAND2-eq** |

### Timing (post-route STA, tt_025C_1v10)

| Check | WNS | TNS | |
|---|---|---|---|
| Setup | 0.000 ns | 0.000 ns | ✅ MET |
| Hold | 0.000 ns | 0.000 ns | ✅ MET |

### Power (tt_025C_1v10, 80 MHz)

| Domain | Total |
|---|---|
| Sequential | 4.08 mW |
| Combinational | 6.11 mW |
| Clock | 1.21 mW |
| Macro (SRAM) | 9.22 mW |
| **Total** | **20.61 mW** |

### DRC

Post-route DRC: **0 errors** ✅

## FPGA (Kintex UltraScale+ KU5P)

**Part:** `xcku5p-ffvb676-2-i` — **Tool:** Vivado ML Standard (free licence) — **Clock:** 50 MHz

Default debug interface: **cJTAG / 2-wire OScan1** (`USE_CJTAG=1`, overridable to 4-wire JTAG with `USE_CJTAG=0`).

```bash
cd fpga/
make impl              # cJTAG bitstream (default)
make impl USE_CJTAG=0  # 4-wire JTAG bitstream
```

See [fpga/README.md](fpga/README.md) for pin assignments, clock architecture, block design, and OpenOCD connection instructions.

## License

MIT — see [LICENSE](LICENSE).

