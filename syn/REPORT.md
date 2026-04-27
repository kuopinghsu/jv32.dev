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
| Standard cell area | 65112 µm² |
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
| **jv32_soc** | **1,949** | **1,555.30** | **100.0%** |
| ↳ jv32_top | 3,523 | 2,811.35 | 180.8% |
| &nbsp;&nbsp;↳ jv32_core | 11,739 | 9,367.72 | 602.3% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ **jv32_alu** | **15,248** | **12,167.90** | **782.3%** |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_regfile | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_csr | 5,039 | 4,020.86 | 258.5% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_rvc | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_decoder | 312 | 248.71 | 16.0% |
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
| Multiplier (MUL/MULH/MULHSU/MULHU) | `FAST_MUL=1, MUL_MC=1` (2-stage 4×16×16 pipeline) | XOR2/XNOR2, DFFR (193 FFs) | ~2,699 | ~18% |
| Divider (DIV/DIVU/REM/REMU) | `FAST_DIV=0` (serial restoring) | NAND2/NOR2, DFFR (210 FFs) | ~1,216 | ~8% |
| Barrel shifter (SLL/SRL/SRA) | `FAST_SHIFT=1` (SRL/SRA shared¹) | MUX2, INV | ~117 | ~1% |
| ADD/SUB/logic/compare | — | XOR2/XNOR2, AOI/OAI | ~11,216 | ~74% |

¹ SRL and SRA share a single right-shift barrel tree (see [rtl/jv32/core/jv32_alu.sv](../rtl/jv32/core/jv32_alu.sv)); the second independent barrel shifter was removed, saving ~100–180 NAND2-eq.

---

## 4. Cell Count & Mix

| Category | Count | % of std cells |
|---|---|---|
| Total instances | 44648 | — |
| Standard cells (excl. tap) | 44,644 | 100% |
| Sequential (flip-flops) | 5276 | 11.8% |
| Multi-input combinational | 27135 | 60.8% |
| Buffers | 96 | 0.2% |
| Inverters | 2233 | 5.0% |
| Macros | 4 | — |
| Tap cells | 9904 | — |
| I/O ports | 768 | — |
| **NAND2 equivalents (post-P&R)** | **81,594** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 2 |
| CTS buffers inserted | 268 |
| Clock subnets | 268 |
| Clock sinks | 5280 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.12246837224313574 ns ⚠️ |

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.639697 | -0.173209 |
| `jtag_tck` | 1.019066 | -0.128091 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.639697 |
| `jtag_tck` | 1.019066 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 61   | ⚠️ |
| Max cap violations    | 198    | ⚠️ |
| Max fanout violations | 0 | ✅ |
| Unconstrained endpoints | 51 | ℹ️ |

### Timing Convergence

| Stage | Setup WNS (ns) | |
|---|---|---|
| Pre-PnR (synthesis) | -11.204 | ❌ |
| Post-placement (mid-PnR) | -15.134 | ❌ |
| Post-CTS + resizer | 0.000 | ✅ |
| Post-GRT resizer | 0.000 | ✅ |
| **Post-route STA (sign-off)** | **0.000** | ✅ |

---

## 7. Design Rule Checks (Post-Route)

| Iteration | DRC Errors | Wirelength (µm) |
|---|---|---|
| 1 | 12,509 | 1,193,870 |
| 2 | 1,750 | 1,189,144 |
| 3 | 1,119 | 1,188,358 |
| 4 | 45 | 1,188,285 |
| 5 | 0 | 1,188,280 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 2.63 mW | 0.09 mW | 0.44 mW | 3.16 mW | 19.8% |
| Combinational | 0.37 mW | 0.71 mW | 1.28 mW | 2.35 mW | 14.7% |
| Clock | 0.30 mW | 0.93 mW | 0.02 mW | 1.25 mW | 7.8% |
| Macro | 8.63 mW | 0.00 mW | 0.59 mW | 9.22 mW | 57.7% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 11.94 mW | 1.72 mW | 2.32 mW | 15.98 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 42,518 |
| Constrained signal nets | 38,653 |
| Total wirelength | **1188.24 mm** |
| Total vias | 380,254 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `net135` | 2.456 mm |
| 2 | `_06201_` | 2.075 mm |
| 3 | `net1171` | 1.634 mm |
| 4 | `_06158_` | 1.624 mm |
| 5 | `_06156_` | 1.600 mm |
| 6 | `_06202_` | 1.584 mm |
| 7 | `net1169` | 1.566 mm |
| 8 | `net1170` | 1.478 mm |
| 9 | `net1172` | 1.460 mm |
| 10 | `net1052` | 1.315 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 3,619,416 | 204,682 | 5.66% ✅ | 0 /  0 /  0 |
| metal3 | 5,187,866 | 260,839 | 5.03% ✅ | 0 /  0 /  0 |
| metal4 | 2,077,934 | 33,873 | 1.63% ✅ | 0 /  0 /  0 |
| metal5 | 3,961,995 | 35,185 | 0.89% ✅ | 0 /  0 /  0 |
| metal6 | 3,956,418 | 1,515 | 0.04% ✅ | 0 /  0 /  0 |
| metal7 | 1,018,877 | 2,368 | 0.23% ✅ | 0 /  0 /  0 |
| metal8 | 1,020,305 | 9 | 0.00% ✅ | 0 /  0 /  0 |
| metal9 | 1,017,451 | 51 | 0.01% ✅ | 0 /  0 /  0 |
| **Total** | **21,860,262** | **538,522** | **2.46%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 1440686 µm

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
| Synthesis | Yosys | 00:05:23.878 |
| Floorplan | OpenROAD | 00:00:05.423 |
| Global Placement | OpenROAD (RePLace) | 00:01:34.642 |
| Clock Tree Synthesis | TritonCTS | 00:00:11.249 |
| Global Routing | OpenROAD (FastRoute) | 00:00:44.509 |
| Detailed Routing | TritonRoute | 00:01:31.864 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:00:59.891 |
| **Total (key steps)** | | **10 m 27 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

