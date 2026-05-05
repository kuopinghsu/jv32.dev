// ============================================================================
// File: tb_jv32_soc.cpp
// Project: JV32 RISC-V Processor
// Description: Verilator C++ Testbench Driver
//
// Usage: ./jv32soc <elf> [--trace <file.fst|file.vcd>] [--rtl-trace <file>]
//                        [--max-cycles <N>] [--timeout=<sec>] [--kanata=<file>]
// ============================================================================

#include <verilated.h>
#if VM_TRACE_VCD
#include <verilated_vcd_c.h>
#else
#include <verilated_fst_c.h>
#endif
#if VM_COVERAGE
#include <verilated_cov.h>
#endif
#include "Vtb_jv32_soc.h"
#include "elfloader.h"
#include <svdpi.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sstream>
#include <iomanip>
#include <iostream>
#include <fstream>
#include <inttypes.h>
#include <chrono>
#include <csignal>
#include "riscv-dis.h"

static const char* const RTL_REG_ABI[32] = {
    "zero","ra","sp","gp","tp","t0","t1","t2",
    "s0","s1","a0","a1","a2","a3","a4","a5",
    "a6","a7","s2","s3","s4","s5","s6","s7",
    "s8","s9","s10","s11","t3","t4","t5","t6"
};
static RiscvDisassembler rtl_disasm;

static const char* csr_name_from_addr(uint32_t csr_addr) {
    switch (csr_addr) {
    case 0x300: return "mstatus";
    case 0x301: return "misa";
    case 0x304: return "mie";
    case 0x305: return "mtvec";
    case 0x307: return "mtvt";
    case 0x340: return "mscratch";
    case 0x341: return "mepc";
    case 0x342: return "mcause";
    case 0x343: return "mtval";
    case 0x344: return "mip";
    case 0x345: return "mnxti";
    case 0x347: return "mintthresh";
    case 0xFB1: return "mintstatus";
    case 0xB00: return "mcycle";
    case 0xB80: return "mcycleh";
    case 0xB02: return "minstret";
    case 0xB82: return "minstreth";
    case 0xC00: return "cycle";
    case 0xC80: return "cycleh";
    case 0xC01: return "time";
    case 0xC81: return "timeh";
    case 0xC02: return "instret";
    case 0xC82: return "instreth";
    case 0xF11: return "mvendorid";
    case 0xF12: return "marchid";
    case 0xF13: return "mimpid";
    case 0xF14: return "mhartid";
    default:    return nullptr;
    }
}

static void emit_rtl_trace(FILE* fp, uint64_t n, uint64_t cyc, uint32_t pc, uint32_t instr,
                           uint32_t rd, uint32_t rddata,
                           bool mem_we, bool mem_re, uint32_t mem_addr, uint32_t mem_data) {
    std::ostringstream oss;
    oss << std::dec << n << ":" << cyc << " "
        << "0x" << std::hex << std::setfill('0') << std::setw(8) << pc << " "
        << "(0x" << std::setw(8) << instr << ")";
    if (rd != 0) {
        oss << " " << RTL_REG_ABI[rd]
            << " 0x" << std::setfill('0') << std::setw(8) << rddata;
    }
    if (mem_we) {
        // Store: emit addr and data
        oss << " mem 0x" << std::setfill('0') << std::setw(8) << mem_addr
            << " 0x" << std::setw(8) << mem_data;
    } else if (mem_re) {
        // Load: emit addr only (no data, matching SW sim format)
        oss << " mem 0x" << std::setfill('0') << std::setw(8) << mem_addr;
    }
    uint32_t opcode = instr & 0x7fu;
    uint32_t funct3 = (instr >> 12) & 0x7u;
    if (opcode == 0x73u && funct3 != 0) {
        uint32_t csr_addr = instr >> 20;
        const char* csr_name = csr_name_from_addr(csr_addr);
        if (csr_name) {
            oss << " csr " << csr_name;
        } else {
            oss << " csr 0x" << std::hex << std::setfill('0') << std::setw(3)
                << (csr_addr & 0xFFFu);
        }
    }
    std::string base = oss.str();
    std::string disasm = rtl_disasm.disassemble(instr, pc);
    int pad = 72 - (int)base.size();
    if (pad < 2) pad = 2;
    fprintf(fp, "%s%*s; %s\n", base.c_str(), pad, "", disasm.c_str());

    // Emit '! hint' comment for cycle-counter CSR reads so jv32sim can sync.
    // Detect: opcode=0x73 (SYSTEM), funct3 != 0, csr_addr in cycle-CSR set.
    if (rd != 0 && opcode == 0x73u && funct3 != 0) {
        uint32_t csr_addr = instr >> 20;
        const char* csr_name = csr_name_from_addr(csr_addr);
        if (csr_name && (csr_addr == 0xB00 || csr_addr == 0xB80 || csr_addr == 0xB02 ||
                         csr_addr == 0xB82 || csr_addr == 0xC00 || csr_addr == 0xC80 ||
                         csr_addr == 0xC01 || csr_addr == 0xC81 || csr_addr == 0xC02 ||
                         csr_addr == 0xC82))
            fprintf(fp, "! csr_hint %s 0x%08x\n", csr_name, rddata);
    }
    // Emit mtime hints for CLIC peripheral reads so jv32sim can sync its
    // internal mtime with the RTL's actual clock-cycle-based counter.
    // rddata = rd register value = the value loaded from the CLIC address.
    if (mem_re && rd != 0) {
        if (mem_addr == 0x02004000U)       // CLIC_MTIME_LO
            fprintf(fp, "! csr_hint mtime_lo 0x%08x\n", rddata);
        else if (mem_addr == 0x02004004U)  // CLIC_MTIME_HI
            fprintf(fp, "! csr_hint mtime_hi 0x%08x\n", rddata);
    }
}

