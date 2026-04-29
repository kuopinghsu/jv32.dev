# JV32 Core Configuration Reference

All parameters are defined in `Makefile.cfg` and can be overridden on the `make` command line:

```bash
make FAST_MUL=1 MUL_MC=0 rtl-hello
make RV32EC=1 build-rtl
```

---

## ISA / Extensions

### RV32EC minimum-area preset

Setting `RV32EC=1` activates the minimum-area configuration. It overrides all individual extension
flags below with the following fixed values:

| Parameter | Value | Effect |
|---|:---:|---|
| `RV32E_EN` | `1` | 16 GPRs (E-class register file) instead of 32 |
| `RV32M_EN` | `0` | M-extension disabled; MUL/DIV trap as illegal instruction |
| `AMO_EN` | `0` | A-extension disabled; all AMO instructions trap as illegal |
| `JTAG_EN` | `0` | JTAG debug transport removed from synthesis |
| `TRACE_EN` | `0` | Trace output registers removed (outputs tied to 0) |
| `BP_EN` | `0` | Branch predictor disabled; always-not-taken prediction |
| `FAST_SHIFT` | `0` | 1-bit-per-cycle serial barrel shifter (area-minimal) |

```bash
make RV32EC=1 build-rtl
# or set RV32EC=1 in Makefile.cfg for a persistent change
```

### Individual extension flags

When `RV32EC=0` (the default), each flag can be set independently:

| Parameter | Default | Description |
|---|:---:|---|
| `RV32E_EN` | `0` | `1` = RV32E (16 GPRs); `0` = RV32I (32 GPRs) |
| `RV32M_EN` | `1` | `1` = include M-extension (MUL/DIV); `0` = illegal trap on MUL/DIV |
| `AMO_EN` | `1` | `1` = include A-extension (atomic ops); `0` = illegal trap on AMO |
| `RV32B_EN` | `1` | `1` = include B-extension (Zba/Zbb/Zbs); `0` = bit-manipulation instructions trap as illegal |
| `JTAG_EN` | `1` | `1` = include JTAG debug interface; `0` = remove from synthesis |
| `TRACE_EN` | `1` | `1` = trace output registers present; `0` = outputs tied to 0 |

---

## Pipeline

| Parameter | Default | Description |
|---|---|---|
| `FAST_MUL` | `1` | `1` = fast multiplier (see `MUL_MC`); `0` = serial shift-and-add (variable latency) |
| `MUL_MC` | `1` | `1` = 2-stage pipelined multiply (2 cycles, better timing); `0` = 1-cycle combinatorial (requires `FAST_MUL=1`) |
| `FAST_DIV` | `0` | `1` = combinatorial divider; `0` = serial restoring divider (variable latency) |
| `FAST_SHIFT` | `1` | `1` = barrel shifter (1 cycle); `0` = 1-bit-per-cycle serial shifter |
| `BP_EN` | `1` | `1` = enable branch predictor; `0` = always-not-taken |
| `RAS_EN` | `1` | `1` = enable return address stack; `0` = disable RAS |
| `IBUF_EN` | `1` | `1` = enable instruction buffer; `0` = disable |

### Multiplier configuration guide (Nangate 45 nm / FreePDK45)

The multiplier has three modes, selectable via `FAST_MUL` and `MUL_MC`:

| Mode | `FAST_MUL` | `MUL_MC` | Latency | Critical path | Recommendation |
|---|:---:|:---:|---|---|---|
| Serial shift-and-add | `0` | — | variable (up to 32 cycles) | minimal (FF-chain) | area-critical designs |
| 1-cycle combinatorial | `1` | `0` | 1 cycle | full 32×32 multiply tree | ≤ 75 MHz |
| 2-stage pipelined | `1` | `1` | 2 cycles | 16×16 partial-product stage | > 75 MHz |

**Selection advice:**

- **≤ 75 MHz target** — use `FAST_MUL=1 MUL_MC=0`. The single-cycle combinatorial 32×32 multiply
  fits comfortably within a ~13 ns period and requires no pipeline stall overhead for most MUL
  instructions.
- **> 75 MHz target** — use `FAST_MUL=1 MUL_MC=1` (default). Splitting the multiply into four
  16×16 partial products halves the combinatorial depth; the pipeline absorbs the extra cycle as a
  1-stall bubble. No `set_multicycle_path` SDC exception is needed because each pipeline stage
  closes timing independently.
- The exact crossover frequency depends on place-and-route results; always run `make -C syn synth`
  for both settings and compare the post-PnR WNS/TNS reports to determine the best choice for your
  target clock period.

---

## Memory Map

| Parameter | Default | Description |
|---|---|---|
| `IRAM_SIZE` | `131072` | Instruction SRAM size in bytes (power-of-2, max 512 KB) |
| `DRAM_SIZE` | `131072` | Data SRAM size in bytes (power-of-2, max 512 KB) |
| `BOOT_ADDR` | `0x80000000` | Reset vector address |
| `IRAM_BASE` | `0x80000000` | Instruction SRAM base address (normally == `BOOT_ADDR`) |
| `DRAM_BASE` | `0x90000000` | Data SRAM base address |

Fixed peripheral addresses (not configurable via `make`):

| Peripheral | Base address |
|---|---|
| CLIC / interrupt controller | `0x02000000` |
| UART | `0x20010000` |
| Simulation magic device | `0x10000000` |
| EXTRAM (simulation only) | `0xA0000000` (2 MB) |

---

## Simulation

| Parameter | Default | Description |
|---|---|---|
| `CLK_FREQ` | `80000000` | Simulation clock frequency in Hz |
| `TIMEOUT` | `120` | Wall-clock timeout in seconds (`0` = no limit); increase when using serial mul/div/shift |
| `MAX_CYCLES` | `0` | Stop RTL simulation after N cycles (`0` = unlimited) |
| `MAX_INSNS` | `0` | Stop software simulator after N instructions (`0` = unlimited) |
| `WAVE` | _(none)_ | Waveform format: `fst` or `vcd` |
| `TRACE` | _(none)_ | `1` = print RTL instruction trace to stdout |
| `DEBUG` | _(none)_ | `1` = level-1 messages; `2` = per-group messages |
| `DEBUG_GROUP` | _(none)_ | Bitmask of module groups to print (used with `DEBUG=2`) |
