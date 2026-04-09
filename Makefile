# ============================================================================
# JV32 RISC-V SoC Project Makefile
# Root build system for the RV32IMAC 3-stage pipeline processor
# ============================================================================

SHELL := /bin/bash

# On macOS prefer gmake (4.x) over system make (3.81)
MAKE := $(shell command -v gmake 2>/dev/null || command -v make)

# Auto-initialize env.config from template if it does not exist
ifeq ($(wildcard env.config),)
$(shell cp env.config.template env.config)
$(info NOTE: env.config was created from env.config.template.)
$(info Edit env.config to set your tool paths before rebuilding.)
endif

# Load environment configuration (tool paths)
-include env.config

# Export so sub-makes (sw/Makefile) inherit
export RISCV_PREFIX
export VERILATOR

# Append additional tool paths if specified
ifdef PATH_APPEND
export PATH := $(PATH):$(PATH_APPEND)
endif

# ============================================================================
# Project directories
# ============================================================================
RTL_DIR  = rtl
CORE_DIR = $(RTL_DIR)/jv32/core
JV32_DIR = $(RTL_DIR)/jv32
AXI_DIR  = $(RTL_DIR)/axi
MEM_DIR  = $(RTL_DIR)/memories
TB_DIR    = testbench
SW_DIR    = sw
SIM_DIR   = sim
VERIF_DIR = verif
BUILD_DIR ?= build

BUILD_DIR_ABS := $(abspath $(BUILD_DIR))

# ============================================================================
# RISC-V toolchain
# ============================================================================
RISCV_PREFIX ?= riscv32-unknown-elf-
CC      = $(RISCV_PREFIX)gcc
OBJDUMP = $(RISCV_PREFIX)objdump

# ============================================================================
# Verilator settings
# ============================================================================
VERILATOR      ?= verilator
VERILATOR_JOBS ?= 0
SVLINT         ?= None

VERILATOR_FLAGS  = -Wall -Wno-UNSIGNED --trace --trace-fst --cc --exe --build -j $(VERILATOR_JOBS)
VERILATOR_FLAGS += -CFLAGS "-I$(abspath $(SIM_DIR))"
VERILATOR_FLAGS += -sv --timescale 1ns/1ps
VERILATOR_FLAGS += --top-module tb_jv32_soc
VERILATOR_FLAGS += -Wno-UNDRIVEN -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -Wno-SYNCASYNCNET -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT
VERILATOR_FLAGS += -CFLAGS "-Wall -Wno-bool-operation -Wno-parentheses-equality -Wno-unused-variable"
VERILATOR_FLAGS += --assert

# Verilator lint-only flags (all warnings enabled, -Werror-IMPLICIT, no simulation output)
VERILATOR_LINT_FLAGS  = --lint-only -Wall -Wno-UNSIGNED
VERILATOR_LINT_FLAGS += -sv --timescale 1ns/1ps
VERILATOR_LINT_FLAGS += --top-module tb_jv32_soc
VERILATOR_LINT_FLAGS += -Wno-UNDRIVEN -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -Wno-SYNCASYNCNET
VERILATOR_LINT_FLAGS += -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT
VERILATOR_LINT_FLAGS += -Werror-IMPLICIT
VERILATOR_LINT_FLAGS += --assert

# RTL-only sources (no testbench) used for per-module lint
RTL_ONLY_SRCS = $(filter-out $(TB_DIR)/%, $(RTL_SOURCES))

# Modules to lint individually: RTL-only, skip package files
LINT_MODULE_LIST = $(filter-out %_pkg.sv, $(RTL_ONLY_SRCS))

# Shared per-module lint flags (packages always supplied as context)
# -Wno-UNDRIVEN:    expected when ports are unconnected at standalone top
# -Wno-UNUSEDSIGNAL/-Wno-UNUSEDPARAM/-Wno-DECLFILENAME: noisy for standalone modules
# -Wno-SYNCASYNCNET: false positive for async-reset FF
# NOTE: no -pvalue+ here; parameters use module defaults when linting individually
LINT_MOD_FLAGS  = --lint-only -Wall -Wno-UNSIGNED -sv
LINT_MOD_FLAGS += -Wno-UNDRIVEN -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -Wno-SYNCASYNCNET -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT -Werror-IMPLICIT
LINT_MOD_FLAGS += -I$(CORE_DIR) -I$(JV32_DIR) -I$(AXI_DIR) -I$(RTL_DIR)

