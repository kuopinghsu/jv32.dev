// Lighter DFF map for NangateOpenCellLibrary (Nangate 45nm Open Cell Library)
//
// This file maps Yosys internal FF-with-enable primitives to clock-gated
// equivalents using the Nangate45 CLKGATE_X{1,2,4} integrated clock-gating
// cells.  It is consumed by the Lighter plugin (reg_clock_gating pass) when
// USE_LIGHTER: true is set in the OpenLane2 config.
//
// Nangate45 CLKGATE_X1 pin mapping:
//   CK  — clock input (posedge)
//   E   — enable input (active-high, latched on CK low)
//   GCK — gated clock output (CK & latched-E)
//
// Cell sizing by FF bundle width:
//   WIDTH <  5 : CLKGATE_X1  (drive strength 1)
//   WIDTH < 17 : CLKGATE_X2  (drive strength 2)
//   WIDTH >= 17: CLKGATE_X4  (drive strength 4)

`define CG_INST(GCLK, cg_clk, cg_enb) \
    generate \
        if (WIDTH < 5) begin \
            CLKGATE_X1 clk_gate (.GCK(GCLK), .CK(cg_clk), .E(cg_enb)); \
        end else if (WIDTH < 17) begin \
            CLKGATE_X2 clk_gate (.GCK(GCLK), .CK(cg_clk), .E(cg_enb)); \
        end else begin \
            CLKGATE_X4 clk_gate (.GCK(GCLK), .CK(cg_clk), .E(cg_enb)); \
        end \
    endgenerate

// ── $adffe ─────────────────────────────────────────────────────────────────
// Asynchronous reset FF with clock enable.
module \$adffe (ARST, CLK, D, EN, Q);
    parameter ARST_POLARITY = 1'b1;
    parameter ARST_VALUE    = 1'b0;
    parameter CLK_POLARITY  = 1'b1;
    parameter EN_POLARITY   = 1'b1;
    parameter WIDTH         = 1;

    input  ARST, CLK, EN;
    input  [WIDTH-1:0] D;
    output [WIDTH-1:0] Q;

    wire GCLK, cg_enb, cg_clk, cg_gclk;

    generate
        if (EN_POLARITY  == 0) assign cg_enb = ~EN;  else assign cg_enb = EN;
        if (CLK_POLARITY == 0) assign cg_clk = ~CLK; else assign cg_clk = CLK;
    endgenerate

    `CG_INST(GCLK, cg_clk, cg_enb)

    generate
        if (CLK_POLARITY == 0) assign cg_gclk = ~GCLK; else assign cg_gclk = GCLK;
    endgenerate

    $adff #(.WIDTH(WIDTH), .CLK_POLARITY(CLK_POLARITY),
            .ARST_POLARITY(ARST_POLARITY), .ARST_VALUE(ARST_VALUE))
        flipflop (.CLK(cg_gclk), .ARST(ARST), .D(D), .Q(Q));
endmodule

// ── $dffe ──────────────────────────────────────────────────────────────────
// Plain FF with clock enable (no reset).
module \$dffe (CLK, D, EN, Q);
    parameter CLK_POLARITY = 1'b1;
    parameter EN_POLARITY  = 1'b1;
    parameter WIDTH        = 1;

    input  CLK, EN;
    input  [WIDTH-1:0] D;
    output [WIDTH-1:0] Q;

    wire GCLK, cg_enb, cg_clk, cg_gclk;

    generate
        if (EN_POLARITY  == 0) assign cg_enb = ~EN;  else assign cg_enb = EN;
        if (CLK_POLARITY == 0) assign cg_clk = ~CLK; else assign cg_clk = CLK;
    endgenerate

    `CG_INST(GCLK, cg_clk, cg_enb)

    generate
        if (CLK_POLARITY == 0) assign cg_gclk = ~GCLK; else assign cg_gclk = GCLK;
    endgenerate

    $dff #(.WIDTH(WIDTH), .CLK_POLARITY(CLK_POLARITY))
        flipflop (.CLK(cg_gclk), .D(D), .Q(Q));
endmodule

// ── $dffsre ────────────────────────────────────────────────────────────────
// FF with synchronous set/reset and clock enable.
module \$dffsre (CLK, EN, CLR, SET, D, Q);
    parameter CLK_POLARITY = 1'b1;
    parameter EN_POLARITY  = 1'b1;
    parameter CLR_POLARITY = 1'b1;
    parameter SET_POLARITY = 1'b1;
    parameter WIDTH        = 1;

    input  CLK, EN, CLR, SET;
    input  [WIDTH-1:0] D;
    output [WIDTH-1:0] Q;

    wire GCLK, cg_enb, cg_clk, cg_gclk;

    generate
        if (EN_POLARITY  == 0) assign cg_enb = ~EN;  else assign cg_enb = EN;
        if (CLK_POLARITY == 0) assign cg_clk = ~CLK; else assign cg_clk = CLK;
    endgenerate

    `CG_INST(GCLK, cg_clk, cg_enb)

    generate
        if (CLK_POLARITY == 0) assign cg_gclk = ~GCLK; else assign cg_gclk = GCLK;
    endgenerate

    $dffsr #(.WIDTH(WIDTH), .CLK_POLARITY(CLK_POLARITY),
             .CLR_POLARITY(CLR_POLARITY), .SET_POLARITY(SET_POLARITY))
        flipflop (.CLK(cg_gclk), .CLR(CLR), .SET(SET), .D(D), .Q(Q));
