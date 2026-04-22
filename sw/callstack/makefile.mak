# makefile.mak — per-test overrides for the callstack test.
#
# Enable frame-pointer so every non-inline function builds a proper
# fp/ra ABI frame that the backtrace walker can follow.
CFLAGS += -fno-omit-frame-pointer
#
# Disable tail-call (sibling-call) optimization.  Without this flag, GCC
# converts   level4() { trigger_fault(); }   into a jump rather than a call,
# reusing the caller's ra and stack frame.  The entire chain collapses to a
# single frame, making the backtrace show only 2 levels instead of 5.
CFLAGS += -fno-optimize-sibling-calls
