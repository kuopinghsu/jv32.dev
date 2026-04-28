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

# Load hardware/simulation configuration (can override on command line)
-include Makefile.cfg

# Export so sub-makes (sw/Makefile, rtos/freertos/Makefile) inherit
export RISCV_PREFIX
export VERILATOR
export VERIBLE
export VERIBLE_FORMAT
export RV32E_EN
export RV32M_EN
export AMO_EN
export RV32B_EN
export RAS_EN
export SPIKE

# Compute ARCH/ABI from feature flags and export so all sub-makes agree.
# sw/Makefile and rtos/freertos/Makefile both use ARCH ?= / ABI ?= guards,
# so exporting here overrides their defaults consistently.
ifeq ($(RV32E_EN),1)
  # GCC 15 maps rv32ec_zicsr to the rv32ec/ilp32e multilib while allowing
  # CSR instructions (zicsr) — no separate -Wa workaround needed.
  export ARCH := rv32ec_zicsr
  export ABI  := ilp32e
else
  _SW_EXTS :=
  ifneq ($(RV32M_EN),0)
    _SW_EXTS := $(_SW_EXTS)m
  endif
  ifneq ($(AMO_EN),0)
    _SW_EXTS := $(_SW_EXTS)a
  endif
  export ARCH := rv32i$(_SW_EXTS)c_zicsr
  export ABI  := ilp32
endif

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
VERIBLE        ?= None
VERIBLE_FORMAT ?= None
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
ifdef RV32E_EN
  VERILATOR_FLAGS += -pvalue+RV32E_EN=$(RV32E_EN)
endif
ifdef RV32M_EN
  VERILATOR_FLAGS += -pvalue+RV32M_EN=$(RV32M_EN)
endif
ifdef JTAG_EN
  VERILATOR_FLAGS += -pvalue+JTAG_EN=$(JTAG_EN)
endif
ifdef TRACE_EN
  VERILATOR_FLAGS += -pvalue+TRACE_EN=$(TRACE_EN)
endif
ifdef AMO_EN
  VERILATOR_FLAGS += -pvalue+AMO_EN=$(AMO_EN)
endif
ifdef FAST_MUL
  VERILATOR_FLAGS += -pvalue+FAST_MUL=$(FAST_MUL)
endif
ifdef MUL_MC
  VERILATOR_FLAGS += -pvalue+MUL_MC=$(MUL_MC)
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
ifdef RAS_EN
  VERILATOR_FLAGS += -pvalue+RAS_EN=$(RAS_EN)
endif
ifdef RV32B_EN
  VERILATOR_FLAGS += -pvalue+RV32B_EN=$(RV32B_EN)
endif
ifdef IRAM_SIZE
  VERILATOR_FLAGS += -pvalue+IRAM_SIZE=$(IRAM_SIZE)
endif
ifdef DRAM_SIZE
  VERILATOR_FLAGS += -pvalue+DRAM_SIZE=$(DRAM_SIZE)
endif
ifdef BOOT_ADDR
  VERILATOR_FLAGS += -pvalue+BOOT_ADDR=$(BOOT_ADDR)
endif
ifdef IRAM_BASE
  VERILATOR_FLAGS += -pvalue+IRAM_BASE=$(IRAM_BASE)
endif
ifdef DRAM_BASE
  VERILATOR_FLAGS += -pvalue+DRAM_BASE=$(DRAM_BASE)
endif
ifdef CLK_FREQ
  VERILATOR_FLAGS += -pvalue+CLK_FREQ=$(CLK_FREQ)
  VERILATOR_FLAGS += -CFLAGS "-DCLK_FREQ_HZ=$(CLK_FREQ)ULL"
