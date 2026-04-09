/**
 * @file csr.h
 * @brief RISC-V CSR (Control and Status Register) inline accessor macros.
 *
 * Provides read_csr(), write_csr(), set_csr(), clear_csr() generic macros
 * and individual named accessors for every M-mode CSR used by jv32_core.
 */

#ifndef CSR_H
#define CSR_H

#include <stdint.h>

/* ============================================================================
 * Generic CSR access macros — use these for CSRs not listed below,
 * or when the CSR name must be a compile-time string.
 *
 * Example:
 *   uint32_t v = read_csr(mstatus);
 *   set_csr(mstatus, 0x8);          // set MIE bit
 *   clear_csr(mie, 1u << 7);        // clear MTIE
 * ============================================================================ */

/** Read CSR. */
#define read_csr(reg)       ({ uint32_t _v; asm volatile("csrr %0, " #reg : "=r"(_v)); _v; })

/** Write CSR (no return value). */
#define write_csr(reg, val) asm volatile("csrw " #reg ", %0" :: "rK"(val))

/** Atomic set bits; returns old value. */
#define set_csr(reg, bits)  ({ uint32_t _v; asm volatile("csrrs %0, " #reg ", %1" : "=r"(_v) : "rK"(bits)); _v; })

/** Atomic clear bits; returns old value. */
#define clear_csr(reg, bits)({ uint32_t _v; asm volatile("csrrc %0, " #reg ", %1" : "=r"(_v) : "rK"(bits)); _v; })

/* ============================================================================
 * Machine Information Registers (Read-Only)
 * ============================================================================ */

static inline uint32_t read_csr_mvendorid(void) { return read_csr(mvendorid); }
static inline uint32_t read_csr_marchid(void)   { return read_csr(marchid);   }
static inline uint32_t read_csr_mimpid(void)    { return read_csr(mimpid);    }
static inline uint32_t read_csr_mhartid(void)   { return read_csr(mhartid);   }

/* ============================================================================
 * Machine Trap Setup
 * ============================================================================ */

/* mstatus — Machine Status Register */
static inline uint32_t read_csr_mstatus(void)         { return read_csr(mstatus); }
static inline void     write_csr_mstatus(uint32_t v)  { write_csr(mstatus, v); }

/* mstatus bit fields */
#define MSTATUS_MIE   (1u << 3)   /* Machine Interrupt Enable (global) */
#define MSTATUS_MPIE  (1u << 7)   /* Machine Previous Interrupt Enable */
#define MSTATUS_MPP_M (3u << 11)  /* Machine Previous Privilege = M-mode */

/* misa — ISA and Extensions (RO on jv32) */
static inline uint32_t read_csr_misa(void) { return read_csr(misa); }

/* mie — Machine Interrupt Enable */
static inline uint32_t read_csr_mie(void)        { return read_csr(mie); }
static inline void     write_csr_mie(uint32_t v) { write_csr(mie, v); }

/* mtvec — Machine Trap-Vector Base Address */
static inline uint32_t read_csr_mtvec(void)        { return read_csr(mtvec); }
static inline void     write_csr_mtvec(uint32_t v) { write_csr(mtvec, v); }

/* mtvec mode bits */
#define MTVEC_MODE_DIRECT   0u   /* All traps jump to mtvec base */
#define MTVEC_MODE_VECTORED 1u   /* Async interrupts jump to mtvec + 4*cause */

/* ============================================================================
 * Machine Trap Handling
 * ============================================================================ */

/* mscratch */
static inline uint32_t read_csr_mscratch(void)        { return read_csr(mscratch); }
static inline void     write_csr_mscratch(uint32_t v) { write_csr(mscratch, v); }

/* mepc — Machine Exception Program Counter */
static inline uint32_t read_csr_mepc(void)        { return read_csr(mepc); }
static inline void     write_csr_mepc(uint32_t v) { write_csr(mepc, v); }

/* mcause — Machine Cause Register */
static inline uint32_t read_csr_mcause(void)        { return read_csr(mcause); }
static inline void     write_csr_mcause(uint32_t v) { write_csr(mcause, v); }

/* mtval — Machine Trap Value */
static inline uint32_t read_csr_mtval(void)        { return read_csr(mtval); }
static inline void     write_csr_mtval(uint32_t v) { write_csr(mtval, v); }

/* mip — Machine Interrupt Pending (mostly RO) */
static inline uint32_t read_csr_mip(void)        { return read_csr(mip); }
static inline void     write_csr_mip(uint32_t v) { write_csr(mip, v); }

/* ============================================================================
 * Machine Counter/Timers
 * ============================================================================ */

/* mcycle / mcycleh — lower and upper 32 bits of the cycle counter */
static inline uint32_t read_csr_mcycle(void)  { return read_csr(mcycle);  }
static inline uint32_t read_csr_mcycleh(void) { return read_csr(mcycleh); }

/** Read the full 64-bit cycle counter (safe against carry-over). */
static inline uint64_t read_csr_mcycle64(void)
{
    uint32_t lo, hi, hi2;
    do {
        hi  = read_csr(mcycleh);
        lo  = read_csr(mcycle);
        hi2 = read_csr(mcycleh);
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

/* minstret / minstreth — instructions-retired counter */
static inline uint32_t read_csr_minstret(void)  { return read_csr(minstret);  }
static inline uint32_t read_csr_minstreth(void) { return read_csr(minstreth); }

/** Read the full 64-bit instret counter (safe against carry-over). */
static inline uint64_t read_csr_minstret64(void)
{
    uint32_t lo, hi, hi2;
    do {
        hi  = read_csr(minstreth);
        lo  = read_csr(minstret);
        hi2 = read_csr(minstreth);
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

/* Aliases matching the unprivileged cycle/instret CSR names */
static inline uint64_t read_csr_cycle64(void)   { return read_csr_mcycle64();   }
static inline uint64_t read_csr_instret64(void) { return read_csr_minstret64(); }

/* ============================================================================
 * Custom jv32 CSRs (0x7C0–0x7FF range reserved for custom M-mode)
 *
 * 0x7C0  mintthresh  — CLIC interrupt threshold: block IRQs with level <= this
 * ============================================================================ */

#define CSR_MINTTHRESH  0x347   /* mclicbase region — CLIC interrupt threshold */

static inline uint32_t read_csr_mintthresh(void)
{
    uint32_t v;
    asm volatile("csrr %0, 0x347" : "=r"(v));
    return v;
}
static inline void write_csr_mintthresh(uint32_t v)
{
    asm volatile("csrw 0x347, %0" :: "r"(v));
}

#endif /* CSR_H */
