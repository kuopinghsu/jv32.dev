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
| `jv32_soc` | 41,207 | 32,882.92 |
| ↳ `jv32_top` | 30,470 | 24,314.79 |
| &nbsp;&nbsp;↳ `jv32_core` | 26,206 | 20,912.12 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_regfile` | 6,928 | 5,528.54 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_csr` | 5,391 | 4,302.28 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_rvc` | 2,412 | 1,924.51 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_alu` | 1,770 | 1,412.73 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_decoder` | 307 | 245.25 |
| &nbsp;&nbsp;↳ `sram_1rw` _(black-box)_ | 84 | 66.77 |
| ↳ `axi_clic` | 5,713 | 4,559.24 |
| ↳ `axi_uart` | 4,321 | 3,448.16 |
| ↳ `axi_xbar` | 689 | 550.09 |
| ↳ `axi_magic` | 0 | 0.00 |
| **TOTAL** (logic, excl. SRAM macros) | **41,207** | **32,882.92** |

> The ~9,400 NAND2 gap between `jv32_core` (26,206) and the sum of its submodules (16,808) is pipeline logic
> instantiated directly in `jv32_core.sv`: pipeline registers (`if_ex_r`, `ex_wb_r`), PC control, forwarding
> muxes, branch evaluation/redirect, hazard control, load/store alignment, exception detection, and debug FSM.

### RV32EC=0 (full / default configuration)

`RV32E_EN=0, RV32M_EN=1, AMO_EN=1, JTAG_EN=1, TRACE_EN=1, BP_EN=1, FAST_SHIFT=1, FAST_MUL=1, MUL_MC=1, N_TRIGGERS=2`

| Module | NAND2 eq | Area (µm²) |
|---|---:|---:|
| `jv32_soc` | 84,635 | 67,538.46 |
| ↳ `jv32_top` | 54,460 | 43,459.08 |
| &nbsp;&nbsp;↳ `jv32_core` | 50,168 | 40,034.33 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_regfile` | 14,288 | 11,402.09 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_alu` | 15,999 | 12,766.94 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_csr` | 5,451 | 4,349.90 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_rvc` | 2,410 | 1,922.91 |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ `jv32_decoder` | 293 | 233.55 |
| &nbsp;&nbsp;↳ `sram_1rw` _(black-box)_ | 84 | 66.77 |
| ↳ `jtag_top` | 17,295 | 13,801.41 |
| &nbsp;&nbsp;↳ `jv32_dtm` | 17,088 | 13,636.22 |
| ↳ `axi_clic` | 5,699 | 4,547.80 |
| ↳ `axi_uart` | 4,315 | 3,443.37 |
| ↳ `axi_xbar` | 689 | 550.09 |
| ↳ `axi_magic` | 0 | 0.00 |
| **TOTAL** (logic, excl. SRAM macros) | **84,635** | **67,538.46** |

> Compared to RV32EC=1 (41,207 NAND2), the full configuration is ~2× larger, with the main contributors being:
> `jv32_regfile` (+7,360, 32 vs 16 GPRs), `jv32_alu` (+14,229, M+A extensions + barrel shifter),
> `jv32_dtm` (+17,088, JTAG debug module).

## Documentation

- Datasheet source: `docs/jv32_soc_datasheet.adoc`
- Generated PDF: `docs/jv32_soc_datasheet.pdf`
- ASIC flow notes: `syn/README.md`

## Notes

J<sub>V</sub>32 is geared toward **educational use, verification, and implementation exploration**. The repository is organized so the same RTL can be exercised in software simulation, RTL regression, and downstream synthesis flows.
