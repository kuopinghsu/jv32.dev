# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-05-13

---

## 1. Configuration

| Parameter | Value |
|---|---|
| Clock | 80 MHz (`core_clk`, period = 12.5 ns) |
| IRAM | 16 KB |
| DRAM | 16 KB |
| `RV32EC` | 0 |
| `RV32E_EN` | 0 |
| `RV32M_EN` | 1 |
| `JTAG_EN` | 1 |
| `AMO_EN` | 1 |
| `FAST_MUL` | 1 |
| `FAST_DIV` | 0 |
| `FAST_SHIFT` | 1 |
| `BP_EN` | 1 |
| `IBUF_EN` | 1 |

---

## 2. Floorplan & Area

| Metric | Value |
|---|---|
| Die area | 1518000 µm² = 1.518 mm² |
| Core area | 1464880 µm² = 1.465 mm² |
| Standard cell area | 69120 µm² |
| Macro area | 382846 µm² |
| Total instance utilization | 30.9% |
| Std cell utilization | 6.39% |

---

## 3. Area Hierarchy (Gate Count)

> Source: `build/gate_count_run/stat.json`
> Methodology: hierarchical (non-flattening) Yosys synthesis against Nangate 45 nm OCL.
> Reference cell: NAND2\_X1 = 0.7980 µm².  SRAM macros treated as black-boxes (area excluded).
> Note: pre-P&R counts; post-P&R NAND2-eq total is in §4.

| Module | NAND2-eq | Area (µm²) | % of SoC logic |
|---|---:|---:|---:|
| **jv32_soc** | **2,665** | **2,126.94** | **100.0%** |
| ↳ jv32_top | 3,550 | 2,833.17 | 133.2% |
| &nbsp;&nbsp;↳ jv32_core | 15,368 | 12,263.66 | 576.7% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ **jv32_alu** | **17,381** | **13,870.30** | **652.2%** |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_regfile | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_csr | 5,077 | 4,051.71 | 190.5% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_rvc | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_decoder | 435 | 346.86 | 16.3% |
| &nbsp;&nbsp;↳ sram_1rw | 253 | 202.16 | 9.5% |
| ↳ jtag_top | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;↳ jtag_tap | 5,017 | 4,003.30 | 188.3% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_dtm | 0 | 0.00 | 0.0% |
| ↳ axi_clic | 5,422 | 4,327.02 | 203.5% |
| ↳ axi_uart | 3,696 | 2,949.41 | 138.7% |
| ↳ axi_xbar | 568 | 453.00 | 21.3% |
| ↳ axi_magic | 0 | 0.00 | 0.0% |

### ALU area breakdown by function

| Sub-block | Config | Key cell types | Est. NAND2-eq | % of ALU |
|---|---|---|---:|---:|
| Multiplier (MUL/MULH/MULHSU/MULHU) | `FAST_MUL=1, MUL_MC=1` (2-stage 4×16×16 pipeline) | XOR2/XNOR2, DFFR (193 FFs) | ~3,036 | ~17% |
| Divider (DIV/DIVU/REM/REMU) | `FAST_DIV=0` (serial restoring) | NAND2/NOR2, DFFR (210 FFs) | ~1,353 | ~8% |
| Barrel shifter (SLL/SRL/SRA) | `FAST_SHIFT=1` (SRL/SRA shared¹) | MUX2, INV | ~163 | ~1% |
| ADD/SUB/logic/compare | — | XOR2/XNOR2, AOI/OAI | ~12,829 | ~74% |

¹ SRL and SRA share a single right-shift barrel tree (see [rtl/jv32/core/jv32_alu.sv](../rtl/jv32/core/jv32_alu.sv)); the second independent barrel shifter was removed, saving ~100–180 NAND2-eq.

---

## 4. Cell Count & Mix

| Category | Count | % of std cells |
|---|---|---|
| Total instances | 45619 | — |
| Standard cells (excl. tap) | 45,615 | 100% |
| Sequential (flip-flops) | 5311 | 11.6% |
| Multi-input combinational | 30863 | 67.7% |
| Buffers | 1 | 0.0% |
| Inverters | 2783 | 6.1% |
| Macros | 4 | — |
| Tap cells | 6358 | — |
| I/O ports | 469 | — |
| **NAND2 equivalents (post-P&R)** | **86,617** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 218 |
| CTS buffers inserted | 1221 |
| Clock subnets | 1221 |
| Clock sinks | 5531 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.13376855557426898 ns ⚠️ |

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.941645 | -0.370405 |
| `jtag_tck` | 1.280068 | -0.370405 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | -1.736155268691188 | -333.6221633384585 | ❌ VIOLATED |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.941645 |
| `jtag_tck` | 1.280068 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 101   | ⚠️ |
| Max cap violations    | 1095    | ⚠️ |
| Max fanout violations | 0 | ✅ |
| Unconstrained endpoints | 251 | ℹ️ |

