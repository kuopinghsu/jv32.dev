// rvtest_config.h
// JV32 RV32IMAC rvtest configuration header
// SPDX-License-Identifier: Apache-2.0

// JV32 has no PMP
#define RVMODEL_PMP_GRAIN 0
#define RVMODEL_NUM_PMPS  0

// Zicntr support flags
#define ZICNTR_SUPPORTED

// JV32 is M-mode only — no U or S mode
// #define U_SUPPORTED
// #define S_SUPPORTED
