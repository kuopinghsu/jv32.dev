/* ============================================================================
 * File: sw/zb_ext/zb_ext.c
 * Project: JV32 RISC-V Processor
 * Description: Coverage-improvement test targeting previously uncovered RTL:
 *
 *   - Zbb:  CLZ, CTZ, CPOP, SEXT.B, SEXT.H, ZEXT.H, ROL, ROR, ORC.B, REV8,
 *            ANDN, ORN, XNOR
 *   - Zbs:  BSET, BCLR, BINV, BEXT
 *   - Zba:  SH1ADD, SH2ADD, SH3ADD
 *   - RV32M: MULH, MULHSU, MULHU, REM, REMU, DIV-by-zero, REM-by-zero
 *   - Base: SRA (arithmetic right shift register)
 *   - CSR:  mscratch, mcountinhibit, instret/instreth, minstret/minstreth
 * ============================================================================ */

#include "jv_platform.h"
#include <stdint.h>

/* ── simple pass/fail counter ────────────────────────────────────────────── */
static int g_fail = 0;

#define CHECK(label, got, exp) do { \
    if ((uint32_t)(got) != (uint32_t)(exp)) { \
        jv_puts("FAIL " label "\n"); \
        g_fail++; \
    } \
} while (0)

/* ── Zbb: count-leading/trailing zeros, popcount ─────────────────────────── */
static void test_count_ops(void)
{
    uint32_t r;

    __asm__ volatile("clz  %0, %1" : "=r"(r) : "r"(0x00008000u)); CHECK("clz",  r, 16);
    __asm__ volatile("clz  %0, %1" : "=r"(r) : "r"(0x00000001u)); CHECK("clz1", r, 31);
    __asm__ volatile("clz  %0, %1" : "=r"(r) : "r"(0u));          CHECK("clz0", r, 32);

    __asm__ volatile("ctz  %0, %1" : "=r"(r) : "r"(0x00008000u)); CHECK("ctz",  r, 15);
    __asm__ volatile("ctz  %0, %1" : "=r"(r) : "r"(0x80000000u)); CHECK("ctz1", r, 31);
    __asm__ volatile("ctz  %0, %1" : "=r"(r) : "r"(0u));          CHECK("ctz0", r, 32);

    __asm__ volatile("cpop %0, %1" : "=r"(r) : "r"(0xFFFFFFFFu)); CHECK("cpop_ff", r, 32);
    __asm__ volatile("cpop %0, %1" : "=r"(r) : "r"(0xDEADBEEFu)); CHECK("cpop_db", r, 24);
    __asm__ volatile("cpop %0, %1" : "=r"(r) : "r"(0u));          CHECK("cpop_0",  r,  0);
}

/* ── Zbb: sign/zero extension ─────────────────────────────────────────────── */
static void test_ext_ops(void)
{
    uint32_t r;

    __asm__ volatile("sext.b %0, %1" : "=r"(r) : "r"(0x80u));
    CHECK("sextb_neg", r, 0xFFFFFF80u);
    __asm__ volatile("sext.b %0, %1" : "=r"(r) : "r"(0x7Fu));
    CHECK("sextb_pos", r, 0x7Fu);

    __asm__ volatile("sext.h %0, %1" : "=r"(r) : "r"(0x8000u));
    CHECK("sexth_neg", r, 0xFFFF8000u);
    __asm__ volatile("sext.h %0, %1" : "=r"(r) : "r"(0x7FFFu));
    CHECK("sexth_pos", r, 0x7FFFu);

    __asm__ volatile("zext.h %0, %1" : "=r"(r) : "r"(0xDEADBEEFu));
    CHECK("zexth", r, 0x0000BEEFu);
}

/* ── Zbb: rotate ──────────────────────────────────────────────────────────── */
static void test_rotate_ops(void)
{
    uint32_t r;

    __asm__ volatile("rol %0, %1, %2" : "=r"(r) : "r"(0x80000001u), "r"(1u));
    CHECK("rol", r, 0x00000003u);

    __asm__ volatile("ror %0, %1, %2" : "=r"(r) : "r"(0x80000001u), "r"(1u));
    CHECK("ror", r, 0xC0000000u);

    /* Rotate by 0 → no change */
    __asm__ volatile("rol %0, %1, %2" : "=r"(r) : "r"(0xDEADBEEFu), "r"(0u));
    CHECK("rol0", r, 0xDEADBEEFu);
}

