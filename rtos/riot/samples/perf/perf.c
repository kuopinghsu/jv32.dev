/*
 * perf.c — RIOT OS operation timing test for JV32 RISC-V SoC.
 *
 * Mirrors the structure of the FreeRTOS perf_test:
 *   1. Yield (solicited context switch)
 *   2. Unsolicited context switch
 *   3. "Semaphore" operations (single-slot msg IPC)
 *   4. Mutex operations
 *   5. Event (thread flags) operations
 *   6. Message queue operations
 *
 * Cycle counts are read with rdcycle.  All averages are over TEST_ITER
 * iterations; the worst-case (max) is also reported.
 *
 * Priority note: in RIOT lower number = higher priority.
 */

#include <stdio.h>
#include <stdint.h>

#include "thread.h"
#include "mutex.h"
#include "msg.h"
#include "thread_flags.h"
#include "sched.h"
#include "irq.h"

#include "jv_platform.h"

/* Forward declaration for unsolicited test */
static kernel_pid_t g_unsol_hi_pid;

/* ── Configuration ──────────────────────────────────────────────────────── */

#define TEST_ITER           3u

/* RIOT: lower number = higher priority */
#define PERF_PRIO           (THREAD_PRIORITY_MAIN)
#define PRIO_LOWER(n)       ((PERF_PRIO) + (n))   /* less urgent         */
#define PRIO_HIGHER(n)      ((PERF_PRIO) - (n))   /* more urgent         */

#define WORKER_STACK_SIZE   THREAD_STACKSIZE_DEFAULT

/* Thread-flags used for event test */
#define EV_FLAG  ((thread_flags_t)0x0001u)

/* Message type tags */
#define MSG_SEM   0x5345u   /* 'SE' */
#define MSG_DONE  0xD04Eu

/* ── Cycle counter ──────────────────────────────────────────────────────── */

static inline uint32_t get_cycles(void)
{
    uint32_t c;
    __asm__ volatile("rdcycle %0" : "=r"(c));
    return c;
}

/* ── Shared state ───────────────────────────────────────────────────────── */

static kernel_pid_t g_main_pid;

static volatile uint32_t g_test_start;
static volatile uint32_t g_test_total;
static volatile uint32_t g_test_max;

/* Mutex for mutex test */
static mutex_t g_mutex = MUTEX_INIT;

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

/* ── Helper: wait for a MSG_DONE from helper thread ────────────────────── */

static void wait_done(void)
{
    msg_t m;
    msg_receive(&m);
    /* m.content.value == MSG_DONE expected */
}

static void send_done(void)
{
    msg_t m;
    m.type          = MSG_DONE;
    m.content.value = MSG_DONE;
    msg_send(&m, g_main_pid);
}

/* ══════════════════════════════════════════════════════════════════════════
 * 1. Yield test
 * ══════════════════════════════════════════════════════════════════════════ */

#define YIELD_SLOTS (TEST_ITER * 4u)
static volatile uint32_t g_yield_vals[YIELD_SLOTS];
static volatile uint32_t g_yield_idx;
static volatile uint32_t g_yield_done_a, g_yield_done_b, g_yield_done_c;

static char g_yield_stack_a[WORKER_STACK_SIZE];
static char g_yield_stack_b[WORKER_STACK_SIZE];
static char g_yield_stack_c[WORKER_STACK_SIZE];

static void *yield_fn(void *arg)
{
    volatile uint32_t *done = (volatile uint32_t *)arg;
    uint32_t i;
    for (i = 0; i < TEST_ITER; i++) {
        uint32_t idx = g_yield_idx++;
        if (idx < YIELD_SLOTS)
            g_yield_vals[idx] = get_cycles();
        thread_yield();
    }
    *done = 1u;
    return NULL;
}

