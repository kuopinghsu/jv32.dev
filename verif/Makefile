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
ACT_REPO     := https://github.com/riscv/riscv-arch-test
ACT_BRANCH   := act4
ACT_DIR      := $(VERIF_DIR)riscv-arch-test
ACT_VENV     := $(ACT_DIR)/.venv
ACT_SENTINEL := $(ACT_VENV)/.act-setup-done

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

# ── Toolchain ─────────────────────────────────────────────────────────────────
RISCV_PREFIX ?= riscv-none-elf-
# SPIKE is set via env.config in repo root; fall back to bare 'spike' if not exported
SPIKE        ?= spike

# ── uv (Python env manager) ──────────────────────────────────────────────────
UV := $(shell command -v uv 2>/dev/null || echo $(HOME)/.local/bin/uv)

# ============================================================================
.PHONY: all arch-test-setup arch-test-run arch-test-clean help

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
	@# ── 2. Clone / update riscv-arch-test ────────────────────────────────
	@if git -C $(JV32_ROOT) config --file .gitmodules --get-regexp '^submodule\.verif/riscv-arch-test\.url$$' >/dev/null 2>&1; then \
	    echo "[arch-test] Initializing/updating existing submodule $(ACT_DIR)..."; \
	    git -C $(JV32_ROOT) submodule sync -- verif/riscv-arch-test; \
	    git -C $(JV32_ROOT) submodule update --init --remote verif/riscv-arch-test; \
	else \
	    echo "[arch-test] Cloning $(ACT_REPO) (branch $(ACT_BRANCH))..."; \
	    git -C $(JV32_ROOT) submodule add -b $(ACT_BRANCH) $(ACT_REPO) verif/riscv-arch-test; \
	    git -C $(JV32_ROOT) submodule update --init verif/riscv-arch-test; \
	fi
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
#   InterruptsSm    — interrupt timing tests; JV32 CLIC quirks not yet modelled
#   ExceptionsZalrsc/Zaamo — LR/SC and AMO exception tests; not yet validated
#   ExceptionsZc    — uses rv32ifdc march (F/D unimplemented); Sail segfaults on this config
#   PMPSm/PMPZca/PMPmisaligned — PMP tests; JV32 has no PMP
#   Sv/Svade/...    — virtual memory tests; JV32 has no MMU
# ============================================================================
arch-test-run: $(ACT_SENTINEL) $(ARCH_TEST_CONFIG) $(ARCH_TEST_EXTENSIONS_FILE)
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
	echo "[arch-test] Phase 1/3: building RTL simulator"; \
	echo "=========================================="; \
	$(MAKE) -C $(JV32_ROOT) --no-print-directory IRAM_SIZE=$(ARCH_TEST_IRAM_SIZE) ZB_EN=$(ZB_EN) RAS_EN=$(RAS_EN) build-rtl; \
	echo "=========================================="; \
	echo "[arch-test] Phase 2/3: generating self-checking ELFs"; \
	echo "=========================================="; \
	IN_UDB_CONTAINER=1 $(MAKE) -C $(ACT_DIR) \
	    CONFIG_FILES=$(ARCH_TEST_CONFIG) \
	    WORKDIR=$(WORKDIR) \
            EXCLUDE_EXTENSIONS=Sm,S,InterruptsSm,ExceptionsZalrsc,ExceptionsZaamo,ExceptionsZc,PMPSm,PMPZca,PMPmisaligned,Sv,Svade,Svadu,SvaduPMP,SvPMP,SvZicbo,SvPMPZicbo \
	    $(if $(EXTENSIONS),EXTENSIONS=$(EXTENSIONS),) \
	    --jobs $(ARCH_TEST_JOBS); \
	elf_count=$$(find "$(WORKDIR)/jv32-rv32imac/elfs" -name '*.elf' | wc -l | tr -d '[:space:]'); \
	echo "[arch-test] Phase 3/3: running $$elf_count ELF tests on JV32 RTL"; \
	echo "[arch-test] Logs: $(WORKDIR)/jv32-rv32imac/logs"; \
	echo "[arch-test] Summary: $(WORKDIR)/jv32-rv32imac/summary.log"; \
	cd $(ACT_DIR) && $(ACT_VENV)/bin/python run_tests.py \
	    "$(JV32_ROOT)/build/jv32soc" \
	    "$(WORKDIR)/jv32-rv32imac/elfs"

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
