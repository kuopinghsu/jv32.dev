#!/usr/bin/env python3
"""
gen_flat_rvc.py — Generate jv32_rvc_flat.sv for SymbiYosys formal verification.

Produces a Yosys-compatible flat SystemVerilog file by:
  1. Including jv32_pkg.sv with the package wrapper stripped
  2. Including jv32_rvc.sv with "import jv32_pkg::*;" and debug macros removed
  3. Injecting formal assertions (ifdef FORMAL blocks) inside jv32_rvc

Run from repo root or from verif/formal/:
    python3 verif/formal/gen_flat_rvc.py

Output: verif/formal/jv32_rvc_flat.sv
"""

import os
import re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR   = os.path.normpath(os.path.join(SCRIPT_DIR, '..', '..'))
CORE_DIR   = os.path.join(ROOT_DIR, 'rtl', 'jv32', 'core')

PKG_FILE   = os.path.join(CORE_DIR, 'jv32_pkg.sv')
RVC_FILE   = os.path.join(CORE_DIR, 'jv32_rvc.sv')
DBGMSG_FILE = os.path.join(ROOT_DIR, 'rtl', 'jv32', 'jv32_dbgmsg.svh')
OUT_FILE   = os.path.join(SCRIPT_DIR, 'jv32_rvc_flat.sv')

# ---------------------------------------------------------------------------
# Formal assertions injected before "endmodule" in jv32_rvc.
#
# Properties cover the key invariants of the compressed-instruction expander:
#   P1. Output PC is always 2-byte aligned (LSB == 0).
#   P2. Compressed outputs keep orig_instr[31:16] == 0.
#   P3. 32-bit outputs are pass-through (instr_data == orig_instr).
#   P4. After a flush, hold_valid is de-asserted on the next cycle.
#   P5. instr_pc[0] is always 0 regardless of compressed/32-bit path.
#   P6. When stall=1, all state registers are stable on the next edge.
#   C1. A compressed instruction followed by a 32-bit instruction is reachable.
# ---------------------------------------------------------------------------
FORMAL_PROPS = r"""
`ifdef FORMAL
    // ========================================================================
    // Formal verification properties (injected by gen_flat_rvc.py)
    // ========================================================================

    // f_past_valid: 0 on the very first cycle (anyinit state), 1 thereafter.
    // Guards all properties so they never fire on the arbitrary anyinit state.
    (* keep *) reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    // Constrain inputs: hold rst_n low on the first cycle so the async reset
    // clears all internal registers before we start checking properties.
    // This eliminates false counterexamples from anyinit register values.
    always @(*) if (!f_past_valid) assume (!rst_n);

    // Track one-cycle-old values without relying on $past() anyinit.
    (* keep *) reg f_instr_valid_prev;
    (* keep *) reg f_is_compressed_prev;
    (* keep *) reg f_flush_prev;
    (* keep *) reg f_stall_prev;
    (* keep *) reg f_hold_valid_prev;
    (* keep *) reg [15:0] f_hold_prev;
    (* keep *) reg [31:0] f_hold_pc_prev;
    (* keep *) reg        f_hold_from_split_prev;
    (* keep *) reg        f_init_offset_prev;
    initial begin
        f_instr_valid_prev    = 1'b0;
        f_is_compressed_prev  = 1'b0;
        f_flush_prev          = 1'b0;
        f_stall_prev          = 1'b0;
        f_hold_valid_prev     = 1'b0;
        f_hold_prev           = 16'h0;
        f_hold_pc_prev        = 32'h0;
        f_hold_from_split_prev = 1'b0;
        f_init_offset_prev    = 1'b0;
    end
    always @(posedge clk) begin
        f_instr_valid_prev    <= instr_valid;
        f_is_compressed_prev  <= is_compressed;
        f_flush_prev          <= flush;
        f_stall_prev          <= stall;
        f_hold_valid_prev     <= hold_valid;
        f_hold_prev           <= hold;
        f_hold_pc_prev        <= hold_pc;
        f_hold_from_split_prev <= hold_from_split;
        f_init_offset_prev    <= init_offset;
    end

    // P1: Instruction PC always 2-byte aligned (bit 0 must be 0).
    always @(posedge clk) begin
        if (f_past_valid && rst_n && instr_valid) begin
            p1_instr_pc_aligned: assert (instr_pc[0] == 1'b0);
        end
    end

    // P2: Compressed output keeps orig_instr[31:16] == 16'h0.
    always @(posedge clk) begin
        if (f_past_valid && rst_n && instr_valid && is_compressed) begin
            p2_compressed_orig_hi_zero: assert (orig_instr[31:16] == 16'h0);
        end
    end

    // P3: 32-bit (non-compressed) output: instr_data is the same word as orig_instr.
    //     (The expander is a pass-through for 32-bit instructions.)
    always @(posedge clk) begin
        if (f_past_valid && rst_n && instr_valid && !is_compressed) begin
            p3_full32_passthrough: assert (instr_data == orig_instr);
        end
    end

    // P4: After flush, hold_valid must be 0 on the very next rising edge.
    always @(posedge clk) begin
        if (f_past_valid && rst_n && f_flush_prev) begin
            p4_flush_clears_hold: assert (!hold_valid);
        end
    end

    // P6: When stall=1 (and no flush), all internal state registers are stable (not changing).
    //     Note: flush takes priority over stall, so we also require !f_flush_prev.
    always @(posedge clk) begin
        if (f_past_valid && rst_n && f_stall_prev && !f_flush_prev && !flush) begin
            p6_stall_hold_stable:    assert (hold_valid      == f_hold_valid_prev);
            p6_stall_hold_data:      assert (hold            == f_hold_prev);
            p6_stall_hold_pc:        assert (hold_pc         == f_hold_pc_prev);
            p6_stall_hold_split:     assert (hold_from_split == f_hold_from_split_prev);
            p6_stall_init_offset:    assert (init_offset     == f_init_offset_prev);
        end
    end

    // P7: is_compressed implies orig_instr[1:0] != 2'b11.
    always @(posedge clk) begin
        if (f_past_valid && rst_n && instr_valid && is_compressed) begin
            p7_orig_not_32bit: assert (orig_instr[1:0] != 2'b11);
        end
    end

    // C1: Cover a compressed instruction followed by a 32-bit instruction.
    always @(posedge clk) begin
        if (f_past_valid && rst_n) begin
            c1_c_then_full32: cover (f_instr_valid_prev && f_is_compressed_prev &&
                                     instr_valid && !is_compressed);
        end
    end

    // Constrain inputs to legal / interesting ranges to reduce search space.
    always @(posedge clk) begin
        // Instruction memory always responds with naturally-aligned words.
        assume (imem_resp_pc[1:0] == 2'b00);
    end

`endif // FORMAL
"""

