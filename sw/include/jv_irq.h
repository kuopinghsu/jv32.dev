/**
 * @file jv_irq.h
 * @brief JV32 machine-mode interrupt and exception management API.
 *
 * Provides:
 *  - mie bit-field constants (JV_IRQ_MSIE / MTIE / MEIE)
 *  - mcause interrupt and exception code constants
 *  - Global interrupt enable/disable helpers
 *  - Per-source mie bit control helpers
 *  - Handler typedefs for the dispatch table (jv_irq.c)
 *  - Handler registration: jv_irq_register() / jv_exc_register()
 *  - Dispatcher: jv_irq_dispatch()
 *
 * The dispatch table is fed by the default weak handle_trap() in jv_irq.c.
 * Tests that override handle_trap() entirely bypass the table.
 *
 * Startup integration
 * ───────────────────
 * startup.S calls:
 *   uint32_t handle_trap(uint32_t mcause, uint32_t mepc, uint32_t mtval);
 *   // returns 0 → keep original mepc; non-zero → write new mepc before mret
 *
 * jv_irq.c provides a weak handle_trap() that calls jv_irq_dispatch().
 * Override handle_trap() in your test to bypass the table entirely.
 */

#ifndef JV_IRQ_H
#define JV_IRQ_H

#include <stdint.h>
#include "csr.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * mie / mip bit positions
 * ============================================================================ */

#define JV_IRQ_MSIE  (1u <<  3)  /**< Machine Software Interrupt Enable  */
#define JV_IRQ_MTIE  (1u <<  7)  /**< Machine Timer    Interrupt Enable  */
#define JV_IRQ_MEIE  (1u << 11)  /**< Machine External Interrupt Enable  */

/* ============================================================================
 * mcause interrupt codes  (MSB = 1, code = mcause & 0x7FFFFFFF)
 * ============================================================================ */

#define JV_CAUSE_MSI   3u   /**< Machine software interrupt  */
#define JV_CAUSE_MTI   7u   /**< Machine timer interrupt     */
#define JV_CAUSE_MEI  11u   /**< Machine external interrupt  */

/* ============================================================================
 * mcause exception codes  (MSB = 0)
 * ============================================================================ */

#define JV_EXC_INSN_MISALIGN   0u  /**< Instruction address misaligned   */
#define JV_EXC_INSN_FAULT      1u  /**< Instruction access fault          */
#define JV_EXC_ILLEGAL_INSN    2u  /**< Illegal instruction               */
#define JV_EXC_BREAKPOINT      3u  /**< Breakpoint (EBREAK)               */
#define JV_EXC_LOAD_MISALIGN   4u  /**< Load address misaligned           */
#define JV_EXC_LOAD_FAULT      5u  /**< Load access fault                 */
#define JV_EXC_STORE_MISALIGN  6u  /**< Store/AMO address misaligned      */
#define JV_EXC_STORE_FAULT     7u  /**< Store/AMO access fault            */
#define JV_EXC_ECALL_M        11u  /**< Environment call from M-mode      */

/* ============================================================================
 * Global interrupt enable / disable
 * ============================================================================ */

/** Enable all machine-mode interrupts (set mstatus.MIE). */
static inline void jv_irq_enable(void)  { set_csr(mstatus,  MSTATUS_MIE); }

/** Disable all machine-mode interrupts (clear mstatus.MIE).
 *  Returns the previous mstatus value so it can be restored. */
static inline uint32_t jv_irq_disable(void) { return clear_csr(mstatus, MSTATUS_MIE); }

/** Restore mstatus from previously saved value (e.g., re-enable after critical section). */
static inline void jv_irq_restore(uint32_t saved_mstatus)
{
    write_csr(mstatus, saved_mstatus);
}

/* ============================================================================
 * Per-source interrupt enable / disable  (mie bits)
 * ============================================================================ */

/**
 * Enable one or more interrupt sources in mie.
 * @param mask  Bitmask of JV_IRQ_MSIE / MTIE / MEIE bits.
 */
static inline void jv_irq_source_enable(uint32_t mask)
{
    set_csr(mie, mask);
}

/**
 * Disable one or more interrupt sources in mie.
 * @param mask  Bitmask of JV_IRQ_MSIE / MTIE / MEIE bits.
 */
static inline void jv_irq_source_disable(uint32_t mask)
{
    clear_csr(mie, mask);
}

/* ============================================================================
 * Handler typedefs
 *
 * jv_irq_handler_t  — called for async interrupts; receives the cause code
 *                     (MSB already stripped from mcause).
 * jv_exc_handler_t  — called for synchronous exceptions; receives raw
 *                     mcause/mepc/mtval; returns 0 to keep mepc unchanged,
 *                     or a new PC to redirect to after mret.
 * ============================================================================ */

/** Interrupt handler: void handler(uint32_t cause). */
typedef void     (*jv_irq_handler_t)(uint32_t cause);

/** Exception handler: uint32_t handler(uint32_t mcause, uint32_t mepc, uint32_t mtval).
 *  Return 0 = resume at original mepc; return N = jump to N after mret. */
typedef uint32_t (*jv_exc_handler_t)(uint32_t mcause, uint32_t mepc, uint32_t mtval);

/* ============================================================================
 * Dispatch table API  (implemented in sw/common/jv_irq.c)
 * ============================================================================ */

/**
 * Register an interrupt handler for the given mcause interrupt code.
 * @param cause    Interrupt cause code (MSB stripped): JV_CAUSE_MSI / MTI / MEI
 *                 or any other code 0–15.
 * @param handler  Handler function; NULL clears the entry (falls back to default).
 */
void jv_irq_register(uint32_t cause, jv_irq_handler_t handler);

/**
 * Register an exception handler for the given mcause exception code.
 * @param cause    Exception cause code 0–31.
 * @param handler  Handler function; NULL clears the entry (falls back to default).
 *                 The handler return value become the new mepc (0 = unchanged).
 */
void jv_exc_register(uint32_t cause, jv_exc_handler_t handler);

/**
 * Route a trap to the appropriate registered handler.
 * Called by the default weak handle_trap() in jv_irq.c.
 * @param mcause  Raw mcause CSR value.
 * @param mepc    mepc at the time of the trap.
 * @param mtval   mtval at the time of the trap.
 * @return  New mepc value (0 = keep original).
 */
uint32_t jv_irq_dispatch(uint32_t mcause, uint32_t mepc, uint32_t mtval);

#ifdef __cplusplus
}
#endif

#endif /* JV_IRQ_H */
