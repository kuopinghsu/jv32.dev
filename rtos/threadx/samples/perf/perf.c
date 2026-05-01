/*
 * perf.c — ThreadX operation timing test for JV32 RISC-V SoC.
 *
 * Mirrors the structure of the FreeRTOS perf_test:
 *   1. Yield (solicited context switch)
 *   2. Unsolicited context switch
 *   3. Semaphore operations
 *   4. Mutex operations
 *   5. Event flag operations
 *   6. Message queue operations
 *
 * Cycle counts are read with rdcycle.  All averages are over TEST_ITER
 * iterations; the worst-case (max) is also reported.
 */

#include <stdio.h>
#include <stdint.h>
#include "tx_api.h"
#include "jv_platform.h"

/* ── Configuration ──────────────────────────────────────────────────────── */

#define TEST_ITER           3u
#define PERF_PRIORITY       8u        /* baseline priority for perf threads  */
#define STACK_WORDS         512u
#define WAIT_TICKS          TX_WAIT_FOREVER
#define QUEUE_MSG_WORDS     4u        /* 4 x uint32_t per message            */
#define QUEUE_DEPTH         16u

/* ── Cycle counter ──────────────────────────────────────────────────────── */

static inline uint32_t get_cycles(void)
{
    uint32_t c;
    __asm__ volatile("rdcycle %0" : "=r"(c));
    return c;
}

/* ── Statistics helper ──────────────────────────────────────────────────── */

typedef struct { uint32_t cnt; uint32_t sum; uint32_t max; } stats_t;

static void stats_reset(stats_t *s)  { s->cnt = s->sum = 0; s->max = 0; }
static void stats_update(stats_t *s, uint32_t v)
{
    s->cnt++;
    s->sum += v;
    if (v > s->max) s->max = v;
}
static void stats_print(const char *label, const stats_t *s)
{
    printf("%-44s: avg %lu max %lu cycles\n",
           label,
           (unsigned long)(s->cnt ? s->sum / s->cnt : 0u),
           (unsigned long)s->max);
}

/* ── Shared primitives (allocated in tx_application_define) ─────────────── */

static TX_SEMAPHORE g_sem;
static TX_SEMAPHORE g_sync_sem;     /* helper semaphore for high-pri tests */
static TX_MUTEX     g_mutex;
static TX_EVENT_FLAGS_GROUP g_events;
static TX_QUEUE     g_queue;

static volatile uint32_t g_test_start;   /* timestamp set just before signal */
static volatile uint32_t g_test_total;
static volatile uint32_t g_test_max;
static volatile uint32_t g_helper_done;

/* ── Helper thread dispatch ──────────────────────────────────────────────── */

static void (*g_helper_dispatch_fn)(void);

/* Forward declarations for helper worker functions */
static void do_sem_help(void);
static void do_mutex_help(void);
static void do_event_help(void);
static void do_queue_help(void);

static void helper_entry(ULONG arg)
{
    (void)arg;
    if (g_helper_dispatch_fn)
        g_helper_dispatch_fn();
    g_helper_done = 1u;
    tx_thread_terminate(tx_thread_identify());
    while (1) {}
}

/* Storage for queues */
static ULONG g_queue_storage[QUEUE_DEPTH * QUEUE_MSG_WORDS];

/* ── Stacks ─────────────────────────────────────────────────────────────── */

static ULONG g_ctrl_stack[STACK_WORDS];
static ULONG g_helper_stack[STACK_WORDS];
static ULONG g_yield_stack_a[STACK_WORDS];
static ULONG g_yield_stack_b[STACK_WORDS];
static ULONG g_yield_stack_c[STACK_WORDS];
static ULONG g_unsol_bg_stack[STACK_WORDS];
static ULONG g_unsol_hi_stack[STACK_WORDS];

static TX_THREAD g_ctrl_thread;
static TX_THREAD g_helper_thread;
static TX_THREAD g_yield_a_thread;
static TX_THREAD g_yield_b_thread;
static TX_THREAD g_yield_c_thread;
static TX_THREAD g_unsol_bg_thread;
static TX_THREAD g_unsol_hi_thread;

