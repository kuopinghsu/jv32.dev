# Tool Requirements

All tool paths are configured in `env.config` (copied from `env.config.template` on first run).

## RTL Simulation (required for `make build-rtl`, `make rtl-*`, `make lint`)

| Tool | Min version | Notes |
|---|---|---|
| [Verilator](https://verilator.org) | 5.x | SystemVerilog simulator; set `VERILATOR=` in `env.config` |
| RISC-V toolchain | GCC 12+ | Bare-metal `riscv-none-elf-` or `riscv64-unknown-elf-`; set `RISCV_PREFIX=` in `env.config` |
| GNU Make | 4.x | Build system |
| Python 3 | 3.9+ | Required by lint helper scripts (`scripts/*.py`) |

## Lint (optional; skipped automatically if binary is absent or set to `None`)

| Tool | Notes |
|---|---|
| [Verible](https://github.com/chipsalliance/verible) | SystemVerilog style lint and formatter; set `VERIBLE=` / `VERIBLE_FORMAT=` in `env.config` |
| [svlint](https://github.com/dalance/svlint) | Structural / intent lint; set `SVLINT=` in `env.config` |

## Waveform viewing (optional)

| Tool | Notes |
|---|---|
| [GTKWave](https://gtkwave.sourceforge.net) | Required for `make wave`; set `GTKWAVE=` in `Makefile.cfg` |

## Architectural Compliance Tests (required for `make arch-test-run`)

Spike (ISA reference simulator) + uv (Python venv manager). Set `SPIKE=` in `env.config`. See [verif/README.md](verif/README.md) for full setup instructions.

## Debug Interface Tests (required for `make openocd-test`)

Patched OpenOCD fork ([kuopinghsu/openocd](https://github.com/kuopinghsu/openocd)) with VPI cJTAG support. Set `OPENOCD=` in `env.config`. See [openocd/README.md](openocd/README.md) for build and install instructions.

## Formal Verification (required for `make -C verif/formal`)

[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build/releases) (Yosys + SymbiYosys + Z3) — recommended all-in-one bundle. See [verif/README.md](verif/README.md) for install options.

## ASIC Synthesis and P&R (required for `make syn` / `make -C syn synth`)

Typical setup/run sequence:

1. `make -C syn syn-setup` (pre-fetch OpenLane2 Nix dependencies)
2. `make -C syn openram-setup`
3. `make -C syn gen-mem`
4. `make syn` (or `make -C syn synth`)

Optional post-flow targets:

- `make -C syn gate-count` (hierarchical gate count report)
- `make -C syn timing-report` (OpenROAD/OpenSTA timing report)

| Tool | Notes |
|---|---|
| [OpenLane2](https://github.com/efabless/openlane2) | Full RTL-to-GDS flow; set `OPENLANE=` in `env.config`; default launcher is `syn/scripts/openlane_nix.sh` |
| [OpenRAM](https://github.com/VLSIDA/OpenRAM) | SRAM macro compiler (1.2.x); set `OPENRAM=` in `env.config` |
| [OpenROAD](https://theopenroadproject.org) | Used by `make -C syn pnr` and `make -C syn timing-report`; set `OPENROAD=` in `env.config` |
| Nangate 45nm PDK | FreePDK45 Open Cell Library; set `NANGATE_HOME=` in `env.config`; download from [NCSU EDA](https://www.eda.ncsu.edu/wiki/FreePDK45) |
| [Nix](https://nixos.org) | `nix-shell` is used by `syn/scripts/openlane_nix.sh` and `syn/scripts/openroad_nix.sh` |
| Python 3 | 3.9+ | Required by OpenLane2 and synthesis helper scripts |

## FPGA (required for `make -C fpga impl`)

| Tool | Notes |
|---|---|
| [Vivado ML Standard](https://www.xilinx.com/support/download.html) | AMD/Xilinx toolchain for Kintex UltraScale+ KU5P; **free licence** (no cost) |