// ============================================================================
// Kanata RTL Pipeline Visualizer
// ============================================================================
// Emits Kanata 0004 format logs for pipeline visualization in the Kanata tool.
// Tracks the 3-stage jv32 pipeline (F/EX/WB) via DPI pipeline snapshot.
//
// Stage names:
//   F   – Fetch       (instruction at rvc expander output)
//   EX  – Execute     (instruction in if_ex_r: decode+ALU+CSR)
//   WB  – Writeback   (instruction in ex_wb_r: memory/writeback)
//   stl – Stall overlay (lane 1): instruction held in stage for ≥2 cycles
//   msp – Misprediction penalty (lane 2): annotated on the branch at WB
// ============================================================================

struct PipelineSnapshot {
    // IF stage (rvc expander output, instruction entering EX next cycle)
    bool     if_valid;
    uint32_t pc_if;
    uint32_t orig_instr_if;
    // EX stage (if_ex_r pipeline register)
    bool     ex_valid;
    uint32_t pc_ex;
    uint32_t orig_instr_ex;
    // WB stage (ex_wb_r pipeline register)
    bool     wb_valid;
    bool     retire;
    uint32_t pc_wb;
    uint32_t orig_instr_wb;
    // Stall / flush / redirect
    bool     if_stall;    // EX stall: if_ex_r held this cycle
    bool     ex_stall;    // WB stall: ex_wb_r held this cycle (multi-cycle / load)
    bool     if_flush;    // IF flush (branch mispred / exception redirect)
    bool     ex_flush;    // EX flush (inject bubble into EX stage)
    // Branch prediction
    bool     bp_taken_ex; // prediction flag carried into EX (if_ex_r.bp_taken)
    bool     redirect_ex; // EX redirect fired (ex_wb_r.redirect & !ex_stall)
};

class KanataRTL {
public:
    static constexpr uint64_t INVALID_FID = ~0ULL;
    static constexpr int STAGE_IF  = 0;
    static constexpr int STAGE_EX  = 1;
    static constexpr int STAGE_WB  = 2;
    static constexpr int NUM_STAGES = 3;
    static constexpr const char* STAGE_NAME[3] = {"F", "EX", "WB"};

    struct SlotState {
        bool     valid       = false;
        uint32_t pc          = 0;
        uint32_t instr       = 0;
        uint64_t fid         = INVALID_FID;
        bool     stl_open    = false;   // lane-1 "stl" stage is open
        bool     msp_open    = false;   // lane-2 "msp" stage is open
        bool     retired     = false;   // retire fired while in WB
        void clear() { *this = SlotState{}; }
    };

private:
    std::ofstream     file_;
    bool              enabled_    = false;
    uint64_t          cur_cycle_  = 0;
    uint64_t          file_id_    = 0;
    uint64_t          retire_id_  = 0;
    SlotState         st_[NUM_STAGES]; // pipeline stage shadows: IF, EX, WB
    RiscvDisassembler dis_;