static void run_yield_test(void)
{
    uint32_t i;
    stats_t s;

    printf("\nYield timing test\n-----------------\n");

    g_yield_idx = 0;
    g_yield_done_a = g_yield_done_b = g_yield_done_c = 0;

    /* Create three same-priority threads; THREAD_CREATE_WOUT_YIELD so we
     * remain in control until all three are created, then yield to them. */
    thread_create(g_yield_stack_a, sizeof(g_yield_stack_a),
                  PERF_PRIO,
                  THREAD_CREATE_WOUT_YIELD,
                  yield_fn, (void *)&g_yield_done_a, "yld_a");
    thread_create(g_yield_stack_b, sizeof(g_yield_stack_b),
                  PERF_PRIO,
                  THREAD_CREATE_WOUT_YIELD,
                  yield_fn, (void *)&g_yield_done_b, "yld_b");
    thread_create(g_yield_stack_c, sizeof(g_yield_stack_c),
                  PERF_PRIO,
                  THREAD_CREATE_WOUT_YIELD,
                  yield_fn, (void *)&g_yield_done_c, "yld_c");

    /* Lower our own priority so yield threads run first */
    sched_change_priority(thread_get_active(), PRIO_LOWER(4));
    thread_yield();

    /* Wait for all three */
    while (!(g_yield_done_a && g_yield_done_b && g_yield_done_c))
        thread_yield();

    /* Restore priority */
    sched_change_priority(thread_get_active(), PERF_PRIO);

    /* Compute solicited context switch time from consecutive timestamps */
    stats_reset(&s);
    for (i = 1; i < g_yield_idx && i < YIELD_SLOTS; i++)
        stats_update(&s, g_yield_vals[i] - g_yield_vals[i - 1]);

    stats_print("Solicited context switch time", &s);
}

/* ══════════════════════════════════════════════════════════════════════════
 * 2. Unsolicited context switch test
 *
 * main wakes hi_thread (higher priority) via thread_wakeup().  hi_thread
 * immediately preempts main — which did not request a context switch —
 * and measures the wakeup-to-running latency using the timestamp main
 * recorded just before the wakeup call.
 * ══════════════════════════════════════════════════════════════════════════ */

static volatile uint32_t g_unsol_cycles;
static volatile uint32_t g_unsol_done;
static stats_t g_unsol_stats;

static char g_unsol_hi_stack[WORKER_STACK_SIZE];

static void *unsol_hi_fn(void *arg)
{
    uint32_t i;
    (void)arg;
    for (i = 0; i < 16u; i++) {
        thread_sleep();   /* suspended until main calls thread_wakeup() */
        stats_update(&g_unsol_stats, get_cycles() - g_unsol_cycles);
    }
    g_unsol_done = 1u;
    send_done();
    return NULL;
}

