/*******************************************************************************
// Copyright (c) 2003-2025 Cadence Design Systems, Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
// CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
// SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--------------------------------------------------------------------------------
*/

// perf_test.c -- measure FreeRTOS operation timing.

#include <stdio.h>
#include "jv_platform.h"
#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"
#include "event_groups.h"
#include "queue.h"
#include "testcommon.h"

#define TEST_ITER           3
#define PERF_TEST_PRIORITY  5  // Priorities will vary between 2 and 7

int get_timer(void) {
    int cycles;
    asm volatile ("rdcycle %0" : "=r"(cycles));
    return cycles;
}

//-----------------------------------------------------------------------------
// Thread function for yield test. Store current cycle count and yield the
// CPU right away.
//-----------------------------------------------------------------------------

static uint32_t printStats = 1;

static uint32_t clock_vals[TEST_ITER * 3] = {0};
static char clock_interrupted[TEST_ITER * 3] = {0};
static volatile uint32_t indx = 0;
static uint32_t uiTaskResponse[4];
static volatile uint32_t test_start = 0;
static uint32_t test_total;
static uint32_t test_max;

static SemaphoreHandle_t  xSemaphore;
static SemaphoreHandle_t  xMutex;
static EventGroupHandle_t xGroupEvents;
static QueueHandle_t      xQueue;

// Compute statistics
typedef struct {
    int cnt;
    int sum;
    int min;
    int max;
} stats_t;

void vApplicationMallocFailedHook(void) {
    printf("Malloc failed!\n");
    while(1);
}

static void stats_reset(stats_t *s)
{
    s->cnt = s->sum = 0;
    s->max = -0x7FFFFFFF; // Small number
    s->min =  0x7FFFFFFF; // Large number
}

static void stats_update(stats_t *s, int value)
{
    s->cnt++;
    s->sum += value;
    if (s->max < value)
        s->max = value;
    if (s->min > value)
        s->min = value;
}

static void yield_func(void * arg)
{
    int32_t i;
    volatile uint32_t* pResponse = (volatile uint32_t*)arg;
    *pResponse = 0;

    for (i = 0; i < TEST_ITER; i++)
    {
        // In FreeRTOS, context switch can occur after interrupts, which can preempt this task for another one of equal priority
        // Hence we disable interrupts for proper behavior. The extras are time calibrated and corrected.
        portENTER_CRITICAL();
        clock_vals[indx++] = get_timer();
        portEXIT_CRITICAL();
        taskYIELD();
    }

    *pResponse = 1;

    vTaskDelete(NULL);
}

//-----------------------------------------------------------------------------
// Task creation wrapper.
//-----------------------------------------------------------------------------
BaseType_t task_create( TaskFunction_t pvTaskCode,
                        const char * const pcName,
                        configSTACK_DEPTH_TYPE usStackDepth,
                        void * pvParameters,
                        UBaseType_t uxPriority,
                        TaskHandle_t *pxCreatedTask)
{
    BaseType_t xret;

    xret = xTaskCreate(pvTaskCode, pcName, usStackDepth, pvParameters,
                       uxPriority, pxCreatedTask);
    if (xret != pdPASS) {
        fprintf(stderr, "Error creating task '%s'\n", pcName);
        jv_exit(-1);
    }

    return xret;
}

//-----------------------------------------------------------------------------
// Helper thread for semaphore tests.
//-----------------------------------------------------------------------------
void sem_get(void * arg)
{
    uint32_t end;
    uint32_t i;
    volatile uint32_t* pResponse = (volatile uint32_t*)arg;

    *pResponse = 0;
    for(i = 0; i < TEST_ITER; i++) {
        xSemaphoreTake(xSemaphore, portMAX_DELAY);
        end = get_timer();
        if (test_start) {
            uint32_t delta = end - test_start;

            test_total += delta;
            test_max = test_max >= delta ? test_max : delta;
        }
    }
    *pResponse = 1;
    vTaskDelete(NULL);
}