endif
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
    $(wildcard $(CORE_DIR)/jtag/*.sv) \
    $(filter-out $(AXI_DIR)/axi_pkg.sv,   $(wildcard $(AXI_DIR)/*.sv)) \
    $(wildcard $(JV32_DIR)/*.sv) \
    $(wildcard $(MEM_DIR)/*.sv) \
    $(RTL_DIR)/jv32_soc.sv

TB_SV_SOURCES = \
    $(wildcard $(TB_DIR)/*.sv)

TB_SOURCES = \
    $(TB_DIR)/tb_jv32_soc.cpp \
    $(TB_DIR)/elfloader.cpp \
    $(SIM_DIR)/riscv-dis.cpp

# VPI testbench sources (no riscv-dis — the VPI testbench does not emit traces)
VPI_SOURCES = \
    $(TB_DIR)/tb_jv32_vpi.cpp \
    $(TB_DIR)/elfloader.cpp

# VPI build output binaries
VPI_TARGET_JTAG     = $(BUILD_DIR)/jv32vpi_jtag
VPI_TARGET_CJTAG    = $(BUILD_DIR)/jv32vpi_cjtag
VPI_TARGET_JTAG_COV = $(BUILD_DIR)/jv32vpi_jtag_cov

# VERILATOR_FLAGS with any caller-supplied USE_CJTAG stripped out, so VPI
# build targets can set USE_CJTAG precisely without risk of duplication.
VERILATOR_FLAGS_VPI     = $(filter-out -pvalue+USE_CJTAG%,$(VERILATOR_FLAGS))
VERILATOR_COV_FLAGS_VPI = $(filter-out -pvalue+USE_CJTAG%,$(VERILATOR_COV_FLAGS))

# Output binary
BUILD_TARGET = $(BUILD_DIR)/jv32soc

# Stamp file: rebuilt only when Verilator parameters change
RTL_PARAMS_STAMP = $(BUILD_DIR)/.build_params
RTL_BUILD_PARAMS = RV32EC=$(RV32EC) RV32E_EN=$(RV32E_EN) RV32M_EN=$(RV32M_EN) RV32B_EN=$(RV32B_EN) JTAG_EN=$(JTAG_EN) TRACE_EN=$(TRACE_EN) AMO_EN=$(AMO_EN) FAST_MUL=$(FAST_MUL) MUL_MC=$(MUL_MC) FAST_DIV=$(FAST_DIV) FAST_SHIFT=$(FAST_SHIFT) BP_EN=$(BP_EN) RAS_EN=$(RAS_EN) IRAM_SIZE=$(IRAM_SIZE) DRAM_SIZE=$(DRAM_SIZE) BOOT_ADDR=$(BOOT_ADDR) IRAM_BASE=$(IRAM_BASE) DRAM_BASE=$(DRAM_BASE) DEBUG=$(DEBUG) DEBUG_GROUP=$(DEBUG_GROUP)

# ============================================================================
# Phony targets
# ============================================================================
.PHONY: all build-rtl rtl-build sim sw-all sw-% wave clean help info \
        rtl-% rtl-all sim-% sim-all lint lint-full lint-modules lint-decl lint-ffreset \
	lint-verible lint-svlint format-rtl sim-build compare-% compare-all arch-test-% FORCE \
        build-vpi-jtag build-vpi-cjtag build-vpi-jtag-cov \
        rtl-freertos-% rtl-freertos-all sim-freertos-% sim-freertos-all \
        compare-freertos-% compare-freertos-all freertos-list-tests \
        submodule-init extra-tests openocd-test syn fpga \
        build-rtl-cov build-vpi-jtag-cov coverage

# Default: build RTL simulator, run all tests, then verification suite
all: rtl-all sim-all compare-all rtl-freertos-all sim-freertos-all compare-freertos-all extra-tests arch-test-run openocd-test

extra-tests:
	@make -f Makefile FAST_MUL=0 MUL_MC=0 FAST_DIV=0 FAST_SHIFT=0 BP_EN=0 rtl-all sim-all compare-all
	@make -f Makefile FAST_DIV=1 FAST_MUL=1 MUL_MC=1 rtl-all sim-all compare-all
	@make -f Makefile FAST_DIV=0 FAST_MUL=1 MUL_MC=0 rtl-all sim-all compare-all

# ============================================================================
# Build RTL simulator
# ============================================================================
build-rtl: $(BUILD_TARGET)

# Alias
rtl-build: build-rtl

$(RTL_PARAMS_STAMP): FORCE
	@mkdir -p $(BUILD_DIR)
	@printf '%s' "$(RTL_BUILD_PARAMS)" | cmp -s - $@ || printf '%s' "$(RTL_BUILD_PARAMS)" > $@

$(BUILD_TARGET): $(RTL_SOURCES) $(TB_SV_SOURCES) $(TB_SOURCES) $(RTL_PARAMS_STAMP)
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
	    $(TB_SV_SOURCES) \
	    $(TB_SOURCES)
	@echo ""
	@echo "=========================================="
	@echo "Build complete!"
	@echo "Simulator: $(BUILD_TARGET)"
	@echo "=========================================="

FORCE:

# ============================================================================
# VPI Testbench builds (for OpenOCD JTAG/cJTAG interface testing)
# ============================================================================
# build-vpi-jtag:  Compile with USE_CJTAG=0 → build/jv32vpi_jtag
# build-vpi-cjtag: Compile with USE_CJTAG=1 → build/jv32vpi_cjtag
#
# The VPI testbench uses the same tb_jv32_soc.sv RTL module as the normal
# simulator, but replaces the C++ driver with tb_jv32_vpi.cpp which implements
# a JTAG VPI TCP server (default port 3333) for OpenOCD to connect to.
# ============================================================================
build-vpi-jtag: $(VPI_TARGET_JTAG)
$(VPI_TARGET_JTAG): $(RTL_SOURCES) $(TB_SV_SOURCES) $(VPI_SOURCES)
	@echo "=========================================="
	@echo "Building JV32 VPI testbench (JTAG, USE_CJTAG=0)"
	@echo "=========================================="
	@mkdir -p $(BUILD_DIR)
	@rm -rf $(BUILD_DIR)/objdir_vpi_jtag
	$(VERILATOR) $(VERILATOR_FLAGS_VPI) \
	    -pvalue+USE_CJTAG=0 \
	    -Mdir $(BUILD_DIR)/objdir_vpi_jtag \
	    -o ../jv32vpi_jtag \
	    -I$(CORE_DIR) \
	    -I$(JV32_DIR) \
	    -I$(AXI_DIR) \
	    -I$(MEM_DIR) \
	    -I$(RTL_DIR) \
	    $(RTL_SOURCES) \
	    $(TB_SV_SOURCES) \
	    $(VPI_SOURCES)
	@echo ""
	@echo "=========================================="
	@echo "VPI JTAG testbench: $(VPI_TARGET_JTAG)"
	@echo "=========================================="

build-vpi-cjtag: $(VPI_TARGET_CJTAG)
$(VPI_TARGET_CJTAG): $(RTL_SOURCES) $(TB_SV_SOURCES) $(VPI_SOURCES)
	@echo "=========================================="
	@echo "Building JV32 VPI testbench (cJTAG, USE_CJTAG=1)"
	@echo "=========================================="
	@mkdir -p $(BUILD_DIR)
	@rm -rf $(BUILD_DIR)/objdir_vpi_cjtag
	$(VERILATOR) $(VERILATOR_FLAGS_VPI) \
	    -pvalue+USE_CJTAG=1 \
	    -Mdir $(BUILD_DIR)/objdir_vpi_cjtag \
	    -o ../jv32vpi_cjtag \
	    -I$(CORE_DIR) \
	    -I$(JV32_DIR) \
	    -I$(AXI_DIR) \
	    -I$(MEM_DIR) \
	    -I$(RTL_DIR) \
	    $(RTL_SOURCES) \
	    $(TB_SV_SOURCES) \
	    $(VPI_SOURCES)
	@echo ""
	@echo "=========================================="
	@echo "VPI cJTAG testbench: $(VPI_TARGET_CJTAG)"
	@echo "=========================================="

build-vpi-jtag-cov: $(VPI_TARGET_JTAG_COV)
$(VPI_TARGET_JTAG_COV): $(RTL_SOURCES) $(TB_SV_SOURCES) $(VPI_SOURCES) $(COV_PARAMS_STAMP)
	@echo "=========================================="
	@echo "Building JV32 VPI testbench (JTAG, coverage)"
	@echo "=========================================="
	@mkdir -p $(BUILD_DIR)
	@rm -rf $(BUILD_DIR)/objdir_vpi_jtag_cov
	$(VERILATOR) $(VERILATOR_COV_FLAGS_VPI) \
	    -pvalue+USE_CJTAG=0 \
	    -Mdir $(BUILD_DIR)/objdir_vpi_jtag_cov \
	    -o ../jv32vpi_jtag_cov \
	    -I$(CORE_DIR) \
	    -I$(JV32_DIR) \
	    -I$(AXI_DIR) \
	    -I$(MEM_DIR) \
	    -I$(RTL_DIR) \
	    $(RTL_SOURCES) \
	    $(TB_SV_SOURCES) \
	    $(VPI_SOURCES)
	@echo ""
	@echo "VPI JTAG coverage testbench: $(VPI_TARGET_JTAG_COV)"

# ============================================================================
# Lint
# ============================================================================

# Lint umbrella: runs all lint passes in sequence.
# Stops on the first failing pass.
lint: lint-full lint-modules lint-decl lint-ffreset lint-verible lint-svlint

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
	    $(RTL_SOURCES) \
	    $(TB_SV_SOURCES)
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
# Synthesis tools (DC, Genus, Vivado strict mode) reject such forward references
# even though SV technically allows module-scope forward references.
# Uses scripts/check_synth_style.py which does not require any extra tools.
lint-decl:
	@echo "=========================================="
	@echo "Declaration-order check ($(words $(RTL_ONLY_SRCS)) files)"
	@echo "=========================================="
	@python3 scripts/check_synth_style.py --no-reset $(RTL_ONLY_SRCS)

# Partial-reset check: detect always_ff blocks where some signals are assigned
# but not included in the reset branch.  Mixed reset/no-reset in a single
# always_ff is a synthesis anti-pattern (Vivado Synth 8-489 / CDC warnings).
# Fix by either resetting all signals in the block or splitting into separate
# always_ff blocks (one with reset, one without).
lint-ffreset:
	@echo "=========================================="
	@echo "Partial-reset check ($(words $(RTL_ONLY_SRCS)) files)"
	@echo "=========================================="
	@python3 scripts/check_synth_style.py --no-decl $(RTL_ONLY_SRCS)

# svlint structural/intent lint of RTL source files.
# Skipped automatically when SVLINT is 'None' or the binary does not exist.
# Rules are read from .svlint.toml.
lint-verible:
	@echo "=========================================="
	@echo "Verible RTL check"
	@echo "=========================================="
	@if [ "$(VERIBLE)" = "None" ] || [ -z "$(VERIBLE)" ]; then \
	    echo "VERIBLE is set to None or unset - skipping Verible."; \
	else \
	    if [[ "$(VERIBLE)" == */* ]]; then \
	        if ! [ -x "$(VERIBLE)" ]; then \
	            echo "Verible binary not executable at: $(VERIBLE) - skipping."; \
	            exit 0; \
	        fi; \
	        VCBIN="$(VERIBLE)"; \
	    else \
	        if ! command -v "$(VERIBLE)" >/dev/null 2>&1; then \
	            echo "Verible binary not found in PATH: $(VERIBLE) - skipping."; \
	            exit 0; \
	        fi; \
	        VCBIN="$(VERIBLE)"; \
	    fi; \
	    echo "verible: $$VCBIN"; \
	    echo "config: .rules.verible_lint"; \
	    $$VCBIN --rules_config .rules.verible_lint $(RTL_ONLY_SRCS) && \
	    echo "" && \
	    echo "==========================================" && \
	    echo "Verible passed!" && \
	    echo "=========================================="; \
	fi

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
	    $(SVLINT) -I rtl/jv32/core -I rtl/jv32 $(RTL_ONLY_SRCS) && \
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
#   make rtl-trap           (build sw/tests/trap.elf then simulate)
# Optional:
#   WAVE=fst    — dump FST waveform to $(BUILD_DIR)/jv32soc.fst
#   TRACE=1     — print instruction trace
#   MAX_CYCLES=N — stop after N cycles (default: unlimited)
#   TIMEOUT=N    — wall-clock timeout in seconds (default: 120; 0=no limit)
# ============================================================================
TIMEOUT     ?= 120
TIMEOUT_ARG  = $(if $(MAX_CYCLES),--max-cycles=$(MAX_CYCLES)) $(if $(TIMEOUT),--timeout=$(TIMEOUT))
RTL_TRACE_FILE = $(abspath $(BUILD_DIR))/rtl_trace.txt

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
	    $(if $(filter 1,$(TRACE)),--rtl-trace $(RTL_TRACE_FILE)) \
	    $(TIMEOUT_ARG) \
	    $*.elf
	@echo "=========================================="
	@if [ "$(WAVE)" = "1" ] || [ "$(WAVE)" = "fst" ]; then \
	    echo "Waveform saved to: $(BUILD_DIR)/jv32soc.fst"; \
	fi

