// ============================================================================
// File: sim/jv32sim.cpp
// Project: JV32 RISC-V Processor
// Description: RV32IMAC + Zicsr software simulator — golden reference model.
//
// Generates an instruction trace compatible with the jv32 RTL testbench
// format, logging every retired instruction.
//
// Usage:
//   ./jv32sim [--trace <file>] [--rtl-hints <file>] [--max-insns <N>] [--timeout=<sec>] [--debug=<N>] <elf>
//
// Debug levels (--debug=N):
//   0  silent — no informational messages (default)
//   1  info   — lifecycle events: ELF loaded, EXIT, insn count, trap taken
//   2  verbose — unmapped memory accesses, segment warnings, CSR details
// ============================================================================

#include <cinttypes>
#include <deque>
#include <cassert>
#include <cerrno>
#include <chrono>
static uint32_t expand_rvc(uint16_t ci);
static bool     uart_irq_active();
static bool     clic_arb(uint32_t *out_id, uint8_t *out_level);
#include <csignal>
#include <iostream>
#include <iomanip>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>
#include "riscv-dis.h"

// ============================================================================
// Memory map
// ============================================================================
static const uint32_t IRAM_BASE  = 0x80000000U;
static const uint32_t IRAM_SIZE  = 128*1024;
static const uint32_t IRAM_ALIAS_BASE = 0x60000000U;
static const uint32_t DRAM_BASE  = 0xC0000000U;
static const uint32_t DRAM_SIZE  = 128*1024;
static const uint32_t DRAM_ALIAS_BASE = 0x70000000U;
static const uint32_t CLIC_BASE  = 0x02000000U;
static const uint32_t UART_BASE  = 0x20010000U;
static const uint32_t MAGIC_BASE = 0x40000000U;

// CLIC register offsets (from CLIC_BASE)
#define CLIC_MSIP_OFF        0x0000U
#define CLIC_MTIME_LO_OFF    0x4000U
#define CLIC_MTIME_HI_OFF    0x4004U
#define CLIC_MTIMECMP_LO_OFF 0x4008U
#define CLIC_MTIMECMP_HI_OFF 0x400CU

// UART register offsets (from UART_BASE)
#define UART_DATA_OFF    0x00U
#define UART_STATUS_OFF  0x04U
#define UART_CAP_OFF     0x18U

// Magic device offsets
#define MAGIC_CONSOLE_OFF 0x0000U
#define MAGIC_EXIT_OFF    0x0004U

// ============================================================================
// CSR addresses
// ============================================================================
#define CSR_MSTATUS    0x300
#define CSR_MISA       0x301
#define CSR_MIE        0x304
#define CSR_MTVEC      0x305
#define CSR_MTVT       0x307
#define CSR_MSCRATCH   0x340
#define CSR_MEPC       0x341
#define CSR_MCAUSE     0x342
#define CSR_MTVAL      0x343
#define CSR_MIP        0x344
#define CSR_MNXTI      0x345
#define CSR_MINTTHRESH 0x347
#define CSR_MINTSTATUS 0xFB1
#define CSR_MCYCLE     0xB00
#define CSR_MINSTRET   0xB02
#define CSR_MCYCLEH    0xB80
#define CSR_MINSTRETH  0xB82
#define CSR_CYCLE      0xC00
#define CSR_TIME       0xC01
#define CSR_INSTRET    0xC02
#define CSR_CYCLEH     0xC80
#define CSR_TIMEH      0xC81
#define CSR_INSTRETH   0xC82
#define CSR_MVENDORID  0xF11
#define CSR_MARCHID    0xF12
#define CSR_MIMPID     0xF13
#define CSR_MHARTID    0xF14

// mstatus bit masks
#define MSTATUS_MIE    (1u << 3)
#define MSTATUS_MPIE   (1u << 7)
#define MSTATUS_MPP    (3u << 11)
// mie/mip bit masks
#define MIP_MSIP       (1u << 3)
#define MIP_MTIP       (1u << 7)
#define MIP_MEIP       (1u << 11)

// Exception / interrupt causes
#define CAUSE_MISALIGNED_FETCH   0u
#define CAUSE_FETCH_ACCESS       1u
#define CAUSE_ILLEGAL_INSN       2u
#define CAUSE_BREAKPOINT         3u
#define CAUSE_LOAD_MISALIGN      4u
#define CAUSE_LOAD_ACCESS        5u
#define CAUSE_STORE_MISALIGN     6u
#define CAUSE_STORE_ACCESS       7u
#define CAUSE_ECALL_M            11u
#define CAUSE_TIMER_INT          0x80000007u
#define CAUSE_SOFTWARE_INT       0x80000003u
#define CAUSE_EXTERNAL_INT       0x8000000Bu

// ELF32 structures (minimal)
struct Elf32_Ehdr {
    uint8_t  e_ident[16];
    uint16_t e_type, e_machine;
    uint32_t e_version, e_entry, e_phoff, e_shoff, e_flags;
    uint16_t e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx;
};
struct Elf32_Phdr {
    uint32_t p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align;
};
#define PT_LOAD 1u
#define ELFMAG  "\177ELF"

// ============================================================================
// Simulator state
// ============================================================================
static uint32_t regs[32];
static uint32_t pc;
static bool     running;
static int      exit_code;
static uint64_t insn_count;

// Physical memory
static uint8_t iram[IRAM_SIZE];
static uint8_t dram[DRAM_SIZE];

// CLINT / CLIC state
static uint64_t mtime;
static uint64_t mtimecmp = 0xFFFFFFFFFFFFFFFFULL;
static uint32_t msip;

// CLIC external interrupt state
static uint8_t  clicint_ie[16];   // per-line interrupt enable
static uint8_t  clicint_ctl[16];  // per-line level/priority

// UART simulation state (loopback, interrupt enable, RX FIFO)
static uint8_t  uart_loopback;   // loopback_en flag (CTRL bit0)
static uint8_t  uart_ie;         // UART IE register [1:0]
static std::deque<uint8_t> uart_rx_fifo;  // simulated RX FIFO

// CSR registers
static uint32_t csr_mstatus;
static uint32_t csr_mie;
static uint32_t csr_mtvec;
static uint32_t csr_mtvt;
static uint32_t csr_mscratch;
static uint32_t csr_mepc;
static uint32_t csr_mcause;
static uint32_t csr_mtval;
static uint64_t csr_mcycle;
static uint64_t csr_minstret;
static uint8_t  csr_mintthresh;
static uint8_t  csr_mintstatus;

// Trace
static FILE  *trace_fp   = nullptr;
static bool   trace_on   = false;
static uint64_t max_insns        = 0;  // 0 = unlimited
static uint64_t timeout_seconds  = 0;  // 0 = no timeout

// ============================================================================
// RTL hint file: cycle-counter CSR values and IRQ-taken events from the RTL.
// When --rtl-hints <file> is provided the software sim uses the RTL's exact
// values when executing cycle-counter CSR reads, eliminating off-by-one drift.
// IRQ hints are used to fire timer interrupts at the exact same instruction as
// the RTL, regardless of mtime tick-rate differences (cycles vs. instructions).
// ============================================================================
struct CsrHint {
    uint32_t csr_addr;   // 0xB00=mcycle, 0xB80=mcycleh, etc.
    uint32_t value;      // exact value the RTL returned
};

static std::vector<CsrHint> g_csr_hints;
static size_t                g_hint_idx = 0;

// IRQ hints: taken from RTL trace '! irq cause=0x<c> epc=0x<e> insn=<N> ...' lines.
// After each step(), if insn_count has reached the hint's retirement count, the
// corresponding interrupt is forced via g_timer_irq_pending so check_interrupts()
// fires the timer on the very next step().  Natural timer firing is suppressed
// when hints are loaded so only hint-driven ticks occur.
struct IrqHint {
    uint32_t cause;
    uint32_t epc;
    uint64_t insn_count;  // total retirements in RTL at time of hint
    uint32_t next_rtl_pc; // PC of first instruction retired after interrupt (0=unknown)
};
static std::deque<IrqHint> g_irq_hints;
static bool g_hints_loaded      = false;  // true once --rtl-hints file is loaded
static bool g_timer_irq_pending = false;  // set by hint; cleared when timer taken
static uint32_t g_timer_irq_epc      = 0; // mepc to use when hint fires the timer
static uint32_t g_timer_irq_next_rtl_pc = 0; // actual next RTL PC (0=real ISR path)
static bool g_msi_irq_pending   = false;  // set by hint; cleared when MSI taken
static uint32_t g_msi_irq_epc   = 0;      // mepc to use when hint fires the MSI
static bool     g_mei_irq_pending = false; // set by MEI hint; cleared when taken
static uint32_t g_mei_irq_epc    = 0;     // mepc to use when hint fires the MEI
// Tail-chain flag: set by mret when returning from a CLIC trap in hints mode;
// allows one natural CLIC MEI check in check_interrupts() so tail-chaining
// (which emits no new ! irq hint in the RTL trace) still works.
static bool     g_just_did_mret  = false;

// Squashed-store hints: when the JV32 pipeline commits a store's DRAM write
// in the 1st WB cycle but the instruction is then squashed by an interrupt in
// the 2nd WB cycle, the RTL emits a '! sq_store' hint before the irq hint so
// the SW sim can apply the early write (making the store effectively idempotent
// when it re-executes after mret).
struct SqStoreHint {
    uint64_t insn_count;
    uint32_t addr;
    uint32_t data;
};
static std::deque<SqStoreHint> g_sq_store_hints;

// Map CSR name string → address
static uint32_t hint_csr_addr(const char* name) {
    if (!strcmp(name, "mcycle"))    return 0xB00;
    if (!strcmp(name, "mcycleh"))   return 0xB80;
    if (!strcmp(name, "minstret"))  return 0xB02;
    if (!strcmp(name, "minstreth")) return 0xB82;
    if (!strcmp(name, "cycle"))     return 0xC00;
    if (!strcmp(name, "cycleh"))    return 0xC80;
    if (!strcmp(name, "time"))      return 0xC01;
    if (!strcmp(name, "timeh"))     return 0xC81;
    if (!strcmp(name, "instret"))   return 0xC02;
    if (!strcmp(name, "instreth"))  return 0xC82;
    if (!strcmp(name, "mtime_lo"))  return 0x1000;  // pseudo-addr for CLIC mtime lo
    if (!strcmp(name, "mtime_hi"))  return 0x1001;  // pseudo-addr for CLIC mtime hi
    return 0xFFFFFFFFu;
}

