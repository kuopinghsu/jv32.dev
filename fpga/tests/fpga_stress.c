/*
 * fpga_stress.c  —  JV32 FPGA Long-Running FreeRTOS Stability Test
 *
 * Designed to run for weeks on the FPGA, exercising all major FreeRTOS
 * synchronisation primitives and detecting FPGA / RTL stability issues.
 *
 * Modules
 * -------
 *   A. CPU hash workers   (2 tasks)  CRC-32 of a 256-byte buffer in a tight
 *                                    loop; result verified every iteration.
 *   B. Queue pipeline     (2 tasks)  Producer sends messages with sequence
 *                                    number and CRC-32 payload; consumer
 *                                    verifies both fields.
 *   C. Event-group barrier(4 tasks)  Four workers rendezvous each round via
 *                                    xEventGroupSync(), cycling continuously.
 *   D. Semaphore ping-pong(2 tasks)  Two tasks alternate on binary semaphores
 *                                    at full scheduler speed.
 *   E. Recursive mutex    (3 tasks)  Three tasks compete for a depth-3
 *                                    recursive mutex; shared counter verified
 *                                    under lock.
 *   F. Memory stress      (1 task)   Heap alloc → fill → verify → free at
 *                                    sizes 32 → 64 → 128 → 256 bytes, cycling.
 *   G. Heartbeat reporter (1 task)   Prints one status line via UART every
 *                                    HEARTBEAT_INTERVAL_S real seconds.
 *   H. Watchdog timer               30-second FreeRTOS auto-reload timer;
 *                                    each module must set its bit each period
 *                                    or a fault message is printed.
 *
 * UART output: 921600 8N1 on the on-chip AXI UART.
 *   Linux:  stty -F /dev/ttyUSBx 921600 raw && cat /dev/ttyUSBx
 *   Win:    PuTTY / TeraTerm at 921600 8N1
 *
 * Output format (one line every 5 s):
 *   [HHH:MM:SS] A=<cpu_iters> B=<q_sent> C=<ev_rounds> D=<sem_rounds>
 *               E=<mtx_iters> F=<mem_allocs> err=<total> heap=<free> wdf=<wdog_faults>
 *
 * Build:  make -C fpga/tests build
 * Flash:  openocd -f fpga/jtag/jv32_fpga_cjtag.cfg \
 *                 -c "program build/fpga-stress.elf verify reset exit"
 */

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "semphr.h"
#include "event_groups.h"
#include "timers.h"

#include "jv_platform.h"
#include "jv_uart.h"

/* =========================================================================
 * Hardware / timing constants
 * ========================================================================= */

#define FPGA_CLK_HZ         50000000UL  /* 50 MHz FPGA system clock           */
#define UART_BAUD           921600UL    /* Target baud — max reliable PC USB   */
/*
 * CLKS_PER_BIT = 50 000 000 / 921 600 ≈ 54.25 → rounded to 54.
 * Actual baud  = 50 000 000 / 54 ≈ 925 926  (0.47 % error — within spec).
 * baud_div     = CLKS_PER_BIT - 1 = 53.
 */
#define UART_BAUD_DIV       ((uint32_t)((FPGA_CLK_HZ / UART_BAUD) - 1U))  /* 53 */

/*
 * FreeRTOS is configured for configCPU_CLOCK_HZ = 100 MHz, but the FPGA
 * runs at 50 MHz.  The mtime tick fires at half the configured rate, giving
 * ~500 ticks/s.  Relative vTaskDelay() calls still work correctly; we just
 * adjust when converting ticks to wall-clock seconds for display.
 */
#define REAL_TICKS_PER_SEC  500U

/* =========================================================================
 * Stress-test tunables
 * ========================================================================= */

#define HEARTBEAT_INTERVAL_S    5U          /* status line period (real seconds)  */
#define WATCHDOG_PERIOD_S      30U          /* watchdog check period (real seconds)*/
#define EG_NUM_WORKERS          4U          /* event-group barrier participants    */
#define QUEUE_DEPTH            16U          /* message queue depth (Module B)      */
#define MEM_MIN_BYTES          32U          /* smallest allocation in Module F     */
#define MEM_MAX_BYTES         256U          /* largest allocation in Module F      */
#define MEM_FILL_PATTERN       0xA5U        /* byte pattern written & verified     */
#define MUTEX_DEPTH             3           /* recursive lock depth in Module E    */
#define SEM_TIMEOUT_MS       5000U          /* per-transfer semaphore timeout      */

