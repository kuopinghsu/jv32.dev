# Force Zba/Zbb/Zbs extensions for this test regardless of the root ARCH.
# The inline assembly uses zbb/zbs/zba opcodes which require the sub-extension
# flags to be present in -march at compile time.
CFLAGS  := $(filter-out -march=%,$(CFLAGS))  -march=rv32imac_zicsr_zba_zbb_zbs
LDFLAGS := $(filter-out -march=%,$(LDFLAGS)) -march=rv32imac_zicsr_zba_zbb_zbs
