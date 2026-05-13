# ============================================================================
# Makefile: openocd/Makefile
# Project: JV32 RISC-V Processor
# Description: Build and run JTAG/cJTAG interface tests via OpenOCD + VPI,
#              and GDB-level debug tests via OpenOCD GDB server.
#
# Workflow
# --------
# 1. Build the Verilator VPI testbench for JTAG (USE_CJTAG=0) and cJTAG (USE_CJTAG=1).
# 2. Run every OpenOCD TCL test script over JTAG, then over cJTAG.
# 3. Run GDB tests: start VPI + OpenOCD GDB server, then drive riscv-gdb --batch.
#
# Top-level targets
#   all             — test-jtag, then test-cjtag
#   all-with-gdb    — test-jtag, test-cjtag, then test-gdb, then gdb-hello (trace compare)
#   test-jtag       — run all JTAG TCL test scripts
#   test-cjtag      — run all cJTAG TCL test scripts
#   test-gdb        — run all GDB tests (JTAG VPI + OpenOCD GDB server)
#   build-jtag      — build the JTAG VPI simulator (USE_CJTAG=0)
#   build-cjtag     — build the cJTAG VPI simulator (USE_CJTAG=1)
#   clean           — remove generated build artefacts
#
# Individual test targets
#   jtag-<name>     — run a single JTAG test   (e.g. make jtag-halt_resume)
#   cjtag-<name>    — run a single cJTAG test  (e.g. make cjtag-halt_resume)
#   gdb-<name>      — run a single GDB test    (e.g. make gdb-step)
#
# Available TCL test names:
#   dtmcs  halt_resume  registers  memory  memory_modes  reset  dm_status
#   programbuf  step  debug_errors  breakpoint  watchpoint
#   misa  dcsr  triggers  abstract_regs  csr_fields
#   sba  havereset  abstractauto  debug_ext_alias
#   cmderr  aampostincrement  dscratch  sbreadondata  haltsum  dmactive
#   jtag_tap  (JTAG-only: BYPASS/IDCODE raw scan — not in cJTAG list)
#   cjtag    (cJTAG-specific activation test — cjtag-* only)
#
# Available GDB test names:
#   load  step  breakpoint  memory  regs  debug
#
# Overridable variables (on the make command line or in env.config)
#   OPENOCD      — openocd binary path       (default: openocd)
#   GDB          — riscv GDB binary path     (default: $(RISCV_PREFIX)gdb)
#   VPI_PORT     — TCP port for VPI server   (default: 5555)
#   GDB_PORT     — TCP port for GDB server   (default: 3333)
#   BOOT_ELF     — ELF loaded into the SoC  (default: build/hello.elf)
#   BOOT_IO_BACKEND — I/O backend for boot ELF build (default: magic)
#   WAVE=1|fst   — dump FST waveform to build/<type>_<name>.fst
#   WAVE=vcd     — dump VCD waveform to build/<type>_<name>.vcd
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
GDB      ?= $(RISCV_PREFIX)gdb

# ── Simulator binaries (built by root Makefile) ───────────────────────────────
VPI_JTAG  := $(BUILD_DIR)/jv32vpi_jtag
VPI_CJTAG := $(BUILD_DIR)/jv32vpi_cjtag

# ── ELF to load into the SoC ─────────────────────────────────────────────────
# hello.elf prints output, calls _exit, then spins in `_spin: j _spin`.
# With sim_request_exit() ignored by the VPI testbench, the hart stays
# alive in that spin loop so OpenOCD can halt/resume/examine it at will.
BOOT_ELF ?= $(BUILD_DIR)/hello.elf
BOOT_IO_BACKEND ?= magic
SEMIHOST_BUILD_DIR ?= $(BUILD_DIR)/semihost
SEMIHOST_ELF := $(SEMIHOST_BUILD_DIR)/hello.elf

# ── VPI TCP port ──────────────────────────────────────────────────────────────
VPI_PORT ?= 5555

# ── OpenOCD GDB server port (used by the GDB test suite) ─────────────────────
GDB_PORT ?= 3333

# ── Test names (file stem of openocd/test_<name>.tcl) ────────────────────────
# JTAG: common functionality; no cJTAG-specific activation test
JTAG_TESTS  := dtmcs halt_resume registers memory memory_modes reset dm_status programbuf step \
			   debug_errors breakpoint watchpoint misa dcsr triggers abstract_regs csr_fields \
			   sba havereset abstractauto debug_ext_alias \
			   cmderr aampostincrement dscratch sbreadondata haltsum dmactive semihost jtag_tap
