// ============================================================================
// File: sw/common/jv_irq.c
// Project: JV32 RISC-V Processor
// Description: Machine-mode IRQ / exception dispatch table implementation.
//
// Provides:
//   - jv_irq_register()  — register an interrupt handler for a given cause
//   - jv_exc_register()  — register an exception handler for a given cause
//   - jv_irq_dispatch()  — route mcause (via frame) to the correct handler
//   - trap_handler()     — WEAK bridge from startup.S trap entry to the
//                          dispatch table (tests may override this directly)
//
// startup.S contract:
//   void trap_handler(jv_trap_frame_t *frame);
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

static void _default_exc(jv_trap_frame_t *frame)
{
    uint32_t mcause = frame->mcause;
    uint32_t mepc   = frame->mepc;
    uint32_t mtval  = frame->mtval;

    /* If the fault occurred inside the debug ROM / program-buffer area
     * (0x0f8000xx), the CPU was executing a debugger-inserted instruction.
     * For ILLEGAL_INSTRUCTION (cause=2, e.g. unsupported CSR), skip past
     * the faulting instruction so execution reaches the implicit ebreak.
     * For data-access faults (LOAD_ACCESS_FAULT=5, STORE_ACCESS_FAULT=7),
     * do NOT skip: retrying the fault lets the DTM detect it via timeout. */
    if ((mepc >> 8) == (0x0F800000u >> 8)) {
        uint32_t cause = mcause & 0x7FFFFFFFu;
        if (cause == 2u /* ILLEGAL_INSTRUCTION */) {
            uint32_t insn_len = ((mtval & 3u) == 3u) ? 4u : 2u;
            frame->mepc = mepc + insn_len;
            return;
        }
        /* Data-access fault — leave mepc unchanged (retry). */
        return;
    }

    _puts("\n=== EXCEPTION ===\n");
    _puts("mcause: "); _puthex(mcause); _puts("\n");
    _puts("mepc:   "); _puthex(mepc);   _puts("\n");
    _puts("mtval:  "); _puthex(mtval);  _puts("\n");
    _puts("Halted.\n");
    jv_exit(1);
    while (1) {}
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

void jv_irq_dispatch(jv_trap_frame_t *frame)
{
    uint32_t mcause = frame->mcause;
    if (mcause & 0x80000000u) {
        /* Async interrupt */
        uint32_t code = mcause & 0x7FFFFFFFu;
        if (code < _IRQ_MAX && _irq_table[code])
            _irq_table[code](code);
        else
            _default_irq(code);
    } else {
        /* Synchronous exception */
        uint32_t code = mcause & 0x7FFFFFFFu;
        if (code < _EXC_MAX && _exc_table[code])
            _exc_table[code](frame);
        else
            _default_exc(frame);
    }
}

/* ── bridge from startup.S ────────────────────────────────────────────────── */

/**
 * Default weak trap_handler(): routes to the jv_irq dispatch tables.
 * Tests that define their own trap_handler() will override this via the linker.
 */
__attribute__((weak))
void trap_handler(jv_trap_frame_t *frame)
{
    jv_irq_dispatch(frame);
}

#ifdef __cplusplus
}
#endif

