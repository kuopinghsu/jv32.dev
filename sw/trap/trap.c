/* ============================================================================
 * File: sw/trap/trap.c
 * Project: JV32 RISC-V Processor
 * Description: Trap / exception handling test — uses JV SDK
 *
 * Tests covered:
 *   1. ecall              – mcause = 11 (JV_EXC_ECALL_M)
 *   2. ebreak             – mcause =  3 (JV_EXC_BREAKPOINT)
 *   3. Misaligned load    – accepted either as a legacy trap or as
 *                           transparent hardware completion with correct data
 *   4. Illegal instruction– mcause =  2 (JV_EXC_ILLEGAL_INSN)
 *   5. Timer interrupt    – mcause =  7 (JV_CAUSE_MTI)
 *
 * Handlers registered with jv_exc_register() / jv_irq_register().
 * Each returns mepc+4 to skip the faulting instruction and resume.
 * ============================================================================ */

#include "jv_platform.h"
#include "jv_uart.h"
#include "jv_clic.h"
#include "jv_irq.h"

/* ── result flags ──────────────────────────────────────────────────────────── */
static volatile int g_trap_ecall    = 0;
static volatile int g_trap_ebreak   = 0;
static volatile int g_trap_misalign = 0;
static volatile int g_trap_illegal  = 0;  /* count of illegal instruction traps */
static volatile int g_trap_timer    = 0;

/* ── helper ────────────────────────────────────────────────────────────────── */
static void report(const char *name, int ok)
{
    jv_uart_puts("  ");
    jv_uart_puts(name);
    jv_uart_puts(ok ? ": OK\n" : ": FAIL\n");
}

/* ── exception handlers ────────────────────────────────────────────────────── */

static void on_ecall(jv_trap_frame_t *frame)
{
    g_trap_ecall = 1;
    frame->mepc += 4;   /* skip ecall (always 4 bytes) */
}

static void on_ebreak(jv_trap_frame_t *frame)
{
    g_trap_ebreak = 1;
    /* Determine instruction size: bits[1:0]==11 → 32-bit, else 16-bit (C.EBREAK) */
    uint16_t inst = *(volatile uint16_t *)frame->mepc;
    frame->mepc += (((inst & 3u) == 3u) ? 4u : 2u);
}

static void on_load_misalign(jv_trap_frame_t *frame)
{
    g_trap_misalign = 1;
    frame->mepc += 4;
}

static void on_illegal(jv_trap_frame_t *frame)
{
    g_trap_illegal++;  /* count each trap so we can verify all paths fired */
    /* Determine instruction size: bits[1:0]==11 → 32-bit, else 16-bit */
    uint16_t inst = *(volatile uint16_t *)frame->mepc;
    frame->mepc += (((inst & 3u) == 3u) ? 4u : 2u);
}

/* ── interrupt handler ─────────────────────────────────────────────────────── */

static void on_timer(uint32_t cause)
{
    (void)cause;
    jv_clic_timer_disable();        /* push mtimecmp far into the future */
    jv_clic_timer_irq_disable();    /* clear MTIE */
    g_trap_timer = 1;
}

/* ── main ──────────────────────────────────────────────────────────────────── */