# Build FreeRTOS ELF via rtos/freertos/Makefile
$(BUILD_DIR)/freertos-%.elf:
	@$(MAKE) -C $(FREERTOS_DIR) --no-print-directory build TEST=$* BUILD_DIR=$(BUILD_DIR_ABS)

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
	@passed=0; failed=0; failed_tests=""; idx=0; \
	for test in $(SW_TESTS); do \
		idx=$$((idx+1)); \
		echo ""; \
		echo "[rtl-all $$idx/$(SW_TEST_COUNT)] $$test"; \
		if $(MAKE) --no-print-directory rtl-$$test; then \
			passed=$$((passed + 1)); \
		else \
			failed=$$((failed + 1)); \
			failed_tests="$$failed_tests $$test"; \
		fi; \
	done; \
	echo ""; \
	echo "=========================================="; \
	echo "RTL Test Summary"; \
	echo "=========================================="; \
	echo "Total:  $$((passed + failed))"; \
	echo "Passed: $$passed"; \
	echo "Failed: $$failed"; \
	if [ $$failed -gt 0 ]; then echo "Failed tests:$$failed_tests"; fi; \
	echo "=========================================="; \
	if [ $$failed -gt 0 ]; then exit 1; fi

# Run all software tests with the software simulator
sim-all: sim-build
	@echo "=========================================="
	@echo "Running all software tests with software simulator"
	@echo "Tests ($(SW_TEST_COUNT)): $(SW_TESTS)"
	@echo "=========================================="
	@passed=0; failed=0; failed_tests=""; idx=0; \
	for test in $(SW_TESTS); do \
		idx=$$((idx+1)); \
		echo ""; \
		echo "[sim-all $$idx/$(SW_TEST_COUNT)] $$test"; \
		if $(MAKE) --no-print-directory sim-$$test; then \
			passed=$$((passed + 1)); \
		else \
			failed=$$((failed + 1)); \
			failed_tests="$$failed_tests $$test"; \
		fi; \
	done; \
	echo ""; \
	echo "=========================================="; \
	echo "Simulator Test Summary"; \
	echo "=========================================="; \
	echo "Total:  $$((passed + failed))"; \
	echo "Passed: $$passed"; \
	echo "Failed: $$failed"; \
	if [ $$failed -gt 0 ]; then echo "Failed tests:$$failed_tests"; fi; \
	echo "=========================================="; \
	if [ $$failed -gt 0 ]; then exit 1; fi

