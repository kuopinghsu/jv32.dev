/*
 * freertos_stress.c  --  FreeRTOS stress tests: heavy context switching
 *
 * No external test framework required.  A minimal self-contained
 * framework (TS_ASSERT_* macros + ts_run) is defined below.
 *
 * Port      : FreeRTOS POSIX / Linux
 * Build     : make -f Makefile.stress
 *
 * Tests (short iteration counts for RTL simulation):
 *   1. Round-robin         -- N tasks yield; counter must be exact.
 *   2. Preemption          -- High-prio ticker preempts low-prio workers.
 *   3. Mutex contention    -- N tasks fight one mutex; counter must be exact.
 *   4. Queue prod/consumer -- 2 producers + 2 consumers; checksum verified.
 *   5. Sem ping-pong       -- Two tasks alternate; rounds must be exact.
 *   6. Event-group fan-out -- N workers set bits; waiter gets all.
 *   7. Timer one-shot      -- Fires exactly once.
 *   8. Timer periodic      -- Fires at least 3 times.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <setjmp.h>

#include "testcommon.h"
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "semphr.h"
#include "event_groups.h"
#include "timers.h"

/* ==================================================================== */
/* Self-contained test framework -- no external library required.       */
/* ==================================================================== */

static int         g_ts_pass;
static int         g_ts_fail;
static int         g_ts_total;
static jmp_buf     g_ts_jmp;
static const char *g_ts_name;

static void ts_fail(const char *file, int line, const char *msg)
{
    fprintf(stderr, "  FAIL  %s  (%s:%d)  %s\n",
            g_ts_name, file, line, msg);
    longjmp(g_ts_jmp, 1);
}

#define TS_ASSERT_MSG(cond, msg) \
    do { if (!(cond)) ts_fail(__FILE__, __LINE__, (msg)); } while (0)

