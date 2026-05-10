///////////////////////////////////////////
// rv32i/Zcmp/Zcmp-cm.push-00.S
//
// Manually written arch-test for cm.push (Zcmp extension).
// cm.push {reglist}, -stack_adj — stores reglist to stack, decrements sp
//
// Store layout (with sp_orig = sp before push, sp_new = sp_orig - sadj):
//   ra  stored at sp_orig-4  = sp_new + (sadj - 4)
//   s0  stored at sp_orig-8  = sp_new + (sadj - 8)
//   s1  stored at sp_orig-12 = sp_new + (sadj - 12)
//   s2  stored at sp_orig-16 = sp_new + (sadj - 16)
//   s3  stored at sp_orig-20 = sp_new + (sadj - 20)
//
// Note: x2 (sp) is used as the actual stack pointer during these tests.
//   x31 (t6) is used as the signature pointer to avoid conflict.
//   x30 (t5) holds the scratch stack top address.
//   x6  (t1) is used as a temp to load back stored values.
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

#define TEST_FILE "Zcmp-cm.push-00.S"
#define SIGUPD_COUNT 21

#include "riscv_arch_test.h"

RVTEST_BEGIN

.option arch, +zcmp

// ============================================================================
// tc1: cm.push {ra, s0}, -16   (rlist=5, sadj=16)
// Store ra at sp_orig-4, s0 at sp_orig-8, sp = sp_orig-16
// After push: ra at sp+12, s0 at sp+8
// SIGUPD: stored_ra, stored_s0, sp_after  (3 total)
// ============================================================================
  mv x31, x2                   // save sig ptr in x31 (running sig ptr)
  la x30, zcmp_scratch_top      // x30 = scratch stack top
  li x1,  0xDEAD0001            // ra = test value
  li x8,  0x11111111            // s0 = test value
  mv x2, x30                   // sp = scratch stack top
Zcmp_cm_push_cg_tc1:
  cm.push {ra, s0}, -16
  // x2 = scratch_top - 16; ra at x2+12, s0 at x2+8
Zcmp_cm_push_cg_tc1_ra:
  lw x6, 12(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc1_ra, Zcmp_cm_push_cg_tc1_ra_str)
Zcmp_cm_push_cg_tc1_s0:
  lw x6, 8(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc1_s0, Zcmp_cm_push_cg_tc1_s0_str)
Zcmp_cm_push_cg_tc1_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2, Zcmp_cm_push_cg_tc1_sp, Zcmp_cm_push_cg_tc1_sp_str)
  mv x2, x31                   // restore sig ptr

// ============================================================================
// tc2: cm.push {ra, s0-s1}, -16  (rlist=6, sadj=16)
// ra at sp+12, s0 at sp+8, s1 at sp+4
// SIGUPD: stored_ra, stored_s0, stored_s1, sp_after  (4 total)
// ============================================================================
  mv x31, x2
  la x30, zcmp_scratch_top
  li x1,  0xDEAD0002
  li x8,  0x22222222
  li x9,  0x33333333
  mv x2, x30
Zcmp_cm_push_cg_tc2:
  cm.push {ra, s0-s1}, -16
Zcmp_cm_push_cg_tc2_ra:
  lw x6, 12(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc2_ra, Zcmp_cm_push_cg_tc2_ra_str)
Zcmp_cm_push_cg_tc2_s0:
  lw x6, 8(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc2_s0, Zcmp_cm_push_cg_tc2_s0_str)
Zcmp_cm_push_cg_tc2_s1:
  lw x6, 4(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc2_s1, Zcmp_cm_push_cg_tc2_s1_str)
Zcmp_cm_push_cg_tc2_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2, Zcmp_cm_push_cg_tc2_sp, Zcmp_cm_push_cg_tc2_sp_str)
  mv x2, x31

// ============================================================================
// tc3: cm.push {ra, s0-s2}, -16  (rlist=7, sadj=16)
// ra at sp+12, s0 at sp+8, s1 at sp+4, s2 at sp+0
// SIGUPD: stored_ra, stored_s0, stored_s1, stored_s2, sp_after  (5 total)
// ============================================================================
  mv x31, x2
  la x30, zcmp_scratch_top
  li x1,  0xDEAD0003
  li x8,  0x44444444
  li x9,  0x55555555
  li x18, 0x66666666
  mv x2, x30