# Simulation parameters (override on command line, e.g. make build-rtl FAST_MUL=0)
ifdef FAST_MUL
  VERILATOR_FLAGS += -pvalue+FAST_MUL=$(FAST_MUL)
endif
ifdef FAST_DIV
  VERILATOR_FLAGS += -pvalue+FAST_DIV=$(FAST_DIV)
endif
ifdef FAST_SHIFT
  VERILATOR_FLAGS += -pvalue+FAST_SHIFT=$(FAST_SHIFT)
endif
ifdef BP_EN
  VERILATOR_FLAGS += -pvalue+BP_EN=$(BP_EN)
endif
ifdef IRAM_SIZE
  VERILATOR_FLAGS += -pvalue+IRAM_SIZE=$(IRAM_SIZE)
endif
ifdef DRAM_SIZE
  VERILATOR_FLAGS += -pvalue+DRAM_SIZE=$(DRAM_SIZE)
endif

# Debug output
#   DEBUG=1  — enable level-1 messages (DEBUG1 macro)
#   DEBUG=2  — enable level-1 + level-2 per-group messages (DEBUG1 + DEBUG2)
#   DEBUG_GROUP=0x<hex>  — bitmask of groups to show (default: all)
DEBUG       ?=
DEBUG_GROUP ?=
ifdef DEBUG
  ifeq ($(DEBUG),1)
    VERILATOR_FLAGS += +define+DEBUG +define+DEBUG_LEVEL_1
    VERILATOR_FLAGS += -CFLAGS "-DDEBUG=1"
  else ifeq ($(DEBUG),2)
    VERILATOR_FLAGS += +define+DEBUG +define+DEBUG_LEVEL_1 +define+DEBUG_LEVEL_2
    VERILATOR_FLAGS += -CFLAGS "-DDEBUG=2"
    ifdef DEBUG_GROUP
      _DG_DEC := $(shell printf '%d' '$(DEBUG_GROUP)' 2>/dev/null || printf '%s' '$(DEBUG_GROUP)')
      VERILATOR_FLAGS += +define+DEBUG_GROUP=$(_DG_DEC)
    endif
  endif
endif

# ============================================================================
# Source file lists
# ============================================================================

