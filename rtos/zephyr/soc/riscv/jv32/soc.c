/*
 * Copyright (c) 2026 jv32 Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * SOC initialization for jv32
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/init.h>
#include <soc.h>

static int jv32_soc_init(void)
{
    return 0;
}

SYS_INIT(jv32_soc_init, PRE_KERNEL_2, 0);
