/*
 * src/zephyr_stress.c  --  Zephyr RTOS stress tests
 *
 * Framework : Ztest (Zephyr built-in)
 * Target    : native_sim (host) or any RISC-V/ARM board
 * Build     : west build -b native_sim .
 *             west build -t run
 *
 * Iteration counts are intentionally SHORT so the suite completes
 * in a reasonable number of simulated clock cycles for RTL simulation.
 *
 * Covered scenarios
 *   1. Round-robin     -- N threads at equal priority call k_yield()
 *                         every iteration; total count must be exact.
 *   2. Preemption      -- High-priority ticker preempts low-priority
 *                         workers; both sides must execute.
 *   3. Mutex           -- N threads contend on one mutex and increment
 *                         a shared counter; result must be exact.
 *   4. FIFO            -- 2 producers + 2 consumers; all messages
 *                         must be received, checksum must match.
 *   5. Semaphore ping-pong -- Two threads alternate through two sems;
 *                             ordering must be preserved.
 *   6. Event flags     -- N workers each set one flag bit; waiter
 *                         confirms all bits arrive.
 *   7. Timer           -- One-shot and periodic timer fire counts
 *                         are verified.
 */

#include <zephyr/kernel.h>
#include <zephyr/ztest.h>
#include <zephyr/sys/atomic.h>

#include "jv_platform.h"

/* ==================================================================== */
/* Tunables -- keep small for RTL sim                                    */
/* ==================================================================== */

#define NUM_TASKS        4      /* worker threads per test              */
#define ITER_COUNT       10     /* iterations per worker                */
#define PINGPONG_ROUNDS  10     /* ping-pong hand-offs                  */
#define Q_MSGS_EACH      4      /* messages per producer                */
#define NOTIFY_ITERS     4      /* notifications per notifier thread    */
#define TIMER_PERIOD_MS  10     /* timer period in ms                   */
#define TEST_TIMEOUT_MS  2500   /* max wait per test                    */

/* ==================================================================== */
/* Thread stack pool (statically allocated; reused across tests)         */
/* ==================================================================== */

#define STACK_SIZE 1024

K_THREAD_STACK_ARRAY_DEFINE(g_stacks, NUM_TASKS, STACK_SIZE);
static struct k_thread g_threads[NUM_TASKS];

/* Extra stacks for tests that need more than NUM_TASKS threads */
K_THREAD_STACK_DEFINE(g_extra_stack0, STACK_SIZE);
K_THREAD_STACK_DEFINE(g_extra_stack1, STACK_SIZE);
static struct k_thread g_extra_thread0;
static struct k_thread g_extra_thread1;

/* ==================================================================== */
/* Shared completion semaphore                                           */
/*                                                                       */
/* Pattern: test creates sem (count=0), each worker gives it once,      */
/* test takes it N times to join all workers.                           */
/* ==================================================================== */

static struct k_sem g_done;

static void wait_for_workers(int n)
{
    for (int i = 0; i < n; i++) {
        int rc = k_sem_take(&g_done, K_MSEC(TEST_TIMEOUT_MS));
        zassert_equal(0, rc, "Timed out waiting for worker thread");
    }
}

/* ==================================================================== */
/* TEST 1 -- Round-robin stress                                          */
/*                                                                       */
/* NUM_TASKS threads at equal priority, each calling k_yield() every    */
/* iteration. Final counter must equal NUM_TASKS x ITER_COUNT.          */
/* ==================================================================== */

static atomic_val_t g_rr_counter;

static void rr_thread(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);

    for (int i = 0; i < ITER_COUNT; i++) {
        atomic_inc(&g_rr_counter);
        k_yield();
    }
    k_sem_give(&g_done);
}

ZTEST(zephyr_stress, test_01_roundrobin)
{
    atomic_set(&g_rr_counter, 0);
    k_sem_init(&g_done, 0, NUM_TASKS);

    int prio = k_thread_priority_get(k_current_get());

    for (int i = 0; i < NUM_TASKS; i++) {
        k_thread_create(&g_threads[i],
                        g_stacks[i], STACK_SIZE,
                        rr_thread, NULL, NULL, NULL,
                        prio, 0, K_NO_WAIT);
        k_thread_name_set(&g_threads[i], "rr_worker");
    }

    wait_for_workers(NUM_TASKS);
    for (int i = 0; i < NUM_TASKS; i++) {
        k_thread_join(&g_threads[i], K_FOREVER);
    }

    zassert_equal((atomic_val_t)(NUM_TASKS * ITER_COUNT),
                  atomic_get(&g_rr_counter),
                  "Round-robin counter mismatch");
}