    // ── Low-level emit helpers ────────────────────────────────────────────
    void emit_I(uint64_t fid, int tid) {
        file_ << "I\t" << fid << "\t" << fid << "\t" << tid << "\n";
    }
    void emit_L(uint64_t fid, int type, const std::string& text) {
        file_ << "L\t" << fid << "\t" << type << "\t" << text << "\n";
    }
    void emit_S(uint64_t fid, int lane, const char* stage) {
        file_ << "S\t" << fid << "\t" << lane << "\t" << stage << "\n";
    }
    void emit_E(uint64_t fid, int lane, const char* stage) {
        file_ << "E\t" << fid << "\t" << lane << "\t" << stage << "\n";
    }
    void emit_R(uint64_t fid, uint64_t ret_id, int type) {
        file_ << "R\t" << fid << "\t" << ret_id << "\t" << type << "\n";
    }

    // Close overlay lanes then end lane-0 stage
    void close_stage(SlotState& sl, int stage) {
        if (!sl.valid || sl.fid == INVALID_FID) return;
        if (sl.stl_open) { emit_E(sl.fid, 1, "stl"); sl.stl_open = false; }
        if (sl.msp_open) { emit_E(sl.fid, 2, "msp"); sl.msp_open = false; }
        emit_E(sl.fid, 0, STAGE_NAME[stage]);
    }

    static std::string hex8(uint32_t v) {
        std::ostringstream ss;
        ss << std::hex << std::setfill('0') << std::setw(8) << v;
        return ss.str();
    }

    // ── Check if snapshot has (pc,instr) at given stage ──────────────────
    bool snap_has(const PipelineSnapshot& s, int stage, uint32_t pc, uint32_t instr) const {
        switch (stage) {
        case STAGE_IF: return s.if_valid && s.pc_if == pc && s.orig_instr_if == instr;
        case STAGE_EX: return s.ex_valid && s.pc_ex == pc && s.orig_instr_ex == instr;
        case STAGE_WB: return s.wb_valid && s.pc_wb == pc && s.orig_instr_wb == instr;
        default:       return false;
        }
    }

    // ── Per-cycle forward pass ────────────────────────────────────────────
    void step_pipeline(const PipelineSnapshot& snap) {
        const bool     sv[NUM_STAGES] = { snap.if_valid, snap.ex_valid, snap.wb_valid };
        const uint32_t sp[NUM_STAGES] = { snap.pc_if,    snap.pc_ex,    snap.pc_wb   };
        const uint32_t si[NUM_STAGES] = { snap.orig_instr_if, snap.orig_instr_ex,
                                          snap.orig_instr_wb };

        uint64_t carry_fid = INVALID_FID;

        for (int s = STAGE_IF; s <= STAGE_WB; s++) {
            bool     new_v = sv[s];
            uint32_t new_p = sp[s];
            uint32_t new_i = si[s];

            // Stall: same instruction held this cycle
            bool same = st_[s].valid && new_v &&
                        st_[s].pc == new_p && st_[s].instr == new_i;
            if (same) {
                if (s == STAGE_WB && snap.retire)
                    st_[s].retired = true;
                else if (!st_[s].stl_open) {
                    emit_S(st_[s].fid, 1, "stl");
                    st_[s].stl_open = true;
                }
                carry_fid = INVALID_FID;
                continue;
            }

            // Old instruction departing this stage
            uint64_t next_carry = INVALID_FID;
            if (st_[s].valid && st_[s].fid != INVALID_FID) {
                close_stage(st_[s], s);
                if (s < STAGE_WB) {
                    if (snap_has(snap, s + 1, st_[s].pc, st_[s].instr))
                        next_carry = st_[s].fid;
                    else
                        emit_R(st_[s].fid, 0, 1);  // flushed
                } else {
                    if (st_[s].retired)
                        emit_R(st_[s].fid, retire_id_++, 0);  // normal retirement
                    else
                        emit_R(st_[s].fid, 0, 1);              // flush / exception
                }
            }

            // New instruction arriving this stage
            if (new_v) {
                uint64_t use_fid;
                if (s == STAGE_IF) {
                    // New instruction entering the pipeline
                    use_fid = file_id_++;
                    emit_I(use_fid, 0);
                    emit_L(use_fid, 0, "0x" + hex8(new_p) + ": " +
                                       dis_.disassemble(new_i, new_p));
                } else {
                    // Carry fid from previous stage, or create fallback entry
                    if (carry_fid != INVALID_FID) {
                        use_fid = carry_fid;
                    } else {
                        use_fid = file_id_++;
                        emit_I(use_fid, 0);
                        emit_L(use_fid, 0, "0x" + hex8(new_p) + ": " +
                                           dis_.disassemble(new_i, new_p));
                    }
                }
                emit_S(use_fid, 0, STAGE_NAME[s]);
                bool wb_retired = (s == STAGE_WB && snap.retire);
                st_[s] = { true, new_p, new_i, use_fid, false, false, wb_retired };
            } else {
                st_[s].clear();
            }

            carry_fid = next_carry;
        }

        // ── Branch misprediction annotation on WB instruction ────────────
        // redirect_ex fires the cycle ex_wb_r.redirect is sampled non-stalled.
        // Annotate the instruction currently in WB (which caused the redirect).
        if (snap.redirect_ex && st_[STAGE_WB].valid &&
            st_[STAGE_WB].fid != INVALID_FID && !st_[STAGE_WB].msp_open) {
            std::string pred = snap.bp_taken_ex ? "pred=T" : "pred=NT";
            emit_L(st_[STAGE_WB].fid, 1, "EX redirect: " + pred);
            emit_S(st_[STAGE_WB].fid, 2, "msp");
            st_[STAGE_WB].msp_open = true;
        }
    }

public:
    void open(const char* filename) {
        file_.open(filename);
        if (!file_.is_open()) {
            std::cerr << "WARNING: Cannot open Kanata log file: " << filename << "\n";
            return;
        }
        enabled_ = true;
        file_ << "Kanata\t0004\n";
        file_ << "C=\t0\n";
    }

