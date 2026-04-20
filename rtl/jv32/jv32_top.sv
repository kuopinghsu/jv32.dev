// ============================================================================
// File: jv32_top.sv
// Project: JV32 RISC-V Processor
// Description: JV32 Core with Tightly-Coupled Memories (TCM) and AXI interfaces
//
// Architecture
// ============
//  ┌──────────────────────────────────────────────────────────────────────┐
//  │                           jv32_top                                   │
//  │  ┌──────────┐  I-fetch   ╔══════════╗                                │
//  │  │          ├───────────►║ IRAM TCM ║◄─┐ D-access (IRAM range)       │
//  │  │ jv32_core│            ╚══════════╝  │                             │
//  │  │          ├─── D-access ─────────────┤                             │
//  │  │          │                          └►╔══════════╗                │
//  │  │          │                            ║ DRAM TCM ║ (DRAM range)   │
//  │  │          │             out-of-TCM     ╚══════════╝                │
//  │  │          ├─────────────── miss ──────►┌──────────┐                │
//  │  └──────────┘                            │ AXI Mstr ├─────────────── │► m_axi
//  │                                          └──────────┘  D > I priority│
//  │  s_axi ◄──── AXI Slave (ext. access to TCM, core has priority) ───── │◄ s_axi
//  └──────────────────────────────────────────────────────────────────────┘
//
// TCM Timing
// ----------
//  sram_1rw has 1-cycle registered read latency.
//  I-fetch : addr presented cycle N → instruction valid cycle N+1.
//  D-read  : addr presented cycle N → data valid cycle N+1 (1-cycle stall).
//  D-write : written at clk edge of cycle N → ack cycle N+1.
//  When D-path and I-path both target IRAM, D-path wins (I-fetch stalls 1 cycle).
//
// AXI Master (merged)
// -------------------
//  Out-of-TCM accesses from I-fetch and D-path share one AXI4-Lite master port.
//  D-bus has priority over I-bus.  Both can have an outstanding miss simultaneously
//  but are served sequentially (D first).
//
// AXI Slave
// ---------
//  External agents (debug, DMA) can read/write TCM via the slave port.
//  Core has absolute priority; slave stalls until core is not accessing the
//  target SRAM for that cycle.
//  For ELF loading (pre-simulation), use DPI mem_write_byte instead.
// ============================================================================

