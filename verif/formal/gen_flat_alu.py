#!/usr/bin/env python3
"""
gen_flat_alu.py — Generate jv32_alu_flat.sv for SymbiYosys formal verification.

Produces a Yosys-compatible flat SystemVerilog file by:
  1. Including jv32_pkg.sv with the package wrapper stripped
  2. Including jv32_alu.sv with "import jv32_pkg::*;" and `ifndef SYNTHESIS
     blocks removed
  3. Injecting formal assertions (ifdef FORMAL blocks) inside jv32_alu

The sby config (jv32_alu.sby) uses `chparam` to set:
    FAST_MUL=1, MUL_MC=0, FAST_DIV=1, FAST_SHIFT=1
making the ALU purely combinational so all properties can be checked at
depth 1 in a single SMT query.

Run from repo root or from verif/formal/:
    python3 verif/formal/gen_flat_alu.py

Output: verif/formal/jv32_alu_flat.sv
"""

import os
import re

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR    = os.path.normpath(os.path.join(SCRIPT_DIR, '..', '..'))
CORE_DIR    = os.path.join(ROOT_DIR, 'rtl', 'jv32', 'core')

PKG_FILE    = os.path.join(CORE_DIR, 'jv32_pkg.sv')
ALU_FILE    = os.path.join(CORE_DIR, 'jv32_alu.sv')
DBGMSG_FILE = os.path.join(ROOT_DIR, 'rtl', 'jv32', 'jv32_dbgmsg.svh')
OUT_FILE    = os.path.join(SCRIPT_DIR, 'jv32_alu_flat.sv')

