# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-04-27

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
| `TRACE_EN` | 1 |
| `AMO_EN` | 1 |
| `FAST_MUL` | 1 |
| `FAST_DIV` | 0 |
| `FAST_SHIFT` | 1 |
| `BP_EN` | 1 |

---

## 2. Floorplan & Area

| Metric | Value |
|---|---|
| Die area | 4500000 µm² = 4.500 mm² |
| Core area | 4406880 µm² = 4.407 mm² |
| Standard cell area | 65211 µm² |
| Macro area | 2183510 µm² |
| Total instance utilization | 51.0% |
| Std cell utilization | 2.93% |

---

## 3. Area Hierarchy (Gate Count)

> Source: `build/gate_count_run/stat.json`
> Methodology: hierarchical (non-flattening) Yosys synthesis against Nangate 45 nm OCL.
> Reference cell: NAND2\_X1 = 0.7980 µm².  SRAM macros treated as black-boxes (area excluded).
> Note: pre-P&R counts; post-P&R NAND2-eq total is in §4.

| Module | NAND2-eq | Area (µm²) | % of SoC logic |
|---|---:|---:|---:|
| **jv32_soc** | **1,949** | **1,555.57** | **100.0%** |
| ↳ jv32_top | 3,522 | 2,810.29 | 180.7% |
| &nbsp;&nbsp;↳ jv32_core | 12,115 | 9,667.50 | 621.6% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ **jv32_alu** | **15,219** | **12,145.03** | **780.9%** |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_regfile | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_csr | 5,039 | 4,020.86 | 258.5% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_rvc | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_decoder | 297 | 237.27 | 15.2% |
| &nbsp;&nbsp;↳ sram_1rw | 84 | 66.77 | 4.3% |
| ↳ jtag_top | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;↳ jtag_tap | 212 | 169.44 | 10.9% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_dtm | 15,631 | 12,473.80 | 802.0% |
| ↳ axi_clic | 5,298 | 4,227.54 | 271.8% |
| ↳ axi_uart | 3,755 | 2,996.76 | 192.7% |
| ↳ axi_xbar | 568 | 453.00 | 29.1% |
| ↳ axi_magic | 0 | 0.00 | 0.0% |

### ALU area breakdown by function

| Sub-block | Config | Key cell types | Est. NAND2-eq | % of ALU |
|---|---|---|---:|---:|
| Multiplier (MUL/MULH/MULHSU/MULHU) | `FAST_MUL=1, MUL_MC=1` (2-stage 4×16×16 pipeline) | XOR2/XNOR2, DFFR (193 FFs) | ~2,738 | ~18% |
| Divider (DIV/DIVU/REM/REMU) | `FAST_DIV=0` (serial restoring) | NAND2/NOR2, DFFR (210 FFs) | ~1,213 | ~8% |
| Barrel shifter (SLL/SRL/SRA) | `FAST_SHIFT=1` (SRL/SRA shared¹) | MUX2, INV | ~118 | ~1% |
| ADD/SUB/logic/compare | — | XOR2/XNOR2, AOI/OAI | ~11,150 | ~73% |

¹ SRL and SRA share a single right-shift barrel tree (see [rtl/jv32/core/jv32_alu.sv](../rtl/jv32/core/jv32_alu.sv)); the second independent barrel shifter was removed, saving ~100–180 NAND2-eq.

---

## 4. Cell Count & Mix

| Category | Count | % of std cells |
|---|---|---|
| Total instances | 44670 | — |
| Standard cells (excl. tap) | 44,666 | 100% |
| Sequential (flip-flops) | 5276 | 11.8% |
| Multi-input combinational | 27417 | 61.4% |
| Buffers | 96 | 0.2% |
| Inverters | 1973 | 4.4% |
| Macros | 4 | — |
| Tap cells | 9904 | — |
| I/O ports | 774 | — |
| **NAND2 equivalents (post-P&R)** | **81,718** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 2 |
| CTS buffers inserted | 271 |
| Clock subnets | 271 |
| Clock sinks | 5280 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.11935358594830646 ns ⚠️ |

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.621618 | -0.133610 |
| `jtag_tck` | 1.017464 | -0.116591 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.621618 |
| `jtag_tck` | 1.017464 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 61   | ⚠️ |
| Max cap violations    | 175    | ⚠️ |
| Max fanout violations | 4 | ⚠️ |
| Unconstrained endpoints | 51 | ℹ️ |