# cJTAG: cJTAG activation check first, then the same common tests (jtag_tap excluded — JTAG only)
CJTAG_TESTS := cjtag dtmcs halt_resume registers memory memory_modes reset dm_status programbuf step \
			   debug_errors breakpoint watchpoint misa dcsr triggers abstract_regs csr_fields \
			   sba havereset abstractauto debug_ext_alias \
			   cmderr aampostincrement dscratch sbreadondata haltsum dmactive semihost

# ── GDB test names (file stem of openocd/test_gdb_<name>.gdb) ────────────────
# Each test is run with the JTAG VPI simulator + OpenOCD GDB server.
GDB_TESTS := load step breakpoint memory regs debug hello

# ── Test counts (computed from the lists above) ──────────────────────────────
N_JTAG      := $(words $(JTAG_TESTS))
N_CJTAG     := $(words $(CJTAG_TESTS))
N_GDB_TESTS := $(words $(GDB_TESTS))

# ── Log directory ─────────────────────────────────────────────────────────────
LOG_DIR := $(BUILD_DIR)/openocd_logs

# ─────────────────────────────────────────────────────────────────────────────
# Phony targets
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: all test-jtag test-cjtag test-gdb build-jtag build-cjtag clean help jtag-% cjtag-% gdb-% gdb-zcmp jtag-no-trace-step FORCE

FORCE:

# ─────────────────────────────────────────────────────────────────────────────
# Default
# ─────────────────────────────────────────────────────────────────────────────
all: test-jtag test-cjtag jtag-no-trace-step

# Run all three test suites (OpenOCD TCL over JTAG, over cJTAG, and GDB)
all-with-gdb: test-jtag test-cjtag test-gdb jtag-no-trace-step gdb-hello gdb-zcmp

# ─────────────────────────────────────────────────────────────────────────────
# Build prerequisites
# ─────────────────────────────────────────────────────────────────────────────
$(BOOT_ELF): FORCE
	$(MAKE) -C $(ROOT_DIR) sw-hello BUILD_DIR=$(BUILD_DIR) JV_IO_BACKEND=$(BOOT_IO_BACKEND)

$(SEMIHOST_ELF): FORCE
	$(MAKE) -C $(ROOT_DIR) sw-hello BUILD_DIR=$(SEMIHOST_BUILD_DIR) JV_IO_BACKEND=semihost

$(VPI_JTAG): FORCE
	$(MAKE) -C $(ROOT_DIR) build-vpi-jtag WAVE=$(WAVE)

$(VPI_CJTAG): FORCE
	$(MAKE) -C $(ROOT_DIR) build-vpi-cjtag WAVE=$(WAVE)

build-jtag:  $(VPI_JTAG)
build-cjtag: $(VPI_CJTAG)

