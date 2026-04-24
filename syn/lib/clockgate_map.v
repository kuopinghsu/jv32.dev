// ─────────────────────────────────────────────────────────────────────────────
// clockgate_map.v — Yosys techmap: $_DFFE_PP_ → CLKGATE_X1 + $_DFF_P_
//
// Technology: Nangate 45nm Open Cell Library (FreePDK45)
// ICG cell  : CLKGATE_X1  (pins: CK, E, GCK)
//             latch_posedge integrated cell — GCK = CK & E (E latched on
//             falling edge of CK, so the gate is glitch-free).
//
// Scope
// ─────
// Two Yosys FF cell types are mapped:
//
//   $_DFFE_PP_   — positive clock, positive enable, no reset
//                  Arises from: always_ff @(posedge clk) if (en) q <= d;
//
//   $_DFFE_PN0P_ — positive clock, negative async reset to 0, positive enable
//                  Arises from: always_ff @(posedge clk or negedge rst_n)
//                                 if (!rst_n) q <= 0; else if (en) q <= d;
//                  NOTE: the synthesis flow runs the fine stage manually with
//                  dfflegalize declaring $_DFFE_PN0P_ as a legal cell, so that
//                  Yosys does NOT decompose it into $_DFF_PN0_ + $_MUX_.
//
// In both cases the async-reset path (RN) on DFFR_X1 bypasses the clock gate,
// so the gate is safe: when RST fires GCK is gated but RN overrides Q directly.
//
// Post-techmap result
// ───────────────────
//   CLKGATE_X1 — already a liberty cell; dfflibmap leaves it untouched.
//   $_DFF_P_   — mapped by dfflibmap to DFF_X1.
//   $_DFF_PN0_ — mapped by dfflibmap to DFFR_X1.
// ─────────────────────────────────────────────────────────────────────────────

(* techmap_celltype = "$_DFFE_PP_" *)
module _cg_dffe_pp_ (input D, C, E, output Q);
    wire GCK;
    CLKGATE_X1 icg (.CK(C), .E(E), .GCK(GCK));
    \$_DFF_P_ ff (.D(D), .C(GCK), .Q(Q));
endmodule

// FF with async active-low reset to 0 + positive enable.
// CLKGATE_X1 gates the clock; DFFR_X1's RN pin overrides Q on reset.
(* techmap_celltype = "$_DFFE_PN0P_" *)
module _cg_dffe_pn0p_ (input D, C, R, E, output Q);
    wire GCK;
    CLKGATE_X1 icg (.CK(C), .E(E), .GCK(GCK));
    \$_DFF_PN0_ ff (.D(D), .C(GCK), .R(R), .Q(Q));
endmodule
