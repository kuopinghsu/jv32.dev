# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-04-24

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
| `IFETCH_PREADVANCE` | 1 |

---

## 2. Floorplan & Area

| Metric | Value |
|---|---|
| Die area | 4500000 µm² = 4.500 mm² |
| Core area | 4406880 µm² = 4.407 mm² |
| Standard cell area | 64066 µm² |
| Macro area | 2183510 µm² |
| Total instance utilization | 51.0% |
| Std cell utilization | 2.88% |

---

## 3. Area Hierarchy (Gate Count)

> Source: `build/gate_count_run/stat.json`
> Methodology: hierarchical (non-flattening) Yosys synthesis against Nangate 45 nm OCL.
> Reference cell: NAND2\_X1 = 0.7980 µm².  SRAM macros treated as black-boxes (area excluded).
> Note: pre-P&R counts; post-P&R NAND2-eq total is in §4.

| Module | NAND2-eq | Area (µm²) | % of SoC logic |
|---|---:|---:|---:|
| **jv32_soc** | **1,953** | **1,558.76** | **100.0%** |
| ↳ jv32_top | 3,532 | 2,818.54 | 180.8% |
| &nbsp;&nbsp;↳ jv32_core | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ **jv32_alu** | **15,265** | **12,181.47** | **781.6%** |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_regfile | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_csr | 5,020 | 4,005.96 | 257.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_rvc | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_decoder | 313 | 250.04 | 16.0% |
| &nbsp;&nbsp;↳ sram_1rw | 84 | 66.77 | 4.3% |
| ↳ jtag_top | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;↳ jtag_tap | 212 | 169.44 | 10.9% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_dtm | 15,624 | 12,468.22 | 800.0% |
| ↳ axi_clic | 5,281 | 4,214.24 | 270.4% |
| ↳ axi_uart | 3,772 | 3,010.06 | 193.1% |
| ↳ axi_xbar | 562 | 448.48 | 28.8% |
| ↳ axi_magic | 0 | 0.00 | 0.0% |

### ALU area breakdown by function

| Sub-block | Config | Key cell types | Est. NAND2-eq | % of ALU |
|---|---|---|---:|---:|
| Multiplier (MUL/MULH/MULHSU/MULHU) | `FAST_MUL=1, MUL_MC=1` (2-stage 4×16×16 pipeline) | XOR2/XNOR2, DFFR (193 FFs) | ~2,721 | ~18% |
| Divider (DIV/DIVU/REM/REMU) | `FAST_DIV=0` (serial restoring) | NAND2/NOR2, DFFR (210 FFs) | ~1,219 | ~8% |
| Barrel shifter (SLL/SRL/SRA) | `FAST_SHIFT=1` (SRL/SRA shared¹) | MUX2, INV | ~120 | ~1% |
| ADD/SUB/logic/compare | — | XOR2/XNOR2, AOI/OAI | ~11,205 | ~73% |

¹ SRL and SRA share a single right-shift barrel tree (see [rtl/jv32/core/jv32_alu.sv](../rtl/jv32/core/jv32_alu.sv)); the second independent barrel shifter was removed, saving ~100–180 NAND2-eq.

---

## 4. Cell Count & Mix

| Category | Count | % of std cells |
|---|---|---|
| Total instances | 44189 | — |
| Standard cells (excl. tap) | 44,185 | 100% |
| Sequential (flip-flops) | 5147 | 11.6% |
| Multi-input combinational | 26882 | 60.8% |
| Buffers | 96 | 0.2% |
| Inverters | 2156 | 4.9% |
| Macros | 4 | — |
| Tap cells | 9904 | — |
| I/O ports | 768 | — |
| **NAND2 equivalents (post-P&R)** | **80,283** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 2 |
| CTS buffers inserted | 269 |
| Clock subnets | 269 |
| Clock sinks | 5151 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.07916234558601404 ns ⚠️ |

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.651180 | -0.187954 |
| `jtag_tck` | 1.044874 | -0.149765 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.651180 |
| `jtag_tck` | 1.044874 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 60   | ⚠️ |
| Max cap violations    | 171    | ⚠️ |
| Max fanout violations | 10 | ⚠️ |
| Unconstrained endpoints | 51 | ℹ️ |