/* Terminate, reset, reprioritise, and restart the helper thread. */
static void helper_restart(void (*fn)(void), UINT priority)
{
    g_helper_done        = 0u;
    g_test_total         = 0u;
    g_test_max           = 0u;
    g_helper_dispatch_fn = fn;
    tx_thread_terminate(&g_helper_thread);
    tx_thread_reset(&g_helper_thread);
    tx_thread_priority_change(&g_helper_thread, priority, NULL);
    tx_thread_resume(&g_helper_thread);
}

/* ── Yield test ─────────────────────────────────────────────────────────── */

#define YIELD_SLOTS (TEST_ITER * 4u)
static volatile uint32_t g_yield_vals[YIELD_SLOTS];
static volatile uint32_t g_yield_idx;
static volatile uint32_t g_yield_done_a, g_yield_done_b, g_yield_done_c;

static void yield_entry(ULONG arg)
{
    volatile uint32_t *done = (volatile uint32_t *)arg;
    uint32_t i;
    for (i = 0; i < TEST_ITER; i++) {
        uint32_t idx = g_yield_idx++;
        if (idx < YIELD_SLOTS)
            g_yield_vals[idx] = get_cycles();
        tx_thread_relinquish();
    }
    *done = 1u;
    tx_thread_suspend(tx_thread_identify());
}

static void run_yield_test(void)
{
    uint32_t i;
    stats_t s;

    printf("\nYield timing test\n-----------------\n");

    g_yield_idx = 0;
    g_yield_done_a = g_yield_done_b = g_yield_done_c = 0;

    tx_thread_resume(&g_yield_a_thread);
    tx_thread_resume(&g_yield_b_thread);
    tx_thread_resume(&g_yield_c_thread);

    /* Wait for all three to finish */
    while (!(g_yield_done_a && g_yield_done_b && g_yield_done_c))
        tx_thread_sleep(1);

    /* Compute solicited context switch time from consecutive timestamps */
    stats_reset(&s);
    for (i = 1; i < g_yield_idx && i < YIELD_SLOTS; i++)
        stats_update(&s, g_yield_vals[i] - g_yield_vals[i - 1]);

    stats_print("Solicited context switch time", &s);
}

/* ── Unsolicited context switch test ────────────────────────────────────── */

static volatile uint32_t g_unsol_cycles;
static volatile uint32_t g_unsol_done;
static stats_t g_unsol_stats;

static void unsol_bg_entry(ULONG arg)
{
    (void)arg;
    while (!g_unsol_done)
        g_unsol_cycles = get_cycles();
    tx_thread_suspend(tx_thread_identify());
}

static void unsol_hi_entry(ULONG arg)
{
    uint32_t i;
    (void)arg;
    for (i = 0; i < 16u; i++) {
        tx_thread_sleep(1);
        stats_update(&g_unsol_stats, get_cycles() - g_unsol_cycles);
    }
    g_unsol_done = 1u;
    tx_thread_suspend(tx_thread_identify());
}

static void run_unsolicited_test(void)
{
    uint32_t calib;

    printf("\nUnsolicited context switch timing test\n--------------------------------------\n");

    stats_reset(&g_unsol_stats);
    g_unsol_done = 0;

    tx_thread_resume(&g_unsol_bg_thread);
    tx_thread_resume(&g_unsol_hi_thread);

    while (!g_unsol_done)
        tx_thread_sleep(2);

    calib = get_cycles();
    calib = get_cycles() - calib;

    printf("%-44s: avg %lu max %lu cycles [calib %lu]\n",
           "Unsolicited context switch time",
           (unsigned long)(g_unsol_stats.cnt
               ? (g_unsol_stats.sum / g_unsol_stats.cnt) - calib : 0u),
           (unsigned long)(g_unsol_stats.max > calib
               ? g_unsol_stats.max - calib : 0u),
           (unsigned long)calib);
}

/* ── Semaphore helper worker ─────────────────────────────────────────────── */

