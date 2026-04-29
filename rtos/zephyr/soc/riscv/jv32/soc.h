/*
 * Copyright (c) 2026 jv32 Project
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef _SOC_RISCV_JV32_SOC_H_
#define _SOC_RISCV_JV32_SOC_H_

#include <zephyr/sys/util.h>

/* CPU core definitions */
#define RISCV_MTVEC_MODE_DIRECT    0
#define RISCV_MTVEC_MODE_VECTORED  1

/* Memory map — matches jv_platform.h */
#define IRAM_BASE_ADDR     0x80000000  /* 128KB instruction TCM (RX) */
#define IRAM_SIZE          0x00020000
#define DRAM_BASE_ADDR     0x90000000  /* 128KB data TCM (RW) */
#define DRAM_SIZE          0x00020000

#define UART_BASE_ADDR     0x20010000  /* matches JV_UART_BASE */
#define CLIC_BASE_ADDR     0x02000000  /* matches JV_CLIC_BASE */

/* UART registers (offsets match JV_UART_*_OFF in jv_platform.h) */
#define UART_DATA_OFF      0x00  /* TX write / RX read */
#define UART_STATUS_OFF    0x04
#define UART_BAUD_DIV_OFF  0x10  /* write: CLKS_PER_BIT - 1 */

/* CLIC/CLINT registers — offsets match JV_CLIC_*_OFF in jv_platform.h */
#define CLIC_MSIP          (CLIC_BASE_ADDR + 0x0000)
#define CLIC_MTIME_LO      (CLIC_BASE_ADDR + 0x4000)
#define CLIC_MTIME_HI      (CLIC_BASE_ADDR + 0x4004)
#define CLIC_MTIMECMP_LO   (CLIC_BASE_ADDR + 0x4008)
#define CLIC_MTIMECMP_HI   (CLIC_BASE_ADDR + 0x400C)

/* System clock */
#define CPU_CLOCK_HZ       50000000  /* 50 MHz */

/* Interrupt numbers */
#define RISCV_IRQ_MSOFT    3   /* Machine software interrupt */
#define RISCV_IRQ_MTIMER   7   /* Machine timer interrupt */
#define RISCV_IRQ_MEXT     11  /* Machine external interrupt */

#ifndef _ASMLANGUAGE

/* Include generic RISC-V SoC definitions */
#include <zephyr/arch/riscv/arch.h>

/* JV32 SoC SDK API (register accessors, magic device helpers) */
#include "jv_platform.h"

/* SoC initialization */
static inline void soc_early_init_hook(void)
{
    /* Machine trap vector setup is handled by Zephyr RISC-V common code */
}

#endif /* !_ASMLANGUAGE */

#endif /* _SOC_RISCV_JV32_SOC_H_ */
