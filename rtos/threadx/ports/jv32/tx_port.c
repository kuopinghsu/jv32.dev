#include <stdint.h>
#include "tx_api.h"
#include "tx_thread.h"
#include "tx_timer.h"
#include "jv_irq.h"
#include "jv_clic.h"
#include "jv_platform.h"

extern VOID *_tx_initialize_unused_memory;
extern VOID *_tx_thread_system_stack_ptr;
extern char __heap_start;
/* Defined in tx_port_asm.S: holds the interrupted PC during a preemptive
 * context switch so _tx_thread_system_return can store it in CTX_PC without
 * corrupting the caller's ra register. */
extern uint32_t _tx_jv32_preempt_pc;
static void _tx_jv32_timer_irq(uint32_t cause);
static VOID _tx_jv32_stack_guard_init(TX_THREAD *thread_ptr);

VOID _tx_jv32_stack_guard_panic(TX_THREAD *thread_ptr)
{
    _tx_thread_stack_error_handler(thread_ptr);
    jv_exit(1);
    while (1) {
    }
}

VOID _tx_timer_interrupt(VOID)
{
    UINT expired = 0u;

    _tx_timer_system_clock++;

    if (_tx_timer_time_slice != 0u) {
        _tx_timer_time_slice--;
        if (_tx_timer_time_slice == 0u) {
            _tx_timer_expired_time_slice = TX_TRUE;
            expired |= 1u;
        }
    }

    if (*_tx_timer_current_ptr != TX_NULL) {
        _tx_timer_expired = TX_TRUE;
        expired |= 2u;
    } else {
        _tx_timer_current_ptr++;
        if (_tx_timer_current_ptr == _tx_timer_list_end) {
            _tx_timer_current_ptr = _tx_timer_list_start;
        }
    }

    if (expired == 0u) {
        return;
    }

    if ((expired & 2u) != 0u) {
        _tx_timer_expiration_process();
    }

    if ((expired & 1u) != 0u) {
        _tx_thread_time_slice();
    }
}

UINT _tx_thread_interrupt_control(UINT new_posture)
{
    UINT old_posture;
    ULONG mstatus;

    __asm__ volatile("csrr %0, mstatus" : "=r"(mstatus));
    old_posture = (UINT)(mstatus & TX_INT_ENABLE);

    if (new_posture == TX_INT_DISABLE) {
        __asm__ volatile("csrc mstatus, %0" :: "r"((ULONG)TX_INT_ENABLE) : "memory");
    } else {
        __asm__ volatile("csrs mstatus, %0" :: "r"((ULONG)(new_posture & TX_INT_ENABLE)) : "memory");
    }

    return old_posture;
}

VOID _tx_initialize_low_level(VOID)
{
    ULONG sp;
    uintptr_t free_mem;

    __asm__ volatile("mv %0, sp" : "=r"(sp));
    _tx_thread_system_stack_ptr = (VOID *)sp;

    free_mem = (uintptr_t)&__heap_start;
    free_mem = (free_mem + 7u) & ~(uintptr_t)7u;
    _tx_initialize_unused_memory = (VOID *)free_mem;

    jv_irq_register(JV_CAUSE_MTI, _tx_jv32_timer_irq);
    jv_clic_timer_set_rel(TX_JV32_CLINT_CYCLES_PER_TICK);
    jv_clic_timer_irq_enable();
    jv_irq_enable();
}

VOID _tx_thread_stack_build(TX_THREAD *thread_ptr, VOID (*function_ptr)(VOID))
{
    ULONG *sp;
    uintptr_t top;
    ULONG gp;
    ULONG tp;
    UINT frame_words;

    __asm__ volatile("mv %0, gp" : "=r"(gp));
    __asm__ volatile("mv %0, tp" : "=r"(tp));

    _tx_jv32_stack_guard_init(thread_ptr);

    top = ((uintptr_t)thread_ptr->tx_thread_stack_end + 1u) & ~(uintptr_t)0xFu;

#if defined(__riscv_float_abi_single) || defined(__riscv_float_abi_double)
    frame_words = 65u;   /* 31 GPR + 33 FP + 1 PC word (CTX_PC, reuses alignment slot) */
#else
    frame_words = 32u;   /* 31 GPR + 1 PC word (CTX_PC) */
#endif

    sp = (ULONG *)(top - (frame_words * sizeof(ULONG)));

    for (UINT i = 0; i < frame_words; i++) {
        sp[i] = 0u;
    }

    sp[0] = (ULONG)function_ptr;   /* CTX_RA  — thread entry point (real ra) */
    sp[1] = (ULONG)top;            /* CTX_SP  — initial stack pointer */
    sp[2] = gp;                    /* CTX_GP */
    sp[3] = tp;                    /* CTX_TP */
    sp[frame_words - 1] = (ULONG)function_ptr;  /* CTX_PC — resume PC = entry point */
    thread_ptr->tx_thread_stack_ptr = (VOID *)sp;
}

void trap_handler(jv_trap_frame_t *frame)
{
    uint32_t mcause;
    uint32_t cause;

    mcause = frame->mcause;
    cause = mcause & 0x7fffffffu;

    if ((mcause & 0x80000000u) != 0u) {
        /* Track ISR nesting depth so ThreadX API and preemption logic can
         * distinguish thread context (_tx_thread_system_state == 0) from
         * ISR context (_tx_thread_system_state > 0). */
        _tx_thread_system_state++;

        if (cause == JV_CAUSE_MTI) {
            _tx_jv32_timer_irq(cause);
        } else {
            jv_irq_dispatch(frame);
        }

        _tx_thread_system_state--;

        /* After any interrupt (timer, PLIC, or software), check whether a
         * higher-priority thread has become ready.  Only preempt when
         * returning to thread context (system_state back to 0). */
        if ((_tx_thread_system_state == 0u) &&
            (_tx_thread_current_ptr != TX_NULL) &&
            (_tx_thread_execute_ptr != TX_NULL) &&
            (_tx_thread_current_ptr != _tx_thread_execute_ptr) &&
            (_tx_thread_preempt_disable == 0u)) {
            /* Store the interrupted PC in a global so _tx_thread_system_return
             * can save it as CTX_PC (the resume PC).  Do NOT overwrite frame->ra
             * here — corrupting ra causes an infinite loop if the interrupted
             * instruction is immediately followed by a `ret` (c.jr ra). */
            _tx_jv32_preempt_pc = frame->mepc;
            frame->mepc = (uint32_t)(uintptr_t)_tx_thread_system_return;
        }
        return;
    }

    /* Synchronous exception path. */
    if (cause == JV_EXC_STORE_FAULT) {  /* stack overflow manifests as store fault */
        if (_tx_thread_current_ptr != TX_NULL) {
            _tx_jv32_stack_guard_panic(_tx_thread_current_ptr);
            return;
        }
    }

    jv_irq_dispatch(frame);
}

static void _tx_jv32_timer_irq(uint32_t cause)
{
    (void)cause;

    jv_clic_timer_set_rel(TX_JV32_CLINT_CYCLES_PER_TICK);
    _tx_timer_interrupt();
}

static VOID _tx_jv32_stack_guard_init(TX_THREAD *thread_ptr)
{
    ULONG *low_guard;
    ULONG *high_guard;

    low_guard = (ULONG *)thread_ptr->tx_thread_stack_start;
    high_guard = (ULONG *)((((UCHAR *)thread_ptr->tx_thread_stack_end) + 1u) - sizeof(ULONG));

    *low_guard = (ULONG)TX_STACK_FILL;
    *high_guard = (ULONG)TX_STACK_FILL;
}