static void run_unsolicited_test(void)
{
    uint32_t i, calib;

    printf("\nUnsolicited context switch timing test\n--------------------------------------\n");

    stats_reset(&g_unsol_stats);
    g_unsol_done = 0;

    /* hi_thread: higher priority; sleeps until main calls thread_wakeup() */
    g_unsol_hi_pid = thread_create(g_unsol_hi_stack, sizeof(g_unsol_hi_stack),
                  PRIO_HIGHER(1),
                  THREAD_CREATE_WOUT_YIELD,
                  unsol_hi_fn, NULL, "u_hi");
    thread_yield();   /* let hi_thread run its first thread_sleep() */

    for (i = 0; i < 16u; i++) {
        /* Record timestamp, then wake hi_thread which immediately preempts
         * main (unsolicited from main's perspective). */
        g_unsol_cycles = get_cycles();
        thread_wakeup(g_unsol_hi_pid);
        /* hi_thread has now measured the delta and gone back to sleep */
    }

    wait_done();

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

/* ══════════════════════════════════════════════════════════════════════════
 * 3. "Semaphore" test  (single-slot msg IPC acts as binary semaphore)
 * ══════════════════════════════════════════════════════════════════════════ */

/*
 * The semaphore is implemented via a 1-slot msg_init_queue on the helper
 * thread.  "put" = msg_send() to helper; "get" = msg_receive() by helper.
 * For the "no-contention" test we send/receive between main and a queue
 * buffer without involving another thread.
 */

#define SEM_Q_SIZE  8

static char g_sem_stack[WORKER_STACK_SIZE];
static char g_sem_stack2[WORKER_STACK_SIZE];

/* Helper for lower-priority wake: waits for semaphore message */
static void *sem_lo_helper_fn(void *arg)
{
    uint32_t i;
    (void)arg;
    for (i = 0; i < TEST_ITER; i++) {
        msg_t m;
        msg_receive(&m);
        uint32_t delta = get_cycles() - g_test_start;
        g_test_total += delta;
        if (delta > g_test_max) g_test_max = delta;
    }
    send_done();
    return NULL;
}

/* Helper for higher-priority wake: already blocked when main signals it */
static void *sem_hi_helper_fn(void *arg)
{
    uint32_t i;
    (void)arg;
    for (i = 0; i < TEST_ITER; i++) {
        msg_t m;
        msg_receive(&m);
        uint32_t delta = get_cycles() - g_test_start;
        g_test_total += delta;
        if (delta > g_test_max) g_test_max = delta;
    }
    send_done();
    return NULL;
}

static void run_sem_test(void)
{
    uint32_t i, start, delta, total, max;
    kernel_pid_t helper;
    msg_t m;

    printf("\nSemaphore timing test\n---------------------\n");

    /* -- Put with no wake (local queue, no other thread) -- */
    total = max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        /* We send to ourselves via the queue */
        start = get_cycles();
        m.type = MSG_SEM; m.content.value = i;
        msg_send_to_self(&m);
        delta = get_cycles() - start;
        total += delta;
        if (delta > max) max = delta;
        msg_receive(&m);   /* drain */
    }
    printf("%-44s: avg %lu max %lu cycles\n",
           "Semaphore put with no wake",
           (unsigned long)total / TEST_ITER, (unsigned long)max);

    /* -- Get with no contention (already in queue) -- */
    for (i = 0; i < TEST_ITER; i++) {
        m.type = MSG_SEM; m.content.value = i;
        msg_send_to_self(&m);
    }
    total = max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        start = get_cycles();
        msg_receive(&m);
        delta = get_cycles() - start;
        total += delta;
        if (delta > max) max = delta;
    }
    printf("%-44s: avg %lu max %lu cycles\n",
           "Semaphore get with no contention",
           (unsigned long)total / TEST_ITER, (unsigned long)max);

    /* -- Put with lower-priority wake -- */
    g_test_total = g_test_max = 0;
    helper = thread_create(g_sem_stack, sizeof(g_sem_stack),
                           PRIO_LOWER(2),
                           THREAD_CREATE_WOUT_YIELD,
                           sem_lo_helper_fn, NULL, "sem_lo");
    thread_yield();   /* let helper reach msg_receive() */

    total = max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        thread_yield();   /* ensure helper is blocked */
        start = get_cycles();
        m.type = MSG_SEM; m.content.value = i;
        msg_send(&m, helper);
        delta = get_cycles() - start;
        total += delta;
        if (delta > max) max = delta;
    }
    wait_done();
    printf("%-44s: avg %lu max %lu cycles\n",
           "Semaphore put with thread wake",
           (unsigned long)total / TEST_ITER, (unsigned long)max);

    /* -- Put with higher-priority wake + context switch -- */
    g_test_total = g_test_max = 0;
    helper = thread_create(g_sem_stack2, sizeof(g_sem_stack2),
                           PRIO_HIGHER(2),
                           THREAD_CREATE_WOUT_YIELD,
                           sem_hi_helper_fn, NULL, "sem_hi");
    thread_yield();   /* let higher-pri helper block on msg_receive() */

    for (i = 0; i < TEST_ITER; i++) {
        g_test_start = get_cycles();
        m.type = MSG_SEM; m.content.value = i;
        msg_send(&m, helper);
        /* helper preempts us here and records delta */
    }
    wait_done();
    printf("%-44s: avg %lu max %lu cycles\n",
           "Semaphore put with context switch",
           (unsigned long)g_test_total / TEST_ITER, (unsigned long)g_test_max);
}

