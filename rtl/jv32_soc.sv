// ============================================================================
// File        : jv32_soc.sv
// Project     : JV32 RISC-V Processor
// Description : JV32 System-on-Chip Top Level
//
// Instantiates:
//   - jv32_top (core + TCM IRAM/DRAM + merged AXI master + AXI slave)
//   - axi_xbar (3 peripheral slaves)
//   - axi_uart  (UART    @ 0x2001_0000)
//   - axi_clic  (CLIC    @ 0x0200_0000)
//   - axi_magic (Magic   @ 0x4000_0000)
//
// Memory map
// ----------
//  0x8000_0000  IRAM (TCM, inside jv32_top, 128 KB)  - I-fetch + data read
//  0x9000_0000  DRAM (TCM, inside jv32_top, 128 KB)  - data read/write
//  0x2001_0000  UART
//  0x0200_0000  CLIC / CLINT
//  0x4000_0000  Magic exit + MMIO
//
// TCM slave ports (s_iram_tcm_* and s_dram_tcm_*)
// -----------------------------
//  The jv32_top AXI slave is exposed as SoC-level ports so an external
//  debug master or the testbench can write to TCM at run-time.
//  For pre-simulation ELF loading, use the DPI mem_write_byte interface
//  (tb_jv32_soc.sv) which directly writes the SRAM arrays.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Kuoping Hsu
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
// ============================================================================

