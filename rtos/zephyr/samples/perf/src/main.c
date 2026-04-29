/*
 * Copyright (c) 2026 jv32 Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * Zephyr kernel performance benchmark -- measures timing of core kernel
 * primitives in cycles.  Mirrors the FreeRTOS perf test structure:
 *
 *   1. Solicited context switch    (k_yield between equal-priority threads)
 *   2. Unsolicited context switch  (high-priority preemption)
 *   3. Semaphore                   (give/take, no contention / wake / switch)
 *   4. Mutex                       (lock/unlock, no contention / wake / switch)
 *   5. Event flags                 (set/wait, no contention / wake / switch)
 *   6. Message queue               (put/get, no contention / wake / switch)
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include "jv_platform.h"

/* ================================================================== */
/* Tunables                                                            */
/* ================================================================== */

#define TEST_ITER   3   /* repetitions per sub-test   */
#define STACK_SIZE  1024

/* ================================================================== */
/* Cycle counter                                                       */
/* ================================================================== */

static inline uint32_t get_cycles(void)
{
    uint32_t v;
    __asm__ volatile("rdcycle %0" : "=r"(v));
    return v;
}

/* ================================================================== */
/* Simple statistics accumulator                                       */
/* ================================================================== */

typedef struct { int cnt; uint32_t sum; uint32_t max; } stats_t;

static void stats_reset(stats_t *s)
{
    s->cnt = 0; s->sum = 0; s->max = 0;
}

static void stats_update(stats_t *s, uint32_t v)
{
    s->cnt++; s->sum += v;
    if (v > s->max) s->max = v;
}

static uint32_t stats_avg(const stats_t *s)
{
    return s->cnt ? s->sum / (uint32_t)s->cnt : 0;
}

/* ================================================================== */
/* Shared synchronisation objects (reused across tests)               */
/* ================================================================== */

static struct k_sem   g_sem;
static struct k_sem   g_sync_sem;   /* for higher-priority hand-off */
static struct k_mutex g_mutex;
static struct k_event g_event;
static struct k_msgq  g_msgq;
static char           g_msgq_buf[sizeof(uint32_t) * 16];

/* ================================================================== */
/* Completion semaphore (join pattern)                                 */
/* ================================================================== */

static struct k_sem g_done;

/* ================================================================== */
/* TEST 1 -- Solicited context switch (k_yield)                        */
/*                                                                     */
/* Three equal-priority threads call k_yield() and record rdcycle.    */
/* Δ between consecutive records – calibration = switch time.         */
/* ================================================================== */

#define YIELD_VALS (TEST_ITER * 3)
static uint32_t g_yield_cycles[YIELD_VALS];
static atomic_t  g_yield_idx;

static K_THREAD_STACK_ARRAY_DEFINE(yield_stacks, 3, STACK_SIZE);
static struct k_thread yield_threads[3];

static void yield_thread(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p2); ARG_UNUSED(p3);
    ARG_UNUSED(p1);

    for (int i = 0; i < TEST_ITER; i++) {
        unsigned int key = irq_lock();
        int idx = atomic_inc(&g_yield_idx);
        if (idx < YIELD_VALS)
            g_yield_cycles[idx] = get_cycles();
        irq_unlock(key);
        k_yield();
    }
    k_sem_give(&g_done);
}

static void yield_test(void)
{
    printk("\nSolicited context switch (k_yield)\n");
    printk("-----------------------------------\n");

    atomic_set(&g_yield_idx, 0);

    /* Calibrate: cost of rdcycle itself */
    unsigned int key = irq_lock();
    uint32_t c0 = get_cycles();
    uint32_t c1 = get_cycles();
    irq_unlock(key);
    uint32_t calib = c1 - c0;

    k_sem_init(&g_done, 0, 3);

    int my_prio = k_thread_priority_get(k_current_get());

    for (int i = 0; i < 3; i++) {
        k_thread_create(&yield_threads[i], yield_stacks[i], STACK_SIZE,
                        yield_thread, NULL, NULL, NULL,
                        my_prio, 0, K_NO_WAIT);
    }

    for (int i = 0; i < 3; i++)
        k_sem_take(&g_done, K_FOREVER);

    /* Compute average Δ between consecutive samples */
    stats_t s; stats_reset(&s);
    int n = (int)atomic_get(&g_yield_idx);
    for (int i = 1; i < n; i++) {
        uint32_t delta = g_yield_cycles[i] - g_yield_cycles[i - 1];
        if (delta < 100000u)    /* skip outliers from preemption */
            stats_update(&s, delta > calib ? delta - calib : 0);
    }

    printk("Solicited context switch time        : avg %u max %u cycles"
           " [calib %u]\n", (unsigned)stats_avg(&s), (unsigned)s.max,
           (unsigned)calib);
}

