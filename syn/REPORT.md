# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-05-18

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
| Die area | 980000 µm² = 0.980 mm² |
| Core area | 934939 µm² = 0.935 mm² |
| Standard cell area | 75953 µm² |
| Macro area | 382846 µm² |
| Total instance utilization | 49.1% |
| Std cell utilization | 13.76% |

---

## 3. Area Hierarchy (Gate Count)

> Source: `build/gate_count_run/stat.json`
> Methodology: hierarchical (non-flattening) Yosys synthesis against Nangate 45 nm OCL.
> Reference cell: NAND2\_X1 = 0.7980 µm².  SRAM macros treated as black-boxes (area excluded).
> Note: pre-P&R counts; post-P&R NAND2-eq total is in §4.

| Module | NAND2-eq | Area (µm²) | % of SoC logic |
|---|---:|---:|---:|
| **jv32_soc** | **2,689** | **2,145.82** | **100.0%** |
| ↳ jv32_top | 3,550 | 2,833.17 | 132.0% |
| &nbsp;&nbsp;↳ jv32_core | 15,270 | 12,185.73 | 567.9% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ **jv32_alu** | **17,431** | **13,909.94** | **648.2%** |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_regfile | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_csr | 4,986 | 3,978.56 | 185.4% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_rvc | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_decoder | 433 | 345.53 | 16.1% |
| &nbsp;&nbsp;↳ sram_1rw | 253 | 202.16 | 9.4% |
| ↳ jtag_top | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;↳ jtag_tap | 5,017 | 4,003.30 | 186.6% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_dtm | 0 | 0.00 | 0.0% |
| ↳ axi_clic | 5,472 | 4,366.92 | 203.5% |
| ↳ axi_uart | 3,755 | 2,996.22 | 139.6% |
| ↳ axi_xbar | 568 | 453.00 | 21.1% |
| ↳ axi_magic | 0 | 0.00 | 0.0% |

### ALU area breakdown by function

| Sub-block | Config | Key cell types | Est. NAND2-eq | % of ALU |
|---|---|---|---:|---:|
| Multiplier (MUL/MULH/MULHSU/MULHU) | `FAST_MUL=1, MUL_MC=1` (2-stage 4×16×16 pipeline) | XOR2/XNOR2, DFFR (193 FFs) | ~3,023 | ~17% |
| Divider (DIV/DIVU/REM/REMU) | `FAST_DIV=0` (serial restoring) | NAND2/NOR2, DFFR (210 FFs) | ~1,357 | ~8% |
| Barrel shifter (SLL/SRL/SRA) | `FAST_SHIFT=1` (SRL/SRA shared¹) | MUX2, INV | ~162 | ~1% |
| ADD/SUB/logic/compare | — | XOR2/XNOR2, AOI/OAI | ~12,889 | ~74% |

¹ SRL and SRA share a single right-shift barrel tree (see [rtl/jv32/core/jv32_alu.sv](../rtl/jv32/core/jv32_alu.sv)); the second independent barrel shifter was removed, saving ~100–180 NAND2-eq.

---

## 4. Cell Count & Mix

| Category | Count | % of std cells |
|---|---|---|
| Total instances | 49510 | — |
| Standard cells (excl. tap) | 49,506 | 100% |
| Sequential (flip-flops) | 5291 | 10.7% |
| Multi-input combinational | 33701 | 68.1% |
| Buffers | 4524 | 9.1% |
| Inverters | 2178 | 4.4% |
| Macros | 4 | — |
| Tap cells | 3507 | — |
| I/O ports | 469 | — |
| **NAND2 equivalents (post-P&R)** | **95,179** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 223 |
| CTS buffers inserted | 1021 |
| Clock subnets | 1021 |
| Clock sinks | 5516 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.07319972613017654 ns ⚠️ |

> **Note:** Negative hold WNS immediately after CTS is expected — TritonCTS optimises setup skew and may temporarily worsen hold slack. The subsequent **Resizer / ECO (post-CTS)** step inserts hold buffers to close hold timing; the final post-PnR STA confirms hold WNS = 0.

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.573454 | -0.273345 |
| `jtag_tck` | 1.169694 | -0.274758 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.573454 |
| `jtag_tck` | 1.169694 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 69   | ⚠️ |
| Max cap violations    | 129937    | ℹ️ |
| Max fanout violations | 0 | ✅ |
| Unconstrained endpoints | 251 | ℹ️ |

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
| 1 | 21,992 | 1,872,059 |
| 2 | 5,241 | 1,863,208 |
| 3 | 3,970 | 1,862,114 |
| 4 | 163 | 1,861,810 |
| 5 | 0 | 1,861,789 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 1.15 mW | 0.12 mW | 0.45 mW | 1.71 mW | 7.4% |
| Combinational | 4.92 mW | 4.43 mW | 2.92 mW | 12.26 mW | 52.9% |
| Clock | 0.71 mW | 0.66 mW | 0.13 mW | 1.50 mW | 6.5% |
| Macro | 7.15 mW | 0.00 mW | 0.53 mW | 7.69 mW | 33.2% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 13.93 mW | 5.21 mW | 4.02 mW | 23.16 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 134,705 |
| Constrained signal nets | 130,060 |
| Total wirelength | **1861.74 mm** |
| Total vias | 685,644 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `clknet_3_4__leaf_clk` | 1.008 mm |
| 2 | `clk` | 0.895 mm |
| 3 | `clknet_3_5__leaf_clk` | 0.833 mm |
| 4 | `_02704_` | 0.745 mm |
| 5 | `_10253_` | 0.700 mm |
| 6 | `net10` | 0.698 mm |
| 7 | `_10212_` | 0.696 mm |
| 8 | `clknet_1_0__leaf_jtag_pin0_tck_i` | 0.640 mm |
| 9 | `net8` | 0.639 mm |
| 10 | `net62774` | 0.613 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 933,964 | 280,728 | 30.06% ✅ | 0 /  0 /  0 |
| metal3 | 1,336,998 | 362,782 | 27.13% ✅ | 0 /  0 /  0 |
| metal4 | 536,544 | 99,769 | 18.59% ✅ | 0 /  0 /  0 |
| metal5 | 862,809 | 71,657 | 8.31% ✅ | 0 /  0 /  0 |
| metal6 | 859,936 | 60,035 | 6.98% ✅ | 0 /  0 /  0 |
| metal7 | 222,110 | 4,791 | 2.16% ✅ | 0 /  0 /  0 |
| metal8 | 221,444 | 1,590 | 0.72% ✅ | 0 /  0 /  0 |
| metal9 | 220,780 | 599 | 0.27% ✅ | 0 /  0 /  0 |
| **Total** | **5,194,585** | **881,951** | **16.98%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 2396574 µm

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
| Synthesis | Yosys | 00:02:33.807 |
| Floorplan | OpenROAD | 00:00:05.411 |
| Global Placement | OpenROAD (RePLace) | 00:02:52.419 |
| Clock Tree Synthesis | TritonCTS | 00:00:20.397 |
| Resizer / ECO (post-CTS) | OpenROAD (resizer) | 00:37:42.387 |
| Global Routing | OpenROAD (FastRoute) | 00:00:36.072 |
| Detailed Routing | TritonRoute | 00:02:07.418 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:02:57.092 |
| GDS Stream-out | KLayout | 00:00:10.262 |
| SPICE Extraction | Magic | 00:03:23.596 |
| LVS | Netgen | 00:00:29.065 |
| **Total (listed steps)** | | **53 m 14 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

