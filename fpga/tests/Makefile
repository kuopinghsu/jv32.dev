# fpga/tests/Makefile — JV32 FPGA long-running FreeRTOS stability stress test
#
# Usage:
#   make -C fpga/tests          # build fpga-stress.elf (default: build target)
#   make -C fpga/tests build
#   make -C fpga/tests clean
#
# The resulting ELF can be loaded onto the FPGA via OpenOCD:
#   openocd -f fpga/jtag/jv32_fpga_cjtag.cfg \
#           -c "program build/fpga-stress.elf verify reset exit"
#
# UART output: 921600 8N1 on the on-board AXI UART.
#   Linux:  stty -F /dev/ttyUSBx 921600 raw && cat /dev/ttyUSBx
#   Win/Mac: PuTTY / CoolTerm at 921600 8N1

-include ../../env.config

export RISCV_PREFIX

PROJECT_ROOT := $(realpath ../..)
BUILD_DIR    ?= $(PROJECT_ROOT)/build
BUILD_DIR    := $(abspath $(BUILD_DIR))

ARCH ?= rv32imac_zicsr
ABI  ?= ilp32

RISCV_PREFIX ?= riscv64-unknown-elf-
CC      = $(RISCV_PREFIX)gcc
OBJDUMP = $(RISCV_PREFIX)objdump
READELF = $(RISCV_PREFIX)readelf

FREERTOS_DIR  = $(PROJECT_ROOT)/rtos/freertos
FREERTOS_PORT = $(FREERTOS_DIR)/portable/RISC-V
FREERTOS_SYS  = $(FREERTOS_DIR)/sys

# Source files: FreeRTOS kernel + port + sys stubs + this test
SOURCES = \
	$(FREERTOS_SYS)/freertos_start.S \
	$(FREERTOS_SYS)/freertos_syscall.c \
	fpga_stress.c \
	$(FREERTOS_DIR)/tasks.c \
	$(FREERTOS_DIR)/queue.c \
	$(FREERTOS_DIR)/list.c \
	$(FREERTOS_DIR)/timers.c \
	$(FREERTOS_DIR)/event_groups.c \
	$(FREERTOS_DIR)/stream_buffer.c \
	$(FREERTOS_PORT)/port.c \
	$(FREERTOS_PORT)/portASM.S \
	$(FREERTOS_DIR)/portable/MemMang/heap_4.c

# heap_4.c manages its own static pool (configTOTAL_HEAP_SIZE from FreeRTOSConfig.h),
# giving xPortGetFreeHeapSize() support.  Stack sizes in fpga_stress.c are chosen
# to keep total FreeRTOS heap usage well under the 64 KB default.

CFLAGS  = -march=$(ARCH) -mabi=$(ABI) -O2 -g -Wall -Wextra
CFLAGS += -ffreestanding -nostartfiles
CFLAGS += -ffunction-sections -fdata-sections
CFLAGS += -I$(FREERTOS_DIR)/include
CFLAGS += -I$(FREERTOS_PORT)
CFLAGS += -I$(FREERTOS_SYS)
CFLAGS += -I$(FREERTOS_DIR)/samples/include
CFLAGS += -I$(PROJECT_ROOT)/sw/include

LDFLAGS  = -T $(FREERTOS_SYS)/freertos_link.ld
LDFLAGS += -Wl,--gc-sections
LDFLAGS += -Wl,-Map=$(BUILD_DIR)/fpga-stress.map
LDFLAGS += -lc -lgcc

OUTPUT = $(BUILD_DIR)/fpga-stress.elf

.PHONY: build clean help

help:
	@echo "FPGA FreeRTOS stress test"
	@echo "  make -C fpga/tests build   # build $(OUTPUT)"
	@echo "  make -C fpga/tests clean   # remove build artifacts"
	@echo ""
	@echo "Load on FPGA via OpenOCD (cJTAG):"
	@echo '  openocd -f fpga/jtag/jv32_fpga_cjtag.cfg \'
	@echo '          -c "program build/fpga-stress.elf verify reset exit"'
	@echo ""
	@echo "Connect terminal at 921600 8N1:"
	@echo '  stty -F /dev/ttyUSBx 921600 raw && cat /dev/ttyUSBx'

build: $(OUTPUT)

$(OUTPUT): $(SOURCES)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $^ -o $@
	@$(OBJDUMP) -D $@ > $(BUILD_DIR)/fpga-stress.dis
	@$(READELF) -a $@ > $(BUILD_DIR)/fpga-stress.readelf
	@echo "Built: $@"

clean:
	@rm -f $(BUILD_DIR)/fpga-stress.elf
	@rm -f $(BUILD_DIR)/fpga-stress.map
	@rm -f $(BUILD_DIR)/fpga-stress.dis
	@rm -f $(BUILD_DIR)/fpga-stress.readelf
	@echo "Cleaned fpga-stress build artifacts"
