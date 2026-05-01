/*
 * riot_simple.c  --  RIOT OS simple threading demo for JV32
 *
 * Demonstrates:
 *   • Thread creation and priorities
 *   • Mutex-protected counter
 *   • IPC message passing
 *   • Thread flags signalling
 *
 * Each test prints PASS/FAIL and the program exits with a summary.
 */

#include <stdio.h>
#include <stdint.h>

#include "thread.h"
#include "mutex.h"
#include "msg.h"
#include "thread_flags.h"

#include "testcommon.h"

/* ── Test framework ──────────────────────────────────────────────── */

static int g_pass = 0;
static int g_fail = 0;

#define ASSERT(cond) do { \
    if (cond) { g_pass++; } \
    else { \
        printf("  FAIL: %s (line %d)\n", #cond, __LINE__); \
        g_fail++; \
    } \
} while (0)

/* ── Test 1: basic thread creation and scheduling ─────────────────── */

#define WORKER_STACK_SIZE   THREAD_STACKSIZE_DEFAULT
static char worker1_stack[WORKER_STACK_SIZE];

static volatile int worker1_ran = 0;

static void *worker1_fn(void *arg)
{
    (void)arg;
    worker1_ran = 1;
    return NULL;
}

static void test_thread_creation(void)
{
    printf("[ RUN ] test_thread_creation\n");
    worker1_ran = 0;
    kernel_pid_t pid = thread_create(worker1_stack, sizeof(worker1_stack),
                                     THREAD_PRIORITY_MAIN - 1,
                                     THREAD_CREATE_WOUT_YIELD,
                                     worker1_fn, NULL, "w1");
    ASSERT(pid > 0);
    thread_yield();
    /* After yield, lower-priority scheduler tick lets worker1 run */
    ASSERT(worker1_ran == 1);
    printf("[  OK ] test_thread_creation\n");
}

/* ── Test 2: mutex ────────────────────────────────────────────────── */

#define MUTEX_STACK_SIZE    THREAD_STACKSIZE_DEFAULT
static char mutex_worker_stack[MUTEX_STACK_SIZE];

static mutex_t g_mutex     = MUTEX_INIT;
static volatile int g_counter = 0;
#define MUTEX_ITER 20

static void *mutex_worker_fn(void *arg)
{
    (void)arg;
    for (int i = 0; i < MUTEX_ITER; i++) {
        mutex_lock(&g_mutex);
        g_counter++;
        mutex_unlock(&g_mutex);
        thread_yield();
    }
    return NULL;
}

static void test_mutex(void)
{
    printf("[ RUN ] test_mutex\n");
    g_counter = 0;

    /* Create a worker at same priority as main — cooperative */
    kernel_pid_t pid = thread_create(mutex_worker_stack,
                                     sizeof(mutex_worker_stack),
                                     THREAD_PRIORITY_MAIN,
                                     THREAD_CREATE_WOUT_YIELD,
                                     mutex_worker_fn, NULL, "mw");
    ASSERT(pid > 0);

    /* Main thread also increments counter */
    for (int i = 0; i < MUTEX_ITER; i++) {
        mutex_lock(&g_mutex);
        g_counter++;
        mutex_unlock(&g_mutex);
        thread_yield();
    }

    ASSERT(g_counter == 2 * MUTEX_ITER);
    printf("[  OK ] test_mutex\n");
}

/* ── Test 3: IPC message passing ─────────────────────────────────── */

#define IPC_STACK_SIZE      THREAD_STACKSIZE_DEFAULT
static char ipc_server_stack[IPC_STACK_SIZE];

#define IPC_MSG_COUNT 5
static kernel_pid_t g_server_pid;

static void *ipc_server_fn(void *arg)
{
    (void)arg;
    msg_t m;
    for (int i = 0; i < IPC_MSG_COUNT; i++) {
        msg_receive(&m);
        m.content.value++;
        msg_reply(&m, &m);
    }
    return NULL;
}

static void test_ipc(void)
{
    printf("[ RUN ] test_ipc\n");

    g_server_pid = thread_create(ipc_server_stack, sizeof(ipc_server_stack),
                                 THREAD_PRIORITY_MAIN - 1,
                                 THREAD_CREATE_WOUT_YIELD,
                                 ipc_server_fn, NULL, "srv");
    ASSERT(g_server_pid > 0);

    msg_t m;
    int errors = 0;
    for (int i = 0; i < IPC_MSG_COUNT; i++) {
        m.content.value = (uint32_t)i;
        msg_send_receive(&m, &m, g_server_pid);
        if ((int)m.content.value != i + 1) {
            errors++;
        }
    }
    ASSERT(errors == 0);
    printf("[  OK ] test_ipc\n");
}

/* ── Test 4: thread flags ─────────────────────────────────────────── */

#define FLAGS_STACK_SIZE    THREAD_STACKSIZE_DEFAULT
static char flags_worker_stack[FLAGS_STACK_SIZE];

#define MY_FLAG             (1u << 0)
static kernel_pid_t g_flags_test_pid;

static void *flags_worker_fn(void *arg)
{
    (void)arg;
    /* Wait until the main thread sets the flag */
    thread_flags_wait_all(MY_FLAG);
    /* Signal back using a different flag bit */
    thread_flags_set(thread_get(g_flags_test_pid), (1u << 1));
    return NULL;
}

static void test_thread_flags(void)
{
    printf("[ RUN ] test_thread_flags\n");

    g_flags_test_pid = thread_getpid();

    kernel_pid_t wid = thread_create(flags_worker_stack,
                                     sizeof(flags_worker_stack),
                                     THREAD_PRIORITY_MAIN - 1,
                                     THREAD_CREATE_WOUT_YIELD,
                                     flags_worker_fn, NULL, "fw");
    ASSERT(wid > 0);

    /* Set the flag on the worker — it will unblock and reply */
    thread_flags_set(thread_get(wid), MY_FLAG);

    /* Wait for reply flag from worker */
    thread_flags_t got = thread_flags_wait_all(1u << 1);
    ASSERT((got & (1u << 1)) != 0);
    printf("[  OK ] test_thread_flags\n");
}

/* ── main ─────────────────────────────────────────────────────────── */

int main(void)
{
    printf("===========================\n");
    printf("RIOT simple test — JV32\n");
    printf("===========================\n\n");

    test_thread_creation();
    test_mutex();
    test_ipc();
    test_thread_flags();

    printf("\n%d Tests  %d Passed  %d Failed\n",
           g_pass + g_fail, g_pass, g_fail);

    if (g_fail == 0) {
        printf("ALL TESTS PASSED\n");
        jv_exit(0);
    } else {
        printf("SOME TESTS FAILED\n");
        jv_exit(1);
    }
    return 0;
}
