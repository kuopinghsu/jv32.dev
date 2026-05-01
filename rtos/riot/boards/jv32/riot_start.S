/*
 * JV32 RIOT startup code
 *
 * Derived from cpu/riscv_common/start.S, adapted for the JV32 SoC.
 * After BSS/data init it calls cpu_init(), board_init(), kernel_init()
 * in exactly the order that the RIOT RISC-V port expects.
 *
 * SPDX-License-Identifier: LGPL-2.1-only
 */

#include "vendor/riscv_csr.h"

    .section .init
    .globl  _start
    .type   _start, @function

_start:
    .cfi_startproc
    .cfi_undefined ra

    /* Disable global interrupts during init */
    csrc    CSR_MSTATUS, MSTATUS_MIE

    /* ── Global pointer relaxation ─────────────────────── */
.option push
.option norelax
    la      gp, __global_pointer$
.option pop

    /* ── Stack pointer ─────────────────────────────────── */
    la      sp, _sp

    /* ── Copy .data from LMA → VMA (for flash→RAM archs) ─
     * On JV32 everything lives in RAM so LMA == VMA, but
     * include this for correctness / future use.          */
    la      a0, _data_lma
    la      a1, _data
    la      a2, _edata
    bgeu    a1, a2, 2f
1:
    lw      t0, (a0)
    sw      t0, (a1)
    addi    a0, a0, 4
    addi    a1, a1, 4
    bltu    a1, a2, 1b
2:

    /* ── Clear BSS ─────────────────────────────────────── */
    la      a0, __bss_start
    la      a1, __bss_end
    bgeu    a0, a1, 2f
1:
    sw      zero, (a0)
    addi    a0, a0, 4
    bltu    a0, a1, 1b
2:

    /* ── C++ / libc constructors ───────────────────────── */
    call    __libc_init_array

    /* ── RIOT init sequence ────────────────────────────── */
    call    cpu_init        /* JV32 cpu.c: enables FPU, PLIC, CLINT   */
    call    board_init      /* JV32 board.c: (no-op for sim)           */
    call    kernel_init     /* JV32 riot_init.c: create threads        */

    /* Should never reach here — kernel_init() does not return */
1:
    j       1b

    .cfi_endproc
    .size   _start, .-_start

/* ── Exit handler ──────────────────────────────────────────────────────
 * Writes exit code to the JV32 simulation magic address and spins.
 * KV_MAGIC_EXIT_ADDR = 0x40000004 (KV_MAGIC_BASE=0x40000000 + 0x0004).
 * No includes needed — we use the raw immediate.
 */
    .globl  _exit
    .type   _exit, @function
_exit:
    li      t0, 0x40000004
    sw      a0, 0(t0)
1:
    j       1b
    .size   _exit, .-_exit
