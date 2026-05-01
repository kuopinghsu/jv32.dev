# JV32 standalone RIOT build Makefile.
#
# Builds RIOT OS kernel sources + JV32 port directly with riscv32-unknown-elf-gcc,
# following the same interface as rtos/freertos/Makefile.
#
# Invoked by the project root Makefile via:
#   make -C rtos/riot/boards/jv32 build TEST=<sample|all>
#   make -C rtos/riot/boards/jv32 list-tests
#   make -C rtos/riot/boards/jv32 clean
#
# Root shared targets (once riot-% is wired in root Makefile):
#   make rtl-riot-<sample|all>
#   make sim-riot-<sample|all>

-include ../../../../env.config

export RISCV_PREFIX

PROJECT_ROOT = $(realpath ../../../..)
BUILD_DIR    ?= $(PROJECT_ROOT)/build
BUILD_DIR    := $(abspath $(BUILD_DIR))
RIOT_OBJ_DIR  = $(BUILD_DIR)/riot

ARCH ?= rv32imac_zicsr
ABI  ?= ilp32

RISCV_PREFIX ?= riscv32-unknown-elf-
CC      = $(RISCV_PREFIX)gcc
OBJDUMP = $(RISCV_PREFIX)objdump
READELF = $(RISCV_PREFIX)readelf

# ── Directory layout ──────────────────────────────────────────────────
RIOT_DIR     = $(PROJECT_ROOT)/rtos/riot
RIOT_SAMPLES = $(RIOT_DIR)/samples
RIOT_BOARDS  = $(RIOT_DIR)/boards/jv32
RIOT_CPUDIR  = $(RIOT_DIR)/cpu/jv32
RIOT_COMMON  = $(RIOT_DIR)/cpu/riscv_common
SW_INCLUDE   = $(PROJECT_ROOT)/sw/include

# ── RIOT source files (minimal kernel — no module system required) ────
#
# Core kernel
RIOT_CORE_SRCS = \
	$(RIOT_DIR)/core/thread.c \
	$(RIOT_DIR)/core/sched.c \
	$(RIOT_DIR)/core/mutex.c \
	$(RIOT_DIR)/core/msg.c \
	$(RIOT_DIR)/core/thread_flags.c \
	$(RIOT_DIR)/core/cond.c

# Core utility library
RIOT_CORELIB_SRCS = \
	$(RIOT_DIR)/core/lib/bitarithm.c \
	$(RIOT_DIR)/core/lib/clist.c \
	$(RIOT_DIR)/core/lib/panic.c \
	$(RIOT_DIR)/core/lib/assert.c

# RISC-V common CPU layer
RIOT_RISCV_SRCS = \
	$(RIOT_COMMON)/thread_arch.c \
	$(RIOT_COMMON)/irq_arch.c \
	$(RIOT_COMMON)/riscv_init.c \
	$(RIOT_COMMON)/context_frame.c \
	$(RIOT_COMMON)/periph/plic.c \
	$(RIOT_COMMON)/periph/coretimer.c

# JV32-specific CPU + board + kernel init
RIOT_JV32_SRCS = \
	$(RIOT_CPUDIR)/cpu.c \
	$(RIOT_CPUDIR)/riot_init.c \
	$(RIOT_BOARDS)/board.c \
	$(RIOT_BOARDS)/riot_syscall.c

RIOT_ASM_SRCS = \
	$(RIOT_BOARDS)/riot_start.S

RIOT_SOURCES = \
	$(RIOT_CORE_SRCS) \
	$(RIOT_CORELIB_SRCS) \
	$(RIOT_RISCV_SRCS) \
	$(RIOT_JV32_SRCS)

