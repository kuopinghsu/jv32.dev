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

`ifdef SYNTHESIS
import jv32_pkg::*;
import axi_pkg::*;
`endif

module jv32_top #(
    parameter bit          FAST_MUL   = 1'b1,
    parameter bit          FAST_DIV   = 1'b1,
    parameter bit          FAST_SHIFT = 1'b1,
    parameter bit          BP_EN      = 1'b1,
    parameter int unsigned IRAM_SIZE  = 65536,       // bytes, power-of-2
    parameter int unsigned DRAM_SIZE  = 65536,       // bytes, power-of-2
    parameter logic [31:0] BOOT_ADDR  = 32'h8000_0000,
    parameter logic [31:0] DRAM_BASE  = 32'hC000_0000
) (
    input  logic        clk,
    input  logic        rst_n,

    // =========================================================================
    // AXI4-Lite Master — merged I+D bus for out-of-TCM accesses (D-bus priority)
    // =========================================================================
    output logic [31:0] m_axi_araddr,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    input  logic [31:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,

    output logic [31:0] m_axi_awaddr,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [31:0] m_axi_wdata,
    output logic [3:0]  m_axi_wstrb,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,

    // =========================================================================
    // AXI4-Lite Slave — external access to TCM (core has priority)
    // =========================================================================
    input  logic [31:0] s_axi_araddr,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    input  logic [31:0] s_axi_awaddr,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,

    // =========================================================================
    // Interrupts
    // =========================================================================
    input  logic        timer_irq,
    input  logic        external_irq,
    input  logic        software_irq,
    input  logic        clic_irq,
    input  logic [7:0]  clic_level,
    input  logic [7:0]  clic_prio,
    input  logic [31:0] clic_vector_pc,
    output logic        clic_ack,

    // =========================================================================
    // Trace
    // =========================================================================
    output logic        trace_valid,
    output logic [31:0] trace_pc,
    output logic [4:0]  trace_rd,
    output logic [31:0] trace_rd_data
);
`ifndef SYNTHESIS
    import jv32_pkg::*;
    import axi_pkg::*;
`endif

    // =========================================================================
    // TCM parameters
    // =========================================================================
    localparam int unsigned IRAM_DEPTH = IRAM_SIZE / 4;
    localparam int unsigned DRAM_DEPTH = DRAM_SIZE / 4;
    localparam int unsigned IRAM_ABITS = $clog2(IRAM_DEPTH);
    localparam int unsigned DRAM_ABITS = $clog2(DRAM_DEPTH);

    // Address decode: power-of-2 regions
    function automatic logic in_iram(input logic [31:0] addr);
        return (addr & ~(32'(IRAM_SIZE) - 32'h1)) == (BOOT_ADDR & ~(32'(IRAM_SIZE) - 32'h1));
    endfunction
    function automatic logic in_dram(input logic [31:0] addr);
        return (addr & ~(32'(DRAM_SIZE) - 32'h1)) == (DRAM_BASE & ~(32'(DRAM_SIZE) - 32'h1));
    endfunction
    function automatic logic in_tcm(input logic [31:0] addr);
        return in_iram(addr) | in_dram(addr);
    endfunction

    // =========================================================================
    // Core memory interface
    // =========================================================================
    logic        imem_req_valid;
    logic [31:0] imem_req_addr;
    logic        imem_resp_valid;
    logic [31:0] imem_resp_data;
    logic [31:0] imem_resp_pc;
    logic        imem_flush_core;   // rvc_flush from core

    logic        dmem_req_valid;
    logic        dmem_req_write;
    logic [31:0] dmem_req_addr;
    logic [31:0] dmem_req_wdata;
    logic [3:0]  dmem_req_wstrb;
    logic        dmem_resp_valid;
    logic [31:0] dmem_resp_data;

    jv32_core #(
        .FAST_MUL   (FAST_MUL),
        .FAST_DIV   (FAST_DIV),
        .FAST_SHIFT (FAST_SHIFT),
        .BP_EN      (BP_EN),
        .BOOT_ADDR  (BOOT_ADDR)
    ) u_core (
        .clk             (clk),
        .rst_n           (rst_n),
        .imem_req_valid  (imem_req_valid),
        .imem_req_addr   (imem_req_addr),
        .imem_resp_valid (imem_resp_valid),
        .imem_resp_data  (imem_resp_data),
        .imem_resp_pc    (imem_resp_pc),
        .imem_flush      (imem_flush_core),
        .dmem_req_valid  (dmem_req_valid),
        .dmem_req_write  (dmem_req_write),
        .dmem_req_addr   (dmem_req_addr),
        .dmem_req_wdata  (dmem_req_wdata),
        .dmem_req_wstrb  (dmem_req_wstrb),
        .dmem_resp_valid (dmem_resp_valid),
        .dmem_resp_data  (dmem_resp_data),
        .timer_irq       (timer_irq),
        .external_irq    (external_irq),
        .software_irq    (software_irq),
        .clic_irq        (clic_irq),
        .clic_level      (clic_level),
        .clic_prio       (clic_prio),
        .clic_vector_pc  (clic_vector_pc),
        .clic_ack        (clic_ack),
        .trace_valid     (trace_valid),
        .trace_pc        (trace_pc),
        .trace_rd        (trace_rd),
        .trace_rd_data   (trace_rd_data)
    );

    // =========================================================================
    // SRAM instances: 4 byte-banks each for IRAM and DRAM
    // Naming conventions chosen for DPI mem_write_byte hierarchical access:
    //   gen_iram_byte[b].u_sram.mem[word_index]
    //   gen_dram_byte[b].u_sram.mem[word_index]
    // =========================================================================
    logic [IRAM_ABITS-1:0] iram_addr;
    logic [3:0]            iram_we;
    logic [31:0]           iram_wdata;
    logic [31:0]           iram_rdata;

    genvar b;
    generate
        for (b = 0; b < 4; b++) begin : gen_iram_byte
            sram_1rw #(.DEPTH(IRAM_DEPTH), .WIDTH(8)) u_sram (
                .clk   (clk),
                .ce    (1'b1),
                .we    (iram_we[b]),
                .addr  (iram_addr),
                .wdata (iram_wdata[b*8 +: 8]),
                .rdata (iram_rdata[b*8 +: 8])
            );
        end
    endgenerate

    logic [DRAM_ABITS-1:0] dram_addr;
    logic [3:0]            dram_we;
    logic [31:0]           dram_wdata;
    logic [31:0]           dram_rdata;

    generate
        for (b = 0; b < 4; b++) begin : gen_dram_byte
            sram_1rw #(.DEPTH(DRAM_DEPTH), .WIDTH(8)) u_sram (
                .clk   (clk),
                .ce    (1'b1),
                .we    (dram_we[b]),
                .addr  (dram_addr),
                .wdata (dram_wdata[b*8 +: 8]),
                .rdata (dram_rdata[b*8 +: 8])
            );
        end
    endgenerate

    // =========================================================================
    // Core requests hitting TCM vs. missing to AXI
    // =========================================================================
    // I-path: always fetching (imem_req_valid=1), but only IRAM is TCM for I
    logic core_if_iram;       // I-fetch hits IRAM
    logic core_if_axi;        // I-fetch misses TCM → needs AXI

    // D-path
    logic core_d_iram_re;     // D-read inside IRAM
    logic core_d_iram_we;     // D-write inside IRAM
    logic core_d_dram_re;     // D-read inside DRAM
    logic core_d_dram_we;     // D-write inside DRAM
    logic core_d_axi;         // D-access misses TCM → needs AXI

    assign core_if_iram   = in_iram(imem_req_addr);
    assign core_if_axi    = !core_if_iram;           // imem_req_valid always 1
    assign core_d_iram_re = dmem_req_valid & ~dmem_req_write & in_iram(dmem_req_addr);
    assign core_d_iram_we = dmem_req_valid &  dmem_req_write & in_iram(dmem_req_addr);
    assign core_d_dram_re = dmem_req_valid & ~dmem_req_write & in_dram(dmem_req_addr);
    assign core_d_dram_we = dmem_req_valid &  dmem_req_write & in_dram(dmem_req_addr);
    assign core_d_axi     = dmem_req_valid & ~in_tcm(dmem_req_addr);

    // =========================================================================
    // Slave state machine (external TCM access, core has priority)
    // =========================================================================
    typedef enum logic [2:0] {
        SLV_IDLE,       // idle
        SLV_RD_WAIT,    // have AR addr, waiting for SRAM grant
        SLV_RD_RESP,    // SRAM response cycle: drive rvalid
        SLV_WR_DATA,    // AW received, waiting for W channel
        SLV_WR_WAIT,    // have AW+W, waiting for SRAM grant
        SLV_WR_RESP     // write accepted, drive bvalid
    } slv_e;

    slv_e        slv_state;
    logic [31:0] slv_addr;    // latched AW/AR address
    logic [31:0] slv_wdata;   // latched W data
    logic [3:0]  slv_wstrb;   // latched W strb
    logic        slv_is_iram; // whether slv_addr targets IRAM
    logic [31:0] slv_rdata_r; // held read data (slave might need >1 cycle rready)
    logic        slv_rd_first; // first cycle of SLV_RD_RESP (fresh SRAM output)

    // Slave SRAM request signals (combinatorial, used by mux below)
    logic slave_wants_iram;
    logic slave_wants_dram;
    logic slave_iram_is_wr;   // slave wants to WRITE to IRAM
    logic slave_dram_is_wr;   // slave wants to WRITE to DRAM

    assign slave_wants_iram = (slv_state == SLV_RD_WAIT | slv_state == SLV_WR_WAIT) &  slv_is_iram;
    assign slave_wants_dram = (slv_state == SLV_RD_WAIT | slv_state == SLV_WR_WAIT) & ~slv_is_iram;
    assign slave_iram_is_wr = (slv_state == SLV_WR_WAIT) &  slv_is_iram;
    assign slave_dram_is_wr = (slv_state == SLV_WR_WAIT) & ~slv_is_iram;

    // Grant: core does not need that SRAM this cycle
    logic slave_iram_grant;
    logic slave_dram_grant;
    assign slave_iram_grant = slave_wants_iram
                              & ~(core_if_iram | core_d_iram_re | core_d_iram_we);
    assign slave_dram_grant = slave_wants_dram
                              & ~(core_d_dram_re | core_d_dram_we);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slv_state    <= SLV_IDLE;
            slv_addr     <= '0;
            slv_wdata    <= '0;
            slv_wstrb    <= '0;
            slv_is_iram  <= 1'b0;
            slv_rdata_r  <= '0;
            slv_rd_first <= 1'b0;
        end else begin
            slv_rd_first <= 1'b0; // pulse

            case (slv_state)
                SLV_IDLE: begin
                    if (s_axi_arvalid) begin
                        slv_addr    <= s_axi_araddr;
                        slv_is_iram <= in_iram(s_axi_araddr);
                        slv_state   <= SLV_RD_WAIT;
                    end else if (s_axi_awvalid) begin
                        slv_addr    <= s_axi_awaddr;
                        slv_is_iram <= in_iram(s_axi_awaddr);
                        slv_state   <= SLV_WR_DATA;
                    end
                end

                SLV_RD_WAIT: begin
                    // When granted: SRAM addr was driven this cycle → data valid next cycle
                    if (slave_iram_grant | slave_dram_grant) begin
                        slv_state    <= SLV_RD_RESP;
                        slv_rd_first <= 1'b1; // next cycle: capture SRAM output
                    end
                end

                SLV_RD_RESP: begin
                    // Latch rdata on first cycle (before core may overwrite SRAM output)
                    if (slv_rd_first)
                        slv_rdata_r <= slv_is_iram ? iram_rdata : dram_rdata;
                    if (s_axi_rready)
                        slv_state <= SLV_IDLE;
                end

                SLV_WR_DATA: begin
                    if (s_axi_wvalid) begin
                        slv_wdata <= s_axi_wdata;
                        slv_wstrb <= s_axi_wstrb;
                        slv_state <= SLV_WR_WAIT;
                    end
                end

                SLV_WR_WAIT: begin
                    // When granted: write happens this cycle (SRAM clocked at end)
                    if (slave_iram_grant | slave_dram_grant)
                        slv_state <= SLV_WR_RESP;
                end

                SLV_WR_RESP: begin
                    if (s_axi_bready)
                        slv_state <= SLV_IDLE;
                end

                default: slv_state <= SLV_IDLE;
            endcase
        end
    end

    // Slave AXI outputs
    assign s_axi_arready = (slv_state == SLV_IDLE) & ~s_axi_awvalid; // prefer AR
    assign s_axi_awready = (slv_state == SLV_IDLE) & ~s_axi_arvalid;
    assign s_axi_wready  = (slv_state == SLV_WR_DATA);
    assign s_axi_rvalid  = (slv_state == SLV_RD_RESP);
    assign s_axi_rdata   = slv_rd_first ? (slv_is_iram ? iram_rdata : dram_rdata)
                                        : slv_rdata_r;
    assign s_axi_rresp   = 2'b00; // OKAY
    assign s_axi_bvalid  = (slv_state == SLV_WR_RESP);
    assign s_axi_bresp   = 2'b00; // OKAY

    // =========================================================================
    // SRAM mux: Core-D > Core-I > Slave  (combinatorial)
    // =========================================================================
    always_comb begin
        // IRAM: D-path > I-path > Slave
        if (core_d_iram_re | core_d_iram_we) begin
            iram_addr  = dmem_req_addr[IRAM_ABITS+1:2];
            iram_we    = core_d_iram_we ? dmem_req_wstrb : 4'h0;
            iram_wdata = dmem_req_wdata;
        end else if (core_if_iram) begin
            iram_addr  = imem_req_addr[IRAM_ABITS+1:2];
            iram_we    = 4'h0;
            iram_wdata = 32'h0;
        end else if (slave_iram_grant) begin
            iram_addr  = slv_addr[IRAM_ABITS+1:2];
            iram_we    = slave_iram_is_wr ? slv_wstrb : 4'h0;
            iram_wdata = slv_wdata;
        end else begin
            iram_addr  = imem_req_addr[IRAM_ABITS+1:2]; // default: I-fetch reads
            iram_we    = 4'h0;
            iram_wdata = 32'h0;
        end

        // DRAM: D-path > Slave
        if (core_d_dram_re | core_d_dram_we) begin
            dram_addr  = dmem_req_addr[DRAM_ABITS+1:2];
            dram_we    = core_d_dram_we ? dmem_req_wstrb : 4'h0;
            dram_wdata = dmem_req_wdata;
        end else if (slave_dram_grant) begin
            dram_addr  = slv_addr[DRAM_ABITS+1:2];
            dram_we    = slave_dram_is_wr ? slv_wstrb : 4'h0;
            dram_wdata = slv_wdata;
        end else begin
            dram_addr  = dmem_req_addr[DRAM_ABITS+1:2]; // default: read-ahead harmless
            dram_we    = 4'h0;
            dram_wdata = 32'h0;
        end
    end

    // =========================================================================
    // TCM response tracking (1-cycle registered SRAM latency)
    // =========================================================================
    // Track whose data is valid on iram_rdata / dram_rdata each cycle
    logic iram_used_by_core_i_d;  // IRAM was accessed by I-fetch last cycle
    logic iram_used_by_core_d_d;  // IRAM was accessed by D-path last cycle
    logic dram_used_by_core_d_d;  // DRAM was accessed by D-path last cycle
    logic dmem_was_write_d;        // D-path access last cycle was a write
    logic imem_flush_d;            // flush was asserted last cycle
    logic [31:0] imem_req_addr_d;  // I-fetch address from last cycle (for resp_pc)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            iram_used_by_core_i_d <= 1'b0;
            iram_used_by_core_d_d <= 1'b0;
            dram_used_by_core_d_d <= 1'b0;
            dmem_was_write_d      <= 1'b0;
            imem_flush_d          <= 1'b0;
            imem_req_addr_d       <= BOOT_ADDR;
        end else begin
            // Core I-fetch used IRAM this cycle (D-path didn't steal it)
            iram_used_by_core_i_d <= core_if_iram
                                     & ~(core_d_iram_re | core_d_iram_we);
            // Core D-path used IRAM this cycle
            iram_used_by_core_d_d <= core_d_iram_re | core_d_iram_we;
            // Core D-path used DRAM this cycle
            dram_used_by_core_d_d <= core_d_dram_re | core_d_dram_we;
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
        BUS_IDLE    = 3'h0,
        BUS_IAR     = 3'h1,   // I-fetch: AR phase
        BUS_IR      = 3'h2,   // I-fetch: R phase
        BUS_DAR     = 3'h3,   // D-read:  AR phase
        BUS_DR      = 3'h4,   // D-read:  R phase
        BUS_DAW     = 3'h5,   // D-write: AW+W phase (parallel)
        BUS_DB      = 3'h6    // D-write: B phase
    } bus_e;

    bus_e        bus_state;
    logic        dbus_aw_done, dbus_w_done;
    logic [31:0] ibus_addr_r;   // registered I-fetch address (stable during stall)
    logic [31:0] ibus_pc_r;     // registered I-fetch PC
    logic [31:0] dbus_addr_r;   // registered D-bus address
    logic [31:0] dbus_wdata_r;
    logic [3:0]  dbus_wstrb_r;
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
        end else begin
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
                    end else if (core_if_axi) begin
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
                    if (m_axi_wready)  dbus_w_done  <= 1'b1;
                    if ((dbus_aw_done | m_axi_awready) && (dbus_w_done | m_axi_wready))
                        bus_state <= BUS_DB;
                end

                BUS_DB: begin
                    if (m_axi_bvalid) bus_state <= BUS_IDLE;
                end

                default: bus_state <= BUS_IDLE;
            endcase
        end
    end

    // AXI master outputs
    assign m_axi_araddr  = (bus_state == BUS_DAR || bus_state == BUS_DR) ? dbus_addr_r
                                                                           : ibus_addr_r;
    assign m_axi_arvalid = (bus_state == BUS_IAR) | (bus_state == BUS_DAR);
    assign m_axi_rready  = (bus_state == BUS_IR)  | (bus_state == BUS_DR);

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

    assign dmem_resp_valid_axi = ((bus_state == BUS_DR) & m_axi_rvalid)
                               | ((bus_state == BUS_DB) & m_axi_bvalid);
    assign dmem_resp_data_axi  = m_axi_rdata;

    // =========================================================================
    // Final response mux to core (TCM vs AXI)
    // =========================================================================
    assign imem_resp_valid = imem_resp_valid_tcm | imem_resp_valid_axi;
    assign imem_resp_data  = imem_resp_valid_tcm ? imem_resp_data_tcm : imem_resp_data_axi;
    assign imem_resp_pc    = imem_resp_valid_tcm ? imem_resp_pc_tcm   : imem_resp_pc_axi;

    assign dmem_resp_valid = dmem_resp_valid_tcm | dmem_resp_valid_axi;
    assign dmem_resp_data  = dmem_resp_valid_tcm ? dmem_resp_data_tcm : dmem_resp_data_axi;

endmodule
