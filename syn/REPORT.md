# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-05-07

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
| Die area | 2802500 µm² = 2.802 mm² |
| Core area | 2723370 µm² = 2.723 mm² |
| Standard cell area | 70259 µm² |
| Macro area | 912770 µm² |
| Total instance utilization | 36.1% |
| Std cell utilization | 3.88% |

---

## 3. Area Hierarchy (Gate Count)

> Source: `build/gate_count_run/stat.json`
> Methodology: hierarchical (non-flattening) Yosys synthesis against Nangate 45 nm OCL.
> Reference cell: NAND2\_X1 = 0.7980 µm².  SRAM macros treated as black-boxes (area excluded).
> Note: pre-P&R counts; post-P&R NAND2-eq total is in §4.

| Module | NAND2-eq | Area (µm²) | % of SoC logic |
|---|---:|---:|---:|
| **jv32_soc** | **2,629** | **2,098.21** | **100.0%** |
| ↳ jv32_top | 3,559 | 2,840.08 | 135.4% |
| &nbsp;&nbsp;↳ jv32_core | 14,694 | 11,726.08 | 558.9% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ **jv32_alu** | **17,445** | **13,920.84** | **663.6%** |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_regfile | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_csr | 5,043 | 4,024.05 | 191.8% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_rvc | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_decoder | 448 | 357.77 | 17.0% |
| &nbsp;&nbsp;↳ sram_1rw | 84 | 66.77 | 3.2% |
| ↳ jtag_top | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;↳ jtag_tap | 212 | 169.44 | 8.1% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_dtm | 16,173 | 12,905.79 | 615.2% |
| ↳ axi_clic | 5,444 | 4,344.31 | 207.1% |
| ↳ axi_uart | 3,692 | 2,946.22 | 140.4% |
| ↳ axi_xbar | 568 | 453.00 | 21.6% |
| ↳ axi_magic | 0 | 0.00 | 0.0% |

### ALU area breakdown by function

| Sub-block | Config | Key cell types | Est. NAND2-eq | % of ALU |
|---|---|---|---:|---:|
| Multiplier (MUL/MULH/MULHSU/MULHU) | `FAST_MUL=1, MUL_MC=1` (2-stage 4×16×16 pipeline) | XOR2/XNOR2, DFFR (193 FFs) | ~3,020 | ~17% |
| Divider (DIV/DIVU/REM/REMU) | `FAST_DIV=0` (serial restoring) | NAND2/NOR2, DFFR (210 FFs) | ~1,357 | ~8% |
| Barrel shifter (SLL/SRL/SRA) | `FAST_SHIFT=1` (SRL/SRA shared¹) | MUX2, INV | ~150 | ~1% |
| ADD/SUB/logic/compare | — | XOR2/XNOR2, AOI/OAI | ~12,918 | ~74% |

¹ SRL and SRA share a single right-shift barrel tree (see [rtl/jv32/core/jv32_alu.sv](../rtl/jv32/core/jv32_alu.sv)); the second independent barrel shifter was removed, saving ~100–180 NAND2-eq.

---

## 4. Cell Count & Mix

| Category | Count | % of std cells |
|---|---|---|
| Total instances | 47442 | — |
| Standard cells (excl. tap) | 47,438 | 100% |
| Sequential (flip-flops) | 5444 | 11.5% |
| Multi-input combinational | 31284 | 65.9% |
| Buffers | N/A | N/A |
| Inverters | 2300 | 4.8% |
| Macros | 4 | — |
| Tap cells | 8410 | — |
| I/O ports | 775 | — |
| **NAND2 equivalents (post-P&R)** | **88,044** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 2 |
| CTS buffers inserted | 291 |
| Clock subnets | 291 |
| Clock sinks | 5448 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.12258705508782475 ns ⚠️ |

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.678378 | -0.233308 |
| `jtag_tck` | 1.096724 | -0.144858 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.678378 |
| `jtag_tck` | 1.096724 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 60   | ⚠️ |
| Max cap violations    | 219    | ⚠️ |
| Max fanout violations | 2 | ⚠️ |
| Unconstrained endpoints | 322 | ℹ️ |

