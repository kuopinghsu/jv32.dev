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
-include ../Makefile.cfg
-include $(SYN_DIR)/common/core_params.mk

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

# openlane run command.
# Default: use the nix-shell wrapper (scripts/openlane_nix.sh) so that
# OpenLane2 dependencies (libparse, klayout, OpenROAD Python bindings, …)
# are provided by Nix rather than the system Python.
# Override with  OPENLANE_CMD=python3 -m openlane  if you prefer a bare
# pip-installed environment (run 'make syn-setup' to install deps first).
OPENLANE_CMD ?= $(SYN_DIR)/scripts/openlane_nix.sh

# Nix-shell binary (override if nix-shell is not in PATH)
NIX_SHELL ?= nix-shell

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

# ── TCM memory size (N × 8 KB OpenRAM macro units) ──────────────────────────
# sram_1rw_2048x32 = 2048 words × 32 bits = 8 KB  (one basic macro sub-bank)
# IRAM_BANKS / DRAM_BANKS: how many sub-banks to stitch per TCM.
# The Makefile computes IRAM_SIZE/DRAM_SIZE and writes them into
# build/tcm_params.yaml, which OpenLane2 picks up as a config override.
# NOTE: if IRAM_BANKS changes, add a matching DEPTH case in syn/lib/sram_1rw.sv
MACRO_BYTES  := 8192
IRAM_BANKS   ?= 2             # N × 8 KB  →  default 16 KB IRAM
DRAM_BANKS   ?= 2             # N × 8 KB  →  default 16 KB DRAM
IRAM_SIZE    := $(shell echo $$(( $(IRAM_BANKS) * $(MACRO_BYTES) )))
DRAM_SIZE    := $(shell echo $$(( $(DRAM_BANKS) * $(MACRO_BYTES) )))

# MUL_MC: 1=2-stage pipelined multiplier (16x16 partial products, 2 cycles; better timing).
#         0=1-cycle combinatorial 32x32 multiply.  Requires FAST_MUL=1.  Default 1.
MUL_MC       ?= 1

# OpenRAM config file (static; re-run gen-mem only for a different macro geometry)
OPENRAM_CFG  ?= openram_sram_1rw_2048x32.py

# OpenRAM optimisation: speed (words_per_row=1, TT+FF+SS) or area (auto, TT)
OPENRAM_OPTIMIZE ?= speed

export NANGATE_HOME
export PDK_ROOT
export OPENRAM
export OPENLANE
export NIX_SHELL

# Nangate typical liberty file — used by gate-count and NAND2-equivalent
# reporting in gen_report.py.
NANGATE_LIB ?= $(NANGATE_HOME)/lib/NangateOpenCellLibrary_typical.lib

.PHONY: all check openram-setup syn-setup gen-mem synth synth-resume pnr timing-report gate-count drc lvs clean cleanall help

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
	    echo "         Set NANGATE_HOME in env.config to avoid errors."; \
	else \
	    echo "  NANGATE_HOME : $(NANGATE_HOME)"; \
	    for entry in \
	      "lef/NangateOpenCellLibrary.tech.lef" \
	      "lef/NangateOpenCellLibrary.macro.lef" \
	      "gds/NangateOpenCellLibrary.gds"; \
	    do \
	      if [ ! -f "$(NANGATE_HOME)/$$entry" ]; then \
	        echo "WARNING: $(NANGATE_HOME)/$$entry not found"; \
	      fi; \
	    done; \
	fi
	@echo "  PDK_ROOT     : $(PDK_ROOT)"
	@echo "  OPENRAM_OUT  : $(OPENRAM_OUTDIR)"
	@echo "Checks passed."