### Timing Convergence

| Stage | Setup WNS (ns) | |
|---|---|---|
| Pre-PnR (synthesis) | -11.204 | ❌ |
| Post-placement (mid-PnR) | -14.204 | ❌ |
| Post-CTS + resizer | 0.000 | ✅ |
| Post-GRT resizer | 0.000 | ✅ |
| **Post-route STA (sign-off)** | **0.000** | ✅ |

---

## 7. Design Rule Checks (Post-Route)

| Iteration | DRC Errors | Wirelength (µm) |
|---|---|---|
| 1 | 11,762 | 1,193,088 |
| 2 | 1,900 | 1,188,470 |
| 3 | 1,179 | 1,187,912 |
| 4 | 114 | 1,187,844 |
| 5 | 34 | 1,187,844 |
| 6 | 8 | 1,187,852 |
| 7 | 0 | 1,187,850 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 3.31 mW | 0.52 mW | 0.44 mW | 4.27 mW | 21.3% |
| Combinational | 1.61 mW | 2.43 mW | 1.29 mW | 5.33 mW | 26.6% |
| Clock | 0.30 mW | 0.91 mW | 0.02 mW | 1.22 mW | 6.1% |
| Macro | 8.63 mW | 0.00 mW | 0.59 mW | 9.22 mW | 46.0% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 13.85 mW | 3.86 mW | 2.34 mW | 20.04 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 42,537 |
| Constrained signal nets | 38,676 |
| Total wirelength | **1187.81 mm** |
| Total vias | 380,905 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `_06221_` | 2.246 mm |
| 2 | `net135` | 1.923 mm |
| 3 | `_06159_` | 1.698 mm |
| 4 | `net1164` | 1.577 mm |
| 5 | `net1162` | 1.573 mm |
| 6 | `_06223_` | 1.441 mm |
| 7 | `net1044` | 1.399 mm |
| 8 | `net1165` | 1.338 mm |
| 9 | `net1166` | 1.328 mm |
| 10 | `net1163` | 1.320 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 3,619,416 | 199,007 | 5.50% ✅ | 0 /  0 /  0 |
| metal3 | 5,187,866 | 259,738 | 5.01% ✅ | 0 /  0 /  0 |
| metal4 | 2,077,934 | 39,370 | 1.89% ✅ | 0 /  0 /  0 |
| metal5 | 3,961,995 | 36,489 | 0.92% ✅ | 0 /  0 /  0 |
| metal6 | 3,956,418 | 1,901 | 0.05% ✅ | 0 /  0 /  0 |
| metal7 | 1,018,877 | 2,779 | 0.27% ✅ | 0 /  0 /  0 |
| metal8 | 1,020,305 | 14 | 0.00% ✅ | 0 /  0 /  0 |
| metal9 | 1,017,451 | 751 | 0.07% ✅ | 0 /  0 /  0 |
| **Total** | **21,860,262** | **540,049** | **2.47%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 1444541 µm

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
| Synthesis | Yosys | 00:06:38.168 |
| Floorplan | OpenROAD | 00:00:01.719 |
| Global Placement | OpenROAD (RePLace) | 00:01:43.314 |
| Clock Tree Synthesis | TritonCTS | 00:00:11.683 |
| Global Routing | OpenROAD (FastRoute) | 00:00:41.949 |
| Detailed Routing | TritonRoute | 00:01:58.686 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:01:03.891 |
| **Total (key steps)** | | **12 m 15 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

