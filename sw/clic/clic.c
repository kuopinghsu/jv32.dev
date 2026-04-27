// ============================================================================
// File        : sw/clic/clic.c
// Project     : JV32 RISC-V Processor
// Description : Comprehensive CLIC / CLINT test
//
//   Test 1  Software interrupt       (MSI — CLINT path)
//   Test 2  Timer interrupt          (MTI — CLINT path)
//   Test 3  UART IRQ via CLIC        (MEI, standard vectored dispatch)
//   Test 4  CLIC level field         (mintstatus.MIL tracks accepted level)
//   Test 5  mintthresh filtering     (blocks IRQs below threshold)
//   Test 6  CLIC Tail-chaining       (2 bytes → 2 handlers, 1 interrupt entry)
//   Test 7  Fast vectored dispatch   (mtvt slot 0 → clic_fast_isr, no trap_entry)
//
// ── SoC wiring (rtl/jv32_soc.sv) ──────────────────────────────────────────
//   UART irq output  →  ext_irq_i[0] | uart_irq  →  CLICINT[0]
//   assign external_irq = clic_irq;          ← IMPORTANT: see note below
//
// ── CRITICAL: mtvt must be set before any CLIC external interrupt fires ─────
//   jv32_csr.sv: when clic_irq fires, irq_pc = mtvt + clic_id * 4.
//   jv32_soc.sv: external_irq = clic_irq, so mip[11] = clic_irq.
//   If mtvt = 0 (reset value), irq_pc = 0x0000_0000 → instruction-access fault.
//   We therefore set mtvt to clic_std_table at the TOP of main() before
//   enabling any CLIC external interrupt or global MIE.
//
// ── Tail-chain (rtl/jv32/core/jv32_csr.sv) ────────────────────────────────
//   assign tail_chain_o = mret && clic_irq && (clic_level > mintthresh_reg);
//   When tail_chain_o is asserted the CPU jumps to tail_chain_pc (= mtvt +
//   clic_id*4) instead of returning to the preempted user code.  mepc is
//   preserved unchanged so the final mret in the chain restores the original PC.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Kuoping Hsu
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include "csr.h"
#include "jv_platform.h"
#include "jv_clic.h"
#include "jv_irq.h"
#include "jv_uart.h"

// ── Configuration ─────────────────────────────────────────────────────────────
#define UART_IRQ_LINE  0u       // UART ORed into ext_irq_i[0] in jv32_soc.sv
#define TIMER_PERIOD   5000u    // MTI period in clock cycles

// Spin-loop safety limits.
// IRQ_LIMIT  : for interrupts that fire within a handful of cycles (MSI, MTI,
//              and CLIC with bytes already in the RX FIFO).
// UART_LIMIT : UART loopback byte arrives after ~6944 cycles at 115200 baud /
//              80 MHz clock.  500000 gives a comfortable margin at CPI≈2.
#define IRQ_LIMIT   20000u
#define UART_LIMIT  500000u

// ── CLIC-specific CSR helpers ──────────────────────────────────────────────────
// mtvt  (0x307) — CLIC vector-table base; hw zeroes bits[5:0] on write.
// mintstatus (0xFB1) — [31:24]=MIL (current active interrupt level).
static inline void csr_write_mtvt(uint32_t v)
{
    asm volatile("csrw 0x307, %0" :: "r"(v));
}
static inline uint32_t csr_read_mintstatus(void)
{
    uint32_t v;
    asm volatile("csrr %0, 0xFB1" : "=r"(v));
    return v;
}

// ── Pass / fail accounting ────────────────────────────────────────────────────
static int g_pass, g_fail;

static void check(const char *tag, int ok)
{
    printf("  %-57s %s\n", tag, ok ? "PASS" : "FAIL");
    if (ok) g_pass++;
    else    g_fail++;
}

// ── Bounded spin: wait until *cnt >= target or limit iterations ───────────────
// The "memory" clobber prevents the compiler from hoisting *cnt out of the loop.
static int wait_cnt(volatile uint32_t *cnt, uint32_t target, uint32_t limit)
{
    for (uint32_t t = 0; *cnt < target && t < limit; t++)
        asm volatile("nop" ::: "memory");
    return (*cnt >= target);
}