//-----------------------------------------------------------------------------
// Semaphore operations timing test.
//-----------------------------------------------------------------------------
void sem_test(void * arg)
{
    uint32_t start;
    uint32_t delta;
    uint32_t total = 0;
    uint32_t max   = 0;
    uint32_t i;
    TaskHandle_t thandle;
    volatile uint32_t* pResponse = (volatile uint32_t*)arg;

    *pResponse = 0;

    printf("\nSemaphore timing test"
           "\n---------------------\n");

    xSemaphore = xSemaphoreCreateCounting( TEST_ITER, 0 );

    // First, just measure how long it takes to get and put a semaphore
    // with no contention and no waits/wakeups.

    for(i = 0; i < TEST_ITER; i++) {
        start = get_timer();
        xSemaphoreGive(xSemaphore);
        delta = get_timer() - start;
        total += delta;
        max = max >= delta ? max : delta;
    }

    if (printStats)
        printf("Semaphore put with no wake           : avg %lu max %lu cycles\n", total/TEST_ITER, max);

    // Measure time to get a semaphore with no contention and no waits/
    // wakeups.
    total = 0;
    max = 0;

    for(i = 0; i < TEST_ITER; i++) {
        start = get_timer();
        xSemaphoreTake(xSemaphore, portMAX_DELAY);
        delta = get_timer() - start;
        total += delta;
        max = max >= delta ? max : delta;
    }

    if (printStats)
        printf("Semaphore get with no contention     : avg %lu max %lu cycles\n", total/TEST_ITER, max);

    // Now measure the time taken to put a semaphore when a lower priority
    // thread has to be unblocked.

    uiTaskResponse[0] = 0;
    task_create(sem_get, "sem_get", configMINIMAL_STACK_SIZE, (void *)&uiTaskResponse[0], portPRIVILEGE_BIT | (PERF_TEST_PRIORITY - 1), NULL);

    total = 0;
    max = 0;

    for(i = 0; i < TEST_ITER; i++) {
        // Yield CPU so that lower priority thread can run and block itself
        // on the semaphore.
        vTaskDelay(1);
        start = get_timer();
        xSemaphoreGive(xSemaphore);
        delta = get_timer() - start;
        total += delta;
        max = max >= delta ? max : delta;
    }

    while (!uiTaskResponse[0])
    {
        vTaskDelay(1);
    }

    if (printStats)
        printf("Semaphore put with thread wake       : avg %lu max %lu cycles\n", total/TEST_ITER, max);

    // Now measure the time taken to put a semaphore + context switch when
    // a higher priority thread is unblocked.

    task_create(sem_get, "sem_get", configMINIMAL_STACK_SIZE, (void *)&uiTaskResponse[0], portPRIVILEGE_BIT | (PERF_TEST_PRIORITY + 1), &thandle);
    UNUSED(thandle);

    test_total = 0;
    test_max = 0;

    for(i = 0; i < TEST_ITER; i++) {
        // No need to yield CPU here since the other thread is at a higher priority.
        test_start = get_timer();
        xSemaphoreGive(xSemaphore);
    }

    while (!uiTaskResponse[0])
    {
        vTaskDelay(1);
    }

    if (printStats)
        printf("Semaphore put with context switch    : avg %lu max %lu cycles\n", test_total/TEST_ITER, test_max);
    *pResponse = 1;

    vSemaphoreDelete(xSemaphore);
    vTaskDelete(NULL);
}

//-----------------------------------------------------------------------------
// Helper thread for mutex tests.
//-----------------------------------------------------------------------------
void mutex_get(void * arg)
{
    uint32_t i;
    volatile uint32_t* pResponse = (volatile uint32_t*)arg;
    *pResponse = 0;

    for(i = 0; i < TEST_ITER; i ++)
    {
        xSemaphoreTake(xMutex, portMAX_DELAY);
        xSemaphoreGive(xMutex);
    }

    *pResponse = 1;
    vTaskDelete(NULL);
}

