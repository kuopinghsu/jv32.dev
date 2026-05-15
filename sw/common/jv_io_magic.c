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

int jv_write(int fd, const char *buf, int len)
{
    (void)fd;
    for (int i = 0; i < len; i++)
        jv_putc(buf[i]);
    return len;
}

void jv_exit(int code)
{
    jv_exit_raw(code);
    __builtin_unreachable();
}