### Timing Convergence

| Stage | Setup WNS (ns) | |
|---|---|---|
| Pre-PnR (synthesis) | -13.444 | ❌ |
| Post-placement (mid-PnR) | -18.432 | ❌ |
| Post-CTS + resizer | 0.000 | ✅ |
| Post-GRT resizer | 0.000 | ✅ |
| **Post-route STA (sign-off)** | **0.000** | ✅ |

---

## 7. Design Rule Checks (Post-Route)

| Iteration | DRC Errors | Wirelength (µm) |
|---|---|---|
| 1 | 16,389 | 1,769,105 |
| 2 | 3,318 | 1,763,900 |
| 3 | 2,244 | 1,762,890 |
| 4 | 60 | 1,762,720 |
| 5 | 0 | 1,762,713 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 3.00 mW | 0.28 mW | 0.46 mW | 3.74 mW | 20.7% |
| Combinational | 1.16 mW | 2.02 mW | 1.48 mW | 4.66 mW | 25.8% |
| Clock | 0.33 mW | 0.98 mW | 0.02 mW | 1.33 mW | 7.4% |
| Macro | 7.74 mW | 0.00 mW | 0.56 mW | 8.30 mW | 46.0% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 12.24 mW | 3.27 mW | 2.51 mW | 18.02 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 46,712 |
| Constrained signal nets | 42,819 |
| Total wirelength | **1762.67 mm** |
| Total vias | 432,920 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `_06515_` | 2.162 mm |
| 2 | `u_jv32.u_dram.g_tcm_4096_sram.dout\[0\]\[10\]` | 1.709 mm |
| 3 | `u_jv32.u_dram.g_tcm_4096_sram.dout\[0\]\[23\]` | 1.683 mm |
| 4 | `u_jv32.u_dram.g_tcm_4096_sram.dout\[0\]\[1\]` | 1.678 mm |
| 5 | `u_jv32.u_dram.g_tcm_4096_sram.dout\[0\]\[0\]` | 1.645 mm |
| 6 | `net371` | 1.636 mm |
| 7 | `clknet_4_0__leaf_clk` | 1.621 mm |
| 8 | `u_jv32.u_dram.g_tcm_4096_sram.dout\[0\]\[15\]` | 1.607 mm |
| 9 | `u_jv32.u_dram.g_tcm_4096_sram.dout\[0\]\[13\]` | 1.605 mm |
| 10 | `net366` | 1.604 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 2,968,021 | 278,317 | 9.38% ✅ | 0 /  0 /  0 |
| metal3 | 4,239,076 | 223,079 | 5.26% ✅ | 0 /  0 /  0 |
| metal4 | 1,703,475 | 130,121 | 7.64% ✅ | 0 /  0 /  0 |
| metal5 | 2,464,191 | 106,126 | 4.31% ✅ | 0 /  0 /  0 |
| metal6 | 2,468,293 | 65,810 | 2.67% ✅ | 0 /  0 /  0 |
| metal7 | 633,655 | 1,425 | 0.22% ✅ | 0 /  0 /  0 |
| metal8 | 635,559 | 1,145 | 0.18% ✅ | 0 /  0 /  0 |
| metal9 | 632,753 | 20 | 0.00% ✅ | 0 /  0 /  0 |
| **Total** | **15,745,023** | **806,043** | **5.12%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 2022478 µm

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
| Synthesis | Yosys | 00:09:06.330 |
| Floorplan | OpenROAD | 00:00:06.910 |
| Global Placement | OpenROAD (RePLace) | 00:01:22.436 |
| Clock Tree Synthesis | TritonCTS | 00:00:11.348 |
| Global Routing | OpenROAD (FastRoute) | 00:00:46.797 |
| Detailed Routing | TritonRoute | 00:01:53.756 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:01:13.567 |
| **Total (key steps)** | | **14 m 37 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