# Package files must come first so types are visible during elaboration
RTL_SOURCES = \
    $(AXI_DIR)/axi_pkg.sv \
    $(CORE_DIR)/jv32_pkg.sv \
    $(filter-out $(CORE_DIR)/jv32_pkg.sv, $(wildcard $(CORE_DIR)/*.sv)) \
    $(filter-out $(AXI_DIR)/axi_pkg.sv,   $(wildcard $(AXI_DIR)/*.sv)) \
    $(wildcard $(JV32_DIR)/*.sv) \
    $(wildcard $(MEM_DIR)/*.sv) \
    $(TB_DIR)/uart_loopback.sv \
    $(TB_DIR)/tb_jv32_soc.sv

TB_SOURCES = \
    $(TB_DIR)/tb_jv32_soc.cpp \
    $(TB_DIR)/elfloader.cpp \
    $(SIM_DIR)/riscv-dis.cpp

# Output binary
BUILD_TARGET = $(BUILD_DIR)/jv32soc

# Stamp file: rebuilt only when Verilator parameters change
RTL_PARAMS_STAMP = $(BUILD_DIR)/.build_params
RTL_BUILD_PARAMS = FAST_MUL=$(FAST_MUL) FAST_DIV=$(FAST_DIV) FAST_SHIFT=$(FAST_SHIFT) BP_EN=$(BP_EN) DEBUG=$(DEBUG) DEBUG_GROUP=$(DEBUG_GROUP)

# ============================================================================
# Phony targets
# ============================================================================
.PHONY: all build-rtl rtl-build sim sw-all sw-% wave clean help info \
        rtl-% rtl-all sim-% sim-all lint lint-full lint-modules lint-decl \
        lint-svlint sim-build compare-% compare-all arch-test-% FORCE \
        rtl-freertos-% rtl-freertos-all sim-freertos-% sim-freertos-all \
        compare-freertos-% compare-freertos-all freertos-list-tests

# Default: build RTL simulator
all: rtl-all sim-all compare-all rtl-freertos-all sim-freertos-all compare-freertos-all arch-test-run

# ============================================================================
# Build RTL simulator
# ============================================================================
build-rtl: $(BUILD_TARGET)

# Alias
rtl-build: build-rtl

$(RTL_PARAMS_STAMP): FORCE
	@mkdir -p $(BUILD_DIR)
	@printf '%s' "$(RTL_BUILD_PARAMS)" | cmp -s - $@ || printf '%s' "$(RTL_BUILD_PARAMS)" > $@

$(BUILD_TARGET): $(RTL_SOURCES) $(TB_SOURCES) $(RTL_PARAMS_STAMP)
	@echo "=========================================="
	@echo "Building JV32 SoC with Verilator"
	@echo "=========================================="
	@echo "Verilator: $(VERILATOR)"
	@echo "Build dir: $(BUILD_DIR)"
	@echo "Output:    $(BUILD_TARGET)"
	@echo ""
	@mkdir -p $(BUILD_DIR)
	@rm -rf $(BUILD_DIR)/objdir
	$(VERILATOR) $(VERILATOR_FLAGS) \
	    -Mdir $(BUILD_DIR)/objdir \
	    -o ../jv32soc \
	    -I$(CORE_DIR) \
	    -I$(JV32_DIR) \
	    -I$(AXI_DIR) \
	    -I$(MEM_DIR) \
	    -I$(RTL_DIR) \
	    $(RTL_SOURCES) \
	    $(TB_SOURCES)
	@echo ""
	@echo "=========================================="
	@echo "Build complete!"
	@echo "Simulator: $(BUILD_TARGET)"
	@echo "=========================================="

FORCE:

# ============================================================================
# Lint
# ============================================================================

# Lint umbrella: runs all four lint passes in sequence.
# Stops on the first failing pass.
lint: lint-full lint-modules lint-decl lint-svlint

# Full-design Verilator lint (all RTL + testbench compiled together)
lint-full:
	@echo "=========================================="
	@echo "Linting RTL with Verilator"
	@echo "=========================================="
	@echo "Verilator: $(VERILATOR)"
	@echo ""
	$(VERILATOR) $(VERILATOR_LINT_FLAGS) \
	    -I$(CORE_DIR) \
	    -I$(JV32_DIR) \
	    -I$(AXI_DIR) \
	    -I$(MEM_DIR) \
	    -I$(RTL_DIR) \
	    $(RTL_SOURCES)
	@echo ""
	@echo "=========================================="
	@echo "Lint passed!"
	@echo "=========================================="

# Per-module lint: lint every RTL module individually as Verilator top.
# This catches issues (e.g. MULTIDRIVEN) that are silently dropped when
# modules are inlined during full-design elaboration.
lint-modules:
	@echo "=========================================="
	@echo "Per-module RTL lint ($(words $(LINT_MODULE_LIST)) modules)"
	@echo "=========================================="
	@fail=0; \
	for sv in $(LINT_MODULE_LIST); do \
	    mod=$$(basename $$sv .sv); \
	    printf "  %-30s ... " "$$mod"; \
	    if $(VERILATOR) $(LINT_MOD_FLAGS) --top-module $$mod \
	            $(RTL_ONLY_SRCS) >/tmp/_lint_$$mod.log 2>&1; then \
	        echo "OK"; \
	    else \
	        echo "FAIL"; \
	        cat /tmp/_lint_$$mod.log; \
	        fail=1; \
	    fi; \
	done; \
	if [ $$fail -eq 0 ]; then \
	    echo "=========================================="; \
	    echo "All modules passed lint!"; \
	    echo "=========================================="; \
	else \
	    echo "=========================================="; \
	    echo "Per-module lint FAILED"; \
	    echo "=========================================="; \
	    exit 1; \
	fi

# Declaration-order check: detect signals used before their declaration line.
# Synthesis tools (DC, Genus, Vivado strict mode) reject such forward references.
lint-decl:
	@echo "=========================================="
	@echo "Declaration-order check ($(words $(RTL_ONLY_SRCS)) files)"
	@echo "=========================================="
	@python3 scripts/check_decl_order.py $(RTL_ONLY_SRCS)

# svlint structural/intent lint of RTL source files.
# Skipped automatically when SVLINT is 'None' or the binary does not exist.
# Rules are read from .svlint.toml.
lint-svlint:
	@echo "=========================================="
	@echo "svlint RTL check"
	@echo "=========================================="
	@if [ "$(SVLINT)" = "None" ] || [ -z "$(SVLINT)" ]; then \
	    echo "SVLINT is set to None or unset — skipping svlint."; \
	elif ! [ -x "$(SVLINT)" ]; then \
	    echo "svlint binary not found at: $(SVLINT) — skipping."; \
	else \
	    echo "svlint: $(SVLINT)"; \
	    echo "config: .svlint.toml"; \
	    $(SVLINT) $(RTL_ONLY_SRCS) && \
	    echo "" && \
	    echo "==========================================" && \
	    echo "svlint passed!" && \
	    echo "=========================================="; \
	fi

# ============================================================================
# Run simulation
# Usage:
#   make sim ELF=sw/tests/hello.elf
#   make rtl-hello          (build sw/tests/hello.elf then simulate)
#   make rtl-trap_test      (build sw/tests/trap_test.elf then simulate)
# Optional:
#   WAVE=fst    — dump FST waveform to $(BUILD_DIR)/jv32soc.fst
#   TRACE=1     — print instruction trace
#   MAX_CYCLES=N — stop after N cycles (default: unlimited)
#   TIMEOUT=N    — wall-clock timeout in seconds (default: 120; 0=no limit)
# ============================================================================
TIMEOUT     ?= 120
TIMEOUT_ARG  = $(if $(MAX_CYCLES),--max-cycles=$(MAX_CYCLES)) $(if $(TIMEOUT),--timeout=$(TIMEOUT))

sim: build-rtl
ifndef ELF
	$(error ELF is not set. Usage: make sim ELF=<path/to/test.elf>)
endif
	@cd $(BUILD_DIR) && ./jv32soc \
	    $(if $(filter 1 fst,$(WAVE)),--trace jv32soc.fst) \
	    $(if $(filter vcd,$(WAVE)),--trace jv32soc.vcd) \
	    $(TIMEOUT_ARG) \
	    $(abspath $(ELF))
	@echo ""
	@if [ "$(WAVE)" = "1" ] || [ "$(WAVE)" = "fst" ]; then \
	    echo "Waveform: $(BUILD_DIR)/jv32soc.fst"; \
	elif [ "$(WAVE)" = "vcd" ]; then \
	    echo "Waveform: $(BUILD_DIR)/jv32soc.vcd"; \
	fi

# Convenience pattern: build sw/<test> then simulate with RTL
# Examples: make rtl-hello, make rtl-coremark, make rtl-dhry
# Optional: WAVE=fst, TRACE=1, MAX_CYCLES=N, TIMEOUT=N
rtl-%: build-rtl $(BUILD_DIR)/%.elf
	@echo "=========================================="
	@echo "Running test '$*' with RTL simulator"
	@echo "=========================================="
	@cd $(BUILD_DIR) && ./jv32soc \
	    $(if $(filter 1 fst,$(WAVE)),--trace jv32soc.fst) \
	    $(if $(filter vcd,$(WAVE)),--trace jv32soc.vcd) \
	    $(if $(filter 1,$(TRACE)),--rtl-trace -) \
	    $(TIMEOUT_ARG) \
	    $*.elf
	@echo "=========================================="
	@if [ "$(WAVE)" = "1" ] || [ "$(WAVE)" = "fst" ]; then \
	    echo "Waveform saved to: $(BUILD_DIR)/jv32soc.fst"; \
	fi

# Build ELF via sw/Makefile dispatcher (handles tests/, coremark/, dhry/)
$(BUILD_DIR)/%.elf:
	@$(MAKE) -C $(SW_DIR) --no-print-directory build TEST=$* BUILD_DIR=$(BUILD_DIR_ABS)

# ============================================================================
# Software build
# ============================================================================

# Discover top-level software tests under sw/ (exclude shared support dirs).
SW_TESTS := $(sort $(notdir $(shell find $(SW_DIR) -mindepth 1 -maxdepth 1 -type d \
                  ! -name common ! -name include 2>/dev/null)))
SW_TEST_COUNT := $(words $(SW_TESTS))

# Build all software tests
sw-all:
	@$(MAKE) -C $(SW_DIR) --no-print-directory all BUILD_DIR=$(BUILD_DIR_ABS)

# Run all software tests with the RTL simulator
rtl-all: build-rtl
	@echo "=========================================="
	@echo "Running all software tests with RTL simulator"
	@echo "Tests ($(SW_TEST_COUNT)): $(SW_TESTS)"
	@echo "=========================================="
	@failed=0; idx=0; \
	for test in $(SW_TESTS); do \
		idx=$$((idx+1)); \
		echo ""; \
		echo "[rtl-all $$idx/$(SW_TEST_COUNT)] $$test"; \
		if ! $(MAKE) --no-print-directory rtl-$$test; then \
			failed=1; \
		fi; \
	done; \
	echo ""; \
	if [ $$failed -ne 0 ]; then \
		echo "rtl-all: one or more tests failed."; \
		exit 1; \
	fi; \
	echo "rtl-all: all $(SW_TEST_COUNT) tests passed."

# Run all software tests with the software simulator
sim-all: sim-build
	@echo "=========================================="
	@echo "Running all software tests with software simulator"
	@echo "Tests ($(SW_TEST_COUNT)): $(SW_TESTS)"
	@echo "=========================================="
	@failed=0; idx=0; \
	for test in $(SW_TESTS); do \
		idx=$$((idx+1)); \
		echo ""; \
		echo "[sim-all $$idx/$(SW_TEST_COUNT)] $$test"; \
		if ! $(MAKE) --no-print-directory sim-$$test; then \
			failed=1; \
		fi; \
	done; \
	echo ""; \
	if [ $$failed -ne 0 ]; then \
		echo "sim-all: one or more tests failed."; \
		exit 1; \
	fi; \
	echo "sim-all: all $(SW_TEST_COUNT) tests passed."

# Compare software-vs-RTL traces for all software tests
compare-all: $(JV32SIM) build-rtl
	@echo "=========================================="
	@echo "Comparing traces for all software tests"
	@echo "Tests ($(SW_TEST_COUNT)): $(SW_TESTS)"
	@echo "=========================================="
	@failed=0; idx=0; \
	for test in $(SW_TESTS); do \
		idx=$$((idx+1)); \
		echo ""; \
		echo "[compare-all $$idx/$(SW_TEST_COUNT)] $$test"; \
		if ! $(MAKE) --no-print-directory compare-$$test; then \
			failed=1; \
		fi; \
	done; \
	echo ""; \
	if [ $$failed -ne 0 ]; then \
		echo "compare-all: one or more tests failed."; \
		exit 1; \
	fi; \
	echo "compare-all: all $(SW_TEST_COUNT) tests passed."

# Build a specific software test: make sw-hello, make sw-coremark, make sw-dhry
sw-%:
	@$(MAKE) -C $(SW_DIR) --no-print-directory build TEST=$* BUILD_DIR=$(BUILD_DIR_ABS)

# ============================================================================
# Waveform viewer
# ============================================================================
GTKWAVE ?= gtkwave
WAVE_FILE ?= $(BUILD_DIR)/jv32soc.fst

wave:
	$(GTKWAVE) $(WAVE_FILE) &

# ============================================================================
# Software simulator
# ============================================================================
JV32SIM = $(BUILD_DIR)/jv32sim

$(JV32SIM): $(SIM_DIR)/jv32sim.cpp $(SIM_DIR)/riscv-dis.cpp
	@mkdir -p $(BUILD_DIR)
	g++ -O2 -Wall -Wextra -std=c++14 -o $@ $(SIM_DIR)/jv32sim.cpp $(SIM_DIR)/riscv-dis.cpp

sim-build: $(JV32SIM)

# Convenience pattern: build sw/<test>.elf then simulate with software simulator
# Examples: make sim-hello, make sim-trap_test
# Optional: MAX_INSNS=N, TIMEOUT=N
SIM_MAX_INSNS_ARG = $(if $(MAX_INSNS),--max-insns=$(MAX_INSNS)) $(if $(TIMEOUT),--timeout=$(TIMEOUT))

sim-%: $(BUILD_DIR)/%.elf $(JV32SIM)
	@echo "=========================================="
	@echo "Running test '$*' with software simulator"
	@echo "=========================================="
	$(JV32SIM) $(SIM_MAX_INSNS_ARG) $(BUILD_DIR)/$*.elf
	@echo "=========================================="
	@echo "Done."
	@echo "=========================================="

# ============================================================================
# Trace comparison: software simulator vs RTL simulator
# Usage:
#   make compare-<test>     e.g. make compare-hello, make compare-trap_test
#
# Builds <test>.elf, jv32sim, and the RTL simulation binary, then runs
# both and diffs the instruction traces (only non-x0 register writes).
# ============================================================================
compare-%: $(BUILD_DIR)/%.elf $(JV32SIM) build-rtl
	@echo "=========================================="
	@echo " JV32 Trace Comparison: $*"
	@echo "=========================================="
	@echo ""
	@echo "[1/3] Running software simulator..."
	@$(JV32SIM) --trace $(BUILD_DIR)/sim_trace.txt $(BUILD_DIR)/$*.elf \
	    || (echo "FAIL: software simulator exited non-zero"; exit 1)
	@echo ""
	@echo "[2/3] Running RTL simulator..."
	@$(BUILD_DIR)/jv32soc --rtl-trace $(BUILD_DIR)/rtl_trace.txt \
	    $(BUILD_DIR)/$*.elf 2>/dev/null \
	    || (echo "FAIL: RTL simulator exited non-zero"; exit 1)
	@echo ""
	@echo "[3/3] Comparing traces (sim=RTL-format vs rtl=Spike-format)..."
	@python3 scripts/trace_compare.py \
	    $(BUILD_DIR)/sim_trace.txt \
	    $(BUILD_DIR)/rtl_trace.txt \
	    || exit 1

# ============================================================================
# FreeRTOS tests
# ============================================================================
FREERTOS_DIR = rtos/freertos

# Build a FreeRTOS ELF via the FreeRTOS Makefile
$(BUILD_DIR)/freertos-%.elf: FORCE
	@$(MAKE) -C $(FREERTOS_DIR) --no-print-directory build TEST=$* BUILD_DIR=$(BUILD_DIR_ABS)

freertos-list-tests:
	@$(MAKE) -C $(FREERTOS_DIR) --no-print-directory list-tests

# Run a FreeRTOS test with the RTL simulator
rtl-freertos-%: build-rtl $(BUILD_DIR)/freertos-%.elf
	@echo "=========================================="
	@echo "Running FreeRTOS test '$*' with RTL simulator"
	@echo "=========================================="
	@cd $(BUILD_DIR) && ./jv32soc \
	    $(if $(filter 1 fst,$(WAVE)),--trace jv32soc.fst) \
	    $(if $(filter vcd,$(WAVE)),--trace jv32soc.vcd) \
	    $(if $(filter 1,$(TRACE)),--rtl-trace -) \
	    $(TIMEOUT_ARG) \
	    freertos-$*.elf
	@echo "=========================================="
	@if [ "$(WAVE)" = "1" ] || [ "$(WAVE)" = "fst" ]; then \
	    echo "Waveform saved to: $(BUILD_DIR)/jv32soc.fst"; \
	fi

# Run all FreeRTOS tests with the RTL simulator
rtl-freertos-all: build-rtl
	@echo "=========================================="
	@echo "Running all FreeRTOS tests with RTL simulator"
	@echo "=========================================="
	@failed=0; \
	for t in $$($(MAKE) -s -C $(FREERTOS_DIR) list-tests 2>/dev/null); do \
		echo ""; \
		echo "[rtl-freertos-all] $$t"; \
		if ! $(MAKE) --no-print-directory rtl-freertos-$$t; then failed=1; fi; \
	done; \
	echo ""; \
	if [ $$failed -ne 0 ]; then \
		echo "rtl-freertos-all: one or more tests failed."; exit 1; \
	fi; \
	echo "rtl-freertos-all: all tests passed."

# Run a FreeRTOS test with the software simulator
sim-freertos-%: $(BUILD_DIR)/freertos-%.elf $(JV32SIM)
	@echo "=========================================="
	@echo "Running FreeRTOS test '$*' with software simulator"
	@echo "=========================================="
	$(JV32SIM) $(SIM_MAX_INSNS_ARG) $(BUILD_DIR)/freertos-$*.elf
	@echo "=========================================="
	@echo "Done."
	@echo "=========================================="

# Run all FreeRTOS tests with the software simulator
sim-freertos-all: sim-build
	@echo "=========================================="
	@echo "Running all FreeRTOS tests with software simulator"
	@echo "=========================================="
	@failed=0; \
	for t in $$($(MAKE) -s -C $(FREERTOS_DIR) list-tests 2>/dev/null); do \
		echo ""; \
		echo "[sim-freertos-all] $$t"; \
		if ! $(MAKE) --no-print-directory sim-freertos-$$t; then failed=1; fi; \
	done; \
	echo ""; \
	if [ $$failed -ne 0 ]; then \
		echo "sim-freertos-all: one or more tests failed."; exit 1; \
	fi; \
	echo "sim-freertos-all: all tests passed."

# Compare software-vs-RTL traces for a FreeRTOS test
compare-freertos-%: $(BUILD_DIR)/freertos-%.elf $(JV32SIM) build-rtl
	@echo "=========================================="
	@echo " JV32 FreeRTOS Trace Comparison: $*"
	@echo "=========================================="
	@echo ""
	@echo "[1/3] Running software simulator..."
	@$(JV32SIM) --trace $(BUILD_DIR)/sim_trace.txt $(BUILD_DIR)/freertos-$*.elf \
	    || (echo "FAIL: software simulator exited non-zero"; exit 1)
	@echo ""
	@echo "[2/3] Running RTL simulator..."
	@$(BUILD_DIR)/jv32soc --rtl-trace $(BUILD_DIR)/rtl_trace.txt \
	    $(BUILD_DIR)/freertos-$*.elf 2>/dev/null \
	    || (echo "FAIL: RTL simulator exited non-zero"; exit 1)
	@echo ""
	@echo "[3/3] Comparing traces..."
	@python3 scripts/trace_compare.py \
	    $(BUILD_DIR)/sim_trace.txt \
	    $(BUILD_DIR)/rtl_trace.txt \
	    || exit 1

# Compare software-vs-RTL traces for all FreeRTOS tests
compare-freertos-all:
	@echo "=========================================="
	@echo "Comparing FreeRTOS traces for all tests"
	@echo "=========================================="
	@failed=0; \
	for t in $$($(MAKE) -s -C $(FREERTOS_DIR) list-tests 2>/dev/null); do \
		echo ""; \
		echo "[compare-freertos-all] $$t"; \
		if ! $(MAKE) --no-print-directory compare-freertos-$$t; then failed=1; fi; \
	done; \
	echo ""; \
	if [ $$failed -ne 0 ]; then \
		echo "compare-freertos-all: one or more tests failed."; exit 1; \
	fi; \
	echo "compare-freertos-all: all tests passed."

# ============================================================================
# Arch-test (ACT4) — delegated to verif/Makefile
# ============================================================================
# All arch-test-* targets are implemented in verif/Makefile to keep this
# file focused on RTL build and simulation.  Variables are passed through.
# ============================================================================
ARCH_TEST_PASSTHROUGH = \
    $(if $(DUT_CONFIG),DUT_CONFIG=$(DUT_CONFIG),) \
    $(if $(EXTENSIONS),EXTENSIONS=$(EXTENSIONS),) \
    $(if $(WORKDIR),WORKDIR=$(WORKDIR),) \
    $(if $(JOBS),JOBS=$(JOBS),)

arch-test-%:
	@$(MAKE) -C $(VERIF_DIR) --no-print-directory $@ $(ARCH_TEST_PASSTHROUGH)

# ============================================================================
clean:
	@rm -rf $(BUILD_DIR)
	@$(MAKE) -C $(SW_DIR) --no-print-directory clean
	@echo "Clean done."

# ============================================================================
# Whitespace cleanup: trim trailing spaces, expand tabs, collapse blank lines
# ============================================================================
# Usage:
#   make cleanup          - clean files modified/untracked in git
#   make cleanup-all      - clean all source files in the repo
#   make cleanup FILES=.. - clean specific files
cleanup:
	@bash scripts/cleanup $(if $(FILES),$(FILES))

cleanup-all:
	@bash scripts/cleanup -all

# ============================================================================
# Info / Help
# ============================================================================
info:
	@echo "JV32 RISC-V SoC Build Configuration"
	@echo "  Verilator:    $(VERILATOR)"
	@echo "  RISCV_PREFIX: $(RISCV_PREFIX)"
	@echo "  RTL dir:      $(RTL_DIR)"
	@echo "  Build dir:    $(BUILD_DIR)"
	@echo "  Simulator:    $(BUILD_TARGET)"

help:
	@echo "JV32 RISC-V SoC Project Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  build-rtl            Build Verilator RTL simulator (default)"
	@echo "  sim ELF=<path>       Run simulation with given ELF"
	@echo "  sim-<test>           Build & run <test>.elf with software simulator"
	@echo "  sim-all              Build & run all tests under sw/ with software simulator"
	@echo "  rtl-<test>           Build & run <test>.elf with RTL simulator"
	@echo "  rtl-all              Build & run all tests under sw/ with RTL simulator"
	@echo "  compare-<test>       Build & compare traces: software vs RTL simulator"
	@echo "  compare-all          Build & compare traces for all tests under sw/"
	@echo "  arch-test-setup      Clone riscv-arch-test (act4) & install Python venv via uv"
	@echo "  arch-test-run        Generate self-checking ELFs and run on JV32 RTL sim"
	@echo "  arch-test-<tgt>      Forward <tgt> to verif/Makefile (see make -C verif help)"
	@echo "  sw-all               Build all software tests"
	@echo "  sw-<test>            Build sw/tests/<test>.elf"
	@echo "  wave                 Open FST waveform in GTKWave"
	@echo "  lint                 Run all lint passes (lint-full + lint-modules + lint-decl + lint-svlint)"
	@echo "  lint-full            Full-design Verilator lint (all warnings + -Werror-IMPLICIT)"
	@echo "  lint-modules         Lint every RTL module as Verilator top (catches MULTIDRIVEN etc.)"
	@echo "  lint-decl            Check signal declaration order (use-before-declare)"
	@echo "  lint-svlint          svlint structural/intent check (skipped if SVLINT=None or binary absent)"
	@echo "  clean                Remove all build artifacts"
	@echo "  info                 Print tool and path configuration"
	@echo ""
	@echo "Simulation variables:"
	@echo "  ELF=<path>           ELF to load (required for 'sim')"
	@echo "  WAVE=fst|vcd         Enable waveform dump"
	@echo "  MAX_CYCLES=<N>       RTL cycle limit (default: unlimited)"
	@echo "  TIMEOUT=<sec>        Wall-clock timeout in seconds (default: 120; 0=no limit)"
	@echo "  DEBUG=1              Enable RTL debug output"
	@echo ""
	@echo "Toolchain variables (set in env.config or command line):"
	@echo "  VERILATOR=<path>     Verilator binary"
	@echo "  RISCV_PREFIX=<pfx>   RISC-V toolchain prefix"
	@echo ""
	@echo "RTL parameters (override on command line):"
	@echo "  FAST_MUL=0|1         Serial/combinatorial multiplier"
	@echo "  FAST_DIV=0|1         Serial/combinatorial divider"
	@echo "  FAST_SHIFT=0|1       Serial/barrel shifter"
	@echo "  BP_EN=0|1            Branch predictor enable"
	@echo "  IRAM_SIZE=<bytes>    Instruction RAM size"
	@echo "  DRAM_SIZE=<bytes>    Data RAM size"