# ── Include paths ─────────────────────────────────────────────────────
RIOT_INCLUDES = \
	-I$(RIOT_DIR)/core/include \
	-I$(RIOT_DIR)/core/lib/include \
	-I$(RIOT_DIR)/sys/include \
	-I$(RIOT_DIR)/drivers/include \
	-I$(RIOT_COMMON)/include \
	-I$(RIOT_COMMON)/include/vendor \
	-I$(RIOT_CPUDIR)/include \
	-I$(RIOT_BOARDS)/include \
	-I$(RIOT_SAMPLES)/include \
	-I$(SW_INCLUDE)

# ── Module enables ────────────────────────────────────────────────────
# Passed as -D flags; IS_ACTIVE(X) in RIOT source expands to !!(X).
# MODULE_CORE_* defines enable RIOT kernel features and their corresponding
# fields in the thread_t struct:
#   CORE_THREAD       — thread_yield(), thread_getname() non-inline impls
#   CORE_MSG          — IPC message fields (msg_queue, msg_array, etc.)
#   CORE_THREAD_FLAGS — thread flags field and API
RIOT_MODULES = \
	-DMODULE_PERIPH_PLIC=0 \
	-DMODULE_PERIPH_CORETIMER=1 \
	-DMODULE_CORE_THREAD=1 \
	-DMODULE_CORE_MSG=1 \
	-DMODULE_CORE_THREAD_FLAGS=1 \
	-DCONFIG_THREAD_NAMES=1

# ── Kernel tuning ─────────────────────────────────────────────────────
RIOT_KERNEL_DEFS = \
	-DSCHED_PRIO_LEVELS=16 \
	-DKERNEL_MAXTHREADS=16 \
	-DTHREAD_STACKSIZE_MAIN=4096 \
	-DTHREAD_STACKSIZE_IDLE=512 \
	-DTHREAD_PRIORITY_MAIN=7

# ── Board / CPU identification ────────────────────────────────────────
RIOT_BOARD_DEFS = \
	-DRIOT_BOARD=\"jv32\" \
	-DRIOT_CPU=\"jv32\" \
	-DRIOT_ARCH=\"rv32i\" \
	-DRIOT_VERSION=\"2024.01-jv32\"

# ── Suppress RIOT debug output ────────────────────────────────────────
RIOT_DEBUG_DEFS = \
	-DENABLE_DEBUG=0 \
	-DCONFIG_SKIP_BOOT_MSG=1

# ── Combined CFLAGS ───────────────────────────────────────────────────
RIOT_CFLAGS  = -march=$(ARCH) -mabi=$(ABI) -O2 -g -Wall
RIOT_CFLAGS += -ffreestanding -nostartfiles
RIOT_CFLAGS += -ffunction-sections -fdata-sections
RIOT_CFLAGS += $(RIOT_INCLUDES)
RIOT_CFLAGS += $(RIOT_MODULES)
RIOT_CFLAGS += $(RIOT_KERNEL_DEFS)
RIOT_CFLAGS += $(RIOT_BOARD_DEFS)
RIOT_CFLAGS += $(RIOT_DEBUG_DEFS)
# Suppress warnings from upstream RIOT code that we cannot modify
RIOT_CFLAGS += -Wno-pedantic -Wno-cast-align -Wno-unused-parameter

# ── Linker flags ──────────────────────────────────────────────────────
RIOT_LDFLAGS  = -T $(RIOT_BOARDS)/riot_link.ld
RIOT_LDFLAGS += -Wl,--gc-sections
RIOT_LDFLAGS += -lc -lgcc -lm

