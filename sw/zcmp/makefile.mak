# Exercise hardware Zcmp even when the RV32E multilib omits it from ARCH.
CFLAGS += -DJV32_TEST_ZCMP=$(if $(ZCMP_EN),$(ZCMP_EN),0)
LDFLAGS_EXTRA += -nostdlib