Zcmp_cm_push_cg_tc3:
  cm.push {ra, s0-s2}, -16
Zcmp_cm_push_cg_tc3_ra:
  lw x6, 12(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc3_ra, Zcmp_cm_push_cg_tc3_ra_str)
Zcmp_cm_push_cg_tc3_s0:
  lw x6, 8(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc3_s0, Zcmp_cm_push_cg_tc3_s0_str)
Zcmp_cm_push_cg_tc3_s1:
  lw x6, 4(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc3_s1, Zcmp_cm_push_cg_tc3_s1_str)
Zcmp_cm_push_cg_tc3_s2:
  lw x6, 0(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc3_s2, Zcmp_cm_push_cg_tc3_s2_str)
Zcmp_cm_push_cg_tc3_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2, Zcmp_cm_push_cg_tc3_sp, Zcmp_cm_push_cg_tc3_sp_str)
  mv x2, x31

// ============================================================================
// tc4: cm.push {ra, s0}, -32  (rlist=5, sadj=32 — extra 16B padding)
// ra at sp_orig-4=sp+28, s0 at sp_orig-8=sp+24; sp = sp_orig-32
// SIGUPD: stored_ra, stored_s0, sp_after  (3 total)
// ============================================================================
  mv x31, x2
  la x30, zcmp_scratch_top
  li x1,  0xDEAD0004
  li x8,  0x77777777
  mv x2, x30
Zcmp_cm_push_cg_tc4:
  cm.push {ra, s0}, -32
Zcmp_cm_push_cg_tc4_ra:
  lw x6, 28(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc4_ra, Zcmp_cm_push_cg_tc4_ra_str)
Zcmp_cm_push_cg_tc4_s0:
  lw x6, 24(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc4_s0, Zcmp_cm_push_cg_tc4_s0_str)
Zcmp_cm_push_cg_tc4_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2, Zcmp_cm_push_cg_tc4_sp, Zcmp_cm_push_cg_tc4_sp_str)
  mv x2, x31

// ============================================================================
// tc5: cm.push {ra, s0-s3}, -32  (rlist=8, sadj=32)
// ra at sp+28, s0 at sp+24, s1 at sp+20, s2 at sp+16, s3 at sp+12
// SIGUPD: stored_ra, stored_s0, stored_s1, stored_s2, stored_s3, sp_after  (6)
// ============================================================================
  mv x31, x2
  la x30, zcmp_scratch_top
  li x1,  0xDEAD0005
  li x8,  0x88888888
  li x9,  0x99999999
  li x18, 0xAAAAAAAA
  li x19, 0xBBBBBBBB
  mv x2, x30
Zcmp_cm_push_cg_tc5:
  cm.push {ra, s0-s3}, -32
Zcmp_cm_push_cg_tc5_ra:
  lw x6, 28(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc5_ra, Zcmp_cm_push_cg_tc5_ra_str)
Zcmp_cm_push_cg_tc5_s0:
  lw x6, 24(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc5_s0, Zcmp_cm_push_cg_tc5_s0_str)
Zcmp_cm_push_cg_tc5_s1:
  lw x6, 20(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc5_s1, Zcmp_cm_push_cg_tc5_s1_str)
Zcmp_cm_push_cg_tc5_s2:
  lw x6, 16(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc5_s2, Zcmp_cm_push_cg_tc5_s2_str)
Zcmp_cm_push_cg_tc5_s3:
  lw x6, 12(x2)
  RVTEST_SIGUPD(x31, x5, x4, x6, Zcmp_cm_push_cg_tc5_s3, Zcmp_cm_push_cg_tc5_s3_str)
Zcmp_cm_push_cg_tc5_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2, Zcmp_cm_push_cg_tc5_sp, Zcmp_cm_push_cg_tc5_sp_str)
  mv x2, x31

RVTEST_CODE_END

