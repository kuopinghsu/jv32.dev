/* ============================================================================
 * File: sw/hello/hello.c
 * Project: JV32 RISC-V Processor
 * Description: Hello World test — uses JV SDK
 * ============================================================================ */

#include "jv_platform.h"
#include "jv_uart.h"
#include "csr.h"

int main(void)
{
    jv_uart_puts("Hello, JV32!\n");

    /* CSR read via SDK macro */
    jv_uart_puts("misa=");
    jv_uart_puthex32(read_csr(misa));
    jv_uart_puts("\n");

    /* Basic arithmetic / division */
    volatile uint32_t a = 1000000U;
    volatile uint32_t b = 7U;
    volatile uint32_t q = a / b;
    volatile uint32_t r = a % b;
    jv_uart_puts("1000000/7=");
    jv_uart_putu32(q);
    jv_uart_puts(" rem=");
    jv_uart_putu32(r);
    jv_uart_puts("\n");

    /* Cycle counter */
    jv_uart_puts("mcycle=");
    jv_uart_puthex32((uint32_t)read_csr_mcycle64());
    jv_uart_puts("\n");

    jv_uart_puts("PASS\n");
    jv_exit(0);
}
