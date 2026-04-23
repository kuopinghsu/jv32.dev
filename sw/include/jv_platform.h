/**
 * @file jv_platform.h
 * @brief JV32 SoC platform definitions: base addresses, register offsets,
 *        bit-field constants, register accessor macro, and basic inline helpers.
 *
 * Include this file before any other jv_ header.
 *
 * Usage:
 *   #include "jv_platform.h"
 *   jv_putc('A');
 *   jv_exit(0);        // PASS
 */

#ifndef JV_PLATFORM_H
#define JV_PLATFORM_H

#include <stdint.h>

/* ============================================================================
 * Memory map
 * ============================================================================ */

#define JV_IRAM_BASE    0x80000000UL  /**< 64 KB IRAM (TCM, RX)             */
#define JV_IRAM_SIZE    0x00010000UL
#define JV_DRAM_BASE    0xC0000000UL  /**< 64 KB DRAM (TCM, RW)             */
#define JV_DRAM_SIZE    0x00010000UL
#define JV_CLIC_BASE    0x02000000UL  /**< CLIC / CLINT-compatible timer     */
#define JV_CLIC_SIZE    0x00200000UL
#define JV_UART_BASE    0x20010000UL  /**< AXI UART                         */
#define JV_UART_SIZE    0x00010000UL
#define JV_MAGIC_BASE   0x40000000UL  /**< Magic device (simulation only)   */
#define JV_MAGIC_SIZE   0x00010000UL
#define JV_NCM_BASE     0x40001000UL  /**< Non-cacheable memory (512 B)      */
#define JV_NCM_SIZE     0x00000200UL

/* ============================================================================
 * Register accessor macro
 * ============================================================================ */

/** Dereference a 32-bit memory-mapped register. */
#define JV_REG32(base, off) \
    (*(volatile uint32_t *)((uintptr_t)(base) + (uintptr_t)(off)))

/* ============================================================================
 * UART  (JV_UART_BASE = 0x2001_0000)
 * ============================================================================ */

/* Register offsets */
#define JV_UART_DATA_OFF    0x00U /**< TX write / RX read (RX FIFO pop-on-read)        */
#define JV_UART_STATUS_OFF  0x04U /**< Status (RO)                                      */
#define JV_UART_IE_OFF      0x08U /**< Interrupt enable (R/W) [1:0]                     */
#define JV_UART_IS_OFF      0x0CU /**< Interrupt status, level (RO) [1:0]               */
#define JV_UART_LEVEL_OFF   0x10U /**< [31:16]=TX FIFO count,[15:0]=RX FIFO count;      *
                                   *   write: sets baud-rate divisor (CLKS_PER_BIT - 1)  */
#define JV_UART_CTRL_OFF    0x14U /**< Control (R/W): [0]=loopback_en                   */
#define JV_UART_CAP_OFF     0x18U /**< Capability (RO): [31:16]=version,[15:8]=RX depth,[7:0]=TX depth */

/* STATUS bits */
#define JV_UART_ST_TX_BUSY    (1u << 0) /**< TX FIFO full — do not write          */
#define JV_UART_ST_TX_FULL    (1u << 1) /**< TX FIFO full (alias for TX_BUSY)     */
#define JV_UART_ST_RX_READY   (1u << 2) /**< RX FIFO not empty — byte available   */
#define JV_UART_ST_RX_OVERRUN (1u << 3) /**< RX FIFO full (incoming bytes lost)   */

/* IE / IS bits */
#define JV_UART_IE_RX_READY (1u << 0) /**< Interrupt on RX FIFO not-empty       */
#define JV_UART_IE_TX_EMPTY (1u << 1) /**< Interrupt on TX FIFO drained         */

/* CTRL bits */
#define JV_UART_CTRL_LOOPBACK (1u << 0) /**< Internal TX→RX loopback             */

/* Register accessors */
#define JV_UART_DATA   JV_REG32(JV_UART_BASE, JV_UART_DATA_OFF)
#define JV_UART_STATUS JV_REG32(JV_UART_BASE, JV_UART_STATUS_OFF)
#define JV_UART_IE     JV_REG32(JV_UART_BASE, JV_UART_IE_OFF)
#define JV_UART_IS     JV_REG32(JV_UART_BASE, JV_UART_IS_OFF)
#define JV_UART_LEVEL  JV_REG32(JV_UART_BASE, JV_UART_LEVEL_OFF)
#define JV_UART_CTRL   JV_REG32(JV_UART_BASE, JV_UART_CTRL_OFF)
#define JV_UART_CAP    JV_REG32(JV_UART_BASE, JV_UART_CAP_OFF)

