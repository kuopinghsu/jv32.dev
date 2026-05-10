///////////////////////////////////////////
// rv32i/Zcmp/Zcmp-cm.popretz-00.S
//
// Manually written arch-test for cm.popretz (Zcmp extension).
// cm.popretz {reglist}, stack_adj — loads reglist from stack, sets a0=0,
//   increments sp, then jumps to restored ra.
// Unlike cm.popret, this zeroes a0 before returning.
//
// Load layout same as cm.pop (sadj=16):
//   ra  loaded from sp_bot+12
//   s0  loaded from sp_bot+8
//   s1  loaded from sp_bot+4   (rlist>=6)
//   s2  loaded from sp_bot+0   (rlist>=7)
//
// Test strategy: write the address of Zcmp_popretz_tcN_return as ra in the
// stack frame. After cm.popretz jumps to that address, check the restored
// non-ra registers, sp, and a0=0.
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

#define TEST_FILE "Zcmp-cm.popretz-00.S"
#define SIGUPD_COUNT 12

#include "riscv_arch_test.h"

RVTEST_BEGIN

.option arch, +zcmp

// ============================================================================
// tc1: cm.popretz {ra, s0}, 16  (rlist=5, sadj=16)
// Sets up: ra=return_label, s0=known_val; a0 set to non-zero before call
// After popretz: x8=known_val, x2=sp_orig, a0=0
// SIGUPD: restored_s0 (x8), sp_after (x2), a0_is_zero (x10)  (3 total)
// ============================================================================
  mv x31, x2                        // save sig ptr in x31
  la x30, zcmp_popretz_scratch_top   // x30 = scratch stack top
  addi x2, x30, -16                  // sp = scratch_top - 16 = frame bottom
  // Write stack frame
  li x6, 0xAA112233
  sw x6, 8(x2)                      // s0 slot
  la x6, Zcmp_popretz_tc1_return    // return address
  sw x6, 12(x2)                     // ra slot
  li x10, 0xDEADBEEF                // a0 = non-zero, must be zeroed by popretz
  li x8,  0xDEADBEEF                // s0 = garbage, will be overwritten
Zcmp_cm_popretz_cg_tc1:
  cm.popretz {ra, s0}, 16            // restores s0, zeroes a0, adjusts sp, jumps ra
Zcmp_popretz_tc1_return:
  // Correct path: x8=0xAA112233, x2=scratch_top, x10=0
Zcmp_cm_popretz_cg_tc1_s0:
  RVTEST_SIGUPD(x31, x5, x4, x8,  Zcmp_cm_popretz_cg_tc1_s0, Zcmp_cm_popretz_cg_tc1_s0_str)
Zcmp_cm_popretz_cg_tc1_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2,  Zcmp_cm_popretz_cg_tc1_sp, Zcmp_cm_popretz_cg_tc1_sp_str)
Zcmp_cm_popretz_cg_tc1_a0:
  RVTEST_SIGUPD(x31, x5, x4, x10, Zcmp_cm_popretz_cg_tc1_a0, Zcmp_cm_popretz_cg_tc1_a0_str)
  mv x2, x31                        // restore sig ptr

// ============================================================================
// tc2: cm.popretz {ra, s0-s1}, 16  (rlist=6, sadj=16)
// Stack: ra=return_label, s0=known0, s1=known1; a0 set non-zero
// SIGUPD: s0 (x8), s1 (x9), sp (x2), a0=0 (x10)  (4 total)
// ============================================================================
  mv x31, x2
  la x30, zcmp_popretz_scratch_top
  addi x2, x30, -16
  li x6, 0xBB223344
  sw x6, 8(x2)                     // s0 slot
  li x6, 0xCC334455
  sw x6, 4(x2)                     // s1 slot
  la x6, Zcmp_popretz_tc2_return
  sw x6, 12(x2)                    // ra slot
  li x10, 0xCAFEBABE               // a0 = non-zero, must be zeroed
  li x8,  0xDEADBEEF
  li x9,  0xDEADBEEF
Zcmp_cm_popretz_cg_tc2:
  cm.popretz {ra, s0-s1}, 16
Zcmp_popretz_tc2_return:
Zcmp_cm_popretz_cg_tc2_s0:
  RVTEST_SIGUPD(x31, x5, x4, x8,  Zcmp_cm_popretz_cg_tc2_s0, Zcmp_cm_popretz_cg_tc2_s0_str)
Zcmp_cm_popretz_cg_tc2_s1:
  RVTEST_SIGUPD(x31, x5, x4, x9,  Zcmp_cm_popretz_cg_tc2_s1, Zcmp_cm_popretz_cg_tc2_s1_str)
Zcmp_cm_popretz_cg_tc2_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2,  Zcmp_cm_popretz_cg_tc2_sp, Zcmp_cm_popretz_cg_tc2_sp_str)
Zcmp_cm_popretz_cg_tc2_a0:
  RVTEST_SIGUPD(x31, x5, x4, x10, Zcmp_cm_popretz_cg_tc2_a0, Zcmp_cm_popretz_cg_tc2_a0_str)
  mv x2, x31

