# ============================================================================
# File: verif/Makefile
# Project: JV32 RISC-V Processor
# Description: Verification targets — RISC-V Architectural Certification Tests
#              (ACT4) and related infrastructure.
#
# All paths are relative to the verif/ directory (this file's location).
# Invoke from the repo root via:
#   make -C verif arch-test-setup
#   make -C verif arch-test-%
# Or use the convenience wrappers in the root Makefile:
#   make arch-test-setup
#   make arch-test-run
# ============================================================================

# ── Directories ──────────────────────────────────────────────────────────────
VERIF_DIR    := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
JV32_ROOT    := $(abspath $(VERIF_DIR)/..)

# Load root env.config so SPIKE and RISCV_PREFIX are set when invoked standalone
-include $(JV32_ROOT)/env.config

# ── ACT4 source ──────────────────────────────────────────────────────────────
# riscv-arch-test is a git submodule pinned to a specific commit.
# arch-test-setup checks it out at that pinned commit (no --remote).
# To update: cd verif/riscv-arch-test && git checkout <new-commit>
#            cd ../.. && git add verif/riscv-arch-test && git commit
ACT_DIR      := $(VERIF_DIR)riscv-arch-test
ACT_VENV         := $(ACT_DIR)/.venv
ACT_SENTINEL     := $(ACT_VENV)/.act-setup-done

# ── JV32 DUT config ──────────────────────────────────────────────────────────
DUT_CONFIG   := $(VERIF_DIR)config/jv32-rv32imac
WORKDIR      ?= $(JV32_ROOT)/build/arch-test-work
ARCH_TEST_JOBS ?= $(if $(JOBS),$(JOBS),$(shell command -v nproc >/dev/null 2>&1 && nproc || sysctl -n hw.logicalcpu 2>/dev/null || echo 1))
ARCH_TEST_CONFIG := $(WORKDIR)/test_config.generated.yaml
ARCH_TEST_REF_WRAPPER := $(WORKDIR)/sail_riscv_sim.wrapper.sh
ARCH_TEST_CONFIG_DIR := $(WORKDIR)/jv32-rv32imac
ARCH_TEST_EXTENSIONS_FILE := $(ARCH_TEST_CONFIG_DIR)/extensions.txt

# ARCH_TEST_IRAM_SIZE: I-jal-00 places its .text segment at 0x80004000 and the
# section is 0x1c080 bytes long, ending at 0x80020080 — 128 bytes past the
# default 128 KB IRAM boundary (0x80020000).  All other tests fit in 128 KB.
# Override to 256 KB (262144) only for the arch-test RTL simulator build so
# the default IRAM_SIZE in Makefile.cfg and the SV files stays at 128 KB.
ARCH_TEST_IRAM_SIZE := 262144

# ── Extra hand-written arch-tests (tracked in parent repo, not in submodule) ─
# Place test .S files here mirroring the tests/ layout: rv32i/<EXT>/<name>.S
# arch-test-run overlays them into the submodule's tests/ before running ACT.
ARCH_TEST_EXTRA := $(VERIF_DIR)arch-test-extra

# ── Zcmp ACT config (jv32sim reference path) ─────────────────────────────────
# Sail v0.11 does not support Zcmp; use jv32sim for Zcmp ELF generation.
ZCMP_DUT_CONFIG       := $(VERIF_DIR)config/jv32-rv32imac-zcmp
ARCH_TEST_ZCMP_CONFIG := $(WORKDIR)/test_config.zcmp.generated.yaml

# ── Toolchain ─────────────────────────────────────────────────────────────────
RISCV_PREFIX ?= riscv-none-elf-
# SPIKE is set via env.config in repo root; fall back to bare 'spike' if not exported
SPIKE        ?= spike

# ── uv (Python env manager) ──────────────────────────────────────────────────
UV := $(shell command -v uv 2>/dev/null || echo $(HOME)/.local/bin/uv)

# ============================================================================
.PHONY: all arch-test-setup arch-test-run arch-test-zcmp arch-test-clean help

all: help