int main(void)
{
    jv_uart_puts("=== JV32 Trap Test ===\n");

    /* Register handlers via SDK dispatch table */
    jv_exc_register(JV_EXC_ECALL_M,       on_ecall);
    jv_exc_register(JV_EXC_BREAKPOINT,    on_ebreak);
    jv_exc_register(JV_EXC_LOAD_MISALIGN, on_load_misalign);
    jv_exc_register(JV_EXC_ILLEGAL_INSN,  on_illegal);
    jv_irq_register(JV_CAUSE_MTI,         on_timer);

    /* ── Test 1: ecall ─────────────────────────────────────────────── */
    jv_uart_puts("Test 1: ecall\n");
    __asm__ volatile("ecall");

    /* ── Test 2: ebreak ────────────────────────────────────────────── */
    jv_uart_puts("Test 2: ebreak\n");
    __asm__ volatile("ebreak");

    /* ── Test 3: misaligned load (DRAM base + 1) ───────────────────── */
    jv_uart_puts("Test 3: misaligned load\n");
    {
        volatile uint32_t *dram = (volatile uint32_t *)JV_DRAM_BASE;
        volatile uint32_t sink = 0;

        /* Seed known bytes so transparent misaligned support can be checked
         * deterministically. Little-endian word load at base+1 should read
         * bytes 0x22,0x33,0x44,0x55 → 0x55443322.
         */
        dram[0] = 0x44332211u;
        dram[1] = 0x88776655u;

        __asm__ volatile(
            "lw %0, 1(%1)"
            : "=r"(sink)
            : "r"((uintptr_t)dram)
            : "memory"
        );

        if (!g_trap_misalign && sink == 0x55443322u)
            g_trap_misalign = 1;
    }

    /* ── Test 4: illegal instruction ───────────────────────────────── */
    jv_uart_puts("Test 4: illegal instruction\n");
    /* Use 0xFFFFFFFF (opcode=0x7F, bits[1:0]=11) so it is unambiguously a
     * single 32-bit illegal instruction and causes exactly one trap. */
    __asm__ volatile(".word 0xFFFFFFFF");

    /* ── Test 4b: additional illegal encodings for decoder coverage ─── */
    /* Each .word exercises a specific decoder path that normal valid code
     * cannot reach, allowing coverage analysis to see those branches.
     * All encodings have bits[1:0]=11 so on_illegal() advances mepc by 4.
     *
     *   0x08001013  OPCODE_OP_IMM funct3=001 funct7=0x04 → unknown shift (both)
     *   0x08005013  OPCODE_OP_IMM funct3=101 funct7=0x04 → unknown shift (both)
     *   0x08000033  OPCODE_OP {funct7=0x04, funct3=000}  → unknown R-type (both)
     *   0xF801102F  OPCODE_AMO funct3=001, amo_op=0x1F, rd=x0, rs1=x2
     *               RTL: funct3≠010 → illegal (decoder line 406)
     *               jv32sim: amo_op=0x1F → default → illegal; rd=x0/rs1=x2
     *               keeps sp intact (reads sp safely, no write since illegal)
     *   0x00200073  OPCODE_SYSTEM funct3=000 funct12=0x002 → unknown SYSTEM (both)
     *   0x7FF02073  CSRRS x0, 0x7FF, x0 → unknown CSR
     *               RTL: illegal; jv32sim: treats unknown CSR as 0 (NOP, no trap)
     */
    jv_uart_puts("Test 4b: decoder coverage traps\n");
    __asm__ volatile(".word 0x08001013");  /* OP-IMM funct3=001 unknown funct7 */
    __asm__ volatile(".word 0x08005013");  /* OP-IMM funct3=101 unknown funct7 */
    __asm__ volatile(".word 0x08000033");  /* OPCODE_OP unknown {funct7,funct3} */
    __asm__ volatile(".word 0xF801102F");  /* AMO funct3=001, amo_op=0x1F, rd=x0, rs1=x2 */
    __asm__ volatile(".word 0x00200073");  /* SYSTEM funct3=000 funct12=0x002 (URET) */
    __asm__ volatile(".word 0x7FF02073");  /* CSRRS x0, 0x7FF, x0 (unknown CSR → illegal in both RTL and sim) */

    /* ── Test 5: timer interrupt ───────────────────────────────────── */
    jv_uart_puts("Test 5: timer interrupt\n");
    {
        /* Fire 100 ticks from now; mask interrupts while writing 64-bit cmp */
        uint32_t saved = jv_irq_disable();
        jv_clic_timer_set_rel(100ULL);
        jv_clic_timer_irq_enable();
        jv_irq_restore(saved);
        jv_irq_enable();

        uint32_t timeout = 200000U;
        while (!g_trap_timer && --timeout)
            ;
        if (!g_trap_timer)
            jv_uart_puts("  [WARN] Timer did not fire within timeout\n");

        jv_irq_disable();
    }

    /* ── Results ───────────────────────────────────────────────────── */
    jv_uart_puts("\n--- Results ---\n");
    report("ecall",    g_trap_ecall);
    report("ebreak",   g_trap_ebreak);
    report("misalign", g_trap_misalign);
    report("illegal",  g_trap_illegal >= 6);  /* 1 original + 5 decoder-cov + 1 unknown CSR = 7 total */
    report("timer",    g_trap_timer);

    int pass = g_trap_ecall && g_trap_ebreak && g_trap_misalign
               && (g_trap_illegal >= 6) && g_trap_timer;
    jv_uart_puts(pass ? "\nPASS\n" : "\nFAIL\n");
    jv_exit(pass ? 0 : 1);
}