/* ================================================================== */
/* TEST 2 -- Unsolicited context switch (preemption)                  */
/*                                                                     */
/* Low-priority background thread continuously stamps rdcycle.        */
/* High-priority timer thread wakes and measures gap from last stamp.  */
/* ================================================================== */

static volatile uint32_t g_bg_cycle;
static volatile int      g_unsol_done;
static stats_t           g_unsol_stats;

static K_THREAD_STACK_DEFINE(bg_stack,  STACK_SIZE);
static K_THREAD_STACK_DEFINE(hi_stack,  STACK_SIZE);
static struct k_thread bg_thread, hi_thread;

static void bg_func(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    while (!g_unsol_done)
        g_bg_cycle = get_cycles();
    k_sem_give(&g_done);
}

static void hi_func(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    for (int i = 0; i < TEST_ITER; i++) {
        k_sleep(K_MSEC(1));
        uint32_t now   = get_cycles();
        uint32_t delta = now - g_bg_cycle;
        stats_update(&g_unsol_stats, delta);
    }
    g_unsol_done = 1;
    k_sem_give(&g_done);
}

static void unsolicited_test(void)
{
    printk("\nUnsolicited context switch (preemption)\n");
    printk("----------------------------------------\n");

    g_unsol_done = 0;
    stats_reset(&g_unsol_stats);
    k_sem_init(&g_done, 0, 2);

    int my_prio = k_thread_priority_get(k_current_get());

    k_thread_create(&bg_thread, bg_stack, STACK_SIZE,
                    bg_func, NULL, NULL, NULL,
                    my_prio + 1, 0, K_NO_WAIT);
    k_thread_create(&hi_thread, hi_stack, STACK_SIZE,
                    hi_func, NULL, NULL, NULL,
                    my_prio - 1, 0, K_NO_WAIT);

    k_sem_take(&g_done, K_FOREVER);
    k_sem_take(&g_done, K_FOREVER);

    /* Calibrate: cost of rdcycle */
    uint32_t c0 = get_cycles(), c1 = get_cycles();
    uint32_t calib = c1 - c0;

    printk("Unsolicited context switch time      : avg %u max %u cycles"
           " [calib %u]\n",
           (unsigned)(stats_avg(&g_unsol_stats) > calib ?
                      stats_avg(&g_unsol_stats) - calib : 0),
           (unsigned)(g_unsol_stats.max > calib ?
                      g_unsol_stats.max - calib : 0),
           (unsigned)calib);
}

/* ================================================================== */
/* TEST 3 -- Semaphore timing                                          */
/* ================================================================== */

static K_THREAD_STACK_DEFINE(sem_lo_stack, STACK_SIZE);
static K_THREAD_STACK_DEFINE(sem_hi_stack, STACK_SIZE);
static struct k_thread sem_lo_thread, sem_hi_thread;

static volatile uint32_t g_test_start;
static stats_t           g_remote_stats;

/* Lower-priority consumer: take sem, record Δ */
static void sem_get_lo(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    for (int i = 0; i < TEST_ITER; i++) {
        k_sem_take(&g_sem, K_FOREVER);
        uint32_t delta = get_cycles() - g_test_start;
        stats_update(&g_remote_stats, delta);
    }
    k_sem_give(&g_done);
}

/* Higher-priority consumer: take sem, record Δ from g_test_start */
static void sem_get_hi(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    for (int i = 0; i < TEST_ITER; i++) {
        /* Sync: wait until producer arms g_test_start */
        k_sem_take(&g_sync_sem, K_FOREVER);
        k_sem_take(&g_sem, K_FOREVER);
        uint32_t delta = get_cycles() - g_test_start;
        stats_update(&g_remote_stats, delta);
    }
    k_sem_give(&g_done);
}