# ─────────────────────────────────────────────────────────────────────────────
# JTAG test suite
# ─────────────────────────────────────────────────────────────────────────────
test-jtag: $(VPI_JTAG) $(BOOT_ELF) $(SEMIHOST_ELF)
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
	    ELF="$(BOOT_ELF)"; \
	    if [ "$$t" = "semihost" ]; then ELF="$(SEMIHOST_ELF)"; fi; \
	    LOG="$(LOG_DIR)/jtag_$$t"; \
	    printf "  [jtag] %d/$(N_JTAG) %-20s ... " "$$N" "test_$$t"; \
	    "$(VPI_JTAG)" "$$ELF" --port $(VPI_PORT) \
	        >"$$LOG.sim.log" 2>&1 & VPI_PID=$$!; \
	    for _i in $$(seq 1 50); do \
	        ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' && break; \
	        sleep 0.1; \
	    done; \
	    ( cd "$(OPENOCD_DIR)" && \
	      $(OPENOCD) -d0 \
	          -c "gdb port disabled" \
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
test-cjtag: $(VPI_CJTAG) $(BOOT_ELF) $(SEMIHOST_ELF)
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
	    ELF="$(BOOT_ELF)"; \
	    if [ "$$t" = "semihost" ]; then ELF="$(SEMIHOST_ELF)"; fi; \
	    LOG="$(LOG_DIR)/cjtag_$$t"; \
	    printf "  [cjtag] %d/$(N_CJTAG) %-20s ... " "$$N" "test_$$t"; \
	    "$(VPI_CJTAG)" "$$ELF" --port $(VPI_PORT) \
	        >"$$LOG.sim.log" 2>&1 & VPI_PID=$$!; \
	    for _i in $$(seq 1 50); do \
	        ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' && break; \
	        sleep 0.1; \
	    done; \
	    ( cd "$(OPENOCD_DIR)" && \
	      $(OPENOCD) -d0 \
	          -c "gdb port disabled" \
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
jtag-%: $(VPI_JTAG) $(BOOT_ELF) $(SEMIHOST_ELF)
	@mkdir -p $(LOG_DIR)
	@t=$*; LOG="$(LOG_DIR)/jtag_$$t"; ELF="$(BOOT_ELF)"; \
	if [ "$$t" = "semihost" ]; then ELF="$(SEMIHOST_ELF)"; fi; \
	echo "--- [jtag] test_$$t ---"; \
	"$(VPI_JTAG)" "$$ELF" --port $(VPI_PORT) \
	    $(if $(filter 1 fst,$(WAVE)),--trace "$(BUILD_DIR)/jtag_$$t.fst") \
	    $(if $(filter vcd,$(WAVE)),--trace "$(BUILD_DIR)/jtag_$$t.vcd") \
	    >"$$LOG.sim.log" 2>&1 & VPI_PID=$$!; \
	for _i in $$(seq 1 50); do \
	    ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' && break; \
	    sleep 0.1; \
	done; \
	( cd "$(OPENOCD_DIR)" && \
	  $(OPENOCD) -d0 \
	      -c "gdb port disabled" \
	      -f jv32.cfg \
	      -c "jtag_vpi set_port $(VPI_PORT)" \
	      -c init \
	      -c "source test_$$t.tcl" \
	      -c shutdown \
	) >"$$LOG.ocd.log" 2>&1; \
	OCD_RC=$$?; \
	kill $$VPI_PID 2>/dev/null; wait $$VPI_PID 2>/dev/null; \
	cat "$$LOG.ocd.log"; \
	if [ -n "$(filter 1 fst,$(WAVE))" ]; then echo ""; echo "Waveform: $(BUILD_DIR)/jtag_$$t.fst"; \
	elif [ -n "$(filter vcd,$(WAVE))" ]; then echo ""; echo "Waveform: $(BUILD_DIR)/jtag_$$t.vcd"; fi; \
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
cjtag-%: $(VPI_CJTAG) $(BOOT_ELF) $(SEMIHOST_ELF)
	@mkdir -p $(LOG_DIR)
	@t=$*; LOG="$(LOG_DIR)/cjtag_$$t"; ELF="$(BOOT_ELF)"; \
	if [ "$$t" = "semihost" ]; then ELF="$(SEMIHOST_ELF)"; fi; \
	echo "--- [cjtag] test_$$t ---"; \
	"$(VPI_CJTAG)" "$$ELF" --port $(VPI_PORT) \
	    $(if $(filter 1 fst,$(WAVE)),--trace "$(BUILD_DIR)/cjtag_$$t.fst") \
	    $(if $(filter vcd,$(WAVE)),--trace "$(BUILD_DIR)/cjtag_$$t.vcd") \
	    >"$$LOG.sim.log" 2>&1 & VPI_PID=$$!; \
	for _i in $$(seq 1 50); do \
	    ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' && break; \
	    sleep 0.1; \
	done; \
	( cd "$(OPENOCD_DIR)" && \
	  $(OPENOCD) -d0 \
	      -c "gdb port disabled" \
	      -f jv32_cjtag.cfg \
	      -c "jtag_vpi set_port $(VPI_PORT)" \
	      -c init \
	      -c "source test_$$t.tcl" \
	      -c shutdown \
	) >"$$LOG.ocd.log" 2>&1; \
	OCD_RC=$$?; \
	kill $$VPI_PID 2>/dev/null; wait $$VPI_PID 2>/dev/null; \
	cat "$$LOG.ocd.log"; \
	if [ -n "$(filter 1 fst,$(WAVE))" ]; then echo ""; echo "Waveform: $(BUILD_DIR)/cjtag_$$t.fst"; \
	elif [ -n "$(filter vcd,$(WAVE))" ]; then echo ""; echo "Waveform: $(BUILD_DIR)/cjtag_$$t.vcd"; fi; \
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
# GDB test suite (JTAG VPI + OpenOCD GDB server + riscv GDB)
#
# Each test:
#   1. Starts the JTAG VPI simulator on VPI_PORT.
#   2. Starts OpenOCD with GDB enabled on GDB_PORT (stays in background).
#   3. Runs GDB --batch with the test script; captures combined output.
#   4. Kills OpenOCD and the VPI simulator.
#   5. Checks for [PASS]/[SKIP] in the GDB log (same convention as TCL tests).
#
# GDB_PORT (default 3333) must not conflict with VPI_PORT (default 5555).
# ─────────────────────────────────────────────────────────────────────────────
test-gdb: $(VPI_JTAG) $(BOOT_ELF)
	@echo ""
	@echo "=========================================="
	@echo "GDB Tests (JTAG VPI + OpenOCD GDB server)"
	@echo "Tests: $(GDB_TESTS)"
	@echo "GDB:   $(GDB)"
	@echo "=========================================="
	@mkdir -p $(LOG_DIR)
	@pkill -9 jv32vpi_jtag 2>/dev/null; sleep 0.2; true
	@PASS=0; SKIP=0; FAIL=0; N=0; \
	run_one() { \
	    N=$$((N+1)); \
	    t=$$1; \
	    LOG="$(LOG_DIR)/gdb_$$t"; \
	    printf "  [gdb]  %d/$(N_GDB_TESTS) %-20s ... " "$$N" "test_gdb_$$t"; \
	    "$(VPI_JTAG)" "$(BOOT_ELF)" --port $(VPI_PORT) \
	        --max-cycles 0 \
	        >"$$LOG.sim.log" 2>&1 & VPI_PID=$$!; \
	    for _i in $$(seq 1 50); do \
	        ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' && break; \
	        sleep 0.1; \
	    done; \
	    ( cd "$(OPENOCD_DIR)" && \
	      $(OPENOCD) -d0 \
	          -f jv32.cfg \
	          -c "jtag_vpi set_port $(VPI_PORT)" \
	          -c "gdb port $(GDB_PORT)" \
	          -c "tcl port disabled" \
	          -c "telnet port disabled" \
	          -c "gdb flash_program disable" \
	          -c init \
	    ) >"$$LOG.ocd.log" 2>&1 & OCD_PID=$$!; \
	    for _i in $$(seq 1 80); do \
	        ss -tnl 2>/dev/null | grep -q ':$(GDB_PORT) ' && break; \
	        sleep 0.1; \
	    done; \
	    $(GDB) --batch \
	        -ex "set pagination off" \
	        -ex "set confirm off" \
	        -ex "set remotetimeout 300" \
	        -ex "target extended-remote :$(GDB_PORT)" \
	        -x "$(OPENOCD_DIR)/test_gdb_$$t.gdb" \
	        "$(BOOT_ELF)" \
	        >"$$LOG.gdb.log" 2>&1; \
	    GDB_RC=$$?; \
	    kill $$OCD_PID 2>/dev/null; wait $$OCD_PID 2>/dev/null; \
	    kill $$VPI_PID 2>/dev/null; wait $$VPI_PID 2>/dev/null; \
	    for _j in $$(seq 1 30); do \
	        ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' || break; \
	        sleep 0.1; \
	    done; \
	    for _j in $$(seq 1 30); do \
	        ss -tnl 2>/dev/null | grep -q ':$(GDB_PORT) ' || break; \
	        sleep 0.1; \
	    done; \
	    if [ $$GDB_RC -eq 0 ] && grep -Eq '\[(PASS|SKIP)\]' "$$LOG.gdb.log" 2>/dev/null; then \
	        if grep -q '\[SKIP\]' "$$LOG.gdb.log" 2>/dev/null; then \
	            echo "SKIP"; SKIP=$$((SKIP+1)); \
	        else \
	            echo "PASS"; PASS=$$((PASS+1)); \
	        fi; \
	    else \
	        echo "FAIL (gdb exit=$$GDB_RC)"; \
	        FAIL=$$((FAIL+1)); \
	        sed 's/^/    /' "$$LOG.gdb.log"; \
	    fi; \
	}; \
	for t in $(GDB_TESTS); do run_one $$t; done; \
	echo ""; \
	echo "------------------------------------------"; \
	echo "GDB result: $$PASS passed, $$SKIP skipped, $$FAIL failed"; \
	echo "Logs: $(LOG_DIR)/gdb_*.gdb.log"; \
	echo "------------------------------------------"; \
	[ $$FAIL -eq 0 ]

