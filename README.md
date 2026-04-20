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

### Pipeline

| Parameter | Default | Description |
|---|---|---|
| `FAST_MUL` | `1` | `1` = combinatorial multiplier; `0` = serial shift-and-add (variable latency) |
| `FAST_DIV` | `0` | `1` = combinatorial divider; `0` = serial restoring divider (variable latency) |
| `FAST_SHIFT` | `1` | `1` = barrel shifter (1 cycle); `0` = 1-bit-per-cycle serial shifter |
| `BP_EN` | `1` | `1` = enable branch predictor; `0` = always-not-taken |

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

## Documentation

- Datasheet source: `docs/jv32_soc_datasheet.adoc`
- Generated PDF: `docs/jv32_soc_datasheet.pdf`
- ASIC flow notes: `syn/README.md`

## Notes

J<sub>V</sub>32 is geared toward **educational use, verification, and implementation exploration**. The repository is organized so the same RTL can be exercised in software simulation, RTL regression, and downstream synthesis flows.
