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

## 3. Cell Count

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

## 4. Timing (Post-PnR STA)

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

## 5. Power

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

## 6. Routing & Wire Length

| Metric | Value |
|---|---|
| Total nets | 38,087 |
| Total wirelength | **1177.69 mm** |
| Longest net (`net135`) | 1.740 mm |

---

## 7. Manufacturability

| Check | Result |
|---|---|
| Antenna | Passed ✅ |
| LVS | N/A |
| DRC | N/A |

---

## 8. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

