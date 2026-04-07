/* ============================================================================
 * File: sw/tests/trap_test.c
 * Project: JV32 RISC-V Processor
 * Description: Trap / exception handling test for JV32
 *
 * Tests covered:
 *   1. ecall  – M-mode environment call (mcause = 11)
 *   2. ebreak – breakpoint exception  (mcause = 3)
 *   3. Misaligned load  (mcause = 4)
 *   4. Illegal instruction (mcause = 2)
 *   5. Timer interrupt (mcause = 0x8000_0007) via CLINT in axi_clic
 *
 * On each expected exception the trap handler below sets a flag and
 * advances mepc past the faulting instruction so execution continues.
 * At the end all expected_traps flags are checked and PASS/FAIL printed.
 * ============================================================================ */

#include <stdint.h>

/* Peripheral base addresses */
#define UART_BASE    0x20010000U
#define MAGIC_BASE   0x40000000U
#define CLIC_BASE    0x02000000U   /* axi_clic */

/* UART register offsets */
#define UART_TX_REG     0x00
#define UART_STATUS_REG 0x08

/* axi_clic CLINT-compatible offsets */
#define CLIC_MTIME_LO    0x4000U
#define CLIC_MTIME_HI    0x4004U
#define CLIC_MTIMECMP_LO 0x4008U
#define CLIC_MTIMECMP_HI 0x400CU

#define UART_REG(off)   (*((volatile uint32_t *)(UART_BASE  + (off))))
#define MAGIC_REG(off)  (*((volatile uint32_t *)(MAGIC_BASE + (off))))
#define CLIC_REG(off)   (*((volatile uint32_t *)(CLIC_BASE  + (off))))

/* ------------------------------------------------------------------ */
/* Trap flags: set by handle_trap when expected cause seen            */
/* ------------------------------------------------------------------ */
static volatile int g_trap_ecall   = 0;
static volatile int g_trap_ebreak  = 0;
static volatile int g_trap_misalign= 0;
static volatile int g_trap_illegal = 0;
static volatile int g_trap_timer   = 0;

/* Last trap info (for diagnostics) */
static volatile uint32_t g_last_mcause = 0;
static volatile uint32_t g_last_mepc   = 0;
static volatile uint32_t g_last_mtval  = 0;

/* ------------------------------------------------------------------ */
/* UART helpers                                                        */
/* ------------------------------------------------------------------ */
static inline void uart_putc(char c)
{
    while (UART_REG(UART_STATUS_REG) & 0x1U);
    UART_REG(UART_TX_REG) = (uint32_t)(unsigned char)c;
}

static void uart_puts(const char *s) { while (*s) uart_putc(*s++); }

static void uart_puthex32(uint32_t v)
{
    const char *h = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4) uart_putc(h[(v >> i) & 0xF]);
}

static void uart_putok(const char *name, int ok)
{
    uart_puts("  ");
    uart_puts(name);
    uart_puts(": ");
    uart_puts(ok ? "OK" : "FAIL");
    uart_puts("\n");
}

