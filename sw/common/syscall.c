/* ============================================================================
 * File: sw/common/syscall.c
 * Project: JV32 RISC-V Processor
 * Description: Newlib syscall stubs for bare-metal sw/ tests.
 *
 * Overrides the Linux-ecall-based stubs that newlib ships by default.
 * _write routes characters to the JV32 magic-device console so that
 * puts() / printf() work without triggering an ecall exception.
 * ============================================================================ */

#include <sys/stat.h>
#include <sys/times.h>
#include <errno.h>
#include <stdint.h>
#include "jv_platform.h"

#undef errno
extern int errno;

/* Heap for dynamic allocation (_sbrk) — symbols from link.ld */
extern char __heap_start[];
extern char __heap_end[];
static char *_heap_ptr = NULL;

int _write(int file, char *ptr, int len)
{
    UNUSED(file);
    for (int i = 0; i < len; i++)
        jv_putc(ptr[i]);
    return len;
}

void *_sbrk(int incr)
{
    char *prev;

    if (_heap_ptr == NULL)
        _heap_ptr = __heap_start;

    prev = _heap_ptr;
    if ((_heap_ptr + incr) > __heap_end) {
        errno = ENOMEM;
        return (void *)-1;
    }
    _heap_ptr += incr;
    return prev;
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

int _link(const char *old, const char *newpath)
{
    UNUSED(old); UNUSED(newpath);
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
