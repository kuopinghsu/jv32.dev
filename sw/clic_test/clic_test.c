// ============================================================================
// File        : sw/clic_test/clic_test.c
// Project     : JV32 RISC-V Processor
// Description : Comprehensive CLIC / CLINT test covering:
//               1. Software interrupt (MSI) — MSIP register
//               2. Timer interrupt   (MTI) — mtime / mtimecmp
//               3. UART IRQ via CLIC external line 0 (standard MEI path)
//               4. CLIC interrupt level field — mintstatus.MIL tracking
//               5. mintthresh filtering — blocks IRQs below threshold
//               6. Fast vectored dispatch — mtvt table, per-line entry point
//
// SoC wiring (rtl/jv32_soc.sv):
//   UART irq output  →  ext_irq_i[0] | uart_irq  →  CLICINT[0]
//
// CLIC arbiter (rtl/axi/axi_clic.sv):
//   clic_irq_o asserted when any CLICINT[n].ie && ext_irq_i[n] is set.
//   Winner = highest clicint_ctl[n]; clic_level_o / clic_id_o carry the result.
//
// Core interrupt priority (rtl/jv32/core/jv32_csr.sv):
//   CLIC path  : clic_irq && clic_level > mintthresh && mstatus.MIE
//                → irq_pc = mtvt + clic_id * 4  (direct vectored dispatch)
//   CLINT path : mip & mie & mstatus.MIE  (timer / software interrupts)
//                → irq_pc via mtvec
//
// UART IS register (rtl/axi/axi_uart.sv):
//   IS is LEVEL-triggered (read-only); it reflects !rxf_empty / txf_empty.
//   The interrupt deasserts when the RX FIFO is drained via jv_uart_getc().
//   jv_uart_irq_status() captures the status snapshot; the W1C write is a no-op
//   on this hardware but is kept for API completeness.
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
#define UART_IRQ_LINE   0u          // UART is ORed into ext_irq_i[0] (jv32_soc.sv)
#define TIMER_PERIOD    5000u       // MTI period in clock cycles
#define WAIT_CYCLES     2000000u    // NOP-loop safety timeout

// ── CLIC CSR helpers (mtvt / mintstatus not yet in csr.h) ────────────────────
// CSR 0x307 = mtvt   — CLIC vector-table base (bits [5:0] masked to 0 by HW)
// CSR 0xFB1 = mintstatus — [31:24] = MIL (current interrupt level)
static inline uint32_t csr_read_mtvt(void)
{
    uint32_t v;
    asm volatile("csrr %0, 0x307" : "=r"(v));
    return v;
}
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

// ── Pass/fail accounting ──────────────────────────────────────────────────────
static int g_pass = 0;
static int g_fail = 0;

static void check(const char *tag, int ok)
{
    printf("  %-57s %s\n", tag, ok ? "PASS" : "FAIL");
    if (ok) g_pass++;
    else    g_fail++;
}

// ── Drain the UART RX FIFO (prevent stale bytes from polluting later tests) ──
static void uart_drain(void)
{
    while (jv_uart_rx_ready())
        (void)jv_uart_getc();
    (void)jv_uart_irq_status();
}

// ── Wait until *cnt >= target or timeout ──────────────────────────────────────
static int wait_for_count(volatile uint32_t *cnt, uint32_t target)
{
    uint32_t t = 0;
    while (*cnt < target && t < WAIT_CYCLES) {
        t++;
        asm volatile("nop");
    }
    return (*cnt >= target);
}

// ── UART loopback test setup / teardown ───────────────────────────────────────
// Enable loopback, UART RX IE, and CLICINT[0] IE only during the test body so
// that printf output never causes spurious RX interrupts.
static void uart_setup(uint8_t level)
{
    uart_drain();
    JV_UART_CTRL |= JV_UART_CTRL_LOOPBACK;
    jv_uart_irq_enable(JV_UART_IE_RX_READY);
    jv_clic_ext_irq_set_level(UART_IRQ_LINE, level);
    jv_clic_ext_irq_enable(UART_IRQ_LINE);
}

static void uart_teardown(void)
{
    jv_clic_ext_irq_disable(UART_IRQ_LINE);
    jv_uart_irq_disable(JV_UART_IE_RX_READY);
    JV_UART_CTRL &= ~JV_UART_CTRL_LOOPBACK;
    uart_drain();
}

