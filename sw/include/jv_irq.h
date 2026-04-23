/**
 * @file jv_irq.h
 * @brief JV32 machine-mode interrupt and exception management API.
 *
 * Provides:
 *  - mie bit-field constants (JV_IRQ_MSIE / MTIE / MEIE)
 *  - mcause interrupt and exception code constants
 *  - Trap frame struct (jv_trap_frame_t) — mirrors startup.S register save layout
 *  - Global interrupt enable/disable helpers (including jv_wfi())
 *  - Per-source mie bit control helpers
 *  - Handler typedefs for the dispatch table (jv_irq.c)
 *  - Handler registration: jv_irq_register() / jv_exc_register()
 *  - Dispatcher: jv_irq_dispatch()
 *
 * The dispatch table is fed by the default weak trap_handler() in jv_irq.c.
 * Tests that override trap_handler() entirely bypass the table.
 *
 * Startup integration
 * ───────────────────
 * startup.S calls:
 *   void trap_handler(jv_trap_frame_t *frame);
 *
 * jv_irq.c provides a weak trap_handler() that calls jv_irq_dispatch(frame).
 * Override trap_handler() in your test to bypass the table entirely.
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
 * Wait For Interrupt (WFI)
 * ============================================================================ */

/**
 * Suspend execution until an interrupt becomes pending.
 * On wake-up the interrupt handler is entered and execution resumes at
 * WFI+4 (the instruction after WFI) after the handler returns via MRET.
 */