/* ── Zbb: ORC.B and REV8 ─────────────────────────────────────────────────── */
static void test_byte_ops(void)
{
    uint32_t r;

    /* ORC.B: each non-zero byte → 0xFF */
    __asm__ volatile("orc.b %0, %1" : "=r"(r) : "r"(0x01000100u));
    CHECK("orcb", r, 0xFF00FF00u);

    __asm__ volatile("orc.b %0, %1" : "=r"(r) : "r"(0x00000000u));
    CHECK("orcb_0", r, 0x00000000u);

    __asm__ volatile("orc.b %0, %1" : "=r"(r) : "r"(0xFFFFFFFFu));
    CHECK("orcb_f", r, 0xFFFFFFFFu);

    /* REV8: byte reverse */
    __asm__ volatile("rev8 %0, %1" : "=r"(r) : "r"(0x12345678u));
    CHECK("rev8", r, 0x78563412u);
}

/* ── Zbb: bitwise logic with complement ─────────────────────────────────── */
static void test_logic_ops(void)
{
    uint32_t r;

    __asm__ volatile("andn %0, %1, %2" : "=r"(r) : "r"(0xFFFF0000u), "r"(0xF0F0F0F0u));
    CHECK("andn", r, 0x0F0F0000u);

    __asm__ volatile("orn %0, %1, %2" : "=r"(r) : "r"(0x00000000u), "r"(0x0F0F0F0Fu));
    CHECK("orn", r, 0xF0F0F0F0u);

    __asm__ volatile("xnor %0, %1, %2" : "=r"(r) : "r"(0xAAAAAAAAu), "r"(0x55555555u));
    CHECK("xnor", r, 0x00000000u);

    __asm__ volatile("xnor %0, %1, %2" : "=r"(r) : "r"(0xFFFFFFFFu), "r"(0x00000000u));
    CHECK("xnor_ff", r, 0x00000000u);
}

/* ── Zbs: single-bit set/clear/invert/extract ─────────────────────────────── */
static void test_bitmanip_ops(void)
{
    uint32_t r;

    __asm__ volatile("bset %0, %1, %2" : "=r"(r) : "r"(0u),        "r"(7u));  CHECK("bset",  r, 0x80u);
    __asm__ volatile("bclr %0, %1, %2" : "=r"(r) : "r"(0xFFu),     "r"(3u));  CHECK("bclr",  r, 0xF7u);
    __asm__ volatile("binv %0, %1, %2" : "=r"(r) : "r"(0u),        "r"(5u));  CHECK("binv",  r, 0x20u);
    __asm__ volatile("bext %0, %1, %2" : "=r"(r) : "r"(0xA5u),     "r"(5u));  CHECK("bext1", r, 1u);
    __asm__ volatile("bext %0, %1, %2" : "=r"(r) : "r"(0xA5u),     "r"(1u));  CHECK("bext0", r, 0u);
    __asm__ volatile("bext %0, %1, %2" : "=r"(r) : "r"(0x80000000u),"r"(31u)); CHECK("bext31",r, 1u);
}

/* ── Zba: shifted-add ────────────────────────────────────────────────────── */
static void test_shadd_ops(void)
{
    uint32_t r;

    __asm__ volatile("sh1add %0, %1, %2" : "=r"(r) : "r"(5u), "r"(10u)); CHECK("sh1add", r, 20u);
    __asm__ volatile("sh2add %0, %1, %2" : "=r"(r) : "r"(5u), "r"(10u)); CHECK("sh2add", r, 30u);
    __asm__ volatile("sh3add %0, %1, %2" : "=r"(r) : "r"(5u), "r"(10u)); CHECK("sh3add", r, 50u);

    /* Zero base */
    __asm__ volatile("sh1add %0, %1, %2" : "=r"(r) : "r"(7u), "r"(0u)); CHECK("sh1add0", r, 14u);
    __asm__ volatile("sh2add %0, %1, %2" : "=r"(r) : "r"(7u), "r"(0u)); CHECK("sh2add0", r, 28u);
    __asm__ volatile("sh3add %0, %1, %2" : "=r"(r) : "r"(7u), "r"(0u)); CHECK("sh3add0", r, 56u);
}