# ── OpenLane2 / Nix dependency setup ─────────────────────────────────────────
# Pre-fetches all OpenLane2 Nix packages into the local Nix store so that
# subsequent 'make synth' invocations start without a network download.
#
# Run once after cloning / updating openlane2:
#   make syn-setup
#
syn-setup:
	@echo "========================================"
	@echo " OpenLane2 Nix dependency setup"
	@echo "  OPENLANE : $(OPENLANE)"
	@echo "  NIX_SHELL: $(NIX_SHELL)"
	@echo "========================================" 
	@if [ ! -d "$(OPENLANE)" ]; then \
	    echo "ERROR: OPENLANE not found at '$(OPENLANE)'"; \
	    echo "       Set OPENLANE in env.config."; \
	    exit 1; \
	fi
	@if [ ! -f "$(OPENLANE)/shell.nix" ]; then \
	    echo "ERROR: shell.nix not found in $(OPENLANE)."; \
	    echo "       Make sure OPENLANE points to the openlane2 source tree."; \
	    exit 1; \
	fi
	@if ! command -v $(NIX_SHELL) >/dev/null 2>&1; then \
	    echo "ERROR: nix-shell not found. Install Nix: https://nixos.org/download"; \
	    exit 1; \
	fi
	@echo "Pre-fetching Nix packages (this may take several minutes on first run)..."
	$(NIX_SHELL) $(OPENLANE)/shell.nix --run \
	    "python3 -m openlane --version"
	@chmod +x $(SYN_DIR)/scripts/openlane_nix.sh
	@echo "========================================" 
	@echo " syn-setup complete."
	@echo " Nix store is primed; 'make synth' will use:"
	@echo "   OPENLANE_CMD = $(OPENLANE_CMD)"
	@echo "========================================" 

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
	@echo "venv ready. Activate with: source $(VENV_DIR)/bin/activate"

# ── OpenRAM macro compilation ────────────────────────────────────────────────
gen-mem:
	@echo "========================================"
	@echo " Compiling OpenRAM SRAM macros"
	@echo "  PDK      : $(PDK) (Nangate 45nm)"
	@echo "  OPENRAM  : $(OPENRAM)"
	@echo "  Config   : $(OPENRAM_OUTDIR)/$(OPENRAM_CFG)"
	@echo "  Macro    : sram_1rw_2048x32 (2048 words x 32-bit = 8 KB)"
	@echo "  IRAM     : $(IRAM_BANKS) banks × 8 KB = $(shell echo $$(( $(IRAM_SIZE)/1024 ))) KB"
	@echo "  DRAM     : $(DRAM_BANKS) banks × 8 KB = $(shell echo $$(( $(DRAM_SIZE)/1024 ))) KB"
	@echo "========================================"
	@if [ ! -d "$(OPENRAM)" ]; then \
	    echo "ERROR: OPENRAM not found at '$(OPENRAM)'"; exit 1; \
	fi
	@if [ ! -f "$(VENV_DIR)/bin/activate" ]; then \
	    echo "ERROR: venv not found. Run 'make openram-setup' first."; exit 1; \
	fi
	@if [ ! -f "$(OPENRAM_OUTDIR)/$(OPENRAM_CFG)" ]; then \
	    echo "ERROR: OpenRAM config not found: $(OPENRAM_OUTDIR)/$(OPENRAM_CFG)"; exit 1; \
	fi
	@echo "Running OpenRAM compiler..."
	@cd $(OPENRAM_OUTDIR) && \
	    . $(VENV_DIR)/bin/activate && \
	    OPENRAM_HOME=$(OPENRAM)/compiler \
	    OPENRAM_TECH=$(OPENRAM)/technology \
	    PYTHONPATH=$(OPENRAM)/compiler \
	    $(PYTHON3) $(OPENRAM)/sram_compiler.py $(OPENRAM_CFG)
	@echo "Snapping OpenRAM LEF pin geometry to manufacturing grid..."
	@$(PYTHON3) $(SYN_DIR)/common/fix_openram_lef_grid.py $(OPENRAM_OUTDIR)/sram_1rw_2048x32.lef
	@echo "========================================"
	@echo " OpenRAM macros compiled in $(OPENRAM_OUTDIR)/"
	@echo " Run 'make synth' to proceed to OpenLane2."
	@echo "========================================"

# ── OpenLane2 full flow (synthesis + place + route + signoff) ────────────────
OPENLANE_RUN_DIR := $(BUILD_DIR)/openlane_run
TCM_PARAMS_YAML  := $(BUILD_DIR)/tcm_params.yaml
SYNTH_LOCK_DIR   := $(BUILD_DIR)/.synth.lock
RESUME           ?= 0
OPENLANE_FROM    ?=

$(BUILD_DIR):
	mkdir -p $@

SRAM_LEF := $(OPENRAM_OUTDIR)/sram_1rw_2048x32.lef

