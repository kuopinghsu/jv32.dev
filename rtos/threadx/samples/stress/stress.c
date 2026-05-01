/*
 * threadx_stress.c  --  ThreadX (Eclipse ThreadX / Azure RTOS) stress tests
 *
 * Port      : Eclipse ThreadX Linux/GCC simulator
 * Build     : make -f Makefile.threadx
 *
 * Iteration counts are intentionally SHORT so the suite completes in a
 * reasonable number of simulated clock cycles for RTL simulation.
 *
 * Tests mirror the FreeRTOS and Zephyr stress suites:
 *   1. Round-robin    -- N threads yield; counter must be exact.
 *   2. Preemption     -- High-priority ticker preempts low-priority workers.
 *   3. Mutex          -- N threads contend; counter must be exact.
 *   4. Queue          -- 2 producers + 2 consumers; checksum verified.
 *   5. Sem ping-pong  -- Two threads alternate; rounds must be exact.
 *   6. Event flags    -- N workers set bits; waiter confirms all arrive.
 *   7. Timer one-shot -- Fires exactly once.
 *   8. Timer periodic -- Fires at least 3 times.
 *
 * ThreadX priority note: lower number = higher priority (opposite of
 * Zephyr; same polarity as FreeRTOS is reversed here).
 *
 * Tick rate assumed: TX_TIMER_TICKS_PER_SECOND = 100  (10 ms per tick),
 * matching the default value in the Linux/GCC port's tx_port.h.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "tx_api.h"
#include <setjmp.h>

/* ==================================================================== */
/* Tunables -- keep small for RTL sim                                    */
/* ==================================================================== */

#define NUM_TASKS        4      /* worker threads per test              */
#define ITER_COUNT       10     /* iterations per worker                */
#define PINGPONG_ROUNDS  10     /* ping-pong hand-offs per side         */
#define Q_PRODUCERS      2      /* producer threads in queue test       */
#define Q_CONSUMERS      2      /* consumer threads in queue test       */
#define Q_MSGS_EACH      4      /* messages per producer                */
#define Q_DEPTH          16     /* queue capacity (messages)            */
#define TIMER_PERIOD_MS  10     /* timer period in milliseconds         */
#define TEST_TIMEOUT_MS  2500   /* max wait for any worker              */

/*
 * Tick conversion.
 * TX_TIMER_TICKS_PER_SECOND is 100 in the Linux/GCC port (10 ms/tick).
 * Override here if your port uses a different rate.
 */
#define TICKS_PER_SEC    100UL
#define MS_TO_TICKS(ms)  ((ULONG)((ULONG)(ms) * TICKS_PER_SEC / 1000UL))

/*
 * Thread priorities.
 * ThreadX: 0 = highest, increasing number = lower priority.
 */
#define RUNNER_PRIORITY  5
#define WORKER_PRIORITY  5   /* equal to runner for round-robin        */
#define HI_PRIO          2   /* higher than runner -> preempts it      */
#define LO_PRIO          8   /* lower than runner                      */

#define STACK_SIZE       2048  /* bytes per thread stack               */

/* ==================================================================== */
/* Minimal test harness (no external framework required)                 */
/* ==================================================================== */

static int        g_test_total  = 0;
static int        g_test_failed = 0;
static const char *g_current_test = "";
static int        g_test_ok;
static jmp_buf    g_test_jmpbuf;

static void setUp(void)    {}
static void tearDown(void) {}

#define UNITY_BEGIN() \
    do { g_test_total = 0; g_test_failed = 0; } while (0)

#define UNITY_END() ({\
    printf("\n%d Tests  %d Passed  %d Failed\n",                           \
           g_test_total, g_test_total - g_test_failed, g_test_failed);     \
    g_test_failed;                                                          \
})

#define RUN_TEST(fn) do {                                                   \
    g_current_test = #fn;                                                   \
    g_test_total++;                                                         \
    g_test_ok = 1;                                                          \
    printf("[ RUN ] %s\n", g_current_test);                               \
    setUp();                                                                \
    if (setjmp(g_test_jmpbuf) == 0) { fn(); }                              \
    tearDown();                                                             \
    if (g_test_ok)                                                          \
        printf("[  OK ] %s\n", g_current_test);                           \
    else {                                                                  \
        printf("[ FAIL] %s\n", g_current_test);                           \
        g_test_failed++;                                                    \
    }                                                                       \
} while (0)