    bool enabled() const { return enabled_; }

    // Called every clock cycle (after DUT eval on posedge).
    void step(const PipelineSnapshot& snap) {
        if (!enabled_) return;
        cur_cycle_++;
        file_ << "C\t1\n";
        step_pipeline(snap);
    }

    void finish() {
        if (!enabled_) return;
        // Flush any instructions still in the pipeline
        for (int s = STAGE_IF; s <= STAGE_WB; s++) {
            if (st_[s].valid && st_[s].fid != INVALID_FID) {
                if (st_[s].stl_open) emit_E(st_[s].fid, 1, "stl");
                if (st_[s].msp_open) emit_E(st_[s].fid, 2, "msp");
                emit_E(st_[s].fid, 0, STAGE_NAME[s]);
                emit_R(st_[s].fid, 0, 1);
            }
        }
        file_.flush();
        file_.close();
    }
};

#ifndef CLK_FREQ_HZ
#  define CLK_FREQ_HZ    80'000'000ULL   // default; override via -DCLK_FREQ_HZ=
#endif
#define CLK_PERIOD_PS  (1'000'000'000'000ULL / CLK_FREQ_HZ)  // derived period
#define CLK_HALF_PS    (CLK_PERIOD_PS / 2ULL)                 // half period

// Magic exit address
#define MAGIC_EXIT_ADDR  0x40000000U

static volatile sig_atomic_t g_sigint = 0;
static void sig_handler(int) { g_sigint = 1; }

static bool g_exit_requested = false;
static int  g_exit_code      = 0;

// DPI-C import: read a GPR by index from the running SV simulation
extern "C" int get_gpr(int idx);

static const char* gpr_name(int i) {
    static const char* names[32] = {
        "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
        "s0",   "s1", "a0", "a1", "a2", "a3", "a4", "a5",
        "a6",   "a7", "s2", "s3", "s4", "s5", "s6", "s7",
        "s8",   "s9", "s10","s11","t3", "t4", "t5", "t6"
    };
    return (i >= 0 && i < 32) ? names[i] : "??";
}

static void dump_registers(Vtb_jv32_soc* dut) {
    fprintf(stderr, "\n=== Register Dump (SIGINT) ===\n");
    fprintf(stderr, "PC  : 0x%08x\n", (uint32_t)dut->trace_pc);
    for (int i = 0; i < 32; i += 4) {
        fprintf(stderr, "%4s: 0x%08x    %4s: 0x%08x    %4s: 0x%08x    %4s: 0x%08x\n",
                gpr_name(i),   (uint32_t)get_gpr(i),
                gpr_name(i+1), (uint32_t)get_gpr(i+1),
                gpr_name(i+2), (uint32_t)get_gpr(i+2),
                gpr_name(i+3), (uint32_t)get_gpr(i+3));
    }
    fprintf(stderr, "==============================\n");
}

// ============================================================================
// SoC memory image (shared with SV via DPI or direct Verilator signal write)
// The jv32_soc instantiates axi_ram_ctrl which wraps sram_1rw.
// We pre-load the SRAMs via Verilator's direct signal access.
// ============================================================================

// Forward: defined below
static void load_elf_to_dut(Vtb_jv32_soc* dut, const char* elf_path,
                             uint32_t iram_base, uint32_t iram_size,
                             uint32_t dram_base, uint32_t dram_size);