synth: check $(BUILD_DIR)
	@echo "========================================"
	@echo " Running OpenLane2 Classic flow"
	@echo "  Design  : $(DESIGN)"
	@echo "  PDK     : $(PDK) (Nangate 45nm)"
	@echo "  PDK_ROOT: $(PDK_ROOT)"
	@echo "  Config  : $(OPENLANE_DIR)/config.yaml"
	@echo "  IRAM    : $(IRAM_BANKS) × 8 KB = $(shell echo $$(( $(IRAM_SIZE) / 1024 ))) KB"
	@echo "  DRAM    : $(DRAM_BANKS) × 8 KB = $(shell echo $$(( $(DRAM_SIZE) / 1024 ))) KB"
	@echo "========================================"
	@if [ ! -f "$(SRAM_LEF)" ]; then \
	    echo "ERROR: SRAM macro LEF not found: $(SRAM_LEF)"; \
	    echo "       Run 'make gen-mem' before 'make synth'."; \
	    exit 1; \
	fi
	@printf 'SYNTH_PARAMETERS:\n  - IRAM_SIZE=%d\n  - DRAM_SIZE=%d\n  - FAST_MUL=%d\n  - MUL_MC=%d\n  - FAST_DIV=%d\n  - FAST_SHIFT=%d\n  - BP_EN=%d\n' \
	    $(IRAM_SIZE) $(DRAM_SIZE) $(FAST_MUL) $(MUL_MC) $(FAST_DIV) $(FAST_SHIFT) $(BP_EN) > $(TCM_PARAMS_YAML)
	@# OpenLane 2 resolves dir:: relative to the LAST config file passed.
	@# Since tcm_params.yaml lives in BUILD_DIR, copy the path-referenced
	@# files there so OpenLane finds them.
	@cp $(OPENLANE_DIR)/jv32_soc_pnr.sdc  $(BUILD_DIR)/jv32_soc_pnr.sdc
	@cp $(OPENLANE_DIR)/macro_placement.cfg $(BUILD_DIR)/macro_placement.cfg
	@( \
	    if ! mkdir $(SYNTH_LOCK_DIR) 2>/dev/null; then \
	        echo "ERROR: another 'make synth' is already running (lock: $(SYNTH_LOCK_DIR))"; \
	        echo "       Wait for it to finish, or remove the lock if it is stale."; \
	        exit 1; \
	    fi; \
	    trap 'rmdir $(SYNTH_LOCK_DIR) 2>/dev/null || true' EXIT INT TERM; \
	    export PYTHONPATH="$(OPENLANE):$$PYTHONPATH"; \
	    export NANGATE_HOME="$(NANGATE_HOME)"; \
	    if [ "$(RESUME)" = "1" ]; then \
	        if [ ! -f "$(OPENLANE_RUN_DIR)/flow.log" ]; then \
	            echo "ERROR: cannot resume because $(OPENLANE_RUN_DIR)/flow.log was not found."; \
	            echo "       Run 'make synth' first, or set OPENLANE_FROM=<step-id> and rerun with RESUME=1."; \
	            exit 1; \
	        fi; \
	        resume_from="$(OPENLANE_FROM)"; \
	        if [ -z "$$resume_from" ]; then \
	            resume_from="$$($(PYTHON3) $(SYN_DIR)/scripts/openlane_resume_step.py $(OPENLANE_RUN_DIR)/flow.log)"; \
	        fi; \
	        if [ -z "$$resume_from" ]; then \
	            echo "ERROR: failed to determine a resume step from $(OPENLANE_RUN_DIR)/flow.log"; \
	            echo "       Set OPENLANE_FROM=<step-id> explicitly, e.g. OPENLANE_FROM=KLayout.StreamOut"; \
	            exit 1; \
	        fi; \
	        echo "Resuming OpenLane2 from step: $$resume_from"; \
	        cd $(OPENLANE_DIR) && \
	        $(OPENLANE_CMD) \
	            --pdk-root $(PDK_ROOT) \
	            --pdk $(PDK) \
	            --manual-pdk \
	            --force-run-dir $(OPENLANE_RUN_DIR) \
	            -F "$$resume_from" \
	            config.yaml \
	            $(TCM_PARAMS_YAML); \
	    else \
	        rm -rf $(OPENLANE_RUN_DIR); \
	        mkdir -p $(OPENLANE_RUN_DIR); \
	        cd $(OPENLANE_DIR) && \
	        $(OPENLANE_CMD) \
	            --pdk-root $(PDK_ROOT) \
	            --pdk $(PDK) \
	            --manual-pdk \
	            --force-run-dir $(OPENLANE_RUN_DIR) \
	            config.yaml \
	            $(TCM_PARAMS_YAML); \
	    fi \
	)
	@echo "========================================"
	@echo " OpenLane2 run complete."
	@echo " Results: $(OPENLANE_RUN_DIR)/"
	@echo "========================================"
	@echo " Running gate-count analysis..."
	@$(MAKE) --no-print-directory gate-count
	@echo " Generating summary report..."
	@$(PYTHON3) $(SYN_DIR)/scripts/gen_report.py \
	    $(OPENLANE_RUN_DIR) \
	    $(SYN_DIR)/REPORT.md \
	    --fast-mul   $(FAST_MUL)   \
	    --fast-div   $(FAST_DIV)   \
	    --fast-shift $(FAST_SHIFT) \
	    --bp-en      $(BP_EN)      \
	    --iram-kb    $(shell echo $$(( $(IRAM_SIZE) / 1024 ))) \
	    --dram-kb    $(shell echo $$(( $(DRAM_SIZE) / 1024 ))) \
	    --clock-mhz  80 \
	    $(if $(NANGATE_LIB),--nangate-lib $(NANGATE_LIB),) \
	    $(if $(wildcard $(GATE_COUNT_STAT)),--gate-count-json $(GATE_COUNT_STAT),)
	@echo " Summary : $(SYN_DIR)/REPORT.md"
	@echo " Generating layout diagram..."
	@$(PYTHON3) $(SYN_DIR)/scripts/gen_layout_diag.py \
	    $(OPENLANE_RUN_DIR) \
	    $(BUILD_DIR)/LAYOUT.png \
	    --lef-dir $(SYN_DIR)/lib/openram \
	    --title "$(DESIGN) — Layout Floorplan ($(shell echo $$(( $(IRAM_SIZE)/1024 ))) KB IRAM / $(shell echo $$(( $(DRAM_SIZE)/1024 ))) KB DRAM)" \
	    || echo " WARNING: layout diagram generation failed (matplotlib required)"
	@echo " Layout  : $(BUILD_DIR)/LAYOUT.png"
	@echo "========================================"

