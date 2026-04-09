// ============================================================================
// File: putc.c
// Project: KV32 RISC-V Processor
// Description: putc() stub for embedded systems: routes single character to stdout
// ============================================================================

#include <stdio.h>
#include <stdint.h>
#include "jv_platform.h"

#ifdef __cplusplus
extern "C" {
#endif

int putc(int c, FILE *stream) {
    (void)stream;
    jv_putc((char)c);
    return c;
}

int putchar(int c) {
    jv_putc((char)c);
    return c;
}

int fputc(int c, FILE *stream) {
    (void)stream;
    jv_putc((char)c);
    return c;
}

#ifdef __cplusplus
}
#endif
