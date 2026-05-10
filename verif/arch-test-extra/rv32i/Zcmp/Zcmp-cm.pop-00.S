///////////////////////////////////////////
// rv32i/Zcmp/Zcmp-cm.pop-00.S
//
// Manually written arch-test for cm.pop (Zcmp extension).
// cm.pop {reglist}, stack_adj — loads reglist from stack, increments sp
//
// Load layout (sp_bot = sp before pop = bottom of frame):
//   ra  loaded from sp_bot+12  (for sadj=16, rlist>=5)
//   s0  loaded from sp_bot+8
//   s1  loaded from sp_bot+4   (rlist>=6)
//   s2  loaded from sp_bot+0   (rlist>=7)
//   ra  loaded from sp_bot+28  (for sadj=32, rlist>=5)
//   s0  loaded from sp_bot+24
//   s1  loaded from sp_bot+20  (rlist>=6)
//   s2  loaded from sp_bot+16  (rlist>=7)
//   s3  loaded from sp_bot+12  (rlist>=8)
//
// For each testcase: manually write known values to scratch area, set sp to
// bottom of frame, execute cm.pop, then SIGUPD restored regs and sp.
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

#define TEST_FILE "Zcmp-cm.pop-00.S"
#define SIGUPD_COUNT 21

#include "riscv_arch_test.h"

RVTEST_BEGIN

.option arch, +zcmp

// ============================================================================
// tc1: cm.pop {ra, s0}, 16   (rlist=5, sadj=16)
// Pre-set: ra slot at sp_bot+12, s0 slot at sp_bot+8
// After pop: x1=ra_val, x8=s0_val, sp=sp_bot+16
// SIGUPD: restored_ra (x1), restored_s0 (x8), sp_after  (3 total)
// ============================================================================
  mv x31, x2                    // save sig ptr in x31
  la x30, zcmp_pop_scratch_top  // x30 = scratch stack top
  addi x2, x30, -16             // sp = scratch_top - 16 = bottom of 16-byte frame
  // Write known values into the stack frame
  li x6, 0xC0DE0001
  sw x6, 12(x2)                 // ra slot (sp_bot+12)
  li x6, 0x12345678
  sw x6, 8(x2)                  // s0 slot (sp_bot+8)
Zcmp_cm_pop_cg_tc1:
  cm.pop {ra, s0}, 16
  // x1=0xC0DE0001, x8=0x12345678, x2=scratch_top
Zcmp_cm_pop_cg_tc1_ra:
  RVTEST_SIGUPD(x31, x5, x4, x1, Zcmp_cm_pop_cg_tc1_ra, Zcmp_cm_pop_cg_tc1_ra_str)
Zcmp_cm_pop_cg_tc1_s0:
  RVTEST_SIGUPD(x31, x5, x4, x8, Zcmp_cm_pop_cg_tc1_s0, Zcmp_cm_pop_cg_tc1_s0_str)
Zcmp_cm_pop_cg_tc1_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2, Zcmp_cm_pop_cg_tc1_sp, Zcmp_cm_pop_cg_tc1_sp_str)
  mv x2, x31                    // restore sig ptr

// ============================================================================
// tc2: cm.pop {ra, s0-s1}, 16  (rlist=6, sadj=16)
// Pre-set: ra at sp_bot+12, s0 at sp_bot+8, s1 at sp_bot+4
// SIGUPD: restored_ra (x1), restored_s0 (x8), restored_s1 (x9), sp  (4 total)
// ============================================================================
  mv x31, x2
  la x30, zcmp_pop_scratch_top
  addi x2, x30, -16
  li x6, 0xC0DE0002
  sw x6, 12(x2)
  li x6, 0x23456789
  sw x6, 8(x2)
  li x6, 0x3456789A
  sw x6, 4(x2)
Zcmp_cm_pop_cg_tc2:
  cm.pop {ra, s0-s1}, 16
Zcmp_cm_pop_cg_tc2_ra:
  RVTEST_SIGUPD(x31, x5, x4, x1, Zcmp_cm_pop_cg_tc2_ra, Zcmp_cm_pop_cg_tc2_ra_str)
Zcmp_cm_pop_cg_tc2_s0:
  RVTEST_SIGUPD(x31, x5, x4, x8, Zcmp_cm_pop_cg_tc2_s0, Zcmp_cm_pop_cg_tc2_s0_str)
Zcmp_cm_pop_cg_tc2_s1:
  RVTEST_SIGUPD(x31, x5, x4, x9, Zcmp_cm_pop_cg_tc2_s1, Zcmp_cm_pop_cg_tc2_s1_str)
