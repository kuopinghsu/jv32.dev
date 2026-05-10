///////////////////////////////////////////
// rv32i/Zcmp/Zcmp-cm.mva01s-00.S
//
// Manually written arch-test for cm.mva01s (Zcmp extension).
// cm.mva01s r1s, r2s  — copies xreg(r1s) → a0, xreg(r2s) → a1
// s-reg mapping: 0→s0(x8), 1→s1(x9), 2→s2(x18), 3→s3(x19),
//                4→s4(x20), 5→s5(x21), 6→s6(x22), 7→s7(x23)
//
// Copyright (C) 2025 JV32 Project
// SPDX-License-Identifier: Apache-2.0
///////////////////////////////////////////

##### START_TEST_CONFIG #####
# REQUIRED_EXTENSIONS: ['I', 'Zcmp']
# params:
#   MXLEN: 32
# MARCH: rv32imac_zicsr_zaamo_zalrsc_zcmp
##### END_TEST_CONFIG #####

#define TEST_FILE "Zcmp-cm.mva01s-00.S"
#define SIGUPD_COUNT 16

#include "riscv_arch_test.h"

RVTEST_BEGIN

.option arch, +zcmp

/////////////////////////////////
// cp_r1s — test each s-reg as r1s source for a0
// cp_r2s — test each s-reg as r2s source for a1
/////////////////////////////////

// Testcase 1: cm.mva01s s0, s1 (r1s=0→x8=s0, r2s=1→x9=s1)
// s0 (x8) → a0 (x10), s1 (x9) → a1 (x11)
  li x8,  0x11223344
  li x9,  0x55667788
Zcmp_cm_mva01s_cg_tc1:
  cm.mva01s s0, s1
Zcmp_cm_mva01s_cg_tc1_r2:
  RVTEST_SIGUPD(x2, x5, x4, x10, Zcmp_cm_mva01s_cg_tc1,     Zcmp_cm_mva01s_cg_tc1_str)
  RVTEST_SIGUPD(x2, x5, x4, x11, Zcmp_cm_mva01s_cg_tc1_r2, Zcmp_cm_mva01s_cg_tc1_r2_str)

// Testcase 2: cm.mva01s s1, s0 (r1s=1→x9=s1, r2s=0→x8=s0)
// s1 (x9) → a0 (x10), s0 (x8) → a1 (x11)
  li x9,  0x99AABBCC
  li x8,  0xDDEEFF00
Zcmp_cm_mva01s_cg_tc2:
  cm.mva01s s1, s0
Zcmp_cm_mva01s_cg_tc2_r2:
  RVTEST_SIGUPD(x2, x5, x4, x10, Zcmp_cm_mva01s_cg_tc2,     Zcmp_cm_mva01s_cg_tc2_str)
  RVTEST_SIGUPD(x2, x5, x4, x11, Zcmp_cm_mva01s_cg_tc2_r2, Zcmp_cm_mva01s_cg_tc2_r2_str)

// Testcase 3: cm.mva01s s2, s3 (r1s=2→x18=s2, r2s=3→x19=s3)
// s2 (x18) → a0 (x10), s3 (x19) → a1 (x11)
  li x18, 0x01234567
  li x19, 0x89ABCDEF
Zcmp_cm_mva01s_cg_tc3:
  cm.mva01s s2, s3
Zcmp_cm_mva01s_cg_tc3_r2:
  RVTEST_SIGUPD(x2, x5, x4, x10, Zcmp_cm_mva01s_cg_tc3,     Zcmp_cm_mva01s_cg_tc3_str)
  RVTEST_SIGUPD(x2, x5, x4, x11, Zcmp_cm_mva01s_cg_tc3_r2, Zcmp_cm_mva01s_cg_tc3_r2_str)

// Testcase 4: cm.mva01s s3, s2 (r1s=3→x19=s3, r2s=2→x18=s2)
// s3 (x19) → a0 (x10), s2 (x18) → a1 (x11)
  li x19, 0xFEDCBA98
  li x18, 0x76543210
Zcmp_cm_mva01s_cg_tc4:
  cm.mva01s s3, s2
Zcmp_cm_mva01s_cg_tc4_r2:
  RVTEST_SIGUPD(x2, x5, x4, x10, Zcmp_cm_mva01s_cg_tc4,     Zcmp_cm_mva01s_cg_tc4_str)
  RVTEST_SIGUPD(x2, x5, x4, x11, Zcmp_cm_mva01s_cg_tc4_r2, Zcmp_cm_mva01s_cg_tc4_r2_str)

// Testcase 5: cm.mva01s s4, s5 (r1s=4→x20=s4, r2s=5→x21=s5)
// s4 (x20) → a0 (x10), s5 (x21) → a1 (x11)
  li x20, 0xCAFEBABE
  li x21, 0xDEADBEEF
Zcmp_cm_mva01s_cg_tc5:
  cm.mva01s s4, s5
Zcmp_cm_mva01s_cg_tc5_r2:
  RVTEST_SIGUPD(x2, x5, x4, x10, Zcmp_cm_mva01s_cg_tc5,     Zcmp_cm_mva01s_cg_tc5_str)
  RVTEST_SIGUPD(x2, x5, x4, x11, Zcmp_cm_mva01s_cg_tc5_r2, Zcmp_cm_mva01s_cg_tc5_r2_str)