synth-resume: RESUME=1
synth-resume: synth

# ── Gate count analysis (hierarchical, NAND2 equivalents) ───────────────────
# Runs a separate OpenLane2 synthesis pass that preserves module hierarchy
# (SYNTH_HIERARCHY_MODE: keep) so Yosys produces per-module gate counts.
# Converts the results to NAND2-equivalent units and writes a report.
#
# Output: build/gate_count.rpt
#
# Run independently (does not require a prior 'make synth'):
#   make gate-count
#
GATE_COUNT_RUN_DIR := $(BUILD_DIR)/gate_count_run
GATE_COUNT_STAT    := $(GATE_COUNT_RUN_DIR)/stat.json
GATE_COUNT_RPT     := $(BUILD_DIR)/gate_count.rpt

# RTL_DIR: absolute path to the project rtl/ directory (one level above syn/).
RTL_DIR := $(abspath $(SYN_DIR)/../rtl)

gate-count: check $(BUILD_DIR)
	@echo "========================================"
	@echo " Gate Count Analysis (NAND2 equivalents)"
	@echo "  Design : $(DESIGN)"
	@echo "  Method : standalone Yosys (no flatten)"
	@echo "  Output : $(GATE_COUNT_RPT)"
	@echo "========================================"
	@if [ -z "$(NANGATE_HOME)" ]; then \
	    echo "ERROR: NANGATE_HOME is not set. Set it in env.config."; \
	    exit 1; \
	fi
	@rm -rf $(GATE_COUNT_RUN_DIR)
	@mkdir -p $(GATE_COUNT_RUN_DIR)
	@( \
	    export NANGATE_LIB="$(NANGATE_LIB)"; \
	    export STAT_JSON="$(GATE_COUNT_STAT)"; \
	    export RTL_DIR="$(RTL_DIR)"; \
	    export LIB_DIR="$(SYN_DIR)/lib"; \
	    export IRAM_SIZE="$(IRAM_SIZE)"; \
	    export DRAM_SIZE="$(DRAM_SIZE)"; \
	    export FAST_MUL="$(FAST_MUL)"; \
	    export MUL_MC="$(MUL_MC)"; \
	    export FAST_DIV="$(FAST_DIV)"; \
	    export FAST_SHIFT="$(FAST_SHIFT)"; \
	    export BP_EN="$(BP_EN)"; \
	    $(NIX_SHELL) $(OPENLANE)/shell.nix \
	        --run "bash $(SYN_DIR)/scripts/hier_synth.sh"; \
	)
	@echo " Generating gate count report..."
	@$(PYTHON3) $(SYN_DIR)/scripts/gen_gate_count.py \
	    $(GATE_COUNT_STAT) \
	    $(NANGATE_LIB) \
	    --output $(GATE_COUNT_RPT)
	@echo ""
	@cat $(GATE_COUNT_RPT)
	@echo ""
	@echo "========================================"
	@echo " Gate count report: $(GATE_COUNT_RPT)"
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