# ---------------------------------------------------------------------------
# Formal assertions injected before "endmodule" in jv32_alu.
#
# The sby script overrides parameters to their fastest (combinational) values:
#   FAST_MUL=1, MUL_MC=0  -> 1-cycle combinatorial multiply (no pipeline)
#   FAST_DIV=1             -> 1-cycle combinatorial divide
#   FAST_SHIFT=1           -> barrel shifter
#   RV32B_EN=1, RV32M_EN=1 (defaults kept)
#
# With these parameters the entire ALU is combinational and ready is always 1.
# All assertions use always_comb so they are checked at every time step.
#
# ALU opcode constants (from jv32_pkg.sv alu_op_e):
#   ALU_ADD=0   ALU_SUB=1   ALU_SLL=2   ALU_SLT=3   ALU_SLTU=4
#   ALU_XOR=5   ALU_SRL=6   ALU_SRA=7   ALU_OR=8    ALU_AND=9
#   ALU_MUL=10  ALU_MULH=11 ALU_MULHSU=12 ALU_MULHU=13
#   ALU_DIV=14  ALU_DIVU=15 ALU_REM=16  ALU_REMU=17
#   ALU_SH1ADD=18 ALU_SH2ADD=19 ALU_SH3ADD=20
#   ALU_CLZ=21  ALU_CTZ=22  ALU_CPOP=23
#   ALU_ANDN=24 ALU_ORN=25  ALU_XNOR=26
#   ALU_MIN=27  ALU_MINU=28 ALU_MAX=29  ALU_MAXU=30
#   ALU_SEXTB=31 ALU_SEXTH=32 ALU_ZEXTH=33
#   ALU_ROL=34  ALU_ROR=35  ALU_ORCB=36 ALU_REV8=37
#   ALU_BCLR=38 ALU_BEXT=39 ALU_BINV=40 ALU_BSET=41
# ---------------------------------------------------------------------------
FORMAL_PROPS = r"""
`ifdef FORMAL
    // ========================================================================
    // Formal verification properties (injected by gen_flat_alu.py)
    // ========================================================================
    //
    // Verified with fast-path parameters (FAST_MUL=1, MUL_MC=0, FAST_DIV=1,
    // FAST_SHIFT=1) set via chparam in jv32_alu.sby.
    // The entire ALU is combinational in that configuration.

    // P1: ready is always 1 for the fast-path configuration.
    always_comb begin
        p1_ready: assert (ready == 1'b1);
    end

    // ---- Base integer operations (RV32I) --------------------------------

    // P2: ADD result.
    always_comb begin
        if (alu_op == 6'd0) // ALU_ADD
            p2_add: assert (result == operand_a + operand_b);
    end

    // P3: SUB result.
    always_comb begin
        if (alu_op == 6'd1) // ALU_SUB
            p3_sub: assert (result == operand_a - operand_b);
    end

    // P4: SLT – signed less-than, result is 0 or 1.
    always_comb begin
        if (alu_op == 6'd3) // ALU_SLT
            p4_slt: assert (result == ($signed(operand_a) < $signed(operand_b) ? 32'd1 : 32'd0));
    end

    // P5: SLTU – unsigned less-than, result is 0 or 1.
    always_comb begin
        if (alu_op == 6'd4) // ALU_SLTU
            p5_sltu: assert (result == (operand_a < operand_b ? 32'd1 : 32'd0));
    end

    // P6: XOR.
    always_comb begin
        if (alu_op == 6'd5) // ALU_XOR
            p6_xor: assert (result == (operand_a ^ operand_b));
    end

    // P7: OR.
    always_comb begin
        if (alu_op == 6'd8) // ALU_OR
            p7_or: assert (result == (operand_a | operand_b));
    end

    // P8: AND.
    always_comb begin
        if (alu_op == 6'd9) // ALU_AND
            p8_and: assert (result == (operand_a & operand_b));
    end

    // ---- Shift operations (barrel shifter, FAST_SHIFT=1) ----------------

    // P9: SLL – logical left shift.
    always_comb begin
        if (alu_op == 6'd2) // ALU_SLL
            p9_sll: assert (result == (operand_a << operand_b[4:0]));
    end

    // P10: SRL – logical right shift.
    always_comb begin
        if (alu_op == 6'd6) // ALU_SRL
            p10_srl: assert (result == (operand_a >> operand_b[4:0]));
    end

    // P11: SRA – arithmetic right shift.
    always_comb begin
        if (alu_op == 6'd7) // ALU_SRA
            p11_sra: assert (result == 32'($signed(operand_a) >>> operand_b[4:0]));
    end

    // ---- RV32M: multiply (FAST_MUL=1, MUL_MC=0 -> 1-cycle combinatorial) --

    // P12: MUL – lower 32 bits of product.
    always_comb begin
        if (alu_op == 6'd10) // ALU_MUL
            p12_mul_lo: assert (result == (operand_a * operand_b));
    end

    // ---- RV32M: divide (FAST_DIV=1 -> combinatorial) --------------------

    // P13: DIV by zero -> all-ones.
    always_comb begin
        if (alu_op == 6'd14 && operand_b == 32'h0) // ALU_DIV, divisor=0
            p13_div_by_zero: assert (result == 32'hffffffff);
    end

    // P14: DIVU by zero -> all-ones.
    always_comb begin
        if (alu_op == 6'd15 && operand_b == 32'h0) // ALU_DIVU, divisor=0
            p14_divu_by_zero: assert (result == 32'hffffffff);
    end

    // P15: DIV signed overflow (INT_MIN / -1 = INT_MIN per RISC-V spec).
    always_comb begin
        if (alu_op == 6'd14 && operand_a == 32'h80000000 && operand_b == 32'hffffffff)
            p15_div_overflow: assert (result == 32'h80000000);
    end

    // P16: REM by zero returns the dividend.
    always_comb begin
        if (alu_op == 6'd16 && operand_b == 32'h0) // ALU_REM, divisor=0
            p16_rem_by_zero: assert (result == operand_a);
    end

    // P17: REMU by zero returns the dividend.
    always_comb begin
        if (alu_op == 6'd17 && operand_b == 32'h0) // ALU_REMU, divisor=0
            p17_remu_by_zero: assert (result == operand_a);
    end

    // ---- Zba: address-generation shift-add (RV32B_EN=1) ----------------

    // P18: SH1ADD = (rs1 << 1) + rs2.
    always_comb begin
        if (alu_op == 6'd18) // ALU_SH1ADD
            p18_sh1add: assert (result == ((operand_a << 1) + operand_b));
    end

    // P19: SH2ADD = (rs1 << 2) + rs2.
    always_comb begin
        if (alu_op == 6'd19) // ALU_SH2ADD
            p19_sh2add: assert (result == ((operand_a << 2) + operand_b));
    end

    // P20: SH3ADD = (rs1 << 3) + rs2.
    always_comb begin
        if (alu_op == 6'd20) // ALU_SH3ADD
            p20_sh3add: assert (result == ((operand_a << 3) + operand_b));
    end

    // ---- Zbb: bit-manipulation (RV32B_EN=1) -----------------------------

    // P21: ANDN = rs1 & ~rs2.
    always_comb begin
        if (alu_op == 6'd24) // ALU_ANDN
            p21_andn: assert (result == (operand_a & ~operand_b));
    end

    // P22: ORN = rs1 | ~rs2.
    always_comb begin
        if (alu_op == 6'd25) // ALU_ORN
            p22_orn: assert (result == (operand_a | ~operand_b));
    end

    // P23: XNOR = rs1 ^ ~rs2.
    always_comb begin
        if (alu_op == 6'd26) // ALU_XNOR
            p23_xnor: assert (result == (operand_a ^ ~operand_b));
    end

    // P24: MIN – signed minimum, result is one of the two operands.
    always_comb begin
        if (alu_op == 6'd27) begin // ALU_MIN
            p24_min_val:   assert (result == ($signed(operand_a) < $signed(operand_b) ? operand_a : operand_b));
            p24_min_one_of: assert (result == operand_a || result == operand_b);
        end
    end

    // P25: MINU – unsigned minimum.
    always_comb begin
        if (alu_op == 6'd28) // ALU_MINU
            p25_minu: assert (result == (operand_a < operand_b ? operand_a : operand_b));
    end

    // P26: MAX – signed maximum.
    always_comb begin
        if (alu_op == 6'd29) // ALU_MAX
            p26_max: assert (result == ($signed(operand_a) > $signed(operand_b) ? operand_a : operand_b));
    end

    // P27: MAXU – unsigned maximum.
    always_comb begin
        if (alu_op == 6'd30) // ALU_MAXU
            p27_maxu: assert (result == (operand_a > operand_b ? operand_a : operand_b));
    end

    // P28: SEXT.B – sign-extend byte.
    always_comb begin
        if (alu_op == 6'd31) // ALU_SEXTB
            p28_sextb: assert (result == {{24{operand_a[7]}}, operand_a[7:0]});
    end

    // P29: SEXT.H – sign-extend halfword.
    always_comb begin
        if (alu_op == 6'd32) // ALU_SEXTH
            p29_sexth: assert (result == {{16{operand_a[15]}}, operand_a[15:0]});
    end

    // P30: ZEXT.H – zero-extend halfword.
    always_comb begin
        if (alu_op == 6'd33) // ALU_ZEXTH
            p30_zexth: assert (result == {16'd0, operand_a[15:0]});
    end

    // P31: ROL – rotate left.
    always_comb begin
        if (alu_op == 6'd34) // ALU_ROL
            p31_rol: assert (result == ((operand_a << operand_b[4:0]) | (operand_a >> (5'(32) - operand_b[4:0]))));
    end

    // P32: ROR – rotate right.
    always_comb begin
        if (alu_op == 6'd35) // ALU_ROR
            p32_ror: assert (result == ((operand_a >> operand_b[4:0]) | (operand_a << (5'(32) - operand_b[4:0]))));
    end

    // P33: ORC.B – OR-combine: each byte becomes 0xff if any bit set, else 0x00.
    always_comb begin
        if (alu_op == 6'd36) begin // ALU_ORCB
            p33_orcb: assert (result == {
                {8{|operand_a[31:24]}}, {8{|operand_a[23:16]}},
                {8{|operand_a[15:8]}},  {8{|operand_a[7:0]}}
            });
        end
    end

    // P34: REV8 – byte-reverse.
    always_comb begin
        if (alu_op == 6'd37) // ALU_REV8
            p34_rev8: assert (result == {operand_a[7:0], operand_a[15:8], operand_a[23:16], operand_a[31:24]});
    end

    // ---- Zbs: single-bit manipulation (RV32B_EN=1) ----------------------

    // P35: BCLR – clear bit at position rs2[4:0].
    always_comb begin
        if (alu_op == 6'd38) // ALU_BCLR
            p35_bclr: assert (result == (operand_a & ~(32'd1 << operand_b[4:0])));
    end

    // P36: BEXT – extract bit at position rs2[4:0], result is 0 or 1.
    always_comb begin
        if (alu_op == 6'd39) begin // ALU_BEXT
            p36_bext_range: assert (result[31:1] == 31'd0);
            p36_bext_val:   assert (result[0] == operand_a[operand_b[4:0]]);
        end
    end

    // P37: BINV – invert bit at position rs2[4:0].
    always_comb begin
        if (alu_op == 6'd40) // ALU_BINV
            p37_binv: assert (result == (operand_a ^ (32'd1 << operand_b[4:0])));
    end

    // P38: BSET – set bit at position rs2[4:0].
    always_comb begin
        if (alu_op == 6'd41) // ALU_BSET
            p38_bset: assert (result == (operand_a | (32'd1 << operand_b[4:0])));
    end

`endif // FORMAL
"""