Zcmp_cm_pop_cg_tc2_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2, Zcmp_cm_pop_cg_tc2_sp, Zcmp_cm_pop_cg_tc2_sp_str)
  mv x2, x31

// ============================================================================
// tc3: cm.pop {ra, s0-s2}, 16  (rlist=7, sadj=16)
// Pre-set: ra at sp_bot+12, s0 at sp_bot+8, s1 at sp_bot+4, s2 at sp_bot+0
// SIGUPD: ra, s0, s1, s2, sp  (5 total)
// ============================================================================
  mv x31, x2
  la x30, zcmp_pop_scratch_top
  addi x2, x30, -16
  li x6, 0xC0DE0003
  sw x6, 12(x2)
  li x6, 0x456789AB
  sw x6, 8(x2)
  li x6, 0x56789ABC
  sw x6, 4(x2)
  li x6, 0x6789ABCD
  sw x6, 0(x2)
Zcmp_cm_pop_cg_tc3:
  cm.pop {ra, s0-s2}, 16
Zcmp_cm_pop_cg_tc3_ra:
  RVTEST_SIGUPD(x31, x5, x4, x1,  Zcmp_cm_pop_cg_tc3_ra, Zcmp_cm_pop_cg_tc3_ra_str)
Zcmp_cm_pop_cg_tc3_s0:
  RVTEST_SIGUPD(x31, x5, x4, x8,  Zcmp_cm_pop_cg_tc3_s0, Zcmp_cm_pop_cg_tc3_s0_str)
Zcmp_cm_pop_cg_tc3_s1:
  RVTEST_SIGUPD(x31, x5, x4, x9,  Zcmp_cm_pop_cg_tc3_s1, Zcmp_cm_pop_cg_tc3_s1_str)
Zcmp_cm_pop_cg_tc3_s2:
  RVTEST_SIGUPD(x31, x5, x4, x18, Zcmp_cm_pop_cg_tc3_s2, Zcmp_cm_pop_cg_tc3_s2_str)
Zcmp_cm_pop_cg_tc3_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2,  Zcmp_cm_pop_cg_tc3_sp, Zcmp_cm_pop_cg_tc3_sp_str)
  mv x2, x31

// ============================================================================
// tc4: cm.pop {ra, s0}, 32   (rlist=5, sadj=32 — extra 16B padding)
// Pre-set: ra at sp_bot+28, s0 at sp_bot+24 (relative to bottom of 32B frame)
// SIGUPD: ra, s0, sp  (3 total)
// ============================================================================
  mv x31, x2
  la x30, zcmp_pop_scratch_top
  addi x2, x30, -32             // sp = scratch_top - 32 = bottom of 32-byte frame
  li x6, 0xC0DE0004
  sw x6, 28(x2)                 // ra slot (sp_bot+28)
  li x6, 0x789ABCDE
  sw x6, 24(x2)                 // s0 slot (sp_bot+24)
Zcmp_cm_pop_cg_tc4:
  cm.pop {ra, s0}, 32
Zcmp_cm_pop_cg_tc4_ra:
  RVTEST_SIGUPD(x31, x5, x4, x1, Zcmp_cm_pop_cg_tc4_ra, Zcmp_cm_pop_cg_tc4_ra_str)
Zcmp_cm_pop_cg_tc4_s0:
  RVTEST_SIGUPD(x31, x5, x4, x8, Zcmp_cm_pop_cg_tc4_s0, Zcmp_cm_pop_cg_tc4_s0_str)
Zcmp_cm_pop_cg_tc4_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2, Zcmp_cm_pop_cg_tc4_sp, Zcmp_cm_pop_cg_tc4_sp_str)
  mv x2, x31

// ============================================================================
// tc5: cm.pop {ra, s0-s3}, 32  (rlist=8, sadj=32)
// Pre-set: ra at sp_bot+28, s0 at +24, s1 at +20, s2 at +16, s3 at +12
// SIGUPD: ra, s0, s1, s2, s3, sp  (6 total)
// ============================================================================
  mv x31, x2
  la x30, zcmp_pop_scratch_top
  addi x2, x30, -32
  li x6, 0xC0DE0005
  sw x6, 28(x2)
  li x6, 0x89ABCDEF
  sw x6, 24(x2)
  li x6, 0x9ABCDEF0
  sw x6, 20(x2)
  li x6, 0xABCDEF01
  sw x6, 16(x2)
  li x6, 0xBCDEF012
  sw x6, 12(x2)
