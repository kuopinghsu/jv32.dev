// ============================================================================
// File: tb_jv32_soc.cpp
// Project: JV32 RISC-V Processor
// Description: Verilator C++ Testbench Driver
//
// Usage: ./sim.exe <elf> [--trace <file.fst>] [--rtl-trace <file>] [--mtime-hints <file>] [--max-cycles <N>] [--timeout=<sec>]
// ============================================================================

#include <verilated.h>
#include <verilated_fst_c.h>
#include "Vtb_jv32_soc.h"
#include "elfloader.h"

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

static void emit_rtl_trace(FILE* fp, uint64_t n, uint32_t pc, uint32_t instr,
                           uint32_t rd, uint32_t rddata,
                           bool mem_we, bool mem_re, uint32_t mem_addr, uint32_t mem_data) {
    std::ostringstream oss;
    oss << std::dec << n << " "
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
    std::string base = oss.str();
    std::string disasm = rtl_disasm.disassemble(instr, pc);
    int pad = 72 - (int)base.size();
    if (pad < 2) pad = 2;
    fprintf(fp, "%s%*s; %s\n", base.c_str(), pad, "", disasm.c_str());
}

#define CLK_PERIOD_NS  10ULL
#define CLK_HALF_PS    (CLK_PERIOD_NS * 500ULL)   // half period in ps

// Magic exit address
#define MAGIC_EXIT_ADDR  0x40000000U

static volatile bool g_abort = false;
static void sig_handler(int) { g_abort = true; }

static bool g_exit_requested = false;
static int  g_exit_code      = 0;

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