def read_file(path):
    with open(path, 'r', encoding='utf-8') as f:
        return f.readlines()

def process_pkg(lines, dbgmsg_lines):
    """Strip the package wrapper; inline jv32_dbgmsg.svh.

    Also strips package localparams whose names collide with jv32_alu module
    parameters.  When the package is inlined (wrapper stripped), these become
    file-scope declarations and Yosys resolves them in favour of the outer
    (package) scope rather than the inner module parameter — causing the wrong
    generate branch to be selected.  The affected names are:
        FAST_MUL, MUL_MC, FAST_DIV, FAST_SHIFT, RV32M_EN, RV32B_EN
    """
    # Localparams from jv32_pkg that share names with jv32_alu's parameters.
    pkg_params_to_strip = {
        'FAST_MUL', 'MUL_MC', 'FAST_DIV', 'FAST_SHIFT', 'RV32M_EN', 'RV32B_EN',
    }
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
            # Strip conflicting localparams (e.g. "localparam ... FAST_DIV ...").
            m = re.match(r'\s*localparam\b.*?\b(' +
                         '|'.join(re.escape(n) for n in pkg_params_to_strip) +
                         r')\b', line)
            if m:
                result.append(
                    f'// STRIPPED (conflicts with module param): {line.rstrip()}\n')
            else:
                result.append(line)
    return result

