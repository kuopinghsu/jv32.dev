# Copyright (c) 2026 jv32 Project
# SPDX-License-Identifier: Apache-2.0

# Zephyr module CMakeLists.txt
# Board and SOC files are sourced through board_root and soc_root

set(JV32_IO_BACKEND semihost CACHE STRING "JV32 application I/O backend")

if(NOT JV32_IO_BACKEND STREQUAL "semihost" AND
     NOT JV32_IO_BACKEND STREQUAL "magic" AND
     NOT JV32_IO_BACKEND STREQUAL "uart")
    message(FATAL_ERROR "Unsupported JV32_IO_BACKEND='${JV32_IO_BACKEND}'")
endif()

# Add platform header (sw/include/jv_platform.h) to the application include path
zephyr_include_directories(${CMAKE_CURRENT_SOURCE_DIR}/../../sw/include)
zephyr_library_sources(${CMAKE_CURRENT_SOURCE_DIR}/../../sw/common/jv_io_${JV32_IO_BACKEND}.c)

# Zephyr's default RISC-V trap path does not emulate semihost ebreak marker
# calls; use raw magic behavior for semihost-like backends on this board.
if(JV32_IO_BACKEND STREQUAL "semihost")
    zephyr_compile_definitions(JV_SEMIHOST_ENABLE=0)
endif()

# Add drivers if any driver configs are enabled
if(CONFIG_CONSOLE_JV32 OR CONFIG_UART_JV32)
    add_subdirectory(drivers)
endif()
