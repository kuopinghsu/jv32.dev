// ============================================================================
// File: nested_irq.c
// Project: JV32 RISC-V Processor
// Description: Nested interrupt test using MTI (outer) and MSI (inner).
//
// JV32 has no PLIC and only one hardware timer (CLINT mtime/mtimecmp).
// Nesting is demonstrated using the two available interrupt sources:
//   - MTI (Machine Timer Interrupt, cause=7):  outer, lower-priority
//   - MSI (Machine Software Interrupt, cause=3): inner, higher-priority
//
// Nesting mechanism — WFI-based:
//   The MTI ISR re-arms the timer, disables MTIE (prevents re-entrant MTI),
//   arms the software interrupt (MSIP=1), re-enables MIE, then executes WFI.
//   Since MSI is already pending, the nested MSI ISR runs immediately and
//   returns; MRET wakes the CPU at the instruction after WFI.  csrrci then
//   atomically closes the nesting window before re-enabling MTIE.
//
// MTI ISR path (outer):
//   1. Re-arm timer (mtimecmp += TIMER0_PERIOD); t0_entry_count++
//   2. Disable MTIE  (prevents a second timer interrupt from re-entering)
//   3. Set MSIP=1    (arm the inner interrupt)
//   4. Re-enable MIE → nested MSI fires immediately
//   5. WFI           (acts as NOP since MSI is already pending/handled)
//   6. csrrci mstatus,8  → close nesting window; t0_exit_count++
//   7. Re-enable MTIE for the next round
//
// MSI ISR path (inner, nested inside MTI):
//   1. Clear MSIP; t1_count++
//   2. If t0_entry_count > t0_exit_count → nested_count++
//
// Pass criteria:
//   - t1_count >= 4                                      (MSI fired several times)
//   - t0_exit_count >= 4                                 (MTI ISR completed several times)
//   - nested_count >= t0_exit_count && nested_count > 0  (nesting in every MTI ISR)
//   - t0_entry_count == t0_exit_count                    (all MTI ISRs completed cleanly)
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include "jv_platform.h"
#include "jv_clic.h"
#include "jv_irq.h"

// ── Timer period ───────────────────────────────────────────────────────────
// Must be large enough for the MTI ISR to complete (re-arm + nested MSI + cleanup).
// In RTL simulation the startup.S trap handler saves/restores ~28 registers;
// each register access is 1-2 cycles over TCM, so the combined handler overhead
// is roughly 200-300 cycles.  5000 provides comfortable headroom.
#define TIMER0_PERIOD  5000u

// ── Shared state (touched by ISRs) ────────────────────────────────────────
static volatile uint32_t t0_entry_count = 0;
static volatile uint32_t t0_exit_count  = 0;
static volatile uint32_t t1_count       = 0;
static volatile uint32_t nested_count   = 0;

// ── MTI handler (outer) ────────────────────────────────────────────────────
static void mti_handler(uint32_t cause)
{
    (void)cause;
    t0_entry_count++;

    // Re-arm: schedule next MTI TIMER0_PERIOD cycles from now.
    jv_clic_timer_set_rel(TIMER0_PERIOD);

    // Disable MTIE so that re-enabling MIE below cannot cause a second
    // timer interrupt to preempt this handler.
    jv_clic_timer_irq_disable();

    // Arm the software interrupt.
    jv_clic_msip_set();

    // Re-enable global MIE: MSI is already pending so it fires immediately.
    jv_irq_enable();

    // WFI: acts as NOP here since the MSI was pending when MIE was set.
    // After the nested MSI ISR returns via MRET, execution resumes here.
    jv_wfi();

    // MRET from the outer MTI trap will restore MIE from MPIE (=1), so
    // MIE stays 1 after returning.  MTIE is still disabled here; we only
    // re-enable it after counting the exit so there is no window where
    // another MTI could preempt this critical section.
    t0_exit_count++;

    // Re-enable MTIE for the next timer period.
    jv_clic_timer_irq_enable();
}

// ── MSI handler (inner, nested inside MTI) ────────────────────────────────
static void msi_handler(uint32_t cause)
{
    (void)cause;

    // Clear the software interrupt immediately.
    jv_clic_msip_clear();
    t1_count++;

    // If MTI entry is ahead of exit we are nested inside the MTI handler.
    if (t0_entry_count > t0_exit_count)
        nested_count++;
}

// ── Main ──────────────────────────────────────────────────────────────────
int main(void)
{
    int pass = 0, fail = 0;

    printf("============================================================\n");
    printf("  Nested Interrupt Test\n");
    printf("  Outer: MTI (machine timer), period=%u cycles\n", TIMER0_PERIOD);
    printf("  Inner: MSI (machine software interrupt)\n");
    printf("============================================================\n\n");

    // Arm the timer for the first MTI.
    jv_clic_timer_set_rel(TIMER0_PERIOD);

    // Register handlers.
    jv_irq_register(JV_CAUSE_MTI, mti_handler);
    jv_irq_register(JV_CAUSE_MSI, msi_handler);

    // Enable MTI and MSI sources in mie.
    jv_irq_source_enable(JV_IRQ_MTIE | JV_IRQ_MSIE);

    // Enable global interrupts.
    jv_irq_enable();

    printf("[TEST] Waiting for nested interrupts to occur...\n");

    // Wait until MTI has completed at least 4 times (and MSI at least 4 times),
    // or a safety timeout expires.
    // With TIMER0_PERIOD=5000 success arrives in ~20 000 cycles; 2 000 000
    // nop iterations is a generous safety net that still keeps simulation short.
    uint32_t timeout = 0;
    while ((t0_exit_count < 4 || t1_count < 4) && timeout < 2000000u) {
        timeout++;
        asm volatile("nop");
    }

    // Atomically disable interrupts (single CSR, no 2-cycle race window).
    asm volatile("csrrci zero, mstatus, 8");

    // Disarm the timer.
    jv_clic_timer_disable();

    // Print counters
    printf("  t0_entry_count  = %lu\n", (unsigned long)t0_entry_count);
    printf("  t0_exit_count   = %lu\n", (unsigned long)t0_exit_count);
    printf("  t1_count        = %lu\n", (unsigned long)t1_count);
    printf("  nested_count    = %lu\n", (unsigned long)nested_count);
    printf("\n");

    // ------------------------------------------------------------------
    // Pass/Fail checks
    // ------------------------------------------------------------------
    printf("[CHECK 1] MSI fired at least 4 times (t1_count >= 4): ");
    if (t1_count >= 4) {
        printf("PASS (t1_count=%lu)\n", (unsigned long)t1_count);
        pass++;
    } else {
        printf("FAIL (t1_count=%lu)\n", (unsigned long)t1_count);
        fail++;
    }

    printf("[CHECK 2] MTI ISR completed at least 4 times (t0_exit >= 4): ");
    if (t0_exit_count >= 4) {
        printf("PASS (t0_exit=%lu)\n", (unsigned long)t0_exit_count);
        pass++;
    } else {
        printf("FAIL (t0_exit=%lu)\n", (unsigned long)t0_exit_count);
        fail++;
    }

    printf("[CHECK 3] Nesting in every MTI ISR (nested_count >= t0_exit_count): ");
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

