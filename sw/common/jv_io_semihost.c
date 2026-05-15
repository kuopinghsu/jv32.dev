// ============================================================================
// File: jv_io_semihost.c
// Project: JV32 RISC-V Processor
// Description: Semihosting backend for jv_putc()/jv_exit().
//
// Issues a RISC-V semihosting v1.0 call sequence:
//   slli x0, x0, 0x1f  (entry marker)
//   ebreak              (trap / debugger intercept)
//   srai x0, x0,  7    (exit marker)
//
// The ebreak is serviced by:
//   - jv32sim.cpp in software-simulation mode (before trap fires)
//   - tb_jv32_soc.cpp in RTL simulation (at ENTRY_NOP retire, host-side)
//   - OpenOCD on FPGA/real-chip (via JTAG halt)
// The SW trap handler in jv_irq.c only advances mepc and sets return value;
// it never writes to the magic device or UART.
// ============================================================================

#include <stdint.h>
#include "jv_platform.h"

static uint32_t jv_semihost_call(uint32_t op, uintptr_t param)
{
    register uint32_t a0 __asm__("a0") = op;
    register uintptr_t a1 __asm__("a1") = param;
    __asm__ volatile (
        ".option push\n"
        ".option norvc\n"
        ".balign 4\n"
        ".word 0x01F01013\n"
        ".word 0x00100073\n"
        ".word 0x40705013\n"
        ".option pop\n"
        : "+r"(a0), "+r"(a1)
        :
        : "memory"
    );
    return a0;
}

void jv_putc(char c)
{
    (void)jv_semihost_call(JV_SEMIHOST_SYS_WRITEC, (uintptr_t)(uint8_t)c);
}

int jv_write(int fd, const char *buf, int len)
{
    volatile uint32_t args[3];

    if (len <= 0)
        return 0;
    args[0] = (uint32_t)fd;
    args[1] = (uint32_t)(uintptr_t)buf;
    args[2] = (uint32_t)len;
    uint32_t not_written = jv_semihost_call(JV_SEMIHOST_SYS_WRITE, (uintptr_t)args);
    return len - (int)not_written;
}

void jv_exit(int code)
{
    volatile uint32_t args[2];

    args[0] = JV_SEMIHOST_ADP_STOPPED_APP_EXIT;
    args[1] = (uint32_t)code;
    (void)jv_semihost_call(JV_SEMIHOST_SYS_EXIT_EXTENDED, (uintptr_t)args);

    /* Should not be reached: the simulator/debugger handles EXIT.
     * Spin here to keep the CPU busy (safe for all environments). */
    while (1) {
        __asm__ volatile ("nop");
    }
}