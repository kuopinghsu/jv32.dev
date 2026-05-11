# sw/zcmp/makefile.mak
# No -march override needed: ARCH already includes _zcmp when ZCMP_EN=1
# (set by the root Makefile).  All Zcmp instructions are encoded as raw
# .hword immediates, so GCC/GNU-as does not need to see _zcmp in -march
# to assemble them.  This file is kept as a placeholder so the pattern is
# consistent with other extension tests (e.g. sw/zb_ext/makefile.mak).

