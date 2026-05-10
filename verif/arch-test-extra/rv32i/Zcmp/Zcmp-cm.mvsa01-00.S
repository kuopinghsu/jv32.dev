///////////////////////////////////////////
// rv32i/Zcmp/Zcmp-cm.mvsa01-00.S
//
// Manually written arch-test for cm.mvsa01 (Zcmp extension).
// cm.mvsa01 r1s, r2s  — copies a0 → xreg(r1s), a1 → xreg(r2s)
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

#define TEST_FILE "Zcmp-cm.mvsa01-00.S"
#define SIGUPD_COUNT 16

#include "riscv_arch_test.h"

RVTEST_BEGIN

.option arch, +zcmp

/////////////////////////////////
// cp_r1s — test each s-reg as r1s destination for a0
// cp_r2s — test each s-reg as r2s destination for a1
/////////////////////////////////

// Testcase 1: cm.mvsa01 s0, s1 (r1s=0→x8=s0, r2s=1→x9=s1)
// a0 (x10) → s0 (x8), a1 (x11) → s1 (x9)
  li x10, 0xA0A0A0A0
  li x11, 0xB1B1B1B1
Zcmp_cm_mvsa01_cg_tc1:
  cm.mvsa01 s0, s1
Zcmp_cm_mvsa01_cg_tc1_r2:
  RVTEST_SIGUPD(x2, x5, x4, x8, Zcmp_cm_mvsa01_cg_tc1,    Zcmp_cm_mvsa01_cg_tc1_str)
  RVTEST_SIGUPD(x2, x5, x4, x9, Zcmp_cm_mvsa01_cg_tc1_r2, Zcmp_cm_mvsa01_cg_tc1_r2_str)

// Testcase 2: cm.mvsa01 s1, s0 (r1s=1→x9=s1, r2s=0→x8=s0)
// a0 → s1 (x9), a1 → s0 (x8)
  li x10, 0xC2C2C2C2
  li x11, 0xD3D3D3D3
Zcmp_cm_mvsa01_cg_tc2:
  cm.mvsa01 s1, s0
Zcmp_cm_mvsa01_cg_tc2_r2:
  RVTEST_SIGUPD(x2, x5, x4, x9, Zcmp_cm_mvsa01_cg_tc2,    Zcmp_cm_mvsa01_cg_tc2_str)
  RVTEST_SIGUPD(x2, x5, x4, x8, Zcmp_cm_mvsa01_cg_tc2_r2, Zcmp_cm_mvsa01_cg_tc2_r2_str)

// Testcase 3: cm.mvsa01 s2, s3 (r1s=2→x18=s2, r2s=3→x19=s3)
// a0 → s2 (x18), a1 → s3 (x19)
  li x10, 0xE4E4E4E4
  li x11, 0xF5F5F5F5
Zcmp_cm_mvsa01_cg_tc3:
  cm.mvsa01 s2, s3
Zcmp_cm_mvsa01_cg_tc3_r2:
  RVTEST_SIGUPD(x2, x5, x4, x18, Zcmp_cm_mvsa01_cg_tc3,    Zcmp_cm_mvsa01_cg_tc3_str)
  RVTEST_SIGUPD(x2, x5, x4, x19, Zcmp_cm_mvsa01_cg_tc3_r2, Zcmp_cm_mvsa01_cg_tc3_r2_str)

// Testcase 4: cm.mvsa01 s3, s2 (r1s=3→x19=s3, r2s=2→x18=s2)
// a0 → s3 (x19), a1 → s2 (x18)
  li x10, 0x16161616
  li x11, 0x27272727
Zcmp_cm_mvsa01_cg_tc4:
  cm.mvsa01 s3, s2
Zcmp_cm_mvsa01_cg_tc4_r2:
  RVTEST_SIGUPD(x2, x5, x4, x19, Zcmp_cm_mvsa01_cg_tc4,    Zcmp_cm_mvsa01_cg_tc4_str)
  RVTEST_SIGUPD(x2, x5, x4, x18, Zcmp_cm_mvsa01_cg_tc4_r2, Zcmp_cm_mvsa01_cg_tc4_r2_str)

// Testcase 5: cm.mvsa01 s4, s5 (r1s=4→x20=s4, r2s=5→x21=s5)
// a0 → s4 (x20), a1 → s5 (x21)
  li x10, 0x38383838
  li x11, 0x49494949
Zcmp_cm_mvsa01_cg_tc5:
  cm.mvsa01 s4, s5
Zcmp_cm_mvsa01_cg_tc5_r2:
  RVTEST_SIGUPD(x2, x5, x4, x20, Zcmp_cm_mvsa01_cg_tc5,    Zcmp_cm_mvsa01_cg_tc5_str)
  RVTEST_SIGUPD(x2, x5, x4, x21, Zcmp_cm_mvsa01_cg_tc5_r2, Zcmp_cm_mvsa01_cg_tc5_r2_str)

// Testcase 6: cm.mvsa01 s5, s4 (r1s=5→x21=s5, r2s=4→x20=s4)
// a0 → s5 (x21), a1 → s4 (x20)
  li x10, 0x5A5A5A5A
  li x11, 0x6B6B6B6B
Zcmp_cm_mvsa01_cg_tc6:
  cm.mvsa01 s5, s4
