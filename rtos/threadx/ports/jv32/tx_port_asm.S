.text
.align 2

/* TX_THREAD critical section layout starts with:
 *   +0: tx_thread_id
 *   +4: tx_thread_run_count
 *   +8: tx_thread_stack_ptr
 */

/* Saved context frame on each thread stack (31 words without FP, 65 with FP):
 *   0:  ra
 *   1:  sp
 *   2:  gp
 *   3:  tp
 *   4:  t0
 *   5:  t1
 *   6:  t2
 *   7:  s0
 *   8:  s1
 *   9:  a0
 *  10:  a1
 *  11:  a2
 *  12:  a3
 *  13:  a4
 *  14:  a5
 *  15:  a6
 *  16:  a7
 *  17:  s2
 *  18:  s3
 *  19:  s4
 *  20:  s5
 *  21:  s6
 *  22:  s7
 *  23:  s8
 *  24:  s9
 *  25:  s10
 *  26:  s11
 *  27:  t3
 *  28:  t4
 *  29:  t5
 *  30:  t6
 * With __riscv_float_abi_single or __riscv_float_abi_double (FP registers
 * are only saved/restored on cooperative context switches; the jv32 trap
 * entry in start.S does not save them, so preemptive switches inherit
 * whatever values the interrupt handler left in the scratch FP registers):
 *  31:  ft0  (f0)
 *  32:  ft1  (f1)
 *  33:  ft2  (f2)
 *  34:  ft3  (f3)
 *  35:  ft4  (f4)
 *  36:  ft5  (f5)
 *  37:  ft6  (f6)
 *  38:  ft7  (f7)
 *  39:  fs0  (f8)
 *  40:  fs1  (f9)
 *  41:  fa0  (f10)
 *  42:  fa1  (f11)
 *  43:  fa2  (f12)
 *  44:  fa3  (f13)
 *  45:  fa4  (f14)
 *  46:  fa5  (f15)
 *  47:  fa6  (f16)
 *  48:  fa7  (f17)
 *  49:  fs2  (f18)
 *  50:  fs3  (f19)
 *  51:  fs4  (f20)
 *  52:  fs5  (f21)
 *  53:  fs6  (f22)
 *  54:  fs7  (f23)
 *  55:  fs8  (f24)
 *  56:  fs9  (f25)
 *  57:  fs10 (f26)
 *  58:  fs11 (f27)
 *  59:  ft8  (f28)
 *  60:  ft9  (f29)
 *  61:  ft10 (f30)
 *  62:  ft11 (f31)
 *  63:  fcsr
 *  64:  (reserved for 16-byte alignment)
 */

.equ CTX_RA,   0
.equ CTX_SP,   4
.equ CTX_GP,   8
.equ CTX_TP,   12
.equ CTX_T0,   16
.equ CTX_T1,   20
.equ CTX_T2,   24
.equ CTX_S0,   28
.equ CTX_S1,   32
.equ CTX_A0,   36
.equ CTX_A1,   40
.equ CTX_A2,   44
.equ CTX_A3,   48
.equ CTX_A4,   52
.equ CTX_A5,   56
.equ CTX_A6,   60
.equ CTX_A7,   64
.equ CTX_S2,   68
.equ CTX_S3,   72
.equ CTX_S4,   76
.equ CTX_S5,   80
.equ CTX_S6,   84
.equ CTX_S7,   88
.equ CTX_S8,   92
.equ CTX_S9,   96
.equ CTX_S10,  100
.equ CTX_S11,  104
.equ CTX_T3,   108
.equ CTX_T4,   112
.equ CTX_T5,   116
.equ CTX_T6,   120