static void do_sem_help(void)
{
    uint32_t i;
    for (i = 0; i < TEST_ITER; i++) {
        tx_semaphore_get(&g_sem, WAIT_TICKS);
        uint32_t delta = get_cycles() - g_test_start;
        g_test_total += delta;
        if (delta > g_test_max) g_test_max = delta;
    }
}

/* ── Semaphore test ─────────────────────────────────────────────────────── */

static void run_sem_test(void)
{
    uint32_t i, start, delta, total, max;

    printf("\nSemaphore timing test\n---------------------\n");

    /* Put with no wake */
    total = max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        start = get_cycles();
        tx_semaphore_put(&g_sem);
        delta = get_cycles() - start;
        total += delta;
        if (delta > max) max = delta;
    }
    printf("%-44s: avg %lu max %lu cycles\n",
           "Semaphore put with no wake", (unsigned long)total / TEST_ITER, (unsigned long)max);

    /* Get with no contention (drain the count we just built up) */
    total = max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        start = get_cycles();
        tx_semaphore_get(&g_sem, WAIT_TICKS);
        delta = get_cycles() - start;
        total += delta;
        if (delta > max) max = delta;
    }
    printf("%-44s: avg %lu max %lu cycles\n",
           "Semaphore get with no contention", (unsigned long)total / TEST_ITER, (unsigned long)max);

    /* Put with lower-priority wake: launch helper at lower priority */
    helper_restart(do_sem_help, PERF_PRIORITY + 2u);

    total = max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        tx_thread_sleep(1);          /* let helper block on semaphore */
        start = get_cycles();
        tx_semaphore_put(&g_sem);
        delta = get_cycles() - start;
        total += delta;
        if (delta > max) max = delta;
    }
    while (!g_helper_done) tx_thread_sleep(1);

    printf("%-44s: avg %lu max %lu cycles\n",
           "Semaphore put with thread wake", (unsigned long)total / TEST_ITER, (unsigned long)max);

    /* Put with higher-priority wake + context switch */
    helper_restart(do_sem_help, PERF_PRIORITY - 2u);
    tx_thread_sleep(1);              /* let helper block on semaphore */

    for (i = 0; i < TEST_ITER; i++) {
        g_test_start = get_cycles();
        tx_semaphore_put(&g_sem);
        /* helper preempts us here and records the delta */
    }
    while (!g_helper_done) tx_thread_sleep(1);

    printf("%-44s: avg %lu max %lu cycles\n",
           "Semaphore put with context switch",
           (unsigned long)g_test_total / TEST_ITER, (unsigned long)g_test_max);
}

/* ── Mutex helper worker ──────────────────────────────────────────────────── */

static void do_mutex_help(void)
{
    uint32_t i;
    for (i = 0; i < TEST_ITER; i++) {
        tx_mutex_get(&g_mutex, WAIT_TICKS);
        uint32_t delta = get_cycles() - g_test_start;
        g_test_total += delta;
        if (delta > g_test_max) g_test_max = delta;
        tx_mutex_put(&g_mutex);
    }
}

/* ── Mutex test ─────────────────────────────────────────────────────────── */