/* Internal: print message, mark test failed, escape via longjmp. */
#define _TEST_FAIL(msg) do {                                                \
    fprintf(stderr, "%s:%d: FAIL (%s): %s\n",                              \
            __FILE__, __LINE__, g_current_test, (msg));                     \
    g_test_ok = 0;                                                          \
    longjmp(g_test_jmpbuf, 1);                                             \
} while (0)

#define TEST_ASSERT_EQUAL_MESSAGE(exp, act, msg) do {                      \
    if ((exp) != (act)) _TEST_FAIL(msg);                                    \
} while (0)

#define TEST_ASSERT_EQUAL(exp, act) do {                                   \
    if ((exp) != (act)) {                                                   \
        char _buf[128];                                                     \
        snprintf(_buf, sizeof(_buf), "Expected %d but got %d",             \
                 (int)(exp), (int)(act));                                   \
        _TEST_FAIL(_buf);                                                   \
    }                                                                       \
} while (0)

#define TEST_ASSERT_EQUAL_INT64(exp, act) do {                             \
    if ((int64_t)(exp) != (int64_t)(act)) {                                \
        char _buf[128];                                                     \
        snprintf(_buf, sizeof(_buf), "Expected %lld but got %lld",         \
                 (long long)(exp), (long long)(act));                       \
        _TEST_FAIL(_buf);                                                   \
    }                                                                       \
} while (0)

#define TEST_ASSERT_EQUAL_UINT32(exp, act) do {                            \
    if ((uint32_t)(exp) != (uint32_t)(act)) {                              \
        char _buf[128];                                                     \
        snprintf(_buf, sizeof(_buf), "Expected 0x%08X but got 0x%08X",     \
                 (unsigned)(exp), (unsigned)(act));                         \
        _TEST_FAIL(_buf);                                                   \
    }                                                                       \
} while (0)

#define TEST_ASSERT_GREATER_THAN(threshold, act) do {                      \
    if (!((act) > (threshold))) {                                           \
        char _buf[128];                                                     \
        snprintf(_buf, sizeof(_buf), "Expected value > %lld but got %lld", \
                 (long long)(threshold), (long long)(act));                 \
        _TEST_FAIL(_buf);                                                   \
    }                                                                       \
} while (0)

#define TEST_ASSERT_GREATER_OR_EQUAL(threshold, act) do {                  \
    if (!((act) >= (threshold))) {                                          \
        char _buf[128];                                                     \
        snprintf(_buf, sizeof(_buf),                                        \
                 "Expected value >= %lld but got %lld",                     \
                 (long long)(threshold), (long long)(act));                 \
        _TEST_FAIL(_buf);                                                   \
    }                                                                       \
} while (0)

/* ==================================================================== */
/* Static thread/stack pool  (reused across sequential tests)           */
/* ==================================================================== */

static TX_THREAD g_threads[NUM_TASKS];
static UCHAR     g_stacks[NUM_TASKS][STACK_SIZE];

static TX_THREAD g_extra0;
static TX_THREAD g_extra1;
static UCHAR     g_extra_stack0[STACK_SIZE];
static UCHAR     g_extra_stack1[STACK_SIZE];

/* Test runner thread (created once in tx_application_define) */
static TX_THREAD g_runner;
static UCHAR     g_runner_stack[STACK_SIZE * 4];

/* ==================================================================== */
/* Shared completion semaphore                                           */
/*                                                                       */
/* Pattern: test initialises g_done (count=0), each worker gives it     */
/* once when done, test takes it N times to join all workers.           */
/* ==================================================================== */

static TX_SEMAPHORE g_done;

static void wait_for_workers(int n)
{
    for (int i = 0; i < n; i++) {
        UINT status = tx_semaphore_get(&g_done,
                                       MS_TO_TICKS(TEST_TIMEOUT_MS));
        TEST_ASSERT_EQUAL_MESSAGE(TX_SUCCESS, status,
                                  "Timed out waiting for worker thread");
    }
}

/*
 * delete_threads -- call after wait_for_workers(); threads are in
 * TX_COMPLETED state by this point.  A 2-tick sleep lets any threads
 * that are still returning from their entry function actually complete
 * before we call tx_thread_delete().
 */