# Compare software-vs-RTL traces for all software tests
compare-all: $(JV32SIM) build-rtl
	@echo "=========================================="
	@echo "Comparing traces for all software tests"
	@echo "Tests ($(SW_TEST_COUNT)): $(SW_TESTS)"
	@echo "=========================================="
	@passed=0; failed=0; failed_tests=""; idx=0; \
	for test in $(SW_TESTS); do \
		idx=$$((idx+1)); \
		echo ""; \
		echo "[compare-all $$idx/$(SW_TEST_COUNT)] $$test"; \
		if $(MAKE) --no-print-directory compare-$$test; then \
			passed=$$((passed + 1)); \
		else \
			failed=$$((failed + 1)); \
			failed_tests="$$failed_tests $$test"; \
		fi; \
	done; \
	echo ""; \
	echo "=========================================="; \
	echo "Comparison Summary"; \
	echo "=========================================="; \
	echo "Total:  $$((passed + failed))"; \
	echo "Passed: $$passed"; \
	echo "Failed: $$failed"; \
	if [ $$failed -gt 0 ]; then echo "Failed tests:$$failed_tests"; fi; \
	echo "=========================================="; \
	if [ $$failed -gt 0 ]; then exit 1; fi

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
# Examples: make sim-hello, make sim-trap
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
#   make compare-<test>     e.g. make compare-hello, make compare-trap
#
# Builds <test>.elf, jv32sim, and the RTL simulation binary, then runs
# both and diffs the instruction traces (only non-x0 register writes).
# ============================================================================
compare-%: $(BUILD_DIR)/%.elf $(JV32SIM) build-rtl
	@echo "=========================================="
	@echo " JV32 Trace Comparison: $*"
	@echo "=========================================="
	@echo ""
	@echo "[1/3] Running RTL simulator (generates cycle-CSR hints)..."
	@$(BUILD_DIR)/jv32soc --rtl-trace $(RTL_TRACE_FILE) \
	    $(BUILD_DIR)/$*.elf \
	    || (echo "FAIL: RTL simulator exited non-zero"; exit 1)
	@echo ""
	@echo "[2/3] Running software simulator (using RTL hints to sync cycle counters)..."
	@$(JV32SIM) --trace $(BUILD_DIR)/sim_trace.txt \
	    --rtl-hints $(RTL_TRACE_FILE) \
	    $(BUILD_DIR)/$*.elf \
	    || (echo "FAIL: software simulator exited non-zero"; exit 1)
	@echo ""
	@echo "[3/3] Comparing traces (sim=RTL-format vs rtl=Spike-format)..."
	@python3 scripts/trace_compare.py \
	    $(BUILD_DIR)/sim_trace.txt \
	    $(RTL_TRACE_FILE) \
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

