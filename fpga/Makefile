# ==========================================================================
# JV32 FPGA build helpers (Vivado)
# ==========================================================================

SHELL := /bin/bash

VIVADO ?= vivado
VIVADO_FLAGS ?= -mode batch -notrace

PROJ_NAME ?= jv32_ku5p
PROJ_DIR ?= fpga/vivado/build
TOP_MODULE ?= jv32_soc
JV32_CLK_HZ ?= 50000000
INCLUDE_DDR4_XDC ?= 0

VIVADO_SCRIPT := vivado/create_project.tcl

.PHONY: help project synth impl clean

help:
	@echo "FPGA Vivado flow targets:"
	@echo "  make -C fpga project                # create project only"
	@echo "  make -C fpga synth                  # create project + run synthesis"
	@echo "  make -C fpga impl                   # create project + run impl + bitstream"
	@echo ""
	@echo "Configurable variables:"
	@echo "  VIVADO=<path-to-vivado>             (default: vivado)"
	@echo "  PROJ_NAME=<project-name>            (default: jv32_ku5p)"
	@echo "  PROJ_DIR=<relative-project-dir>     (default: fpga/vivado/build)"
	@echo "  TOP_MODULE=<rtl-top>                (default: jv32_soc)"
	@echo "  JV32_CLK_HZ=<clock-hz>              (default: 50000000)"
	@echo "  INCLUDE_DDR4_XDC=0|1                (default: 0)"

project:
	PROJ_NAME=$(PROJ_NAME) \
	PROJ_DIR=$(PROJ_DIR) \
	TOP_MODULE=$(TOP_MODULE) \
	JV32_CLK_HZ=$(JV32_CLK_HZ) \
	INCLUDE_DDR4_XDC=$(INCLUDE_DDR4_XDC) \
	RUN_SYNTH=0 RUN_IMPL=0 \
	$(VIVADO) $(VIVADO_FLAGS) -source $(VIVADO_SCRIPT)

synth:
	PROJ_NAME=$(PROJ_NAME) \
	PROJ_DIR=$(PROJ_DIR) \
	TOP_MODULE=$(TOP_MODULE) \
	JV32_CLK_HZ=$(JV32_CLK_HZ) \
	INCLUDE_DDR4_XDC=$(INCLUDE_DDR4_XDC) \
	RUN_SYNTH=1 RUN_IMPL=0 \
	$(VIVADO) $(VIVADO_FLAGS) -source $(VIVADO_SCRIPT)

impl:
	PROJ_NAME=$(PROJ_NAME) \
	PROJ_DIR=$(PROJ_DIR) \
	TOP_MODULE=$(TOP_MODULE) \
	JV32_CLK_HZ=$(JV32_CLK_HZ) \
	INCLUDE_DDR4_XDC=$(INCLUDE_DDR4_XDC) \
	RUN_SYNTH=1 RUN_IMPL=1 \
	$(VIVADO) $(VIVADO_FLAGS) -source $(VIVADO_SCRIPT)

clean:
	@echo "Removing Vivado build outputs from $(PROJ_DIR)"
	@rm -rf $(PROJ_DIR)