static void cleanup_threads(TX_THREAD *arr, int n)
{
    tx_thread_sleep(2);
    for (int i = 0; i < n; i++)
        tx_thread_delete(&arr[i]);
}

/* ==================================================================== */
/* TEST 1 -- Round-robin stress                                          */
/*                                                                       */
/* NUM_TASKS threads at equal priority call tx_thread_relinquish()      */
/* every iteration.  Final counter must equal NUM_TASKS x ITER_COUNT.   */
/* ==================================================================== */

static volatile int64_t s_rr_counter;

static void rr_entry(ULONG arg)
{
    (void)arg;
    for (int i = 0; i < ITER_COUNT; i++) {
        s_rr_counter++;
        tx_thread_relinquish();
    }
    tx_semaphore_put(&g_done);
}

static void test_01_roundrobin(void)
{
    s_rr_counter = 0;
    tx_semaphore_create(&g_done, "done", 0);

    for (int i = 0; i < NUM_TASKS; i++) {
        UINT rc = tx_thread_create(&g_threads[i], "RR",
                                   rr_entry, (ULONG)i,
                                   g_stacks[i], STACK_SIZE,
                                   WORKER_PRIORITY, WORKER_PRIORITY,
                                   1,              /* time_slice = 1 tick */
                                   TX_AUTO_START);
        TEST_ASSERT_EQUAL(TX_SUCCESS, rc);
    }

    wait_for_workers(NUM_TASKS);
    cleanup_threads(g_threads, NUM_TASKS);

    TEST_ASSERT_EQUAL_INT64((int64_t)NUM_TASKS * ITER_COUNT, s_rr_counter);

    tx_semaphore_delete(&g_done);
}

/* ==================================================================== */
/* TEST 2 -- Priority preemption stress                                  */
/*                                                                       */
/* High-priority (HI_PRIO) ticker fires every tick.  Low-priority       */
/* (LO_PRIO) workers run between ticks.  Both must accumulate > 0.      */
/* ==================================================================== */

static volatile int64_t  s_low_slices;
static volatile int64_t  s_high_fires;
static TX_SEMAPHORE       s_ticker_stop;
static TX_SEMAPHORE       s_low_done;

static void lo_prio_entry(ULONG arg)
{
    (void)arg;
    for (int i = 0; i < ITER_COUNT; i++) {
        s_low_slices++;
        /* Small busy delay so the high-prio ticker can preempt. */
        volatile int spin = 20;
        while (spin-- > 0) {}
    }
    tx_semaphore_put(&s_low_done);
}

static void hi_prio_entry(ULONG arg)
{
    (void)arg;
    while (tx_semaphore_get(&s_ticker_stop, TX_NO_WAIT) != TX_SUCCESS) {
        s_high_fires++;
        tx_thread_sleep(1); /* 1 tick -> preempts low workers each tick */
    }
    tx_semaphore_put(&g_done);
}

static void test_02_preemption(void)
{
    s_low_slices = 0;
    s_high_fires = 0;
    tx_semaphore_create(&g_done,        "done",  0);
    tx_semaphore_create(&s_ticker_stop, "tstop", 0);
    tx_semaphore_create(&s_low_done,    "ldone", 0);

    /* High-priority ticker -- starts immediately and preempts workers. */
    tx_thread_create(&g_extra0, "HiTick",
                     hi_prio_entry, 0,
                     g_extra_stack0, STACK_SIZE,
                     HI_PRIO, HI_PRIO,
                     TX_NO_TIME_SLICE, TX_AUTO_START);

    for (int i = 0; i < NUM_TASKS; i++) {
        tx_thread_create(&g_threads[i], "LoPre",
                         lo_prio_entry, (ULONG)i,
                         g_stacks[i], STACK_SIZE,
                         LO_PRIO, LO_PRIO,
                         TX_NO_TIME_SLICE, TX_AUTO_START);
    }

    /* Wait for all low-priority workers to finish. */
    for (int i = 0; i < NUM_TASKS; i++) {
        UINT status = tx_semaphore_get(&s_low_done,
                                       MS_TO_TICKS(TEST_TIMEOUT_MS));
        TEST_ASSERT_EQUAL_MESSAGE(TX_SUCCESS, status,
                                  "Low-priority thread timed out");
    }

    /* Signal the ticker to stop, then join it. */
    tx_semaphore_put(&s_ticker_stop);
    wait_for_workers(1);

    cleanup_threads(g_threads, NUM_TASKS);
    tx_thread_sleep(2);
    tx_thread_delete(&g_extra0);

    TEST_ASSERT_EQUAL_INT64((int64_t)NUM_TASKS * ITER_COUNT, s_low_slices);
    TEST_ASSERT_GREATER_THAN(0, s_high_fires);

    tx_semaphore_delete(&g_done);
    tx_semaphore_delete(&s_ticker_stop);
    tx_semaphore_delete(&s_low_done);
}

