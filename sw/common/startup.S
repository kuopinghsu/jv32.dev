/* ============================================================================
 * File: sw/startup.S
 * Project: JV32 RISC-V Processor
 * Description: Reset vector and trap handler for RV32IMAC bare-metal tests
 *
 * Memory map:
 *   IRAM: 0x80000000 - 0x8000FFFF (64 KB, RX)
 *   DRAM: 0xC0000000 - 0xC000FFFF (64 KB, RW)
 * ============================================================================ */

    .section .text.reset, "ax", @progbits
    .global  _start
    .type    _start, @function

_start:
    /* ------------------------------------------------------------------ */
    /* 1. Initialise global pointer (for gp-relative data access)         */
    /* ------------------------------------------------------------------ */
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop

    /* ------------------------------------------------------------------ */
    /* 2. Set up mtvec to trap handler (direct mode, bottom 2 bits = 00)  */
    /* ------------------------------------------------------------------ */
    la      t0, trap_entry
    csrw    mtvec, t0

    /* ------------------------------------------------------------------ */
    /* 3. Zero the BSS section                                             */
    /* ------------------------------------------------------------------ */
    la      a0, _bss_start
    la      a1, _bss_end
    bgeu    a0, a1, .Lbss_done
.Lbss_loop:
    sw      zero, 0(a0)
    addi    a0, a0, 4
    bltu    a0, a1, .Lbss_loop
.Lbss_done:

    /* ------------------------------------------------------------------ */
    /* ------------------------------------------------------------------ */
    /* 3. Copy .data from LMA (IRAM copy) to VMA (DRAM)                   */
    /* ------------------------------------------------------------------ */
    la      a0, _data_lma      /* source (IRAM) */
    la      a1, _data_start    /* destination (DRAM) */
    la      a2, _data_end
    bgeu    a1, a2, .Ldata_done
.Ldata_loop:
    lw      t0, 0(a0)
    sw      t0, 0(a1)
    addi    a0, a0, 4
    addi    a1, a1, 4
    bltu    a1, a2, .Ldata_loop
.Ldata_done:

    /* ------------------------------------------------------------------ */
    /* 4. Set up stack pointer                                             */
    /* ------------------------------------------------------------------ */
    la      sp, _stack_top

    /* ------------------------------------------------------------------ */
    /* 5. Call global constructors (C++ .init_array)                      */
    /* ------------------------------------------------------------------ */
    call    __libc_init_array

    /* ------------------------------------------------------------------ */
    /* 6. Call main                                                        */
    /* ------------------------------------------------------------------ */
    li      a0, 0           /* argc = 0 */
    li      a1, 0           /* argv = NULL */
    call    main

    /* ------------------------------------------------------------------ */
    /* 6. If main returns: write exit code to magic register and spin     */
    /* ------------------------------------------------------------------ */
    mv      a0, a0          /* exit code already in a0 */
    call    _exit

_spin:
    j       _spin

    .size _start, . - _start

/* ============================================================================
 * _exit: write exit code to magic peripheral then spin
 * ============================================================================ */
    .section .text, "ax", @progbits
    .global  _exit
    .type    _exit, @function
_exit:
    /* magic peripheral EXIT register at 0x4000_0004:
     *   encoding: PASS (code=0) → write 1; FAIL (code≠0) → write (code<<1)|1
     *   write non-zero value triggers sim_request_exit(value>>1) DPI-C call */
    li      t0, 0x40000004
    beqz    a0, .Lexit_pass
    slli    a0, a0, 1
    ori     a0, a0, 1
    j       .Lexit_write
.Lexit_pass:
    li      a0, 1
.Lexit_write:
    sw      a0, 0(t0)
    j       _spin             /* should not reach here; DPI exits sim */
    .size _exit, . - _exit

/* ============================================================================
 * Trap entry: M-mode trap handler
 * Saves all GPRs + mepc/mstatus/mcause/mtval to a frame on the stack,
 * then calls trap_handler(jv_trap_frame_t *frame).
 *
 * RV32I frame (144 bytes):  [sp+0] x0 pad, [sp+4..124] x1-x31,
 *                            [sp+128] mepc, [sp+132] mstatus,
 *                            [sp+136] mcause, [sp+140] mtval
 * RV32E frame (80 bytes):   [sp+0] x0 pad, [sp+4..60] x1-x15,
 *                            [sp+64] mepc,  [sp+68] mstatus,
 *                            [sp+72] mcause,[sp+76] mtval
 * ============================================================================ */