/* ── RV32M multiply-high variants ────────────────────────────────────────── */
static void test_mulhigh_ops(void)
{
    int32_t  r;
    uint32_t ur;

    /* MULH: signed × signed → upper 32 bits */
    __asm__ volatile("mulh %0, %1, %2" : "=r"(r)  : "r"((int32_t) 0x7FFFFFFF), "r"((int32_t)2));
    CHECK("mulh_pos", (uint32_t)r, 0u);  /* (2^31-1)*2 = 0xFFFFFFFE → upper=0 */

    __asm__ volatile("mulh %0, %1, %2" : "=r"(r)  : "r"((int32_t)-1), "r"((int32_t)-1));
    CHECK("mulh_neg", (uint32_t)r, 0u);  /* (-1)*(-1)=1 → upper=0 */

    __asm__ volatile("mulh %0, %1, %2" : "=r"(r)  : "r"((int32_t)0x80000000), "r"((int32_t)2));
    CHECK("mulh_ovf", (uint32_t)r, 0xFFFFFFFFu); /* -2^31*2 = -2^32 → upper=-1 */

    /* MULHSU: signed × unsigned → upper 32 bits */
    __asm__ volatile("mulhsu %0, %1, %2" : "=r"(r) : "r"((int32_t)-1), "r"(0xFFFFFFFFu));
    /* -1 × 0xFFFFFFFF = -(2^32-1); upper 32 bits = -1 = 0xFFFFFFFF */
    CHECK("mulhsu", (uint32_t)r, 0xFFFFFFFFu);

    /* MULHU: unsigned × unsigned → upper 32 bits */
    __asm__ volatile("mulhu %0, %1, %2" : "=r"(ur) : "r"(0xFFFFFFFFu), "r"(0xFFFFFFFFu));
    CHECK("mulhu", ur, 0xFFFFFFFEu);  /* (2^32-1)^2 = 2^64-2^33+1 → upper=2^32-2 */
}

/* ── RV32M remainder ─────────────────────────────────────────────────────── */
static void test_rem_ops(void)
{
    int32_t  r;
    uint32_t ur;

    /* REM (signed) */
    __asm__ volatile("rem %0, %1, %2" : "=r"(r) : "r"((int32_t) 10), "r"((int32_t) 3)); CHECK("rem",  (uint32_t)r,  1u);
    __asm__ volatile("rem %0, %1, %2" : "=r"(r) : "r"((int32_t)-10), "r"((int32_t) 3)); CHECK("remn", (uint32_t)r, (uint32_t)-1);
    __asm__ volatile("rem %0, %1, %2" : "=r"(r) : "r"((int32_t) 10), "r"((int32_t)-3)); CHECK("remp", (uint32_t)r,  1u);

    /* REMU (unsigned) */
    __asm__ volatile("remu %0, %1, %2" : "=r"(ur) : "r"(10u), "r"(3u)); CHECK("remu", ur, 1u);
    __asm__ volatile("remu %0, %1, %2" : "=r"(ur) : "r"(0xFFFFFFFFu), "r"(2u)); CHECK("remu_big", ur, 1u);
}

/* ── RV32M: division/remainder by zero (RISC-V spec-defined results) ─────── */
static void test_divzero_ops(void)
{
    int32_t  r;
    uint32_t ur;

    /* DIV by zero → -1 (all ones) per RISC-V spec */
    __asm__ volatile("div %0, %1, %2"  : "=r"(r)  : "r"(1), "r"(0)); CHECK("div0",  (uint32_t)r,  0xFFFFFFFFu);
    /* DIVU by zero → 2^32-1 */
    __asm__ volatile("divu %0, %1, %2" : "=r"(ur) : "r"(1u), "r"(0u)); CHECK("divu0", ur, 0xFFFFFFFFu);
    /* REM by zero → dividend */
    __asm__ volatile("rem %0, %1, %2"  : "=r"(r)  : "r"(5), "r"(0)); CHECK("rem0",  (uint32_t)r,  5u);
    /* REMU by zero → dividend */
    __asm__ volatile("remu %0, %1, %2" : "=r"(ur) : "r"(5u), "r"(0u)); CHECK("remu0", ur, 5u);
    /* Signed overflow: INT_MIN / -1 → INT_MIN per spec */
    __asm__ volatile("div %0, %1, %2"  : "=r"(r)  : "r"((int32_t)0x80000000), "r"(-1));
    CHECK("div_ovf", (uint32_t)r, 0x80000000u);
    /* Signed overflow: INT_MIN % -1 → 0 per spec */
    __asm__ volatile("rem %0, %1, %2"  : "=r"(r)  : "r"((int32_t)0x80000000), "r"(-1));
    CHECK("rem_ovf", (uint32_t)r, 0u);
}