static void sem_test(void)
{
    printk("\nSemaphore timing test\n");
    printk("---------------------\n");

    int my_prio = k_thread_priority_get(k_current_get());

    /* ---- (a) give with no wake, take with no contention ---- */
    k_sem_init(&g_sem, 0, TEST_ITER + 1);

    stats_t s; stats_reset(&s);
    for (int i = 0; i < TEST_ITER; i++) {
        uint32_t t0 = get_cycles();
        k_sem_give(&g_sem);
        stats_update(&s, get_cycles() - t0);
    }
    printk("Semaphore give with no wake          : avg %u max %u cycles\n",
           (unsigned)stats_avg(&s), (unsigned)s.max);

    stats_reset(&s);
    for (int i = 0; i < TEST_ITER; i++) {
        uint32_t t0 = get_cycles();
        k_sem_take(&g_sem, K_NO_WAIT);
        stats_update(&s, get_cycles() - t0);
    }
    printk("Semaphore take with no contention    : avg %u max %u cycles\n",
           (unsigned)stats_avg(&s), (unsigned)s.max);

    /* ---- (b) give wakes a lower-priority waiter ---- */
    k_sem_init(&g_sem, 0, TEST_ITER + 1);
    k_sem_init(&g_done, 0, 1);
    stats_reset(&g_remote_stats);

    k_thread_create(&sem_lo_thread, sem_lo_stack, STACK_SIZE,
                    sem_get_lo, NULL, NULL, NULL,
                    my_prio + 1, 0, K_NO_WAIT);

    stats_reset(&s);
    for (int i = 0; i < TEST_ITER; i++) {
        k_sleep(K_TICKS(1));  /* let waiter run and block */
        uint32_t t0 = get_cycles();
        k_sem_give(&g_sem);
        stats_update(&s, get_cycles() - t0);
    }
    k_sem_take(&g_done, K_FOREVER);
    printk("Semaphore give with thread wake      : avg %u max %u cycles\n",
           (unsigned)stats_avg(&s), (unsigned)s.max);

    /* ---- (c) give causes immediate context switch (higher-priority waiter) ---- */
    k_sem_init(&g_sem, 0, TEST_ITER + 1);
    k_sem_init(&g_sync_sem, 0, TEST_ITER + 1);
    k_sem_init(&g_done, 0, 1);
    stats_reset(&g_remote_stats);

    k_thread_create(&sem_hi_thread, sem_hi_stack, STACK_SIZE,
                    sem_get_hi, NULL, NULL, NULL,
                    my_prio - 1, 0, K_NO_WAIT);

    for (int i = 0; i < TEST_ITER; i++) {
        k_sleep(K_MSEC(1));  /* let high-prio block on g_sync_sem */
        g_test_start = get_cycles();
        k_sem_give(&g_sync_sem);
        k_sem_give(&g_sem);   /* triggers immediate switch */
    }
    k_sem_take(&g_done, K_FOREVER);
    printk("Semaphore give with context switch   : avg %u max %u cycles\n",
           (unsigned)stats_avg(&g_remote_stats), (unsigned)g_remote_stats.max);
}

/* ================================================================== */
/* TEST 4 -- Mutex timing                                              */
/* ================================================================== */

static K_THREAD_STACK_DEFINE(mtx_lo_stack, STACK_SIZE);
static K_THREAD_STACK_DEFINE(mtx_hi_stack, STACK_SIZE);
static struct k_thread mtx_lo_thread, mtx_hi_thread;

static void mutex_waiter_lo(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    for (int i = 0; i < TEST_ITER; i++) {
        k_mutex_lock(&g_mutex, K_FOREVER);
        k_mutex_unlock(&g_mutex);
    }
    k_sem_give(&g_done);
}

static void mutex_waiter_hi(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    for (int i = 0; i < TEST_ITER; i++) {
        k_sem_take(&g_sync_sem, K_FOREVER);
        k_mutex_lock(&g_mutex, K_FOREVER);
        uint32_t delta = get_cycles() - g_test_start;
        stats_update(&g_remote_stats, delta);
        k_mutex_unlock(&g_mutex);
    }
    k_sem_give(&g_done);
}

