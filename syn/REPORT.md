# jv32_soc — P&R Results Report

**Design:** `jv32_soc`
**PDK:** FreePDK45 / Nangate 45nm Open Cell Library
**Flow:** OpenLane2 (Classic)
**Date:** 2026-04-23

---

## 1. Configuration

| Parameter | Value |
|---|---|
| Clock | 80 MHz (`core_clk`, period = 12.5 ns) |
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
| Standard cell area | 63444 µm² |
| Macro area | 2183510 µm² |
| Total instance utilization | 51.0% |
| Std cell utilization | 2.85% |

---

## 3. Area Hierarchy (Gate Count)

_Gate-count JSON not found. Re-run with --gate-count-json._

---

## 4. Cell Count & Mix

| Category | Count | % of std cells |
|---|---|---|
| Total instances | 43576 | — |
| Standard cells (excl. tap) | 43,572 | 100% |
| Sequential (flip-flops) | 5148 | 11.8% |
| Multi-input combinational | 26334 | 60.4% |
| Buffers | 96 | 0.2% |
| Inverters | 2090 | 4.8% |
| Macros | 4 | — |
| Tap cells | 9904 | — |
| I/O ports | 768 | — |
| **NAND2 equivalents (post-P&R)** | **79,503** | — |

---

## 5. Clock Tree Synthesis

| Metric | Value |
|---|---|
| Clock roots | 2 |
| CTS buffers inserted | 263 |
| Clock subnets | 263 |
| Clock sinks | 5152 |
| Post-CTS setup WNS | 0.0 ns ✅ |
| Post-CTS hold WNS  | -0.1314081103348555 ns ⚠️ |

### Clock Skew (post-PnR, tt_025C_1v10)

| Clock | Setup skew (ns) | Hold skew (ns) |
|---|---|---|
| `core_clk` | 0.613638 | -0.145101 |
| `jtag_tck` | 1.029891 | -0.171246 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | 0  | 0.0  | ✅ MET  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.613638 |
| `jtag_tck` | 1.029891 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 61   | ⚠️ |
| Max cap violations    | 183    | ⚠️ |
| Max fanout violations | 0 | ✅ |
| Unconstrained endpoints | 51 | ℹ️ |

### Timing Convergence

| Stage | Setup WNS (ns) | |
|---|---|---|
| Pre-PnR (synthesis) | -9.570 | ❌ |
| Post-placement (mid-PnR) | -12.923 | ❌ |
| Post-CTS + resizer | 0.000 | ✅ |
| Post-GRT resizer | 0.000 | ✅ |
| **Post-route STA (sign-off)** | **0.000** | ✅ |

---

## 7. Design Rule Checks (Post-Route)

| Iteration | DRC Errors | Wirelength (µm) |
|---|---|---|
| 1 | 11,699 | 1,139,207 |
| 2 | 1,902 | 1,134,842 |
| 3 | 1,133 | 1,134,223 |
| 4 | 44 | 1,134,216 |
| 5 | 0 | 1,134,220 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 3.28 mW | 0.58 mW | 0.43 mW | 4.30 mW | 21.2% |
| Combinational | 1.78 mW | 2.56 mW | 1.26 mW | 5.59 mW | 27.6% |
| Clock | 0.28 mW | 0.87 mW | 0.02 mW | 1.17 mW | 5.8% |
| Macro | 8.63 mW | 0.00 mW | 0.59 mW | 9.22 mW | 45.5% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 13.98 mW | 4.01 mW | 2.29 mW | 20.28 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 41,411 |
| Constrained signal nets | 37,673 |
| Total wirelength | **1134.18 mm** |
| Total vias | 368,363 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `net135` | 1.941 mm |
| 2 | `_06028_` | 1.848 mm |
| 3 | `_06070_` | 1.680 mm |
| 4 | `net1242` | 1.542 mm |
| 5 | `net1246` | 1.522 mm |
| 6 | `net1244` | 1.429 mm |
| 7 | `net1241` | 1.381 mm |
| 8 | `_06026_` | 1.366 mm |
| 9 | `net1243` | 1.363 mm |
| 10 | `_06069_` | 1.335 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 3,619,416 | 200,401 | 5.54% ✅ | 0 /  0 /  0 |
| metal3 | 5,187,866 | 229,015 | 4.41% ✅ | 0 /  0 /  0 |
| metal4 | 2,077,934 | 47,496 | 2.29% ✅ | 0 /  0 /  0 |
| metal5 | 3,961,995 | 27,089 | 0.68% ✅ | 0 /  0 /  0 |
| metal6 | 3,956,418 | 1,261 | 0.03% ✅ | 0 /  0 /  0 |
| metal7 | 1,018,877 | 5,018 | 0.49% ✅ | 0 /  0 /  0 |
| metal8 | 1,020,305 | 52 | 0.01% ✅ | 0 /  0 /  0 |
| metal9 | 1,017,451 | 2,836 | 0.28% ✅ | 0 /  0 /  0 |
| **Total** | **21,860,262** | **513,168** | **2.35%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 1381279 µm

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
| Synthesis | Yosys | 00:04:50.884 |
| Floorplan | OpenROAD | 00:00:04.765 |
| Global Placement | OpenROAD (RePLace) | 00:01:51.207 |
| Clock Tree Synthesis | TritonCTS | 00:00:12.005 |
| Global Routing | OpenROAD (FastRoute) | 00:00:41.814 |
| Detailed Routing | TritonRoute | 00:01:31.445 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:00:51.231 |
| **Total (key steps)** | | **10 m 0 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