//-----------------------------------------------------------------------------
// Helper thread 2 for mutex tests.
//-----------------------------------------------------------------------------
void mutex_get2(void * arg)
{
    uint32_t delta;
    uint32_t i;
    volatile uint32_t* pResponse = (volatile uint32_t*)arg;
    *pResponse = 0;

    for(i = 0; i < TEST_ITER; i ++)
    {
        // First get the semaphore to sync with lower priority thread
        xSemaphoreTake(xSemaphore, portMAX_DELAY);
        // Now block on the mutex
        xSemaphoreTake(xMutex, portMAX_DELAY);
        delta = get_timer() - test_start;
        test_total += delta;
        test_max = test_max >= delta ? test_max : delta;
        xSemaphoreGive(xMutex);
    }

    *pResponse = 1;
    vTaskDelete(NULL);
}

//-----------------------------------------------------------------------------
// Mutex operations timing test.
//-----------------------------------------------------------------------------
void mutex_test(void * arg)
{
    uint32_t start;
    uint32_t delta;
    uint32_t total;
    uint32_t max;
    uint32_t i;
    TaskHandle_t thandle;
    volatile uint32_t* pResponse = (volatile uint32_t*)arg;
    *pResponse = 0;
    printf("\nMutex timing test"
           "\n-----------------\n");

    xMutex = xSemaphoreCreateMutex();
    vSemaphoreCreateBinary(xSemaphore);

    // First, just measure how long it takes to lock a mutex with no contention
    // and no waits/wakeups. Also measure how long it takes to unlock.

    test_total = 0;
    test_max = 0;
    total = 0;
    max = 0;

    for(i = 0; i < TEST_ITER; i++)
    {
        start = get_timer();
        xSemaphoreTake(xMutex, portMAX_DELAY);
        delta = get_timer() - start;
        test_total += delta;
        test_max = test_max >= delta ? test_max : delta;

        start = get_timer();
        xSemaphoreGive(xMutex);
        delta = get_timer() - start;
        total += delta;
        max = max >= delta ? max : delta;
    }

    if (printStats){
        printf("Mutex lock with no wake/contention   : avg %lu max %lu cycles\n",
                test_total/TEST_ITER, test_max);
        printf("Mutex unlock with no wake/contention : avg %lu max %lu cycles\n",
                total/TEST_ITER, max);
    }

    // Now measure the time taken to unlock a mutex when a lower priority
    // thread has to be unblocked.
    uiTaskResponse[1] = 0;
    task_create(mutex_get, "mutex_get", configMINIMAL_STACK_SIZE, (void *)&uiTaskResponse[1], portPRIVILEGE_BIT | (PERF_TEST_PRIORITY - 1), NULL);

    test_total = 0;
    test_max = 0;

    for(i = 0; i < TEST_ITER; i++)
    {
        xSemaphoreTake(xMutex, portMAX_DELAY);
        // Let the other thread run so that it can block on the mutex
        vTaskDelay(1);
        start = get_timer();
        xSemaphoreGive(xMutex);
        delta = get_timer() - start;
        test_total += delta;
        test_max = test_max >= delta ? test_max : delta;
    }

    while (!uiTaskResponse[1])
    {
        vTaskDelay(1);
    }

    if (printStats)
        printf("Mutex unlock with thread wake        : avg %lu max %lu cycles\n",
                test_total/TEST_ITER, test_max);

    // Now measure the time taken to unlock a mutex + context switch when
    // a higher priority thread is unblocked.

    task_create(mutex_get2, "mutex_get2", configMINIMAL_STACK_SIZE, (void *)&uiTaskResponse[1], portPRIVILEGE_BIT | (PERF_TEST_PRIORITY + 1), &thandle);
    UNUSED(thandle);

    test_total = 0;
    test_max = 0;

    for(i = 0; i < TEST_ITER; i++)
    {
        xSemaphoreTake(xMutex, portMAX_DELAY);
        // Now signal the other thread with the semaphore. This will cause an
        // immediate switch to the other thread, which will then block on the
        // mutex and give back control to here.
        xSemaphoreGive(xSemaphore);
        test_start = get_timer();
        xSemaphoreGive(xMutex);
    }

    while (!uiTaskResponse[1])
    {
        vTaskDelay(1);
    }

    if (printStats)
        printf("Mutex unlock with context switch     : avg %lu max %lu cycles\n",
                test_total/TEST_ITER, test_max);

    vSemaphoreDelete(xSemaphore);
    vSemaphoreDelete(xMutex);

    *pResponse = 1;
    vTaskDelete(NULL);
}