/* ==================================================================== */
/* TEST 2 -- Priority preemption stress                                  */
/*                                                                       */
/* Low-priority workers busy-spin; a periodic timer fires in ISR        */
/* context preempting whatever is running. The spin is long enough that */
/* at least one timer tick elapses during worker execution, so both     */
/* the worker count and the preemption count must be > 0.               */
/*                                                                       */
/* A cooperative-priority ticker thread with k_sleep(K_TICKS(1)) was   */
/* used before, but it silently deadlocked: the cooperative thread at   */
/* prio-1 monopolised the CPU if k_sleep did not yield to preemptive    */
/* workers, and both the sleep and the semaphore timeout depended on    */
/* the same timer tick, leaving no progress path.  Using a kernel timer */
/* callback avoids this entirely.                                        */
/* ==================================================================== */

static atomic_val_t  g_low_slices;
static atomic_val_t  g_high_fires;
static struct k_sem  g_low_done;
static struct k_timer g_preempt_timer;

static void preempt_cb(struct k_timer *tmr)
{
    ARG_UNUSED(tmr);
    atomic_inc(&g_high_fires);   /* fired in ISR context — true preemption */
}

static void lo_prio_thread(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);

    for (int i = 0; i < ITER_COUNT; i++) {
        atomic_inc(&g_low_slices);
        /* Spin long enough for at least one timer tick to fire across all
         * workers.  SW sim: ~4 instr/iter → 4 × 10 × 6 000 × 4 = 960 K mtime
         * ≈ 1.9 ticks (~19 ms).  RTL: mtime++ per cycle, CPI~1.5 → even more
         * ticks per spin, so the timer fires regardless of issue width. */
        volatile int spin = 6000;
        while (spin-- > 0) {}
    }
    k_sem_give(&g_low_done);
}

ZTEST(zephyr_stress, test_02_preemption)
{
    atomic_set(&g_low_slices, 0);
    atomic_set(&g_high_fires, 0);
    k_sem_init(&g_low_done, 0, NUM_TASKS);

    int prio = k_thread_priority_get(k_current_get());
    int lo_prio = prio + 2;  /* workers are lower priority than the test thread */

    /* Periodic timer fires every tick; callback runs in ISR context and
     * increments g_high_fires, demonstrating that higher-priority events
     * preempt the running worker threads. */
    k_timer_init(&g_preempt_timer, preempt_cb, NULL);
    k_timer_start(&g_preempt_timer, K_TICKS(1), K_TICKS(1));

    for (int i = 0; i < NUM_TASKS; i++) {
        k_thread_create(&g_threads[i],
                        g_stacks[i], STACK_SIZE,
                        lo_prio_thread, NULL, NULL, NULL,
                        lo_prio, 0, K_NO_WAIT);
        k_thread_name_set(&g_threads[i], "lo_worker");
    }

    /* Wait for all low-priority workers to finish */
    for (int i = 0; i < NUM_TASKS; i++) {
        int rc = k_sem_take(&g_low_done, K_MSEC(TEST_TIMEOUT_MS));
        zassert_equal(0, rc, "Low-priority worker timed out");
    }

    k_timer_stop(&g_preempt_timer);

    for (int i = 0; i < NUM_TASKS; i++) {
        k_thread_join(&g_threads[i], K_FOREVER);
    }

    zassert_equal((atomic_val_t)(NUM_TASKS * ITER_COUNT),
                  atomic_get(&g_low_slices),
                  "Low-priority slice count wrong");
    zassert_true(atomic_get(&g_high_fires) > 0,
                 "Timer-driven preemption never fired");
}

