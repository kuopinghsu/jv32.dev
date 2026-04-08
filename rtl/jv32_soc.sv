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
//  0x8000_0000  IRAM (TCM, inside jv32_top, 64 KB)  — I-fetch + data read
//  0xC000_0000  DRAM (TCM, inside jv32_top, 64 KB)  — data read/write
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

`ifdef SYNTHESIS
import jv32_pkg::*;
`endif

module jv32_soc #(
    parameter int unsigned CLK_FREQ       = 100_000_000,
    parameter int unsigned BAUD_RATE      = 115_200,
    parameter int unsigned UART_FIFO_DEPTH = 16,        // TX/RX FIFO depth (power of 2)
    parameter int unsigned IRAM_SIZE      = 65536,      // bytes
    parameter int unsigned DRAM_SIZE      = 65536,      // bytes
    parameter bit          FAST_MUL    = 1'b1,
    parameter bit          FAST_DIV    = 1'b1,
    parameter bit          FAST_SHIFT  = 1'b1,
    parameter bit          BP_EN       = 1'b1,
    parameter logic [31:0] BOOT_ADDR   = 32'h8000_0000,
    parameter logic [31:0] DRAM_BASE   = 32'hC000_0000
) (
    input  logic        clk,
    input  logic        rst_n,

    // UART
    input  logic        uart_rx_i,
    output logic        uart_tx_o,

    // External IRQ
    input  logic [15:0] ext_irq_i,

    // AXI4-Lite Slave: external access to TCM (IRAM and DRAM)
    // Tie arvalid/awvalid/wvalid = 0 if no external master is used.
    input  logic [31:0] s_tcm_araddr,
    input  logic        s_tcm_arvalid,
    output logic        s_tcm_arready,
    output logic [31:0] s_tcm_rdata,
    output logic [1:0]  s_tcm_rresp,
    output logic        s_tcm_rvalid,
    input  logic        s_tcm_rready,
    input  logic [31:0] s_tcm_awaddr,
    input  logic        s_tcm_awvalid,
    output logic        s_tcm_awready,
    input  logic [31:0] s_tcm_wdata,
    input  logic [3:0]  s_tcm_wstrb,
    input  logic        s_tcm_wvalid,
    output logic        s_tcm_wready,
    output logic [1:0]  s_tcm_bresp,
    output logic        s_tcm_bvalid,
    input  logic        s_tcm_bready,

    // Trace
    output logic        trace_valid,
    output logic        trace_reg_we,
    output logic [31:0] trace_pc,
    output logic [4:0]  trace_rd,
    output logic [31:0] trace_rd_data,
    output logic [31:0] trace_instr,
    output logic        trace_mem_we,    output logic        trace_mem_re,    output logic [31:0] trace_mem_addr,
    output logic [31:0] trace_mem_data
);
`ifndef SYNTHESIS
    import jv32_pkg::*;
`endif

    // =====================================================================
    // AXI bus between jv32_top master and xbar
    // =====================================================================
    logic [31:0] mbus_araddr;  logic mbus_arvalid, mbus_arready;
    logic [31:0] mbus_rdata;   logic [1:0] mbus_rresp;
    logic        mbus_rvalid,  mbus_rready;
    logic [31:0] mbus_awaddr;  logic mbus_awvalid, mbus_awready;
    logic [31:0] mbus_wdata;   logic [3:0] mbus_wstrb;
    logic        mbus_wvalid,  mbus_wready;
    logic [1:0]  mbus_bresp;   logic mbus_bvalid, mbus_bready;

    // IRQ interconnect
    logic        timer_irq, software_irq, external_irq;
    logic        clic_irq;
    logic [7:0]  clic_level, clic_prio;
    logic [4:0]  clic_id;
    logic        clic_ack;

    // =====================================================================
    // JV32 Core + TCM
    // =====================================================================
    jv32_top #(
        .FAST_MUL   (FAST_MUL),
        .FAST_DIV   (FAST_DIV),
        .FAST_SHIFT (FAST_SHIFT),
        .BP_EN      (BP_EN),
        .IRAM_SIZE  (IRAM_SIZE),
        .DRAM_SIZE  (DRAM_SIZE),
        .BOOT_ADDR  (BOOT_ADDR),
        .DRAM_BASE  (DRAM_BASE)
    ) u_jv32 (
        .clk              (clk),
        .rst_n            (rst_n),
        // Merged AXI master → peripheral xbar
        .m_axi_araddr     (mbus_araddr),
        .m_axi_arvalid    (mbus_arvalid),
        .m_axi_arready    (mbus_arready),
        .m_axi_rdata      (mbus_rdata),
        .m_axi_rresp      (mbus_rresp),
        .m_axi_rvalid     (mbus_rvalid),
        .m_axi_rready     (mbus_rready),
        .m_axi_awaddr     (mbus_awaddr),
        .m_axi_awvalid    (mbus_awvalid),
        .m_axi_awready    (mbus_awready),
        .m_axi_wdata      (mbus_wdata),
        .m_axi_wstrb      (mbus_wstrb),
        .m_axi_wvalid     (mbus_wvalid),
        .m_axi_wready     (mbus_wready),
        .m_axi_bresp      (mbus_bresp),
        .m_axi_bvalid     (mbus_bvalid),
        .m_axi_bready     (mbus_bready),
        // TCM slave port (external debug/DMA)
        .s_axi_araddr     (s_tcm_araddr),
        .s_axi_arvalid    (s_tcm_arvalid),
        .s_axi_arready    (s_tcm_arready),
        .s_axi_rdata      (s_tcm_rdata),
        .s_axi_rresp      (s_tcm_rresp),
        .s_axi_rvalid     (s_tcm_rvalid),
        .s_axi_rready     (s_tcm_rready),
        .s_axi_awaddr     (s_tcm_awaddr),
        .s_axi_awvalid    (s_tcm_awvalid),
        .s_axi_awready    (s_tcm_awready),
        .s_axi_wdata      (s_tcm_wdata),
        .s_axi_wstrb      (s_tcm_wstrb),
        .s_axi_wvalid     (s_tcm_wvalid),
        .s_axi_wready     (s_tcm_wready),
        .s_axi_bresp      (s_tcm_bresp),
        .s_axi_bvalid     (s_tcm_bvalid),
        .s_axi_bready     (s_tcm_bready),
        // Interrupts
        .timer_irq        (timer_irq),
        .software_irq     (software_irq),
        .external_irq     (external_irq),
        .clic_irq         (clic_irq),
        .clic_level       (clic_level),
        .clic_prio        (clic_prio),
        .clic_id          (clic_id),
        .clic_ack         (clic_ack),
        // Trace
        .trace_valid      (trace_valid),
        .trace_reg_we     (trace_reg_we),
        .trace_pc         (trace_pc),
        .trace_rd         (trace_rd),
        .trace_rd_data    (trace_rd_data),
        .trace_instr      (trace_instr),
        .trace_mem_we     (trace_mem_we),
        .trace_mem_re     (trace_mem_re),
        .trace_mem_addr   (trace_mem_addr),
        .trace_mem_data   (trace_mem_data)
    );

    // =====================================================================
    // AXI crossbar: 1 master → 3 peripheral slaves
    //   Slave 0: UART   @ 0x2001_0000  mask 0xFFFF_FF00 (256 B)
    //   Slave 1: CLIC   @ 0x0200_0000  mask 0xFFE0_0000 (2 MB)
    //   Slave 2: Magic  @ 0x4000_0000  mask 0xF000_0000 (256 MB)
    // =====================================================================
    localparam logic [31:0] XBAR_BASE [3] = '{32'h2001_0000,
                                              32'h0200_0000,
                                              32'h4000_0000};
    localparam logic [31:0] XBAR_MASK [3] = '{32'hFFFF_FF00,
                                              32'hFFE0_0000,
                                              32'hF000_0000};

    logic [2:0][31:0] xs_awaddr; logic [2:0] xs_awvalid, xs_awready;
    logic [2:0][31:0] xs_wdata;  logic [2:0][3:0] xs_wstrb;
    logic [2:0]       xs_wvalid, xs_wready;
    logic [2:0][1:0]  xs_bresp;  logic [2:0] xs_bvalid, xs_bready;
    logic [2:0][31:0] xs_araddr; logic [2:0] xs_arvalid, xs_arready;
    logic [2:0][31:0] xs_rdata;  logic [2:0][1:0] xs_rresp;
    logic [2:0]       xs_rvalid, xs_rready;

    axi_xbar #(.N_SLAVES(3), .SLAVE_BASE(XBAR_BASE), .SLAVE_MASK(XBAR_MASK)) u_xbar (
        .clk     (clk),       .rst_n   (rst_n),
        .m_awaddr(mbus_awaddr),.m_awvalid(mbus_awvalid),.m_awready(mbus_awready),
        .m_wdata (mbus_wdata), .m_wstrb (mbus_wstrb),   .m_wvalid (mbus_wvalid),
        .m_wready(mbus_wready),.m_bresp (mbus_bresp),   .m_bvalid (mbus_bvalid),
        .m_bready(mbus_bready),
        .m_araddr(mbus_araddr),.m_arvalid(mbus_arvalid),.m_arready(mbus_arready),
        .m_rdata (mbus_rdata), .m_rresp (mbus_rresp),   .m_rvalid (mbus_rvalid),
        .m_rready(mbus_rready),
        .s_awaddr(xs_awaddr),  .s_awvalid(xs_awvalid),  .s_awready(xs_awready),
        .s_wdata (xs_wdata),   .s_wstrb  (xs_wstrb),    .s_wvalid (xs_wvalid),
        .s_wready(xs_wready),  .s_bresp  (xs_bresp),    .s_bvalid (xs_bvalid),
        .s_bready(xs_bready),
        .s_araddr(xs_araddr),  .s_arvalid(xs_arvalid),  .s_arready(xs_arready),
        .s_rdata (xs_rdata),   .s_rresp  (xs_rresp),    .s_rvalid (xs_rvalid),
        .s_rready(xs_rready)
    );

    // =====================================================================
    // UART — slave 0
    // =====================================================================
    axi_uart #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE), .FIFO_DEPTH(UART_FIFO_DEPTH)) u_uart (
        .clk(clk), .rst_n(rst_n),
        .axi_awaddr(xs_awaddr[0]),.axi_awvalid(xs_awvalid[0]),.axi_awready(xs_awready[0]),
        .axi_wdata (xs_wdata[0]), .axi_wstrb  (xs_wstrb[0]),  .axi_wvalid (xs_wvalid[0]),
        .axi_wready(xs_wready[0]),.axi_bresp  (xs_bresp[0]),  .axi_bvalid (xs_bvalid[0]),
        .axi_bready(xs_bready[0]),
        .axi_araddr(xs_araddr[0]),.axi_arvalid(xs_arvalid[0]),.axi_arready(xs_arready[0]),
        .axi_rdata (xs_rdata[0]), .axi_rresp  (xs_rresp[0]),  .axi_rvalid (xs_rvalid[0]),
        .axi_rready(xs_rready[0]),
        .uart_rx(uart_rx_i), .uart_tx(uart_tx_o),
        .irq()
    );

    // =====================================================================
    // CLIC / CLINT — slave 1
    // =====================================================================
    axi_clic #(.CLK_FREQ(CLK_FREQ)) u_clic (
        .clk(clk), .rst_n(rst_n),
        .instret_inc      (trace_valid),
        .s_awaddr(xs_awaddr[1]),.s_awvalid(xs_awvalid[1]),.s_awready(xs_awready[1]),
        .s_wdata (xs_wdata[1]), .s_wstrb  (xs_wstrb[1]),  .s_wvalid (xs_wvalid[1]),
        .s_wready(xs_wready[1]),.s_bresp  (xs_bresp[1]),  .s_bvalid (xs_bvalid[1]),
        .s_bready(xs_bready[1]),
        .s_araddr(xs_araddr[1]),.s_arvalid(xs_arvalid[1]),.s_arready(xs_arready[1]),
        .s_rdata (xs_rdata[1]), .s_rresp  (xs_rresp[1]),  .s_rvalid (xs_rvalid[1]),
        .s_rready(xs_rready[1]),
        .ext_irq_i        (ext_irq_i),
        .timer_irq_o      (timer_irq),
        .software_irq_o   (software_irq),
        .clic_irq_o       (clic_irq),
        .clic_level_o     (clic_level),
        .clic_prio_o      (clic_prio),
        .clic_id_o        (clic_id)
    );
    assign external_irq = clic_irq;

    // =====================================================================
    // Magic — slave 2
    // =====================================================================
    axi_magic u_magic (
        .clk(clk), .rst_n(rst_n),
        .axi_awaddr(xs_awaddr[2]),.axi_awvalid(xs_awvalid[2]),.axi_awready(xs_awready[2]),
        .axi_wdata (xs_wdata[2]), .axi_wstrb  (xs_wstrb[2]),  .axi_wvalid (xs_wvalid[2]),
        .axi_wready(xs_wready[2]),.axi_bresp  (xs_bresp[2]),  .axi_bvalid (xs_bvalid[2]),
        .axi_bready(xs_bready[2]),
        .axi_araddr(xs_araddr[2]),.axi_arvalid(xs_arvalid[2]),.axi_arready(xs_arready[2]),
        .axi_rdata (xs_rdata[2]), .axi_rresp  (xs_rresp[2]),  .axi_rvalid (xs_rvalid[2]),
        .axi_rready(xs_rready[2])
    );

    // CLIC ack unused (CLINT-style polling, no ack needed)
    logic _unused; assign _unused = &{1'b0, clic_ack};

endmodule