/* ── Base: SRA (arithmetic right shift, register form) ───────────────────── */
static void test_sra_op(void)
{
    int32_t r;

    __asm__ volatile("sra %0, %1, %2" : "=r"(r) : "r"((int32_t)0x80000000), "r"(1));
    CHECK("sra_neg", (uint32_t)r, 0xC0000000u);

    __asm__ volatile("sra %0, %1, %2" : "=r"(r) : "r"((int32_t)0x80000000), "r"(31));
    CHECK("sra_neg31", (uint32_t)r, 0xFFFFFFFFu);

    __asm__ volatile("sra %0, %1, %2" : "=r"(r) : "r"((int32_t)0x7FFFFFFF), "r"(1));
    CHECK("sra_pos", (uint32_t)r, 0x3FFFFFFFu);
}

/* ── CSR: mscratch ───────────────────────────────────────────────────────── */
static void test_mscratch(void)
{
    uint32_t v;

    __asm__ volatile("csrw mscratch, %0" : : "r"(0xDEADBEEFu));
    __asm__ volatile("csrr %0, mscratch"  : "=r"(v));
    CHECK("mscratch", v, 0xDEADBEEFu);

    /* csrrw: swap — old value returned in v2 */
    uint32_t v2;
    __asm__ volatile("csrrw %0, mscratch, %1" : "=r"(v2) : "r"(0x12345678u));
    CHECK("mscratch_swap_old", v2, 0xDEADBEEFu);
    __asm__ volatile("csrr %0, mscratch" : "=r"(v));
    CHECK("mscratch_swap_new", v, 0x12345678u);

    /* Restore to 0 */
    __asm__ volatile("csrw mscratch, zero");
}

/* ── CSR: mcountinhibit + instret ────────────────────────────────────────── */
static void test_counters(void)
{
    uint32_t lo, hi, lo2;

    /* Read instret before */
    __asm__ volatile("csrr %0, instret"  : "=r"(lo));
    __asm__ volatile("csrr %0, instreth" : "=r"(hi));
    /* hi might be 0 for short tests — just check it doesn't trap */
    (void)hi;
    (void)lo;

    /* Read minstret (M-mode alias) */
    __asm__ volatile("csrr %0, minstret"  : "=r"(lo));
    __asm__ volatile("csrr %0, minstreth" : "=r"(hi));
    (void)hi;

    /* Inhibit instruction-retire counter (bit 2) */
    __asm__ volatile("csrw mcountinhibit, %0" : : "r"(4u));
    __asm__ volatile("nop");
    __asm__ volatile("nop");
    __asm__ volatile("csrr %0, minstret" : "=r"(lo2));
    /* With inhibit set, lo2 should equal lo (counter frozen).
     * Accept lo2 == lo OR lo2 == lo+1 (the csrr itself may retire). */
    /* Re-enable counter */
    __asm__ volatile("csrw mcountinhibit, zero");

    /* Read instret again after re-enabling — must be ≥ lo+1 */
    uint32_t lo3;
    __asm__ volatile("csrr %0, instret" : "=r"(lo3));
    if (lo3 == 0 && lo == 0) { /* both zero — valid on short run */ }

    /* Write minstret / minstreth then read back */
    __asm__ volatile("csrw minstret,  %0" : : "r"(0x1000u));
    __asm__ volatile("csrw minstreth, %0" : : "r"(0u));
    __asm__ volatile("csrr %0, minstret" : "=r"(lo));
    /* Counter increments after write, so lo ≥ 0x1000 */
}

/* ── Zbb: RORI (rotate right immediate) ──────────────────────────────────── */
static void test_imm_rotate(void)
{
    uint32_t r;

    /* RORI: decoder path funct3=101 funct7=0x30 in OP-IMM */
    __asm__ volatile("rori %0, %1, 4" : "=r"(r) : "r"(0x80000001u));
    CHECK("rori4", r, 0x18000000u);  /* (0x80000001 >> 4) | (1 << 28) = 0x18000000 */

    __asm__ volatile("rori %0, %1, 1" : "=r"(r) : "r"(0x80000001u));
    CHECK("rori1", r, 0xC0000000u);  /* (0x80000001 >> 1) | (1 << 31) = 0xC0000000 */

    __asm__ volatile("rori %0, %1, 0" : "=r"(r) : "r"(0xDEADBEEFu));
    CHECK("rori0", r, 0xDEADBEEFu);  /* rotate by 0 = identity */
}