static bool load_rtl_hints(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "[SIM] Cannot open rtl-hints file: %s\n", path);
        return false;
    }
    setvbuf(f, nullptr, _IOFBF, 4 * 1024 * 1024);  // 4 MB read buffer
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        // Match lines of the form: ! csr_hint <name> 0x<value>
        if (line[0] != '!') continue;
        char keyword[32], csr_name[32], val_str[32];
        if (sscanf(line, "! %31s %31s %31s", keyword, csr_name, val_str) == 3 &&
                strcmp(keyword, "csr_hint") == 0) {
            uint32_t addr = hint_csr_addr(csr_name);
            if (addr == 0xFFFFFFFFu) continue;
            uint32_t val = (uint32_t)strtoul(val_str, nullptr, 16);
            g_csr_hints.push_back({addr, val});
        }
        // Match lines of the form: ! sq_store insn=<N> addr=0x<a> data=0x<d>
        uint32_t sq_addr = 0, sq_data = 0;
        uint64_t sq_insn = 0;
        if (sscanf(line, "! sq_store insn=%" SCNu64 " addr=0x%x data=0x%x",
                   &sq_insn, &sq_addr, &sq_data) == 3) {
            g_sq_store_hints.push_back({sq_insn, sq_addr, sq_data});
        }
        // Match lines of the form: ! irq cause=0x<c> epc=0x<e> insn=<N> cycle=<cyc>
        uint32_t irq_cause = 0, irq_epc = 0;
        uint64_t irq_insn = 0, irq_cyc = 0;
        if (sscanf(line, "! irq cause=0x%x epc=0x%x insn=%" SCNu64 " cycle=%" SCNu64,
                   &irq_cause, &irq_epc, &irq_insn, &irq_cyc) >= 3) {
            g_irq_hints.push_back({irq_cause, irq_epc, irq_insn, 0u});
        }
    }
    fclose(f);

    // Second pass: find the actual first-retired PC after each interrupt.
    // Trace lines have the format: "insn_count:cycle 0xPC ..."
    // For each irq hint at insn=N, the next retired instruction is at insn=N+1.
    // Build a lookup set of the needed insn counts, then scan.
    if (!g_irq_hints.empty()) {
        // Build map: needed_insn_count → hint index
        std::unordered_map<uint64_t, size_t> needed;
        needed.reserve(g_irq_hints.size());
        for (size_t i = 0; i < g_irq_hints.size(); ++i)
            needed[g_irq_hints[i].insn_count + 1] = i;

        FILE* f2 = fopen(path, "r");
        if (f2) {
            setvbuf(f2, nullptr, _IOFBF, 4 * 1024 * 1024);
            char line2[256];
            while (fgets(line2, sizeof(line2), f2) && !needed.empty()) {
                if (line2[0] == '!') continue;
                uint64_t t_insn, t_cyc;
                uint32_t t_pc;
                if (sscanf(line2, "%" SCNu64 ":%" SCNu64 " 0x%x",
                           &t_insn, &t_cyc, &t_pc) == 3) {
                    auto it = needed.find(t_insn);
                    if (it != needed.end()) {
                        g_irq_hints[it->second].next_rtl_pc = t_pc;
                        needed.erase(it);
                    }
                }
            }
            fclose(f2);
        }
    }
    return true;
}

// SIGINT handler
static volatile sig_atomic_t g_sigint = 0;
static void handle_sigint(int) { g_sigint = 1; }

static const char* gpr_name(int i) {
    static const char* names[32] = {
        "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
        "s0",   "s1", "a0", "a1", "a2", "a3", "a4", "a5",
        "a6",   "a7", "s2", "s3", "s4", "s5", "s6", "s7",
        "s8",   "s9", "s10","s11","t3", "t4", "t5", "t6"
    };
    return (i >= 0 && i < 32) ? names[i] : "??";
}

static void dump_registers() {
    fprintf(stderr, "\n=== Register Dump (SIGINT) ===\n");
    fprintf(stderr, "PC  : 0x%08x\n", pc);
    for (int i = 0; i < 32; i += 4) {
        fprintf(stderr, "%4s: 0x%08x    %4s: 0x%08x    %4s: 0x%08x    %4s: 0x%08x\n",
                gpr_name(i),   regs[i],
                gpr_name(i+1), regs[i+1],
                gpr_name(i+2), regs[i+2],
                gpr_name(i+3), regs[i+3]);
    }
    fprintf(stderr, "==============================\n");
}

// Debug level (0=silent, 1=info, 2=verbose)
static int debug_level = 0;

// DBG(level, fmt, ...) — emit to stderr when debug_level >= level
#define DBG(lvl, ...) \
    do { if (debug_level >= (lvl)) fprintf(stderr, "[SIM] " __VA_ARGS__); } while (0)

// ============================================================================
// Helpers
// ============================================================================
static inline int32_t sign_extend(uint32_t v, int bits) {
    int shift = 32 - bits;
    return (int32_t)((int32_t)(v << shift) >> shift);
}

// ABI register names (index = register number)
static const char* const REG_ABI[32] = {
    "zero", "ra",  "sp",  "gp",  "tp",  "t0",  "t1",  "t2",
    "s0",   "s1",  "a0",  "a1",  "a2",  "a3",  "a4",  "a5",
    "a6",   "a7",  "s2",  "s3",  "s4",  "s5",  "s6",  "s7",
    "s8",   "s9",  "s10", "s11", "t3",  "t4",  "t5",  "t6"
};

static const char* csr_name_from_addr(uint32_t csr_addr) {
    switch (csr_addr) {
    case CSR_MSTATUS:   return "mstatus";
    case CSR_MISA:      return "misa";
    case CSR_MIE:       return "mie";
    case CSR_MTVEC:     return "mtvec";
    case CSR_MTVT:      return "mtvt";
    case CSR_MSCRATCH:  return "mscratch";
    case CSR_MEPC:      return "mepc";
    case CSR_MCAUSE:    return "mcause";
    case CSR_MTVAL:     return "mtval";
    case CSR_MIP:       return "mip";
    case CSR_MNXTI:     return "mnxti";
    case CSR_MINTTHRESH:return "mintthresh";
    case CSR_MINTSTATUS:return "mintstatus";
    case CSR_MCYCLE:    return "mcycle";
    case CSR_MCYCLEH:   return "mcycleh";
    case CSR_MINSTRET:  return "minstret";
    case CSR_MINSTRETH: return "minstreth";
    case CSR_CYCLE:     return "cycle";
    case CSR_CYCLEH:    return "cycleh";
    case CSR_TIME:      return "time";
    case CSR_TIMEH:     return "timeh";
    case CSR_INSTRET:   return "instret";
    case CSR_INSTRETH:  return "instreth";
    case CSR_MVENDORID: return "mvendorid";
    case CSR_MARCHID:   return "marchid";
    case CSR_MIMPID:    return "mimpid";
    case CSR_MHARTID:   return "mhartid";
    default:            return nullptr;
    }
}

// kv32 RTL format: INSN_COUNT 0xPC (0xINSTR) [abi_reg 0xVAL] [mem 0xADDR [0xVAL]] ; disasm
static RiscvDisassembler disassembler;

static void emit_trace(uint32_t instr_pc, uint32_t raw_instr,
                       int rd, uint32_t result,
                       bool has_mem, uint32_t mem_addr,
                       uint32_t mem_val, bool is_store) {
    if (!trace_on) return;

    char base[128];
    int pos = 0;
    pos += snprintf(base + pos, sizeof(base) - pos,
                    "%" PRIu64 " 0x%08x (0x%08x)",
                    insn_count, instr_pc, raw_instr);
    if (rd > 0)
        pos += snprintf(base + pos, sizeof(base) - pos,
                        " %s 0x%08x", REG_ABI[rd], result);
    if (has_mem) {
        pos += snprintf(base + pos, sizeof(base) - pos,
                        " mem 0x%08x", mem_addr);
        if (is_store)
            pos += snprintf(base + pos, sizeof(base) - pos,
                            " 0x%08x", mem_val);
    }
    uint32_t opcode = raw_instr & 0x7Fu;
    uint32_t funct3 = (raw_instr >> 12) & 0x7u;
    if (opcode == 0x73u && funct3 != 0) {
        uint32_t csr_addr = raw_instr >> 20;
        const char* csr_name = csr_name_from_addr(csr_addr);
        if (csr_name) {
            pos += snprintf(base + pos, sizeof(base) - pos,
                            " csr %s", csr_name);
        } else {
            pos += snprintf(base + pos, sizeof(base) - pos,
                            " csr 0x%03x", csr_addr & 0xFFFu);
        }
    }

    std::string disasm = disassembler.disassemble(raw_instr, instr_pc);
    int pad = 72 - pos;
    if (pad < 2) pad = 2;
    fprintf(trace_fp, "%s%*s; %s\n", base, pad, "", disasm.c_str());
}

// ============================================================================
// Memory access helpers
// ============================================================================

// Exception state for pending trap inside mem_read/mem_write
static bool     exc_pending;
static uint32_t exc_cause;
static uint32_t exc_tval;

static inline bool in_range(uint32_t addr, uint32_t base, uint32_t span, int size) {
    uint32_t n = (uint32_t)size;
    if (n == 0 || n > span) return false;
    if (addr < base) return false;
    uint32_t off = addr - base;
    return off <= (span - n);
}

static inline bool iram_offset_for_addr(uint32_t addr, int size, uint32_t *off) {
    if (in_range(addr, IRAM_BASE, IRAM_SIZE, size)) {
        *off = addr - IRAM_BASE;
        return true;
    }
    if (in_range(addr, IRAM_ALIAS_BASE, IRAM_SIZE, size)) {
        *off = addr - IRAM_ALIAS_BASE;
        return true;
    }
    return false;
}

static inline bool dram_offset_for_addr(uint32_t addr, int size, uint32_t *off) {
    if (in_range(addr, DRAM_BASE, DRAM_SIZE, size)) {
        *off = addr - DRAM_BASE;
        return true;
    }
    if (in_range(addr, DRAM_ALIAS_BASE, DRAM_SIZE, size)) {
        *off = addr - DRAM_ALIAS_BASE;
        return true;
    }
    return false;
}

// Forward declaration (defined after the hint infrastructure)
static uint32_t consume_hint(uint32_t csr_addr, uint32_t fallback_val);

static uint32_t mem_read(uint32_t addr, int size) {
    uint32_t off = 0;

    // IRAM (primary + alias)
    if (iram_offset_for_addr(addr, size, &off)) {
        if (size == 1) return iram[off];
        if (size == 2) {
            uint32_t v;
            memcpy(&v, &iram[off], 2);
            return v & 0xFFFFu;
        }
        uint32_t v;
        memcpy(&v, &iram[off], 4);
        return v;
    }
    // DRAM (primary + alias)
    if (dram_offset_for_addr(addr, size, &off)) {
        if (size == 1) return dram[off];
        if (size == 2) {
            uint32_t v;
            memcpy(&v, &dram[off], 2);
            return v & 0xFFFFu;
        }
        uint32_t v;
        memcpy(&v, &dram[off], 4);
        return v;
    }
    // CLIC registers
    if (addr >= CLIC_BASE && addr < CLIC_BASE + 0x200000U) {
        uint32_t off = addr - CLIC_BASE;
        if (off == CLIC_MSIP_OFF)        return msip & 1u;
        if (off == CLIC_MTIME_LO_OFF) {
            uint32_t lo = consume_hint(0x1000, (uint32_t)(mtime & 0xFFFFFFFFu));
            mtime = (mtime & 0xFFFFFFFF00000000ULL) | lo;
            return lo;
        }
        if (off == CLIC_MTIME_HI_OFF) {
            uint32_t hi = consume_hint(0x1001, (uint32_t)(mtime >> 32));
            mtime = (mtime & 0x00000000FFFFFFFFULL) | ((uint64_t)hi << 32);
            return hi;
        }
        if (off == CLIC_MTIMECMP_LO_OFF) return (uint32_t)(mtimecmp & 0xFFFFFFFFu);
        if (off == CLIC_MTIMECMP_HI_OFF) return (uint32_t)(mtimecmp >> 32);
        // CLICINT[n] external interrupt control registers (offset 0x1000 + n*4)
        if (off >= 0x1000u && off < 0x1000u + 16u * 4u) {
            uint32_t n = (off - 0x1000u) / 4u;
            bool ext_irq_n = (n == 0u) ? uart_irq_active() : false;
            return (ext_irq_n             ? (1u << 0)                : 0u)  // bit0 = IP (RO)
                 | (clicint_ie[n]         ? (1u << 1)                : 0u)  // bit1 = IE
                 | ((uint32_t)clicint_ctl[n] << 16);                        // bits[23:16] = CTL
        }
        return 0;
    }
    // UART
    if (addr >= UART_BASE && addr < UART_BASE + 0x10000U) {
        uint32_t off = addr - UART_BASE;
        if (off == UART_DATA_OFF) {
            // Pop one byte from the RX FIFO on read
            if (!uart_rx_fifo.empty()) {
                uint8_t b = uart_rx_fifo.front();
                uart_rx_fifo.pop_front();
                return b;
            }
            return 0u;
        }
        if (off == UART_STATUS_OFF) {
            // bit0 = TX_BUSY (always 0 = not full), bit2 = RX_READY
            return uart_rx_fifo.empty() ? 0u : (1u << 2);
        }
        if (off == 0x08U) return uart_ie;                          // IE register
        // IS: bit1=txf_empty (always 1 in SW sim: TX is instantaneous),
        //     bit0=rxf_not_empty (RX data available)
        if (off == 0x0CU) return (1u << 1) | (uart_rx_fifo.empty() ? 0u : 1u);
        if (off == 0x10U) return (uint32_t)uart_rx_fifo.size();    // LEVEL[15:0]=RX count
        if (off == 0x14U) return uart_loopback;                    // CTRL: loopback_en
        if (off == UART_CAP_OFF) return 0x00010808u;               // version=1, rx=8, tx=8
        return 0u;
    }
    // Magic device (reads return 0)
    if (addr >= MAGIC_BASE && addr < MAGIC_BASE + 0x10000U) {
        return 0;
    }
    DBG(2, "mem_read: unmapped addr 0x%08x size=%d\n", (unsigned)addr, size);
    return 0;
}