static void mutex_test(void)
{
    printk("\nMutex timing test\n");
    printk("-----------------\n");

    int my_prio = k_thread_priority_get(k_current_get());

    /* ---- (a) lock/unlock with no contention ---- */
    k_mutex_init(&g_mutex);

    stats_t sl, su; stats_reset(&sl); stats_reset(&su);
    for (int i = 0; i < TEST_ITER; i++) {
        uint32_t t0 = get_cycles();
        k_mutex_lock(&g_mutex, K_NO_WAIT);
        stats_update(&sl, get_cycles() - t0);

        t0 = get_cycles();
        k_mutex_unlock(&g_mutex);
        stats_update(&su, get_cycles() - t0);
    }
    printk("Mutex lock with no contention        : avg %u max %u cycles\n",
           (unsigned)stats_avg(&sl), (unsigned)sl.max);
    printk("Mutex unlock with no contention      : avg %u max %u cycles\n",
           (unsigned)stats_avg(&su), (unsigned)su.max);

    /* ---- (b) unlock wakes a lower-priority waiter ---- */
    k_mutex_init(&g_mutex);
    k_sem_init(&g_done, 0, 1);
    stats_reset(&g_remote_stats);

    k_thread_create(&mtx_lo_thread, mtx_lo_stack, STACK_SIZE,
                    mutex_waiter_lo, NULL, NULL, NULL,
                    my_prio + 1, 0, K_NO_WAIT);

    stats_t s; stats_reset(&s);
    for (int i = 0; i < TEST_ITER; i++) {
        k_mutex_lock(&g_mutex, K_FOREVER);
        k_sleep(K_TICKS(1));  /* let waiter run and block on mutex */
        uint32_t t0 = get_cycles();
        k_mutex_unlock(&g_mutex);
        stats_update(&s, get_cycles() - t0);
    }
    k_sem_take(&g_done, K_FOREVER);
    printk("Mutex unlock with thread wake        : avg %u max %u cycles\n",
           (unsigned)stats_avg(&s), (unsigned)s.max);

    /* ---- (c) unlock causes immediate switch (higher-priority waiter) ---- */
    k_mutex_init(&g_mutex);
    k_sem_init(&g_sync_sem, 0, TEST_ITER + 1);
    k_sem_init(&g_done, 0, 1);
    stats_reset(&g_remote_stats);

    k_thread_create(&mtx_hi_thread, mtx_hi_stack, STACK_SIZE,
                    mutex_waiter_hi, NULL, NULL, NULL,
                    my_prio - 1, 0, K_NO_WAIT);

    for (int i = 0; i < TEST_ITER; i++) {
        k_mutex_lock(&g_mutex, K_FOREVER);
        k_sleep(K_MSEC(1));  /* let high-prio block on g_sync_sem */
        k_sem_give(&g_sync_sem);
        /* high-prio thread now wakes, tries mutex, blocks */
        k_sleep(K_TICKS(1));
        g_test_start = get_cycles();
        k_mutex_unlock(&g_mutex);
        /* high-prio thread runs, measures Δ, unlocks */
        k_sleep(K_TICKS(1));
    }
    k_sem_take(&g_done, K_FOREVER);
    printk("Mutex unlock with context switch     : avg %u max %u cycles\n",
           (unsigned)stats_avg(&g_remote_stats), (unsigned)g_remote_stats.max);
}

/* ================================================================== */
/* TEST 5 -- Event flags timing                                        */
/* ================================================================== */

static K_THREAD_STACK_DEFINE(evt_lo_stack, STACK_SIZE);
static K_THREAD_STACK_DEFINE(evt_hi_stack, STACK_SIZE);
static struct k_thread evt_lo_thread, evt_hi_thread;

#define EVT_ALL_BITS 0xFFFFu

static void event_waiter_lo(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    for (int i = 0; i < TEST_ITER; i++) {
        k_event_wait(&g_event, EVT_ALL_BITS, true, K_FOREVER);
    }
    k_sem_give(&g_done);
}

