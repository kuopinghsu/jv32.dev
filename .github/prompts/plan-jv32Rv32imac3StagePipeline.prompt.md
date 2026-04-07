# Plan: JV32 — RV32IMAC 3-Stage Pipeline Processor (SystemVerilog)

JV32 is a brand-new RV32IMAC SoC in SystemVerilog targeting the RVM23 microcontroller profile. Reuse KV32's ALU, RVC decompressor, UART, Magic device, and trace format as reference templates. Replace KV32's PLIC+CLINT with CLIC. Configure low-area vs high-performance via top-level parameters.

**Pipeline: IF → EX → WB**
- **IF**: PC, IRAM fetch, RVC decompressor, PC advance (±2/±4)
- **EX**: Decode, register read, ALU, branch eval, memory address/request, CSR, hazard detect, WB→EX forwarding
- **WB**: Load data sign/zero extend, register writeback, exception flush, MRET redirect
- Hazards: 1-cycle load-use stall; 1-cycle branch flush (resolved in EX)

---

## Steps

### Phase 1 — Foundation *(all parallel)*
1. `rtl/jv32/core/jv32_pkg.sv` — enums (`alu_op_e`, `mem_size_e`, `exc_cause_e`), all top-level parameters (`FAST_MUL`, `FAST_DIV`, `FAST_SHIFT`, `BP_EN`, `IRAM_SIZE`, `DRAM_SIZE`, `AXI_DATA_WIDTH`, `BOOT_ADDR`), pipeline register structs (`if_ex_t`, `ex_wb_t`)
2. `rtl/axi/axi_pkg.sv` — AXI4-Lite type definitions parameterized on `DATA_WIDTH`; adapt from kv32's `axi_pkg.sv`
3. `rtl/memories/sram_1rw.sv` — 1-port synchronous SRAM wrapper; reuse from kv32

### Phase 2 — Core Building Blocks *(parallel, depends on Phase 1)*
4. `rtl/jv32/core/jv32_regfile.sv` — 32×32 GPRs, x0 hardwired 0; adapt from kv32_regfile.sv
5. `rtl/jv32/core/jv32_rvc.sv` — 16-bit RVC → 32-bit decompressor; rename from kv32_rvc.sv
6. `rtl/jv32/core/jv32_alu.sv` — RV32IMAC ALU with `FAST_MUL/FAST_DIV/FAST_SHIFT` params; adapt from kv32_alu.sv (remove FPU/dual-issue hooks)
7. `rtl/jv32/core/jv32_decoder.sv` — RV32IMAC + Zicsr + Zihintpause + C; simplify from kv32_decoder.sv (remove Zfinx, B-ext, dual-issue)

### Phase 3 — CSR & Pipeline Core *(depends on Phase 2)*
8. `rtl/jv32/core/jv32_csr.sv` — CSR registers (`mstatus`, `mie`, `mip`, `mtvec`, `mepc`, `mcause`, `mtval`, `mscratch`, `mtvt`/`mnxti` for CLIC, `mcycle`, `minstret`); interrupt prioritization; adapt from kv32_csr.sv
9. `rtl/jv32/core/jv32_core.sv` — 3-stage pipeline top: IF stage (PC, IRAM req, branch predictor BTB+RAS if `BP_EN`), EX stage (decoder, regfile, ALU, mem req, CSR, hazard + forwarding), WB stage (load capture, writeback, exception redirect); uses `if_ex_t` / `ex_wb_t` structs

### Phase 4 — Processor Top *(depends on Phase 3)*
10. `rtl/jv32/jv32_top.sv` — wraps jv32_core; converts internal I/D bus to AXI4-Lite masters (I-port: read-only; D-port: read/write)

### Phase 5 — Peripherals *(parallel; depends on Phase 1)*
11. `rtl/axi/axi_uart.sv` — 16550-compatible UART; TX/RX FIFO; interrupt; reuse kv32's axi_uart.sv
12. `rtl/axi/axi_clic.sv` — RISC-V CLIC v0.9: 16 external IRQs with per-IRQ priority/level/enable; `mtime`/`mtimecmp` timer; `msip` software interrupt; sideband CSR signals to core
13. `rtl/axi/axi_magic.sv` — CONSOLE_MAGIC → `$write`, EXIT_MAGIC → `$finish`; reuse kv32's axi_magic.sv

### Phase 6 — Crossbar & RAM Controllers *(parallel with Phase 5)*
14. `rtl/axi/axi_xbar.sv` — 1-master, 5-slave AXI4-Lite crossbar (IRAM, DRAM, UART, CLIC, Magic); base/mask decode; simplify from kv32's axi_xbar.sv
15. `rtl/axi/axi_ram_ctrl.sv` — AXI4-Lite slave wrapper over `sram_1rw`; WSTRB byte-enable; used for both IRAM and DRAM

### Phase 7 — SoC Integration *(depends on Phases 4–6)*
16. `rtl/jv32_soc.sv` — top SoC: instantiates jv32_top; IRAM (0x8000_0000) on I-bus; D-bus → axi_xbar → {DRAM @ 0xC000_0000, UART @ 0x2001_0000, CLIC @ 0x0200_0000, Magic @ 0x4000_0000}; wires UART/timer/software IRQs to CLIC → core

