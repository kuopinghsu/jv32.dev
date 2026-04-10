# ===========================================================================
# JV32 SoC — Synthesis & P&R Makefile
#
# Flow:
#   openram-setup  → create local Python venv for OpenRAM
#   gen-mem        → compile OpenRAM SRAM macros (Nangate 45nm / freepdk45)
#   synth          → run OpenLane2 Classic flow (synthesis + P&R)
#
# Quick start:
#   cp ../env.config.template ../env.config   # first time only
#   # edit env.config: set OPENRAM, OPENLANE, NANGATE_HOME
#   make openram-setup
#   make gen-mem
#   make synth
# ===========================================================================

SHELL := /bin/bash

-include ../env.config

ifdef PATH_APPEND
export PATH := $(PATH_APPEND):$(PATH)
endif

DESIGN := jv32_soc
PDK    := freepdk45

# ── Tool paths ──────────────────────────────────────────────────────────────
# Override in env.config or on the command line.

# OpenRAM 1.2.x root (directory containing sram_compiler.py)
OPENRAM ?= $(HOME)/OpenRAM-1.2.48

# OpenLane 2 root (directory containing 'openlane' Python package)
OPENLANE ?= $(HOME)/openlane2

# Nangate 45nm Open Cell Library root — must contain:
#   NangateOpenCellLibrary.tech.lef
#   NangateOpenCellLibrary.macro.lef  (or .macro.mod.lef)
#   liberty/NangateOpenCellLibrary_typical.lib  (or plain .lib at root)
#   NangateOpenCellLibrary.gds
# Common install: $(HOME)/FreePDK45/NangateOpenCellLibrary
NANGATE_HOME ?=

# Python binary used to run OpenRAM and openram-setup
PYTHON3 ?= python3

# openlane run command (override if using docker or nix wrapper)
OPENLANE_CMD ?= $(PYTHON3) -m openlane

# OpenROAD binary — used by the standalone pnr and timing-report targets
OPENROAD ?= $(HOME)/OpenROAD/python/openroad

# ── Local directories ────────────────────────────────────────────────────────
# SYN_DIR is the absolute path of this Makefile's directory.
# Use SYN_DIR rather than CURDIR so the Makefile works when invoked with -C.
# $(firstword $(MAKEFILE_LIST)) is always this Makefile itself (not includes).
SYN_DIR        := $(abspath $(dir $(firstword $(MAKEFILE_LIST))))
VENV_DIR       := $(SYN_DIR)/.venv
PDK_ROOT       := $(SYN_DIR)/pdk
OPENRAM_OUTDIR := $(SYN_DIR)/lib/openram
OPENLANE_DIR   := $(SYN_DIR)/openlane
BUILD_DIR      := $(SYN_DIR)/build

# ── OpenRAM SRAM sizes (must match jv32_top parameters) ────────────────────
IRAM_SIZE ?= 131072   # bytes = 128 KB
DRAM_SIZE ?= 131072   # bytes = 128 KB

# OpenRAM optimisation: speed (words_per_row=1, TT+FF+SS) or area (auto, TT)
OPENRAM_OPTIMIZE ?= speed

export NANGATE_HOME
export PDK_ROOT
export OPENRAM

.PHONY: all check openram-setup gen-mem synth pnr timing-report clean cleanall help

all: synth

