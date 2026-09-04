// ============================================================================
// File: sw/atomic_compat/atomic_compat.c
// Project: JV32 RISC-V Processor
// Description: RISC-V "A" extension architectural-compliance regression test.
//
// Covers three confirmed compatibility issues from
// TODO.bak/RISCV_COMPATIBILITY_TODO.md (recommended fix order #1-#3):
//
//   [#2] Misaligned LR.W / SC.W / AMO*.W must raise an address-misaligned
//        exception (load-misaligned for LR, store/AMO-misaligned for SC/AMO)
//        instead of reaching memory.  RISC-V Unpriv. ISA, "A" extension:
//        "the address held in rs1 [must] be naturally aligned to the size of
//        the operand ... otherwise an address-misaligned exception or an
//        access-fault exception will be generated."
//
//   [#3] Reserved AMO funct5 encodings must raise illegal-instruction, not
//        execute as an unintended read-modify-write.
//
//   [#1] Executing an SC.W invalidates the hart's reservation regardless of
//        whether the SC succeeds or fails.  A failing SC (address mismatch)
//        must therefore prevent a later SC from succeeding without a new LR.
//        RISC-V Unpriv. ISA, "A" extension: "Regardless of success or
//        failure, executing an SC.W instruction invalidates any reservation
//        held by this hart."
//
// Self-checking: prints per-check lines and exits 0 (PASS) / 1 (FAIL).
// Runs identically on the RTL simulator and the jv32sim ISS, so
// `make compare-atomic_compat` must also match.
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include "jv_platform.h"
#include "jv_irq.h"

static uint32_t tests_passed = 0;
static uint32_t tests_failed = 0;

static void check(const char *name, int ok)
{
    printf("  %-44s : %s\n", name, ok ? "PASS" : "FAIL");
    if (ok) tests_passed++; else tests_failed++;
}

// ---------------------------------------------------------------------------
// Shared trap bookkeeping.  A single exception handler records the most
// recent synchronous exception and skips the faulting (always 32-bit)
// instruction so the test can continue.
// ---------------------------------------------------------------------------
static volatile uint32_t g_trap_count = 0;
static volatile uint32_t g_last_cause = 0xFFFFFFFFu;
static volatile uint32_t g_last_tval  = 0xFFFFFFFFu;

static void on_sync_exc(jv_trap_frame_t *frame)
{
    g_trap_count++;
    g_last_cause = frame->mcause;
    g_last_tval  = frame->mtval;
    frame->mepc += 4;   // all faulting encodings below are 32-bit
}

// A word we point misaligned/reserved atomics at.  Global => lives in DRAM
// (TCM), which is the path the TODO calls out for word-address selection.
static volatile uint32_t g_cell;

// ===========================================================================
// [#2] Misaligned atomics must trap
// ===========================================================================
static void test_misaligned_atomics(void)
{
    printf("\n[#2] Misaligned LR/SC/AMO raise address-misaligned\n");

    // 16-byte aligned backing store; we deliberately target base+{1,2,3}.
    static volatile uint32_t backing[4] __attribute__((aligned(16)));
    const uintptr_t base = (uintptr_t)backing;

    struct {
        const char *name;
        int         is_lr;      // expected cause: 1 => load-misaligned(4)
        int         off;
    } cases[] = {
        { "lr.w    base+1", 1, 1 },
        { "lr.w    base+2", 1, 2 },
        { "lr.w    base+3", 1, 3 },
        { "sc.w    base+1", 0, 1 },
        { "sc.w    base+2", 0, 2 },
        { "amoadd  base+1", 0, 1 },
        { "amoadd  base+3", 0, 3 },
        { "amoswap base+2", 0, 2 },
        { "amoor   base+1", 0, 1 },
        { "amoxor  base+3", 0, 3 },
    };

    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        backing[0] = 0xA5A5A5A5u;
        backing[1] = 0x5A5A5A5Au;
        backing[2] = 0xA5A5A5A5u;
        backing[3] = 0x5A5A5A5Au;

        uintptr_t ma = base + cases[i].off;
        uint32_t  before0 = backing[0], before1 = backing[1];
        uint32_t  before2 = backing[2], before3 = backing[3];
        uint32_t  rd = 0xdeadbeefu;
        uint32_t  scratch = 0x11112222u;

        g_trap_count = 0;
        g_last_cause = 0xFFFFFFFFu;
        g_last_tval  = 0xFFFFFFFFu;

        switch (i) {
        case 0: case 1: case 2:
            __asm__ volatile("lr.w %0, (%1)" : "=r"(rd) : "r"(ma) : "memory");
            break;
        case 3: case 4:
            __asm__ volatile("sc.w %0, %2, (%1)"
                             : "=r"(rd) : "r"(ma), "r"(scratch) : "memory");
            break;
        case 5: case 6:
            __asm__ volatile("amoadd.w %0, %2, (%1)"
                             : "=r"(rd) : "r"(ma), "r"(scratch) : "memory");
            break;
        case 7:
            __asm__ volatile("amoswap.w %0, %2, (%1)"
                             : "=r"(rd) : "r"(ma), "r"(scratch) : "memory");
            break;
        case 8:
            __asm__ volatile("amoor.w %0, %2, (%1)"
                             : "=r"(rd) : "r"(ma), "r"(scratch) : "memory");
            break;
        case 9:
            __asm__ volatile("amoxor.w %0, %2, (%1)"
                             : "=r"(rd) : "r"(ma), "r"(scratch) : "memory");
            break;
        }

        uint32_t want_cause = cases[i].is_lr ? JV_EXC_LOAD_MISALIGN
                                             : JV_EXC_STORE_MISALIGN;
        int trapped   = (g_trap_count == 1);
        int cause_ok  = (g_last_cause == want_cause);
        int tval_ok   = (g_last_tval  == (uint32_t)ma);
        int mem_ok    = (backing[0] == before0) && (backing[1] == before1)
                     && (backing[2] == before2) && (backing[3] == before3);

        check(cases[i].name,
              trapped && cause_ok && tval_ok && mem_ok);
        if (!(trapped && cause_ok && tval_ok && mem_ok)) {
            printf("      trapped=%d cause=%lu(want %lu) tval=0x%08lx(want 0x%08lx) mem_ok=%d\n",
                   trapped, (unsigned long)g_last_cause, (unsigned long)want_cause,
                   (unsigned long)g_last_tval, (unsigned long)ma, mem_ok);
        }
    }
}

