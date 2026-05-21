# sw/zcmp/makefile.mak
# When ZCMP_EN=1 the root Makefile appends _zcmp to ARCH, which causes the
# compiler to define __riscv_zcmp.  The test's main() skips cleanly when
# __riscv_zcmp is not defined (ZCMP_EN=0 or standalone build).
# Each asm block emits ".option arch, +zcmp" so the assembler accepts
# cm.push/cm.pop/etc. even if the global -march does not include _zcmp.
# This file is kept as a placeholder consistent with other extension tests
# (e.g. sw/zb_ext/makefile.mak).

