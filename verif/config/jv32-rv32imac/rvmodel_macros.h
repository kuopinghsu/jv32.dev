# rvmodel_macros.h
# RVMODEL macro definitions for JV32 RV32IMAC core
# SPDX-License-Identifier: Apache-2.0
#
# JV32 memory map (relevant):
#   0x40000000  CONSOLE_MAGIC — byte write outputs char to simulator stdout
#   0x40000004  EXIT_MAGIC    — word write exits sim; HTIF decode: exit_code = value >> 1
#                               write 1  → exit(0)  → PASS
#                               write 3  → exit(1)  → FAIL
#   0x02000000  CLIC MSIP     — software interrupt pending
#   0x02004000  mtime (lo)
#   0x02004008  mtimecmp (lo)

#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define RVMODEL_DATA_SECTION

##### STARTUP #####
/*
 * JV32 resets with:
 *   mstatus.MIE = 0  (interrupts disabled)
 *   mcountinhibit not implemented — mcycle/minstret always count
 * No special boot sequence required.
 */
#define RVMODEL_BOOT

# Address to use for load/store fault tests that should cause an access fault.
# JV32 raises EXC_LOAD_ACCESS_FAULT (cause=5) or EXC_STORE_ACCESS_FAULT (cause=7)
# when the AXI crossbar returns DECERR for unmapped addresses.
# 0x00000000 is unmapped in the JV32 address space (lowest mapped address is CLIC at 0x02000000).
#define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000

##### TERMINATION #####

# Terminate test with a pass indication.
# Write HTIF-encoded 1 to EXIT_MAGIC (0x40000004):
#   exit_code = 1 >> 1 = 0  →  program exits 0  →  PASS
#define RVMODEL_HALT_PASS                             \
  li    x1, 1                                        ;\
  li    x2, 0x40000004                               ;\
  sw    x1, 0(x2)                                    ;\
rvmodel_halt_pass_loop:                              ;\
  j     rvmodel_halt_pass_loop                       ;\

# Terminate test with a fail indication.
# Write HTIF-encoded 3 to EXIT_MAGIC (0x40000004):
#   exit_code = 3 >> 1 = 1  →  program exits 1  →  FAIL
#define RVMODEL_HALT_FAIL                             \
  li    x1, 3                                        ;\
  li    x2, 0x40000004                               ;\
  sw    x1, 0(x2)                                    ;\
rvmodel_halt_fail_loop:                              ;\
  j     rvmodel_halt_fail_loop                       ;\

##### IO #####

# No IO initialisation required.
#define RVMODEL_IO_INIT(_R1, _R2, _R3)

# Print a null-terminated string to the JV32 console (CONSOLE_MAGIC = 0x40000000).
# Each word-store with the character in bits[7:0] outputs one character to stdout
# of the jv32soc simulation process, which is captured in the ACT4 run log.
# _R1   — scratch: character byte
# _R2   — scratch: console address
# _R3   — (unused)
# _STR_PTR — pointer to string (incremented in place; null-terminates the loop)
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)      \
  li    _R2, 0x40000000                                    ;\
1:                                                         ;\
  lbu   _R1, 0(_STR_PTR)                                   ;\
  beqz  _R1, 2f                                            ;\
  sw    _R1, 0(_R2)                                        ;\
  addi  _STR_PTR, _STR_PTR, 1                              ;\
  j     1b                                                 ;\
2:

##### Interrupt Latency #####

#define RVMODEL_INTERRUPT_LATENCY 10

##### Machine Timer #####

#define RVMODEL_TIMER_INT_SOON_DELAY 100

# JV32 CLIC timer registers (compatible with standard CLINT layout):
#   mtime    at 0x02004000  (CLIC_BASE + 0x4000)
#   mtimecmp at 0x02004008  (CLIC_BASE + 0x4008)
# These are defined but machine-timer interrupt tests are excluded by default
# (InterruptsSm is in EXCLUDE_EXTENSIONS).
#define RVMODEL_MTIME_ADDRESS    0x02004000
#define RVMODEL_MTIMECMP_ADDRESS 0x02004008

##### Machine Interrupts #####

# JV32 CLIC MSIP at 0x02000000 (compatible with standard CLINT MSIP layout).
# Writing 1 sets the machine software interrupt pending bit.
#define RVMODEL_SET_MSW_INT(_R1, _R2)           \
  li    _R1, 1                                 ;\
  li    _R2, 0x02000000                        ;\
  sw    _R1, 0(_R2)                            ;\

#define RVMODEL_CLR_MSW_INT(_R1, _R2)           \
  li    _R2, 0x02000000                        ;\
  sw    x0,  0(_R2)                            ;\

# External interrupts driven by CLIC — not connected to a configurable PLIC.
# Leave empty; external-interrupt tests are excluded.
#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)

##### Supervisor Interrupts #####

# JV32 is M-mode only — no S-mode support.
#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)

#endif // _RVMODEL_MACROS_H