// =============================================================================
// Test 1: Software Interrupt (MSI)
// =============================================================================
static volatile uint32_t msi_count = 0;

static void msi_handler(uint32_t cause)
{
    (void)cause;
    jv_clic_msip_clear();   // must clear MSIP before returning
    msi_count++;
}

// =============================================================================
// Test 2: Timer Interrupt (MTI)
// =============================================================================
static volatile uint32_t mti_count = 0;

static void mti_handler(uint32_t cause)
{
    (void)cause;
    jv_clic_timer_disable();  // prevent repeated firing
    mti_count++;
}

// =============================================================================
// Tests 3–5: Standard MEI handler (dispatched via jv_irq_dispatch)
// =============================================================================
static volatile uint32_t mei_count       = 0;
static volatile char     mei_rx_char     = '\0';
static volatile uint32_t mei_mintstatus  = 0;   // captured inside handler

static void mei_handler(uint32_t cause)
{
    (void)cause;
    // Capture mintstatus.MIL before doing anything else.
    // The hardware sets mintstatus.MIL = clic_level when the interrupt is
    // accepted.  This value is reset to 0 on mret, so we must read it now.
    mei_mintstatus = csr_read_mintstatus();

    // Reading the UART IS snapshot (level-triggered; write-back is a no-op).
    (void)jv_uart_irq_status();

    // Drain one byte from the RX FIFO.  This is what actually deasserts
    // uart_irq (is_wire[0] = !rxf_empty transitions to 0).
    int c = jv_uart_getc();
    if (c >= 0)
        mei_rx_char = (char)c;

    mei_count++;
}

// =============================================================================
// Test 6: Fast vectored ISR (entered directly from mtvt; NOT via trap_entry)
//
// __attribute__((interrupt("machine"))) instructs GCC to:
//   - save all caller-saved registers in the prologue
//   - end the function with mret (not ret)
// The function is entered by hardware after the CPU jumps to mtvt + id * 4.
// The hardware has already saved mstatus.MPIE/MIE, mepc, and updated mcause
// before the jump, so the C function runs with a clean interrupt context.
// =============================================================================
static volatile uint32_t fast_count   = 0;
static volatile char     fast_rx_char = '\0';

__attribute__((interrupt("machine"), noinline, used))
static void clic_fast_uart_isr(void)
{
    (void)jv_uart_irq_status();      // snapshot IS (clears nothing on HW)
    int c = jv_uart_getc();          // drain RX FIFO → deasserts uart_irq
    if (c >= 0)
        fast_rx_char = (char)c;
    fast_count++;
}

// ── CLIC vector table ─────────────────────────────────────────────────────────
// When mtvt is programmed to this table's address, the hardware jumps to
// mtvt + clic_id * 4 as CODE on every CLIC-sourced MEI.
//
// Requirements:
//   • The table must be 64-byte aligned (mtvt CSR zeroes bits [5:0]).
//   • Each entry must be exactly 4 bytes → use .option norvc to force 32-bit
//     JAL instructions (uncompressed), guaranteeing 4-byte slot widths.
//   • 16 entries × 4 bytes = 64 bytes total.
//
// Slot 0 → CLICINT[0] (UART): jump to clic_fast_uart_isr (the fast ISR).
// Slots 1–15 → redirect to startup.S trap_entry (standard dispatch fallback).
// =============================================================================
extern void trap_entry(void);   // startup.S standard trap-entry / register save

__attribute__((naked, aligned(64), used))
static void clic_vector_table(void)
{
    asm volatile(
        ".option push\n"
        ".option norvc\n"                  /* force 32-bit JAL (4 bytes each) */
        "j clic_fast_uart_isr\n"           /* slot  0 — CLICINT[0]: UART      */
        "j trap_entry\n"                   /* slot  1 — unused (default)      */
        "j trap_entry\n"                   /* slot  2                         */
        "j trap_entry\n"                   /* slot  3                         */
        "j trap_entry\n"                   /* slot  4                         */
        "j trap_entry\n"                   /* slot  5                         */
        "j trap_entry\n"                   /* slot  6                         */
        "j trap_entry\n"                   /* slot  7                         */
        "j trap_entry\n"                   /* slot  8                         */
        "j trap_entry\n"                   /* slot  9                         */
        "j trap_entry\n"                   /* slot 10                         */
        "j trap_entry\n"                   /* slot 11                         */
        "j trap_entry\n"                   /* slot 12                         */
        "j trap_entry\n"                   /* slot 13                         */
        "j trap_entry\n"                   /* slot 14                         */
        "j trap_entry\n"                   /* slot 15                         */
        ".option pop\n"
        ::: "memory"
    );
}

