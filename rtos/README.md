# JV32 RTOS Support

JV32 supports two RTOS environments: **FreeRTOS** (bare-metal port) and **Zephyr** (external workspace, west-managed). Both can be built, run on the Verilator RTL simulator, and verified via RTL-vs-ISS trace comparison.

---

## FreeRTOS

**Version:** FreeRTOS Kernel V11.2.0  
**Port:** `rtos/freertos/portable/RISC-V/` (machine-mode, CLINT timer)

Sources live entirely inside the repository (`rtos/freertos/`). No external workspace is required.

### Samples

| Name | Description |
|---|---|
| `simple` | Two tasks blinking at different priorities; demonstrates the preemptive scheduler |
| `perf` | Task-switch timing benchmark; prints cycles-per-context-switch |
| `stress` | Many tasks with queues and semaphores; exercises the scheduler under load |

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

All FreeRTOS and Zephyr targets are included in `make all`.
