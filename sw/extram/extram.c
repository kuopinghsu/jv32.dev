/* ============================================================================
 * File: sw/extram/extram.c
 * Project: JV32 RISC-V Processor
 * Description: External AXI RAM access test (simulation only)
 *
 * Tests word, halfword and byte read/write accesses to the external AXI RAM
 * at 0xA0000000.  A small code function and a constant table are placed in
 * .text.ext / .rodata.ext; a mutable array lives in .data.ext.
 * ============================================================================ */

#include <stdint.h>
#include "jv_platform.h"
#include "jv_uart.h"

/* -------------------------------------------------------------------------
 * Code in external RAM
 * ------------------------------------------------------------------------- */
__attribute__((section(".text.ext"), noinline))
static uint32_t extram_add(uint32_t a, uint32_t b)
{
    return a + b;
}

/* -------------------------------------------------------------------------
 * Read-only data in external RAM
 * ------------------------------------------------------------------------- */
__attribute__((section(".rodata.ext")))
static const uint32_t extram_magic[4] = {
    0xDEADBEEF, 0xCAFEBABE, 0x12345678, 0xA5A5A5A5
};

/* -------------------------------------------------------------------------
 * Mutable data in external RAM
 * ------------------------------------------------------------------------- */
__attribute__((section(".data.ext")))
static volatile uint32_t extram_buf[16];

/* -------------------------------------------------------------------------
 * Helper: PASS / FAIL reporting
 * ------------------------------------------------------------------------- */
static int g_pass = 1;

static void check(const char *name, uint32_t got, uint32_t expected)
{
    if (got != expected) {
        jv_uart_puts("FAIL: ");
        jv_uart_puts(name);
        jv_uart_puts("  got=");
        jv_uart_puthex32(got);
        jv_uart_puts("  exp=");
        jv_uart_puthex32(expected);
        jv_uart_puts("\n");
        g_pass = 0;
    }
}

/* -------------------------------------------------------------------------
 * Main
 * ------------------------------------------------------------------------- */
int main(void)
{
    volatile uint8_t  *p8;
    volatile uint16_t *p16;
    volatile uint32_t *p32;
    uint32_t val;

    jv_uart_puts("extram test start\n");

    /* ------------------------------------------------------------------ */
    /* 1. Raw word writes / reads via pointer — use 1 MB offset to avoid  */
    /*    overwriting .text.ext/.data.ext sections at the base             */
    /* ------------------------------------------------------------------ */
    p32 = (volatile uint32_t *)(uintptr_t)(JV_EXTRAM_BASE + 0x100000u);
    for (uint32_t i = 0; i < 16; i++) {
        p32[i] = 0xA0000000u + i;
    }
    for (uint32_t i = 0; i < 16; i++) {
        check("word-rw", p32[i], 0xA0000000u + i);
    }

    /* ------------------------------------------------------------------ */
    /* 2. Byte-lane writes / reads                                          */
    /* ------------------------------------------------------------------ */
    p8 = (volatile uint8_t *)(uintptr_t)(JV_EXTRAM_BASE + 0x100080u);
    p8[0] = 0x11;
    p8[1] = 0x22;
    p8[2] = 0x33;
    p8[3] = 0x44;
    check("byte[0]", p8[0], 0x11);
    check("byte[1]", p8[1], 0x22);
    check("byte[2]", p8[2], 0x33);
    check("byte[3]", p8[3], 0x44);
    /* Full word after byte writes */
    check("word-after-bytes", *(volatile uint32_t *)(uintptr_t)(JV_EXTRAM_BASE + 0x100080u), 0x44332211u);

    /* ------------------------------------------------------------------ */
    /* 3. Halfword-lane writes / reads                                     */
    /* ------------------------------------------------------------------ */
    p16 = (volatile uint16_t *)(uintptr_t)(JV_EXTRAM_BASE + 0x100090u);
    p16[0] = 0xAAAA;
    p16[1] = 0xBBBB;
    check("hw[0]", p16[0], 0xAAAA);
    check("hw[1]", p16[1], 0xBBBB);

    /* ------------------------------------------------------------------ */
    /* 4. .data.ext array: pre-initialised by ELF loader                  */
    /* ------------------------------------------------------------------ */
    for (uint32_t i = 0; i < 16; i++) {
        extram_buf[i] = i * 0x10101010u;
    }
    for (uint32_t i = 0; i < 16; i++) {
        check("data.ext", extram_buf[i], i * 0x10101010u);
    }

    /* ------------------------------------------------------------------ */
    /* 5. .rodata.ext constant table access                                */
    /* ------------------------------------------------------------------ */
    check("rodata.ext[0]", extram_magic[0], 0xDEADBEEFu);
    check("rodata.ext[1]", extram_magic[1], 0xCAFEBABEu);
    check("rodata.ext[2]", extram_magic[2], 0x12345678u);
    check("rodata.ext[3]", extram_magic[3], 0xA5A5A5A5u);

    /* ------------------------------------------------------------------ */
    /* 6. .text.ext function call                                          */
    /* ------------------------------------------------------------------ */
    val = extram_add(0xDEAD0000u, 0x0000BEEFu);
    check("text.ext fn", val, 0xDEADBEEFu);

    /* ------------------------------------------------------------------ */
    /* 7. High-address word access (near end of 2 MB region)             */
    /* ------------------------------------------------------------------ */
    p32 = (volatile uint32_t *)(uintptr_t)(JV_EXTRAM_BASE + JV_EXTRAM_SIZE - 0x1000);
    *p32 = 0x5A5A5A5Au;
    check("hi-extram", *p32, 0x5A5A5A5Au);

    /* ------------------------------------------------------------------ */
    /* Result                                                              */
    /* ------------------------------------------------------------------ */
    if (g_pass) {
        jv_uart_puts("PASS\n");
        jv_exit(0);
    } else {
        jv_uart_puts("FAIL\n");
        jv_exit(1);
    }
}
