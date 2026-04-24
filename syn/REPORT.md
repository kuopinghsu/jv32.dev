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
| Standard cell area | 64137 µm² |
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
| **jv32_soc** | **2,171** | **1,732.72** | **100.0%** |
| ↳ jv32_top | 4,124 | 3,291.22 | 190.0% |
| &nbsp;&nbsp;↳ jv32_core | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ **jv32_alu** | **16,002** | **12,769.33** | **737.1%** |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_regfile | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_csr | 5,505 | 4,392.72 | 253.6% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_rvc | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_decoder | 314 | 250.84 | 14.5% |
| &nbsp;&nbsp;↳ sram_1rw | 84 | 66.77 | 3.9% |
| ↳ jtag_top | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;↳ jtag_tap | 207 | 165.19 | 9.5% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_dtm | 17,072 | 13,623.19 | 786.4% |
| ↳ axi_clic | 5,699 | 4,547.80 | 262.5% |
| ↳ axi_uart | 4,840 | 3,862.32 | 222.9% |
| ↳ axi_xbar | 689 | 550.09 | 31.7% |
| ↳ axi_magic | 0 | 0.00 | 0.0% |

### ALU area breakdown by function

| Sub-block | Config | Key cell types | Est. NAND2-eq | % of ALU |
|---|---|---|---:|---:|
| Multiplier (MUL/MULH/MULHSU/MULHU) | `FAST_MUL=1, MUL_MC=1` (2-stage 4×16×16 pipeline) | XOR2/XNOR2, DFFR (193 FFs) | ~2,761 | ~17% |
| Divider (DIV/DIVU/REM/REMU) | `FAST_DIV=0` (serial restoring) | NAND2/NOR2, DFFR (210 FFs) | ~1,234 | ~8% |
| Barrel shifter (SLL/SRL/SRA) | `FAST_SHIFT=1` (SRL/SRA shared¹) | MUX2, INV | ~190 | ~1% |
| ADD/SUB/logic/compare | — | XOR2/XNOR2, AOI/OAI | ~11,817 | ~74% |

¹ SRL and SRA share a single right-shift barrel tree (see [rtl/jv32/core/jv32_alu.sv](../rtl/jv32/core/jv32_alu.sv)); the second independent barrel shifter was removed, saving ~100–180 NAND2-eq.

---

## 4. Cell Count & Mix

| Category | Count | % of std cells |
|---|---|---|
| Total instances | 44221 | — |
| Standard cells (excl. tap) | 44,217 | 100% |
| Sequential (flip-flops) | 5147 | 11.6% |
| Multi-input combinational | 26934 | 60.9% |
| Buffers | 96 | 0.2% |
| Inverters | 2136 | 4.8% |
| Macros | 4 | — |
| Tap cells | 9904 | — |
| I/O ports | 768 | — |
| **NAND2 equivalents (post-P&R)** | **80,372** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 2 |
| CTS buffers inserted | 265 |
| Clock subnets | 265 |
| Clock sinks | 5151 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.12855777917197123 ns ⚠️ |

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.643371 | -0.189628 |
| `jtag_tck` | 1.050919 | -0.158520 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.643371 |
| `jtag_tck` | 1.050919 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 61   | ⚠️ |
| Max cap violations    | 166    | ⚠️ |
| Max fanout violations | 0 | ✅ |
| Unconstrained endpoints | 51 | ℹ️ |

### Timing Convergence

| Stage | Setup WNS (ns) | |
|---|---|---|
| Pre-PnR (synthesis) | -9.556 | ❌ |
| Post-placement (mid-PnR) | -13.041 | ❌ |
| Post-CTS + resizer | 0.000 | ✅ |
| Post-GRT resizer | 0.000 | ✅ |
| **Post-route STA (sign-off)** | **0.000** | ✅ |

---

## 7. Design Rule Checks (Post-Route)

| Iteration | DRC Errors | Wirelength (µm) |
|---|---|---|
| 1 | 11,992 | 1,131,466 |
| 2 | 1,888 | 1,126,917 |
| 3 | 1,148 | 1,126,452 |
| 4 | 39 | 1,126,400 |
| 5 | 0 | 1,126,400 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 3.28 mW | 0.61 mW | 0.43 mW | 4.33 mW | 17.5% |
| Combinational | 3.48 mW | 5.29 mW | 1.26 mW | 10.03 mW | 40.5% |
| Clock | 0.29 mW | 0.89 mW | 0.02 mW | 1.19 mW | 4.8% |
| Macro | 8.63 mW | 0.00 mW | 0.59 mW | 9.22 mW | 37.2% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 15.68 mW | 6.79 mW | 2.30 mW | 24.78 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 41,942 |
| Constrained signal nets | 38,209 |
| Total wirelength | **1126.36 mm** |
| Total vias | 372,823 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `_06035_` | 1.798 mm |
| 2 | `net135` | 1.569 mm |
| 3 | `_06144_` | 1.559 mm |
| 4 | `net1139` | 1.541 mm |
| 5 | `net1138` | 1.517 mm |
| 6 | `net954` | 1.386 mm |
| 7 | `_06033_` | 1.303 mm |
| 8 | `_06143_` | 1.298 mm |
| 9 | `net1140` | 1.287 mm |
| 10 | `_07329_` | 1.258 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 3,619,416 | 200,985 | 5.55% ✅ | 0 /  0 /  0 |
| metal3 | 5,187,866 | 226,321 | 4.36% ✅ | 0 /  0 /  0 |
| metal4 | 2,077,934 | 44,214 | 2.13% ✅ | 0 /  0 /  0 |
| metal5 | 3,961,995 | 32,479 | 0.82% ✅ | 0 /  0 /  0 |
| metal6 | 3,956,418 | 2,473 | 0.06% ✅ | 0 /  0 /  0 |
| metal7 | 1,018,877 | 2,128 | 0.21% ✅ | 0 /  0 /  0 |
| metal8 | 1,020,305 | 12 | 0.00% ✅ | 0 /  0 /  0 |
| metal9 | 1,017,451 | 583 | 0.06% ✅ | 0 /  0 /  0 |
| **Total** | **21,860,262** | **509,195** | **2.33%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 1374758 µm

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
| Synthesis | Yosys | 00:05:00.002 |
| Floorplan | OpenROAD | 00:00:06.056 |
| Global Placement | OpenROAD (RePLace) | 00:01:27.998 |
| Clock Tree Synthesis | TritonCTS | 00:00:10.969 |
| Global Routing | OpenROAD (FastRoute) | 00:00:41.215 |
| Detailed Routing | TritonRoute | 00:01:28.743 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:00:51.272 |
| **Total (key steps)** | | **9 m 43 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