### Phase 8 — Testbench *(depends on Phase 7)*
17. `testbench/tb_jv32_soc.sv` — Verilator SV top: clock gen, reset
18. `testbench/tb_jv32_soc.cpp` — C++ Verilator driver: ELF loader (from kv32), 100 MHz clock, RTL trace in kv32sim-compatible format (PC + retired rd + rd_data per cycle), FST/VCD dump; exit on EXIT_MAGIC
19. `testbench/elfloader.cpp/.h` — copy from ~/Projects/kv32/testbench/

### Phase 9 — Build System *(parallel with Phase 8)*
20. `build/Makefile` — Verilator build rules; targets `make sim ELF=…`, `make wave`, `make clean`

### Phase 10 — Software *(parallel with Phases 8–9)*
21. `sw/startup.S` — reset vector, minimal trap/interrupt handler (save mepc/mstatus, call C handler, MRET)
22. `sw/link.ld` — .text/.rodata → IRAM @ 0x8000_0000; .data/.bss/stack → DRAM @ 0xC000_0000
23. `sw/Makefile` — `riscv32-unknown-elf-gcc` with `march=rv32imac_zicsr mabi=ilp32`
24. `sw/tests/hello.c` — smoke test: UART "hello", EXIT_MAGIC code 0
25. `sw/tests/trap_test.c` — ebreak → trap handler → MRET, ecall M-mode test

---

## Memory Map

```
0x0200_0000  CLIC   (64KB, IRQ controller + timer + software IRQ)
0x2001_0000  UART   (64KB)
0x4000_0000  Magic  (64KB, simulation exit/console)
0x8000_0000  IRAM   (64KB default, I-bus + D-bus read-only for .rodata)
0xC000_0000  DRAM   (64KB default, D-bus read/write)
BOOT_ADDR = 0x8000_0000
```

## Configuration Parameters

```
FAST_MUL=1/0       1=single-cycle multiplier,  0=iterative (32 cycles)
FAST_DIV=1/0       1=single-cycle divider,      0=iterative (33 cycles)
FAST_SHIFT=1/0     1=barrel shifter,            0=serial (1-bit/cycle)
BP_EN=1/0          1=BTB+RAS branch predictor,  0=predict-not-taken
IRAM_SIZE=65536    bytes (default 64KB)
DRAM_SIZE=65536    bytes (default 64KB)
AXI_DATA_WIDTH=32  32 or 64-bit AXI data bus
BOOT_ADDR=32'h8000_0000
```

---

## Reference Files (from kv32)

- `/home/kuoping/Projects/kv32/rtl/kv32/core/kv32_alu.sv` — ALU to adapt
- `/home/kuoping/Projects/kv32/rtl/kv32/core/kv32_rvc.sv` — RVC decompressor to reuse
- `/home/kuoping/Projects/kv32/rtl/kv32/core/kv32_csr.sv` — CSR to simplify
- `/home/kuoping/Projects/kv32/rtl/kv32/core/kv32_decoder.sv` — decoder to simplify
- `/home/kuoping/Projects/kv32/rtl/kv32/core/kv32_core.sv` — 5-stage pipeline reference
- `/home/kuoping/Projects/kv32/rtl/axi/axi_uart.sv` — UART to reuse
- `/home/kuoping/Projects/kv32/rtl/axi/axi_magic.sv` — Magic to reuse
- `/home/kuoping/Projects/kv32/sim/kv32sim.cpp` — trace format to match
- `/home/kuoping/Projects/kv32/testbench/tb_kv32_soc.cpp` — testbench reference
- `/home/kuoping/Projects/kv32/testbench/elfloader.cpp` — ELF loader to reuse

---

## Verification

1. RTL lint: `verilator --lint-only -sv rtl/jv32_soc.sv` — zero errors/warnings
2. Smoke sim: `make sim ELF=sw/tests/hello.elf` → UART prints "hello", exit 0
3. Trap test: `make sim ELF=sw/tests/trap_test.elf` → ebreak enters handler, MRET returns cleanly
4. Trace diff: diff `rtl_trace.txt` vs `kv32sim` output — PC sequence and `rd` values match
5. Arch-test: RISC-V compliance suite (rv32i, rv32m, rv32c, rv32a) — all pass
6. Waveform: GTKWave on `test.fst` — verify 1-bubble load-use stall and 1-bubble branch flush

---

## Decisions

- Stages: IF → EX → WB; memory request in EX, data captured in WB; 1-cycle load-use stall
- No dual-issue, no MMU, no cache, no JTAG, no FPU
- CLIC replaces KV32's PLIC+CLINT (RVM23-mandated)
- Harvard: IRAM on I-bus (rw) + D-bus (read-only, for .rodata); DRAM on D-bus only

## Further Considerations

1. **CLIC scope**: Full RISC-V CLIC v0.9 with hardware preemption (`mtvt`/`mnxti`) vs lightweight CLINT-style (timer + software + N external IRQs). Recommend CLIC-compatible registers but core subset for area. *Options: (A) full CLIC spec / (B) CLINT-compatible with CLIC register map*
2. **IRAM on D-bus**: IRAM must be readable via D-bus for `.rodata` constants. Option A: expose IRAM as read-only slave on D-bus crossbar (transparent to software). Option B: put `.rodata` in DRAM. *Recommend Option A.*
3. **Simulator sharing**: kv32sim already executes RV32IMAC — no changes needed; JV32 testbench just matches the same `rtl_trace.txt` column format.