# ── Sanity checks ────────────────────────────────────────────────────────────
check:
	@echo "========================================"
	@echo " jv32 synthesis/P&R setup check"
	@echo "========================================"
	@if [ ! -d "$(OPENRAM)" ]; then \
	    echo "ERROR: OPENRAM not found at '$(OPENRAM)'"; \
	    echo "       Set OPENRAM in env.config or on command line."; \
	    exit 1; \
	fi
	@echo "  OPENRAM      : $(OPENRAM)"
	@if [ ! -d "$(OPENLANE)" ]; then \
	    echo "ERROR: OPENLANE not found at '$(OPENLANE)'"; \
	    echo "       Set OPENLANE in env.config or on command line."; \
	    exit 1; \
	fi
	@echo "  OPENLANE     : $(OPENLANE)"
	@if [ -z "$(NANGATE_HOME)" ]; then \
	    echo "WARNING: NANGATE_HOME is not set."; \
	    echo "         The OpenLane2 PDK config will search for Nangate LEF/GDS"; \
	    echo "         files relative to PDK_ROOT. Set NANGATE_HOME to avoid errors."; \
	else \
	    echo "  NANGATE_HOME : $(NANGATE_HOME)"; \
	    for f in \
	      "NangateOpenCellLibrary.tech.lef" \
	      "NangateOpenCellLibrary.macro.lef NangateOpenCellLibrary.macro.mod.lef" \
	      "NangateOpenCellLibrary.gds"; \
	    do \
	      found=0; \
	      for candidate in $$f; do \
	        if [ -f "$(NANGATE_HOME)/$$candidate" ]; then found=1; fi; \
	      done; \
	      if [ $$found -eq 0 ]; then \
	        echo "WARNING: $$f not found in NANGATE_HOME=$(NANGATE_HOME)"; \
	      fi; \
	    done; \
	fi
	@echo "  PDK_ROOT     : $(PDK_ROOT)"
	@echo "  OPENRAM_OUT  : $(OPENRAM_OUTDIR)"
	@echo "Checks passed."

# ── OpenRAM Python venv setup ────────────────────────────────────────────────
openram-setup:
	@echo "========================================"
	@echo " Creating local Python venv for OpenRAM"
	@echo "  venv    : $(VENV_DIR)"
	@echo "  OpenRAM : $(OPENRAM)"
	@echo "========================================"
	@if [ ! -d "$(OPENRAM)" ]; then \
	    echo "ERROR: OPENRAM not found at '$(OPENRAM)'"; exit 1; \
	fi
	$(PYTHON3) -m venv $(VENV_DIR)
	$(VENV_DIR)/bin/pip install --upgrade pip --quiet
	@if [ -f "$(OPENRAM)/requirements.txt" ]; then \
	    $(VENV_DIR)/bin/pip install -r $(OPENRAM)/requirements.txt --quiet; \
	else \
	    echo "WARNING: $(OPENRAM)/requirements.txt not found, skipping."; \
	fi
	@# Pin numpy<2 and gdspy for OpenRAM 1.x compatibility
	$(VENV_DIR)/bin/pip install "numpy<2" "gdspy" --quiet
	@SITE_PKG=$$($(VENV_DIR)/bin/python3 -c \
	    "import site; print(site.getsitepackages()[0])") && \
	    cp common/openram_sitecustomize.py $$SITE_PKG/sitecustomize.py && \
	    echo "Installed OpenRAM tech patch → $$SITE_PKG/sitecustomize.py"
	@echo "venv ready. Activate with: source $(VENV_DIR)/bin/activate"

# ── OpenRAM macro compilation ────────────────────────────────────────────────
gen-mem:
	@echo "========================================"
	@echo " Compiling OpenRAM SRAM macros"
	@echo "  PDK      : $(PDK) (Nangate 45nm)"
	@echo "  OPENRAM  : $(OPENRAM)"
	@echo "  IRAM     : $(IRAM_SIZE) bytes"
	@echo "  DRAM     : $(DRAM_SIZE) bytes"
	@echo "  OPTIMIZE : $(OPENRAM_OPTIMIZE)"
	@echo "========================================"
	@if [ ! -d "$(OPENRAM)" ]; then \
	    echo "ERROR: OPENRAM not found at '$(OPENRAM)'"; exit 1; \
	fi
	@if [ ! -f "$(VENV_DIR)/bin/activate" ]; then \
	    echo "ERROR: venv not found. Run 'make openram-setup' first."; exit 1; \
	fi
	mkdir -p $(OPENRAM_OUTDIR)
	@echo "Generating OpenRAM config files..."
	$(PYTHON3) common/gen_openram_config.py \
	    --iram-size $(IRAM_SIZE) \
	    --dram-size $(DRAM_SIZE) \
	    --pdk $(PDK) \
	    --optimize $(OPENRAM_OPTIMIZE) \
	    --output-dir $(OPENRAM_OUTDIR)
	@echo "Running OpenRAM compiler..."
	@cd $(OPENRAM_OUTDIR) && \
	    . $(VENV_DIR)/bin/activate && \
	    OPENRAM_HOME=$(OPENRAM)/compiler \
	    OPENRAM_TECH=$(OPENRAM)/technology \
	    PYTHONPATH=$(OPENRAM)/compiler \
	    $(PYTHON3) $(OPENRAM)/sram_compiler.py openram_sram_1rw_8192x8.py
	@echo "========================================"
	@echo " OpenRAM macros compiled in $(OPENRAM_OUTDIR)/"
	@echo " Run 'make synth' to proceed to OpenLane2."
	@echo "========================================"

