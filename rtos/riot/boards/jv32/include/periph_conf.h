/*
 * JV32 peripheral configuration for RIOT OS
 * SPDX-License-Identifier: LGPL-2.1-only
 */

#pragma once

/**
 * @ingroup     boards_jv32
 * @{
 *
 * @file
 * @brief       JV32 peripheral configuration (UART, timer)
 */

#include "periph_cpu.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @name    UART configuration
 *
 * The JV32 SoC has one UART at 0x20010000.  We expose it as UART_DEV(0).
 * @{
 */
#define UART_NUMOF      (1U)
/** @} */

/**
 * @name    Timer configuration
 *
 * RIOT's coretimer driver uses the RISC-V CLINT machine timer.
 * Only one timer device (TIM_DEV(0)) is exposed.
 * @{
 */
#define TIMER_NUMOF     (1U)
/** @} */

#ifdef __cplusplus
}
#endif

/** @} */
