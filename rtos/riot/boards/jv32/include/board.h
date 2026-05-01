/*
 * JV32 board definitions for RIOT OS
 * SPDX-License-Identifier: LGPL-2.1-only
 */

#pragma once

/**
 * @ingroup     boards_jv32
 * @{
 *
 * @file
 * @brief       Board-level configuration for the JV32 RISC-V SoC
 */

#include "cpu.h"
#include "cpu_conf.h"
#include "periph_conf.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief   String constants identifying the platform
 */
#define RIOT_BOARD   "jv32"
#define RIOT_CPU     "jv32"
#define RIOT_ARCH    "rv32i"

#ifdef __cplusplus
}
#endif

/** @} */
