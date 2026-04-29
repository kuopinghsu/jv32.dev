# Copyright (c) 2026 jv32 Project
# SPDX-License-Identifier: Apache-2.0

if(CONFIG_UART_JV32)
  zephyr_library()
  zephyr_library_sources(uart_jv32.c)
endif()
