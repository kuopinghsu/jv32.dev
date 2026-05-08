# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-05-08

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
| Die area | 1028700 µm² = 1.029 mm² |
| Core area | 985108 µm² = 0.985 mm² |
| Standard cell area | 68918 µm² |
| Macro area | 382846 µm² |
| Total instance utilization | 45.9% |
| Std cell utilization | 11.44% |

---

## 3. Area Hierarchy (Gate Count)

> Source: `build/gate_count_run/stat.json`
> Methodology: hierarchical (non-flattening) Yosys synthesis against Nangate 45 nm OCL.
> Reference cell: NAND2\_X1 = 0.7980 µm².  SRAM macros treated as black-boxes (area excluded).
> Note: pre-P&R counts; post-P&R NAND2-eq total is in §4.

| Module | NAND2-eq | Area (µm²) | % of SoC logic |
|---|---:|---:|---:|
| **jv32_soc** | **2,628** | **2,097.14** | **100.0%** |
| ↳ jv32_top | 3,559 | 2,840.08 | 135.4% |
| &nbsp;&nbsp;↳ jv32_core | 14,976 | 11,950.58 | 569.9% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ **jv32_alu** | **17,464** | **13,936.01** | **664.5%** |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_regfile | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_csr | 5,073 | 4,048.25 | 193.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_rvc | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_decoder | 433 | 345.53 | 16.5% |
| &nbsp;&nbsp;↳ sram_1rw | 253 | 202.16 | 9.6% |
| ↳ jtag_top | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;↳ jtag_tap | 212 | 169.44 | 8.1% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_dtm | 16,183 | 12,913.77 | 615.8% |
| ↳ axi_clic | 5,403 | 4,311.59 | 205.6% |
| ↳ axi_uart | 3,697 | 2,950.47 | 140.7% |
| ↳ axi_xbar | 568 | 453.00 | 21.6% |
| ↳ axi_magic | 0 | 0.00 | 0.0% |

### ALU area breakdown by function

| Sub-block | Config | Key cell types | Est. NAND2-eq | % of ALU |
|---|---|---|---:|---:|
| Multiplier (MUL/MULH/MULHSU/MULHU) | `FAST_MUL=1, MUL_MC=1` (2-stage 4×16×16 pipeline) | XOR2/XNOR2, DFFR (193 FFs) | ~3,013 | ~17% |
| Divider (DIV/DIVU/REM/REMU) | `FAST_DIV=0` (serial restoring) | NAND2/NOR2, DFFR (210 FFs) | ~1,360 | ~8% |
| Barrel shifter (SLL/SRL/SRA) | `FAST_SHIFT=1` (SRL/SRA shared¹) | MUX2, INV | ~138 | ~1% |
| ADD/SUB/logic/compare | — | XOR2/XNOR2, AOI/OAI | ~12,953 | ~74% |

¹ SRL and SRA share a single right-shift barrel tree (see [rtl/jv32/core/jv32_alu.sv](../rtl/jv32/core/jv32_alu.sv)); the second independent barrel shifter was removed, saving ~100–180 NAND2-eq.

---

## 4. Cell Count & Mix

| Category | Count | % of std cells |
|---|---|---|
| Total instances | 41683 | — |
| Standard cells (excl. tap) | 41,679 | 100% |
| Sequential (flip-flops) | 5696 | 13.7% |
| Multi-input combinational | 29719 | 71.3% |
| Buffers | 33 | 0.1% |
| Inverters | 2271 | 5.4% |
| Macros | 4 | — |
| Tap cells | 3661 | — |
| I/O ports | 469 | — |
| **NAND2 equivalents (post-P&R)** | **86,363** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 217 |
| CTS buffers inserted | 1018 |
| Clock subnets | 1018 |
| Clock sinks | 5915 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.2325061320394942 ns ⚠️ |

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.793646 | -0.249627 |
| `jtag_tck` | 1.153985 | -0.249627 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.793646 |
| `jtag_tck` | 1.153985 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 63   | ⚠️ |
| Max cap violations    | 345    | ⚠️ |
| Max fanout violations | 0 | ✅ |
| Unconstrained endpoints | 248 | ℹ️ |

### Timing Convergence

| Stage | Setup WNS (ns) | |
|---|---|---|
| Pre-PnR (synthesis) | -17.039 | ❌ |
| Post-placement (mid-PnR) | -26.437 | ❌ |
| Post-CTS + resizer | 0.000 | ✅ |
| Post-GRT resizer | 0.000 | ✅ |
| **Post-route STA (sign-off)** | **0.000** | ✅ |

---

## 7. Design Rule Checks (Post-Route)

| Iteration | DRC Errors | Wirelength (µm) |
|---|---|---|
| 1 | 14,146 | 1,505,270 |
| 2 | 2,560 | 1,500,745 |
| 3 | 1,809 | 1,499,944 |
| 4 | 41 | 1,499,881 |
| 5 | 4 | 1,499,876 |
| 6 | 0 | 1,499,874 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 2.03 mW | 1.39 mW | 0.49 mW | 3.91 mW | 11.5% |
| Combinational | 8.49 mW | 10.87 mW | 1.41 mW | 20.77 mW | 61.2% |
| Clock | 0.71 mW | 0.73 mW | 0.13 mW | 1.56 mW | 4.6% |
| Macro | 7.15 mW | 0.00 mW | 0.53 mW | 7.69 mW | 22.7% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 18.39 mW | 12.99 mW | 2.56 mW | 33.93 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 48,634 |
| Constrained signal nets | 44,485 |
| Total wirelength | **1499.83 mm** |
| Total vias | 420,834 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `net792` | 1.648 mm |
| 2 | `net826` | 1.611 mm |
| 3 | `net827` | 1.610 mm |
| 4 | `net825` | 1.571 mm |
| 5 | `net828` | 1.567 mm |
| 6 | `_06818_` | 1.536 mm |
| 7 | `_05377_` | 1.518 mm |
| 8 | `net829` | 1.469 mm |
| 9 | `clknet_3_0_0_clk` | 1.431 mm |
| 10 | `net729` | 1.429 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 1,010,192 | 209,235 | 20.71% ✅ | 0 /  0 /  0 |
| metal3 | 1,446,307 | 344,286 | 23.80% ✅ | 0 /  0 /  0 |
| metal4 | 580,064 | 39,942 | 6.89% ✅ | 0 /  0 /  0 |
| metal5 | 904,257 | 71,129 | 7.87% ✅ | 0 /  0 /  0 |
| metal6 | 902,289 | 16,397 | 1.82% ✅ | 0 /  0 /  0 |
| metal7 | 232,758 | 4,187 | 1.80% ✅ | 0 /  0 /  0 |
| metal8 | 232,320 | 86 | 0.04% ✅ | 0 /  0 /  0 |
| metal9 | 231,552 | 692 | 0.30% ✅ | 0 /  0 /  0 |
| **Total** | **5,539,739** | **685,954** | **12.38%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 1758573 µm

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
| Synthesis | Yosys | 00:06:51.141 |
| Floorplan | OpenROAD | 00:00:05.177 |
| Global Placement | OpenROAD (RePLace) | 00:01:47.430 |
| Clock Tree Synthesis | TritonCTS | 00:00:13.435 |
| Global Routing | OpenROAD (FastRoute) | 00:00:46.042 |
| Detailed Routing | TritonRoute | 00:01:34.559 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:01:22.632 |
| **Total (key steps)** | | **12 m 38 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

