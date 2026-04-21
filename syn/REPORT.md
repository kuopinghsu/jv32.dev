# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-04-21

---

## 1. Configuration

| Parameter | Value |
|---|---|
| Clock | 80 MHz |
| IRAM | 16 KB |
| DRAM | 16 KB |
| `FAST_MUL` | 1 |
| `FAST_DIV` | 1 |
| `FAST_SHIFT` | 1 |
| `BP_EN` | 0 |

---

## 2. Floorplan & Area

| Metric | Value |
|---|---|
| Die area | 4500000 µm² = 4.500 mm² |
| Core area | 4406880 µm² = 4.407 mm² |
| Standard cell area | 65994 µm² |
| Macro area | 2183510 µm² |
| Total instance utilization | 51.0% |
| Std cell utilization | 2.97% |

---

## 3. Cell Count

| Category | Count |
|---|---|
| Total instances | 45188 |
| Standard cells (excl. tap) | 45184 |
| Sequential (flip-flops) | 5372 |
| Multi-input combinational | 27800 |
| Buffers | N/A |
| Inverters | 2108 |
| Macros | 4 |
| Tap cells | 9904 |
| I/O ports | 638 |

---

## 4. Timing (Post-PnR STA)

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.636869 |
| `jtag_tck` | 1.014340 |

---

## 5. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 3.24 mW | 0.52 mW | 0.45 mW | 4.21 mW | 21.3% |
| Combinational | 1.52 mW | 2.26 mW | 1.27 mW | 5.04 mW | 25.6% |
| Clock | 0.31 mW | 0.92 mW | 0.02 mW | 1.25 mW | 6.3% |
| Macro | 8.63 mW | 0.00 mW | 0.59 mW | 9.22 mW | 46.8% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 13.69 mW | 3.70 mW | 2.32 mW | 19.72 mW | 100.0% |

---

## 6. Routing & Wire Length

| Metric | Value |
|---|---|
| Total nets | 38,714 |
| Total wirelength | **1151.71 mm** |
| Longest net (`net135`) | 2.127 mm |

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

