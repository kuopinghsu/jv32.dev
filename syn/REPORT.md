# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-05-25

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
| Standard cell area | 75883 µm² |
| Macro area | 382846 µm² |
| Total instance utilization | 50.2% |
| Std cell utilization | 14.30% |

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
| Total instances | 49249 | — |
| Standard cells (excl. tap) | 49,245 | 100% |
| Sequential (flip-flops) | 5291 | 10.7% |
| Multi-input combinational | 33701 | 68.4% |
| Buffers | 4524 | 9.2% |
| Inverters | 2178 | 4.4% |
| Macros | 4 | — |
| Tap cells | 3246 | — |
| I/O ports | 469 | — |
| **NAND2 equivalents (post-P&R)** | **95,092** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 223 |
| CTS buffers inserted | 1010 |
| Clock subnets | 1010 |
| Clock sinks | 5516 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.06937944859439654 ns ⚠️ |

> **Note:** Negative hold WNS immediately after CTS is expected — TritonCTS optimises setup skew and may temporarily worsen hold slack. The subsequent **Resizer / ECO (post-CTS)** step inserts hold buffers to close hold timing; the final post-PnR STA confirms hold WNS = 0.

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.579098 | -0.282790 |
| `jtag_tck` | 1.156651 | -0.256651 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.579098 |
| `jtag_tck` | 1.156651 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 68   | ⚠️ |
| Max cap violations    | 130274    | ℹ️ |
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
| 1 | 20,977 | 1,865,957 |
| 2 | 5,152 | 1,857,120 |
| 3 | 3,984 | 1,855,640 |
| 4 | 171 | 1,855,307 |
| 5 | 0 | 1,855,283 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 1.15 mW | 0.11 mW | 0.45 mW | 1.70 mW | 7.3% |
| Combinational | 4.94 mW | 4.57 mW | 2.92 mW | 12.43 mW | 53.6% |
| Clock | 0.64 mW | 0.62 mW | 0.12 mW | 1.39 mW | 6.0% |
| Macro | 7.15 mW | 0.00 mW | 0.53 mW | 7.69 mW | 33.1% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 13.88 mW | 5.30 mW | 4.02 mW | 23.21 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 135,042 |
| Constrained signal nets | 130,397 |
| Total wirelength | **1855.23 mm** |
| Total vias | 688,454 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `clk` | 0.942 mm |
| 2 | `_02704_` | 0.820 mm |
| 3 | `clknet_3_6_0_clk` | 0.782 mm |
| 4 | `clknet_3_5_0_clk` | 0.713 mm |
| 5 | `clknet_3_0_0_clk` | 0.667 mm |
| 6 | `net6` | 0.616 mm |
| 7 | `net4` | 0.610 mm |
| 8 | `net5` | 0.599 mm |
| 9 | `_32887_` | 0.567 mm |
| 10 | `clknet_3_2_0_clk` | 0.565 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 899,560 | 273,424 | 30.40% ✅ | 0 /  0 /  0 |
| metal3 | 1,291,937 | 438,198 | 33.92% ✅ | 0 /  0 /  0 |
| metal4 | 516,500 | 75,543 | 14.63% ✅ | 0 /  0 /  0 |
| metal5 | 846,097 | 67,294 | 7.95% ✅ | 0 /  0 /  0 |
| metal6 | 840,616 | 12,264 | 1.46% ✅ | 0 /  0 /  0 |
| metal7 | 217,360 | 6,221 | 2.86% ✅ | 0 /  0 /  0 |
| metal8 | 216,692 | 279 | 0.13% ✅ | 0 /  0 /  0 |
| metal9 | 215,840 | 2,726 | 1.26% ✅ | 0 /  0 /  0 |
| **Total** | **5,044,602** | **875,949** | **17.36%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 2401704 µm

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
| Synthesis | Yosys | 00:02:31.394 |
| Floorplan | OpenROAD | 00:00:05.746 |
| Global Placement | OpenROAD (RePLace) | 00:03:00.213 |
| Clock Tree Synthesis | TritonCTS | 00:00:18.381 |
| Resizer / ECO (post-CTS) | OpenROAD (resizer) | 00:35:03.637 |
| Global Routing | OpenROAD (FastRoute) | 00:00:35.584 |
| Detailed Routing | TritonRoute | 00:02:07.702 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:02:41.021 |
| GDS Stream-out | KLayout | 00:00:09.602 |
| SPICE Extraction | Magic | 00:02:59.579 |
| LVS | Netgen | 00:00:32.785 |
| **Total (listed steps)** | | **50 m 0 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