#define TS_ASSERT(cond) \
    TS_ASSERT_MSG((cond), #cond)

#define TS_ASSERT_EQ(a, b) \
    do { if ((a) != (b)) { \
        char _b[128]; \
        snprintf(_b, sizeof(_b), "%lld != %lld", \
                 (long long)(a), (long long)(b)); \
        ts_fail(__FILE__, __LINE__, _b); \
    }} while (0)

#define TS_ASSERT_NOT_NULL(p) \
    TS_ASSERT_MSG((p) != NULL, #p " is NULL")

#define TS_ASSERT_GT(val, thr) \
    do { if (!((val) > (thr))) { \
        char _b[128]; \
        snprintf(_b, sizeof(_b), #val " (%lld) not > %lld", \
                 (long long)(val), (long long)(thr)); \
        ts_fail(__FILE__, __LINE__, _b); \
    }} while (0)

#define TS_ASSERT_GE(val, thr) \
    do { if (!((val) >= (thr))) { \
        char _b[128]; \
        snprintf(_b, sizeof(_b), #val " (%lld) not >= %lld", \
                 (long long)(val), (long long)(thr)); \
        ts_fail(__FILE__, __LINE__, _b); \
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
/* Tunables -- keep small for RTL sim                                    */
/* ==================================================================== */

#define NUM_TASKS        4
#define ITER_COUNT       10
#define PINGPONG_ROUNDS  10
#define Q_PRODUCERS      2
#define Q_CONSUMERS      2
#define Q_MSGS_EACH      4
#define TIMER_PERIOD_MS  10
#define TEST_TIMEOUT_MS  2500

/* ==================================================================== */
/* Shared completion semaphore                                           */
/* ==================================================================== */

static SemaphoreHandle_t s_done;

static void wait_for_workers(int n)
{
    for (int i = 0; i < n; i++) {
        BaseType_t ok = xSemaphoreTake(s_done,
                                       pdMS_TO_TICKS(TEST_TIMEOUT_MS));
        TS_ASSERT_MSG(ok == pdTRUE, "Timed out waiting for worker task");
    }
}

/* ==================================================================== */
/* TEST 1 -- Round-robin stress                                          */
/* ==================================================================== */

static volatile int64_t s_rr_counter;

static void rr_task(void *pvArg)
{
    (void)pvArg;
    for (int i = 0; i < ITER_COUNT; i++) {
        s_rr_counter++;
        taskYIELD();
    }
    xSemaphoreGive(s_done);
    vTaskDelete(NULL);
}

static void test_01_roundrobin(void)
{
    s_rr_counter = 0;
    s_done = xSemaphoreCreateCounting(NUM_TASKS, 0);
    TS_ASSERT_NOT_NULL(s_done);

    UBaseType_t prio = uxTaskPriorityGet(NULL);
    for (int i = 0; i < NUM_TASKS; i++) {
        BaseType_t rc = xTaskCreate(rr_task, "RR",
                                    configMINIMAL_STACK_SIZE * 3,
                                    NULL, prio, NULL);
        TS_ASSERT_EQ(pdPASS, rc);
    }

    wait_for_workers(NUM_TASKS);
    TS_ASSERT_EQ((int64_t)NUM_TASKS * ITER_COUNT, s_rr_counter);
    vSemaphoreDelete(s_done);
}

/* ==================================================================== */
/* TEST 2 -- Priority preemption stress                                  */
/* ==================================================================== */

static volatile int64_t  s_low_slices;
static volatile int64_t  s_high_fires;
static SemaphoreHandle_t s_ticker_stop;
static SemaphoreHandle_t s_low_done;

static void lo_prio_task(void *pvArg)
{
    (void)pvArg;
    for (int i = 0; i < ITER_COUNT; i++) {
        s_low_slices++;
        volatile int spin = 20;
        while (spin-- > 0) {}
    }
    xSemaphoreGive(s_low_done);
    vTaskDelete(NULL);
}

static void hi_prio_ticker(void *pvArg)
{
    (void)pvArg;
    while (xSemaphoreTake(s_ticker_stop, 0) != pdTRUE) {
        s_high_fires++;
        vTaskDelay(1);
    }
    xSemaphoreGive(s_done);
    vTaskDelete(NULL);
}

static void test_02_preemption(void)
{
    s_low_slices = 0;
    s_high_fires = 0;

    s_done        = xSemaphoreCreateCounting(1, 0);
    s_ticker_stop = xSemaphoreCreateBinary();
    s_low_done    = xSemaphoreCreateCounting(NUM_TASKS, 0);
    TS_ASSERT_NOT_NULL(s_done);
    TS_ASSERT_NOT_NULL(s_ticker_stop);
    TS_ASSERT_NOT_NULL(s_low_done);

    UBaseType_t runner_prio = uxTaskPriorityGet(NULL);
    UBaseType_t lo_prio = (runner_prio > 1) ? (runner_prio - 1)
                                             : tskIDLE_PRIORITY + 1;
    UBaseType_t hi_prio = runner_prio + 1;

    xTaskCreate(hi_prio_ticker, "HiTick",
                configMINIMAL_STACK_SIZE * 2, NULL, hi_prio, NULL);
    for (int i = 0; i < NUM_TASKS; i++)
        xTaskCreate(lo_prio_task, "LoPre",
                    configMINIMAL_STACK_SIZE * 3, NULL, lo_prio, NULL);

    for (int i = 0; i < NUM_TASKS; i++) {
        BaseType_t ok = xSemaphoreTake(s_low_done,
                                       pdMS_TO_TICKS(TEST_TIMEOUT_MS));
        TS_ASSERT_MSG(ok == pdTRUE, "Low-priority task timed out");
    }

    xSemaphoreGive(s_ticker_stop);
    wait_for_workers(1);

    TS_ASSERT_EQ((int64_t)NUM_TASKS * ITER_COUNT, s_low_slices);
    TS_ASSERT_GT(s_high_fires, 0);

    vSemaphoreDelete(s_done);
    vSemaphoreDelete(s_ticker_stop);
    vSemaphoreDelete(s_low_done);
}

/* ==================================================================== */
/* TEST 3 -- Mutex contention stress                                     */
/* ==================================================================== */

static SemaphoreHandle_t s_mutex;
static volatile int64_t  s_mutex_counter;

static void mutex_task(void *pvArg)
{
    (void)pvArg;
    for (int i = 0; i < ITER_COUNT; i++) {
        xSemaphoreTake(s_mutex, portMAX_DELAY);
        s_mutex_counter++;
        xSemaphoreGive(s_mutex);
        taskYIELD();
    }
    xSemaphoreGive(s_done);
    vTaskDelete(NULL);
}

static void test_03_mutex_contention(void)
{
    s_mutex_counter = 0;
    s_mutex = xSemaphoreCreateMutex();
    s_done  = xSemaphoreCreateCounting(NUM_TASKS, 0);
    TS_ASSERT_NOT_NULL(s_mutex);
    TS_ASSERT_NOT_NULL(s_done);

    UBaseType_t prio = uxTaskPriorityGet(NULL);
    for (int i = 0; i < NUM_TASKS; i++)
        xTaskCreate(mutex_task, "MuxT",
                    configMINIMAL_STACK_SIZE * 3, NULL, prio, NULL);

    wait_for_workers(NUM_TASKS);
    TS_ASSERT_EQ((int64_t)NUM_TASKS * ITER_COUNT, s_mutex_counter);

    vSemaphoreDelete(s_mutex);
    vSemaphoreDelete(s_done);
}

/* ==================================================================== */
/* TEST 4 -- Queue producer / consumer stress                            */
/* ==================================================================== */

#define Q_DEPTH  16

struct qmsg { uint32_t value; };

static QueueHandle_t     s_queue;
static volatile int64_t  s_total_received;
static volatile int64_t  s_sum_sent;
static volatile int64_t  s_sum_received;
static volatile int32_t  s_producers_active;
static SemaphoreHandle_t s_prod_active_mutex;
static SemaphoreHandle_t s_prod_done_sem;
static SemaphoreHandle_t s_cons_done_sem;

typedef struct { int start_val; } ProdArgs;
static ProdArgs s_prod_args[Q_PRODUCERS];

static void producer_task(void *pvArg)
{
    ProdArgs *args = (ProdArgs *)pvArg;
    for (int i = 0; i < Q_MSGS_EACH; i++) {
        struct qmsg msg = { .value = (uint32_t)(args->start_val + i) };
        xQueueSend(s_queue, &msg, portMAX_DELAY);
        if ((i % 4) == 0) taskYIELD();
    }
    xSemaphoreTake(s_prod_active_mutex, portMAX_DELAY);
    s_producers_active--;
    xSemaphoreGive(s_prod_active_mutex);
    xSemaphoreGive(s_prod_done_sem);
    vTaskDelete(NULL);
}

static void consumer_task(void *pvArg)
{
    (void)pvArg;
    struct qmsg msg;
    for (;;) {
        if (xQueueReceive(s_queue, &msg, pdMS_TO_TICKS(10)) == pdTRUE) {
            s_total_received++;
            s_sum_received += (int64_t)msg.value;
        } else {
            xSemaphoreTake(s_prod_active_mutex, portMAX_DELAY);
            int32_t active = s_producers_active;
            xSemaphoreGive(s_prod_active_mutex);
            if (active == 0 && uxQueueMessagesWaiting(s_queue) == 0)
                break;
        }
    }
    xSemaphoreGive(s_cons_done_sem);
    vTaskDelete(NULL);
}

static void test_04_queue_producer_consumer(void)
{
    s_total_received   = 0;
    s_sum_sent         = 0;
    s_sum_received     = 0;
    s_producers_active = Q_PRODUCERS;

    s_queue             = xQueueCreate(Q_DEPTH, sizeof(struct qmsg));
    s_prod_active_mutex = xSemaphoreCreateMutex();
    s_prod_done_sem     = xSemaphoreCreateCounting(Q_PRODUCERS, 0);
    s_cons_done_sem     = xSemaphoreCreateCounting(Q_CONSUMERS, 0);
    TS_ASSERT_NOT_NULL(s_queue);
    TS_ASSERT_NOT_NULL(s_prod_active_mutex);
    TS_ASSERT_NOT_NULL(s_prod_done_sem);
    TS_ASSERT_NOT_NULL(s_cons_done_sem);

    for (int p = 0; p < Q_PRODUCERS; p++) {
        s_prod_args[p].start_val = (p * Q_MSGS_EACH) + 1;
        for (int i = 0; i < Q_MSGS_EACH; i++)
            s_sum_sent += (int64_t)(s_prod_args[p].start_val + i);
    }

    UBaseType_t prio = uxTaskPriorityGet(NULL);
    for (int i = 0; i < Q_CONSUMERS; i++)
        xTaskCreate(consumer_task, "Cons",
                    configMINIMAL_STACK_SIZE * 3, NULL, prio, NULL);
    for (int i = 0; i < Q_PRODUCERS; i++)
        xTaskCreate(producer_task, "Prod",
                    configMINIMAL_STACK_SIZE * 3,
                    &s_prod_args[i], prio, NULL);

    for (int i = 0; i < Q_PRODUCERS; i++) {
        BaseType_t ok = xSemaphoreTake(s_prod_done_sem,
                                       pdMS_TO_TICKS(TEST_TIMEOUT_MS));
        TS_ASSERT_MSG(ok == pdTRUE, "Producer timed out");
    }
    for (int i = 0; i < Q_CONSUMERS; i++) {
        BaseType_t ok = xSemaphoreTake(s_cons_done_sem,
                                       pdMS_TO_TICKS(TEST_TIMEOUT_MS));
        TS_ASSERT_MSG(ok == pdTRUE, "Consumer timed out");
    }

    TS_ASSERT_EQ((int64_t)Q_PRODUCERS * Q_MSGS_EACH, s_total_received);
    TS_ASSERT_EQ(s_sum_sent, s_sum_received);

    vQueueDelete(s_queue);
    vSemaphoreDelete(s_prod_active_mutex);
    vSemaphoreDelete(s_prod_done_sem);
    vSemaphoreDelete(s_cons_done_sem);
}

/* ==================================================================== */
/* TEST 5 -- Semaphore ping-pong                                         */
/* ==================================================================== */

static SemaphoreHandle_t s_ping;
static SemaphoreHandle_t s_pong;
static volatile int64_t  s_ping_count;
static volatile int64_t  s_pong_count;

static void ping_task(void *pvArg)
{
    (void)pvArg;
    for (int i = 0; i < PINGPONG_ROUNDS; i++) {
        xSemaphoreTake(s_ping, portMAX_DELAY);
        s_ping_count++;
        xSemaphoreGive(s_pong);
    }
    xSemaphoreGive(s_done);
    vTaskDelete(NULL);
}

static void pong_task(void *pvArg)
{
    (void)pvArg;
    for (int i = 0; i < PINGPONG_ROUNDS; i++) {
        xSemaphoreTake(s_pong, portMAX_DELAY);
        s_pong_count++;
        xSemaphoreGive(s_ping);
    }
    xSemaphoreGive(s_done);
    vTaskDelete(NULL);
}

static void test_05_semaphore_pingpong(void)
{
    s_ping_count = 0;
    s_pong_count = 0;
    s_ping = xSemaphoreCreateBinary();
    s_pong = xSemaphoreCreateBinary();
    s_done = xSemaphoreCreateCounting(2, 0);
    TS_ASSERT_NOT_NULL(s_ping);
    TS_ASSERT_NOT_NULL(s_pong);
    TS_ASSERT_NOT_NULL(s_done);

    UBaseType_t prio = uxTaskPriorityGet(NULL);
    xTaskCreate(ping_task, "Ping", configMINIMAL_STACK_SIZE * 2, NULL, prio, NULL);
    xTaskCreate(pong_task, "Pong", configMINIMAL_STACK_SIZE * 2, NULL, prio, NULL);
    xSemaphoreGive(s_ping);

    wait_for_workers(2);
    TS_ASSERT_EQ(PINGPONG_ROUNDS, s_ping_count);
    TS_ASSERT_EQ(PINGPONG_ROUNDS, s_pong_count);

    vSemaphoreDelete(s_ping);
    vSemaphoreDelete(s_pong);
    vSemaphoreDelete(s_done);
}

/* ==================================================================== */
/* TEST 6 -- Event-group fan-out                                         */
/* ==================================================================== */

#define ALL_BITS  ((EventBits_t)((1UL << NUM_TASKS) - 1UL))

static EventGroupHandle_t s_event_group;

typedef struct { int bit; } EGArgs;
static EGArgs s_eg_args[NUM_TASKS];

static void eg_worker(void *pvArg)
{
    EGArgs *args = (EGArgs *)pvArg;
    vTaskDelay((TickType_t)(args->bit + 1));
    xEventGroupSetBits(s_event_group, (EventBits_t)(1UL << args->bit));
    xSemaphoreGive(s_done);
    vTaskDelete(NULL);
}

static void test_06_event_group_fanout(void)
{
    s_event_group = xEventGroupCreate();
    s_done        = xSemaphoreCreateCounting(NUM_TASKS, 0);
    TS_ASSERT_NOT_NULL(s_event_group);
    TS_ASSERT_NOT_NULL(s_done);

    UBaseType_t prio = uxTaskPriorityGet(NULL);
    for (int i = 0; i < NUM_TASKS; i++) {
        s_eg_args[i].bit = i;
        xTaskCreate(eg_worker, "EGWk",
                    configMINIMAL_STACK_SIZE * 2,
                    &s_eg_args[i], prio, NULL);
    }

    EventBits_t result = xEventGroupWaitBits(s_event_group,
                                             ALL_BITS,
                                             pdFALSE, pdTRUE,
                                             pdMS_TO_TICKS(TEST_TIMEOUT_MS));
    TS_ASSERT_EQ((uint32_t)ALL_BITS, (uint32_t)(result & ALL_BITS));

    wait_for_workers(NUM_TASKS);
    vEventGroupDelete(s_event_group);
    vSemaphoreDelete(s_done);
}

/* ==================================================================== */
/* TEST 7 -- Timer one-shot                                              */
/* ==================================================================== */

static volatile uint32_t s_timer_count;

static void timer_cb(TimerHandle_t xTimer)
{
    (void)xTimer;
    s_timer_count++;
}

static void test_07_timer_oneshot(void)
{
    s_timer_count = 0;
    const TickType_t period = pdMS_TO_TICKS(TIMER_PERIOD_MS);

    TimerHandle_t t = xTimerCreate("OneSh", period,
                                   pdFALSE, NULL, timer_cb);
    TS_ASSERT_NOT_NULL(t);
    TS_ASSERT_EQ(pdPASS, xTimerStart(t, portMAX_DELAY));
    TS_ASSERT(xTimerIsTimerActive(t) == pdTRUE);

    vTaskDelay(period * 3);

    TS_ASSERT_EQ(1U, s_timer_count);
    TS_ASSERT(xTimerIsTimerActive(t) == pdFALSE);

    xTimerDelete(t, portMAX_DELAY);
}

/* ==================================================================== */
/* TEST 8 -- Timer periodic                                              */
/* ==================================================================== */

static void test_08_timer_periodic(void)
{
    s_timer_count = 0;
    const TickType_t period = pdMS_TO_TICKS(TIMER_PERIOD_MS);

    TimerHandle_t t = xTimerCreate("Repet", period,
                                   pdTRUE, NULL, timer_cb);
    TS_ASSERT_NOT_NULL(t);
    xTimerStart(t, portMAX_DELAY);

    vTaskDelay(period * 3 + period / 2);
    xTimerStop(t, portMAX_DELAY);
    vTaskDelay(pdMS_TO_TICKS(10));

    TS_ASSERT_GE(s_timer_count, 3U);
    TS_ASSERT(xTimerIsTimerActive(t) == pdFALSE);

    xTimerDelete(t, portMAX_DELAY);
}

/* ==================================================================== */
/* Test runner task                                                       */
/* ==================================================================== */

static void vTestRunnerTask(void *pvParameters)
{
    (void)pvParameters;

    TEST_BEGIN();

    RUN_TEST(test_01_roundrobin);
    RUN_TEST(test_02_preemption);
    RUN_TEST(test_03_mutex_contention);
    RUN_TEST(test_04_queue_producer_consumer);
    RUN_TEST(test_05_semaphore_pingpong);
    RUN_TEST(test_06_event_group_fanout);
    RUN_TEST(test_07_timer_oneshot);
    RUN_TEST(test_08_timer_periodic);

    jv_exit(TEST_END());
}

/* FreeRTOS hook functions */
void vApplicationIdleHook(void) {}
void vApplicationTickHook(void) {}
void vApplicationStackOverflowHook(TaskHandle_t xTask, char *pcTaskName)
{
    (void)xTask;
    printf("Stack overflow in task: %s\n", pcTaskName);
    jv_exit(1);
    while (1) {
    }
}

void vApplicationMallocFailedHook(void)
{
    printf("Malloc failed!\n");
    jv_exit(1);
    while (1) {
    }
}

/* ==================================================================== */
/* Program entry                                                          */
/* ==================================================================== */

int main(void)
{
    BaseType_t rc = xTaskCreate(vTestRunnerTask,
                                "TestRunner",
                                configMINIMAL_STACK_SIZE * 8,
                                NULL,
                                tskIDLE_PRIORITY + 2,
                                NULL);
    if (rc != pdPASS) {
        fprintf(stderr, "ERROR: failed to create test runner task\n");
        return 1;
    }

    vTaskStartScheduler();

    fprintf(stderr, "ERROR: scheduler exited unexpectedly\n");
    return 1;
}