// ── UART helpers ──────────────────────────────────────────────────────────────
static void uart_drain(void)
{
    for (uint32_t t = 0; jv_uart_rx_ready() && t < 1024u; t++)
        (void)jv_uart_getc();
    (void)jv_uart_irq_status();   /* clear IS snapshot */
}

// Enable UART loopback + UART RX IE + CLICINT[0] with the given CTL level.
// Call uart_loopback_off() to tear down when done.
static void uart_loopback_on(uint8_t level)
{
    uart_drain();
    JV_UART_CTRL |= JV_UART_CTRL_LOOPBACK;
    jv_uart_irq_enable(JV_UART_IE_RX_READY);
    jv_clic_ext_irq_set_level(UART_IRQ_LINE, level);
    jv_clic_ext_irq_enable(UART_IRQ_LINE);
}

static void uart_loopback_off(void)
{
    jv_clic_ext_irq_disable(UART_IRQ_LINE);
    jv_uart_irq_disable(JV_UART_IE_RX_READY);
    JV_UART_CTRL &= ~JV_UART_CTRL_LOOPBACK;
    uart_drain();
}

// =============================================================================
// CLIC vector tables
//
// The JV32 CLIC vectored dispatch (jv32_csr.sv):
//   irq_pc = mtvt_reg + {clic_id, 2'b00}
//
// Each table entry is exactly 4 bytes (.option norvc forces 32-bit JAL).
// 16 entries × 4 bytes = 64 bytes total → aligned(64) places the table at a
// 64-byte boundary so mtvt CSR (which zeroes bits[5:0]) can address it exactly.
//
// Two tables are used:
//   clic_std_table  — all 16 slots jump to trap_entry (standard dispatch)
//                     used for Tests 3–6
//   clic_fast_table — slot 0 jumps to clic_fast_isr  (fast ISR, Test 7)
//                     slots 1–15 jump to trap_entry
// =============================================================================
extern void trap_entry(void);   // defined in common/startup.S

__attribute__((naked, aligned(64), used))
static void clic_std_table(void)
{
    asm volatile(
        ".option push\n\t"
        ".option norvc\n\t"         /* force 4-byte JAL for exact 4-byte slots */
        "j trap_entry\n\t"          /* slot  0 — CLICINT[0]: UART              */
        "j trap_entry\n\t"          /* slot  1                                  */
        "j trap_entry\n\t"          /* slot  2                                  */
        "j trap_entry\n\t"          /* slot  3                                  */
        "j trap_entry\n\t"          /* slot  4                                  */
        "j trap_entry\n\t"          /* slot  5                                  */
        "j trap_entry\n\t"          /* slot  6                                  */
        "j trap_entry\n\t"          /* slot  7                                  */
        "j trap_entry\n\t"          /* slot  8                                  */
        "j trap_entry\n\t"          /* slot  9                                  */
        "j trap_entry\n\t"          /* slot 10                                  */
        "j trap_entry\n\t"          /* slot 11                                  */
        "j trap_entry\n\t"          /* slot 12                                  */
        "j trap_entry\n\t"          /* slot 13                                  */
        "j trap_entry\n\t"          /* slot 14                                  */
        "j trap_entry\n\t"          /* slot 15                                  */
        ".option pop\n\t"
        ::: "memory"
    );
}

// =============================================================================
// Test 1 — Machine Software Interrupt (MSI, CLINT path)
// =============================================================================
static volatile uint32_t msi_count;

static void msi_handler(uint32_t cause)
{
    (void)cause;
    jv_clic_msip_clear();   /* must clear MSIP before returning */
    msi_count++;
}

// =============================================================================
// Test 2 — Machine Timer Interrupt (MTI, CLINT path)
// =============================================================================
static volatile uint32_t mti_count;

static void mti_handler(uint32_t cause)
{
    (void)cause;
    jv_clic_timer_disable();   /* disarm to prevent re-fire */
    mti_count++;
}

