# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-04-28

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
| Standard cell area | 67871 µm² |
| Macro area | 2183510 µm² |
| Total instance utilization | 51.1% |
| Std cell utilization | 3.05% |

---

## 3. Area Hierarchy (Gate Count)

> Source: `build/gate_count_run/stat.json`
> Methodology: hierarchical (non-flattening) Yosys synthesis against Nangate 45 nm OCL.
> Reference cell: NAND2\_X1 = 0.7980 µm².  SRAM macros treated as black-boxes (area excluded).
> Note: pre-P&R counts; post-P&R NAND2-eq total is in §4.

| Module | NAND2-eq | Area (µm²) | % of SoC logic |
|---|---:|---:|---:|
| **jv32_soc** | **1,955** | **1,560.36** | **100.0%** |
| ↳ jv32_top | 3,545 | 2,828.64 | 181.3% |
| &nbsp;&nbsp;↳ jv32_core | 13,358 | 10,659.68 | 683.3% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ **jv32_alu** | **17,503** | **13,967.39** | **895.3%** |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_regfile | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_csr | 5,058 | 4,036.55 | 258.7% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_rvc | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_decoder | 428 | 341.81 | 21.9% |
| &nbsp;&nbsp;↳ sram_1rw | 84 | 66.77 | 4.3% |
| ↳ jtag_top | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;↳ jtag_tap | 212 | 169.44 | 10.8% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_dtm | 15,628 | 12,471.14 | 799.4% |
| ↳ axi_clic | 5,289 | 4,220.89 | 270.5% |
| ↳ axi_uart | 3,720 | 2,968.56 | 190.3% |
| ↳ axi_xbar | 568 | 453.00 | 29.1% |
| ↳ axi_magic | 0 | 0.00 | 0.0% |

### ALU area breakdown by function

| Sub-block | Config | Key cell types | Est. NAND2-eq | % of ALU |
|---|---|---|---:|---:|
| Multiplier (MUL/MULH/MULHSU/MULHU) | `FAST_MUL=1, MUL_MC=1` (2-stage 4×16×16 pipeline) | XOR2/XNOR2, DFFR (193 FFs) | ~3,033 | ~17% |
| Divider (DIV/DIVU/REM/REMU) | `FAST_DIV=0` (serial restoring) | NAND2/NOR2, DFFR (210 FFs) | ~1,355 | ~8% |
| Barrel shifter (SLL/SRL/SRA) | `FAST_SHIFT=1` (SRL/SRA shared¹) | MUX2, INV | ~165 | ~1% |
| ADD/SUB/logic/compare | — | XOR2/XNOR2, AOI/OAI | ~12,950 | ~74% |

¹ SRL and SRA share a single right-shift barrel tree (see [rtl/jv32/core/jv32_alu.sv](../rtl/jv32/core/jv32_alu.sv)); the second independent barrel shifter was removed, saving ~100–180 NAND2-eq.

---

## 4. Cell Count & Mix

| Category | Count | % of std cells |
|---|---|---|
| Total instances | 46861 | — |
| Standard cells (excl. tap) | 46,857 | 100% |
| Sequential (flip-flops) | 5376 | 11.5% |
| Multi-input combinational | 29344 | 62.6% |
| Buffers | 96 | 0.2% |
| Inverters | 2137 | 4.6% |
| Macros | 4 | — |
| Tap cells | 9904 | — |
| I/O ports | 774 | — |
| **NAND2 equivalents (post-P&R)** | **85,051** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 2 |
| CTS buffers inserted | 277 |
| Clock subnets | 277 |
| Clock sinks | 5380 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.11190698684463395 ns ⚠️ |

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.625048 | -0.170009 |
| `jtag_tck` | 1.046123 | -0.170009 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.625048 |
| `jtag_tck` | 1.046123 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 61   | ⚠️ |
| Max cap violations    | 210    | ⚠️ |
| Max fanout violations | 0 | ✅ |
| Unconstrained endpoints | 51 | ℹ️ |

### Timing Convergence

| Stage | Setup WNS (ns) | |
|---|---|---|
| Pre-PnR (synthesis) | -12.557 | ❌ |
| Post-placement (mid-PnR) | -16.912 | ❌ |
| Post-CTS + resizer | 0.000 | ✅ |
| Post-GRT resizer | 0.000 | ✅ |
| **Post-route STA (sign-off)** | **0.000** | ✅ |

---

## 7. Design Rule Checks (Post-Route)

| Iteration | DRC Errors | Wirelength (µm) |
|---|---|---|
| 1 | 13,192 | 1,280,748 |
| 2 | 2,192 | 1,275,838 |
| 3 | 1,608 | 1,275,116 |
| 4 | 56 | 1,275,043 |
| 5 | 0 | 1,275,036 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 2.69 mW | 0.18 mW | 0.45 mW | 3.32 mW | 19.8% |
| Combinational | 0.58 mW | 1.02 mW | 1.37 mW | 2.97 mW | 17.7% |
| Clock | 0.33 mW | 0.95 mW | 0.02 mW | 1.29 mW | 7.7% |
| Macro | 8.63 mW | 0.00 mW | 0.59 mW | 9.22 mW | 54.9% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 12.23 mW | 2.14 mW | 2.43 mW | 16.81 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 44,926 |
| Constrained signal nets | 40,994 |
| Total wirelength | **1275.00 mm** |
| Total vias | 407,157 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `net135` | 2.845 mm |
| 2 | `_06287_` | 1.930 mm |
| 3 | `_06340_` | 1.559 mm |
| 4 | `net1251` | 1.552 mm |
| 5 | `net1252` | 1.538 mm |
| 6 | `net1254` | 1.417 mm |
| 7 | `net1253` | 1.390 mm |
| 8 | `net1140` | 1.367 mm |
| 9 | `_07469_` | 1.277 mm |
| 10 | `net1256` | 1.207 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 3,619,416 | 219,556 | 6.07% ✅ | 0 /  0 /  0 |
| metal3 | 5,187,866 | 253,603 | 4.89% ✅ | 0 /  0 /  0 |
| metal4 | 2,077,934 | 60,178 | 2.90% ✅ | 0 /  0 /  0 |
| metal5 | 3,961,995 | 33,423 | 0.84% ✅ | 0 /  0 /  0 |
| metal6 | 3,956,418 | 3,850 | 0.10% ✅ | 0 /  0 /  0 |
| metal7 | 1,018,877 | 4,708 | 0.46% ✅ | 0 /  0 /  0 |
| metal8 | 1,020,305 | 22 | 0.00% ✅ | 0 /  0 /  0 |
| metal9 | 1,017,451 | 1,096 | 0.11% ✅ | 0 /  0 /  0 |
| **Total** | **21,860,262** | **576,436** | **2.64%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 1538598 µm

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
| Synthesis | Yosys | 00:07:55.914 |
| Floorplan | OpenROAD | 00:00:07.810 |
| Global Placement | OpenROAD (RePLace) | 00:01:37.116 |
| Clock Tree Synthesis | TritonCTS | 00:00:11.552 |
| Global Routing | OpenROAD (FastRoute) | 00:00:43.554 |
| Detailed Routing | TritonRoute | 00:01:47.442 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:01:13.310 |
| **Total (key steps)** | | **13 m 33 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

