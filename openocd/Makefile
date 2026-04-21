# ============================================================================
# Makefile: openocd/Makefile
# Project: JV32 RISC-V Processor
# Description: Build and run JTAG/cJTAG interface tests via OpenOCD + VPI
#
# Workflow
# --------
# 1. Build the Verilator VPI testbench for JTAG (USE_CJTAG=0) and cJTAG (USE_CJTAG=1).
# 2. Run every test script under openocd/ first over JTAG, then over cJTAG.
#
# Top-level targets
#   all          — test-jtag, then test-cjtag
#   test-jtag    — run all JTAG test scripts
#   test-cjtag   — run all cJTAG test scripts
#   build-jtag   — build the JTAG VPI simulator (USE_CJTAG=0)
#   build-cjtag  — build the cJTAG VPI simulator (USE_CJTAG=1)
#   clean        — remove generated build artefacts
#
# Individual test targets
#   jtag-<name>  — run a single JTAG test  (e.g. make jtag-halt_resume)
#   cjtag-<name> — run a single cJTAG test (e.g. make cjtag-halt_resume)
#
# Available test names:
#   dtmcs  halt_resume  registers  memory  memory_modes  reset  dm_status
#   programbuf  step  debug_errors  breakpoint  watchpoint
#   misa  dcsr  triggers  abstract_regs  csr_fields
#   cjtag        (cJTAG-specific activation test, cjtag-* only)
#
# Overridable variables (on the make command line or in env.config)
#   OPENOCD      — openocd binary path (default: openocd)
#   VPI_PORT     — TCP port for the VPI server (default: 3333)
#   BOOT_ELF     — ELF loaded into the SoC (default: build/hello.elf)
# ============================================================================

SHELL := /bin/bash

# ── Project paths ─────────────────────────────────────────────────────────────
ROOT_DIR    := $(abspath ..)
BUILD_DIR   := $(ROOT_DIR)/build
OPENOCD_DIR := $(abspath .)

# ── Inherit tool paths from env.config ────────────────────────────────────────
-include $(ROOT_DIR)/env.config

# ── Tools ─────────────────────────────────────────────────────────────────────
OPENOCD ?= openocd

# ── Simulator binaries (built by root Makefile) ───────────────────────────────
VPI_JTAG  := $(BUILD_DIR)/jv32vpi_jtag
VPI_CJTAG := $(BUILD_DIR)/jv32vpi_cjtag

# ── ELF to load into the SoC ─────────────────────────────────────────────────
# hello.elf prints output, calls _exit, then spins in `_spin: j _spin`.
# With sim_request_exit() ignored by the VPI testbench, the hart stays
# alive in that spin loop so OpenOCD can halt/resume/examine it at will.
BOOT_ELF ?= $(BUILD_DIR)/hello.elf

# ── VPI TCP port ──────────────────────────────────────────────────────────────
VPI_PORT ?= 5555

# ── Test names (file stem of openocd/test_<name>.tcl) ────────────────────────
# JTAG: common functionality; no cJTAG-specific activation test
JTAG_TESTS  := dtmcs halt_resume registers memory memory_modes reset dm_status programbuf step \
			   debug_errors breakpoint watchpoint misa dcsr triggers abstract_regs csr_fields \
			   sba havereset abstractauto debug_ext_alias
# cJTAG: cJTAG activation check first, then the same common tests
CJTAG_TESTS := cjtag dtmcs halt_resume registers memory memory_modes reset dm_status programbuf step \
			   debug_errors breakpoint watchpoint misa dcsr triggers abstract_regs csr_fields \
			   sba havereset abstractauto debug_ext_alias

# ── Test counts (computed from the lists above) ──────────────────────────────
N_JTAG  := $(words $(JTAG_TESTS))
N_CJTAG := $(words $(CJTAG_TESTS))

# ── Log directory ─────────────────────────────────────────────────────────────
LOG_DIR := $(BUILD_DIR)/openocd_logs

# ─────────────────────────────────────────────────────────────────────────────
# Phony targets
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: all test-jtag test-cjtag build-jtag build-cjtag clean help jtag-% cjtag-%

