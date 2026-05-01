/*
 * Simplified kernel_init() for the JV32 RIOT standalone build.
 *
 * This replaces the upstream core/lib/init.c which drags in the full
 * auto_init / stdio_base / periph/pm module graph.  For the JV32 port
 * we only need the essentials: idle thread, main thread, and the
 * context-switch exit to hand control to the scheduler.
 *
 * SPDX-License-Identifier: LGPL-2.1-only
 */

#include <stdint.h>
#include <stdio.h>

#include "irq.h"
#include "sched.h"
#include "thread.h"
#include "kernel_init.h"

#define ENABLE_DEBUG 0
#include "debug.h"

/* Stack areas for the mandatory RIOT idle and main threads */
static char _main_stack[THREAD_STACKSIZE_MAIN];
static char _idle_stack[THREAD_STACKSIZE_DEFAULT];

/* RIOT version string (normally provided by the build system) */
#ifndef RIOT_VERSION
#define RIOT_VERSION "custom"
#endif

extern int main(void);

/*
 * idle_thread: lowest-priority thread; runs WFI whenever nothing else is
 * ready.  RIOT requires this thread to be present.
 */
static void *idle_thread(void *arg)
{
    (void)arg;
    while (1) {
        __asm__ volatile("wfi");
        /* Give the scheduler a chance to run a higher-priority thread
         * that may have been unblocked by an ISR.               */
        thread_yield();
    }
    return NULL;
}

/*
 * main_trampoline: wraps application main() so that thread_create can
 * treat it as a standard RIOT thread function.
 */
static void *main_trampoline(void *arg)
{
    (void)arg;
    printf("main(): This is RIOT! (Version: " RIOT_VERSION ")\n");
    main();
    /* If main() returns, idle here rather than crashing */
    while (1) {
        thread_yield();
    }
    return NULL;
}

/*
 * kernel_init: create idle and main threads, then transfer control to the
 * RIOT scheduler.  Called from the RISC-V startup code (start.S) after
 * cpu_init() and board_init().
 */
void kernel_init(void)
{
    irq_disable();

    /* Idle thread — lowest priority (SCHED_PRIO_LEVELS-1) */
    thread_create(_idle_stack, sizeof(_idle_stack),
                  SCHED_PRIO_LEVELS - 1,
                  THREAD_CREATE_WOUT_YIELD,
                  idle_thread, NULL, "idle");

    /* Main thread — application entry point */
    thread_create(_main_stack, sizeof(_main_stack),
                  THREAD_PRIORITY_MAIN,
                  THREAD_CREATE_WOUT_YIELD,
                  main_trampoline, NULL, "main");

    /* Hand control to the highest-priority runnable thread */
    cpu_switch_context_exit();

    /* UNREACHABLE */
    while (1) {}
}