/* FP extension (only present when __riscv_float_abi_single/_double is set) */
.equ CTX_FT0,  124   /* f0  */
.equ CTX_FT1,  128   /* f1  */
.equ CTX_FT2,  132   /* f2  */
.equ CTX_FT3,  136   /* f3  */
.equ CTX_FT4,  140   /* f4  */
.equ CTX_FT5,  144   /* f5  */
.equ CTX_FT6,  148   /* f6  */
.equ CTX_FT7,  152   /* f7  */
.equ CTX_FS0,  156   /* f8  */
.equ CTX_FS1,  160   /* f9  */
.equ CTX_FA0,  164   /* f10 */
.equ CTX_FA1,  168   /* f11 */
.equ CTX_FA2,  172   /* f12 */
.equ CTX_FA3,  176   /* f13 */
.equ CTX_FA4,  180   /* f14 */
.equ CTX_FA5,  184   /* f15 */
.equ CTX_FA6,  188   /* f16 */
.equ CTX_FA7,  192   /* f17 */
.equ CTX_FS2,  196   /* f18 */
.equ CTX_FS3,  200   /* f19 */
.equ CTX_FS4,  204   /* f20 */
.equ CTX_FS5,  208   /* f21 */
.equ CTX_FS6,  212   /* f22 */
.equ CTX_FS7,  216   /* f23 */
.equ CTX_FS8,  220   /* f24 */
.equ CTX_FS9,  224   /* f25 */
.equ CTX_FS10, 228   /* f26 */
.equ CTX_FS11, 232   /* f27 */
.equ CTX_FT8,  236   /* f28 */
.equ CTX_FT9,  240   /* f29 */
.equ CTX_FT10, 244   /* f30 */
.equ CTX_FT11, 248   /* f31 */
.equ CTX_FCSR, 252
/* CTX_PC (resume PC for mret-based context restore):
 *   FP builds:     word 64, offset 256 (reuses the former alignment slot)
 *   non-FP builds: word 31, offset 124 (new word appended after CTX_T6)
 */
#if defined(__riscv_float_abi_single) || defined(__riscv_float_abi_double)
.equ CTX_PC,   256   /* word 64 — replaces former alignment pad */
.equ CTX_SIZE, 260   /* 65 words: 31 GPR + 33 FP + 1 PC (= CTX_PC) */
#else
.equ CTX_PC,   124   /* word 31 — new field after CTX_T6 */
.equ CTX_SIZE, 128   /* 32 words: 31 GPR + 1 PC */
#endif

/* JV32 custom CSR: stack guard base (sguard_base). */
.equ JV32_CSR_SGUARD_BASE, 0x7cc

/* _tx_jv32_preempt_pc: written by trap_handler (tx_port.c) when a preemptive
 * context switch is triggered.  _tx_thread_system_return reads it to store
 * the interrupted PC in CTX_PC without corrupting the thread's ra register. */
    .section .data
    .global _tx_jv32_preempt_pc
    .type _tx_jv32_preempt_pc, @object
_tx_jv32_preempt_pc:
    .word 0
    .text

.global _tx_thread_context_save
.type _tx_thread_context_save, @function
_tx_thread_context_save:
    /* Not used in the jv32 deferred-preemption model.
     * All traps enter via start.S which saves the full register file into
     * jv_trap_frame_t before calling C trap_handler.  That handler manages
     * _tx_thread_system_state directly and patches frame->mepc when a
     * preemptive switch is required.  There is no per-ISR call convention
     * for _tx_thread_context_save/_tx_thread_context_restore in this port. */
    ret

.global _tx_thread_schedule
.type _tx_thread_schedule, @function
_tx_thread_schedule:
    csrsi mstatus, 0x8
1:
    la t0, _tx_thread_execute_ptr
    lw t1, 0(t0)
    bnez t1, 2f
#ifndef TX_NO_WFI
    wfi
#endif
    j 1b
2:
    csrci mstatus, 0x8
    lw t1, 0(t0)
    beqz t1, _tx_thread_schedule
    la t0, _tx_thread_current_ptr
    sw t1, 0(t0)

    lw t2, 4(t1)
    addi t2, t2, 1
    sw t2, 4(t1)

    lw t2, 24(t1)
    la t3, _tx_timer_time_slice
    sw t2, 0(t3)

.global _tx_thread_context_restore
.type _tx_thread_context_restore, @function
_tx_thread_context_restore:
    /* Program per-thread stack guard before switching to thread SP.
       Keep the low-end canary word outside the hardware fault region. */
    lw t0, 12(t1)
#ifdef TX_JV32_SGUARD
    csrw JV32_CSR_SGUARD_BASE, t0
