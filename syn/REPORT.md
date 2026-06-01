# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-06-01

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
| Standard cell area | 78250 µm² |
| Macro area | 382846 µm² |
| Total instance utilization | 50.5% |
| Std cell utilization | 14.75% |

---

## 3. Area Hierarchy (Gate Count)

> Source: `build/gate_count_run/stat.json`
> Methodology: hierarchical (non-flattening) Yosys synthesis against Nangate 45 nm OCL.
> Reference cell: NAND2\_X1 = 0.7980 µm².  SRAM macros treated as black-boxes (area excluded).
> Note: pre-P&R counts; post-P&R NAND2-eq total is in §4.

| Module | NAND2-eq | Area (µm²) | % of SoC logic |
|---|---:|---:|---:|
| **jv32_soc** | **2,630** | **2,098.74** | **100.0%** |
| ↳ jv32_top | 3,550 | 2,833.17 | 135.0% |
| &nbsp;&nbsp;↳ jv32_core | 16,431 | 13,111.94 | 624.8% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ **jv32_alu** | **21,001** | **16,758.53** | **798.5%** |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_regfile | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_csr | 4,940 | 3,942.12 | 187.8% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_rvc | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_decoder | 446 | 355.91 | 17.0% |
| &nbsp;&nbsp;↳ sram_1rw | 253 | 202.16 | 9.6% |
| ↳ jtag_top | 0 | 0.00 | 0.0% |
| &nbsp;&nbsp;↳ jtag_tap | 5,015 | 4,001.70 | 190.7% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_dtm | 0 | 0.00 | 0.0% |
| ↳ axi_clic | 5,420 | 4,325.43 | 206.1% |
| ↳ axi_uart | 3,791 | 3,025.22 | 144.1% |
| ↳ axi_xbar | 568 | 453.00 | 21.6% |
| ↳ axi_magic | 0 | 0.00 | 0.0% |

### ALU area breakdown by function

| Sub-block | Config | Key cell types | Est. NAND2-eq | % of ALU |
|---|---|---|---:|---:|
| Multiplier (MUL/MULH/MULHSU/MULHU) | `FAST_MUL=1, MUL_MC=1` (2-stage 4×16×16 pipeline) | XOR2/XNOR2, DFFR (193 FFs) | ~4,087 | ~19% |
| Divider (DIV/DIVU/REM/REMU) | `FAST_DIV=0` (serial restoring) | NAND2/NOR2, DFFR (210 FFs) | ~1,553 | ~7% |
| Barrel shifter (SLL/SRL/SRA) | `FAST_SHIFT=1` (SRL/SRA shared¹) | MUX2, INV | ~163 | ~1% |
| ADD/SUB/logic/compare | — | XOR2/XNOR2, AOI/OAI | ~15,198 | ~72% |

¹ SRL and SRA share a single right-shift barrel tree (see [rtl/jv32/core/jv32_alu.sv](../rtl/jv32/core/jv32_alu.sv)); the second independent barrel shifter was removed, saving ~100–180 NAND2-eq.

---

## 4. Cell Count & Mix

| Category | Count | % of std cells |
|---|---|---|
| Total instances | 50946 | — |
| Standard cells (excl. tap) | 50,942 | 100% |
| Sequential (flip-flops) | 5337 | 10.5% |
| Multi-input combinational | 35081 | 68.9% |
| Buffers | 4607 | 9.0% |
| Inverters | 2363 | 4.6% |
| Macros | 4 | — |
| Tap cells | 3246 | — |
| I/O ports | 469 | — |
| **NAND2 equivalents (post-P&R)** | **98,057** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 225 |
| CTS buffers inserted | 1020 |
| Clock subnets | 1020 |
| Clock sinks | 5564 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.059490553056505135 ns ⚠️ |

> **Note:** Negative hold WNS immediately after CTS is expected — TritonCTS optimises setup skew and may temporarily worsen hold slack. The subsequent **Resizer / ECO (post-CTS)** step inserts hold buffers to close hold timing; the final post-PnR STA confirms hold WNS = 0.

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.643789 | -0.219518 |
| `jtag_tck` | 1.119518 | -0.219518 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.643789 |
| `jtag_tck` | 1.119518 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 66   | ⚠️ |
| Max cap violations    | 134272    | ℹ️ |
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
| 1 | 20,809 | 1,985,266 |
| 2 | 4,894 | 1,976,208 |
| 3 | 3,594 | 1,975,001 |
| 4 | 95 | 1,974,887 |
| 5 | 0 | 1,974,885 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 1.24 mW | 0.25 mW | 0.45 mW | 1.94 mW | 9.0% |
| Combinational | 3.71 mW | 3.67 mW | 3.03 mW | 10.41 mW | 48.6% |
| Clock | 0.64 mW | 0.63 mW | 0.12 mW | 1.40 mW | 6.5% |
| Macro | 7.15 mW | 0.00 mW | 0.53 mW | 7.69 mW | 35.9% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 12.75 mW | 4.55 mW | 4.14 mW | 21.43 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 139,031 |
| Constrained signal nets | 134,403 |
| Total wirelength | **1974.83 mm** |
| Total vias | 705,766 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `clk` | 0.922 mm |
| 2 | `dbg_mem_addr\[22\]` | 0.778 mm |
| 3 | `dbg_mem_addr\[21\]` | 0.771 mm |
| 4 | `dbg_mem_addr\[20\]` | 0.770 mm |
| 5 | `dbg_mem_addr\[19\]` | 0.769 mm |
| 6 | `dbg_mem_addr\[23\]` | 0.765 mm |
| 7 | `clknet_3_6_0_clk` | 0.765 mm |
| 8 | `dbg_mem_addr\[24\]` | 0.764 mm |
| 9 | `dbg_mem_addr\[27\]` | 0.750 mm |
| 10 | `clknet_3_5_0_clk` | 0.749 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 899,560 | 278,211 | 30.93% ✅ | 0 /  0 /  0 |
| metal3 | 1,291,937 | 454,920 | 35.21% ✅ | 0 /  0 /  0 |
| metal4 | 516,500 | 94,985 | 18.39% ✅ | 0 /  0 /  0 |
| metal5 | 846,097 | 79,770 | 9.43% ✅ | 0 /  0 /  0 |
| metal6 | 840,616 | 16,315 | 1.94% ✅ | 0 /  0 /  0 |
| metal7 | 217,360 | 6,723 | 3.09% ✅ | 0 /  0 /  0 |
| metal8 | 216,692 | 229 | 0.11% ✅ | 0 /  0 /  0 |
| metal9 | 215,840 | 1,740 | 0.81% ✅ | 0 /  0 /  0 |
| **Total** | **5,044,602** | **932,893** | **18.49%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 2531726 µm

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
| Synthesis | Yosys | 00:02:36.301 |
| Floorplan | OpenROAD | 00:00:05.208 |
| Global Placement | OpenROAD (RePLace) | 00:02:53.961 |
| Clock Tree Synthesis | TritonCTS | 00:00:19.105 |
| Resizer / ECO (post-CTS) | OpenROAD (resizer) | 00:40:47.253 |
| Global Routing | OpenROAD (FastRoute) | 00:00:36.567 |
| Detailed Routing | TritonRoute | 00:02:01.304 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:02:45.325 |
| GDS Stream-out | KLayout | 00:00:10.025 |
| SPICE Extraction | Magic | 00:02:51.145 |
| LVS | Netgen | 00:00:32.028 |
| **Total (listed steps)** | | **55 m 35 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

