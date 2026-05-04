// ============================================================================
// File: tb_jv32_vpi.cpp
// Project: JV32 RISC-V Processor
// Description: Verilator VPI Testbench — JTAG/cJTAG debug interface testing
//
// Implements a JTAG VPI TCP server (default port 3333) that Verilator-simulates
// the JV32 SoC while OpenOCD drives the JTAG (or cJTAG) interface.
//
// Compile once with USE_CJTAG=0 for standard JTAG, once with USE_CJTAG=1 for
// cJTAG mode.  The VPI protocol is the same in both cases — in cJTAG mode
// OpenOCD sends CMD_OSCAN1_RAW to bitbang TCKC/TMSC rather than the standard
// CMD_TMS_SEQ / CMD_SCAN_CHAIN commands.
//
// Supported VPI commands (little-endian uint32 cmd field — same as OpenOCD):
//   CMD_RESET               (0) – assert/deassert nTRST, no response
//   CMD_TMS_SEQ             (1) – TMS bit-bang sequence, no response
//   CMD_SCAN_CHAIN          (2) – TDI scan, returns TDO in buffer_in
//   CMD_SCAN_CHAIN_FLIP_TMS (3) – same with TMS=1 on the last bit
//   CMD_STOP_SIMU           (4) – shut down simulation
//   CMD_OSCAN1_RAW          (5) – cJTAG: drive TCKC/TMSC, return TMSC_out
//
// Timing conventions (hardware-like but simulation-only):
//   TCK_HALF_CLKS system clocks per TCK half-period (default 10).
//   For cJTAG (CMD_OSCAN1_RAW) one TCKC/TMSC sample = TCK_HALF_CLKS clocks.
//   The cJTAG bridge requires f_sys >= 6 × f_tckc (synchronizer + edge detect).
//   With TCK_HALF_CLKS >= 6, this constraint is always met.
//
// Usage:
//   ./jv32vpi_jtag  <elf> [options]   (compiled with USE_CJTAG=0)
//   ./jv32vpi_cjtag <elf> [options]   (compiled with USE_CJTAG=1)
//
// Options:
//   --port N            TCP port for VPI server (default: 3333)
//   --trace <file.fst>  Write FST waveform
//   --max-cycles N      Exit after N simulation cycles (default: 50 000 000)
//   --boot-clocks N     System clocks before accepting connections (default: 2000)
//   --tck-half-clks N   System clocks per TCK/TCKC half-period (default: 10)
//   --idle-clks N       System clocks advanced per idle poll (default: 1000)
// ============================================================================

#include <verilated.h>
#include <verilated_fst_c.h>
#if VM_COVERAGE
#include <verilated_cov.h>
#endif
#include "Vtb_jv32_soc.h"
#include "elfloader.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <cerrno>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <sys/select.h>

// ─── VPI protocol constants ─────────────────────────────────────────────────
// Must match OpenOCD src/jtag/drivers/jtag_vpi.c exactly.
#define CMD_RESET               0u
#define CMD_TMS_SEQ             1u
#define CMD_SCAN_CHAIN          2u
#define CMD_SCAN_CHAIN_FLIP_TMS 3u
#define CMD_STOP_SIMU           4u
#define CMD_OSCAN1_RAW          5u
#define XFERT_MAX_SIZE          512

// Must match OpenOCD's struct vpi_cmd layout (1036 bytes on x86-64).
// Layout: 4 + 512 + 512 + 4 + 4 = 1036.  No padding on x86 / ARM64.
// Integers are transmitted in little-endian byte order; on x86 no swapping
// is needed since both sides are little-endian.
struct vpi_cmd {
    uint32_t cmd;
    uint8_t  buffer_out[XFERT_MAX_SIZE];
    uint8_t  buffer_in[XFERT_MAX_SIZE];
    uint32_t length;
    uint32_t nb_bits;
};
static_assert(sizeof(vpi_cmd) == 1036,
              "vpi_cmd size mismatch — check struct layout against OpenOCD");