# ─────────────────────────────────────────────────────────────────────────────
# Default
# ─────────────────────────────────────────────────────────────────────────────
all: test-jtag test-cjtag

# ─────────────────────────────────────────────────────────────────────────────
# Build prerequisites
# ─────────────────────────────────────────────────────────────────────────────
$(BOOT_ELF):
	$(MAKE) -C $(ROOT_DIR) sw-hello BUILD_DIR=$(BUILD_DIR)

$(VPI_JTAG):
	$(MAKE) -C $(ROOT_DIR) build-vpi-jtag

$(VPI_CJTAG):
	$(MAKE) -C $(ROOT_DIR) build-vpi-cjtag

build-jtag:  $(VPI_JTAG)
build-cjtag: $(VPI_CJTAG)

# ─────────────────────────────────────────────────────────────────────────────
# JTAG test suite
# ─────────────────────────────────────────────────────────────────────────────
test-jtag: $(VPI_JTAG) $(BOOT_ELF)
	@echo ""
	@echo "=========================================="
	@echo "JTAG Interface Tests (USE_CJTAG=0)"
	@echo "Tests: $(JTAG_TESTS)"
	@echo "=========================================="
	@mkdir -p $(LOG_DIR)
	@pkill -9 jv32vpi_jtag 2>/dev/null; pkill -9 jv32vpi_cjtag 2>/dev/null; sleep 0.2; true
	@PASS=0; SKIP=0; FAIL=0; N=0; \
	run_one() { \
	    N=$$((N+1)); \
	    t=$$1; \
	    LOG="$(LOG_DIR)/jtag_$$t"; \
	    printf "  [jtag] %d/$(N_JTAG) %-20s ... " "$$N" "test_$$t"; \
	    "$(VPI_JTAG)" "$(BOOT_ELF)" --port $(VPI_PORT) \
	        >"$$LOG.sim.log" 2>&1 & VPI_PID=$$!; \
	    for _i in $$(seq 1 50); do \
	        ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' && break; \
	        sleep 0.1; \
	    done; \
	    ( cd "$(OPENOCD_DIR)" && \
	      $(OPENOCD) -d0 \
	          -c "gdb_port disabled" \
	          -f jv32.cfg \
	          -c "jtag_vpi set_port $(VPI_PORT)" \
	          -c init \
	          -c "source test_$$t.tcl" \
	          -c shutdown \
	    ) >"$$LOG.ocd.log" 2>&1; \
	    OCD_RC=$$?; \
	    kill $$VPI_PID 2>/dev/null; wait $$VPI_PID 2>/dev/null; \
	    for _j in $$(seq 1 30); do \
	        ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' || break; \
	        sleep 0.1; \
	    done; \
	    if [ $$OCD_RC -eq 0 ] && grep -Eq '\[(PASS|SKIP)\]' "$$LOG.ocd.log" 2>/dev/null; then \
	        if grep -q '\[SKIP\]' "$$LOG.ocd.log" 2>/dev/null; then \
	            echo "SKIP"; SKIP=$$((SKIP+1)); \
	        else \
	            echo "PASS"; PASS=$$((PASS+1)); \
	        fi; \
	    else \
	        echo "FAIL (openocd exit=$$OCD_RC)"; \
	        FAIL=$$((FAIL+1)); \
	        sed 's/^/    /' "$$LOG.ocd.log"; \
	    fi; \
	}; \
	for t in $(JTAG_TESTS); do run_one $$t; done; \
	echo ""; \
	echo "------------------------------------------"; \
	echo "JTAG result: $$PASS passed, $$SKIP skipped, $$FAIL failed"; \
	echo "Logs: $(LOG_DIR)/jtag_*.ocd.log"; \
	echo "------------------------------------------"; \
	[ $$FAIL -eq 0 ]

