/*
 * Common test definitions for RIOT OS on JV32
 */

#ifndef TESTCOMMON_RIOT_JV32_H
#define TESTCOMMON_RIOT_JV32_H

#include <stdint.h>
#include "jv_platform.h"

/* Console I/O helpers (RIOT printf goes through _write → jv_putc). */
static inline void console_putc(char c)  { jv_putc(c); }
static inline void console_puts(const char *s)
{
    while (*s) console_putc(*s++);
}

/* Exit simulation */
static inline void exit_sim(int code)   { jv_exit(code); }

#endif /* TESTCOMMON_RIOT_JV32_H */