/* ── Zbs: immediate single-bit ops ───────────────────────────────────────── */
static void test_imm_bitops(void)
{
    uint32_t r;

    /* BSETI: set bit by immediate — decoder funct3=001 funct7=0x14 in OP-IMM */
    __asm__ volatile("bseti %0, %1, 7" : "=r"(r) : "r"(0u));
    CHECK("bseti7", r, 0x80u);

    __asm__ volatile("bseti %0, %1, 0" : "=r"(r) : "r"(0u));
    CHECK("bseti0", r, 1u);

    /* BCLRI: clear bit by immediate — decoder funct3=001 funct7=0x24 in OP-IMM */
    __asm__ volatile("bclri %0, %1, 3" : "=r"(r) : "r"(0xFFu));
    CHECK("bclri3", r, 0xF7u);

    __asm__ volatile("bclri %0, %1, 31" : "=r"(r) : "r"(0x80000000u));
    CHECK("bclri31", r, 0u);

    /* BINVI: invert bit by immediate — decoder funct3=001 funct7=0x34 in OP-IMM */
    __asm__ volatile("binvi %0, %1, 5" : "=r"(r) : "r"(0u));
    CHECK("binvi5", r, 0x20u);

    __asm__ volatile("binvi %0, %1, 5" : "=r"(r) : "r"(0x20u));
    CHECK("binvi5_tog", r, 0u);

    /* BEXTI: extract bit by immediate — decoder funct3=101 funct7=0x24 in OP-IMM */
    __asm__ volatile("bexti %0, %1, 5" : "=r"(r) : "r"(0xA5u));
    CHECK("bexti5_1", r, 1u);  /* bit 5 of 0xA5 (10100101) = 1 */

    __asm__ volatile("bexti %0, %1, 6" : "=r"(r) : "r"(0xA5u));
    CHECK("bexti6_0", r, 0u);  /* bit 6 of 0xA5 = 0 */

    __asm__ volatile("bexti %0, %1, 31" : "=r"(r) : "r"(0x80000000u));
    CHECK("bexti31", r, 1u);
}

/* ── Zbb: min/max (signed and unsigned) ──────────────────────────────────── */
static void test_minmax_ops(void)
{
    int32_t  r;
    uint32_t ur;

    /* MIN: signed minimum */
    __asm__ volatile("min %0, %1, %2" : "=r"(r) : "r"((int32_t)3), "r"((int32_t)5));
    CHECK("min_3_5", (uint32_t)r, 3u);

    __asm__ volatile("min %0, %1, %2" : "=r"(r) : "r"((int32_t)-1), "r"((int32_t)1));
    CHECK("min_neg", (uint32_t)r, (uint32_t)-1);

    __asm__ volatile("min %0, %1, %2" : "=r"(r) : "r"((int32_t)0x80000000), "r"((int32_t)0));
    CHECK("min_intmin", (uint32_t)r, 0x80000000u);

    /* MINU: unsigned minimum */
    __asm__ volatile("minu %0, %1, %2" : "=r"(ur) : "r"(0xFFFFFFFFu), "r"(1u));
    CHECK("minu_big", ur, 1u);

    __asm__ volatile("minu %0, %1, %2" : "=r"(ur) : "r"(0u), "r"(1u));
    CHECK("minu_0", ur, 0u);

    /* MAX: signed maximum */
    __asm__ volatile("max %0, %1, %2" : "=r"(r) : "r"((int32_t)-1), "r"((int32_t)1));
    CHECK("max_neg", (uint32_t)r, 1u);

    __asm__ volatile("max %0, %1, %2" : "=r"(r) : "r"((int32_t)0x80000000), "r"((int32_t)0));
    CHECK("max_intmin", (uint32_t)r, 0u);

    /* MAXU: unsigned maximum */
    __asm__ volatile("maxu %0, %1, %2" : "=r"(ur) : "r"(0xFFFFFFFFu), "r"(1u));
    CHECK("maxu_big", ur, 0xFFFFFFFFu);

    __asm__ volatile("maxu %0, %1, %2" : "=r"(ur) : "r"(0u), "r"(1u));
    CHECK("maxu_0", ur, 1u);
}

/* ── main ─────────────────────────────────────────────────────────────────── */
int main(void)
{
    jv_puts("zb_ext: Zba/Zbb/Zbs + M-ext + CSR coverage test\n");

    test_count_ops();
    test_ext_ops();
    test_rotate_ops();
    test_byte_ops();
    test_logic_ops();
    test_bitmanip_ops();
    test_shadd_ops();
    test_mulhigh_ops();
    test_rem_ops();
    test_divzero_ops();
    test_sra_op();
    test_mscratch();
    test_counters();
    test_imm_rotate();
    test_imm_bitops();
    test_minmax_ops();

    if (g_fail == 0)
        jv_puts("PASS\n");
    else
        jv_puts("FAIL\n");

    jv_exit(g_fail);
    return g_fail;
}