static void mem_write(uint32_t addr, uint32_t val, int size) {
    uint32_t off = 0;

    // DRAM (primary + alias)
    if (dram_offset_for_addr(addr, size, &off)) {
        if (size == 1) dram[off] = (uint8_t)val;
        else if (size == 2) memcpy(&dram[off], &val, 2);
        else memcpy(&dram[off], &val, 4);
        return;
    }
    // IRAM (primary + alias, writable if mapped)
    if (iram_offset_for_addr(addr, size, &off)) {
        if (size == 1) iram[off] = (uint8_t)val;
        else if (size == 2) memcpy(&iram[off], &val, 2);
        else memcpy(&iram[off], &val, 4);
        return;
    }
    // CLIC registers
    if (addr >= CLIC_BASE && addr < CLIC_BASE + 0x200000U) {
        uint32_t off = addr - CLIC_BASE;
        if (off == CLIC_MSIP_OFF)        msip = val & 1u;
        else if (off == CLIC_MTIME_LO_OFF)    mtime = (mtime & 0xFFFFFFFF00000000ULL) | val;
        else if (off == CLIC_MTIME_HI_OFF)    mtime = (mtime & 0x00000000FFFFFFFFULL) | ((uint64_t)val << 32);
        else if (off == CLIC_MTIMECMP_LO_OFF) mtimecmp = (mtimecmp & 0xFFFFFFFF00000000ULL) | val;
        else if (off == CLIC_MTIMECMP_HI_OFF) mtimecmp = (mtimecmp & 0x00000000FFFFFFFFULL) | ((uint64_t)val << 32);
        // CLICINT[n] writes: update IE (bit1) and CTL (bits[23:16]); IP is read-only
        else if (off >= 0x1000u && off < 0x1000u + 16u * 4u) {
            uint32_t n = (off - 0x1000u) / 4u;
            clicint_ie[n]  = (uint8_t)((val >> 1) & 1u);
            clicint_ctl[n] = (uint8_t)((val >> 16) & 0xFFu);
        }
        return;
    }
    // UART registers
    if (addr >= UART_BASE && addr < UART_BASE + 0x10000U) {
        uint32_t off = addr - UART_BASE;
        if (off == UART_DATA_OFF) {
            fputc((int)(val & 0xFF), stdout);
            fflush(stdout);
            if (uart_loopback)                          // loopback: TX byte → RX FIFO
                uart_rx_fifo.push_back((uint8_t)(val & 0xFFu));
        } else if (off == 0x08U) {                      // IE register
            uart_ie = (uint8_t)(val & 0x3u);
        } else if (off == 0x0CU) {                      // IS — W1C, no effect in sim
        } else if (off == 0x10U) {                      // LEVEL — baud-rate divisor, ignore
        } else if (off == 0x14U) {                      // CTRL: loopback_en bit0
            uart_loopback = (uint8_t)(val & 1u);
        }
        return;
    }
    // Magic device
    if (addr >= MAGIC_BASE && addr < MAGIC_BASE + 0x10000U) {
        uint32_t off = addr - MAGIC_BASE;
        if ((off & ~3u) == MAGIC_CONSOLE_OFF) {
            // console write — print character
            fputc((int)(val & 0xFF), stdout);
            fflush(stdout);
        } else if ((off & ~3u) == MAGIC_EXIT_OFF) {
            // exit — value>>1 is the exit code
            exit_code = (int)(val >> 1);
            running   = false;
            DBG(1, "EXIT requested: code=%d\n", exit_code);
        }
        return;
    }
    // fallback: ignore
}

// Misalignment check helper (sets exc_pending if misaligned)
static bool check_align(uint32_t addr, int size, bool is_load) {
    if ((addr & (uint32_t)(size - 1)) == 0) return true;  // aligned
    exc_pending = true;
    exc_cause   = is_load ? CAUSE_LOAD_MISALIGN : CAUSE_STORE_MISALIGN;
    exc_tval    = addr;
    return false;
}

// ============================================================================
// CSR access
// ============================================================================

// Try to consume the next RTL hint for csr_addr; return the hinted value
// if found, or fall back to fallback_val.
static uint32_t consume_hint(uint32_t csr_addr, uint32_t fallback_val) {
    if (g_hint_idx < g_csr_hints.size() &&
            g_csr_hints[g_hint_idx].csr_addr == csr_addr) {
        return g_csr_hints[g_hint_idx++].value;
    }
    return fallback_val;
}

static uint32_t read_csr(uint32_t csr) {
    switch (csr) {
    case CSR_MSTATUS:   return csr_mstatus | MSTATUS_MPP;  // MPP always M-mode
    case CSR_MISA:      return 0x40001105u;  // RV32IMAC
    case CSR_MIE:       return csr_mie;
    case CSR_MTVEC:     return csr_mtvec;
    case CSR_MTVT:      return csr_mtvt;
    case CSR_MSCRATCH:  return csr_mscratch;
    case CSR_MEPC:      return csr_mepc;
    case CSR_MCAUSE:    return csr_mcause;
    case CSR_MTVAL:     return csr_mtval;
    case CSR_MIP: {
        // Compute live mip from hardware state
        uint32_t mip = 0;
        if (msip)                             mip |= MIP_MSIP;
        if (mtime >= mtimecmp &&
            mtimecmp != 0xFFFFFFFFFFFFFFFFULL) mip |= MIP_MTIP;
        return mip;
    }
    case CSR_MCYCLE:    return consume_hint(0xB00, (uint32_t)(csr_mcycle & 0xFFFFFFFFu));
    case CSR_MCYCLEH:   return consume_hint(0xB80, (uint32_t)(csr_mcycle >> 32));
    case CSR_MINSTRET:  return consume_hint(0xB02, (uint32_t)(csr_minstret & 0xFFFFFFFFu));
    case CSR_MINSTRETH: return consume_hint(0xB82, (uint32_t)(csr_minstret >> 32));
    case CSR_CYCLE:     return consume_hint(0xC00, (uint32_t)(csr_mcycle & 0xFFFFFFFFu));
    case CSR_TIME:      return consume_hint(0xC01, (uint32_t)(mtime & 0xFFFFFFFFu));
    case CSR_CYCLEH:    return consume_hint(0xC80, (uint32_t)(csr_mcycle >> 32));
    case CSR_TIMEH:     return consume_hint(0xC81, (uint32_t)(mtime >> 32));
    case CSR_INSTRET:   return consume_hint(0xC02, (uint32_t)(csr_minstret & 0xFFFFFFFFu));
    case CSR_INSTRETH:  return consume_hint(0xC82, (uint32_t)(csr_minstret >> 32));
    case CSR_MVENDORID: return 0x0u;
    case CSR_MARCHID:   return 0x0u;
    case CSR_MIMPID:    return 0x1u;
    case CSR_MHARTID:   return 0x0u;
    case CSR_MINTTHRESH:return csr_mintthresh;
    case CSR_MINTSTATUS:return (uint32_t)csr_mintstatus << 24;
    default:            return 0;
    }
}

static void write_csr(uint32_t csr, uint32_t val) {
    switch (csr) {
    case CSR_MSTATUS:
        // Only MIE (bit3) and MPIE (bit7) are writable; MPP is always 11
        csr_mstatus = (val & (MSTATUS_MIE | MSTATUS_MPIE)) | MSTATUS_MPP;
        break;
    case CSR_MIE:
        csr_mie = val & (MIP_MSIP | MIP_MTIP | MIP_MEIP);
        break;
    case CSR_MTVEC:
        csr_mtvec = (val & ~2u);  // force bit1=0 per hw
        break;
    case CSR_MTVT:       csr_mtvt     = val & ~63u;     break;
    case CSR_MSCRATCH:   csr_mscratch = val;             break;
    case CSR_MEPC:       csr_mepc     = val & ~1u;       break;
    case CSR_MCAUSE:     csr_mcause   = val;             break;
    case CSR_MTVAL:      csr_mtval    = val;             break;
    case CSR_MCYCLE:     csr_mcycle   = (csr_mcycle & 0xFFFFFFFF00000000ULL) | val; break;
    case CSR_MCYCLEH:    csr_mcycle   = (csr_mcycle & 0x00000000FFFFFFFFULL) | ((uint64_t)val << 32); break;
    case CSR_MINSTRET:   csr_minstret = (csr_minstret & 0xFFFFFFFF00000000ULL) | val; break;
    case CSR_MINSTRETH:  csr_minstret = (csr_minstret & 0x00000000FFFFFFFFULL) | ((uint64_t)val << 32); break;
    case CSR_MINTTHRESH: csr_mintthresh = (uint8_t)val; break;
    default: break;
    }
}

// ============================================================================
// Trap handling
// ============================================================================
static void take_trap(uint32_t cause, uint32_t tval, uint32_t trap_pc) {
    uint32_t mie_bit = (csr_mstatus >> 3) & 1u;
    csr_mstatus = (csr_mstatus & ~(MSTATUS_MIE | MSTATUS_MPIE))
                | (mie_bit ? MSTATUS_MPIE : 0)
                | MSTATUS_MPP;   // MPP always 11
    csr_mcause = cause;
    csr_mepc   = trap_pc & ~1u;
    csr_mtval  = tval;

    // Compute trap vector
    uint32_t base = csr_mtvec & ~3u;
    if ((csr_mtvec & 1u) && (cause & 0x80000000u)) {
        // Vectored mode for interrupts
        pc = base + 4u * (cause & 0x7FFFFFFFu);
    } else {
        pc = base;
    }
    DBG(1, "trap: cause=0x%08x tval=0x%08x pc=0x%08x -> vec=0x%08x\n",
        (unsigned)cause, (unsigned)tval, (unsigned)trap_pc, (unsigned)pc);
}

