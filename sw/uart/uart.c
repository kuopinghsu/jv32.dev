// ============================================================================
// File: sw/uart/uart.c
// Project: JV32 RISC-V Processor
// Description: AXI UART hardware test -- uses JV_IO_BACKEND=uart so all
//              jv_puts()/jv_puthex32() output flows through the AXI UART.
//
// Tests:
//   1. Capability register -- read TX/RX FIFO depths and version field.
//   2. Polling loopback -- enable internal TX->RX loopback, send a test
//      string byte-by-byte, poll for RX-ready, verify each byte matches.
//   3. FIFO burst -- write several bytes then read them back via loopback
//      to confirm the FIFO buffers multiple bytes correctly.
//   4. Interrupt-status loopback -- arm RX-ready IRQ enable, write one byte,
//      wait for JV_UART_IS to set the rx_ready bit, then clear by reading
//      the byte.  No actual CPU interrupt is taken.
//
// Note on loopback and pending TX:
//   All test output goes through the same UART (jv_putc -> jv_uart_putc).
//   When JV_UART_CTRL_LOOPBACK is enabled, TX bytes already queued in the
//   TX FIFO from previous jv_puts() calls may loop back to RX.  loopback_rx_drain()
//   spins long enough for pending TX to serialize (each byte takes 80 sim-cycles
//   at SIM_CLKS_PER_BIT=8), then flushes the RX FIFO.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Kuoping Hsu
// ============================================================================

#include <stdint.h>
#include "jv_platform.h"
#include "jv_uart.h"

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static int g_pass = 1;   /* 0 once any check fails */

static void print_result(const char *name, int ok)
{
    if (!ok) g_pass = 0;
    jv_puts(ok ? "  [PASS] " : "  [FAIL] ");
    jv_puts(name);
    jv_puts("\n");
}

/* After enabling loopback, wait for any bytes already in the TX FIFO
 * (previous jv_puts() output) to finish serializing and appear in RX,
 * then drain them.  50 000 C iterations ~300 000 sim-cycles >> any
 * realistic pending output (~100 bytes x 80 cycles/byte = 8 000 cycles). */
static void loopback_rx_drain(void)
{
    for (volatile uint32_t i = 50000u; i; i--) {}
    while (jv_uart_rx_ready()) (void)jv_uart_getc();
}

// ---------------------------------------------------------------------------
// Test 1: capability register
// ---------------------------------------------------------------------------
static int test_capability(void)
{
    uint32_t cap    = jv_uart_capability();
    uint32_t tx_dep = jv_uart_tx_fifo_depth();
    uint32_t rx_dep = jv_uart_rx_fifo_depth();
    uint32_t ver    = jv_uart_version();

    /* Note: jv_puthex32() already prepends "0x". */
    jv_puts("  cap="); jv_puthex32(cap);
    jv_puts(" tx_depth="); jv_puthex32(tx_dep);
    jv_puts(" rx_depth="); jv_puthex32(rx_dep);
    jv_puts(" ver="); jv_puthex32(ver);
    jv_puts("\n");

    /* The 8-bit depth field overflows to 0 when FIFO_DEPTH >= 256
     * (testbench uses UART_FIFO_DEPTH=4096; 4096 & 0xFF == 0).
     * Treat 0 as "deep FIFO" and require only version >= 1. */
    int ok = (ver >= 1u);
    print_result("capability register", ok);
    return ok;
}

// ---------------------------------------------------------------------------
// Test 2: polling loopback - byte-by-byte
// ---------------------------------------------------------------------------
static int test_polling_loopback(void)
{
    static const char msg[] = "JV32-UART";
    int ok = 1;

    jv_uart_loopback_enable();
    /* Drain bytes that looped back from previous TX output. */
    loopback_rx_drain();

    for (uint32_t i = 0; msg[i] != '\0'; i++) {
        char tx = msg[i];
        jv_uart_putc(tx);

        /* Wait for the echoed byte to arrive in the RX FIFO. */
        uint32_t limit = 1000000u;
        while (!jv_uart_rx_ready() && --limit) {}
        if (limit == 0) { ok = 0; break; }

        char rx = jv_uart_getc();
        if (rx != tx) { ok = 0; break; }
    }

    jv_uart_loopback_disable();
    print_result("polling loopback", ok);
    return ok;
}

// ---------------------------------------------------------------------------
// Test 3: FIFO burst loopback
// ---------------------------------------------------------------------------
#define BURST_SIZE 8u   /* fixed; FIFO depth field may be 0 on 8-bit overflow */

static int test_fifo_burst(void)
{
    jv_uart_loopback_enable();
    loopback_rx_drain();

    /* Write BURST_SIZE bytes back-to-back. */
    for (uint32_t i = 0; i < BURST_SIZE; i++)
        jv_uart_putc((char)('A' + (i & 0x1Fu)));

    /* Read back and verify. */
    int ok = 1;
    for (uint32_t i = 0; i < BURST_SIZE; i++) {
        uint32_t limit = 1000000u;
        while (!jv_uart_rx_ready() && --limit) {}
        if (limit == 0) { ok = 0; break; }

        char rx = jv_uart_getc();
        char expected = (char)('A' + (i & 0x1Fu));
        if (rx != expected) { ok = 0; break; }
    }

    jv_uart_loopback_disable();
    print_result("FIFO burst loopback", ok);
    return ok;
}

// ---------------------------------------------------------------------------
// Test 4: interrupt-status flag (no CPU interrupt taken)
// ---------------------------------------------------------------------------
static int test_irq_status(void)
{
    /* Enable the RX-ready interrupt source in the IE register so IS reflects
     * the RX FIFO state, then verify the IS bit sets after a loopback byte. */
    jv_uart_irq_enable(JV_UART_IE_RX_READY);
    jv_uart_loopback_enable();
    loopback_rx_drain();

    jv_uart_putc('Z');

    /* Poll IS (level-triggered: clears automatically when FIFO drains). */
    uint32_t limit = 1000000u;
    while (!(jv_uart_irq_status() & JV_UART_IE_RX_READY) && --limit) {}

    int irq_seen = (limit > 0u);

    /* Drain the byte so the IS bit deasserts. */
    if (irq_seen)
        (void)jv_uart_getc();

    jv_uart_loopback_disable();
    jv_uart_irq_disable(JV_UART_IE_RX_READY);

    print_result("RX-ready interrupt status", irq_seen);
    return irq_seen;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(void)
{
    jv_puts("\n=== UART Hardware Test (JV_IO_BACKEND=uart) ===\n\n");

    jv_puts("[1] Capability register\n");
    test_capability();

    jv_puts("[2] Polling loopback\n");
    test_polling_loopback();

    jv_puts("[3] FIFO burst loopback\n");
    test_fifo_burst();

    jv_puts("[4] RX-ready interrupt status\n");
    test_irq_status();

    jv_puts("\n=== UART test ");
    jv_puts(g_pass ? "PASS" : "FAIL");
    jv_puts(" ===\n");

    jv_exit(g_pass ? 0 : 1);
}
