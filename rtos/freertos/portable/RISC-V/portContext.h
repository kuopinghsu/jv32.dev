/*
 * FreeRTOS Kernel V11.2.0
 * Copyright (C) 2021 Amazon.com, Inc. or its affiliates. All Rights Reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of
 * this software and associated documentation files (the "Software"), to deal in
 * the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 * the Software, and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 * FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 * COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 * IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 * CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 *
 * https://www.FreeRTOS.org
 * https://github.com/FreeRTOS
 *
 */

#ifndef PORTCONTEXT_H
#define PORTCONTEXT_H

#if __riscv_xlen == 64
    #define portWORD_SIZE    8
    #define store_x          sd
    #define load_x           ld
#elif __riscv_xlen == 32
    #define store_x          sw
    #define load_x           lw
    #define portWORD_SIZE    4
#else
    #error Assembler did not define __riscv_xlen
#endif

#include "freertos_risc_v_chip_specific_extensions.h"

/* Only the standard core registers are stored by default.  Any additional
 * registers must be saved by the portasmSAVE_ADDITIONAL_REGISTERS and
 * portasmRESTORE_ADDITIONAL_REGISTERS macros - which can be defined in a chip
 * specific version of freertos_risc_v_chip_specific_extensions.h.  See the
 * notes at the top of portASM.S file. */
#ifdef __riscv_32e
    #define portCONTEXT_SIZE               ( 15 * portWORD_SIZE )
    #define portCRITICAL_NESTING_OFFSET    13
    #define portMSTATUS_OFFSET             14
#elif defined( __riscv_zcmp )
    /* ZCmp-optimised context frame (31 words = 124 bytes, same total size as the
     * standard RV32I frame).  The callee-saved registers (ra, s0-s11) are saved
     * and restored with the single-instruction cm.push / cm.pop pair; the three
     * words that cm.push leaves unused at the base of its 64-byte sub-frame hold
     * t6, xCriticalNesting, and mstatus.
     *
     * Frame layout (low address → high address, relative to sp after save):
     *
     *  sp+  0  mepc              (slot  0)  written by SAVE_EXCEPTION/INTERRUPT
     *  sp+  4  x5  (t0)         (slot  1)
     *  sp+  8  x6  (t1)         (slot  2)
     *  sp+ 12  x7  (t2)         (slot  3)
     *  sp+ 16  x10 (a0)         (slot  4)
     *  sp+ 20  x11 (a1)         (slot  5)
     *  sp+ 24  x12 (a2)         (slot  6)
     *  sp+ 28  x13 (a3)         (slot  7)
     *  sp+ 32  x14 (a4)         (slot  8)
     *  sp+ 36  x15 (a5)         (slot  9)
     *  sp+ 40  x16 (a6)         (slot 10)
     *  sp+ 44  x17 (a7)         (slot 11)
     *  sp+ 48  x28 (t3)         (slot 12)
     *  sp+ 52  x29 (t4)         (slot 13)
     *  sp+ 56  x30 (t5)         (slot 14)
     *  sp+ 60  x31 (t6)         (slot 15)  ─┐ cm.push unused
     *  sp+ 64  xCriticalNesting (slot 16)   ├─ sub-frame words
     *  sp+ 68  mstatus          (slot 17)  ─┘
     *  sp+ 72  x27 (s11)        (slot 18)  ─┐
     *  sp+ 76  x26 (s10)        (slot 19)   │
     *  sp+ 80  x25 (s9)         (slot 20)   │
     *  sp+ 84  x24 (s8)         (slot 21)   │ cm.push {ra,s0-s11},-64
     *  sp+ 88  x23 (s7)         (slot 22)   │
     *  sp+ 92  x22 (s6)         (slot 23)   │
     *  sp+ 96  x21 (s5)         (slot 24)   │
     *  sp+100  x20 (s4)         (slot 25)   │
     *  sp+104  x19 (s3)         (slot 26)   │
     *  sp+108  x18 (s2)         (slot 27)   │
     *  sp+112  x9  (s1)         (slot 28)   │
     *  sp+116  x8  (s0)         (slot 29)   │
     *  sp+120  x1  (ra)         (slot 30)  ─┘
     *
     * Save sequence:  cm.push {ra,s0-s11},-64  then  addi sp,sp,-60
     * Restore sequence:  addi sp,sp,60  then  cm.pop {ra,s0-s11},64
     */
    #define portCONTEXT_SIZE               ( 31 * portWORD_SIZE )
    #define portCRITICAL_NESTING_OFFSET    16
    #define portMSTATUS_OFFSET             17