/* ══════════════════════════════════════════════════════════════════════════
 * 4. Mutex test
 * ══════════════════════════════════════════════════════════════════════════ */

static char g_mutex_stack[WORKER_STACK_SIZE];
static char g_mutex_stack2[WORKER_STACK_SIZE];

/* Helper for mutex lock+delta test */
static void *mutex_helper_fn(void *arg)
{
    uint32_t i;
    (void)arg;
    for (i = 0; i < TEST_ITER; i++) {
        mutex_lock(&g_mutex);
        uint32_t delta = get_cycles() - g_test_start;
        g_test_total += delta;
        if (delta > g_test_max) g_test_max = delta;
        mutex_unlock(&g_mutex);
    }
    send_done();
    return NULL;
}

static void run_mutex_test(void)
{
    uint32_t i, start, delta, lock_total, lock_max, unlock_total, unlock_max;

    printf("\nMutex timing test\n-----------------\n");

    /* -- Lock / unlock with no contention -- */
    lock_total = lock_max = unlock_total = unlock_max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        start = get_cycles();
        mutex_lock(&g_mutex);
        delta = get_cycles() - start;
        lock_total += delta;
        if (delta > lock_max) lock_max = delta;

        start = get_cycles();
        mutex_unlock(&g_mutex);
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

    /* -- Unlock with lower-priority wake -- */
    g_test_total = g_test_max = 0;
    mutex_lock(&g_mutex);   /* take before creating helper */
    (void)thread_create(g_mutex_stack, sizeof(g_mutex_stack),
                        PRIO_LOWER(2),
                        THREAD_CREATE_WOUT_YIELD,
                        mutex_helper_fn, NULL, "mtx_lo");

    unlock_total = unlock_max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        thread_yield();   /* let helper block on mutex */
        start = get_cycles();
        mutex_unlock(&g_mutex);
        delta = get_cycles() - start;
        unlock_total += delta;
        if (delta > unlock_max) unlock_max = delta;
        thread_yield();   /* let helper re-take and release mutex */
        mutex_lock(&g_mutex);
    }
    mutex_unlock(&g_mutex);
    wait_done();
    printf("%-44s: avg %lu max %lu cycles\n",
           "Mutex unlock with thread wake",
           (unsigned long)unlock_total / TEST_ITER, (unsigned long)unlock_max);

    /* -- Unlock with higher-priority wake + context switch -- */
    g_test_total = g_test_max = 0;
    mutex_lock(&g_mutex);
    (void)thread_create(g_mutex_stack2, sizeof(g_mutex_stack2),
                        PRIO_HIGHER(2),
                        THREAD_CREATE_WOUT_YIELD,
                        mutex_helper_fn, NULL, "mtx_hi");
    thread_yield();   /* let higher-pri helper block on mutex */

    for (i = 0; i < TEST_ITER; i++) {
        g_test_start = get_cycles();
        mutex_unlock(&g_mutex);
        /* helper preempts, records delta, then re-locks and unlocks */
        /* wait until helper releases and we can re-take */
        mutex_lock(&g_mutex);
    }
    mutex_unlock(&g_mutex);
    wait_done();
    printf("%-44s: avg %lu max %lu cycles\n",
           "Mutex unlock with context switch",
           (unsigned long)g_test_total / TEST_ITER, (unsigned long)g_test_max);
}

/* ══════════════════════════════════════════════════════════════════════════
 * 5. Event (thread flags) test
 * ══════════════════════════════════════════════════════════════════════════ */

static char g_event_stack[WORKER_STACK_SIZE];
static char g_event_stack2[WORKER_STACK_SIZE];

/* Helper that waits for a thread flag, records latency */
static void *event_helper_fn(void *arg)
{
    uint32_t i;
    (void)arg;
    for (i = 0; i < TEST_ITER; i++) {
        thread_flags_wait_any(EV_FLAG);
        uint32_t delta = get_cycles() - g_test_start;
        g_test_total += delta;
        if (delta > g_test_max) g_test_max = delta;
        thread_flags_clear(EV_FLAG);
    }
    send_done();
    return NULL;
}