# Create a local wrapper that delegates to sail_riscv_sim.
$(ARCH_TEST_REF_WRAPPER): $(VERIF_DIR)sail_spike_wrapper.sh.in $(VERIF_DIR)Makefile
	@mkdir -p "$(WORKDIR)"
	@sail_bin="$$(command -v sail_riscv_sim 2>/dev/null || echo sail_riscv_sim)"; \
	cp "$(JV32_ROOT)/verif/sail_spike_wrapper.sh.in" "$(ARCH_TEST_REF_WRAPPER)"; \
	sed -i.bak "s|__SAIL_BIN__|$$sail_bin|g" "$(ARCH_TEST_REF_WRAPPER)"; \
	rm -f "$(ARCH_TEST_REF_WRAPPER).bak"; \
	chmod +x "$(ARCH_TEST_REF_WRAPPER)"

# Generate a toolchain-adjusted ACT config for this run.
$(ARCH_TEST_CONFIG): $(DUT_CONFIG)/test_config.yaml $(ARCH_TEST_REF_WRAPPER) $(VERIF_DIR)Makefile
	@mkdir -p "$(WORKDIR)"
	@sed -e 's|^[[:space:]]*compiler_exe:.*|compiler_exe: $(RISCV_PREFIX)gcc|' \
	     -e 's|^[[:space:]]*objdump_exe:.*|objdump_exe: $(RISCV_PREFIX)objdump|' \
	     -e 's|^[[:space:]]*ref_model_exe:.*|ref_model_exe: $(ARCH_TEST_REF_WRAPPER)|' \
	     -e 's|^[[:space:]]*udb_config:.*|udb_config: $(DUT_CONFIG)/jv32-rv32imac.yaml|' \
	     -e 's|^[[:space:]]*linker_script:.*|linker_script: $(DUT_CONFIG)/link.ld|' \
	     -e 's|^[[:space:]]*dut_include_dir:.*|dut_include_dir: $(DUT_CONFIG)|' \
	     "$(DUT_CONFIG)/test_config.yaml" > "$@"

# Generate Zcmp-specific ACT config that uses jv32sim as reference model.
$(ARCH_TEST_ZCMP_CONFIG): $(ZCMP_DUT_CONFIG)/test_config.yaml $(VERIF_DIR)Makefile
	@mkdir -p "$(WORKDIR)"
	@sed -e 's|^[[:space:]]*compiler_exe:.*|compiler_exe: $(RISCV_PREFIX)gcc|' \
	     -e 's|^[[:space:]]*objdump_exe:.*|objdump_exe: $(RISCV_PREFIX)objdump|' \
	     -e 's|^[[:space:]]*ref_model_exe:.*|ref_model_exe: $(JV32_ROOT)/build/jv32sim|' \
	     -e 's|^[[:space:]]*udb_config:.*|udb_config: $(DUT_CONFIG)/jv32-rv32imac.yaml|' \
	     -e 's|^[[:space:]]*linker_script:.*|linker_script: $(DUT_CONFIG)/link.ld|' \
	     -e 's|^[[:space:]]*dut_include_dir:.*|dut_include_dir: $(DUT_CONFIG)|' \
	     "$(ZCMP_DUT_CONFIG)/test_config.yaml" > "$@"

# Pre-generate implemented extension list directly from DUT UDB YAML.
# If this file is present and up-to-date, ACT skips invoking external UDB tooling
# (which may require container or newer Ruby runtime on host).
$(ARCH_TEST_EXTENSIONS_FILE): $(DUT_CONFIG)/jv32-rv32imac.yaml $(VERIF_DIR)Makefile
	@mkdir -p "$(ARCH_TEST_CONFIG_DIR)"
	@sed -nE 's|.*name:[[:space:]]*([^,}[:space:]]+).*|\1|p' "$(DUT_CONFIG)/jv32-rv32imac.yaml" > "$@"
	@ext_count=$$(wc -l < "$@" | tr -d '[:space:]'); \
	  echo "[arch-test] Prepared $$ext_count implemented extensions in $(ARCH_TEST_EXTENSIONS_FILE)"