#else
    #define portCONTEXT_SIZE               ( 31 * portWORD_SIZE )
    #define portCRITICAL_NESTING_OFFSET    29
    #define portMSTATUS_OFFSET             30
#endif

/*-----------------------------------------------------------*/

    .extern pxCurrentTCB
    .extern xISRStackTop
    .extern xCriticalNesting
    .extern pxCriticalNesting
/*-----------------------------------------------------------*/

   .macro portcontextSAVE_CONTEXT_INTERNAL
#if defined( __riscv_zcmp ) && !defined( __riscv_32e )
    /* Step 1: cm.push {ra,s0-s11},-64
     * Saves x1,x8,x9,x18-x27 onto the stack and decrements sp by 64. */
    .option arch, +zcmp
    cm.push {ra, s0-s11}, -64
    /* Step 2: allocate space for the remaining 15 caller-saved registers plus
     * t6, xCriticalNesting and mstatus that occupy the 3 unused words of the
     * cm.push sub-frame (slots 15-17). */
    addi sp, sp, -60
    /* Step 3: save caller-saved registers (task values, unmodified by cm.push). */
    store_x x5,  1 * portWORD_SIZE( sp )   /* t0  */
    store_x x6,  2 * portWORD_SIZE( sp )   /* t1  */
    store_x x7,  3 * portWORD_SIZE( sp )   /* t2  */
    store_x x10, 4 * portWORD_SIZE( sp )   /* a0  */
    store_x x11, 5 * portWORD_SIZE( sp )   /* a1  */
    store_x x12, 6 * portWORD_SIZE( sp )   /* a2  */
    store_x x13, 7 * portWORD_SIZE( sp )   /* a3  */
    store_x x14, 8 * portWORD_SIZE( sp )   /* a4  */
    store_x x15, 9 * portWORD_SIZE( sp )   /* a5  */
    store_x x16, 10 * portWORD_SIZE( sp )  /* a6  */
    store_x x17, 11 * portWORD_SIZE( sp )  /* a7  */
    store_x x28, 12 * portWORD_SIZE( sp )  /* t3  */
    store_x x29, 13 * portWORD_SIZE( sp )  /* t4  */
    store_x x30, 14 * portWORD_SIZE( sp )  /* t5  */
    store_x x31, 15 * portWORD_SIZE( sp )  /* t6  */
    /* Step 4: save xCriticalNesting using t0 as temp (t0 is already on the stack). */
    load_x t0, xCriticalNesting
    store_x t0, portCRITICAL_NESTING_OFFSET * portWORD_SIZE( sp )
    /* Step 5: save mstatus. */
    csrr t0, mstatus
    store_x t0, portMSTATUS_OFFSET * portWORD_SIZE( sp )

    portasmSAVE_ADDITIONAL_REGISTERS /* Defined in freertos_risc_v_chip_specific_extensions.h to save any registers unique to the RISC-V implementation. */

    load_x t0, pxCurrentTCB          /* Load pxCurrentTCB. */
    beq t0, x0, 1f
    store_x sp, 0 ( t0 )             /* Write sp to first TCB member. */
1:
#else /* Standard (non-ZCmp) save path. */
    addi sp, sp, -portCONTEXT_SIZE
    store_x x1,  1 * portWORD_SIZE( sp )
    store_x x5,  2 * portWORD_SIZE( sp )
    store_x x6,  3 * portWORD_SIZE( sp )
    store_x x7,  4 * portWORD_SIZE( sp )
    store_x x8,  5 * portWORD_SIZE( sp )
    store_x x9,  6 * portWORD_SIZE( sp )
    store_x x10, 7 * portWORD_SIZE( sp )
    store_x x11, 8 * portWORD_SIZE( sp )
    store_x x12, 9 * portWORD_SIZE( sp )
    store_x x13, 10 * portWORD_SIZE( sp )
    store_x x14, 11 * portWORD_SIZE( sp )
    store_x x15, 12 * portWORD_SIZE( sp )
