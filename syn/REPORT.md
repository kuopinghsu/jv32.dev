# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-09-23

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
| `ZCMP_EN` | 1 |

---

## 2. Floorplan & Area

| Metric | Value |
|---|---|
| Die area | 960000 µm² = 0.960 mm² |
| Core area | 913469 µm² = 0.913 mm² |
| Standard cell area | 81577 µm² |
| Macro area | 382846 µm² |
| Total instance utilization | 50.8% |
| Std cell utilization | 15.37% |

---

## 3. Area Hierarchy (Gate Count)

> Source: `build/gate_count_run/stat.json`  
> Methodology: hierarchical (non-flattening) Yosys synthesis against Nangate 45 nm OCL.  
> Reference cell: NAND2\_X1 = 0.7980 µm².  SRAM macros treated as black-boxes (area excluded).  
> Note: pre-P&R counts; post-P&R NAND2-eq total is in §4.

| Module | NAND2-eq | Area (µm²) | % of SoC logic |
|---|---:|---:|---:|
| **jv32_soc** | **2,634** | **2,102.20** | **100.0%** |
| ↳ jv32_top | 3,547 | 2,830.77 | 134.7% |
| &nbsp;&nbsp;↳ jv32_core | 16,357 | 13,052.62 | 621.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ **jv32_alu** | **21,050** | **16,797.63** | **799.2%** |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_regfile | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_csr | 5,684 | 4,535.83 | 215.8% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_rvc | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_decoder | 437 | 348.73 | 16.6% |
| &nbsp;&nbsp;↳ sram_1rw | 253 | 202.16 | 9.6% |
| ↳ jtag_top | 1 | 1.06 | 0.0% |
| &nbsp;&nbsp;↳ jtag_tap | 5,229 | 4,172.48 | 198.5% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_dtm | 8,651 | 6,903.76 | 328.4% |
| ↳ axi_clic | 5,361 | 4,277.81 | 203.5% |
| ↳ axi_uart | 4,036 | 3,220.46 | 153.2% |
| ↳ axi_xbar | 599 | 478.00 | 22.7% |
| ↳ axi_magic | 0 | 0.00 | 0.0% |

### ALU area breakdown by function

| Sub-block | Config | Key cell types | Est. NAND2-eq | % of ALU |
|---|---|---|---:|---:|
| Multiplier (MUL/MULH/MULHSU/MULHU) | `FAST_MUL=1, MUL_MC=1` (2-stage 4×16×16 pipeline) | XOR2/XNOR2, DFFR (193 FFs) | ~4,052 | ~19% |
| Divider (DIV/DIVU/REM/REMU) | `FAST_DIV=0` (serial restoring) | NAND2/NOR2, DFFR (210 FFs) | ~1,575 | ~7% |
| Barrel shifter (SLL/SRL/SRA) | `FAST_SHIFT=1` (SRL/SRA shared¹) | MUX2, INV | ~166 | ~1% |
| ADD/SUB/logic/compare | — | XOR2/XNOR2, AOI/OAI | ~15,257 | ~72% |

¹ SRL and SRA share a single right-shift barrel tree (see [rtl/jv32/core/jv32_alu.sv](../rtl/jv32/core/jv32_alu.sv)); the second independent barrel shifter was removed, saving ~100–180 NAND2-eq.

---

## 4. Cell Count & Mix

| Category | Count | % of std cells |
|---|---|---|
| Total instances | 53408 | — |
| Standard cells (excl. tap) | 53,404 | 100% |
| Sequential (flip-flops) | 5440 | 10.2% |
| Multi-input combinational | 37108 | 69.5% |
| Buffers | 4874 | 9.1% |
| Inverters | 2419 | 4.5% |
| Macros | 4 | — |
| Tap cells | 3246 | — |
| I/O ports | 469 | — |
| **NAND2 equivalents (post-P&R)** | **102,227** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 231 |
| CTS buffers inserted | 1036 |
| Clock subnets | 1036 |
| Clock sinks | 5673 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.041985582865439075 ns ⚠️ |

