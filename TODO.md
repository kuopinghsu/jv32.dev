# JV32 TODO / Improvement List

## Architecture / Performance

- [x] **JALR redirect elimination (RAS)** — Added an 2-entry circular Return Address Stack. Push on JAL/JALR with rd∈{x1,x5}; pop on JALR with rs1∈{x1,x5} and rd∉{x1,x5}. Predicted target stored in new `bp_pred_pc` field of the IF/EX register; EX suppresses the redirect when the actual JALR target matches. See [rtl/jv32/core/jv32_core.sv](rtl/jv32/core/jv32_core.sv) and [rtl/jv32/core/jv32_pkg.sv](rtl/jv32/core/jv32_pkg.sv).
- [ ] **Branch predictor: 2-bit saturating counters** — the current L0 is a 1-entry "last-branch" cache with a 1-bit direction. A small 4–16 entry PHT with 2-bit saturating counters would better handle loops executed multiple times, at very low area cost.
- [x] **Instruction prefetch buffer** — 2-entry shift-register FIFO (`gen_ibuf`) between TCM/AXI response and jv32_rvc. Controlled by `IBUF_EN` parameter (default: 1). Auto-disabled when `RV32E_EN=1` (via `IBUF_ACTIVE = IBUF_EN && !RV32E_EN`). `ibuf_fetch_pc_ff` runs 1–2 words ahead of `pc_if`, sending pre-fetch requests to SRAM/AXI while the RVC processes earlier words. AXI correctness guaranteed by gating `imem_req_valid=0` when FIFO full. AXI I-fetch faults serialised through `ibuf_fault_pending_r` so buffered instructions before the fault execute first.
- [x] **2-entry store queue** — Upgraded the 1-entry store buffer (`sb_valid/sb_addr/sb_wdata/sb_wstrb`) to a 2-slot shift-register FIFO (`sb_valid[1:0]`, etc.). Slot 0 = head (being drained), slot 1 = tail. Consecutive TCM store gap reduced from 3 → 1: store 2 retires into slot 1 while slot 0 is still draining, without waiting for the SRAM ack. No regression for store→ALU (still gap=1). Gate count increase: ~70 extra flops; no new combinatorial paths on the critical timing arc. Dhrystone: CPI 1.330 → 1.245 (+6.4 %), DMIPS/MHz 1.41 → 1.77. CoreMark: CPI 1.100 → 1.093 (+0.6 %).

## ISA Extensions

- [x] **Zba / Zbb / Zbs bit-manipulation extensions** — implemented with `RV32B_EN` parameter (default 1). Forced off when `RV32E_EN=1` (via `ZB_ACTIVE` localparam in `jv32_core`). When `RV32B_EN=0`, all logic removed from synthesis via `generate` blocks. `FAST_SHIFT` controls rotate implementation (barrel vs serial). Parameter propagated through: `jv32_pkg` → `jv32_alu` / `jv32_decoder` → `jv32_core` → `jv32_top` → `jv32_soc`.
- [ ] **Zicntr / Zihpm performance counters** — expose `mhpmcounter3`–`mhpmcounterN` mapped to the existing `perf_bp_*` hardware counter outputs, allowing benchmarking tools and profilers to read statistics directly from M-mode software.
- [ ] **PMP (Physical Memory Protection)** — even a minimal 4-region PMP would enable safer firmware sandboxing and is required for some embedded OS security models.

## Verification

- [x] **Formal verification (SymbiYosys)** — `verif/formal/` contains a full BMC flow for `jv32_csr.sv`: `gen_flat_csr.py` generates a Yosys-compatible flat SV file and injects 7 assertion properties (MEPC alignment, MTVEC bit-1 zero, MIE reserved-bit mask, MIE clears on exception/IRQ, MISA read-only, MPIE captures pre-trap MIE). Run with `make -C verif/formal csr` (PASS in ~23 s, depth 20, engine: `smtbmc --nopresat --unroll z3`).
- [x] **Coverage-driven simulation** — added `build-rtl-cov` (builds with Verilator `--coverage`) and `coverage` target (runs all SW tests, collects per-test `.dat` files, merges and annotates with `verilator_coverage`). Run with `make coverage`; annotated line/toggle report written to `build/coverage/annotated/`.

## Software / RTOS

- [x] **Zephyr RTOS port** — out-of-tree module at `rtos/zephyr/`. Board `jv32`, SoC `SOC_RISCV_JV32` (RV32IMAC, 3-stage pipeline). Drivers: magic-address console, AXI UART. Samples: hello, simple, threads_sync, uart_echo, stress (ztest). DTS memory map: 64KB IRAM (0x80000000) + 64KB DRAM (0xC0000000), CLIC timer (mtime@0x02004000).
- [x] **C++ standard library / newlib integration test** — `sw/cpp/cpp_test.cpp` tests 42 checks covering: global constructors (`.init_array` sequencing), `std::vector<int>` (heap via `_sbrk`→`malloc`), `std::array`, `std::sort`/`is_sorted`, `std::find`/`find_if`, `std::fill`/`iota`, `std::accumulate`, `std::min_element`/`max_element`, `std::transform`, `operator new`/`delete` (linked list + array), placement new, and move semantics (`std::move`, move constructor, `vector<MoveOnly>`). All 42 checks PASS on both RTL and ISS. Compiled with `-fno-exceptions -fno-rtti` (the standard embedded C++ mode; full exception unwinding exceeds the 128 KB IRAM budget). See `sw/cpp/makefile.mak` for the GCC 15 hosted-mode fix (`filter-out -ffreestanding`).

## Synthesis / Physical Design

- [ ] **Sky130 / GF180 PDK target** — the current syn flow targets FreePDK45, which is academic-only and cannot be taped out. Adding a Sky130 OpenLane config would make the design fabricatable via the Efabless shuttle program.
- [ ] **Clock gating for TCM and peripherals** — add integrated clock gating cells on IRAM/DRAM and the UART FIFO to reduce dynamic power on the ASIC path.

## Documentation

- [x] **Machine-readable register description (IP-XACT)** — Created [docs/jv32_soc_ipxact.xml](docs/jv32_soc_ipxact.xml) (IEEE 1685-2014 IP-XACT 2.1) covering UART, CLIC/CLINT, Magic, and all M-mode CSR registers.
- [x] **CI pipeline (GitHub Actions)** — Created [.github/workflows/ci.yml](.github/workflows/ci.yml) with two jobs: `lint` (Verilator lint-only) and `regression` (`make compare-all`), both with Verilator-5 and xPack RISC-V toolchain installation cached for speed.