#endif
    lw sp, 8(t1)
    /* Load CTX_PC (resume PC) into t0 and programme mepc before t0 is
     * overwritten by its context-frame restore below.  Also set MPIE so
     * that mret re-enables interrupts (MIE = MPIE after mret). */
    lw t0, CTX_PC(sp)
    csrw mepc, t0
    li t0, 0x80
    csrs mstatus, t0         /* MPIE = 1 → MIE = 1 after mret */
    lw ra, CTX_RA(sp)
    lw gp, CTX_GP(sp)
    lw tp, CTX_TP(sp)
    lw t0, CTX_T0(sp)
    lw t1, CTX_T1(sp)
    lw t2, CTX_T2(sp)
    lw s0, CTX_S0(sp)
    lw s1, CTX_S1(sp)
    lw a0, CTX_A0(sp)
    lw a1, CTX_A1(sp)
    lw a2, CTX_A2(sp)
    lw a3, CTX_A3(sp)
    lw a4, CTX_A4(sp)
    lw a5, CTX_A5(sp)
    lw a6, CTX_A6(sp)
    lw a7, CTX_A7(sp)
    lw s2, CTX_S2(sp)
    lw s3, CTX_S3(sp)
    lw s4, CTX_S4(sp)
    lw s5, CTX_S5(sp)
    lw s6, CTX_S6(sp)
    lw s7, CTX_S7(sp)
    lw s8, CTX_S8(sp)
    lw s9, CTX_S9(sp)
    lw s10, CTX_S10(sp)
    lw s11, CTX_S11(sp)
    lw t3, CTX_T3(sp)
    lw t4, CTX_T4(sp)
    lw t5, CTX_T5(sp)
    lw t6, CTX_T6(sp)
#if defined(__riscv_float_abi_single)
    flw f0,  CTX_FT0(sp)
    flw f1,  CTX_FT1(sp)
    flw f2,  CTX_FT2(sp)
    flw f3,  CTX_FT3(sp)
    flw f4,  CTX_FT4(sp)
    flw f5,  CTX_FT5(sp)
    flw f6,  CTX_FT6(sp)
    flw f7,  CTX_FT7(sp)
    flw f8,  CTX_FS0(sp)
    flw f9,  CTX_FS1(sp)
    flw f10, CTX_FA0(sp)
    flw f11, CTX_FA1(sp)
    flw f12, CTX_FA2(sp)
    flw f13, CTX_FA3(sp)
    flw f14, CTX_FA4(sp)
    flw f15, CTX_FA5(sp)
    flw f16, CTX_FA6(sp)
    flw f17, CTX_FA7(sp)
    flw f18, CTX_FS2(sp)
    flw f19, CTX_FS3(sp)
    flw f20, CTX_FS4(sp)
    flw f21, CTX_FS5(sp)
    flw f22, CTX_FS6(sp)
    flw f23, CTX_FS7(sp)
    flw f24, CTX_FS8(sp)
    flw f25, CTX_FS9(sp)
    flw f26, CTX_FS10(sp)
    flw f27, CTX_FS11(sp)
    flw f28, CTX_FT8(sp)
    flw f29, CTX_FT9(sp)
    flw f30, CTX_FT10(sp)
    flw f31, CTX_FT11(sp)
    lw  t0,  CTX_FCSR(sp)
    csrw fcsr, t0
#elif defined(__riscv_float_abi_double)
    fld f0,  CTX_FT0(sp)
    fld f1,  CTX_FT1(sp)
    fld f2,  CTX_FT2(sp)
    fld f3,  CTX_FT3(sp)
    fld f4,  CTX_FT4(sp)
    fld f5,  CTX_FT5(sp)
    fld f6,  CTX_FT6(sp)
    fld f7,  CTX_FT7(sp)
    fld f8,  CTX_FS0(sp)
    fld f9,  CTX_FS1(sp)
    fld f10, CTX_FA0(sp)
    fld f11, CTX_FA1(sp)
    fld f12, CTX_FA2(sp)
    fld f13, CTX_FA3(sp)
    fld f14, CTX_FA4(sp)
    fld f15, CTX_FA5(sp)
    fld f16, CTX_FA6(sp)
    fld f17, CTX_FA7(sp)
    fld f18, CTX_FS2(sp)
    fld f19, CTX_FS3(sp)
    fld f20, CTX_FS4(sp)
    fld f21, CTX_FS5(sp)
    fld f22, CTX_FS6(sp)
    fld f23, CTX_FS7(sp)
    fld f24, CTX_FS8(sp)
    fld f25, CTX_FS9(sp)
    fld f26, CTX_FS10(sp)
    fld f27, CTX_FS11(sp)
    fld f28, CTX_FT8(sp)
    fld f29, CTX_FT9(sp)
    fld f30, CTX_FT10(sp)
    fld f31, CTX_FT11(sp)
    lw  t0,  CTX_FCSR(sp)
    csrw fcsr, t0
