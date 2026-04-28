#!/usr/bin/env python3
"""
gen_flat_csr.py — Generate jv32_csr_flat.sv for SymbiYosys formal verification.

Produces a Yosys-0.33-compatible flat SystemVerilog file by:
  1. Inlining jv32_dbgmsg.svh (makes flat file self-contained)
  2. Including jv32_pkg.sv with the package wrapper stripped
  3. Including jv32_csr.sv with "import jv32_pkg::*;" removed
  4. Injecting formal assertions (ifdef FORMAL blocks) inside jv32_csr

Run from repo root or from verif/formal/:
    python3 verif/formal/gen_flat_csr.py

Output: verif/formal/jv32_csr_flat.sv
"""

import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR   = os.path.normpath(os.path.join(SCRIPT_DIR, '..', '..'))
RTL_DIR    = os.path.join(ROOT_DIR, 'rtl', 'jv32')
CORE_DIR   = os.path.join(RTL_DIR, 'core')

PKG_FILE    = os.path.join(CORE_DIR, 'jv32_pkg.sv')
CSR_FILE    = os.path.join(CORE_DIR, 'jv32_csr.sv')
DBGMSG_FILE = os.path.join(RTL_DIR,  'jv32_dbgmsg.svh')
OUT_FILE    = os.path.join(SCRIPT_DIR, 'jv32_csr_flat.sv')


# ---------------------------------------------------------------------------
# Formal assertions to inject before "endmodule" in jv32_csr
# ---------------------------------------------------------------------------
FORMAL_PROPS = r"""
`ifdef FORMAL
    // ========================================================================
    // Formal verification properties (injected by gen_flat_csr.py)
    // ========================================================================

    // P1: MEPC is always word-aligned (bit 0 must be 0)
    always @(posedge clk) begin
        if (rst_n) begin
            p1_mepc_aligned: assert (mepc_o[0] == 1'b0);
        end
    end

    // P2: MTVEC bit 1 is always zero (hardware forces {wd[31:2],1'b0,wd[0]})
    always @(posedge clk) begin
        if (rst_n) begin
            p2_mtvec_bit1_zero: assert (mtvec_o[1] == 1'b0);
        end
    end

    // P3: MIE only keeps bits {11,7,3}; all others stay zero after any write
    always @(posedge clk) begin
        if (rst_n) begin
            p3_mie_reserved_zero: assert ((mie_reg & 32'hFFFF_F777) == 32'h0);
        end
    end

    // Explicit past-value registers (avoids Yosys $past() anyinit entries).
    // All initialized to 0 (consistent with: everything was in reset before cycle 0).
    (* keep *) reg past_exception;
    (* keep *) reg past_rst_n;
    (* keep *) reg past_irq_active;
    (* keep *) reg past_mstatus_mie;
    (* keep *) reg formal_saw_exception;
    initial begin
        past_exception     = 1'b0;
        past_rst_n         = 1'b0;
        past_irq_active    = 1'b0;
        past_mstatus_mie   = 1'b0;
        formal_saw_exception = 1'b0;
    end
    always @(posedge clk) begin
        past_exception   <= exception;
        past_rst_n       <= rst_n;
        past_irq_active  <= irq_pending && mstatus_mie && wb_valid;
        past_mstatus_mie <= mstatus_mie;
        if (!rst_n) formal_saw_exception <= 1'b0;
        else if (exception) formal_saw_exception <= 1'b1;
    end

    // P4: Exception clears MIE in the cycle after the exception
    always @(posedge clk) begin
        if (rst_n && past_exception && past_rst_n) begin
            p4_mie_clears_on_exception: assert (!mstatus_mie);
        end
    end

    // P5: Interrupt acceptance clears MIE in the following cycle
    always @(posedge clk) begin
        if (rst_n && past_irq_active) begin
            p5_mie_clears_on_irq: assert (!mstatus_mie);
        end
    end

    // P6: MISA is read-only — reading address 0x301 always returns MISA_VAL
    always @(posedge clk) begin
        if (rst_n && csr_addr == 12'h301) begin
            p6_misa_readonly: assert (csr_rdata == MISA_VAL);
        end
    end

    // P7: MPIE captures the pre-exception value of MIE
    always @(posedge clk) begin
        if (rst_n && past_exception && past_rst_n) begin
            p7_mpie_saves_mie: assert (mstatus_mpie == past_mstatus_mie);
        end
    end

    // C1: Cover that an exception followed by MRET is reachable
    always @(posedge clk) begin
        if (rst_n && formal_saw_exception) begin
            c1_exception_then_mret: cover (mret);
        end
    end

    // Initialize all CSR registers to their reset values (all zero) so the
    // formalff pass produces zero anyinit entries. Verification starts from
    // reset state; BMC depth ≥ 3 can reach all interesting scenarios.
    initial begin
        // mstatus fields
        mstatus_mie      = 1'b0;
        mstatus_mpie     = 1'b0;
        // CSR data registers
        mtvec_reg        = 32'h0;
        mscratch_reg     = 32'h0;
        mepc_reg         = 32'h0;
        mcause_reg       = 32'h0;
        mtval_reg        = 32'h0;
        mie_reg          = 32'h0;
        mtvt_reg         = 32'h0;
        // 8-bit registers
        mintthresh_reg   = 8'h0;
        mintstatus_mil   = 8'h0;
        // Performance counters
        mcycle_cnt       = 64'h0;
        minstret_cnt     = 64'h0;
        // Counter inhibit
        mcountinhibit_cy = 1'b0;
        mcountinhibit_ir = 1'b0;
    end

    // Constrain 64-bit mtime_i input (read-only, not checked by P1-P7).
    always @(posedge clk) begin
        assume (mtime_i == 64'h0);
        // RISC-V ISA: all instruction PCs are at minimum 2-byte aligned (bit 0 = 0).
        // The CPU core guarantees this; the CSR module relies on it.
        assume (irq_mepc[0] == 1'b0);
    end

`endif // FORMAL
"""


