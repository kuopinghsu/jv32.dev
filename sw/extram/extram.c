/* ============================================================================
 * File: sw/extram/extram.c
 * Project: JV32 RISC-V Processor
 * Description: External AXI RAM access test (simulation only)
 *
 * Tests int/short/char signed & unsigned read/write, sign/zero extension,
 * read-modify-write, sequential fill, .text.ext/.rodata.ext/.data.ext and
 * high-address accesses in the 2 MB external AXI RAM at 0xA0000000.
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
 * Mutable data in external RAM (.data.ext)
 * ------------------------------------------------------------------------- */
__attribute__((section(".data.ext")))
static volatile uint32_t extram_buf[16];

/* -------------------------------------------------------------------------
 * Helpers
 * ------------------------------------------------------------------------- */
static int g_pass = 1;
static int g_section_fails = 0;

static void check(const char *name, uint32_t got, uint32_t expected)
{
    if (got != expected) {
        jv_uart_puts("  FAIL: ");
        jv_uart_puts(name);
        jv_uart_puts("  got=");
        jv_uart_puthex32(got);
        jv_uart_puts("  exp=");
        jv_uart_puthex32(expected);
        jv_uart_puts("\n");
        g_pass = 0;
        g_section_fails++;
    }
}

static void section(const char *name)
{
    g_section_fails = 0;
    jv_uart_puts("  ");
    jv_uart_puts(name);
    jv_uart_puts(" ... ");
}

static void section_done(void)
{
    if (g_section_fails == 0)
        jv_uart_puts("ok\n");
}

/* -------------------------------------------------------------------------
 * Main
 * ------------------------------------------------------------------------- */