// ============================================================================
// tc3: cm.popretz {ra, s0-s2}, 16  (rlist=7, sadj=16)
// Stack: ra=return_label, s0=known0, s1=known1, s2=known2; a0 set non-zero
// SIGUPD: s0 (x8), s1 (x9), s2 (x18), sp (x2), a0=0 (x10)  (5 total)
// ============================================================================
  mv x31, x2
  la x30, zcmp_popretz_scratch_top
  addi x2, x30, -16
  li x6, 0xDD445566
  sw x6, 8(x2)                    // s0 slot
  li x6, 0xEE556677
  sw x6, 4(x2)                    // s1 slot
  li x6, 0xFF667788
  sw x6, 0(x2)                    // s2 slot
  la x6, Zcmp_popretz_tc3_return
  sw x6, 12(x2)                   // ra slot
  li x10, 0xBAADF00D              // a0 = non-zero, must be zeroed
  li x8,  0xDEADBEEF
  li x9,  0xDEADBEEF
  li x18, 0xDEADBEEF
Zcmp_cm_popretz_cg_tc3:
  cm.popretz {ra, s0-s2}, 16
Zcmp_popretz_tc3_return:
Zcmp_cm_popretz_cg_tc3_s0:
  RVTEST_SIGUPD(x31, x5, x4, x8,  Zcmp_cm_popretz_cg_tc3_s0, Zcmp_cm_popretz_cg_tc3_s0_str)
Zcmp_cm_popretz_cg_tc3_s1:
  RVTEST_SIGUPD(x31, x5, x4, x9,  Zcmp_cm_popretz_cg_tc3_s1, Zcmp_cm_popretz_cg_tc3_s1_str)
Zcmp_cm_popretz_cg_tc3_s2:
  RVTEST_SIGUPD(x31, x5, x4, x18, Zcmp_cm_popretz_cg_tc3_s2, Zcmp_cm_popretz_cg_tc3_s2_str)
Zcmp_cm_popretz_cg_tc3_sp:
  RVTEST_SIGUPD(x31, x5, x4, x2,  Zcmp_cm_popretz_cg_tc3_sp, Zcmp_cm_popretz_cg_tc3_sp_str)
Zcmp_cm_popretz_cg_tc3_a0:
  RVTEST_SIGUPD(x31, x5, x4, x10, Zcmp_cm_popretz_cg_tc3_a0, Zcmp_cm_popretz_cg_tc3_a0_str)
  mv x2, x31

RVTEST_CODE_END

RVTEST_DATA_BEGIN

// 64-byte scratch stack for popretz operations
.balign 16
zcmp_popretz_scratch_space:
  .fill 64, 1, 0
zcmp_popretz_scratch_top:

// Testcase strings
Zcmp_cm_popretz_cg_tc1_s0_str: .string "\"test: 1; cg: Zcmp_cm.popretz_cg; cp: cp_rlist_r5; item: s0\""
Zcmp_cm_popretz_cg_tc1_sp_str: .string "\"test: 1; cg: Zcmp_cm.popretz_cg; cp: cp_rlist_r5; item: sp\""
Zcmp_cm_popretz_cg_tc1_a0_str: .string "\"test: 1; cg: Zcmp_cm.popretz_cg; cp: cp_rlist_r5; item: a0_zero\""
Zcmp_cm_popretz_cg_tc2_s0_str: .string "\"test: 2; cg: Zcmp_cm.popretz_cg; cp: cp_rlist_r6; item: s0\""
Zcmp_cm_popretz_cg_tc2_s1_str: .string "\"test: 2; cg: Zcmp_cm.popretz_cg; cp: cp_rlist_r6; item: s1\""
Zcmp_cm_popretz_cg_tc2_sp_str: .string "\"test: 2; cg: Zcmp_cm.popretz_cg; cp: cp_rlist_r6; item: sp\""
Zcmp_cm_popretz_cg_tc2_a0_str: .string "\"test: 2; cg: Zcmp_cm.popretz_cg; cp: cp_rlist_r6; item: a0_zero\""
Zcmp_cm_popretz_cg_tc3_s0_str: .string "\"test: 3; cg: Zcmp_cm.popretz_cg; cp: cp_rlist_r7; item: s0\""
Zcmp_cm_popretz_cg_tc3_s1_str: .string "\"test: 3; cg: Zcmp_cm.popretz_cg; cp: cp_rlist_r7; item: s1\""
Zcmp_cm_popretz_cg_tc3_s2_str: .string "\"test: 3; cg: Zcmp_cm.popretz_cg; cp: cp_rlist_r7; item: s2\""
Zcmp_cm_popretz_cg_tc3_sp_str: .string "\"test: 3; cg: Zcmp_cm.popretz_cg; cp: cp_rlist_r7; item: sp\""
Zcmp_cm_popretz_cg_tc3_a0_str: .string "\"test: 3; cg: Zcmp_cm.popretz_cg; cp: cp_rlist_r7; item: a0_zero\""

RVTEST_DATA_END

RVTEST_SIG_SETUP