#endif
    lw sp, CTX_SP(sp)
    mret

.global _tx_thread_system_return
.type _tx_thread_system_return, @function
_tx_thread_system_return:
    csrci mstatus, 0x8

    addi sp, sp, -CTX_SIZE
    sw ra, CTX_RA(sp)
    sw gp, CTX_GP(sp)
    sw tp, CTX_TP(sp)
    /* Save t0 and t1 before using them as scratch below. */
    sw t0, CTX_T0(sp)
    sw t1, CTX_T1(sp)
    /* Save CTX_PC (the resume PC for mret-based context restore).
     * For preemptive switches _tx_jv32_preempt_pc holds the interrupted PC;
     * for cooperative yields it is 0 and we use ra (the return address). */
    la t0, _tx_jv32_preempt_pc
    lw t1, 0(t0)
    bnez t1, 1f
    sw ra, CTX_PC(sp)       /* cooperative: resume PC == ra */
    j 2f
1:  sw t1, CTX_PC(sp)       /* preemptive: resume PC == interrupted PC */
    sw zero, 0(t0)          /* clear preempt_pc for next context switch */
2:
    sw t2, CTX_T2(sp)
    sw s0, CTX_S0(sp)
    sw s1, CTX_S1(sp)
    sw a0, CTX_A0(sp)
    sw a1, CTX_A1(sp)
    sw a2, CTX_A2(sp)
    sw a3, CTX_A3(sp)
    sw a4, CTX_A4(sp)
    sw a5, CTX_A5(sp)
    sw a6, CTX_A6(sp)
    sw a7, CTX_A7(sp)
    sw s2, CTX_S2(sp)
    sw s3, CTX_S3(sp)
    sw s4, CTX_S4(sp)
    sw s5, CTX_S5(sp)
    sw s6, CTX_S6(sp)
    sw s7, CTX_S7(sp)
    sw s8, CTX_S8(sp)
    sw s9, CTX_S9(sp)
    sw s10, CTX_S10(sp)
    sw s11, CTX_S11(sp)
    sw t3, CTX_T3(sp)
    sw t4, CTX_T4(sp)
    sw t5, CTX_T5(sp)
    sw t6, CTX_T6(sp)

#if defined(__riscv_float_abi_single)
    fsw f0,  CTX_FT0(sp)
    fsw f1,  CTX_FT1(sp)
    fsw f2,  CTX_FT2(sp)
    fsw f3,  CTX_FT3(sp)
    fsw f4,  CTX_FT4(sp)
    fsw f5,  CTX_FT5(sp)
    fsw f6,  CTX_FT6(sp)
    fsw f7,  CTX_FT7(sp)
    fsw f8,  CTX_FS0(sp)
    fsw f9,  CTX_FS1(sp)
    fsw f10, CTX_FA0(sp)
    fsw f11, CTX_FA1(sp)
    fsw f12, CTX_FA2(sp)
    fsw f13, CTX_FA3(sp)
    fsw f14, CTX_FA4(sp)
    fsw f15, CTX_FA5(sp)
    fsw f16, CTX_FA6(sp)
    fsw f17, CTX_FA7(sp)
    fsw f18, CTX_FS2(sp)
    fsw f19, CTX_FS3(sp)
    fsw f20, CTX_FS4(sp)
    fsw f21, CTX_FS5(sp)
    fsw f22, CTX_FS6(sp)
    fsw f23, CTX_FS7(sp)
    fsw f24, CTX_FS8(sp)
    fsw f25, CTX_FS9(sp)
    fsw f26, CTX_FS10(sp)
    fsw f27, CTX_FS11(sp)
    fsw f28, CTX_FT8(sp)
    fsw f29, CTX_FT9(sp)
    fsw f30, CTX_FT10(sp)
    fsw f31, CTX_FT11(sp)
    csrr t0, fcsr
    sw   t0, CTX_FCSR(sp)