#ifndef __riscv_32e
    store_x x16, 13 * portWORD_SIZE( sp )
    store_x x17, 14 * portWORD_SIZE( sp )
    store_x x18, 15 * portWORD_SIZE( sp )
    store_x x19, 16 * portWORD_SIZE( sp )
    store_x x20, 17 * portWORD_SIZE( sp )
    store_x x21, 18 * portWORD_SIZE( sp )
    store_x x22, 19 * portWORD_SIZE( sp )
    store_x x23, 20 * portWORD_SIZE( sp )
    store_x x24, 21 * portWORD_SIZE( sp )
    store_x x25, 22 * portWORD_SIZE( sp )
    store_x x26, 23 * portWORD_SIZE( sp )
    store_x x27, 24 * portWORD_SIZE( sp )
    store_x x28, 25 * portWORD_SIZE( sp )
    store_x x29, 26 * portWORD_SIZE( sp )
    store_x x30, 27 * portWORD_SIZE( sp )
    store_x x31, 28 * portWORD_SIZE( sp )
#endif /* ifndef __riscv_32e */

    load_x t0, xCriticalNesting                                   /* Load the value of xCriticalNesting into t0. */
    store_x t0, portCRITICAL_NESTING_OFFSET * portWORD_SIZE( sp ) /* Store the critical nesting value to the stack. */

    csrr t0, mstatus /* Required for MPIE bit. */
    store_x t0, portMSTATUS_OFFSET * portWORD_SIZE( sp )

    portasmSAVE_ADDITIONAL_REGISTERS /* Defined in freertos_risc_v_chip_specific_extensions.h to save any registers unique to the RISC-V implementation. */

    load_x t0, pxCurrentTCB          /* Load pxCurrentTCB. */
    beq t0, x0, 1f
    store_x sp, 0 ( t0 )             /* Write sp to first TCB member. */
1:
#endif /* __riscv_zcmp */
   .endm
/*-----------------------------------------------------------*/

   .macro portcontextSAVE_EXCEPTION_CONTEXT
    portcontextSAVE_CONTEXT_INTERNAL
    csrr a0, mcause
    csrr a1, mepc
    addi a1, a1, 4          /* Synchronous so update exception return address to the instruction after the instruction that generated the exception. */
    store_x a1, 0 ( sp )    /* Save updated exception return address. */
    load_x t0, pxCurrentTCB
    beq t0, x0, 1f
    load_x sp, xISRStackTop /* Switch to ISR stack. */
1:
   .endm
/*-----------------------------------------------------------*/

   .macro portcontextSAVE_INTERRUPT_CONTEXT
    portcontextSAVE_CONTEXT_INTERNAL
    csrr a0, mcause
    csrr a1, mepc
    store_x a1, 0 ( sp )    /* Asynchronous interrupt so save unmodified exception return address. */
    load_x t0, pxCurrentTCB
    beq t0, x0, 1f
    load_x sp, xISRStackTop /* Switch to ISR stack. */
1:
   .endm
/*-----------------------------------------------------------*/

   .macro portcontextRESTORE_CONTEXT
    load_x t1, pxCurrentTCB /* Load pxCurrentTCB. */
    beq t1, x0, 1f
    load_x sp, 0 ( t1 )     /* Read sp from first TCB member. */
1:

    /* Load mepc with the address of the instruction in the task to run next. */
    load_x t0, 0 ( sp )
    csrw mepc, t0

    /* Defined in freertos_risc_v_chip_specific_extensions.h to restore any registers unique to the RISC-V implementation. */
    portasmRESTORE_ADDITIONAL_REGISTERS

    /* Load mstatus with the interrupt enable bits used by the task. */
    load_x t0, portMSTATUS_OFFSET * portWORD_SIZE( sp )
    csrw mstatus, t0                                             /* Required for MPIE bit. */

    load_x t0, portCRITICAL_NESTING_OFFSET * portWORD_SIZE( sp ) /* Obtain xCriticalNesting value for this task from task's stack. */
    load_x t1, pxCriticalNesting                                 /* Load the address of xCriticalNesting into t1. */
    beq t1, x0, 2f
    store_x t0, 0 ( t1 )                                         /* Restore the critical nesting value for this task. */