/* =========================================================================
 * Task priorities  (0 = idle, configMAX_PRIORITIES-1 = highest)
 * ========================================================================= */

#define PRIO_HEARTBEAT      (tskIDLE_PRIORITY + 1U)
#define PRIO_MEM            (tskIDLE_PRIORITY + 2U)
#define PRIO_CPU            (tskIDLE_PRIORITY + 2U)
#define PRIO_MUTEX          (tskIDLE_PRIORITY + 2U)
#define PRIO_SEM            (tskIDLE_PRIORITY + 3U)
#define PRIO_QUEUE          (tskIDLE_PRIORITY + 3U)
#define PRIO_EG_WORKER      (tskIDLE_PRIORITY + 3U)

/* =========================================================================
 * Watchdog bit assignments
 * ========================================================================= */

#define WDOG_BIT_CPU        (1u << 0)
#define WDOG_BIT_QUEUE      (1u << 1)
#define WDOG_BIT_EVENT      (1u << 2)
#define WDOG_BIT_SEM        (1u << 3)
#define WDOG_BIT_MUTEX      (1u << 4)
#define WDOG_BIT_MEM        (1u << 5)
#define WDOG_ALL_BITS       0x3Fu

/* =========================================================================
 * Global synchronisation objects
 * ========================================================================= */

static SemaphoreHandle_t  g_uart_mutex;     /* serialise all UART writes          */
static SemaphoreHandle_t  g_wdog_mutex;     /* protect g_wdog_mask                */
static volatile uint32_t  g_wdog_mask;      /* bits set by live modules            */

/* Module B */
static QueueHandle_t      g_pipeline;

/* Module C */
static EventGroupHandle_t g_barrier;
#define EG_WORKER_BITS      ((EventBits_t)((1U << EG_NUM_WORKERS) - 1U))

/* Module D */
static SemaphoreHandle_t  g_sem_ping;
static SemaphoreHandle_t  g_sem_pong;

/* Module E */
static SemaphoreHandle_t  g_rmutex;
static volatile uint32_t  g_rmutex_ctr;

/* =========================================================================
 * Per-module statistics
 * Written exclusively by the owning task → no locking required for writes.
 * The heartbeat task reads them for display; occasional torn reads are
 * acceptable (they self-correct on the next heartbeat interval).
 * ========================================================================= */

static volatile uint32_t g_cpu_iters;
static volatile uint32_t g_cpu_errors;
static volatile uint32_t g_queue_sent;
static volatile uint32_t g_queue_errors;
static volatile uint32_t g_event_rounds;
static volatile uint32_t g_event_errors;
static volatile uint32_t g_sem_rounds;
static volatile uint32_t g_sem_errors;
static volatile uint32_t g_mutex_iters;
static volatile uint32_t g_mutex_errors;
static volatile uint32_t g_mem_allocs;
static volatile uint32_t g_mem_errors;
static volatile uint32_t g_wdog_faults;

/* =========================================================================
 * Watchdog helper — any task may call this from any context.
 * ========================================================================= */

