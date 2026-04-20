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

# ── ACT4 source ──────────────────────────────────────────────────────────────
ACT_REPO     := https://github.com/riscv/riscv-arch-test
ACT_BRANCH   := act4
ACT_DIR      := $(VERIF_DIR)riscv-arch-test
ACT_VENV     := $(ACT_DIR)/.venv
ACT_SENTINEL := $(ACT_VENV)/.act-setup-done

# ── JV32 DUT config ──────────────────────────────────────────────────────────
DUT_CONFIG   := $(VERIF_DIR)config/jv32-rv32imac
WORKDIR      ?= $(JV32_ROOT)/build/arch-test-work
ARCH_TEST_JOBS ?= $(if $(JOBS),$(JOBS),$(shell nproc))

# ── Toolchain ─────────────────────────────────────────────────────────────────
RISCV_PREFIX ?= riscv-none-elf-
SPIKE        ?= spike

# ── uv (Python env manager) ──────────────────────────────────────────────────
UV := $(shell command -v uv 2>/dev/null || echo $(HOME)/.local/bin/uv)

# ============================================================================
.PHONY: all arch-test-setup arch-test-run arch-test-clean help

all: help

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
	@if [ ! -d "$(ACT_DIR)/.git" ]; then \
	    echo "[arch-test] Cloning $(ACT_REPO) (branch $(ACT_BRANCH))..."; \
	    git -C $(JV32_ROOT) submodule add -b $(ACT_BRANCH) $(ACT_REPO) verif/riscv-arch-test; \
	    git -C $(JV32_ROOT) submodule update --init verif/riscv-arch-test; \
	else \
	    echo "[arch-test] Updating $(ACT_DIR)..."; \
	    git -C $(JV32_ROOT) submodule update --remote verif/riscv-arch-test; \
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
# ============================================================================
arch-test-run: $(ACT_SENTINEL)
	@mkdir -p "$(WORKDIR)"
	@SANITIZED_TESTDIR="$(WORKDIR)/tests-sanitized"; \
	 rm -rf "$$SANITIZED_TESTDIR"; \
	 mkdir -p "$$SANITIZED_TESTDIR"
	@echo "=========================================="
	@echo "[arch-test] Work directory: $(WORKDIR)"
	@echo "[arch-test] Phase 1/3: building RTL simulator"
	@echo "=========================================="
	@$(MAKE) -C $(JV32_ROOT) --no-print-directory build-rtl
	@echo "=========================================="
	@echo "[arch-test] Phase 2/3: generating self-checking ELFs"
	@echo "=========================================="
	@$(MAKE) -C $(ACT_DIR) tests \
	    WORKDIR=$(WORKDIR) \
	    $(if $(EXTENSIONS),EXTENSIONS=$(EXTENSIONS),) \
	    --jobs $(ARCH_TEST_JOBS)
	@SANITIZED_TESTDIR="$(WORKDIR)/tests-sanitized"; \
	 cp -a "$(ACT_DIR)/tests/." "$$SANITIZED_TESTDIR/"; \
	 find "$$SANITIZED_TESTDIR" -type f -name '*.S' -exec sed -i '/^# CONFIG_DEPENDENT:/d' {} +
	@$(MAKE) -C $(ACT_DIR) elfs \
	    CONFIG_FILES=$(DUT_CONFIG)/test_config.yaml \
	    WORKDIR=$(WORKDIR) \
	    TESTDIR=$(WORKDIR)/tests-sanitized \
	    $(if $(EXTENSIONS),EXTENSIONS=$(EXTENSIONS),) \
	    --jobs $(ARCH_TEST_JOBS)
	@elf_count=$$(find "$(WORKDIR)/jv32-rv32imac/elfs" -name '*.elf' | wc -l | tr -d '[:space:]'); \
	  echo "[arch-test] Phase 3/3: running $$elf_count ELF tests on JV32 RTL"; \
	  echo "[arch-test] Logs: $(WORKDIR)/jv32-rv32imac/logs"; \
	  echo "[arch-test] Summary: $(WORKDIR)/jv32-rv32imac/summary.log"
	@cd $(ACT_DIR) && $(ACT_VENV)/bin/python run_tests.py \
	    "$(JV32_ROOT)/build/jv32soc" \
	    "$(WORKDIR)/jv32-rv32imac/elfs"

# ============================================================================
# arch-test-%: pass-through any other target to the ACT4 Makefile
# ============================================================================
arch-test-%: $(ACT_SENTINEL)
	@$(MAKE) -C $(ACT_DIR) \
	    CONFIG_FILES=$(DUT_CONFIG)/test_config.yaml \
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
