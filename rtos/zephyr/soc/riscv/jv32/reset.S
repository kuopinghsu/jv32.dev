/*
 * Copyright (c) 2026 jv32 Project
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/toolchain.h>

/* Reset entry point */
GTEXT(__reset)
SECTION_FUNC(reset, __reset)
    /* Initialize stack pointer to top of IRAM (128KB at 0x80000000) */
    /* Stack grows down, so set SP to end of IRAM: 0x80000000 + 0x20000 */
    lui sp, %hi(0x80020000)
    addi sp, sp, %lo(0x80020000)

    /* Jump to Zephyr initialization */
    tail z_prep_c
