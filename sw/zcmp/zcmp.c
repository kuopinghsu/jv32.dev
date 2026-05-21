/* ============================================================================
 * File: sw/zcmp/zcmp.c
 * Project: JV32 RISC-V Processor
 * Description: Coverage test for the Zcmp compressed instruction extension.
 *
 * Exercises all six Zcmp instruction classes:
 *
 *   cm.push  {rlist}, -sadj  -- adjust sp, store callee-save regs to stack
 *   cm.pop   {rlist},  sadj  -- restore callee-save regs from stack, adjust sp
 *   cm.popret  {rlist}, sadj -- cm.pop + jalr x0,0(ra)
 *   cm.popretz {rlist}, sadj -- cm.pop + addi a0,x0,0 + jalr x0,0(ra)
 *   cm.mvsa01 sreg1, sreg2  -- s[sreg1]=a0,  s[sreg2]=a1
 *   cm.mva01s sreg1, sreg2  -- a0=s[sreg1],  a1=s[sreg2]
 *
 * Each asm block emits ".option arch, +zcmp" before the first Zcmp
 * mnemonic so the assembler accepts cm.push/cm.pop/etc. regardless of
 * the -march string passed on the command line (same approach used in
 * rtos/freertos/portable/RISC-V/portContext.h).
 *
 * Encoding reference (RTL implementation -- Q2=ci[1:0]=10, funct3=5=ci[15:13]=101):
 *
 *   Push/pop group (ci[12]=1):
 *     ci[11:10]=10: push (ci[9:8]=00) / pop  (ci[9:8]=10)
 *     ci[11:10]=11: popretz (ci[9:8]=00) / popret (ci[9:8]=10)
 *     ci[7:4]=rlist, ci[3:2]=spimm_extra
 *
 *   sadj = min_stack(rlist) + spimm_extra x 16
 *     rlist 4-7  -> min_stack=16;  rlist 8-11 -> min_stack=32
 *     rlist 12-14 -> min_stack=48; rlist 15   -> min_stack=64
 *
 *   Mv group (ci[12]=0, ci[11:10]=11):
 *     ci[6]=0 -> cm.mvsa01;  ci[6]=1 -> cm.mva01s
 *     ci[9:7]=sreg1, ci[4:2]=sreg2
 *     s-reg mapping: 0->s0(x8), 1->s1(x9), 2->s2(x18), ..., 7->s7(x23)
 *
 *   Instruction                    rlist  sadj
 *   cm.push  {ra,s0},   -16         5     16
 *   cm.pop   {ra,s0},    16         5     16
 *   cm.push  {ra,s0},   -32         5     32   (spimm_extra=1)
 *   cm.pop   {ra,s0},    32         5     32   (spimm_extra=1)
 *   cm.push  {ra,s0-s1},-16         6     16
 *   cm.pop   {ra,s0-s1}, 16         6     16
 *   cm.popretz {ra,s0},  16         5     16
 *   cm.popret  {ra,s0},  16         5     16
 *   cm.mvsa01 s0,s1   (sreg1=0, sreg2=1)
 *   cm.mva01s s0,s1   (sreg1=0, sreg2=1)
 * ============================================================================ */

#include "jv_platform.h"
#include <stdint.h>

static int g_fail __attribute__((unused)) = 0;

#define CHECK(label, got, exp) do { \
    if ((uint32_t)(got) != (uint32_t)(exp)) { \
        jv_puts("FAIL " label "\n"); \
        g_fail++; \
    } \
} while (0)

/* ============================================================================
 * Push / pop round-trip tests
 *
 * Each naked helper function:
 *   1. Saves the caller's s-registers to temporaries (t0, t1) so the
 *      function is callee-save correct regardless of what it pushes.
 *   2. Loads the test sentinel into an s-register.
 *   3. cm.push -- saves ra (= return address) and the s-register(s).
 *   4. Corrupts the s-register(s) with a distinctive pattern.
 *   5. cm.pop  -- restores ra and s-register(s) from the stack frame.
 *   6. Moves the restored s-register value into a0 (return value).
 *   7. Restores the caller's original s-register value from the temporary.
 *   8. ret (jalr x0, 0(ra)).
 *
 * After a correct push/pop round-trip, the returned value equals sentinel.
 * ============================================================================ */

