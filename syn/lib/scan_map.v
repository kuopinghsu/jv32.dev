// ─────────────────────────────────────────────────────────────────────────────
// scan_map.v — Yosys techmap: DFF primitives → scan flip-flops (SDFF_X1 /
//              SDFFR_X1) for DFT gate-count analysis.
//
// Technology: Nangate 45nm Open Cell Library (FreePDK45)
//
//   SDFF_X1   — D, SI, SE, CK → Q (area = 6.118 µm²)
//                 SE=0: Q = D on rising CK  (capture mode)
//                 SE=1: Q = SI on rising CK (scan shift mode)
//
//   SDFFR_X1  — D, SI, SE, CK, RN → Q (area = 6.650 µm²)
//                 SE=0: Q = D on rising CK; RN=0: async reset to 0
//                 SE=1: Q = SI on rising CK (scan shift mode)
//
// Usage in hier_synth.sh (DFT_EN=1 flow)
// ──────────────────────────────────────
//   Step 1: synth -run begin:map        (fine synthesis; produces $_DFF_* cells)
//   Step 2: techmap -map clockgate_dft_map.v
//             $_DFFE_PP_ → CLKGATETST_X1 + $_DFF_P_
//   Step 3: techmap -map scan_map.v     (this file)
//             $_DFF_P_   → SDFF_X1
//             $_DFF_PN0_ → SDFFR_X1
//   Step 4: dfflibmap + abc             (combinational + any residual DFFs)
//
// SI and SE are tied to 1'b0 for gate-count analysis (functional mode).
// Scan chain stitching (connecting SI/Q between scan cells) is performed
// by OpenROAD ScanInsert during the P&R DFT flow, not by Yosys.
// ─────────────────────────────────────────────────────────────────────────────

// ── $_DFF_P_: positive clock edge, no reset, no enable ──────────────────────
// Arises from: (a) direct DFFs without reset/enable, and
//              (b) $_DFF_P_ emitted by clockgate_dft_map.v for each ICG output.
(* techmap_celltype = "$_DFF_P_" *)
module _scan_dff_p_ (input D, C, output Q);
    SDFF_X1 ff (.D(D), .CK(C), .SE(1'b0), .SI(1'b0), .Q(Q));
endmodule

// ── $_DFF_PN0_: positive clock edge, negative async reset (active-low) ──────
// Typical pattern in jv32: FF with rst_n (DFFR_X1 data-path family).
// Maps to SDFFR_X1 which has the same active-low RN async-reset pin.
(* techmap_celltype = "$_DFF_PN0_" *)
module _scan_dff_pn0_ (input D, C, R, output Q);
    SDFFR_X1 ff (.D(D), .CK(C), .RN(R), .SE(1'b0), .SI(1'b0), .Q(Q));
endmodule