# Internal helper used by rtl-freertos-% and rtl-freertos-all
.PHONY: __rtl-freertos-run
__rtl-freertos-run: build-rtl
	@if [ "$(RV32E_EN)" = "1" ]; then \
		echo "=========================================================="; \
		echo "  FreeRTOS SKIPPED (RV32E_EN=1, not supported for RV32EC)"; \
		echo "=========================================================="; \
		exit 0; \
	fi
	@if [ -z "$(TEST)" ]; then \
		echo "ERROR: TEST is required (e.g. make __rtl-freertos-run TEST=perf)"; \
		exit 1; \
	fi
	@$(MAKE) -C $(FREERTOS_DIR) --no-print-directory build TEST=$(TEST) BUILD_DIR=$(BUILD_DIR_ABS)
	@echo "=========================================="
	@echo "Running FreeRTOS test '$(TEST)' with RTL simulator"
	@echo "=========================================="
	@cd $(BUILD_DIR) && ./jv32soc \
	    $(if $(filter 1 fst,$(WAVE)),--trace jv32soc.fst) \
	    $(if $(filter vcd,$(WAVE)),--trace jv32soc.vcd) \
	    $(if $(filter 1,$(TRACE)),--rtl-trace $(RTL_TRACE_FILE)) \
	    $(TIMEOUT_ARG) \
	    freertos-$(TEST).elf
	@echo "=========================================="
	@if [ "$(WAVE)" = "1" ] || [ "$(WAVE)" = "fst" ]; then \
	    echo "Waveform saved to: $(BUILD_DIR)/jv32soc.fst"; \
	fi

# Run a FreeRTOS test with the RTL simulator
rtl-freertos-%:
	@$(MAKE) --no-print-directory __rtl-freertos-run TEST=$*

# Run all FreeRTOS tests with the RTL simulator
rtl-freertos-all: build-rtl
	@echo "=========================================="
	@echo "Running all FreeRTOS tests with RTL simulator"
	@echo "=========================================="
	@failed=0; \
	for t in $$($(MAKE) -s -C $(FREERTOS_DIR) list-tests 2>/dev/null); do \
		echo ""; \
		echo "[rtl-freertos-all] $$t"; \
		if ! $(MAKE) --no-print-directory __rtl-freertos-run TEST=$$t; then failed=1; fi; \
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
	@echo "[1/3] Running RTL simulator (generates mtime/irq hints)..."
	@$(BUILD_DIR)/jv32soc --rtl-trace $(RTL_TRACE_FILE) \
	    $(TIMEOUT_ARG) \
	    $(BUILD_DIR)/freertos-$*.elf 2>/dev/null \
	    || (echo "FAIL: RTL simulator exited non-zero"; exit 1)
	@echo ""
	@echo "[2/3] Running software simulator (using RTL hints to sync mtime/irq)..."
	@$(JV32SIM) --trace $(BUILD_DIR)/sim_trace.txt \
	    --rtl-hints $(RTL_TRACE_FILE) \
	    $(SIM_MAX_INSNS_ARG) \
	    $(BUILD_DIR)/freertos-$*.elf \
	    || (echo "FAIL: software simulator exited non-zero"; exit 1)
	@echo ""
	@echo "[3/3] Comparing traces..."
	@python3 scripts/trace_compare.py \
	    $(BUILD_DIR)/sim_trace.txt \
	    $(RTL_TRACE_FILE) \
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
# Submodule initialization (avoids pulling large nested submodules like llvm-project)
# ============================================================================
# DO NOT use `git clone --recurse-submodules` — it will recursively clone
# riscv-arch-test → riscv-unified-db → llvm-project (~4 GB).
# Use `make submodule-init` instead after a plain `git clone`.
# ============================================================================
submodule-init:
	@echo "[submodule] Initializing verif/riscv-arch-test..."
	@git submodule update --init verif/riscv-arch-test
	@echo "[submodule] Initializing riscv-arch-test nested submodules (excluding llvm-project)..."
	@git -C verif/riscv-arch-test submodule update --init external/riscv-unified-db docs/docs-resources
	@echo "[submodule] Done. llvm-project was intentionally skipped (not needed for arch tests)."