//-----------------------------------------------------------------------------
// Helper thread for event tests.
//-----------------------------------------------------------------------------
void event_get(void * arg)
{
    uint32_t i;
    volatile uint32_t* pResponse = (volatile uint32_t*)arg;

    *pResponse = 0;
    for(i = 0; i < TEST_ITER; i ++)
    {
        xEventGroupWaitBits(xGroupEvents, 0xFFFF, pdFALSE, pdTRUE, portMAX_DELAY);
        xEventGroupClearBits(xGroupEvents, 0xFFFF);
    }

    *pResponse = 1;
    vTaskDelete(NULL);
}

//-----------------------------------------------------------------------------
// Helper thread 2 for event tests.
//-----------------------------------------------------------------------------
void event_get2(void * arg)
{
    uint32_t delta;
    uint32_t i;

    volatile uint32_t* pResponse = (volatile uint32_t*)arg;

    *pResponse = 0;
    for(i = 0; i < TEST_ITER; i ++)
    {
        // First get the semaphore to sync with lower priority thread
        xSemaphoreTake(xSemaphore, portMAX_DELAY);
        // Now block on the event
        xEventGroupWaitBits(xGroupEvents, 0xFFFF, pdFALSE, pdTRUE, portMAX_DELAY);
        delta = get_timer() - test_start;
        test_total += delta;
        test_max = test_max >= delta ? test_max : delta;
        xEventGroupClearBits(xGroupEvents, 0xFFFF);
    }

    *pResponse = 1;
    vTaskDelete(NULL);
}

