/**
 * @file jv_clic.h
 * @brief JV32 CLIC driver — mtime, mtimecmp, MSIP, and external interrupt control.
 *
 * Header-only inline driver for the JV32 CLIC peripheral at JV_CLIC_BASE.
 * The CLIC exposes a CLINT-compatible mtime/mtimecmp/msip block at the
 * standard CLINT offsets (0x0000/0x4000/0x4004/0x4008/0x400C), plus per-line
 * external interrupt control registers at offset 0x1000 + n*4.
 *
 * @see axi_clic.sv
 */

#ifndef JV_CLIC_H
#define JV_CLIC_H

#include <stdint.h>
#include "jv_platform.h"
#include "jv_irq.h"

/* ── mtime ───────────────────────────────────────────────────────────────── */

/**
 * Read the 64-bit hardware timer, safe against carry-over of the high word.
 * @return  Current mtime value (increments every clock cycle).
 */
static inline uint64_t jv_clic_mtime(void)
{
    uint32_t lo, hi, hi2;
    do {
        hi  = JV_CLIC_MTIME_HI;
        lo  = JV_CLIC_MTIME_LO;
        hi2 = JV_CLIC_MTIME_HI;
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

/* ── mtimecmp ────────────────────────────────────────────────────────────── */

/**
 * Write a new 64-bit compare value.
 * Writes HI = 0xFFFFFFFF first to prevent a spurious timer interrupt while
 * updating LO (required when the new LO decreases below the current mtime_lo).
 * @param cmp  Absolute compare value; timer IRQ fires when mtime >= cmp.
 */
static inline void jv_clic_set_mtimecmp(uint64_t cmp)
{
    JV_CLIC_MTIMECMP_HI = 0xFFFFFFFFu;           /* prevent spurious IRQ  */
    JV_CLIC_MTIMECMP_LO = (uint32_t)cmp;
    JV_CLIC_MTIMECMP_HI = (uint32_t)(cmp >> 32);
}

/**
 * Read the current 64-bit mtimecmp value.
 * @return  Current compare value.
 */
static inline uint64_t jv_clic_get_mtimecmp(void)
{
    uint32_t lo = JV_CLIC_MTIMECMP_LO;
    uint32_t hi = JV_CLIC_MTIMECMP_HI;
    return ((uint64_t)hi << 32) | lo;
}

/**
 * Disable timer interrupts by setting mtimecmp to the maximum value.
 */
static inline void jv_clic_timer_disable(void)
{
    jv_clic_set_mtimecmp(0xFFFFFFFFFFFFFFFFULL);
}

/**
 * Schedule a timer interrupt @p ticks cycles from now.
 * @param ticks  Offset from current mtime.
 */
static inline void jv_clic_timer_set_rel(uint64_t ticks)
{
    jv_clic_set_mtimecmp(jv_clic_mtime() + ticks);
}

/**
 * Enable the machine timer interrupt source in mie (MTIE = bit 7).
 */
static inline void jv_clic_timer_irq_enable(void)
{
    jv_irq_source_enable(JV_IRQ_MTIE);
}

/**
 * Disable the machine timer interrupt source in mie.
 */
static inline void jv_clic_timer_irq_disable(void)
{
    jv_irq_source_disable(JV_IRQ_MTIE);
}

/* ── software interrupt (MSIP) ───────────────────────────────────────────── */

/** Trigger a machine software interrupt by setting MSIP[0]. */
static inline void jv_clic_msip_set(void)
{
    JV_CLIC_MSIP = 1u;
}

/**
 * Clear the machine software interrupt.
 * A read-back ensures the write is visible before returning.
 */
static inline void jv_clic_msip_clear(void)
{
    JV_CLIC_MSIP = 0u;
    (void)JV_CLIC_MSIP;   /* read-back to flush write */
}

/** Enable the machine software interrupt source in mie (MSIE = bit 3). */
static inline void jv_clic_msip_irq_enable(void)
{
    jv_irq_source_enable(JV_IRQ_MSIE);
}

/** Disable the machine software interrupt source in mie. */
static inline void jv_clic_msip_irq_disable(void)
{
    jv_irq_source_disable(JV_IRQ_MSIE);
}

/* ── external interrupt lines (CLICINT[n]) ───────────────────────────────── */

/**
 * Enable external interrupt line @p n.
 * @param n  Line index (0–15).
 */
static inline void jv_clic_ext_irq_enable(unsigned n)
{
    JV_CLICINT(n) |= JV_CLICINT_IE;
}

/**
 * Disable external interrupt line @p n.
 * @param n  Line index (0–15).
 */
static inline void jv_clic_ext_irq_disable(unsigned n)
{
    JV_CLICINT(n) &= ~JV_CLICINT_IE;
}

/**
 * Return non-zero if external interrupt line @p n is pending.
 * @param n  Line index (0–15).
 */
static inline int jv_clic_ext_irq_pending(unsigned n)
{
    return (JV_CLICINT(n) & JV_CLICINT_IP) != 0;
}

/**
 * Set the priority/level of external interrupt line @p n.
 * @param n      Line index (0–15).
 * @param level  8-bit level value; higher = more urgent.
 */
static inline void jv_clic_ext_irq_set_level(unsigned n, uint8_t level)
{
    uint32_t r = JV_CLICINT(n);
    r &= ~JV_CLICINT_CTL_MASK;
    r |= (uint32_t)level << JV_CLICINT_CTL_SHIFT;
    JV_CLICINT(n) = r;
}

/**
 * Enable the machine external interrupt source in mie (MEIE = bit 11).
 * This is the global gate for all CLIC external lines.
 */
static inline void jv_clic_meie_enable(void)
{
    jv_irq_source_enable(JV_IRQ_MEIE);
}

/** Disable the machine external interrupt source in mie. */
static inline void jv_clic_meie_disable(void)
{
    jv_irq_source_disable(JV_IRQ_MEIE);
}

#endif /* JV_CLIC_H */
