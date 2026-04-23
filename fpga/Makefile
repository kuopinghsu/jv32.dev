# ==========================================================================
# JV32 FPGA build helpers (Vivado)
# ==========================================================================

SHELL           := /bin/bash

VIVADO          ?= vivado
VIVADO_FLAGS    ?= -mode batch -notrace

PROJ_NAME       ?= jv32_ku5p
PROJ_DIR        ?= fpga/build
TOP_MODULE      ?= jv32_fpga_top
FPGA_PART       ?= xcku5p-ffvb676-2-i
JV32_CLK_HZ     ?= 50000000
FLASH_PART      ?= mt25qu256-spi-x1_x2_x4
USE_CJTAG       ?= 1

VIVADO_SCRIPT   := scripts/create_project.tcl

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
	@echo "  PROJ_DIR=<repo-relative-dir>         (default: fpga/build)"
	@echo "  TOP_MODULE=<rtl-top>                (default: jv32_fpga_top)"
	@echo "  FPGA_PART=<part-number>             (default: xcku5pffvb676-2)"
	@echo "  FLASH_PART=<flash-part>             (default: mt25qu256-spi-x1_x2_x4)"
	@echo "  USE_CJTAG=0|1                       (default: 1 = cJTAG / 2-pin)"

project:
	PROJ_NAME=$(PROJ_NAME) \
	PROJ_DIR=$(PROJ_DIR) \
	TOP_MODULE=$(TOP_MODULE) \
	FPGA_PART=$(FPGA_PART) \
	JV32_CLK_HZ=$(JV32_CLK_HZ) \
	USE_CJTAG=$(USE_CJTAG) \
	RUN_SYNTH=0 RUN_IMPL=0 \
	$(VIVADO) $(VIVADO_FLAGS) -source $(VIVADO_SCRIPT)

synth:
	PROJ_NAME=$(PROJ_NAME) \
	PROJ_DIR=$(PROJ_DIR) \
	TOP_MODULE=$(TOP_MODULE) \
	FPGA_PART=$(FPGA_PART) \
	JV32_CLK_HZ=$(JV32_CLK_HZ) \
	USE_CJTAG=$(USE_CJTAG) \
	RUN_SYNTH=1 RUN_IMPL=0 \
	$(VIVADO) $(VIVADO_FLAGS) -source $(VIVADO_SCRIPT)

impl:
	PROJ_NAME=$(PROJ_NAME) \
	PROJ_DIR=$(PROJ_DIR) \
	TOP_MODULE=$(TOP_MODULE) \
	FPGA_PART=$(FPGA_PART) \
	JV32_CLK_HZ=$(JV32_CLK_HZ) \
	FLASH_PART=$(FLASH_PART) \
	USE_CJTAG=$(USE_CJTAG) \
	RUN_SYNTH=1 RUN_IMPL=1 \
	$(VIVADO) $(VIVADO_FLAGS) -source $(VIVADO_SCRIPT)

clean:
	@echo "Removing Vivado build outputs from $(PROJ_DIR)"
	@rm -rf ../$(PROJ_DIR) .Xil *.log *.jou