# ── OpenLane2 full flow (synthesis + place + route + signoff) ────────────────
OPENLANE_RUN_DIR := $(BUILD_DIR)/openlane_run

$(BUILD_DIR):
	mkdir -p $@

SRAM_LEF := $(OPENRAM_OUTDIR)/sram_1rw_8192x8/sram_1rw_8192x8.lef

synth: check $(BUILD_DIR)
	@echo "========================================"
	@echo " Running OpenLane2 Classic flow"
	@echo "  Design  : $(DESIGN)"
	@echo "  PDK     : $(PDK) (Nangate 45nm)"
	@echo "  PDK_ROOT: $(PDK_ROOT)"
	@echo "  Config  : $(OPENLANE_DIR)/config.yaml"
	@echo "========================================"
	@if [ ! -f "$(SRAM_LEF)" ]; then \
	    echo "ERROR: SRAM macro LEF not found: $(SRAM_LEF)"; \
	    echo "       Run 'make gen-mem' before 'make synth'."; \
	    exit 1; \
	fi
	@( \
	    export PYTHONPATH="$(OPENLANE):$$PYTHONPATH"; \
	    export NANGATE_HOME="$(NANGATE_HOME)"; \
	    cd $(OPENLANE_DIR) && \
	    $(OPENLANE_CMD) \
	        --pdk-root $(PDK_ROOT) \
	        --pdk $(PDK) \
	        --run-dir $(OPENLANE_RUN_DIR) \
	        config.yaml \
	)
	@echo "========================================"
	@echo " OpenLane2 run complete."
	@echo " Results: $(OPENLANE_RUN_DIR)/"
	@echo "========================================"

# ── Standalone OpenROAD P&R ──────────────────────────────────────────────────
# Inputs expected:
#   NETLIST   — synthesised gate-level Verilog (set on command line or below)
#   SDC_FILE  — timing constraints  (defaults to openlane/jv32_soc_pnr.sdc)
#
# Outputs land in build/pnr/{results,reports}/.
#
# Usage:
#   make pnr NETLIST=/path/to/jv32_soc_synth.v
#
NETLIST   ?= $(OPENLANE_RUN_DIR)/final/nl/jv32_soc.nl.v
SDC_FILE  ?= $(OPENLANE_DIR)/jv32_soc_pnr.sdc

SRAM_LIB_TT := $(OPENRAM_OUTDIR)/sram_1rw_8192x8/sram_1rw_8192x8_TT_1p1V_25C.lib
SRAM_LIB_FF := $(OPENRAM_OUTDIR)/sram_1rw_8192x8/sram_1rw_8192x8_FF_1p1V_25C.lib
SRAM_LIB_SS := $(OPENRAM_OUTDIR)/sram_1rw_8192x8/sram_1rw_8192x8_SS_1p1V_25C.lib

PNR_RESULTS := $(BUILD_DIR)/pnr/results
PNR_REPORTS := $(BUILD_DIR)/pnr/reports

