# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-05-12

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
| Die area | 1552320 µm² = 1.552 mm² |
| Core area | 1499220 µm² = 1.499 mm² |
| Standard cell area | 69414 µm² |
| Macro area | 382846 µm² |
| Total instance utilization | 30.2% |
| Std cell utilization | 6.22% |

---

## 3. Area Hierarchy (Gate Count)

> Source: `build/gate_count_run/stat.json`
> Methodology: hierarchical (non-flattening) Yosys synthesis against Nangate 45 nm OCL.
> Reference cell: NAND2\_X1 = 0.7980 µm².  SRAM macros treated as black-boxes (area excluded).
> Note: pre-P&R counts; post-P&R NAND2-eq total is in §4.

| Module | NAND2-eq | Area (µm²) | % of SoC logic |
|---|---:|---:|---:|
| **jv32_soc** | **2,613** | **2,085.44** | **100.0%** |
| ↳ jv32_top | 3,550 | 2,833.17 | 135.9% |
| &nbsp;&nbsp;↳ jv32_core | 15,302 | 12,211.00 | 585.6% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ **jv32_alu** | **17,385** | **13,873.23** | **665.3%** |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_regfile | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_csr | 5,077 | 4,051.71 | 194.3% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_rvc | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_decoder | 463 | 369.21 | 17.7% |
| &nbsp;&nbsp;↳ sram_1rw | 253 | 202.16 | 9.7% |
| ↳ jtag_top | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;↳ jtag_tap | 5,017 | 4,003.30 | 192.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_dtm | 0 | 0.00 | 0.0% |
| ↳ axi_clic | 5,422 | 4,327.02 | 207.5% |
| ↳ axi_uart | 3,696 | 2,949.41 | 141.4% |
| ↳ axi_xbar | 568 | 453.00 | 21.7% |
| ↳ axi_magic | 0 | 0.00 | 0.0% |

### ALU area breakdown by function

| Sub-block | Config | Key cell types | Est. NAND2-eq | % of ALU |
|---|---|---|---:|---:|
| Multiplier (MUL/MULH/MULHSU/MULHU) | `FAST_MUL=1, MUL_MC=1` (2-stage 4×16×16 pipeline) | XOR2/XNOR2, DFFR (193 FFs) | ~3,020 | ~17% |
| Divider (DIV/DIVU/REM/REMU) | `FAST_DIV=0` (serial restoring) | NAND2/NOR2, DFFR (210 FFs) | ~1,364 | ~8% |
| Barrel shifter (SLL/SRL/SRA) | `FAST_SHIFT=1` (SRL/SRA shared¹) | MUX2, INV | ~167 | ~1% |
| ADD/SUB/logic/compare | — | XOR2/XNOR2, AOI/OAI | ~12,834 | ~74% |

¹ SRL and SRA share a single right-shift barrel tree (see [rtl/jv32/core/jv32_alu.sv](../rtl/jv32/core/jv32_alu.sv)); the second independent barrel shifter was removed, saving ~100–180 NAND2-eq.

---

## 4. Cell Count & Mix

| Category | Count | % of std cells |
|---|---|---|
| Total instances | 46192 | — |
| Standard cells (excl. tap) | 46,188 | 100% |
| Sequential (flip-flops) | 5311 | 11.5% |
| Multi-input combinational | 31230 | 67.6% |
| Buffers | 1 | 0.0% |
| Inverters | 2562 | 5.5% |
| Macros | 4 | — |
| Tap cells | 6785 | — |
| I/O ports | 469 | — |
| **NAND2 equivalents (post-P&R)** | **86,984** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 218 |
| CTS buffers inserted | 1100 |
| Clock subnets | 1100 |
| Clock sinks | 5531 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.09248557736983495 ns ⚠️ |

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.695000 | -0.255517 |
| `jtag_tck` | 1.158446 | -0.255517 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | -0.0169656515860258  | -0.031025183300602107  | ❌ VIOLATED  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.695000 |
| `jtag_tck` | 1.158446 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 62   | ⚠️ |
| Max cap violations    | 610    | ⚠️ |
| Max fanout violations | 0 | ✅ |
| Unconstrained endpoints | 251 | ℹ️ |

### Timing Convergence

| Stage | Setup WNS (ns) | |
|---|---|---|
| Pre-PnR (synthesis) | -0.889 | ⚠️ |
| Post-placement (mid-PnR) | -4.117 | ❌ |
| Post-CTS + resizer | 0.000 | ✅ |
| **Post-route STA (sign-off)** | **0.000** | ✅ |

---

## 7. Design Rule Checks (Post-Route)

| Iteration | DRC Errors | Wirelength (µm) |
|---|---|---|
| 1 | 47,852 | 3,336,189 |
| 2 | 19,238 | 3,332,134 |
| 3 | 16,668 | 3,330,914 |
| 4 | 1,088 | 3,329,904 |
| 5 | 58 | 3,329,785 |
| 6 | 0 | 3,329,777 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 1.69 mW | 1.05 mW | 0.50 mW | 3.24 mW | 13.2% |
| Combinational | 3.31 mW | 6.65 mW | 1.78 mW | 11.74 mW | 47.8% |
| Clock | 0.73 mW | 1.02 mW | 0.12 mW | 1.87 mW | 7.6% |
| Macro | 7.15 mW | 0.00 mW | 0.53 mW | 7.69 mW | 31.3% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 12.88 mW | 8.72 mW | 2.93 mW | 24.53 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 50,372 |
| Constrained signal nets | 45,650 |
| Total wirelength | **3329.73 mm** |
| Total vias | 611,558 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `_05446_` | 2.187 mm |
| 2 | `_06030_` | 1.779 mm |
| 3 | `_06111_` | 1.709 mm |
| 4 | `net979` | 1.568 mm |
| 5 | `dbg_reg_wdata\[13\]` | 1.500 mm |
| 6 | `net242` | 1.496 mm |
| 7 | `dbg_reg_wdata\[15\]` | 1.496 mm |
| 8 | `dbg_reg_wdata\[28\]` | 1.481 mm |
| 9 | `dbg_reg_wdata\[7\]` | 1.480 mm |
| 10 | `dbg_reg_wdata\[14\]` | 1.475 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 2,368,512 | 546,860 | 23.09% ✅ | 0 /  0 /  0 |
| metal3 | 3,158,845 | 765,665 | 24.24% ✅ | 0 /  0 /  0 |
| metal4 | 1,318,048 | 92,886 | 7.05% ✅ | 0 /  0 /  0 |
| metal5 | 1,703,528 | 91,328 | 5.36% ✅ | 0 /  0 /  0 |
| metal6 | 1,701,208 | 27,904 | 1.64% ✅ | 0 /  0 /  0 |
| metal7 | 351,906 | 969 | 0.28% ✅ | 0 /  0 /  0 |
| metal8 | 351,120 | 26 | 0.01% ✅ | 0 /  0 /  0 |
| metal9 | 350,588 | 438 | 0.12% ✅ | 0 /  0 /  0 |
| **Total** | **11,303,755** | **1,526,076** | **13.50%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 3662805 µm

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
| Synthesis | Yosys | 00:08:26.959 |
| Floorplan | OpenROAD | 00:00:06.401 |
| Global Placement | OpenROAD (RePLace) | 00:01:50.971 |
| Clock Tree Synthesis | TritonCTS | 00:00:13.223 |
| Global Routing | OpenROAD (FastRoute) | 00:00:53.990 |
| Detailed Routing | TritonRoute | 00:04:08.853 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:01:34.127 |
| **Total (key steps)** | | **17 m 10 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

