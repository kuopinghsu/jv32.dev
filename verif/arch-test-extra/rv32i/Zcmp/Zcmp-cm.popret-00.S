///////////////////////////////////////////
// rv32i/Zcmp/Zcmp-cm.popret-00.S
//
// Manually written arch-test for cm.popret (Zcmp extension).
// cm.popret {reglist}, stack_adj — loads reglist from stack, increments sp,
//   then jumps to restored ra (same as pop + ret).
// a0 is preserved (not cleared, unlike cm.popretz).
//
// Load layout same as cm.pop:
//   ra  loaded from sp_bot+12  (sadj=16)
//   s0  loaded from sp_bot+8
//   s1  loaded from sp_bot+4   (rlist>=6)
//   s2  loaded from sp_bot+0   (rlist>=7)
//
// Test strategy: write the address of Zcmp_popret_tcN_return as ra in the
// stack frame. After cm.popret jumps to that address, check the restored
// non-ra registers, sp, and a0 (which must be preserved).
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

#define TEST_FILE "Zcmp-cm.popret-00.S"
#define SIGUPD_COUNT 12

#include "riscv_arch_test.h"

RVTEST_BEGIN

.option arch, +zcmp

// ============================================================================
// tc1: cm.popret {ra, s0}, 16  (rlist=5, sadj=16)
// Sets up stack frame with ra=return_label, s0=known_val
// After popret: x8=known_val, x2=sp_orig, a0 preserved
// SIGUPD: restored_s0 (x8), sp_after (x2), a0_preserved (x10)  (3 total)
// ============================================================================
  mv x31, x2                       // save sig ptr in x31
  la x30, zcmp_popret_scratch_top   // x30 = scratch stack top
  addi x2, x30, -16                 // sp = scratch_top - 16 = frame bottom
  // Write stack frame
  li x6, 0x11AABB99
  sw x6, 8(x2)                     // s0 slot (sp_bot+8)
  la x6, Zcmp_popret_tc1_return    // return address
  sw x6, 12(x2)                    // ra slot (sp_bot+12)
  li x10, 0xA0B0C0D0               // a0 = known value, must survive popret
  li x8, 0xDEADBEEF                // s0 = garbage, will be overwritten
Zcmp_cm_popret_cg_tc1:
  cm.popret {ra, s0}, 16            // loads s0, adjusts sp, jumps to ra
Zcmp_popret_tc1_return:
  // Correct path: x8=0x11AABB99, x2=scratch_top, x10=0xA0B0C0D0
Zcmp_cm_popret_cg_tc1_s0:
  RVTEST_SIGUPD(x31, x5, x4, x8,  Zcmp_cm_popret_cg_tc1_s0, Zcmp_cm_popret_cg_tc1_s0_str)
Zcmp_cm_popret_cg_tc1_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2,  Zcmp_cm_popret_cg_tc1_sp, Zcmp_cm_popret_cg_tc1_sp_str)
Zcmp_cm_popret_cg_tc1_a0:
  RVTEST_SIGUPD(x31, x5, x4, x10, Zcmp_cm_popret_cg_tc1_a0, Zcmp_cm_popret_cg_tc1_a0_str)
  mv x2, x31                       // restore sig ptr

// ============================================================================
// tc2: cm.popret {ra, s0-s1}, 16  (rlist=6, sadj=16)
// Stack: ra=return_label, s0=known_val0, s1=known_val1
// SIGUPD: s0 (x8), s1 (x9), sp (x2), a0 (x10)  (4 total)
// ============================================================================
  mv x31, x2
  la x30, zcmp_popret_scratch_top
  addi x2, x30, -16
  li x6, 0x22CC3344
  sw x6, 8(x2)                    // s0 slot
  li x6, 0x33445566
  sw x6, 4(x2)                    // s1 slot (sp_bot+4)
  la x6, Zcmp_popret_tc2_return
  sw x6, 12(x2)                   // ra slot
  li x10, 0xB1C1D1E1              // a0 = known, must survive
  li x8, 0xDEADBEEF
  li x9, 0xDEADBEEF
Zcmp_cm_popret_cg_tc2:
  cm.popret {ra, s0-s1}, 16
Zcmp_popret_tc2_return:
Zcmp_cm_popret_cg_tc2_s0:
  RVTEST_SIGUPD(x31, x5, x4, x8,  Zcmp_cm_popret_cg_tc2_s0, Zcmp_cm_popret_cg_tc2_s0_str)
Zcmp_cm_popret_cg_tc2_s1:
  RVTEST_SIGUPD(x31, x5, x4, x9,  Zcmp_cm_popret_cg_tc2_s1, Zcmp_cm_popret_cg_tc2_s1_str)
Zcmp_cm_popret_cg_tc2_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2,  Zcmp_cm_popret_cg_tc2_sp, Zcmp_cm_popret_cg_tc2_sp_str)
Zcmp_cm_popret_cg_tc2_a0:
  RVTEST_SIGUPD(x31, x5, x4, x10, Zcmp_cm_popret_cg_tc2_a0, Zcmp_cm_popret_cg_tc2_a0_str)
  mv x2, x31