static void run_mutex_test(void)
{
    uint32_t i, start, delta, lock_total, lock_max, unlock_total, unlock_max;

    printf("\nMutex timing test\n-----------------\n");

    /* Lock/unlock with no contention */
    lock_total = lock_max = unlock_total = unlock_max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        start = get_cycles();
        tx_mutex_get(&g_mutex, WAIT_TICKS);
        delta = get_cycles() - start;
        lock_total += delta;
        if (delta > lock_max) lock_max = delta;

        start = get_cycles();
        tx_mutex_put(&g_mutex);
        delta = get_cycles() - start;
        unlock_total += delta;
        if (delta > unlock_max) unlock_max = delta;
    }
    printf("%-44s: avg %lu max %lu cycles\n",
           "Mutex lock with no contention",
           (unsigned long)lock_total / TEST_ITER, (unsigned long)lock_max);
    printf("%-44s: avg %lu max %lu cycles\n",
           "Mutex unlock with no contention",
           (unsigned long)unlock_total / TEST_ITER, (unsigned long)unlock_max);

    /* Unlock with lower-priority wake */
    helper_restart(do_mutex_help, PERF_PRIORITY + 2u);

    unlock_total = unlock_max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        tx_mutex_get(&g_mutex, WAIT_TICKS);
        tx_thread_sleep(1);          /* let helper block on mutex */
        start = get_cycles();
        tx_mutex_put(&g_mutex);
        delta = get_cycles() - start;
        unlock_total += delta;
        if (delta > unlock_max) unlock_max = delta;
    }
    while (!g_helper_done) tx_thread_sleep(1);

    printf("%-44s: avg %lu max %lu cycles\n",
           "Mutex unlock with thread wake",
           (unsigned long)unlock_total / TEST_ITER, (unsigned long)unlock_max);

    /* Unlock with higher-priority wake + context switch */
    helper_restart(do_mutex_help, PERF_PRIORITY - 2u);

    for (i = 0; i < TEST_ITER; i++) {
        tx_mutex_get(&g_mutex, WAIT_TICKS);
        tx_thread_sleep(1);          /* let helper block on mutex */
        g_test_start = get_cycles();
        tx_mutex_put(&g_mutex);
        /* helper preempts here */
        tx_thread_sleep(1);          /* wait for helper to release mutex */
    }
    while (!g_helper_done) tx_thread_sleep(1);

    printf("%-44s: avg %lu max %lu cycles\n",
           "Mutex unlock with context switch",
           (unsigned long)g_test_total / TEST_ITER, (unsigned long)g_test_max);
}

/* ── Event helper worker ─────────────────────────────────────────────────── */

static void do_event_help(void)
{
    uint32_t i;
    ULONG actual;
    for (i = 0; i < TEST_ITER; i++) {
        tx_event_flags_get(&g_events, 0xFFFFu, TX_AND, &actual, WAIT_TICKS);
        uint32_t delta = get_cycles() - g_test_start;
        g_test_total += delta;
        if (delta > g_test_max) g_test_max = delta;
        tx_event_flags_set(&g_events, 0u, TX_AND);   /* clear all flags */
    }
}

/* ── Event test ─────────────────────────────────────────────────────────── */

static void run_event_test(void)
{
    uint32_t i, start, delta, set_total, set_max, clr_total, clr_max;
    ULONG    actual;

    printf("\nEvent timing test\n-----------------\n");

    /* Make sure flags start clear */
    tx_event_flags_set(&g_events, 0u, TX_AND);

    /* Set / clear with no wake */
    set_total = set_max = clr_total = clr_max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        start = get_cycles();
        tx_event_flags_set(&g_events, 0xFFFFu, TX_OR);
        delta = get_cycles() - start;
        set_total += delta;
        if (delta > set_max) set_max = delta;

        start = get_cycles();
        tx_event_flags_set(&g_events, 0u, TX_AND);   /* clear all flags */
        delta = get_cycles() - start;
        clr_total += delta;
        if (delta > clr_max) clr_max = delta;
    }
    printf("%-44s: avg %lu max %lu cycles\n",
           "Event set with no wake",
           (unsigned long)set_total / TEST_ITER, (unsigned long)set_max);
    printf("%-44s: avg %lu max %lu cycles\n",
           "Event clear with no wake",
           (unsigned long)clr_total / TEST_ITER, (unsigned long)clr_max);

    /* Set with lower-priority wake */
    helper_restart(do_event_help, PERF_PRIORITY + 2u);

    set_total = set_max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        tx_event_flags_set(&g_events, 0u, TX_AND);   /* clear all flags */
        tx_thread_sleep(1);          /* let helper block on event */
        start = get_cycles();
        tx_event_flags_set(&g_events, 0xFFFFu, TX_OR);
        delta = get_cycles() - start;
        set_total += delta;
        if (delta > set_max) set_max = delta;
        tx_thread_sleep(1);   /* yield so lower-priority helper can clear flags */
    }
    while (!g_helper_done) tx_thread_sleep(1);

    printf("%-44s: avg %lu max %lu cycles\n",
           "Event set with thread wake",
           (unsigned long)set_total / TEST_ITER, (unsigned long)set_max);

    /* Set with higher-priority wake + context switch */
    tx_event_flags_set(&g_events, 0u, TX_AND);   /* clear all flags */
    helper_restart(do_event_help, PERF_PRIORITY - 2u);
    tx_thread_sleep(1);              /* let helper block on event */

    for (i = 0; i < TEST_ITER; i++) {
        g_test_start = get_cycles();
        tx_event_flags_set(&g_events, 0xFFFFu, TX_OR);
        /* helper preempts here */
        tx_thread_sleep(1);          /* wait for helper to clear and re-block */
    }
    while (!g_helper_done) tx_thread_sleep(1);

    printf("%-44s: avg %lu max %lu cycles\n",
           "Event set with context switch",
           (unsigned long)g_test_total / TEST_ITER, (unsigned long)g_test_max);
}