SRAM_LIB_TT := $(OPENRAM_OUTDIR)/sram_1rw_2048x32_TT_1p1V_25C.lib
SRAM_LIB_FF := $(OPENRAM_OUTDIR)/sram_1rw_2048x32_FF_1p0V_25C.lib
SRAM_LIB_SS := $(OPENRAM_OUTDIR)/sram_1rw_2048x32_SS_1p0V_25C.lib

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
# Prefer the OpenLane2 final ODB; fall back to the standalone pnr output.
_OL_ODB   := $(OPENLANE_RUN_DIR)/final/odb/$(DESIGN).odb
_PNR_ODB  := $(PNR_RESULTS)/$(DESIGN)_final.odb
ODB_FILE  ?= $(if $(wildcard $(_OL_ODB)),$(_OL_ODB),$(_PNR_ODB))

timing-report:
	@mkdir -p $(PNR_REPORTS)
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
	@python3 $(SYN_DIR)/scripts/extract_from_log.py $(PNR_REPORTS) || true
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

# ── Standalone DRC (Magic) ───────────────────────────────────────────────────
# Runs Magic DRC on the KLayout GDS from the last OpenLane2 run.
# Magic uses the built-in FreePDK45 / Nangate45 DRC rule deck.
#
# Usage:
#   make drc
#   make drc GDS_FILE=/path/to/custom.gds
#
_OL_GDS  := $(OPENLANE_RUN_DIR)/final/klayout_gds/$(DESIGN).klayout.gds
GDS_FILE ?= $(if $(wildcard $(_OL_GDS)),$(_OL_GDS),)
DRC_RPT  := $(BUILD_DIR)/drc.rpt
DRC_LOG  := $(BUILD_DIR)/drc_magic.log

drc:
	@echo "========================================"
	@echo " Standalone Magic DRC"
	@echo "  Design  : $(DESIGN)"
	@echo "  GDS     : $(GDS_FILE)"
	@echo "  Report  : $(DRC_RPT)"
	@echo "========================================"
	@if [ -z "$(GDS_FILE)" ] || [ ! -f "$(GDS_FILE)" ]; then \
	    echo "ERROR: GDS not found: $(GDS_FILE)"; \
	    echo "       Run 'make synth' first, or set GDS_FILE=<path>"; \
	    exit 1; \
	fi
	@if [ -z "$(PDK_ROOT)" ]; then \
	    echo "ERROR: PDK_ROOT is not set."; exit 1; \
	fi
	@mkdir -p $(BUILD_DIR)
	@printf '%%s\n' \
	    'drc euclidean on' \
	    'load $(GDS_FILE) -dereference' \
	    'select top cell' \
	    'drc check' \
	    'set count [drc listcount]' \
	    'puts "DRC violations: $$count"' \
	    'set f [open $(DRC_RPT) w]' \
	    'puts $$f "Magic DRC report — $(DESIGN)"' \
	    'puts $$f "GDS : $(GDS_FILE)"' \
	    'puts $$f "Date: [clock format [clock seconds]]"' \
	    'puts $$f ""' \
	    'puts $$f "Total DRC violations: $$count"' \
	    'puts $$f ""' \
	    'foreach item [drc listall why] { puts $$f $$item }' \
	    'close $$f' \
	    'quit -noprompt' \
	    > $(BUILD_DIR)/drc_magic_cmd.tcl
	MAGIC_EXT_USE_GDS=1 \
	    magic -dnull -noconsole \
	        -rcfile $(PDK_ROOT)/freepdk45/libs.tech/magic/FreePDK45.magicrc \
	        $(BUILD_DIR)/drc_magic_cmd.tcl \
	    2>&1 | tee $(DRC_LOG)
	@rm -f $(BUILD_DIR)/drc_magic_cmd.tcl
	@echo "========================================"
	@echo " DRC report: $(DRC_RPT)"
	@grep -E "^Total DRC" $(DRC_RPT) || true
	@echo "========================================"

