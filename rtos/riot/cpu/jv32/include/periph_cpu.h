/*
 * JV32 RISC-V SoC peripheral CPU definitions for RIOT OS
 * SPDX-License-Identifier: LGPL-2.1-only
 */

#pragma once

/**
 * @ingroup     cpu_jv32
 * @{
 *
 * @file
 * @brief       JV32 peripheral CPU type definitions
 */

#include <inttypes.h>
#include "periph_cpu_common.h"
#include "cpu.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief   Overwrite the default gpio_t type definition
 */
#ifndef HAVE_GPIO_T
#define HAVE_GPIO_T
typedef uint8_t gpio_t;
#endif

/**
 * @brief   Definition of a fitting UNDEF value for GPIO
 */
#define GPIO_UNDEF          (0xff)

/**
 * @brief   Define a CPU-specific GPIO pin generator macro
 */
#define GPIO_PIN(x, y)      ((gpio_t)((x) | (y)))

#ifdef __cplusplus
}
#endif

/** @} */