// ============================================================================
// CLIC arbiter helpers
// ============================================================================

// Return true when the UART RX interrupt is active (level-triggered).
static bool uart_irq_active() {
    return (uart_ie & 0x1u) != 0u && !uart_rx_fifo.empty();
}

// Scan CLICINT[0..15]: find the enabled+pending line with the highest CTL.
// Returns true if any line fires; sets *out_id and *out_level on success.
static bool clic_arb(uint32_t *out_id, uint8_t *out_level) {
    bool     found      = false;
    uint8_t  best_level = 0;
    uint32_t best_id    = 0;
    for (uint32_t n = 0; n < 16u; n++) {
        bool ext_irq_n = (n == 0u) ? uart_irq_active() : false;
        if (clicint_ie[n] && ext_irq_n) {
            if (!found || clicint_ctl[n] > best_level) {
                found      = true;
                best_level = clicint_ctl[n];
                best_id    = n;
            }
        }
    }
    if (found) { *out_id = best_id; *out_level = best_level; }
    return found;
}

// Take a CLIC external interrupt trap: save CSR state, compute
// PC = mtvt + clic_id*4, update mintstatus.MIL.
static void take_clic_trap(uint32_t clic_id, uint8_t clic_level, uint32_t trap_pc) {
    uint32_t mie_bit = (csr_mstatus >> 3) & 1u;
    csr_mstatus = (csr_mstatus & ~(MSTATUS_MIE | MSTATUS_MPIE))
                | (mie_bit ? MSTATUS_MPIE : 0u)
                | MSTATUS_MPP;
    csr_mcause     = CAUSE_EXTERNAL_INT;
    csr_mepc       = trap_pc & ~1u;
    csr_mtval      = 0u;
    csr_mintstatus = clic_level;
    pc = (csr_mtvt & ~63u) + clic_id * 4u;
    DBG(1, "clic_trap: id=%u level=0x%02x mepc=0x%08x pc->0x%08x\n",
        (unsigned)clic_id, (unsigned)clic_level,
        (unsigned)csr_mepc, (unsigned)pc);
}

static bool check_interrupts() {
    // When RTL hints are loaded: allow firing the timer even when mstatus.MIE=0
    // if we are exactly at the instruction that the RTL squashed via irq_cancel.
    // This handles the case where irq_cancel squashes a MIE-enabling instruction
    // (e.g. "csrsi mstatus,8") in the WB stage simultaneously with taking the
    // interrupt.
    //
    // jv32 microarchitecture note: when the squashed instruction is a CSR write
    // to mstatus that would SET MIE=1 (e.g. csrsi mstatus,8), jv32 lets the
    // CSR write commit in the same clock cycle as irq_cancel fires, so the
    // interrupt is taken with MIE=1 (MPIE←1).  We replicate this by applying
    // the CSR write side-effect before computing MPIE in take_trap.
    bool timer_at_squash_pc = g_hints_loaded && g_timer_irq_pending
                              && g_timer_irq_epc && (pc == g_timer_irq_epc);
    bool msi_at_squash_pc   = g_hints_loaded && g_msi_irq_pending
                              && g_msi_irq_epc   && (pc == g_msi_irq_epc);
    bool mei_at_squash_pc   = g_hints_loaded && g_mei_irq_pending
                              && g_mei_irq_epc   && (pc == g_mei_irq_epc);
    bool at_squash_pc = timer_at_squash_pc || msi_at_squash_pc || mei_at_squash_pc;

    // If at_squash_pc and the squashed instruction is a CSR write to mstatus
    // that enables interrupts, apply the write first (before take_trap).
    if (at_squash_pc) {
        uint16_t sq_half0 = (uint16_t)mem_read(pc & ~1u, 2);
        uint32_t sq_instr;
        if ((sq_half0 & 3u) != 3u) {
            sq_instr = expand_rvc(sq_half0);
        } else {
            uint16_t sq_half1 = (uint16_t)mem_read((pc & ~1u) + 2u, 2);
            sq_instr = ((uint32_t)sq_half1 << 16) | sq_half0;
        }
        uint32_t sq_opcode = sq_instr & 0x7Fu;
        if (sq_opcode == 0x73u) {  // SYSTEM (CSR)
            uint32_t sq_funct3 = (sq_instr >> 12) & 7u;
            uint32_t sq_csr    = sq_instr >> 20;
            if (sq_csr == 0x300u && sq_funct3 != 0u) {
                // CSR read-modify-write on mstatus: compute new value and apply
                uint32_t old_val  = (csr_mstatus & 0x1888u) | 0x1800u;
                uint32_t src_bits = (sq_funct3 & 4u)
                    ? ((sq_instr >> 15) & 0x1Fu)          // zimm for CSRRSI/CSRRCI/CSRRWI
                    : regs[(sq_instr >> 15) & 0x1Fu];     // rs1 value
                uint32_t new_val;
                switch (sq_funct3 & 3u) {
                    case 1: new_val = src_bits;              break; // CSRRW(I)
                    case 2: new_val = old_val | src_bits;    break; // CSRRS(I)
                    case 3: new_val = old_val & ~src_bits;   break; // CSRRC(I)
                    default: new_val = old_val;              break;
                }
                // Apply write to mstatus
                csr_mstatus = (new_val & (MSTATUS_MIE | MSTATUS_MPIE)) | MSTATUS_MPP;
                DBG(1, "at_squash_pc: applied csrsi mstatus side-effect, "
                       "mstatus=0x%08x\n", (unsigned)csr_mstatus);
            }
        }
    }

    if (!(csr_mstatus & MSTATUS_MIE) && !at_squash_pc) return false;

    // When RTL hints are loaded: timer fires only via g_timer_irq_pending (set
    // by the hint mechanism below).  Without hints, or once all hints have been
    // consumed (g_irq_hints empty), fire naturally so vTaskDelay() never hangs.
    bool all_irq_hints_done = g_hints_loaded && g_irq_hints.empty() && !g_timer_irq_pending;
    bool timer_irq = g_timer_irq_pending ||
                     ((!g_hints_loaded || all_irq_hints_done) &&
                      mtime >= mtimecmp &&
                      mtimecmp != 0xFFFFFFFFFFFFFFFFULL);
    bool soft_irq  = (msip != 0);

    // CLIC external interrupt arbiter
    uint32_t clic_id    = 0;
    uint8_t  clic_level = 0;
    bool clic_irq_active = clic_arb(&clic_id, &clic_level);
    // Consume the tail-chain flag (set by mret returning from a CLIC trap).
    // When set, allow one natural CLIC MEI check even with hints loaded so
    // that tail-chained interrupts (which emit no ! irq hint in the RTL trace)
    // still fire correctly.
    bool tail_chain_allowed = g_just_did_mret;
    g_just_did_mret = false;
    bool natural_mei     = (!g_hints_loaded || tail_chain_allowed) && clic_irq_active
                           && clic_level > csr_mintthresh;
    bool mei_irq = g_mei_irq_pending || natural_mei;

    if (mei_irq) {
        // CLIC external interrupt has highest priority (no mie.MEIE gate in RTL).
        // RTL condition: clic_irq && clic_level > mintthresh && mstatus_mie.
        // (mstatus.MIE already checked at the top of this function via at_squash_pc guard.)
        g_mei_irq_pending = false;
        if (!clic_irq_active) {
            for (uint32_t n = 0; n < 16u; n++) {
                if (clicint_ie[n]) { clic_id = n; clic_level = clicint_ctl[n]; break; }
            }
        }
        uint32_t trap_pc = (g_hints_loaded && g_mei_irq_epc && pc == g_mei_irq_epc)
                            ? g_mei_irq_epc : pc;
        take_clic_trap(clic_id, clic_level, trap_pc);
        return true;
    } else if ((csr_mie & MIP_MTIP) && timer_irq) {
        bool hint_triggered = g_timer_irq_pending;  // set by hint, not natural timer
        g_timer_irq_pending = false;  // consumed
        uint32_t hint_next = g_timer_irq_next_rtl_pc;
        g_timer_irq_next_rtl_pc = 0;

        // Compute where a normal interrupt would redirect to (mtvec / vectored).
        uint32_t mtvec_base = csr_mtvec & ~3u;
        uint32_t expected_irq_pc = (csr_mtvec & 1u)
            ? mtvec_base + 4u * (CAUSE_TIMER_INT & 0x7FFFFFFFu)
            : mtvec_base;

        // Detect "spurious ISR due to load-use stall" (jv32 microarch quirk):
        // When irq_cancel fires while load_use_stall=1 in the jv32 pipeline,
        // pc_if is frozen and NOT redirected to mtvec.  The RTL trace will show
        // the next instruction at a PC other than mtvec.  We use the recorded
        // next_rtl_pc as ground truth: if it differs from the expected IRQ target
        // it's a spurious ISR — update CSRs as normal but set PC to next_rtl_pc.
        if (hint_triggered && hint_next != 0 && hint_next != expected_irq_pc) {
            DBG(1, "spurious_isr: epc=0x%08x next_rtl_pc=0x%08x\n",
                (unsigned)g_timer_irq_epc, (unsigned)hint_next);
            uint32_t epc = (pc == g_timer_irq_epc) ? g_timer_irq_epc : pc;
            uint32_t mie_bit = (csr_mstatus >> 3) & 1u;
            csr_mstatus = (csr_mstatus & ~(MSTATUS_MIE | MSTATUS_MPIE))
                        | (mie_bit ? MSTATUS_MPIE : 0u)
                        | MSTATUS_MPP;
            csr_mcause = CAUSE_TIMER_INT;
            csr_mepc   = epc & ~1u;
            csr_mtval  = 0u;
            pc = hint_next;
            return true;
        }

        uint32_t trap_pc = (g_hints_loaded && g_timer_irq_epc && pc == g_timer_irq_epc)
                           ? g_timer_irq_epc : pc;
        take_trap(CAUSE_TIMER_INT, 0, trap_pc);
        return true;
    } else if ((csr_mie & MIP_MSIP) && soft_irq) {
        if (msi_at_squash_pc) {
            // RTL squashed the instruction at msi_irq_epc (e.g. csrrsi that
            // enables MIE) while simultaneously firing the MSI.  Match that
            // behaviour: take the trap at the squash PC without retiring it.
            g_msi_irq_pending = false;
            take_trap(CAUSE_SOFTWARE_INT, 0, g_msi_irq_epc);
            return true;
        } else if (!timer_at_squash_pc) {
            // Normal MSI (not suppressed by a simultaneous timer squash).
            take_trap(CAUSE_SOFTWARE_INT, 0, pc);
            return true;
        }
    }
    return false;
}

// ============================================================================
// RVC compressed instruction expander
// Translated from jv32_rvc.sv expand_c() function.
// ============================================================================
static inline int32_t c_sext6(uint32_t v) {
    return (v & 0x20u) ? (int32_t)(v | 0xFFFFFFC0u) : (int32_t)v;
}
static inline int32_t c_sext9(uint32_t v) {
    return (v & 0x100u) ? (int32_t)(v | 0xFFFFFF00u) : (int32_t)v;
}
static inline int32_t c_sext10(uint32_t v) {
    return (v & 0x200u) ? (int32_t)(v | 0xFFFFFE00u) : (int32_t)v;
}
static inline int32_t c_sext12(uint32_t v) {
    return (v & 0x800u) ? (int32_t)(v | 0xFFFFF000u) : (int32_t)v;
}