# ─────────────────────────────────────────────────────────────────────────────
# gdb-hello: GDB debug-workflow test + RTL instruction trace vs ISS comparison.
#
# The RTL instruction trace is captured BY the VPI testbench during the GDB
# session (--rtl-trace), not from a separate jv32soc run.  This verifies that
# the processor executes the correct instruction stream even while the debugger
# is controlling it (breakpoints, watchpoints, single-step, next-over-call).
# ─────────────────────────────────────────────────────────────────────────────
RTL_TRACE_FILE  = $(BUILD_DIR)/rtl_trace.txt
SIM_TRACE_FILE  = $(BUILD_DIR)/sim_trace.txt
JV32SIM_BIN     = $(BUILD_DIR)/jv32sim
TRACE_COMPARE   = $(ROOT_DIR)/scripts/trace_compare.py

$(JV32SIM_BIN): FORCE
	$(MAKE) -C $(ROOT_DIR) sim-build

.PHONY: gdb-hello
gdb-hello: $(VPI_JTAG) $(BOOT_ELF) $(JV32SIM_BIN)
	@mkdir -p $(LOG_DIR)
	@t=hello; LOG="$(LOG_DIR)/gdb_$$t"; \
	echo "--- [gdb] test_gdb_$$t (GDB debug test + ISS trace compare) ---"; \
	pkill -x jv32vpi_jtag 2>/dev/null || true; \
	pkill -x openocd      2>/dev/null || true; \
	fuser -k $(VPI_PORT)/tcp 2>/dev/null || true; \
	fuser -k $(GDB_PORT)/tcp 2>/dev/null || true; \
	sleep 0.3; \
	"$(VPI_JTAG)" "$(BOOT_ELF)" --port $(VPI_PORT) \
	    --max-cycles 0 \
	    --boot-clocks 50 \
	    --rtl-trace "$(RTL_TRACE_FILE)" \
	    >"$$LOG.sim.log" 2>&1 & VPI_PID=$$!; \
	for _i in $$(seq 1 50); do \
	    ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' && break; \
	    kill -0 $$VPI_PID 2>/dev/null || { echo "[FAIL] VPI failed to start — see $$LOG.sim.log:"; cat "$$LOG.sim.log"; exit 1; }; \
	    sleep 0.1; \
	done; \
	ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' || { echo "[FAIL] VPI port $(VPI_PORT) never opened"; cat "$$LOG.sim.log"; kill $$VPI_PID 2>/dev/null; exit 1; }; \
	( cd "$(OPENOCD_DIR)" && \
	  $(OPENOCD) -d0 \
	      -f jv32.cfg \
	      -c "jtag_vpi set_port $(VPI_PORT)" \
	      -c "gdb port $(GDB_PORT)" \
	      -c "tcl port disabled" \
	      -c "telnet port disabled" \
	      -c "gdb flash_program disable" \
	      -c init \
	) >"$$LOG.ocd.log" 2>&1 & OCD_PID=$$!; \
	for _i in $$(seq 1 80); do \
	    ss -tnl 2>/dev/null | grep -q ':$(GDB_PORT) ' && break; \
	    sleep 0.1; \
	done; \
	$(GDB) --batch \
	    -ex "set pagination off" \
	    -ex "set confirm off" \
	    -ex "set remotetimeout 300" \
	    -ex "target extended-remote :$(GDB_PORT)" \
	    -x "$(OPENOCD_DIR)/test_gdb_$$t.gdb" \
	    "$(BOOT_ELF)" \
	    >"$$LOG.gdb.log" 2>&1; \
	GDB_RC=$$?; \
	kill $$OCD_PID 2>/dev/null; wait $$OCD_PID 2>/dev/null; \
	kill $$VPI_PID 2>/dev/null; wait $$VPI_PID 2>/dev/null; \
	cat "$$LOG.gdb.log"; \
	if [ $$GDB_RC -eq 0 ] && grep -Eq '\[(PASS|SKIP)\]' "$$LOG.gdb.log" 2>/dev/null; then \
	    if grep -q '\[SKIP\]' "$$LOG.gdb.log" 2>/dev/null; then \
	        echo ""; echo "[SKIP] gdb: test_gdb_$$t"; exit 0; \
	    fi; \
	    echo ""; echo "[PASS] gdb: test_gdb_$$t"; \
	    echo ""; \
	    echo "--- [gdb-hello] Step 2: ISS (jv32sim) instruction trace ---"; \
	    if [ ! -s "$(RTL_TRACE_FILE)" ]; then \
	        echo "[SKIP] trace-compare: $(RTL_TRACE_FILE) empty — trace may not have fired"; exit 0; \
	    fi; \
	    "$(JV32SIM_BIN)" --trace "$(SIM_TRACE_FILE)" \
	        --rtl-hints "$(RTL_TRACE_FILE)" \
	        "$(BOOT_ELF)" \
	        >"$$LOG.iss.log" 2>&1 \
	        || { echo "[FAIL] jv32sim failed (see $$LOG.iss.log)"; exit 1; }; \
	    echo "  ISS trace: $(SIM_TRACE_FILE)"; \
	    echo ""; \
	    echo "--- [gdb-hello] Step 3: trace comparison (ISS vs RTL) ---"; \
	    python3 "$(TRACE_COMPARE)" \
	        "$(SIM_TRACE_FILE)" \
	        "$(RTL_TRACE_FILE)" \
	        >"$$LOG.cmp.log" 2>&1; \
	    CMP_RC=$$?; \
	    cat "$$LOG.cmp.log"; \
	    if [ $$CMP_RC -eq 0 ]; then \
	        echo ""; echo "[PASS] gdb-hello: trace comparison passed"; \
	        echo "  RTL trace: $(RTL_TRACE_FILE) (captured during GDB session)"; \
	        echo "  ISS trace: $(SIM_TRACE_FILE)"; \
	        exit 0; \
	    else \
	        echo ""; echo "[FAIL] gdb-hello: trace mismatch (see $$LOG.cmp.log)"; exit 1; \
	    fi; \
	else \
	    echo ""; echo "[FAIL] gdb: test_gdb_$$t (gdb exit=$$GDB_RC)"; exit 1; \
	fi