module jv32_top #(
    parameter bit                 FAST_MUL   = 1'b1,
    parameter bit                 MUL_MC     = 1'b1,
    parameter bit                 FAST_DIV   = 1'b0,
    parameter bit                 FAST_SHIFT = 1'b1,
    parameter bit                 BP_EN      = 1'b1,
    parameter int unsigned        IRAM_SIZE  = 128 * 1024,  // bytes, power-of-2 (128 KB)
    parameter int unsigned        DRAM_SIZE  = 128 * 1024,  // bytes, power-of-2 (128 KB)
    parameter bit          [31:0] BOOT_ADDR  = 32'h8000_0000,
    parameter bit          [31:0] IRAM_BASE  = 32'h8000_0000,
    parameter bit          [31:0] DRAM_BASE  = 32'hC000_0000
) (
    input logic clk,
    input logic rst_n,

    // =========================================================================
    // AXI4-Lite Master — merged I+D bus for out-of-TCM accesses (D-bus priority)
    // =========================================================================
    output logic [31:0] m_axi_araddr,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    input  logic [31:0] m_axi_rdata,
    input  logic [ 1:0] m_axi_rresp,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,

    output logic [31:0] m_axi_awaddr,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [31:0] m_axi_wdata,
    output logic [ 3:0] m_axi_wstrb,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    input  logic [ 1:0] m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,

    // =========================================================================
    // AXI4-Lite Slave (IRAM TCM) — address uses low bits only
    // =========================================================================
    input  logic [31:0] s_iram_axi_araddr,
    input  logic        s_iram_axi_arvalid,
    output logic        s_iram_axi_arready,
    output logic [31:0] s_iram_axi_rdata,
    output logic [ 1:0] s_iram_axi_rresp,
    output logic        s_iram_axi_rvalid,
    input  logic        s_iram_axi_rready,

    input  logic [31:0] s_iram_axi_awaddr,
    input  logic        s_iram_axi_awvalid,
    output logic        s_iram_axi_awready,
    input  logic [31:0] s_iram_axi_wdata,
    input  logic [ 3:0] s_iram_axi_wstrb,
    input  logic        s_iram_axi_wvalid,
    output logic        s_iram_axi_wready,
    output logic [ 1:0] s_iram_axi_bresp,
    output logic        s_iram_axi_bvalid,
    input  logic        s_iram_axi_bready,

    // =========================================================================
    // AXI4-Lite Slave (DRAM TCM) — address uses low bits only
    // =========================================================================
    input  logic [31:0] s_dram_axi_araddr,
    input  logic        s_dram_axi_arvalid,
    output logic        s_dram_axi_arready,
    output logic [31:0] s_dram_axi_rdata,
    output logic [ 1:0] s_dram_axi_rresp,
    output logic        s_dram_axi_rvalid,
    input  logic        s_dram_axi_rready,

    input  logic [31:0] s_dram_axi_awaddr,
    input  logic        s_dram_axi_awvalid,
    output logic        s_dram_axi_awready,
    input  logic [31:0] s_dram_axi_wdata,
    input  logic [ 3:0] s_dram_axi_wstrb,
    input  logic        s_dram_axi_wvalid,
    output logic        s_dram_axi_wready,
    output logic [ 1:0] s_dram_axi_bresp,
    output logic        s_dram_axi_bvalid,
    input  logic        s_dram_axi_bready,

    // =========================================================================
    // Interrupts
    // =========================================================================
    input  logic       timer_irq,
    input  logic       external_irq,
    input  logic       software_irq,
    input  logic       clic_irq,
    input  logic [7:0] clic_level,
    input  logic [7:0] clic_prio,
    input  logic [4:0] clic_id,
    output logic       clic_ack,

    // =========================================================================
    // Debug interface from the JTAG debug module
    // =========================================================================
    input  logic        dbg_hartreset_i,
    input  logic        dbg_halt_req_i,
    output logic        dbg_halted_o,
    input  logic        dbg_resume_req_i,
    output logic        dbg_resumeack_o,
    input  logic [ 4:0] dbg_reg_addr_i,
    input  logic [31:0] dbg_reg_wdata_i,
    input  logic        dbg_reg_we_i,
    output logic [31:0] dbg_reg_rdata_o,
    input  logic [31:0] dbg_pc_wdata_i,
    input  logic        dbg_pc_we_i,
    output logic [31:0] dbg_pc_o,
    input  logic        dbg_singlestep_i,
    input  logic        dbg_ebreakm_i,
    input  logic [31:0] progbuf0_i,
    input  logic [31:0] progbuf1_i,

    // Trigger interface (Debug Spec 0.13 §5.2)
    output logic             dbg_trigger_halt_o,
    output logic [1:0]       dbg_trigger_hit_o,   // per-trigger hit bits (set by HW, cleared on resume)
    input  logic [1:0][31:0] dbg_tdata1_i,
    input  logic [1:0][31:0] dbg_tdata2_i,

    // =========================================================================
    // Trace
    // =========================================================================
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
    output logic [31:0] trace_mem_data
);
    import jv32_pkg::*;
    import axi_pkg::*;

    // =========================================================================
    // TCM parameters
    // =========================================================================
    localparam int unsigned IRAM_DEPTH = IRAM_SIZE / 4;
    localparam int unsigned DRAM_DEPTH = DRAM_SIZE / 4;
    localparam int unsigned IRAM_ABITS = $clog2(IRAM_DEPTH);
    localparam int unsigned DRAM_ABITS = $clog2(DRAM_DEPTH);

    // Address decode: power-of-2 regions
    function automatic logic in_iram(input logic [31:0] addr);
        return (addr & ~(32'(IRAM_SIZE) - 32'h1)) == (IRAM_BASE & ~(32'(IRAM_SIZE) - 32'h1));
    endfunction
    function automatic logic in_dram(input logic [31:0] addr);
        return (addr & ~(32'(DRAM_SIZE) - 32'h1)) == (DRAM_BASE & ~(32'(DRAM_SIZE) - 32'h1));
    endfunction
    function automatic logic in_tcm(input logic [31:0] addr);
        return in_iram(addr) | in_dram(addr);
    endfunction

    localparam logic [31:0] DEBUG_ROM_BASE   = 32'h0F80_0000;
    localparam logic [31:0] DEBUG_ROM_EBREAK = 32'h0010_0073;

    // =========================================================================
    // Core memory interface
    // =========================================================================
    logic        imem_req_valid;
    logic [31:0] imem_req_addr;
    logic        imem_resp_valid;
    logic [31:0] imem_resp_data;
    logic        dmem_resp_fault;
    logic [31:0] imem_resp_pc;
    logic        imem_resp_fault;     // AXI I-fetch returned non-OKAY response (DECERR)
    logic [31:0] imem_resp_fault_pc;  // exact request PC for the faulting AXI response
    logic        imem_flush_core;     // rvc_flush from core

    logic        dmem_req_valid;
    logic        dmem_req_write;
    logic [31:0] dmem_req_addr;
    logic [31:0] dmem_req_wdata;
    logic [ 3:0] dmem_req_wstrb;
    logic        dmem_resp_valid;
    logic [31:0] dmem_resp_data;
    logic        core_rst_n;

    assign core_rst_n = rst_n & ~dbg_hartreset_i;

    jv32_core #(
        .FAST_MUL  (FAST_MUL),
        .MUL_MC    (MUL_MC),
        .FAST_DIV  (FAST_DIV),
        .FAST_SHIFT(FAST_SHIFT),
        .BP_EN     (BP_EN),
        .BOOT_ADDR (BOOT_ADDR)
    ) u_core (
        .clk               (clk),
        .rst_n             (core_rst_n),
        .imem_req_valid    (imem_req_valid),
        .imem_req_addr     (imem_req_addr),
        .imem_resp_valid   (imem_resp_valid),
        .imem_resp_data    (imem_resp_data),
        .imem_resp_pc      (imem_resp_pc),
        .imem_resp_fault   (imem_resp_fault),
        .imem_resp_fault_pc(imem_resp_fault_pc),
        .timer_irq         (timer_irq),
        .external_irq      (external_irq),
        .software_irq      (software_irq),
        .clic_irq          (clic_irq),
        .clic_level        (clic_level),
        .clic_prio         (clic_prio),
        .clic_id           (clic_id),
        .clic_ack          (clic_ack),
        .halt_req_i        (dbg_halt_req_i),
        .halted_o          (dbg_halted_o),
        .resume_req_i      (dbg_resume_req_i),
        .resumeack_o       (dbg_resumeack_o),
        .dbg_reg_addr_i    (dbg_reg_addr_i),
        .dbg_reg_wdata_i   (dbg_reg_wdata_i),
        .dbg_reg_we_i      (dbg_reg_we_i),
        .dbg_reg_rdata_o   (dbg_reg_rdata_o),
        .dbg_pc_wdata_i    (dbg_pc_wdata_i),
        .dbg_pc_we_i       (dbg_pc_we_i),
        .dbg_pc_o          (dbg_pc_o),
        .dbg_singlestep_i  (dbg_singlestep_i),
        .dbg_ebreakm_i     (dbg_ebreakm_i),
        .trigger_halt_o    (dbg_trigger_halt_o),
        .trigger_hit_o     (dbg_trigger_hit_o),
        .tdata1_i          (dbg_tdata1_i),
        .tdata2_i          (dbg_tdata2_i),
        .imem_flush        (imem_flush_core),
        .dmem_req_valid    (dmem_req_valid),
        .dmem_req_write    (dmem_req_write),
        .dmem_req_addr     (dmem_req_addr),
        .dmem_req_wdata    (dmem_req_wdata),
        .dmem_req_wstrb    (dmem_req_wstrb),
        .dmem_resp_valid   (dmem_resp_valid),
        .dmem_resp_data    (dmem_resp_data),
        .dmem_resp_fault   (dmem_resp_fault),
        .trace_en          (trace_en),
        .trace_valid       (trace_valid),
        .trace_reg_we      (trace_reg_we),
        .trace_pc          (trace_pc),
        .trace_rd          (trace_rd),
        .trace_rd_data     (trace_rd_data),
        .trace_instr       (trace_instr),
        .trace_mem_we      (trace_mem_we),
        .trace_mem_re      (trace_mem_re),
        .trace_mem_addr    (trace_mem_addr),
        .trace_mem_data    (trace_mem_data)
    );

    // =========================================================================
    // SRAM instances: single 32-bit-wide SRAM each for IRAM and DRAM
    // Byte-write granularity via wbe[3:0] (byte enables).
    // Naming for DPI mem_write_byte hierarchical access:
    //   u_iram.mem[word_index]
    //   u_dram.mem[word_index]
    // DEPTH = SIZE/4 (32-bit word-addressed);
    // synthesis wrapper maps each to 16 × sram_1rw_2048x32 sub-banks.
    // =========================================================================
    logic [IRAM_ABITS-1:0] iram_addr;
    logic [           3:0] iram_wbe;
    logic [          31:0] iram_wdata;
    logic [          31:0] iram_rdata;

    sram_1rw #(
        .DEPTH(IRAM_DEPTH),
        .WIDTH(32)
    ) u_iram (
        .clk  (clk),
        .ce   (1'b1),
        .we   (|iram_wbe),
        .wbe  (iram_wbe),
        .addr (iram_addr),
        .wdata(iram_wdata),
        .rdata(iram_rdata)
    );

    logic [DRAM_ABITS-1:0] dram_addr;
    logic [           3:0] dram_wbe;
    logic [          31:0] dram_wdata;
    logic [          31:0] dram_rdata;

    sram_1rw #(
        .DEPTH(DRAM_DEPTH),
        .WIDTH(32)
    ) u_dram (
        .clk  (clk),
        .ce   (1'b1),
        .we   (|dram_wbe),
        .wbe  (dram_wbe),
        .addr (dram_addr),
        .wdata(dram_wdata),
        .rdata(dram_rdata)
    );

    // =========================================================================
    // Core requests hitting TCM vs. missing to AXI
    // =========================================================================
    // I-path: always fetching (imem_req_valid=1), but only IRAM is TCM for I
    logic core_if_dbgrom;  // I-fetch hits the debug ROM/program buffer window
    logic core_if_iram;    // I-fetch hits IRAM
    logic core_if_axi;     // I-fetch misses TCM → needs AXI

    // D-path
    logic core_d_iram_re;  // D-read inside IRAM
    logic core_d_iram_we;  // D-write inside IRAM
    logic core_d_dram_re;  // D-read inside DRAM
    logic core_d_dram_we;  // D-write inside DRAM
    logic core_d_axi;      // D-access misses TCM → needs AXI

    assign core_if_dbgrom = imem_req_valid
                            && (imem_req_addr[31:4] == DEBUG_ROM_BASE[31:4])
                            && (imem_req_addr[3:2] <= 2'd2);
    assign core_if_iram = imem_req_valid && in_iram(imem_req_addr);
    assign core_if_axi = imem_req_valid && !core_if_dbgrom && !core_if_iram;
    assign core_d_iram_re = dmem_req_valid & ~dmem_req_write & in_iram(dmem_req_addr);
    assign core_d_iram_we = dmem_req_valid & dmem_req_write & in_iram(dmem_req_addr);
    assign core_d_dram_re = dmem_req_valid & ~dmem_req_write & in_dram(dmem_req_addr);
    assign core_d_dram_we = dmem_req_valid & dmem_req_write & in_dram(dmem_req_addr);
    assign core_d_axi = dmem_req_valid & ~in_tcm(dmem_req_addr);

    // =========================================================================
    // Slave state machines (external TCM access, core has priority)
    // Addresses are indexed by low bits only; no base-address decode here.
    // =========================================================================
    typedef enum logic [2:0] {
        SLV_IDLE,     // idle
        SLV_RD_WAIT,  // have AR addr, waiting for SRAM grant
        SLV_RD_RESP,  // SRAM response cycle: drive rvalid
        SLV_WR_DATA,  // AW received, waiting for W channel
        SLV_WR_WAIT,  // have AW+W, waiting for SRAM grant
        SLV_WR_RESP   // write accepted, drive bvalid
    } slv_e;

    slv_e        iram_slv_state;
    slv_e        dram_slv_state;
    logic [31:0] iram_slv_addr;
    logic [31:0] dram_slv_addr;
    logic [31:0] iram_slv_wdata;
    logic [31:0] dram_slv_wdata;
    logic [ 3:0] iram_slv_wstrb;
    logic [ 3:0] dram_slv_wstrb;
    logic [31:0] iram_slv_rdata_r;
    logic [31:0] dram_slv_rdata_r;
    logic        iram_slv_rd_first;
    logic        dram_slv_rd_first;

    logic        slave_wants_iram;
    logic        slave_wants_dram;
    logic        slave_iram_is_wr;
    logic        slave_dram_is_wr;
    logic        slave_iram_grant;
    logic        slave_dram_grant;

    assign slave_wants_iram = (iram_slv_state == SLV_RD_WAIT) | (iram_slv_state == SLV_WR_WAIT);
    assign slave_wants_dram = (dram_slv_state == SLV_RD_WAIT) | (dram_slv_state == SLV_WR_WAIT);
    assign slave_iram_is_wr = (iram_slv_state == SLV_WR_WAIT);
    assign slave_dram_is_wr = (dram_slv_state == SLV_WR_WAIT);

    // Grant: core does not need that SRAM this cycle
    assign slave_iram_grant = slave_wants_iram & ~(core_d_iram_re | core_d_iram_we);
    assign slave_dram_grant = slave_wants_dram & ~(core_d_dram_re | core_d_dram_we);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            iram_slv_state    <= SLV_IDLE;
            iram_slv_addr     <= '0;
            iram_slv_wdata    <= '0;
            iram_slv_wstrb    <= '0;
            iram_slv_rdata_r  <= '0;
            iram_slv_rd_first <= 1'b0;

            dram_slv_state    <= SLV_IDLE;
            dram_slv_addr     <= '0;
            dram_slv_wdata    <= '0;
            dram_slv_wstrb    <= '0;
            dram_slv_rdata_r  <= '0;
            dram_slv_rd_first <= 1'b0;
        end
        else begin
            iram_slv_rd_first <= 1'b0;
            dram_slv_rd_first <= 1'b0;

            case (iram_slv_state)
                SLV_IDLE: begin
                    if (s_iram_axi_arvalid) begin
                        iram_slv_addr  <= s_iram_axi_araddr;
                        iram_slv_state <= SLV_RD_WAIT;
                    end
                    else if (s_iram_axi_awvalid) begin
                        iram_slv_addr  <= s_iram_axi_awaddr;
                        iram_slv_state <= SLV_WR_DATA;
                    end
                end
                SLV_RD_WAIT: begin
                    if (slave_iram_grant) begin
                        iram_slv_state    <= SLV_RD_RESP;
                        iram_slv_rd_first <= 1'b1;
                    end
                end
                SLV_RD_RESP: begin
                    if (iram_slv_rd_first) iram_slv_rdata_r <= iram_rdata;
                    if (s_iram_axi_rready) iram_slv_state <= SLV_IDLE;
                end
                SLV_WR_DATA: begin
                    if (s_iram_axi_wvalid) begin
                        iram_slv_wdata <= s_iram_axi_wdata;
                        iram_slv_wstrb <= s_iram_axi_wstrb;
                        iram_slv_state <= SLV_WR_WAIT;
                    end
                end
                SLV_WR_WAIT: begin
                    if (slave_iram_grant) iram_slv_state <= SLV_WR_RESP;
                end
                SLV_WR_RESP: begin
                    if (s_iram_axi_bready) iram_slv_state <= SLV_IDLE;
                end
                default: iram_slv_state <= SLV_IDLE;
            endcase

            case (dram_slv_state)
                SLV_IDLE: begin
                    if (s_dram_axi_arvalid) begin
                        dram_slv_addr  <= s_dram_axi_araddr;
                        dram_slv_state <= SLV_RD_WAIT;
                    end
                    else if (s_dram_axi_awvalid) begin
                        dram_slv_addr  <= s_dram_axi_awaddr;
                        dram_slv_state <= SLV_WR_DATA;
                    end
                end
                SLV_RD_WAIT: begin
                    if (slave_dram_grant) begin
                        dram_slv_state    <= SLV_RD_RESP;
                        dram_slv_rd_first <= 1'b1;
                    end
                end
                SLV_RD_RESP: begin
                    if (dram_slv_rd_first) dram_slv_rdata_r <= dram_rdata;
                    if (s_dram_axi_rready) dram_slv_state <= SLV_IDLE;
                end
                SLV_WR_DATA: begin
                    if (s_dram_axi_wvalid) begin
                        dram_slv_wdata <= s_dram_axi_wdata;
                        dram_slv_wstrb <= s_dram_axi_wstrb;
                        dram_slv_state <= SLV_WR_WAIT;
                    end
                end
                SLV_WR_WAIT: begin
                    if (slave_dram_grant) dram_slv_state <= SLV_WR_RESP;
                end
                SLV_WR_RESP: begin
                    if (s_dram_axi_bready) dram_slv_state <= SLV_IDLE;
                end
                default: dram_slv_state <= SLV_IDLE;
            endcase
        end
    end

    // IRAM slave AXI outputs
    assign s_iram_axi_arready = (iram_slv_state == SLV_IDLE) & ~s_iram_axi_awvalid;
    assign s_iram_axi_awready = (iram_slv_state == SLV_IDLE) & ~s_iram_axi_arvalid;
    assign s_iram_axi_wready  = (iram_slv_state == SLV_WR_DATA);
    assign s_iram_axi_rvalid  = (iram_slv_state == SLV_RD_RESP);
    assign s_iram_axi_rdata   = iram_slv_rd_first ? iram_rdata : iram_slv_rdata_r;
    assign s_iram_axi_rresp   = 2'b00;
    assign s_iram_axi_bvalid  = (iram_slv_state == SLV_WR_RESP);
    assign s_iram_axi_bresp   = 2'b00;

    // DRAM slave AXI outputs
    assign s_dram_axi_arready = (dram_slv_state == SLV_IDLE) & ~s_dram_axi_awvalid;
    assign s_dram_axi_awready = (dram_slv_state == SLV_IDLE) & ~s_dram_axi_arvalid;
    assign s_dram_axi_wready  = (dram_slv_state == SLV_WR_DATA);
    assign s_dram_axi_rvalid  = (dram_slv_state == SLV_RD_RESP);
    assign s_dram_axi_rdata   = dram_slv_rd_first ? dram_rdata : dram_slv_rdata_r;
    assign s_dram_axi_rresp   = 2'b00;
    assign s_dram_axi_bvalid  = (dram_slv_state == SLV_WR_RESP);
    assign s_dram_axi_bresp   = 2'b00;

    // =========================================================================
    // SRAM mux: Core-D > Core-I > Slave  (combinatorial)
    // =========================================================================
    always_comb begin
        // IRAM: D-path > Slave > I-path
        if (core_d_iram_re | core_d_iram_we) begin
            iram_addr  = dmem_req_addr[IRAM_ABITS+1:2];
            iram_wbe   = core_d_iram_we ? dmem_req_wstrb : 4'h0;
            iram_wdata = dmem_req_wdata;
        end
        else if (slave_iram_grant) begin
            iram_addr  = iram_slv_addr[IRAM_ABITS+1:2];
            iram_wbe   = slave_iram_is_wr ? iram_slv_wstrb : 4'h0;
            iram_wdata = iram_slv_wdata;
        end
        else if (core_if_iram) begin
            iram_addr  = imem_req_addr[IRAM_ABITS+1:2];
            iram_wbe   = 4'h0;
            iram_wdata = 32'h0;
        end
        else begin
            iram_addr  = imem_req_addr[IRAM_ABITS+1:2];  // default: I-fetch reads
            iram_wbe   = 4'h0;
            iram_wdata = 32'h0;
        end

        // DRAM: D-path > Slave
        if (core_d_dram_re | core_d_dram_we) begin
            dram_addr  = dmem_req_addr[DRAM_ABITS+1:2];
            dram_wbe   = core_d_dram_we ? dmem_req_wstrb : 4'h0;
            dram_wdata = dmem_req_wdata;
        end
        else if (slave_dram_grant) begin
            dram_addr  = dram_slv_addr[DRAM_ABITS+1:2];
            dram_wbe   = slave_dram_is_wr ? dram_slv_wstrb : 4'h0;
            dram_wdata = dram_slv_wdata;
        end
        else begin
            dram_addr  = dmem_req_addr[DRAM_ABITS+1:2];  // default: read-ahead harmless
            dram_wbe   = 4'h0;
            dram_wdata = 32'h0;
        end
    end

    // =========================================================================
    // TCM response tracking (1-cycle registered SRAM latency)
    // =========================================================================
    // Track whose data is valid on iram_rdata / dram_rdata each cycle
    logic        dbgrom_used_by_core_i_d;  // debug ROM was accessed by I-fetch last cycle
    logic [31:0] dbgrom_data_d;            // debug ROM/program-buffer instruction
    logic [31:0] dbgrom_pc_d;              // debug ROM request PC
    logic        iram_used_by_core_i_d;    // IRAM was accessed by I-fetch last cycle
    logic        iram_used_by_core_d_d;    // IRAM was accessed by D-path last cycle
    logic        dram_used_by_core_d_d;    // DRAM was accessed by D-path last cycle
    logic        dmem_was_write_d;         // D-path access last cycle was a write
    logic        imem_flush_d;             // flush was asserted last cycle
    logic [31:0] imem_req_addr_d;          // I-fetch address from last cycle (for resp_pc)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbgrom_used_by_core_i_d <= 1'b0;
            dbgrom_data_d           <= DEBUG_ROM_EBREAK;
            dbgrom_pc_d             <= DEBUG_ROM_BASE;
            iram_used_by_core_i_d   <= 1'b0;
            iram_used_by_core_d_d   <= 1'b0;
            dram_used_by_core_d_d   <= 1'b0;
            dmem_was_write_d        <= 1'b0;
            imem_flush_d            <= 1'b0;
            imem_req_addr_d         <= BOOT_ADDR;
        end
        else begin
            dbgrom_used_by_core_i_d <= core_if_dbgrom;
            dbgrom_pc_d             <= imem_req_addr;
            case (imem_req_addr[3:2])
                2'd0:    dbgrom_data_d <= progbuf0_i;
                2'd1:    dbgrom_data_d <= progbuf1_i;
                default: dbgrom_data_d <= DEBUG_ROM_EBREAK;
            endcase
            // Core I-fetch used IRAM this cycle only if neither D-path nor
            // slave access preempted IRAM in the mux arbitration.
            iram_used_by_core_i_d <= core_if_iram & ~(core_d_iram_re | core_d_iram_we) & ~slave_iram_grant;
            // Core D-path used IRAM this cycle.
            // Gate out the spurious re-assertion that occurs on the response cycle:
            // when iram_used_by_core_d_d is already high (TCM response in flight),
            // ex_wb_r still holds the completing instruction and would re-drive
            // core_d_iram_re/we with the same old address, causing the SRAM to
            // capture the old address again and return stale data to the next load.
            iram_used_by_core_d_d <= (core_d_iram_re | core_d_iram_we) & ~iram_used_by_core_d_d;
            // Core D-path used DRAM this cycle.
            // Gate out the spurious re-assertion that occurs on the response cycle:
            // when dram_used_by_core_d_d is already high (TCM response in flight),
            // ex_wb_r still holds the completing instruction and would re-drive
            // core_d_dram_re/we with the same old address, causing the SRAM to
            // capture the old address again and return stale data to the next load.
            dram_used_by_core_d_d <= (core_d_dram_re | core_d_dram_we) & ~dram_used_by_core_d_d;
            // Was the D-path a write?
            dmem_was_write_d      <= dmem_req_write;
            // Flush invalidates in-flight I-fetch response
            imem_flush_d          <= imem_flush_core;
            // Register I-fetch address for imem_resp_pc
            imem_req_addr_d       <= imem_req_addr;
        end
    end

    // TCM responses to core
    // I-fetch: valid when IRAM was used for I-fetch AND no flush last cycle
    logic        imem_resp_valid_tcm;
    logic [31:0] imem_resp_data_tcm;
    logic [31:0] imem_resp_pc_tcm;
    assign imem_resp_valid_tcm = iram_used_by_core_i_d & ~imem_flush_d;
    assign imem_resp_data_tcm  = iram_rdata;
    assign imem_resp_pc_tcm    = imem_req_addr_d;

    // Debug ROM / program buffer fetches: 1-cycle registered response like the TCM.
    logic        imem_resp_valid_dbgrom;
    logic [31:0] imem_resp_data_dbgrom;
    logic [31:0] imem_resp_pc_dbgrom;
    assign imem_resp_valid_dbgrom = dbgrom_used_by_core_i_d & ~imem_flush_d;
    assign imem_resp_data_dbgrom  = dbgrom_data_d;
    assign imem_resp_pc_dbgrom    = dbgrom_pc_d;

    // D-access: valid when IRAM or DRAM was used by D-path last cycle (read or write)
    logic        dmem_resp_valid_tcm;
    logic [31:0] dmem_resp_data_tcm;
    assign dmem_resp_valid_tcm = iram_used_by_core_d_d | dram_used_by_core_d_d;
    // Data mux (for writes, callers ignore dmem_resp_data)
    assign dmem_resp_data_tcm  = iram_used_by_core_d_d ? iram_rdata : dram_rdata;

    // =========================================================================
    // Merged AXI master state machine
    // Arbitrates I-fetch AXI miss and D-path AXI miss onto the single m_axi bus.
    // D-bus has priority.  Both are stable during their miss (core stalls).
    // =========================================================================
    typedef enum logic [2:0] {
        BUS_IDLE = 3'h0,
        BUS_IAR  = 3'h1,  // I-fetch: AR phase
        BUS_IR   = 3'h2,  // I-fetch: R phase
        BUS_DAR  = 3'h3,  // D-read:  AR phase
        BUS_DR   = 3'h4,  // D-read:  R phase
        BUS_DAW  = 3'h5,  // D-write: AW+W phase (parallel)
        BUS_DB   = 3'h6   // D-write: B phase
    } bus_e;

    bus_e bus_state;
    logic dbus_aw_done, dbus_w_done;
    logic [31:0] ibus_addr_r;  // registered I-fetch address (stable during stall)
    logic [31:0] ibus_pc_r;    // registered I-fetch PC
    logic [31:0] dbus_addr_r;  // registered D-bus address
    logic [31:0] dbus_wdata_r;
    logic [ 3:0] dbus_wstrb_r;
    logic        dbus_write_r;

    // Register D/I miss addresses on first detection (before stall freezes them)
    // In practice the core already holds them stable during stall, but
    // registering ensures we hold them correctly across the state machine.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_state    <= BUS_IDLE;
            dbus_aw_done <= 1'b0;
            dbus_w_done  <= 1'b0;
            ibus_addr_r  <= BOOT_ADDR;
            ibus_pc_r    <= BOOT_ADDR;
            dbus_addr_r  <= '0;
            dbus_wdata_r <= '0;
            dbus_wstrb_r <= '0;
            dbus_write_r <= 1'b0;
        end
        else begin
            case (bus_state)
                BUS_IDLE: begin
                    if (core_d_axi) begin
                        // D-bus wins
                        dbus_addr_r  <= dmem_req_addr;
                        dbus_wdata_r <= dmem_req_wdata;
                        dbus_wstrb_r <= dmem_req_wstrb;
                        dbus_write_r <= dmem_req_write;
                        dbus_aw_done <= 1'b0;
                        dbus_w_done  <= 1'b0;
                        bus_state    <= dmem_req_write ? BUS_DAW : BUS_DAR;
                    end
                    else if (core_if_axi) begin
                        // I-fetch goes if D-bus is idle
                        ibus_addr_r <= imem_req_addr;
                        ibus_pc_r   <= imem_req_addr;
                        bus_state   <= BUS_IAR;
                    end
                end

                BUS_IAR: begin
                    if (m_axi_arready) bus_state <= BUS_IR;
                    // If D-bus miss arrives while I-fetch is pending, let it
                    // go after R completes (I-fetch is already in progress)
                end

                BUS_IR: begin
                    if (m_axi_rvalid) bus_state <= BUS_IDLE;
                    // After I-fetch completes, if D-bus miss is pending,
                    // BUS_IDLE picks it up next cycle
                end

                BUS_DAR: begin
                    if (m_axi_arready) bus_state <= BUS_DR;
                end

                BUS_DR: begin
                    if (m_axi_rvalid) bus_state <= BUS_IDLE;
                end

                BUS_DAW: begin
                    if (m_axi_awready) dbus_aw_done <= 1'b1;
                    if (m_axi_wready) dbus_w_done <= 1'b1;
                    if ((dbus_aw_done | m_axi_awready) && (dbus_w_done | m_axi_wready)) bus_state <= BUS_DB;
                end

                BUS_DB: begin
                    if (m_axi_bvalid) bus_state <= BUS_IDLE;
                end

                default: bus_state <= BUS_IDLE;
            endcase
        end
    end

    // AXI master outputs
    assign m_axi_araddr  = (bus_state == BUS_DAR || bus_state == BUS_DR) ? dbus_addr_r : ibus_addr_r;
    assign m_axi_arvalid = (bus_state == BUS_IAR) | (bus_state == BUS_DAR);
    assign m_axi_rready  = (bus_state == BUS_IR) | (bus_state == BUS_DR);

    assign m_axi_awaddr  = dbus_addr_r;
    assign m_axi_awvalid = (bus_state == BUS_DAW) & ~dbus_aw_done;
    assign m_axi_wdata   = dbus_wdata_r;
    assign m_axi_wstrb   = dbus_wstrb_r;
    assign m_axi_wvalid  = (bus_state == BUS_DAW) & ~dbus_w_done;
    assign m_axi_bready  = (bus_state == BUS_DB);

    // AXI responses back to core
    logic        imem_resp_valid_axi;
    logic [31:0] imem_resp_data_axi;
    logic [31:0] imem_resp_pc_axi;
    logic        dmem_resp_valid_axi;
    logic [31:0] dmem_resp_data_axi;

    assign imem_resp_valid_axi = (bus_state == BUS_IR) & m_axi_rvalid;
    assign imem_resp_data_axi  = m_axi_rdata;
    assign imem_resp_pc_axi    = ibus_pc_r;
    assign imem_resp_fault     = (bus_state == BUS_IR) & m_axi_rvalid & (m_axi_rresp != 2'b00);
    assign imem_resp_fault_pc  = ibus_pc_r;

    assign dmem_resp_valid_axi = ((bus_state == BUS_DR) & m_axi_rvalid) | ((bus_state == BUS_DB) & m_axi_bvalid);
    assign dmem_resp_data_axi  = m_axi_rdata;

    // Data memory AXI fault: DECERR on load (rresp) or store (bresp)
    logic dmem_resp_fault_axi;
    assign dmem_resp_fault_axi = ((bus_state == BUS_DR) & m_axi_rvalid & (m_axi_rresp != 2'b00))
                               | ((bus_state == BUS_DB) & m_axi_bvalid & (m_axi_bresp != 2'b00));

    // =========================================================================
    // Final response mux to core (TCM vs AXI)
    // =========================================================================
    assign imem_resp_valid = imem_resp_valid_tcm | imem_resp_valid_dbgrom | imem_resp_valid_axi;
    assign imem_resp_data  = imem_resp_valid_tcm   ? imem_resp_data_tcm   :
                             imem_resp_valid_dbgrom ? imem_resp_data_dbgrom :
                                                      imem_resp_data_axi;
    assign imem_resp_pc    = (imem_resp_valid_tcm    ? imem_resp_pc_tcm    :
                              imem_resp_valid_dbgrom ? imem_resp_pc_dbgrom  :
                                                       imem_resp_pc_axi) & ~32'h3;

    assign dmem_resp_valid = dmem_resp_valid_tcm | dmem_resp_valid_axi;
    assign dmem_resp_data = dmem_resp_valid_tcm ? dmem_resp_data_tcm : dmem_resp_data_axi;
    // Fault only possible on AXI path (TCM/DRAM never returns DECERR)
    assign dmem_resp_fault = dmem_resp_fault_axi;

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (bus_state == BUS_IDLE && core_d_axi && dmem_req_write)
            `DEBUG1(("[TOP] AXI WR latch: addr=0x%h data=0x%h strb=%b", dmem_req_addr, dmem_req_wdata, dmem_req_wstrb));
        if (m_axi_awvalid && m_axi_awready) `DEBUG1(("[TOP] AXI AW: addr=0x%h", m_axi_awaddr));
        if (m_axi_wvalid && m_axi_wready) `DEBUG1(("[TOP] AXI W:  data=0x%h", m_axi_wdata));
        if (m_axi_bvalid && m_axi_bready) `DEBUG1(("[TOP] AXI B:  done"));
        // Monitor DRAM writes to watch for stack corruption
        if (|dram_wbe)
            `DEBUG1(
                ("[TOP] DRAM WR: addr=0x%h data=0x%h strb=%b",
                (DRAM_BASE | 32'({dram_addr, 2'b00})), dram_wdata, dram_wbe));
        // Monitor DRAM reads - log address issued and, one cycle later, returned data
        if (core_d_dram_re) `DEBUG1(("[TOP] DRAM RD req: addr=0x%h", (DRAM_BASE | 32'({dram_addr, 2'b00}))));
        if (dram_used_by_core_d_d) `DEBUG1(("[TOP] DRAM RD rsp: data=0x%h", dram_rdata));
    end
`endif

endmodule
