// ============================================================================
// File: jv_io_magic.c
// Project: JV32 RISC-V Processor
// Description: Magic-device backend for jv_putc()/jv_exit().
// ============================================================================

#include "jv_platform.h"

void jv_putc(char c)
{
    jv_putc_raw(c);
}

void jv_exit(int code)
{
    jv_exit_raw(code);
    __builtin_unreachable();
}