// ─── Simulation globals ──────────────────────────────────────────────────────
static Vtb_jv32_soc* g_dut     = nullptr;
static VerilatedFstC* g_tfp    = nullptr;
static uint64_t       g_sim_time = 0;
static uint64_t       g_cycle    = 0;
static volatile bool  g_abort    = false;

// 10 ns clock period → 5 ns half-period → 5000 ps (timescale 1 ps/1 ps)
static const uint64_t CLK_HALF_PS = 5000ULL;

// ─── Run-time parameters (overridable via CLI) ───────────────────────────────
static int      g_vpi_port       = 3333;
static uint64_t g_max_cycles     = 50000000ULL; // 50 M cycles ≈ 500 ms @ 100 MHz
static int      g_tck_half_clks  = 10;          // sys clocks per TCK/TCKC half-period
static int      g_idle_clks      = 1000;        // sys clocks advanced per idle poll
static int      g_boot_clks      = 2000;        // sys clocks before accepting connection

static void sig_handler(int) { g_abort = true; }

// ─── DPI-C: sim_request_exit ─────────────────────────────────────────────────
// In VPI mode the software exit is a no-op — after _exit() the startup code
// spins in `_spin: j _spin`, so OpenOCD can still halt and interact with the
// running hart.
extern "C" void sim_request_exit(int exit_code) {
    fprintf(stderr,
            "[VPI] sim_request_exit(code=%d) — ignored; hart will spin in _spin loop\n",
            exit_code);
}

// ─── Clock helpers ───────────────────────────────────────────────────────────
static inline void tick_half() {
    g_dut->eval();
    if (g_tfp) g_tfp->dump(g_sim_time);
    g_sim_time += CLK_HALF_PS;
}

static inline void tick() {
    g_dut->clk = 1; tick_half();
    g_dut->clk = 0; tick_half();
    ++g_cycle;
}

static void run_clocks(int n) {
    for (int i = 0; i < n; ++i) tick();
}

// ─── JTAG TCK cycle (4-wire JTAG only) ──────────────────────────────────────
// Drive TMS and TDI, toggle TCK with g_tck_half_clks system clocks per half,
// and sample TDO at the END of the TCK-low phase (BEFORE the rising edge).
//
// In JTAG, the shift register (ir_shift / dr_shift) updates on the RISING
// edge of TCK.  TDO is a combinatorial output of the LSB that will be shifted
// out ON this rising edge.  Sampling AFTER the posedge would yield the NEXT
// bit (the post-shift value), producing a one-bit offset error.
// Sampling during the last system clock of the TCK-low half-period gives the
// correct pre-shift value.
static uint8_t jtag_tck(uint8_t tms, uint8_t tdi) {
    // Falling / setup phase: drive TMS and TDI with TCK=0
    g_dut->jtag_pin0_tck_i = 0;
    g_dut->jtag_pin1_tms_i = tms & 1u;
    g_dut->jtag_pin2_tdi_i = tdi & 1u;
    run_clocks(g_tck_half_clks);

    // Sample TDO at end of TCK-low phase — BEFORE posedge shifts the register
    uint8_t tdo = g_dut->jtag_pin3_tdo_o & 1u;

    // Rising edge: clocks in TDI, advances TAP FSM, shifts data registers
    g_dut->jtag_pin0_tck_i = 1;
    run_clocks(g_tck_half_clks);

    // Return TCK to low so the next call starts in a clean low state
    g_dut->jtag_pin0_tck_i = 0;
    return tdo;
}

// ─── TCP helpers ─────────────────────────────────────────────────────────────
static bool recv_exact(int fd, void *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = recv(fd, static_cast<char*>(buf) + got, n - got, 0);
        if (r <= 0) return false;
        got += static_cast<size_t>(r);
    }
    return true;
}

static bool send_exact(int fd, const void *buf, size_t n) {
    size_t sent = 0;
    while (sent < n) {
        ssize_t r = send(fd, static_cast<const char*>(buf) + sent, n - sent, 0);
        if (r <= 0) return false;
        sent += static_cast<size_t>(r);
    }
    return true;
}

