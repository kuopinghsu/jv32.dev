// ============================================================================
// File: callstack.c
// Project: JV32 RISC-V Processor
// Description: Call-stack backtrace from inside a trap handler.
//
// Test flow:
//   main() -> level1() -> level2() -> level3() -> level4() -> trigger_fault()
//
//   trigger_fault() executes an illegal instruction (0x00000000 unimp).
//   The trap handler catches ILLEGAL_INSN (mcause=2), walks the saved-frame
//   fp/ra chain to print a backtrace, then resumes by skipping the faulting
//   instruction.
//
// Backtrace method:
//   The RISC-V ABI -fno-omit-frame-pointer (or explicit asm) links each
//   stack frame as:
//       sp → [ra_prev] [fp_prev] [saved locals…]
//             fp ------^
//   Walking: next_fp = *(fp - 8), next_ra = *(fp - 4)  (when fp ≠ 0)
//
//   The test is compiled with -fno-omit-frame-pointer via makefile.mak so
//   every non-inline function pushes an ABI-standard frame.
//
// Expected output (relative to text base; exact addresses vary):
//   [TRAP] Illegal instruction at PC 0x8xxxxxxx  mcause=0x00000002
//   [BT#0] ra=0x8xxxxxxx  (trigger_fault return address)
//   [BT#1] ra=0x8xxxxxxx  (level4 return address)
//   [BT#2] ra=0x8xxxxxxx  (level3 return address)
//   [BT#3] ra=0x8xxxxxxx  (level2 return address)
//   [BT#4] ra=0x8xxxxxxx  (level1 return address)
//   [TRAP] resuming at PC+4
//   PASS: returned from fault normally
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include "jv_platform.h"
#include "jv_irq.h"
#include "csr.h"

/* ── low-level helpers (no printf available inside trap) ─────────────── */

static void _puts_raw(const char *s)
{
    while (*s) jv_putc(*s++);
}

static void _puthex32(uint32_t v)
{
    static const char h[] = "0123456789abcdef";
    jv_putc('0'); jv_putc('x');
    for (int i = 7; i >= 0; i--)
        jv_putc(h[(v >> (i * 4)) & 0xf]);
}

static void _putdec(int v)
{
    if (v < 0) { jv_putc('-'); v = -v; }
    char buf[12]; int n = 0;
    if (v == 0) { jv_putc('0'); return; }
    while (v) { buf[n++] = '0' + v % 10; v /= 10; }
    while (n--) jv_putc(buf[n]);
}

/* ── call-stack limits (guard against corrupt frames) ─────────────────── */

/* Stack grows down from __stack_top toward __stack_bottom.
 * We define guards: frame pointers must be on the stack (DRAM);
 * return addresses must be in IRAM or DRAM (both are valid code regions). */
extern char _stack_top[];
#define BT_FP_MIN   ((uintptr_t)JV_DRAM_BASE)
#define BT_FP_MAX   ((uintptr_t)(uintptr_t)_stack_top)
#define BT_RA_MIN   ((uintptr_t)JV_IRAM_BASE)
#define BT_RA_MAX   ((uintptr_t)_stack_top)
#define BT_MAX_FRAMES 16

/* ── flag so main() knows the trap fired ─────────────────────────────── */
static volatile int g_fault_caught;

/* ── illegal-instruction handler ─────────────────────────────────────── */
/*
 * Print a backtrace by walking saved frame-pointer/return-address pairs.
 *
 * Standard RV32 ABI frame layout (with -fno-omit-frame-pointer):
 *
 *   high addr ──┐
 *                │  ...caller's frame...
 *   fp-8  ──── saved fp (caller's fp)
 *   fp-4  ──── saved ra (our return address into caller)
 *   fp     ──► frame pointer of this function
 *   sp     ──► top of this function's locals / saved regs
 *   low addr ──┘
 *
 * The s0/fp register in the trap frame holds the fp of trigger_fault().
 * From there we can unwind: next_fp = *(cur_fp - 8), next_ra = *(cur_fp - 4).
 */
static void illegal_insn_handler(jv_trap_frame_t *frame)
{
    g_fault_caught = 1;

    _puts_raw("\n[TRAP] Illegal instruction at PC ");
    _puthex32(frame->mepc);
    _puts_raw("  mcause=");
    _puthex32(frame->mcause);
    _puts_raw("\n");

    /* Walk the frame chain.  frame->s0 is the fp/s0 of the function that
     * executed the illegal instruction (trigger_fault). */
    uintptr_t fp = frame->s0;
    for (int depth = 0; depth < BT_MAX_FRAMES; depth++) {
        /* Validate fp before dereferencing. */
        if (fp < BT_FP_MIN || fp > BT_FP_MAX || (fp & 3u))
            break;

        uintptr_t saved_ra = *((uint32_t *)fp - 1);  /* fp - 4 */
        uintptr_t saved_fp = *((uint32_t *)fp - 2);  /* fp - 8 */

        /* A saved_ra of 0 or outside code range means we've walked off the stack. */
        if (saved_ra < BT_RA_MIN || saved_ra > BT_RA_MAX)
            break;

        _puts_raw("[BT#");
        _putdec(depth);
        _puts_raw("] ra=");
        _puthex32((uint32_t)saved_ra);
        _puts_raw("\n");

        fp = saved_fp;
    }

    /* Skip the 4-byte illegal instruction (unimp is always 32-bit). */
    _puts_raw("[TRAP] resuming at PC+4\n");
    frame->mepc += 4;
}

/* ── deep call chain ─────────────────────────────────────────────────── */

__attribute__((noinline))
static void trigger_fault(void)
{
    /* Emit a 32-bit all-zero word as an instruction.  On RV32 this is
     * "unimp" (the canonical illegal-instruction encoding) and raises
     * an Illegal Instruction exception (mcause=2). */
    __asm__ volatile (".word 0x00000000" ::: "memory");
}

__attribute__((noinline))
static void level4(void) { trigger_fault(); }

__attribute__((noinline))
static void level3(void) { level4(); }

__attribute__((noinline))
static void level2(void) { level3(); }

__attribute__((noinline))
static void level1(void) { level2(); }

/* ── main ─────────────────────────────────────────────────────────────── */

int main(void)
{
    printf("=== callstack: backtrace-from-trap test ===\n");

    /* Register our handler for mcause=2 (Illegal Instruction). */
    jv_exc_register(JV_EXC_ILLEGAL_INSN, illegal_insn_handler);

    g_fault_caught = 0;

    /* Invoke the deep call chain; trigger_fault() will raise ILLEGAL_INSN. */
    level1();

    if (g_fault_caught) {
        printf("PASS: returned from fault normally\n");
    } else {
        printf("FAIL: fault was not caught\n");
        return 1;
    }

    printf("=== callstack: DONE ===\n");
    return 0;
}
