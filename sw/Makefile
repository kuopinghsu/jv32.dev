# ============================================================================
# File: sw/Makefile
# Project: JV32 RISC-V Processor
# Description: Build system for bare-metal software tests
#
# Usage:
#   make all                          # build all tests
#   make build TEST=hello BUILD_DIR=… # build a single test
#   make clean
# ============================================================================

# RISC-V cross toolchain prefix
# Prefer RISCV_PREFIX exported by the root Makefile (from env.config),
# falling back to CROSS or a bare riscv32-unknown-elf-
ifdef RISCV_PREFIX
  CROSS ?= $(patsubst %-,%,$(RISCV_PREFIX))
else
  CROSS ?= riscv32-unknown-elf
endif

CC      := $(CROSS)-gcc
AS      := $(CROSS)-gcc
LD      := $(CROSS)-gcc
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump
SIZE    := $(CROSS)-size

# Architecture flags: RV32IMAC + Zicsr
ARCH    := rv32imac_zicsr
ABI     := ilp32

CFLAGS  := -march=$(ARCH) -mabi=$(ABI)
CFLAGS  += -O2 -g
CFLAGS  += -Wall -Wextra
CFLAGS  += -nostdlib -nostartfiles -ffreestanding
CFLAGS  += -ffunction-sections -fdata-sections
CFLAGS  += -Iinclude

ASFLAGS := $(CFLAGS)

# Output directory for ELFs (set by root Makefile; defaults to sw/)
BUILD_DIR ?= .
# Intermediate object directory (always under BUILD_DIR)
OBJ_DIR   := $(BUILD_DIR)/obj

# Linker script and startup source (in common/)
COMMON_LINK := common/link.ld
STARTUP_SRC := common/startup.S
STARTUP_OBJ := $(OBJ_DIR)/startup.o

LDFLAGS := -march=$(ARCH) -mabi=$(ABI)
LDFLAGS += -nostdlib -nostartfiles
LDFLAGS += -T $(COMMON_LINK)
LDFLAGS += -Wl,--gc-sections