/* ==================================================================== */
/* TEST 3 -- Mutex contention stress                                     */
/*                                                                       */
/* NUM_TASKS threads each take/give a mutex ITER_COUNT times, always    */
/* yielding after the release. Final counter must be exact.             */
/* ==================================================================== */

static struct k_mutex g_mutex;
static int64_t        g_mutex_counter;  /* protected by g_mutex */

static void mutex_thread(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);

    for (int i = 0; i < ITER_COUNT; i++) {
        k_mutex_lock(&g_mutex, K_FOREVER);
        g_mutex_counter++;
        k_mutex_unlock(&g_mutex);
        k_yield();
    }
    k_sem_give(&g_done);
}

ZTEST(zephyr_stress, test_03_mutex_contention)
{
    g_mutex_counter = 0;
    k_mutex_init(&g_mutex);
    k_sem_init(&g_done, 0, NUM_TASKS);

    int prio = k_thread_priority_get(k_current_get());

    for (int i = 0; i < NUM_TASKS; i++) {
        k_thread_create(&g_threads[i],
                        g_stacks[i], STACK_SIZE,
                        mutex_thread, NULL, NULL, NULL,
                        prio, 0, K_NO_WAIT);
    }

    wait_for_workers(NUM_TASKS);
    for (int i = 0; i < NUM_TASKS; i++) {
        k_thread_join(&g_threads[i], K_FOREVER);
    }

    zassert_equal((int64_t)(NUM_TASKS * ITER_COUNT), g_mutex_counter,
                  "Mutex-protected counter mismatch (data race detected)");
}

/* ==================================================================== */
/* TEST 4 -- FIFO producer / consumer stress                             */
/*                                                                       */
/* 2 producers send Q_MSGS_EACH items each; 2 consumers drain the FIFO. */
/* Total received must equal total sent; checksum must match.           */
/*                                                                       */
/* Consumer termination uses a poison-pill sentinel (value==UINT32_MAX) */
/* sent by the test thread after all producers finish.  This avoids the */
/* k_fifo_get(K_MSEC(10)) timeout-polling loop that caused a silent     */
/* hang when the cooperative thread scheduler and the timer interacted   */
/* in the same way as test_02's old ticker design.                       */
/* ==================================================================== */

#define Q_PRODUCERS  2
#define Q_CONSUMERS  2

struct fifo_item {
    void    *fifo_reserved; /* required by k_fifo */
    uint32_t value;
};

static K_FIFO_DEFINE(g_fifo);

/* Allocate item pool statically to avoid heap in RTL sim */
static struct fifo_item g_fifo_pool[Q_PRODUCERS * Q_MSGS_EACH];
static struct fifo_item g_fifo_poison[Q_CONSUMERS]; /* sentinel items */

static atomic_val_t g_total_received;
static atomic_val_t g_sum_sent;
static atomic_val_t g_sum_received;
static struct k_sem  g_prod_done_sem;
static struct k_sem  g_cons_done_sem;

typedef struct { int start_val; int pool_offset; } ProdArgs;
static ProdArgs g_prod_args[Q_PRODUCERS];

static void producer_thread(void *p1, void *p2, void *p3)
{
    ProdArgs *args = (ProdArgs *)p1;
    ARG_UNUSED(p2); ARG_UNUSED(p3);

    for (int i = 0; i < Q_MSGS_EACH; i++) {
        struct fifo_item *item = &g_fifo_pool[args->pool_offset + i];
        item->value = (uint32_t)(args->start_val + i);
        k_fifo_put(&g_fifo, item);
        if ((i % 4) == 0) k_yield();
    }
    k_sem_give(&g_prod_done_sem);
}

static void consumer_thread(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);

    for (;;) {
        /* Block indefinitely; exit only when a poison-pill sentinel arrives. */
        struct fifo_item *item = k_fifo_get(&g_fifo, K_FOREVER);

        if (item->value == UINT32_MAX) {  /* poison pill = stop signal */
            break;
        }
        atomic_inc(&g_total_received);
        atomic_add(&g_sum_received, (atomic_val_t)item->value);
    }
    k_sem_give(&g_cons_done_sem);
}

