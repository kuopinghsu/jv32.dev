/* ============================================================================
 * File: sw/tcm_alias/tcm_alias.c
 * Project: JV32 RISC-V Processor
 * Description: Verify TCM alias mapping:
 *   0x6000_0000 -> IRAM TCM
 *   0x7000_0000 -> DRAM TCM
 * ============================================================================ */

#include "jv_platform.h"
#include "jv_uart.h"
#include <stdint.h>

#define IRAM_BASE_PRIMARY 0x80000000u
#define IRAM_BASE_ALIAS   0x60000000u
#define DRAM_BASE_PRIMARY 0xC0000000u
#define DRAM_BASE_ALIAS   0x70000000u
#define TCM_SIZE_BYTES    (128u * 1024u)

static int check_equal(const char *name, uint32_t got, uint32_t exp)
{
    jv_uart_puts(name);
    if (got == exp) {
        jv_uart_puts(": OK\n");
        return 1;
    }

    jv_uart_puts(": FAIL got=");
    jv_uart_puthex32(got);
    jv_uart_puts(" exp=");
    jv_uart_puthex32(exp);
    jv_uart_puts("\n");
    return 0;
}

static int check_word_window(const char *name,
                             volatile uint32_t *primary,
                             volatile uint32_t *alias,
                             uint32_t seed,
                             int write_alias)
{
    int pass = 1;
    for (int i = 0; i < 16; i++) {
        uint32_t exp = seed ^ (0x9E3779B9u * (uint32_t)(i + 1));
        if (write_alias)
            alias[i] = exp;
        else
            primary[i] = exp;
    }

    for (int i = 0; i < 16; i++) {
        uint32_t exp = seed ^ (0x9E3779B9u * (uint32_t)(i + 1));
        uint32_t got = write_alias ? primary[i] : alias[i];
        if (got != exp) {
            jv_uart_puts(name);
            jv_uart_puts(": FAIL word[");
            jv_uart_putu32((uint32_t)i);
            jv_uart_puts("] got=");
            jv_uart_puthex32(got);
            jv_uart_puts(" exp=");
            jv_uart_puthex32(exp);
            jv_uart_puts("\n");
            pass = 0;
            break;
        }
    }

    if (pass) {
        jv_uart_puts(name);
        jv_uart_puts(": OK\n");
    }
    return pass;
}

static int check_mixed_width(const char *name,
                             volatile uint8_t *primary8,
                             volatile uint8_t *alias8)
{
    int pass = 1;
    volatile uint16_t *primary16 = (volatile uint16_t *)primary8;
    volatile uint16_t *alias16 = (volatile uint16_t *)alias8;
    volatile uint32_t *primary32 = (volatile uint32_t *)primary8;
    volatile uint32_t *alias32 = (volatile uint32_t *)alias8;

    alias32[0] = 0x01234567u;
    pass &= check_equal("mixed word a->p", primary32[0], 0x01234567u);

    primary8[1] = 0xABu;
    pass &= check_equal("mixed byte p->a", alias8[1], 0xABu);
    pass &= check_equal("mixed word check", alias32[0], 0x0123AB67u);

    alias16[2] = 0x55AAu;
    pass &= check_equal("mixed half a->p", primary16[2], 0x55AAu);
    pass &= check_equal("mixed word merge", primary32[1], 0x000055AAu);

    primary32[3] = 0x89ABCDEFu;
    pass &= check_equal("mixed word p->a", alias32[3], 0x89ABCDEFu);

    if (pass) {
        jv_uart_puts(name);
        jv_uart_puts(": OK\n");
    }
    return pass;
}

int main(void)
{
    jv_uart_puts("=== TCM Alias Mapping Test (Complex) ===\n");

    volatile uint32_t *iram_p = (volatile uint32_t *)(uintptr_t)(IRAM_BASE_PRIMARY + TCM_SIZE_BYTES - 256u);
    volatile uint32_t *iram_a = (volatile uint32_t *)(uintptr_t)(IRAM_BASE_ALIAS + TCM_SIZE_BYTES - 256u);
    volatile uint32_t *dram_p = (volatile uint32_t *)(uintptr_t)(DRAM_BASE_PRIMARY + TCM_SIZE_BYTES - 256u);
    volatile uint32_t *dram_a = (volatile uint32_t *)(uintptr_t)(DRAM_BASE_ALIAS + TCM_SIZE_BYTES - 256u);
    volatile uint8_t *iram_p8 = (volatile uint8_t *)(uintptr_t)(IRAM_BASE_PRIMARY + TCM_SIZE_BYTES - 64u);
    volatile uint8_t *iram_a8 = (volatile uint8_t *)(uintptr_t)(IRAM_BASE_ALIAS + TCM_SIZE_BYTES - 64u);
    volatile uint8_t *dram_p8 = (volatile uint8_t *)(uintptr_t)(DRAM_BASE_PRIMARY + TCM_SIZE_BYTES - 64u);
    volatile uint8_t *dram_a8 = (volatile uint8_t *)(uintptr_t)(DRAM_BASE_ALIAS + TCM_SIZE_BYTES - 64u);

    int pass = 1;

    jv_uart_puts("-- Basic coherence --\n");
    *iram_p = 0xA5A55A5Au;
    pass &= check_equal("IRAM read alias", *iram_a, 0xA5A55A5Au);

    *iram_a = 0x11223344u;
    pass &= check_equal("IRAM read primary", *iram_p, 0x11223344u);

    *dram_p = 0x55AA33CCu;
    pass &= check_equal("DRAM read alias", *dram_a, 0x55AA33CCu);

    *dram_a = 0xCAFEBABEu;
    pass &= check_equal("DRAM read primary", *dram_p, 0xCAFEBABEu);

    jv_uart_puts("-- Window pattern tests --\n");
    pass &= check_word_window("IRAM pattern alias->primary", iram_p, iram_a, 0x13579BDFu, 1);
    pass &= check_word_window("IRAM pattern primary->alias", iram_p, iram_a, 0x2468ACE0u, 0);
    pass &= check_word_window("DRAM pattern alias->primary", dram_p, dram_a, 0x0F1E2D3Cu, 1);
    pass &= check_word_window("DRAM pattern primary->alias", dram_p, dram_a, 0x4B5A6978u, 0);

    jv_uart_puts("-- Mixed width tests --\n");
    pass &= check_mixed_width("IRAM mixed", iram_p8, iram_a8);
    pass &= check_mixed_width("DRAM mixed", dram_p8, dram_a8);

    jv_uart_puts(pass ? "PASS\n" : "FAIL\n");
    jv_exit(pass ? 0 : 1);
}