// =============================================================================
// main
// =============================================================================
int main(void)
{
    printf("============================================================\n");
    printf("  CLIC Comprehensive Test\n");
    printf("  UART → CLICINT[0]  |  mtvt fast vectored dispatch\n");
    printf("============================================================\n\n");

    // ── Test 1: Software Interrupt (MSI) ────────────────────────────────────
    printf("[Test 1] Software Interrupt (MSI)\n");

    jv_irq_register(JV_CAUSE_MSI, msi_handler);
    jv_clic_msip_irq_enable();
    jv_irq_enable();
    jv_clic_msip_set();             // trigger MSIP = 1
    (void)wait_for_count(&msi_count, 1);
    jv_irq_disable();
    jv_clic_msip_irq_disable();

    printf("  msi_count = %lu\n", (unsigned long)msi_count);
    check("[1]  MSI handler fired exactly once", msi_count == 1);
    printf("\n");

    // ── Test 2: Timer Interrupt (MTI) ───────────────────────────────────────
    printf("[Test 2] Timer Interrupt (MTI)\n");

    jv_irq_register(JV_CAUSE_MTI, mti_handler);
    jv_clic_timer_set_rel(TIMER_PERIOD);
    jv_clic_timer_irq_enable();
    jv_irq_enable();
    (void)wait_for_count(&mti_count, 1);
    jv_irq_disable();
    jv_clic_timer_disable();
    jv_clic_timer_irq_disable();

    printf("  mti_count = %lu\n", (unsigned long)mti_count);
    check("[2]  MTI handler fired exactly once", mti_count == 1);
    printf("\n");

    // ── Test 3: UART IRQ via CLIC (MEI, standard path, level = 0x80) ────────
    printf("[Test 3] UART IRQ via CLIC external line %u (MEI, level=0x80)\n",
           UART_IRQ_LINE);

    jv_irq_register(JV_CAUSE_MEI, mei_handler);
    write_csr_mintthresh(0x00);     // allow all CLIC levels
    uart_setup(0x80);               // loopback on, UART IE, CLICINT[0] IE
    jv_irq_enable();
    jv_uart_putc('A');              // TX → loopback → RX FIFO → uart_irq → MEI
    (void)wait_for_count(&mei_count, 1);
    jv_irq_disable();
    uart_teardown();

    printf("  mei_count   = %lu (expected 1)\n",  (unsigned long)mei_count);
    printf("  mei_rx_char = '%c'  (expected 'A')\n", mei_rx_char);
    check("[3a] MEI handler fired once",            mei_count == 1);
    check("[3b] Correct byte received ('A')",       mei_rx_char == 'A');
    printf("\n");

    // ── Test 4: CLIC level field — mintstatus.MIL tracks accepted level ──────
    printf("[Test 4] CLIC level field — mintstatus.MIL tracks accepted level\n");
    // Change CTL to 0x60 to verify the hardware accurately reports the level.

    uint32_t count_before = mei_count;
    write_csr_mintthresh(0x00);
    uart_setup(0x60);
    jv_irq_enable();
    jv_uart_putc('B');
    (void)wait_for_count(&mei_count, count_before + 1);
    jv_irq_disable();
    uart_teardown();

    uint32_t mil = (mei_mintstatus >> 24) & 0xFFu;  // mintstatus[31:24] = MIL
    printf("  mintstatus.MIL = 0x%02lx (expected 0x60)\n", (unsigned long)mil);
    printf("  mei_rx_char    = '%c'  (expected 'B')\n", mei_rx_char);
    check("[4a] MEI fired (level = 0x60)",           mei_count == count_before + 1);
    check("[4b] mintstatus.MIL == 0x60",             mil == 0x60u);
    check("[4c] Correct byte received ('B')",        mei_rx_char == 'B');
    printf("\n");

    // ── Test 5: mintthresh filtering ─────────────────────────────────────────
    printf("[Test 5] mintthresh filtering (CLICINT[0] level=0x40, threshold=0x80)\n");

    // Part A — interrupt BLOCKED: level 0x40 is NOT > mintthresh 0x80
    count_before = mei_count;
    write_csr_mintthresh(0x80);
    uart_setup(0x40);
    jv_irq_enable();
    jv_uart_putc('C');              // CLICINT[0].ip set, but gated by mintthresh

    // Spin long enough for UART serialization + a generous margin.
    // Handler must NOT run while mintthresh = 0x80 blocks level 0x40.
    for (uint32_t i = 0; i < 50000u; i++)
        asm volatile("nop");
    jv_irq_disable();

    int blocked = (mei_count == count_before);
    int ip_set  = jv_clic_ext_irq_pending(UART_IRQ_LINE);
    printf("  mintthresh=0x80, level=0x40:\n");
    printf("    handler fired:     %s (expected: NO)\n",  blocked ? "NO" : "YES");
    printf("    CLICINT[0].ip:     %s (expected: YES)\n", ip_set  ? "YES" : "NO");
    check("[5a] IRQ blocked  (level 0x40 <= mintthresh 0x80)", blocked);
    check("[5b] CLICINT[0].ip set  (IRQ pending in CLIC)",     ip_set);

    // Part B — lower threshold to 0x00: pending IRQ fires immediately
    count_before = mei_count;
    write_csr_mintthresh(0x00);
    jv_irq_enable();                // pending CLIC IRQ fires at next WB cycle
    (void)wait_for_count(&mei_count, count_before + 1);
    jv_irq_disable();
    uart_teardown();
    write_csr_mintthresh(0x00);     // ensure threshold remains 0 going forward

    printf("  mintthresh lowered to 0x00 → pending IRQ fires:\n");
    printf("    mei_rx_char = '%c' (expected 'C')\n", mei_rx_char);
    check("[5c] IRQ fires after mintthresh lowered",     mei_count == count_before + 1);
    check("[5d] Pending byte received ('C')",            mei_rx_char == 'C');
    printf("\n");

    // ── Test 6: Fast vectored dispatch via mtvt ───────────────────────────────
    printf("[Test 6] Fast vectored dispatch via mtvt (CLIC-mode ISR)\n");
    //
    // When mtvt is programmed, a CLIC MEI bypasses trap_entry entirely and
    // jumps to  mtvt + clic_id * 4  (slot 0 = clic_fast_uart_isr for UART).
    // clic_fast_uart_isr uses __attribute__((interrupt("machine"))) to generate
    // proper register save / restore and ends with mret.
    //
    uint32_t mei_before = mei_count;    // standard handler must NOT be called
    uint32_t vt_addr = (uint32_t)(uintptr_t)clic_vector_table;
    printf("  clic_vector_table @ 0x%08lx\n", (unsigned long)vt_addr);

    csr_write_mtvt(vt_addr);        // arm the CLIC vector table
    write_csr_mintthresh(0x00);
    uart_setup(0x80);               // level 0x80 > mintthresh 0x00 → fires
    jv_irq_enable();
    jv_uart_putc('D');              // TX → loopback → RX FIFO → slot 0 ISR
    (void)wait_for_count(&fast_count, 1);
    jv_irq_disable();
    uart_teardown();
    csr_write_mtvt(0);              // restore: back to standard mtvec dispatch

    printf("  fast_count   = %lu (expected 1)\n",   (unsigned long)fast_count);
    printf("  fast_rx_char = '%c'  (expected 'D')\n", fast_rx_char);
    check("[6a] Fast ISR (mtvt slot 0) executed",          fast_count == 1);
    check("[6b] Fast ISR received correct byte ('D')",     fast_rx_char == 'D');
    check("[6c] Standard MEI handler NOT called (mtvt bypasses trap_entry)",
          mei_count == mei_before);
    printf("\n");

    // ── Summary ───────────────────────────────────────────────────────────────
    int total = g_pass + g_fail;
    printf("============================================================\n");
    printf("  %d / %d checks PASSED\n", g_pass, total);
    printf("============================================================\n");

    jv_exit(g_fail == 0 ? 0 : 1);
    return 0;
}
