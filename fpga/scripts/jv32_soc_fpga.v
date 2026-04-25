// ============================================================================
// File   : jv32_soc_fpga.v
// Project: JV32 RISC-V SoC
// Brief  : Plain Verilog wrapper for jv32_soc (SystemVerilog).
//
// Vivado IP Integrator restricts -type module -reference to modules whose
// top file is plain Verilog (.v); SystemVerilog (.sv) top files are rejected
// with [filemgmt 56-195].  This wrapper is the BD module reference and
// instantiates the actual jv32_soc SV module as a lower-level source.
//
// Functional ports exposed to the block design:
//   clk, rst_n, uart_rx_i, uart_tx_o
//   jtag_pin{0,1,2,3}_* (JTAG / cJTAG)
//
// Tied off internally (not wired to BD ports):
//   jtag_ntrst_i       = 1      (nTRST deasserted – not fitted on this board)
//   ext_irq_i          = 16'h0  (no external IRQ sources on this FPGA target)
//   TCM AXI slaves     = idle   (no external master; valid=0 / ready=1)
//   ext_axi master     = stall  (no external slave;  ready=0 / valid=0)
//   trace_en           = 0      (trace outputs disabled on FPGA)
//
// Parameters:
//   USE_CJTAG  0 (default) = 4-wire JTAG
//              1           = 2-wire cJTAG / OScan1
//              Configured via CONFIG.USE_CJTAG in create_bd.tcl.
// ============================================================================

`default_nettype none

module jv32_soc_fpga #(
    parameter USE_CJTAG = 0
) (
    input  wire clk,
    input  wire rst_n,

    // UART
    output wire uart_tx_o,
    input  wire uart_rx_i,

    // JTAG / cJTAG
    input  wire jtag_pin0_tck_i,
    input  wire jtag_pin1_tms_i,
    output wire jtag_pin1_tms_o,
    output wire jtag_pin1_tms_oe,
    // TDI is muxed to 1'b0 when USE_CJTAG=1 (unused in cJTAG mode)
    input  wire jtag_pin2_tdi_i,
    output wire jtag_pin3_tdo_o
);

    jv32_soc #(
        .CLK_FREQ  (50_000_000),
        .BAUD_RATE (115_200),
        .USE_CJTAG (USE_CJTAG)
    ) u_soc (
        .clk   (clk),
        .rst_n (rst_n),

        // ── UART ─────────────────────────────────────────────────────────
        .uart_rx_i        (uart_rx_i),
        .uart_tx_o        (uart_tx_o),

        // ── JTAG / cJTAG ─────────────────────────────────────────────────
        .jtag_ntrst_i     (1'b1),
        .jtag_pin0_tck_i  (jtag_pin0_tck_i),
        .jtag_pin1_tms_i  (jtag_pin1_tms_i),
        .jtag_pin1_tms_o  (jtag_pin1_tms_o),
        .jtag_pin1_tms_oe (jtag_pin1_tms_oe),
        .jtag_pin2_tdi_i  (USE_CJTAG ? 1'b0 : jtag_pin2_tdi_i),
        .jtag_pin3_tdo_o  (jtag_pin3_tdo_o),
        .jtag_pin3_tdo_oe (),

        // ── External IRQ (unused) ─────────────────────────────────────────
        .ext_irq_i        (16'h0),

        // ── TCM AXI slave – IRAM (no external master on FPGA) ────────────
        .s_iram_tcm_araddr  (32'h0), .s_iram_tcm_arvalid (1'b0), .s_iram_tcm_arready (),
        .s_iram_tcm_rdata   (),      .s_iram_tcm_rresp   (),     .s_iram_tcm_rvalid  (), .s_iram_tcm_rready  (1'b1),
        .s_iram_tcm_awaddr  (32'h0), .s_iram_tcm_awvalid (1'b0), .s_iram_tcm_awready (),
        .s_iram_tcm_wdata   (32'h0), .s_iram_tcm_wstrb   (4'h0), .s_iram_tcm_wvalid  (1'b0), .s_iram_tcm_wready  (),
        .s_iram_tcm_bresp   (),      .s_iram_tcm_bvalid  (),     .s_iram_tcm_bready  (1'b1),

        // ── TCM AXI slave – DRAM (no external master on FPGA) ────────────
        .s_dram_tcm_araddr  (32'h0), .s_dram_tcm_arvalid (1'b0), .s_dram_tcm_arready (),
        .s_dram_tcm_rdata   (),      .s_dram_tcm_rresp   (),     .s_dram_tcm_rvalid  (), .s_dram_tcm_rready  (1'b1),
        .s_dram_tcm_awaddr  (32'h0), .s_dram_tcm_awvalid (1'b0), .s_dram_tcm_awready (),
        .s_dram_tcm_wdata   (32'h0), .s_dram_tcm_wstrb   (4'h0), .s_dram_tcm_wvalid  (1'b0), .s_dram_tcm_wready  (),
        .s_dram_tcm_bresp   (),      .s_dram_tcm_bvalid  (),     .s_dram_tcm_bready  (1'b1),

        // ── External AXI master (unused – stall all transactions) ─────────
        .ext_axi_araddr   (), .ext_axi_arvalid  (), .ext_axi_rready   (),
        .ext_axi_awaddr   (), .ext_axi_awvalid  (), .ext_axi_wdata    (),
        .ext_axi_wstrb    (), .ext_axi_wvalid   (), .ext_axi_bready   (),
        .ext_axi_arready  (1'b0), .ext_axi_rdata  (32'h0), .ext_axi_rresp  (2'b00), .ext_axi_rvalid  (1'b0),
        .ext_axi_awready  (1'b0), .ext_axi_wready (1'b0),  .ext_axi_bresp  (2'b00), .ext_axi_bvalid  (1'b0),

        // ── Trace (disabled on FPGA) ──────────────────────────────────────
        .trace_en             (1'b0),
        .trace_valid          (), .trace_reg_we         (), .trace_pc            (),
        .trace_rd             (), .trace_rd_data        (), .trace_instr         (),
        .trace_mem_we         (), .trace_mem_re         (), .trace_mem_addr      (),
        .trace_mem_data       (), .trace_irq_taken      (), .trace_irq_cause     (),
        .trace_irq_epc        (),
        .trace_irq_store_we   (), .trace_irq_store_addr (), .trace_irq_store_data()
    );

endmodule

`default_nettype wire
