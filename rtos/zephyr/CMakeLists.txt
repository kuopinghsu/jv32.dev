# Copyright (c) 2026 jv32 Project
# SPDX-License-Identifier: Apache-2.0

# Zephyr module CMakeLists.txt
# Board and SOC files are sourced through board_root and soc_root

# Add platform header (sw/include/jv_platform.h) to the application include path
zephyr_include_directories(${CMAKE_CURRENT_SOURCE_DIR}/../../sw/include)

# Add drivers if any driver configs are enabled
if(CONFIG_CONSOLE_JV32 OR CONFIG_UART_JV32)
    add_subdirectory(drivers)
endif()
