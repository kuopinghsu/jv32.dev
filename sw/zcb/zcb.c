/* ============================================================================
 * File: sw/zcb/zcb.c
 * Project: JV32 RISC-V Processor
 * Description: Coverage test for Zcb (RVM23 compressed) instructions.
 *
 * Exercises decoder paths in jv32_rvc.sv that were previously uncovered:
 *
 *   Quad 00, funct3=100 (Zcb byte/halfword loads and stores):
 *     C.LBU  rd',  uimm(rs1')  → LBU  rd',  uimm(rs1')
 *     C.LHU  rd',  uimm(rs1')  → LHU  rd',  uimm(rs1')
 *     C.LH   rd',  uimm(rs1')  → LH   rd',  uimm(rs1')
 *     C.SB   rs2', uimm(rs1')  → SB   rs2', uimm(rs1')
 *     C.SH   rs2', uimm(rs1')  → SH   rs2', uimm(rs1')
 *
 *   Quad 01, funct3=100, funct2=11, ci[12]=1 (Zcb arithmetic, RVM23_EN):
 *     C.MUL    rd', rs2'        → MUL    rd', rd', rs2'
 *     C.ZEXT.B rd'              → ANDI   rd', rd', 0xFF
 *     C.NOT    rd'              → XORI   rd', rd', -1
 *
 * All Zcb instructions encode registers as 3-bit CIW specifiers (x8–x15).
 * Raw .hword encodings pin operands to s0 (x8) and s1 (x9):
 *
 *   Encoding summary (rs1'=rs2'=rd'=s0=x8, rs2'=s1=x9 for loads/stores):
 *
 *   Instruction          .hword    bits [15:0]
 *   C.LBU s1, 0(s0)     0x8004   1000_0000_0000_0100
 *   C.LHU s1, 0(s0)     0x8404   1000_0100_0000_0100
 *   C.LH  s1, 0(s0)     0x8444   1000_0100_0100_0100
 *   C.SB  s1, 0(s0)     0x8804   1000_1000_0000_0100
 *   C.SH  s1, 0(s0)     0x8C04   1000_1100_0000_0100
 *   C.MUL s0, s1        0x9C45   1001_1100_0100_0101
 *   C.ZEXT.B s0         0x9C61   1001_1100_0110_0001
 *   C.NOT s0            0x9C75   1001_1100_0111_0101
 *
 * No makefile.mak override is needed; .hword is assembled as raw 16-bit data
 * regardless of -march, so the standard rv32imac build flags suffice.
 * ============================================================================ */

#include "jv_platform.h"
#include <stdint.h>

static int g_fail = 0;

#define CHECK(label, got, exp) do { \
    if ((uint32_t)(got) != (uint32_t)(exp)) { \
        jv_puts("FAIL " label "\n"); \
        g_fail++; \
    } \
} while (0)

/* Source data for load tests — uninitialised (BSS) to avoid misaligned .data
 * LMA that would fault in the crt0 word-copy loop.  Filled at runtime. */
static volatile uint8_t  src_b[4];
static volatile uint16_t src_h[4];

/* Destination buffers for store tests */
static volatile uint8_t  dst_b[4];
static volatile uint16_t dst_h[4];

/* ---------------------------------------------------------------------------
 * Zcb Quad-00 load instructions
 *
 *   C.LBU rd'=s1(x9), rs1'=s0(x8), uimm=0  →  LBU x9, 0(x8)
 *     [15:13]=100 [12:10]=000 [9:7]=000 [6]=0 [5]=0 [4:2]=001 [1:0]=00
 *
 *   C.LHU rd'=s1(x9), rs1'=s0(x8), uimm=0  →  LHU x9, 0(x8)
 *     [15:13]=100 [12:10]=001 [9:7]=000 [6]=0 [5]=0 [4:2]=001 [1:0]=00
 *
 *   C.LH  rd'=s1(x9), rs1'=s0(x8), uimm=0  →  LH  x9, 0(x8)
 *     [15:13]=100 [12:10]=001 [9:7]=000 [6]=1 [5]=0 [4:2]=001 [1:0]=00
 * --------------------------------------------------------------------------- */