Zcmp_cm_pop_cg_tc5:
  cm.pop {ra, s0-s3}, 32
Zcmp_cm_pop_cg_tc5_ra:
  RVTEST_SIGUPD(x31, x5, x4, x1,  Zcmp_cm_pop_cg_tc5_ra, Zcmp_cm_pop_cg_tc5_ra_str)
Zcmp_cm_pop_cg_tc5_s0:
  RVTEST_SIGUPD(x31, x5, x4, x8,  Zcmp_cm_pop_cg_tc5_s0, Zcmp_cm_pop_cg_tc5_s0_str)
Zcmp_cm_pop_cg_tc5_s1:
  RVTEST_SIGUPD(x31, x5, x4, x9,  Zcmp_cm_pop_cg_tc5_s1, Zcmp_cm_pop_cg_tc5_s1_str)
Zcmp_cm_pop_cg_tc5_s2:
  RVTEST_SIGUPD(x31, x5, x4, x18, Zcmp_cm_pop_cg_tc5_s2, Zcmp_cm_pop_cg_tc5_s2_str)
Zcmp_cm_pop_cg_tc5_s3:
  RVTEST_SIGUPD(x31, x5, x4, x19, Zcmp_cm_pop_cg_tc5_s3, Zcmp_cm_pop_cg_tc5_s3_str)
Zcmp_cm_pop_cg_tc5_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2,  Zcmp_cm_pop_cg_tc5_sp, Zcmp_cm_pop_cg_tc5_sp_str)
  mv x2, x31

RVTEST_CODE_END

RVTEST_DATA_BEGIN

// 64-byte scratch stack for pop operations
.balign 16
zcmp_pop_scratch_space:
  .fill 64, 1, 0
zcmp_pop_scratch_top:

// Testcase strings
Zcmp_cm_pop_cg_tc1_ra_str: .string "\"test: 1; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r5; item: ra\""
Zcmp_cm_pop_cg_tc1_s0_str: .string "\"test: 1; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r5; item: s0\""
Zcmp_cm_pop_cg_tc1_sp_str: .string "\"test: 1; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r5; item: sp\""
Zcmp_cm_pop_cg_tc2_ra_str: .string "\"test: 2; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r6; item: ra\""
Zcmp_cm_pop_cg_tc2_s0_str: .string "\"test: 2; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r6; item: s0\""
Zcmp_cm_pop_cg_tc2_s1_str: .string "\"test: 2; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r6; item: s1\""
Zcmp_cm_pop_cg_tc2_sp_str: .string "\"test: 2; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r6; item: sp\""
Zcmp_cm_pop_cg_tc3_ra_str: .string "\"test: 3; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r7; item: ra\""
Zcmp_cm_pop_cg_tc3_s0_str: .string "\"test: 3; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r7; item: s0\""
Zcmp_cm_pop_cg_tc3_s1_str: .string "\"test: 3; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r7; item: s1\""
Zcmp_cm_pop_cg_tc3_s2_str: .string "\"test: 3; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r7; item: s2\""
Zcmp_cm_pop_cg_tc3_sp_str: .string "\"test: 3; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r7; item: sp\""
Zcmp_cm_pop_cg_tc4_ra_str: .string "\"test: 4; cg: Zcmp_cm.pop_cg; cp: cp_sadj_32_r5; item: ra\""
Zcmp_cm_pop_cg_tc4_s0_str: .string "\"test: 4; cg: Zcmp_cm.pop_cg; cp: cp_sadj_32_r5; item: s0\""
Zcmp_cm_pop_cg_tc4_sp_str: .string "\"test: 4; cg: Zcmp_cm.pop_cg; cp: cp_sadj_32_r5; item: sp\""
Zcmp_cm_pop_cg_tc5_ra_str: .string "\"test: 5; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r8; item: ra\""
Zcmp_cm_pop_cg_tc5_s0_str: .string "\"test: 5; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r8; item: s0\""
Zcmp_cm_pop_cg_tc5_s1_str: .string "\"test: 5; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r8; item: s1\""
Zcmp_cm_pop_cg_tc5_s2_str: .string "\"test: 5; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r8; item: s2\""
Zcmp_cm_pop_cg_tc5_s3_str: .string "\"test: 5; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r8; item: s3\""
Zcmp_cm_pop_cg_tc5_sp_str: .string "\"test: 5; cg: Zcmp_cm.pop_cg; cp: cp_rlist_r8; item: sp\""

RVTEST_DATA_END

RVTEST_SIG_SETUP