static int32_t c_j_off(uint16_t ci) {
    uint32_t v = ((ci >> 12) & 1u) << 11
               | ((ci >>  8) & 1u) << 10
               | ((ci >>  9) & 3u) << 8
               | ((ci >>  6) & 1u) << 7
               | ((ci >>  7) & 1u) << 6
               | ((ci >>  2) & 1u) << 5
               | ((ci >> 11) & 1u) << 4
               | ((ci >>  3) & 7u) << 1;
    return c_sext12(v);
}

static int32_t c_b_off(uint16_t ci) {
    uint32_t v = ((ci >> 12) & 1u) << 8
               | ((ci >>  5) & 3u) << 6
               | ((ci >>  2) & 1u) << 5
               | ((ci >> 10) & 3u) << 3
               | ((ci >>  3) & 3u) << 1;
    return c_sext9(v);
}

static uint32_t enc_jal(uint32_t rd, int32_t imm) {
    uint32_t u = (uint32_t)imm;
    return ((u >> 20) & 1u) << 31
         | ((u >>  1) & 0x3FFu) << 21
         | ((u >> 11) & 1u) << 20
         | ((u >> 12) & 0xFFu) << 12
         | (rd << 7)
         | 0x6Fu;
}

static uint32_t enc_br(uint32_t f3, uint32_t rs1, uint32_t rs2, int32_t imm) {
    uint32_t u = (uint32_t)imm;
    return ((u >> 12) & 1u) << 31
         | ((u >>  5) & 0x3Fu) << 25
         | (rs2 << 20)
         | (rs1 << 15)
         | (f3 << 12)
         | ((u >>  1) & 0xFu) << 8
         | ((u >> 11) & 1u) << 7
         | 0x63u;
}

static uint32_t expand_rvc(uint16_t ci) {
    uint32_t quad   = ci & 3u;
    uint32_t funct3 = (ci >> 13) & 7u;
    uint32_t rd_p   = 8u + ((ci >> 2) & 7u);   // compressed rd'
    uint32_t rs1_p  = 8u + ((ci >> 7) & 7u);   // compressed rs1'
    uint32_t rs2_p  = 8u + ((ci >> 2) & 7u);   // compressed rs2' (same as rd_p)
    uint32_t uimm;

    switch (quad) {
    // ── Quadrant 0 ──────────────────────────────────────────────────────────
    case 0:
        switch (funct3) {
        case 0: { // c.addi4spn → addi rd', sp, nzuimm
            // nzuimm[9:6]=ci[10:7], [5:4]=ci[12:11], [3]=ci[5], [2]=ci[6]
            uimm = ((ci >> 7) & 0xFu) << 6
                 | ((ci >> 11) & 3u)  << 4
                 | ((ci >>  5) & 1u)  << 3
                 | ((ci >>  6) & 1u)  << 2;
            if (uimm == 0) return 0;
            return (uimm << 20) | (2u << 15) | (0u << 12) | (rd_p << 7) | 0x13u;
        }
        case 2: { // c.lw → lw rd', uimm(rs1')
            uimm = ((ci >>  5) & 1u) << 6
                 | ((ci >> 10) & 7u) << 3
                 | ((ci >>  6) & 1u) << 2;
            return (uimm << 20) | (rs1_p << 15) | (2u << 12) | (rd_p << 7) | 0x03u;
        }
        case 6: { // c.sw → sw rs2', uimm(rs1')
            uimm = ((ci >>  5) & 1u) << 6
                 | ((ci >> 10) & 7u) << 3
                 | ((ci >>  6) & 1u) << 2;
            return ((uimm >> 5) << 25) | (rs2_p << 20) | (rs1_p << 15)
                 | (2u << 12) | ((uimm & 0x1Fu) << 7) | 0x23u;
        }
        case 4: { // Q0,f3=4: custom Zcb — LBU,LH,LHU,SB,SH subset
            // Decode ci[11:10] for sub-type
            uint32_t sub = (ci >> 10) & 3u;
            if (sub == 0) { // c.lbu: lbu rd', uimm(rs1')
                uimm = ((ci >> 5) & 1u) << 1 | ((ci >> 6) & 1u);
                return (uimm << 20) | (rs1_p << 15) | (4u << 12) | (rd_p << 7) | 0x03u;
            } else if (sub == 1) { // c.lh / c.lhu
                uimm = ((ci >> 5) & 1u) << 1;
                uint32_t f3h = ((ci >> 6) & 1u) ? 1u : 5u;  // LH or LHU
                return (uimm << 20) | (rs1_p << 15) | (f3h << 12) | (rd_p << 7) | 0x03u;
            } else if (sub == 2) { // c.sb: sb rs2', uimm(rs1')
                uimm = ((ci >> 5) & 1u) << 1 | ((ci >> 6) & 1u);
                return ((uimm >> 1) << 25) | (rs2_p << 20) | (rs1_p << 15)
                     | (0u << 12) | ((uimm & 1u) << 7) | 0x23u;
            } else { // c.sh: sh rs2', uimm(rs1')
                uimm = ((ci >> 5) & 1u) << 1;
                return ((uimm >> 1) << 25) | (rs2_p << 20) | (rs1_p << 15)
                     | (1u << 12) | ((uimm & 1u) << 7) | 0x23u;
            }
        }
        default: return 0;
        }
        break;

    // ── Quadrant 1 ──────────────────────────────────────────────────────────
    case 1: {
        uint32_t rd_rs1 = (ci >> 7) & 0x1Fu;

        switch (funct3) {
        case 0: { // c.addi / c.nop
            int32_t nzimm = c_sext6(((ci >> 12) & 1u) << 5 | ((ci >> 2) & 0x1Fu));
            return ((uint32_t)(nzimm & 0xFFF) << 20) | (rd_rs1 << 15)
                 | (0u << 12) | (rd_rs1 << 7) | 0x13u;
        }
        case 1: // c.jal (RV32) → jal x1, offset
            return enc_jal(1u, c_j_off(ci));
        case 2: { // c.li → addi rd, x0, imm
            int32_t imm = c_sext6(((ci >> 12) & 1u) << 5 | ((ci >> 2) & 0x1Fu));
            return ((uint32_t)(imm & 0xFFF) << 20) | (0u << 15)
                 | (0u << 12) | (rd_rs1 << 7) | 0x13u;
        }
        case 3: {
            if (rd_rs1 == 2u) { // c.addi16sp
                int32_t nz = c_sext10(((ci >> 12) & 1u) << 9 | ((ci >> 3) & 3u) << 7
                                    | ((ci >>  5) & 1u) << 6 | ((ci >> 2) & 1u) << 5
                                    | ((ci >>  6) & 1u) << 4);
                if (nz == 0) return 0;
                return ((uint32_t)(nz & 0xFFF) << 20) | (2u << 15)
                     | (0u << 12) | (2u << 7) | 0x13u;
            } else { // c.lui
                int32_t nz = c_sext6(((ci >> 12) & 1u) << 5 | ((ci >> 2) & 0x1Fu));
                if (nz == 0) return 0;
                return ((uint32_t)(nz & 0xFFFFF) << 12) | (rd_rs1 << 7) | 0x37u;
            }
        }
        case 4: {
            uint32_t funct2 = (ci >> 10) & 3u;
            uint32_t rd_p2  = 8u + ((ci >> 7) & 7u);
            uint32_t rs2_p2 = 8u + ((ci >> 2) & 7u);
            switch (funct2) {
            case 0: { // c.srli
                uint32_t sh = ((ci >> 12) & 1u) << 5 | ((ci >> 2) & 0x1Fu);
                return (sh << 20) | (rd_p2 << 15) | (5u << 12)
                     | (rd_p2 << 7) | 0x13u;
            }
            case 1: { // c.srai
                uint32_t sh = ((ci >> 12) & 1u) << 5 | ((ci >> 2) & 0x1Fu);
                return (0x20u << 25) | (sh << 20) | (rd_p2 << 15)
                     | (5u << 12) | (rd_p2 << 7) | 0x13u;
            }
            case 2: { // c.andi
                int32_t im = c_sext6(((ci >> 12) & 1u) << 5 | ((ci >> 2) & 0x1Fu));
                return ((uint32_t)(im & 0xFFF) << 20) | (rd_p2 << 15)
                     | (7u << 12) | (rd_p2 << 7) | 0x13u;
            }
            case 3: {
                bool f1 = ((ci >> 12) & 1u) != 0;
                uint32_t f2l = (ci >> 5) & 3u;
                if (!f1) {
                    switch (f2l) {
                    case 0: return (0x20u<<25)|(rs2_p2<<20)|(rd_p2<<15)|(0u<<12)|(rd_p2<<7)|0x33u; // c.sub
                    case 1: return (0x00u<<25)|(rs2_p2<<20)|(rd_p2<<15)|(4u<<12)|(rd_p2<<7)|0x33u; // c.xor
                    case 2: return (0x00u<<25)|(rs2_p2<<20)|(rd_p2<<15)|(6u<<12)|(rd_p2<<7)|0x33u; // c.or
                    case 3: return (0x00u<<25)|(rs2_p2<<20)|(rd_p2<<15)|(7u<<12)|(rd_p2<<7)|0x33u; // c.and
                    }
                } else {
                    switch (f2l) {
                    case 2: // c.mul (Zcb)
                        return (0x01u<<25)|(rs2_p2<<20)|(rd_p2<<15)|(0u<<12)|(rd_p2<<7)|0x33u;
                    case 3: { // c.zext / c.not / etc (Zcb hints, treat as NOP)
                        uint32_t sub = (ci >> 2) & 7u;
                        if (sub == 0) // c.zext.b: andi rd, rd, 255
                            return (0xFF << 20) | (rd_p2 << 15) | (7u << 12) | (rd_p2 << 7) | 0x13u;
                        if (sub == 4) // c.zext.h: ZEXT.H rd = (funct7=0x04, rs2=x0, funct3=4) -> zext.h rd,rd
                            return (0x04u<<25)|(0u<<20)|(rd_p2<<15)|(4u<<12)|(rd_p2<<7)|0x33u;
                        if (sub == 5) // c.not: xori rd, rd, -1
                            return (0xFFF << 20) | (rd_p2 << 15) | (4u << 12) | (rd_p2 << 7) | 0x13u;
                        return 0x00000013u; // NOP
                    }
                    default: return 0x00000013u;
                    }
                }
                return 0;
            }
            }
            return 0;
        }
        case 5: // c.j → jal x0, offset
            return enc_jal(0u, c_j_off(ci));
        case 6: // c.beqz → beq rs1', x0, offset
            return enc_br(0u, 8u + ((ci >> 7) & 7u), 0u, c_b_off(ci));
        case 7: // c.bnez → bne rs1', x0, offset
            return enc_br(1u, 8u + ((ci >> 7) & 7u), 0u, c_b_off(ci));
        }
        return 0;
    }

    // ── Quadrant 2 ──────────────────────────────────────────────────────────
    case 2: {
        uint32_t rd_rs1f = (ci >> 7) & 0x1Fu;
        uint32_t rs2f    = (ci >> 2) & 0x1Fu;

        switch (funct3) {
        case 0: { // c.slli
            uint32_t sh = ((ci >> 12) & 1u) << 5 | rs2f;
            return (sh << 20) | (rd_rs1f << 15) | (1u << 12)
                 | (rd_rs1f << 7) | 0x13u;
        }
        case 2: { // c.lwsp → lw rd, uimm(sp)
            if (rd_rs1f == 0) return 0;
            uimm = ((ci >> 2) & 3u) << 6 | ((ci >> 12) & 1u) << 5
                 | ((ci >> 4) & 7u) << 2;
            return (uimm << 20) | (2u << 15) | (2u << 12)
                 | (rd_rs1f << 7) | 0x03u;
        }
        case 4: {
            bool f1 = ((ci >> 12) & 1u) != 0;
            if (!f1) {
                if (rs2f == 0) { // c.jr → jalr x0, 0(rs1)
                    if (rd_rs1f == 0) return 0;
                    return (0u << 20) | (rd_rs1f << 15) | (0u << 12)
                         | (0u << 7) | 0x67u;
                } else { // c.mv → add rd, x0, rs2
                    return (0u<<25)|(rs2f<<20)|(0u<<15)|(0u<<12)|(rd_rs1f<<7)|0x33u;
                }
            } else {
                if (rs2f == 0) {
                    if (rd_rs1f == 0) return 0x00100073u; // c.ebreak
                    // c.jalr → jalr x1, 0(rs1)
                    return (0u<<20)|(rd_rs1f<<15)|(0u<<12)|(1u<<7)|0x67u;
                } else { // c.add → add rd, rd, rs2
                    return (0u<<25)|(rs2f<<20)|(rd_rs1f<<15)|(0u<<12)|(rd_rs1f<<7)|0x33u;
                }
            }
        }
        case 6: { // c.swsp → sw rs2, uimm(sp)
            // uimm[7:6]=ci[8:7], [5:2]=ci[12:9], [1:0]=00
            uimm = ((ci >> 7) & 3u) << 6 | ((ci >> 9) & 0xFu) << 2;
            return ((uimm >> 5) << 25) | (rs2f << 20) | (2u << 15)
                 | (2u << 12) | ((uimm & 0x1Fu) << 7) | 0x23u;
        }
        default: return 0;
        }
        break;
    }
    } // switch quad
    return 0;
}