module jv32_soc #(
    parameter int unsigned        CLK_FREQ        = 100_000_000,
    parameter int unsigned        BAUD_RATE       = 115_200,
    parameter int unsigned        UART_FIFO_DEPTH = 16,          // TX/RX FIFO depth (power of 2)
    parameter bit                 RV32E_EN        = 1'b0,        // 1=RV32E (16 GPRs); 0=RV32I (32 GPRs)
    parameter bit                 RV32M_EN        = 1'b1,        // 1=M-extension; 0=MUL/DIV illegal
    parameter bit                 JTAG_EN         = 1'b1,        // 1=JTAG debug port; 0=no JTAG
    parameter bit                 USE_CJTAG       = 1'b0,        // 0=4-wire JTAG, 1=2-wire cJTAG
    parameter bit          [31:0] JTAG_IDCODE     = 32'h1DEAD3FF,
    parameter int                 N_TRIGGERS      = 2,           // hardware breakpoints (0..4)
    parameter bit                 AMO_EN          = 1'b1,        // 1=full A-extension; 0=LR/SC only
    parameter int unsigned        IRAM_SIZE       = 128 * 1024,  // bytes (128 KB)
    parameter int unsigned        DRAM_SIZE       = 128 * 1024,  // bytes (128 KB)
    parameter bit                 FAST_MUL        = 1'b1,
    parameter bit                 MUL_MC          = 1'b1,
    parameter bit                 FAST_DIV        = 1'b0,
    parameter bit                 FAST_SHIFT      = 1'b1,
    parameter bit                 BP_EN           = 1'b1,
    parameter bit                 RAS_EN          = 1'b1,        // 1=RAS enabled; 0=JALR always 1-cycle
    parameter bit                 IBUF_EN         = 1'b1,        // 1=2-entry instruction prefetch buffer; 0=disabled
    parameter bit                 RV32B_EN        = 1'b1,        // 1=Zba/Zbb/Zbs; 0=illegal (synthesized away)
    parameter bit          [31:0] BOOT_ADDR       = 32'h8000_0000,
    parameter bit          [31:0] IRAM_BASE       = 32'h8000_0000,
    parameter bit          [31:0] DRAM_BASE       = 32'h9000_0000
) (
    input logic clk,
    input logic rst_n,

    // UART
    input  logic uart_rx_i,
    output logic uart_tx_o,

    // JTAG / cJTAG debug pins
    input  logic jtag_ntrst_i,
    input  logic jtag_pin0_tck_i,
    input  logic jtag_pin1_tms_i,
    output logic jtag_pin1_tms_o,
    output logic jtag_pin1_tms_oe,
    input  logic jtag_pin2_tdi_i,
    output logic jtag_pin3_tdo_o,
    output logic jtag_pin3_tdo_oe,

    // External IRQ
    input logic [15:0] ext_irq_i,

    // AXI4-Lite Slave: external access to IRAM TCM
    // Tie arvalid/awvalid/wvalid = 0 if no external master is used.
    input  logic [31:0] s_iram_tcm_araddr,
    input  logic        s_iram_tcm_arvalid,
    output logic        s_iram_tcm_arready,
    output logic [31:0] s_iram_tcm_rdata,
    output logic [ 1:0] s_iram_tcm_rresp,
    output logic        s_iram_tcm_rvalid,
    input  logic        s_iram_tcm_rready,
    input  logic [31:0] s_iram_tcm_awaddr,
    input  logic        s_iram_tcm_awvalid,
    output logic        s_iram_tcm_awready,
    input  logic [31:0] s_iram_tcm_wdata,
    input  logic [ 3:0] s_iram_tcm_wstrb,
    input  logic        s_iram_tcm_wvalid,
    output logic        s_iram_tcm_wready,
    output logic [ 1:0] s_iram_tcm_bresp,
    output logic        s_iram_tcm_bvalid,
    input  logic        s_iram_tcm_bready,

    // AXI4-Lite Slave: external access to DRAM TCM
    input  logic [31:0] s_dram_tcm_araddr,
    input  logic        s_dram_tcm_arvalid,
    output logic        s_dram_tcm_arready,
    output logic [31:0] s_dram_tcm_rdata,
    output logic [ 1:0] s_dram_tcm_rresp,
    output logic        s_dram_tcm_rvalid,
    input  logic        s_dram_tcm_rready,
    input  logic [31:0] s_dram_tcm_awaddr,
    input  logic        s_dram_tcm_awvalid,
    output logic        s_dram_tcm_awready,
    input  logic [31:0] s_dram_tcm_wdata,
    input  logic [ 3:0] s_dram_tcm_wstrb,
    input  logic        s_dram_tcm_wvalid,
    output logic        s_dram_tcm_wready,
    output logic [ 1:0] s_dram_tcm_bresp,
    output logic        s_dram_tcm_bvalid,
    input  logic        s_dram_tcm_bready,

    // External AXI interface (SoC path to access external memory/MMIO)
    output logic [31:0] ext_axi_araddr,
    output logic        ext_axi_arvalid,
    output logic        ext_axi_rready,
    output logic [31:0] ext_axi_awaddr,
    output logic        ext_axi_awvalid,
    output logic [31:0] ext_axi_wdata,
    output logic [ 3:0] ext_axi_wstrb,
    output logic        ext_axi_wvalid,
    output logic        ext_axi_bready,
    input  logic        ext_axi_arready,
    input  logic [31:0] ext_axi_rdata,
    input  logic [ 1:0] ext_axi_rresp,
    input  logic        ext_axi_rvalid,
    input  logic        ext_axi_awready,
    input  logic        ext_axi_wready,
    input  logic [ 1:0] ext_axi_bresp,
    input  logic        ext_axi_bvalid,

    // Trace (simulation only -- excluded from synthesis)
`ifndef SYNTHESIS
    input  logic        trace_en,
    output logic        trace_valid,
    output logic        trace_reg_we,
    output logic [31:0] trace_pc,
    output logic [ 4:0] trace_rd,
    output logic [31:0] trace_rd_data,
    output logic [31:0] trace_instr,
    output logic        trace_mem_we,
    output logic        trace_mem_re,
    output logic [31:0] trace_mem_addr,
    output logic [31:0] trace_mem_data,
    output logic        trace_irq_taken,
    output logic [31:0] trace_irq_cause,
    output logic [31:0] trace_irq_epc,
    output logic        trace_irq_store_we,
    output logic [31:0] trace_irq_store_addr,
    output logic [31:0] trace_irq_store_data,

    // Branch predictor performance counters
    output logic perf_bp_branch,
    output logic perf_bp_taken,
    output logic perf_bp_mispred,
    output logic perf_bp_jal,
    output logic perf_bp_jal_miss,
    output logic perf_bp_jalr,
`endif

    // Heartbeat: toggles every 2^24 retired instructions (= minstret[24]).
    // One full toggle period = 2 * 2^24 * CPI clock cycles.
    output logic heartbeat_o
);
    import jv32_pkg::*;

    // =====================================================================
    // AXI bus between jv32_top master and xbar
    // =====================================================================
    logic [          31:0]       core_mbus_araddr;
    logic                        core_mbus_arvalid;
    logic                        core_mbus_arready;
    logic [          31:0]       core_mbus_rdata;
    logic [           1:0]       core_mbus_rresp;
    logic                        core_mbus_rvalid;
    logic                        core_mbus_rready;
    logic [          31:0]       core_mbus_awaddr;
    logic                        core_mbus_awvalid;
    logic                        core_mbus_awready;
    logic [          31:0]       core_mbus_wdata;
    logic [           3:0]       core_mbus_wstrb;
    logic                        core_mbus_wvalid;
    logic                        core_mbus_wready;
    logic [           1:0]       core_mbus_bresp;
    logic                        core_mbus_bvalid;
    logic                        core_mbus_bready;

    logic [          31:0]       mbus_araddr;
    logic                        mbus_arvalid;
    logic                        mbus_arready;
    logic [          31:0]       mbus_rdata;
    logic [           1:0]       mbus_rresp;
    logic                        mbus_rvalid;
    logic                        mbus_rready;
    logic [          31:0]       mbus_awaddr;
    logic                        mbus_awvalid;
    logic                        mbus_awready;
    logic [          31:0]       mbus_wdata;
    logic [           3:0]       mbus_wstrb;
    logic                        mbus_wvalid;
    logic                        mbus_wready;
    logic [           1:0]       mbus_bresp;
    logic                        mbus_bvalid;
    logic                        mbus_bready;

    // IRQ interconnect
    logic                        timer_irq;
    logic                        software_irq;
    logic                        external_irq;
    logic                        clic_irq;
    logic                        uart_irq;
    logic [           7:0]       clic_level;
    logic [           7:0]       clic_prio;
    logic [           4:0]       clic_id;
    logic                        clic_ack;
    logic [          63:0]       clic_mtime;  // mtime from CLIC, wired to core time/timeh CSR

    // =====================================================================
    // Debug / JTAG interconnect
    // =====================================================================
    logic                        dbg_halt_req;
    logic                        dbg_halted;
    logic                        dbg_resume_req;
    logic                        dbg_resumeack;
    logic [           4:0]       dbg_reg_addr;
    logic [          31:0]       dbg_reg_wdata;
    logic [          31:0]       dbg_reg_rdata;
    logic                        dbg_reg_we;
    logic [          31:0]       dbg_pc_wdata;
    logic [          31:0]       dbg_pc;
    logic                        dbg_pc_we;
    logic                        dbg_mem_req;
    logic                        dbg_mem_ready;
    logic                        dbg_mem_error;
    logic [          31:0]       dbg_mem_addr;
    logic [          31:0]       dbg_mem_wdata;
    logic [          31:0]       dbg_mem_rdata;
    logic [           3:0]       dbg_mem_we;
    logic                        dbg_ndmreset;
    logic                        dbg_hartreset;
    logic                        dbg_singlestep;
    logic                        dbg_ebreakm;
    logic [          31:0]       progbuf0;
    logic [          31:0]       progbuf1;
    logic                        soc_rst_n;
    logic                        rst_n_pre;
    logic                        rst_sync_ff1;
    logic                        rst_sync_ff2;

    // Trigger interface wires (DTM <-> core)
    logic                        dbg_trigger_halt;
    logic [N_TRIGGERS-1:0]       dbg_trigger_hit;  // per-trigger hit bits
    logic [N_TRIGGERS-1:0][31:0] dbg_tdata1;
    logic [N_TRIGGERS-1:0][31:0] dbg_tdata2;

    // Internal AXI wires into the `jv32_top` IRAM/DRAM TCM slaves.
    logic [          31:0]       iram_tcm_araddr_mux;
    logic                        iram_tcm_arvalid_mux;
    logic                        iram_tcm_arready_int;
    logic [          31:0]       iram_tcm_rdata_int;
    logic [           1:0]       iram_tcm_rresp_int;
    logic                        iram_tcm_rvalid_int;
    logic                        iram_tcm_rready_mux;
    logic [          31:0]       iram_tcm_awaddr_mux;
    logic                        iram_tcm_awvalid_mux;
    logic                        iram_tcm_awready_int;
    logic [          31:0]       iram_tcm_wdata_mux;
    logic [           3:0]       iram_tcm_wstrb_mux;
    logic                        iram_tcm_wvalid_mux;
    logic                        iram_tcm_wready_int;
    logic [           1:0]       iram_tcm_bresp_int;
    logic                        iram_tcm_bvalid_int;
    logic                        iram_tcm_bready_mux;

    logic [          31:0]       dram_tcm_araddr_mux;
    logic                        dram_tcm_arvalid_mux;
    logic                        dram_tcm_arready_int;
    logic [          31:0]       dram_tcm_rdata_int;
    logic [           1:0]       dram_tcm_rresp_int;
    logic                        dram_tcm_rvalid_int;
    logic                        dram_tcm_rready_mux;
    logic [          31:0]       dram_tcm_awaddr_mux;
    logic                        dram_tcm_awvalid_mux;
    logic                        dram_tcm_awready_int;
    logic [          31:0]       dram_tcm_wdata_mux;
    logic [           3:0]       dram_tcm_wstrb_mux;
    logic                        dram_tcm_wvalid_mux;
    logic                        dram_tcm_wready_int;
    logic [           1:0]       dram_tcm_bresp_int;
    logic                        dram_tcm_bvalid_int;
    logic                        dram_tcm_bready_mux;

    typedef enum logic [3:0] {
        DBG_TCM_IDLE,
        DBG_TCM_RD_ADDR,
        DBG_TCM_RD_RESP,
        DBG_TCM_WR_REQ,
        DBG_TCM_WR_RESP,
        DBG_EXT_RD_ADDR,
        DBG_EXT_RD_RESP,
        DBG_EXT_WR_REQ,
        DBG_EXT_WR_RESP
    } dbg_tcm_state_e;

    dbg_tcm_state_e        dbg_tcm_state;
    logic                  dbg_tcm_select;
    logic                  dbg_ext_select;
    logic                  dbg_mem_req_d;
    logic                  dbg_tcm_is_iram;
    logic                  dbg_mem_error_r;
    logic                  dbg_aw_done;
    logic                  dbg_w_done;
    logic           [31:0] dbg_addr_r;
    logic           [31:0] dbg_wdata_r;
    logic           [ 3:0] dbg_wstrb_r;

    function automatic logic in_iram(input logic [31:0] addr);
        // Canonical TCM address: 0x8000_0000 - 0x8000_0000 + IRAM_SIZE
        // Out-of-TCM alias:      0x6000_0000 - 0x6000_0000 + IRAM_SIZE
        logic in_canonical = (addr >= IRAM_BASE) && (addr < IRAM_BASE + 32'(IRAM_SIZE));
        logic in_alias = (addr >= 32'h6000_0000) && (addr < 32'h6000_0000 + 32'(IRAM_SIZE));
        return in_canonical || in_alias;
    endfunction

    function automatic logic in_dram(input logic [31:0] addr);
        // Canonical TCM address: 0x9000_0000 - 0x9000_0000 + DRAM_SIZE
        // Out-of-TCM alias:      0x7000_0000 - 0x7000_0000 + DRAM_SIZE
        logic in_canonical = (addr >= DRAM_BASE) && (addr < DRAM_BASE + 32'(DRAM_SIZE));
        logic in_alias = (addr >= 32'h7000_0000) && (addr < 32'h7000_0000 + 32'(DRAM_SIZE));
        return in_canonical || in_alias;
    endfunction

    function automatic logic [31:0] map_to_canonical(input logic [31:0] addr);
        // Map alias addresses to canonical TCM addresses
        // IRAM: 0x6xxxxxxx -> 0x8xxxxxxx
        // DRAM: 0x7xxxxxxx -> 0x9xxxxxxx
        if ((addr >= 32'h6000_0000) && (addr < 32'h6000_0000 + 32'(IRAM_SIZE)))
            return {4'h8, addr[27:0]};  // 0x6 -> 0x8
        else if ((addr >= 32'h7000_0000) && (addr < 32'h7000_0000 + 32'(DRAM_SIZE)))
            return {4'h9, addr[27:0]};  // 0x7 -> 0x9
        else return addr;  // Already canonical or external address
    endfunction

    function automatic logic in_tcm(input logic [31:0] addr);
        return in_iram(addr) || in_dram(addr);
    endfunction

    // Map core's AXI master addresses: alias -> canonical for TCM routing (declarations early for debug traces)
    logic [31:0] core_mbus_araddr_mapped;
    logic [31:0] core_mbus_awaddr_mapped;
    logic        core_araddr_is_tcm_alias;  // Read address is alias and maps to TCM
    logic        core_awaddr_is_tcm_alias;  // Write address is alias and maps to TCM
    logic core_alias_rd_is_iram, core_alias_wr_is_iram;
    logic core_alias_rd_active, core_alias_wr_active;
    logic core_alias_rd_addr_done;          // AR handshake complete (prevent infinite arvalid to TCM)
    logic core_alias_wr_aw_done;            // AW handshake complete (prevent infinite awvalid to TCM)
    logic core_alias_wr_w_done;             // W  handshake complete (prevent infinite wvalid  to TCM)
    logic core_alias_wr_is_iram_r;          // Latched at AW handshake: IRAM vs DRAM for W channel routing

    // Response-pending: keep forwarding core rready/bready to TCM until response consumed
    logic core_alias_iram_rd_pend;  // IRAM read accepted by TCM, R response not yet consumed
    logic core_alias_dram_rd_pend;  // DRAM read accepted by TCM, R response not yet consumed
    logic core_alias_iram_wr_pend;  // IRAM write data accepted, B response not yet consumed
    logic core_alias_dram_wr_pend;  // DRAM write data accepted, B response not yet consumed

    assign core_mbus_araddr_mapped  = map_to_canonical(core_mbus_araddr);
    assign core_mbus_awaddr_mapped  = map_to_canonical(core_mbus_awaddr);
    assign core_araddr_is_tcm_alias = (core_mbus_araddr != core_mbus_araddr_mapped) && in_tcm(core_mbus_araddr);
    assign core_awaddr_is_tcm_alias = (core_mbus_awaddr != core_mbus_awaddr_mapped) && in_tcm(core_mbus_awaddr);
    assign core_alias_rd_is_iram    = in_iram(core_mbus_araddr);
    assign core_alias_wr_is_iram    = core_alias_wr_aw_done ? core_alias_wr_is_iram_r : in_iram(core_mbus_awaddr);

    // AW active: send awaddr to TCM once (until AW handshake fires)
    // W  active: send wdata  to TCM once (until W  handshake fires, independent of AW phase)
    logic core_alias_aw_active, core_alias_w_active;
    assign core_alias_aw_active = core_awaddr_is_tcm_alias && core_mbus_awvalid && !core_alias_wr_aw_done;
    assign core_alias_w_active  = (core_awaddr_is_tcm_alias || core_alias_wr_aw_done) &&
                                   core_mbus_wvalid && !core_alias_wr_w_done;
    assign core_alias_rd_active = core_araddr_is_tcm_alias && core_mbus_arvalid && !core_alias_rd_addr_done;
    assign core_alias_wr_active = core_alias_aw_active || core_alias_w_active;

    // Reset synchronizer: async assert, synchronous de-assert.
    // Both the external rst_n and the debug ndmreset can assert the reset
    // immediately, but de-assertion is delayed two clk cycles to avoid
    // metastability on downstream flops.
    assign rst_n_pre = rst_n & ~dbg_ndmreset;

    always_ff @(posedge clk or negedge rst_n_pre) begin
        if (!rst_n_pre) begin
            rst_sync_ff1 <= 1'b0;
            rst_sync_ff2 <= 1'b0;
        end
        else begin
            rst_sync_ff1 <= 1'b1;
            rst_sync_ff2 <= rst_sync_ff1;
        end
    end

    assign soc_rst_n = rst_sync_ff2;
    assign dbg_tcm_select = (dbg_tcm_state == DBG_TCM_RD_ADDR)
                            || (dbg_tcm_state == DBG_TCM_RD_RESP)
                            || (dbg_tcm_state == DBG_TCM_WR_REQ)
                            || (dbg_tcm_state == DBG_TCM_WR_RESP);
    assign dbg_ext_select = (dbg_tcm_state == DBG_EXT_RD_ADDR)
                            || (dbg_tcm_state == DBG_EXT_RD_RESP)
                            || (dbg_tcm_state == DBG_EXT_WR_REQ)
                            || (dbg_tcm_state == DBG_EXT_WR_RESP);
    assign dbg_mem_error = dbg_mem_error_r;

    // JTAG top-level interface + RISC-V debug transport module
    generate
        if (JTAG_EN) begin : gen_jtag
            jtag_top #(
                .USE_CJTAG (USE_CJTAG),
                .IDCODE    (JTAG_IDCODE),
                .N_TRIGGERS(N_TRIGGERS)
            ) u_jtag (
                .clk_i           (clk),
                .rst_n_i         (rst_n),
                .ntrst_i         (jtag_ntrst_i),
                .pin0_tck_i      (jtag_pin0_tck_i),
                .pin1_tms_i      (jtag_pin1_tms_i),
                .pin1_tms_o      (jtag_pin1_tms_o),
                .pin1_tms_oe     (jtag_pin1_tms_oe),
                .pin2_tdi_i      (jtag_pin2_tdi_i),
                .pin3_tdo_o      (jtag_pin3_tdo_o),
                .pin3_tdo_oe     (jtag_pin3_tdo_oe),
                .halt_req_o      (dbg_halt_req),
                .halted_i        (dbg_halted),
                .resume_req_o    (dbg_resume_req),
                .resumeack_i     (dbg_resumeack),
                .dbg_reg_addr_o  (dbg_reg_addr),
                .dbg_reg_wdata_o (dbg_reg_wdata),
                .dbg_reg_we_o    (dbg_reg_we),
                .dbg_reg_rdata_i (dbg_reg_rdata),
                .dbg_pc_wdata_o  (dbg_pc_wdata),
                .dbg_pc_we_o     (dbg_pc_we),
                .dbg_pc_i        (dbg_pc),
                .dbg_mem_req_o   (dbg_mem_req),
                .dbg_mem_addr_o  (dbg_mem_addr),
                .dbg_mem_we_o    (dbg_mem_we),
                .dbg_mem_wdata_o (dbg_mem_wdata),
                .dbg_mem_ready_i (dbg_mem_ready),
                .dbg_mem_error_i (dbg_mem_error),
                .dbg_mem_rdata_i (dbg_mem_rdata),
                .dbg_ndmreset_o  (dbg_ndmreset),
                .dbg_hartreset_o (dbg_hartreset),
                .dbg_singlestep_o(dbg_singlestep),
                .dbg_ebreakm_o   (dbg_ebreakm),
                .progbuf0_o      (progbuf0),
                .progbuf1_o      (progbuf1),

                // Trigger interface
                .trigger_halt_i(dbg_trigger_halt),
                .trigger_hit_i (dbg_trigger_hit),
                .tdata1_o      (dbg_tdata1),
                .tdata2_o      (dbg_tdata2)
            );
        end
        else begin : gen_no_jtag
            // No JTAG: tie all debug master outputs to safe quiescent values.
            assign dbg_halt_req     = 1'b0;
            assign dbg_resume_req   = 1'b0;
            assign dbg_reg_we       = 1'b0;
            assign dbg_reg_addr     = 5'd0;
            assign dbg_reg_wdata    = 32'd0;
            assign dbg_pc_we        = 1'b0;
            assign dbg_pc_wdata     = 32'd0;
            assign dbg_mem_req      = 1'b0;
            assign dbg_mem_addr     = 32'd0;
            assign dbg_mem_we       = 4'd0;
            assign dbg_mem_wdata    = 32'd0;
            assign dbg_ndmreset     = 1'b0;
            assign dbg_hartreset    = 1'b0;
            assign dbg_singlestep   = 1'b0;
            assign dbg_ebreakm      = 1'b0;
            assign progbuf0         = 32'h0010_0073;  // EBREAK
            assign progbuf1         = 32'h0010_0073;  // EBREAK
            assign dbg_tdata1       = '0;
            assign dbg_tdata2       = '0;

            // Tie JTAG output pins to safe levels
            assign jtag_pin1_tms_o  = 1'b1;
            assign jtag_pin1_tms_oe = 1'b0;
            assign jtag_pin3_tdo_o  = 1'b1;
            assign jtag_pin3_tdo_oe = 1'b0;

            logic _unused_jtag_pins;
            assign _unused_jtag_pins = &{1'b0, jtag_ntrst_i, jtag_pin0_tck_i,
                                         jtag_pin1_tms_i, jtag_pin2_tdi_i,
                                         dbg_halted, dbg_resumeack, dbg_reg_rdata,
                                         dbg_pc, dbg_mem_ready, dbg_mem_error, dbg_mem_rdata,
                                         dbg_trigger_halt, dbg_trigger_hit};
        end
    endgenerate

    // Track core alias address/data phase completion to prevent repeated valid signals to TCM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            core_alias_rd_addr_done <= 1'b0;
            core_alias_wr_aw_done   <= 1'b0;
            core_alias_wr_w_done    <= 1'b0;
            core_alias_wr_is_iram_r <= 1'b0;
            core_alias_iram_rd_pend <= 1'b0;
            core_alias_dram_rd_pend <= 1'b0;
            core_alias_iram_wr_pend <= 1'b0;
            core_alias_dram_wr_pend <= 1'b0;
        end
        else begin
            // Read AR phase: set done when arvalid && arready, clear when arvalid deasserts
            if (core_araddr_is_tcm_alias && core_mbus_arvalid && core_mbus_arready) begin
                core_alias_rd_addr_done <= 1'b1;
            end
            else if (!core_mbus_arvalid) begin
                core_alias_rd_addr_done <= 1'b0;
            end

            // Write AW phase: latch IRAM/DRAM routing at handshake, set done to stop re-sending awvalid
            if (core_awaddr_is_tcm_alias && core_mbus_awvalid && core_mbus_awready) begin
                core_alias_wr_aw_done   <= 1'b1;
                core_alias_wr_is_iram_r <= in_iram(core_mbus_awaddr);
            end
            else if (!core_mbus_awvalid && !core_mbus_wvalid) begin
                core_alias_wr_aw_done <= 1'b0;  // Clear when both AW and W deassert
            end

            // Write W phase: set done when wvalid && wready, clear when wvalid deasserts
            if (core_awaddr_is_tcm_alias && core_mbus_wvalid && core_mbus_wready) begin
                core_alias_wr_w_done <= 1'b1;
            end
            else if (!core_mbus_wvalid) begin
                core_alias_wr_w_done <= 1'b0;
            end

            // IRAM read response pending: set at AR handshake, clear at R handshake
            if (core_alias_rd_active && core_alias_rd_is_iram && iram_tcm_arvalid_mux && iram_tcm_arready_int) begin
                core_alias_iram_rd_pend <= 1'b1;
            end
            else if (core_alias_iram_rd_pend && iram_tcm_rvalid_int && core_mbus_rready) begin
                core_alias_iram_rd_pend <= 1'b0;
            end

            // DRAM read response pending: set at AR handshake, clear at R handshake
            if (core_alias_rd_active && !core_alias_rd_is_iram && dram_tcm_arvalid_mux && dram_tcm_arready_int) begin
                core_alias_dram_rd_pend <= 1'b1;
            end
            else if (core_alias_dram_rd_pend && dram_tcm_rvalid_int && core_mbus_rready) begin
                core_alias_dram_rd_pend <= 1'b0;
            end

            // IRAM write response pending: set at W handshake, clear at B handshake
            if (core_alias_w_active && core_alias_wr_is_iram && iram_tcm_wvalid_mux && iram_tcm_wready_int) begin
                core_alias_iram_wr_pend <= 1'b1;
            end
            else if (core_alias_iram_wr_pend && iram_tcm_bvalid_int && core_mbus_bready) begin
                core_alias_iram_wr_pend <= 1'b0;
            end

            // DRAM write response pending: set at W handshake, clear at B handshake
            if (core_alias_w_active && !core_alias_wr_is_iram && dram_tcm_wvalid_mux && dram_tcm_wready_int) begin
                core_alias_dram_wr_pend <= 1'b1;
            end
            else if (core_alias_dram_wr_pend && dram_tcm_bvalid_int && core_mbus_bready) begin
                core_alias_dram_wr_pend <= 1'b0;
            end
        end
    end

    // Pass external IRAM/DRAM TCM AXI masters through unless JTAG DM or core alias access
    // is actively performing an in-TCM access on that bank.
    // Priority: Debug > Core alias > External
    assign iram_tcm_araddr_mux = (dbg_tcm_select && dbg_tcm_is_iram) ? dbg_addr_r :
                                  (core_alias_rd_active && core_alias_rd_is_iram) ? core_mbus_araddr_mapped :
                                  s_iram_tcm_araddr;
    assign iram_tcm_arvalid_mux  = (dbg_tcm_select && dbg_tcm_is_iram) ? (dbg_tcm_state == DBG_TCM_RD_ADDR) :
                                    (core_alias_rd_active && core_alias_rd_is_iram) ? 1'b1 :
                                    s_iram_tcm_arvalid;
    assign iram_tcm_rready_mux   = (dbg_tcm_select && dbg_tcm_is_iram) ? (dbg_tcm_state == DBG_TCM_RD_RESP) :
                                    ((core_alias_rd_active && core_alias_rd_is_iram) || core_alias_iram_rd_pend) ? core_mbus_rready :
                                    s_iram_tcm_rready;
    assign iram_tcm_awaddr_mux = (dbg_tcm_select && dbg_tcm_is_iram) ? dbg_addr_r :
                                  (core_alias_aw_active && core_alias_wr_is_iram) ? core_mbus_awaddr_mapped :
                                  s_iram_tcm_awaddr;
    assign iram_tcm_awvalid_mux  = (dbg_tcm_select && dbg_tcm_is_iram) ? ((dbg_tcm_state == DBG_TCM_WR_REQ) && !dbg_aw_done) :
                                    (core_alias_aw_active && core_alias_wr_is_iram) ? core_mbus_awvalid :
                                    s_iram_tcm_awvalid;
    assign iram_tcm_wdata_mux = (dbg_tcm_select && dbg_tcm_is_iram) ? dbg_wdata_r :
                                 (core_alias_w_active && core_alias_wr_is_iram) ? core_mbus_wdata :
                                 s_iram_tcm_wdata;
    assign iram_tcm_wstrb_mux = (dbg_tcm_select && dbg_tcm_is_iram) ? dbg_wstrb_r :
                                 (core_alias_w_active && core_alias_wr_is_iram) ? core_mbus_wstrb :
                                 s_iram_tcm_wstrb;
    assign iram_tcm_wvalid_mux   = (dbg_tcm_select && dbg_tcm_is_iram) ? ((dbg_tcm_state == DBG_TCM_WR_REQ) && !dbg_w_done) :
                                    (core_alias_w_active && core_alias_wr_is_iram) ? core_mbus_wvalid :
                                    s_iram_tcm_wvalid;
    assign iram_tcm_bready_mux   = (dbg_tcm_select && dbg_tcm_is_iram) ? (dbg_tcm_state == DBG_TCM_WR_RESP) :
                                    ((core_alias_wr_active && core_alias_wr_is_iram) || core_alias_iram_wr_pend) ? core_mbus_bready :
                                    s_iram_tcm_bready;

    assign dram_tcm_araddr_mux = (dbg_tcm_select && !dbg_tcm_is_iram) ? dbg_addr_r :
                                  (core_alias_rd_active && !core_alias_rd_is_iram) ? core_mbus_araddr_mapped :
                                  s_dram_tcm_araddr;
    assign dram_tcm_arvalid_mux  = (dbg_tcm_select && !dbg_tcm_is_iram) ? (dbg_tcm_state == DBG_TCM_RD_ADDR) :
                                    (core_alias_rd_active && !core_alias_rd_is_iram) ? 1'b1 :
                                    s_dram_tcm_arvalid;
    assign dram_tcm_rready_mux   = (dbg_tcm_select && !dbg_tcm_is_iram) ? (dbg_tcm_state == DBG_TCM_RD_RESP) :
                                    ((core_alias_rd_active && !core_alias_rd_is_iram) || core_alias_dram_rd_pend) ? core_mbus_rready :
                                    s_dram_tcm_rready;
    assign dram_tcm_awaddr_mux = (dbg_tcm_select && !dbg_tcm_is_iram) ? dbg_addr_r :
                                  (core_alias_aw_active && !core_alias_wr_is_iram) ? core_mbus_awaddr_mapped :
                                  s_dram_tcm_awaddr;
    assign dram_tcm_awvalid_mux  = (dbg_tcm_select && !dbg_tcm_is_iram) ? ((dbg_tcm_state == DBG_TCM_WR_REQ) && !dbg_aw_done) :
                                    (core_alias_aw_active && !core_alias_wr_is_iram) ? core_mbus_awvalid :
                                    s_dram_tcm_awvalid;
    assign dram_tcm_wdata_mux = (dbg_tcm_select && !dbg_tcm_is_iram) ? dbg_wdata_r :
                                 (core_alias_w_active && !core_alias_wr_is_iram) ? core_mbus_wdata :
                                 s_dram_tcm_wdata;
    assign dram_tcm_wstrb_mux = (dbg_tcm_select && !dbg_tcm_is_iram) ? dbg_wstrb_r :
                                 (core_alias_w_active && !core_alias_wr_is_iram) ? core_mbus_wstrb :
                                 s_dram_tcm_wstrb;
    assign dram_tcm_wvalid_mux   = (dbg_tcm_select && !dbg_tcm_is_iram) ? ((dbg_tcm_state == DBG_TCM_WR_REQ) && !dbg_w_done) :
                                    (core_alias_w_active && !core_alias_wr_is_iram) ? core_mbus_wvalid :
                                    s_dram_tcm_wvalid;
    assign dram_tcm_bready_mux   = (dbg_tcm_select && !dbg_tcm_is_iram) ? (dbg_tcm_state == DBG_TCM_WR_RESP) :
                                    ((core_alias_wr_active && !core_alias_wr_is_iram) || core_alias_dram_wr_pend) ? core_mbus_bready :
                                    s_dram_tcm_bready;

    // Block external TCM slave access when debug or core alias access is active
    logic iram_blocked, dram_blocked;
    assign iram_blocked = (dbg_tcm_select && dbg_tcm_is_iram) || (core_alias_rd_active && core_alias_rd_is_iram) || (core_alias_wr_active && core_alias_wr_is_iram);
    assign dram_blocked = (dbg_tcm_select && !dbg_tcm_is_iram) || (core_alias_rd_active && !core_alias_rd_is_iram) || (core_alias_wr_active && !core_alias_wr_is_iram);

    assign s_iram_tcm_arready = iram_blocked ? 1'b0 : iram_tcm_arready_int;
    assign s_iram_tcm_rdata = iram_blocked ? 32'h0 : iram_tcm_rdata_int;
    assign s_iram_tcm_rresp = iram_blocked ? 2'b00 : iram_tcm_rresp_int;
    assign s_iram_tcm_rvalid = iram_blocked ? 1'b0 : iram_tcm_rvalid_int;
    assign s_iram_tcm_awready = iram_blocked ? 1'b0 : iram_tcm_awready_int;
    assign s_iram_tcm_wready = iram_blocked ? 1'b0 : iram_tcm_wready_int;
    assign s_iram_tcm_bresp = iram_blocked ? 2'b00 : iram_tcm_bresp_int;
    assign s_iram_tcm_bvalid = iram_blocked ? 1'b0 : iram_tcm_bvalid_int;

    assign s_dram_tcm_arready = dram_blocked ? 1'b0 : dram_tcm_arready_int;
    assign s_dram_tcm_rdata = dram_blocked ? 32'h0 : dram_tcm_rdata_int;
    assign s_dram_tcm_rresp = dram_blocked ? 2'b00 : dram_tcm_rresp_int;
    assign s_dram_tcm_rvalid = dram_blocked ? 1'b0 : dram_tcm_rvalid_int;
    assign s_dram_tcm_awready = dram_blocked ? 1'b0 : dram_tcm_awready_int;
    assign s_dram_tcm_wready = dram_blocked ? 1'b0 : dram_tcm_wready_int;
    assign s_dram_tcm_bresp = dram_blocked ? 2'b00 : dram_tcm_bresp_int;
    assign s_dram_tcm_bvalid = dram_blocked ? 1'b0 : dram_tcm_bvalid_int;

    // Mux xbar master between core and debugger (out-of-TCM accesses).
    // Core accesses to alias TCM addresses are blocked here (routed to TCM instead).
    assign mbus_araddr = dbg_ext_select ? dbg_addr_r : core_mbus_araddr;
    assign mbus_arvalid = dbg_ext_select ? (dbg_tcm_state == DBG_EXT_RD_ADDR) : (core_mbus_arvalid && !core_araddr_is_tcm_alias);
    assign mbus_rready = dbg_ext_select ? (dbg_tcm_state == DBG_EXT_RD_RESP) : core_mbus_rready;
    assign mbus_awaddr = dbg_ext_select ? dbg_addr_r : core_mbus_awaddr;
    assign mbus_awvalid = dbg_ext_select ? ((dbg_tcm_state == DBG_EXT_WR_REQ) && !dbg_aw_done) : (core_mbus_awvalid && !core_awaddr_is_tcm_alias);
    assign mbus_wdata = dbg_ext_select ? dbg_wdata_r : core_mbus_wdata;
    assign mbus_wstrb = dbg_ext_select ? dbg_wstrb_r : core_mbus_wstrb;
    assign mbus_wvalid = dbg_ext_select ? ((dbg_tcm_state == DBG_EXT_WR_REQ) && !dbg_w_done) : (core_mbus_wvalid && !core_awaddr_is_tcm_alias);
    assign mbus_bready = dbg_ext_select ? (dbg_tcm_state == DBG_EXT_WR_RESP) : (core_mbus_bready && !core_awaddr_is_tcm_alias);

    // Route core AXI master responses from either crossbar (normal) or TCM (alias access)
    logic core_use_iram_resp, core_use_dram_resp;
    assign core_use_iram_resp = core_araddr_is_tcm_alias && core_alias_rd_is_iram;
    assign core_use_dram_resp = core_araddr_is_tcm_alias && !core_alias_rd_is_iram;

    assign core_mbus_arready = dbg_ext_select ? 1'b0 :
                               core_use_iram_resp ? iram_tcm_arready_int :
                               core_use_dram_resp ? dram_tcm_arready_int :
                               mbus_arready;
    assign core_mbus_rdata = dbg_ext_select ? 32'h0 :
                             core_use_iram_resp ? iram_tcm_rdata_int :
                             core_use_dram_resp ? dram_tcm_rdata_int :
                             mbus_rdata;
    assign core_mbus_rresp = dbg_ext_select ? 2'b00 :
                             core_use_iram_resp ? iram_tcm_rresp_int :
                             core_use_dram_resp ? dram_tcm_rresp_int :
                             mbus_rresp;
    assign core_mbus_rvalid = dbg_ext_select ? 1'b0 :
                              core_use_iram_resp ? iram_tcm_rvalid_int :
                              core_use_dram_resp ? dram_tcm_rvalid_int :
                              mbus_rvalid;

    logic core_use_iram_wresp, core_use_dram_wresp;
    assign core_use_iram_wresp = core_awaddr_is_tcm_alias && core_alias_wr_is_iram;
    assign core_use_dram_wresp = core_awaddr_is_tcm_alias && !core_alias_wr_is_iram;

    assign core_mbus_awready = dbg_ext_select ? 1'b0 :
                               core_use_iram_wresp ? iram_tcm_awready_int :
                               core_use_dram_wresp ? dram_tcm_awready_int :
                               mbus_awready;
    assign core_mbus_wready = dbg_ext_select ? 1'b0 :
                              core_use_iram_wresp ? iram_tcm_wready_int :
                              core_use_dram_wresp ? dram_tcm_wready_int :
                              mbus_wready;
    assign core_mbus_bresp = dbg_ext_select ? 2'b00 :
                             core_use_iram_wresp ? iram_tcm_bresp_int :
                             core_use_dram_wresp ? dram_tcm_bresp_int :
                             mbus_bresp;
    assign core_mbus_bvalid = dbg_ext_select ? 1'b0 :
                              core_use_iram_wresp ? iram_tcm_bvalid_int :
                              core_use_dram_wresp ? dram_tcm_bvalid_int :
                              mbus_bvalid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbg_tcm_state   <= DBG_TCM_IDLE;
            dbg_mem_req_d   <= 1'b0;
            dbg_mem_error_r <= 1'b0;
            dbg_aw_done     <= 1'b0;
            dbg_w_done      <= 1'b0;
            dbg_addr_r      <= 32'h0;
            dbg_wdata_r     <= 32'h0;
            dbg_wstrb_r     <= 4'h0;
            dbg_tcm_is_iram <= 1'b0;
            dbg_mem_ready   <= 1'b0;
            dbg_mem_rdata   <= 32'h0;
        end
        else begin
            dbg_mem_req_d <= dbg_mem_req;
            dbg_mem_ready <= 1'b0;

            case (dbg_tcm_state)
                DBG_TCM_IDLE: begin
                    dbg_aw_done <= 1'b0;
                    dbg_w_done  <= 1'b0;
                    if (dbg_mem_req && !dbg_mem_req_d) begin
                        // Map alias addresses to canonical TCM addresses
                        dbg_addr_r      <= map_to_canonical(dbg_mem_addr);
                        dbg_wdata_r     <= dbg_mem_wdata;
                        dbg_wstrb_r     <= dbg_mem_we;
                        dbg_tcm_is_iram <= in_iram(dbg_mem_addr);
                        dbg_mem_error_r <= 1'b0;
                        if (in_tcm(dbg_mem_addr))
                            dbg_tcm_state <= (dbg_mem_we == 4'b0000) ? DBG_TCM_RD_ADDR : DBG_TCM_WR_REQ;
                        else dbg_tcm_state <= (dbg_mem_we == 4'b0000) ? DBG_EXT_RD_ADDR : DBG_EXT_WR_REQ;
                    end
                end

                DBG_TCM_RD_ADDR: begin
                    if (dbg_tcm_is_iram ? iram_tcm_arready_int : dram_tcm_arready_int) dbg_tcm_state <= DBG_TCM_RD_RESP;
                end

                DBG_TCM_RD_RESP: begin
                    if (dbg_tcm_is_iram ? iram_tcm_rvalid_int : dram_tcm_rvalid_int) begin
                        dbg_mem_rdata   <= dbg_tcm_is_iram ? iram_tcm_rdata_int : dram_tcm_rdata_int;
                        dbg_mem_error_r <= (dbg_tcm_is_iram ? iram_tcm_rresp_int : dram_tcm_rresp_int) != 2'b00;
                        dbg_mem_ready   <= 1'b1;
                        dbg_tcm_state   <= DBG_TCM_IDLE;
                    end
                end

                DBG_TCM_WR_REQ: begin
                    if (dbg_tcm_is_iram ? iram_tcm_awready_int : dram_tcm_awready_int) dbg_aw_done <= 1'b1;
                    if (dbg_tcm_is_iram ? iram_tcm_wready_int : dram_tcm_wready_int) dbg_w_done <= 1'b1;
                    if ((dbg_aw_done || (dbg_tcm_is_iram ? iram_tcm_awready_int : dram_tcm_awready_int))
                     && (dbg_w_done || (dbg_tcm_is_iram ? iram_tcm_wready_int : dram_tcm_wready_int)))
                        dbg_tcm_state <= DBG_TCM_WR_RESP;
                end

                DBG_TCM_WR_RESP: begin
                    if (dbg_tcm_is_iram ? iram_tcm_bvalid_int : dram_tcm_bvalid_int) begin
                        dbg_mem_error_r <= (dbg_tcm_is_iram ? iram_tcm_bresp_int : dram_tcm_bresp_int) != 2'b00;
                        dbg_mem_ready   <= 1'b1;
                        dbg_tcm_state   <= DBG_TCM_IDLE;
                    end
                end

                DBG_EXT_RD_ADDR: begin
                    if (mbus_arready) dbg_tcm_state <= DBG_EXT_RD_RESP;
                end

                DBG_EXT_RD_RESP: begin
                    if (mbus_rvalid) begin
                        dbg_mem_rdata   <= mbus_rdata;
                        dbg_mem_error_r <= (mbus_rresp != 2'b00);
                        dbg_mem_ready   <= 1'b1;
                        dbg_tcm_state   <= DBG_TCM_IDLE;
                    end
                end

                DBG_EXT_WR_REQ: begin
                    if (mbus_awready) dbg_aw_done <= 1'b1;
                    if (mbus_wready) dbg_w_done <= 1'b1;
                    if ((dbg_aw_done || mbus_awready) && (dbg_w_done || mbus_wready)) dbg_tcm_state <= DBG_EXT_WR_RESP;
                end

                DBG_EXT_WR_RESP: begin
                    if (mbus_bvalid) begin
                        dbg_mem_error_r <= (mbus_bresp != 2'b00);
                        dbg_mem_ready   <= 1'b1;
                        dbg_tcm_state   <= DBG_TCM_IDLE;
                    end
                end

                default: dbg_tcm_state <= DBG_TCM_IDLE;
            endcase
        end
    end

    // =====================================================================
    // JV32 Core + TCM
    // =====================================================================
    jv32_top #(
        .RV32E_EN  (RV32E_EN),
        .RV32M_EN  (RV32M_EN),
        .AMO_EN    (AMO_EN),
        .FAST_MUL  (FAST_MUL),
        .MUL_MC    (MUL_MC),
        .FAST_DIV  (FAST_DIV),
        .FAST_SHIFT(FAST_SHIFT),
        .BP_EN     (BP_EN),
        .RAS_EN    (RAS_EN),
        .IBUF_EN   (IBUF_EN),
        .RV32B_EN  (RV32B_EN),
        .N_TRIGGERS(N_TRIGGERS),
        .IRAM_SIZE (IRAM_SIZE),
        .DRAM_SIZE (DRAM_SIZE),
        .BOOT_ADDR (BOOT_ADDR),
        .DRAM_BASE (DRAM_BASE)
    ) u_jv32 (
        .clk  (clk),
        .rst_n(soc_rst_n),

        // Merged AXI master -> peripheral xbar
        .m_axi_araddr (core_mbus_araddr),
        .m_axi_arvalid(core_mbus_arvalid),
        .m_axi_arready(core_mbus_arready),
        .m_axi_rdata  (core_mbus_rdata),
        .m_axi_rresp  (core_mbus_rresp),
        .m_axi_rvalid (core_mbus_rvalid),
        .m_axi_rready (core_mbus_rready),
        .m_axi_awaddr (core_mbus_awaddr),
        .m_axi_awvalid(core_mbus_awvalid),
        .m_axi_awready(core_mbus_awready),
        .m_axi_wdata  (core_mbus_wdata),
        .m_axi_wstrb  (core_mbus_wstrb),
        .m_axi_wvalid (core_mbus_wvalid),
        .m_axi_wready (core_mbus_wready),
        .m_axi_bresp  (core_mbus_bresp),
        .m_axi_bvalid (core_mbus_bvalid),
        .m_axi_bready (core_mbus_bready),

        // TCM slave ports (external masters or internal JTAG debug bridge)
        .s_iram_axi_araddr (iram_tcm_araddr_mux),
        .s_iram_axi_arvalid(iram_tcm_arvalid_mux),
        .s_iram_axi_arready(iram_tcm_arready_int),
        .s_iram_axi_rdata  (iram_tcm_rdata_int),
        .s_iram_axi_rresp  (iram_tcm_rresp_int),
        .s_iram_axi_rvalid (iram_tcm_rvalid_int),
        .s_iram_axi_rready (iram_tcm_rready_mux),
        .s_iram_axi_awaddr (iram_tcm_awaddr_mux),
        .s_iram_axi_awvalid(iram_tcm_awvalid_mux),
        .s_iram_axi_awready(iram_tcm_awready_int),
        .s_iram_axi_wdata  (iram_tcm_wdata_mux),
        .s_iram_axi_wstrb  (iram_tcm_wstrb_mux),
        .s_iram_axi_wvalid (iram_tcm_wvalid_mux),
        .s_iram_axi_wready (iram_tcm_wready_int),
        .s_iram_axi_bresp  (iram_tcm_bresp_int),
        .s_iram_axi_bvalid (iram_tcm_bvalid_int),
        .s_iram_axi_bready (iram_tcm_bready_mux),

        .s_dram_axi_araddr (dram_tcm_araddr_mux),
        .s_dram_axi_arvalid(dram_tcm_arvalid_mux),
        .s_dram_axi_arready(dram_tcm_arready_int),
        .s_dram_axi_rdata  (dram_tcm_rdata_int),
        .s_dram_axi_rresp  (dram_tcm_rresp_int),
        .s_dram_axi_rvalid (dram_tcm_rvalid_int),
        .s_dram_axi_rready (dram_tcm_rready_mux),
        .s_dram_axi_awaddr (dram_tcm_awaddr_mux),
        .s_dram_axi_awvalid(dram_tcm_awvalid_mux),
        .s_dram_axi_awready(dram_tcm_awready_int),
        .s_dram_axi_wdata  (dram_tcm_wdata_mux),
        .s_dram_axi_wstrb  (dram_tcm_wstrb_mux),
        .s_dram_axi_wvalid (dram_tcm_wvalid_mux),
        .s_dram_axi_wready (dram_tcm_wready_int),
        .s_dram_axi_bresp  (dram_tcm_bresp_int),
        .s_dram_axi_bvalid (dram_tcm_bvalid_int),
        .s_dram_axi_bready (dram_tcm_bready_mux),

        // Interrupts
        .timer_irq   (timer_irq),
        .software_irq(software_irq),
        .external_irq(external_irq),
        .clic_irq    (clic_irq),
        .clic_level  (clic_level),
        .clic_prio   (clic_prio),
        .clic_id     (clic_id),
        .clic_ack    (clic_ack),

        // Debug sideband from the JTAG DM
        .dbg_hartreset_i (dbg_hartreset),
        .dbg_halt_req_i  (dbg_halt_req),
        .dbg_halted_o    (dbg_halted),
        .dbg_resume_req_i(dbg_resume_req),
        .dbg_resumeack_o (dbg_resumeack),
        .dbg_reg_addr_i  (dbg_reg_addr),
        .dbg_reg_wdata_i (dbg_reg_wdata),
        .dbg_reg_we_i    (dbg_reg_we),
        .dbg_reg_rdata_o (dbg_reg_rdata),
        .dbg_pc_wdata_i  (dbg_pc_wdata),
        .dbg_pc_we_i     (dbg_pc_we),
        .dbg_pc_o        (dbg_pc),
        .dbg_singlestep_i(dbg_singlestep),
        .dbg_ebreakm_i   (dbg_ebreakm),
        .progbuf0_i      (progbuf0),
        .progbuf1_i      (progbuf1),

        // Trigger interface
        .dbg_trigger_halt_o(dbg_trigger_halt),
        .dbg_trigger_hit_o (dbg_trigger_hit),
        .dbg_tdata1_i      (dbg_tdata1),
        .dbg_tdata2_i      (dbg_tdata2),

        // Trace
`ifndef SYNTHESIS
        .trace_en            (trace_en),
        .trace_valid         (trace_valid),
        .trace_reg_we        (trace_reg_we),
        .trace_pc            (trace_pc),
        .trace_rd            (trace_rd),
        .trace_rd_data       (trace_rd_data),
        .trace_instr         (trace_instr),
        .trace_mem_we        (trace_mem_we),
        .trace_mem_re        (trace_mem_re),
        .trace_mem_addr      (trace_mem_addr),
        .trace_mem_data      (trace_mem_data),
        .trace_irq_taken     (trace_irq_taken),
        .trace_irq_cause     (trace_irq_cause),
        .trace_irq_epc       (trace_irq_epc),
        .trace_irq_store_we  (trace_irq_store_we),
        .trace_irq_store_addr(trace_irq_store_addr),
        .trace_irq_store_data(trace_irq_store_data),
        .perf_bp_branch      (perf_bp_branch),
        .perf_bp_taken       (perf_bp_taken),
        .perf_bp_mispred     (perf_bp_mispred),
        .perf_bp_jal         (perf_bp_jal),
        .perf_bp_jal_miss    (perf_bp_jal_miss),
        .perf_bp_jalr        (perf_bp_jalr),
`endif
        .heartbeat_o         (heartbeat_o),
        .mtime_i             (clic_mtime)
    );

    // =====================================================================
    // AXI crossbar: 1 master -> 4 slaves
    //   Slave 0: UART   @ 0x2001_0000  mask 0xFFFF_FF00 (256 B)
    //   Slave 1: CLIC   @ 0x0200_0000  mask 0xFFE0_0000 (2 MB)
    //   Slave 2: Magic  @ 0x4000_0000  mask 0xF000_0000 (256 MB)
    //   Slave 3: External @ default catch-all (out-of-peripheral)
    // =====================================================================
    localparam logic [31:0] XBAR_BASE[4] = '{32'h2001_0000, 32'h0200_0000, 32'h4000_0000, 32'h0000_0000};
    localparam logic [31:0] XBAR_MASK[4] = '{32'hFFFF_FF00, 32'hFFE0_0000, 32'hF000_0000, 32'h0000_0000};

    logic [3:0][31:0] xs_awaddr;
    logic [3:0]       xs_awvalid;
    logic [3:0]       xs_awready;
    logic [3:0][31:0] xs_wdata;
    logic [3:0][ 3:0] xs_wstrb;
    logic [3:0]       xs_wvalid;
    logic [3:0]       xs_wready;
    logic [3:0][ 1:0] xs_bresp;
    logic [3:0]       xs_bvalid;
    logic [3:0]       xs_bready;
    logic [3:0][31:0] xs_araddr;
    logic [3:0]       xs_arvalid;
    logic [3:0]       xs_arready;
    logic [3:0][31:0] xs_rdata;
    logic [3:0][ 1:0] xs_rresp;
    logic [3:0]       xs_rvalid;
    logic [3:0]       xs_rready;

    axi_xbar #(
        .N_SLAVES  (4),
        .SLAVE_BASE(XBAR_BASE),
        .SLAVE_MASK(XBAR_MASK)
    ) u_xbar (
        .clk      (clk),
        .rst_n    (soc_rst_n),
        .m_awaddr (mbus_awaddr),
        .m_awvalid(mbus_awvalid),
        .m_awready(mbus_awready),
        .m_wdata  (mbus_wdata),
        .m_wstrb  (mbus_wstrb),
        .m_wvalid (mbus_wvalid),
        .m_wready (mbus_wready),
        .m_bresp  (mbus_bresp),
        .m_bvalid (mbus_bvalid),
        .m_bready (mbus_bready),
        .m_araddr (mbus_araddr),
        .m_arvalid(mbus_arvalid),
        .m_arready(mbus_arready),
        .m_rdata  (mbus_rdata),
        .m_rresp  (mbus_rresp),
        .m_rvalid (mbus_rvalid),
        .m_rready (mbus_rready),
        .s_awaddr (xs_awaddr),
        .s_awvalid(xs_awvalid),
        .s_awready(xs_awready),
        .s_wdata  (xs_wdata),
        .s_wstrb  (xs_wstrb),
        .s_wvalid (xs_wvalid),
        .s_wready (xs_wready),
        .s_bresp  (xs_bresp),
        .s_bvalid (xs_bvalid),
        .s_bready (xs_bready),
        .s_araddr (xs_araddr),
        .s_arvalid(xs_arvalid),
        .s_arready(xs_arready),
        .s_rdata  (xs_rdata),
        .s_rresp  (xs_rresp),
        .s_rvalid (xs_rvalid),
        .s_rready (xs_rready)
    );

    // External-memory/MMIO slave (catch-all out-of-peripheral path)
    assign ext_axi_awaddr  = xs_awaddr[3];
    assign ext_axi_awvalid = xs_awvalid[3];
    assign xs_awready[3]   = ext_axi_awready;
    assign ext_axi_wdata   = xs_wdata[3];
    assign ext_axi_wstrb   = xs_wstrb[3];
    assign ext_axi_wvalid  = xs_wvalid[3];
    assign xs_wready[3]    = ext_axi_wready;
    assign xs_bresp[3]     = ext_axi_bresp;
    assign xs_bvalid[3]    = ext_axi_bvalid;
    assign ext_axi_bready  = xs_bready[3];

    assign ext_axi_araddr  = xs_araddr[3];
    assign ext_axi_arvalid = xs_arvalid[3];
    assign xs_arready[3]   = ext_axi_arready;
    assign xs_rdata[3]     = ext_axi_rdata;
    assign xs_rresp[3]     = ext_axi_rresp;
    assign xs_rvalid[3]    = ext_axi_rvalid;
    assign ext_axi_rready  = xs_rready[3];

    // =====================================================================
    // UART - slave 0
    // =====================================================================
    axi_uart #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE),
        .FIFO_DEPTH(UART_FIFO_DEPTH)
    ) u_uart (
        .clk        (clk),
        .rst_n      (soc_rst_n),
        .axi_awaddr (xs_awaddr[0]),
        .axi_awvalid(xs_awvalid[0]),
        .axi_awready(xs_awready[0]),
        .axi_wdata  (xs_wdata[0]),
        .axi_wstrb  (xs_wstrb[0]),
        .axi_wvalid (xs_wvalid[0]),
        .axi_wready (xs_wready[0]),
        .axi_bresp  (xs_bresp[0]),
        .axi_bvalid (xs_bvalid[0]),
        .axi_bready (xs_bready[0]),
        .axi_araddr (xs_araddr[0]),
        .axi_arvalid(xs_arvalid[0]),
        .axi_arready(xs_arready[0]),
        .axi_rdata  (xs_rdata[0]),
        .axi_rresp  (xs_rresp[0]),
        .axi_rvalid (xs_rvalid[0]),
        .axi_rready (xs_rready[0]),
        .uart_rx    (uart_rx_i),
        .uart_tx    (uart_tx_o),
        .irq        (uart_irq)
    );

    // =====================================================================
    // CLIC / CLINT - slave 1
    // =====================================================================
    axi_clic #(
        .CLK_FREQ(CLK_FREQ)
    ) u_clic (
        .clk           (clk),
        .rst_n         (soc_rst_n),
        .mtime_o       (clic_mtime),
        .s_awaddr      (xs_awaddr[1]),
        .s_awvalid     (xs_awvalid[1]),
        .s_awready     (xs_awready[1]),
        .s_wdata       (xs_wdata[1]),
        .s_wstrb       (xs_wstrb[1]),
        .s_wvalid      (xs_wvalid[1]),
        .s_wready      (xs_wready[1]),
        .s_bresp       (xs_bresp[1]),
        .s_bvalid      (xs_bvalid[1]),
        .s_bready      (xs_bready[1]),
        .s_araddr      (xs_araddr[1]),
        .s_arvalid     (xs_arvalid[1]),
        .s_arready     (xs_arready[1]),
        .s_rdata       (xs_rdata[1]),
        .s_rresp       (xs_rresp[1]),
        .s_rvalid      (xs_rvalid[1]),
        .s_rready      (xs_rready[1]),
        .ext_irq_i     ({ext_irq_i[15:1], ext_irq_i[0] | uart_irq}),
        .timer_irq_o   (timer_irq),
        .software_irq_o(software_irq),
        .clic_irq_o    (clic_irq),
        .clic_level_o  (clic_level),
        .clic_prio_o   (clic_prio),
        .clic_id_o     (clic_id)
    );
    assign external_irq = clic_irq;

    // =====================================================================
    // Magic - slave 2
    // =====================================================================
`ifndef SYNTHESIS
    axi_magic u_magic (
        .clk        (clk),
        .rst_n      (soc_rst_n),
        .axi_awaddr (xs_awaddr[2]),
        .axi_awvalid(xs_awvalid[2]),
        .axi_awready(xs_awready[2]),
        .axi_wdata  (xs_wdata[2]),
        .axi_wstrb  (xs_wstrb[2]),
        .axi_wvalid (xs_wvalid[2]),
        .axi_wready (xs_wready[2]),
        .axi_bresp  (xs_bresp[2]),
        .axi_bvalid (xs_bvalid[2]),
        .axi_bready (xs_bready[2]),
        .axi_araddr (xs_araddr[2]),
        .axi_arvalid(xs_arvalid[2]),
        .axi_arready(xs_arready[2]),
        .axi_rdata  (xs_rdata[2]),
        .axi_rresp  (xs_rresp[2]),
        .axi_rvalid (xs_rvalid[2]),
        .axi_rready (xs_rready[2])
    );
`else
    assign xs_awready[2]     = 1'b1;
    assign xs_wready[2]      = 1'b1;
    assign xs_bresp[2][1:0]  = 2'b00;  // RESP_OKAY
    assign xs_bvalid[2]      = 1'b1;
    assign xs_arready[2]     = 1'b1;
    assign xs_rdata[2][31:0] = 32'b0;
    assign xs_rresp[2][1:0]  = 2'b00;  // RESP_OKAY
    assign xs_rvalid[2]      = 1'b1;
`endif

    // CLIC ack unused (CLINT-style polling, no ack needed)
    logic _unused;
    assign _unused = &{1'b0, clic_ack};

endmodule
