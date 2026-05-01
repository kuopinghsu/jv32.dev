/*
 * JV32 board initialization for RIOT OS
 * SPDX-License-Identifier: LGPL-2.1-only
 */

/**
 * @ingroup     boards_jv32
 * @{
 *
 * @file
 * @brief       board_init() — minimal board initialization for the JV32 SoC.
 *
 * The JV32 UART is memory-mapped with no special initialization required
 * beyond what the hardware resets to (8-N-1, baud derived from simulation
 * clock).  printf() routes through the syscall _write stub which directly
 * polls the TX register, so no interrupt-based UART init is needed here.
 */

#include "board.h"
#include "kernel_init.h"

void board_init(void)
{
    /* No board-level hardware initialization is required for JV32 RTL/sim.
     * UART, PLIC, and CLINT are initialized by cpu_init() (riscv_init)
     * and the standalone syscall layer (_write polls TX directly).       */
}

/** @} */
