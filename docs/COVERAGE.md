# JV32 RTL Coverage Report

**Generated:** 2026-04-29
**Tool:** Verilator 5.049 `--coverage` + `genhtml`
**HTML report:** `build/coverage/html/index.html`

---

## Overall Summary

| Metric   | Covered | Total  | %      |
|----------|--------:|-------:|-------:|
| Lines    |    3749 |   4174 |  89.8% |
| Branches |     897 |   1278 |  70.2% |
| Expressions |  883 |   1092 |  80.9% |
| Toggles  |   23853 |  33394 |  71.4% |

> *Lines* is the lcov line-hit metric (source lines executed ≥ 1×).
> *Branches / Expressions / Toggles* are Verilator-native coverage points from `verilator_coverage`.

---

## Per-File Line Coverage

| RTL File                                    | Hit  | Total |  Lines% |
|---------------------------------------------|-----:|------:|--------:|
| `rtl/jv32/core/jv32_regfile.sv`             |   23 |    23 | 100.0%  |
| `rtl/memories/sram_1rw.sv`                  |   14 |    14 | 100.0%  |
| `rtl/jv32/core/jv32_alu.sv`                 |  185 |   189 |  97.9%  |
| `rtl/jv32/core/jv32_rvc.sv`                 |  246 |   253 |  97.2%  |
| `rtl/jv32/core/jv32_decoder.sv`             |  252 |   263 |  95.8%  |
| `rtl/jv32/jv32_top.sv`                      |  358 |   375 |  95.5%  |
| `rtl/axi/axi_uart.sv`                       |  219 |   230 |  95.2%  |
| `rtl/axi/axi_clic.sv`                       |  135 |   144 |  93.8%  |
| `rtl/axi/axi_xbar.sv`                       |  102 |   109 |  93.6%  |
| `rtl/jv32/core/jv32_core.sv`                |  786 |   849 |  92.6%  |
| `rtl/jv32/core/jtag/jtag_tap.sv`            |  100 |   109 |  91.7%  |
| `rtl/jv32/core/jv32_csr.sv`                 |  175 |   193 |  90.7%  |
| `rtl/jv32/core/jtag/jtag_top.sv`            |   39 |    43 |  90.7%  |
| `rtl/jv32_soc.sv`                           |  315 |   356 |  88.5%  |
| `rtl/jv32/core/jtag/jv32_dtm.sv`            |  800 |  1024 |  78.1%  |
| **Total**                                   | **3749** | **4174** | **89.8%** |

---

## Per-File Branch Coverage

Branch coverage is the lcov `BRH/BRF` metric produced by `verilator_coverage --write-info`.

| RTL File                                    | Hit  | Total |  Branch% |
|---------------------------------------------|-----:|------:|---------:|
| `rtl/memories/sram_1rw.sv`                  |  178 |   180 |   98.9%  |
| `rtl/jv32/core/jv32_alu.sv`                 | 2890 |  3293 |   87.8%  |
| `rtl/jv32/core/jv32_rvc.sv`                 |  612 |   739 |   82.8%  |
| `rtl/jv32/core/jv32_regfile.sv`             |  298 |   397 |   75.1%  |
| `rtl/jv32/core/jv32_decoder.sv`             |  359 |   500 |   71.8%  |
| `rtl/jv32/core/jv32_core.sv`                | 5131 |  7183 |   71.4%  |
| `rtl/axi/axi_xbar.sv`                       | 1151 |  1699 |   67.7%  |
| `rtl/jv32/jv32_top.sv`                      | 2778 |  4801 |   57.9%  |
| `rtl/jv32_soc.sv`                           | 2818 |  5302 |   53.1%  |
| `rtl/axi/axi_uart.sv`                       |  433 |   953 |   45.4%  |
| `rtl/axi/axi_clic.sv`                       |  657 |  1637 |   40.1%  |
| `rtl/jv32/core/jv32_csr.sv`                 |  715 |  2242 |   31.9%  |
| `rtl/jv32/core/jtag/jtag_tap.sv`            |  293 |  1056 |   27.7%  |
| `rtl/jv32/core/jtag/jv32_dtm.sv`            | 1330 |  5242 |   25.4%  |
| `rtl/jv32/core/jtag/jtag_top.sv`            |  178 |   918 |   19.4%  |
| **Total**                                   | **19821** | **36142** | **54.8%** |

---

## Test Suite

### Software Tests (16 tests)

| Test         | Description                                         |
|--------------|-----------------------------------------------------|
| `atomic`     | RV32A atomic instruction sequences                  |
| `callstack`  | Backtrace from trap handler                         |
| `clic`       | CLIC interrupt controller                           |
| `coremark`   | CoreMark benchmark                                  |
| `cpp`        | C++ / newlib integration                            |
| `dhry`       | Dhrystone benchmark                                 |
| `extram`     | External SRAM (sim-only, 0xA0000000)                |
| `fence`      | FENCE / FENCE.I ordering                            |
| `hello`      | Hello World / basic UART                            |
| `mibench`    | MiBench suite (qsort, dijkstra, blowfish, fft, sha1, bitcount, adpcm, stringsearch) |
| `nested_irq` | Nested / preemptive interrupt handling              |
| `simple`     | Minimal smoke test                                  |
| `tcm_alias`  | TCM alias mapping (complex)                         |
| `trap`       | Exception / trap handling                           |
| `zb_ext`     | Zba/Zbb/Zbs + M-ext + CSR coverage                  |
| `zcb`        | Zcb compressed instruction coverage                 |

### JTAG Debug Coverage Scenarios (7 scenarios)

| Scenario         | Coverage focus                          |
|------------------|-----------------------------------------|
| `halt_resume`    | Debug halt / resume flow                |
| `programbuf`     | Program buffer execution                |
| `sba`            | System Bus Access                       |
| `step`           | Single-step execution                   |
| `abstract_regs`  | Abstract command register access        |
| `triggers`       | Hardware breakpoint / watchpoint        |
| `debug_errors`   | Debug module error handling             |

---

## Exclusions

The following blocks are excluded from coverage instrumentation with
`/* verilator coverage_off */`:

- Testbench wrappers (`testbench/`)
- `rtl/jv32_soc.sv` — `axi_magic` peripheral (simulation-only debug sink)

---

## Regenerating

```sh
make coverage            # full run (all SW tests + JTAG scenarios)
make coverage TIMEOUT=300  # with per-test wall-clock timeout override
# HTML report: build/coverage/html/index.html
# Annotated source: build/coverage/annotated/
```
