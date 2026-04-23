// ============================================================================
// File   : jv32_fpga_top.sv
// Project: JV32 RISC-V SoC
// Brief  : FPGA top-level wrapper – Xilinx KU5P (XCKU5PFFVB676)
//          Configurable for 4-wire JTAG (USE_CJTAG=0, default) or
//          2-wire cJTAG / OScan1 (USE_CJTAG=1).
//
// Pins
// ----
//   clk_50m       E18   LVCMOS18  50 MHz system clock
//
//   JTAG / cJTAG (LVCMOS33, shared physical connector)
//   jtag_tck_i    D11   TCK  (JTAG) / TCKC (cJTAG) – always input
//   jtag_tmsc_io  C12   TMS  (JTAG) / TMSC (cJTAG) – bidir IOBUF
//   jtag_tdi_i    J12   TDI  (JTAG only; tie to GND in cJTAG)
//   jtag_tdo_o    E12   TDO  (JTAG only; driven 0   in cJTAG)
//
//   UART (LVCMOS33)
//   uart_tx_o     J14   TX
//   uart_rx_i     G12   RX
//
// Parameters
// ----------
//   USE_CJTAG  0 (default) = 4-wire JTAG
//              1           = 2-wire cJTAG (IEEE 1149.7 OScan1)
//
// Reset
// -----
//   jv32_clk_rst_bd_wrapper (IP Integrator BD) contains clk_wiz + proc_sys_reset.
//   rst_n is held low until the MMCM is locked after configuration.
// ============================================================================

module jv32_fpga_top #(
    parameter bit USE_CJTAG = 1'b0  // 0 = 4-wire JTAG, 1 = 2-wire cJTAG
) (
    input  logic clk_50m,

    // JTAG / cJTAG – shared physical connector
    input  logic jtag_tck_i,    // TCK  (JTAG) / TCKC (cJTAG)  – D11
    inout  wire  jtag_tmsc_io,  // TMS  (JTAG) / TMSC (cJTAG)  – C12 bidir
    input  logic jtag_tdi_i,    // TDI  (JTAG only)             – J12
    output logic jtag_tdo_o,    // TDO  (JTAG only)             – E12

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
    // IOBUF for TMS / TMSC (C12)
    //
    // Xilinx IOBUF primitive:
    //   IO – bidirectional FPGA pad
    //   I  – fabric data driven to pad when T=0
    //   O  – fabric data read from pad
    //   T  – tristate enable: 1=tristate (input mode), 0=drive output
    //
    // JTAG mode  (USE_CJTAG=0): T is permanently 1 → pad is a pure input.
    // cJTAG mode (USE_CJTAG=1): T follows soc_tms_oe; the SoC drives TMSC
    //                            during the TDO-capture OScan1 phase.
    // -----------------------------------------------------------------------
    logic tmsc_in;    // data read from TMS / TMSC pad
    logic tmsc_out;   // data driven to TMSC pad  (cJTAG only)
    logic tmsc_oe_n;  // IOBUF T: 1=tristate/input, 0=drive output

    IOBUF u_tmsc_iobuf (
        .IO (jtag_tmsc_io),
        .I  (tmsc_out),
        .O  (tmsc_in),
        .T  (tmsc_oe_n)
    );

    // SoC-side TMS / TMSC signals (always declared; unused ports tie off)
    logic soc_tms_o, soc_tms_oe, soc_tdo_o;

    if (USE_CJTAG) begin : g_cjtag_io
        // cJTAG: SoC drives TMSC and controls output-enable
        assign tmsc_out   = soc_tms_o;
        assign tmsc_oe_n  = soc_tms_oe;
        assign jtag_tdo_o = 1'b0;  // TDO pin (E12) unused in cJTAG – drive 0
    end else begin : g_jtag_io
        // JTAG: TMS is always an input – permanently tristate the IOBUF
        assign tmsc_out   = 1'b0;
        assign tmsc_oe_n  = 1'b1;
        assign jtag_tdo_o = soc_tdo_o;
    end

    // -----------------------------------------------------------------------
    // JV32 SoC
    // -----------------------------------------------------------------------
    jv32_soc #(
        .CLK_FREQ  (50_000_000),
        .BAUD_RATE (115_200),
        .USE_CJTAG (USE_CJTAG)
    ) u_soc (
        .clk   (clk_core),
        .rst_n (rst_n),

        // ── UART ────────────────────────────────────────────────────────────
        .uart_rx_i (uart_rx_i),
        .uart_tx_o (uart_tx_o),

        // ── JTAG / cJTAG ────────────────────────────────────────────────────
        .jtag_ntrst_i     (1'b1),                           // nTRST deasserted
        .jtag_pin0_tck_i  (jtag_tck_i),
        .jtag_pin1_tms_i  (tmsc_in),                        // TMS / TMSC in
        .jtag_pin1_tms_o  (soc_tms_o),                      // TMSC out (cJTAG)
        .jtag_pin1_tms_oe (soc_tms_oe),                     // TMSC OE  (cJTAG)
        .jtag_pin2_tdi_i  (USE_CJTAG ? 1'b0 : jtag_tdi_i), // unused in cJTAG
        .jtag_pin3_tdo_o  (soc_tdo_o),                      // TDO → g_jtag_io
        .jtag_pin3_tdo_oe (),                                // not used on FPGA

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