def process_alu(lines):
    """
    Strip 'import jv32_pkg::*;', handle `ifndef SYNTHESIS blocks, and inject
    formal properties before endmodule.

    For `ifndef SYNTHESIS ... `else ... `endif:
      - Strip the `ifndef SYNTHESIS branch (simulation-only content).
      - Keep the `else branch (-DSYNTHESIS content, e.g. alu_op port type).
    For `ifndef SYNTHESIS ... `endif with no `else:
      - Strip the entire block.

    Parameter overrides for the formal fast-path configuration (purely
    combinational ALU so all assertions are valid at depth 1):
      MUL_MC=0   : 1-cycle comb. multiply instead of 2-stage pipeline.
      FAST_DIV=1 : 1-cycle comb. divide instead of serial restoring divider.
    These are baked into the parameter defaults so that Yosys elaborates the
    correct generate blocks (chparam cannot retroactively change generates).
    """
    # Parameter default substitutions for the formal fast-path configuration.
    # Only non-default values are listed (FAST_MUL=1, FAST_SHIFT=1, RV32M_EN=1,
    # RV32B_EN=1 are already the defaults in jv32_alu.sv).
    param_overrides = {
        'MUL_MC':   ('1\'b1', '1\'b0'),   # 2-stage pipeline -> 1-cycle comb.
        'FAST_DIV': ('1\'b0', '1\'b1'),   # serial divider   -> comb. divider
    }

    result = []
    in_nosyn   = False   # inside a `ifndef SYNTHESIS block
    nosyn_keep = False   # True once we cross `else into the keep branch
    for line in lines:
        stripped = line.strip()
        # Remove package import
        if re.match(r'import\s+jv32_pkg\s*::\s*\*\s*;', stripped):
            result.append(f'// STRIPPED (package import): {line.rstrip()}\n')
            continue
        # Begin `ifndef SYNTHESIS guard
        if stripped == '`ifndef SYNTHESIS' and not in_nosyn:
            in_nosyn   = True
            nosyn_keep = False
            result.append('// STRIPPED (`ifndef SYNTHESIS block)\n')
            continue
        if in_nosyn:
            if stripped == '`else':
                nosyn_keep = True
                continue
            elif stripped == '`endif':
                in_nosyn   = False
                nosyn_keep = False
                result.append('// END STRIPPED\n')
                continue
            elif nosyn_keep:
                result.append(line)
            continue
        # Apply fast-path parameter overrides (in the module parameter list).
        for pname, (old_val, new_val) in param_overrides.items():
            pat = rf'(parameter\s+bit\s+{re.escape(pname)}\s*=\s*){re.escape(old_val)}'
            m = re.search(pat, line)
            if m:
                line = line[:m.start(1)] + m.group(1) + new_val + \
                       line[m.start(1) + len(m.group(1)) + len(old_val):]
                # Append a note to the line's comment (strip trailing newline first)
                line = line.rstrip('\n') + \
                       f'  // FORMAL override: {old_val} -> {new_val}\n'
                break
        # Inject formal props before endmodule
        if stripped == 'endmodule':
            result.append(FORMAL_PROPS)
        result.append(line)
    return result

