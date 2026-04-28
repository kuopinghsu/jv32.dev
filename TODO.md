# JV32 TODO / Improvement List

## Architecture / Performance

- [x] **JALR redirect elimination (RAS)** — Added an 2-entry circular Return Address Stack. Push on JAL/JALR with rd∈{x1,x5}; pop on JALR with rs1∈{x1,x5} and rd∉{x1,x5}. Predicted target stored in new `bp_pred_pc` field of the IF/EX register; EX suppresses the redirect when the actual JALR target matches. See [rtl/jv32/core/jv32_core.sv](rtl/jv32/core/jv32_core.sv) and [rtl/jv32/core/jv32_pkg.sv](rtl/jv32/core/jv32_pkg.sv).
- [ ] **Branch predictor: 2-bit saturating counters** — the current L0 is a 1-entry "last-branch" cache with a 1-bit direction. A small 4–16 entry PHT with 2-bit saturating counters would better handle loops executed multiple times, at very low area cost.
- [ ] **Instruction prefetch buffer** — a 2-entry fetch queue between the TCM and the RVC expander would hide the 1-cycle RVC stall for compressed instructions at boundaries, slightly reducing CPI.

## ISA Extensions

- [x] **Zba / Zbb / Zbs bit-manipulation extensions** — implemented with `RV32B_EN` parameter (default 1). Forced off when `RV32E_EN=1` (via `ZB_ACTIVE` localparam in `jv32_core`). When `RV32B_EN=0`, all logic removed from synthesis via `generate` blocks. `FAST_SHIFT` controls rotate implementation (barrel vs serial). Parameter propagated through: `jv32_pkg` → `jv32_alu` / `jv32_decoder` → `jv32_core` → `jv32_top` → `jv32_soc`.
- [ ] **Zicntr / Zihpm performance counters** — expose `mhpmcounter3`–`mhpmcounterN` mapped to the existing `perf_bp_*` hardware counter outputs, allowing benchmarking tools and profilers to read statistics directly from M-mode software.
- [ ] **PMP (Physical Memory Protection)** — even a minimal 4-region PMP would enable safer firmware sandboxing and is required for some embedded OS security models.

## Verification

- [x] **Formal verification (SymbiYosys)** — `verif/formal/` contains a full BMC flow for `jv32_csr.sv`: `gen_flat_csr.py` generates a Yosys-compatible flat SV file and injects 7 assertion properties (MEPC alignment, MTVEC bit-1 zero, MIE reserved-bit mask, MIE clears on exception/IRQ, MISA read-only, MPIE captures pre-trap MIE). Run with `make -C verif/formal csr` (PASS in ~23 s, depth 20, engine: `smtbmc --nopresat --unroll z3`).
- [x] **Coverage-driven simulation** — added `build-rtl-cov` (builds with Verilator `--coverage`) and `coverage` target (runs all SW tests, collects per-test `.dat` files, merges and annotates with `verilator_coverage`). Run with `make coverage`; annotated line/toggle report written to `build/coverage/annotated/`.

## Software / RTOS

- [ ] **Zephyr RTOS port** — only FreeRTOS is currently supported. A Zephyr port (requires a HAL layer and device tree) would broaden software ecosystem validation.
- [ ] **C++ standard library / newlib integration test** — `sw/cpp/` exists but there is no test verifying STL containers or exception unwinding on the ABI.

## Synthesis / Physical Design

- [ ] **Sky130 / GF180 PDK target** — the current syn flow targets FreePDK45, which is academic-only and cannot be taped out. Adding a Sky130 OpenLane config would make the design fabricatable via the Efabless shuttle program.
- [ ] **Clock gating for TCM and peripherals** — add integrated clock gating cells on IRAM/DRAM and the UART FIFO to reduce dynamic power on the ASIC path.

## Documentation

- [x] **Machine-readable register description (IP-XACT)** — Created [docs/jv32_soc_ipxact.xml](docs/jv32_soc_ipxact.xml) (IEEE 1685-2014 IP-XACT 2.1) covering UART, CLIC/CLINT, Magic, and all M-mode CSR registers.
- [x] **CI pipeline (GitHub Actions)** — Created [.github/workflows/ci.yml](.github/workflows/ci.yml) with two jobs: `lint` (Verilator lint-only) and `regression` (`make compare-all`), both with Verilator-5 and xPack RISC-V toolchain installation cached for speed.