#ifdef __riscv_zcmp

/* rlist=5 ({ra,s0}), sadj=16 -- single s-register save/restore. */
__attribute__((naked, noinline))
static uint32_t do_push_pop_rlist5(uint32_t sentinel __attribute__((unused)))
{
    __asm__(
        "mv   t0, s0\n"           /* t0 = caller's s0                   */
        "mv   s0, a0\n"           /* s0 = sentinel                       */
        ".option arch, +zcmp\n"
        "cm.push {ra,s0}, -16\n"  /* save ra and s0, sp -= 16           */
        "li   s0, 0xDEADC0DE\n"  /* corrupt s0                          */
        "cm.pop  {ra,s0}, 16\n"   /* restore ra and s0, sp += 16        */
        "mv   a0, s0\n"           /* a0 = restored s0 (should = sentinel)*/
        "mv   s0, t0\n"           /* restore caller's s0                 */
        "ret\n"
    );
}

/* rlist=5 ({ra,s0}), sadj=32 (spimm_extra=1) -- non-minimal stack adj. */
__attribute__((naked, noinline))
static uint32_t do_push_pop_rlist5_spimm1(uint32_t sentinel __attribute__((unused)))
{
    __asm__(
        "mv   t0, s0\n"           /* t0 = caller's s0                   */
        "mv   s0, a0\n"           /* s0 = sentinel                       */
        ".option arch, +zcmp\n"
        "cm.push {ra,s0}, -32\n"  /* save ra and s0, sp -= 32 (spimm=1) */
        "li   s0, 0xDEADC0DE\n"  /* corrupt s0                          */
        "cm.pop  {ra,s0}, 32\n"   /* restore ra and s0, sp += 32        */
        "mv   a0, s0\n"           /* a0 = restored s0                    */
        "mv   s0, t0\n"           /* restore caller's s0                 */
        "ret\n"
    );
}

/* rlist=6 ({ra,s0,s1}), sadj=16 -- two s-registers; returns restored s1. */
__attribute__((naked, noinline))
static uint32_t do_push_pop_rlist6(uint32_t sentinel __attribute__((unused)))
{
    __asm__(
        "mv   t0, s0\n"           /* t0 = caller's s0                   */
        "mv   t1, s1\n"           /* t1 = caller's s1                   */
        "li   s0, 0xAAAAAAAA\n"   /* s0 = distinct filler               */
        "mv   s1, a0\n"           /* s1 = sentinel                       */
        ".option arch, +zcmp\n"
        "cm.push {ra,s0-s1}, -16\n" /* save ra, s0, s1; sp -= 16        */
        "li   s0, 0xDEAD0001\n"  /* corrupt s0                          */
        "li   s1, 0xDEAD0002\n"  /* corrupt s1                          */
        "cm.pop  {ra,s0-s1}, 16\n"  /* restore ra, s0, s1; sp += 16     */
        "mv   a0, s1\n"           /* a0 = restored s1 (should = sentinel)*/
        "mv   s0, t0\n"           /* restore caller's s0                 */
        "mv   s1, t1\n"           /* restore caller's s1                 */
        "ret\n"
    );
}

/* ============================================================================
 * cm.popret -- pop registers, then jalr x0,0(ra)
 *
 * The cm.push at the start of this function pushes:
 *   - ra (= the return address of this function's caller) at sp+12
 *   - s0 (= the caller's original s0, unchanged) at sp+8
 *
 * cm.popret then restores ra and s0 from the stack frame and returns.
 * a0 is NOT zeroed by cm.popret, so the caller receives a0 = sentinel.
 * ============================================================================ */
__attribute__((naked, noinline))
static uint32_t do_popret(uint32_t sentinel __attribute__((unused)))
{
    __asm__(
        ".option arch, +zcmp\n"
        "cm.push  {ra,s0}, -16\n"  /* save ra and s0, sp -= 16          */
        /* a0 is still = sentinel; s0 = caller's original s0              */
        "cm.popret {ra,s0}, 16\n"  /* restore ra and s0, sp += 16, ret  */
    );
}

