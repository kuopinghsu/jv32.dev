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
// Only Yosys $_DFFE_PP_ cells are mapped:
//   − Positive clock edge (P)
//   − Positive enable     (P)
//   − No asynchronous reset / preset
//
// FFs with async reset are represented as $_DFF_PN0_ + $_MUX_ after the
// fine-synthesis pass and are left for scan_map.v to handle.
//
// Post-techmap result
// ───────────────────
//   CLKGATETST_X1  — liberty cell; dfflibmap leaves it untouched.
//   $_DFF_P_       — caught by scan_map.v → SDFF_X1.
// ─────────────────────────────────────────────────────────────────────────────

(* techmap_celltype = "$_DFFE_PP_" *)
module _cg_dffe_pp_dft_ (input D, C, E, output Q);
    wire GCK;
    CLKGATETST_X1 icg (.CK(C), .E(E), .SE(1'b0), .GCK(GCK));
    \$_DFF_P_ ff (.D(D), .C(GCK), .Q(Q));
endmodule
