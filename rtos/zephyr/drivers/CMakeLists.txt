# Copyright (c) 2026 jv32 Project
# SPDX-License-Identifier: Apache-2.0

add_subdirectory_ifdef(CONFIG_CONSOLE_JV32 console)
add_subdirectory_ifdef(CONFIG_UART_JV32 serial)