// ===========================================================================
// [#3] Reserved AMO funct5 encodings must raise illegal-instruction
// ===========================================================================
//
// a5 is pinned to &g_cell across the block.  Each `.insn r` uses
// opcode=0x2F (AMO), func3=0x2 (.W), func7 = funct5<<2 (aq=rl=0),
// rd=x0, rs1=a5, rs2=x0.  All 21 reserved funct5 values are exercised.
static void test_reserved_amo_funct5(void)
{
    printf("\n[#3] Reserved AMO funct5 -> illegal instruction\n");

    g_cell = 0xC0FFEE00u;
    const uint32_t seed = g_cell;

    register volatile uint32_t *p asm("a5") = &g_cell;

    g_trap_count = 0;
    g_last_cause = 0xFFFFFFFFu;

    __asm__ volatile(
        ".insn r 0x2f,0x2,0x14,x0,a5,x0\n"   // funct5 = 0b00101
        ".insn r 0x2f,0x2,0x18,x0,a5,x0\n"   // funct5 = 0b00110
        ".insn r 0x2f,0x2,0x1c,x0,a5,x0\n"   // funct5 = 0b00111
        ".insn r 0x2f,0x2,0x24,x0,a5,x0\n"   // funct5 = 0b01001
        ".insn r 0x2f,0x2,0x28,x0,a5,x0\n"   // funct5 = 0b01010
        ".insn r 0x2f,0x2,0x2c,x0,a5,x0\n"   // funct5 = 0b01011
        ".insn r 0x2f,0x2,0x34,x0,a5,x0\n"   // funct5 = 0b01101
        ".insn r 0x2f,0x2,0x38,x0,a5,x0\n"   // funct5 = 0b01110
        ".insn r 0x2f,0x2,0x3c,x0,a5,x0\n"   // funct5 = 0b01111
        ".insn r 0x2f,0x2,0x44,x0,a5,x0\n"   // funct5 = 0b10001
        ".insn r 0x2f,0x2,0x48,x0,a5,x0\n"   // funct5 = 0b10010
        ".insn r 0x2f,0x2,0x4c,x0,a5,x0\n"   // funct5 = 0b10011
        ".insn r 0x2f,0x2,0x54,x0,a5,x0\n"   // funct5 = 0b10101
        ".insn r 0x2f,0x2,0x58,x0,a5,x0\n"   // funct5 = 0b10110
        ".insn r 0x2f,0x2,0x5c,x0,a5,x0\n"   // funct5 = 0b10111
        ".insn r 0x2f,0x2,0x64,x0,a5,x0\n"   // funct5 = 0b11001
        ".insn r 0x2f,0x2,0x68,x0,a5,x0\n"   // funct5 = 0b11010
        ".insn r 0x2f,0x2,0x6c,x0,a5,x0\n"   // funct5 = 0b11011
        ".insn r 0x2f,0x2,0x74,x0,a5,x0\n"   // funct5 = 0b11101
        ".insn r 0x2f,0x2,0x78,x0,a5,x0\n"   // funct5 = 0b11110
        ".insn r 0x2f,0x2,0x7c,x0,a5,x0\n"   // funct5 = 0b11111
        : "+r"(p) :: "memory");

    check("21 reserved funct5 all trapped", g_trap_count == 21);
    check("all traps were illegal-instruction",
          g_last_cause == JV_EXC_ILLEGAL_INSN);
    check("reserved AMO did not modify memory", g_cell == seed);
    if (g_cell != seed)
        printf("      g_cell = 0x%08lx (seed 0x%08lx)\n",
               (unsigned long)g_cell, (unsigned long)seed);
}

