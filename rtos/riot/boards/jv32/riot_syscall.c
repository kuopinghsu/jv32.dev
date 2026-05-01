/*
 * JV32 newlib syscall stubs for RIOT OS standalone build
 *
 * Provides the minimal _sbrk / _write / _read / _exit hooks that
 * newlib (and RIOT printf) need.  All file-descriptor operations other
 * than stdout/stderr are no-ops or errors.
 *
 * SPDX-License-Identifier: LGPL-2.1-only
 */

#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>
#include <stdint.h>

#include "jv_platform.h"

#undef errno
extern int errno;

/* ── Heap management ────────────────────────────────────────────────── */
extern char _sheap[];   /* defined in riot_link.ld */
extern char _eheap[];   /* defined in riot_link.ld */

static char *_heap_ptr = NULL;

void *_sbrk(int incr)
{
    char *prev;

    if (!_heap_ptr) {
        _heap_ptr = _sheap;
    }
    prev = _heap_ptr;

    if ((_heap_ptr + incr) > _eheap) {
        errno = ENOMEM;
        return (void *)-1;
    }
    _heap_ptr += incr;
    return prev;
}

/* ── I/O stubs ──────────────────────────────────────────────────────── */

int _write(int file, char *ptr, int len)
{
    (void)file;
    for (int i = 0; i < len; i++) {
        if (ptr[i] == '\n') {
            jv_putc('\r');
        }
        jv_putc(ptr[i]);
    }
    return len;
}

int _read(int file, char *ptr, int len)
{
    (void)file;
    (void)ptr;
    (void)len;
    return 0;
}

int _close(int file)
{
    (void)file;
    return -1;
}

int _fstat(int file, struct stat *st)
{
    (void)file;
    st->st_mode = S_IFCHR;
    return 0;
}

int _isatty(int file)
{
    (void)file;
    return 1;
}

int _lseek(int file, int offset, int whence)
{
    (void)file;
    (void)offset;
    (void)whence;
    return 0;
}

int _open(const char *name, int flags, int mode)
{
    (void)name;
    (void)flags;
    (void)mode;
    return -1;
}

int _wait(int *status)
{
    (void)status;
    errno = ECHILD;
    return -1;
}

int _unlink(const char *name)
{
    (void)name;
    errno = ENOENT;
    return -1;
}

int _kill(int pid, int sig)
{
    (void)pid;
    (void)sig;
    errno = EINVAL;
    return -1;
}

int _getpid(void)
{
    return 1;
}

/* _exit is provided in riot_start.S */