static void run_event_test(void)
{
    uint32_t i, start, delta, set_total, set_max;
    kernel_pid_t helper;

    printf("\nEvent (thread flags) timing test\n--------------------------------\n");

    /* -- Set/clear flags with no wake (on ourselves) -- */
    set_total = set_max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        start = get_cycles();
        thread_flags_set(thread_get_active(), EV_FLAG);
        delta = get_cycles() - start;
        set_total += delta;
        if (delta > set_max) set_max = delta;

        thread_flags_clear(EV_FLAG);
    }
    printf("%-44s: avg %lu max %lu cycles\n",
           "Event set with no wake",
           (unsigned long)set_total / TEST_ITER, (unsigned long)set_max);

    /* -- Set with lower-priority wake -- */
    /* ev_lo is at PRIO_LOWER(2): it won't run while main has higher priority.
     * We temporarily lower main's priority so ev_lo can run and block in
     * thread_flags_wait_any, then restore main's priority for measurements.
     * After each set, lower priority again to let ev_lo process the flag. */
    g_test_total = g_test_max = 0;
    helper = thread_create(g_event_stack, sizeof(g_event_stack),
                           PRIO_LOWER(2),
                           THREAD_CREATE_WOUT_YIELD,
                           event_helper_fn, NULL, "ev_lo");
    /* Let ev_lo reach thread_flags_wait_any */
    sched_change_priority(thread_get_active(), PRIO_LOWER(4));
    thread_yield();
    sched_change_priority(thread_get_active(), PERF_PRIO);

    set_total = set_max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        start = get_cycles();
        thread_flags_set(thread_get(helper), EV_FLAG);
        delta = get_cycles() - start;
        set_total += delta;
        if (delta > set_max) set_max = delta;
        /* Let ev_lo process the flag before next iteration */
        sched_change_priority(thread_get_active(), PRIO_LOWER(4));
        thread_yield();
        sched_change_priority(thread_get_active(), PERF_PRIO);
    }
    wait_done();
    printf("%-44s: avg %lu max %lu cycles\n",
           "Event set with thread wake",
           (unsigned long)set_total / TEST_ITER, (unsigned long)set_max);

    /* -- Set with higher-priority wake + context switch -- */
    g_test_total = g_test_max = 0;
    helper = thread_create(g_event_stack2, sizeof(g_event_stack2),
                           PRIO_HIGHER(2),
                           THREAD_CREATE_WOUT_YIELD,
                           event_helper_fn, NULL, "ev_hi");
    thread_yield();   /* let higher-pri helper block on wait */

    for (i = 0; i < TEST_ITER; i++) {
        g_test_start = get_cycles();
        thread_flags_set(thread_get(helper), EV_FLAG);
        /* helper preempts here */
        thread_yield();   /* allow helper to run next wait */
    }
    wait_done();
    printf("%-44s: avg %lu max %lu cycles\n",
           "Event set with context switch",
           (unsigned long)g_test_total / TEST_ITER, (unsigned long)g_test_max);
}

/* ══════════════════════════════════════════════════════════════════════════
 * 6. Message queue test  (multi-slot msg IPC)
 * ══════════════════════════════════════════════════════════════════════════ */

#define Q_DEPTH     16

static char g_queue_stack[WORKER_STACK_SIZE];

/* Helper that drains messages from main and records latency */
static void *queue_helper_fn(void *arg)
{
    uint32_t i;
    (void)arg;
    for (i = 0; i < TEST_ITER; i++) {
        msg_t m;
        msg_receive(&m);
        uint32_t delta = get_cycles() - g_test_start;
        g_test_total += delta;
        if (delta > g_test_max) g_test_max = delta;
    }
    send_done();
    return NULL;
}