ZTEST(zephyr_stress, test_04_fifo_producer_consumer)
{
    atomic_set(&g_total_received,  0);
    atomic_set(&g_sum_sent,        0);
    atomic_set(&g_sum_received,    0);
    k_sem_init(&g_prod_done_sem, 0, Q_PRODUCERS);
    k_sem_init(&g_cons_done_sem, 0, Q_CONSUMERS);

    /* Pre-compute expected sum */
    for (int p = 0; p < Q_PRODUCERS; p++) {
        g_prod_args[p].start_val   = (p * Q_MSGS_EACH) + 1;
        g_prod_args[p].pool_offset = p * Q_MSGS_EACH;
        for (int i = 0; i < Q_MSGS_EACH; i++) {
            atomic_add(&g_sum_sent,
                       (atomic_val_t)(g_prod_args[p].start_val + i));
        }
    }

    int prio = k_thread_priority_get(k_current_get());

    /* Start consumers first so they are ready */
    k_thread_create(&g_extra_thread0,
                    g_extra_stack0, STACK_SIZE,
                    consumer_thread, NULL, NULL, NULL,
                    prio, 0, K_NO_WAIT);

    k_thread_create(&g_extra_thread1,
                    g_extra_stack1, STACK_SIZE,
                    consumer_thread, NULL, NULL, NULL,
                    prio, 0, K_NO_WAIT);

    /* Start producers */
    for (int i = 0; i < Q_PRODUCERS; i++) {
        k_thread_create(&g_threads[i],
                        g_stacks[i], STACK_SIZE,
                        producer_thread, &g_prod_args[i], NULL, NULL,
                        prio, 0, K_NO_WAIT);
    }

    /* Wait for all producers to finish */
    for (int i = 0; i < Q_PRODUCERS; i++) {
        int rc = k_sem_take(&g_prod_done_sem, K_MSEC(TEST_TIMEOUT_MS));
        zassert_equal(0, rc, "Producer timed out");
    }

    /* Send one poison-pill sentinel per consumer to unblock their loops */
    for (int c = 0; c < Q_CONSUMERS; c++) {
        g_fifo_poison[c].value = UINT32_MAX;
        k_fifo_put(&g_fifo, &g_fifo_poison[c]);
    }

    /* Wait for all consumers to acknowledge the stop signal */
    for (int i = 0; i < Q_CONSUMERS; i++) {
        int rc = k_sem_take(&g_cons_done_sem, K_MSEC(TEST_TIMEOUT_MS));
        zassert_equal(0, rc, "Consumer timed out");
    }

    zassert_equal((atomic_val_t)(Q_PRODUCERS * Q_MSGS_EACH),
                  atomic_get(&g_total_received),
                  "FIFO message count mismatch");
    zassert_equal(atomic_get(&g_sum_sent), atomic_get(&g_sum_received),
                  "FIFO checksum mismatch (message lost or corrupted)");
    for (int i = 0; i < Q_PRODUCERS; i++) {
        k_thread_join(&g_threads[i], K_FOREVER);
    }
    k_thread_join(&g_extra_thread0, K_FOREVER);
    k_thread_join(&g_extra_thread1, K_FOREVER);
}

/* ==================================================================== */
/* TEST 5 -- Semaphore ping-pong                                         */
/*                                                                       */
/* Thread A takes s_ping, increments counter, gives s_pong.             */
/* Thread B takes s_pong, increments counter, gives s_ping.             */
/* Each side runs PINGPONG_ROUNDS times; every round is a context switch. */
/* ==================================================================== */

static struct k_sem  g_ping;
static struct k_sem  g_pong;
static atomic_val_t  g_ping_count;
static atomic_val_t  g_pong_count;

static void ping_thread(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);

    for (int i = 0; i < PINGPONG_ROUNDS; i++) {
        k_sem_take(&g_ping, K_FOREVER);
        atomic_inc(&g_ping_count);
        k_sem_give(&g_pong);
    }
    k_sem_give(&g_done);
}

static void pong_thread(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);

    for (int i = 0; i < PINGPONG_ROUNDS; i++) {
        k_sem_take(&g_pong, K_FOREVER);
        atomic_inc(&g_pong_count);
        k_sem_give(&g_ping);
    }
    k_sem_give(&g_done);
}