// ============================================================================
// Main instruction execution step
// ============================================================================
static void step() {
    // ── 1. Advance counters and check interrupts ──────────────────────────
    // mtime and mcycle are incremented on instruction retirement (below), not here

    if (check_interrupts()) return;
    if (!running) return;

    // ── 2. Fetch instruction ───────────────────────────────────────────────
    uint32_t instr_pc = pc;
    uint32_t instr;
    uint32_t pc_step;

    // Read first halfword
    uint16_t half0 = (uint16_t)mem_read(instr_pc & ~1u, 2);
    uint32_t raw_instr;  // original encoding passed to disassembler

    if ((half0 & 3u) != 3u) {
        // Compressed 16-bit instruction
        raw_instr = (uint32_t)half0;
        instr   = expand_rvc(half0);
        pc_step = 2;
        if (instr == 0) {
            // Illegal compressed instruction
            exc_pending = true;
            exc_cause   = CAUSE_ILLEGAL_INSN;
            exc_tval    = half0;
        }
    } else {
        // Full 32-bit instruction
        uint16_t half1 = (uint16_t)mem_read((instr_pc & ~1u) + 2, 2);
        instr     = ((uint32_t)half1 << 16) | half0;
        raw_instr = instr;
        pc_step = 4;
    }

    // ── 3. Pre-decode top-level exception check ────────────────────────────
    if (exc_pending) {
        take_trap(exc_cause, exc_tval, instr_pc);
        exc_pending = false;
        return;
    }

    // Decode common fields
    uint32_t opcode = instr & 0x7Fu;
    uint32_t rd     = (instr >> 7)  & 0x1Fu;
    uint32_t funct3 = (instr >> 12) & 0x7u;
    uint32_t rs1    = (instr >> 15) & 0x1Fu;
    uint32_t rs2    = (instr >> 20) & 0x1Fu;
    uint32_t funct7 = (instr >> 25) & 0x7Fu;

    uint32_t a = regs[rs1];
    uint32_t b = regs[rs2];

    uint32_t result        = 0;
    bool     do_write      = false;
    uint32_t new_pc        = instr_pc + pc_step;
    bool     retired       = true;   // most instructions retire normally

    // Memory-access trace fields
    uint32_t trace_mem_addr = 0;
    uint32_t trace_mem_val  = 0;
    bool     trace_has_mem  = false;
    bool     trace_is_store = false;

    // I-type immediate (sign-extended)
    auto imm_i = [&]() -> uint32_t {
        return (uint32_t)sign_extend(instr >> 20, 12);
    };
    // S-type immediate
    auto imm_s = [&]() -> uint32_t {
        return (uint32_t)sign_extend((funct7 << 5) | rd, 12);
    };
    // B-type immediate
    auto imm_b = [&]() -> uint32_t {
        uint32_t v = ((instr >> 31) & 1u) << 12
                   | ((instr >>  7) & 1u) << 11
                   | ((instr >> 25) & 0x3Fu) << 5
                   | ((instr >>  8) & 0xFu)  << 1;
        return (uint32_t)sign_extend(v, 13);
    };
    // U-type immediate
    auto imm_u = [&]() -> uint32_t {
        return instr & 0xFFFFF000u;
    };
    // J-type immediate
    auto imm_j = [&]() -> uint32_t {
        uint32_t v = ((instr >> 31) & 1u) << 20
                   | ((instr >> 12) & 0xFFu) << 12
                   | ((instr >> 20) & 1u) << 11
                   | ((instr >> 21) & 0x3FFu) << 1;
        return (uint32_t)sign_extend(v, 21);
    };

    switch (opcode) {
    // ── LUI ──────────────────────────────────────────────────────────────
    case 0x37:  // LUI
        result = imm_u();
        do_write = true;
        break;

    // ── AUIPC ─────────────────────────────────────────────────────────────
    case 0x17:  // AUIPC
        result = instr_pc + imm_u();
        do_write = true;
        break;

    // ── JAL ───────────────────────────────────────────────────────────────
    case 0x6F:  // JAL
        result   = instr_pc + pc_step;  // link address
        do_write = true;
        new_pc   = instr_pc + imm_j();
        break;

    // ── JALR ──────────────────────────────────────────────────────────────
    case 0x67:  // JALR
        result   = instr_pc + pc_step;
        do_write = true;
        new_pc   = (a + imm_i()) & ~1u;
        break;

    // ── Branches ──────────────────────────────────────────────────────────
    case 0x63: {
        bool taken = false;
        switch (funct3) {
        case 0: taken = (a == b);                    break; // BEQ
        case 1: taken = (a != b);                    break; // BNE
        case 4: taken = ((int32_t)a < (int32_t)b);   break; // BLT
        case 5: taken = ((int32_t)a >= (int32_t)b);  break; // BGE
        case 6: taken = (a < b);                     break; // BLTU
        case 7: taken = (a >= b);                    break; // BGEU
        default: exc_pending=true; exc_cause=CAUSE_ILLEGAL_INSN; exc_tval=instr; break;
        }
        if (taken) new_pc = instr_pc + imm_b();
        // branches do NOT write rd — no trace
        break;
    }

    // ── Loads ─────────────────────────────────────────────────────────────
    case 0x03: {
        uint32_t addr = a + imm_i();
        switch (funct3) {
        case 0: result = (uint32_t)sign_extend(mem_read(addr, 1) & 0xFFu, 8);     break; // LB
        case 1: if (!check_align(addr, 2, true)) break;
                result = (uint32_t)sign_extend(mem_read(addr, 2) & 0xFFFFu, 16);  break; // LH
        case 2: if (!check_align(addr, 4, true)) break;
                result = mem_read(addr, 4);                                        break; // LW
        case 4: result = mem_read(addr, 1) & 0xFFu;                               break; // LBU
        case 5: if (!check_align(addr, 2, true)) break;
                result = mem_read(addr, 2) & 0xFFFFu;                             break; // LHU
        default: exc_pending=true; exc_cause=CAUSE_ILLEGAL_INSN; exc_tval=instr;  break;
        }
        do_write = !exc_pending;
        if (do_write) {
            trace_has_mem  = true;
            trace_mem_addr = addr;
            trace_is_store = false;
        }
        break;
    }

    // ── Stores ────────────────────────────────────────────────────────────
    case 0x23: {
        uint32_t addr = a + imm_s();
        // JV32 handles misaligned stores transparently as byte-lane writes.
        switch (funct3) {
        case 0: mem_write(addr, b & 0xFFu,   1); break; // SB
        case 1: mem_write(addr, b & 0xFFFFu, 2); break; // SH
        case 2: mem_write(addr, b,           4); break; // SW
        default: exc_pending=true; exc_cause=CAUSE_ILLEGAL_INSN; exc_tval=instr; break;
        }
        if (!exc_pending) {
            trace_has_mem  = true;
            trace_mem_addr = addr;
            // Mask to store width to match RTL trace format: SB→byte, SH→halfword, SW→word
            switch (funct3) {
            case 0:  trace_mem_val = b & 0xFFu;   break; // SB
            case 1:  trace_mem_val = b & 0xFFFFu; break; // SH
            default: trace_mem_val = b;            break; // SW
            }
            trace_is_store = true;
        }
        // stores do NOT write rd
        break;
    }

    // ── OP-IMM ────────────────────────────────────────────────────────────
    case 0x13: {
        uint32_t imm = imm_i();
        switch (funct3) {
        case 0: result = a + imm;                               break; // ADDI
        case 2: result = ((int32_t)a < (int32_t)imm) ? 1u : 0u; break; // SLTI
        case 3: result = (a < imm) ? 1u : 0u;                   break; // SLTIU
        case 4: result = a ^ imm;                               break; // XORI
        case 6: result = a | imm;                               break; // ORI
        case 7: result = a & imm;                               break; // ANDI
        case 1: // SLLI / Zbb unary (CLZ/CTZ/CPOP/SEXT.B/SEXT.H) / Zbs BCLRI/BINVI/BSETI
            if (funct7 == 0x00) {
                result = a << (imm & 0x1Fu);         // SLLI
            } else if (funct7 == 0x30) { // Zbb: CLZ / CTZ / CPOP / SEXT.B / SEXT.H
                switch (rs2) { // shamt field doubles as op selector
                case 0: { uint32_t n=0; for(int i=31;i>=0;i--){if((a>>i)&1){n=(uint32_t)(31-i);goto clz_done;}} n=32; clz_done: result=n; break; } // CLZ
                case 1: { uint32_t n=0; for(int i=0;i<=31;i++){if((a>>i)&1){n=(uint32_t)i;goto ctz_done;}} n=32; ctz_done: result=n; break; } // CTZ
                case 2: { uint32_t n=0; for(int i=0;i<=31;i++) n+=(a>>i)&1u; result=n; break; } // CPOP
                case 4: result = (uint32_t)sign_extend(a & 0xFFu, 8);   break; // SEXT.B
                case 5: result = (uint32_t)sign_extend(a & 0xFFFFu, 16); break; // SEXT.H
                default: exc_pending=true; exc_cause=CAUSE_ILLEGAL_INSN; exc_tval=instr; break;
                }
            } else if (funct7 == 0x14) { // Zbs: BSETI
                result = a | (1u << (imm & 0x1Fu));
            } else if (funct7 == 0x24) { // Zbs: BCLRI
                result = a & ~(1u << (imm & 0x1Fu));
            } else if (funct7 == 0x34) { // Zbs: BINVI
                result = a ^ (1u << (imm & 0x1Fu));
            } else {
                exc_pending=true; exc_cause=CAUSE_ILLEGAL_INSN; exc_tval=instr;
            }
            break;
        case 5: // SRLI / SRAI / Zbb RORI / Zbb ORC.B / Zbb REV8 / Zbs BEXTI
            if      (funct7 == 0x00) { result = a >> (imm & 0x1Fu); // SRLI
            } else if (funct7 == 0x20) { result = (uint32_t)((int32_t)a >> (imm & 0x1Fu)); // SRAI
            } else if (funct7 == 0x30) { // Zbb: RORI
                { uint32_t n=imm&0x1Fu; result=(a>>n)|(a<<(32u-n)); }
            } else if (funct7 == 0x14 && rs2 == 7)  { // Zbb: ORC.B (shamt=0x07)
                result = (a & 0xFF000000u ? 0xFF000000u : 0u)
                       | (a & 0x00FF0000u ? 0x00FF0000u : 0u)
                       | (a & 0x0000FF00u ? 0x0000FF00u : 0u)
                       | (a & 0x000000FFu ? 0x000000FFu : 0u);
            } else if (funct7 == 0x34 && rs2 == 24) { // Zbb: REV8 (shamt=0x18)
                result = ((a & 0x000000FFu) << 24)
                       | ((a & 0x0000FF00u) << 8)
                       | ((a & 0x00FF0000u) >> 8)
                       | ((a & 0xFF000000u) >> 24);
            } else if (funct7 == 0x24) { // Zbs: BEXTI
                result = (a >> (imm & 0x1Fu)) & 1u;
            } else {
                exc_pending=true; exc_cause=CAUSE_ILLEGAL_INSN; exc_tval=instr;
            }
            break;
        default: break;
        }
        do_write = !exc_pending;
        break;
    }

    // ── OP (R-type arithmetic, incl RV32M) ───────────────────────────────
    case 0x33: {
        if (funct7 == 0x01) { // RV32M
            switch (funct3) {
            case 0: result = (uint32_t)((int64_t)(int32_t)a * (int64_t)(int32_t)b); break; // MUL
            case 1: result = (uint32_t)(((int64_t)(int32_t)a * (int64_t)(int32_t)b) >> 32); break; // MULH
            case 2: result = (uint32_t)(((int64_t)(int32_t)a * (uint64_t)(uint32_t)b) >> 32); break; // MULHSU
            case 3: result = (uint32_t)(((uint64_t)a * (uint64_t)b) >> 32); break; // MULHU
            case 4: result = (b == 0) ? 0xFFFFFFFFu : (uint32_t)((int32_t)a / (int32_t)b); break; // DIV
            case 5: result = (b == 0) ? 0xFFFFFFFFu : a / b;                 break; // DIVU
            case 6: result = (b == 0) ? a : (uint32_t)((int32_t)a % (int32_t)b); break; // REM
            case 7: result = (b == 0) ? a : a % b;                            break; // REMU
            default: break;
            }
            do_write = true;
        } else {
            switch ((funct7 << 3) | funct3) {
            case 0x000: result = a + b;                                  break; // ADD
            case 0x100: result = a - b;                                  break; // SUB
            case 0x001: result = a << (b & 0x1Fu);                       break; // SLL
            case 0x002: result = ((int32_t)a < (int32_t)b) ? 1u : 0u;    break; // SLT
            case 0x003: result = (a < b) ? 1u : 0u;                      break; // SLTU
            case 0x004: result = a ^ b;                                  break; // XOR
            case 0x005: result = a >> (b & 0x1Fu);                       break; // SRL
            case 0x105: result = (uint32_t)((int32_t)a >> (b & 0x1Fu));  break; // SRA
            case 0x006: result = a | b;                                  break; // OR
            case 0x007: result = a & b;                                  break; // AND
            // Zba: address generation  (funct7=0x10)
            case 0x082: result = (a << 1) + b;                           break; // SH1ADD
            case 0x084: result = (a << 2) + b;                           break; // SH2ADD
            case 0x086: result = (a << 3) + b;                           break; // SH3ADD
            // Zbb: logical-with-negate (funct7=0x20, reuses funct7 of SUB/SRA)
            case 0x104: result = a ^ ~b;                                 break; // XNOR
            case 0x106: result = a | ~b;                                 break; // ORN
            case 0x107: result = a & ~b;                                 break; // ANDN
            // Zbb: min/max             (funct7=0x05)
            case 0x02C: result = ((int32_t)a < (int32_t)b) ? a : b;      break; // MIN
            case 0x02D: result = (a < b) ? a : b;                        break; // MINU
            case 0x02E: result = ((int32_t)a > (int32_t)b) ? a : b;      break; // MAX
            case 0x02F: result = (a > b) ? a : b;                        break; // MAXU
            // Zbb: rotate              (funct7=0x30)
            case 0x181: { uint32_t n=b&0x1Fu; result=(a<<n)|(a>>(32u-n)); break; } // ROL
            case 0x185: { uint32_t n=b&0x1Fu; result=(a>>n)|(a<<(32u-n)); break; } // ROR
            // Zbb: ZEXT.H              (funct7=0x04, rs2 must be x0)
            case 0x024:
                if (rs2 == 0) result = a & 0xFFFFu;
                else { exc_pending=true; exc_cause=CAUSE_ILLEGAL_INSN; exc_tval=instr; }
                break; // ZEXT.H
            // Zbs: single-bit ops      (funct7=0x14/0x24/0x34)
            case 0x0A1: result = a | (1u << (b & 0x1Fu));                break; // BSET
            case 0x121: result = a & ~(1u << (b & 0x1Fu));               break; // BCLR
            case 0x125: result = (a >> (b & 0x1Fu)) & 1u;                break; // BEXT
            case 0x1A1: result = a ^ (1u << (b & 0x1Fu));                break; // BINV
            default:
                exc_pending = true; exc_cause = CAUSE_ILLEGAL_INSN; exc_tval = instr;
                break;
            }
            do_write = !exc_pending;
        }
        break;
    }

    // ── SYSTEM (CSR, ECALL, EBREAK, MRET, WFI) ───────────────────────────
    case 0x73: {
        if (funct3 == 0) {
            uint32_t sys_imm = instr >> 20;
            if      (sys_imm == 0x000) { // ECALL
                exc_pending = true; exc_cause = CAUSE_ECALL_M; exc_tval = 0;
            } else if (sys_imm == 0x001) { // EBREAK
                exc_pending = true; exc_cause = CAUSE_BREAKPOINT; exc_tval = instr_pc;
            } else if (sys_imm == 0x302) { // MRET
                uint32_t mpie = (csr_mstatus >> 7) & 1u;
                // When returning from a CLIC trap (MIL != 0) in hints mode,
                // set the tail-chain flag so check_interrupts() on the next
                // step() allows one natural CLIC MEI check (tail-chain has
                // no ! irq hint in the RTL trace).
                if (g_hints_loaded && csr_mintstatus != 0)
                    g_just_did_mret = true;
                csr_mstatus = (csr_mstatus & ~(MSTATUS_MIE | MSTATUS_MPIE))
                            | (mpie ? MSTATUS_MIE : 0)
                            | MSTATUS_MPIE     // MPIE set to 1
                            | MSTATUS_MPP;     // MPP stays M-mode
                csr_mintstatus = 0;            // clear MIL on exit from interrupt context
                new_pc = csr_mepc;
                // MRET does not write rd → no do_write
            } else if (sys_imm == 0x105) { // WFI — treat as NOP
                // do nothing special (interrupts checked at top of next step)
            } else {
                exc_pending = true; exc_cause = CAUSE_ILLEGAL_INSN; exc_tval = instr;
            }
        } else {
            // CSR instructions
            bool is_imm = (funct3 & 4u) != 0;
            uint32_t csr_addr = instr >> 20;
            uint32_t old_val  = read_csr(csr_addr);
            uint32_t src      = is_imm ? rs1 : a;  // rs1 field as zimm or reg value

            result   = old_val;
            do_write = (rd != 0);  // write rd with old CSR value

            // Update CSR based on op
            switch (funct3 & 3u) {
            case 1: write_csr(csr_addr, src);           break; // CSRRW(I)
            case 2: write_csr(csr_addr, old_val | src); break; // CSRRS(I)
            case 3: write_csr(csr_addr, old_val & ~src);break; // CSRRC(I)
            }
        }
        break;
    }

    // ── FENCE (FENCE, FENCE.I) — treat as NOP ────────────────────────────
    case 0x0F:
        break;

    // ── AMO (RV32A) ───────────────────────────────────────────────────────
    case 0x2F: {
        uint32_t amo_op = (instr >> 27) & 0x1Fu;
        uint32_t addr   = a;
        if (!check_align(addr, 4, true)) break;
        uint32_t val    = mem_read(addr, 4);
        result   = val;
        do_write = true;
        uint32_t new_val = val;
        switch (amo_op) {
        case 0x00: new_val = val + b;                             break; // AMOADD
        case 0x01: new_val = b;                                   break; // AMOSWAP
        case 0x04: new_val = val ^ b;                             break; // AMOXOR
        case 0x0C: new_val = val & b;                             break; // AMOAND
        case 0x08: new_val = val | b;                             break; // AMOOR
        case 0x10: new_val = ((int32_t)val < (int32_t)b) ? val : b; break; // AMOMIN
        case 0x14: new_val = ((int32_t)val > (int32_t)b) ? val : b; break; // AMOMAX
        case 0x18: new_val = (val < b) ? val : b;                break; // AMOMINU
        case 0x1C: new_val = (val > b) ? val : b;                break; // AMOMAXU
        case 0x02: // LR.W
            result = val; do_write = true; new_val = val; break;
        case 0x03: // SC.W — always succeeds in software sim
            new_val = b; result = 0; break;
        default:
            exc_pending = true; exc_cause = CAUSE_ILLEGAL_INSN; exc_tval = instr;
            do_write = false; break;
        }
        if (!exc_pending) {
            mem_write(addr, new_val, 4);
            trace_has_mem  = true;
            trace_mem_addr = addr;
            trace_mem_val  = new_val;
            trace_is_store = true;
        }
        break;
    }

    // ── Unknown opcode ────────────────────────────────────────────────────
    default:
        exc_pending = true;
        exc_cause   = CAUSE_ILLEGAL_INSN;
        exc_tval    = instr;
        break;
    } // switch opcode

    // ── 4. Handle pending exception from execution ─────────────────────────
    if (exc_pending) {
        take_trap(exc_cause, exc_tval, instr_pc);
        exc_pending = false;
        retired     = false;
    }

    // ── 5. Write result and emit trace ─────────────────────────────────────
    if (retired) {
        if (do_write && rd != 0)
            regs[rd] = result;
        regs[0] = 0;  // x0 always zero
        pc = new_pc;
        mtime++;        // increment mtime per retired instruction (approx. clock cycles)
        csr_mcycle++;   // increment mcycle per retired instruction (fallback when no RTL hint)
        csr_minstret++;
        insn_count++;
        emit_trace(instr_pc, raw_instr,
                   (do_write && rd != 0) ? (int)rd : 0, result,
                   trace_has_mem, trace_mem_addr, trace_mem_val, trace_is_store);
    }
}