int main(void)
{
    jv_uart_puts("extram test start\n");

    /* Use a scratch area at +0x100000 to avoid stomping .text.ext/.data.ext */
#define SCRATCH  (JV_EXTRAM_BASE + 0x100000u)

    volatile uint8_t   *pu8;
    volatile uint16_t  *pu16;
    volatile uint32_t  *pu32;
    volatile int8_t    *ps8;
    volatile int16_t   *ps16;
    volatile int32_t   *ps32;

    /* ==================================================================
     * 1. uint32_t (int) word R/W — 16 sequential words
     * ================================================================== */
    section("1. uint32 word R/W");
    pu32 = (volatile uint32_t *)(uintptr_t)SCRATCH;
    for (uint32_t i = 0; i < 16; i++)
        pu32[i] = 0xA0000000u + i;
    for (uint32_t i = 0; i < 16; i++)
        check("word", pu32[i], 0xA0000000u + i);
    section_done();

    /* ==================================================================
     * 2. uint8_t (unsigned char) byte R/W — byte lanes + word readback
     * ================================================================== */
    section("2. uint8 byte R/W");
    pu8 = (volatile uint8_t *)(uintptr_t)(SCRATCH + 0x40u);
    pu8[0] = 0x11u;
    pu8[1] = 0x22u;
    pu8[2] = 0x33u;
    pu8[3] = 0x44u;
    check("byte[0]", pu8[0], 0x11u);
    check("byte[1]", pu8[1], 0x22u);
    check("byte[2]", pu8[2], 0x33u);
    check("byte[3]", pu8[3], 0x44u);
    check("word-after-bytes",
          *(volatile uint32_t *)(uintptr_t)(SCRATCH + 0x40u), 0x44332211u);
    section_done();

    /* ==================================================================
     * 3. uint16_t (unsigned short) halfword R/W
     * ================================================================== */
    section("3. uint16 halfword R/W");
    pu16 = (volatile uint16_t *)(uintptr_t)(SCRATCH + 0x50u);
    pu16[0] = 0xAAAAu;
    pu16[1] = 0xBBBBu;
    pu16[2] = 0x1234u;
    pu16[3] = 0x5678u;
    check("hw[0]", pu16[0], 0xAAAAu);
    check("hw[1]", pu16[1], 0xBBBBu);
    check("hw[2]", pu16[2], 0x1234u);
    check("hw[3]", pu16[3], 0x5678u);
    /* word readback of two consecutive halfwords */
    check("word-after-hw", *(volatile uint32_t *)(uintptr_t)(SCRATCH + 0x50u),
          0xBBBBAAAAu);
    section_done();

    /* ==================================================================
     * 4. int8_t (signed char) R/W — LB sign extension
     * ================================================================== */
    section("4. int8 signed char R/W (LB)");
    ps8 = (volatile int8_t *)(uintptr_t)(SCRATCH + 0x60u);
    *ps8 = (int8_t)-1;
    check("int8 -1",   (uint32_t)*ps8, (uint32_t)(int32_t)(int8_t)-1);   /* 0xFFFFFFFF */
    *ps8 = (int8_t)-128;
    check("int8 -128", (uint32_t)*ps8, (uint32_t)(int32_t)(int8_t)-128); /* 0xFFFFFF80 */
    *ps8 = (int8_t)127;
    check("int8  127", (uint32_t)*ps8, 0x0000007Fu);
    *ps8 = (int8_t)0;
    check("int8   0",  (uint32_t)*ps8, 0x00000000u);
    section_done();

    /* ==================================================================
     * 5. int16_t (signed short) R/W — LH sign extension
     * ================================================================== */
    section("5. int16 signed short R/W (LH)");
    ps16 = (volatile int16_t *)(uintptr_t)(SCRATCH + 0x70u);
    *ps16 = (int16_t)-1;
    check("int16 -1",     (uint32_t)*ps16, (uint32_t)(int32_t)(int16_t)-1);    /* 0xFFFFFFFF */
    *ps16 = (int16_t)-32768;
    check("int16 -32768", (uint32_t)*ps16, (uint32_t)(int32_t)(int16_t)-32768);/* 0xFFFF8000 */
    *ps16 = (int16_t)32767;
    check("int16  32767", (uint32_t)*ps16, 0x00007FFFu);
    *ps16 = (int16_t)0;
    check("int16   0",    (uint32_t)*ps16, 0x00000000u);
    section_done();

    /* ==================================================================
     * 6. int32_t (signed int) R/W
     * ================================================================== */
    section("6. int32 signed int R/W");
    ps32 = (volatile int32_t *)(uintptr_t)(SCRATCH + 0x80u);
    *ps32 = (int32_t)-1;
    check("int32 -1",        (uint32_t)*ps32, 0xFFFFFFFFu);
    *ps32 = (int32_t)(-2147483647 - 1); /* INT32_MIN */
    check("int32 INT32_MIN", (uint32_t)*ps32, 0x80000000u);
    *ps32 = (int32_t)2147483647;        /* INT32_MAX */
    check("int32 INT32_MAX", (uint32_t)*ps32, 0x7FFFFFFFu);
    *ps32 = (int32_t)0;
    check("int32 0",         (uint32_t)*ps32, 0x00000000u);
    section_done();

    /* ==================================================================
     * 7. LBU / LHU zero-extension vs LB / LH sign-extension
     *    Write 0xFF byte and 0xFFFF halfword; verify the two load
     *    variants produce different results for the same memory content.
     * ================================================================== */
    section("7. sign vs zero extension (LB/LBU, LH/LHU)");
    /* byte: write 0xFF */
    pu8  = (volatile uint8_t *)(uintptr_t)(SCRATCH + 0x90u);
    ps8  = (volatile  int8_t *)(uintptr_t)(SCRATCH + 0x90u);
    *pu8 = 0xFFu;
    check("LBU 0xFF (zero-ext)", (uint32_t)*pu8,  0x000000FFu);
    check("LB  0xFF (sign-ext)", (uint32_t)*ps8,  0xFFFFFFFFu);
    *pu8 = 0x7Fu;
    check("LBU 0x7F",            (uint32_t)*pu8,  0x0000007Fu);
    check("LB  0x7F",            (uint32_t)*ps8,  0x0000007Fu);
    /* halfword: write 0xFFFF */
    pu16 = (volatile uint16_t *)(uintptr_t)(SCRATCH + 0x98u);
    ps16 = (volatile  int16_t *)(uintptr_t)(SCRATCH + 0x98u);
    *pu16 = 0xFFFFu;
    check("LHU 0xFFFF (zero-ext)", (uint32_t)*pu16, 0x0000FFFFu);
    check("LH  0xFFFF (sign-ext)", (uint32_t)*ps16, 0xFFFFFFFFu);
    *pu16 = 0x7FFFu;
    check("LHU 0x7FFF",            (uint32_t)*pu16, 0x00007FFFu);
    check("LH  0x7FFF",            (uint32_t)*ps16, 0x00007FFFu);
    section_done();

    /* ==================================================================
     * 8. Read-Modify-Write — write word, overwrite individual bytes,
     *    verify the full word is updated correctly
     * ================================================================== */
    section("8. read-modify-write (byte into word)");
    pu32 = (volatile uint32_t *)(uintptr_t)(SCRATCH + 0xA0u);
    pu8  = (volatile  uint8_t *)(uintptr_t)(SCRATCH + 0xA0u);
    *pu32 = 0x00000000u;
    pu8[0] = 0xAAu;                          /* update byte 0 only */
    check("rmw byte0", *pu32, 0x000000AAu);
    pu8[3] = 0xBBu;                          /* update byte 3 only */
    check("rmw byte3", *pu32, 0xBB0000AAu);
    pu8[1] = 0xCCu;
    pu8[2] = 0xDDu;
    check("rmw all",   *pu32, 0xBBDDCCAAu);
    /* halfword update */
    pu16 = (volatile uint16_t *)(uintptr_t)(SCRATCH + 0xA4u);
    *pu32 = (volatile uint32_t)0u; pu32++;   /* advance base for clean test */
    pu32--;
    *(volatile uint32_t *)(uintptr_t)(SCRATCH + 0xA4u) = 0x00000000u;
    pu16[0] = 0x1234u;
    check("rmw hw0", *(volatile uint32_t *)(uintptr_t)(SCRATCH + 0xA4u), 0x00001234u);
    pu16[1] = 0x5678u;
    check("rmw hw1", *(volatile uint32_t *)(uintptr_t)(SCRATCH + 0xA4u), 0x56781234u);
    section_done();

    /* ==================================================================
     * 9. Sequential fill — 256 words with incrementing pattern, then
     *    verify all, then overwrite with inverted pattern and verify again
     * ================================================================== */
    section("9. sequential fill (256 words)");
    pu32 = (volatile uint32_t *)(uintptr_t)(SCRATCH + 0x200u);
    for (uint32_t i = 0; i < 256u; i++)
        pu32[i] = 0xA5000000u | i;
    for (uint32_t i = 0; i < 256u; i++)
        check("fill", pu32[i], 0xA5000000u | i);
    for (uint32_t i = 0; i < 256u; i++)
        pu32[i] = ~(0xA5000000u | i);
    for (uint32_t i = 0; i < 256u; i++)
        check("fill-inv", pu32[i], ~(0xA5000000u | i));
    section_done();

    /* ==================================================================
     * 10. .data.ext mutable array (placed in extram by linker)
     * ================================================================== */
    section("10. .data.ext array");
    for (uint32_t i = 0; i < 16u; i++)
        extram_buf[i] = i * 0x10101010u;
    for (uint32_t i = 0; i < 16u; i++)
        check("data.ext", extram_buf[i], i * 0x10101010u);
    section_done();

    /* ==================================================================
     * 11. .rodata.ext constant table (placed in extram by linker)
     * ================================================================== */
    section("11. .rodata.ext constants");
    check("magic[0]", extram_magic[0], 0xDEADBEEFu);
    check("magic[1]", extram_magic[1], 0xCAFEBABEu);
    check("magic[2]", extram_magic[2], 0x12345678u);
    check("magic[3]", extram_magic[3], 0xA5A5A5A5u);
    section_done();

    /* ==================================================================
     * 12. .text.ext function call (code executing from extram)
     * ================================================================== */
    section("12. .text.ext function call");
    check("extram_add", extram_add(0xDEAD0000u, 0x0000BEEFu), 0xDEADBEEFu);
    check("extram_add overflow",
          extram_add(0xFFFFFFFFu, 0x00000001u), 0x00000000u);
    section_done();

    /* ==================================================================
     * 13. High-address access (near end of 2 MB window)
     * ================================================================== */
    section("13. high-address word access");
    pu32 = (volatile uint32_t *)(uintptr_t)(JV_EXTRAM_BASE + JV_EXTRAM_SIZE - 0x10u);
    pu32[0] = 0x5A5A5A5Au;
    pu32[1] = 0xA5A5A5A5u;
    pu32[2] = 0x12345678u;
    check("hi[0]", pu32[0], 0x5A5A5A5Au);
    check("hi[1]", pu32[1], 0xA5A5A5A5u);
    check("hi[2]", pu32[2], 0x12345678u);
    section_done();

    /* ==================================================================
     * Result
     * ================================================================== */
    if (g_pass) {
        jv_uart_puts("PASS\n");
        jv_exit(0);
    } else {
        jv_uart_puts("FAIL\n");
        jv_exit(1);
    }
}
