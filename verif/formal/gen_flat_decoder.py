#!/usr/bin/env python3
"""
gen_flat_decoder.py — Generate jv32_decoder_flat.sv for SymbiYosys formal verification.

Produces a Yosys-compatible flat SystemVerilog file by:
  1. Including jv32_pkg.sv with the package wrapper stripped
  2. Including jv32_decoder.sv with "import jv32_pkg::*;" removed
  3. Injecting formal assertions (ifdef FORMAL blocks) inside jv32_decoder

Run from repo root or from verif/formal/:
    python3 verif/formal/gen_flat_decoder.py

Output: verif/formal/jv32_decoder_flat.sv
"""

import os
import re

SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR     = os.path.normpath(os.path.join(SCRIPT_DIR, '..', '..'))
CORE_DIR     = os.path.join(ROOT_DIR, 'rtl', 'jv32', 'core')

PKG_FILE     = os.path.join(CORE_DIR, 'jv32_pkg.sv')
DECODER_FILE = os.path.join(CORE_DIR, 'jv32_decoder.sv')
DBGMSG_FILE  = os.path.join(ROOT_DIR, 'rtl', 'jv32', 'jv32_dbgmsg.svh')
OUT_FILE     = os.path.join(SCRIPT_DIR, 'jv32_decoder_flat.sv')

# ---------------------------------------------------------------------------
# Formal assertions injected before "endmodule" in jv32_decoder.
#
# jv32_decoder is purely combinational (no clk/rst).  Properties are checked
# as immediate assertions inside an always_comb block so SymbiYosys can verify
# them as combinational safety properties (mode prove, depth 1 is sufficient).
# ---------------------------------------------------------------------------
FORMAL_PROPS = r"""
`ifdef FORMAL
    // ========================================================================
    // Formal verification properties (injected by gen_flat_decoder.py)
    // ========================================================================

    // P1: Mutual exclusion among the five PC-modifier flags.
    //     At most one of {jal, jalr, branch, lui, auipc} may be asserted.
    //     (lui and auipc don't redirect PC, but they do write the register file
    //     with PC-relative/absolute immediates, so they are in this group.)
    always_comb begin
        if (valid) begin
            p1_pc_mod_onehot0: assert ($onehot0({jal, jalr, branch, lui, auipc}));
        end
    end

    // P2: Conditional write-back implies reg_we.
    //     jal, jalr, lui, and auipc always write rd; branch never writes rd.
    always_comb begin
        if (valid) begin
            p2_jal_reg_we:   assert (!jal   || reg_we);
            p2_jalr_reg_we:  assert (!jalr  || reg_we);
            p2_lui_reg_we:   assert (!lui   || reg_we);
            p2_auipc_reg_we: assert (!auipc || reg_we);
            p2_branch_no_we: assert (!branch || !reg_we);
        end
    end

    // P3: Memory read and write are mutually exclusive.
    always_comb begin
        if (valid) begin
            p3_mem_rw_excl: assert (!(mem_read && mem_write));
        end
    end

    // P4: Register file address fields are taken directly from instr[].
    //     This holds regardless of valid (the wires are always connected).
    always_comb begin
        p4_rs1_from_instr: assert (rs1_addr == instr[19:15]);
        p4_rs2_from_instr: assert (rs2_addr == instr[24:20]);
        p4_rd_from_instr:  assert (rd_addr  == instr[11:7]);
        p4_csr_from_instr: assert (csr_addr == instr[31:20]);
    end

    // P5: When valid=0 the decoder must produce safe (de-asserted) outputs.
    //     Control signals that could trigger side-effects must be 0.
    always_comb begin
        if (!valid) begin
            p5_no_mem_read:  assert (!mem_read);
            p5_no_mem_write: assert (!mem_write);
            p5_no_reg_we:    assert (!reg_we);
            p5_no_branch:    assert (!branch);
            p5_no_jal:       assert (!jal);
            p5_no_jalr:      assert (!jalr);
            p5_no_is_mret:   assert (!is_mret);
            p5_no_is_ecall:  assert (!is_ecall);
            p5_no_is_ebreak: assert (!is_ebreak);
            p5_no_is_amo:    assert (!is_amo);
            p5_no_illegal:   assert (!illegal);
        end
    end

    // P6: LOAD instructions always produce mem_read=1, mem_write=0, reg_we=1.
    //     OPCODE_LOAD = 7'b0000011.
    always_comb begin
        if (valid && instr[6:0] == 7'b0000011 && !illegal) begin
            p6_load_mem_read:  assert (mem_read);
            p6_load_no_write:  assert (!mem_write);
            p6_load_reg_we:    assert (reg_we);
        end
    end

    // P7: STORE instructions always produce mem_write=1, mem_read=0, reg_we=0.
    //     OPCODE_STORE = 7'b0100011.
    always_comb begin
        if (valid && instr[6:0] == 7'b0100011 && !illegal) begin
            p7_store_mem_write: assert (mem_write);
            p7_store_no_read:   assert (!mem_read);
            p7_store_no_we:     assert (!reg_we);
        end
    end

    // P8: Exception-type signals are mutually exclusive.
    always_comb begin
        if (valid) begin
            p8_exc_onehot0: assert ($onehot0({is_mret, is_ecall, is_ebreak, is_wfi}));
        end
    end

    // P9: AMO instructions always assert both mem_read and reg_we.
    //     (AMO reads and writes the memory location, and writes rd.)
    always_comb begin
        if (valid && is_amo) begin
            p9_amo_mem_read: assert (mem_read);
            p9_amo_reg_we:   assert (reg_we);
        end
    end

    // P10: JAL immediate encoding — bit 0 of the J-type immediate is always 0
    //      (the ISA encodes a 2-byte-aligned offset; the decoder must preserve this).
    always_comb begin
        if (valid && jal) begin
            p10_jal_imm_aligned: assert (imm[0] == 1'b0);
        end
    end

    // P11: BRANCH immediate encoding — bit 0 must be 0 (B-type immediate).
    always_comb begin
        if (valid && branch) begin
            p11_branch_imm_aligned: assert (imm[0] == 1'b0);
        end
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

def process_decoder(lines):
    """
    Strip 'import jv32_pkg::*;' and inject formal properties before endmodule.
    """
    result = []
    for line in lines:
        stripped = line.strip()
        if re.match(r'import\s+jv32_pkg\s*::\s*\*\s*;', stripped):
            result.append(f'// STRIPPED (package import): {line.rstrip()}\n')
        elif stripped == 'endmodule':
            result.append(FORMAL_PROPS)
            result.append(line)
        else:
            result.append(line)
    return result

def main():
    pkg_lines     = read_file(PKG_FILE)
    decoder_lines = read_file(DECODER_FILE)
    dbgmsg_lines  = read_file(DBGMSG_FILE)

    out = []
    out.append('// ============================================================\n')
    out.append('// AUTO-GENERATED by verif/formal/gen_flat_decoder.py\n')
    out.append('// DO NOT EDIT — regenerate with: python3 gen_flat_decoder.py\n')
    out.append('//\n')
    out.append('// Flat (package-free) version of jv32_decoder for SymbiYosys.\n')
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
    out.append('// Part 2: jv32_decoder.sv content\n')
    out.append('// ============================================================\n')
    out.extend(process_decoder(decoder_lines))

    with open(OUT_FILE, 'w', encoding='utf-8') as f:
        f.writelines(out)

    print(f'Generated: {OUT_FILE}')

if __name__ == '__main__':
    main()