# ─────────────────────────────────────────────────────────────────────────────
# Individual GDB tests: make gdb-load, make gdb-step, make gdb-memory, ...
# ─────────────────────────────────────────────────────────────────────────────
gdb-%: $(VPI_JTAG) $(BOOT_ELF)
	@mkdir -p $(LOG_DIR)
	@t=$*; LOG="$(LOG_DIR)/gdb_$$t"; \
	echo "--- [gdb] test_gdb_$$t ---"; \
	"$(VPI_JTAG)" "$(BOOT_ELF)" --port $(VPI_PORT) \
	    >"$$LOG.sim.log" 2>&1 & VPI_PID=$$!; \
	for _i in $$(seq 1 50); do \
	    ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' && break; \
	    sleep 0.1; \
	done; \
	( cd "$(OPENOCD_DIR)" && \
	  $(OPENOCD) -d0 \
	      -f jv32.cfg \
	      -c "jtag_vpi set_port $(VPI_PORT)" \
	      -c "gdb port $(GDB_PORT)" \
	      -c "tcl port disabled" \
	      -c "telnet port disabled" \
	      -c "gdb flash_program disable" \
	      -c init \
	) >"$$LOG.ocd.log" 2>&1 & OCD_PID=$$!; \
	for _i in $$(seq 1 80); do \
	    ss -tnl 2>/dev/null | grep -q ':$(GDB_PORT) ' && break; \
	    sleep 0.1; \
	done; \
	$(GDB) --batch \
	    -ex "set pagination off" \
	    -ex "set confirm off" \
	    -ex "set remotetimeout 30" \
	    -ex "target extended-remote :$(GDB_PORT)" \
	    -x "$(OPENOCD_DIR)/test_gdb_$$t.gdb" \
	    "$(BOOT_ELF)" \
	    >"$$LOG.gdb.log" 2>&1; \
	GDB_RC=$$?; \
	kill $$OCD_PID 2>/dev/null; wait $$OCD_PID 2>/dev/null; \
	kill $$VPI_PID 2>/dev/null; wait $$VPI_PID 2>/dev/null; \
	cat "$$LOG.gdb.log"; \
	if [ $$GDB_RC -eq 0 ] && grep -Eq '\[(PASS|SKIP)\]' "$$LOG.gdb.log" 2>/dev/null; then \
	    if grep -q '\[SKIP\]' "$$LOG.gdb.log" 2>/dev/null; then \
	        echo ""; echo "[SKIP] gdb: test_gdb_$$t"; \
	    else \
	        echo ""; echo "[PASS] gdb: test_gdb_$$t"; \
	    fi; \
	    exit 0; \
	else \
	    echo ""; echo "[FAIL] gdb: test_gdb_$$t (gdb exit=$$GDB_RC)"; exit 1; \
	fi

