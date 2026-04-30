# J<sub>V</sub>32 RISC-V SoC

<p align="center">
  <img src="docs/jv32-logo.svg" alt="JV32 logo" width="260">
</p>

This repository is part of a family of open-source RV32 cores targeting different cost/performance points:

| Core | Pipeline | ISA | Target | Status |
|---|---|---|---|---|
| **J<sub>V</sub>32** | 3-stage, single-issue | RV32IMAC + B (`Zba`/`Zbb`/`Zbs`) | Low-cost embedded processors | **This repo — active** |
| **K<sub>V</sub>32** | 5-stage, dual-issue | RV32IMAC + B + F/D (floating-point) | General-purpose processor | In development |
| **L<sub>V</sub>32** | 8-stage, dual-issue | RV32GC + Linux-capable MMU | Linux-capable application processor | In planning |

**J<sub>V</sub>32** is a compact **RV32IMAC** RISC-V system-on-chip for RTL simulation, software bring-up, and ASIC/FPGA experimentation. The project includes a 3-stage in-order core, tightly-coupled memories, AXI peripherals, JTAG debug support, verification flows, and an OpenRAM/OpenLane-based synthesis path.

## Table of Contents

- [Highlights](#highlights)
- [Performance](#performance)
- [Performance Features](#performance-features)
  - [Branch Predictor (`BP_EN`)](#branch-predictor-bp_en)
  - [Return Address Stack (`RAS_EN`)](#return-address-stack-ras_en)
  - [Instruction Prefetch Buffer (`IBUF_EN`)](#instruction-prefetch-buffer-ibuf_en)
  - [2-Entry Store Buffer](#2-entry-store-buffer)
  - [Multiplier (`FAST_MUL`, `MUL_MC`)](#multiplier-fast_mul-mul_mc)
  - [Divider (`FAST_DIV`)](#divider-fast_div)
  - [Barrel Shifter (`FAST_SHIFT`)](#barrel-shifter-fast_shift)
  - [WB→EX Same-Cycle Forwarding](#wbex-same-cycle-forwarding)
- [Repository Layout](#repository-layout)
- [Tool Requirements](#tool-requirements)
- [Quick Start](#quick-start)
  - [1) Clone the repository](#1-clone-the-repository)
  - [2) Configure the environment](#2-configure-the-environment)
  - [3) Build and run RTL simulation](#3-build-and-run-rtl-simulation)
  - [4) Run lint and regression checks](#4-run-lint-and-regression-checks)
  - [5) Run synthesis / P&R](#5-run-synthesis--pr)
- [Useful Targets](#useful-targets)
- [Core Configuration](#core-configuration)
- [RTOS Support](#rtos-support)
- [Verification](#verification)
  - [Summary](#summary)
  - [Regression (`make all`)](#regression-make-all)
  - [RISC-V Architectural Compliance Tests (`make arch-test-run`)](#risc-v-architectural-compliance-tests-make-arch-test-run)
  - [Debug Interface Tests (`make openocd-test`)](#debug-interface-tests-make-openocd-test)
  - [RTL Lint (`make lint`)](#rtl-lint-make-lint)
  - [ASIC Synthesis and P&R (`make -C syn synth`)](#asic-synthesis-and-pr-make--c-syn-synth)
  - [FPGA (`make -C fpga impl`)](#fpga-make--c-fpga-impl)
- [FPGA (Kintex UltraScale+ KU5P)](#fpga-kintex-ultrascale-ku5p)
- [Synthesis & P&R Results](#synthesis--pr-results)
- [Area Reference](#area-reference)
- [Coverage](#coverage)
- [Documentation](#documentation)
- [License](#license)

## Highlights

- **ISA:** RV32IMAC with `Zicsr` / `Zifencei`; optional B-extension (`Zba` / `Zbb` / `Zbs`)
- **Core:** 3-stage single-issue pipeline (`IF → EX → WB`)
- **Memory:** tightly-coupled `IRAM` and `DRAM`
- **Peripherals:** UART, CLIC/CLINT-style interrupt block, simulation magic device
- **Debug:** JTAG / cJTAG debug transport integration
- **Flows:** Verilator RTL simulation, trace comparison, arch tests, synthesis/P&R
- **Performance:** branch predictor (BTB + RAS), instruction prefetch buffer, store buffer, fast multiplier/divider/shifter — see [Performance Features](#performance-features)

## Performance

Measured on the Verilator RTL simulator at 80 MHz with maximum-performance settings
(`ARCH=rv32ima_zicsr_zba_zbb_zbs FAST_MUL=1 MUL_MC=0 FAST_DIV=1 FAST_SHIFT=1 BP_EN=1 IBUF_EN=1`).

| Benchmark | Score | CPI |
|---|---|---|
| CoreMark 1.0 | **3.80 CoreMark/MHz** | 1.093 |
| Dhrystone 2.1 | **1.77 DMIPS/MHz** | 1.245 |

See [docs/performance_analysis.pdf](docs/performance_analysis.pdf) for the full analysis,
including branch-predictor impact, B-extension impact, compressed-instruction overhead,
and CPI decomposition from RTL trace data.

## Performance Features

All features below are enabled by default and can be individually tuned or disabled via `Makefile.cfg`
or the `make` command line. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full parameter reference.

### Branch Predictor (`BP_EN`)

A static branch predictor combined with a return-address stack. When `BP_EN=1`:

- **Predict-taken for backward branches, predict-not-taken for forward branches** — evaluated in
  the IF stage before the instruction is decoded, so no extra fetch cycle is needed for predicted
  branches.
- **1-cycle flush penalty on misprediction** — the erroneously fetched IF-stage instruction is
  squashed and the correct PC is redirected in EX.
- **Disabled** (`BP_EN=0`): always-not-taken prediction; every taken branch pays 1 cycle.

```bash
make BP_EN=0 build-rtl   # disable branch predictor
```

### Return Address Stack (`RAS_EN`)

A 2-deep return address stack (RAS) that predicts the target of indirect jumps used as function
returns (`JALR ra`, `C.JR ra`, `C.JALR ra`):

- **Push** on `JAL`/`C.JAL` (call): saves `PC+4`/`PC+2` to the stack top.
- **Pop** on `JALR ra`/`C.JR ra` (return): reads the saved return address in IF and redirects
  the fetch, eliminating the normal 1-cycle JALR penalty for predicted returns.
- Automatically disabled (`RAS_ACTIVE=0`) when `RV32E_EN=1` (minimum-area preset).

```bash
make RAS_EN=0 build-rtl  # disable RAS, JALR always pays 1 cycle
```

### Instruction Prefetch Buffer (`IBUF_EN`)

A 2-entry instruction FIFO sits between the I-bus and the IF/EX pipeline register:

- Decouples the fetch bus from the pipeline so the core can issue the next fetch request one cycle
  ahead of when the instruction is needed, hiding 1-cycle I-memory latency bubbles.
- Allows a sequential fetch to proceed during a stall cycle (e.g. a load-use stall), so the next
  instruction is already in the buffer when the stall clears.
- AXI bus faults are serialised through the buffer and injected at the correct instruction slot.
- Automatically disabled for RV32E minimum configurations (`IBUF_ACTIVE = IBUF_EN && !RV32E_EN`).

```bash
make IBUF_EN=0 build-rtl  # disable prefetch buffer
```

### 2-Entry Store Buffer

A 2-slot store queue (head = drain, tail = enqueue) decouples store commits from D-bus availability:

- A retiring store writes into the buffer and the pipeline continues immediately — no stall waiting
  for the DRAM write to complete.
- The buffer drains to DRAM in the background; a subsequent load to the same address stalls until
  the conflicting store has drained (store-to-load forwarding is not implemented).
- Prevents D-bus contention: a store drain and a load request are serialised, with the load taking
  priority once the store slot has started.

The store buffer is always present and is not separately configurable.

### Multiplier (`FAST_MUL`, `MUL_MC`)

Three selectable implementations for `MUL`/`MULH`/`MULHSU`/`MULHU`:

| Mode | `FAST_MUL` | `MUL_MC` | Latency | Best for |
|---|:---:|:---:|---|---|
| Serial shift-and-add | `0` | — | variable (≤ 32 cycles) | minimum area |
| 1-cycle combinatorial | `1` | `0` | 1 cycle | ≤ 75 MHz targets |
| 2-stage pipelined | `1` | `1` | 2 cycles | > 75 MHz targets (default) |

```bash
make FAST_MUL=1 MUL_MC=0 build-rtl  # 1-cycle multiply
make FAST_MUL=0 build-rtl           # serial multiply (minimum area)
```

### Divider (`FAST_DIV`)

| Mode | `FAST_DIV` | Latency | Notes |
|---|:---:|---|---|
| Serial restoring divider | `0` | variable (≤ 33 cycles) | default; minimal area |
| Combinatorial divider | `1` | 1 cycle | large critical path |

```bash
make FAST_DIV=1 build-rtl  # 1-cycle combinatorial divide
```

### Barrel Shifter (`FAST_SHIFT`)

| Mode | `FAST_SHIFT` | Latency | Notes |
|---|:---:|---|---|
| Barrel shifter | `1` | 1 cycle | default |
| 1-bit-per-cycle serial | `0` | variable (≤ 31 cycles) | minimum area |

```bash
make FAST_SHIFT=0 build-rtl  # serial shifter
```

### WB→EX Same-Cycle Forwarding

The writeback stage forwards its result to the execute stage in the same cycle — register data
produced by instruction N is available to instruction N+1 without a stall. The only remaining
hazard is a **load-use** case (1 stall cycle): when a load is in WB and the immediately following
instruction reads the loaded register.

## Repository Layout

```text
rtl/        SystemVerilog RTL for the core, SoC, AXI peripherals, and memories
sw/         Bare-metal software tests and demos
testbench/  Verilator testbench wrapper and support code
sim/        C++ simulation utilities and disassembler support
verif/      RISC-V arch-test integration and verification flow
rtos/       FreeRTOS port and samples; Zephyr board/SoC port and samples
docs/       Datasheet and project documentation
fpga/       Vivado FPGA flow (Kintex UltraScale+ KU5P)
syn/        OpenRAM + OpenLane2 synthesis and physical-design flow
```

## Tool Requirements

All tool paths are configured in `env.config` (copied from `env.config.template` on first run). See [TOOLS.md](TOOLS.md) for the full per-flow tool list and install notes.

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
| `make rtl-freertos-all` | Build and run all FreeRTOS samples on RTL |
| `make compare-freertos-all` | RTL-vs-ISS trace comparison for all FreeRTOS samples |
| `make rtl-zephyr-all` | Build and run all Zephyr samples on RTL |
| `make compare-zephyr-all` | RTL-vs-ISS trace comparison for all Zephyr samples |
| `cd syn && make synth` | Launch the OpenLane2 synthesis / P&R flow |

## Core Configuration

Hardware parameters are set in `Makefile.cfg` and can be overridden on the command line:

```bash
make RV32EC=1 build-rtl            # minimum-area preset (RV32E, no M/A/JTAG)
make FAST_MUL=1 MUL_MC=0 rtl-hello # 1-cycle combinatorial multiplier
```

> Full parameter reference (ISA flags, pipeline, multiplier guide, memory map, simulation): [docs/CONFIGURATION.md](docs/CONFIGURATION.md)

## RTOS Support

JV32 supports two RTOS environments. Both run on the Verilator RTL simulator and are verified via RTL-vs-ISS trace comparison. All targets are included in `make all`.

| RTOS | Version | Port | Samples |
|---|---|---|---|
| **FreeRTOS** | V11.2.0 | `rtos/freertos/portable/RISC-V/` (machine-mode, CLINT timer) | `simple`, `perf`, `stress` |
| **Zephyr** | 4.4 | `rtos/zephyr/` (west module, CLIC driver) | `hello`, `simple`, `perf`, `stress`, `threads_sync`, `uart_echo` |

> Full build instructions, sample descriptions, and setup steps: [rtos/README.md](rtos/README.md)

## Verification

### Summary

| Target | Purpose |
|---|---|
| `make all` | Full regression — RTL sim, FreeRTOS, Zephyr, trace comparison, config variants, arch tests, OpenOCD |
| `make compare-all` | Compare RTL instruction traces against the software (JIT) simulator for all `sw/` tests |
| `make compare-freertos-all` | RTL-vs-ISS trace comparison for all FreeRTOS samples |
| `make compare-zephyr-all` | RTL-vs-ISS trace comparison for all Zephyr samples |
| `make lint` | RTL lint: Verilator, Verible, svlint, declaration order, FF reset |
| `make arch-test-run` | RISC-V ACT4 architectural compliance tests (details below) |
| `make openocd-test` | JTAG and cJTAG debug interface tests via OpenOCD + VPI (details below) |
| `make -C syn synth` | ASIC synthesis and P&R (see [syn/README.md](syn/README.md)) |
| `make -C fpga impl` | FPGA build — synthesis + place-and-route + bitstream (see [fpga/README.md](fpga/README.md)) |

### Regression (`make all`)

`make all` is the full end-to-end regression; it runs the following steps in order:

1. `rtl-all` — build and run every `sw/` test on the Verilator RTL simulator
2. `sim-all` — run every `sw/` test on the software (JIT) simulator
3. `compare-all` — compare RTL instruction traces against software simulator traces word-for-word
4. `rtl-freertos-all` / `sim-freertos-all` / `compare-freertos-all` — the same three steps for the FreeRTOS workloads
5. `rtl-zephyr-all` / `sim-zephyr-all` / `compare-zephyr-all` — the same three steps for the Zephyr workloads
6. `extra-tests` — repeat steps 1–3 for three additional RTL parameter combinations to exercise different multiplier/divider/shifter/branch-predictor paths
7. `arch-test-run` — RISC-V architectural compliance suite (see below)
8. `openocd-test` — JTAG + cJTAG debug interface tests (see below)

> `make -C syn synth` and `make -C fpga impl` are **not** included in `make all` because they require
> commercial/specialised EDA tools and can take several hours. Run them explicitly when needed.

### RISC-V Architectural Compliance Tests (`make arch-test-run`)

Verified against ACT4 ([riscv-non-isa/riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test)). Extensions: `I`, `M`, `Zaamo`, `Zalrsc`, `C/Zca`, `Zicsr`, `Zifencei`, `Zicntr`, `Zba/Zbb/Zbs`, `Sm`.

```bash
make arch-test-setup   # first-time setup
make arch-test-run
```

> Methodology, extension list, and I-jal-00 (256 KB IRAM) note: [verif/README.md](verif/README.md)

### Debug Interface Tests (`make openocd-test`)

Runs 22 Tcl test scripts against both 4-wire JTAG (`build/jv32vpi_jtag`) and 2-wire cJTAG/OScan1 (`build/jv32vpi_cjtag`) transports. Tests cover halt/resume, single-step, breakpoints, watchpoints, abstract register access, program buffer, SBA, reset/havereset, DCSR, DTMCS/DMI, and cJTAG-specific protocol sequences.

> Full test descriptions, VPI setup, and individual-test make targets: [openocd/README.md](openocd/README.md)

### RTL Lint (`make lint`)

Six passes: Verilator full-design + per-module, Python FF-reset and declaration-order checks, Verible, svlint.

### ASIC Synthesis and P&R (`make -C syn synth`)

Runs OpenLane2 with the Nangate 45 nm Open Cell Library (FreePDK45). See [syn/README.md](syn/README.md)
and the [Area Reference](#area-reference) section below for results.

### FPGA (`make -C fpga impl`)

Runs full synthesis, place-and-route, and bitstream generation using Vivado ML Standard Edition
(free licence). See [fpga/README.md](fpga/README.md) and the [FPGA](#fpga-kintex-ultrascale-ku5p)
section below for configuration and results.

## FPGA (Kintex UltraScale+ KU5P)

**Part:** `xcku5p-ffvb676-2-i` — **Tool:** Vivado ML Standard (free licence) — **Clock:** 50 MHz

Default debug interface: **cJTAG / 2-wire OScan1** (`USE_CJTAG=1`, overridable to 4-wire JTAG with `USE_CJTAG=0`).

```bash
cd fpga/
make impl              # cJTAG bitstream (default)
make impl USE_CJTAG=0  # 4-wire JTAG bitstream
```

See [fpga/README.md](fpga/README.md) for pin assignments, clock architecture, block design, and OpenOCD connection instructions.

## Synthesis & P&R Results

**PDK:** FreePDK45 / Nangate 45 nm — **Flow:** OpenLane2 (Classic) — **Date:** 2026-04-26
Config: `RV32EC=0`, `RV32M_EN=1`, `AMO_EN=1`, `JTAG_EN=1`, `TRACE_EN=1`, `FAST_MUL=1 (MUL_MC=1)`, `FAST_SHIFT=1`, `BP_EN=1`, 80 MHz, 16 KB IRAM + 16 KB DRAM.

| Metric | Value |
|---|---|
| Standard cell area | 64,148 µm² |
| Logic (pre-P&R) | 78,090 NAND2-eq · post-P&R flat: **80,386 NAND2-eq** |
| Timing | Setup ✅ MET · Hold ✅ MET (80 MHz, tt_025C_1v10) |
| Total power | **20.61 mW** (seq 4.08 + comb 6.11 + clk 1.21 + SRAM 9.22) |
| DRC | **0 errors** ✅ |

> Full floorplan, timing, power, DRC, and P&R detail: [syn/REPORT.md](syn/REPORT.md)
> Gate count hierarchy and clock gating breakdown: [syn/README.md](syn/README.md)

## Area Reference

Gate counts from hierarchical Yosys synthesis on Nangate 45 nm (NAND2\_X1 = 0.7980 µm²). SRAM macros excluded.

| Config | jv32_soc | jv32_core | jv32_top |
|---|---:|---:|---:|
| RV32EC=1 (minimum) | 38,731 NAND2-eq | 25,491 | 29,191 |
| RV32EC=0 (full, default) | 78,090 NAND2-eq | 47,049 | 50,749 |

> Per-module hierarchy, FF counts, and clock gating breakdown: [syn/README.md](syn/README.md)

## Coverage

Verilator line + branch + expression + toggle coverage over all `sw/` tests and 7 JTAG debug scenarios (`make coverage`).  Testbench wrappers and `axi_magic` are excluded.

**Overall (2026-04-29):** lines **89.8%** · branches **70.2%** · expressions **80.9%** · toggles **71.4%**

> Per-file line and branch tables, full test suite details: [docs/COVERAGE.md](docs/COVERAGE.md)
> HTML report: `build/coverage/html/index.html` (regenerate with `make coverage`)

## Documentation

- Tool requirements: [TOOLS.md](TOOLS.md)
- Core configuration reference: [docs/CONFIGURATION.md](docs/CONFIGURATION.md)
- Performance features (branch predictor, store buffer, multiplier modes, …): [Performance Features](#performance-features)
- Datasheet source: `docs/jv32_soc_datasheet.adoc`
- Generated PDF: `docs/jv32_soc_datasheet.pdf`
- Performance analysis: [docs/performance_analysis.pdf](docs/performance_analysis.pdf)
- RTOS (FreeRTOS & Zephyr): [rtos/README.md](rtos/README.md)
- Verification (arch-test & formal): [verif/README.md](verif/README.md)
- Debug interface tests (OpenOCD): [openocd/README.md](openocd/README.md)
- Coverage report: [docs/COVERAGE.md](docs/COVERAGE.md)
- FPGA implementation notes: [fpga/README.md](fpga/README.md)
- ASIC flow notes: [syn/README.md](syn/README.md)
- Full P&R results report: [syn/REPORT.md](syn/REPORT.md)

## License

MIT — see [LICENSE](LICENSE).