Zcmp_cm_mvsa01_cg_tc6_r2:
  RVTEST_SIGUPD(x2, x5, x4, x21, Zcmp_cm_mvsa01_cg_tc6,    Zcmp_cm_mvsa01_cg_tc6_str)
  RVTEST_SIGUPD(x2, x5, x4, x20, Zcmp_cm_mvsa01_cg_tc6_r2, Zcmp_cm_mvsa01_cg_tc6_r2_str)

// Testcase 7: cm.mvsa01 s6, s7 (r1s=6→x22=s6, r2s=7→x23=s7)
// a0 → s6 (x22), a1 → s7 (x23)
  li x10, 0x7C7C7C7C
  li x11, 0x8D8D8D8D
Zcmp_cm_mvsa01_cg_tc7:
  cm.mvsa01 s6, s7
Zcmp_cm_mvsa01_cg_tc7_r2:
  RVTEST_SIGUPD(x2, x5, x4, x22, Zcmp_cm_mvsa01_cg_tc7,    Zcmp_cm_mvsa01_cg_tc7_str)
  RVTEST_SIGUPD(x2, x5, x4, x23, Zcmp_cm_mvsa01_cg_tc7_r2, Zcmp_cm_mvsa01_cg_tc7_r2_str)

// Testcase 8: cm.mvsa01 s7, s6 (r1s=7→x23=s7, r2s=6→x22=s6)
// a0 → s7 (x23), a1 → s6 (x22)
  li x10, 0x9E9E9E9E
  li x11, 0xAFAFAFAF
Zcmp_cm_mvsa01_cg_tc8:
  cm.mvsa01 s7, s6
Zcmp_cm_mvsa01_cg_tc8_r2:
  RVTEST_SIGUPD(x2, x5, x4, x23, Zcmp_cm_mvsa01_cg_tc8,    Zcmp_cm_mvsa01_cg_tc8_str)
  RVTEST_SIGUPD(x2, x5, x4, x22, Zcmp_cm_mvsa01_cg_tc8_r2, Zcmp_cm_mvsa01_cg_tc8_r2_str)

RVTEST_CODE_END

RVTEST_DATA_BEGIN

// Testcase strings
Zcmp_cm_mvsa01_cg_tc1_str:    .string "\"test: 1; cg: Zcmp_cm.mvsa01_cg; cp: cp_r1s; bin: s0\""
Zcmp_cm_mvsa01_cg_tc1_r2_str: .string "\"test: 1; cg: Zcmp_cm.mvsa01_cg; cp: cp_r2s; bin: s1\""
Zcmp_cm_mvsa01_cg_tc2_str:    .string "\"test: 2; cg: Zcmp_cm.mvsa01_cg; cp: cp_r1s; bin: s1\""
Zcmp_cm_mvsa01_cg_tc2_r2_str: .string "\"test: 2; cg: Zcmp_cm.mvsa01_cg; cp: cp_r2s; bin: s0\""
Zcmp_cm_mvsa01_cg_tc3_str:    .string "\"test: 3; cg: Zcmp_cm.mvsa01_cg; cp: cp_r1s; bin: s2\""
Zcmp_cm_mvsa01_cg_tc3_r2_str: .string "\"test: 3; cg: Zcmp_cm.mvsa01_cg; cp: cp_r2s; bin: s3\""
Zcmp_cm_mvsa01_cg_tc4_str:    .string "\"test: 4; cg: Zcmp_cm.mvsa01_cg; cp: cp_r1s; bin: s3\""
Zcmp_cm_mvsa01_cg_tc4_r2_str: .string "\"test: 4; cg: Zcmp_cm.mvsa01_cg; cp: cp_r2s; bin: s2\""
Zcmp_cm_mvsa01_cg_tc5_str:    .string "\"test: 5; cg: Zcmp_cm.mvsa01_cg; cp: cp_r1s; bin: s4\""
Zcmp_cm_mvsa01_cg_tc5_r2_str: .string "\"test: 5; cg: Zcmp_cm.mvsa01_cg; cp: cp_r2s; bin: s5\""
Zcmp_cm_mvsa01_cg_tc6_str:    .string "\"test: 6; cg: Zcmp_cm.mvsa01_cg; cp: cp_r1s; bin: s5\""
Zcmp_cm_mvsa01_cg_tc6_r2_str: .string "\"test: 6; cg: Zcmp_cm.mvsa01_cg; cp: cp_r2s; bin: s4\""
Zcmp_cm_mvsa01_cg_tc7_str:    .string "\"test: 7; cg: Zcmp_cm.mvsa01_cg; cp: cp_r1s; bin: s6\""
Zcmp_cm_mvsa01_cg_tc7_r2_str: .string "\"test: 7; cg: Zcmp_cm.mvsa01_cg; cp: cp_r2s; bin: s7\""
Zcmp_cm_mvsa01_cg_tc8_str:    .string "\"test: 8; cg: Zcmp_cm.mvsa01_cg; cp: cp_r1s; bin: s7\""
Zcmp_cm_mvsa01_cg_tc8_r2_str: .string "\"test: 8; cg: Zcmp_cm.mvsa01_cg; cp: cp_r2s; bin: s6\""

RVTEST_DATA_END

RVTEST_SIG_SETUP