static void wdog_pet(uint32_t bit)
{
    if (xSemaphoreTake(g_wdog_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
        g_wdog_mask |= bit;
        xSemaphoreGive(g_wdog_mutex);
    }
}

/* =========================================================================
 * UART output helpers
 *
 * printf() is not used: _write() routes to the magic simulation device which
 * is not mapped on FPGA.  All output goes directly through the AXI UART.
 *
 * The caller MUST hold g_uart_mutex before calling any up_* function.
 * Use the UART_LOG_BEGIN / UART_LOG_END macros to bracket a log entry.
 * ========================================================================= */

#define UART_LOG_BEGIN()   xSemaphoreTake(g_uart_mutex, portMAX_DELAY)
#define UART_LOG_END()     xSemaphoreGive(g_uart_mutex)

static void up_char(char c) { jv_uart_putc(c); }
static void up_str(const char *s) { while (*s) up_char(*s++); }
static void up_crlf(void) { up_char('\r'); up_char('\n'); }

static void up_u32(uint32_t v)
{
    char buf[11];
    int  pos = 10;
    buf[pos] = '\0';
    if (v == 0u) {
        buf[--pos] = '0';
    } else {
        while (v != 0u) { buf[--pos] = (char)('0' + v % 10u); v /= 10u; }
    }
    up_str(&buf[pos]);
}

/* Zero-padded 2-digit decimal (minutes, seconds). */
static void up_d2(uint32_t v)
{
    up_char((char)('0' + (v / 10u) % 10u));
    up_char((char)('0' + v % 10u));
}

/* 2-digit uppercase hex (no "0x" prefix). */
static void up_hex8(uint32_t v)
{
    static const char h[] = "0123456789ABCDEF";
    up_char(h[(v >> 4) & 0xFu]);
    up_char(h[v & 0xFu]);
}

/*
 * Print [HHH:MM:SS] timestamp from a tick count.
 * Hours may exceed 99 for multi-day runs (week = 168 h).
 */
static void up_timestamp(TickType_t t)
{
    uint32_t sec = (uint32_t)t / REAL_TICKS_PER_SEC;
    up_char('[');
    up_u32(sec / 3600u);              /* hours — may be 3+ digits */
    up_char(':'); up_d2((sec % 3600u) / 60u);
    up_char(':'); up_d2(sec % 60u);
    up_char(']');
}

/* Print "key=value " pair (with trailing space). */
static void up_kv(const char *k, uint32_t v)
{
    up_str(k); up_char('='); up_u32(v); up_char(' ');
}

/* =========================================================================
 * CRC-32 (IEEE 802.3 / Ethernet, bit-serial, no lookup table)
 * Small code footprint; ~32 clock cycles per byte on RV32.
 * ========================================================================= */

static uint32_t crc32(const uint8_t *buf, uint32_t len)
{
    uint32_t crc = 0xFFFFFFFFu;
    for (uint32_t i = 0u; i < len; i++) {
        uint8_t b = buf[i];
        for (int k = 0; k < 8; k++) {
            uint32_t mix = (crc ^ (uint32_t)b) & 1u;
            crc >>= 1;
            if (mix) crc ^= 0xEDB88320u;
            b = (uint8_t)(b >> 1);
        }
    }
    return crc ^ 0xFFFFFFFFu;
}

/* =========================================================================
 * Module A: CPU hash workers  (2 tasks, tskIDLE_PRIORITY + 2)
 *
 * Each task maintains a 256-byte buffer initialised from a unique seed.
 * It repeatedly computes CRC-32 of the buffer and compares against a
 * reference computed at startup.  Any mismatch indicates memory corruption.
 * The buffer deliberately lives on the task stack to stress stack memory.
 * ========================================================================= */

static void vCpuWorker(void *pv)
{
    uint32_t seed = (uint32_t)(uintptr_t)pv;
    uint8_t  buf[256];

    /* Deterministic initialisation. */
    for (int i = 0; i < 256; i++)
        buf[i] = (uint8_t)(seed ^ (uint32_t)i ^ (seed >> 3));

    uint32_t expected = crc32(buf, 256u);

    for (;;) {
        uint32_t got = crc32(buf, 256u);
        if (got != expected)
            g_cpu_errors++;

        g_cpu_iters++;
        wdog_pet(WDOG_BIT_CPU);

        /* Yield every 64 iterations to give lower-priority tasks CPU time. */
        if ((g_cpu_iters & 63u) == 0u)
            taskYIELD();
    }
}

/* =========================================================================
 * Module B: Queue pipeline  (producer task + consumer task)
 *
 * Queue message layout: sequence number, 4 payload words derived from seq,
 * and a CRC-32 that covers all previous fields.  Consumer independently
 * recomputes the expected payload and CRC-32 and flags any discrepancy.
 * ========================================================================= */

typedef struct {
    uint32_t seq;
    uint32_t payload[4];
    uint32_t crc;      /* CRC-32 of everything before this field */
} QMsg_t;

static volatile uint32_t g_prod_seq;

static void vQueueProducer(void *pv)
{
    (void)pv;
    QMsg_t msg;

    for (;;) {
        uint32_t seq  = g_prod_seq++;
        msg.seq        = seq;
        msg.payload[0] = seq ^ 0xDEAD0000u;
        msg.payload[1] = seq + 0xBEEFu;
        msg.payload[2] = ~seq;
        msg.payload[3] = (seq << 3) | (seq >> 29);
        msg.crc        = crc32((const uint8_t *)&msg, offsetof(QMsg_t, crc));

        if (xQueueSend(g_pipeline, &msg, pdMS_TO_TICKS(2000)) != pdTRUE)
            g_queue_errors++;
        else
            g_queue_sent++;

        wdog_pet(WDOG_BIT_QUEUE);
    }
}

static void vQueueConsumer(void *pv)
{
    (void)pv;
    QMsg_t msg;

    for (;;) {
        if (xQueueReceive(g_pipeline, &msg, pdMS_TO_TICKS(4000)) != pdTRUE) {
            g_queue_errors++;
            continue;
        }

        /* Verify CRC-32 over header + payload. */
        uint32_t expected_crc = crc32((const uint8_t *)&msg, offsetof(QMsg_t, crc));
        if (msg.crc != expected_crc) {
            g_queue_errors++;
            wdog_pet(WDOG_BIT_QUEUE);
            continue;
        }

        /* Verify payload derivation from sequence number. */
        uint32_t seq = msg.seq;
        if (msg.payload[0] != (seq ^ 0xDEAD0000u) ||
            msg.payload[1] != (seq + 0xBEEFu)      ||
            msg.payload[2] != ~seq                   ||
            msg.payload[3] != ((seq << 3) | (seq >> 29))) {
            g_queue_errors++;
        }

        wdog_pet(WDOG_BIT_QUEUE);
    }
}

/* =========================================================================
 * Module C: Event-group barrier  (EG_NUM_WORKERS tasks)
 *
 * All workers rendezvous each round using xEventGroupSync().  Every task
 * sets its own bit and waits until all EG_WORKER_BITS are set.  FreeRTOS
 * then clears all bits atomically and unblocks every waiting task together.
 * This validates the scheduler's ability to unblock multiple tasks in one
 * tick and correctly manage EventGroup internals over millions of rounds.
 * ========================================================================= */

typedef struct { uint32_t id; } EGArg_t;
static EGArg_t g_eg_args[EG_NUM_WORKERS];

static void vEventWorker(void *pv)
{
    EGArg_t     *arg    = (EGArg_t *)pv;
    EventBits_t  my_bit = (EventBits_t)(1U << arg->id);

    for (;;) {
        EventBits_t result = xEventGroupSync(g_barrier,
                                             my_bit,
                                             EG_WORKER_BITS,
                                             portMAX_DELAY);
        if ((result & EG_WORKER_BITS) != EG_WORKER_BITS)
            g_event_errors++;

        g_event_rounds++;
        wdog_pet(WDOG_BIT_EVENT);

        /* Tiny delay proportional to worker id spreads unblock times. */
        if (arg->id == 0u)
            taskYIELD();     /* only one worker yields; others spin back */
    }
}

/* =========================================================================
 * Module D: Semaphore ping-pong  (2 tasks, alternating binary semaphores)
 *
 * vSemPing waits on g_sem_ping, increments g_sem_rounds, gives g_sem_pong.
 * vSemPong does the reverse.  A 5-second timeout on every Take detects hangs
 * and self-recovers by re-kicking the opposite semaphore.
 * ========================================================================= */

static void vSemPing(void *pv)
{
    (void)pv;
    const TickType_t tmo = pdMS_TO_TICKS(SEM_TIMEOUT_MS);

    for (;;) {
        if (xSemaphoreTake(g_sem_ping, tmo) != pdTRUE) {
            g_sem_errors++;
            xSemaphoreGive(g_sem_pong); /* re-kick the chain */
            continue;
        }
        g_sem_rounds++;
        wdog_pet(WDOG_BIT_SEM);
        xSemaphoreGive(g_sem_pong);
    }
}

static void vSemPong(void *pv)
{
    (void)pv;
    const TickType_t tmo = pdMS_TO_TICKS(SEM_TIMEOUT_MS);

    for (;;) {
        if (xSemaphoreTake(g_sem_pong, tmo) != pdTRUE) {
            g_sem_errors++;
            xSemaphoreGive(g_sem_ping);
            continue;
        }
        g_sem_rounds++;
        wdog_pet(WDOG_BIT_SEM);
        xSemaphoreGive(g_sem_ping);
    }
}

/* =========================================================================
 * Module E: Recursive mutex stress  (3 competing tasks)
 *
 * Each task locks g_rmutex to depth MUTEX_DEPTH, increments and immediately
 * verifies g_rmutex_ctr, then unwinds all MUTEX_DEPTH levels.  A mismatch
 * in the verified value indicates either a missed lock or memory corruption.
 * ========================================================================= */

static void vMutexWorker(void *pv)
{
    (void)pv;
    const TickType_t tmo = pdMS_TO_TICKS(5000);

    for (;;) {
        int acquired = 0;

        /* Lock to depth MUTEX_DEPTH. */
        while (acquired < MUTEX_DEPTH) {
            if (xSemaphoreTakeRecursive(g_rmutex, tmo) != pdTRUE) {
                g_mutex_errors++;
                break;
            }
            acquired++;
        }

        if (acquired == MUTEX_DEPTH) {
            /* Critical section: increment and verify under full lock depth. */
            uint32_t prev = g_rmutex_ctr;
            g_rmutex_ctr++;
            if (g_rmutex_ctr != prev + 1u)
                g_mutex_errors++;

            g_mutex_iters++;
            wdog_pet(WDOG_BIT_MUTEX);
        }

        /* Unwind exactly as many levels as were acquired. */
        for (int i = 0; i < acquired; i++)
            xSemaphoreGiveRecursive(g_rmutex);

        taskYIELD();
    }
}

/* =========================================================================
 * Module F: Memory stress  (1 task)
 *
 * Cycles through allocation sizes MEM_MIN_BYTES → MEM_MAX_BYTES (powers of
 * two).  Each allocation is filled with MEM_FILL_PATTERN, verified byte-by-
 * byte, then freed.  Heap fragmentation or memory bus errors will be caught
 * by the fill-verify mismatch.
 * ========================================================================= */

static void vMemStress(void *pv)
{
    (void)pv;
    uint32_t alloc_size = MEM_MIN_BYTES;

    for (;;) {
        uint8_t *p = (uint8_t *)pvPortMalloc(alloc_size);
        if (p == NULL) {
            g_mem_errors++;
            vTaskDelay(pdMS_TO_TICKS(20));
            continue;
        }

        memset(p, (int)MEM_FILL_PATTERN, alloc_size);

        for (uint32_t i = 0u; i < alloc_size; i++) {
            if (p[i] != (uint8_t)MEM_FILL_PATTERN) {
                g_mem_errors++;
                break;
            }
        }

        vPortFree(p);
        g_mem_allocs++;
        wdog_pet(WDOG_BIT_MEM);

        /* Advance to next size: 32 → 64 → 128 → 256 → 32 → ... */
        alloc_size <<= 1;
        if (alloc_size > MEM_MAX_BYTES)
            alloc_size = MEM_MIN_BYTES;

        taskYIELD();
    }
}

/* =========================================================================
 * Module H: Watchdog timer callback  (timer service task context)
 *
 * Fires every WATCHDOG_PERIOD_S real seconds.  Checks that every module has
 * set its bit since the last fire; prints "OK" or a fault line naming the
 * stuck modules, then resets the mask for the next period.
 * ========================================================================= */

static void vWatchdogTimerCb(TimerHandle_t xTimer)
{
    (void)xTimer;

    xSemaphoreTake(g_wdog_mutex, portMAX_DELAY);
    uint32_t mask = g_wdog_mask;
    g_wdog_mask   = 0u;
    xSemaphoreGive(g_wdog_mutex);

    UART_LOG_BEGIN();
    up_str("[WDOG] ");
    if (mask == WDOG_ALL_BITS) {
        up_str("OK mask=0x");
        up_hex8(mask);
    } else {
        g_wdog_faults++;
        up_str("FAULT hung:");
        if (!(mask & WDOG_BIT_CPU))   up_str(" CPU");
        if (!(mask & WDOG_BIT_QUEUE)) up_str(" QUEUE");
        if (!(mask & WDOG_BIT_EVENT)) up_str(" EVENT");
        if (!(mask & WDOG_BIT_SEM))   up_str(" SEM");
        if (!(mask & WDOG_BIT_MUTEX)) up_str(" MUTEX");
        if (!(mask & WDOG_BIT_MEM))   up_str(" MEM");
        up_str("  mask=0x");
        up_hex8(mask);
    }
    up_crlf();
    UART_LOG_END();
}

/* =========================================================================
 * Module G: Heartbeat reporter  (lowest-priority worker task)
 *
 * Prints one status line to UART every HEARTBEAT_INTERVAL_S real seconds.
 * Uses xTaskDelayUntil() for drift-free periodic operation.
 * ========================================================================= */

static void vHeartbeat(void *pv)
{
    (void)pv;
    const TickType_t interval =
        (TickType_t)(HEARTBEAT_INTERVAL_S * REAL_TICKS_PER_SEC);
    TickType_t wake = xTaskGetTickCount() + interval;

    for (;;) {
        xTaskDelayUntil(&wake, interval);

        TickType_t now      = xTaskGetTickCount();
        size_t     free_mem = xPortGetFreeHeapSize();
        uint32_t   total_err =
            g_cpu_errors + g_queue_errors + g_event_errors +
            g_sem_errors  + g_mutex_errors + g_mem_errors;

        UART_LOG_BEGIN();
        up_timestamp(now);
        up_char(' ');
        up_kv("A", g_cpu_iters);
        up_kv("B", g_queue_sent);
        up_kv("C", g_event_rounds);
        up_kv("D", g_sem_rounds);
        up_kv("E", g_mutex_iters);
        up_kv("F", g_mem_allocs);
        up_kv("err", total_err);
        up_kv("heap", (uint32_t)free_mem);
        up_kv("wdf", g_wdog_faults);
        up_crlf();
        UART_LOG_END();
    }
}

/* =========================================================================
 * FreeRTOS application hooks
 * ========================================================================= */

void vApplicationIdleHook(void) {}
void vApplicationTickHook(void) {}

void vApplicationStackOverflowHook(TaskHandle_t xTask, char *pcTaskName)
{
    (void)xTask;
    /*
     * Stack overflow is a fatal error — the task's context is corrupt.
     * Print the offending task name and halt.  Do NOT call jv_exit(): the
     * magic simulation device is not mapped on FPGA hardware.
     */
    if (xSemaphoreTake(g_uart_mutex, 0) == pdTRUE) {
        up_str("\r\n[FATAL] Stack overflow: ");
        up_str(pcTaskName);
        up_crlf();
        /* intentionally do not release mutex — we are halting */
    }
    taskDISABLE_INTERRUPTS();
    for (;;) { __asm__ volatile("nop"); }
}

void vApplicationMallocFailedHook(void)
{
    /*
     * Not fatal: the memory-stress task counts and recovers from allocation
     * failures.  Log a warning if the UART mutex is immediately available
     * (non-blocking attempt avoids deadlock from ISR/timer context).
     */
    if (xSemaphoreTake(g_uart_mutex, 0) == pdTRUE) {
        up_str("[WARN] pvPortMalloc failed");
        up_crlf();
        xSemaphoreGive(g_uart_mutex);
    }
}

/* =========================================================================
 * main()
 * ========================================================================= */

int main(void)
{
    /* ── 1. Initialise UART to maximum PC-compatible baud rate ─────────── */
    jv_uart_set_baud(UART_BAUD_DIV);   /* 921 600 baud at 50 MHz FPGA clock */

    /* Drain any stale bytes left in the RX FIFO from a previous run. */
    while (jv_uart_rx_ready())
        (void)jv_uart_getc();

    /* Print banner synchronously before the scheduler starts. */
    jv_uart_puts("\r\n");
    jv_uart_puts("============================================================\r\n");
    jv_uart_puts("  JV32 FPGA FreeRTOS Long-Running Stability Stress Test\r\n");
    jv_uart_puts("  UART 921600 8N1  |  CLK 50 MHz  |  baud_div=53\r\n");
    jv_uart_puts("  Modules: A=CPU(x2) B=Queue(x2) C=Event(x4) D=Sem(x2)\r\n");
    jv_uart_puts("           E=Mutex(x3) F=Mem(x1) G=HB(x1) H=Wdog(30s)\r\n");
    jv_uart_puts("  Output:  [HHH:MM:SS] A= B= C= D= E= F= err= heap= wdf=\r\n");
    jv_uart_puts("============================================================\r\n");
    jv_uart_puts("Starting scheduler...\r\n\r\n");

    /* ── 2. Create synchronisation objects ─────────────────────────────── */
    g_uart_mutex = xSemaphoreCreateMutex();
    g_wdog_mutex = xSemaphoreCreateMutex();
    g_pipeline   = xQueueCreate((UBaseType_t)QUEUE_DEPTH, sizeof(QMsg_t));
    g_barrier    = xEventGroupCreate();
    g_sem_ping   = xSemaphoreCreateBinary();
    g_sem_pong   = xSemaphoreCreateBinary();
    g_rmutex     = xSemaphoreCreateRecursiveMutex();

    configASSERT(g_uart_mutex);
    configASSERT(g_wdog_mutex);
    configASSERT(g_pipeline);
    configASSERT(g_barrier);
    configASSERT(g_sem_ping);
    configASSERT(g_sem_pong);
    configASSERT(g_rmutex);

    /* Seed the ping-pong chain: vSemPing blocks first. */
    xSemaphoreGive(g_sem_ping);

    /* ── 3. Create all tasks ────────────────────────────────────────────── */

    /* Module A: CPU hash workers */
    xTaskCreate(vCpuWorker, "CpuW0", configMINIMAL_STACK_SIZE * 2,
                (void *)0xC0FFEE01u, PRIO_CPU, NULL);
    xTaskCreate(vCpuWorker, "CpuW1", configMINIMAL_STACK_SIZE * 2,
                (void *)0xDEADBE02u, PRIO_CPU, NULL);

    /* Module B: Queue pipeline */
    xTaskCreate(vQueueProducer, "QProd", configMINIMAL_STACK_SIZE,
                NULL, PRIO_QUEUE, NULL);
    xTaskCreate(vQueueConsumer, "QCons", configMINIMAL_STACK_SIZE,
                NULL, PRIO_QUEUE, NULL);

    /* Module C: Event-group barrier workers */
    for (uint32_t i = 0u; i < EG_NUM_WORKERS; i++) {
        g_eg_args[i].id = i;
        xTaskCreate(vEventWorker, "EvWk", configMINIMAL_STACK_SIZE,
                    &g_eg_args[i], PRIO_EG_WORKER, NULL);
    }

    /* Module D: Semaphore ping-pong */
    xTaskCreate(vSemPing, "SemPi", configMINIMAL_STACK_SIZE,
                NULL, PRIO_SEM, NULL);
    xTaskCreate(vSemPong, "SemPo", configMINIMAL_STACK_SIZE,
                NULL, PRIO_SEM, NULL);

    /* Module E: Recursive mutex workers */
    xTaskCreate(vMutexWorker, "MtxW0", configMINIMAL_STACK_SIZE,
                NULL, PRIO_MUTEX, NULL);
    xTaskCreate(vMutexWorker, "MtxW1", configMINIMAL_STACK_SIZE,
                NULL, PRIO_MUTEX, NULL);
    xTaskCreate(vMutexWorker, "MtxW2", configMINIMAL_STACK_SIZE,
                NULL, PRIO_MUTEX, NULL);

    /* Module F: Memory stress */
    xTaskCreate(vMemStress, "MemSt", configMINIMAL_STACK_SIZE,
                NULL, PRIO_MEM, NULL);

    /* Module G: Heartbeat reporter — larger stack for UART string formatting */
    xTaskCreate(vHeartbeat, "HB", configMINIMAL_STACK_SIZE * 2,
                NULL, PRIO_HEARTBEAT, NULL);

    /* ── 4. Watchdog software timer (auto-reload) ───────────────────────── */
    TimerHandle_t wdog = xTimerCreate(
        "Wdog",
        (TickType_t)(WATCHDOG_PERIOD_S * REAL_TICKS_PER_SEC),
        pdTRUE,     /* auto-reload */
        NULL,
        vWatchdogTimerCb);
    configASSERT(wdog);
    xTimerStart(wdog, portMAX_DELAY);

    /* ── 5. Start the scheduler — never returns ─────────────────────────── */
    vTaskStartScheduler();

    /* Unreachable: halt via UART if the scheduler unexpectedly returns. */
    jv_uart_puts("[FATAL] Scheduler returned!\r\n");
    for (;;) { __asm__ volatile("nop"); }
}
