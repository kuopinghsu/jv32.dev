/*
 * riot_stress.c  --  RIOT OS stress tests for JV32
 *
 * Port      : RIOT OS / JV32 RISC-V SoC
 *
 * Tests mirror the FreeRTOS and ThreadX stress suites so that comparison
 * runs across kernels are straightforward.  Iteration counts are kept
 * short to complete in reasonable RTL simulation time.
 *
 * Tests:
 *   1. Round-robin     -- N threads yield; counter must be exact.
 *   2. Preemption      -- High-priority ticker preempts low-priority workers.
 *   3. Mutex contention-- N threads fight one mutex; counter must be exact.
 *   4. Queue (msg IPC) -- 2 producers + 2 consumers; checksum verified.
 *   5. Sem ping-pong   -- Two threads alternate; rounds must be exact.
 *   6. Thread flags    -- N workers set bits; waiter confirms all arrive.
 *
 * RIOT priority note: lower number = higher priority (same as FreeRTOS,
 * opposite of Zephyr).
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <setjmp.h>
#include <inttypes.h>

#include "thread.h"
#include "mutex.h"
#include "msg.h"
#include "thread_flags.h"
#include "sched.h"

#include "testcommon.h"

#define DONE_SIGNAL 0xD04EU

/* ==================================================================== */
/* Minimal test framework (no external library)                          */
/* ==================================================================== */

static int         g_ts_pass;
static int         g_ts_fail;
static int         g_ts_total;
static jmp_buf     g_ts_jmp;
static const char *g_ts_name;

static void ts_fail_fn(const char *file, int line, const char *msg)
{
    fprintf(stderr, "  FAIL  %s  (%s:%d)  %s\n",
            g_ts_name, file, line, msg);
    longjmp(g_ts_jmp, 1);
}

#define TS_ASSERT_MSG(cond, msg) \
    do { if (!(cond)) ts_fail_fn(__FILE__, __LINE__, (msg)); } while (0)

