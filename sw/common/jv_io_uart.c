// ============================================================================
// File: jv_io_uart.c
// Project: JV32 RISC-V Processor
// Description: UART backend for jv_putc()/jv_exit().
// ============================================================================

#include "jv_platform.h"
#include "jv_uart.h"

void jv_putc(char c)
{
    jv_uart_putc(c);
}

int jv_write(int fd, const char *buf, int len)
{
    (void)fd;
    for (int i = 0; i < len; i++)
        jv_uart_putc(buf[i]);
    return len;
}

void jv_exit(int code)
{
    if (code == 0) {
        jv_uart_puts("\n[EXIT] PASS\n");
    } else {
        jv_uart_puts("\n[EXIT] FAIL code=");
        jv_uart_puthex32((uint32_t)code);
        jv_uart_puts("\n");
    }

    /* Drain TX FIFO before handing off to the raw exit path. */
        /* Wait until TX FIFO is empty so the exit message is fully queued
         * into the UART serializer before handing off to jv_exit_raw(). */
    while (!(jv_uart_irq_status() & JV_UART_IE_TX_EMPTY)) {}

    /* Fire the magic-device exit register so the RTL/ISS simulator
     * terminates cleanly.  On bare-metal FPGA targets this address is
     * unmapped; the resulting AXI DECERR is harmless since the test
     * output has already been flushed to the UART TX FIFO above. */
    jv_exit_raw(code);
    __builtin_unreachable();
}
