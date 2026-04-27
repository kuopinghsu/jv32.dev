/**
 * @file jv_uart.h
 * @brief JV32 AXI UART driver — polling and interrupt-driven modes.
 *
 * Header-only inline driver for the JV32 UART peripheral at JV_UART_BASE.
 * The baud rate is fixed at SoC synthesis time (CLK_FREQ/BAUD_RATE divisor
 * programmed into the hardware); call jv_uart_set_baud() to change it at
 * run-time if needed.
 *
 * @see axi_uart.sv
 */

#ifndef JV_UART_H
#define JV_UART_H

#include <stdint.h>
#include "jv_platform.h"

/* ── status queries ──────────────────────────────────────────────────────── */

/** Return non-zero if the TX FIFO is full (do not write right now). */
static inline int jv_uart_tx_busy(void)
{
    return (JV_UART_STATUS & JV_UART_ST_TX_BUSY) != 0;
}

/** Return non-zero if at least one byte is waiting in the RX FIFO. */
static inline int jv_uart_rx_ready(void)
{
    return (JV_UART_STATUS & JV_UART_ST_RX_READY) != 0;
}

/* ── baud rate ───────────────────────────────────────────────────────────── */

/**
 * Set the baud-rate divisor at run-time.
 * @param baud_div  CLKS_PER_BIT − 1.  Examples at 80 MHz:
 *                  baud_div = 694  → 115200 baud
 *                  baud_div = 24   → 3.2 Mbaud
 *
 * The peripheral latches the new divisor immediately.  Any byte currently
 * in flight will be corrupted; flush the TX FIFO first if needed.
 */
static inline void jv_uart_set_baud(uint32_t baud_div)
{
    JV_UART_LEVEL = baud_div & 0xFFFFu;
}

/* ── polling TX ──────────────────────────────────────────────────────────── */

/**
 * Block until the TX FIFO has room, then transmit one byte.
 * @param c  Byte to transmit.
 */
static inline void jv_uart_putc(char c)
{
    while (jv_uart_tx_busy()) {}
    JV_UART_DATA = (uint32_t)(uint8_t)c;
}

/**
 * Transmit a NUL-terminated string.
 * @param s  Pointer to the string.
 */
static inline void jv_uart_puts(const char *s)
{
    while (*s) jv_uart_putc(*s++);
}

/**
 * Transmit @p len bytes from @p buf.
 * @param buf  Source buffer.
 * @param len  Number of bytes to transmit.
 */
static inline void jv_uart_write(const uint8_t *buf, uint32_t len)
{
    for (uint32_t i = 0; i < len; i++)
        jv_uart_putc((char)buf[i]);
}

/**
 * Print a 32-bit value as 8 hex digits via UART.
 * @param v  Value to print.
 */
static inline void jv_uart_puthex32(uint32_t v)
{
    static const char h[] = "0123456789abcdef";
    jv_uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        jv_uart_putc(h[(v >> i) & 0xFu]);
}

/**
 * Print a decimal unsigned 32-bit integer via UART.
 * @param v  Value to print.
 */
static inline void jv_uart_putu32(uint32_t v)
{
    char buf[11];
    int  pos = 10;
    buf[pos] = '\0';
    if (v == 0) { buf[--pos] = '0'; }
    else {
        while (v) { buf[--pos] = (char)('0' + v % 10); v /= 10; }
    }
    jv_uart_puts(&buf[pos]);
}

/* ── polling RX ──────────────────────────────────────────────────────────── */

/**
 * Return the next byte from the RX FIFO, or -1 if empty.
 * @return  Received byte (0–255) or -1 when the FIFO is empty.
 */
static inline int jv_uart_getc(void)
{
    if (!jv_uart_rx_ready()) return -1;
    return (int)(JV_UART_DATA & 0xFFu);
}

/**
 * Block until a byte is received, then return it.
 * @return  Received byte (0–255).
 */
static inline uint8_t jv_uart_getc_blocking(void)
{
    while (!jv_uart_rx_ready()) {}
    return (uint8_t)(JV_UART_DATA & 0xFFu);
}

/* ── interrupt control ───────────────────────────────────────────────────── */

/**
 * Enable one or more UART interrupt sources.
 * @param mask  Bitmask of JV_UART_IE_* bits to enable.
 */
static inline void jv_uart_irq_enable(uint32_t mask)
{
    JV_UART_IE |= mask;
}

/**
 * Disable one or more UART interrupt sources.
 * @param mask  Bitmask of JV_UART_IE_* bits to disable.
 */
static inline void jv_uart_irq_disable(uint32_t mask)
{
    JV_UART_IE &= ~mask;
}

/**
 * Read (and clear) the interrupt status register (level-triggered, W1C).
 * @return  Snapshot of IS before clearing.
 */
static inline uint32_t jv_uart_irq_status(void)
{
    uint32_t s = JV_UART_IS;
    JV_UART_IS = s;   /* W1C */
    return s;
}

/* ── loopback ────────────────────────────────────────────────────────────── */

/** Enable internal TX→RX loopback; uart_rx external pin is ignored. */
static inline void jv_uart_loopback_enable(void)  { JV_UART_CTRL |=  JV_UART_CTRL_LOOPBACK; }

/** Disable loopback; RX reads from the external uart_rx pin. */
static inline void jv_uart_loopback_disable(void) { JV_UART_CTRL &= ~JV_UART_CTRL_LOOPBACK; }

/* ── capability ──────────────────────────────────────────────────────────── */

/** Return the raw CAPABILITY register value ([31:16]=version,[15:8]=RX_depth,[7:0]=TX_depth). */
static inline uint32_t jv_uart_capability(void)     { return JV_UART_CAP; }

/** Return TX FIFO depth (entries). */
static inline uint32_t jv_uart_tx_fifo_depth(void)  { return  JV_UART_CAP        & 0xFFu; }

/** Return RX FIFO depth (entries). */
static inline uint32_t jv_uart_rx_fifo_depth(void)  { return (JV_UART_CAP >>  8) & 0xFFu; }

/** Return hardware version field. */
static inline uint32_t jv_uart_version(void)         { return (JV_UART_CAP >> 16) & 0xFFFFu; }

#endif /* JV_UART_H */
