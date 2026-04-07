/* ============================================================================
 * File: sw/tests/hello.c
 * Project: JV32 RISC-V Processor
 * Description: Hello World test for JV32 SoC
 *
 * Writes "Hello, JV32!\n" to the UART (polling TX), then exits via the
 * magic peripheral.  No C library: output is driven directly through
 * memory-mapped registers.
 *
 * Memory map:
 *   UART @ 0x2001_0000   (axi_uart)
 *   MAGIC @ 0x4000_0000  (axi_magic – offset 0 = exit code)
 *
 * UART register offsets (axi_uart, 32-bit word-aligned):
 *   0x00  TX data / status  – write byte to transmit
 *   0x04  RX data / status
 *   0x08  Status register: bit[0]=TX full, bit[1]=RX empty
 *   0x0C  Control register
 * ============================================================================ */

#include <stdint.h>

/* Peripheral base addresses */
#define UART_BASE   0x20010000U
#define MAGIC_BASE  0x40000000U

/* UART register offsets */
#define UART_TX_REG     0x00    /* write: TX data byte; read: TX FIFO status */
#define UART_RX_REG     0x04    /* read: RX data byte                        */
#define UART_STATUS_REG 0x08    /* bit[0] = TX full, bit[1] = RX empty       */
#define UART_CTRL_REG   0x0C    /* control (baud already set by SoC params)  */

/* Convenience macros */
#define UART_REG(off)   (*((volatile uint32_t *)(UART_BASE + (off))))
#define MAGIC_REG(off)  (*((volatile uint32_t *)(MAGIC_BASE + (off))))

/* ------------------------------------------------------------------ */
/* UART helpers                                                        */
/* ------------------------------------------------------------------ */

static inline void uart_putc(char c)
{
    /* Wait until TX FIFO is not full (STATUS bit 0 = 1 means full) */
    while (UART_REG(UART_STATUS_REG) & 0x1U)
        ;
    UART_REG(UART_TX_REG) = (uint32_t)(unsigned char)c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static void uart_puthex32(uint32_t v)
{
    const char *hex = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

/* ------------------------------------------------------------------ */
/* Weak trap handler override: print cause and exit(1)                */
/* ------------------------------------------------------------------ */
uint32_t handle_trap(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    uart_puts("\n[TRAP] mcause=");
    uart_puthex32(mcause);
    uart_puts(" mepc=");
    uart_puthex32(mepc);
    uart_puts(" mtval=");
    uart_puthex32(mtval);
    uart_puts("\n");
    /* Exit with failure code */
    MAGIC_REG(0) = 1U;
    for (;;);
    return 0;
}

/* ------------------------------------------------------------------ */
/* main                                                                */
/* ------------------------------------------------------------------ */
int main(void)
{
    uart_puts("Hello, JV32!\n");

    /* Confirm CSR reads work */
    uint32_t misa;
    __asm__ volatile ("csrr %0, misa" : "=r"(misa));
    uart_puts("misa=");
    uart_puthex32(misa);
    uart_puts("\n");

    /* Confirm basic arithmetic / division */
    volatile uint32_t a = 1000000U;
    volatile uint32_t b = 7U;
    volatile uint32_t q = a / b;
    volatile uint32_t r = a % b;
    uart_puts("1000000/7=");
    uart_puthex32(q);
    uart_puts(" rem=");
    uart_puthex32(r);
    uart_puts("\n");

    uart_puts("PASS\n");
    return 0; /* startup.S calls _exit(a0) → writes 0 to MAGIC */
}
