# makefile.mak — per-test overrides for the hello / debugger test.
#
# The labels foo1..foo5 exist solely as GDB breakpoint targets
# (break main:foo1 … break main:foo5).  They are intentionally not
# referenced by any C code, which triggers -Wunused-label.  Suppress
# that warning for this translation unit only.
CFLAGS += -Wno-unused-label