endmodule

// ── $aldffe ────────────────────────────────────────────────────────────────
// FF with async load and clock enable.
module \$aldffe (CLK, EN, ALOAD, AD, D, Q);
    parameter CLK_POLARITY   = 1'b1;
    parameter EN_POLARITY    = 1'b1;
    parameter ALOAD_POLARITY = 1'b1;
    parameter WIDTH          = 1;

    input  CLK, EN, ALOAD;
    input  [WIDTH-1:0] D, AD;
    output [WIDTH-1:0] Q;

    wire GCLK, cg_enb, cg_clk, cg_gclk;

    generate
        if (EN_POLARITY  == 0) assign cg_enb = ~EN;  else assign cg_enb = EN;
        if (CLK_POLARITY == 0) assign cg_clk = ~CLK; else assign cg_clk = CLK;
    endgenerate

    `CG_INST(GCLK, cg_clk, cg_enb)

    generate
        if (CLK_POLARITY == 0) assign cg_gclk = ~GCLK; else assign cg_gclk = GCLK;
    endgenerate

    $aldff #(.WIDTH(WIDTH), .CLK_POLARITY(CLK_POLARITY),
             .ALOAD_POLARITY(ALOAD_POLARITY))
        flipflop (.CLK(cg_gclk), .ALOAD(ALOAD), .AD(AD), .D(D), .Q(Q));
endmodule

// ── $sdffe ─────────────────────────────────────────────────────────────────
// FF with synchronous reset and clock enable (reset takes priority over EN).
// The clock gate must remain open during reset so the reset value propagates.
module \$sdffe (CLK, EN, SRST, D, Q);
    parameter CLK_POLARITY  = 1'b1;
    parameter EN_POLARITY   = 1'b1;
    parameter SRST_POLARITY = 1'b1;
    parameter SRST_VALUE    = 1'b0;
    parameter WIDTH         = 1;

    input  CLK, EN, SRST;
    input  [WIDTH-1:0] D;
    output [WIDTH-1:0] Q;

    wire GCLK, cg_enb, cg_clk, cg_gclk, cg_rstenb;

    // Keep clock open during reset assertion
    generate
        if (SRST_POLARITY == 0) assign cg_rstenb = ~SRST; else assign cg_rstenb = SRST;
        if (EN_POLARITY   == 0) assign cg_enb = (~EN) | cg_rstenb;
        else                    assign cg_enb = EN | cg_rstenb;
        if (CLK_POLARITY  == 0) assign cg_clk = ~CLK; else assign cg_clk = CLK;
    endgenerate

    `CG_INST(GCLK, cg_clk, cg_enb)

    generate
        if (CLK_POLARITY == 0) assign cg_gclk = ~GCLK; else assign cg_gclk = GCLK;
    endgenerate

    $sdff #(.WIDTH(WIDTH), .CLK_POLARITY(CLK_POLARITY),
            .SRST_POLARITY(SRST_POLARITY), .SRST_VALUE(SRST_VALUE))
        flipflop (.CLK(cg_gclk), .SRST(SRST), .D(D), .Q(Q));
endmodule

// ── $sdffce ────────────────────────────────────────────────────────────────
// FF with synchronous reset and clock enable (EN takes priority over reset).
module \$sdffce (CLK, EN, SRST, D, Q);
    parameter CLK_POLARITY  = 1'b1;
    parameter EN_POLARITY   = 1'b1;
    parameter SRST_POLARITY = 1'b1;
    parameter SRST_VALUE    = 1'b0;
    parameter WIDTH         = 1;

    input  CLK, EN, SRST;
    input  [WIDTH-1:0] D;
    output [WIDTH-1:0] Q;

    wire GCLK, cg_enb, cg_clk, cg_gclk;

    generate
        if (EN_POLARITY  == 0) assign cg_enb = ~EN;  else assign cg_enb = EN;
        if (CLK_POLARITY == 0) assign cg_clk = ~CLK; else assign cg_clk = CLK;
    endgenerate

    `CG_INST(GCLK, cg_clk, cg_enb)

    generate
        if (CLK_POLARITY == 0) assign cg_gclk = ~GCLK; else assign cg_gclk = GCLK;
    endgenerate

    $sdff #(.WIDTH(WIDTH), .CLK_POLARITY(CLK_POLARITY),
            .SRST_POLARITY(SRST_POLARITY), .SRST_VALUE(SRST_VALUE))
        flipflop (.CLK(cg_gclk), .SRST(SRST), .D(D), .Q(Q));
endmodule
