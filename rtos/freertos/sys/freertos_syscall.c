/*
 * FreeRTOS Syscall stubs for newlib
 */

#include <sys/stat.h>
#include <sys/types.h>
#include <sys/times.h>
#include <errno.h>
#include <stdint.h>
#include "jv_platform.h"

#undef errno
extern int errno;

/* Memory management */
extern char __heap_start[];
extern char __heap_end[];
static char *heap_ptr = NULL;

void *_sbrk(int incr)
{
    char *prev_heap_ptr;

    if (heap_ptr == NULL) {
        heap_ptr = __heap_start;
    }

    prev_heap_ptr = heap_ptr;

    if ((heap_ptr + incr) > __heap_end) {
        errno = ENOMEM;
        return (void *)-1;
    }

    heap_ptr += incr;
    return prev_heap_ptr;
}

int _close(int file)
{
    UNUSED(file);
    return -1;
}

int _fstat(int file, struct stat *st)
{
    UNUSED(file);
    st->st_mode = S_IFCHR;
    return 0;
}

int _isatty(int file)
{
    UNUSED(file);
    return 1;
}

int _lseek(int file, int offset, int whence)
{
    UNUSED(file); UNUSED(offset); UNUSED(whence);
    return 0;
}

int _read(int file, char *ptr, int len)
{
    UNUSED(file); UNUSED(ptr); UNUSED(len);
    return 0;
}

int _write(int file, char *ptr, int len)
{
    UNUSED(file);
    for (int i = 0; i < len; i++) {
        if (ptr[i] == '\n')
            jv_putc_raw('\r');
        jv_putc_raw(ptr[i]);
    }
    return len;
}

/* _exit is defined in freertos_start.S */

int _kill(int pid, int sig)
{
    UNUSED(pid); UNUSED(sig);
    errno = EINVAL;
    return -1;
}

int _getpid(void)
{
    return 1;
}

int _open(const char *name, int flags, int mode)
{
    UNUSED(name); UNUSED(flags); UNUSED(mode);
    return -1;
}

int _wait(int *status)
{
    UNUSED(status);
    errno = ECHILD;
    return -1;
}

int _unlink(const char *name)
{
    UNUSED(name);
    errno = ENOENT;
    return -1;
}

int _times(struct tms *buf)
{
    UNUSED(buf);
    return -1;
}

int _stat(const char *file, struct stat *st)
{
    UNUSED(file);
    st->st_mode = S_IFCHR;
    return 0;
}

int _link(const char *old, const char *new)
{
    UNUSED(old); UNUSED(new);
    errno = EMLINK;
    return -1;
}

int _fork(void)
{
    errno = EAGAIN;
    return -1;
}

int _execve(const char *name, char *const *argv, char *const *env)
{
    UNUSED(name); UNUSED(argv); UNUSED(env);
    errno = ENOMEM;
    return -1;
}
/*
 * FreeRTOS RISC-V port weak defaults in portASM.S trap forever for
 * application exceptions/interrupts. Override them here so semihosting
 * breakpoint traps used by jv_putc()/jv_exit() are tolerated.
 *
 * Call ABI from portASM.S:
 *   a0 = mcause
 *   a1 = mepc (already advanced by +4 for synchronous exceptions)
 */
void freertos_risc_v_application_exception_handler(uint32_t mcause, uint32_t mepc)
{
    UNUSED(mepc);

    /* Breakpoint exception: used by semihosting ebreak sequence.
     * Return so the trap epilogue resumes execution at the next instruction. */
    if ((mcause & 0x7FFFFFFFu) == 3u) {
        return;
    }

    /* Unexpected exception in FreeRTOS app context: fail fast. */
    jv_putc_raw('\n');
    jv_putc_raw('['); jv_putc_raw('F'); jv_putc_raw('R'); jv_putc_raw('T'); jv_putc_raw(']');
    jv_putc_raw(' '); jv_putc_raw('E'); jv_putc_raw('X'); jv_putc_raw('C'); jv_putc_raw('\n');
    jv_exit_raw(1);
}

void freertos_risc_v_application_interrupt_handler(uint32_t mcause, uint32_t mepc)
{
    UNUSED(mcause);
    UNUSED(mepc);
    /* Ignore unexpected non-timer interrupts by default.
     * Dedicated timer IRQ path is handled elsewhere in portASM.S. */
}
