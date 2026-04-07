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
    /* 1. Set up mtvec to trap handler (direct mode, bottom 2 bits = 00)  */
    /* ------------------------------------------------------------------ */
    la      t0, trap_entry
    csrw    mtvec, t0

    /* ------------------------------------------------------------------ */
    /* 2. Zero the BSS section                                             */
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
    /* 5. Call main                                                        */
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
    /* magic peripheral at 0x4000_0000:
     *   offset 0x00 = exit request register
     *   write non-zero value triggers sim_request_exit() DPI-C call */
    li      t0, 0x40000000
    sw      a0, 0(t0)
    j       _spin             /* should not reach here; DPI exits sim */
    .size _exit, . - _exit

/* ============================================================================
 * Trap entry: minimal M-mode trap handler
 * Saves critical registers, calls handle_trap(mcause, mepc, mtval)
 * ============================================================================ */
    .section .text.trap, "ax", @progbits
    .global  trap_entry
    .type    trap_entry, @function
    .align   2

trap_entry:
    /* Save registers to a scratch area in DRAM.
     * We use a simple per-hart trap stack; for single-hart this is fine. */
    addi    sp, sp, -128

    sw      ra,   0(sp)
    sw      t0,   4(sp)
    sw      t1,   8(sp)
    sw      t2,  12(sp)
    sw      a0,  16(sp)
    sw      a1,  20(sp)
    sw      a2,  24(sp)
    sw      a3,  28(sp)
    sw      a4,  32(sp)
    sw      a5,  36(sp)
    sw      a6,  40(sp)
    sw      a7,  44(sp)
    sw      t3,  48(sp)
    sw      t4,  52(sp)
    sw      t5,  56(sp)
    sw      t6,  60(sp)

    /* Pass mcause / mepc / mtval to C handler */
    csrr    a0, mcause
    csrr    a1, mepc
    csrr    a2, mtval

    call    handle_trap

    /* handle_trap returns updated mepc in a0 (0 = use original mepc) */
    beqz    a0, .Ltrap_restore_mepc
    csrw    mepc, a0
.Ltrap_restore_mepc:

    lw      ra,   0(sp)
    lw      t0,   4(sp)
    lw      t1,   8(sp)
    lw      t2,  12(sp)
    lw      a0,  16(sp)
    lw      a1,  20(sp)
    lw      a2,  24(sp)
    lw      a3,  28(sp)
    lw      a4,  32(sp)
    lw      a5,  36(sp)
    lw      a6,  40(sp)
    lw      a7,  44(sp)
    lw      t3,  48(sp)
    lw      t4,  52(sp)
    lw      t5,  56(sp)
    lw      t6,  60(sp)
    addi    sp, sp, 128

    mret

    .size trap_entry, . - trap_entry

/* ============================================================================
 * Default handle_trap is provided by sw/common/jv_irq.c as a weak symbol.
 * Tests can override it by defining their own handle_trap().
 * ============================================================================ */