#define TS_ASSERT(cond) \
    TS_ASSERT_MSG((cond), #cond)

#define TS_ASSERT_EQ(a, b) \
    do { if ((a) != (b)) { \
        char _buf[128]; \
        snprintf(_buf, sizeof(_buf), "%lld != %lld", \
                 (long long)(a), (long long)(b)); \
        ts_fail_fn(__FILE__, __LINE__, _buf); \
    }} while (0)

#define TS_ASSERT_GE(val, thr) \
    do { if (!((val) >= (thr))) { \
        char _buf[128]; \
        snprintf(_buf, sizeof(_buf), #val " (%lld) not >= %lld", \
                 (long long)(val), (long long)(thr)); \
        ts_fail_fn(__FILE__, __LINE__, _buf); \
    }} while (0)

static void ts_run(void (*fn)(void), const char *name)
{
    g_ts_total++;
    g_ts_name = name;
    printf("[ RUN ] %s\n", name);
    if (setjmp(g_ts_jmp) == 0) {
        fn();
        g_ts_pass++;
        printf("[  OK ] %s\n", name);
    } else {
        g_ts_fail++;
        printf("[ FAIL] %s\n", name);
    }
}

static int ts_summary(void)
{
    printf("\n%d Tests  %d Passed  %d Failed\n",
           g_ts_total, g_ts_pass, g_ts_fail);
    return g_ts_fail;
}

#define RUN_TEST(fn)  ts_run(fn, #fn)
#define TEST_BEGIN()  do { g_ts_pass = 0; g_ts_fail = 0; g_ts_total = 0; } while (0)
#define TEST_END()    ts_summary()

/* ==================================================================== */
/* Tunables — keep small for RTL sim                                     */
/* ==================================================================== */

#define NUM_TASKS        4
#define ITER_COUNT       10
#define PINGPONG_ROUNDS  10
#define Q_PRODUCERS      2
#define Q_CONSUMERS      2
#define Q_MSGS_EACH      4

/* Standard stack size for spawned worker threads */
#define WORKER_STACK_SIZE   THREAD_STACKSIZE_DEFAULT

/*
 * Priority layout (lower number = higher priority in RIOT):
 *   RUNNER_PRIO   — test-driver thread (main)
 *   WORKER_PRIO   — same-priority workers for round-robin/mutex tests
 *   HI_PRIO       — higher than runner (preempts it)
 *   LO_PRIO       — lower than runner
 */
#define RUNNER_PRIO   (THREAD_PRIORITY_MAIN)
#define WORKER_PRIO   (THREAD_PRIORITY_MAIN)
#define HI_PRIO       (THREAD_PRIORITY_MAIN - 2)
#define LO_PRIO       (THREAD_PRIORITY_MAIN + 2)

/* ==================================================================== */
/* Completion-semaphore implemented with msg IPC                         */
/*                                                                       */
/* RIOT has no built-in binary semaphore, but a single-slot msg queue    */
/* gives the same behaviour: each "done" signal sends one message to    */
/* the waiting (main) thread.                                            */
/* ==================================================================== */

static kernel_pid_t g_runner_pid;

/* Signal "done" from a worker to the runner */
static void signal_done(void)
{
    msg_t m;
    m.content.value = DONE_SIGNAL;
    msg_send(&m, g_runner_pid);
}

/* Wait for n done-signals from workers */
static void wait_for_workers(int n)
{
    msg_t m;
    for (int i = 0; i < n; i++) {
        msg_receive(&m);
        TS_ASSERT_MSG(m.content.value == DONE_SIGNAL,
                      "Unexpected message in done-wait");
    }
}

/* ==================================================================== */
/* TEST 1 — Round-robin                                                  */
/* ==================================================================== */

static volatile int64_t s_rr_counter;

#define RR_STACK_TOTAL  (NUM_TASKS * WORKER_STACK_SIZE)
static char rr_stacks[RR_STACK_TOTAL];

typedef struct { int idx; } rr_arg_t;
static rr_arg_t rr_args[NUM_TASKS];

static void *rr_thread(void *arg)
{
    (void)arg;
    for (int i = 0; i < ITER_COUNT; i++) {
        s_rr_counter++;
        thread_yield();
    }
    signal_done();
    return NULL;
}

static void test_round_robin(void)
{
    s_rr_counter = 0;

    for (int i = 0; i < NUM_TASKS; i++) {
        rr_args[i].idx = i;
        char name[8];
        snprintf(name, sizeof(name), "rr%d", i);
        kernel_pid_t pid = thread_create(
            rr_stacks + i * WORKER_STACK_SIZE,
            WORKER_STACK_SIZE,
            WORKER_PRIO,
            THREAD_CREATE_WOUT_YIELD,
            rr_thread, &rr_args[i], name);
        TS_ASSERT_MSG(pid > 0, "rr thread_create failed");
    }

    wait_for_workers(NUM_TASKS);

    TS_ASSERT_EQ(s_rr_counter, (int64_t)NUM_TASKS * ITER_COUNT);
}

/* ==================================================================== */
/* TEST 2 — Preemption                                                   */
/* ==================================================================== */

static volatile int64_t s_tick_count;
static volatile int     s_preempt_running;

#define TICK_STACK_SIZE  WORKER_STACK_SIZE
#define LO_STACK_SIZE    WORKER_STACK_SIZE
static char tick_stack[TICK_STACK_SIZE];
static char lo_stack[LO_STACK_SIZE];

static void *ticker_thread(void *arg)
{
    (void)arg;
    for (int i = 0; i < ITER_COUNT; i++) {
        s_tick_count++;
        /* yield so the scheduler can run lo_worker; then we preempt back */
        thread_yield();
    }
    /* Stop low-priority worker */
    s_preempt_running = 0;
    signal_done();
    return NULL;
}

static void *lo_worker(void *arg)
{
    (void)arg;
    while (s_preempt_running) {
        thread_yield();
    }
    signal_done();
    return NULL;
}

static void test_preemption(void)
{
    s_tick_count = 0;
    s_preempt_running = 1;

    /* Low-priority worker first so ticker can preempt it */
    kernel_pid_t lpid = thread_create(lo_stack, sizeof(lo_stack),
                                      LO_PRIO,
                                      THREAD_CREATE_WOUT_YIELD,
                                      lo_worker, NULL, "lo");
    TS_ASSERT_MSG(lpid > 0, "lo thread_create failed");

    kernel_pid_t tpid = thread_create(tick_stack, sizeof(tick_stack),
                                      HI_PRIO,
                                      THREAD_CREATE_WOUT_YIELD,
                                      ticker_thread, NULL, "tick");
    TS_ASSERT_MSG(tpid > 0, "ticker thread_create failed");

    wait_for_workers(2);

    TS_ASSERT_EQ(s_tick_count, (int64_t)ITER_COUNT);
}

/* ==================================================================== */
/* TEST 3 — Mutex contention                                             */
/* ==================================================================== */

static mutex_t       s_mx     = MUTEX_INIT;
static volatile int64_t s_mx_counter;

#define MX_STACK_TOTAL  (NUM_TASKS * WORKER_STACK_SIZE)
static char mx_stacks[MX_STACK_TOTAL];

static void *mx_thread(void *arg)
{
    (void)arg;
    for (int i = 0; i < ITER_COUNT; i++) {
        mutex_lock(&s_mx);
        s_mx_counter++;
        mutex_unlock(&s_mx);
        thread_yield();
    }
    signal_done();
    return NULL;
}

static void test_mutex_contention(void)
{
    s_mx_counter = 0;

    for (int i = 0; i < NUM_TASKS; i++) {
        char name[8];
        snprintf(name, sizeof(name), "mx%d", i);
        kernel_pid_t pid = thread_create(
            mx_stacks + i * WORKER_STACK_SIZE,
            WORKER_STACK_SIZE,
            WORKER_PRIO,
            THREAD_CREATE_WOUT_YIELD,
            mx_thread, NULL, name);
        TS_ASSERT_MSG(pid > 0, "mx thread_create failed");
    }

    wait_for_workers(NUM_TASKS);

    TS_ASSERT_EQ(s_mx_counter, (int64_t)NUM_TASKS * ITER_COUNT);
}

/* ==================================================================== */
/* TEST 4 — Queue (IPC message) producer/consumer                        */
/* ==================================================================== */

/*
 * RIOT IPC: msg_send / msg_receive operate on a thread's built-in
 * message queue (if initialized) or block the sender until the
 * receiver calls msg_receive.
 *
 * We use a dedicated "consumer" thread that owns an in-thread queue.
 * Each producer sends Q_MSGS_EACH messages; the consumer accumulates
 * a checksum.  At the end we verify it matches the expected value.
 */

#define Q_TOTAL_MSGS  (Q_PRODUCERS * Q_MSGS_EACH)

#define Q_DEPTH       16   /* must be a power of 2 (RIOT CIB requirement) */

static msg_t          q_consumer_queue[Q_DEPTH];
static kernel_pid_t   g_consumer_pid;

static volatile uint32_t s_q_checksum_rx;
static volatile int       s_q_msgs_rx;

#define PROD_STACK_TOTAL  (Q_PRODUCERS * WORKER_STACK_SIZE)
#define CONS_STACK_SIZE   WORKER_STACK_SIZE
static char prod_stacks[PROD_STACK_TOTAL];
static char cons_stack[CONS_STACK_SIZE];

typedef struct { int producer_id; } prod_arg_t;
static prod_arg_t prod_args[Q_PRODUCERS];

static void *q_producer(void *arg)
{
    prod_arg_t *a = (prod_arg_t *)arg;
    for (int i = 0; i < Q_MSGS_EACH; i++) {
        uint32_t val = (uint32_t)(a->producer_id * 100 + i + 1);
        msg_t m;
        m.type          = 0;
        m.content.value = val;
        msg_send(&m, g_consumer_pid);
        thread_yield();
    }
    signal_done();
    return NULL;
}

static void *q_consumer(void *arg)
{
    (void)arg;
    msg_init_queue(q_consumer_queue, Q_DEPTH);
    uint32_t sum = 0;
    int received = 0;

    while (received < Q_TOTAL_MSGS) {
        msg_t m;
        msg_receive(&m);
        sum += m.content.value;
        received++;
    }
    s_q_checksum_rx = sum;
    s_q_msgs_rx     = received;
    signal_done();
    return NULL;
}

static void test_queue(void)
{
    s_q_checksum_rx = 0;
    s_q_msgs_rx     = 0;

    /* Expected checksum: sum over all (prod_id * 100 + idx + 1) */
    uint32_t expected_sum = 0;
    for (int p = 0; p < Q_PRODUCERS; p++) {
        for (int i = 0; i < Q_MSGS_EACH; i++) {
            expected_sum += (uint32_t)(p * 100 + i + 1);
        }
    }

    /* Consumer must be created first so its PID is known */
    g_consumer_pid = thread_create(cons_stack, sizeof(cons_stack),
                                   WORKER_PRIO - 1,  /* higher prio to drain */
                                   THREAD_CREATE_WOUT_YIELD,
                                   q_consumer, NULL, "qcons");
    TS_ASSERT_MSG(g_consumer_pid > 0, "consumer thread_create failed");

    for (int p = 0; p < Q_PRODUCERS; p++) {
        prod_args[p].producer_id = p;
        char name[8];
        snprintf(name, sizeof(name), "qp%d", p);
        kernel_pid_t pid = thread_create(
            prod_stacks + p * WORKER_STACK_SIZE,
            WORKER_STACK_SIZE,
            WORKER_PRIO,
            THREAD_CREATE_WOUT_YIELD,
            q_producer, &prod_args[p], name);
        TS_ASSERT_MSG(pid > 0, "producer thread_create failed");
    }

    /* Wait for all producers + consumer */
    wait_for_workers(Q_PRODUCERS + 1);

    TS_ASSERT_EQ((int64_t)s_q_msgs_rx, (int64_t)Q_TOTAL_MSGS);
    TS_ASSERT_EQ((int64_t)s_q_checksum_rx, (int64_t)expected_sum);
}

/* ==================================================================== */
/* TEST 5 — Semaphore ping-pong via thread flags                         */
/* ==================================================================== */

/*
 * RIOT has no binary semaphore in its core; we emulate one using
 * thread_flags, which is the appropriate RIOT mechanism for this
 * pattern.
 */

#define PING_FLAG   (1u << 0)
#define PONG_FLAG   (1u << 1)

#define PP_STACK_SIZE  WORKER_STACK_SIZE
static char pong_stack[PP_STACK_SIZE];

static volatile int s_pingpong_rounds;
static kernel_pid_t g_ping_pid;
static kernel_pid_t g_pong_pid;

static void *pong_thread(void *arg)
{
    (void)arg;
    for (int i = 0; i < PINGPONG_ROUNDS; i++) {
        thread_flags_wait_all(PING_FLAG);
        s_pingpong_rounds++;
        thread_flags_set(thread_get(g_ping_pid), PONG_FLAG);
    }
    signal_done();
    return NULL;
}

static void test_ping_pong(void)
{
    s_pingpong_rounds = 0;
    g_ping_pid = thread_getpid();

    g_pong_pid = thread_create(pong_stack, sizeof(pong_stack),
                               WORKER_PRIO - 1,   /* higher prio */
                               THREAD_CREATE_WOUT_YIELD,
                               pong_thread, NULL, "pong");
    TS_ASSERT_MSG(g_pong_pid > 0, "pong thread_create failed");

    for (int i = 0; i < PINGPONG_ROUNDS; i++) {
        thread_flags_set(thread_get(g_pong_pid), PING_FLAG);
        thread_flags_wait_all(PONG_FLAG);
    }

    wait_for_workers(1);
    TS_ASSERT_EQ(s_pingpong_rounds, PINGPONG_ROUNDS);
}

/* ==================================================================== */
/* TEST 6 — Thread-flags fan-out (N workers set bits, waiter gets all)  */
/* ==================================================================== */

#define FAN_STACK_TOTAL  (NUM_TASKS * WORKER_STACK_SIZE)
static char fan_stacks[FAN_STACK_TOTAL];

static kernel_pid_t g_fan_waiter_pid;

typedef struct { int bit; } fan_arg_t;
static fan_arg_t fan_args[NUM_TASKS];

static void *fan_worker(void *arg)
{
    fan_arg_t *a = (fan_arg_t *)arg;
    thread_flags_set(thread_get(g_fan_waiter_pid),
                     (thread_flags_t)(1u << a->bit));
    signal_done();
    return NULL;
}

static void test_flags_fanout(void)
{
    /* Build expected mask */
    thread_flags_t expected = 0;
    for (int i = 0; i < NUM_TASKS; i++) {
        expected |= (thread_flags_t)(1u << i);
    }

    g_fan_waiter_pid = thread_getpid();

    for (int i = 0; i < NUM_TASKS; i++) {
        fan_args[i].bit = i;
        char name[8];
        snprintf(name, sizeof(name), "fan%d", i);
        kernel_pid_t pid = thread_create(
            fan_stacks + i * WORKER_STACK_SIZE,
            WORKER_STACK_SIZE,
            WORKER_PRIO - 1,    /* higher prio so they run immediately */
            THREAD_CREATE_WOUT_YIELD,
            fan_worker, &fan_args[i], name);
        TS_ASSERT_MSG(pid > 0, "fan thread_create failed");
    }

    /* Wait for all workers to signal done */
    wait_for_workers(NUM_TASKS);

    /* Collect the accumulated flags */
    thread_flags_t got = thread_flags_clear(expected);
    TS_ASSERT_EQ((uint32_t)got, (uint32_t)expected);
}

/* ==================================================================== */
/* main                                                                  */
/* ==================================================================== */

int main(void)
{
    g_runner_pid = thread_getpid();

    printf("=============================================\n");
    printf("RIOT stress test — JV32 RISC-V SoC\n");
    printf("=============================================\n\n");

    TEST_BEGIN();
    RUN_TEST(test_round_robin);
    RUN_TEST(test_preemption);
    RUN_TEST(test_mutex_contention);
    RUN_TEST(test_queue);
    RUN_TEST(test_ping_pong);
    RUN_TEST(test_flags_fanout);
    int rc = TEST_END();

    if (rc == 0) {
        printf("ALL TESTS PASSED\n");
    } else {
        printf("SOME TESTS FAILED\n");
    }

    jv_exit(rc);
    return rc;
}
