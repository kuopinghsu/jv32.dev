# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-04-22

---

## 1. Configuration

| Parameter | Value |
|---|---|
| Clock | 80 MHz |
| IRAM | 16 KB |
| DRAM | 16 KB |
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
| Standard cell area | 65856 µm² |
| Macro area | 2183510 µm² |
| Total instance utilization | 51.0% |
| Std cell utilization | 2.96% |

---

## 3. Area Hierarchy (Gate Count)

> Source: `syn/build/gate_count.rpt`
> Methodology: hierarchical (non-flattening) Yosys synthesis against Nangate 45 nm OCL.
> Reference cell: NAND2_X1 = 0.7980 µm².  SRAM macros treated as black-boxes (area excluded).
> Note: pre-P&R counts; post-P&R NAND2-eq total is 82,526 (see §4).

| Module | NAND2-eq | Area (µm²) | % of SoC logic |
|---|---:|---:|---:|
| **jv32_soc** | **84,750** | **67,630.77** | 100.0% |
| ↳ jv32_top | 54,389 | 43,402.42 | 64.2% |
| &nbsp;&nbsp;↳ jv32_core | 50,097 | 39,977.67 | 59.1% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ **jv32_alu** | **16,046** | **12,804.44** | **18.9%** |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_regfile | 14,295 | 11,407.14 | 16.9% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_csr | 5,506 | 4,393.52 | 6.5% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_rvc | 2,410 | 1,922.91 | 2.8% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_decoder | 311 | 248.44 | 0.4% |
| &nbsp;&nbsp;↳ sram_1rw (glue) | 84 | 66.77 | 0.1% |
| ↳ jtag_top | 17,254 | 13,768.96 | 20.4% |
| &nbsp;&nbsp;↳ jtag_tap | 17,254 | 13,768.96 | 20.4% |
| &nbsp;&nbsp;&nbsp;&nbsp;↳ jv32_dtm | 17,047 | 13,603.77 | 20.1% |
| ↳ axi_clic | 5,863 | 4,678.94 | 6.9% |
| ↳ axi_uart | 4,382 | 3,497.10 | 5.2% |
| ↳ axi_xbar | 689 | 550.09 | 0.8% |
| ↳ axi_magic | 0 | 0.00 | 0.0% |

### ALU area breakdown by function

| Sub-block | Config | Key cell types | Est. NAND2-eq | % of ALU |
|---|---|---|---:|---:|
| Multiplier (MUL/MULH/MULHSU/MULHU) | `FAST_MUL=1, MUL_MC=1` (2-stage 4×16×16 pipeline) | XOR2/XNOR2, DFFR (193 FFs) | ~7,200 | ~45% |
| Divider (DIV/DIVU/REM/REMU) | `FAST_DIV=0` (serial restoring) | NAND2/NOR2, DFFR (210 FFs) | ~4,500 | ~28% |
| Barrel shifter (SLL/SRL/SRA) | `FAST_SHIFT=1` (SRL/SRA shared¹) | MUX2, INV | ~2,800 | ~17% |
| ADD/SUB/logic/compare | — | XOR2/XNOR2, AOI/OAI | ~1,546 | ~10% |

¹ SRL and SRA now share a single right-shift barrel tree (see [rtl/jv32/core/jv32_alu.sv](../rtl/jv32/core/jv32_alu.sv)); the second independent barrel shifter was removed, saving ~100–180 NAND2-eq.

---

## 4. Cell Count

| Category | Count |
|---|---|
| Total instances | 44313 |
| Standard cells (excl. tap) | 44309 |
| Sequential (flip-flops) | 5438 |
| Multi-input combinational | 26625 |
| Buffers | 96 |
| Inverters | 2246 |
| Macros | 4 |
| Tap cells | 9904 |
| I/O ports | 768 |
| **NAND2 equivalents (post-P&R)** | **82,526** |

---

## 5. Timing (Post-PnR STA)

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.613819 |
| `jtag_tck` | 1.013976 |

---

## 6. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 3.37 mW | 0.59 mW | 0.45 mW | 4.42 mW | 22.2% |
| Combinational | 1.54 mW | 2.21 mW | 1.28 mW | 5.02 mW | 25.2% |
| Clock | 0.30 mW | 0.93 mW | 0.02 mW | 1.25 mW | 6.3% |
| Macro | 8.63 mW | 0.00 mW | 0.59 mW | 9.22 mW | 46.3% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 13.85 mW | 3.73 mW | 2.34 mW | 19.91 mW | 100.0% |

---

## 7. Routing & Wire Length

| Metric | Value |
|---|---|
| Total nets | 38,087 |
| Total wirelength | **1177.69 mm** |
| Longest net (`net135`) | 1.740 mm |

---

## 8. Manufacturability

| Check | Result |
|---|---|
| Antenna | Passed ✅ |
| LVS | N/A |
| DRC | N/A |

---

## 9. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