//-----------------------------------------------------------------------------
// Event operations timing test.
//-----------------------------------------------------------------------------
void event_test(void * arg)
{
    uint32_t start;
    uint32_t delta;
    uint32_t total;
    uint32_t max;
    uint32_t i;

    TaskHandle_t thandle;
    volatile uint32_t* pResponse = (volatile uint32_t*)arg;

    *pResponse = 0;

    printf("\nEvent timing test"
           "\n-----------------\n");

    xGroupEvents = xEventGroupCreate();
    vSemaphoreCreateBinary(xSemaphore);

    // First, just measure how long it takes to set an event with no contention
    // and no waits/wakeups. Also measure how long it takes to clear.

    test_total = 0;
    test_max = 0;
    total = 0;
    max = 0;

    for(i = 0; i < TEST_ITER; i++)
    {
        start = get_timer();
        xEventGroupSetBits(xGroupEvents, 0xFFFF);
        delta = get_timer() - start;
        test_total += delta;
        test_max = test_max >= delta ? test_max : delta;

        start = get_timer();
        xEventGroupClearBits(xGroupEvents, 0xFFFF);
        delta = get_timer() - start;
        total += delta;
        max = max >= delta ? max : delta;
    }

    if (printStats) {
        printf("Event set with no wake/contention    : avg %lu max %lu cycles\n",
                test_total/TEST_ITER, test_max);
        printf("Event clear with no wake/contention  : avg %lu max %lu cycles\n",
                total/TEST_ITER, max);
    }

    // Now measure the time taken to set an event when a lower priority
    // thread has to be unblocked.
    uiTaskResponse[1] = 0;
    task_create(event_get, "event_get", configMINIMAL_STACK_SIZE, (void *)&uiTaskResponse[1], portPRIVILEGE_BIT | (PERF_TEST_PRIORITY - 1), NULL);

    // Let the other thread run so that it can block on the event
    vTaskDelay(1);

    test_total = 0;
    test_max = 0;

    for(i = 0; i < TEST_ITER; i++)
    {
        xEventGroupClearBits(xGroupEvents, 0xFFFF);
        // Let the other thread run so that it can block on the event
        vTaskDelay(1);
        start = get_timer();
        xEventGroupSetBits(xGroupEvents, 0xFFFF);
        delta = get_timer() - start;
        test_total += delta;
        test_max = test_max >= delta ? test_max : delta;
    }

    while (!uiTaskResponse[1])
    {
        vTaskDelay(1);
    }

    if (printStats)
        printf("Event set with thread wake           : avg %lu max %lu cycles\n",
                test_total/TEST_ITER, test_max);

    // Now measure the time taken to set an event + context switch when
    // a higher priority thread is unblocked.

    uiTaskResponse[1] = 0;
    task_create(event_get2, "event_get2", configMINIMAL_STACK_SIZE, (void *)&uiTaskResponse[1], portPRIVILEGE_BIT | (PERF_TEST_PRIORITY + 1), &thandle);
    UNUSED(thandle);

    test_total = 0;
    test_max = 0;

    for(i = 0; i < TEST_ITER; i++)
    {
        xEventGroupClearBits(xGroupEvents, 0xFFFF);
        // Now signal the other thread with the semaphore. This will cause an
        // immediate switch to the other thread, which will then block on the
        // event and give back control to here.
        xSemaphoreGive(xSemaphore);
        test_start = get_timer();
        xEventGroupSetBits(xGroupEvents, 0xFFFF);
    }

    while (!uiTaskResponse[1])
    {
        vTaskDelay(1);
    }

    if (printStats)
        printf("Event set with context switch        : avg %lu max %lu cycles\n",
                test_total/TEST_ITER, test_max);

    vSemaphoreDelete(xSemaphore);
    vEventGroupDelete(xGroupEvents);

    *pResponse = 1;
    vTaskDelete(NULL);
}

//-----------------------------------------------------------------------------
// Helper thread for message queue tests.
//-----------------------------------------------------------------------------
void msg_get(void * arg)
{
    uint32_t i;
    uint32_t msg[4];
    volatile uint32_t* pResponse = (volatile uint32_t*)arg;

    *pResponse = 0;
    for(i = 0; i < TEST_ITER; i++)
    {
        xQueueReceive(xQueue, msg, portMAX_DELAY);
    }

    *pResponse = 1;
    vTaskDelete(NULL);
}

//-----------------------------------------------------------------------------
// Helper thread 2 for message queue tests.
//-----------------------------------------------------------------------------
void msg_get2(void * arg)
{
    uint32_t delta;
    uint32_t i;
    uint32_t msg[4];
    volatile uint32_t* pResponse = (volatile uint32_t*)arg;

    *pResponse = 0;
    for(i = 0; i < TEST_ITER; i++)
    {
        // First get the semaphore to sync with lower priority thread
        xSemaphoreTake(xSemaphore, portMAX_DELAY);
        // Now block on the queue
        xQueueReceive(xQueue, msg, portMAX_DELAY);
        delta = get_timer() - test_start;
        test_total += delta;
        test_max = test_max >= delta ? test_max : delta;
 //       xEventGroupClearBits(xGroupEvents, 0xFFFF);
    }

    *pResponse = 1;
    vTaskDelete(NULL);
}

