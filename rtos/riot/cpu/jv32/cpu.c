/*
 * JV32 RISC-V SoC CPU initialization for RIOT OS
 * SPDX-License-Identifier: LGPL-2.1-only
 */

/**
 * @ingroup     cpu_jv32
 * @{
 *
 * @file
 * @brief       JV32 cpu_init() — initializes PLIC and core-timer IRQ,
 *              then delegates to the generic RISC-V init (FPU + IRQ).
 */

#include "cpu.h"
#include "cpu_conf.h"
#include "vendor/riscv_csr.h"

/* Disable the CLINT timer by setting mtimecmp to its maximum value.
 * We inline this instead of including jv_clic.h to avoid pulling in
 * sw/include/csr.h, which redefines macros already defined by
 * vendor/riscv_csr.h (MSTATUS_MIE, MIP_MTIP, MIP_MSIP, MIP_MEIP). */
static inline void _clint_timer_disable(void)
{
    volatile uint32_t *mtimecmp =
        (volatile uint32_t *)(CLINT_BASE_ADDR + CLINT_MTIMECMP);
    mtimecmp[1] = 0xFFFFFFFFu;  /* set hi first to prevent spurious IRQ */
    mtimecmp[0] = 0xFFFFFFFFu;
}

/* Ensure timer interrupt (MTIE) is enabled in mie before the scheduler
 * starts.  The coretimer peripheral driver arms the first compare value;
 * we just make sure the global enable bit is set. */
static void jv32_timer_init(void)
{
    /* Disable timer interrupt while we initialise the compare value */
    clear_csr(mie, MIP_MTIP);

    /* Set mtimecmp to max so no spurious timer IRQ fires at startup */
    _clint_timer_disable();

    /* Enable the machine-timer interrupt source */
    set_csr(mie, MIP_MTIP);
}

void cpu_init(void)
{
    /* Call common RISC-V init: enables FPU (if present) and sets up
     * the trap vector / PLIC / global interrupt enable.             */
    riscv_init();

    /* Arm the CLINT timer (needed by RIOT's coretimer scheduler) */
    jv32_timer_init();
}

void sched_arch_idle(void)
{
    /* Execute WFI to suspend until the next interrupt wakes the CPU. */
    __asm__ volatile ("wfi");
    /* Re-enable interrupts briefly so pending IRQs run and update runqueue */
    set_csr(mstatus, MSTATUS_MIE);
}

/** @} */