// ============================================================================
// ELF loader
// ============================================================================
static bool load_elf(const char *path, uint32_t *entry) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "[SIM] Cannot open ELF: %s (%s)\n", path, strerror(errno));
        return false;
    }

    // Read ELF header
    Elf32_Ehdr ehdr;
    if (fread(&ehdr, sizeof(ehdr), 1, f) != 1) { fclose(f); return false; }
    if (memcmp(ehdr.e_ident, ELFMAG, 4) != 0) {
        fprintf(stderr, "[SIM] Not an ELF file: %s\n", path);
        fclose(f); return false;
    }
    *entry = ehdr.e_entry;

    // Load PT_LOAD segments
    for (int i = 0; i < ehdr.e_phnum; i++) {
        Elf32_Phdr phdr;
        fseek(f, (long)(ehdr.e_phoff + i * ehdr.e_phentsize), SEEK_SET);
        if (fread(&phdr, sizeof(phdr), 1, f) != 1) { fclose(f); return false; }
        if (phdr.p_type != PT_LOAD || phdr.p_memsz == 0) continue;

        uint32_t vaddr = phdr.p_vaddr;
        uint8_t *dst   = nullptr;
        uint32_t max_sz;

        if (vaddr >= IRAM_BASE && vaddr < IRAM_BASE + IRAM_SIZE) {
            dst    = iram + (vaddr - IRAM_BASE);
            max_sz = IRAM_SIZE - (vaddr - IRAM_BASE);
        } else if (vaddr >= DRAM_BASE && vaddr < DRAM_BASE + DRAM_SIZE) {
            dst    = dram + (vaddr - DRAM_BASE);
            max_sz = DRAM_SIZE - (vaddr - DRAM_BASE);
        } else {
            DBG(2, "Warning: PT_LOAD segment at 0x%08x outside known regions\n", (unsigned)vaddr);
            continue;
        }

        // Zero the full memory range first (BSS zeroing)
        if (phdr.p_memsz <= max_sz)
            memset(dst, 0, phdr.p_memsz);

        // Copy file data to VMA
        fseek(f, (long)phdr.p_offset, SEEK_SET);
        uint32_t to_copy = (phdr.p_filesz < phdr.p_memsz) ? phdr.p_filesz : phdr.p_memsz;
        if (to_copy > max_sz) to_copy = max_sz;
        if (to_copy > 0 && fread(dst, 1, to_copy, f) != to_copy) {
            fprintf(stderr, "[SIM] ELF read error at segment %d\n", i);
            fclose(f); return false;
        }

        // When LMA (p_paddr) differs from VMA (p_vaddr), also copy file data to
        // the LMA region.  Bare-metal startup code copies .data from LMA (e.g.
        // IRAM at end of .text) to VMA (DRAM); without the LMA populated the
        // startup reads zeros and overwrites the correctly-initialised VMA data.
        uint32_t paddr = phdr.p_paddr;
        if (to_copy > 0 && paddr != phdr.p_vaddr) {
            uint8_t *dst_lma = nullptr;
            uint32_t max_lma = 0;
            if (paddr >= IRAM_BASE && paddr < IRAM_BASE + IRAM_SIZE) {
                dst_lma = iram + (paddr - IRAM_BASE);
                max_lma = IRAM_SIZE - (paddr - IRAM_BASE);
            } else if (paddr >= DRAM_BASE && paddr < DRAM_BASE + DRAM_SIZE) {
                dst_lma = dram + (paddr - DRAM_BASE);
                max_lma = DRAM_SIZE - (paddr - DRAM_BASE);
            }
            if (dst_lma && to_copy <= max_lma) {
                fseek(f, (long)phdr.p_offset, SEEK_SET);
                if (fread(dst_lma, 1, to_copy, f) != to_copy) {
                    fprintf(stderr, "[SIM] ELF read error at LMA for segment %d\n", i);
                    fclose(f); return false;
                }
            }
        }
    }

    fclose(f);
    DBG(1, "ELF loaded: %s (entry=0x%08x)\n", path, (unsigned)*entry);
    return true;
}