// =============================================================================
// Tests 3–5 — Machine External Interrupt (MEI, CLIC path)
//
// When clic_irq fires the CPU jumps to clic_std_table[clic_id] = j trap_entry,
// which saves context and calls jv_irq_dispatch(frame), which calls this handler
// with cause = JV_CAUSE_MEI = 11.
// =============================================================================
static volatile uint32_t mei_count;
static volatile uint8_t  mei_rx;
static volatile uint8_t  mei_mil;   /* mintstatus.MIL captured in handler */

static void mei_handler(uint32_t cause)
{
    (void)cause;
    /* mintstatus[31:24] = MIL (current interrupt level); read before draining */
    mei_mil = (uint8_t)((csr_read_mintstatus() >> 24) & 0xFFu);
    (void)jv_uart_irq_status();     /* IS snapshot (level-triggered, no W1C effect) */
    int c = jv_uart_getc();         /* drain one byte → deasserts uart_irq          */
    if (c >= 0) mei_rx = (uint8_t)c;
    mei_count++;
}

// =============================================================================
// Test 6 — CLIC Tail-chain handler
//
// Drains EXACTLY ONE byte per invocation.  If the RX FIFO still contains data
// after this handler's mret, uart_irq stays high, clic_irq stays high, and the
// hardware fires tail_chain_o = 1:
//   jv32_csr.sv: assign tail_chain_o = mret && clic_irq && (clic_level > mintthresh)
// The CPU then jumps to tail_chain_pc = mtvt + clic_id*4 (clic_std_table[0])
// instead of returning to user code, running this handler again for the next byte.
// =============================================================================
static volatile uint32_t chain_count;
static volatile char     chain_rx[2];

static void chain_handler(uint32_t cause)
{
    (void)cause;
    int c = jv_uart_getc();     /* drain exactly ONE byte */
    if (c >= 0 && chain_count < 2u)
        chain_rx[chain_count] = (char)c;
    chain_count++;
    /* Intentionally do NOT drain further bytes: leaving data in the RX FIFO
     * keeps uart_irq asserted so the hardware tail-chains on mret.          */
}

// =============================================================================
// Test 7 — Fast vectored ISR (entered directly via mtvt; bypasses trap_entry)
//
// __attribute__((interrupt("machine"))) instructs GCC to:
//   • Generate a prologue that saves all caller-saved regs (and any others used)
//   • Terminate the function with mret instead of ret
// The CPU jumps here directly from mtvt + clic_id*4 (clic_fast_table slot 0).
// trap_entry's full save/restore is completely bypassed.
// =============================================================================
static volatile uint32_t fast_count;
static volatile char     fast_rx;

__attribute__((interrupt("machine"), noinline, used))
static void clic_fast_isr(void)
{
    (void)jv_uart_irq_status();
    int c = jv_uart_getc();
    if (c >= 0) fast_rx = (char)c;
    fast_count++;
}

// Fast-dispatch table: slot 0 → clic_fast_isr, slots 1–15 → trap_entry.
// clic_fast_isr must be defined before this table in the translation unit.
__attribute__((naked, aligned(64), used))
static void clic_fast_table(void)
{
    asm volatile(
        ".option push\n\t"
        ".option norvc\n\t"
        "j clic_fast_isr\n\t"       /* slot  0 — UART fast ISR                 */
        "j trap_entry\n\t"          /* slot  1 – 15 fallback                   */
        "j trap_entry\n\t"
        "j trap_entry\n\t"
        "j trap_entry\n\t"
        "j trap_entry\n\t"
        "j trap_entry\n\t"
        "j trap_entry\n\t"
        "j trap_entry\n\t"
        "j trap_entry\n\t"
        "j trap_entry\n\t"
        "j trap_entry\n\t"
        "j trap_entry\n\t"
        "j trap_entry\n\t"
        "j trap_entry\n\t"
        "j trap_entry\n\t"
        ".option pop\n\t"
        ::: "memory"
    );
}