// Testcase 6: cm.mva01s s5, s4 (r1s=5→x21=s5, r2s=4→x20=s4)
// s5 (x21) → a0 (x10), s4 (x20) → a1 (x11)
  li x21, 0xBAADF00D
  li x20, 0xC0FFEE00
Zcmp_cm_mva01s_cg_tc6:
  cm.mva01s s5, s4
Zcmp_cm_mva01s_cg_tc6_r2:
  RVTEST_SIGUPD(x2, x5, x4, x10, Zcmp_cm_mva01s_cg_tc6,     Zcmp_cm_mva01s_cg_tc6_str)
  RVTEST_SIGUPD(x2, x5, x4, x11, Zcmp_cm_mva01s_cg_tc6_r2, Zcmp_cm_mva01s_cg_tc6_r2_str)

// Testcase 7: cm.mva01s s6, s7 (r1s=6→x22=s6, r2s=7→x23=s7)
// s6 (x22) → a0 (x10), s7 (x23) → a1 (x11)
  li x22, 0x12345678
  li x23, 0x9ABCDEF0
Zcmp_cm_mva01s_cg_tc7:
  cm.mva01s s6, s7
Zcmp_cm_mva01s_cg_tc7_r2:
  RVTEST_SIGUPD(x2, x5, x4, x10, Zcmp_cm_mva01s_cg_tc7,     Zcmp_cm_mva01s_cg_tc7_str)
  RVTEST_SIGUPD(x2, x5, x4, x11, Zcmp_cm_mva01s_cg_tc7_r2, Zcmp_cm_mva01s_cg_tc7_r2_str)

// Testcase 8: cm.mva01s s7, s6 (r1s=7→x23=s7, r2s=6→x22=s6)
// s7 (x23) → a0 (x10), s6 (x22) → a1 (x11)
  li x23, 0xABCDEF01
  li x22, 0x23456789
Zcmp_cm_mva01s_cg_tc8:
  cm.mva01s s7, s6
Zcmp_cm_mva01s_cg_tc8_r2:
  RVTEST_SIGUPD(x2, x5, x4, x10, Zcmp_cm_mva01s_cg_tc8,     Zcmp_cm_mva01s_cg_tc8_str)
  RVTEST_SIGUPD(x2, x5, x4, x11, Zcmp_cm_mva01s_cg_tc8_r2, Zcmp_cm_mva01s_cg_tc8_r2_str)

RVTEST_CODE_END

RVTEST_DATA_BEGIN

// Testcase strings
Zcmp_cm_mva01s_cg_tc1_str:    .string "\"test: 1; cg: Zcmp_cm.mva01s_cg; cp: cp_r1s; bin: s0->a0\""
Zcmp_cm_mva01s_cg_tc1_r2_str: .string "\"test: 1; cg: Zcmp_cm.mva01s_cg; cp: cp_r2s; bin: s1->a1\""
Zcmp_cm_mva01s_cg_tc2_str:    .string "\"test: 2; cg: Zcmp_cm.mva01s_cg; cp: cp_r1s; bin: s1->a0\""
Zcmp_cm_mva01s_cg_tc2_r2_str: .string "\"test: 2; cg: Zcmp_cm.mva01s_cg; cp: cp_r2s; bin: s0->a1\""
Zcmp_cm_mva01s_cg_tc3_str:    .string "\"test: 3; cg: Zcmp_cm.mva01s_cg; cp: cp_r1s; bin: s2->a0\""
Zcmp_cm_mva01s_cg_tc3_r2_str: .string "\"test: 3; cg: Zcmp_cm.mva01s_cg; cp: cp_r2s; bin: s3->a1\""
Zcmp_cm_mva01s_cg_tc4_str:    .string "\"test: 4; cg: Zcmp_cm.mva01s_cg; cp: cp_r1s; bin: s3->a0\""
Zcmp_cm_mva01s_cg_tc4_r2_str: .string "\"test: 4; cg: Zcmp_cm.mva01s_cg; cp: cp_r2s; bin: s2->a1\""
Zcmp_cm_mva01s_cg_tc5_str:    .string "\"test: 5; cg: Zcmp_cm.mva01s_cg; cp: cp_r1s; bin: s4->a0\""
Zcmp_cm_mva01s_cg_tc5_r2_str: .string "\"test: 5; cg: Zcmp_cm.mva01s_cg; cp: cp_r2s; bin: s5->a1\""
Zcmp_cm_mva01s_cg_tc6_str:    .string "\"test: 6; cg: Zcmp_cm.mva01s_cg; cp: cp_r1s; bin: s5->a0\""
Zcmp_cm_mva01s_cg_tc6_r2_str: .string "\"test: 6; cg: Zcmp_cm.mva01s_cg; cp: cp_r2s; bin: s4->a1\""
Zcmp_cm_mva01s_cg_tc7_str:    .string "\"test: 7; cg: Zcmp_cm.mva01s_cg; cp: cp_r1s; bin: s6->a0\""
Zcmp_cm_mva01s_cg_tc7_r2_str: .string "\"test: 7; cg: Zcmp_cm.mva01s_cg; cp: cp_r2s; bin: s7->a1\""
Zcmp_cm_mva01s_cg_tc8_str:    .string "\"test: 8; cg: Zcmp_cm.mva01s_cg; cp: cp_r1s; bin: s7->a0\""
Zcmp_cm_mva01s_cg_tc8_r2_str: .string "\"test: 8; cg: Zcmp_cm.mva01s_cg; cp: cp_r2s; bin: s6->a1\""

RVTEST_DATA_END

RVTEST_SIG_SETUP
