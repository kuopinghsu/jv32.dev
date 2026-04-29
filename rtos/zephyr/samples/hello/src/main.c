/*
 * Copyright (c) 2026 jv32 Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * Simple Hello World application for jv32 board
 * Uses magic address console driver for fast simulation output
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/version.h>
#include "jv_platform.h"

void main(void)
{
    printk("*** Booting Zephyr OS build %s ***\n", KERNEL_VERSION_STRING);
    printk("Hello World! jv32 RISC-V Board\n");
    printk("Test completed successfully!\n");
    jv_exit(0);
}