// DPI-C: called by axi_magic when EXIT magic address is written.
// Use a deferred exit so the main loop can sample trace_valid for the
// exit-store instruction before terminating.
extern "C" void sim_request_exit(int exit_code) {
    fprintf(stderr, "[SIM] EXIT requested: code=%d\n", exit_code);
    g_exit_requested = true;
    g_exit_code      = exit_code;
}

// ============================================================================
static uint64_t sim_time = 0;

static void tick(Vtb_jv32_soc* dut
#if VM_TRACE_VCD
                 , VerilatedVcdC* vcdp
#else
                 , VerilatedFstC* tfp
#endif
                 ) {
    // Rising edge
    dut->clk = 1;
    dut->eval();
#if VM_TRACE_VCD
    if (vcdp) vcdp->dump(sim_time);
#else
    if (tfp)  tfp->dump(sim_time);
#endif
    sim_time += CLK_HALF_PS;

    // Falling edge
    dut->clk = 0;
    dut->eval();
#if VM_TRACE_VCD
    if (vcdp) vcdp->dump(sim_time);
#else
    if (tfp)  tfp->dump(sim_time);
#endif
    sim_time += CLK_HALF_PS;
}

int main(int argc, char** argv) {
    signal(SIGINT, sig_handler);

    // -------------------------------------------------------------------------
    // Parse arguments
    // -------------------------------------------------------------------------
    const char* elf_path        = nullptr;
    const char* trace_file      = nullptr;
    const char* rtl_trace_file  = nullptr;
    const char* kanata_file     = nullptr;
    uint64_t    max_cycles      = 0;   // 0 = unlimited
    uint64_t    timeout_seconds = 0;   // 0 = no timeout

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--trace") == 0 && i+1 < argc) {
            trace_file = argv[++i];
        } else if (strcmp(argv[i], "--rtl-trace") == 0 && i+1 < argc) {
            rtl_trace_file = argv[++i];
        } else if (strncmp(argv[i], "--max-cycles=", 13) == 0) {
            max_cycles = (uint64_t)strtoull(argv[i] + 13, nullptr, 10);
        } else if (strcmp(argv[i], "--max-cycles") == 0 && i+1 < argc) {
            max_cycles = (uint64_t)strtoull(argv[++i], nullptr, 10);
        } else if (strcmp(argv[i], "--timeout") == 0 && i+1 < argc) {
            timeout_seconds = (uint64_t)strtoull(argv[++i], nullptr, 10);
        } else if (strncmp(argv[i], "--timeout=", 10) == 0) {
            timeout_seconds = (uint64_t)strtoull(argv[i] + 10, nullptr, 10);
        } else if (strncmp(argv[i], "--kanata=", 9) == 0) {
            kanata_file = argv[i] + 9;
        } else if (argv[i][0] == '+') {
            // +verilator+... Verilator runtime args (e.g. +verilator+coverage+file+<path>)
            // are handled by ctx->commandArgs() below; skip in manual parser.
        } else if (!elf_path) {
            elf_path = argv[i];
        } else {
            fprintf(stderr, "Unknown arg: %s\n", argv[i]);
            return 1;
        }
    }

    if (!elf_path) {
        fprintf(stderr, "JV32 RISC-V RTL Simulator (Verilator)\n");
        fprintf(stderr, "\n");
        fprintf(stderr, "Usage: %s <elf> [options]\n", argv[0]);
        fprintf(stderr, "\n");
        fprintf(stderr, "Options:\n");
        fprintf(stderr, "  --trace <file.fst|file.vcd>   Dump waveform to FST or VCD file\n");
        fprintf(stderr, "  --rtl-trace <file>            Enable Spike-format RTL trace log (use '-' for stdout)\n");
        fprintf(stderr, "  --max-cycles <N>              Stop after N clock cycles (default: unlimited)\n");
        fprintf(stderr, "  --max-cycles=<N>              Same as above (= form)\n");
        fprintf(stderr, "  --timeout=<sec>               Stop after wall-clock timeout in seconds\n");
        fprintf(stderr, "  --kanata=<file>               Enable Kanata pipeline visualization log (default: disabled)\n");
        fprintf(stderr, "\n");
        fprintf(stderr, "Examples:\n");
        fprintf(stderr, "  %s hello.elf\n", argv[0]);
        fprintf(stderr, "  %s hello.elf --rtl-trace trace.log --kanata pipeline.log\n", argv[0]);
        fprintf(stderr, "  %s hello.elf --trace sim.fst --max-cycles=1000000\n", argv[0]);
        return 1;
    }

    // -------------------------------------------------------------------------
    // Verilator setup
    // -------------------------------------------------------------------------
    VerilatedContext* ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    ctx->timeprecision(12); // 1 ps

    Vtb_jv32_soc* dut = new Vtb_jv32_soc(ctx);