# ============================================================================
# arch-test-setup: clone riscv-arch-test (act4 branch) and install Python venv
# ============================================================================
$(ACT_SENTINEL):
	@# ── 1. Ensure uv is available ────────────────────────────────────────
	@if ! command -v $(UV) >/dev/null 2>&1; then \
	    echo "[arch-test] Installing uv..."; \
	    curl -LsSf https://astral.sh/uv/install.sh | sh; \
	fi
	@# ── 2. Checkout riscv-arch-test at the pinned commit ─────────────────
	@# We use 'submodule update --init' WITHOUT --remote so the submodule is
	@# always checked out at the commit recorded in the parent repo index.
	@# To advance to a newer arch-test release:
	@#   cd verif/riscv-arch-test && git fetch && git checkout <new-commit>
	@#   cd ../.. && git add verif/riscv-arch-test && git commit
	@echo "[arch-test] Checking out pinned riscv-arch-test submodule..."
	@git -C $(JV32_ROOT) submodule sync -- verif/riscv-arch-test
	@git -C $(JV32_ROOT) submodule update --init verif/riscv-arch-test
	@# Remove stale untracked generated files left by any previous run.
	@# testgen  → tests/           covergroupgen → coverpoints/unpriv/ + external/
	@# These directories are inside the submodule working tree but not tracked by it.
	@git -C $(ACT_DIR) clean -fdq -- tests/ coverpoints/unpriv/ external/
	@# ── 3. Bootstrap Python venv via uv ──────────────────────────────────
	@echo "[arch-test] Installing Python environment (uv sync)..."
	@cd $(ACT_DIR) && $(UV) sync --quiet
	@touch $(ACT_SENTINEL)
	@echo "[arch-test] Setup complete. venv: $(ACT_VENV)"

arch-test-setup: $(ACT_SENTINEL)