/* ── Queue helper worker ─────────────────────────────────────────────────── */

static void do_queue_help(void)
{
    uint32_t i;
    ULONG msg[QUEUE_MSG_WORDS];
    for (i = 0; i < TEST_ITER; i++) {
        tx_queue_receive(&g_queue, msg, WAIT_TICKS);
        uint32_t delta = get_cycles() - g_test_start;
        g_test_total += delta;
        if (delta > g_test_max) g_test_max = delta;
    }
}

/* ── Queue test ─────────────────────────────────────────────────────────── */

static void run_queue_test(void)
{
    uint32_t i, start, delta, put_total, put_max, get_total, get_max;
    ULONG msg[QUEUE_MSG_WORDS] = {0xDEADBEEFu, 0xCAFEBABEu, 0u, 0u};

    printf("\nMessage queue timing test\n-------------------------\n");

    /* Fill queue */
    put_total = put_max = 0;
    for (i = 0; i < QUEUE_DEPTH; i++) {
        start = get_cycles();
        tx_queue_send(&g_queue, msg, TX_NO_WAIT);
        delta = get_cycles() - start;
        put_total += delta;
        if (delta > put_max) put_max = delta;
    }
    printf("%-44s: avg %lu max %lu cycles\n",
           "Message put with no wake",
           (unsigned long)put_total / QUEUE_DEPTH, (unsigned long)put_max);

    /* Drain queue */
    get_total = get_max = 0;
    for (i = 0; i < QUEUE_DEPTH; i++) {
        start = get_cycles();
        tx_queue_receive(&g_queue, msg, TX_NO_WAIT);
        delta = get_cycles() - start;
        get_total += delta;
        if (delta > get_max) get_max = delta;
    }
    printf("%-44s: avg %lu max %lu cycles\n",
           "Message get with no contention",
           (unsigned long)get_total / QUEUE_DEPTH, (unsigned long)get_max);

    /* Send with lower-priority wake */
    helper_restart(do_queue_help, PERF_PRIORITY + 2u);

    put_total = put_max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        tx_thread_sleep(1);          /* let helper block on queue */
        start = get_cycles();
        tx_queue_send(&g_queue, msg, TX_NO_WAIT);
        delta = get_cycles() - start;
        put_total += delta;
        if (delta > put_max) put_max = delta;
    }
    while (!g_helper_done) tx_thread_sleep(1);

    printf("%-44s: avg %lu max %lu cycles\n",
           "Message put with thread wake",
           (unsigned long)put_total / TEST_ITER, (unsigned long)put_max);

    /* Send with higher-priority wake + context switch */
    helper_restart(do_queue_help, PERF_PRIORITY - 2u);
    tx_thread_sleep(1);              /* let helper block on queue */

    for (i = 0; i < TEST_ITER; i++) {
        g_test_start = get_cycles();
        tx_queue_send(&g_queue, msg, TX_NO_WAIT);
        /* helper preempts here */
        tx_thread_sleep(1);
    }
    while (!g_helper_done) tx_thread_sleep(1);

    printf("%-44s: avg %lu max %lu cycles\n",
           "Message put with context switch",
           (unsigned long)g_test_total / TEST_ITER, (unsigned long)g_test_max);
}

