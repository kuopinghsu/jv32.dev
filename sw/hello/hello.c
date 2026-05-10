/* ============================================================================
 * File: sw/hello/hello.c
 * Project: JV32 RISC-V Processor
 * Description: Hello World test — uses JV SDK
 * ============================================================================ */

#include "jv_platform.h"
#include "jv_uart.h"
#include "csr.h"

/* ============================================================================
 * Debugger testing constructs (exercised by openocd/test_gdb_hello.gdb):
 *
 *  flag     - volatile global used as an access-watchpoint target.
 *             GDB command: awatch flag
 *             Fires on every read or write of flag (i.e. on every foo() call
 *             that modifies it, and on every read-back).
 *
 *  foo()    - non-inline function that increments flag; used to exercise
 *             stepi / step across a real function-call boundary.
 *
 *  foo1..5  - C labels in main() used as named breakpoint targets:
 *               break main:foo1   break main:foo2   break main:foo3
 *               break main:foo4   break main:foo5
 *             foo1..4 each precede a foo() call site; foo5 follows the last.
 *
 * GDB session overview (see openocd/test_gdb_hello.gdb):
 *   break main         -- stop at main entry
 *   run                -- load ELF and run to main breakpoint
 *
 *   awatch flag        -- access watchpoint on flag (read + write)
 *   break main:foo1..5 -- breakpoints at each label
 *   c                  -- continue to first breakpoint / watchpoint hit
 *
 *   stepi 100 (x2)     -- machine-level single-step, 100 instructions each
 *   c
 *
 *   step 100 (x2)      -- source-level single-step, 100 lines each
 *   c
 *
 *   delete             -- remove all breakpoints and watchpoints
 *   nexti              -- machine-level step-over (does not enter calls)
 *   next (x2)          -- source-level step-over
 * ============================================================================ */
volatile int flag = 0;

__attribute__((noinline))
void foo(void)
{
    flag++;  /* write to flag -- triggers awatch watchpoint */
}

int main(void)
{

    /* Breakpoint labels: use 'break main:foo1' .. 'break main:foo5' in GDB */
foo1: foo();  /* first  call site -- break main:foo1 */
foo2: foo();  /* second call site -- break main:foo2 */
foo3: foo();  /* third  call site -- break main:foo3 */
foo4: foo();  /* fourth call site -- break main:foo4 */
foo5:         /* after last call  -- break main:foo5 */

    jv_uart_puts("Hello, JV32!\n");

    /* CSR read via SDK macro */
    jv_uart_puts("misa=");
    jv_uart_puthex32(read_csr(misa));
    jv_uart_puts("\n");

    /* Basic arithmetic / division */
    volatile uint32_t a = 1000000U;
    volatile uint32_t b = 7U;
    volatile uint32_t q = a / b;
    volatile uint32_t r = a % b;
    jv_uart_puts("1000000/7=");
    jv_uart_putu32(q);
    jv_uart_puts(" rem=");
    jv_uart_putu32(r);
    jv_uart_puts("\n");

    /* Cycle counter */
    jv_uart_puts("mcycle=");
    jv_uart_puthex32((uint32_t)read_csr_mcycle64());
    jv_uart_puts("\n");

    jv_uart_puts("PASS\n");
    jv_exit(0);
}