pnr: check $(BUILD_DIR)
	@echo "========================================"
	@echo " Standalone OpenROAD Place-and-Route"
	@echo "  Design     : $(DESIGN)"
	@echo "  Netlist    : $(NETLIST)"
	@echo "  SDC        : $(SDC_FILE)"
	@echo "  NANGATE    : $(NANGATE_HOME)"
	@echo "  SRAM LEF   : $(SRAM_LEF)"
	@echo "  Results    : $(PNR_RESULTS)/"
	@echo "  Reports    : $(PNR_REPORTS)/"
	@echo "========================================"
	@if [ -z "$(NANGATE_HOME)" ]; then \
	    echo "ERROR: NANGATE_HOME is not set. Set it in env.config or on the command line."; \
	    exit 1; \
	fi
	@if [ ! -f "$(NETLIST)" ]; then \
	    echo "ERROR: Netlist not found: $(NETLIST)"; \
	    echo "       Run 'make synth' first, or set NETLIST=<path> explicitly."; \
	    exit 1; \
	fi
	@if [ ! -f "$(SRAM_LEF)" ]; then \
	    echo "ERROR: SRAM macro LEF not found: $(SRAM_LEF)"; \
	    echo "       Run 'make gen-mem' first."; \
	    exit 1; \
	fi
	mkdir -p $(PNR_RESULTS) $(PNR_REPORTS)
	env DESIGN=$(DESIGN) \
	    NANGATE_DIR=$(NANGATE_HOME) \
	    NETLIST=$(NETLIST) \
	    SDC_FILE=$(SDC_FILE) \
	    RESULTS_DIR=$(PNR_RESULTS) \
	    REPORTS_DIR=$(PNR_REPORTS) \
	    SRAM_LEF=$(SRAM_LEF) \
	    SRAM_LIB=$(SRAM_LIB_TT) \
	    CORE_UTIL=35 \
	    MAX_ROUTING_LAYER=metal7 \
	    $(OPENROAD) -exit $(SYN_DIR)/scripts/openroad/run_pnr.tcl \
	        2>&1 | tee $(PNR_REPORTS)/pnr_run.log
	@echo "========================================"
	@echo " P&R complete. Results: $(PNR_RESULTS)/"
	@echo "========================================"

# ── Standalone timing report (post-route STA) ────────────────────────────────
# Reads the ODB written by 'make pnr' (or by OpenLane2 final step).
# Supply ODB_FILE on the command line to point at a different database.
#
# Usage (after make pnr):
#   make timing-report
# Usage with explicit ODB:
#   make timing-report ODB_FILE=/path/to/design_final.odb
#
ODB_FILE  ?= $(PNR_RESULTS)/$(DESIGN)_final.odb

timing-report:
	@echo "========================================"
	@echo " Post-route Static Timing Analysis"
	@echo "  Design  : $(DESIGN)"
	@echo "  ODB     : $(ODB_FILE)"
	@echo "  SDC     : $(SDC_FILE)"
	@echo "  NANGATE : $(NANGATE_HOME)"
	@echo "  Reports : $(PNR_REPORTS)/"
	@echo "========================================"
	@if [ -z "$(NANGATE_HOME)" ]; then \
	    echo "ERROR: NANGATE_HOME is not set."; exit 1; \
	fi
	@if [ ! -f "$(ODB_FILE)" ]; then \
	    echo "ERROR: ODB not found: $(ODB_FILE)"; \
	    echo "       Run 'make pnr' first, or set ODB_FILE=<path> explicitly."; \
	    exit 1; \
	fi
	@if [ ! -f "$(SRAM_LIB_TT)" ]; then \
	    echo "ERROR: SRAM liberty not found: $(SRAM_LIB_TT)"; \
	    echo "       Run 'make gen-mem' first."; \
	    exit 1; \
	fi
	env DESIGN=$(DESIGN) \
	    NANGATE_DIR=$(NANGATE_HOME) \
	    ODB_FILE=$(ODB_FILE) \
	    SDC_FILE=$(SDC_FILE) \
	    REPORTS_DIR=$(PNR_REPORTS) \
	    SRAM_LEF=$(SRAM_LEF) \
	    SRAM_LIB_TT=$(SRAM_LIB_TT) \
	    SRAM_LIB_FF=$(if $(wildcard $(SRAM_LIB_FF)),$(SRAM_LIB_FF),) \
	    SRAM_LIB_SS=$(if $(wildcard $(SRAM_LIB_SS)),$(SRAM_LIB_SS),) \
	    CORNER=TT_1p1V_25C \
	    $(OPENROAD) -exit $(SYN_DIR)/scripts/openroad/report_timing.tcl \
	        2>&1 | tee $(PNR_REPORTS)/timing_run.log
	@echo ""
	@echo "========================================"
	@echo " Timing analysis complete."
	@echo " Key reports:"
	@echo "   Setup : $(PNR_REPORTS)/timing_setup.rpt"
	@echo "   Hold  : $(PNR_REPORTS)/timing_hold.rpt"
	@echo "   WNS   : $(PNR_REPORTS)/timing_summary.rpt"
	@echo "   Power : $(PNR_REPORTS)/power.rpt"
	@echo "   Area  : $(PNR_REPORTS)/area.rpt"
	@echo "========================================"