static inline void jv_wfi(void)
{
    asm volatile("wfi");
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
 * Trap frame — mirrors the register save layout in startup.S
 *
 * RV32I: startup.S allocates 144 bytes on entry (addi sp, sp, -144):
 * RV32E: startup.S allocates  80 bytes on entry (addi sp, sp, -80);
 *        only x0-x15 exist; mepc/mstatus/mcause/mtval follow at +64..+76.
 *
 *   offset   field      register / CSR
 *   ------   --------   ---------------
 *    +0      _pad       (x0 placeholder, always 0)
 *    +4      ra         x1
 *    +8      sp         x2  (stack pointer at trap entry, post-alloc)
 *    +12     gp         x3
 *    +16     tp         x4
 *    +20     t0         x5
 *    +24     t1         x6
 *    +28     t2         x7
 *    +32     s0         x8 / fp
 *    +36     s1         x9
 *    +40     a0         x10
 *    +44     a1         x11
 *    +48     a2         x12
 *    +52     a3         x13
 *    +56     a4         x14
 *    +60     a5         x15
 *    +64     a6         x16
 *    +68     a7         x17
 *    +72     s2         x18
 *    +76     s3         x19
 *    +80     s4         x20
 *    +84     s5         x21
 *    +88     s6         x22
 *    +92     s7         x23
 *    +96     s8         x24
 *    +100    s9         x25
 *    +104    s10        x26
 *    +108    s11        x27
 *    +112    t3         x28
 *    +116    t4         x29
 *    +120    t5         x30
 *    +124    t6         x31
 *    +128    mepc       mepc CSR  (handler may update to redirect return PC)
 *    +132    mstatus    mstatus CSR (handler may update; restored before mret)
 *    +136    mcause     mcause CSR (read-only for handlers)
 *    +140    mtval      mtval CSR  (read-only for handlers)
 *
 * Exception handlers receive a pointer to this struct and may:
 *   - Set frame->mepc to redirect the return PC (e.g. skip a faulting insn).
 *   - Modify frame->mstatus bits (e.g. clear MIE/MPIE) — changes are applied
 *     via csrw before mret so they survive the MRET mstatus restore.
 * ============================================================================ */
typedef struct jv_trap_frame {
    uint32_t _pad;      /* +0   x0 placeholder */
    uint32_t ra;        /* +4   x1  */
    uint32_t sp;        /* +8   x2  (stack pointer at trap entry) */
    uint32_t gp;        /* +12  x3  */
    uint32_t tp;        /* +16  x4  */
    uint32_t t0;        /* +20  x5  */
    uint32_t t1;        /* +24  x6  */
    uint32_t t2;        /* +28  x7  */
    uint32_t s0;        /* +32  x8/fp */
    uint32_t s1;        /* +36  x9  */
    uint32_t a0;        /* +40  x10 */
    uint32_t a1;        /* +44  x11 */
    uint32_t a2;        /* +48  x12 */
    uint32_t a3;        /* +52  x13 */
    uint32_t a4;        /* +56  x14 */
    uint32_t a5;        /* +60  x15 */
#ifndef __riscv_e
    uint32_t a6;        /* +64  x16 */
    uint32_t a7;        /* +68  x17 */
    uint32_t s2;        /* +72  x18 */
    uint32_t s3;        /* +76  x19 */
    uint32_t s4;        /* +80  x20 */
    uint32_t s5;        /* +84  x21 */
    uint32_t s6;        /* +88  x22 */
    uint32_t s7;        /* +92  x23 */
    uint32_t s8;        /* +96  x24 */
    uint32_t s9;        /* +100 x25 */
    uint32_t s10;       /* +104 x26 */
    uint32_t s11;       /* +108 x27 */
    uint32_t t3;        /* +112 x28 */
    uint32_t t4;        /* +116 x29 */
    uint32_t t5;        /* +120 x30 */
    uint32_t t6;        /* +124 x31 */
    uint32_t mepc;      /* +128 return PC (writable by exception handlers) */
    uint32_t mstatus;   /* +132 (writable; restored before mret) */
    uint32_t mcause;    /* +136 (read-only for handlers) */
    uint32_t mtval;     /* +140 (read-only for handlers) */
#else  /* __riscv_e: x0-x15 only, 80-byte frame */
    uint32_t mepc;      /* +64  return PC (writable by exception handlers) */
    uint32_t mstatus;   /* +68  (writable; restored before mret) */
    uint32_t mcause;    /* +72  (read-only for handlers) */
    uint32_t mtval;     /* +76  (read-only for handlers) */
#endif /* __riscv_e */
} jv_trap_frame_t;

/* ============================================================================
 * Handler typedefs
 *
 * jv_irq_handler_t  — called for async interrupts; receives the cause code
 *                     (MSB already stripped from mcause).
 * jv_exc_handler_t  — called for synchronous exceptions; receives a pointer
 *                     to the full saved register frame.  Set frame->mepc to
 *                     redirect the return PC (e.g. skip the faulting insn).
 * ============================================================================ */

/** Interrupt handler: void handler(uint32_t cause). */
typedef void (*jv_irq_handler_t)(uint32_t cause);

/** Exception handler: void handler(jv_trap_frame_t *frame).
 *  Set frame->mepc to redirect the return address after mret. */
typedef void (*jv_exc_handler_t)(jv_trap_frame_t *frame);

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
 *                 Set frame->mepc inside the handler to redirect the return PC.
 */
void jv_exc_register(uint32_t cause, jv_exc_handler_t handler);

/**
 * Route a trap to the appropriate registered handler.
 * Called by the default weak trap_handler() in jv_irq.c.
 * @param frame  Pointer to the saved register frame on the trap stack.
 */
void jv_irq_dispatch(jv_trap_frame_t *frame);

/**
 * Top-level trap handler — called from trap_entry in startup.S with a pointer
 * to the full saved register frame.  Weak symbol; individual tests may override.
 * Exception handlers communicate the return PC via frame->mepc rather than a
 * direct csrw; the startup.S epilogue restores mepc from frame->mepc before mret.
 * @param frame  Pointer to the saved register frame.
 */
void trap_handler(jv_trap_frame_t *frame);

#ifdef __cplusplus
}
#endif

#endif /* JV_IRQ_H */
