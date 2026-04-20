// ============================================================================
// File: jv32_regfile.sv
// Project: JV32 RISC-V Processor
// Description: RV32 Integer Register File
//
// 32×32-bit GPRs (x0 hardwired to 0), 2 read ports, 1 write port.
// Synchronous write, asynchronous read with write-through forwarding.
// ============================================================================

module jv32_regfile (
    input logic clk,
    input logic rst_n,

    // Read ports
    input  logic [ 4:0] rs1_addr,
    output logic [31:0] rs1_data,
    input  logic [ 4:0] rs2_addr,
    output logic [31:0] rs2_data,

    // Write port (WB stage)
    input logic        we,
    input logic [ 4:0] rd_addr,
    input logic [31:0] rd_data,

    // Debug sideband access (used while the hart is halted)
    input  logic [ 4:0] dbg_addr,
    input  logic        dbg_we,
    input  logic [31:0] dbg_wdata,
    output logic [31:0] dbg_rdata
);

    logic [31:0] regs[31:1];  // x0 is hardwired to 0

    // Asynchronous read with write-through forwarding
    assign rs1_data = (rs1_addr == 5'd0)                          ? 32'd0     :
                      (dbg_we && (rs1_addr == dbg_addr))          ? dbg_wdata :
                      (we && (rs1_addr == rd_addr))               ? rd_data   :
                      regs[rs1_addr];

    assign rs2_data = (rs2_addr == 5'd0)                          ? 32'd0     :
                      (dbg_we && (rs2_addr == dbg_addr))          ? dbg_wdata :
                      (we && (rs2_addr == rd_addr))               ? rd_data   :
                      regs[rs2_addr];

    assign dbg_rdata = (dbg_addr == 5'd0)                         ? 32'd0     :
                       (dbg_we)                                   ? dbg_wdata :
                       (we && (dbg_addr == rd_addr))              ? rd_data   :
                       regs[dbg_addr];

    // Synchronous write
    always_ff @(posedge clk) begin
        if (dbg_we && (dbg_addr != 5'd0)) regs[dbg_addr] <= dbg_wdata;
        else if (we && (rd_addr != 5'd0)) regs[rd_addr] <= rd_data;
    end

    // unused rst_n (purely combinational read, synchronous write without reset)
    logic _unused;
    assign _unused = &{1'b0, rst_n};

endmodule