// =============================================================================
// main
// =============================================================================
int main(void)
{
    // ── Global CLIC setup ──────────────────────────────────────────────────
    // MUST be done before enabling any CLIC interrupt or global MIE.
    // jv32_soc.sv:  external_irq = clic_irq
    // jv32_csr.sv:  when clic_irq fires, irq_pc = mtvt + clic_id * 4
    // Without a valid mtvt the CPU would jump to 0x0 → instruction-access fault.
    csr_write_mtvt((uint32_t)(uintptr_t)clic_std_table);
    write_csr_mintthresh(0x00u);    /* accept all CLIC levels initially */

    printf("============================================================\n");
    printf("  CLIC Comprehensive Test\n");
    printf("  UART → CLICINT[0]  |  tail-chain + fast vectored dispatch\n");
    printf("============================================================\n\n");

    // ── Test 1: Software Interrupt (MSI) ──────────────────────────────────
    printf("[Test 1] Software Interrupt (MSI)\n");
    {
        jv_irq_register(JV_CAUSE_MSI, msi_handler);
        jv_clic_msip_irq_enable();
        jv_clic_msip_set();             /* MSIP = 1 while MIE=0: no interrupt yet */
        jv_irq_enable();                /* csrrsi mstatus,8 → MSI fires here (safe re-exec) */
        wait_cnt(&msi_count, 1, IRQ_LIMIT);
        jv_irq_disable();
        jv_clic_msip_irq_disable();

        printf("  msi_count = %lu\n", (unsigned long)msi_count);
        check("[1]  MSI handler fired exactly once", msi_count == 1u);
    }
    printf("\n");

    // ── Test 2: Timer Interrupt (MTI) ─────────────────────────────────────
    printf("[Test 2] Timer Interrupt (MTI)\n");
    {
        jv_irq_register(JV_CAUSE_MTI, mti_handler);
        jv_clic_timer_set_rel(TIMER_PERIOD);
        jv_clic_timer_irq_enable();
        jv_irq_enable();
        wait_cnt(&mti_count, 1, TIMER_PERIOD * 4u);
        jv_irq_disable();
        jv_clic_timer_disable();
        jv_clic_timer_irq_disable();

        printf("  mti_count = %lu\n", (unsigned long)mti_count);
        check("[2]  MTI handler fired exactly once", mti_count == 1u);
    }
    printf("\n");

    // ── Test 3: UART IRQ via CLIC external line 0 (level = 0x80) ──────────
    printf("[Test 3] UART IRQ via CLIC external line %u (MEI, level=0x80)\n",
           UART_IRQ_LINE);
    {
        jv_irq_register(JV_CAUSE_MEI, mei_handler);
        uart_loopback_on(0x80);
        jv_irq_enable();
        jv_uart_putc('A');
        wait_cnt(&mei_count, 1, UART_LIMIT);
        jv_irq_disable();
        uart_loopback_off();

        printf("  mei_count   = %lu  (expected 1)\n",  (unsigned long)mei_count);
        printf("  mei_rx      = '%c'  (expected 'A')\n", mei_rx);
        check("[3a] MEI handler fired once",   mei_count == 1u);
        check("[3b] Correct byte 'A' received", mei_rx == 'A');
    }
    printf("\n");

    // ── Test 4: CLIC level field — mintstatus.MIL tracks accepted level ───
    printf("[Test 4] CLIC level field (mintstatus.MIL, level=0x60)\n");
    {
        uint32_t before = mei_count;
        uart_loopback_on(0x60);
        jv_irq_enable();
        jv_uart_putc('B');
        wait_cnt(&mei_count, before + 1u, UART_LIMIT);
        jv_irq_disable();
        uart_loopback_off();

        printf("  mintstatus.MIL = 0x%02x  (expected 0x60)\n", (unsigned)mei_mil);
        printf("  mei_rx         = '%c'     (expected 'B')\n",  mei_rx);
        check("[4a] MEI fired (level=0x60)",    mei_count == before + 1u);
        check("[4b] mintstatus.MIL == 0x60",    mei_mil == 0x60u);
        check("[4c] Correct byte 'B' received", mei_rx == 'B');
    }
    printf("\n");

    // ── Test 5: mintthresh filtering ──────────────────────────────────────
    printf("[Test 5] mintthresh filtering (CLICINT[0] level=0x40, threshold=0x80)\n");
    {
        uint32_t before = mei_count;

        /* Part A — IRQ blocked: level 0x40 is NOT > mintthresh 0x80 */
        write_csr_mintthresh(0x80u);
        uart_loopback_on(0x40);
        jv_irq_enable();
        jv_uart_putc('C');
        /* Spin long enough for the UART byte to arrive in RX FIFO but NOT    *
         * enough for the (blocked) interrupt to fire.  50 000 iterations ≈   *
         * 100 000 cycles >> 8680 cycles (one UART byte at 115200 / 100 MHz). */
        for (uint32_t t = 0; t < 50000u; t++)
            asm volatile("nop" ::: "memory");
        jv_irq_disable();

        int blocked = (mei_count == before);
        int ip_set  = jv_clic_ext_irq_pending(UART_IRQ_LINE);
        printf("  mintthresh=0x80, level=0x40:\n");
        printf("    IRQ fired:     %s  (expected NO)\n",  blocked ? "NO" : "YES");
        printf("    CLICINT[0].ip: %s  (expected YES)\n", ip_set  ? "YES" : "NO");
        check("[5a] IRQ blocked (level 0x40 <= mintthresh 0x80)", blocked);
        check("[5b] CLICINT[0].ip set (IRQ pending in CLIC)",      ip_set);

        /* Part B — lower threshold → pending IRQ fires immediately */
        before = mei_count;
        write_csr_mintthresh(0x00u);
        jv_irq_enable();
        wait_cnt(&mei_count, before + 1u, IRQ_LIMIT);
        jv_irq_disable();
        uart_loopback_off();

        printf("  mintthresh=0x00 → pending IRQ fires:\n");
        printf("    mei_rx = '%c'  (expected 'C')\n", mei_rx);
        check("[5c] IRQ fires after mintthresh lowered",   mei_count == before + 1u);
        check("[5d] Pending byte 'C' received",            mei_rx == 'C');
    }
    printf("\n");

    // ── Test 6: CLIC Tail-chaining ────────────────────────────────────────
    printf("[Test 6] CLIC Tail-chaining (2 bytes → 1 interrupt entry → 2 handlers)\n");
    //
    // Tail-chain sequence:
    //   1. Both bytes sent to UART TX FIFO; loopback copies them to RX FIFO.
    //   2. Wait until RX FIFO holds 2 bytes (JV_UART_LEVEL[15:0] >= 2).
    //   3. Enable CLICINT[0].ie → clic_irq immediately high.
    //   4. Enable MIE → interrupt fires: chain_handler drains byte 0 ('E').
    //   5. mret: RX FIFO still has byte 1 ('F'), uart_irq = 1, clic_irq = 1.
    //      tail_chain_o = mret && clic_irq && clic_level(0x80) > mintthresh(0) = 1.
    //      Hardware jumps to tail_chain_pc = clic_std_table[0] = j trap_entry.
    //   6. chain_handler drains byte 1 ('F'), chain_count = 2.
    //   7. mret: RX empty, clic_irq = 0, tail_chain_o = 0 → return to user code.
    //
    // The user code was only interrupted ONCE (steps 4–7 appear atomic to it).
    {
        chain_count = 0;
        chain_rx[0] = chain_rx[1] = '\0';

        jv_irq_register(JV_CAUSE_MEI, chain_handler);

        /* Enable loopback + UART IE but do NOT enable CLICINT yet so that
         * the interrupt cannot fire while the bytes are still in transit.  */
        uart_drain();
        JV_UART_CTRL |= JV_UART_CTRL_LOOPBACK;
        jv_uart_irq_enable(JV_UART_IE_RX_READY);
        jv_clic_ext_irq_set_level(UART_IRQ_LINE, 0x80u);

        /* Send both bytes through the loopback path.
         * Use direct DATA writes here to avoid STATUS polling jitter between
         * RTL and ISS in the pre-arm setup path.                           */
        JV_UART_DATA = (uint32_t)'E';
        JV_UART_DATA = (uint32_t)'F';

        /* Fixed settle: UART_TX_SETTLE nops run identically in ISS (instant
         * loopback) and RTL (serial, ~80 cycles/byte at SIM_CLKS_PER_BIT=8).
         * 300 nops > 2 bytes x 80 RTL cycles / CPI guarantees both bytes are
         * in the RX FIFO before CLICINT is armed, with deterministic traces. */
        for (uint32_t t = 300u; t > 0u; t--)
            asm volatile("nop" ::: "memory");

        printf("  RX FIFO count before arm = %lu  (expected 2)\n",
               (unsigned long)(JV_UART_LEVEL & 0xFFFFu));

        /* Arm CLICINT[0]: clic_irq immediately asserts (bytes are pending). */
        jv_clic_ext_irq_enable(UART_IRQ_LINE);

        /* Enable MIE: first interrupt fires; tail-chain fires on first mret. *
         * Both handlers complete before execution returns here.              */
        jv_irq_enable();
        wait_cnt(&chain_count, 2u, IRQ_LIMIT);
        jv_irq_disable();

        jv_clic_ext_irq_disable(UART_IRQ_LINE);
        jv_uart_irq_disable(JV_UART_IE_RX_READY);
        JV_UART_CTRL &= ~JV_UART_CTRL_LOOPBACK;
        uart_drain();

        printf("  chain_count  = %lu  (expected 2: two tail-chained invocations)\n",
               (unsigned long)chain_count);
        printf("  chain_rx[0]  = '%c'  (expected 'E' — first  handler)\n", chain_rx[0]);
        printf("  chain_rx[1]  = '%c'  (expected 'F' — tail-chained handler)\n",
               chain_rx[1]);
        check("[6a] chain_count == 2 (two handlers via tail-chain)",  chain_count == 2u);
        check("[6b] First  byte 'E' — initial interrupt",             chain_rx[0] == 'E');
        check("[6c] Second byte 'F' — delivered by tail-chain",       chain_rx[1] == 'F');

        /* Restore standard MEI handler for Test 7 */
        jv_irq_register(JV_CAUSE_MEI, mei_handler);
    }
    printf("\n");

    // ── Test 7: Fast vectored dispatch via mtvt ───────────────────────────
    printf("[Test 7] Fast vectored dispatch via mtvt (clic_fast_isr)\n");
    //
    // Switch mtvt to clic_fast_table where slot 0 jumps directly to
    // clic_fast_isr.  The GCC interrupt("machine") attribute gives clic_fast_isr
    // its own prologue/epilogue with mret; trap_entry is completely bypassed.
    // Verify by checking that mei_count (incremented only by mei_handler, which
    // is only reachable through trap_entry → jv_irq_dispatch) did not change.
    {
        uint32_t mei_before = mei_count;
        uint32_t vt = (uint32_t)(uintptr_t)clic_fast_table;
        printf("  clic_fast_table @ 0x%08lx\n", (unsigned long)vt);

        csr_write_mtvt(vt);
        uart_loopback_on(0x80u);
        jv_irq_enable();
        jv_uart_putc('D');
        wait_cnt(&fast_count, 1u, UART_LIMIT);
        jv_irq_disable();
        uart_loopback_off();

        csr_write_mtvt((uint32_t)(uintptr_t)clic_std_table);   /* restore */

        printf("  fast_count = %lu  (expected 1)\n",   (unsigned long)fast_count);
        printf("  fast_rx    = '%c'  (expected 'D')\n", fast_rx);
        check("[7a] Fast ISR (mtvt slot 0) executed",           fast_count == 1u);
        check("[7b] Fast ISR received correct byte 'D'",        fast_rx == 'D');
        check("[7c] Standard MEI handler NOT called (mtvt bypasses trap_entry)",
              mei_count == mei_before);
    }
    printf("\n");

    // ── Summary ───────────────────────────────────────────────────────────────
    int total = g_pass + g_fail;
    printf("============================================================\n");
    printf("  %d / %d checks PASSED\n", g_pass, total);
    printf("============================================================\n");

    jv_exit(g_fail == 0 ? 0 : 1);
    return 0;
}