static void event_waiter_hi(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    for (int i = 0; i < TEST_ITER; i++) {
        k_sem_take(&g_sync_sem, K_FOREVER);
        k_event_wait(&g_event, EVT_ALL_BITS, true, K_FOREVER);
        uint32_t delta = get_cycles() - g_test_start;
        stats_update(&g_remote_stats, delta);
    }
    k_sem_give(&g_done);
}

static void event_test(void)
{
    printk("\nEvent flags timing test\n");
    printk("-----------------------\n");

    int my_prio = k_thread_priority_get(k_current_get());

    k_event_init(&g_event);

    /* ---- (a) set/clear with no contention ---- */
    stats_t ss, sc; stats_reset(&ss); stats_reset(&sc);
    for (int i = 0; i < TEST_ITER; i++) {
        uint32_t t0 = get_cycles();
        k_event_set(&g_event, EVT_ALL_BITS);
        stats_update(&ss, get_cycles() - t0);

        t0 = get_cycles();
        k_event_clear(&g_event, EVT_ALL_BITS);
        stats_update(&sc, get_cycles() - t0);
    }
    printk("Event set with no contention         : avg %u max %u cycles\n",
           (unsigned)stats_avg(&ss), (unsigned)ss.max);
    printk("Event clear with no contention       : avg %u max %u cycles\n",
           (unsigned)stats_avg(&sc), (unsigned)sc.max);

    /* ---- (b) set wakes a lower-priority waiter ---- */
    k_event_init(&g_event);
    k_sem_init(&g_done, 0, 1);
    stats_reset(&g_remote_stats);

    k_thread_create(&evt_lo_thread, evt_lo_stack, STACK_SIZE,
                    event_waiter_lo, NULL, NULL, NULL,
                    my_prio + 1, 0, K_NO_WAIT);

    stats_t s; stats_reset(&s);
    for (int i = 0; i < TEST_ITER; i++) {
        k_sleep(K_TICKS(1));  /* let waiter run and block */
        uint32_t t0 = get_cycles();
        k_event_set(&g_event, EVT_ALL_BITS);
        stats_update(&s, get_cycles() - t0);
        k_sleep(K_TICKS(1));  /* let waiter consume event and re-block */
    }
    k_sem_take(&g_done, K_FOREVER);
    printk("Event set with thread wake           : avg %u max %u cycles\n",
           (unsigned)stats_avg(&s), (unsigned)s.max);

    /* ---- (c) set causes immediate switch (higher-priority waiter) ---- */
    k_event_init(&g_event);
    k_sem_init(&g_sync_sem, 0, TEST_ITER + 1);
    k_sem_init(&g_done, 0, 1);
    stats_reset(&g_remote_stats);

    k_thread_create(&evt_hi_thread, evt_hi_stack, STACK_SIZE,
                    event_waiter_hi, NULL, NULL, NULL,
                    my_prio - 1, 0, K_NO_WAIT);

    for (int i = 0; i < TEST_ITER; i++) {
        k_sleep(K_MSEC(1));    /* let high-prio block on g_sync_sem */
        k_sem_give(&g_sync_sem);
        k_sleep(K_TICKS(1));   /* let high-prio reach k_event_wait */
        g_test_start = get_cycles();
        k_event_set(&g_event, EVT_ALL_BITS);
    }
    k_sem_take(&g_done, K_FOREVER);
    printk("Event set with context switch        : avg %u max %u cycles\n",
           (unsigned)stats_avg(&g_remote_stats), (unsigned)g_remote_stats.max);
}

/* ================================================================== */
/* TEST 6 -- Message queue timing                                      */
/* ================================================================== */

static K_THREAD_STACK_DEFINE(msgq_lo_stack, STACK_SIZE);
static K_THREAD_STACK_DEFINE(msgq_hi_stack, STACK_SIZE);
static struct k_thread msgq_lo_thread, msgq_hi_thread;

static void msgq_receiver_lo(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    uint32_t msg;
    for (int i = 0; i < TEST_ITER; i++) {
        k_msgq_get(&g_msgq, &msg, K_FOREVER);
    }
    k_sem_give(&g_done);
}

