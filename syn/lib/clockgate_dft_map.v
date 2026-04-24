// ─────────────────────────────────────────────────────────────────────────────
// clockgate_dft_map.v — Yosys techmap: $_DFFE_PP_ → CLKGATETST_X1 + $_DFF_P_
//
// Technology: Nangate 45nm Open Cell Library (FreePDK45)
// ICG cell  : CLKGATETST_X1  (pins: CK, E, SE, GCK; area = 3.990 µm²)
//             latch_posedge_precontrol integrated cell.
//             SE=1 forces GCK = CK (scan test mode bypasses the latch).
//             SE is tied to 1'b0 for gate-count analysis (functional mode).
//
// Used when DFT_EN=1.  CLKGATETST_X1 is identical in function to CLKGATE_X1
// during normal operation (SE=0) but provides a test-mode bypass pin needed
// by ATPG to control clock domains during scan shift.
//
// Scope
// ─────
// Two Yosys FF cell types are mapped (same scope as clockgate_map.v but using
// CLKGATETST_X1 so that ATPG can bypass the latch via SE=1).
//
//   $_DFFE_PP_   — positive clock, positive enable, no reset
//   $_DFFE_PN0P_ — positive clock, negative async reset to 0, positive enable
//                  (preserved by running dfflegalize with $_DFFE_PN0P_ as a
//                   legal cell, preventing decomposition to $_DFF_PN0_ + $_MUX_)
//
// Post-techmap result
// ───────────────────
//   CLKGATETST_X1 — liberty cell; dfflibmap leaves it untouched.
//   $_DFF_P_      — caught by scan_map.v → SDFF_X1.
//   $_DFF_PN0_    — caught by scan_map.v → SDFFR_X1.
// ─────────────────────────────────────────────────────────────────────────────

(* techmap_celltype = "$_DFFE_PP_" *)
module _cg_dffe_pp_dft_ (input D, C, E, output Q);
    wire GCK;
    CLKGATETST_X1 icg (.CK(C), .E(E), .SE(1'b0), .GCK(GCK));
    \$_DFF_P_ ff (.D(D), .C(GCK), .Q(Q));
endmodule

// FF with async active-low reset to 0 + positive enable (DFT variant).
(* techmap_celltype = "$_DFFE_PN0P_" *)
module _cg_dffe_pn0p_dft_ (input D, C, R, E, output Q);
    wire GCK;
    CLKGATETST_X1 icg (.CK(C), .E(E), .SE(1'b0), .GCK(GCK));
    \$_DFF_PN0_ ff (.D(D), .C(GCK), .R(R), .Q(Q));
endmodule
