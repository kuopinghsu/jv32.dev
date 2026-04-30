# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-04-30

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
| `IBUF_EN` | 1 |

---

## 2. Floorplan & Area

| Metric | Value |
|---|---|
| Die area | 4500000 µm² = 4.500 mm² |
| Core area | 4406880 µm² = 4.407 mm² |
| Standard cell area | 71066 µm² |
| Macro area | 2183510 µm² |
| Total instance utilization | 51.2% |
| Std cell utilization | 3.20% |

---

## 3. Area Hierarchy (Gate Count)

> Source: `build/gate_count_run/stat.json`
> Methodology: hierarchical (non-flattening) Yosys synthesis against Nangate 45 nm OCL.
> Reference cell: NAND2\_X1 = 0.7980 µm².  SRAM macros treated as black-boxes (area excluded).
> Note: pre-P&R counts; post-P&R NAND2-eq total is in §4.

| Module | NAND2-eq | Area (µm²) | % of SoC logic |
|---|---:|---:|---:|
| **jv32_soc** | **1,953** | **1,558.49** | **100.0%** |
| ↳ jv32_top | 3,559 | 2,840.08 | 182.2% |
| &nbsp;&nbsp;↳ jv32_core | 16,621 | 13,263.82 | 851.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ **jv32_alu** | **17,463** | **13,935.74** | **894.2%** |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_regfile | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_csr | 5,057 | 4,035.75 | 258.9% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_rvc | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_decoder | 436 | 347.66 | 22.3% |
| &nbsp;&nbsp;↳ sram_1rw | 84 | 66.77 | 4.3% |
| ↳ jtag_top | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;↳ jtag_tap | 212 | 169.44 | 10.9% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_dtm | 15,660 | 12,496.41 | 801.8% |
| ↳ axi_clic | 5,289 | 4,220.89 | 270.8% |
| ↳ axi_uart | 3,690 | 2,944.35 | 188.9% |
| ↳ axi_xbar | 568 | 453.00 | 29.1% |
| ↳ axi_magic | 0 | 0.00 | 0.0% |

### ALU area breakdown by function

| Sub-block | Config | Key cell types | Est. NAND2-eq | % of ALU |
|---|---|---|---:|---:|
| Multiplier (MUL/MULH/MULHSU/MULHU) | `FAST_MUL=1, MUL_MC=1` (2-stage 4×16×16 pipeline) | XOR2/XNOR2, DFFR (193 FFs) | ~3,008 | ~17% |
| Divider (DIV/DIVU/REM/REMU) | `FAST_DIV=0` (serial restoring) | NAND2/NOR2, DFFR (210 FFs) | ~1,377 | ~8% |
| Barrel shifter (SLL/SRL/SRA) | `FAST_SHIFT=1` (SRL/SRA shared¹) | MUX2, INV | ~141 | ~1% |
| ADD/SUB/logic/compare | — | XOR2/XNOR2, AOI/OAI | ~12,937 | ~74% |

¹ SRL and SRA share a single right-shift barrel tree (see [rtl/jv32/core/jv32_alu.sv](../rtl/jv32/core/jv32_alu.sv)); the second independent barrel shifter was removed, saving ~100–180 NAND2-eq.

---

## 4. Cell Count & Mix

| Category | Count | % of std cells |
|---|---|---|
| Total instances | 48594 | — |
| Standard cells (excl. tap) | 48,590 | 100% |
| Sequential (flip-flops) | 5639 | 11.6% |
| Multi-input combinational | 30575 | 62.9% |
| Buffers | 96 | 0.2% |
| Inverters | 2376 | 4.9% |
| Macros | 4 | — |
| Tap cells | 9904 | — |
| I/O ports | 775 | — |
| **NAND2 equivalents (post-P&R)** | **89,055** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 2 |
| CTS buffers inserted | 323 |
| Clock subnets | 323 |
| Clock sinks | 5643 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.10288298282296195 ns ⚠️ |

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.634354 | -0.160387 |
| `jtag_tck` | 1.059981 | -0.118817 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.634354 |
| `jtag_tck` | 1.059981 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 61   | ⚠️ |
| Max cap violations    | 175    | ⚠️ |
| Max fanout violations | 2 | ⚠️ |
| Unconstrained endpoints | 51 | ℹ️ |

### Timing Convergence

| Stage | Setup WNS (ns) | |
|---|---|---|
| Pre-PnR (synthesis) | -16.098 | ❌ |
| Post-placement (mid-PnR) | -20.705 | ❌ |
| Post-CTS + resizer | 0.000 | ✅ |
| Post-GRT resizer | 0.000 | ✅ |
| **Post-route STA (sign-off)** | **0.000** | ✅ |

---

## 7. Design Rule Checks (Post-Route)

| Iteration | DRC Errors | Wirelength (µm) |
|---|---|---|
| 1 | 13,711 | 1,313,327 |
| 2 | 2,382 | 1,308,223 |
| 3 | 1,639 | 1,307,348 |
| 4 | 99 | 1,307,324 |
| 5 | 0 | 1,307,319 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 3.70 mW | 0.74 mW | 0.47 mW | 4.91 mW | 20.1% |
| Combinational | 3.01 mW | 4.45 mW | 1.42 mW | 8.88 mW | 36.4% |
| Clock | 0.37 mW | 1.02 mW | 0.02 mW | 1.40 mW | 5.8% |
| Macro | 8.63 mW | 0.00 mW | 0.59 mW | 9.22 mW | 37.8% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 15.71 mW | 6.21 mW | 2.50 mW | 24.42 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 46,943 |
| Constrained signal nets | 42,748 |
| Total wirelength | **1307.28 mm** |
| Total vias | 422,329 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `net135` | 1.771 mm |
| 2 | `_06526_` | 1.662 mm |
| 3 | `net1232` | 1.534 mm |
| 4 | `net1228` | 1.460 mm |
| 5 | `_08016_` | 1.438 mm |
| 6 | `net1229` | 1.425 mm |
| 7 | `_06584_` | 1.377 mm |
| 8 | `net1231` | 1.333 mm |
| 9 | `net1230` | 1.236 mm |
| 10 | `_07964_` | 1.230 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 3,619,416 | 223,352 | 6.17% ✅ | 0 /  0 /  0 |
| metal3 | 5,187,866 | 279,934 | 5.40% ✅ | 0 /  0 /  0 |
| metal4 | 2,077,934 | 42,308 | 2.04% ✅ | 0 /  0 /  0 |
| metal5 | 3,961,995 | 34,482 | 0.87% ✅ | 0 /  0 /  0 |
| metal6 | 3,956,418 | 7,966 | 0.20% ✅ | 0 /  0 /  0 |
| metal7 | 1,018,877 | 2,271 | 0.22% ✅ | 0 /  0 /  0 |
| metal8 | 1,020,305 | 365 | 0.04% ✅ | 0 /  0 /  0 |
| metal9 | 1,017,451 | 350 | 0.03% ✅ | 0 /  0 /  0 |
| **Total** | **21,860,262** | **591,028** | **2.70%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 1583175 µm

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
| Synthesis | Yosys | 00:08:54.906 |
| Floorplan | OpenROAD | 00:00:03.923 |
| Global Placement | OpenROAD (RePLace) | 00:01:37.042 |
| Clock Tree Synthesis | TritonCTS | 00:00:13.097 |
| Global Routing | OpenROAD (FastRoute) | 00:00:47.524 |
| Detailed Routing | TritonRoute | 00:01:49.532 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:01:18.012 |
| **Total (key steps)** | | **14 m 41 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