/* ==================================================================== */
/* TEST 3 -- Mutex contention stress                                     */
/*                                                                       */
/* NUM_TASKS threads each lock/unlock a mutex ITER_COUNT times and      */
/* relinquish after each unlock.  Final counter must be exact.          */
/* ==================================================================== */

static TX_MUTEX          s_mutex;
static volatile int64_t  s_mutex_counter;

static void mutex_entry(ULONG arg)
{
    (void)arg;
    for (int i = 0; i < ITER_COUNT; i++) {
        tx_mutex_get(&s_mutex, TX_WAIT_FOREVER);
        s_mutex_counter++;
        tx_mutex_put(&s_mutex);
        tx_thread_relinquish();
    }
    tx_semaphore_put(&g_done);
}

static void test_03_mutex_contention(void)
{
    s_mutex_counter = 0;
    tx_mutex_create(&s_mutex, "mtx", TX_INHERIT);
    tx_semaphore_create(&g_done, "done", 0);

    for (int i = 0; i < NUM_TASKS; i++) {
        tx_thread_create(&g_threads[i], "MuxT",
                         mutex_entry, (ULONG)i,
                         g_stacks[i], STACK_SIZE,
                         WORKER_PRIORITY, WORKER_PRIORITY,
                         1, TX_AUTO_START);
    }

    wait_for_workers(NUM_TASKS);
    cleanup_threads(g_threads, NUM_TASKS);

    TEST_ASSERT_EQUAL_INT64((int64_t)NUM_TASKS * ITER_COUNT, s_mutex_counter);

    tx_mutex_delete(&s_mutex);
    tx_semaphore_delete(&g_done);
}

/* ==================================================================== */
/* TEST 4 -- Queue producer / consumer stress                            */
/*                                                                       */
/* Q_PRODUCERS send Q_MSGS_EACH items each; Q_CONSUMERS drain the       */
/* queue.  Total received must equal total sent; checksum must match.   */
/*                                                                       */
/* ThreadX queue messages are measured in 32-bit words.                  */
/* Q_MSG_WORDS=1 means each message is one ULONG.                       */
/* ==================================================================== */

#define Q_MSG_WORDS  1   /* message size in ULONGs (1 ULONG = 4 bytes) */

static TX_QUEUE          s_queue;
static ULONG             s_queue_storage[Q_DEPTH * Q_MSG_WORDS];
static volatile int64_t  s_total_received;
static volatile int64_t  s_sum_sent;
static volatile int64_t  s_sum_received;
static volatile int32_t  s_producers_active;
static TX_MUTEX          s_prod_mutex;
static TX_SEMAPHORE      s_prod_done_sem;
static TX_SEMAPHORE      s_cons_done_sem;

typedef struct { int start_val; } ProdArgs;
static ProdArgs s_prod_args[Q_PRODUCERS];

static void producer_entry(ULONG arg)
{
    /* Cast ULONG back to pointer; safe on 64-bit Linux where
     * sizeof(ULONG) == sizeof(void *). */
    ProdArgs *args = (ProdArgs *)(uintptr_t)arg;

    for (int i = 0; i < Q_MSGS_EACH; i++) {
        ULONG msg = (ULONG)(args->start_val + i);
        tx_queue_send(&s_queue, &msg, TX_WAIT_FOREVER);
        if ((i % 4) == 0) tx_thread_relinquish();
    }

    tx_mutex_get(&s_prod_mutex, TX_WAIT_FOREVER);
    s_producers_active--;
    tx_mutex_put(&s_prod_mutex);

    tx_semaphore_put(&s_prod_done_sem);
}

