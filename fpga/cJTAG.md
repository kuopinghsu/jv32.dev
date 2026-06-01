# FT2232H cJTAG (Compact JTAG) Hardware Modification Guide

This repository/guide explains how to modify a standard, generic FT2232H MPSSE breakout board (e.g., CJMCU-2232, FT2232H Mini-Module) to support **cJTAG (IEEE 1149.7)** 2-wire debugging for Texas Instruments CC26xx/CC13xx, ESP32-H2, RISC-V, and other compatible target MCUs.

## Overview

Standard JTAG requires 4 to 5 wires (TCK, TMS, TDI, TDO, RESET). cJTAG reduces this requirement to just **2 wires**:
* **TCKC** (Compact Clock)
* **TMSC** (Compact Data, Half-Duplex Bi-directional)

Since the FT2232H MPSSE engine is natively designed for full-duplex Full JTAG (where `TMS` is output-only and `TDO` is input-only), a hardware workaround using an isolation resistor is required to tie `TMS` and `TDO` together safely without causing bus contention or hardware damage.

---

## Hardware Wiring Diagram

To implement half-duplex communication and protect both the FT2232H and the target MCU from short circuits during I/O direction switches, wire them as follows:

```text
  FT2232H Breakout Board                             FPGA (cJTAG)
+------------------------+                          +-----------------------+
|  ADBUS0 (TCK)          |------------------------->| TCKC (Clock)          |
|                        |                          |                       |
|  ADBUS2 (TMS)          |---[ 470Ω Resistor ]--+   |                       |
|                        |                      |   |                       |
|  ADBUS3 (TDO)          |<---------------------+-->| TMSC (Data)           |
|                        |                          |                       |
|  GND                   |--------------------------| GND                   |
|                        |                          |                       |
|  VCC / VIO             |--------------------------| VCC (Target Voltage)  |
+------------------------+                          +-----------------------+
```

### Pin Description & Purpose:
1. **ADBUS0 to TCKC**: Direct clock output line.
2. **ADBUS3 to TMSC**: Direct line from target data to FT2232H Input. This ensures clean, unattenuated signal reception.
3. **ADBUS2 via Resistor**: The FT2232H output line connects to the data bus through a **470 Ω to 1 kΩ resistor**.
   * **Why the resistor?** During turnaround phases (when the bus changes from write to read), both the FT2232H and the target MCU might drive the line simultaneously with opposite polarities (e.g., 3.3V vs 0V). The resistor limits the current to a safe level (~7mA), protecting the IO pins from burning out.

---

## Software Configuration (OpenOCD)

To drive this modified hardware, you must configure OpenOCD to handle the custom FTDI layout and select the `cjtag` transport protocol.

Create a custom OpenOCD configuration file, e.g., `ft2232h_cjtag.cfg`:

```tcl
# =====================================================================
# OpenOCD Configuration for Modified FT2232H cJTAG Adapter
# =====================================================================

adapter driver ftdi

# Specify your FT2232H VID/PID (Default is usually 0x0403 and 0x6010)
ftdi vid_pid 0x0403 0x6010

# Channel 0 corresponds to Interface A of the FT2232H
ftdi channel 0

# Initialize FTDI GPIO direction and states (1 = Output, 0 = Input)
# ADBUS0(TCK)=Out(1), ADBUS1(TDI)=Out(1), ADBUS2(TMS)=Out(1), ADBUS3(TDO)=In(0)
# Binary: 0000 1011 -> Hex: 0x000b for direction
ftdi layout_init 0x0005 0x000b

# Force OpenOCD to use 2-wire cJTAG protocol
transport select cjtag

# Set adapter speed (Start low at 1MHz for stability over generic wires)
adapter speed 1000

# Include your specific target configuration file below
# Example for TI CC26x2:
# source [find target/ti_cc26x2.cfg]
```

---

## Setup & Troubleshooting

### 1. Driver Installation (Windows Only)
Windows default FTDI virtual COM port drivers will not work with OpenOCD.
* Download and run **Zadig** (https://akeo.ie).
* Select your FT2232H (Interface 0).
* Replace the driver with **WinUSB** or **libusb-win32**.

### 2. Signal Integrity and Wire Length
* Keep jumper wires **under 15 cm (6 inches)**.
* Wrap a ground (`GND`) wire tightly around the `TCKC` and `TMSC` lines to reduce cross-talk and signal noise caused by the high-speed bi-directional switching.

### 3. Connection Errors
If OpenOCD throws a `Switch to cJTAG failed` or `JTAG scan chain interrogation failed` error:
* Double-check that your resistor is soldered securely on the `ADBUS2` line.
* Lower the adapter speed using `adapter speed 500` or `100` in the configuration file to debug timing issues.