def read_file(path):
    with open(path, 'r', encoding='utf-8') as f:
        return f.readlines()


def process_pkg(lines, dbgmsg_lines):
    """
    Process jv32_pkg.sv lines:
      - Replace `include "jv32_dbgmsg.svh" with the inlined content
      - Comment out `package jv32_pkg;` and `endpackage`
    All other lines are kept verbatim (Yosys handles ifdef/ifndef via -DSYNTHESIS).
    """
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
            result.append(f'// STRIPPED (package wrapper): endpackage\n')
        else:
            result.append(line)
    return result


def process_csr(lines):
    """
    Process jv32_csr.sv lines:
      - Comment out `import jv32_pkg::*;`
      - Inject formal properties before `endmodule`
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
    pkg_lines    = read_file(PKG_FILE)
    csr_lines    = read_file(CSR_FILE)
    dbgmsg_lines = read_file(DBGMSG_FILE)

    out = []
    out.append('// ============================================================\n')
    out.append('// AUTO-GENERATED by verif/formal/gen_flat_csr.py\n')
    out.append('// DO NOT EDIT — regenerate with: python3 gen_flat_csr.py\n')
    out.append('//\n')
    out.append('// Flat (package-free) version of jv32_csr for SymbiYosys.\n')
    out.append('// Formal properties are injected inside the jv32_csr module\n')
    out.append('// when compiled with -D FORMAL.\n')
    out.append('// ============================================================\n')
    out.append('\n')
    out.append('// ============================================================\n')
    out.append('// Part 1: jv32_pkg.sv content (package wrapper stripped)\n')
    out.append('// ============================================================\n')
    out.extend(process_pkg(pkg_lines, dbgmsg_lines))
    out.append('\n')
    out.append('// ============================================================\n')
    out.append('// Part 2: jv32_csr.sv (import stripped, formal props injected)\n')
    out.append('// ============================================================\n')
    out.extend(process_csr(csr_lines))

    with open(OUT_FILE, 'w', encoding='utf-8') as f:
        f.writelines(out)

    print(f'Generated: {OUT_FILE}', file=sys.stderr)


if __name__ == '__main__':
    main()