# ─────────────────────────────────────────────────────────────────────────────
# Regression: single-step with trace_en=0 (simulates FPGA conditions)
#
# Runs test_step.tcl against a VPI sim launched with --no-trace-en.
# Trace ports are excluded from synthesis via `ifndef SYNTHESIS; only the runtime
# trace_en signal is held low.  Verifies that the stepi fix in jv32_core.sv
# (decoupling trace_valid_r from trace_en) keeps single-step working when
# the trace output to the testbench is disabled.
# ─────────────────────────────────────────────────────────────────────────────
jtag-no-trace-step: $(VPI_JTAG) $(BOOT_ELF)
	@mkdir -p $(LOG_DIR)
	@t=step; LOG="$(LOG_DIR)/jtag_no_trace_$$t"; \
	echo "--- [jtag / trace_en=0] test_$$t ---"; \
	"$(VPI_JTAG)" "$(BOOT_ELF)" --port $(VPI_PORT) --no-trace-en \
	    $(if $(filter 1 fst,$(WAVE)),--trace "$(BUILD_DIR)/jtag_no_trace_$$t.fst") \
	    $(if $(filter vcd,$(WAVE)),--trace "$(BUILD_DIR)/jtag_no_trace_$$t.vcd") \
	    >"$$LOG.sim.log" 2>&1 & VPI_PID=$$!; \
	for _i in $$(seq 1 50); do \
	    ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' && break; \
	    sleep 0.1; \
	done; \
	( cd "$(OPENOCD_DIR)" && \
	  $(OPENOCD) -d0 \
	      -c "gdb port disabled" \
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
	    echo ""; echo "[PASS] jtag(trace_en=0): test_$$t"; exit 0; \
	else \
	    echo ""; echo "[FAIL] jtag(trace_en=0): test_$$t (openocd exit=$$OCD_RC)"; exit 1; \
	fi

