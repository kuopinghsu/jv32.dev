# ============================================================================
# File: sw/Makefile
# Project: JV32 RISC-V Processor
# Description: Build system for bare-metal software tests
#
# Usage:
#   make build TEST=<name> [BUILD_DIR=<dir>]  # build a single test
#   make build-all [BUILD_DIR=<dir>]          # build all tests
#   make clean
#
# Any subdirectory of sw/ (except common/ and include/) is a valid test.
# Per-test compiler flags can be set in <test>/makefile.mak via CFLAGS +=
# ============================================================================

# RISC-V cross toolchain prefix
# Prefer RISCV_PREFIX exported by the root Makefile (from env.config),
# falling back to CROSS or a bare riscv32-unknown-elf-
ifdef RISCV_PREFIX
  CROSS ?= $(patsubst %-,%,$(RISCV_PREFIX))
else
  CROSS ?= riscv32-unknown-elf
endif

CC      := $(CROSS)-gcc
CXX     := $(CROSS)-g++
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump
SIZE    := $(CROSS)-size

# Architecture flags: ARCH and ABI are computed and exported by the root Makefile
# based on RV32E_EN / RV32M_EN / AMO_EN.  Defaults below apply when sw/Makefile
# is invoked standalone (e.g. make -C sw build TEST=hello).
ARCH    ?= rv32imac_zicsr
ABI     ?= ilp32

CFLAGS  := -march=$(ARCH) -mabi=$(ABI)
CFLAGS  += -O2 -g
CFLAGS  += -Wall -Wextra
CFLAGS  += -nostartfiles -ffreestanding
CFLAGS  += -ffunction-sections -fdata-sections
CFLAGS  += -Iinclude

CXXFLAGS := $(CFLAGS)

# Per-test optional extra flags: sourced from <test>/makefile.mak if it exists.
# That file may append to CFLAGS, e.g.:  CFLAGS += -O3 -DFOO
SW_DIR := $(CURDIR)
ifneq ($(strip $(TEST)),)
-include $(SW_DIR)/$(TEST)/makefile.mak
endif

# Output directory for ELFs (set by root Makefile; defaults to sw/)
BUILD_DIR ?= .
OBJ_DIR   := $(BUILD_DIR)/obj

# Linker script
COMMON_LINK := common/link.ld

LDFLAGS := -march=$(ARCH) -mabi=$(ABI)
LDFLAGS += -nostartfiles
LDFLAGS += -T $(COMMON_LINK)
LDFLAGS += -Wl,--gc-sections

# Common sources compiled into every test ELF
COMMON_SRCS := common/startup.S $(wildcard common/*.c)

# Discover all test directories (exclude common and include)
TEST_DIRS  := $(shell find $(SW_DIR) -mindepth 1 -maxdepth 1 -type d \
                  ! -name common ! -name include)
TEST_NAMES := $(notdir $(TEST_DIRS))

.PHONY: all build build-all clean disasm help __build-test FORCE
.SECONDARY:

all: build-all

# ----------------------------------------------------------------------------
# Build dispatcher: called by root Makefile as 'make -C sw build TEST=<name>'
# ----------------------------------------------------------------------------
build:
ifndef TEST
	$(error TEST is not set. Usage: make -C sw build TEST=<name> BUILD_DIR=<dir>)
endif
	@$(MAKE) --no-print-directory $(BUILD_DIR)/$(TEST).elf

build-all:
	@failed=0; \
	for test in $(TEST_NAMES); do \
		if ! $(MAKE) --no-print-directory build TEST=$$test; then \
			failed=1; \
		fi; \
	done; \
	if [ $$failed -ne 0 ]; then exit 1; fi

FORCE:

# Generic pattern rule: ELF is rebuilt when common sources, linker script,
# or any source/header under the test directory changes.
.SECONDEXPANSION:
$(BUILD_DIR)/%.elf: $(COMMON_SRCS) $(COMMON_LINK) \
                    $$(wildcard $(SW_DIR)/$$*/*.c $(SW_DIR)/$$*/*.S $(SW_DIR)/$$*/*.cpp $(SW_DIR)/$$*/*.h)
	@$(MAKE) --no-print-directory __build-test TEST=$* OUT=$@

__build-test:
	@echo "=========================================="
	@echo "Building test: $(TEST)"
	@echo "=========================================="
	@mkdir -p $(BUILD_DIR) $(OBJ_DIR)
	@if [ ! -d "$(SW_DIR)/$(TEST)" ]; then \
		echo "Error: Test directory $(SW_DIR)/$(TEST) not found"; \
		exit 1; \
	fi
	@set -e; \
	OBJS=""; \
	for src in $(COMMON_SRCS); do \
		stem=$$(basename $${src%.*}); \
		obj="$(OBJ_DIR)/_common_$${stem}.o"; \
		OBJS="$$OBJS $$obj"; \
		$(CC) $(CFLAGS) -c $$src -o $$obj; \
	done; \
	C_SRCS="$(wildcard $(SW_DIR)/$(TEST)/*.c)"; \
	if [ -n "$$C_SRCS" ]; then \
		for src in $$C_SRCS; do \
			obj="$(OBJ_DIR)/$(TEST)_$$(basename $${src%.c}).o"; \
			OBJS="$$OBJS $$obj"; \
			$(CC) $(CFLAGS) -I$(SW_DIR)/$(TEST) -c $$src -o $$obj; \
		done; \
	fi; \
	S_SRCS="$(wildcard $(SW_DIR)/$(TEST)/*.S)"; \
	if [ -n "$$S_SRCS" ]; then \
		for src in $$S_SRCS; do \
			obj="$(OBJ_DIR)/$(TEST)_$$(basename $${src%.S}).o"; \
			OBJS="$$OBJS $$obj"; \
			$(CC) $(CFLAGS) -I$(SW_DIR)/$(TEST) -c $$src -o $$obj; \
		done; \
	fi; \
	CPP_SRCS="$(wildcard $(SW_DIR)/$(TEST)/*.cpp)"; \
	LINKER="$(CC)"; \
	if [ -n "$$CPP_SRCS" ]; then \
		LINKER="$(CXX)"; \
		for src in $$CPP_SRCS; do \
			obj="$(OBJ_DIR)/$(TEST)_$$(basename $${src%.cpp}).o"; \
			OBJS="$$OBJS $$obj"; \
			$(CXX) $(CXXFLAGS) -I$(SW_DIR)/$(TEST) -c $$src -o $$obj; \
		done; \
	fi; \
	$$LINKER $(LDFLAGS) -Wl,-Map,$(OBJ_DIR)/$(TEST).map -o $(OUT) $$OBJS
	@$(SIZE) $(OUT)

# Disassembly (built on demand)
$(BUILD_DIR)/%.dis: $(BUILD_DIR)/%.elf
	$(OBJDUMP) -d -S $< > $@

## Remove build artifacts
clean:
	@rm -rf $(OBJ_DIR)
	@rm -f $(BUILD_DIR)/*.elf $(BUILD_DIR)/*.map $(BUILD_DIR)/*.dis
	@echo "Clean done."

## Show this help
help:
	@echo "JV32 Software Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all              Build all tests"
	@echo "  build TEST=name  Build a named test (dispatched by root Makefile)"
	@echo "  build-all        Build all discovered tests"
	@echo "  disasm           Generate disassembly for a test"
	@echo "  clean            Remove build outputs"
	@echo ""
	@echo "Variables:"
	@echo "  CROSS=<prefix>   Toolchain prefix (default: riscv32-unknown-elf)"
	@echo "  BUILD_DIR=<dir>  Output directory (default: sw/)"
