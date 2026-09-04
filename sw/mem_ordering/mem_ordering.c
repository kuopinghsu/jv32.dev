// ============================================================================
// File: sw/mem_ordering/mem_ordering.c
// Project: JV32 RISC-V Processor
// Description: Single-hart memory-ordering checks for the claims in
//   TODO.bak/RISCV_COMPATIBILITY_TODO.md:
//     P2 "aq / rl ordering for atomic instructions"  -- the pipeline must
//        already provide ordering at least as strong as every required
//        acquire/release, so ignoring aq/rl in the decoder is safe.
//     P2 "FENCE is implemented as a NOP"             -- program order must be
//        preserved across TCM<->TCM and TCM<->MMIO with and without FENCE.
//
// These are single-hart tests: they cannot prove multi-agent ordering, but a
// core that reordered stores/loads observably (e.g. a store queue that let a
// younger load pass an older store to the same or a FENCE-separated address)
// would fail here.  Self-checking; exits 0 (PASS) / 1 (FAIL).
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include "jv_platform.h"
#include "jv_irq.h"

static uint32_t tp = 0, tf = 0;
static void check(const char *n, int ok)
{
    printf("  %-52s : %s\n", n, ok ? "PASS" : "FAIL");
    if (ok) tp++; else tf++;
}

#define FENCE()   __asm__ volatile("fence" ::: "memory")

// A scratch region in DRAM (TCM).
static volatile uint32_t g_buf[32] __attribute__((aligned(64)));

// ---------------------------------------------------------------------------
// 1. AMO with aq/rl: the release store before an AMO.aqrl must be visible,
//    and a load after it must observe the AMO result.  On JV32 the decoder
//    ignores aq/rl, so this checks the pipeline already orders them.
// ---------------------------------------------------------------------------
static void test_amo_aqrl(void)
{
    printf("\n[1] AMO .aq/.rl/.aqrl ordering (single hart)\n");

    for (int i = 0; i < 32; i++) g_buf[i] = 0;

    // sw X ; amoswap.w.aqrl Y ; lw X   -> X must read the sw value
    volatile uint32_t *X = &g_buf[1];
    volatile uint32_t *Y = &g_buf[2];
    uint32_t old, back;
    *X = 0xA11CE000u;
    __asm__ volatile("amoswap.w.aqrl %0, %2, (%1)"
                     : "=r"(old) : "r"(Y), "r"(0x5A5A0002u) : "memory");
    back = *X;
    check("release: store before AMO.aqrl is visible", back == 0xA11CE000u);
    check("AMO.aqrl wrote its target",                 *Y == 0x5A5A0002u);
    check("AMO.aqrl returned the old value",           old == 0x00000000u);

    // amoadd.w.aq Z ; lw Z  -> acquire: the load sees the AMO's new value
    volatile uint32_t *Z = &g_buf[3];
    *Z = 100;
    __asm__ volatile("amoadd.w.aq %0, %2, (%1)"
                     : "=r"(old) : "r"(Z), "r"(23) : "memory");
    check("acquire: load after AMO.aq sees new value", *Z == 123);

    // Chain of .rl stores then a single load of each: all must be present.
    for (int i = 0; i < 8; i++) {
        uint32_t d;
        __asm__ volatile("amoswap.w.rl %0, %2, (%1)"
                         : "=r"(d) : "r"(&g_buf[8 + i]), "r"(0xD00D0000u | i) : "memory");
    }
    int all_ok = 1;
    for (int i = 0; i < 8; i++)
        if (g_buf[8 + i] != (0xD00D0000u | (uint32_t)i)) all_ok = 0;
    check("release chain: every amoswap.w.rl result is visible", all_ok);
}

// ---------------------------------------------------------------------------
// 2. FENCE: store-buffer drain + program order, TCM<->TCM and TCM<->MMIO.
// ---------------------------------------------------------------------------
static void test_fence_ordering(void)
{
    printf("\n[2] FENCE store->load ordering\n");

    // TCM->TCM, different addresses, load must not pass the stores.
    for (int i = 0; i < 16; i++) g_buf[i] = 0xB0000000u | (uint32_t)i;
    FENCE();
    int tt_ok = 1;
    for (int i = 0; i < 16; i++)
        if (g_buf[i] != (0xB0000000u | (uint32_t)i)) tt_ok = 0;
    check("TCM->TCM: all stores drained before loads (with FENCE)", tt_ok);

    // Back-to-back FENCE must not hang and must keep data intact.
    g_buf[0] = 0x1234abcdu;
    FENCE(); FENCE(); FENCE();
    check("back-to-back FENCE: data intact, no hang", g_buf[0] == 0x1234abcdu);

    // TCM store -> MMIO read -> TCM read: the TCM store must be complete.
    g_buf[5] = 0xCAFEBEEFu;
    FENCE();
    volatile uint32_t mtime_lo = JV_CLIC_MTIME_LO;   // MMIO read
    (void)mtime_lo;
    FENCE();
    check("TCM->MMIO->TCM: TCM store visible across FENCE", g_buf[5] == 0xCAFEBEEFu);

    // MMIO store (mtimecmp, harmless) -> FENCE -> MMIO read-back.
    uint32_t saved_lo = JV_CLIC_MTIMECMP_LO;
    uint32_t saved_hi = JV_CLIC_MTIMECMP_HI;
    JV_CLIC_MTIMECMP_HI = 0xFFFFFFFFu;              // park far in the future
    JV_CLIC_MTIMECMP_LO = 0xDEAD0000u;
    FENCE();
    check("MMIO->MMIO: mtimecmp write visible across FENCE",
          JV_CLIC_MTIMECMP_LO == 0xDEAD0000u);
    JV_CLIC_MTIMECMP_LO = saved_lo;                 // restore
    JV_CLIC_MTIMECMP_HI = saved_hi;
    FENCE();

    // Store / load to the same address interleaved with FENCE.
    volatile uint32_t *p = &g_buf[7];
    int sa_ok = 1;
    for (uint32_t v = 1; v <= 64; v++) {
        *p = v;
        FENCE();
        if (*p != v) { sa_ok = 0; break; }
    }
    check("same-address store;FENCE;load returns the stored value", sa_ok);
}

int main(void)
{
    printf("=== JV32 single-hart memory-ordering test ===\n");
    test_amo_aqrl();
    test_fence_ordering();

    printf("\n--- Results ---  passed: %lu  failed: %lu\n",
           (unsigned long)tp, (unsigned long)tf);
    int pass = (tf == 0);
    printf(pass ? "\nPASS\n" : "\nFAIL\n");
    jv_exit(pass ? 0 : 1);
    return pass ? 0 : 1;
}