static void tick(Vtb_jv32_soc* dut, VerilatedFstC* tfp) {
    // Rising edge
    dut->clk = 1;
    dut->eval();
    if (tfp) tfp->dump(sim_time);
    sim_time += CLK_HALF_PS;

    // Falling edge
    dut->clk = 0;
    dut->eval();
    if (tfp) tfp->dump(sim_time);
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
    const char* mtime_hints_file = nullptr;
    uint64_t    max_cycles      = 0;   // 0 = unlimited
    uint64_t    timeout_seconds = 0;   // 0 = no timeout

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--trace") == 0 && i+1 < argc) {
            trace_file = argv[++i];
        } else if (strcmp(argv[i], "--rtl-trace") == 0 && i+1 < argc) {
            rtl_trace_file = argv[++i];
        } else if (strcmp(argv[i], "--mtime-hints") == 0 && i+1 < argc) {
            mtime_hints_file = argv[++i];
        } else if (strcmp(argv[i], "--max-cycles") == 0 && i+1 < argc) {
            max_cycles = (uint64_t)strtoull(argv[++i], nullptr, 10);
        } else if (strncmp(argv[i], "--timeout=", 10) == 0) {
            timeout_seconds = (uint64_t)strtoull(argv[i] + 10, nullptr, 10);
        } else if (!elf_path) {
            elf_path = argv[i];
        } else {
            fprintf(stderr, "Unknown arg: %s\n", argv[i]);
            return 1;
        }
    }

    if (!elf_path) {
        fprintf(stderr, "Usage: %s <elf> [--trace <file.fst>] [--rtl-trace <file>] [--mtime-hints <file>] [--max-cycles <N>] [--timeout=<sec>]\n", argv[0]);
        return 1;
    }

    // -------------------------------------------------------------------------
    // Verilator setup
    // -------------------------------------------------------------------------
    VerilatedContext* ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    ctx->timeprecision(12); // 1 ps

    Vtb_jv32_soc* dut = new Vtb_jv32_soc(ctx);

    VerilatedFstC* tfp = nullptr;
    if (trace_file) {
        Verilated::traceEverOn(true);
        tfp = new VerilatedFstC;
        dut->trace(tfp, 99);
        tfp->open(trace_file);
    }

    // -------------------------------------------------------------------------
    // Reset
    // -------------------------------------------------------------------------
    dut->rst_n             = 0;
    dut->clk               = 0;
    dut->uart_rx_i         = 1; // idle
    dut->jtag_ntrst_i      = 0;
    dut->jtag_pin0_tck_i   = 0;
    dut->jtag_pin1_tms_i   = 1; // JTAG idle / TAP reset state
    dut->jtag_pin2_tdi_i   = 0;
    dut->eval();

    for (int i = 0; i < 10; i++) tick(dut, tfp);

    // -------------------------------------------------------------------------
    // Load ELF
    // -------------------------------------------------------------------------
    load_elf_to_dut(dut, elf_path,
                    0x80000000U, 262144,
                    0xC0000000U, 262144);

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
    bool  rtl_tfp_is_stdout = false;
    if (rtl_trace_file) {
        if (strcmp(rtl_trace_file, "-") == 0) {
            rtl_tfp = stdout;
            rtl_tfp_is_stdout = true;
        } else {
            rtl_tfp = fopen(rtl_trace_file, "w");
            if (!rtl_tfp) {
                fprintf(stderr, "Cannot open rtl-trace file: %s\n", rtl_trace_file);
                return 1;
            }
        }
    }

    // -------------------------------------------------------------------------
    // Open optional mtime-hints file (dedicated helper stream for SW sync)
    // -------------------------------------------------------------------------
    FILE* mtime_hints_tfp = nullptr;
    bool  mtime_hints_is_stdout = false;
    if (mtime_hints_file) {
        if (strcmp(mtime_hints_file, "-") == 0) {
            mtime_hints_tfp = stdout;
            mtime_hints_is_stdout = true;
        } else {
            mtime_hints_tfp = fopen(mtime_hints_file, "w");
            if (!mtime_hints_tfp) {
                fprintf(stderr, "Cannot open mtime-hints file: %s\n", mtime_hints_file);
                return 1;
            }
        }
    }

    // Helper events are written to the dedicated hint file when provided.
    // For backward compatibility, fall back to rtl-trace stream.
    FILE* helper_tfp = mtime_hints_tfp ? mtime_hints_tfp : rtl_tfp;

    // -------------------------------------------------------------------------
    // Simulation loop
    // -------------------------------------------------------------------------
    uint64_t cycle = 0;
    uint64_t instret = 0;
    bool     timeout_hit = false;
    auto     time_begin  = std::chrono::steady_clock::now();

    while (!g_abort && !g_exit_requested && !ctx->gotFinish() &&
           (max_cycles == 0 || cycle < max_cycles)) {
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
        tick(dut, tfp);
        cycle++;

        // Count all retired instructions; emit trace for register-writing and memory-access ones
        if (dut->trace_valid) {
            instret++;
            if ((dut->trace_reg_we || dut->trace_mem_we || dut->trace_mem_re) && rtl_tfp) {
                emit_rtl_trace(rtl_tfp, instret,
                               dut->trace_pc, dut->trace_instr,
                               dut->trace_reg_we ? dut->trace_rd : 0,
                               dut->trace_rd_data,
                               dut->trace_mem_we,
                               dut->trace_mem_re,
                               dut->trace_mem_addr,
                               dut->trace_mem_data);
            }
            if (mtime_hints_tfp) {
                // Per-instruction timer hint for tight SW/RTL timer alignment.
                // Format: ! step mtime=0x<64-bit> instret=<N>
                fprintf(mtime_hints_tfp, "! step mtime=0x%016" PRIx64 " instret=%" PRIu64 "\n",
                        (uint64_t)dut->trace_mtime, instret);
            }
            if (helper_tfp) {
                // mret (0x30200073): sync mtime/mcycle after ISR return so the
                // SW sim knows exactly how many cycles elapsed inside the handler.
                // Format: ! mret mtime=0x<64-bit> instret=<N>
                if (dut->trace_instr == 0x30200073U) {
                    fprintf(helper_tfp, "! mret mtime=0x%016" PRIx64 " instret=%" PRIu64 "\n",
                            (uint64_t)dut->trace_mtime, instret);
                }
                // Periodic sync every 64 retired instructions: keeps the SW sim's
                // mtime/mcycle current between IRQ and mret events.
                // Format: ! sync mtime=0x<64-bit> instret=<N>
                if ((instret & 63ULL) == 0) {
                    fprintf(helper_tfp, "! sync mtime=0x%016" PRIx64 " instret=%" PRIu64 "\n",
                            (uint64_t)dut->trace_mtime, instret);
                }
            }
        }
        // Async interrupt taken: emit a helper comment so the SW simulator can
        // synchronize mtime and mcycle at the exact interrupt point.
        // Format: ! irq cause=0x<32-bit> mtime=0x<64-bit> instret=<N>
        if (dut->trace_irq_taken && helper_tfp) {
            fprintf(helper_tfp, "! irq cause=0x%08" PRIx32 " mtime=0x%016" PRIx64 " instret=%" PRIu64 "\n",
                    (uint32_t)dut->trace_irq_cause,
                    (uint64_t)dut->trace_mtime,
                    instret);
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
    if (g_exit_requested && !g_abort) {
        uint64_t idle_count = 0;
        while (idle_count < UART_IDLE_THRESH &&
               (max_cycles == 0 || cycle < max_cycles)) {
            tick(dut, tfp);
            cycle++;
            if (dut->uart_tx_o_monitor) idle_count++;
            else idle_count = 0;
        }
    }

    if (tfp) { tfp->flush(); tfp->close(); }
    if (rtl_tfp && !rtl_tfp_is_stdout) { fflush(rtl_tfp); fclose(rtl_tfp); }
    else if (rtl_tfp) { fflush(rtl_tfp); }
    if (mtime_hints_tfp && !mtime_hints_is_stdout) { fflush(mtime_hints_tfp); fclose(mtime_hints_tfp); }
    else if (mtime_hints_tfp) { fflush(mtime_hints_tfp); }

    fprintf(stderr, "[SIM] %llu cycles, %llu instructions retired\n",
           (unsigned long long)cycle, (unsigned long long)instret);

    dut->final();
    delete dut;
    delete ctx;
    if (tfp) delete tfp;

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
