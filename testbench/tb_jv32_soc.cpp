// ============================================================================
// File: tb_jv32_soc.cpp
// Project: JV32 RISC-V Processor
// Description: Verilator C++ Testbench Driver
//
// Usage: ./sim.exe <elf> [--trace <file.fst>] [--max-cycles <N>] [--timeout=<sec>]
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
    std::string base = oss.str();
    std::string disasm = rtl_disasm.disassemble(instr, pc);
    int pad = 72 - (int)base.size();
    if (pad < 2) pad = 2;
    fprintf(fp, "%s%*s; %s\n", base.c_str(), pad, "", disasm.c_str());

    // Emit '! hint' comment for cycle-counter CSR reads so jv32sim can sync.
    // Detect: opcode=0x73 (SYSTEM), funct3 != 0, csr_addr in cycle-CSR set.
    uint32_t opcode = instr & 0x7fu;
    uint32_t funct3 = (instr >> 12) & 0x7u;
    if (rd != 0 && opcode == 0x73u && funct3 != 0) {
        uint32_t csr_addr = instr >> 20;
        const char* csr_name = nullptr;
        switch (csr_addr) {
        case 0xB00: csr_name = "mcycle";    break;
        case 0xB80: csr_name = "mcycleh";   break;
        case 0xB02: csr_name = "minstret";  break;
        case 0xB82: csr_name = "minstreth"; break;
        case 0xC00: csr_name = "cycle";     break;
        case 0xC80: csr_name = "cycleh";    break;
        case 0xC01: csr_name = "time";      break;
        case 0xC81: csr_name = "timeh";     break;
        case 0xC02: csr_name = "instret";   break;
        case 0xC82: csr_name = "instreth";  break;
        default:    break;
        }
        if (csr_name)
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
        } else if (!elf_path) {
            elf_path = argv[i];
        } else {
            fprintf(stderr, "Unknown arg: %s\n", argv[i]);
            return 1;
        }
    }

    if (!elf_path) {
        fprintf(stderr, "Usage: %s <elf> [--trace <file.fst>] [--rtl-trace <file>] [--max-cycles <N>] [--timeout=<sec>]\n", argv[0]);
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
    dut->trace_en          = 1; // enable trace
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
    // Simulation loop
    // -------------------------------------------------------------------------
    uint64_t cycle = 0;
    uint64_t instret = 0;
    bool     timeout_hit = false;
    auto     time_begin  = std::chrono::steady_clock::now();

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
        tick(dut, tfp);
        cycle++;

        // Count all retired instructions; emit trace for register-writing and memory-access ones
        if (dut->trace_valid) {
            instret++;
            if ((dut->trace_reg_we || dut->trace_mem_we || dut->trace_mem_re) && rtl_tfp) {
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
            tick(dut, tfp);
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

    fprintf(stderr, "[RTL-SIM] Run stats: wall=%.6f s, cycles=%llu, eff_freq=%.3f MHz, CPI=%.3f\n",
         elapsed_seconds,
         (unsigned long long)cycle,
         eff_mhz,
         cpi);

    dut->final();

    delete dut;
    delete ctx;

    if (tfp) delete tfp;

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