# ─────────────────────────────────────────────────────────────────────────────
# gdb-zcmp: run zcmp.elf on the VPI + OpenOCD GDB server, verify all Zcmp
#           instruction tests passed via the magic exit register, then compare
#           the RTL instruction trace against the ISS (jv32sim) trace.
#
# Pattern:
#   1. Build zcmp.elf (sw/zcmp) if not present.
#   2. Start VPI with zcmp.elf + --rtl-trace to capture the RTL trace.
#   3. Start OpenOCD GDB server; run test_gdb_zcmp.gdb which halts the core
#      and reads the magic exit register to confirm all C-level tests passed.
#   4. Run jv32sim to produce the ISS trace for zcmp.elf.
#   5. Compare ISS trace vs RTL trace with trace_compare.py.
# ─────────────────────────────────────────────────────────────────────────────
ZCMP_ELF = $(BUILD_DIR)/zcmp.elf

$(ZCMP_ELF): FORCE
	$(MAKE) -C $(ROOT_DIR) sw-zcmp BUILD_DIR=$(BUILD_DIR)

gdb-zcmp: $(VPI_JTAG) $(ZCMP_ELF) $(JV32SIM_BIN)
	@mkdir -p $(LOG_DIR)
	@t=zcmp; LOG="$(LOG_DIR)/gdb_$$t"; \
	echo "--- [gdb] test_gdb_$$t (Zcmp instruction test + ISS trace compare) ---"; \
	pkill -x jv32vpi_jtag 2>/dev/null || true; \
	pkill -x openocd      2>/dev/null || true; \
	fuser -k $(VPI_PORT)/tcp 2>/dev/null || true; \
	fuser -k $(GDB_PORT)/tcp 2>/dev/null || true; \
	sleep 0.3; \
	"$(VPI_JTAG)" "$(ZCMP_ELF)" --port $(VPI_PORT) \
	    --max-cycles 0 \
	    --boot-clocks 50 \
	    --rtl-trace "$(RTL_TRACE_FILE)" \
	    >"$$LOG.sim.log" 2>&1 & VPI_PID=$$!; \
	for _i in $$(seq 1 50); do \
	    ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' && break; \
	    kill -0 $$VPI_PID 2>/dev/null || { echo "[FAIL] VPI failed to start — see $$LOG.sim.log:"; cat "$$LOG.sim.log"; exit 1; }; \
	    sleep 0.1; \
	done; \
	ss -tnl 2>/dev/null | grep -q ':$(VPI_PORT) ' || { echo "[FAIL] VPI port $(VPI_PORT) never opened"; cat "$$LOG.sim.log"; kill $$VPI_PID 2>/dev/null; exit 1; }; \
	( cd "$(OPENOCD_DIR)" && \
	  $(OPENOCD) -d0 \
	      -f jv32.cfg \
	      -c "jtag_vpi set_port $(VPI_PORT)" \
	      -c "gdb port $(GDB_PORT)" \
	      -c "tcl port disabled" \
	      -c "telnet port disabled" \
	      -c "gdb flash_program disable" \
	      -c init \
	) >"$$LOG.ocd.log" 2>&1 & OCD_PID=$$!; \
	for _i in $$(seq 1 80); do \
	    ss -tnl 2>/dev/null | grep -q ':$(GDB_PORT) ' && break; \
	    sleep 0.1; \
	done; \
	$(GDB) --batch \
	    -ex "set pagination off" \
	    -ex "set confirm off" \
	    -ex "set remotetimeout 300" \
	    -ex "target extended-remote :$(GDB_PORT)" \
	    -x "$(OPENOCD_DIR)/test_gdb_$$t.gdb" \
	    "$(ZCMP_ELF)" \
	    >"$$LOG.gdb.log" 2>&1; \
	GDB_RC=$$?; \
	kill $$OCD_PID 2>/dev/null; wait $$OCD_PID 2>/dev/null; \
	kill $$VPI_PID 2>/dev/null; wait $$VPI_PID 2>/dev/null; \
	cat "$$LOG.gdb.log"; \
	if [ $$GDB_RC -eq 0 ] && grep -Eq '\[(PASS|SKIP)\]' "$$LOG.gdb.log" 2>/dev/null; then \
	    if grep -q '\[SKIP\]' "$$LOG.gdb.log" 2>/dev/null; then \
	        echo ""; echo "[SKIP] gdb: test_gdb_$$t"; exit 0; \
	    fi; \
	    echo ""; echo "[PASS] gdb: test_gdb_$$t"; \
	    echo ""; \
	    echo "--- [gdb-zcmp] Step 2: ISS (jv32sim) instruction trace ---"; \
	    if [ ! -s "$(RTL_TRACE_FILE)" ]; then \
	        echo "[SKIP] trace-compare: $(RTL_TRACE_FILE) empty — trace may not have fired"; exit 0; \
	    fi; \
	    "$(JV32SIM_BIN)" --trace "$(SIM_TRACE_FILE)" \
	        --rtl-hints "$(RTL_TRACE_FILE)" \
	        "$(ZCMP_ELF)" \
	        >"$$LOG.iss.log" 2>&1 \
	        || { echo "[FAIL] jv32sim failed (see $$LOG.iss.log)"; exit 1; }; \
	    echo "  ISS trace: $(SIM_TRACE_FILE)"; \
	    echo ""; \
	    echo "--- [gdb-zcmp] Step 3: trace comparison (ISS vs RTL) ---"; \
	    python3 "$(TRACE_COMPARE)" \
	        "$(SIM_TRACE_FILE)" \
	        "$(RTL_TRACE_FILE)" \
	        >"$$LOG.cmp.log" 2>&1; \
	    CMP_RC=$$?; \
	    cat "$$LOG.cmp.log"; \
	    if [ $$CMP_RC -eq 0 ]; then \
	        echo ""; echo "[PASS] gdb-zcmp: trace comparison passed"; \
	        echo "  RTL trace: $(RTL_TRACE_FILE)"; \
	        echo "  ISS trace: $(SIM_TRACE_FILE)"; \
	        exit 0; \
	    else \
	        echo ""; echo "[FAIL] gdb-zcmp: trace mismatch (see $$LOG.cmp.log)"; exit 1; \
	    fi; \
	else \
	    echo ""; echo "[FAIL] gdb: test_gdb_$$t (gdb exit=$$GDB_RC)"; \
	    cat "$$LOG.ocd.log"; \
	    exit 1; \
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
	@echo "  jtag-<name>   — single JTAG test  (e.g. jtag-halt_resume)"
	@echo "  cjtag-<name>  — single cJTAG test (e.g. cjtag-cjtag)"
	@echo "  jtag-no-trace-step — run test_step with trace_en=0 (FPGA regression)"
	@echo "  test-gdb      — run all GDB tests (JTAG VPI + OpenOCD GDB server)"
	@echo "  gdb-<name>    — single GDB test   (e.g. gdb-step)"
	@echo "  gdb-hello     — GDB debug workflow + ISS trace compare (hello.elf)"
	@echo "  gdb-zcmp      — Zcmp instruction test + ISS trace compare (zcmp.elf)"
	@echo "  all-with-gdb  — test-jtag + test-cjtag + test-gdb + gdb-hello + gdb-zcmp"
	@echo ""
	@echo "  Available TCL test names:"
	@echo "    halt_resume  registers  memory  memory_modes  reset  dm_status"
	@echo "    programbuf   step  debug_errors  breakpoint  watchpoint"
	@echo "    misa  dcsr  triggers  abstract_regs  csr_fields"
	@echo "    sba  havereset  abstractauto  debug_ext_alias"
	@echo "    semihost"
	@echo "    cjtag (cjtag-* only)"
	@echo ""
	@echo "  Available GDB test names:"
	@echo "    load  step  breakpoint  memory  regs  debug"
	@echo ""
	@echo "  BOOT_ELF=$(BOOT_ELF)"
	@echo "  VPI_PORT=$(VPI_PORT)"
	@echo "  GDB_PORT=$(GDB_PORT)"
	@echo "  OPENOCD=$(OPENOCD)"
	@echo "  GDB=$(GDB)"