#if VM_TRACE_VCD
    VerilatedVcdC* vcdp = nullptr;
#else
    VerilatedFstC* tfp  = nullptr;
#endif
    if (trace_file) {
        Verilated::traceEverOn(true);
#if VM_TRACE_VCD
        vcdp = new VerilatedVcdC;
        dut->trace(vcdp, 99);
        vcdp->open(trace_file);
#else
        tfp = new VerilatedFstC;
        dut->trace(tfp, 99);
        tfp->open(trace_file);
#endif
    }

    // -------------------------------------------------------------------------
    // Reset
    // -------------------------------------------------------------------------
    dut->rst_n             = 0;
    dut->clk               = 0;
    dut->uart_rx_i         = 1; // idle
    dut->trace_en          = 1; // enable trace
    dut->jtag_ntrst_i      = 0;
    dut->jtag_pin0_tck_i   = 0;
    dut->jtag_pin1_tms_i   = 1; // JTAG idle / TAP reset state
    dut->jtag_pin2_tdi_i   = 0;
    dut->eval();

    for (int i = 0; i < 10; i++) tick(dut
#if VM_TRACE_VCD
                                       , vcdp
#else
                                       , tfp
#endif
                                       );

    // -------------------------------------------------------------------------
    // Load ELF
    // -------------------------------------------------------------------------
    load_elf_to_dut(dut, elf_path,
                    0x80000000U, 262144,
                    0x90000000U, 262144);

    // -------------------------------------------------------------------------
    // Release reset
    // -------------------------------------------------------------------------
    dut->jtag_ntrst_i = 1;
    dut->rst_n = 1;
    dut->eval();

    // -------------------------------------------------------------------------
    // Open RTL trace file
    // -------------------------------------------------------------------------
    FILE* rtl_tfp = nullptr;
    if (rtl_trace_file) {
        if (strcmp(rtl_trace_file, "-") == 0) {
            rtl_tfp = stdout;
        } else {
            rtl_tfp = fopen(rtl_trace_file, "w");
            if (!rtl_tfp) {
                fprintf(stderr, "Cannot open rtl-trace file: %s\n", rtl_trace_file);
                return 1;
            }
        }
    }

    // -------------------------------------------------------------------------
    // Open Kanata pipeline log
    // -------------------------------------------------------------------------
    KanataRTL kanata;
    if (kanata_file) {
        kanata.open(kanata_file);
        if (kanata.enabled())
            fprintf(stderr, "[SIM] Kanata pipeline log: %s\n", kanata_file);
    }

    // -------------------------------------------------------------------------
    // Simulation loop
    // -------------------------------------------------------------------------
    uint64_t cycle = 0;
    uint64_t instret = 0;
    bool     timeout_hit = false;
    auto     time_begin  = std::chrono::steady_clock::now();

    // Branch predictor performance counters
    uint64_t bp_branches  = 0;   // conditional branches
    uint64_t bp_taken     = 0;   // branches actually taken
    uint64_t bp_mispred   = 0;   // branch mispredictions
    uint64_t bp_jal       = 0;   // JAL instructions
    uint64_t bp_jal_miss  = 0;   // JALs not pre-decoded (caused EX redirect)
    uint64_t bp_jalr      = 0;   // JALR instructions (always cause EX redirect)

    while (!g_sigint && !g_exit_requested && !ctx->gotFinish() &&
           (max_cycles == 0 || cycle < max_cycles)) {
        if (g_sigint) break;
        if (timeout_seconds > 0) {
            uint64_t elapsed = (uint64_t)std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - time_begin).count();
            if (elapsed >= timeout_seconds) {
                fprintf(stderr, "\n*** TIMEOUT: Simulation exceeded %llu seconds (--timeout) ***\n",
                        (unsigned long long)timeout_seconds);
                timeout_hit = true;
                break;
            }
        }
        tick(dut
#if VM_TRACE_VCD
             , vcdp
#else
             , tfp
#endif
             );
        cycle++;

        // Kanata pipeline snapshot (collected after posedge eval).
        if (kanata.enabled()) {
            PipelineSnapshot snap{};
            svBit if_v=0, ex_v=0, wb_v=0, ret=0;
            svBit if_stl=0, ex_stl=0, if_fl=0, ex_fl=0;
            svBit bp_taken=0, redir=0;
            svBitVecVal pc_if[1]={}, oi_if[1]={};
            svBitVecVal pc_ex[1]={}, oi_ex[1]={};
            svBitVecVal pc_wb[1]={}, oi_wb[1]={};
            dut->get_pipeline_snapshot(
                &if_v,  pc_if, oi_if,
                &ex_v,  pc_ex, oi_ex,
                &wb_v,  &ret,  pc_wb, oi_wb,
                &if_stl, &ex_stl, &if_fl, &ex_fl,
                &bp_taken, &redir);
            snap.if_valid      = if_v;     snap.pc_if        = pc_if[0]; snap.orig_instr_if = oi_if[0];
            snap.ex_valid      = ex_v;     snap.pc_ex        = pc_ex[0]; snap.orig_instr_ex = oi_ex[0];
            snap.wb_valid      = wb_v;     snap.retire       = ret;
            snap.pc_wb         = pc_wb[0]; snap.orig_instr_wb = oi_wb[0];
            snap.if_stall      = if_stl;   snap.ex_stall     = ex_stl;
            snap.if_flush      = if_fl;    snap.ex_flush     = ex_fl;
            snap.bp_taken_ex   = bp_taken; snap.redirect_ex  = redir;
            kanata.step(snap);
        }

        // Count and emit every retired instruction.
        if (dut->trace_valid) {
            instret++;
            if (rtl_tfp) {
                emit_rtl_trace(rtl_tfp, instret, cycle,
                               dut->trace_pc, dut->trace_instr,
                               dut->trace_reg_we ? dut->trace_rd : 0,
                               dut->trace_rd_data,
                               dut->trace_mem_we,
                               dut->trace_mem_re,
                               dut->trace_mem_addr,
                               dut->trace_mem_data);
            }
        }

        // Accumulate branch predictor stats each cycle.
        if (dut->perf_bp_branch)   bp_branches++;
        if (dut->perf_bp_taken)    bp_taken++;
        if (dut->perf_bp_mispred)  bp_mispred++;
        if (dut->perf_bp_jal)      bp_jal++;
        if (dut->perf_bp_jal_miss) bp_jal_miss++;
        if (dut->perf_bp_jalr)     bp_jalr++;
        // Emit IRQ-taken hint line (one cycle after interrupt is accepted).
        // insn=<instret> gives the total retirement count at this cycle so the
        // SW simulator can fire the interrupt at the exact same instruction.
        if (dut->trace_irq_taken && rtl_tfp) {
            // When the interrupted instruction was a STORE whose memory write
            // had already committed in the pipeline (irq fired in 2nd WB
            // cycle), emit a squashed-store hint BEFORE the irq hint so the
            // SW simulator can apply the early write before taking the trap.
            if (dut->trace_irq_store_we) {
                fprintf(rtl_tfp, "! sq_store insn=%" PRIu64 " addr=0x%08x data=0x%08x\n",
                        instret,
                        (uint32_t)dut->trace_irq_store_addr,
                        (uint32_t)dut->trace_irq_store_data);
            }
            fprintf(rtl_tfp, "! irq cause=0x%08x epc=0x%08x insn=%" PRIu64 " cycle=%" PRIu64 "\n",
                    (uint32_t)dut->trace_irq_cause,
                    (uint32_t)dut->trace_irq_epc,
                    instret,
                    cycle);
        }
    }

    // Drain UART TX: keep ticking until the TX line has been idle (HIGH) for
    // at least UART_IDLE_THRESH consecutive cycles.
    //
    // With SIM_CLKS_PER_BIT=8, the worst-case consecutive-HIGH window during
    // active transmission is 8 data bits + 1 stop bit = 9 bit-periods × 8
    // cycles = 72 cycles.  The idle threshold must exceed 72; use 160 (20
    // bit-periods at 8 cycles/bit) so there is ample margin.
    static constexpr uint64_t UART_IDLE_THRESH = 160;
    if (g_exit_requested && !g_sigint) {
        uint64_t idle_count = 0;
        while (idle_count < UART_IDLE_THRESH &&
               (max_cycles == 0 || cycle < max_cycles)) {
            tick(dut
#if VM_TRACE_VCD
                 , vcdp
#else
                 , tfp
#endif
                 );
            cycle++;
            if (dut->uart_tx_o_monitor) idle_count++;
            else idle_count = 0;
        }
    }

    if (g_sigint) {
        fprintf(stderr, "\n*** SIGINT received: dumping registers and exiting ***\n");
        dump_registers(dut);
    }

    auto   time_end = std::chrono::steady_clock::now();
    double elapsed_seconds = std::chrono::duration<double>(time_end - time_begin).count();
    double eff_hz = (elapsed_seconds > 0.0) ? ((double)cycle / elapsed_seconds) : 0.0;
    double eff_mhz = eff_hz / 1.0e6;
    double cpi = (instret > 0) ? ((double)cycle / (double)instret) : 0.0;

    fprintf(stderr, "[RTL-SIM] %llu cycles, %llu instructions retired, CPI=%.3f\n",
            (unsigned long long)cycle, (unsigned long long)instret, cpi);

    if (bp_branches > 0) {
        double taken_pct   = 100.0 * (double)bp_taken    / (double)bp_branches;
        double mispred_pct = 100.0 * (double)bp_mispred  / (double)bp_branches;
        double correct_pct = 100.0 - mispred_pct;
        fprintf(stderr, "[RTL-SIM] Branch predictor statistics (BTFNT+L0):\n");
        fprintf(stderr, "[RTL-SIM]   Conditional branches   : %9llu  taken: %llu (%.1f%%)\n",
                (unsigned long long)bp_branches,
                (unsigned long long)bp_taken, taken_pct);
        fprintf(stderr, "[RTL-SIM]   Mispredictions        : %9llu  rate:  %.1f%%  (accuracy: %.1f%%)\n",
                (unsigned long long)bp_mispred, mispred_pct, correct_pct);
        if (bp_jal > 0)
            fprintf(stderr, "[RTL-SIM]   JAL (pre-decoded/miss): %9llu  miss:  %llu (%.1f%%)\n",
                    (unsigned long long)bp_jal,
                    (unsigned long long)bp_jal_miss,
                    100.0 * (double)bp_jal_miss / (double)bp_jal);
        if (bp_jalr > 0)
            fprintf(stderr, "[RTL-SIM]   JALR (always 1-cycle) : %9llu\n",
                    (unsigned long long)bp_jalr);
    }

    fprintf(stderr, "[RTL-SIM] Run stats: wall=%.6f s, cycles=%llu, eff_freq=%.3f MHz, CPI=%.3f\n",
         elapsed_seconds,
         (unsigned long long)cycle,
         eff_mhz,
         cpi);

    kanata.finish();
    dut->final();

