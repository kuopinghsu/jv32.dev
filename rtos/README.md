# JV32 RTOS Support

JV32 supports four RTOS environments: **FreeRTOS**, **Eclipse ThreadX**, **RIOT OS**, and **Zephyr**. All can be built, run on the Verilator RTL simulator, and verified via RTL-vs-ISS trace comparison. All targets are included in `make all`.

---

## FreeRTOS

**Version:** FreeRTOS Kernel V11.2.0
**Port:** `rtos/freertos/portable/RISC-V/` (machine-mode, CLINT timer)

Sources live entirely inside the repository (`rtos/freertos/`). No external workspace is required.

### Samples

| Name | Description |
|---|---|
| `simple` | Two tasks at different priorities; demonstrates the preemptive scheduler |
| `perf` | Task-switch timing benchmark; prints cycles-per-context-switch for yield, semaphore, mutex, event, and queue operations |
| `stress` | Round-robin, preemption, mutex contention, queue prod/consumer, semaphore ping-pong, event-group fan-out, and timer tests |

### Running

```bash
# Run a single sample on the RTL simulator
make rtl-freertos-simple
make rtl-freertos-perf
make rtl-freertos-stress

# Run all samples
make rtl-freertos-all

# RTL-vs-ISS trace comparison (single / all)
make compare-freertos-simple
make compare-freertos-all
```

The software simulator (`jv32sim`) also supports FreeRTOS:

```bash
make sim-freertos-all
```

---

## Eclipse ThreadX

**Version:** Eclipse ThreadX 6.5.0 (build 202601)
**Port:** `rtos/threadx/ports/jv32/` (machine-mode, CLINT timer, CLIC interrupt controller)

Sources live entirely inside the repository (`rtos/threadx/`). No external workspace is required.

### Port details

| File | Purpose |
|---|---|
| `ports/jv32/tx_port.h` | Type definitions, timer configuration, stack-size defaults |
| `ports/jv32/tx_port.c` | CLINT timer ISR, CLIC interrupt dispatch, kernel entry |
| `ports/jv32/tx_port_asm.S` | Context-save/restore, `_tx_thread_system_return`, `_tx_thread_context_save/restore` |
| `ports/jv32/tx_user.h` | Build-time feature knobs (`TX_JV32_SGUARD`, timer tick rate) |
| `ports/jv32/threadx_link.ld` | Linker script for TCM layout |

Timer tick rate: 100 Hz (`TX_TIMER_TICKS_PER_SECOND = 100`, 10 ms per tick).

### Samples

| Name | Description |
|---|---|
| `simple` | Four threads exercising context switch, semaphore, mutex, and event-flag primitives |
| `perf` | Cycle-accurate timing benchmark for yield, context switch, semaphore, mutex, event, and queue operations |
| `stress` | Round-robin, preemption, mutex contention, queue prod/consumer, semaphore ping-pong, event-flag fan-out, and timer tests |
| `benchmark` | Thread-Metric-style preemption and synchronisation throughput benchmark |
| `tm_basic` | Thread-Metric basic processing throughput test |
| `tm_coop` | Thread-Metric cooperative scheduling throughput test |
| `tm_preempt` | Thread-Metric preemptive scheduling throughput test |

### Running

```bash
# Run a single sample on the RTL simulator
make rtl-threadx-simple
make rtl-threadx-perf
make rtl-threadx-stress

# Run all samples
make rtl-threadx-all

# RTL-vs-ISS trace comparison (single / all)
make compare-threadx-simple
make compare-threadx-all
```

The software simulator also supports ThreadX:

```bash
make sim-threadx-all
```

---

## RIOT OS

**Version:** RIOT OS (custom standalone port, LGPL-2.1)
**Port:** `rtos/riot/` (machine-mode, CLINT coretimer, `boards/jv32/`, `cpu/jv32/`)

Sources live entirely inside the repository (`rtos/riot/`). No external workspace or west/build-system is required.

### Port details

| Path | Purpose |
|---|---|
| `boards/jv32/` | Board init, linker script, startup assembly, syscall stubs |
| `cpu/jv32/` | `cpu_init()` — CLINT timer setup, `sched_arch_idle()` (WFI) |
| `cpu/riscv_common/` | Generic RISC-V context-switch, IRQ arch, trap vector |
| `core/` | RIOT kernel: scheduler, threads, mutex, message passing, thread flags |

The port uses the CLINT machine-timer for the tick source and routes all M-mode traps through the RIOT IRQ architecture layer.

### Samples

| Name | Description |
|---|---|
| `simple` | Thread creation, mutex-protected counter, IPC message passing, thread-flags signalling |
| `perf` | Cycle-accurate timing benchmark for yield, context switch, mutex, message, and thread-flag operations |
| `stress` | Round-robin, preemption, mutex contention, message-queue prod/consumer, semaphore ping-pong, and thread-flag fan-out tests |

### Running

```bash
# Run a single sample on the RTL simulator
make rtl-riot-simple
make rtl-riot-perf
make rtl-riot-stress

# Run all samples
make rtl-riot-all

# RTL-vs-ISS trace comparison (single / all)
make compare-riot-simple
make compare-riot-all
```

The software simulator also supports RIOT:

```bash
make sim-riot-all
```

---

## Zephyr

**Version:** Zephyr 4.4
**Port:** `rtos/zephyr/` (west module, `boards/riscv/jv32/`, `soc/jv32/`, CLIC driver)

Zephyr is an external west-managed workspace. Point `ZEPHYR_BASE` in `env.config` to your Zephyr installation:

```ini
ZEPHYR_BASE=$(HOME)/zephyrproject/zephyr
```

### One-time setup

```bash
# 1. Install Zephyr via west (if you haven't already)
pip install west
west init ~/zephyrproject
west update
# 2. Bootstrap the rtos/zephyr Python venv and export the board/soc module
make -C rtos/zephyr setup
```

### Samples

| Name | Description |
|---|---|
| `hello` | "Hello World" — printk over UART; minimal smoke test |
| `simple` | Single thread; basic kernel init and scheduling sanity |
| `perf` | Thread-switch and semaphore/mutex/event/message benchmark |
| `stress` | Many threads sharing queues; scheduler stress under load |
| `threads_sync` | Mutex and semaphore synchronisation between producer/consumer threads |
| `uart_echo` | UART RX→TX loopback; exercises the UART driver and ISR path |

### Running

```bash
# Run a single sample on the RTL simulator
make rtl-zephyr-hello
make rtl-zephyr-perf
make rtl-zephyr-uart_echo

# Run all samples
make rtl-zephyr-all

# RTL-vs-ISS trace comparison (single / all)
make compare-zephyr-uart_echo
make compare-zephyr-all
```

The software simulator also supports Zephyr:

```bash
make sim-zephyr-all
```

All targets for all four RTOS environments are included in `make all`.
