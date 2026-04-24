// clockgate_hier_dft_map.v — hierarchical (multi-bit) clock gating techmap
//                            for DFT mode (CLKGATETST_X1).
//
// Same as clockgate_hier_map.v but uses CLKGATETST_X1 which adds a scan
// enable (SE) port for test insertion.  SE is tied low here; the DFT P&R
// flow connects the actual scan chain.
//
// Cell: CLKGATETST_X1 (Nangate 45 nm)
//   CK  – pre-gate clock
//   E   – enable  (E=1 passes clock)
//   SE  – scan enable (SE=1 forces clock on during scan)
//   GCK – gated clock output

// ── $dffe : no reset ──────────────────────────────────────────────────────────
(* techmap_celltype = "$dffe" *)
module _cg_dffe_dft_ #(
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
            CLKGATETST_X1 icg (.CK(CLK), .E(EN), .SE(1'b0), .GCK(GCK));
            \$dff #(.WIDTH(WIDTH), .CLK_POLARITY(1)) ff (.CLK(GCK), .D(D), .Q(Q));
        end else begin : skip
            wire _TECHMAP_FAIL_ = 1;
        end
    endgenerate
endmodule

// ── $adffe : async reset + enable ────────────────────────────────────────────
(* techmap_celltype = "$adffe" *)
module _cg_adffe_dft_ #(
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
            CLKGATETST_X1 icg (.CK(CLK), .E(EN), .SE(1'b0), .GCK(GCK));
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