RVTEST_DATA_BEGIN

// 64-byte scratch stack for push/pop operations
// zcmp_scratch_top is used as sp before each push; stores happen below it.
.balign 16
zcmp_scratch_space:
  .fill 64, 1, 0
zcmp_scratch_top:

// Testcase strings
Zcmp_cm_push_cg_tc1_ra_str: .string "\"test: 1; cg: Zcmp_cm.push_cg; cp: cp_rlist_r5; item: ra\""
Zcmp_cm_push_cg_tc1_s0_str: .string "\"test: 1; cg: Zcmp_cm.push_cg; cp: cp_rlist_r5; item: s0\""
Zcmp_cm_push_cg_tc1_sp_str: .string "\"test: 1; cg: Zcmp_cm.push_cg; cp: cp_rlist_r5; item: sp\""
Zcmp_cm_push_cg_tc2_ra_str: .string "\"test: 2; cg: Zcmp_cm.push_cg; cp: cp_rlist_r6; item: ra\""
Zcmp_cm_push_cg_tc2_s0_str: .string "\"test: 2; cg: Zcmp_cm.push_cg; cp: cp_rlist_r6; item: s0\""
Zcmp_cm_push_cg_tc2_s1_str: .string "\"test: 2; cg: Zcmp_cm.push_cg; cp: cp_rlist_r6; item: s1\""
Zcmp_cm_push_cg_tc2_sp_str: .string "\"test: 2; cg: Zcmp_cm.push_cg; cp: cp_rlist_r6; item: sp\""
Zcmp_cm_push_cg_tc3_ra_str: .string "\"test: 3; cg: Zcmp_cm.push_cg; cp: cp_rlist_r7; item: ra\""
Zcmp_cm_push_cg_tc3_s0_str: .string "\"test: 3; cg: Zcmp_cm.push_cg; cp: cp_rlist_r7; item: s0\""
Zcmp_cm_push_cg_tc3_s1_str: .string "\"test: 3; cg: Zcmp_cm.push_cg; cp: cp_rlist_r7; item: s1\""
Zcmp_cm_push_cg_tc3_s2_str: .string "\"test: 3; cg: Zcmp_cm.push_cg; cp: cp_rlist_r7; item: s2\""
Zcmp_cm_push_cg_tc3_sp_str: .string "\"test: 3; cg: Zcmp_cm.push_cg; cp: cp_rlist_r7; item: sp\""
Zcmp_cm_push_cg_tc4_ra_str: .string "\"test: 4; cg: Zcmp_cm.push_cg; cp: cp_sadj_32_r5; item: ra\""
Zcmp_cm_push_cg_tc4_s0_str: .string "\"test: 4; cg: Zcmp_cm.push_cg; cp: cp_sadj_32_r5; item: s0\""
Zcmp_cm_push_cg_tc4_sp_str: .string "\"test: 4; cg: Zcmp_cm.push_cg; cp: cp_sadj_32_r5; item: sp\""
Zcmp_cm_push_cg_tc5_ra_str: .string "\"test: 5; cg: Zcmp_cm.push_cg; cp: cp_rlist_r8; item: ra\""
Zcmp_cm_push_cg_tc5_s0_str: .string "\"test: 5; cg: Zcmp_cm.push_cg; cp: cp_rlist_r8; item: s0\""
Zcmp_cm_push_cg_tc5_s1_str: .string "\"test: 5; cg: Zcmp_cm.push_cg; cp: cp_rlist_r8; item: s1\""
Zcmp_cm_push_cg_tc5_s2_str: .string "\"test: 5; cg: Zcmp_cm.push_cg; cp: cp_rlist_r8; item: s2\""
Zcmp_cm_push_cg_tc5_s3_str: .string "\"test: 5; cg: Zcmp_cm.push_cg; cp: cp_rlist_r8; item: s3\""
Zcmp_cm_push_cg_tc5_sp_str: .string "\"test: 5; cg: Zcmp_cm.push_cg; cp: cp_rlist_r8; item: sp\""

RVTEST_DATA_END

RVTEST_SIG_SETUP