def main():
    pkg_lines    = read_file(PKG_FILE)
    alu_lines    = read_file(ALU_FILE)
    dbgmsg_lines = read_file(DBGMSG_FILE)

    out = []
    out.append('// ============================================================\n')
    out.append('// AUTO-GENERATED by verif/formal/gen_flat_alu.py\n')
    out.append('// DO NOT EDIT — regenerate with: python3 gen_flat_alu.py\n')
    out.append('//\n')
    out.append('// Flat (package-free) version of jv32_alu for SymbiYosys.\n')
    out.append('// Formal properties are injected inside the module when\n')
    out.append('// compiled with -DFORMAL.\n')
    out.append('// sby uses baked-in parameter defaults MUL_MC=0, FAST_DIV=1\n')
    out.append('// (purely combinational ALU; all properties at depth 1).\n')
    out.append('// ============================================================\n')
    out.append('\n')
    out.append('// ============================================================\n')
    out.append('// Part 1: jv32_pkg.sv content (package wrapper stripped)\n')
    out.append('// ============================================================\n')
    out.extend(process_pkg(pkg_lines, dbgmsg_lines))
    out.append('\n')
    out.append('// ============================================================\n')
    out.append('// Part 2: jv32_alu.sv content\n')
    out.append('// ============================================================\n')
    out.extend(process_alu(alu_lines))

    with open(OUT_FILE, 'w', encoding='utf-8') as f:
        f.writelines(out)

    print(f'Generated: {OUT_FILE}')

if __name__ == '__main__':
    main()
