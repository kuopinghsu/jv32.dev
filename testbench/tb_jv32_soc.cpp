// ============================================================================
// File: tb_jv32_soc.cpp
// Project: JV32 RISC-V Processor
// Description: Verilator C++ Testbench Driver
//
// Usage: ./sim.exe <elf> [--trace <file.fst>] [--max-cycles <N>]
// ============================================================================

#include <verilated.h>
#include <verilated_fst_c.h>
#include "Vtb_jv32_soc.h"
#include "elfloader.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <iostream>
#include <fstream>
#include <inttypes.h>
#include <csignal>

#define CLK_PERIOD_NS  10ULL
#define CLK_HALF_PS    (CLK_PERIOD_NS * 500ULL)   // half period in ps
#define MAX_CYCLES_DEF 10000000ULL

// Magic exit address
#define MAGIC_EXIT_ADDR  0x40000000U

static volatile bool g_abort = false;
static void sig_handler(int) { g_abort = true; }

// ============================================================================
// SoC memory image (shared with SV via DPI or direct Verilator signal write)
// The jv32_soc instantiates axi_ram_ctrl which wraps sram_1rw.
// We pre-load the SRAMs via Verilator's direct signal access.
// ============================================================================

// Forward: defined below
static void load_elf_to_dut(Vtb_jv32_soc* dut, const char* elf_path,
                             uint32_t iram_base, uint32_t iram_size,
                             uint32_t dram_base, uint32_t dram_size);

// DPI-C: called by axi_magic when EXIT magic address is written
extern "C" void sim_request_exit(int exit_code) {
    std::cout << "[SIM] EXIT requested: code=" << exit_code << std::endl;
    exit(exit_code);
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
    const char* elf_path    = nullptr;
    const char* trace_file  = nullptr;
    uint64_t    max_cycles  = MAX_CYCLES_DEF;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--trace") == 0 && i+1 < argc) {
            trace_file = argv[++i];
        } else if (strcmp(argv[i], "--max-cycles") == 0 && i+1 < argc) {
            max_cycles = (uint64_t)strtoull(argv[++i], nullptr, 10);
        } else if (!elf_path) {
            elf_path = argv[i];
        } else {
            fprintf(stderr, "Unknown arg: %s\n", argv[i]);
            return 1;
        }
    }

    if (!elf_path) {
        fprintf(stderr, "Usage: %s <elf> [--trace <file.fst>] [--max-cycles <N>]\n", argv[0]);
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
    dut->rst_n    = 0;
    dut->clk      = 0;
    dut->uart_rx_i= 1; // idle
    dut->eval();

    for (int i = 0; i < 10; i++) tick(dut, tfp);

    // -------------------------------------------------------------------------
    // Load ELF
    // -------------------------------------------------------------------------
    load_elf_to_dut(dut, elf_path,
                    0x80000000U, 65536,
                    0xC0000000U, 65536);

    // -------------------------------------------------------------------------
    // Release reset
    // -------------------------------------------------------------------------
    dut->rst_n = 1;
    dut->eval();

    // -------------------------------------------------------------------------
    // Simulation loop
    // -------------------------------------------------------------------------
    uint64_t cycle = 0;
    uint64_t instret = 0;

    while (!g_abort && !ctx->gotFinish() && cycle < max_cycles) {
        tick(dut, tfp);
        cycle++;

        // Print trace on retired instruction
        if (dut->trace_valid) {
            instret++;
            uint32_t pc  = dut->trace_pc;
            uint32_t rd  = dut->trace_rd;
            uint32_t rdd = dut->trace_rd_data;
            printf("PC=%08" PRIx32 " rd=x%02" PRIu32 " rd_data=%08" PRIx32 "\n",
                   pc, rd, rdd);
        }
    }

    if (tfp) { tfp->flush(); tfp->close(); }

    printf("[SIM] %llu cycles, %llu instructions retired\n",
           (unsigned long long)cycle, (unsigned long long)instret);
    printf("[SIM] TIMEOUT or max-cycles reached\n");

    dut->final();
    delete dut;
    delete ctx;
    if (tfp) delete tfp;
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
    // Cover: IRAM @ 0x8000_0000 through DRAM end @ 0xC000_0000 + dram_size
    g_mem_base = iram_base;
    g_mem_size = 0x40000000U + dram_size;

    if (!load_program(dut, std::string(elf_path))) {
        fprintf(stderr, "[SIM] ELF load failed: %s\n", elf_path);
        exit(1);
    }

    fprintf(stdout, "[SIM] ELF loaded: %s\n", elf_path);
    if (g_tohost_addr)
        fprintf(stdout, "[SIM]   tohost=0x%08x fromhost=0x%08x\n",
                g_tohost_addr, g_fromhost_addr);
}