# ─────────────────────────────────────────────────────────────────────────────
# cJTAG test suite
# ─────────────────────────────────────────────────────────────────────────────
test-cjtag: $(VPI_CJTAG) $(BOOT_ELF)
	@echo ""
	@echo "=========================================="
	@echo "cJTAG Interface Tests (USE_CJTAG=1)"
	@echo "Tests: $(CJTAG_TESTS)"
	@echo "=========================================="
	@mkdir -p $(LOG_DIR)
	@pkill -9 jv32vpi_jtag 2>/dev/null; pkill -9 jv32vpi_cjtag 2>/dev/null; sleep 0.2; true
	@PASS=0; SKIP=0; FAIL=0; N=0; \
	run_one() { \
	    N=$$((N+1)); \
	    t=$$1; \
	    LOG="$(LOG_DIR)/cjtag_$$t"; \
	    printf "  [cjtag] %d/$(N_CJTAG) %-20s ... " "$$N" "test_$$t"; \
	    "$(VPI_CJTAG)" "$(BOOT_ELF)" --port $(VPI_PORT) \
	        >"$$LOG.sim.log" 2>&1 & VPI_PID=$$!; \
	    for _i in $$(seq 1 50); do \
	        ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' && break; \
	        sleep 0.1; \
	    done; \
	    ( cd "$(OPENOCD_DIR)" && \
	      $(OPENOCD) -d0 \
	          -c "gdb_port disabled" \
	          -f jv32_cjtag.cfg \
	          -c "jtag_vpi set_port $(VPI_PORT)" \
	          -c init \
	          -c "source test_$$t.tcl" \
	          -c shutdown \
	    ) >"$$LOG.ocd.log" 2>&1; \
	    OCD_RC=$$?; \
	    kill $$VPI_PID 2>/dev/null; wait $$VPI_PID 2>/dev/null; \
	    for _j in $$(seq 1 30); do \
	        ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' || break; \
	        sleep 0.1; \
	    done; \
	    if [ $$OCD_RC -eq 0 ] && grep -Eq '\[(PASS|SKIP)\]' "$$LOG.ocd.log" 2>/dev/null; then \
	        if grep -q '\[SKIP\]' "$$LOG.ocd.log" 2>/dev/null; then \
	            echo "SKIP"; SKIP=$$((SKIP+1)); \
	        else \
	            echo "PASS"; PASS=$$((PASS+1)); \
	        fi; \
	    else \
	        echo "FAIL (openocd exit=$$OCD_RC)"; \
	        FAIL=$$((FAIL+1)); \
	        sed 's/^/    /' "$$LOG.ocd.log"; \
	    fi; \
	}; \
	for t in $(CJTAG_TESTS); do run_one $$t; done; \
	echo ""; \
	echo "------------------------------------------"; \
	echo "cJTAG result: $$PASS passed, $$SKIP skipped, $$FAIL failed"; \
	echo "Logs: $(LOG_DIR)/cjtag_*.ocd.log"; \
	echo "------------------------------------------"; \
	[ $$FAIL -eq 0 ]

# ─────────────────────────────────────────────────────────────────────────────
# Individual JTAG tests: make jtag-halt_resume, make jtag-registers, ...
# ─────────────────────────────────────────────────────────────────────────────
jtag-%: $(VPI_JTAG) $(BOOT_ELF)
	@mkdir -p $(LOG_DIR)
	@t=$*; LOG="$(LOG_DIR)/jtag_$$t"; \
	echo "--- [jtag] test_$$t ---"; \
	"$(VPI_JTAG)" "$(BOOT_ELF)" --port $(VPI_PORT) \
	    >"$$LOG.sim.log" 2>&1 & VPI_PID=$$!; \
	for _i in $$(seq 1 50); do \
	    ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' && break; \
	    sleep 0.1; \
	done; \
	( cd "$(OPENOCD_DIR)" && \
	  $(OPENOCD) -d0 \
	      -c "gdb_port disabled" \
	      -f jv32.cfg \
	      -c "jtag_vpi set_port $(VPI_PORT)" \
	      -c init \
	      -c "source test_$$t.tcl" \
	      -c shutdown \
	) >"$$LOG.ocd.log" 2>&1; \
	OCD_RC=$$?; \
	kill $$VPI_PID 2>/dev/null; wait $$VPI_PID 2>/dev/null; \
	cat "$$LOG.ocd.log"; \
	if [ $$OCD_RC -eq 0 ] && grep -Eq '\[(PASS|SKIP)\]' "$$LOG.ocd.log" 2>/dev/null; then \
	    if grep -q '\[SKIP\]' "$$LOG.ocd.log" 2>/dev/null; then \
	        echo ""; echo "[SKIP] jtag: test_$$t"; \
	    else \
	        echo ""; echo "[PASS] jtag: test_$$t"; \
	    fi; \
	    exit 0; \
	else \
	    echo ""; echo "[FAIL] jtag: test_$$t (openocd exit=$$OCD_RC)"; exit 1; \
	fi