// ============================================================================
// Main
// ============================================================================
int main(int argc, char **argv) {
    std::signal(SIGINT, handle_sigint);

    const char *elf_path    = nullptr;
    const char *trace_path  = nullptr;
    const char *hints_path  = nullptr;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--trace") == 0 && i + 1 < argc) {
            trace_path = argv[++i];
        } else if (strcmp(argv[i], "--rtl-hints") == 0 && i + 1 < argc) {
            hints_path = argv[++i];
        } else if (strncmp(argv[i], "--max-insns=", 12) == 0) {
            max_insns = (uint64_t)strtoull(argv[i] + 12, nullptr, 10);
        } else if (strcmp(argv[i], "--max-insns") == 0 && i + 1 < argc) {
            max_insns = (uint64_t)strtoull(argv[++i], nullptr, 10);
        } else if (strncmp(argv[i], "--timeout=", 10) == 0) {
            timeout_seconds = (uint64_t)strtoull(argv[i] + 10, nullptr, 10);
        } else if (strncmp(argv[i], "--debug=", 8) == 0) {
            debug_level = (int)strtol(argv[i] + 8, nullptr, 10);
        } else if (strcmp(argv[i], "--debug") == 0 && i + 1 < argc) {
            debug_level = (int)strtol(argv[++i], nullptr, 10);
        } else if (!elf_path) {
            elf_path = argv[i];
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            return 1;
        }
    }

    if (!elf_path) {
        fprintf(stderr, "Usage: %s [--trace <file>] [--rtl-hints <file>] [--max-insns <N>] [--timeout=<sec>] [--debug=<N>] <elf>\n", argv[0]);
        return 1;
    }

    // Open trace file (only enabled when --trace is given)
    if (trace_path) {
        trace_fp = fopen(trace_path, "w");
        if (!trace_fp) {
            fprintf(stderr, "[SIM] Cannot open trace file: %s\n", trace_path);
            return 1;
        }
        setvbuf(trace_fp, nullptr, _IOFBF, 4 * 1024 * 1024);  // 4 MB write buffer
        trace_on = true;
    }

    // Load RTL hints (optional — used to sync cycle-counter CSR values)
    if (hints_path) {
        if (!load_rtl_hints(hints_path)) return 1;
        g_hints_loaded = true;
        DBG(1, "Loaded %zu cycle-CSR hints from %s\n",
            g_csr_hints.size(), hints_path);
    }

    // Initialise state
    memset(regs, 0, sizeof(regs));
    memset(iram, 0, sizeof(iram));
    memset(dram, 0, sizeof(dram));
    csr_mstatus  = MSTATUS_MPP;  // MPP=11 (M-mode), MIE=0
    csr_mie      = 0;
    csr_mtvec    = 0;
    csr_mscratch = 0;
    csr_mepc     = 0;
    csr_mcause   = 0;
    csr_mtval    = 0;
    csr_mcycle   = 0;
    csr_minstret = 0;
    mtime        = 0;
    mtimecmp     = 0xFFFFFFFFFFFFFFFFULL;
    msip         = 0;
    memset(clicint_ie,  0, sizeof(clicint_ie));
    memset(clicint_ctl, 0, sizeof(clicint_ctl));
    uart_loopback = 0;
    uart_ie       = 0;
    uart_rx_fifo.clear();
    exc_pending  = false;
    running      = true;
    exit_code    = 0;
    insn_count   = 0;

    // Load ELF
    uint32_t entry = 0;
    if (!load_elf(elf_path, &entry)) return 1;
    pc = entry;

    // Run
    auto time_begin = std::chrono::steady_clock::now();
    while (running && !g_sigint) {
        if (g_sigint) break;
        if (max_insns && insn_count >= max_insns) {
            DBG(1, "Reached max-insns limit (%llu)\n",
                    (unsigned long long)max_insns);
            break;
        }
        if (timeout_seconds > 0) {
            uint64_t elapsed = (uint64_t)std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - time_begin).count();
            if (elapsed >= timeout_seconds) {
                fprintf(stderr, "\n*** TIMEOUT: Simulation exceeded %llu seconds (--timeout) ***\n",
                        (unsigned long long)timeout_seconds);
                exit_code = 1;
                break;
            }
        }
        // Apply squashed-store hints before irq hints: when the JV32 pipeline
        // committed a store's DRAM write before the interrupt squashed the
        // instruction, replay that write now so the SW sim memory matches.
        while (!g_sq_store_hints.empty() &&
               insn_count >= g_sq_store_hints.front().insn_count) {
            DBG(2, "[sq_store] write 0x%08x = 0x%08x at insn=%llu\n",
                (unsigned)g_sq_store_hints.front().addr,
                (unsigned)g_sq_store_hints.front().data,
                (unsigned long long)insn_count);
            mem_write(g_sq_store_hints.front().addr, g_sq_store_hints.front().data, 4);
            g_sq_store_hints.pop_front();
        }
        // Apply any pending IRQ hint once the retirement count matches.
        // Suppress natural timer firing (above) while a hint is pending so the
        // interrupt fires at exactly the same instruction as in the RTL.
        if (!g_irq_hints.empty() && insn_count >= g_irq_hints.front().insn_count) {
            uint32_t hint_epc        = g_irq_hints.front().epc;
            uint32_t hint_cause      = g_irq_hints.front().cause;
            uint32_t hint_next_rtlpc = g_irq_hints.front().next_rtl_pc;
            g_irq_hints.pop_front();
            // Timer interrupt (cause = 0x8000_0007): set mtime = mtimecmp so
            // that check_interrupts() fires on the very next step().
            if ((hint_cause & 0x8000007Fu) == 0x80000007u &&
                    mtimecmp != 0xFFFFFFFFFFFFFFFFULL) {
                DBG(2, "[irq] tick at insn=%llu epc=0x%08x hint_idx=%zu\n",
                    (unsigned long long)insn_count, (unsigned)hint_epc, g_hint_idx);
                mtime = mtimecmp;        // keep mtime in sync at tick boundaries
                g_timer_irq_pending     = true;  // fire on the very next step()
                g_timer_irq_epc         = hint_epc;
                g_timer_irq_next_rtl_pc = hint_next_rtlpc;
            } else if ((hint_cause & 0x8000007Fu) == 0x80000003u) {
                // MSI hint: fire on the very next step() at hint_epc.
                // The RTL squashes the instruction at hint_epc (typically a
                // csrrsi that enables MIE) in the same cycle the interrupt fires.
                DBG(2, "[irq] msi hint at insn=%llu epc=0x%08x\n",
                    (unsigned long long)insn_count, (unsigned)hint_epc);
                g_msi_irq_pending = true;
                g_msi_irq_epc     = hint_epc;
            } else if ((hint_cause & 0x8000007Fu) == 0x8000000Bu) {
                // MEI hint (CLIC external interrupt): fire on the very next step().
                DBG(2, "[irq] mei hint at insn=%llu epc=0x%08x\n",
                    (unsigned long long)insn_count, (unsigned)hint_epc);
                g_mei_irq_pending = true;
                g_mei_irq_epc     = hint_epc;
            }
        }
        step();
    }

    if (g_sigint || exit_code) {
        fprintf(stderr, "\n*** SIGINT received: dumping registers and exiting ***\n");
        dump_registers();
        exit_code = 1;
    }

    auto   time_end = std::chrono::steady_clock::now();
    double elapsed_seconds = std::chrono::duration<double>(time_end - time_begin).count();
    double eff_hz = (elapsed_seconds > 0.0) ? ((double)csr_mcycle / elapsed_seconds) : 0.0;
    double eff_mhz = eff_hz / 1.0e6;

    double cpi = (insn_count > 0) ? ((double)csr_mcycle / (double)insn_count) : 0.0;
    DBG(1, "%llu instructions retired\n",
        (unsigned long long)insn_count);
    fprintf(stderr, "[SIM] Run stats: wall=%.6f s, cycles=%llu, eff_freq=%.3f MHz, CPI=%.3f\n",
        elapsed_seconds,
        (unsigned long long)csr_mcycle,
        eff_mhz,
        cpi);

    if (trace_fp && trace_fp != stdout) fclose(trace_fp);
    return exit_code;
}
