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
// Block Design
// ------------
//   jv32_bd_wrapper (IP Integrator BD) contains:
//     clk_wiz_0        – MMCM 50 MHz → 50 MHz clean clock
//     proc_sys_reset_0 – rst_n held low until MMCM locked
//     u_soc            – jv32_soc_fpga.v (Verilog BD wrapper for jv32_soc)
//   JTAG signals and UART are routed through the BD.
//   IOBUF and USE_CJTAG I/O mux remain in this top-level (Xilinx primitive).
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
    // IP Integrator block design
    //   Contains: clk_wiz_0, proc_sys_reset_0, u_soc (jv32_soc_fpga)
    //   All AXI tie-offs, trace disable, and nTRST/ext_irq tie-offs are
    //   handled inside jv32_soc_fpga.v; this top only routes I/O.
    // -----------------------------------------------------------------------
    logic soc_tms_o, soc_tms_oe, soc_tdo_o;

    jv32_bd_wrapper u_bd (
        .clk_in1      (clk_50m),
        .jtag_tck_i   (jtag_tck_i),
        .jtag_tmsc_in (tmsc_in),      // from IOBUF below
        .jtag_tdi_i   (jtag_tdi_i),   // jv32_soc_fpga muxes to 0 when USE_CJTAG=1
        .soc_tms_o    (soc_tms_o),
        .soc_tms_oe   (soc_tms_oe),
        .soc_tdo_o    (soc_tdo_o),
        .uart_rx_i    (uart_rx_i),
        .uart_tx_o    (uart_tx_o)
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

endmodule
