# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-05-17

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
| Die area | 2104930 µm² = 2.105 mm² |
| Core area | 2043430 µm² = 2.043 mm² |
| Standard cell area | 76966 µm² |
| Macro area | 382846 µm² |
| Total instance utilization | 22.5% |
| Std cell utilization | 4.63% |

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
| Total instances | 53808 | — |
| Standard cells (excl. tap) | 53,804 | 100% |
| Sequential (flip-flops) | 5311 | 9.9% |
| Multi-input combinational | 33134 | 61.6% |
| Buffers | 4458 | 8.3% |
| Inverters | 2129 | 4.0% |
| Macros | 4 | — |
| Tap cells | 8473 | — |
| I/O ports | 469 | — |
| **NAND2 equivalents (post-P&R)** | **96,449** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 218 |
| CTS buffers inserted | 1002 |
| Clock subnets | 1002 |
| Clock sinks | 5531 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.054309419609803226 ns ⚠️ |

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.586998 | -0.220539 |
| `jtag_tck` | 1.159585 | -0.220539 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.586998 |
| `jtag_tck` | 1.159585 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 72   | ⚠️ |
| Max cap violations    | 264    | ⚠️ |
| Max fanout violations | 0 | ✅ |
| Unconstrained endpoints | 251 | ℹ️ |

### Timing Convergence

| Stage | Setup WNS (ns) | |
|---|---|---|
| Pre-PnR (synthesis) | 0.000 | ✅ |
| Post-placement (mid-PnR) | 0.000 | ✅ |
| Post-CTS + resizer | 0.000 | ✅ |
| Post-GRT resizer | 0.000 | ✅ |
| **Post-route STA (sign-off)** | **0.000** | ✅ |

---

## 7. Design Rule Checks (Post-Route)

| Iteration | DRC Errors | Wirelength (µm) |
|---|---|---|
| 1 | 16,775 | 1,606,946 |
| 2 | 3,748 | 1,602,510 |
| 3 | 2,535 | 1,601,701 |
| 4 | 77 | 1,601,581 |
| 5 | 0 | 1,601,583 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 1.44 mW | 0.63 mW | 0.46 mW | 2.53 mW | 11.1% |
| Combinational | 3.94 mW | 5.64 mW | 1.60 mW | 11.18 mW | 49.2% |
| Clock | 0.61 mW | 0.60 mW | 0.12 mW | 1.33 mW | 5.8% |
| Macro | 7.15 mW | 0.00 mW | 0.53 mW | 7.69 mW | 33.8% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 13.15 mW | 6.87 mW | 2.71 mW | 22.73 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 54,584 |
| Constrained signal nets | 49,861 |
| Total wirelength | **1601.53 mm** |
| Total vias | 430,858 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `net17` | 3.215 mm |
| 2 | `net508` | 1.549 mm |
| 3 | `net511` | 1.461 mm |
| 4 | `net509` | 1.241 mm |
| 5 | `clknet_3_0_0_clk` | 1.174 mm |
| 6 | `net512` | 1.147 mm |
| 7 | `net510` | 1.135 mm |
| 8 | `net252` | 1.040 mm |
| 9 | `clk` | 1.009 mm |
| 10 | `clknet_3_1_0_clk` | 0.948 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 2,716,088 | 264,513 | 9.74% ✅ | 0 /  0 /  0 |
| metal3 | 3,883,515 | 332,418 | 8.56% ✅ | 0 /  0 /  0 |
| metal4 | 1,554,584 | 81,967 | 5.27% ✅ | 0 /  0 /  0 |
| metal5 | 1,854,818 | 37,347 | 2.01% ✅ | 0 /  0 /  0 |
| metal6 | 1,849,734 | 24,754 | 1.34% ✅ | 0 /  0 /  0 |
| metal7 | 477,106 | 516 | 0.11% ✅ | 0 /  0 /  0 |
| metal8 | 476,160 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal9 | 474,880 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| **Total** | **13,286,885** | **741,515** | **5.58%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 1900065 µm

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
| Synthesis | Yosys | 00:02:35.148 |
| Floorplan | OpenROAD | 00:00:05.094 |
| Global Placement | OpenROAD (RePLace) | 00:02:04.061 |
| Clock Tree Synthesis | TritonCTS | 00:00:13.396 |
| Global Routing | OpenROAD (FastRoute) | 00:00:36.276 |
| Detailed Routing | TritonRoute | 00:01:35.467 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:01:21.057 |
| **Total (key steps)** | | **8 m 29 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