2:

#if defined( __riscv_zcmp ) && !defined( __riscv_32e )
    /* Restore the caller-saved registers from the lower region of the ZCmp frame. */
    load_x x5,  1 * portWORD_SIZE( sp )   /* t0  */
    load_x x6,  2 * portWORD_SIZE( sp )   /* t1  */
    load_x x7,  3 * portWORD_SIZE( sp )   /* t2  */
    load_x x10, 4 * portWORD_SIZE( sp )   /* a0  */
    load_x x11, 5 * portWORD_SIZE( sp )   /* a1  */
    load_x x12, 6 * portWORD_SIZE( sp )   /* a2  */
    load_x x13, 7 * portWORD_SIZE( sp )   /* a3  */
    load_x x14, 8 * portWORD_SIZE( sp )   /* a4  */
    load_x x15, 9 * portWORD_SIZE( sp )   /* a5  */
    load_x x16, 10 * portWORD_SIZE( sp )  /* a6  */
    load_x x17, 11 * portWORD_SIZE( sp )  /* a7  */
    load_x x28, 12 * portWORD_SIZE( sp )  /* t3  */
    load_x x29, 13 * portWORD_SIZE( sp )  /* t4  */
    load_x x30, 14 * portWORD_SIZE( sp )  /* t5  */
    load_x x31, 15 * portWORD_SIZE( sp )  /* t6  */
    /* Undo the addi sp,-60 from the save path; sp is now at the post-cm.push position. */
    addi sp, sp, 60
    /* cm.pop {ra,s0-s11},64
     * Restores x1,x8,x9,x18-x27 from the stack and increments sp by 64. */
    .option arch, +zcmp
    cm.pop {ra, s0-s11}, 64
#else /* Standard (non-ZCmp) restore path. */
    load_x x1,  1 * portWORD_SIZE( sp )
    load_x x5,  2 * portWORD_SIZE( sp )
    load_x x6,  3 * portWORD_SIZE( sp )
    load_x x7,  4 * portWORD_SIZE( sp )
    load_x x8,  5 * portWORD_SIZE( sp )
    load_x x9,  6 * portWORD_SIZE( sp )
    load_x x10, 7 * portWORD_SIZE( sp )
    load_x x11, 8 * portWORD_SIZE( sp )
    load_x x12, 9 * portWORD_SIZE( sp )
    load_x x13, 10 * portWORD_SIZE( sp )
    load_x x14, 11 * portWORD_SIZE( sp )
    load_x x15, 12 * portWORD_SIZE( sp )
#ifndef __riscv_32e
    load_x x16, 13 * portWORD_SIZE( sp )
    load_x x17, 14 * portWORD_SIZE( sp )
    load_x x18, 15 * portWORD_SIZE( sp )
    load_x x19, 16 * portWORD_SIZE( sp )
    load_x x20, 17 * portWORD_SIZE( sp )
    load_x x21, 18 * portWORD_SIZE( sp )
    load_x x22, 19 * portWORD_SIZE( sp )
    load_x x23, 20 * portWORD_SIZE( sp )
    load_x x24, 21 * portWORD_SIZE( sp )
    load_x x25, 22 * portWORD_SIZE( sp )
    load_x x26, 23 * portWORD_SIZE( sp )
    load_x x27, 24 * portWORD_SIZE( sp )
    load_x x28, 25 * portWORD_SIZE( sp )
    load_x x29, 26 * portWORD_SIZE( sp )
    load_x x30, 27 * portWORD_SIZE( sp )
    load_x x31, 28 * portWORD_SIZE( sp )
#endif /* ifndef __riscv_32e */
    addi sp, sp, portCONTEXT_SIZE
#endif /* __riscv_zcmp */

    mret
   .endm
/*-----------------------------------------------------------*/

#endif /* PORTCONTEXT_H */