// ===========================================================================
// [#1] A failing SC.W invalidates the reservation
// ===========================================================================
static uint32_t do_lr(volatile uint32_t *a)
{
    uint32_t v;
    __asm__ volatile("lr.w %0, (%1)" : "=r"(v) : "r"(a) : "memory");
    return v;
}
static uint32_t do_sc(volatile uint32_t *a, uint32_t v)
{
    uint32_t r;
    __asm__ volatile("sc.w %0, %2, (%1)" : "=r"(r) : "r"(a), "r"(v) : "memory");
    return r;   // 0 = success, 1 = failure
}

static void test_sc_invalidates_reservation(void)
{
    printf("\n[#1] Failing SC.W invalidates the reservation\n");

    static volatile uint32_t A __attribute__((aligned(4)));
    static volatile uint32_t B __attribute__((aligned(4)));

    // --- Sub-test 1: LR(A) ; SC(B) fails ; SC(A) must ALSO fail ---------
    // Emitted as one back-to-back block with no intervening memory traffic so
    // the failing SC(B) is the only thing that can have cleared the
    // reservation.  (With function-call spills in between, incidental bus
    // activity masks the RTL bug.)
    A = 0x11111111u; B = 0x22222222u;
    uint32_t sc_b, sc_a, lr_junk;
    __asm__ volatile(
        "lr.w  %0, (%3)\n"          // reserve A
        "sc.w  %1, %5, (%4)\n"      // SC -> B: address mismatch, must fail
        "sc.w  %2, %6, (%3)\n"      // SC -> A: reservation killed by SC(B) => must fail
        : "=&r"(lr_junk), "=&r"(sc_b), "=&r"(sc_a)
        : "r"(&A), "r"(&B), "r"(0xBBBBBBBBu), "r"(0xAAAAAAAAu)
        : "memory");
    (void)lr_junk;

    check("SC(B) after LR(A) fails", sc_b == 1);
    check("B unchanged by failed SC(B)", B == 0x22222222u);
    check("SC(A) after failed SC(B) also fails", sc_a == 1);
    check("A unchanged by failed SC(A)", A == 0x11111111u);

    // --- Sub-test 2: LR(A) ; SC(A) succeeds ; SC(A) again must fail -----
    A = 0x33333333u;
    (void)do_lr(&A);
    uint32_t sc_a1 = do_sc(&A, 0x44444444u);  // success
    uint32_t sc_a2 = do_sc(&A, 0x55555555u);  // no fresh LR -> fail

    check("first SC(A) succeeds", sc_a1 == 0);
    check("A updated by successful SC(A)", A == 0x44444444u);
    check("second SC(A) without new LR fails", sc_a2 == 1);
    check("A unchanged by failed second SC(A)", A == 0x44444444u);

    // --- Sub-test 3: reservation survives an ordinary store (JV32 model),
    //     but is still cleared by any SC --------------------------------
    A = 0x66666666u;
    (void)do_lr(&A);
    uint32_t sc_ok = do_sc(&A, 0x77777777u);  // matching -> success
    check("LR/SC pair still works after other activity", sc_ok == 0 && A == 0x77777777u);
}

// ===========================================================================
// misa.A must agree with the verified A-extension behaviour
// (RISCV_COMPATIBILITY_TODO P0 "A Extension Advertisement Must Match Compliance")
// ===========================================================================
static void test_misa_advertisement(void)
{
    printf("\n[misa] misa.A matches the A-extension behaviour above\n");

    uint32_t misa;
    __asm__ volatile("csrr %0, misa" : "=r"(misa));

    // This binary is built -march=...a..., so if the P0 items above all pass,
    // misa.A (bit 0) must be 1.  A mismatch means the core advertises an
    // extension whose architectural behaviour it does not (fully) implement.
    int a_bit = (misa >> 0) & 1u;
    check("misa.A == 1 (A extension advertised)", a_bit == 1);
    check("misa.A consistent with A-ext tests passing",
          (a_bit == 1) && (tests_failed == 0));
    if (a_bit != 1)
        printf("      misa = 0x%08lx\n", (unsigned long)misa);
}

int main(void)
{
    printf("=== JV32 RISC-V A-extension compatibility test ===\n");

    jv_exc_register(JV_EXC_LOAD_MISALIGN,  on_sync_exc);
    jv_exc_register(JV_EXC_STORE_MISALIGN, on_sync_exc);
    jv_exc_register(JV_EXC_ILLEGAL_INSN,   on_sync_exc);

    test_misaligned_atomics();
    test_reserved_amo_funct5();
    test_sc_invalidates_reservation();
    test_misa_advertisement();

    printf("\n--- Results ---\n");
    printf("  passed: %lu  failed: %lu\n",
           (unsigned long)tests_passed, (unsigned long)tests_failed);

    int pass = (tests_failed == 0);
    printf(pass ? "\nPASS\n" : "\nFAIL\n");
    jv_exit(pass ? 0 : 1);
    return pass ? 0 : 1;
}
