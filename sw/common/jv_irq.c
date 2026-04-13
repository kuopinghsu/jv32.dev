// ============================================================================
// File: sw/common/jv_irq.c
// Project: JV32 RISC-V Processor
// Description: Machine-mode IRQ / exception dispatch table implementation.
//
// Provides:
//   - jv_irq_register()  — register an interrupt handler for a given cause
//   - jv_exc_register()  — register an exception handler for a given cause
//   - jv_irq_dispatch()  — route mcause to the correct registered handler
//   - handle_trap()      — WEAK bridge from startup.S trap entry to the
//                          dispatch table (tests may override this directly)
//
// Startup.S contract:
//   uint32_t handle_trap(uint32_t mcause, uint32_t mepc, uint32_t mtval);
//   Returns 0 → use original mepc; non-zero → redirect mepc before mret.
// ============================================================================

#include <stdint.h>
#include "jv_irq.h"
#include "jv_platform.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ── default handlers ─────────────────────────────────────────────────────── */

static void _puts(const char *s) { while (*s) jv_putc(*s++); }

static void _puthex(uint32_t v)
{
    static const char h[] = "0123456789abcdef";
    _puts("0x");
    for (int i = 7; i >= 0; i--)
        jv_putc(h[(v >> (i * 4)) & 0xfu]);
}

static void _default_irq(uint32_t cause)
{
    _puts("[jv_irq] unhandled interrupt, cause=");
    _puthex(cause);
    _puts("\n");
}

static uint32_t _default_exc(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    /* If the fault occurred inside the debug ROM / program-buffer area
     * (0x0f8000xx), the CPU was executing a debugger-inserted instruction.
     * For ILLEGAL_INSTRUCTION (cause=2, e.g. unsupported CSR), skip past
     * the faulting instruction so execution reaches the implicit ebreak.
     * For data-access faults (LOAD_ACCESS_FAULT=5, STORE_ACCESS_FAULT=7),
     * do NOT skip: returning mepc=0 retries the fault, causing a tight loop
     * that the DTM detects as an exception (CMD_EXEC timeout → CMDERR_EXCEPTION). */
    if ((mepc >> 8) == (0x0F800000u >> 8)) {
        uint32_t cause = mcause & 0x7FFFFFFFu;  /* strip interrupt bit */
        if (cause == 2u /* ILLEGAL_INSTRUCTION */) {
            /* Advance past the faulting instruction: 4 bytes if 32-bit (bits[1:0]==11),
             * 2 bytes for a compressed (16-bit) instruction. */
            uint32_t insn_len = ((mtval & 3u) == 3u) ? 4u : 2u;
            return mepc + insn_len;
        }
        /* Data-access fault — retry at mepc until DTM times out. */
        return 0;
    }

    _puts("\n=== EXCEPTION ===\n");
    _puts("mcause: "); _puthex(mcause); _puts("\n");
    _puts("mepc:   "); _puthex(mepc);   _puts("\n");
    _puts("mtval:  "); _puthex(mtval);  _puts("\n");
    _puts("Halted.\n");
    jv_exit(1);
    /* jv_exit never returns; spin in case it does */
    while (1) {}
    return 0;
}

/* ── dispatch tables ──────────────────────────────────────────────────────── */

#define _IRQ_MAX 16u
#define _EXC_MAX 32u

static jv_irq_handler_t _irq_table[_IRQ_MAX];
static jv_exc_handler_t _exc_table[_EXC_MAX];

/* ── registration ─────────────────────────────────────────────────────────── */

void jv_irq_register(uint32_t cause, jv_irq_handler_t handler)
{
    if (cause < _IRQ_MAX)
        _irq_table[cause] = handler;
}

void jv_exc_register(uint32_t cause, jv_exc_handler_t handler)
{
    if (cause < _EXC_MAX)
        _exc_table[cause] = handler;
}

/* ── dispatcher ───────────────────────────────────────────────────────────── */

uint32_t jv_irq_dispatch(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    if (mcause & 0x80000000u) {
        /* Async interrupt */
        uint32_t code = mcause & 0x7FFFFFFFu;
        if (code < _IRQ_MAX && _irq_table[code]) {
            _irq_table[code](code);
        } else {
            _default_irq(code);
        }
        return 0;   /* resume at mepc (interrupt return) */
    } else {
        /* Synchronous exception */
        uint32_t code = mcause & 0x7FFFFFFFu;
        if (code < _EXC_MAX && _exc_table[code]) {
            return _exc_table[code](mcause, mepc, mtval);
        } else {
            return _default_exc(mcause, mepc, mtval);
        }
    }
}

/* ── bridge from startup.S ────────────────────────────────────────────────── */

/**
 * Default weak handle_trap(): routes to the jv_irq dispatch tables.
 * Tests that define their own handle_trap() will override this via the linker
 * (the linker prefers strong symbols over weak ones).
 */
__attribute__((weak))
uint32_t handle_trap(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    return jv_irq_dispatch(mcause, mepc, mtval);
}

#ifdef __cplusplus
}
#endif
