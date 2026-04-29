# JV32 Verification

This directory contains the RISC-V Architectural Compliance Test (ACT4) infrastructure and formal verification flows.

```
verif/
├── Makefile                    # ACT4 build/run orchestration
├── sail_spike_wrapper.sh.in    # Spike wrapper template for ACT4 reference model
├── config/                     # ACT4 DUT/reference model configuration
├── riscv-arch-test/            # ACT4 submodule (cloned by make arch-test-setup)
└── formal/
    ├── Makefile
    ├── gen_flat_csr.py         # Flattens jv32_csr + packages for SymbiYosys
    ├── jv32_csr.sby            # SymbiYosys configuration
    ├── jv32_csr_bind.sv        # SVA bind file
    └── jv32_csr_flat.sv        # Generated flat source (created by gen_flat_csr.py)
```

---

## RISC-V Architectural Compliance Tests (`make arch-test-run`)

JV32 is verified against the **RISC-V Architectural Compliance Test suite v4 (ACT4)** from
[riscv-non-isa/riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test).

### Tool requirements

| Tool | Notes |
|---|---|
| [Spike](https://github.com/riscv-software-src/riscv-isa-sim) | RISC-V ISA reference simulator; set `SPIKE=` in `env.config` |
| [uv](https://docs.astral.sh/uv/) | Python package/venv manager for the ACT4 framework; auto-installed by `make arch-test-setup` if absent |
| Git | Required to clone the `riscv-arch-test` submodule during `make arch-test-setup` |

Configure your Spike binary in `env.config`:

```ini
SPIKE=$(HOME)/opt/riscv/bin/spike
```

### One-time setup

```bash
make arch-test-setup   # clone riscv-arch-test submodule and install Python venv (uv)
```

### Running

```bash
make arch-test-run
```

### Test methodology

The arch-test run proceeds in three phases:

1. **Build RTL simulator** — `build/jv32soc` is recompiled with `IRAM_SIZE=262144` (256 KB) to
   accommodate the largest test (see _I-jal-00_ below). The default `IRAM_SIZE` in `Makefile.cfg`
   is unchanged.

2. **Generate self-checking ELFs** — ACT4 compiles each test to a self-checking ELF. During this
   phase, **Spike** also runs each test and dumps a golden memory signature for the region
   `begin_signature`…`end_signature`.

3. **Run on JV32 RTL** — `run_tests.py` loads each ELF on to `build/jv32soc`. The RTL simulator
   polls the `tohost` MMIO word; when the test program writes `1` (pass) or `(exit_code << 1) | 1`
   (fail/timeout), the simulator exits and dumps its own memory signature. The two signatures are
   compared word-for-word: any mismatch is a compliance failure.

### Extensions covered

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

### I-jal-00: 256 KB IRAM requirement

The `I-jal-00` test places its `.text` segment at `0x80004000` and extends approximately 0x1C080
bytes, ending just past the default 128 KB IRAM boundary (`0x80020000`). All other tests fit within
128 KB.

`verif/Makefile` automatically overrides `IRAM_SIZE=262144` (256 KB) when building the RTL
simulator for arch-test runs. The default simulator and all other `make` targets continue to use the
128 KB default from `Makefile.cfg`.

---

## Formal Verification (`make -C verif/formal`)

### Tool requirements

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

### Running

```bash
cd verif/formal
make csr        # BMC + induction on jv32_csr
make cleanall   # remove all sby output directories
```

`gen_flat_csr.py` must be run once to produce `jv32_csr_flat.sv` before `make csr` if the file is absent:

```bash
python3 gen_flat_csr.py
```