//-----------------------------------------------------------------------------
// Message queue test.
//-----------------------------------------------------------------------------
void msgq_test(void* arg)
{
    int32_t  i;
    uint32_t msg[4];
    uint32_t sum = 0;
    uint32_t max = 0;
    uint32_t start;
    uint32_t delta;
    uint32_t get_avg, get_max, put_avg, put_max;

    TaskHandle_t thandle;
    volatile uint32_t* pResponse = (volatile uint32_t*)arg;

    *pResponse = 0;

    printf("\nMessage Queue timing test"
           "\n-------------------------\n");

    // First, measure the time taken to put and get messages on the queue
    // when no thread wakeup/context switch is involved.
    vSemaphoreCreateBinary(xSemaphore);
    xQueue = xQueueCreate(16, 4 * sizeof(uint32_t));

    for (i = 0; i < 16; i++)
    {
        start = get_timer();
        xQueueSend(xQueue, msg, portMAX_DELAY);
        delta = get_timer() - start;
        sum += delta;
        max = max >= delta ? max : delta;
    }

    put_avg = sum/16;
    put_max = max;

    sum = 0;
    max = 0;

    for (i = 0; i < 16; i++)
    {
        start = get_timer();

        xQueueReceive(xQueue, msg, portMAX_DELAY);
        delta = get_timer() - start;
        sum += delta;
        max = max >= delta ? max : delta;
    }

    get_avg = sum/16;
    get_max = max;

    if (printStats) {
        printf("Message put with no wake/contention  : avg %lu max %lu cycles\n",
                put_avg, put_max);
        printf("Message get with no wake/contention  : avg %lu max %lu cycles\n",
                get_avg, get_max);
    }

    // Now measure the time taken to send a message when a lower priority
    // thread has to be unblocked.

    uiTaskResponse[1] = 0;
    task_create(msg_get, "msg_get", configMINIMAL_STACK_SIZE, (void *)&uiTaskResponse[1], portPRIVILEGE_BIT | (PERF_TEST_PRIORITY - 1), NULL);

    test_total = 0;
    test_max = 0;

    for(i = 0; i < TEST_ITER; i++)
    {
        // Let the other thread run so that it can block on the queue
        vTaskDelay(1);
        start = get_timer();
        xQueueSend(xQueue, msg, portMAX_DELAY);
        delta = get_timer() - start;
        test_total += delta;
        test_max = test_max >= delta ? test_max : delta;
    }

    while (!uiTaskResponse[1])
    {
        vTaskDelay(1);
    }

    if (printStats)
        printf("Message put with thread wake         : avg %lu max %lu cycles\n",
                test_total/TEST_ITER, test_max);

    // Now measure the time taken to send a message + context switch when
    // a higher priority thread is unblocked.

    uiTaskResponse[1] = 0;
    task_create(msg_get2, "msg_get2", configMINIMAL_STACK_SIZE, (void *)&uiTaskResponse[1], portPRIVILEGE_BIT | (PERF_TEST_PRIORITY + 1), &thandle);
    UNUSED(thandle);

    test_total = 0;
    test_max = 0;

    for(i = 0; i < TEST_ITER; i++)
    {
        // Now signal the other thread with the semaphore. This will cause an
        // immediate switch to the other thread, which will then block on the
        // msg queue and give back control to here.
        xSemaphoreGive(xSemaphore);
        test_start = get_timer();
        xQueueSend(xQueue, msg, portMAX_DELAY);
    }

    while (!uiTaskResponse[1])
    {
        vTaskDelay(1);
    }

    if (printStats)
        printf("Message put with context switch      : avg %lu max %lu cycles\n",
                test_total/TEST_ITER, test_max);

    *pResponse = 1;
    vTaskDelete(NULL);
}

