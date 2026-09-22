# This raw-instruction test needs no libc or libgcc. Keep disabled-A builds
# independent of the host toolchain's available multilib configurations.
LDFLAGS_EXTRA += -nostdlib