// ─── VPI command processor ───────────────────────────────────────────────────
// Returns true to keep running, false to stop the simulation.
static bool process_vpi_cmd(int fd, struct vpi_cmd *c) {
    const uint32_t cmd     = c->cmd;
    const uint32_t nb_bits = c->nb_bits;

    switch (cmd) {

    // ── CMD_RESET: reset the TAP controller via nTRST ───────────────────────
    // No response expected (OpenOCD does not call jtag_vpi_receive_cmd here).
    // buffer_out[0] bit0 = trst (1=active/assert), bit1 = srst
    case CMD_RESET: {
        uint8_t trst = c->buffer_out[0] & 0x01u;
        g_dut->jtag_ntrst_i = trst ? 0 : 1; // active-low nTRST
        run_clocks(g_tck_half_clks * 4);
        return true;
    }

    // ── CMD_TMS_SEQ: bit-bang TMS sequence, TDI=1 (don't care) ─────────────
    // No response expected.
    case CMD_TMS_SEQ:
        for (uint32_t i = 0; i < nb_bits; ++i) {
            uint8_t tms = (c->buffer_out[i / 8] >> (i % 8)) & 1u;
            jtag_tck(tms, 1u);
        }
        return true;

    // ── CMD_SCAN_CHAIN / CMD_SCAN_CHAIN_FLIP_TMS: TDI scan, return TDO ──────
    // Response (buffer_in filled with TDO bits) is sent back to OpenOCD.
    case CMD_SCAN_CHAIN:
    case CMD_SCAN_CHAIN_FLIP_TMS: {
        uint32_t nbytes = (nb_bits + 7u) / 8u;
        memset(c->buffer_in, 0, nbytes);
        for (uint32_t i = 0; i < nb_bits; ++i) {
            uint8_t tdi = (c->buffer_out[i / 8] >> (i % 8)) & 1u;
            // TMS=1 only on the very last bit when entering Exit1-DR/IR
            uint8_t tms = (cmd == CMD_SCAN_CHAIN_FLIP_TMS && i == nb_bits - 1u) ? 1u : 0u;
            uint8_t tdo = jtag_tck(tms, tdi);
            if (tdo) c->buffer_in[i / 8] |= static_cast<uint8_t>(1u << (i % 8));
        }
        return send_exact(fd, c, sizeof(*c));
    }

    // ── CMD_OSCAN1_RAW: cJTAG — drive TCKC/TMSC, return TMSC output ─────────
    // OpenOCD encodes each OScan1 bit as a separate CMD_OSCAN1_RAW packet.
    // buffer_out[0] bit0 = TCKC, bit1 = TMSC_in.
    // buffer_in[0]  bit0 = TMSC_out (from cJTAG bridge when it drives the line).
    //
    // pin1_tms_oe semantics (active-low output-enable from jtag_top.sv):
    //   0 = DUT drives TMSC (bridge is outputting TDO)
    //   1 = DUT tristates TMSC (host is driving)
    case CMD_OSCAN1_RAW: {
        uint8_t tckc = c->buffer_out[0] & 0x01u;
        uint8_t tmsc = (c->buffer_out[0] >> 1) & 0x01u;
        g_dut->jtag_pin0_tck_i = tckc;
        g_dut->jtag_pin1_tms_i = tmsc;
        run_clocks(g_tck_half_clks);

        // Read TMSC_out when the bridge is driving (oe active-low = 0)
        uint8_t oe  = g_dut->jtag_pin1_tms_oe & 1u;
        uint8_t out = g_dut->jtag_pin1_tms_o  & 1u;
        uint8_t tmsc_out = (oe == 0u) ? out : 0u;
#ifdef DEBUG
        fprintf(stderr, "[VPI] OSCAN1_RAW tckc=%u tmsc_in=%u oe=%u out=%u → tmsc_out=%u\n",
                tckc, tmsc, oe, out, tmsc_out);
#endif
        memset(c->buffer_in, 0, sizeof(c->buffer_in));
        c->buffer_in[0] = tmsc_out;
        return send_exact(fd, c, sizeof(*c));
    }

    // ── CMD_STOP_SIMU: clean shutdown ────────────────────────────────────────
    case CMD_STOP_SIMU:
        fprintf(stderr, "[VPI] CMD_STOP_SIMU received — shutting down\n");
        return false;

    default:
        fprintf(stderr, "[VPI] Unknown VPI command 0x%08x — skipping\n", cmd);
        return true;
    }
}