# ── Standalone LVS (Magic + Netgen) ─────────────────────────────────────────
# Extracts a SPICE netlist from the GDS using Magic, then runs Netgen LVS
# against the post-route gate-level Verilog netlist.
#
# Usage:
#   make lvs
#   make lvs GDS_FILE=... NETLIST=...
#
_OL_NL   := $(OPENLANE_RUN_DIR)/final/nl/$(DESIGN).nl.v
LVS_NL   ?= $(if $(wildcard $(_OL_NL)),$(_OL_NL),)
LVS_LOG  := $(BUILD_DIR)/lvs.log
LVS_RPT  := $(BUILD_DIR)/lvs.rpt

lvs:
	@echo "========================================"
	@echo " Standalone Magic + Netgen LVS"
	@echo "  Design  : $(DESIGN)"
	@echo "  GDS     : $(GDS_FILE)"
	@echo "  Netlist : $(LVS_NL)"
	@echo "  Report  : $(LVS_RPT)"
	@echo "========================================"
	@if [ -z "$(GDS_FILE)" ] || [ ! -f "$(GDS_FILE)" ]; then \
	    echo "ERROR: GDS not found: $(GDS_FILE)"; \
	    echo "       Run 'make synth' first, or set GDS_FILE=<path>"; \
	    exit 1; \
	fi
	@if [ -z "$(LVS_NL)" ] || [ ! -f "$(LVS_NL)" ]; then \
	    echo "ERROR: Gate-level netlist not found: $(LVS_NL)"; \
	    echo "       Run 'make synth' first, or set LVS_NL=<path>"; \
	    exit 1; \
	fi
	@if [ -z "$(PDK_ROOT)" ]; then \
	    echo "ERROR: PDK_ROOT is not set."; exit 1; \
	fi
	@mkdir -p $(BUILD_DIR)
	@# Step 1: Magic SPICE extraction from GDS
	@printf '%%s\n' \
	    'gds read $(GDS_FILE)' \
	    'load $(DESIGN)' \
	    'select top cell' \
	    'port makeall' \
	    'ext2spice lvs' \
	    'ext2spice -o $(BUILD_DIR)/$(DESIGN).spice' \
	    'quit -noprompt' \
	    > $(BUILD_DIR)/lvs_magic_cmd.tcl
	MAGIC_EXT_USE_GDS=1 \
	    magic -dnull -noconsole \
	        -rcfile $(PDK_ROOT)/freepdk45/libs.tech/magic/FreePDK45.magicrc \
	        $(BUILD_DIR)/lvs_magic_cmd.tcl \
	    2>&1 | tee $(LVS_LOG)
	@rm -f $(BUILD_DIR)/lvs_magic_cmd.tcl
	@# Step 2: Netgen LVS (extracted SPICE vs gate-level netlist)
	netgen -batch lvs \
	    "$(BUILD_DIR)/$(DESIGN).spice $(DESIGN)" \
	    "$(LVS_NL) $(DESIGN)" \
	    $(PDK_ROOT)/freepdk45/libs.tech/netgen/FreePDK45_setup.tcl \
	    $(LVS_RPT) \
	    2>&1 | tee -a $(LVS_LOG)
	@echo "========================================"
	@echo " LVS report: $(LVS_RPT)"
	@grep -E "(Circuit|Netlist|match|Mismatch)" $(LVS_RPT) | tail -5 || true
	@echo "========================================"