# ── Reports convenience targets ───────────────────────────────────────────────
reports:
	@find $(OPENLANE_RUN_DIR) -name "*.rpt" | sort | \
	    xargs -I{} sh -c 'echo "=== {} ==="; cat "{}"; echo'

summary:
	@find $(OPENLANE_RUN_DIR) -name "metrics.json" | sort -r | head -1 | \
	    xargs -r cat

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	@echo "Removing OpenLane2 run directory..."
	rm -rf $(BUILD_DIR)

cleanall: clean
	@echo "Removing venv and generated OpenRAM macros..."
	rm -rf $(VENV_DIR) $(OPENRAM_OUTDIR)
	@echo "Done."

# ── Help ─────────────────────────────────────────────────────────────────────
help:
	@echo "jv32 SoC Synthesis & Place-and-Route Flow"
	@echo ""
	@echo "Usage:"
	@echo "  make openram-setup            # create local Python venv for OpenRAM"
	@echo "  make gen-mem                  # compile OpenRAM SRAM macros (freepdk45)"
	@echo "  make synth                    # run OpenLane2 (synth + PnR)"
	@echo "  make pnr                      # standalone OpenROAD P&R (after synth)"
	@echo "  make timing-report            # post-route STA (after pnr)"
	@echo "  make check                    # verify tool paths"
	@echo "  make reports                  # print all .rpt files from last OpenLane2 run"
	@echo "  make summary                  # print metrics.json from last OpenLane2 run"
	@echo "  make clean                    # remove build directory"
	@echo "  make cleanall                 # remove build + venv + OpenRAM macros"
	@echo ""
	@echo "Key variables (set in ../env.config or override on command line):"
	@echo "  OPENRAM        = $(OPENRAM)"
	@echo "  OPENLANE       = $(OPENLANE)"
	@echo "  OPENROAD       = $(OPENROAD)"
	@echo "  NANGATE_HOME   = $(if $(NANGATE_HOME),$(NANGATE_HOME),(not set))"
	@echo "  IRAM_SIZE      = $(IRAM_SIZE) bytes (= $$(( $(IRAM_SIZE)/1024 )) KB)"
	@echo "  DRAM_SIZE      = $(DRAM_SIZE) bytes (= $$(( $(DRAM_SIZE)/1024 )) KB)"
	@echo "  OPENRAM_OPTIMIZE = $(OPENRAM_OPTIMIZE) (speed|area)"
	@echo ""
	@echo "Standalone P&R overrides:"
	@echo "  NETLIST       = $(NETLIST)"
	@echo "  SDC_FILE      = $(SDC_FILE)"
	@echo "  ODB_FILE      = $(ODB_FILE)  (for timing-report)"
	@echo ""
	@echo "Example: different memory sizes"
	@echo "  make gen-mem IRAM_SIZE=65536 DRAM_SIZE=65536  # 64 KB each"
	@echo ""
	@echo "Notes:"
	@echo "  - NANGATE_HOME must point to ~/opt/nangate (or your Nangate distribution)"
	@echo "  - OpenRAM 1.2.48 requires numpy<2 and Python 3.8+"
	@echo "  - OpenLane2 run results are in build/openlane_run/"
	@echo "  - Standalone P&R results are in build/pnr/{results,reports}/"