# ============================================================================
# arch-test-run: generate self-checking ELFs and run them on the JV32 RTL sim
#
# Requires arch-test-setup to have been run first.
# Requires DUT config files in $(DUT_CONFIG)/ (test_config.yaml, link.ld, etc).
#
# Variables:
#   EXTENSIONS        — comma-separated list (default: all in UDB config)
#   JOBS              — parallel build jobs (default: nproc)
#   WORKDIR           — build/output dir (default: build/arch-test-work)
#
# EXCLUDE_EXTENSIONS rationale:
#   Sm              — machine-mode CSR tests; excluded pending Sail CSR model alignment
#   S               — supervisor mode; JV32 is M-mode only
#   ExceptionsSm    — supervisor-mode exception tests; JV32 is M-mode only
#   InterruptsSm    — interrupt timing tests; JV32 CLIC quirks not yet modelled
#   ExceptionsZalrsc/Zaamo — LR/SC and AMO exception tests; not yet validated
#   ExceptionsZc    — uses rv32ifdc march (F/D unimplemented); Sail segfaults on this config
#   PMPSm/PMPZca/PMPmisaligned — PMP tests; JV32 has no PMP
#   Sv/Svade/...    — virtual memory tests; JV32 has no MMU
#   Zcmp            — Sail v0.11 does not implement Zcmp; generated in a
#                     second pass below with jv32sim as reference model
# ============================================================================
arch-test-run: $(ACT_SENTINEL) $(ARCH_TEST_CONFIG) $(ARCH_TEST_ZCMP_CONFIG) $(ARCH_TEST_EXTENSIONS_FILE)
	@set -e; \
	stty_state="$$(stty -g 2>/dev/null || true)"; \
	restore_tty() { \
	  if [ -n "$$stty_state" ]; then \
	    stty "$$stty_state" 2>/dev/null || stty sane 2>/dev/null || true; \
	  else \
	    stty sane 2>/dev/null || true; \
	  fi; \
	}; \
	trap 'restore_tty' EXIT INT TERM; \
	mkdir -p "$(WORKDIR)"; \
	echo "=========================================="; \
	echo "[arch-test] Work directory: $(WORKDIR)"; \
	echo "[arch-test] Phase 1/4: building RTL simulator"; \
	echo "=========================================="; \
	$(MAKE) -C $(JV32_ROOT) --no-print-directory IRAM_SIZE=$(ARCH_TEST_IRAM_SIZE) RV32B_EN=$(RV32B_EN) RAS_EN=$(RAS_EN) build-rtl; \
	echo "=========================================="; \
	echo "[arch-test] Phase 2/4: generating self-checking ELFs (non-Zcmp via Sail)"; \
	echo "=========================================="; \
	if [ -d "$(ARCH_TEST_EXTRA)" ]; then \
	  echo "[arch-test] Overlaying local tests from verif/arch-test-extra/..."; \
	  cp -r "$(ARCH_TEST_EXTRA)/." "$(ACT_DIR)/tests/"; \
	fi; \
	IN_UDB_CONTAINER=1 $(MAKE) -C $(ACT_DIR) \
	    CONFIG_FILES=$(ARCH_TEST_CONFIG) \
	    WORKDIR=$(WORKDIR) \
	    EXCLUDE_EXTENSIONS=Sm,S,ExceptionsSm,InterruptsSm,ExceptionsZalrsc,ExceptionsZaamo,ExceptionsZc,PMPSm,PMPZca,PMPmisaligned,Sv,Svade,Svadu,SvaduPMP,SvPMP,SvZicbo,SvPMPZicbo,Zcmp \
	    $(if $(EXTENSIONS),EXTENSIONS=$(EXTENSIONS),) \
	    --jobs $(ARCH_TEST_JOBS); \
	echo "=========================================="; \
	echo "[arch-test] Phase 3/4: generating Zcmp ELFs (jv32sim reference)"; \
	echo "=========================================="; \
	$(MAKE) -C $(JV32_ROOT) --no-print-directory sim-build; \
	PATH="$(JV32_ROOT)/build:$$PATH" IN_UDB_CONTAINER=1 $(MAKE) -C $(ACT_DIR) \
	    CONFIG_FILES=$(ARCH_TEST_ZCMP_CONFIG) \
	    WORKDIR=$(WORKDIR) \
	    EXTENSIONS=Zcmp \
	    --jobs $(ARCH_TEST_JOBS); \
	elf_count=$$(find "$(WORKDIR)/jv32-rv32imac/elfs" -name '*.elf' | wc -l | tr -d '[:space:]'); \
	echo "[arch-test] Phase 4/4: running $$elf_count ELF tests on JV32 RTL"; \
	echo "[arch-test] Logs: $(WORKDIR)/jv32-rv32imac/logs"; \
	echo "[arch-test] Summary: $(WORKDIR)/jv32-rv32imac/summary.log"; \
	cd $(ACT_DIR) && $(ACT_VENV)/bin/python run_tests.py \
	    "$(JV32_ROOT)/build/jv32soc" \
	    "$(WORKDIR)/jv32-rv32imac/elfs"