# ── Clean ─────────────────────────────────────────────────────────────────────
# SLPP_ALL_DIRS: Surelog pre-processing cache directories generated by OpenLane
# (yosys-with-surelog step).  They live in the source tree but are fully
# regenerated on every 'make synth' run, so remove them on clean.
SLPP_ALL_DIRS := $(SYN_DIR)/slpp_all $(SYN_DIR)/openlane/slpp_all

clean:
	@echo "Removing OpenLane2 run directory..."
	rm -rf $(BUILD_DIR)
	@echo "Removing Surelog cache directories..."
	rm -rf $(SLPP_ALL_DIRS)

cleanall: clean
	@echo "Removing venv and generated OpenRAM macros..."
	rm -rf $(VENV_DIR) $(OPENRAM_OUTDIR)
	@echo "Done."

# ── Help ─────────────────────────────────────────────────────────────────────
help:
	@echo "jv32 SoC Synthesis & Place-and-Route Flow"
	@echo ""
	@echo "First-time setup:"
	@echo "  1. cp ../env.config.template ../env.config  && edit env.config"
	@echo "  2. make openram-setup         # create Python venv for OpenRAM"
	@echo "  3. make syn-setup             # pre-fetch OpenLane2 Nix packages"
	@echo ""
	@echo "Usage:"
	@echo "  make openram-setup            # create local Python venv for OpenRAM"
	@echo "  make syn-setup                # pre-fetch OpenLane2 Nix deps (run once)"
	@echo "  make gen-mem                  # compile OpenRAM SRAM macros (freepdk45)"
	@echo "  make synth                    # run OpenLane2 (synth + PnR + DRC + LVS)"
	@echo "  make synth-resume             # resume last OpenLane2 run from failed step"
	@echo "  make gate-count               # hierarchical gate count (NAND2 eq, with hierarchy)"
	@echo "  make pnr                      # standalone OpenROAD P&R (after synth)"
	@echo "  make timing-report            # post-route STA with hold repair (after pnr)"
	@echo "  make drc                      # standalone Magic DRC on last OpenLane2 GDS"
	@echo "  make lvs                      # standalone Magic+Netgen LVS on last OpenLane2 GDS"
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
	@echo "  IRAM_BANKS     = $(IRAM_BANKS)  (N × 8 KB = $(shell echo $$(( $(IRAM_SIZE)/1024 ))) KB IRAM)"
	@echo "  DRAM_BANKS     = $(DRAM_BANKS)  (N × 8 KB = $(shell echo $$(( $(DRAM_SIZE)/1024 ))) KB DRAM)"
	@echo "  OPENRAM_CFG    = $(OPENRAM_CFG)  (static config in lib/openram/)"
	@echo "  OPENRAM_OPTIMIZE = $(OPENRAM_OPTIMIZE) (speed|area)"
	@echo "  RESUME         = $(RESUME)  (set to 1 to resume instead of starting clean)"
	@echo "  OPENLANE_FROM  = $(if $(OPENLANE_FROM),$(OPENLANE_FROM),(auto-detect from flow.log))"
	@echo ""
	@echo "  NOTE: SYNTH_PARAMETERS are generated into build/tcm_params.yaml at"
	@echo "        synth time and passed to OpenLane2 as a second config file."
	@echo "        To change TCM size: set IRAM_BANKS and DRAM_BANKS, and ensure"
	@echo "        syn/lib/sram_1rw.sv has a matching DEPTH generate branch."
	@echo ""
	@echo "Standalone P&R overrides:"
	@echo "  NETLIST       = $(NETLIST)"
	@echo "  SDC_FILE      = $(SDC_FILE)"
	@echo "  ODB_FILE      = $(ODB_FILE)  (for timing-report)"
	@echo ""
	@echo "Notes:"
	@echo "  - NANGATE_HOME must point to ~/opt/nangate (or your Nangate distribution)"
	@echo "  - OpenRAM 1.2.48 requires numpy<2 and Python 3.8+"
	@echo "  - OpenLane2 run results are in build/openlane_run/"
	@echo "  - Standalone P&R results are in build/pnr/{results,reports}/"
