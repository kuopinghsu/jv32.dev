# C++ integration test – per-test compiler flag overrides.
#
# GCC 15 added a freestanding-mode check to <vector> and other libstdc++
# hosted headers (#error "This header is not available in freestanding mode").
# For C++ files we must compile in hosted mode (drop -ffreestanding) and use
# -fno-exceptions / -fno-rtti instead — the standard embedded C++ ABI.
#
# Full exception unwinding would require:
#   - .eh_frame kept in link.ld  (currently discarded to save IRAM)
#   - IRAM ≥ 256 KB  (libstdc++ unwind runtime + application > 128 KB)
# Both constraints make it impractical on this 128 KB IRAM target; the
# -fno-exceptions mode is the correct production configuration.
#
# -fpermissive: GCC 15+ libstdc++ calls __throw_length_error() and other
# exception functions inside template bodies even when -fno-exceptions is used.
# These functions are defined as weak symbols in cxx_stubs.cpp and resolved at
# link time. -fpermissive allows undeclared names in template bodies.

# Drop -ffreestanding from CFLAGS so hosted C++ headers can be included.
# C++-only flags are saved in CPP_EXTRA_FLAGS and will be appended to CXXFLAGS
# in sw/Makefile, so they don't contaminate C file compilation.
CFLAGS := $(filter-out -ffreestanding,$(CFLAGS))
CPP_EXTRA_FLAGS := -fno-exceptions -fno-rtti -fpermissive

# GCC 15 riscv64-unknown-elf does not add the target-specific C++ include
# sub-directory (e.g. riscv64-unknown-elf/) to the search path when the
# matching multilib directory does not exist, so bits/c++config.h is not
# found.  Add it explicitly via -isystem so it is searched after the generic
# headers but before the compiler's own fixed includes.
CPP_EXTRA_FLAGS += -isystem $(shell $(CXX) -print-sysroot)/include/c++/$(shell $(CXX) -dumpversion)/$(shell $(CXX) -dumpmachine)
# The riscv64-unknown-elf toolchain only ships 64-bit libstdc++/libsupc++ so
# linking it against a 32-bit ELF fails.  Use -nostdlib++ to suppress the
# implicit -lstdc++ added by g++; operator new/delete are provided by
# sw/common/cxx_stubs.cpp backed by newlib malloc.
LDFLAGS_EXTRA += -nostdlib++

# Use magic backend for this test so RTL and ISS exit paths match.
# The ISS implements RISC-V semihosting and exits via ebreak, while the RTL
# doesn't and continues to the magic device exit. Using the magic backend
# ensures both exit the same way for trace comparison.
JV_IO_BACKEND := magic
