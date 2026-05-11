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

static void _puts(const char *s) { while (*s) jv_putc_raw(*s++); }

static inline uint8_t _u8_at(uint32_t addr)
{
    return *(volatile const uint8_t *)(uintptr_t)addr;
}

static inline uint32_t _u32_at(uint32_t addr)
{
    return ((uint32_t)_u8_at(addr + 0u)      ) |
           ((uint32_t)_u8_at(addr + 1u) <<  8) |
           ((uint32_t)_u8_at(addr + 2u) << 16) |
           ((uint32_t)_u8_at(addr + 3u) << 24);
}

static int _semihost_try_handle(jv_trap_frame_t *frame)
{
    uint32_t mepc = frame->mepc;
    if (mepc < 4u) return 0;

    if (_u32_at(mepc - 4u) != JV_SEMIHOST_ENTRY_NOP) return 0;
    if (_u32_at(mepc)      != JV_SEMIHOST_EBREAK)    return 0;
    if (_u32_at(mepc + 4u) != JV_SEMIHOST_EXIT_NOP)  return 0;

    switch (frame->a0) {
    case JV_SEMIHOST_SYS_WRITEC: {
        uint8_t ch = (frame->a1 <= 0xFFu) ? (uint8_t)frame->a1
                                          : _u8_at(frame->a1);
        jv_putc_raw((char)ch);
        frame->a0 = 0u;
        frame->mepc = mepc + 4u;
        return 1;
    }
    case JV_SEMIHOST_SYS_WRITE0: {
        uint32_t p = frame->a1;
        while (_u8_at(p) != 0u) jv_putc_raw((char)_u8_at(p++));
        frame->a0 = 0u;
        frame->mepc = mepc + 4u;
        return 1;
    }
    case JV_SEMIHOST_SYS_WRITE: {
        uint32_t p = frame->a1;
        uint32_t handle = _u32_at(p + 0u);
        uint32_t buf    = _u32_at(p + 4u);
        uint32_t len    = _u32_at(p + 8u);
        if (handle == 1u || handle == 2u) {
            for (uint32_t i = 0; i < len; i++) jv_putc_raw((char)_u8_at(buf + i));
            frame->a0 = 0u;  // bytes not written
        } else {
            frame->a0 = len; // unsupported handle: all bytes unwritten
        }
        frame->mepc = mepc + 4u;
        return 1;
    }
    case JV_SEMIHOST_SYS_READC:
        frame->a0 = 0xFFFFFFFFu;  // EOF / no input in this environment
        frame->mepc = mepc + 4u;
        return 1;
    case JV_SEMIHOST_SYS_EXIT: {
        uint32_t reason = frame->a1;
        int code = (reason == JV_SEMIHOST_ADP_STOPPED_APP_EXIT) ? 0 : 1;
        jv_exit_raw(code);
        return 1;
    }
    case JV_SEMIHOST_SYS_EXIT_EXTENDED: {
        uint32_t p = frame->a1;
        uint32_t reason = _u32_at(p + 0u);
        uint32_t subcode = _u32_at(p + 4u);
        int code = (reason == JV_SEMIHOST_ADP_STOPPED_APP_EXIT) ? (int)subcode
                                                                 : (subcode ? (int)subcode : 1);
        jv_exit_raw(code);
        return 1;
    }
    default:
        frame->a0 = 0xFFFFFFFFu;  // unsupported op
        frame->mepc = mepc + 4u;
        return 1;
    }
}

static void _puthex(uint32_t v)
{
    static const char h[] = "0123456789abcdef";
    _puts("0x");
    for (int i = 7; i >= 0; i--)
        jv_putc_raw(h[(v >> (i * 4)) & 0xfu]);
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

    /* RISC-V semihosting v1.0: slli/ebreak/srai marker sequence.
     * Handle in software so both RTL and software-simulator runs can service
     * basic semihosting calls without an external debugger. */
    if ((mcause & 0x7FFFFFFFu) == JV_EXC_BREAKPOINT) {
        if (_semihost_try_handle(frame)) return;
    }

    _puts("\n=== EXCEPTION ===\n");
    _puts("mcause: "); _puthex(mcause); _puts("\n");
    _puts("mepc:   "); _puthex(mepc);   _puts("\n");
    _puts("mtval:  "); _puthex(mtval);  _puts("\n");
    _puts("Halted.\n");
    jv_exit_raw(1);
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