def read_file(path):
    with open(path, 'r', encoding='utf-8') as f:
        return f.readlines()

def process_pkg(lines, dbgmsg_lines):
    """Strip the package wrapper; inline jv32_dbgmsg.svh."""
    result = []
    for line in lines:
        stripped = line.strip()
        if re.match(r'`include\s+"jv32_dbgmsg\.svh"', stripped):
            result.append('// BEGIN inlined jv32_dbgmsg.svh\n')
            result.extend(dbgmsg_lines)
            result.append('// END inlined jv32_dbgmsg.svh\n')
        elif re.match(r'package\s+jv32_pkg\s*;', stripped):
            result.append(f'// STRIPPED (package wrapper): {line.rstrip()}\n')
        elif stripped == 'endpackage':
            result.append('// STRIPPED (package wrapper): endpackage\n')
        else:
            result.append(line)
    return result

def process_rvc(lines):
    """
    Strip 'import jv32_pkg::*;' and inject formal properties before endmodule.
    Also strip the debug macro guard block (ifndef SYNTHESIS ... always_ff block
    at the end) so sby doesn't see unsupported $display-like macros.
    """
    result = []
    in_nosyn_debug = False
    for line in lines:
        stripped = line.strip()
        # Remove package import
        if re.match(r'import\s+jv32_pkg\s*::\s*\*\s*;', stripped):
            result.append(f'// STRIPPED (package import): {line.rstrip()}\n')
            continue
        # The debug-only always_ff block at the end of jv32_rvc.sv is wrapped
        # in `ifndef SYNTHESIS ... `endif.  Since we compile with -DSYNTHESIS,
        # Yosys will not see it, but the Python flattener removes it anyway to
        # keep the flat file self-explanatory.
        if stripped == '`ifndef SYNTHESIS' and not in_nosyn_debug:
            # peek ahead to decide if this is the debug always_ff wrapper
            in_nosyn_debug = True
            result.append(f'// STRIPPED (`ifndef SYNTHESIS debug block)\n')
            continue
        if in_nosyn_debug:
            if stripped == '`endif':
                in_nosyn_debug = False
                result.append(f'// END STRIPPED\n')
            # else: skip every line inside the guard
            continue
        # Inject formal props before endmodule
        if stripped == 'endmodule':
            result.append(FORMAL_PROPS)
        result.append(line)
    return result

def main():
    pkg_lines    = read_file(PKG_FILE)
    rvc_lines    = read_file(RVC_FILE)
    dbgmsg_lines = read_file(DBGMSG_FILE)

    out = []
    out.append('// ============================================================\n')
    out.append('// AUTO-GENERATED by verif/formal/gen_flat_rvc.py\n')
    out.append('// DO NOT EDIT — regenerate with: python3 gen_flat_rvc.py\n')
    out.append('//\n')
    out.append('// Flat (package-free) version of jv32_rvc for SymbiYosys.\n')
    out.append('// Formal properties are injected inside the module when\n')
    out.append('// compiled with -DFORMAL.\n')
    out.append('// ============================================================\n')
    out.append('\n')
    out.append('// ============================================================\n')
    out.append('// Part 1: jv32_pkg.sv content (package wrapper stripped)\n')
    out.append('// ============================================================\n')
    out.extend(process_pkg(pkg_lines, dbgmsg_lines))
    out.append('\n')
    out.append('// ============================================================\n')
    out.append('// Part 2: jv32_rvc.sv content\n')
    out.append('// ============================================================\n')
    out.extend(process_rvc(rvc_lines))

    with open(OUT_FILE, 'w', encoding='utf-8') as f:
        f.writelines(out)

    print(f'Generated: {OUT_FILE}')

if __name__ == '__main__':
    main()