//-----------------------------------------------------------------------------
// Yield test - runs in main thread. Start 3 threads to measure the context
// switch time. Wait for them all to exit. Then compute the average and worst
// case switch times.
//-----------------------------------------------------------------------------
void yieldTest(void)
{
#define OVERHEAD_MEASUREMENT_RPT    10
    uint32_t oh_cycles;
    int32_t  i;

    printf("\nYield timing test"
           "\n-----------------\n");

    // Measure the overhead of updating the cycle count

    portENTER_CRITICAL();

    for (i = 0; i < OVERHEAD_MEASUREMENT_RPT; i++) {
        // Copied from yield_func to calibrate timing
        portENTER_CRITICAL();
        clock_vals[indx++] = get_timer();
        portEXIT_CRITICAL();
    }

    portEXIT_CRITICAL();

    oh_cycles = (clock_vals[indx-1] - clock_vals[indx-OVERHEAD_MEASUREMENT_RPT]) / (OVERHEAD_MEASUREMENT_RPT -1);
    indx = 0;

    // Launch test threads
    uiTaskResponse[0] = uiTaskResponse[1] = uiTaskResponse[2] = 0;
    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY + 2);
    task_create( yield_func, "thd1", configMINIMAL_STACK_SIZE, (void *)&uiTaskResponse[0], portPRIVILEGE_BIT | (PERF_TEST_PRIORITY +2), NULL );
    task_create( yield_func, "thd2", configMINIMAL_STACK_SIZE, (void *)&uiTaskResponse[1], portPRIVILEGE_BIT | (PERF_TEST_PRIORITY +2), NULL );
    task_create( yield_func, "thd3", configMINIMAL_STACK_SIZE, (void *)&uiTaskResponse[2], portPRIVILEGE_BIT | (PERF_TEST_PRIORITY +2), NULL );

    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY);
    // Wait for them all to finish
    while (3 > (uiTaskResponse[0] + uiTaskResponse[1] + uiTaskResponse[2]))
    {
        vTaskDelay(1);
    }

    // Compute average values for solicited context switch
    stats_t solicited;
    stats_reset(&solicited);

    // Throw first and last values containing delete tasks instructions (FreeRTOS) and such
    // Use an adaptive skip so short runs (small TEST_ITER) still produce valid results.
    int front_skip = (indx > 6) ? 2 : 1;
    int back_skip  = (indx > 4) ? 3 : 1;
    for (i = front_skip; i < indx - back_skip; i++) {
        if (clock_interrupted[i]) {
            i += 2; // Skip region perturbed by interrupt
            continue;
        }
        uint32_t delta = clock_vals[i] - clock_vals[i-1] - oh_cycles;
        stats_update(&solicited, (int)delta);
    }

    if (printStats && solicited.cnt > 0)
        printf("Solicited context switch time : min %u avg %u max %u cycles [calibration %lu]\n",
                (unsigned)solicited.min,
                (unsigned)(solicited.sum / solicited.cnt),
                (unsigned)solicited.max,
                oh_cycles);

}

volatile unsigned unsolicited_done = 0;
volatile unsigned unsolicited_cycles = 0;
stats_t unsolicited_stats;

// Background task
void unsolicited_background(void *arg)
{
    (void)(arg);
    while (!unsolicited_done) {
        unsolicited_cycles = get_timer();  // Keep recording the counter's value
    }
    vTaskDelete(NULL);
}

// Preempting task (we measure the unsolicited context switch time)
void unsolicited_hipriority(void *arg)
{
    int i;
    (void)(arg);
    for (i = 0; i < 16; i++) {
        vTaskDelay(1); // Give time to background task
        unsigned cycles = get_timer() - unsolicited_cycles;
        stats_update(&unsolicited_stats, cycles);
    }
    unsolicited_done = 1;
    vTaskDelete(NULL);
}