#ifdef __riscv_e
# define TRAP_FRAME_SIZE  80
# define TRAP_MEPC_OFF    64
# define TRAP_MSTAT_OFF   68
# define TRAP_MCAUSE_OFF  72
# define TRAP_MTVAL_OFF   76
#else
# define TRAP_FRAME_SIZE  144
# define TRAP_MEPC_OFF    128
# define TRAP_MSTAT_OFF   132
# define TRAP_MCAUSE_OFF  136
# define TRAP_MTVAL_OFF   140
#endif

    .section .text.trap, "ax", @progbits
    .global  trap_entry
    .type    trap_entry, @function
    .align   2

trap_entry:
    addi    sp, sp, -TRAP_FRAME_SIZE

    sw      x1,   4(sp)
    sw      x2,   8(sp)
    sw      x3,  12(sp)
    sw      x4,  16(sp)
    sw      x5,  20(sp)
    sw      x6,  24(sp)
    sw      x7,  28(sp)
    sw      x8,  32(sp)
    sw      x9,  36(sp)
    sw      x10, 40(sp)
    sw      x11, 44(sp)
    sw      x12, 48(sp)
    sw      x13, 52(sp)
    sw      x14, 56(sp)
    sw      x15, 60(sp)
#ifndef __riscv_e
    sw      x16, 64(sp)
    sw      x17, 68(sp)
    sw      x18, 72(sp)
    sw      x19, 76(sp)
    sw      x20, 80(sp)
    sw      x21, 84(sp)
    sw      x22, 88(sp)
    sw      x23, 92(sp)
    sw      x24, 96(sp)
    sw      x25, 100(sp)
    sw      x26, 104(sp)
    sw      x27, 108(sp)
    sw      x28, 112(sp)
    sw      x29, 116(sp)
    sw      x30, 120(sp)
    sw      x31, 124(sp)
#endif /* !__riscv_e */

    csrr    x1, mepc
    sw      x1,  TRAP_MEPC_OFF(sp)
    csrr    x1, mstatus
    sw      x1,  TRAP_MSTAT_OFF(sp)
    csrr    x1, mcause
    sw      x1,  TRAP_MCAUSE_OFF(sp)
    csrr    x1, mtval
    sw      x1,  TRAP_MTVAL_OFF(sp)

    /* Restore ra (used as scratch above) from saved copy */
    lw      x1, 4(sp)

    /* Call trap_handler(jv_trap_frame_t *frame) */
    mv      a0, sp
    call    trap_handler

    /* Restore mstatus and mepc from frame (authoritative — handlers may have
     * modified them to redirect return PC or update interrupt-enable state). */
    lw      x1, TRAP_MSTAT_OFF(sp)
    csrw    mstatus, x1
    lw      x1, TRAP_MEPC_OFF(sp)
    csrw    mepc, x1

    /* Restore all general-purpose registers */
    lw      x1,   4(sp)
    lw      x2,   8(sp)
    lw      x3,  12(sp)
    lw      x4,  16(sp)
    lw      x5,  20(sp)
    lw      x6,  24(sp)
    lw      x7,  28(sp)
    lw      x8,  32(sp)
    lw      x9,  36(sp)
    lw      x10, 40(sp)
    lw      x11, 44(sp)
    lw      x12, 48(sp)
    lw      x13, 52(sp)
    lw      x14, 56(sp)
    lw      x15, 60(sp)
#ifndef __riscv_e
    lw      x16, 64(sp)
    lw      x17, 68(sp)
    lw      x18, 72(sp)
    lw      x19, 76(sp)
    lw      x20, 80(sp)
    lw      x21, 84(sp)
    lw      x22, 88(sp)
    lw      x23, 92(sp)
    lw      x24, 96(sp)
    lw      x25, 100(sp)
    lw      x26, 104(sp)
    lw      x27, 108(sp)
    lw      x28, 112(sp)
    lw      x29, 116(sp)
    lw      x30, 120(sp)
    lw      x31, 124(sp)
#endif /* !__riscv_e */

    addi    sp, sp, TRAP_FRAME_SIZE
    mret

    .size trap_entry, . - trap_entry

/* ============================================================================
 * Default trap_handler is provided by sw/common/jv_irq.c as a weak symbol.
 * Tests can override it by defining their own trap_handler().
 * ============================================================================ */
