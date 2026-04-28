// ============================================================================
// File: formal/jv32_csr_bind.sv
// Project: JV32 RISC-V Processor
// Description: SVA properties bound to jv32_csr for SymbiYosys BMC.
//
// Bound to the DUT with `bind jv32_csr jv32_csr_props #(...) u_props(...)`.
// All signals are accessible through the bind port list without modifying
// the production source.
// ============================================================================

module jv32_csr_props #(
    parameter bit RV32E_EN = 1'b0,
    parameter bit RV32M_EN = 1'b1,
    parameter bit AMO_EN   = 1'b1
) (
    input logic        clk,
    input logic        rst_n,
    // --- CSR access ---
    input logic [11:0] csr_addr,
    input logic [ 2:0] csr_op,
    input logic [31:0] csr_wdata,
    input logic        csr_we,
    // --- Trap/MRET ---
    input logic        exception,
    input logic        mret,
    input logic        irq_pending,
    input logic        wb_valid,
    // --- Internal state (accessed via bind hierarchy) ---
    input logic        mstatus_mie,
    input logic        mstatus_mpie,
    input logic [31:0] mepc_reg,
    input logic [31:0] mtvec_reg,
    input logic [31:0] mie_reg,
    // --- Outputs ---
    input logic [31:0] csr_rdata,
    input logic [31:0] mepc_o,
    input logic [31:0] mtvec_o,
    input logic [31:0] irq_cause
);
    import jv32_pkg::*;

    // -----------------------------------------------------------------------
    // Convenience wires
    // -----------------------------------------------------------------------
    logic taking_irq;
    assign taking_irq = irq_pending && mstatus_mie && wb_valid;

    // -----------------------------------------------------------------------
    // P1: mepc_o is always word-aligned (LSB always 0)
    //     RISC-V spec: MEPC[1:0] = 0 in RV32 (no C-extension would allow[1],
    //     but jv32 always clears bit0 on write and on exception).
    // -----------------------------------------------------------------------
    p1_mepc_aligned: assert property (
        @(posedge clk) disable iff (!rst_n)
        mepc_o[0] == 1'b0
    );

    // -----------------------------------------------------------------------
    // P2: MTVEC bit 1 is always 0 (hardware enforces: {wd[31:2],1'b0,wd[0]})
    // -----------------------------------------------------------------------
    p2_mtvec_bit1_zero: assert property (
        @(posedge clk) disable iff (!rst_n)
        mtvec_o[1] == 1'b0
    );

    // -----------------------------------------------------------------------
    // P3: MIE register only retains bits {11,7,3}; all other bits are 0
    //     (mask 0x0000_0888 applied on write)
    // -----------------------------------------------------------------------
    p3_mie_reserved_zero: assert property (
        @(posedge clk) disable iff (!rst_n)
        (mie_reg & 32'hFFFF_F777) == 32'h0
    );

    // -----------------------------------------------------------------------
    // P4: On exception, MIE is cleared in the next cycle
    // -----------------------------------------------------------------------
    p4_mie_clears_on_exception: assert property (
        @(posedge clk) disable iff (!rst_n)
        exception |=> !mstatus_mie
    );

    // -----------------------------------------------------------------------
    // P5: On interrupt acceptance, MIE is cleared in the next cycle
    // -----------------------------------------------------------------------
    p5_mie_clears_on_irq: assert property (
        @(posedge clk) disable iff (!rst_n)
        taking_irq |=> !mstatus_mie
    );

    // -----------------------------------------------------------------------
    // P6: MISA is read-only — whenever CSR_MISA is addressed, csr_rdata
    //     always returns the fixed MISA_VAL (no write can change it).
    // -----------------------------------------------------------------------
    localparam bit [31:0] MISA_VAL_EXP = {
        2'b01,           // [31:30] MXL = 1 (RV32)
        4'b0, 13'b0,     // [29:13]
        RV32M_EN,        // [12] M
        3'b0,            // [11:9]
        ~RV32E_EN,       // [8]  I
        3'b0,            // [7:5]
        RV32E_EN,        // [4]  E
        1'b0,            // [3]
        1'b1,            // [2]  C
        1'b0,            // [1]
        AMO_EN           // [0]  A
    };

    p6_misa_readonly: assert property (
        @(posedge clk) disable iff (!rst_n)
        (csr_addr == 12'h301) |-> (csr_rdata == MISA_VAL_EXP)
    );

    // -----------------------------------------------------------------------
    // P7: MPIE is saved correctly — after exception, MPIE == old MIE
    // -----------------------------------------------------------------------
    p7_mpie_saves_mie: assert property (
        @(posedge clk) disable iff (!rst_n)
        exception |=> (mstatus_mpie == $past(mstatus_mie))
    );

    // -----------------------------------------------------------------------
    // P8: After MRET (non-tail-chain), MIE is restored from MPIE
    //     (clic_irq=0 path -- simple case assumed by constraining clic_irq=0)
    // -----------------------------------------------------------------------

    // -----------------------------------------------------------------------
    // Cover: show a complete exception -> MRET cycle is reachable
    // -----------------------------------------------------------------------
    c1_exception_then_mret: cover property (
        @(posedge clk) disable iff (!rst_n)
        exception ##[1:10] mret
    );

endmodule

// Bind the property module to the DUT
bind jv32_csr jv32_csr_props #(
    .RV32E_EN(RV32E_EN),
    .RV32M_EN(RV32M_EN),
    .AMO_EN  (AMO_EN)
) u_csr_props (
    .clk         (clk),
    .rst_n       (rst_n),
    .csr_addr    (csr_addr),
    .csr_op      (csr_op),
    .csr_wdata   (csr_wdata),
    .csr_we      (csr_we),
    .exception   (exception),
    .mret        (mret),
    .irq_pending (irq_pending),
    .wb_valid    (wb_valid),
    .mstatus_mie (mstatus_mie),
    .mstatus_mpie(mstatus_mpie),
    .mepc_reg    (mepc_reg),
    .mtvec_reg   (mtvec_reg),
    .mie_reg     (mie_reg),
    .csr_rdata   (csr_rdata),
    .mepc_o      (mepc_o),
    .mtvec_o     (mtvec_o),
    .irq_cause   (irq_cause)
);
