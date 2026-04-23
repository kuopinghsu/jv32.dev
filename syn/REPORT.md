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
| `core_clk` | 0.611417 | -0.141214 |
| `jtag_tck` | 1.032037 | -0.171396 |

---

## 6. Timing — Post-PnR STA

**Corner: tt_025C_1v10**

| Check | WNS (ns) | TNS (ns) | Result |
|---|---|---|---|
| Setup (max) | 0.0 | 0.0 | ✅ MET |
| Hold (min)  | -0.007234935078041464  | -0.023856639561310903  | ❌ VIOLATED  |

| Clock | Setup skew (ns) |
|---|---|
| `core_clk` | 0.611417 |
| `jtag_tck` | 1.032037 |

### Design Checks

| Check | Count | |
|---|---|---|
| Max slew violations   | 62   | ⚠️ |
| Max cap violations    | 181    | ⚠️ |
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
| 1 | 11,413 | 1,138,566 |
| 2 | 1,989 | 1,134,086 |
| 3 | 1,227 | 1,133,651 |
| 4 | 68 | 1,133,608 |
| 5 | 0 | 1,133,608 |
| **Final** | **0** ✅ | — |

---

## 8. Power

**Corner: tt_025C_1v10**

| Group | Internal (W) | Switching (W) | Leakage (W) | Total (W) | % |
|---|---|---|---|---|---|
| Sequential | 3.28 mW | 0.58 mW | 0.43 mW | 4.30 mW | 21.2% |
| Combinational | 1.77 mW | 2.56 mW | 1.25 mW | 5.58 mW | 27.5% |
| Clock | 0.28 mW | 0.87 mW | 0.02 mW | 1.17 mW | 5.8% |
| Macro | 8.63 mW | 0.00 mW | 0.59 mW | 9.22 mW | 45.5% |
| Pad | 0.00 mW | 0.00 mW | 0.00 mW | 0.00 mW | 0.0% |
| Total | 13.97 mW | 4.01 mW | 2.29 mW | 20.28 mW | 100.0% |

---

## 9. Routing & Wire Length

| Metric | Value |
|---|---|
| Total routed nets | 41,128 |
| Constrained signal nets | 37,390 |
| Total wirelength | **1133.57 mm** |
| Total vias | 367,492 |

### Longest Nets (Top 10)

| Rank | Net | Length |
|---|---|---|
| 1 | `net135` | 1.943 mm |
| 2 | `_06028_` | 1.845 mm |
| 3 | `_06070_` | 1.679 mm |
| 4 | `net1242` | 1.550 mm |
| 5 | `net1246` | 1.512 mm |
| 6 | `net1244` | 1.446 mm |
| 7 | `net1243` | 1.384 mm |
| 8 | `net1241` | 1.382 mm |
| 9 | `_06026_` | 1.370 mm |
| 10 | `_06069_` | 1.331 mm |

---

## 10. Routing Congestion (GRT)

| Layer | Resource | Demand | Usage | Overflow (H/V/Total) |
|---|---|---|---|---|
| metal1 | 0 | 0 | 0.00% ✅ | 0 /  0 /  0 |
| metal2 | 3,619,416 | 200,748 | 5.55% ✅ | 0 /  0 /  0 |
| metal3 | 5,187,866 | 228,750 | 4.41% ✅ | 0 /  0 /  0 |
| metal4 | 2,077,934 | 47,075 | 2.27% ✅ | 0 /  0 /  0 |
| metal5 | 3,961,995 | 26,830 | 0.68% ✅ | 0 /  0 /  0 |
| metal6 | 3,956,418 | 1,213 | 0.03% ✅ | 0 /  0 /  0 |
| metal7 | 1,018,877 | 5,014 | 0.49% ✅ | 0 /  0 /  0 |
| metal8 | 1,020,305 | 68 | 0.01% ✅ | 0 /  0 /  0 |
| metal9 | 1,017,451 | 3,151 | 0.31% ✅ | 0 /  0 /  0 |
| **Total** | **21,860,262** | **512,849** | **2.35%** | **0 /  0 /  0** ✅ |

> GRT total wirelength: 1380172 µm

---

## 11. Manufacturability

| Check | Result |
|---|---|
| Antenna | Passed ✅ |
| LVS     | N/A |
| DRC     | N/A |

---

## 12. Flow Runtime

| Step | Tool | Runtime |
|---|---|---|
| Synthesis | Yosys | 00:04:45.300 |
| Floorplan | OpenROAD | 00:00:04.838 |
| Global Placement | OpenROAD (RePLace) | 00:01:50.937 |
| Clock Tree Synthesis | TritonCTS | 00:00:10.874 |
| Global Routing | OpenROAD (FastRoute) | 00:00:40.577 |
| Detailed Routing | TritonRoute | 00:01:34.301 |
| Post-PnR STA | OpenROAD (OpenSTA) | 00:00:49.477 |
| **Total (key steps)** | | **9 m 52 s** |

---

## 13. Output Files

| Format | Path |
|---|---|
| DEF | `build/openlane_run/final/def/jv32_soc.def` |
| ODB | `build/openlane_run/final/odb/jv32_soc.odb` |
| GDS (KLayout) | `build/openlane_run/final/klayout_gds/jv32_soc.klayout.gds` |
| Netlist | `build/openlane_run/final/nl/jv32_soc.nl.v` |
| SDC | `build/openlane_run/final/sdc/jv32_soc.sdc` |

