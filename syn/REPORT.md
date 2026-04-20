# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-04-20

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
| Standard cell area | 60044 µm² |
| Macro area | 2183510 µm² |
| Total instance utilization | 50.9% |
| Std cell utilization | 2.70% |

---

## 3. Cell Count

| Category | Count |
|---|---|
| Total instances | 40007 |
| Standard cells (excl. tap) | 40003 |
| Sequential (flip-flops) | 5358 |
| Multi-input combinational | 22611 |
| Buffers | 109 |
| Inverters | 2021 |
| Macros | 4 |
| Tap cells | 9904 |
| I/O ports | 637 |

---

## 4. Timing (Post-PnR STA)

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.603769 |
| `jtag_tck` | 1.012552 |

---

## 5. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 3.37 mW | 0.53 mW | 0.46 mW | 4.36 mW | 22.1% |
| Combinational | 1.68 mW | 2.25 mW | 1.04 mW | 4.97 mW | 25.1% |
| Clock | 0.29 mW | 0.90 mW | 0.01 mW | 1.20 mW | 6.1% |
| Macro | 8.63 mW | 0.00 mW | 0.59 mW | 9.22 mW | 46.7% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 13.96 mW | 3.68 mW | 2.11 mW | 19.75 mW | 100.0% |

---

## 6. Routing & Wire Length

| Metric | Value |
|---|---|
| Total nets | 33,603 |
| Total wirelength | **1063.62 mm** |
| Longest net (`_06448_`) | 1.749 mm |

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