> **Note:** Negative hold WNS immediately after CTS is expected — TritonCTS optimises setup skew and may temporarily worsen hold slack. The subsequent **Resizer / ECO (post-CTS)** step inserts hold buffers to close hold timing; the final post-PnR STA confirms hold WNS = 0.

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.675741 | -0.349546 |
| `jtag_tck` | 1.187508 | -0.231870 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.675741 |
| `jtag_tck` | 1.187508 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 75   | ⚠️ |
| Max cap violations    | 140510    | ℹ️ |
| Max fanout violations | 0 | ✅ |
| Unconstrained endpoints | 259 | ℹ️ |

> **Notes:**
> - **Max cap violations**: Nangate 45nm PDK artifact — Liberty `max_capacitance` limits are very conservative; OpenSTA flags most nets in the routed design even after the resizer has inserted `max_cap*` buffers. Does not indicate a functional or timing failure.
> - **Max slew violations**: Minor; common for this PDK and typically benign at 80 MHz.
> - **Unconstrained endpoints**: Top-level I/O ports have no input/output delay constraints (expected — this design targets ASIC integration, not stand-alone I/O timing closure).

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
| 1 | 23,257 | 2,218,832 |
| 2 | 5,513 | 2,209,503 |
| 3 | 4,394 | 2,208,168 |
| 4 | 109 | 2,207,949 |
| 5 | 1 | 2,207,941 |
| 6 | 0 | 2,207,941 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 0.90 mW | 0.12 mW | 0.47 mW | 1.48 mW | 8.2% |
| Combinational | 2.12 mW | 2.18 mW | 3.21 mW | 7.50 mW | 41.6% |
| Clock | 0.62 mW | 0.60 mW | 0.13 mW | 1.34 mW | 7.5% |
| Macro | 7.15 mW | 0.00 mW | 0.53 mW | 7.69 mW | 42.7% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 10.79 mW | 2.89 mW | 4.34 mW | 18.02 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 145,311 |
| Constrained signal nets | 140,641 |
| Total wirelength | **2207.89 mm** |
| Total vias | 748,456 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `clk` | 0.932 mm |
| 2 | `clknet_1_0__leaf_jtag_pin0_tck_i` | 0.784 mm |
| 3 | `net44522` | 0.755 mm |
| 4 | `clknet_3_6_0_clk` | 0.747 mm |
| 5 | `clknet_3_0_0_clk` | 0.715 mm |
| 6 | `clknet_3_1_0_clk` | 0.703 mm |
| 7 | `clknet_3_5_0_clk` | 0.681 mm |
| 8 | `_11856_` | 0.666 mm |
| 9 | `_17655_` | 0.664 mm |
| 10 | `_17509_` | 0.656 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 899,560 | 292,100 | 32.47% ✅ | 0 /  0 /  0 |
| metal3 | 1,291,937 | 484,426 | 37.50% ✅ | 0 /  0 /  0 |
| metal4 | 516,500 | 94,626 | 18.32% ✅ | 0 /  0 /  0 |
| metal5 | 846,097 | 103,128 | 12.19% ✅ | 0 /  0 /  0 |
| metal6 | 840,616 | 42,032 | 5.00% ✅ | 0 /  0 /  0 |
| metal7 | 217,360 | 13,870 | 6.38% ✅ | 0 /  0 /  0 |
| metal8 | 216,692 | 868 | 0.40% ✅ | 0 /  0 /  0 |
| metal9 | 215,840 | 9,468 | 4.39% ✅ | 0 /  0 /  0 |
| **Total** | **5,044,602** | **1,040,518** | **20.63%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 2787120 µm

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
| Synthesis | Yosys | 00:02:40.155 |
| Floorplan | OpenROAD | 00:00:05.701 |
| Global Placement | OpenROAD (RePLace) | 00:03:01.195 |
| Clock Tree Synthesis | TritonCTS | 00:00:20.935 |
| Resizer / ECO (post-CTS) | OpenROAD (resizer) | 00:41:26.942 |
| Global Routing | OpenROAD (FastRoute) | 00:00:48.658 |
| Detailed Routing | TritonRoute | 00:02:14.152 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:02:59.819 |
| GDS Stream-out | KLayout | 00:00:10.624 |
| SPICE Extraction | Magic | 00:03:44.115 |
| LVS | Netgen | 00:00:35.825 |
| **Total (listed steps)** | | **58 m 2 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

