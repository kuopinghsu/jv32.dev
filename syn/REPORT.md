# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-04-26

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
| Standard cell area | 64148 µm² |
| Macro area | 2183510 µm² |
| Total instance utilization | 51.0% |
| Std cell utilization | 2.89% |

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
| Total instances | 44223 | — |
| Standard cells (excl. tap) | 44,219 | 100% |
| Sequential (flip-flops) | 5152 | 11.7% |
| Multi-input combinational | 26787 | 60.6% |
| Buffers | 96 | 0.2% |
| Inverters | 2280 | 5.2% |
| Macros | 4 | — |
| Tap cells | 9904 | — |
| I/O ports | 768 | — |
| **NAND2 equivalents (post-P&R)** | **80,386** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 2 |
| CTS buffers inserted | 267 |
| Clock subnets | 267 |
| Clock sinks | 5156 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.06980421993563149 ns ⚠️ |

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.593932 | -0.116669 |
| `jtag_tck` | 1.012936 | -0.116669 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.593932 |
| `jtag_tck` | 1.012936 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 128   | ⚠️ |
| Max cap violations    | 188    | ⚠️ |
| Max fanout violations | 2 | ⚠️ |
| Unconstrained endpoints | 51 | ℹ️ |

### Timing Convergence

| Stage | Setup WNS (ns) | |
|---|---|---|
| Pre-PnR (synthesis) | -9.556 | ❌ |
| Post-placement (mid-PnR) | -13.170 | ❌ |
| Post-CTS + resizer | 0.000 | ✅ |
| Post-GRT resizer | 0.000 | ✅ |
| **Post-route STA (sign-off)** | **0.000** | ✅ |

---

## 7. Design Rule Checks (Post-Route)

| Iteration | DRC Errors | Wirelength (µm) |
|---|---|---|
| 1 | 12,201 | 1,168,964 |
| 2 | 2,010 | 1,164,388 |
| 3 | 1,223 | 1,163,762 |
| 4 | 40 | 1,163,696 |
| 5 | 0 | 1,163,688 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 3.19 mW | 0.45 mW | 0.43 mW | 4.08 mW | 19.8% |
| Combinational | 1.92 mW | 2.91 mW | 1.27 mW | 6.11 mW | 29.6% |
| Clock | 0.30 mW | 0.89 mW | 0.02 mW | 1.21 mW | 5.9% |
| Macro | 8.63 mW | 0.00 mW | 0.59 mW | 9.22 mW | 44.7% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 14.04 mW | 4.26 mW | 2.31 mW | 20.61 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 41,923 |
| Constrained signal nets | 38,187 |
| Total wirelength | **1163.65 mm** |
| Total vias | 376,486 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `net135` | 2.407 mm |
| 2 | `_06035_` | 1.668 mm |
| 3 | `net1127` | 1.553 mm |
| 4 | `net1130` | 1.551 mm |
| 5 | `net4` | 1.407 mm |
| 6 | `net1007` | 1.357 mm |
| 7 | `_06139_` | 1.308 mm |
| 8 | `net1126` | 1.291 mm |
| 9 | `net1011` | 1.268 mm |
| 10 | `net950` | 1.216 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 3,619,416 | 196,960 | 5.44% ✅ | 0 /  0 /  0 |
| metal3 | 5,187,866 | 251,525 | 4.85% ✅ | 0 /  0 /  0 |
| metal4 | 2,077,934 | 38,441 | 1.85% ✅ | 0 /  0 /  0 |
| metal5 | 3,961,995 | 34,187 | 0.86% ✅ | 0 /  0 /  0 |
| metal6 | 3,956,418 | 3,201 | 0.08% ✅ | 0 /  0 /  0 |
| metal7 | 1,018,877 | 1,650 | 0.16% ✅ | 0 /  0 /  0 |
| metal8 | 1,020,305 | 18 | 0.00% ✅ | 0 /  0 /  0 |
| metal9 | 1,017,451 | 386 | 0.04% ✅ | 0 /  0 /  0 |
| **Total** | **21,860,262** | **526,368** | **2.41%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 1413018 µm

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
| Synthesis | Yosys | 00:05:20.862 |
| Floorplan | OpenROAD | 00:00:01.411 |
| Global Placement | OpenROAD (RePLace) | 00:01:42.804 |
| Clock Tree Synthesis | TritonCTS | 00:00:11.362 |
| Global Routing | OpenROAD (FastRoute) | 00:00:43.075 |
| Detailed Routing | TritonRoute | 00:01:37.848 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:00:55.777 |
| **Total (key steps)** | | **10 m 29 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