# ============================================================================
# Arch-test (ACT4) — delegated to verif/Makefile
# ============================================================================
# All arch-test-* targets are implemented in verif/Makefile to keep this
# file focused on RTL build and simulation.  Variables are passed through.
#
# The RISC-V Architectural Compliance Test suite (ACT4) validates that the
# JV32 core implements RV32IMAC correctly against the RISC-V specification.
#
# Test methodology:
#   1. ACT4 compiles each test to a self-checking ELF that writes a memory
#      signature to a known address range (begin_signature..end_signature).
#   2. The ELF is loaded onto the JV32 RTL simulator (build/jv32soc).  The
#      simulator polls the tohost MMIO word; when the test writes 1 (pass)
#      or (exit_code<<1)|1 (fail) to tohost, the simulator exits.
#   3. The memory signature dumped by the RTL run is compared word-for-word
#      against the reference generated by Spike (configured via SPIKE in
#      env.config).  Any mismatch is a compliance failure.
#
# Notable constraint — I-jal-00 IRAM requirement:
#   The I-jal-00 test places its .text segment at 0x80004000 and the section
#   is ~0x1C080 bytes long, ending at 0x80020080 — 128 bytes past the normal
#   128 KB IRAM boundary (0x80020000).  All other tests fit in 128 KB.
#   The arch-test RTL build therefore overrides IRAM_SIZE=262144 (256 KB)
#   automatically.  The default IRAM_SIZE in Makefile.cfg stays at 128 KB.
#
# Extensions covered (see verif/Makefile EXCLUDE_EXTENSIONS for exclusions):
#   I, M, Zaamo, Zalrsc, C/Zca, Zicsr, Zifencei, Zicntr, Sm
#
# Reference model:
#   Spike (ISA simulator) is used as the golden reference.  Set SPIKE in
#   env.config to point to your Spike binary.
# ============================================================================
ARCH_TEST_PASSTHROUGH = \
    $(if $(DUT_CONFIG),DUT_CONFIG=$(DUT_CONFIG),) \
    $(if $(EXTENSIONS),EXTENSIONS=$(EXTENSIONS),) \
    $(if $(WORKDIR),WORKDIR=$(WORKDIR),) \
    $(if $(JOBS),JOBS=$(JOBS),) \
    RV32B_EN=$(RV32B_EN) \
    RAS_EN=$(RAS_EN) \
    SPIKE=$(SPIKE)

arch-test-%:
	@$(MAKE) -C $(VERIF_DIR) --no-print-directory $@ $(ARCH_TEST_PASSTHROUGH)

# ============================================================================
# Verification suite
# ============================================================================
# Summary of all verification targets:
#
#   make all           — runs every verification step below end-to-end
#   make arch-test-run — RISC-V ACT4 compliance tests (see section above)
#   make openocd-test  — JTAG + cJTAG debug interface tests via OpenOCD VPI
#   make -C syn        — ASIC synthesis + P&R (OpenLane2 / Nangate45)
#   make -C fpga       — FPGA build (Vivado ML Standard Edition, free license)
#
# openocd-test builds two VPI testbench variants (JTAG and cJTAG) and then
# runs every Tcl test script in openocd/ against both transports.
# A patched OpenOCD with cJTAG VPI support is required:
#   https://github.com/kuopinghsu/openocd
#
# syn (ASIC) and fpga targets are not included in the default 'make all'
# because they require commercial/specialised EDA tools and may take hours.
# Run them explicitly when needed.
# ============================================================================

# OpenOCD JTAG + cJTAG interface tests.
# Builds both VPI testbench variants, then runs all openocd/ test scripts.
# Requires a patched OpenOCD with cJTAG VPI support:
#   https://github.com/kuopinghsu/openocd
openocd-test: build-vpi-jtag build-vpi-cjtag
	@$(MAKE) -C openocd --no-print-directory all

# ASIC synthesis and place-and-route (OpenLane2 + Nangate 45nm).
# Configure OPENRAM, OPENLANE, NANGATE_HOME in env.config before running.
syn:
	@$(MAKE) -C syn --no-print-directory synth

# FPGA build using Vivado ML Standard Edition (free of license).
# Requires Vivado on PATH or VIVADO set in env.config / fpga/Makefile.
# 'impl' runs synthesis + place-and-route + bitstream generation.
fpga:
	@$(MAKE) -C fpga --no-print-directory impl

# ============================================================================
# Coverage-driven simulation (Verilator line + toggle coverage)
# ============================================================================
# Build the RTL simulator with --coverage, run every SW test to collect
# per-test .dat files, merge them, and emit an annotated source report.
#
# Usage:
#   make coverage              # run all SW tests, write build/coverage/
#   make coverage TIMEOUT=300  # override per-test wall-clock timeout
# ============================================================================
COV_DIR          = $(BUILD_DIR)/coverage
COV_TARGET       = $(BUILD_DIR)/jv32soc_cov
COV_PARAMS_STAMP = $(BUILD_DIR)/.build_params_cov

# Coverage build flags: same as VERILATOR_FLAGS but with --coverage appended
VERILATOR_COV_FLAGS = $(VERILATOR_FLAGS) --coverage

