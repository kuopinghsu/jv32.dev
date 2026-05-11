// ============================================================================
// File: jv_io_semihost.c
// Project: JV32 RISC-V Processor
// Description: Semihosting backend for jv_putc()/jv_exit(), with magic fallback.
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
    uint32_t rc = jv_semihost_call(JV_SEMIHOST_SYS_WRITEC,
                                   (uintptr_t)(uint8_t)c);
    if (rc != 0u) {
        jv_putc_raw(c);
    }
}

void jv_exit(int code)
{
    volatile uint32_t args[2];

    args[0] = JV_SEMIHOST_ADP_STOPPED_APP_EXIT;
    args[1] = (uint32_t)code;
    (void)jv_semihost_call(JV_SEMIHOST_SYS_EXIT_EXTENDED, (uintptr_t)args);
    jv_exit_raw(code);
    __builtin_unreachable();
}