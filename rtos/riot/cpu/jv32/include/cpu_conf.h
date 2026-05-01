/*
 * JV32 RISC-V SoC CPU configuration for RIOT OS
 * SPDX-License-Identifier: LGPL-2.1-only
 */

#pragma once

#include "cpu_conf_common.h"
#include "jv_platform.h"
#include "vendor/clint.h"

/*
 * The JV32 CLIC uses a non-standard mtime/mtimecmp layout:
 *   mtime    at offset 0x4000 (vendor/clint.h has 0xBFF8 — standard CLINT)
 *   mtimecmp at offset 0x4008 (vendor/clint.h has 0x4000 — standard CLINT)
 * Override the vendor defines here so coretimer.c and cpu.c use correct offsets.
 */
#undef  CLINT_MTIME
#undef  CLINT_MTIME_size
#undef  CLINT_MTIMECMP
#undef  CLINT_MTIMECMP_size
#define CLINT_MTIME             (JV_CLIC_MTIME_LO_OFF)     /* 0x4000 */
#define CLINT_MTIME_size        0x8
#define CLINT_MTIMECMP          (JV_CLIC_MTIMECMP_LO_OFF)  /* 0x4008 */
#define CLINT_MTIMECMP_size     0x8

#ifdef __cplusplus
extern "C" {
#endif

/* ── CLINT ─────────────────────────────────────────────────────────── */
/** @brief Base address of the CLINT (matches jv_platform.h JV_CLIC_BASE) */
#define CLINT_BASE_ADDR         (JV_CLIC_BASE)     /* 0x02000000 */

/* ── PLIC ──────────────────────────────────────────────────────────── */
/** @brief Base address of the PLIC (matches jv_platform.h JV_PLIC_BASE) */
#define PLIC_CTRL_ADDR          (JV_PLIC_BASE)      /* 0x0C000000 */
#define PLIC_BASE_ADDR          (PLIC_CTRL_ADDR)

/** @brief Total number of PLIC interrupt sources (JV32 SoC wires 10) */
#define PLIC_NUM_INTERRUPTS     16

/** @brief Number of PLIC priority levels */
#define PLIC_NUM_PRIORITIES     7

/* PLIC register offsets (RIOT PLIC driver uses these) */
#define PLIC_PRIORITY_OFFSET         (JV_PLIC_PRIORITY_OFF)   /* 0x000000 */
#define PLIC_ENABLE_OFFSET           (JV_PLIC_ENABLE_OFF)     /* 0x002000 */
#define PLIC_THRESHOLD_OFFSET        (JV_PLIC_THRESHOLD_OFF)  /* 0x200000 */
#define PLIC_CLAIM_OFFSET            (JV_PLIC_CLAIM_OFF)      /* 0x200004 */

/* Per-target shift amounts (JV32 has a single hart; shifts are irrelevant
 * for hart 0 but must be defined.  Use PLIC standard layout values.) */
#define PLIC_ENABLE_SHIFT_PER_TARGET    7   /* 128 bytes per context */
#define PLIC_THRESHOLD_SHIFT_PER_TARGET 12  /* 4096 bytes per context */
#define PLIC_CLAIM_SHIFT_PER_TARGET     12  /* same as threshold */

/* ── Timer frequency ───────────────────────────────────────────────── */
/**
 * @brief   CLINT mtime tick rate (Hz).
 *
 * JV32 runs mtime at the CPU clock / no prescaler.  The testbench clock
 * is 50 MHz; RIOT uses this value only for tick arithmetic in the
 * coretimer peripheral driver.
 */
#define RTC_FREQ                50000000UL

/* ── Number of PMP entries ─────────────────────────────────────────── */
#define NUM_PMP_ENTRIES         8

#ifdef __cplusplus
}
#endif

/** @} */