$(COV_PARAMS_STAMP): FORCE
	@mkdir -p $(BUILD_DIR)
	@printf '%s' "$(RTL_BUILD_PARAMS)" | cmp -s - $@ || printf '%s' "$(RTL_BUILD_PARAMS)" > $@

build-rtl-cov: $(COV_TARGET)

$(COV_TARGET): $(RTL_SOURCES) $(TB_SV_SOURCES) $(TB_SOURCES) $(COV_PARAMS_STAMP)
	@echo "=========================================="
	@echo "Building JV32 SoC with Verilator (coverage)"
	@echo "=========================================="
	@mkdir -p $(BUILD_DIR)
	@rm -rf $(BUILD_DIR)/objdir_cov
	$(VERILATOR) $(VERILATOR_COV_FLAGS) \
	    -Mdir $(BUILD_DIR)/objdir_cov \
	    -o ../jv32soc_cov \
	    -I$(CORE_DIR) \
	    -I$(JV32_DIR) \
	    -I$(AXI_DIR) \
	    -I$(MEM_DIR) \
	    -I$(RTL_DIR) \
	    $(RTL_SOURCES) \
	    $(TB_SV_SOURCES) \
	    $(TB_SOURCES)
	@echo ""
	@echo "Coverage build complete: $(COV_TARGET)"