#elif defined(__riscv_float_abi_double)
    fsd f0,  CTX_FT0(sp)
    fsd f1,  CTX_FT1(sp)
    fsd f2,  CTX_FT2(sp)
    fsd f3,  CTX_FT3(sp)
    fsd f4,  CTX_FT4(sp)
    fsd f5,  CTX_FT5(sp)
    fsd f6,  CTX_FT6(sp)
    fsd f7,  CTX_FT7(sp)
    fsd f8,  CTX_FS0(sp)
    fsd f9,  CTX_FS1(sp)
    fsd f10, CTX_FA0(sp)
    fsd f11, CTX_FA1(sp)
    fsd f12, CTX_FA2(sp)
    fsd f13, CTX_FA3(sp)
    fsd f14, CTX_FA4(sp)
    fsd f15, CTX_FA5(sp)
    fsd f16, CTX_FA6(sp)
    fsd f17, CTX_FA7(sp)
    fsd f18, CTX_FS2(sp)
    fsd f19, CTX_FS3(sp)
    fsd f20, CTX_FS4(sp)
    fsd f21, CTX_FS5(sp)
    fsd f22, CTX_FS6(sp)
    fsd f23, CTX_FS7(sp)
    fsd f24, CTX_FS8(sp)
    fsd f25, CTX_FS9(sp)
    fsd f26, CTX_FS10(sp)
    fsd f27, CTX_FS11(sp)
    fsd f28, CTX_FT8(sp)
    fsd f29, CTX_FT9(sp)
    fsd f30, CTX_FT10(sp)
    fsd f31, CTX_FT11(sp)
    csrr t0, fcsr
    sw   t0, CTX_FCSR(sp)
#endif

    addi t0, sp, CTX_SIZE
    sw t0, CTX_SP(sp)

    la t0, _tx_thread_current_ptr
    lw t1, 0(t0)
    beqz t1, 1f

    la t2, _tx_timer_time_slice
    lw t3, 0(t2)
    beqz t3, 0f
    sw t3, 24(t1)
    sw zero, 0(t2)
0:

    sw sp, 8(t1)
    sw zero, 0(t0)
    j 2f

1:
    addi sp, sp, CTX_SIZE

2:
3:
    la t0, _tx_thread_execute_ptr
    lw t1, 0(t0)
    beqz t1, _tx_thread_schedule

    la t0, _tx_thread_current_ptr
    sw t1, 0(t0)

    lw t2, 24(t1)
    la t3, _tx_timer_time_slice
    sw t2, 0(t3)

     /* Program per-thread stack guard before switching to thread SP.
         Keep the low-end canary word outside the hardware fault region. */
    lw t0, 12(t1)
#ifdef TX_JV32_SGUARD
     csrw JV32_CSR_SGUARD_BASE, t0