// ============================================================================
// tc3: cm.popret {ra, s0-s2}, 16  (rlist=7, sadj=16)
// Stack: ra=return_label, s0=known0, s1=known1, s2=known2
// SIGUPD: s0 (x8), s1 (x9), s2 (x18), sp (x2), a0 (x10)  (5 total)
// ============================================================================
  mv x31, x2
  la x30, zcmp_popret_scratch_top
  addi x2, x30, -16
  li x6, 0x44556677
  sw x6, 8(x2)                   // s0 slot
  li x6, 0x55667788
  sw x6, 4(x2)                   // s1 slot
  li x6, 0x66778899
  sw x6, 0(x2)                   // s2 slot (sp_bot+0)
  la x6, Zcmp_popret_tc3_return
  sw x6, 12(x2)                  // ra slot
  li x10, 0xC2D2E2F2             // a0 = known, must survive
  li x8,  0xDEADBEEF
  li x9,  0xDEADBEEF
  li x18, 0xDEADBEEF
Zcmp_cm_popret_cg_tc3:
  cm.popret {ra, s0-s2}, 16
Zcmp_popret_tc3_return:
Zcmp_cm_popret_cg_tc3_s0:
  RVTEST_SIGUPD(x31, x5, x4, x8,  Zcmp_cm_popret_cg_tc3_s0, Zcmp_cm_popret_cg_tc3_s0_str)
Zcmp_cm_popret_cg_tc3_s1:
  RVTEST_SIGUPD(x31, x5, x4, x9,  Zcmp_cm_popret_cg_tc3_s1, Zcmp_cm_popret_cg_tc3_s1_str)
Zcmp_cm_popret_cg_tc3_s2:
  RVTEST_SIGUPD(x31, x5, x4, x18, Zcmp_cm_popret_cg_tc3_s2, Zcmp_cm_popret_cg_tc3_s2_str)
Zcmp_cm_popret_cg_tc3_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2,  Zcmp_cm_popret_cg_tc3_sp, Zcmp_cm_popret_cg_tc3_sp_str)
Zcmp_cm_popret_cg_tc3_a0:
  RVTEST_SIGUPD(x31, x5, x4, x10, Zcmp_cm_popret_cg_tc3_a0, Zcmp_cm_popret_cg_tc3_a0_str)
  mv x2, x31

RVTEST_CODE_END

RVTEST_DATA_BEGIN

// 64-byte scratch stack for popret operations
.balign 16
zcmp_popret_scratch_space:
  .fill 64, 1, 0
zcmp_popret_scratch_top:

// Testcase strings
Zcmp_cm_popret_cg_tc1_s0_str: .string "\"test: 1; cg: Zcmp_cm.popret_cg; cp: cp_rlist_r5; item: s0\""
Zcmp_cm_popret_cg_tc1_sp_str: .string "\"test: 1; cg: Zcmp_cm.popret_cg; cp: cp_rlist_r5; item: sp\""
Zcmp_cm_popret_cg_tc1_a0_str: .string "\"test: 1; cg: Zcmp_cm.popret_cg; cp: cp_rlist_r5; item: a0\""
Zcmp_cm_popret_cg_tc2_s0_str: .string "\"test: 2; cg: Zcmp_cm.popret_cg; cp: cp_rlist_r6; item: s0\""
Zcmp_cm_popret_cg_tc2_s1_str: .string "\"test: 2; cg: Zcmp_cm.popret_cg; cp: cp_rlist_r6; item: s1\""
Zcmp_cm_popret_cg_tc2_sp_str: .string "\"test: 2; cg: Zcmp_cm.popret_cg; cp: cp_rlist_r6; item: sp\""
Zcmp_cm_popret_cg_tc2_a0_str: .string "\"test: 2; cg: Zcmp_cm.popret_cg; cp: cp_rlist_r6; item: a0\""
Zcmp_cm_popret_cg_tc3_s0_str: .string "\"test: 3; cg: Zcmp_cm.popret_cg; cp: cp_rlist_r7; item: s0\""
Zcmp_cm_popret_cg_tc3_s1_str: .string "\"test: 3; cg: Zcmp_cm.popret_cg; cp: cp_rlist_r7; item: s1\""
Zcmp_cm_popret_cg_tc3_s2_str: .string "\"test: 3; cg: Zcmp_cm.popret_cg; cp: cp_rlist_r7; item: s2\""
Zcmp_cm_popret_cg_tc3_sp_str: .string "\"test: 3; cg: Zcmp_cm.popret_cg; cp: cp_rlist_r7; item: sp\""
Zcmp_cm_popret_cg_tc3_a0_str: .string "\"test: 3; cg: Zcmp_cm.popret_cg; cp: cp_rlist_r7; item: a0\""

RVTEST_DATA_END

RVTEST_SIG_SETUP
