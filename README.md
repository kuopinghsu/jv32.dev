# J<sub>V</sub>32 RISC-V SoC

<p align="center">
  <img src="docs/jv32-logo.svg" alt="JV32 logo" width="260">
</p>

J<sub>V</sub>32 is a compact **RV32IMAC** RISC-V system-on-chip for RTL simulation, software bring-up, and ASIC/FPGA experimentation. The project includes a 3-stage in-order core, tightly-coupled memories, AXI peripherals, JTAG debug support, verification flows, and an OpenRAM/OpenLane-based synthesis path.

## Highlights

- **ISA:** RV32IMAC with `Zicsr` / `Zifencei`; optional B-extension (`Zba` / `Zbb` / `Zbs`)
- **Core:** 3-stage single-issue pipeline (`IF → EX → WB`)
- **Memory:** tightly-coupled `IRAM` and `DRAM`
- **Peripherals:** UART, CLIC/CLINT-style interrupt block, simulation magic device
- **Debug:** JTAG / cJTAG debug transport integration
- **Flows:** Verilator RTL simulation, trace comparison, arch tests, synthesis/P&R

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

## Tool Requirements

All tool paths are configured in `env.config` (copied from `env.config.template` on first run).

### RTL Simulation (required for `make build-rtl`, `make rtl-*`, `make lint`)

