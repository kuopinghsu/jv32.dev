// ============================================================================
// File   : jv32_fpga_top.sv
// Project: JV32 RISC-V SoC
// Brief  : FPGA top-level wrapper – Xilinx KU5P (XCKU5PFFVB676)
//
// Pins
// ----
//   clk_50m    E18   LVCMOS18  50 MHz system clock
//
//   JTAG (LVCMOS33)
//   jtag_tck_i D11   TCK
//   jtag_tms_i C12   TMS
//   jtag_tdi_i J12   TDI
//   jtag_tdo_o E12   TDO
//
//   UART (LVCMOS33)
//   uart_tx_o  J14   TX
//   uart_rx_i  G12   RX
//
// Reset
// -----
//   jv32_clk_rst_bd_wrapper (IP Integrator BD) contains clk_wiz + proc_sys_reset.
//   rst_n is held low until the MMCM is locked after configuration.
// ============================================================================

module jv32_fpga_top (
    input  logic clk_50m,

    // JTAG – 4-wire
    input  logic jtag_tck_i,
    input  logic jtag_tms_i,
    input  logic jtag_tdi_i,
    output logic jtag_tdo_o,

    // UART
    output logic uart_tx_o,
    input  logic uart_rx_i
);

    // -----------------------------------------------------------------------
    // Clock and reset from IP Integrator block design
    // -----------------------------------------------------------------------
    logic clk_core;
    logic rst_n;

    jv32_clk_rst_bd_wrapper u_clk_rst (
        .clk_in1  (clk_50m),
        .clk_out1 (clk_core),
        .rst_n    (rst_n)
    );

    // -----------------------------------------------------------------------
    // JV32 SoC
    // -----------------------------------------------------------------------
    jv32_soc #(
        .CLK_FREQ  (50_000_000),
        .BAUD_RATE (115_200),
        .USE_CJTAG (1'b0)         // 4-wire JTAG
    ) u_soc (
        .clk   (clk_core),
        .rst_n (rst_n),

        // ── UART ────────────────────────────────────────────────────────────
        .uart_rx_i (uart_rx_i),
        .uart_tx_o (uart_tx_o),

        // ── JTAG (4-wire, USE_CJTAG=0) ─────────────────────────────────────
        .jtag_ntrst_i     (1'b1),       // deasserted (active-low)
        .jtag_pin0_tck_i  (jtag_tck_i),
        .jtag_pin1_tms_i  (jtag_tms_i),
        .jtag_pin1_tms_o  (),           // cJTAG only – not used
        .jtag_pin1_tms_oe (),           // cJTAG only – not used
        .jtag_pin2_tdi_i  (jtag_tdi_i),
        .jtag_pin3_tdo_o  (jtag_tdo_o),
        .jtag_pin3_tdo_oe (),           // cJTAG only – not used

        // ── External IRQ (unused) ───────────────────────────────────────────
        .ext_irq_i (16'h0),

        // ── TCM AXI slave – IRAM (no external master on FPGA) ──────────────
        .s_iram_tcm_araddr  (32'h0), .s_iram_tcm_arvalid (1'b0),
        .s_iram_tcm_arready (),
        .s_iram_tcm_rdata   (),      .s_iram_tcm_rresp   (),
        .s_iram_tcm_rvalid  (),      .s_iram_tcm_rready  (1'b1),
        .s_iram_tcm_awaddr  (32'h0), .s_iram_tcm_awvalid (1'b0),
        .s_iram_tcm_awready (),
        .s_iram_tcm_wdata   (32'h0), .s_iram_tcm_wstrb   (4'h0),
        .s_iram_tcm_wvalid  (1'b0),  .s_iram_tcm_wready  (),
        .s_iram_tcm_bresp   (),      .s_iram_tcm_bvalid  (),
        .s_iram_tcm_bready  (1'b1),

        // ── TCM AXI slave – DRAM (no external master on FPGA) ──────────────
        .s_dram_tcm_araddr  (32'h0), .s_dram_tcm_arvalid (1'b0),
        .s_dram_tcm_arready (),
        .s_dram_tcm_rdata   (),      .s_dram_tcm_rresp   (),
        .s_dram_tcm_rvalid  (),      .s_dram_tcm_rready  (1'b1),
        .s_dram_tcm_awaddr  (32'h0), .s_dram_tcm_awvalid (1'b0),
        .s_dram_tcm_awready (),
        .s_dram_tcm_wdata   (32'h0), .s_dram_tcm_wstrb   (4'h0),
        .s_dram_tcm_wvalid  (1'b0),  .s_dram_tcm_wready  (),
        .s_dram_tcm_bresp   (),      .s_dram_tcm_bvalid  (),
        .s_dram_tcm_bready  (1'b1),

        // ── External AXI master (unused on FPGA – tie off slave inputs) ─────
        .ext_axi_araddr  (), .ext_axi_arvalid (), .ext_axi_rready  (),
        .ext_axi_awaddr  (), .ext_axi_awvalid (), .ext_axi_wdata   (),
        .ext_axi_wstrb   (), .ext_axi_wvalid  (), .ext_axi_bready  (),
        .ext_axi_arready (1'b0),
        .ext_axi_rdata   (32'h0), .ext_axi_rresp  (2'b00),
        .ext_axi_rvalid  (1'b0),
        .ext_axi_awready (1'b0),
        .ext_axi_wready  (1'b0),
        .ext_axi_bresp   (2'b00), .ext_axi_bvalid (1'b0),

        // ── Trace (disabled) ────────────────────────────────────────────────
        .trace_en       (1'b0),
        .trace_valid    (), .trace_reg_we   (), .trace_pc       (),
        .trace_rd       (), .trace_rd_data  (), .trace_instr    (),
        .trace_mem_we   (), .trace_mem_re   (), .trace_mem_addr (),
        .trace_mem_data (), .trace_irq_taken(), .trace_irq_cause(),
        .trace_irq_epc  ()
    );

endmodule
