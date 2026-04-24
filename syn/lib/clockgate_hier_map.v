// clockgate_hier_map.v — hierarchical (multi-bit) clock gating techmap.
//
// This map runs BEFORE dfflegalize, while flip-flops are still multi-bit
// abstract Yosys cells ($dffe / $adffe).  That gives exactly ONE CLKGATE_X1
// per logical register group (e.g. a 32-bit pipeline stage → 1 ICG + 32 DFFs)
// instead of one ICG per bit.
//
// Supported patterns  (positive-edge clock, positive enable):
//   $dffe            no reset            → CLKGATE_X1 + $dff
//   $adffe           async reset (any polarity) → CLKGATE_X1 + $adff
//
// Unsupported polarities fall through via _TECHMAP_FAIL_ and are handled
// later by dfflegalize + the fallback clockgate_map.v.
//
// Cell: CLKGATE_X1 (Nangate 45 nm)
//   CK  – pre-gate clock (positive edge)
//   E   – enable  (E=1 passes clock)
//   GCK – gated clock output

// ── $dffe : no reset ──────────────────────────────────────────────────────────
(* techmap_celltype = "$dffe" *)
module _cg_dffe_ #(
    parameter WIDTH        = 1,
    parameter CLK_POLARITY = 1,
    parameter EN_POLARITY  = 1
) (
    input              CLK, EN,
    input  [WIDTH-1:0] D,
    output [WIDTH-1:0] Q
);
    generate
        if (CLK_POLARITY == 1 && EN_POLARITY == 1) begin : do_gate
            wire GCK;
            CLKGATE_X1 icg (.CK(CLK), .E(EN), .GCK(GCK));
            \$dff #(.WIDTH(WIDTH), .CLK_POLARITY(1)) ff (.CLK(GCK), .D(D), .Q(Q));
        end else begin : skip
            wire _TECHMAP_FAIL_ = 1;
        end
    endgenerate
endmodule

// ── $adffe : async reset + enable ────────────────────────────────────────────
// ARST_POLARITY is passed through unchanged; async reset is independent of the
// clock, so gating with EN is always safe regardless of reset polarity.
(* techmap_celltype = "$adffe" *)
module _cg_adffe_ #(
    parameter WIDTH         = 1,
    parameter CLK_POLARITY  = 1,
    parameter ARST_POLARITY = 1,
    parameter ARST_VALUE    = 0,
    parameter EN_POLARITY   = 1
) (
    input              CLK, ARST, EN,
    input  [WIDTH-1:0] D,
    output [WIDTH-1:0] Q
);
    generate
        if (CLK_POLARITY == 1 && EN_POLARITY == 1) begin : do_gate
            wire GCK;
            CLKGATE_X1 icg (.CK(CLK), .E(EN), .GCK(GCK));
            \$adff #(
                .WIDTH(WIDTH),
                .CLK_POLARITY(1),
                .ARST_POLARITY(ARST_POLARITY),
                .ARST_VALUE(ARST_VALUE)
            ) ff (.CLK(GCK), .ARST(ARST), .D(D), .Q(Q));
        end else begin : skip
            wire _TECHMAP_FAIL_ = 1;
        end
    endgenerate
endmodule