/* ============================================================================
 * cm.popretz -- pop registers, set a0=0, then jalr x0,0(ra)
 *
 * Regardless of the argument, the caller receives 0 in a0.
 * ============================================================================ */
__attribute__((naked, noinline))
static uint32_t do_popretz(uint32_t sentinel)
{
    (void)sentinel;
    __asm__(
        ".option arch, +zcmp\n"
        "cm.push   {ra,s0}, -16\n"  /* save ra and s0, sp -= 16         */
        "cm.popretz {ra,s0}, 16\n"  /* restore ra and s0, a0=0, ret     */
    );
}

/* ============================================================================
 * cm.mvsa01 / cm.mva01s -- register moves between a0/a1 and s-registers
 *
 * cm.mvsa01 (sreg1=0=s0, sreg2=1=s1):  s0=a0,  s1=a1
 * cm.mva01s (sreg1=0=s0, sreg2=1=s1):  a0=s0,  a1=s1
 *
 * GCC register-pinned locals ensure the compiler puts the right values
 * in the right physical registers before and after each cm.mv* instruction.
 * ============================================================================ */
static void test_mv_variants(void)
{
    register uint32_t ra0 asm("a0");
    register uint32_t ra1 asm("a1");
    register uint32_t rs0 asm("s0");
    register uint32_t rs1 asm("s1");

    /* cm.mvsa01 (sreg1=0->s0, sreg2=1->s1): s0=a0, s1=a1 */
    ra0 = 0x12345678u;
    ra1 = 0x9ABCDEF0u;
    __asm__ volatile(
        ".option arch, +zcmp\n"
        "cm.mvsa01 s0,s1\n"        /* s0=a0, s1=a1                       */
        : "=r"(rs0), "=r"(rs1)
        : "r"(ra0),  "r"(ra1)
    );
    CHECK("cm.mvsa01 s0=a0", rs0, 0x12345678u);
    CHECK("cm.mvsa01 s1=a1", rs1, 0x9ABCDEF0u);

    /* cm.mva01s (sreg1=0->s0, sreg2=1->s1): a0=s0, a1=s1 */
    rs0 = 0xABCD1234u;
    rs1 = 0xEF012345u;
    __asm__ volatile(
        ".option arch, +zcmp\n"
        "cm.mva01s s0,s1\n"        /* a0=s0, a1=s1                       */
        : "=r"(ra0), "=r"(ra1)
        : "r"(rs0),  "r"(rs1)
    );
    CHECK("cm.mva01s a0=s0", ra0, 0xABCD1234u);
    CHECK("cm.mva01s a1=s1", ra1, 0xEF012345u);
}

#endif /* __riscv_zcmp */

/* ============================================================================
 * Main
 * ============================================================================ */
int main(void)
{
#ifndef __riscv_zcmp
    jv_puts("SKIP (Zcmp extension not enabled; __riscv_zcmp not defined)\n");
    jv_exit(0);
    return 0;
#else
    uint32_t v;

    jv_puts("zcmp: Zcmp compressed instruction coverage test\n");

    /* -- cm.push / cm.pop round-trip --------------------------------------- */
    v = do_push_pop_rlist5(0xCAFEBABEu);
    CHECK("cm.push/pop rlist5 s0",        v, 0xCAFEBABEu);

    v = do_push_pop_rlist5_spimm1(0x55AA55AAu);
    CHECK("cm.push/pop rlist5 spimm1 s0", v, 0x55AA55AAu);

    v = do_push_pop_rlist6(0xA5A5A5A5u);
    CHECK("cm.push/pop rlist6 s1",        v, 0xA5A5A5A5u);

    /* -- cm.popret / cm.popretz --------------------------------------------- */
    v = do_popret(0x12345678u);
    CHECK("cm.popret  a0=sentinel",        v, 0x12345678u);

    v = do_popretz(0xDEADBEEFu);
    CHECK("cm.popretz a0=0",               v, 0u);

    /* -- cm.mvsa01 / cm.mva01s ---------------------------------------------- */
    test_mv_variants();

    if (g_fail == 0)
        jv_puts("PASS\n");
    else
        jv_puts("FAIL\n");

    jv_exit(g_fail);
    return g_fail;
#endif /* __riscv_zcmp */
}