static void msgq_receiver_hi(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    uint32_t msg;
    for (int i = 0; i < TEST_ITER; i++) {
        k_sem_take(&g_sync_sem, K_FOREVER);
        k_msgq_get(&g_msgq, &msg, K_FOREVER);
        uint32_t delta = get_cycles() - g_test_start;
        stats_update(&g_remote_stats, delta);
    }
    k_sem_give(&g_done);
}

static void msgq_test(void)
{
    printk("\nMessage queue timing test\n");
    printk("-------------------------\n");

    int my_prio = k_thread_priority_get(k_current_get());

    k_msgq_init(&g_msgq, g_msgq_buf, sizeof(uint32_t), 16);

    /* ---- (a) put/get with no contention ---- */
    stats_t sp, sg; stats_reset(&sp); stats_reset(&sg);
    uint32_t msg = 0xDEADBEEFu;

    for (int i = 0; i < TEST_ITER; i++) {
        uint32_t t0 = get_cycles();
        k_msgq_put(&g_msgq, &msg, K_NO_WAIT);
        stats_update(&sp, get_cycles() - t0);
    }
    for (int i = 0; i < TEST_ITER; i++) {
        uint32_t t0 = get_cycles();
        k_msgq_get(&g_msgq, &msg, K_NO_WAIT);
        stats_update(&sg, get_cycles() - t0);
    }
    printk("Message put with no contention       : avg %u max %u cycles\n",
           (unsigned)stats_avg(&sp), (unsigned)sp.max);
    printk("Message get with no contention       : avg %u max %u cycles\n",
           (unsigned)stats_avg(&sg), (unsigned)sg.max);

    /* ---- (b) put wakes a lower-priority receiver ---- */
    k_msgq_purge(&g_msgq);
    k_sem_init(&g_done, 0, 1);
    stats_reset(&g_remote_stats);

    k_thread_create(&msgq_lo_thread, msgq_lo_stack, STACK_SIZE,
                    msgq_receiver_lo, NULL, NULL, NULL,
                    my_prio + 1, 0, K_NO_WAIT);

    stats_t s; stats_reset(&s);
    for (int i = 0; i < TEST_ITER; i++) {
        k_sleep(K_TICKS(1));  /* let receiver run and block */
        uint32_t t0 = get_cycles();
        k_msgq_put(&g_msgq, &msg, K_NO_WAIT);
        stats_update(&s, get_cycles() - t0);
    }
    k_sem_take(&g_done, K_FOREVER);
    printk("Message put with thread wake         : avg %u max %u cycles\n",
           (unsigned)stats_avg(&s), (unsigned)s.max);

    /* ---- (c) put causes immediate switch (higher-priority receiver) ---- */
    k_msgq_purge(&g_msgq);
    k_sem_init(&g_sync_sem, 0, TEST_ITER + 1);
    k_sem_init(&g_done, 0, 1);
    stats_reset(&g_remote_stats);

    k_thread_create(&msgq_hi_thread, msgq_hi_stack, STACK_SIZE,
                    msgq_receiver_hi, NULL, NULL, NULL,
                    my_prio - 1, 0, K_NO_WAIT);

    for (int i = 0; i < TEST_ITER; i++) {
        k_sleep(K_MSEC(1));    /* let high-prio block on g_sync_sem */
        k_sem_give(&g_sync_sem);
        k_sleep(K_TICKS(1));   /* let high-prio reach k_msgq_get */
        g_test_start = get_cycles();
        k_msgq_put(&g_msgq, &msg, K_NO_WAIT);
    }
    k_sem_take(&g_done, K_FOREVER);
    printk("Message put with context switch      : avg %u max %u cycles\n",
           (unsigned)stats_avg(&g_remote_stats), (unsigned)g_remote_stats.max);
}

/* ================================================================== */
/* Entry point                                                         */
/* ================================================================== */

int main(void)
{
    printk("JV32 Zephyr Performance Test\n");
    printk("============================\n");

    yield_test();
    unsolicited_test();
    sem_test();
    mutex_test();
    event_test();
    msgq_test();

    printk("\nAll performance tests done.\n");
    jv_exit(0);
    return 0;
}