/* ------------------------------------------------------------------ */
/* handle_trap: override startup.S weak default                       */
/* startup.S calls: a0 = handle_trap(mcause, mepc, mtval)            */
/* return 0 = use mepc unchanged; return X = set mepc = X            */
/* ------------------------------------------------------------------ */
uint32_t handle_trap(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    g_last_mcause = mcause;
    g_last_mepc   = mepc;
    g_last_mtval  = mtval;

    /* Timer interrupt: mcause[31]=1, cause=7 */
    if (mcause & 0x80000000U) {
        if ((mcause & 0x7FFFFFFFU) == 7U) {
            /* Disable timer by setting mtimecmp very far in future */
            CLIC_REG(CLIC_MTIMECMP_LO) = 0xFFFFFFFFU;
            CLIC_REG(CLIC_MTIMECMP_HI) = 0xFFFFFFFFU;
            g_trap_timer = 1;
        }
        return 0; /* return to interrupted PC (mret returns to mepc) */
    }

    switch (mcause) {
        case 2:  /* Illegal instruction */
            g_trap_illegal = 1;
            return mepc + 4;  /* skip 4-byte illegal insn (NOP fill) */

        case 3:  /* ebreak / breakpoint */
            g_trap_ebreak = 1;
            return mepc + 4;  /* skip ebreak */

        case 4:  /* Load address misaligned */
        case 6:  /* Store address misaligned */
            g_trap_misalign = 1;
            return mepc + 4;  /* skip faulting load/store */

        case 11: /* Environment call (M-mode ecall) */
            g_trap_ecall = 1;
            return mepc + 4;  /* skip ecall */

        default:
            uart_puts("\n[TRAP UNEXPECTED] mcause=");
            uart_puthex32(mcause);
            uart_puts(" mepc=");
            uart_puthex32(mepc);
            uart_puts("\n");
            MAGIC_REG(0) = 1U;  /* exit(1) */
            for (;;);
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* main                                                               */
/* ------------------------------------------------------------------ */
int main(void)
{
    uart_puts("=== JV32 Trap Test ===\n");

    /* ----------------------------------------------------------------
     * Test 1: ecall
     * -------------------------------------------------------------- */
    uart_puts("Test 1: ecall\n");
    __asm__ volatile ("ecall");
    /* handle_trap sets g_trap_ecall and advances mepc past ecall */

    /* ----------------------------------------------------------------
     * Test 2: ebreak
     * -------------------------------------------------------------- */
    uart_puts("Test 2: ebreak\n");
    __asm__ volatile ("ebreak");

    /* ----------------------------------------------------------------
     * Test 3: misaligned load (address 0xC000_0001 = DRAM+1)
     * -------------------------------------------------------------- */
    uart_puts("Test 3: misaligned load\n");
    {
        volatile uint32_t scratch = 0;
        volatile uint8_t *p = (volatile uint8_t *)0xC0000001U;
        /* Cast to uint32_t* to force a 4-byte misaligned load */
        volatile uint32_t *mp = (volatile uint32_t *)p;
        scratch = *mp;
        (void)scratch;
    }

    /* ----------------------------------------------------------------
     * Test 4: illegal instruction (encoding 0x00000000 is illegal)
     * -------------------------------------------------------------- */
    uart_puts("Test 4: illegal instruction\n");
    __asm__ volatile (".word 0x00000000");  /* illegal on RV32 */

    /* ----------------------------------------------------------------
     * Test 5: timer interrupt
     * -------------------------------------------------------------- */
    uart_puts("Test 5: timer interrupt\n");
    {
        /* Set mtimecmp = mtime + 100 ticks */
        uint32_t lo = CLIC_REG(CLIC_MTIME_LO);
        uint32_t hi = CLIC_REG(CLIC_MTIME_HI);
        uint64_t now = ((uint64_t)hi << 32) | lo;
        uint64_t cmp = now + 100ULL;
        /* Disable interrupts while writing 64-bit compare */
        __asm__ volatile ("csrci mstatus, 8");  /* clear MIE */
        CLIC_REG(CLIC_MTIMECMP_HI) = 0xFFFFFFFFU;  /* prevent spurious */
        CLIC_REG(CLIC_MTIMECMP_LO) = (uint32_t)(cmp & 0xFFFFFFFFU);
        CLIC_REG(CLIC_MTIMECMP_HI) = (uint32_t)(cmp >> 32);
        /* Enable timer interrupt in mie */
        __asm__ volatile ("csrsi mie, 0x80");   /* MTIE = bit 7 */
        __asm__ volatile ("csrsi mstatus, 8");  /* MIE = bit 3 */

        /* Spin and wait for timer to fire */
        uint32_t timeout = 100000U;
        while (!g_trap_timer && --timeout)
            ;
        if (!g_trap_timer) {
            uart_puts("  [WARN] Timer did not fire within timeout\n");
        }
        /* Disable interrupts again */
        __asm__ volatile ("csrci mstatus, 8");
        __asm__ volatile ("csrci mie, 0x80");
    }

    /* ----------------------------------------------------------------
     * Report results
     * -------------------------------------------------------------- */
    uart_puts("\n--- Results ---\n");
    uart_putok("ecall",    g_trap_ecall);
    uart_putok("ebreak",   g_trap_ebreak);
    uart_putok("misalign", g_trap_misalign);
    uart_putok("illegal",  g_trap_illegal);
    uart_putok("timer",    g_trap_timer);

    int pass = g_trap_ecall && g_trap_ebreak && g_trap_misalign
                && g_trap_illegal && g_trap_timer;
    uart_puts(pass ? "\nPASS\n" : "\nFAIL\n");

    return pass ? 0 : 1;
}
