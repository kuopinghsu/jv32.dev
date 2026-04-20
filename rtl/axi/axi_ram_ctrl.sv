// ============================================================================
// File: axi_ram_ctrl.sv
// Project: JV32 RISC-V Processor
// Description: AXI4-Lite slave wrapping sram_1rw
//
// Single-cycle read/write RAM controller.
// WSTRB byte-enable supported.
// WR_EN=0: read-only (write returns SLVERR)
// ============================================================================

module axi_ram_ctrl #(
    parameter int unsigned DEPTH = 16384,  // words (32-bit)
    parameter bit          WR_EN = 1'b1    // 0=read-only
) (
    input logic clk,
    input logic rst_n,

    // AXI4-Lite slave
    input  logic [31:0] s_awaddr,
    input  logic        s_awvalid,
    output logic        s_awready,
    input  logic [31:0] s_wdata,
    input  logic [ 3:0] s_wstrb,
    input  logic        s_wvalid,
    output logic        s_wready,
    output logic [ 1:0] s_bresp,
    output logic        s_bvalid,
    input  logic        s_bready,
    input  logic [31:0] s_araddr,
    input  logic        s_arvalid,
    output logic        s_arready,
    output logic [31:0] s_rdata,
    output logic [ 1:0] s_rresp,
    output logic        s_rvalid,
    input  logic        s_rready
);
    localparam int unsigned ALEN = $clog2(DEPTH);

    // SRAM interface
    logic ram_ce, ram_we;
    logic [ALEN-1:0] ram_addr;
    logic [31:0] ram_wdata, ram_rdata;
    logic [3:0] ram_wbe;

    sram_1rw #(
        .DEPTH(DEPTH),
        .WIDTH(32)
    ) u_sram (
        .clk  (clk),
        .ce   (ram_ce),
        .we   (ram_we),
        .wbe  (ram_wbe),
        .addr (ram_addr),
        .wdata(ram_wdata),
        .rdata(ram_rdata)
    );

    // =====================================================================
    // Write channel
    // =====================================================================
    logic        aw_active;
    logic [31:0] aw_addr_r;
    logic        w_active;
    logic [31:0] w_data_r;
    logic [ 3:0] w_strb_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_active <= 1'b0;
            aw_addr_r <= 32'h0;
            w_active  <= 1'b0;
            w_data_r  <= 32'h0;
            w_strb_r  <= 4'h0;
            s_bvalid  <= 1'b0;
        end
        else begin
            if (s_awvalid && s_awready) begin
                aw_active <= 1'b1;
                aw_addr_r <= s_awaddr;
            end
            if (s_wvalid && s_wready) begin
                w_active <= 1'b1;
                w_data_r <= s_wdata;
                w_strb_r <= s_wstrb;
            end
            if ((aw_active || (s_awvalid && s_awready)) && (w_active || (s_wvalid && s_wready))) begin
                aw_active <= 1'b0;
                w_active  <= 1'b0;
                s_bvalid  <= 1'b1;
            end
            else if (s_bvalid && s_bready) s_bvalid <= 1'b0;
        end
    end

    assign s_awready = !aw_active;
    assign s_wready  = !w_active;
    assign s_bresp   = WR_EN ? 2'b00 : 2'b10;  // SLVERR if read-only

    // SRAM write
    logic do_write;
    assign do_write  = WR_EN && (aw_active || (s_awvalid && !aw_active)) && (w_active || (s_wvalid && !w_active));

    assign ram_ce    = do_write || (s_arvalid && s_arready);
    assign ram_we    = do_write;
    assign ram_wbe   = do_write ? (w_active ? w_strb_r : s_wstrb) : 4'h0;
    assign ram_addr  = do_write ? ALEN'((aw_active ? aw_addr_r : s_awaddr) >> 2) : ALEN'(s_araddr >> 2);
    assign ram_wdata = w_active ? w_data_r : s_wdata;

    // =====================================================================
    // Read channel (1-cycle latency)
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_rvalid <= 1'b0;
            s_rdata  <= 32'h0;
        end
        else if (s_arvalid && s_arready) begin
            s_rvalid <= 1'b1;
            s_rdata  <= ram_rdata;
        end
        else if (s_rvalid && s_rready) begin
            s_rvalid <= 1'b0;
        end
    end

    assign s_arready = !s_rvalid;
    assign s_rresp   = 2'b00;

    // Suppress unused
    logic _unused;
    assign _unused = &{1'b0, rst_n};

endmodule