### Timing Convergence

| Stage | Setup WNS (ns) | |
|---|---|---|
| Pre-PnR (synthesis) | -9.556 | ❌ |
| Post-placement (mid-PnR) | -13.238 | ❌ |
| Post-CTS + resizer | 0.000 | ✅ |
| Post-GRT resizer | 0.000 | ✅ |
| **Post-route STA (sign-off)** | **0.000** | ✅ |

---

## 7. Design Rule Checks (Post-Route)

| Iteration | DRC Errors | Wirelength (µm) |
|---|---|---|
| 1 | 12,036 | 1,160,859 |
| 2 | 1,840 | 1,156,023 |
| 3 | 1,125 | 1,155,483 |
| 4 | 45 | 1,155,450 |
| 5 | 0 | 1,155,449 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 3.20 mW | 0.51 mW | 0.43 mW | 4.14 mW | 19.1% |
| Combinational | 2.34 mW | 3.48 mW | 1.27 mW | 7.10 mW | 32.7% |
| Clock | 0.31 mW | 0.90 mW | 0.02 mW | 1.23 mW | 5.7% |
| Macro | 8.63 mW | 0.00 mW | 0.59 mW | 9.22 mW | 42.5% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 14.48 mW | 4.89 mW | 2.31 mW | 21.69 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 41,928 |
| Constrained signal nets | 38,195 |
| Total wirelength | **1155.41 mm** |
| Total vias | 375,682 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `_06030_` | 1.774 mm |
| 2 | `net135` | 1.620 mm |
| 3 | `net1169` | 1.601 mm |
| 4 | `_06131_` | 1.487 mm |
| 5 | `net1168` | 1.479 mm |
| 6 | `net1167` | 1.434 mm |
| 7 | `net1031` | 1.386 mm |
| 8 | `net998` | 1.375 mm |
| 9 | `_06028_` | 1.326 mm |
| 10 | `net1034` | 1.322 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 3,619,416 | 202,492 | 5.59% ✅ | 0 /  0 /  0 |
| metal3 | 5,187,866 | 232,816 | 4.49% ✅ | 0 /  0 /  0 |
| metal4 | 2,077,934 | 49,068 | 2.36% ✅ | 0 /  0 /  0 |
| metal5 | 3,961,995 | 34,184 | 0.86% ✅ | 0 /  0 /  0 |
| metal6 | 3,956,418 | 1,708 | 0.04% ✅ | 0 /  0 /  0 |
| metal7 | 1,018,877 | 2,560 | 0.25% ✅ | 0 /  0 /  0 |
| metal8 | 1,020,305 | 11 | 0.00% ✅ | 0 /  0 /  0 |
| metal9 | 1,017,451 | 427 | 0.04% ✅ | 0 /  0 /  0 |
| **Total** | **21,860,262** | **523,266** | **2.39%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 1405958 µm

---

## 11. Manufacturability

| Check | Result |
|---|---|
| Antenna | Passed ✅ |
| LVS     | N/A |
| DRC     | Passed ✅ |

---

## 12. Flow Runtime

| Step | Tool | Runtime |
|---|---|---|
| Synthesis | Yosys | 00:04:59.428 |
| Floorplan | OpenROAD | 00:00:04.941 |
| Global Placement | OpenROAD (RePLace) | 00:01:53.393 |
| Clock Tree Synthesis | TritonCTS | 00:00:12.896 |
| Global Routing | OpenROAD (FastRoute) | 00:00:41.687 |
| Detailed Routing | TritonRoute | 00:01:33.674 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:00:57.416 |
| **Total (key steps)** | | **10 m 19 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