static void consumer_entry(ULONG arg)
{
    (void)arg;
    for (;;) {
        ULONG msg = 0;
        UINT  status = tx_queue_receive(&s_queue, &msg, MS_TO_TICKS(200));

        if (status == TX_SUCCESS) {
            s_total_received++;
            s_sum_received += (int64_t)msg;
        } else {
            /* Timeout -- check if producers have all finished. */
            tx_mutex_get(&s_prod_mutex, TX_WAIT_FOREVER);
            int32_t active = s_producers_active;
            tx_mutex_put(&s_prod_mutex);

            if (active == 0) {
                ULONG enqueued = 0;
                tx_queue_info_get(&s_queue, TX_NULL, &enqueued,
                                  TX_NULL, TX_NULL, TX_NULL, TX_NULL);
                if (enqueued == 0)
                    break; /* queue drained and no more producers */
            }
        }
    }
    tx_semaphore_put(&s_cons_done_sem);
}

static void test_04_queue_producer_consumer(void)
{
    s_total_received   = 0;
    s_sum_sent         = 0;
    s_sum_received     = 0;
    s_producers_active = Q_PRODUCERS;

    tx_queue_create(&s_queue, "q", Q_MSG_WORDS,
                    s_queue_storage, sizeof(s_queue_storage));
    tx_mutex_create(&s_prod_mutex, "pmtx", TX_NO_INHERIT);
    tx_semaphore_create(&s_prod_done_sem, "pdone", 0);
    tx_semaphore_create(&s_cons_done_sem, "cdone", 0);

    /* Pre-compute expected checksum. */
    for (int p = 0; p < Q_PRODUCERS; p++) {
        s_prod_args[p].start_val = (p * Q_MSGS_EACH) + 1;
        for (int i = 0; i < Q_MSGS_EACH; i++)
            s_sum_sent += (int64_t)(s_prod_args[p].start_val + i);
    }

    /* Start consumers first so they are ready to receive. */
    tx_thread_create(&g_extra0, "Cons0",
                     consumer_entry, 0,
                     g_extra_stack0, STACK_SIZE,
                     WORKER_PRIORITY, WORKER_PRIORITY,
                     1, TX_AUTO_START);
    tx_thread_create(&g_extra1, "Cons1",
                     consumer_entry, 0,
                     g_extra_stack1, STACK_SIZE,
                     WORKER_PRIORITY, WORKER_PRIORITY,
                     1, TX_AUTO_START);

    for (int i = 0; i < Q_PRODUCERS; i++) {
        tx_thread_create(&g_threads[i], "Prod",
                         producer_entry,
                         (ULONG)(uintptr_t)&s_prod_args[i],
                         g_stacks[i], STACK_SIZE,
                         WORKER_PRIORITY, WORKER_PRIORITY,
                         1, TX_AUTO_START);
    }

    for (int i = 0; i < Q_PRODUCERS; i++) {
        UINT ok = tx_semaphore_get(&s_prod_done_sem,
                                    MS_TO_TICKS(TEST_TIMEOUT_MS));
        TEST_ASSERT_EQUAL_MESSAGE(TX_SUCCESS, ok, "Producer timed out");
    }
    for (int i = 0; i < Q_CONSUMERS; i++) {
        UINT ok = tx_semaphore_get(&s_cons_done_sem,
                                    MS_TO_TICKS(TEST_TIMEOUT_MS));
        TEST_ASSERT_EQUAL_MESSAGE(TX_SUCCESS, ok, "Consumer timed out");
    }

    cleanup_threads(g_threads, Q_PRODUCERS);
    tx_thread_sleep(2);
    tx_thread_delete(&g_extra0);
    tx_thread_delete(&g_extra1);

    TEST_ASSERT_EQUAL_INT64((int64_t)Q_PRODUCERS * Q_MSGS_EACH,
                             s_total_received);
    TEST_ASSERT_EQUAL_INT64(s_sum_sent, s_sum_received);

    tx_queue_delete(&s_queue);
    tx_mutex_delete(&s_prod_mutex);
    tx_semaphore_delete(&s_prod_done_sem);
    tx_semaphore_delete(&s_cons_done_sem);
}

/* ==================================================================== */
/* TEST 5 -- Semaphore ping-pong                                         */
/*                                                                       */
/* Thread A takes s_ping, increments counter, gives s_pong.             */
/* Thread B takes s_pong, increments counter, gives s_ping.             */
/* Every round is a context switch; both counts must be exact.          */
/* ==================================================================== */

static TX_SEMAPHORE      s_ping;
static TX_SEMAPHORE      s_pong;
static volatile int64_t  s_ping_count;
static volatile int64_t  s_pong_count;