/* ── Controller thread ───────────────────────────────────────────────────── */

static void ctrl_entry(ULONG arg)
{
    (void)arg;

    printf("=== ThreadX JV32 performance test ===\n");
    printf("iterations : %u\n\n", (unsigned)TEST_ITER);

    run_yield_test();
    run_unsolicited_test();
    run_sem_test();
    run_mutex_test();
    run_event_test();
    run_queue_test();

    printf("\n[PASS] ThreadX perf test complete\n");
    jv_exit(0);
    while (1) {}
}

/* ── tx_application_define ───────────────────────────────────────────────── */

void tx_application_define(void *first_unused_memory)
{
    (void)first_unused_memory;

    /* Primitives */
    tx_semaphore_create(&g_sem,       "sem",    0u);
    tx_semaphore_create(&g_sync_sem,  "sync",   0u);
    tx_mutex_create(&g_mutex,         "mutex",  TX_NO_INHERIT);
    tx_event_flags_create(&g_events,  "events");
    tx_queue_create(&g_queue, "queue",
                    QUEUE_MSG_WORDS,
                    g_queue_storage,
                    sizeof(g_queue_storage));

    /* Helper thread: uses dispatch entry; restarted via helper_restart() per sub-test */
    tx_thread_create(&g_helper_thread, "helper",
                     helper_entry, 0u,
                     g_helper_stack, sizeof(g_helper_stack),
                     PERF_PRIORITY + 2u, PERF_PRIORITY + 2u,
                     TX_NO_TIME_SLICE, TX_DONT_START);

    /* Yield threads (same priority as ctrl to get round-robin) */
    tx_thread_create(&g_yield_a_thread, "yield_a",
                     yield_entry, (ULONG)&g_yield_done_a,
                     g_yield_stack_a, sizeof(g_yield_stack_a),
                     PERF_PRIORITY, PERF_PRIORITY,
                     TX_NO_TIME_SLICE, TX_DONT_START);
    tx_thread_create(&g_yield_b_thread, "yield_b",
                     yield_entry, (ULONG)&g_yield_done_b,
                     g_yield_stack_b, sizeof(g_yield_stack_b),
                     PERF_PRIORITY, PERF_PRIORITY,
                     TX_NO_TIME_SLICE, TX_DONT_START);
    tx_thread_create(&g_yield_c_thread, "yield_c",
                     yield_entry, (ULONG)&g_yield_done_c,
                     g_yield_stack_c, sizeof(g_yield_stack_c),
                     PERF_PRIORITY, PERF_PRIORITY,
                     TX_NO_TIME_SLICE, TX_DONT_START);

    /* Unsolicited switch threads */
    tx_thread_create(&g_unsol_bg_thread, "unsol_bg",
                     unsol_bg_entry, 0u,
                     g_unsol_bg_stack, sizeof(g_unsol_bg_stack),
                     PERF_PRIORITY + 1u, PERF_PRIORITY + 1u,
                     TX_NO_TIME_SLICE, TX_DONT_START);
    tx_thread_create(&g_unsol_hi_thread, "unsol_hi",
                     unsol_hi_entry, 0u,
                     g_unsol_hi_stack, sizeof(g_unsol_hi_stack),
                     PERF_PRIORITY - 1u, PERF_PRIORITY - 1u,
                     TX_NO_TIME_SLICE, TX_DONT_START);

    /* Controller */
    tx_thread_create(&g_ctrl_thread, "ctrl",
                     ctrl_entry, 0u,
                     g_ctrl_stack, sizeof(g_ctrl_stack),
                     PERF_PRIORITY, PERF_PRIORITY,
                     TX_NO_TIME_SLICE, TX_AUTO_START);
}

int main(void)
{
    tx_kernel_enter();
    return 0;
}
