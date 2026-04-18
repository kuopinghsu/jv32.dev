// ============================================================================
// File: jv32_soc.sv
// Project: JV32 RISC-V Processor
// Description: JV32 System-on-Chip Top Level
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
//  0x8000_0000  IRAM (TCM, inside jv32_top, 128 KB)  — I-fetch + data read
//  0xC000_0000  DRAM (TCM, inside jv32_top, 128 KB)  — data read/write
//  0x2001_0000  UART
//  0x0200_0000  CLIC / CLINT
//  0x4000_0000  Magic exit + MMIO
//
// TCM slave port (s_tcm_axi_*)
// -----------------------------
//  The jv32_top AXI slave is exposed as SoC-level ports so an external
//  debug master or the testbench can write to TCM at run-time.
//  For pre-simulation ELF loading, use the DPI mem_write_byte interface
//  (tb_jv32_soc.sv) which directly writes the SRAM arrays.
// ============================================================================

module jv32_soc #(
    parameter int unsigned        CLK_FREQ        = 100_000_000,
    parameter int unsigned        BAUD_RATE       = 115_200,
    parameter int unsigned        UART_FIFO_DEPTH = 16,          // TX/RX FIFO depth (power of 2)
    parameter bit                 USE_CJTAG       = 1'b0,        // 0=4-wire JTAG, 1=2-wire cJTAG
    parameter logic        [31:0] JTAG_IDCODE     = 32'h1DEAD3FF,
    parameter int unsigned        IRAM_SIZE       = 128 * 1024,  // bytes (128 KB)
    parameter int unsigned        DRAM_SIZE       = 128 * 1024,  // bytes (128 KB)
    parameter bit                 FAST_MUL        = 1'b1,
    parameter bit                 FAST_DIV        = 1'b0,
    parameter bit                 FAST_SHIFT      = 1'b1,
    parameter bit                 BP_EN           = 1'b1,
    parameter logic        [31:0] BOOT_ADDR       = 32'h8000_0000,
    parameter logic        [31:0] IRAM_BASE       = 32'h8000_0000,
    parameter logic        [31:0] DRAM_BASE       = 32'hC000_0000
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

    // AXI4-Lite Slave: external access to TCM (IRAM and DRAM)
    // Tie arvalid/awvalid/wvalid = 0 if no external master is used.
    input  logic [31:0] s_tcm_araddr,
    input  logic        s_tcm_arvalid,
    output logic        s_tcm_arready,
    output logic [31:0] s_tcm_rdata,
    output logic [ 1:0] s_tcm_rresp,
    output logic        s_tcm_rvalid,
    input  logic        s_tcm_rready,
    input  logic [31:0] s_tcm_awaddr,
    input  logic        s_tcm_awvalid,
    output logic        s_tcm_awready,
    input  logic [31:0] s_tcm_wdata,
    input  logic [ 3:0] s_tcm_wstrb,
    input  logic        s_tcm_wvalid,
    output logic        s_tcm_wready,
    output logic [ 1:0] s_tcm_bresp,
    output logic        s_tcm_bvalid,
    input  logic        s_tcm_bready,

    // Trace
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

    // =====================================================================
    // AXI bus between jv32_top master and xbar
    // =====================================================================
    logic [31:0] mbus_araddr;
    logic mbus_arvalid, mbus_arready;
    logic [31:0] mbus_rdata;
    logic [ 1:0] mbus_rresp;
    logic mbus_rvalid, mbus_rready;
    logic [31:0] mbus_awaddr;
    logic mbus_awvalid, mbus_awready;
    logic [31:0] mbus_wdata;
    logic [ 3:0] mbus_wstrb;
    logic mbus_wvalid, mbus_wready;
    logic [1:0] mbus_bresp;
    logic mbus_bvalid, mbus_bready;

    // IRQ interconnect
    logic timer_irq, software_irq, external_irq;
    logic clic_irq;
    logic [7:0] clic_level, clic_prio;
    logic [4:0] clic_id;
    logic       clic_ack;

    // =====================================================================
    // Debug / JTAG interconnect
    // =====================================================================
    logic dbg_halt_req, dbg_halted, dbg_resume_req, dbg_resumeack;
    logic [4:0] dbg_reg_addr;
    logic [31:0] dbg_reg_wdata, dbg_reg_rdata;
    logic dbg_reg_we;
    logic [31:0] dbg_pc_wdata, dbg_pc;
    logic dbg_pc_we;
    logic dbg_mem_req, dbg_mem_ready, dbg_mem_error;
    logic [31:0] dbg_mem_addr, dbg_mem_wdata, dbg_mem_rdata;
    logic [3:0] dbg_mem_we;
    logic dbg_ndmreset, dbg_hartreset;
    logic dbg_singlestep, dbg_ebreakm;
    logic [31:0] progbuf0, progbuf1;
    logic soc_rst_n;

    // Trigger interface wires (DTM ↔ core)
    localparam int N_TRIGGERS = 2;
    logic                  dbg_trigger_halt;
    logic [N_TRIGGERS-1:0] dbg_trigger_hit;  // per-trigger hit bits
    logic [N_TRIGGERS-1:0][31:0] dbg_tdata1, dbg_tdata2;

    // Internal AXI wires into the `jv32_top` TCM slave.
    logic [31:0] tcm_araddr_mux;
    logic tcm_arvalid_mux, tcm_arready_int;
    logic [31:0] tcm_rdata_int;
    logic [ 1:0] tcm_rresp_int;
    logic tcm_rvalid_int, tcm_rready_mux;
    logic [31:0] tcm_awaddr_mux;
    logic tcm_awvalid_mux, tcm_awready_int;
    logic [31:0] tcm_wdata_mux;
    logic [ 3:0] tcm_wstrb_mux;
    logic tcm_wvalid_mux, tcm_wready_int;
    logic [1:0] tcm_bresp_int;
    logic tcm_bvalid_int, tcm_bready_mux;

    typedef enum logic [2:0] {
        DBG_TCM_IDLE,
        DBG_TCM_RD_ADDR,
        DBG_TCM_RD_RESP,
        DBG_TCM_WR_REQ,
        DBG_TCM_WR_RESP
    } dbg_tcm_state_e;

    dbg_tcm_state_e dbg_tcm_state;
    logic           dbg_tcm_select;
    logic           dbg_mem_req_d;
    logic dbg_aw_done, dbg_w_done;
    logic [31:0] dbg_addr_r, dbg_wdata_r;
    logic [3:0] dbg_wstrb_r;

    assign soc_rst_n      = rst_n & ~dbg_ndmreset;
    assign dbg_tcm_select = (dbg_tcm_state != DBG_TCM_IDLE);
    assign dbg_mem_error  = 1'b0;  // TCM bridge does not generate AXI bus errors

    // JTAG top-level interface + RISC-V debug transport module
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
        .trigger_halt_i  (dbg_trigger_halt),
        .trigger_hit_i   (dbg_trigger_hit),
        .tdata1_o        (dbg_tdata1),
        .tdata2_o        (dbg_tdata2)
    );

    // Pass the external TCM AXI master through unless the JTAG DM is actively
    // performing a debug memory access. The bridge is single-beat and targets
    // the existing TCM slave path, which is sufficient for halted-memory debug.
    assign tcm_araddr_mux  = dbg_tcm_select ? dbg_addr_r : s_tcm_araddr;
    assign tcm_arvalid_mux = dbg_tcm_select ? (dbg_tcm_state == DBG_TCM_RD_ADDR) : s_tcm_arvalid;
    assign tcm_rready_mux  = dbg_tcm_select ? (dbg_tcm_state == DBG_TCM_RD_RESP) : s_tcm_rready;
    assign tcm_awaddr_mux  = dbg_tcm_select ? dbg_addr_r : s_tcm_awaddr;
    assign tcm_awvalid_mux = dbg_tcm_select ? ((dbg_tcm_state == DBG_TCM_WR_REQ) && !dbg_aw_done) : s_tcm_awvalid;
    assign tcm_wdata_mux   = dbg_tcm_select ? dbg_wdata_r : s_tcm_wdata;
    assign tcm_wstrb_mux   = dbg_tcm_select ? dbg_wstrb_r : s_tcm_wstrb;
    assign tcm_wvalid_mux  = dbg_tcm_select ? ((dbg_tcm_state == DBG_TCM_WR_REQ) && !dbg_w_done) : s_tcm_wvalid;
    assign tcm_bready_mux  = dbg_tcm_select ? (dbg_tcm_state == DBG_TCM_WR_RESP) : s_tcm_bready;

    assign s_tcm_arready   = dbg_tcm_select ? 1'b0 : tcm_arready_int;
    assign s_tcm_rdata     = dbg_tcm_select ? 32'h0 : tcm_rdata_int;
    assign s_tcm_rresp     = dbg_tcm_select ? 2'b00 : tcm_rresp_int;
    assign s_tcm_rvalid    = dbg_tcm_select ? 1'b0 : tcm_rvalid_int;
    assign s_tcm_awready   = dbg_tcm_select ? 1'b0 : tcm_awready_int;
    assign s_tcm_wready    = dbg_tcm_select ? 1'b0 : tcm_wready_int;
    assign s_tcm_bresp     = dbg_tcm_select ? 2'b00 : tcm_bresp_int;
    assign s_tcm_bvalid    = dbg_tcm_select ? 1'b0 : tcm_bvalid_int;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbg_tcm_state <= DBG_TCM_IDLE;
            dbg_mem_req_d <= 1'b0;
            dbg_aw_done   <= 1'b0;
            dbg_w_done    <= 1'b0;
            dbg_addr_r    <= 32'h0;
            dbg_wdata_r   <= 32'h0;
            dbg_wstrb_r   <= 4'h0;
            dbg_mem_ready <= 1'b0;
            dbg_mem_rdata <= 32'h0;
        end
        else begin
            dbg_mem_req_d <= dbg_mem_req;
            dbg_mem_ready <= 1'b0;

            case (dbg_tcm_state)
                DBG_TCM_IDLE: begin
                    dbg_aw_done <= 1'b0;
                    dbg_w_done  <= 1'b0;
                    if (dbg_mem_req && !dbg_mem_req_d) begin
                        dbg_addr_r    <= dbg_mem_addr;
                        dbg_wdata_r   <= dbg_mem_wdata;
                        dbg_wstrb_r   <= dbg_mem_we;
                        dbg_tcm_state <= (dbg_mem_we == 4'b0000) ? DBG_TCM_RD_ADDR : DBG_TCM_WR_REQ;
                    end
                end

                DBG_TCM_RD_ADDR: begin
                    if (tcm_arready_int) dbg_tcm_state <= DBG_TCM_RD_RESP;
                end

                DBG_TCM_RD_RESP: begin
                    if (tcm_rvalid_int) begin
                        dbg_mem_rdata <= tcm_rdata_int;
                        dbg_mem_ready <= 1'b1;
                        dbg_tcm_state <= DBG_TCM_IDLE;
                    end
                end

                DBG_TCM_WR_REQ: begin
                    if (tcm_awready_int) dbg_aw_done <= 1'b1;
                    if (tcm_wready_int) dbg_w_done <= 1'b1;
                    if ((dbg_aw_done || tcm_awready_int) && (dbg_w_done || tcm_wready_int))
                        dbg_tcm_state <= DBG_TCM_WR_RESP;
                end

                DBG_TCM_WR_RESP: begin
                    if (tcm_bvalid_int) begin
                        dbg_mem_ready <= 1'b1;
                        dbg_tcm_state <= DBG_TCM_IDLE;
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
        .FAST_MUL  (FAST_MUL),
        .FAST_DIV  (FAST_DIV),
        .FAST_SHIFT(FAST_SHIFT),
        .BP_EN     (BP_EN),
        .IRAM_SIZE (IRAM_SIZE),
        .DRAM_SIZE (DRAM_SIZE),
        .BOOT_ADDR (BOOT_ADDR),
        .DRAM_BASE (DRAM_BASE)
    ) u_jv32 (
        .clk          (clk),
        .rst_n        (soc_rst_n),
        // Merged AXI master → peripheral xbar
        .m_axi_araddr (mbus_araddr),
        .m_axi_arvalid(mbus_arvalid),
        .m_axi_arready(mbus_arready),
        .m_axi_rdata  (mbus_rdata),
        .m_axi_rresp  (mbus_rresp),
        .m_axi_rvalid (mbus_rvalid),
        .m_axi_rready (mbus_rready),
        .m_axi_awaddr (mbus_awaddr),
        .m_axi_awvalid(mbus_awvalid),
        .m_axi_awready(mbus_awready),
        .m_axi_wdata  (mbus_wdata),
        .m_axi_wstrb  (mbus_wstrb),
        .m_axi_wvalid (mbus_wvalid),
        .m_axi_wready (mbus_wready),
        .m_axi_bresp  (mbus_bresp),
        .m_axi_bvalid (mbus_bvalid),
        .m_axi_bready (mbus_bready),

        // TCM slave port (external master or internal JTAG debug bridge)
        .s_axi_araddr (tcm_araddr_mux),
        .s_axi_arvalid(tcm_arvalid_mux),
        .s_axi_arready(tcm_arready_int),
        .s_axi_rdata  (tcm_rdata_int),
        .s_axi_rresp  (tcm_rresp_int),
        .s_axi_rvalid (tcm_rvalid_int),
        .s_axi_rready (tcm_rready_mux),
        .s_axi_awaddr (tcm_awaddr_mux),
        .s_axi_awvalid(tcm_awvalid_mux),
        .s_axi_awready(tcm_awready_int),
        .s_axi_wdata  (tcm_wdata_mux),
        .s_axi_wstrb  (tcm_wstrb_mux),
        .s_axi_wvalid (tcm_wvalid_mux),
        .s_axi_wready (tcm_wready_int),
        .s_axi_bresp  (tcm_bresp_int),
        .s_axi_bvalid (tcm_bvalid_int),
        .s_axi_bready (tcm_bready_mux),

        // Interrupts
        .timer_irq         (timer_irq),
        .software_irq      (software_irq),
        .external_irq      (external_irq),
        .clic_irq          (clic_irq),
        .clic_level        (clic_level),
        .clic_prio         (clic_prio),
        .clic_id           (clic_id),
        .clic_ack          (clic_ack),
        // Debug sideband from the JTAG DM
        .dbg_hartreset_i   (dbg_hartreset),
        .dbg_halt_req_i    (dbg_halt_req),
        .dbg_halted_o      (dbg_halted),
        .dbg_resume_req_i  (dbg_resume_req),
        .dbg_resumeack_o   (dbg_resumeack),
        .dbg_reg_addr_i    (dbg_reg_addr),
        .dbg_reg_wdata_i   (dbg_reg_wdata),
        .dbg_reg_we_i      (dbg_reg_we),
        .dbg_reg_rdata_o   (dbg_reg_rdata),
        .dbg_pc_wdata_i    (dbg_pc_wdata),
        .dbg_pc_we_i       (dbg_pc_we),
        .dbg_pc_o          (dbg_pc),
        .dbg_singlestep_i  (dbg_singlestep),
        .dbg_ebreakm_i     (dbg_ebreakm),
        .progbuf0_i        (progbuf0),
        .progbuf1_i        (progbuf1),
        // Trigger interface
        .dbg_trigger_halt_o(dbg_trigger_halt),
        .dbg_trigger_hit_o (dbg_trigger_hit),
        .dbg_tdata1_i      (dbg_tdata1),
        .dbg_tdata2_i      (dbg_tdata2),
        // Trace
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

    // =====================================================================
    // AXI crossbar: 1 master → 3 peripheral slaves
    //   Slave 0: UART   @ 0x2001_0000  mask 0xFFFF_FF00 (256 B)
    //   Slave 1: CLIC   @ 0x0200_0000  mask 0xFFE0_0000 (2 MB)
    //   Slave 2: Magic  @ 0x4000_0000  mask 0xF000_0000 (256 MB)
    // =====================================================================
    localparam logic [31:0] XBAR_BASE[3] = '{32'h2001_0000, 32'h0200_0000, 32'h4000_0000};
    localparam logic [31:0] XBAR_MASK[3] = '{32'hFFFF_FF00, 32'hFFE0_0000, 32'hF000_0000};

    logic [2:0][31:0] xs_awaddr;
    logic [2:0]       xs_awvalid;
    logic [2:0]       xs_awready;
    logic [2:0][31:0] xs_wdata;
    logic [2:0][ 3:0] xs_wstrb;
    logic [2:0]       xs_wvalid;
    logic [2:0]       xs_wready;
    logic [2:0][ 1:0] xs_bresp;
    logic [2:0]       xs_bvalid;
    logic [2:0]       xs_bready;
    logic [2:0][31:0] xs_araddr;
    logic [2:0]       xs_arvalid;
    logic [2:0]       xs_arready;
    logic [2:0][31:0] xs_rdata;
    logic [2:0][ 1:0] xs_rresp;
    logic [2:0]       xs_rvalid;
    logic [2:0]       xs_rready;

    axi_xbar #(
        .N_SLAVES  (3),
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

    // =====================================================================
    // UART — slave 0
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
        .irq        ()
    );

    // =====================================================================
    // CLIC / CLINT — slave 1
    // =====================================================================
    axi_clic #(
        .CLK_FREQ(CLK_FREQ)
    ) u_clic (
        .clk           (clk),
        .rst_n         (soc_rst_n),
        .instret_inc   (trace_valid),
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
        .ext_irq_i     (ext_irq_i),
        .timer_irq_o   (timer_irq),
        .software_irq_o(software_irq),
        .clic_irq_o    (clic_irq),
        .clic_level_o  (clic_level),
        .clic_prio_o   (clic_prio),
        .clic_id_o     (clic_id)
    );
    assign external_irq = clic_irq;

    // =====================================================================
    // Magic — slave 2
    // =====================================================================
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

    // CLIC ack unused (CLINT-style polling, no ack needed)
    logic _unused;
    assign _unused = &{1'b0, clic_ack};

endmodule