| Tool | Min version | Notes |
|---|---|---|
| [Verilator](https://verilator.org) | 5.x | SystemVerilog simulator; set `VERILATOR=` in `env.config` |
| RISC-V toolchain | GCC 12+ | Bare-metal `riscv-none-elf-` or `riscv64-unknown-elf-`; set `RISCV_PREFIX=` in `env.config` |
| GNU Make | 4.x | Build system |
| Python 3 | 3.9+ | Required by lint helper scripts (`scripts/*.py`) |

### Lint (optional; skipped automatically if binary is absent or set to `None`)

| Tool | Notes |
|---|---|
| [Verible](https://github.com/chipsalliance/verible) | SystemVerilog style lint and formatter; set `VERIBLE=` / `VERIBLE_FORMAT=` in `env.config` |
| [svlint](https://github.com/dalance/svlint) | Structural / intent lint; set `SVLINT=` in `env.config` |

### Waveform viewing (optional)

| Tool | Notes |
|---|---|
| [GTKWave](https://gtkwave.sourceforge.net) | Required for `make wave`; set `GTKWAVE=` in `Makefile.cfg` |

### Architectural Compliance Tests (required for `make arch-test-run`)

| Tool | Notes |
|---|---|
| [Spike](https://github.com/riscv-software-src/riscv-isa-sim) | RISC-V ISA reference simulator; set `SPIKE=` in `env.config` |
| [uv](https://docs.astral.sh/uv/) | Python package/venv manager for the ACT4 framework; auto-installed by `make arch-test-setup` if absent |
| Git | Required to clone the `riscv-arch-test` submodule during `make arch-test-setup` |

### Debug Interface Tests (required for `make openocd-test`)

| Tool | Notes |
|---|---|
| [OpenOCD](https://github.com/kuopinghsu/openocd) | **Patched fork required** for cJTAG VPI support; set `OPENOCD=` in `openocd/Makefile` or PATH |

Build the patched OpenOCD:

```bash
git clone https://github.com/kuopinghsu/openocd
cd openocd && ./bootstrap
./configure --prefix=/usr/local --disable-werror --enable-internal-jimtcl
make -j$(nproc) && sudo make install
```

### Formal Verification (required for `make -C verif/formal`)

| Tool | Min version | Notes |
|---|---|---|
| [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build/releases) | 2024-01+ | All-in-one bundle containing Yosys, SymbiYosys, Z3, Boolector, and related solvers; **recommended install method** |
| [Yosys](https://github.com/YosysHQ/yosys) | 0.36+ | RTL synthesis front-end for formal; included in OSS CAD Suite |
| [SymbiYosys (`sby`)](https://github.com/YosysHQ/sby) | 0.36+ | BMC/induction task runner; included in OSS CAD Suite |
| [Z3](https://github.com/Z3Prover/z3) | 4.12+ | SMT solver back-end used by `smtbmc`; included in OSS CAD Suite |

**Quick install via OSS CAD Suite (Linux x86-64):**

```bash
# Download and extract the latest nightly release
SUITE_VER=$(curl -s https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest \
            | grep tag_name | cut -d'"' -f4)
wget https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${SUITE_VER}/oss-cad-suite-linux-x64-${SUITE_VER#*-}.tgz
tar xf oss-cad-suite-linux-x64-*.tgz -C ~/opt
# Add to PATH (add this line to ~/.bashrc for permanent use)
source ~/opt/oss-cad-suite/environment
```

**Alternative — install individual packages (Ubuntu/Debian):**

> **Note:** `sby` is not a Python package and cannot be installed via pip.
> Install it from source using `make install`:

```bash
# Yosys and Z3 from apt (Ubuntu 22.04+)
sudo apt install yosys z3
# SymbiYosys (sby) from GitHub source — uses make install, not pip
git clone https://github.com/YosysHQ/sby && cd sby && sudo make install
```

> The `apt` Yosys may be too old for some formal features. If you encounter issues,
> prefer the OSS CAD Suite bundle above.

### ASIC Synthesis and P&R (required for `make -C syn synth`)

| Tool | Notes |
|---|---|
| [OpenLane2](https://github.com/efabless/openlane2) | Full RTL-to-GDS flow; set `OPENLANE=` in `env.config`; Nix-based setup recommended |
| [OpenRAM](https://github.com/VLSIDA/OpenRAM) | SRAM macro compiler (1.2.x); set `OPENRAM=` in `env.config` |
| [OpenROAD](https://theopenroadproject.org) | P&R engine bundled with OpenLane2 / Nix; set `OPENROAD=` in `env.config` |
| Nangate 45nm PDK | FreePDK45 Open Cell Library; set `NANGATE_HOME=` in `env.config`; download from [NCSU EDA](https://www.eda.ncsu.edu/wiki/FreePDK45) |
| [Nix](https://nixos.org) | Package manager used by the OpenLane2 Nix shell wrapper (`syn/scripts/openlane_nix.sh`) |
| Python 3 | 3.9+ | Required by OpenLane2 and synthesis helper scripts |

### FPGA (required for `make -C fpga impl`)

| Tool | Notes |
|---|---|
| [Vivado ML Standard](https://www.xilinx.com/support/download.html) | AMD/Xilinx toolchain for Kintex UltraScale+ KU5P; **free licence** (no cost) |

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
| `RV32B_EN` | `1` | `1` = include B-extension (Zba/Zbb/Zbs); `0` = bit-manipulation instructions trap as illegal |
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

## Verification

### Summary

| Target | Purpose |
|---|---|
| `make all` | Full regression — RTL sim, FreeRTOS, trace comparison, config variants, arch tests, OpenOCD |
| `make compare-all` | Compare RTL instruction traces against the software (JIT) simulator for all `sw/` tests |
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
5. `extra-tests` — repeat steps 1–3 for three additional RTL parameter combinations to exercise different multiplier/divider/shifter/branch-predictor paths
6. `arch-test-run` — RISC-V architectural compliance suite (see below)
7. `openocd-test` — JTAG + cJTAG debug interface tests (see below)

> `make -C syn synth` and `make -C fpga impl` are **not** included in `make all` because they require
> commercial/specialised EDA tools and can take several hours. Run them explicitly when needed.

### RISC-V Architectural Compliance Tests (`make arch-test-run`)

JV32 is verified against the **RISC-V Architectural Compliance Test suite v4 (ACT4)** from
[riscv-non-isa/riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test).

#### One-time setup

```bash
make arch-test-setup   # clone riscv-arch-test submodule and install Python venv (uv)
```

#### Running the tests

```bash
make arch-test-run
```

#### Test methodology

The arch-test run proceeds in three phases:

1. **Build RTL simulator** — `build/jv32soc` is recompiled with `IRAM_SIZE=262144` (256 KB) to
   accommodate the largest test (see _I-jal-00_ below). The default `IRAM_SIZE` in `Makefile.cfg`
   is unchanged.

2. **Generate self-checking ELFs** — ACT4 compiles each test to a self-checking ELF. During this
   phase, **Spike** (the RISC-V ISA reference simulator) also runs each test and dumps a golden
   memory signature for the region `begin_signature`…`end_signature`.

3. **Run on JV32 RTL** — `run_tests.py` loads each ELF on to `build/jv32soc`. The RTL simulator
   polls the `tohost` MMIO word; when the test program writes `1` (pass) or `(exit_code << 1) | 1`
   (fail/timeout), the simulator exits and dumps its own memory signature. The two signatures are
   compared word-for-word: any mismatch is a compliance failure.

Configure your Spike binary in `env.config`:

```ini
SPIKE=$(HOME)/opt/riscv/bin/spike
```

#### Extensions covered

| Extension | Notes |
|---|---|
| `I` | Base integer instruction set (RV32I) |
| `M` | Integer multiply and divide |
| `Zaamo` / `Zalrsc` | Atomic memory operations (AMO and LR/SC subsets) |
| `C` / `Zca` | Compressed (16-bit) instructions |
| `Zicsr` | Control and status register instructions |
| `Zifencei` | Instruction-fetch fence |
| `Zicntr` | Base counters and timers (`cycle`, `time`, `instret`) |
| `Zba` / `Zbb` / `Zbs` | B-extension: address generation, basic bit manipulation, single-bit instructions (enabled by `RV32B_EN=1`) |
| `Sm` | Machine-mode privileged architecture |

Supervisor mode (`S`), PMP, and virtual-memory extensions are excluded because JV32 is M-mode only
with no MMU and no PMP.

#### I-jal-00: 256 KB IRAM requirement

The `I-jal-00` test places its `.text` segment at `0x80004000` and extends approximately 0x1C080
bytes, ending just past the default 128 KB IRAM boundary (`0x80020000`). All other tests fit within
128 KB.

`verif/Makefile` automatically overrides `IRAM_SIZE=262144` (256 KB) when building the RTL
simulator for arch-test runs. The default simulator and all other `make` targets continue to use the
128 KB default from `Makefile.cfg`.

### Debug Interface Tests (`make openocd-test`)

`make openocd-test` builds two Verilator VPI testbench variants and runs all Tcl test scripts in
`openocd/` against both debug transports:

| Mode | Transport | Simulator binary |
|---|---|---|
| JTAG | 4-wire IEEE 1149.1 | `build/jv32vpi_jtag` |
| cJTAG | 2-wire OScan1 (IEEE 1149.7) | `build/jv32vpi_cjtag` |

Tests cover: halt/resume, single-step, breakpoints, watchpoints, abstract register access, program
buffer execution, system bus access (SBA), reset and `havereset` behaviour, DCSR fields, DTMCS/DMI
registers, and cJTAG-specific protocol sequences.

#### Patched OpenOCD required

Standard OpenOCD does not include VPI-based cJTAG simulation support. Use the patched fork:

```bash
git clone https://github.com/kuopinghsu/openocd
cd openocd
./bootstrap
./configure --enable-jtag_vpi --enable-cjtag_vpi
make -j$(nproc)
sudo make install    # or set OPENOCD= in env.config
```

### RTL Lint (`make lint`)

`make lint` runs six passes in sequence:

| Pass | Tool | Checks |
|---|---|---|
| `lint-full` | Verilator | Full-design lint with all warnings and `-Werror-IMPLICIT` |
| `lint-modules` | Verilator | Each module linted as an independent top (catches `MULTIDRIVEN` etc.) |
| `lint-decl` | Python script | Signal use-before-declare order |
| `lint-ffreset` | Python script | Flip-flop reset completeness |
| `lint-verible` | Verible | SystemVerilog style and formatting rules |
| `lint-svlint` | svlint | Structural / intent lint rules |

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
| **jv32_soc** total | **78,090 NAND2-eq** (62,316 µm²) |
| ↳ jv32_core (logic only) | 47,049 NAND2-eq |
| ↳ jtag_top | 15,846 NAND2-eq |
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

## Area Reference

Gate counts use hierarchical (non-flattening) synthesis on **Nangate 45 nm Open Cell Library (FreePDK45)**.
Reference cell: NAND2\_X1 = 0.7980 µm².
SRAM macros (`sram_1rw_2048x32`) are treated as black-boxes and excluded from the NAND2 equivalent count.

> Each module is optimised independently; cross-module sharing (as in a flat synthesis) may differ by ±5–10%.

### RV32EC=1 (minimum configuration)

`RV32E_EN=1, RV32M_EN=0, AMO_EN=0, JTAG_EN=0, TRACE_EN=0, BP_EN=0, FAST_SHIFT=0`

| Module | NAND2 eq | Area (µm²) |
|---|---:|---:|
| `jv32_soc` | 38,731 | 30,907.60 |
| ↳ `jv32_top` | 29,191 | 23,294.42 |
| &nbsp;&nbsp;↳ `jv32_core` | 25,491 | 20,342.08 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_regfile` | 5,765 | 4,600.47 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_csr` | 5,048 | 4,028.04 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_rvc` | 2,041 | 1,628.72 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_alu` | 1,636 | 1,305.79 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_decoder` | 307 | 244.99 |
| &nbsp;&nbsp;↳ `sram_1rw` _(black-box)_ | 84 | 66.77 |
| ↳ `axi_clic` | 5,257 | 4,195.35 |
| ↳ `axi_uart` | 3,701 | 2,953.13 |
| ↳ `axi_xbar` | 568 | 453.00 |
| ↳ `axi_magic` | 0 | 0.00 |
| **TOTAL** (logic, excl. SRAM macros) | **38,731** | **30,907.60** |

> The ~10,694 NAND2 gap between `jv32_core` (25,491) and the sum of its submodules (14,797) is pipeline logic
> instantiated directly in `jv32_core.sv`: pipeline registers (`if_ex_r`, `ex_wb_r`), PC control, forwarding
> muxes, branch evaluation/redirect, hazard control, load/store alignment, exception detection, and debug FSM.

#### Clock Gating — RV32EC=1

| Module | Total FFs | Gated FFs | Gated% |
|---|---:|---:|---:|
| `jv32_soc` | 2,674 | 2,358 | **88.2%** |
| ↳ `jv32_top` | 1,856 | 1,612 | 86.9% |
| &nbsp;&nbsp;↳ `jv32_core` | 1,508 | 1,341 | 88.9% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_regfile` | 480 | 480 | 100.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_csr` | 336 | 208 | 61.9% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_rvc` | 51 | 51 | 100.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_alu` | 79 | 78 | 98.7% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_decoder` | 0 | 0 | 0.0% |
| &nbsp;&nbsp;↳ `sram_1rw` | 1 | 0 | 0.0% |
| ↳ `axi_clic` | 361 | 297 | 82.3% |
| ↳ `axi_uart` | 386 | 382 | 99.0% |
| ↳ `axi_xbar` | 69 | 67 | 97.1% |
| ↳ `axi_magic` | 0 | 0 | 0.0% |

### RV32EC=0 (full / default configuration)

`RV32E_EN=0, RV32M_EN=1, AMO_EN=1, JTAG_EN=1, TRACE_EN=1, BP_EN=1, FAST_SHIFT=1, FAST_MUL=1, MUL_MC=1`

> Numbers below are from pre-P&R hierarchical synthesis (`make gate-count`).
> The post-P&R flat-optimised count is **80,386 NAND2-eq** (OpenLane2 run, 2026-04-26).

| Module | NAND2 eq | Area (µm²) |
|---|---:|---:|
| `jv32_soc` | 78,090 | 62,315.82 |
| ↳ `jv32_top` | 50,749 | 40,497.44 |
| &nbsp;&nbsp;↳ `jv32_core` | 47,049 | 37,545.10 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_alu` | 15,238 | 12,160.19 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_regfile` | 12,190 | 9,727.35 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_csr` | 5,008 | 3,996.65 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_rvc` | 2,046 | 1,632.97 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_decoder` | 314 | 250.57 |
| &nbsp;&nbsp;↳ `sram_1rw` _(black-box)_ | 84 | 66.77 |
| ↳ `jtag_top` | 15,846 | 12,645.37 |
| &nbsp;&nbsp;↳ `jtag_tap` | 15,846 | 12,645.37 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_dtm` | 15,634 | 12,475.93 |
| ↳ `axi_clic` | 5,281 | 4,214.24 |
| ↳ `axi_uart` | 3,693 | 2,947.28 |
| ↳ `axi_xbar` | 568 | 453.00 |
| ↳ `axi_magic` | 0 | 0.00 |
| **TOTAL** (logic, excl. SRAM macros) | **78,090** | **62,315.82** |

### Clock Gating — RV32EC=0

Clock gating uses `CLKGATE_X1` (Nangate 45 nm ICG cell).
The synthesis flow applies **multi-bit hierarchical clock gating**: one ICG cell per logical register group (`$adffe`/`$dffe` at the abstract-cell level, before bit-blasting), so a 32-bit pipeline register maps to 1 ICG + 32 DFFs rather than 32 ICG + 32 DFFs.

**Gated%** = Gated FFs / Total FFs, where Gated FFs are flip-flop cells whose clock is driven by a CLKGATE GCK output.

| Module | Total FFs | Gated FFs | Gated% |
|---|---:|---:|---:|
| `jv32_soc` | 5,624 | 4,590 | **81.6%** |
| ↳ `jv32_top` | 2,924 | 2,675 | 91.5% |
| &nbsp;&nbsp;↳ `jv32_core` | 2,576 | 2,404 | 93.3% |
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
| ↳ `axi_uart` | 386 | 382 | 99.0% |
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

## Coverage

Verilator line + branch coverage measured by running all `sw/` tests and 7 JTAG debug scenarios
(`make coverage`).  Testbench wrappers (`tb_jv32_soc`, `uart_loopback`) and the simulation-only
`axi_magic` device are excluded with `/* verilator coverage_off */`.

**Overall (2026-04-28):** lines **90.1%** · branches **69.9%** · expressions **80.5%** · toggles **69.7%**

| Module | Lines | Branch |
|---|---:|---:|
| `jv32_alu.sv` | 97.7% | — |
| `jv32_regfile.sv` | 100.0% | — |
| `jv32_rvc.sv` | 97.1% | — |
| `jv32_decoder.sv` | 95.5% | — |
| `jv32_top.sv` | 95.5% | — |
| `axi_uart.sv` | 94.3% | — |
| `jv32_core.sv` | 92.8% | — |
| `axi_xbar.sv` | 92.3% | — |
| `axi_clic.sv` | 91.8% | — |
| `jv32_csr.sv` | 90.2% | — |
| `jtag_tap.sv` | 89.3% | — |
| `jtag_top.sv` | 87.1% | — |
| `jv32_soc.sv` | 84.9% | — |
| `jv32_dtm.sv` | 75.5% | — |
| `sram_1rw.sv` | 100.0% | — |

> `jv32_dtm` is lower because JTAG tests cover the halt/resume, programbuf, SBA, step, abstract
> register, trigger, and debug-error flows but leave several rarely-exercised error-recovery paths
> untested.  Run `make coverage` to regenerate; HTML report is written to `build/coverage/html/`.

## Documentation

- Datasheet source: `docs/jv32_soc_datasheet.adoc`
- Generated PDF: `docs/jv32_soc_datasheet.pdf`
- Performance analysis: [docs/performance_analysis.pdf](docs/performance_analysis.pdf)
- FPGA implementation notes: [fpga/README.md](fpga/README.md)
- ASIC flow notes: [syn/README.md](syn/README.md)
- Full P&R results report: [syn/REPORT.md](syn/REPORT.md)

## License

MIT — see [LICENSE](LICENSE).