#if VM_COVERAGE
    VerilatedCov::write(ctx->coverageFilename());
#endif

    delete dut;
    delete ctx;

#if VM_TRACE_VCD
    if (vcdp) delete vcdp;
#else
    if (tfp)  delete tfp;
#endif

    if (rtl_tfp && rtl_tfp != stdout) {
        fflush(rtl_tfp);
        fclose(rtl_tfp);
    } else if (rtl_tfp) {
        fflush(rtl_tfp);
    }

    if (g_exit_requested) return g_exit_code;

    if (timeout_hit) {
        fprintf(stderr, "[SIM] Terminated due to --timeout\n");
        return 1;
    }

    fprintf(stderr, "[SIM] max-cycles reached\n");
    return 1;
}

// ============================================================================
// ELF loader: writes bytes to DUT via DPI-C mem_write_byte.
// elfloader.cpp implements load_program() which calls mem_write_byte()
// which is exported from tb_jv32_soc.sv and writes directly to the
// internal SRAM byte-banks (gen_byte_sram[b].u_sram.mem[w]).
// g_mem_base/g_mem_size must span both IRAM and DRAM address ranges.
// ============================================================================
static void load_elf_to_dut(Vtb_jv32_soc* dut, const char* elf_path,
                             uint32_t iram_base, uint32_t /*iram_size*/,
                             uint32_t /*dram_base*/, uint32_t dram_size) {
    // mem_write_byte() in tb_jv32_soc.sv accepts full AXI (physical) addresses
    // and performs its own IRAM/DRAM range check, so pass g_mem_base=0 so the
    // elfloader does not subtract the IRAM base from p_paddr before the call.
    g_mem_base = 0;
    g_mem_size = iram_base + 0x40000000U + dram_size;

    if (!load_program(dut, std::string(elf_path))) {
        fprintf(stderr, "[SIM] ELF load failed: %s\n", elf_path);
        exit(1);
    }

    fprintf(stderr, "[SIM] ELF loaded: %s\n", elf_path);
    if (g_tohost_addr)
        fprintf(stderr, "[SIM]   tohost=0x%08x fromhost=0x%08x\n",
                g_tohost_addr, g_fromhost_addr);
}