# ============================================================================
# arch-test-zcmp: run Zcmp extension tests using jv32sim as reference model
#
# Sail v0.11 does not implement Zcmp, so jv32sim is used as the reference model
# for this extension only.  jv32sim accepts the same --test-signature and
# --signature-granularity flags as Sail (ref_model_type: sail).
#
# This target:
#   1. Builds jv32sim (reference model) and jv32soc (RTL sim, arch-test build)
#   2. Overlays verif/arch-test-extra/rv32i/Zcmp/ tests into the ACT tests dir
#   3. Runs ACT for Zcmp only (EXTENSIONS=Zcmp) with jv32sim as reference
#   4. Runs ALL ELFs in the elfs/ dir on jv32soc (combines Zcmp + prior tests)
#      and writes a unified build/arch-test-work/jv32-rv32imac/summary.log
#
# arch-test-run already includes this pass; use this target to rerun Zcmp only.
# ============================================================================
arch-test-zcmp: $(ACT_SENTINEL) $(ARCH_TEST_ZCMP_CONFIG) $(ARCH_TEST_EXTENSIONS_FILE)
	@set -e; \
	stty_state="$$(stty -g 2>/dev/null || true)"; \
	restore_tty() { \
	  if [ -n "$$stty_state" ]; then \
	    stty "$$stty_state" 2>/dev/null || stty sane 2>/dev/null || true; \
	  else \
	    stty sane 2>/dev/null || true; \
	  fi; \
	}; \
	trap 'restore_tty' EXIT INT TERM; \
	mkdir -p "$(WORKDIR)"; \
	echo "=========================================="; \
	echo "[arch-test-zcmp] Building jv32sim (Zcmp reference model)"; \
	echo "=========================================="; \
	$(MAKE) -C $(JV32_ROOT) --no-print-directory sim-build; \
	echo "=========================================="; \
	echo "[arch-test-zcmp] Building RTL simulator (jv32soc)"; \
	echo "=========================================="; \
	$(MAKE) -C $(JV32_ROOT) --no-print-directory IRAM_SIZE=$(ARCH_TEST_IRAM_SIZE) RV32B_EN=$(RV32B_EN) RAS_EN=$(RAS_EN) build-rtl; \
	echo "=========================================="; \
	echo "[arch-test-zcmp] Generating Zcmp self-checking ELFs"; \
	echo "=========================================="; \
	if [ -d "$(ARCH_TEST_EXTRA)" ]; then \
	  echo "[arch-test-zcmp] Overlaying Zcmp tests from verif/arch-test-extra/..."; \
	  cp -r "$(ARCH_TEST_EXTRA)/." "$(ACT_DIR)/tests/"; \
	fi; \
	PATH="$(JV32_ROOT)/build:$$PATH" IN_UDB_CONTAINER=1 $(MAKE) -C $(ACT_DIR) \
	    CONFIG_FILES=$(ARCH_TEST_ZCMP_CONFIG) \
	    WORKDIR=$(WORKDIR) \
	    EXTENSIONS=Zcmp \
	    --jobs $(ARCH_TEST_JOBS); \
	elf_count=$$(find "$(WORKDIR)/jv32-rv32imac/elfs" -name '*.elf' | wc -l | tr -d '[:space:]'); \
	echo "[arch-test-zcmp] Running $$elf_count ELF tests on JV32 RTL (all extensions)"; \
	echo "[arch-test-zcmp] Summary: $(WORKDIR)/jv32-rv32imac/summary.log"; \
	cd $(ACT_DIR) && $(ACT_VENV)/bin/python run_tests.py \
	    "$(JV32_ROOT)/build/jv32soc" \
	    "$(WORKDIR)/jv32-rv32imac/elfs"; \
	echo "[arch-test-zcmp] Done. Zcmp tests now included in summary.log"

# ============================================================================
# arch-test-%: pass-through any other target to the ACT4 Makefile
# ============================================================================
arch-test-%: $(ACT_SENTINEL) $(ARCH_TEST_CONFIG) $(ARCH_TEST_EXTENSIONS_FILE)
	@$(MAKE) -C $(ACT_DIR) \
	    CONFIG_FILES=$(ARCH_TEST_CONFIG) \
	    WORKDIR=$(WORKDIR) \
	    $*

# ============================================================================
# arch-test-clean: remove generated artifacts (keep cloned repo and venv)
# ============================================================================
arch-test-clean:
	@rm -rf $(WORKDIR)
	@echo "[arch-test] Work directory removed: $(WORKDIR)"

# ============================================================================
# help
# ============================================================================
help:
	@echo "verif/Makefile — JV32 Architectural Certification Test targets"
	@echo ""
	@echo "Usage: make -C verif <target>"
	@echo "  (or from repo root: make arch-test-setup / make arch-test-run)"
	@echo ""
	@echo "Targets:"
	@echo "  arch-test-setup    Clone riscv-arch-test (act4) & install Python venv via uv"
	@echo "  arch-test-run      Generate self-checking ELFs and run on JV32 RTL sim"
	@echo "  arch-test-<tgt>    Forward <tgt> to the ACT4 Makefile"
	@echo "  arch-test-clean    Remove work/ directory"
	@echo ""
	@echo "Variables:"
	@echo "  DUT_CONFIG=<dir>   Path to DUT config dir (default: verif/config/jv32-rv32imac)"
	@echo "  EXTENSIONS=<list>  Comma-separated extension list (default: all)"
	@echo "  WORKDIR=<dir>      Build/output dir (default: build/arch-test-work)"
	@echo "  JOBS=<n>           Parallel build jobs (default: nproc)"
