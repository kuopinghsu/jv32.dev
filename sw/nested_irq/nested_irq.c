// ============================================================================
// File: nested_irq.c
// Project: JV32 RISC-V Processor
// Description: Nested interrupt test using two axi_timer channels via PLIC.
//
// Test design:
//   Timer 0: period N = 5000 cycles, PLIC source 6 (KV_PLIC_SRC_TIMER0), priority 1
//   Timer 1: period N/5  = 1000 cycles, PLIC source 7 (KV_PLIC_SRC_TIMER1), priority 2
//
// Nesting mechanism — WFI-based (simulator-agnostic):
//   The timer0 ISR raises the PLIC threshold to 1 (blocking timer0 self-preemption but
//   allowing timer1 prio=2), re-enables MIE, then executes WFI.  The CPU suspends until
//   timer1 fires.  The nested timer1 ISR runs and returns; MRET wakes the CPU at the
//   instruction after WFI.  csrrci then atomically closes the nesting window.
//
//   Why WFI instead of a spin loop:
//     In RTL simulation each timer1 ISR takes ~380 cycles (AXI pipeline stalls for PLIC
//     claim/complete and timer register accesses).  With TIMER1_PERIOD=1000 this leaves
//     ~620 cycles of margin after the nested ISR completes and csrrci can commit before
//     the next timer1 fire — safe on all three simulators.
//     With TIMER1_PERIOD=400 the margin shrinks to ~20 cycles, which is not enough when
//     AXI stall counts vary, causing a cascade of nested traps that overflows the stack.
//
// Both TIMER0 and TIMER1 interrupts arrive as MEI (Machine External Interrupt,
// cause 11).  A single mei_handler dispatches based on the PLIC claim result.
//
// Timer 0 ISR path (lower-priority):
//   1. Claim PLIC → src 6; clear timer0 INT_STATUS; t0_entry_count++
//   2. Raise PLIC threshold to 1 (blocks timer0 re-entry; timer1 prio=2 still passes)
//   3. Re-enable global MIE → timer1 can now preempt
//   4. WFI — CPU suspends until timer1 fires; nested timer1 ISR runs and returns
//   5. Disable MIE (csrrci); t0_exit_count++
//   6. Restore threshold=0; complete source 6
//
// Timer 1 ISR path (higher-priority, may be nested inside timer 0):
//   1. Claim PLIC → src 7; clear timer1 INT_STATUS; t1_count++
//   2. If t0_entry_count > t0_exit_count → nested_detected = 1
//   3. Complete source 7
//
// Pass criteria:
//   - nested_count >= t0_exit_count && nested_count > 0  (nesting in every timer0 ISR)
//   - t1_count >= 4                                      (timer1 fired several times)
//   - t0_entry_count >= 2                                (timer0 ISR ran at least twice)
//   - t0_entry_count == t0_exit_count                    (all timer0 ISRs completed cleanly)
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include "jv_platform.h"
#include "jv_timer.h"
#include "jv_plic.h"
#include "jv_irq.h"

// ── Timer periods ──────────────────────────────────────────────────────────
// TIMER0_PERIOD: must be larger than the timer0 ISR execution time.
// With both caches enabled, 5000 cycles keeps the test fast while leaving
// enough headroom for the claim + threshold + WFI + nested timer1 ISR + cleanup.
// With ICACHE or DCACHE disabled the WFI/PLIC path stretches substantially:
//   - No icache: instruction fetches are slow on DDR4.
//   - No dcache: the trap_vector saves/restores 26 registers on the uncached
//     stack each needing a full memory round-trip (up to 16 cycles each with
//     high-latency SRAM), so the timer1 ISR alone takes ~10k wall-clock cycles.
// Use conservative periods for any no-cache configuration to guarantee the
// ISR always completes within one timer period regardless of memory latency.
// TIMER1_PERIOD: with both caches enabled ~380 cycle ISR leaves ~620 cycles
// of margin; values below ~600 risk a cascade of nested traps that overflows
// the stack.  Without dcache the ISR grows to ~10k cycles (26 register
// saves/restores on the uncached stack) so TIMER1_PERIOD must exceed that.
#if (defined(ICACHE_EN) && (ICACHE_EN == 0)) || \
    (defined(DCACHE_EN) && (DCACHE_EN == 0))