// ─── ELF loader ──────────────────────────────────────────────────────────────
static void load_elf_to_dut(Vtb_jv32_soc *dut, const char *elf_path) {
    // mem_write_byte() exported from tb_jv32_soc.sv accepts full AXI physical
    // addresses and performs its own IRAM/DRAM range check internally.
    // Pass g_mem_base=0 so the elfloader does not subtract any base before
    // forwarding the address to mem_write_byte.
    g_mem_base = 0;
    g_mem_size = 0xA0040000U; // covers IRAM (0x8000_0000), DRAM (0x9000_0000), and EXTRAM (0xA000_0000 + 256 KB)

    if (!load_program(dut, std::string(elf_path))) {
        fprintf(stderr, "[VPI] ELF load failed: %s\n", elf_path);
        exit(1);
    }
    fprintf(stderr, "[VPI] ELF loaded: %s\n", elf_path);
}

// ─── Main ────────────────────────────────────────────────────────────────────
int main(int argc, char **argv) {
    signal(SIGINT, sig_handler);

    // ── Argument parsing ─────────────────────────────────────────────────────
    const char *elf_path   = nullptr;
    const char *trace_file = nullptr;

    for (int i = 1; i < argc; ++i) {
        if      (!strcmp(argv[i], "--port")          && i+1 < argc)
            g_vpi_port      = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--trace")         && i+1 < argc)
            trace_file      = argv[++i];
        else if (!strcmp(argv[i], "--max-cycles")    && i+1 < argc)
            g_max_cycles    = static_cast<uint64_t>(strtoull(argv[++i], nullptr, 10));
        else if (!strcmp(argv[i], "--boot-clocks")   && i+1 < argc)
            g_boot_clks     = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--tck-half-clks") && i+1 < argc)
            g_tck_half_clks = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--idle-clks")     && i+1 < argc)
            g_idle_clks     = atoi(argv[++i]);
        else if (argv[i][0] == '+')
            ; // +verilator+... runtime args handled by ctx->commandArgs() below
        else if (!elf_path)
            elf_path = argv[i];
        else {
            fprintf(stderr, "[VPI] Unknown argument: %s\n", argv[i]);
            return 1;
        }
    }

    if (!elf_path) {
        fprintf(stderr,
            "Usage: %s <elf> [--port N] [--trace <f.fst>] [--max-cycles N]\n"
            "              [--boot-clocks N] [--tck-half-clks N] [--idle-clks N]\n",
            argv[0]);
        return 1;
    }

    // ── TCP server setup (done FIRST so port is open before Verilator init) ──
    // Binding the socket before boot clocks ensures OpenOCD can connect
    // immediately after startting the process; it waits in accept() until
    // boot clocks have finished.
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("[VPI] socket"); return 1; }

    int one = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in sa = {};
    sa.sin_family      = AF_INET;
    sa.sin_addr.s_addr = INADDR_ANY;
    sa.sin_port        = htons(static_cast<uint16_t>(g_vpi_port));

    if (bind(server_fd, reinterpret_cast<struct sockaddr*>(&sa), sizeof(sa)) < 0) {
        perror("[VPI] bind"); close(server_fd); return 1;
    }
    if (listen(server_fd, 1) < 0) {
        perror("[VPI] listen"); close(server_fd); return 1;
    }
    fprintf(stderr, "[VPI] Listening on port %d\n", g_vpi_port);

    // ── Verilator context + DUT ──────────────────────────────────────────────
    VerilatedContext *ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    ctx->timeprecision(12); // 1 ps resolution

    g_dut = new Vtb_jv32_soc(ctx);

    if (trace_file) {
        Verilated::traceEverOn(true);
        g_tfp = new VerilatedFstC;
        g_dut->trace(g_tfp, 99);
        g_tfp->open(trace_file);
    }

    // ── Reset sequence ───────────────────────────────────────────────────────
    g_dut->rst_n           = 0;
    g_dut->clk             = 0;
    g_dut->uart_rx_i       = 1;  // UART idle high
    g_dut->trace_en        = 1;  // enable trace / single-step retire detection
    g_dut->jtag_ntrst_i    = 0;  // hold TAP in reset
    g_dut->jtag_pin0_tck_i = 0;
    g_dut->jtag_pin1_tms_i = 1;  // TMS=1 forces TAP reset state
    g_dut->jtag_pin2_tdi_i = 0;
    g_dut->eval();
    for (int i = 0; i < 10; ++i) tick();

    // ── Load ELF into IRAM/DRAM via DPI ─────────────────────────────────────
    load_elf_to_dut(g_dut, elf_path);

    // ── Release reset ────────────────────────────────────────────────────────
    g_dut->jtag_ntrst_i = 1;
    g_dut->rst_n        = 1;
    g_dut->eval();

    // ── Boot clocks: let DUT initialise (BSS zero, startup code run) ─────────
    fprintf(stderr, "[VPI] Running %d boot clocks...\n", g_boot_clks);
    run_clocks(g_boot_clks);

    // ── Accept connection (poll with idle clocks while waiting) ──────────────
    fprintf(stderr, "[VPI] Waiting for OpenOCD on port %d...\n", g_vpi_port);
    int client_fd = -1;
    while (!g_abort && client_fd < 0 &&
           (g_max_cycles == 0 || g_cycle < g_max_cycles)) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(server_fd, &rfds);
        struct timeval tv = { 0, 1000 }; // 1 ms timeout
        if (select(server_fd + 1, &rfds, nullptr, nullptr, &tv) > 0) {
            client_fd = accept(server_fd, nullptr, nullptr);
            if (client_fd > 0) {
                setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
                fprintf(stderr, "[VPI] OpenOCD connected\n");
            }
        } else {
            run_clocks(g_idle_clks);
        }
    }

    if (g_abort || client_fd < 0) {
        close(server_fd);
        fprintf(stderr, "[VPI] Aborted before OpenOCD connected\n");
        return 1;
    }

    // ── Main VPI command loop ─────────────────────────────────────────────────
    // Use select(1ms) to poll the socket; advance idle clocks between commands
    // so the hart continues to execute software during OpenOCD "think time"
    // (e.g. sleep 50 in test_halt_resume.tcl).
    uint64_t cmd_count = 0;
    bool     running   = true;

    while (running && !g_abort &&
           (g_max_cycles == 0 || g_cycle < g_max_cycles)) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(client_fd, &rfds);
        struct timeval tv = { 0, 1000 }; // 1 ms

        int ready = select(client_fd + 1, &rfds, nullptr, nullptr, &tv);
        if (ready > 0) {
            struct vpi_cmd cmd;
            if (!recv_exact(client_fd, &cmd, sizeof(cmd))) {
                fprintf(stderr, "[VPI] Connection closed by OpenOCD\n");
                break;
            }
            running = process_vpi_cmd(client_fd, &cmd);
            ++cmd_count;
        } else if (ready == 0) {
            // Poll timeout: advance idle clocks so the hart keeps running
            run_clocks(g_idle_clks);
        }
        // ready < 0 (EINTR or transient error): just loop again
    }

    fprintf(stderr, "[VPI] Done: %llu commands, %llu cycles\n",
            static_cast<unsigned long long>(cmd_count),
            static_cast<unsigned long long>(g_cycle));

    // ── Cleanup ───────────────────────────────────────────────────────────────
    close(client_fd);
    close(server_fd);
    if (g_tfp) { g_tfp->flush(); g_tfp->close(); }
#if VM_COVERAGE
    VerilatedCov::write(ctx->coverageFilename());
#endif
    g_dut->final();
    delete g_dut;
    delete ctx;
    if (g_tfp) delete g_tfp;

    return 0;
}