# ─────────────────────────────────────────────────────────────────────────────
# Individual cJTAG tests: make cjtag-cjtag, make cjtag-halt_resume, ...
# ─────────────────────────────────────────────────────────────────────────────
cjtag-%: $(VPI_CJTAG) $(BOOT_ELF)
	@mkdir -p $(LOG_DIR)
	@t=$*; LOG="$(LOG_DIR)/cjtag_$$t"; \
	echo "--- [cjtag] test_$$t ---"; \
	"$(VPI_CJTAG)" "$(BOOT_ELF)" --port $(VPI_PORT) \
	    >"$$LOG.sim.log" 2>&1 & VPI_PID=$$!; \
	for _i in $$(seq 1 50); do \
	    ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' && break; \
	    sleep 0.1; \
	done; \
	( cd "$(OPENOCD_DIR)" && \
	  $(OPENOCD) -d0 \
	      -c "gdb_port disabled" \
	      -f jv32_cjtag.cfg \
	      -c "jtag_vpi set_port $(VPI_PORT)" \
	      -c init \
	      -c "source test_$$t.tcl" \
	      -c shutdown \
	) >"$$LOG.ocd.log" 2>&1; \
	OCD_RC=$$?; \
	kill $$VPI_PID 2>/dev/null; wait $$VPI_PID 2>/dev/null; \
	cat "$$LOG.ocd.log"; \
	if [ $$OCD_RC -eq 0 ] && grep -Eq '\[(PASS|SKIP)\]' "$$LOG.ocd.log" 2>/dev/null; then \
	    if grep -q '\[SKIP\]' "$$LOG.ocd.log" 2>/dev/null; then \
	        echo ""; echo "[SKIP] cjtag: test_$$t"; \
	    else \
	        echo ""; echo "[PASS] cjtag: test_$$t"; \
	    fi; \
	    exit 0; \
	else \
	    echo ""; echo "[FAIL] cjtag: test_$$t (openocd exit=$$OCD_RC)"; exit 1; \
	fi

# ─────────────────────────────────────────────────────────────────────────────
# Clean
# ─────────────────────────────────────────────────────────────────────────────
clean:
	rm -rf $(LOG_DIR)
	rm -f  $(VPI_JTAG) $(VPI_CJTAG)
	rm -rf $(BUILD_DIR)/objdir_vpi_jtag $(BUILD_DIR)/objdir_vpi_cjtag

# ─────────────────────────────────────────────────────────────────────────────
# Help
# ─────────────────────────────────────────────────────────────────────────────
help:
	@echo "JV32 OpenOCD JTAG/cJTAG test targets:"
	@echo "  all           — test-jtag then test-cjtag"
	@echo "  test-jtag     — run all JTAG tests"
	@echo "  test-cjtag    — run all cJTAG tests"
	@echo "  build-jtag    — build VPI sim with USE_CJTAG=0"
	@echo "  build-cjtag   — build VPI sim with USE_CJTAG=1"
	@echo "  jtag-<name>   — single JTAG test (e.g. jtag-halt_resume)"
	@echo "  cjtag-<name>  — single cJTAG test (e.g. cjtag-cjtag)"
	@echo ""
	@echo "  Available test names:"
	@echo "    halt_resume  registers  memory  memory_modes  reset  dm_status"
	@echo "    programbuf   step  debug_errors  breakpoint"
	@echo "    watchpoint"
	@echo "    cjtag (cjtag-* only)"
	@echo ""
	@echo "  BOOT_ELF=$(BOOT_ELF)"
	@echo "  VPI_PORT=$(VPI_PORT)"
	@echo "  OPENOCD=$(OPENOCD)"