#define TIMER0_PERIOD    200000u  // conservative outer period for no-cache/slow paths
#define TIMER1_PERIOD     20000u  // timer1 ISR ~10k cycles without dcache; 2× margin
#else
#define TIMER0_PERIOD      5000u  // fast path when both caches are enabled
#define TIMER1_PERIOD      1000u  // ~380 cycle ISR; ~620 cycle margin
#endif

// ── Shared state (touched by ISRs) ────────────────────────────────────────
static volatile uint32_t t0_entry_count = 0;
static volatile uint32_t t0_exit_count  = 0;
static volatile uint32_t t1_count       = 0;
static volatile uint32_t nested_count = 0;   // incremented each time timer1 fires inside timer0 ISR

// ── Combined MEI dispatcher ────────────────────────────────────────────────
// Both TIMER0 and TIMER1 interrupts arrive as MEI.  The PLIC claim identifies
// the source so that each path is handled independently.
static void mei_handler(uint32_t cause)
{
    (void)cause;
    uint32_t src = jv_plic_claim();

    if (src == (uint32_t)KV_PLIC_SRC_TIMER0) {
        // ── Timer 0 (lower-priority) path ─────────────────────────────────
        jv_timer_clear_int(1u << 0);
        t0_entry_count++;

        // Raise PLIC threshold to 1.  Timer0 prio = 1 <= threshold, so
        // timer0 cannot re-preempt itself.  Timer1 prio = 2 > threshold,
        // so it can still be delivered once MIE is re-enabled below.
        jv_plic_set_threshold(1u);

        // Re-enable global MIE: opens the nested-interrupt window.
        jv_irq_enable();

        // WFI: suspend until timer1 fires.  The CPU halts here; when
        // timer1's MEI arrives the nested timer1 ISR runs and returns
        // via MRET to the instruction after this WFI.  No spin loop
        // is needed — one WFI catches exactly one timer1 event,
        // regardless of the ISR/period ratio in each simulator.
        asm volatile("wfi");

        // Close the preemption window before updating the exit counter.
        // Use a single atomic CSR instruction so no extra interrupt can
        // slip in between the read and clear phases.
        asm volatile("csrrci zero, mstatus, 8");
        t0_exit_count++;

        // Restore threshold and complete this interrupt.
        jv_plic_set_threshold(0u);
        jv_plic_complete(src);

    } else if (src == (uint32_t)KV_PLIC_SRC_TIMER1) {
        // ── Timer 1 (higher-priority) path — may execute nested inside timer0
        jv_timer_clear_int(1u << 1);
        t1_count++;

        // If timer0 entry count is ahead of exit count we are inside a
        // timer0 ISR — this is the nested preemption we want to detect.
        // Count nesting events rather than just setting a flag: this lets the
        // final check verify that nesting occurred in every timer0 ISR cycle.
        if (t0_entry_count > t0_exit_count)
            nested_count++;

        jv_plic_complete(src);

    } else {
        // Spurious or unknown source — complete and continue.
        if (src) jv_plic_complete(src);
    }
}