/* ============================================================================
 * CLIC / CLINT  (JV_CLIC_BASE = 0x0200_0000)
 *
 * CLINT-compatible layout (mtime/mtimecmp/msip at standard offsets).
 * Per-interrupt CLICINT registers extend the block at offset 0x1000.
 * ============================================================================ */

/* CLINT register offsets */
#define JV_CLIC_MSIP_OFF          0x0000U /**< Machine Software Interrupt Pending [0]    */
#define JV_CLIC_MTIME_LO_OFF      0x4000U /**< mtime lower 32 bits (R/W)                 */
#define JV_CLIC_MTIME_HI_OFF      0x4004U /**< mtime upper 32 bits (R/W)                 */
#define JV_CLIC_MTIMECMP_LO_OFF   0x4008U /**< mtimecmp lower 32 bits (R/W)              */
#define JV_CLIC_MTIMECMP_HI_OFF   0x400CU /**< mtimecmp upper 32 bits (R/W)              */

/** CLICINT[n] register offset (n = 0..15). */
#define JV_CLIC_INT_OFF(n)        (0x1000U + (unsigned)(n) * 4U)

/* CLICINT bit fields */
#define JV_CLICINT_IP           (1u << 0)  /**< Interrupt pending (RO — mirrors ext_irq_i[n]) */
#define JV_CLICINT_IE           (1u << 1)  /**< Interrupt enable                              */
#define JV_CLICINT_CTL_SHIFT    16         /**< Priority/level field shift                    */
#define JV_CLICINT_CTL_MASK     (0xFFu << 16) /**< Priority/level field mask                 */

/* Register accessors */
#define JV_CLIC_MSIP        JV_REG32(JV_CLIC_BASE, JV_CLIC_MSIP_OFF)
#define JV_CLIC_MTIME_LO    JV_REG32(JV_CLIC_BASE, JV_CLIC_MTIME_LO_OFF)
#define JV_CLIC_MTIME_HI    JV_REG32(JV_CLIC_BASE, JV_CLIC_MTIME_HI_OFF)
#define JV_CLIC_MTIMECMP_LO JV_REG32(JV_CLIC_BASE, JV_CLIC_MTIMECMP_LO_OFF)
#define JV_CLIC_MTIMECMP_HI JV_REG32(JV_CLIC_BASE, JV_CLIC_MTIMECMP_HI_OFF)
/** Access CLICINT[n] register. */
#define JV_CLICINT(n)       JV_REG32(JV_CLIC_BASE, JV_CLIC_INT_OFF(n))

/* ============================================================================
 * Magic device  (JV_MAGIC_BASE = 0x4000_0000)  — simulation only
 * ============================================================================ */

#define JV_MAGIC_CONSOLE_OFF  0x0000U /**< Write low byte → host stdout         */
#define JV_MAGIC_EXIT_OFF     0x0004U /**< Write to exit sim; 1=PASS, N=FAIL(N) */

#define JV_MAGIC_CONSOLE  JV_REG32(JV_MAGIC_BASE, JV_MAGIC_CONSOLE_OFF)
#define JV_MAGIC_EXIT     JV_REG32(JV_MAGIC_BASE, JV_MAGIC_EXIT_OFF)

/* ============================================================================
 * Utility macros
 * ============================================================================ */

#ifndef UNUSED
#define UNUSED(x) ((void)(x))
#endif

/* ============================================================================
 * Inline platform helpers
 * ============================================================================ */

#ifndef JV_PLATFORM_NO_INLINE_HELPERS

/**
 * Write one character to the simulation console (Magic device).
 * @param c  Character to write.
 */
static inline void jv_putc(char c)
{
    JV_MAGIC_CONSOLE = (uint32_t)(unsigned char)c;
}

/**
 * Signal simulation exit.
 * Encoding: pass (code==0) → write 1; fail (code≠0) → write (code<<1)|1.
 * This function never returns.
 * @param code  Exit code (0=PASS, non-zero=FAIL).
 */
static inline void jv_exit(int code)
{
    JV_MAGIC_EXIT = (code == 0) ? 1u : (((uint32_t)code << 1) | 1u);
    while (1) { __asm__ volatile("nop"); }
}

/**
 * Print a 32-bit value as 8 hex digits via the Magic console.
 * @param v  Value to print.
 */
static inline void jv_puthex32(uint32_t v)
{
    static const char h[] = "0123456789abcdef";
    jv_putc('0'); jv_putc('x');
    for (int i = 28; i >= 0; i -= 4)
        jv_putc(h[(v >> i) & 0xFu]);
}

/**
 * Print a NUL-terminated string via the Magic console.
 * @param s  String to print.
 */
static inline void jv_puts(const char *s)
{
    while (*s) jv_putc(*s++);
}

#endif /* JV_PLATFORM_NO_INLINE_HELPERS */

#endif /* JV_PLATFORM_H */