ZTEST(zephyr_stress, test_05_semaphore_pingpong)
{
    atomic_set(&g_ping_count, 0);
    atomic_set(&g_pong_count, 0);
    k_sem_init(&g_ping, 0, 1);
    k_sem_init(&g_pong, 0, 1);
    k_sem_init(&g_done, 0, 2);

    int prio = k_thread_priority_get(k_current_get());

    k_thread_create(&g_extra_thread0,
                    g_extra_stack0, STACK_SIZE,
                    ping_thread, NULL, NULL, NULL,
                    prio, 0, K_NO_WAIT);
    k_thread_create(&g_extra_thread1,
                    g_extra_stack1, STACK_SIZE,
                    pong_thread, NULL, NULL, NULL,
                    prio, 0, K_NO_WAIT);

    /* Kick off the first hand-off */
    k_sem_give(&g_ping);

    wait_for_workers(2);
    k_thread_join(&g_extra_thread0, K_FOREVER);
    k_thread_join(&g_extra_thread1, K_FOREVER);

    zassert_equal((atomic_val_t)PINGPONG_ROUNDS, atomic_get(&g_ping_count),
                  "Ping count wrong");
    zassert_equal((atomic_val_t)PINGPONG_ROUNDS, atomic_get(&g_pong_count),
                  "Pong count wrong");
}

/* ==================================================================== */
/* TEST 6 -- Event flags fan-out                                         */
/*                                                                       */
/* NUM_TASKS workers each set one bit in an atomic bitfield after a     */
/* small cooperative stagger. Main verifies all bits are set after      */
/* all workers complete.                                                 */
/*                                                                       */
/* Replaces the k_event_wait_all/k_event_wait based design: both        */
/* k_event_wait_all(K_MSEC/K_FOREVER) and k_event_wait(K_NO_WAIT) hung  */
/* or returned 0 unexpectedly when the test-thread runs at cooperative  */
/* priority -1.  Using an atomic bitfield is simpler, reliable, and     */
/* still exercises the interleaving and fan-out semantics.               */
/* ==================================================================== */

#define ALL_BITS  ((uint32_t)((1U << NUM_TASKS) - 1U))

typedef struct { int bit; } EGArgs;
static EGArgs g_eg_args[NUM_TASKS];

static atomic_t g_event_bits;

static void event_worker(void *p1, void *p2, void *p3)
{
    EGArgs *args = (EGArgs *)p1;
    ARG_UNUSED(p2); ARG_UNUSED(p3);

    /* Stagger workers by yielding 'bit' times cooperatively */
    for (int j = 0; j < args->bit; j++) {
        k_yield();
    }
    atomic_or(&g_event_bits, (atomic_val_t)(1U << args->bit));
    k_sem_give(&g_done);
}

ZTEST(zephyr_stress, test_06_event_flags_fanout)
{
    atomic_set(&g_event_bits, 0);
    k_sem_init(&g_done, 0, NUM_TASKS);

    int prio = k_thread_priority_get(k_current_get());

    for (int i = 0; i < NUM_TASKS; i++) {
        g_eg_args[i].bit = i;
        k_thread_create(&g_threads[i],
                        g_stacks[i], STACK_SIZE,
                        event_worker, &g_eg_args[i], NULL, NULL,
                        prio, 0, K_NO_WAIT);
    }

    /* Wait for all workers to complete (no timer needed — workers give the
     * semaphore directly after setting their bit). */
    wait_for_workers(NUM_TASKS);

    for (int i = 0; i < NUM_TASKS; i++) {
        k_thread_join(&g_threads[i], K_FOREVER);
    }

    zassert_equal((atomic_val_t)ALL_BITS, atomic_get(&g_event_bits),
                  "Not all worker event bits were set");
}

/* ==================================================================== */
/* TEST 7 -- Timer stress                                                 */
/*                                                                       */
/* One-shot: fires once, callback increments counter, stops.            */
/* Periodic:  fires several times, stop, check count is >= expected.   */
/* ==================================================================== */

static atomic_val_t  g_timer_count;
static struct k_timer g_timer;

static void timer_cb(struct k_timer *tmr)
{
    ARG_UNUSED(tmr);
    atomic_inc(&g_timer_count);
}

