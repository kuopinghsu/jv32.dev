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

CXXFLAGS := $(filter-out -ffreestanding,$(CXXFLAGS))
CXXFLAGS += -fno-exceptions -fno-rtti