//-----------------------------------------------------------------------------
// Unsolicited test - runs in main thread. Starts 2 threads to measure the context
// switch time. Wait for them all to exit.
//-----------------------------------------------------------------------------
void unsolicitedTest(void)
{
    TaskHandle_t thd_bg_h, thd_hi_h;

    printf("\nUnsolicited context switch timing test"
           "\n--------------------------------------\n");

    stats_reset(&unsolicited_stats);

    // Launch test threads
    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY + 2);

    task_create( unsolicited_background, "thd_bg", configMINIMAL_STACK_SIZE, NULL, portPRIVILEGE_BIT | (PERF_TEST_PRIORITY + 1), &thd_bg_h );
    UNUSED(thd_bg_h);
    task_create( unsolicited_hipriority, "thd_hi", configMINIMAL_STACK_SIZE, NULL, portPRIVILEGE_BIT | (PERF_TEST_PRIORITY + 2), &thd_hi_h );
    UNUSED(thd_hi_h);

    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY);

    // Wait for them all to finish
    while (!unsolicited_done)
        vTaskDelay(1);

    // Calibrate read counter function (approximate calibration)
    unsigned calib = get_timer();
    calib = get_timer() - calib;

    if (printStats)
        printf("Unsolicited context switch time      : min %u avg %u max %u cycles [calibration %u]\n",
                (unsigned)unsolicited_stats.min - calib,
                (unsigned)(unsolicited_stats.sum + unsolicited_stats.cnt - 1) /
                    (unsigned)unsolicited_stats.cnt - calib,
                (unsigned)unsolicited_stats.max - calib,
                calib);

}

//-----------------------------------------------------------------------------
// Semaphore test.
//-----------------------------------------------------------------------------
void semaphoreTest(void)
{
    uiTaskResponse[1] = 0;
    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY + 1);
    task_create( sem_test, "sem_test", configMINIMAL_STACK_SIZE, (void *)&uiTaskResponse[1], portPRIVILEGE_BIT | PERF_TEST_PRIORITY, NULL );
    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY - 3);
    while (!uiTaskResponse[1])
    {
        vTaskDelay(1);
    }
    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY);
}

void mutexTest(void)
{
    uiTaskResponse[0] = 0;
    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY + 1);
    task_create( mutex_test, "mutex_test", configMINIMAL_STACK_SIZE, (void *)&uiTaskResponse[0], portPRIVILEGE_BIT | PERF_TEST_PRIORITY, NULL );
    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY - 2);
    while (!uiTaskResponse[0])
    {
        vTaskDelay(1);
    }
    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY);
}

void eventTest(void)
{
    uiTaskResponse[0] = 0;
    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY + 1);
    task_create( event_test, "event_test", configMINIMAL_STACK_SIZE, (void *)&uiTaskResponse[0], portPRIVILEGE_BIT | PERF_TEST_PRIORITY, NULL );
    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY - 2);
    while (!uiTaskResponse[0])
    {
        vTaskDelay(1);
    }
    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY);
}

void queueTest(void)
{
    uiTaskResponse[0] = 0;
    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY + 1);
    task_create( msgq_test, "msgq_test", configMINIMAL_STACK_SIZE, (void *)&uiTaskResponse[0], portPRIVILEGE_BIT | PERF_TEST_PRIORITY, NULL );
    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY - 2);
    while (!uiTaskResponse[0])
    {
        vTaskDelay(1);
    }
    vTaskPrioritySet( NULL, PERF_TEST_PRIORITY);
}

void test(void* pArg)
{
    UNUSED(pArg);

    /* Delays between tests are inserted to allow the idle task to run.
       The idle task frees up memory from deleted tasks and makes that
       memory available to the next test.
     */
    yieldTest();
    vTaskDelay(1);
    unsolicitedTest();
    vTaskDelay(1);
    semaphoreTest();
    vTaskDelay(1);
    mutexTest();
    vTaskDelay(1);
    eventTest();
    vTaskDelay(1);
    queueTest();
    printf("\nTest PASSED\n");
    jv_exit(0);
}

int main(void)
{
    task_create( test, "test", configMINIMAL_STACK_SIZE, (void *)NULL, portPRIVILEGE_BIT | PERF_TEST_PRIORITY , NULL );
    /* Finally start the scheduler. */
    vTaskStartScheduler();
    /* Will only reach here if there is insufficient heap available to start
    the scheduler. */
    for( ;; );
    return 0;
}