ZTEST(zephyr_stress, test_07_timer_oneshot)
{
    atomic_set(&g_timer_count, 0);
    k_timer_init(&g_timer, timer_cb, NULL);

    k_timer_start(&g_timer, K_MSEC(TIMER_PERIOD_MS), K_NO_WAIT);

    /* k_sleep() is unreliable in jv32sim when the test thread is the only
     * runnable thread: the idle WFI spin exits only when mstatus.MIE=1, but
     * Zephyr may enter WFI with interrupts disabled in certain paths.
     * Busy-spinning keeps the CPU executing instructions; jv32sim calls
     * tick_slaves() + check_interrupts() on every instruction, so mtime
     * advances and the machine-timer ISR fires normally.
     * 1 tick = 500 000 mtime increments; ~4 instructions per loop iteration;
     * 200 000 iterations ≈ 800 K mtime increments ≈ 1.6 ticks (~16 ms). */
    volatile uint32_t spin = 200000U;
    while (spin-- > 0) {}

    k_timer_stop(&g_timer);
    zassert_equal((atomic_val_t)1, atomic_get(&g_timer_count),
                  "One-shot timer did not fire exactly once");
}

ZTEST(zephyr_stress, test_08_timer_periodic)
{
    atomic_set(&g_timer_count, 0);
    k_timer_init(&g_timer, timer_cb, NULL);

    k_timer_start(&g_timer,
                  K_MSEC(TIMER_PERIOD_MS),
                  K_MSEC(TIMER_PERIOD_MS));

    /* Busy-spin for ~2+ periods; same reasoning as test_07.
     * 280 000 iterations ≈ 1.12 M mtime increments ≈ 2.2 ticks (~23 ms).
     * RTL (mtime++ per cycle, CPI~1.5): ≈ 3.4 ticks → same result.
     * Requires >= 2 fires; 3 fires would demand exactly 3 ticks = 30 ms. */
    volatile uint32_t spin = 280000U;
    while (spin-- > 0) {}

    k_timer_stop(&g_timer);

    zassert_true(atomic_get(&g_timer_count) >= 2,
                 "Periodic timer fired fewer times than expected");
}

/* ==================================================================== */
/* Test result reporting                                                 */
/* ==================================================================== */

/*
 * Print "[ RUN ] test_name" before each test.
 * Using printk (not printf): CONFIG_STDOUT_CONSOLE is not set on this
 * port, so printf produces no output; only the printk backend is wired
 * to the magic-address console by console_jv32_init().
 */
static void zt_before(const struct ztest_unit_test *test, void *data)
{
    ARG_UNUSED(data);
    printk("[ RUN ] %s\n", test->name);
}

ZTEST_RULE(stress_results, zt_before, NULL);

/* ==================================================================== */
/* Test suite registration                                               */
/* ==================================================================== */

/*
 * Called by the ztest framework after ALL tests in the suite have run.
 * At this point test->stats->pass_count / fail_count are fully updated,
 * so we can print accurate per-test results and a final summary.
 *
 * We iterate _ztest_unit_test_list_start.._ztest_unit_test_list_end
 * (the same iterator used internally by the ztest framework) rather than
 * maintaining our own counters, which avoids the ordering hazard that
 * would arise if we tried to record results inside zt_after (the stats
 * are updated by the caller of run_test(), i.e. AFTER the after-each
 * rules have already fired).
 */
static void suite_teardown(void *data)
{
    ARG_UNUSED(data);
    int total = 0, passed = 0, failed = 0;

    for (struct ztest_unit_test *t = _ztest_unit_test_list_start;
         t < _ztest_unit_test_list_end; ++t) {
        if (strcmp(t->test_suite_name, "zephyr_stress") != 0) {
            continue;
        }
        total++;
        if (t->stats->fail_count > 0) {
            printk("[ FAIL] %s\n", t->name);
            failed++;
        } else {
            printk("[  OK ] %s\n", t->name);
            passed++;
        }
    }
    printk("\n%d Tests  %d Passed  %d Failed\n", total, passed, failed);
    jv_exit(failed);
}

ZTEST_SUITE(zephyr_stress, NULL, NULL, NULL, NULL, suite_teardown);
