// ============================================================================
// File: jv32_regfile.sv
// Project: JV32 RISC-V Processor
// Description: RV32 Integer Register File
//
// 32×32-bit GPRs (x0 hardwired to 0), 2 read ports, 1 write port.
// Synchronous write, asynchronous read with write-through forwarding.
// ============================================================================

module jv32_regfile #(
    parameter bit RV32E_EN = 1'b0  // 1=RV32E (16 GPRs), 0=RV32I/M/A (32 GPRs)
) (
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

    // RV32E: 16 registers (x1-x15); RV32I: 32 registers (x1-x31).
    // Accesses to x16-x31 from RV32E code are caught by the decoder (illegal=1).
    // The debug port may still read x16-x31; they return 0 safely in RV32E mode.
    localparam int NREGS = RV32E_EN ? 16 : 32;

    logic [31:0] regs[NREGS-1:1];  // x0 is hardwired to 0

    // Pipeline read ports: pure registered reads, no write-through.
    //
    // WB→EX forwarding for non-load results is handled entirely by the
    // fwd_rs1/fwd_rs2 mux in jv32_core.sv, which uses only FF outputs
    // (ex_wb_r.*) and therefore carries no combinatorial dependency on
    // dbg_halted_r.  Providing a duplicate write-through mux here would
    // route dbg_halted_r (via rf_we → wb_retire → ex_stall) into
    // operand_a/operand_b, creating the large combinatorial loop that
    // Vivado flags as LUTLP-1.
    //
    // For load results, the load-use stall guarantees that regs[] is
    // updated one full cycle before the dependent instruction enters EX,
    // so a registered read is always correct.
    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : (RV32E_EN && rs1_addr[4]) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : (RV32E_EN && rs2_addr[4]) ? 32'd0 : regs[rs2_addr];

    assign dbg_rdata = (dbg_addr == 5'd0)                    ? 32'd0     :
                       (RV32E_EN && dbg_addr[4])             ? 32'd0     :
                       (dbg_we)                              ? dbg_wdata :
                       (we && (dbg_addr == rd_addr))         ? rd_data   :
                       regs[dbg_addr];

    // Synchronous write
    always_ff @(posedge clk) begin
        if (dbg_we && (dbg_addr != 5'd0) && !(RV32E_EN && dbg_addr[4])) regs[dbg_addr] <= dbg_wdata;
        else if (we && (rd_addr != 5'd0) && !(RV32E_EN && rd_addr[4])) regs[rd_addr] <= rd_data;
    end

    // unused rst_n (purely combinational read, synchronous write without reset)
    logic _unused;
    assign _unused = &{1'b0, rst_n};

endmodule