#endif
    lw sp, 8(t1)
    /* Load CTX_PC (resume PC) into t0 and programme mepc before t0 is
     * overwritten by its context-frame restore below.  Also set MPIE so
     * that mret re-enables interrupts (MIE = MPIE after mret). */
    lw t0, CTX_PC(sp)
    csrw mepc, t0
    li t0, 0x80
    csrs mstatus, t0         /* MPIE = 1 → MIE = 1 after mret */
    lw ra, CTX_RA(sp)
    lw gp, CTX_GP(sp)
    lw tp, CTX_TP(sp)
    lw t0, CTX_T0(sp)
    lw t1, CTX_T1(sp)
    lw t2, CTX_T2(sp)
    lw s0, CTX_S0(sp)
    lw s1, CTX_S1(sp)
    lw a0, CTX_A0(sp)
    lw a1, CTX_A1(sp)
    lw a2, CTX_A2(sp)
    lw a3, CTX_A3(sp)
    lw a4, CTX_A4(sp)
    lw a5, CTX_A5(sp)
    lw a6, CTX_A6(sp)
    lw a7, CTX_A7(sp)
    lw s2, CTX_S2(sp)
    lw s3, CTX_S3(sp)
    lw s4, CTX_S4(sp)
    lw s5, CTX_S5(sp)
    lw s6, CTX_S6(sp)
    lw s7, CTX_S7(sp)
    lw s8, CTX_S8(sp)
    lw s9, CTX_S9(sp)
    lw s10, CTX_S10(sp)
    lw s11, CTX_S11(sp)
    lw t3, CTX_T3(sp)
    lw t4, CTX_T4(sp)
    lw t5, CTX_T5(sp)
    lw t6, CTX_T6(sp)
#if defined(__riscv_float_abi_single)
    flw f0,  CTX_FT0(sp)
    flw f1,  CTX_FT1(sp)
    flw f2,  CTX_FT2(sp)
    flw f3,  CTX_FT3(sp)
    flw f4,  CTX_FT4(sp)
    flw f5,  CTX_FT5(sp)
    flw f6,  CTX_FT6(sp)
    flw f7,  CTX_FT7(sp)
    flw f8,  CTX_FS0(sp)
    flw f9,  CTX_FS1(sp)
    flw f10, CTX_FA0(sp)
    flw f11, CTX_FA1(sp)
    flw f12, CTX_FA2(sp)
    flw f13, CTX_FA3(sp)
    flw f14, CTX_FA4(sp)
    flw f15, CTX_FA5(sp)
    flw f16, CTX_FA6(sp)
    flw f17, CTX_FA7(sp)
    flw f18, CTX_FS2(sp)
    flw f19, CTX_FS3(sp)
    flw f20, CTX_FS4(sp)
    flw f21, CTX_FS5(sp)
    flw f22, CTX_FS6(sp)
    flw f23, CTX_FS7(sp)
    flw f24, CTX_FS8(sp)
    flw f25, CTX_FS9(sp)
    flw f26, CTX_FS10(sp)
    flw f27, CTX_FS11(sp)
    flw f28, CTX_FT8(sp)
    flw f29, CTX_FT9(sp)
    flw f30, CTX_FT10(sp)
    flw f31, CTX_FT11(sp)
    lw  t0,  CTX_FCSR(sp)
    csrw fcsr, t0
#elif defined(__riscv_float_abi_double)
    fld f0,  CTX_FT0(sp)
    fld f1,  CTX_FT1(sp)
    fld f2,  CTX_FT2(sp)
    fld f3,  CTX_FT3(sp)
    fld f4,  CTX_FT4(sp)
    fld f5,  CTX_FT5(sp)
    fld f6,  CTX_FT6(sp)
    fld f7,  CTX_FT7(sp)
    fld f8,  CTX_FS0(sp)
    fld f9,  CTX_FS1(sp)
    fld f10, CTX_FA0(sp)
    fld f11, CTX_FA1(sp)
    fld f12, CTX_FA2(sp)
    fld f13, CTX_FA3(sp)
    fld f14, CTX_FA4(sp)
    fld f15, CTX_FA5(sp)
    fld f16, CTX_FA6(sp)
    fld f17, CTX_FA7(sp)
    fld f18, CTX_FS2(sp)
    fld f19, CTX_FS3(sp)
    fld f20, CTX_FS4(sp)
    fld f21, CTX_FS5(sp)
    fld f22, CTX_FS6(sp)
    fld f23, CTX_FS7(sp)
    fld f24, CTX_FS8(sp)
    fld f25, CTX_FS9(sp)
    fld f26, CTX_FS10(sp)
    fld f27, CTX_FS11(sp)
    fld f28, CTX_FT8(sp)
    fld f29, CTX_FT9(sp)
    fld f30, CTX_FT10(sp)
    fld f31, CTX_FT11(sp)
    lw  t0,  CTX_FCSR(sp)
    csrw fcsr, t0
#endif
    lw sp, CTX_SP(sp)
    mret
