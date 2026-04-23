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
// Only Yosys $_DFFE_PP_ cells are mapped:
//   − Positive clock edge (P)
//   − Positive enable     (P)
//   − No asynchronous reset / preset
//
// These typically arise from register-file or pipeline registers that use
// a write-enable but do NOT have an active-low rst_n.
//
// FFs that DO have async reset (common rst_n pattern in jv32) are represented
// by Yosys as $_DFF_PN0_ + $_MUX_ after the fine-synthesis pass.  Those are
// intentionally left unmapped here: the async-reset path on DFFR_X1 is
// asynchronous and thus unaffected by the clock gate, but the combined
// pattern requires a more complex techmap.
//
// Post-techmap result
// ───────────────────
//   CLKGATE_X1  — already a liberty cell; dfflibmap leaves it untouched.
//   $_DFF_P_    — mapped by dfflibmap to DFF_X1.
// ─────────────────────────────────────────────────────────────────────────────

(* techmap_celltype = "$_DFFE_PP_" *)
module _cg_dffe_pp_ (input D, C, E, output Q);
    wire GCK;
    CLKGATE_X1 icg (.CK(C), .E(E), .GCK(GCK));
    \$_DFF_P_ ff (.D(D), .C(GCK), .Q(Q));
endmodule