// ── Main ──────────────────────────────────────────────────────────────────
int main(void)
{
    int pass = 0, fail = 0;

    printf("============================================================\n");
    printf("  Nested Interrupt Test\n");
    printf("  Timer0: period=%u cycles, PLIC src=%d, prio=1\n",
           TIMER0_PERIOD, KV_PLIC_SRC_TIMER0);
    printf("  Timer1: period=%u cycles, PLIC src=%d, prio=2\n",
           TIMER1_PERIOD, KV_PLIC_SRC_TIMER1);
    printf("============================================================\n\n");

    // ------------------------------------------------------------------
    // Init timers (auto-reload on COMPARE2 match, interrupt on COMPARE2)
    // ------------------------------------------------------------------
    jv_timer_init();

    // Channel 0: period = TIMER0_PERIOD, no prescale
    KV_TIMER_COMPARE1(0) = 0;
    KV_TIMER_COMPARE2(0) = TIMER0_PERIOD - 1u;
    KV_TIMER_INT_ENABLE  = 0x3u;    // enable channels 0 and 1 globally
    KV_TIMER_CTRL(0) = KV_TIMER_CTRL_EN | KV_TIMER_CTRL_INT_EN;

    // Channel 1: period = TIMER1_PERIOD, no prescale
    KV_TIMER_COMPARE1(1) = 0;
    KV_TIMER_COMPARE2(1) = TIMER1_PERIOD - 1u;
    KV_TIMER_CTRL(1) = KV_TIMER_CTRL_EN | KV_TIMER_CTRL_INT_EN;

    // ------------------------------------------------------------------
    // Configure PLIC:
    //   Timer0 → source 6, priority 1
    //   Timer1 → source 7, priority 2
    //   Threshold = 0 (all enabled sources can fire)
    // ------------------------------------------------------------------
    jv_plic_set_priority(KV_PLIC_SRC_TIMER0, 1u);
    jv_plic_set_priority(KV_PLIC_SRC_TIMER1, 2u);
    jv_plic_enable_source(KV_PLIC_SRC_TIMER0);
    jv_plic_enable_source(KV_PLIC_SRC_TIMER1);
    jv_plic_set_threshold(0u);

    // Register the combined MEI handler and enable external interrupts.
    jv_irq_register(KV_CAUSE_MEI, mei_handler);
    jv_irq_source_enable(KV_IRQ_MEIE);
    jv_irq_enable();

    printf("[TEST] Waiting for nested interrupt to occur...\n");

    // Wait until timer0 has COMPLETED at least twice (checking exit count to
    // avoid a race where we see entry=2 before the ISR finishes) and timer1
    // has fired at least 4 times, or a safety timeout expires.
    // With TIMER0_PERIOD=5000 success arrives in ~10 000 cycles; 2 000 000
    // nop iterations is a generous safety net that still keeps simulation short.
    uint32_t timeout = 0;
    while ((t0_exit_count < 2 || t1_count < 4) && timeout < 2000000u) {
        timeout++;
        asm volatile("nop");
    }

    // Atomically disable interrupts (single CSR, no 2-cycle race window).
    asm volatile("csrrci zero, mstatus, 8");

    // Disable timers
    jv_timer_stop(0);
    jv_timer_stop(1);

    // Print counters
    printf("  t0_entry_count  = %lu\n", (unsigned long)t0_entry_count);
    printf("  t0_exit_count   = %lu\n", (unsigned long)t0_exit_count);
    printf("  t1_count        = %lu\n", (unsigned long)t1_count);
    printf("  nested_count    = %lu\n", (unsigned long)nested_count);
    printf("\n");

    // ------------------------------------------------------------------
    // Pass/Fail checks
    // ------------------------------------------------------------------
    printf("[CHECK 1] Timer1 fired at least 4 times (t1_count >= 4): ");
    if (t1_count >= 4) {
        printf("PASS (t1_count=%lu)\n", (unsigned long)t1_count);
        pass++;
    } else {
        printf("FAIL (t1_count=%lu)\n", (unsigned long)t1_count);
        fail++;
    }

    printf("[CHECK 2] Timer0 ISR completed at least twice (t0_exit >= 2): ");
    if (t0_exit_count >= 2) {
        printf("PASS (t0_exit=%lu)\n", (unsigned long)t0_exit_count);
        pass++;
    } else {
        printf("FAIL (t0_exit=%lu)\n", (unsigned long)t0_exit_count);
        fail++;
    }

    printf("[CHECK 3] Nesting in every timer0 ISR (nested_count >= t0_exit_count): ");
    if (nested_count >= t0_exit_count && nested_count > 0) {
        printf("PASS (nested_count=%lu)\n", (unsigned long)nested_count);
        pass++;
    } else {
        printf("FAIL (nested_count=%lu t0_exit=%lu)\n",
               (unsigned long)nested_count, (unsigned long)t0_exit_count);
        fail++;
    }

    printf("[CHECK 4] ISR count balanced (t0_entry == t0_exit): ");
    if (t0_entry_count == t0_exit_count) {
        printf("PASS (entry=%lu exit=%lu)\n",
               (unsigned long)t0_entry_count, (unsigned long)t0_exit_count);
        pass++;
    } else {
        printf("FAIL (entry=%lu exit=%lu)\n",
               (unsigned long)t0_entry_count, (unsigned long)t0_exit_count);
        fail++;
    }

    printf("\n============================================================\n");
    printf("  Results: %d PASS, %d FAIL\n", pass, fail);
    printf("============================================================\n");

    // Signal exit to simulator using proper HTIF encoding.
    // jv_exit() handles the encoding automatically:
    //   code == 0 → write 1 (success)
    //   code != 0 → write (code<<1)|1 (failure)
    jv_exit(fail);
}