static void test_zcb_loads(void)
{
    register uint32_t rs0 asm("s0");
    register uint32_t rs1 asm("s1");

    /* C.LBU: load byte unsigned → zero-extends */
    rs0 = (uint32_t)(uintptr_t)src_b;
    __asm__ volatile(".hword 0x8004" : "=r"(rs1) : "r"(rs0) : "memory");
    CHECK("c_lbu", rs1, 0xDEu);

    /* C.LHU: load halfword unsigned → zero-extends */
    rs0 = (uint32_t)(uintptr_t)src_h;
    __asm__ volatile(".hword 0x8404" : "=r"(rs1) : "r"(rs0) : "memory");
    CHECK("c_lhu", rs1, 0xCAFEu);

    /* C.LH: load halfword signed → sign-extends (0x8001 → 0xFFFF8001) */
    rs0 = (uint32_t)(uintptr_t)(src_h + 1);
    __asm__ volatile(".hword 0x8444" : "=r"(rs1) : "r"(rs0) : "memory");
    CHECK("c_lh", rs1, 0xFFFF8001u);
}

/* ---------------------------------------------------------------------------
 * Zcb Quad-00 store instructions
 *
 *   C.SB rs2'=s1(x9), rs1'=s0(x8), uimm=0  →  SB x9, 0(x8)
 *     [15:13]=100 [12:10]=010 [9:7]=000 [6]=0 [5]=0 [4:2]=001 [1:0]=00
 *
 *   C.SH rs2'=s1(x9), rs1'=s0(x8), uimm=0  →  SH x9, 0(x8)
 *     [15:13]=100 [12:10]=011 [9:7]=000 [6]=0 [5]=0 [4:2]=001 [1:0]=00
 * --------------------------------------------------------------------------- */
static void test_zcb_stores(void)
{
    register uint32_t rs0 asm("s0");
    register uint32_t rs1 asm("s1");

    /* C.SB: store byte */
    rs0 = (uint32_t)(uintptr_t)dst_b;
    rs1 = 0xABu;
    __asm__ volatile(".hword 0x8804" :: "r"(rs0), "r"(rs1) : "memory");
    CHECK("c_sb", (uint32_t)dst_b[0], 0xABu);

    /* C.SH: store halfword */
    rs0 = (uint32_t)(uintptr_t)dst_h;
    rs1 = 0x1234u;
    __asm__ volatile(".hword 0x8C04" :: "r"(rs0), "r"(rs1) : "memory");
    CHECK("c_sh", (uint32_t)dst_h[0], 0x1234u);
}

/* ---------------------------------------------------------------------------
 * Zcb Quad-01, funct2=11, ci[12]=1 arithmetic (RVM23_EN path)
 *
 *   C.MUL rd'=s0(x8), rs2'=s1(x9)  →  MUL x8, x8, x9
 *     quad=01, funct3=100, funct2=11, ci[12]=1, ci[6:5]=10, ci[9:7]=000, ci[4:2]=001
 *
 *   C.ZEXT.B rd'=s0(x8)             →  ANDI x8, x8, 0xFF
 *     quad=01, funct3=100, funct2=11, ci[12]=1, ci[6:5]=11, ci[9:7]=000, ci[4:2]=000
 *
 *   C.NOT rd'=s0(x8)                →  XORI x8, x8, -1
 *     quad=01, funct3=100, funct2=11, ci[12]=1, ci[6:5]=11, ci[9:7]=000, ci[4:2]=101
 * --------------------------------------------------------------------------- */
static void test_zcb_arith(void)
{
    register uint32_t rs0 asm("s0");
    register uint32_t rs1 asm("s1");

    /* C.MUL: s0 = s0 * s1 */
    rs0 = 6u;
    rs1 = 7u;
    __asm__ volatile(".hword 0x9C45" : "+r"(rs0) : "r"(rs1));
    CHECK("c_mul", rs0, 42u);

    /* C.ZEXT.B: s0 = s0 & 0xFF */
    rs0 = 0xDEADBEFFu;
    __asm__ volatile(".hword 0x9C61" : "+r"(rs0));
    CHECK("c_zextb", rs0, 0xFFu);

    /* C.NOT: s0 = ~s0 */
    rs0 = 0xDEADBEEFu;
    __asm__ volatile(".hword 0x9C75" : "+r"(rs0));
    CHECK("c_not", rs0, 0x21524110u);
}

/* ── main ─────────────────────────────────────────────────────────────────── */
int main(void)
{
    /* Initialise source buffers at runtime (BSS avoids misaligned .data LMA). */
    src_b[0] = 0xDE; src_b[1] = 0xAD; src_b[2] = 0xBE; src_b[3] = 0xEF;
    src_h[0] = 0xCAFE; src_h[1] = 0x8001; src_h[2] = 0x7FFF; src_h[3] = 0x0000;

    jv_puts("zcb: Zcb compressed instruction coverage test\n");

    test_zcb_loads();
    test_zcb_stores();
    test_zcb_arith();

    if (g_fail == 0)
        jv_puts("PASS\n");
    else
        jv_puts("FAIL\n");

    jv_exit(g_fail);
    return g_fail;
}