static void run_queue_test(void)
{
    uint32_t i, start, delta, put_total, put_max, get_total, get_max;
    kernel_pid_t helper;
    msg_t m;

    printf("\nMessage queue timing test\n-------------------------\n");

    /* Use main thread's msg queue (already initialised in main) */

    /* -- Fill queue: put with no contention -- */
    put_total = put_max = 0;
    for (i = 0; i < Q_DEPTH; i++) {
        m.type = (uint16_t)i; m.content.value = i;
        start = get_cycles();
        msg_send_to_self(&m);
        delta = get_cycles() - start;
        put_total += delta;
        if (delta > put_max) put_max = delta;
    }
    printf("%-44s: avg %lu max %lu cycles\n",
           "Message put with no wake",
           (unsigned long)put_total / Q_DEPTH, (unsigned long)put_max);

    /* -- Drain queue: get with no contention -- */
    get_total = get_max = 0;
    for (i = 0; i < Q_DEPTH; i++) {
        start = get_cycles();
        msg_receive(&m);
        delta = get_cycles() - start;
        get_total += delta;
        if (delta > get_max) get_max = delta;
    }
    printf("%-44s: avg %lu max %lu cycles\n",
           "Message get with no contention",
           (unsigned long)get_total / Q_DEPTH, (unsigned long)get_max);

    /* -- Send with lower-priority wake -- */
    g_test_total = g_test_max = 0;
    helper = thread_create(g_queue_stack, sizeof(g_queue_stack),
                           PRIO_LOWER(2),
                           THREAD_CREATE_WOUT_YIELD,
                           queue_helper_fn, NULL, "q_lo");
    thread_yield();   /* let helper block on msg_receive */

    put_total = put_max = 0;
    for (i = 0; i < TEST_ITER; i++) {
        thread_yield();   /* ensure helper is blocked */
        start = get_cycles();
        m.type = (uint16_t)i; m.content.value = i;
        msg_send(&m, helper);
        delta = get_cycles() - start;
        put_total += delta;
        if (delta > put_max) put_max = delta;
    }
    wait_done();
    printf("%-44s: avg %lu max %lu cycles\n",
           "Message put with thread wake",
           (unsigned long)put_total / TEST_ITER, (unsigned long)put_max);

    /* -- Send with higher-priority wake + context switch -- */
    g_test_total = g_test_max = 0;
    /* Reuse stack */
    helper = thread_create(g_queue_stack, sizeof(g_queue_stack),
                           PRIO_HIGHER(2),
                           THREAD_CREATE_WOUT_YIELD,
                           queue_helper_fn, NULL, "q_hi");
    thread_yield();   /* let higher-pri helper block on msg_receive */

    for (i = 0; i < TEST_ITER; i++) {
        g_test_start = get_cycles();
        m.type = (uint16_t)i; m.content.value = i;
        msg_send(&m, helper);
        /* helper preempts here */
    }
    wait_done();
    printf("%-44s: avg %lu max %lu cycles\n",
           "Message put with context switch",
           (unsigned long)g_test_total / TEST_ITER, (unsigned long)g_test_max);
}

/* ══════════════════════════════════════════════════════════════════════════
 * main
 * ══════════════════════════════════════════════════════════════════════════ */

/*
 * Receive queue for the main thread — must be initialised before any other
 * thread sends us a message.
 */
#define MAIN_Q_SIZE (SEM_Q_SIZE > Q_DEPTH ? SEM_Q_SIZE : Q_DEPTH)
static msg_t g_main_queue[MAIN_Q_SIZE];

int main(void)
{
    g_main_pid = thread_getpid();
    msg_init_queue(g_main_queue, MAIN_Q_SIZE);

    printf("=== RIOT JV32 performance test ===\n");
    printf("iterations : %u\n\n", (unsigned)TEST_ITER);

    run_yield_test();
    run_unsolicited_test();
    run_sem_test();
    run_mutex_test();
    run_event_test();
    run_queue_test();

    printf("\n[PASS] RIOT perf test complete\n");
    jv_exit(0);
    return 0;
}