### Timing Convergence

| Stage | Setup WNS (ns) | |
|---|---|---|
| Pre-PnR (synthesis) | -1.554 | ❌ |
| Post-placement (mid-PnR) | -9.718 | ❌ |
| Post-CTS + resizer | 0.000 | ✅ |
| **Post-route STA (sign-off)** | **-1.736** | ❌ |

---

## 7. Design Rule Checks (Post-Route)

| Iteration | DRC Errors | Wirelength (µm) |
|---|---|---|
| 1 | 62,390 | 6,433,092 |
| 2 | 25,088 | 6,429,979 |
| 3 | 22,135 | 6,429,205 |
| 4 | 2,948 | 6,430,201 |
| 5 | 476 | 6,430,250 |
| 6 | 37 | 6,430,221 |
| 7 | 0 | 6,430,211 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 1.68 mW | 1.76 mW | 0.54 mW | 3.98 mW | 12.7% |
| Combinational | 4.61 mW | 10.70 mW | 2.24 mW | 17.54 mW | 55.8% |
| Clock | 0.78 mW | 1.32 mW | 0.12 mW | 2.23 mW | 7.1% |
| Macro | 7.15 mW | 0.00 mW | 0.53 mW | 7.69 mW | 24.5% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 14.23 mW | 13.78 mW | 3.43 mW | 31.44 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 53,700 |
| Constrained signal nets | 48,977 |
| Total wirelength | **6430.16 mm** |
| Total vias | 768,507 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `_05430_` | 3.251 mm |
| 2 | `u_jv32.u_core.alu_op_b\[4\]` | 2.706 mm |
| 3 | `u_jv32.u_core.alu_op_a\[17\]` | 2.677 mm |
| 4 | `_06082_` | 2.597 mm |
| 5 | `gen_jtag.u_jtag.u_jtag_tap.sba_busy_clk` | 2.494 mm |
| 6 | `u_jv32.u_core.alu_op_a\[23\]` | 2.481 mm |
| 7 | `u_jv32.u_core.alu_op_a\[19\]` | 2.464 mm |
| 8 | `u_jv32.u_core.alu_op_a\[9\]` | 2.444 mm |
| 9 | `u_jv32.u_core.alu_op_a\[22\]` | 2.420 mm |
| 10 | `_05375_` | 2.343 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 2,298,275 | 920,114 | 40.03% ✅ | 0 /  0 /  0 |
| metal3 | 3,066,636 | 1,304,960 | 42.55% ✅ | 0 /  0 /  0 |
| metal4 | 1,280,962 | 212,630 | 16.60% ✅ | 0 /  0 /  0 |
| metal5 | 1,664,976 | 375,395 | 22.55% ✅ | 0 /  0 /  0 |
| metal6 | 1,666,050 | 40,352 | 2.42% ✅ | 0 /  0 /  0 |
| metal7 | 343,392 | 19,754 | 5.75% ✅ | 0 /  0 /  0 |
| metal8 | 343,919 | 966 | 0.28% ✅ | 0 /  0 /  0 |
| metal9 | 342,608 | 8,226 | 2.40% ✅ | 0 /  0 /  0 |
| **Total** | **11,006,818** | **2,882,397** | **26.19%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 6564096 µm

---

## 11. Manufacturability

| Check | Result |
|---|---|
| Antenna | Passed ✅ |
| LVS     | Passed ✅ |
| DRC     | Passed ✅ |

---

## 12. Flow Runtime

| Step | Tool | Runtime |
|---|---|---|
| Synthesis | Yosys | 00:09:06.902 |
| Floorplan | OpenROAD | 00:00:05.718 |
| Global Placement | OpenROAD (RePLace) | 00:01:57.762 |
| Clock Tree Synthesis | TritonCTS | 00:00:34.017 |
| Global Routing | OpenROAD (FastRoute) | 00:01:02.011 |
| Detailed Routing | TritonRoute | 00:05:54.525 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:01:53.324 |
| **Total (key steps)** | | **20 m 31 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