# ── Sample discovery ─────────────────────────────────────────────────
SAMPLE_DIRS  = $(filter-out $(RIOT_SAMPLES)/include,$(wildcard $(RIOT_SAMPLES)/*))
SAMPLE_NAMES = $(notdir $(SAMPLE_DIRS))

# ── Targets ──────────────────────────────────────────────────────────

.PHONY: help list-tests build clean

help:
	@echo "RIOT OS framework build targets (JV32 standalone)"
	@echo "  make -C rtos/riot/boards/jv32 build TEST=<sample|all>"
	@echo "  make -C rtos/riot/boards/jv32 list-tests"
	@echo "  make -C rtos/riot/boards/jv32 clean"
	@echo ""
	@echo "Run through root shared targets:"
	@echo "  make rtl-riot-<sample|all>"
	@echo "  make sim-riot-<sample|all>"
	@echo "  make spike-riot-<sample|all>"
	@echo "  make compare-riot-<sample|all>"

list-tests:
	@for t in $(SAMPLE_NAMES); do echo $$t; done

build:
	@if [ -z "$(TEST)" ]; then \
		echo "Error: TEST is required"; exit 1; \
	fi
	@if [ "$(TEST)" = "all" ]; then \
		failed=0; \
		for t in $(SAMPLE_NAMES); do \
			if ! $(MAKE) --no-print-directory build TEST=$$t; then failed=1; fi; \
		done; \
		exit $$failed; \
	fi
	@if [ ! -d $(RIOT_SAMPLES)/$(TEST) ]; then \
		echo "Error: RIOT sample '$(TEST)' not found"; \
		exit 1; \
	fi
	@mkdir -p $(BUILD_DIR) $(RIOT_OBJ_DIR)/$(TEST)
	@set -e; \
	all_srcs="$(RIOT_ASM_SRCS) $(RIOT_SOURCES)"; \
	app_srcs=$$(ls $(RIOT_SAMPLES)/$(TEST)/*.c 2>/dev/null); \
	total=0; \
	for s in $$all_srcs $$app_srcs; do total=$$((total + 1)); done; \
	printf '[riot] CC %d objects for riot-%s\n' $$total '$(TEST)'; \
	objs=""; count=0; next_pct=10; \
	\
	for src in $$all_srcs; do \
		count=$$((count + 1)); \
		base=$$(basename "$$src"); stem=$${base%.*}; \
		obj=$(RIOT_OBJ_DIR)/$(TEST)_$${stem}.o; \
		$(CC) $(RIOT_CFLAGS) -c "$$src" -o "$$obj"; \
		objs="$$objs $$obj"; \
		pct=$$((count * 100 / total)); \
		if [ $$pct -ge $$next_pct ]; then \
			printf '[riot] %d%% (%d/%d)\n' $$next_pct $$count $$total; \
			next_pct=$$((next_pct + 10)); \
		fi; \
	done; \
	\
	for src in $$app_srcs; do \
		count=$$((count + 1)); \
		base=$$(basename "$$src"); stem=$${base%.*}; \
		obj=$(RIOT_OBJ_DIR)/$(TEST)_app_$${stem}.o; \
		$(CC) $(RIOT_CFLAGS) -c "$$src" -o "$$obj"; \
		objs="$$objs $$obj"; \
	done; \
	\
	printf '[riot] LD riot-%s.elf\n' '$(TEST)'; \
	$(CC) $(RIOT_CFLAGS) $(RIOT_LDFLAGS) \
		-Wl,-Map=$(BUILD_DIR)/riot-$(TEST).map \
		$$objs \
		-o $(BUILD_DIR)/riot-$(TEST).elf
	@$(OBJDUMP) -D $(BUILD_DIR)/riot-$(TEST).elf > $(BUILD_DIR)/riot-$(TEST).dis
	@$(READELF) -a $(BUILD_DIR)/riot-$(TEST).elf > $(BUILD_DIR)/riot-$(TEST).readelf
	@printf '[riot] done: %s\n' '$(BUILD_DIR)/riot-$(TEST).elf'

clean:
	@rm -f  $(BUILD_DIR)/riot-*.elf
	@rm -f  $(BUILD_DIR)/riot-*.map
	@rm -f  $(BUILD_DIR)/riot-*.dis
	@rm -f  $(BUILD_DIR)/riot-*.readelf
	@rm -rf $(RIOT_OBJ_DIR)