# Common SDK sources (compiled once; linked into every test ELF)
# handle_trap() in jv_irq.c is weak, so test overrides take priority.
COMMON_SRCS := $(wildcard common/*.c)
COMMON_OBJS := $(patsubst common/%.c,$(OBJ_DIR)/common/%.o,$(COMMON_SRCS))

# List of test binaries to build (ELFs go directly to BUILD_DIR)
TESTS := \
    $(BUILD_DIR)/hello.elf \
    $(BUILD_DIR)/trap_test.elf

.PHONY: all build clean disasm help \
        _build-hello _build-trap_test _build-coremark _build-dhry

# Prevent make from deleting intermediate object files
.SECONDARY:

all: $(TESTS)

# ----------------------------------------------------------------------------
# Build dispatcher: called by root Makefile as 'make build TEST=<name> BUILD_DIR=<dir>'
# ----------------------------------------------------------------------------
build:
ifndef TEST
	$(error TEST is not set. Usage: make -C sw build TEST=<name> BUILD_DIR=<dir>)
endif
	@$(MAKE) --no-print-directory _build-$(TEST)

# ============================================================================
# Hello World
# ============================================================================
HELLO_DIR  := hello
HELLO_SRCS := $(HELLO_DIR)/hello.c
HELLO_OBJS := $(patsubst $(HELLO_DIR)/%.c,$(OBJ_DIR)/$(HELLO_DIR)/%.o,$(HELLO_SRCS))

$(OBJ_DIR)/$(HELLO_DIR)/%.o: $(HELLO_DIR)/%.c
	@mkdir -p $(dir $@)
	@echo "  CC      $@"
	$(CC) $(CFLAGS) -I$(HELLO_DIR) -c -o $@ $<

$(BUILD_DIR)/hello.elf: $(HELLO_OBJS) $(STARTUP_OBJ) $(COMMON_OBJS) $(COMMON_LINK)
	@mkdir -p $(BUILD_DIR)
	@echo "  LD      $@"
	$(LD) $(LDFLAGS) -Wl,-Map,$(OBJ_DIR)/hello.map -o $@ $(STARTUP_OBJ) $(COMMON_OBJS) $(HELLO_OBJS)
	$(SIZE) $@

_build-hello: $(BUILD_DIR)/hello.elf

# ============================================================================
# Trap Test
# ============================================================================
TRAP_TEST_DIR  := trap_test
TRAP_TEST_SRCS := $(TRAP_TEST_DIR)/trap_test.c
TRAP_TEST_OBJS := $(patsubst $(TRAP_TEST_DIR)/%.c,$(OBJ_DIR)/$(TRAP_TEST_DIR)/%.o,$(TRAP_TEST_SRCS))

$(OBJ_DIR)/$(TRAP_TEST_DIR)/%.o: $(TRAP_TEST_DIR)/%.c
	@mkdir -p $(dir $@)
	@echo "  CC      $@"
	$(CC) $(CFLAGS) -I$(TRAP_TEST_DIR) -c -o $@ $<

$(BUILD_DIR)/trap_test.elf: $(TRAP_TEST_OBJS) $(STARTUP_OBJ) $(COMMON_OBJS) $(COMMON_LINK)
	@mkdir -p $(BUILD_DIR)
	@echo "  LD      $@"
	$(LD) $(LDFLAGS) -Wl,-Map,$(OBJ_DIR)/trap_test.map -o $@ $(STARTUP_OBJ) $(COMMON_OBJS) $(TRAP_TEST_OBJS)
	$(SIZE) $@

_build-trap_test: $(BUILD_DIR)/trap_test.elf

# ============================================================================
# CoreMark
# ============================================================================
COREMARK_DIR  := coremark
COREMARK_SRCS := \
    $(COREMARK_DIR)/core_list_join.c \
    $(COREMARK_DIR)/core_main.c \
    $(COREMARK_DIR)/core_matrix.c \
    $(COREMARK_DIR)/core_portme.c \
    $(COREMARK_DIR)/core_state.c \
    $(COREMARK_DIR)/core_util.c
COREMARK_OBJS := $(patsubst $(COREMARK_DIR)/%.c,$(OBJ_DIR)/$(COREMARK_DIR)/%.o,$(COREMARK_SRCS))

# Extra coremark compiler flags (from coremark/makefile.mak)
COREMARK_CFLAGS := -O3 -DITERATIONS=4 -DPERFORMANCE_RUN=1
COREMARK_CFLAGS += -fno-common -funroll-loops -finline-functions -falign-functions=16
COREMARK_CFLAGS += -falign-jumps=4 -falign-loops=4 -finline-limit=1000
COREMARK_CFLAGS += -freorder-blocks-and-partition -fno-tree-loop-if-convert
COREMARK_CFLAGS += -fno-tree-sink -fgcse-sm -fno-strict-overflow
FLAGS_STR       := "$(COREMARK_CFLAGS)"
COREMARK_CFLAGS += -DFLAGS_STR=\"$(FLAGS_STR)\"

$(OBJ_DIR)/$(COREMARK_DIR)/%.o: $(COREMARK_DIR)/%.c
	@mkdir -p $(dir $@)
	@echo "  CC      $@"
	$(CC) $(CFLAGS) $(COREMARK_CFLAGS) -I$(COREMARK_DIR) -c -o $@ $<

$(BUILD_DIR)/coremark.elf: $(COREMARK_OBJS) $(STARTUP_OBJ) $(COMMON_OBJS) $(COMMON_LINK)
	@mkdir -p $(BUILD_DIR)
	@echo "  LD      $@"
	$(LD) $(LDFLAGS) -Wl,-Map,$(OBJ_DIR)/coremark.map -o $@ $(STARTUP_OBJ) $(COMMON_OBJS) $(COREMARK_OBJS)
	$(SIZE) $@

_build-coremark: $(BUILD_DIR)/coremark.elf

# ============================================================================
# Dhrystone
# ============================================================================
DHRY_DIR  := dhry
DHRY_SRCS := $(DHRY_DIR)/dhry_1.c $(DHRY_DIR)/dhry_2.c
DHRY_OBJS := $(patsubst $(DHRY_DIR)/%.c,$(OBJ_DIR)/$(DHRY_DIR)/%.o,$(DHRY_SRCS))

DHRY_CFLAGS := -O3 -DREG= -DNO_PROTOTYPES

$(OBJ_DIR)/$(DHRY_DIR)/%.o: $(DHRY_DIR)/%.c
	@mkdir -p $(dir $@)
	@echo "  CC      $@"
	$(CC) $(CFLAGS) $(DHRY_CFLAGS) -I$(DHRY_DIR) -c -o $@ $<

$(BUILD_DIR)/dhry.elf: $(DHRY_OBJS) $(STARTUP_OBJ) $(COMMON_OBJS) $(COMMON_LINK)
	@mkdir -p $(BUILD_DIR)
	@echo "  LD      $@"
	$(LD) $(LDFLAGS) -Wl,-Map,$(OBJ_DIR)/dhry.map -o $@ $(STARTUP_OBJ) $(COMMON_OBJS) $(DHRY_OBJS)
	$(SIZE) $@

_build-dhry: $(BUILD_DIR)/dhry.elf

# ============================================================================
# Common rules
# ============================================================================

# Compile common SDK C sources → objects in OBJ_DIR/common/
$(OBJ_DIR)/common/%.o: common/%.c
	@mkdir -p $(dir $@)
	@echo "  CC      $@"
	$(CC) $(CFLAGS) -c -o $@ $<

# Assemble startup → OBJ_DIR/startup.o
$(OBJ_DIR)/startup.o: $(STARTUP_SRC)
	@mkdir -p $(OBJ_DIR)
	@echo "  AS      $@"
	$(AS) $(ASFLAGS) -c -o $@ $<

# Disassembly
disasm: $(patsubst $(BUILD_DIR)/%.elf,$(BUILD_DIR)/%.dis,$(TESTS))

$(BUILD_DIR)/%.dis: $(BUILD_DIR)/%.elf
	$(OBJDUMP) -d -S $< > $@

## Remove build artifacts
clean:
	@rm -rf $(OBJ_DIR)
	@rm -f $(BUILD_DIR)/*.elf $(BUILD_DIR)/*.map $(BUILD_DIR)/*.dis
	@echo "Clean done."

## Show this help
help:
	@echo "JV32 Software Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all              Build all tests (default)"
	@echo "  build TEST=name  Build a named test (dispatched by root Makefile)"
	@echo "  disasm           Generate disassembly for all tests"
	@echo "  clean            Remove build outputs"
	@echo ""
	@echo "Variables:"
	@echo "  CROSS=<prefix>   Toolchain prefix (default: riscv32-unknown-elf)"
	@echo "  BUILD_DIR=<dir>  Output directory for ELFs and objects (default: sw/)"