static void ping_entry(ULONG arg)
{
    (void)arg;
    for (int i = 0; i < PINGPONG_ROUNDS; i++) {
        tx_semaphore_get(&s_ping, TX_WAIT_FOREVER);
        s_ping_count++;
        tx_semaphore_put(&s_pong);
    }
    tx_semaphore_put(&g_done);
}

static void pong_entry(ULONG arg)
{
    (void)arg;
    for (int i = 0; i < PINGPONG_ROUNDS; i++) {
        tx_semaphore_get(&s_pong, TX_WAIT_FOREVER);
        s_pong_count++;
        tx_semaphore_put(&s_ping);
    }
    tx_semaphore_put(&g_done);
}

static void test_05_semaphore_pingpong(void)
{
    s_ping_count = 0;
    s_pong_count = 0;
    tx_semaphore_create(&s_ping, "ping", 0);
    tx_semaphore_create(&s_pong, "pong", 0);
    tx_semaphore_create(&g_done, "done", 0);

    tx_thread_create(&g_extra0, "Ping",
                     ping_entry, 0,
                     g_extra_stack0, STACK_SIZE,
                     WORKER_PRIORITY, WORKER_PRIORITY,
                     TX_NO_TIME_SLICE, TX_AUTO_START);
    tx_thread_create(&g_extra1, "Pong",
                     pong_entry, 0,
                     g_extra_stack1, STACK_SIZE,
                     WORKER_PRIORITY, WORKER_PRIORITY,
                     TX_NO_TIME_SLICE, TX_AUTO_START);

    /* Kick off the first hand-off. */
    tx_semaphore_put(&s_ping);

    wait_for_workers(2);
    tx_thread_sleep(2);
    tx_thread_delete(&g_extra0);
    tx_thread_delete(&g_extra1);

    TEST_ASSERT_EQUAL_INT64(PINGPONG_ROUNDS, s_ping_count);
    TEST_ASSERT_EQUAL_INT64(PINGPONG_ROUNDS, s_pong_count);

    tx_semaphore_delete(&s_ping);
    tx_semaphore_delete(&s_pong);
    tx_semaphore_delete(&g_done);
}

/* ==================================================================== */
/* TEST 6 -- Event flags fan-out                                         */
/*                                                                       */
/* NUM_TASKS workers each set their own bit after a staggered delay.    */
/* tx_event_flags_get blocks until ALL bits arrive (TX_AND).            */
/* ==================================================================== */

#define ALL_BITS  ((ULONG)((1UL << NUM_TASKS) - 1UL))

static TX_EVENT_FLAGS_GROUP s_event_flags;

typedef struct { int bit; } EGArgs;
static EGArgs s_eg_args[NUM_TASKS];

static void eg_worker_entry(ULONG arg)
{
    EGArgs *args = (EGArgs *)(uintptr_t)arg;
    tx_thread_sleep((ULONG)(args->bit + 1)); /* stagger bit-sets */
    tx_event_flags_set(&s_event_flags, (ULONG)(1UL << args->bit), TX_OR);
    tx_semaphore_put(&g_done);
}

static void test_06_event_flags_fanout(void)
{
    tx_event_flags_create(&s_event_flags, "evfl");
    tx_semaphore_create(&g_done, "done", 0);

    for (int i = 0; i < NUM_TASKS; i++) {
        s_eg_args[i].bit = i;
        tx_thread_create(&g_threads[i], "EGWk",
                         eg_worker_entry,
                         (ULONG)(uintptr_t)&s_eg_args[i],
                         g_stacks[i], STACK_SIZE,
                         WORKER_PRIORITY, WORKER_PRIORITY,
                         TX_NO_TIME_SLICE, TX_AUTO_START);
    }

    /* Block until all bits are set. */
    ULONG actual = 0;
    UINT  status = tx_event_flags_get(&s_event_flags, ALL_BITS,
                                      TX_AND,  /* wait for ALL, no clear */
                                      &actual,
                                      MS_TO_TICKS(TEST_TIMEOUT_MS));

    TEST_ASSERT_EQUAL_MESSAGE(TX_SUCCESS, status,
                              "Event flags: timeout before all bits set");
    TEST_ASSERT_EQUAL_UINT32((uint32_t)ALL_BITS,
                             (uint32_t)(actual & ALL_BITS));

    wait_for_workers(NUM_TASKS);
    cleanup_threads(g_threads, NUM_TASKS);

    tx_event_flags_delete(&s_event_flags);
    tx_semaphore_delete(&g_done);
}