coverage: build-rtl-cov build-vpi-jtag-cov sw-all sw-hello
	@echo "=========================================="
	@echo "Coverage run: $(SW_TEST_COUNT) SW tests + JTAG tests"
	@echo "=========================================="
	@mkdir -p $(COV_DIR)/dat
	@for test in $(SW_TESTS); do \
		printf "  %-20s ... " "$$test"; \
		$(COV_TARGET) \
		    $(TIMEOUT_ARG) \
		    +verilator+coverage+file+$(abspath $(COV_DIR)/dat/$$test.dat) \
		    $(BUILD_DIR)/$$test.elf 2>/dev/null; \
		echo "done"; \
	done
	@echo ""
	@echo "Running JTAG coverage tests..."
	@JTAG_COV_PORT=5556; \
	OPENOCD_DIR=$(abspath openocd); \
	OPENOCD=$${OPENOCD:-openocd}; \
	for t in halt_resume programbuf sba step abstract_regs triggers debug_errors; do \
	    printf "  [jtag-cov] %-20s ... " "$$t"; \
	    $(VPI_TARGET_JTAG_COV) \
	        $(BUILD_DIR)/hello.elf \
	        --port $$JTAG_COV_PORT \
	        +verilator+coverage+file+$(abspath $(COV_DIR)/dat/jtag_$$t.dat) \
	        >/dev/null 2>&1 & VPI_PID=$$!; \
	    for _i in $$(seq 1 60); do \
	        ss -tnl 2>/dev/null | grep -q ":$$JTAG_COV_PORT " && break; \
	        sleep 0.1; \
	    done; \
	    ( cd "$$OPENOCD_DIR" && \
	      $$OPENOCD -d0 \
	          -c "gdb_port disabled" \
	          -f jv32.cfg \
	          -c "jtag_vpi set_port $$JTAG_COV_PORT" \
	          -c init \
	          -c "source test_$$t.tcl" \
	          -c shutdown \
	    ) >/dev/null 2>&1; \
	    OCD_RC=$$?; \
	    for _k in $$(seq 1 40); do \
	        kill -0 $$VPI_PID 2>/dev/null || break; \
	        sleep 0.1; \
	    done; \
	    kill $$VPI_PID 2>/dev/null; wait $$VPI_PID 2>/dev/null; \
	    for _j in $$(seq 1 30); do \
	        ss -tnl 2>/dev/null | grep -q ":$$JTAG_COV_PORT " || break; \
	        sleep 0.1; \
	    done; \
	    if [ $$OCD_RC -eq 0 ]; then echo "done"; else echo "FAIL (rc=$$OCD_RC)"; fi; \
	done
	@echo ""
	@echo "Generating annotated coverage report..."
	@mkdir -p $(COV_DIR)/annotated
	@verilator_coverage \
	    --annotate $(COV_DIR)/annotated \
	    --annotate-min 1 \
	    $(COV_DIR)/dat/*.dat
	@echo ""
	@echo "Generating HTML coverage report (genhtml)..."
	@mkdir -p $(COV_DIR)/html
	@verilator_coverage \
	    --write-info $(COV_DIR)/coverage.info \
	    $(COV_DIR)/dat/*.dat
	@genhtml --output-directory $(COV_DIR)/html \
	    --title "JV32 RTL Coverage" \
	    --legend \
	    $(COV_DIR)/coverage.info
	@echo ""
	@echo "=========================================="
	@echo "Annotated report : $(COV_DIR)/annotated/"
	@echo "HTML report      : $(COV_DIR)/html/index.html"
	@echo "=========================================="

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
# SystemVerilog formatting with Verible
# Usage:
#   make format-rtl
#   make format-rtl FILES="rtl/jv32/core/jv32_rvc.sv rtl/axi/axi_clic.sv"
# ============================================================================
format-rtl:
	@echo "=========================================="
	@echo "Verible SystemVerilog format"
	@echo "=========================================="
	@if [ "$(VERIBLE_FORMAT)" = "None" ] || [ -z "$(VERIBLE_FORMAT)" ]; then \
	    echo "VERIBLE_FORMAT is set to None or unset - skipping format."; \
	else \
	    if [[ "$(VERIBLE_FORMAT)" == */* ]]; then \
	        if ! [ -x "$(VERIBLE_FORMAT)" ]; then \
	            echo "Verible formatter not executable at: $(VERIBLE_FORMAT) - skipping."; \
	            exit 0; \
	        fi; \
	        VFBIN="$(VERIBLE_FORMAT)"; \
	    else \
	        if ! command -v "$(VERIBLE_FORMAT)" >/dev/null 2>&1; then \
	            echo "Verible formatter not found in PATH: $(VERIBLE_FORMAT) - skipping."; \
	            exit 0; \
	        fi; \
	        VFBIN="$(VERIBLE_FORMAT)"; \
	    fi; \
	    echo "verible-format: $$VFBIN"; \
	    echo "flagfile: .rules.verible_format"; \
	    $$VFBIN \
	        --inplace \
	        --flagfile=.rules.verible_format \
	        $(if $(FILES),$(FILES),$(RTL_SOURCES) $(TB_SV_SOURCES)) \
	        >/dev/null && \
	    python3 scripts/align_localparams.py $(if $(FILES),$(FILES),$(RTL_SOURCES) $(TB_SV_SOURCES)) && \
	    python3 scripts/align_trailing_comments.py $(if $(FILES),$(FILES),$(RTL_SOURCES) $(TB_SV_SOURCES)) && \
	    echo "" && \
	    echo "==========================================" && \
	    echo "Format complete!" && \
	    echo "=========================================="; \
	fi

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
	@echo ""
	@echo "Verification targets:"
	@echo "  arch-test-setup      Clone riscv-arch-test (act4) & install Python venv via uv"
	@echo "  arch-test-run        Run RISC-V ACT4 compliance tests on JV32 RTL simulator"
	@echo "                       (IRAM auto-set to 256 KB for I-jal-00; default stays 128 KB)"
	@echo "  arch-test-<tgt>      Forward <tgt> to verif/Makefile (see make -C verif help)"
	@echo "  openocd-test         Build VPI testbenches + run OpenOCD JTAG & cJTAG tests"
	@echo "                       (requires patched OpenOCD: github.com/kuopinghsu/openocd)"
	@echo "  coverage             Build coverage-instrumented sim and run all SW tests;"
	@echo "                       writes annotated line/toggle report to build/coverage/"
	@echo "  build-rtl-cov        Build Verilator simulator with --coverage (used by coverage)"
	@echo "  syn                  ASIC synthesis + P&R via OpenLane2 / Nangate 45nm"
	@echo "  fpga                 FPGA build via Vivado ML Standard Edition (free license)"
	@echo "                       (runs synth + place-and-route + bitstream via 'impl')"
	@echo "  submodule-init       Init submodules safely (skips llvm-project)"
	@echo "  sw-all               Build all software tests"
	@echo "  sw-<test>            Build sw/tests/<test>.elf"
	@echo "  wave                 Open FST waveform in GTKWave"
	@echo "  format-rtl           Format SystemVerilog files with Verible (all RTL or FILES=...)"
	@echo "  lint                 Run all lint passes (lint-full + lint-modules + lint-decl + lint-ffreset + lint-verible + lint-svlint)"
	@echo "  lint-full            Full-design Verilator lint (all warnings + -Werror-IMPLICIT)"
	@echo "  lint-modules         Lint every RTL module as Verilator top (catches MULTIDRIVEN etc.)"
	@echo "  lint-decl            Check signal declaration order (use-before-declare)"
	@echo "  lint-verible         Verible lint check (skipped if VERIBLE=None or binary absent)"
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
	@echo "  VERIBLE=<path>       Verible lint binary"
	@echo "  VERIBLE_FORMAT=<p>   Verible formatter binary"
	@echo "  RISCV_PREFIX=<pfx>   RISC-V toolchain prefix"
	@echo ""
	@echo "RTL parameters (override on command line):"
	@echo "  RV32EC=1             Minimum-area RV32EC preset (sets all flags below)"
	@echo "  RV32E_EN=0|1         0=RV32I 32 GPRs, 1=RV32E 16 GPRs"
	@echo "  RV32M_EN=0|1         M-extension (MUL/DIV) enable"
	@echo "  JTAG_EN=0|1          JTAG debug interface enable"
	@echo "  TRACE_EN=0|1         Trace output registers enable"
	@echo "  AMO_EN=0|1           A-extension (atomic ops) enable"
	@echo "  FAST_MUL=0|1         Serial/combinatorial multiplier"
	@echo "  MUL_MC=0|1           1=2-stage pipelined (2 cyc); 0=1-cycle comb. (requires FAST_MUL=1)"
	@echo "  FAST_DIV=0|1         Serial/combinatorial divider"
	@echo "  FAST_SHIFT=0|1       Serial/barrel shifter"
	@echo "  BP_EN=0|1            Branch predictor enable"
	@echo "  RAS_EN=0|1           Return Address Stack enable (auto-off for RV32EC=1)"
	@echo "  DRAM_SIZE=<bytes>    Data RAM size"