/* ==================================================================== */
/* TEST 7 -- Timer one-shot                                              */
/*                                                                       */
/* Start a one-shot timer (reschedule_ticks=0); after 3x the period     */
/* the callback must have fired exactly once.                           */
/* ==================================================================== */

static volatile uint32_t s_timer_count;
static TX_TIMER          s_timer;

static void timer_cb(ULONG param)
{
    (void)param;
    s_timer_count++;
}

static void test_07_timer_oneshot(void)
{
    s_timer_count = 0;
    ULONG period = MS_TO_TICKS(TIMER_PERIOD_MS);
    if (period == 0) period = 1; /* guard against rounding to 0 */

    tx_timer_create(&s_timer, "OneSh",
                    timer_cb, 0,
                    period,   /* initial_ticks: ticks before first fire */
                    0,        /* reschedule_ticks = 0 -> one-shot       */
                    TX_AUTO_ACTIVATE);

    /* Wait 3x the period to ensure the one-shot fires. */
    tx_thread_sleep(period * 3);

    TEST_ASSERT_EQUAL_UINT32(1U, s_timer_count);

    tx_timer_deactivate(&s_timer);
    tx_timer_delete(&s_timer);
}

/* ==================================================================== */
/* TEST 8 -- Timer periodic                                              */
/*                                                                       */
/* Auto-reloading timer runs for ~3.5 periods; callback must have       */
/* fired at least 3 times before the timer is stopped.                  */
/* ==================================================================== */

static void test_08_timer_periodic(void)
{
    s_timer_count = 0;
    ULONG period = MS_TO_TICKS(TIMER_PERIOD_MS);
    if (period == 0) period = 1;

    tx_timer_create(&s_timer, "Repet",
                    timer_cb, 0,
                    period,   /* initial_ticks  */
                    period,   /* reschedule_ticks = same -> periodic */
                    TX_AUTO_ACTIVATE);

    /* Let it run for ~3.5 periods. */
    tx_thread_sleep(period * 3 + period / 2);

    tx_timer_deactivate(&s_timer);
    tx_thread_sleep(2); /* drain any in-flight callback */

    TEST_ASSERT_GREATER_OR_EQUAL(3U, s_timer_count);

    tx_timer_delete(&s_timer);
}

/* ==================================================================== */
/* Test runner thread entry                                              */
/* ==================================================================== */

static void test_runner_entry(ULONG arg)
{
    (void)arg;

    UNITY_BEGIN();

    RUN_TEST(test_01_roundrobin);
    RUN_TEST(test_02_preemption);
    RUN_TEST(test_03_mutex_contention);
    RUN_TEST(test_04_queue_producer_consumer);
    RUN_TEST(test_05_semaphore_pingpong);
    RUN_TEST(test_06_event_flags_fanout);
    RUN_TEST(test_07_timer_oneshot);
    RUN_TEST(test_08_timer_periodic);

    int failed = UNITY_END();
    exit(failed);
}

/* ==================================================================== */
/* tx_application_define -- called by tx_kernel_enter()                 */
/*                                                                       */
/* Mandatory user function in ThreadX.  Creates the initial thread      */
/* that runs the test suite.                                            */
/* ==================================================================== */

void tx_application_define(void *first_unused_memory)
{
    (void)first_unused_memory;

    UINT rc = tx_thread_create(&g_runner, "TestRunner",
                               test_runner_entry, 0,
                               g_runner_stack, sizeof(g_runner_stack),
                               RUNNER_PRIORITY, RUNNER_PRIORITY,
                               TX_NO_TIME_SLICE, TX_AUTO_START);
    if (rc != TX_SUCCESS) {
        fprintf(stderr, "ERROR: failed to create test runner thread\n");
        exit(1);
    }
}

/* ==================================================================== */
/* Program entry                                                          */
/* ==================================================================== */

int main(void)
{
    /* tx_kernel_enter() never returns; exit() is called inside the
     * test runner thread after all tests complete. */
    tx_kernel_enter();

    fprintf(stderr, "ERROR: tx_kernel_enter returned unexpectedly\n");
    return 1;
}
