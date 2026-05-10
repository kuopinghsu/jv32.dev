// ============================================================================
// File        : jv32_rvc.sv
// Project     : JV32 RISC-V Processor
// Description : RVC (Zca + Zcb + Zcmp) Compressed-Instruction Expander
//
// Handles: (1) two compressed per word, (2) split 32-bit across words,
// (3) halfword-aligned fetch targets.
//
// hold[1:0]==11 -> case_d (split 32-bit lower half buffered)
// hold[1:0]!=11 -> case_c (compressed instruction buffered)
// init_offset   -> skip lower halfword on first post-flush fetch
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Kuoping Hsu
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
// ============================================================================

module jv32_rvc #(
    parameter bit RVM23_EN = 1'b1,
    parameter bit ZCMP_EN  = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        imem_resp_valid,
    input  logic [31:0] imem_resp_data,
    input  logic [31:0] imem_resp_pc,
    input  logic        stall,
    input  logic        flush,
    input  logic [31:0] flush_pc,
    output logic        instr_valid,
    output logic [31:0] instr_data,
    output logic [31:0] orig_instr,
    output logic [31:0] instr_pc,
    output logic        is_compressed,
    output logic        mem_ready
);

`ifndef DBG_GRP_FETCH
    `define DBG_GRP_FETCH 0
`endif

`ifndef DEBUG2
    `define DEBUG2(grp, msg)
`endif

    import jv32_pkg::*;

    logic        hold_valid;
    logic [15:0] hold;
    logic [31:0] hold_pc;
    logic        hold_from_split;  // hold was set from split32 path; don't re-advance pc_if on output
    logic        init_offset;
    /* verilator coverage_off */  // stale_rsp is architecturally always 0 (IFETCH_PREADVANCE)
    logic        stale_rsp;  // 1 cycle after mr=1: SRAM echoes the old word, must discard
    /* verilator coverage_on */

    // -------------------------------------------------------------------------
    // Zcmp microsequencer state
    //   zcmp_seq     : 1 while a multi-op Zcmp instruction is in progress
    //   zcmp_step    : current micro-op index (0 = first op not yet emitted)
    //   zcmp_total   : total number of micro-ops for this instruction
    //   zcmp_op      : 2'b00=push, 2'b01=pop, 2'b10=popret, 2'b11=popretz,
    //                  3'b100=mvsa01, 3'b101=mva01s  (uses bit 2 for mv group)
    //   zcmp_pc      : PC of the Zcmp instruction (all micro-ops share it)
    //   zcmp_orig    : original 16-bit compressed word (for orig_instr trace)
    //   zcmp_rcount  : number of registers in rlist (1-12)
    //   zcmp_sadj    : stack adjustment in bytes
    //   zcmp_sreg1   : s-reg index for mvsa01/mva01s operand 1  (3-bit, maps to GPR)
    //   zcmp_sreg2   : s-reg index for mvsa01/mva01s operand 2  (3-bit, maps to GPR)
    // -------------------------------------------------------------------------
    logic        zcmp_seq;
    logic [ 3:0] zcmp_step;     // current micro-op (0-based)
    logic [ 3:0] zcmp_total;    // total micro-ops
    logic [ 2:0] zcmp_op;       // operation code
    logic [31:0] zcmp_pc;
    logic [15:0] zcmp_orig;
    logic [ 3:0] zcmp_rcount;   // registers in list
    logic [ 7:0] zcmp_sadj;     // stack adjustment (positive magnitude)
    logic [ 2:0] zcmp_sreg1;    // 3-bit s-reg encoding for mvsa01/mva01s
    logic [ 2:0] zcmp_sreg2;    // 3-bit s-reg encoding
    logic        zcmp_last_mr;  // mem_ready to drive on the last Zcmp micro-op

    // Zcmp detection wires (combinational): used by both comb and FF blocks
    logic        zcmp_det_hold;     // Zcmp detected from hold path
    logic        zcmp_det_eff_lo;   // Zcmp from eff_data[15:0] path
    logic        zcmp_det_eff_hi;   // Zcmp from eff_data[31:16] path (init_offset)
    logic [15:0] zcmp_det_ci;       // the triggering CI word
    logic [ 2:0] zcmp_det_op;       // decoded op code
    logic [ 3:0] zcmp_det_rcount;   // decoded register count
    logic [ 7:0] zcmp_det_sadj;     // decoded stack adjustment
    logic [ 2:0] zcmp_det_sreg1;    // sreg1 (mv variants)
    logic [ 2:0] zcmp_det_sreg2;    // sreg2 (mv variants)
    logic [31:0] zcmp_det_pc;       // PC of the Zcmp instruction
    logic        zcmp_det_last_mr;  // mem_ready for the last micro-op
    logic [ 3:0] zcmp_det_total;    // total micro-ops for this instruction

    // Map 3-bit s-register encoding to 5-bit GPR number
    // 0→s0(x8), 1→s1(x9), 2→s2(x18), 3→s3(x19), 4→s4(x20), 5→s5(x21), 6→s6(x22), 7→s7(x23)
    function automatic logic [4:0] zcmp_sreg_to_gpr(input logic [2:0] s);
        case (s)
            3'd0:    zcmp_sreg_to_gpr = 5'd8;   // s0
            3'd1:    zcmp_sreg_to_gpr = 5'd9;   // s1
            3'd2:    zcmp_sreg_to_gpr = 5'd18;  // s2
            3'd3:    zcmp_sreg_to_gpr = 5'd19;  // s3
            3'd4:    zcmp_sreg_to_gpr = 5'd20;  // s4
            3'd5:    zcmp_sreg_to_gpr = 5'd21;  // s5
            3'd6:    zcmp_sreg_to_gpr = 5'd22;  // s6
            default: zcmp_sreg_to_gpr = 5'd23;  // 3'd7: s7
        endcase
    endfunction

    // Map save-list index (0=ra, 1=s0, 2=s1, 3+=s{i-1}) to GPR number
    function automatic logic [4:0] zcmp_save_gpr(input logic [3:0] idx);
        case (idx)
            4'd0:    zcmp_save_gpr = 5'd1;   // ra
            4'd1:    zcmp_save_gpr = 5'd8;   // s0
            4'd2:    zcmp_save_gpr = 5'd9;   // s1
            4'd3:    zcmp_save_gpr = 5'd18;  // s2
            4'd4:    zcmp_save_gpr = 5'd19;  // s3
            4'd5:    zcmp_save_gpr = 5'd20;  // s4
            4'd6:    zcmp_save_gpr = 5'd21;  // s5
            4'd7:    zcmp_save_gpr = 5'd22;  // s6
            4'd8:    zcmp_save_gpr = 5'd23;  // s7
            4'd9:    zcmp_save_gpr = 5'd24;  // s8
            4'd10:   zcmp_save_gpr = 5'd25;  // s9
            4'd11:   zcmp_save_gpr = 5'd26;  // s10
            4'd12:   zcmp_save_gpr = 5'd27;  // s11
            default: zcmp_save_gpr = 5'd0;
        endcase
    endfunction

    // Compute stack adjustment from rlist value (4-bit field from CI[7:4])
    // rlist 4-7 → min=16, 8-11 → min=32, 12-14 → min=48, 15 → min=64
    function automatic logic [7:0] zcmp_min_stack(input logic [3:0] rlist);
        case (rlist[3:2])
            2'b01:   zcmp_min_stack = 8'd16;                             // rlist 4-7
            2'b10:   zcmp_min_stack = 8'd32;                             // rlist 8-11
            2'b11:   zcmp_min_stack = (rlist == 4'd15) ? 8'd64 : 8'd48;  // 12-14 → 48, 15 → 64
            default: zcmp_min_stack = 8'd0;                              // rlist 0-3: reserved/invalid
        endcase
    endfunction

    // Compute number of registers from rlist (4-bit)
    // rlist 4 → 1 reg, rlist r → r-3 regs; max rlist=15 → 12 regs
    function automatic logic [3:0] zcmp_rcount_f(input logic [3:0] rlist);
        zcmp_rcount_f = (rlist < 4'd4) ? 4'd0 : (rlist - 4'd3);
    endfunction

    function automatic logic [31:0] c_sext6(input logic [5:0] v);
        c_sext6 = {{26{v[5]}}, v};
    endfunction

    // c_imm6: sign-extend 6-bit value to 12-bit I-type immediate field
    function automatic logic [11:0] c_imm6(input logic [5:0] v);
        c_imm6 = {{6{v[5]}}, v};
    endfunction

    function automatic logic [31:0] c_sext9(input logic [8:0] v);
        c_sext9 = {{23{v[8]}}, v};
    endfunction

    function automatic logic [31:0] c_sext10(input logic [9:0] v);
        c_sext10 = {{22{v[9]}}, v};
    endfunction

    function automatic logic [31:0] c_sext12(input logic [11:0] v);
        c_sext12 = {{20{v[11]}}, v};
    endfunction

    // c_j_off: J-type offset [20:1] from C.JAL/C.J encoding (inlined sign-extension, no temp needed)
    function automatic logic [20:1] c_j_off(input logic [12:2] ci);
        c_j_off = {{9{ci[12]}}, ci[12], ci[8], ci[10:9], ci[6], ci[7], ci[2], ci[11], ci[5:3]};
    endfunction

    // c_b_off: B-type offset [12:1] from C.BEQZ/C.BNEZ encoding (inlined sign-extension, no temp needed)
    function automatic logic [12:1] c_b_off(input logic [2:0] ci_hi, input logic [4:0] ci_lo);
        c_b_off = {{4{ci_hi[2]}}, ci_hi[2], ci_lo[4:3], ci_lo[0], ci_hi[1:0], ci_lo[2:1]};
    endfunction

    // enc_jal: encode J-type instruction; im[20:1] are the offset bits (bit 0 always 0)
    function automatic logic [31:0] enc_jal(input logic [4:0] rd, input logic [20:1] im);
        enc_jal = {im[20], im[10:1], im[11], im[19:12], rd, 7'h6F};
    endfunction

    // enc_br: encode B-type instruction; im[12:1] are the offset bits (bit 0 always 0)
    function automatic logic [31:0] enc_br(input logic [2:0] f3, input logic [4:0] rs1, input logic [4:0] rs2,
                                           input logic [12:1] im);
        enc_br = {im[12], im[10:5], rs2, rs1, f3, im[4:1], im[11], 7'h63};
    endfunction

    function automatic logic [31:0] expand_c(input logic [15:0] ci);
        logic [1:0] quad, funct2;
        logic [2:0] funct3;
        logic [4:0] rd_rs1, rs2, rd_p, rs1_p, rs2_p;
        logic [11:0] nzuimm12, uimm12;
        logic [31:0] nzimm;
        logic [11:0] _sext;  // lower 12 bits of sign-extended value (I-type immediate field)
        logic        f1;
        logic [ 1:0] f2_low;

        // Default all locals to silence Yosys latch inference on partial paths
        funct2   = '0;
        rd_rs1   = '0;
        rs2      = '0;
        nzuimm12 = '0;
        uimm12   = '0;
        nzimm    = '0;
        _sext    = '0;
        f1       = '0;
        f2_low   = '0;
        expand_c = 32'h0;
        quad     = ci[1:0];
        funct3   = ci[15:13];
        rd_p     = {2'b01, ci[4:2]};
        rs1_p    = {2'b01, ci[9:7]};
        rs2_p    = {2'b01, ci[4:2]};

        case (quad)
            2'b00:
            case (funct3)
                3'h0: begin
                    nzuimm12 = {2'b00, ci[10:7], ci[12:11], ci[5], ci[6], 2'b00};
                    expand_c = (nzuimm12 == 12'h0) ? 32'h0 : {nzuimm12, 5'd2, 3'h0, rd_p, 7'h13};
                end
                3'h2: expand_c = {{5'b0, ci[5], ci[12:10], ci[6], 2'b00}, rs1_p, 3'h2, rd_p, 7'h03};
                3'h6: begin
                    uimm12   = {5'b0, ci[5], ci[12:10], ci[6], 2'b00};
                    expand_c = {uimm12[11:5], rs2_p, rs1_p, 3'h2, uimm12[4:0], 7'h23};
                end
                3'h4:
                if (!RVM23_EN) expand_c = 32'h0;
                else
                    case (ci[12:10])
                        3'b000: expand_c = {{10'b0, ci[5], ci[6]}, rs1_p, 3'h4, rd_p, 7'h03};
                        3'b001:
                        expand_c = !ci[6] ? {{10'b0,ci[5],1'b0},rs1_p,3'h5,rd_p,7'h03}
                                              : {{10'b0,ci[5],1'b0},rs1_p,3'h1,rd_p,7'h03};
                        3'b010: begin
                            uimm12   = {10'b0, ci[5], ci[6]};
                            expand_c = {uimm12[11:5], rs2_p, rs1_p, 3'h0, uimm12[4:0], 7'h23};
                        end
                        3'b011: begin
                            uimm12   = {10'b0, ci[5], 1'b0};
                            expand_c = {uimm12[11:5], rs2_p, rs1_p, 3'h1, uimm12[4:0], 7'h23};
                        end
                        default: expand_c = 32'h0;
                    endcase
                default: expand_c = 32'h0;
            endcase

            2'b01: begin
                rd_rs1 = ci[11:7];
                case (funct3)
                    3'h0: begin
                        _sext    = c_imm6({ci[12], ci[6:2]});
                        expand_c = {_sext, rd_rs1, 3'h0, rd_rs1, 7'h13};
                    end
                    3'h1:    expand_c = enc_jal(5'd1, c_j_off(ci[12:2]));
                    3'h2: begin
                        _sext    = c_imm6({ci[12], ci[6:2]});
                        expand_c = {_sext, 5'd0, 3'h0, rd_rs1, 7'h13};
                    end
                    3'h3: begin
                        if (rd_rs1 == 5'd2) begin
                            nzimm    = c_sext10({ci[12], ci[4:3], ci[5], ci[2], ci[6], 4'b0});
                            expand_c = (nzimm == 32'h0) ? 32'h0 : {nzimm[11:0], 5'd2, 3'h0, 5'd2, 7'h13};
                        end
                        else begin
                            nzimm    = c_sext6({ci[12], ci[6:2]});
                            expand_c = (nzimm == 32'h0) ? 32'h0 : {nzimm[19:0], rd_rs1, 7'h37};
                        end
                    end
                    3'h4: begin
                        funct2 = ci[11:10];
                        rd_p   = {2'b01, ci[9:7]};
                        rs2_p  = {2'b01, ci[4:2]};
                        case (funct2)
                            2'h0:    expand_c = {7'h00, ci[6:2], rd_p, 3'h5, rd_p, 7'h13};
                            2'h1:    expand_c = {7'h20, ci[6:2], rd_p, 3'h5, rd_p, 7'h13};
                            2'h2: begin
                                _sext    = c_imm6({ci[12], ci[6:2]});
                                expand_c = {_sext, rd_p, 3'h7, rd_p, 7'h13};
                            end
                            2'h3: begin
                                f1     = ci[12];
                                f2_low = ci[6:5];
                                if (!f1)
                                    case (f2_low)  // 2-bit field: default unreachable
                                        2'h0: expand_c = {7'h20, rs2_p, rd_p, 3'h0, rd_p, 7'h33};
                                        2'h1: expand_c = {7'h00, rs2_p, rd_p, 3'h4, rd_p, 7'h33};
                                        2'h2: expand_c = {7'h00, rs2_p, rd_p, 3'h6, rd_p, 7'h33};
                                        2'h3: expand_c = {7'h00, rs2_p, rd_p, 3'h7, rd_p, 7'h33};
                                        /* verilator coverage_off */  // f2_low is 2-bit: 0-3 exhaustive
                                        default: expand_c = 32'h0;
                                        /* verilator coverage_on */
                                    endcase
                                else if (RVM23_EN)
                                    case (f2_low)
                                        2'h2: expand_c = {7'h01, rs2_p, rd_p, 3'h0, rd_p, 7'h33};
                                        2'h3:
                                        case (ci[4:2])
                                            3'b000:  expand_c = {12'hFF, rd_p, 3'h7, rd_p, 7'h13};
                                            3'b101:  expand_c = {12'hFFF, rd_p, 3'h4, rd_p, 7'h13};
                                            default: expand_c = 32'h0;
                                        endcase
                                        default: expand_c = 32'h0;
                                    endcase
                                else expand_c = 32'h0;
                            end
                            /* verilator coverage_off */  // funct2 is 2-bit: 0-3 exhaustive
                            default: expand_c = 32'h0;
                            /* verilator coverage_on */
                        endcase
                    end
                    3'h5:    expand_c = enc_jal(5'd0, c_j_off(ci[12:2]));
                    3'h6:    expand_c = enc_br(3'h0, {2'b01, ci[9:7]}, 5'd0, c_b_off(ci[12:10], ci[6:2]));
                    3'h7:    expand_c = enc_br(3'h1, {2'b01, ci[9:7]}, 5'd0, c_b_off(ci[12:10], ci[6:2]));
                    /* verilator coverage_off */  // funct3 is 3-bit: 0-7 exhaustive
                    default: expand_c = 32'h0;
                    /* verilator coverage_on */
                endcase
            end

            2'b10: begin
                rd_rs1 = ci[11:7];
                rs2    = ci[6:2];
                case (funct3)
                    3'h0:    expand_c = {7'h00, ci[6:2], rd_rs1, 3'h1, rd_rs1, 7'h13};
                    3'h2: begin
                        if (rd_rs1 == 5'd0) expand_c = 32'h0;
                        else begin
                            uimm12   = {4'b0, ci[3:2], ci[12], ci[6:4], 2'b00};
                            expand_c = {uimm12, 5'd2, 3'h2, rd_rs1, 7'h03};
                        end
                    end
                    3'h4: begin
                        f1 = ci[12];
                        if (!f1) begin
                            if (rs2 == 5'd0) expand_c = (rd_rs1 == 5'd0) ? 32'h0 : {12'h0, rd_rs1, 3'h0, 5'd0, 7'h67};
                            else expand_c = {7'h00, rs2, 5'd0, 3'h0, rd_rs1, 7'h33};
                        end else begin
                            if (rd_rs1 == 5'd0 && rs2 == 5'd0) expand_c = 32'h00100073;
                            else if (rs2 == 5'd0) expand_c = {12'h0, rd_rs1, 3'h0, 5'd1, 7'h67};
                            else expand_c = {7'h00, rs2, rd_rs1, 3'h0, rd_rs1, 7'h33};
                        end
                    end
                    3'h6: begin
                        uimm12   = {4'b0, ci[8:7], ci[12:9], 2'b00};
                        expand_c = {uimm12[11:5], rs2, 5'd2, 3'h2, uimm12[4:0], 7'h23};
                    end
                    default: expand_c = 32'h0;
                endcase
            end

            default: expand_c = 32'h0;
        endcase
    endfunction

    // Effective memory response
    // Gate imem_resp_valid with !stale_rsp so the stale SRAM echo (one cycle after
    // mem_ready=1 advances pc_if) is invisible to all downstream decode logic.
    logic eff_valid;
    logic [31:0] eff_data, eff_pc;
    always_comb begin
        eff_valid = imem_resp_valid && !stale_rsp;
        eff_data  = imem_resp_data;
        eff_pc    = imem_resp_pc;
    end

    logic split32;
    assign split32 = hold_valid && (hold[1:0] == 2'b11);

    // Combinational output
    //
    // mem_ready=1 tells the core to advance pc_if by 4 on the next clock edge.
    // It must only be 1 when the RVC has genuinely consumed the current fetch word
    // and is ready for the next one.  Defaulting to 1 would advance pc_if on
    // every cycle where no instruction is produced (e.g. after a flush with
    // eff_valid=0), causing pc_if to overshoot.  Instead default to 0 and
    // explicitly set to 1 only in cases that advance the fetch.
    //
    // Zcmp extension: when zcmp_seq=1 a multi-op Zcmp sequence is in progress.
    // We hold mem_ready=0 and emit one micro-op per un-stalled cycle. When the
    // last micro-op is presented, zcmp_seq clears on the next posedge.
    //
    // Zcmp op codes (zcmp_op[2:0]):
    //   000 = cm.push   : addi sp,-sadj  + N sw  regs
    //   001 = cm.pop    : N lw regs      + addi sp,+sadj
    //   010 = cm.popret : N lw regs      + addi sp,+sadj + jalr x0,0(x1)
    //   011 = cm.popretz: N lw regs      + addi sp,+sadj + addi a0,x0,0 + jalr x0,0(x1)
    //   100 = cm.mvsa01 : mv s?,a0  +  mv s?,a1  (2 micro-ops)
    //   101 = cm.mva01s : mv a0,s?  +  mv a1,s?  (2 micro-ops)

    // Zcmp helpers (combinational, used inside always_comb)
    // sp offset for save/restore index i (0=ra slot):  sp + (sadj - 4*(i+1))
    // The function returns the signed 12-bit immediate for the S/L instruction.
    function automatic logic [11:0] zcmp_sp_off(input logic [7:0] sadj, input logic [3:0] idx);
        // sadj - 4*(idx+1); sadj is at most 64, idx at most 12 → always positive (≤60)
        zcmp_sp_off = {4'b0, sadj} - 12'({4'b0, idx} + 12'd1) * 12'd4;
    endfunction

    // Build: addi rd, rs1, imm12
    function automatic logic [31:0] enc_addi(input logic [4:0] rd, input logic [4:0] rs1, input logic [11:0] imm12);
        enc_addi = {imm12, rs1, 3'h0, rd, 7'h13};
    endfunction

    // Build: sw rs2, offset(rs1)
    function automatic logic [31:0] enc_sw(input logic [4:0] rs1, input logic [4:0] rs2, input logic [11:0] offset);
        enc_sw = {offset[11:5], rs2, rs1, 3'h2, offset[4:0], 7'h23};
    endfunction

    // Build: lw rd, offset(rs1)
    function automatic logic [31:0] enc_lw(input logic [4:0] rd, input logic [4:0] rs1, input logic [11:0] offset);
        enc_lw = {offset, rs1, 3'h2, rd, 7'h03};
    endfunction

    // Build: jalr x0, 0(x1) (return)
    function automatic logic [31:0] enc_jalr_ret();
        enc_jalr_ret = {12'h0, 5'd1, 3'h0, 5'd0, 7'h67};
    endfunction

    // Determine if a compressed halfword is a Zcmp instruction:
    //   Q2 (ci[1:0]=10), funct3=5 (ci[15:13]=101)
    //   push/pop variant: ci[12]=1, rlist=ci[7:4] >= 4
    //   mv   variant: ci[12]=0, ci[11:10]=11 (bit[11]=1,bit[10]=1 per ratified spec)
    /* verilator lint_off UNUSEDSIGNAL */  // not all bits of ci are relevant for detection
    function automatic logic is_zcmp(input logic [15:0] ci);
        is_zcmp = ZCMP_EN && (ci[1:0] == 2'b10) && (ci[15:13] == 3'b101) &&
                  (ci[12] ? (ci[7:4] >= 4'h4) : (ci[11:10] == 2'b11));
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // Decode a Zcmp CI word into a 3-bit op code (same encoding as zcmp_op):
    //   push/pop variants (ci[12]=1):
    //     ci[11:10]=10 (bits[15:10]=101110): ci[9:8]=00→push(000), ci[9:8]=10→pop(001)
    //     ci[11:10]=11 (bits[15:10]=101111): ci[9:8]=00→popretz(011), ci[9:8]=10→popret(010)
    //   mv variants (ci[12]=0): ci[11:10]=11, ci[6]=0→mvsa01(100), ci[6]=1→mva01s(101)
    /* verilator lint_off UNUSEDSIGNAL */  // quadrant/funct3 bits validated by is_zcmp already
    function automatic logic [2:0] zcmp_decode_op(input logic [15:0] ci);
        if (ci[12]) begin
            // push/pop/popret/popretz: ci[10] distinguishes push/pop (0) from popret/popretz (1)
            case ({
                ci[10], ci[9:8]
            })
                3'b000:  zcmp_decode_op = 3'b000;  // cm.push   (ci[10]=0, ci[9:8]=00)
                3'b010:  zcmp_decode_op = 3'b001;  // cm.pop    (ci[10]=0, ci[9:8]=10)
                3'b100:  zcmp_decode_op = 3'b011;  // cm.popretz (ci[10]=1, ci[9:8]=00)
                3'b110:  zcmp_decode_op = 3'b010;  // cm.popret  (ci[10]=1, ci[9:8]=10)
                default: zcmp_decode_op = 3'b000;
            endcase
        end
        else begin
            // mv variants: ci[6] distinguishes mvsa01 vs mva01s
            zcmp_decode_op = ci[6] ? 3'b101 : 3'b100;
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // Compute total number of micro-ops for a Zcmp instruction
    function automatic logic [3:0] zcmp_total_f(input logic [2:0] op, input logic [3:0] rcount);
        case (op)
            3'b000:  zcmp_total_f = 4'(5'(1) + {1'b0, rcount});  // push: 1 addi + rcount sw
            3'b001:  zcmp_total_f = 4'(5'(1) + {1'b0, rcount});  // pop:  rcount lw + 1 addi
            3'b010:  zcmp_total_f = 4'(5'(2) + {1'b0, rcount});  // popret:   +1 jalr
            3'b011:  zcmp_total_f = 4'(5'(3) + {1'b0, rcount});  // popretz:  +1 addi a0,0 +1 jalr
            3'b100:  zcmp_total_f = 4'd2;                        // mvsa01:   2 mv ops
            3'b101:  zcmp_total_f = 4'd2;                        // mva01s:   2 mv ops
            default: zcmp_total_f = 4'd1;
        endcase
    endfunction

    // Generate one Zcmp micro-op given current sequencer state
    function automatic logic [31:0] zcmp_microop(input logic [2:0] op, input logic [3:0] step, input logic [3:0] rcount,
                                                 input logic [7:0] sadj, input logic [2:0] sreg1,
                                                 input logic [2:0] sreg2);
        logic [ 4:0] gpr;
        logic [11:0] off;
        zcmp_microop = 32'h13;  // NOP (addi x0,x0,0) as default
        gpr          = '0;
        off          = '0;
        case (op)
            // cm.push: step 0 = addi sp,sp,-sadj; steps 1..rcount = sw reg[i-1], off(sp)
            3'b000: begin
                if (step == 4'd0) zcmp_microop = enc_addi(5'd2, 5'd2, 12'(-{4'b0, sadj}));
                else begin
                    gpr          = zcmp_save_gpr(step - 4'd1);  // index 0..rcount-1
                    off          = zcmp_sp_off(sadj, step - 4'd1);
                    zcmp_microop = enc_sw(5'd2, gpr, off);
                end
            end
            // cm.pop: steps 0..rcount-1 = lw reg[i], off(sp); last step = addi sp,sp,+sadj
            3'b001: begin
                if ({1'b0, step} < {1'b0, rcount}) begin
                    gpr          = zcmp_save_gpr(step[3:0]);
                    off          = zcmp_sp_off(sadj, step[3:0]);
                    zcmp_microop = enc_lw(gpr, 5'd2, off);
                end
                else  // step == rcount
                    zcmp_microop = enc_addi(5'd2, 5'd2, {4'b0, sadj});
            end
            // cm.popret: steps 0..rcount-1 = lw; step rcount = addi sp,sp,+sadj;
            //            step rcount+1 = jalr x0,0(x1)
            3'b010: begin
                if ({1'b0, step} < {1'b0, rcount}) begin
                    gpr          = zcmp_save_gpr(step[3:0]);
                    off          = zcmp_sp_off(sadj, step[3:0]);
                    zcmp_microop = enc_lw(gpr, 5'd2, off);
                end
                else if ({1'b0, step} == {1'b0, rcount}) zcmp_microop = enc_addi(5'd2, 5'd2, {4'b0, sadj});
                else  // step == rcount+1: jalr x0,0(ra)
                    zcmp_microop = enc_jalr_ret();
            end
            // cm.popretz: steps 0..rcount-1 = lw; step rcount = addi sp,sp,+sadj;
            //             step rcount+1 = addi a0,x0,0; step rcount+2 = jalr x0,0(x1)
            3'b011: begin
                if ({1'b0, step} < {1'b0, rcount}) begin
                    gpr          = zcmp_save_gpr(step[3:0]);
                    off          = zcmp_sp_off(sadj, step[3:0]);
                    zcmp_microop = enc_lw(gpr, 5'd2, off);
                end
                else if ({1'b0, step} == {1'b0, rcount}) zcmp_microop = enc_addi(5'd2, 5'd2, {4'b0, sadj});
                else if ({1'b0, step} == ({1'b0, rcount} + 5'd1))
                    zcmp_microop = enc_addi(5'd10, 5'd0, 12'h0);  // addi a0,x0,0
                else  // step == rcount+2
                    zcmp_microop = enc_jalr_ret();
            end
            // cm.mvsa01: step 0 = mv sreg1,a0; step 1 = mv sreg2,a1
            3'b100: begin
                if (step == 4'd0) zcmp_microop = {7'h00, 5'd10, 5'd0, 3'h0, zcmp_sreg_to_gpr(sreg1), 7'h33};
                else zcmp_microop = {7'h00, 5'd11, 5'd0, 3'h0, zcmp_sreg_to_gpr(sreg2), 7'h33};
            end
            // cm.mva01s: step 0 = mv a0,sreg1; step 1 = mv a1,sreg2
            3'b101: begin
                if (step == 4'd0) zcmp_microop = {7'h00, zcmp_sreg_to_gpr(sreg1), 5'd0, 3'h0, 5'd10, 7'h33};
                else zcmp_microop = {7'h00, zcmp_sreg_to_gpr(sreg2), 5'd0, 3'h0, 5'd11, 7'h33};
            end
            default: zcmp_microop = 32'h13;
        endcase
    endfunction

    always_comb begin
        instr_valid   = 1'b0;
        instr_data    = 32'h13;
        orig_instr    = 32'h13;
        instr_pc      = 32'h0;
        is_compressed = 1'b0;
        mem_ready     = 1'b0;

        // ---------------------------------------------------------------
        // Zcmp microsequencer: active while zcmp_seq=1
        // ---------------------------------------------------------------
        if (ZCMP_EN && zcmp_seq && !stall) begin
            instr_valid   = 1'b1;
            instr_data    = zcmp_microop(zcmp_op, zcmp_step, zcmp_rcount, zcmp_sadj, zcmp_sreg1, zcmp_sreg2);
            orig_instr    = {16'h0, zcmp_orig};
            instr_pc      = zcmp_pc;
            is_compressed = 1'b1;
            // Drive mem_ready=1 on the last micro-op (allowing fetch to advance)
            mem_ready     = (zcmp_step == zcmp_total - 4'd1) ? zcmp_last_mr : 1'b0;
        end
        else if (!stall) begin
            if (split32) begin
                if (eff_valid) begin
                    instr_valid   = 1'b1;
                    instr_data    = {eff_data[15:0], hold};
                    orig_instr    = {eff_data[15:0], hold};
                    instr_pc      = hold_pc;
                    is_compressed = 1'b0;
                    mem_ready     = 1'b1;
                end
                // else: eff_valid=0 or stale_rsp active - mem_ready stays 0
            end
            else if (hold_valid) begin
                instr_valid   = 1'b1;
                orig_instr    = {16'h0, hold};
                instr_pc      = hold_pc;
                is_compressed = 1'b1;
                if (ZCMP_EN && is_zcmp(hold)) begin
                    // First micro-op of a Zcmp sequence (step 0), decoded fields
                    // are computed from hold directly here (zcmp_seq is still 0).
                    instr_data = zcmp_microop(
                        zcmp_decode_op(
                            hold
                        ),
                        4'd0,
                        zcmp_rcount_f(
                            hold[7:4]
                        ),
                        zcmp_min_stack(
                            hold[7:4]
                        ) + {2'b0, hold[3:2], 4'b0},
                        hold[9:7],
                        hold[4:2]
                    );
                end
                else instr_data = expand_c(hold);
                // When hold came from the split32 path, pc_if was already advanced
                // by the split32 mr=1.  The SRAM is already fetching the next fresh
                // word, so we must NOT advance pc_if again here (mr=0).  When hold
                // came from the normal lower-compressed path, pc_if was NOT advanced
                // and we must advance it now so the SRAM moves on (mr=1).
                //
                // For Zcmp: if total > 1, sequencer continues next cycle with mr=0.
                //           if total == 1 (single-op), use zcmp_det_last_mr.
                mem_ready = (ZCMP_EN && is_zcmp(hold)) ? (zcmp_det_total == 4'd1 ? zcmp_det_last_mr : 1'b0) :
                    hold_from_split ? 1'b0 : 1'b1;
            end
            else if (eff_valid) begin
                if (init_offset) begin
                    if (eff_data[17:16] != 2'b11) begin
                        // upper compressed half: output it and advance
                        instr_valid   = 1'b1;
                        orig_instr    = {16'h0, eff_data[31:16]};
                        instr_pc      = eff_pc + 32'd2;
                        is_compressed = 1'b1;
                        if (ZCMP_EN && is_zcmp(eff_data[31:16])) begin
                            instr_data = zcmp_microop(
                                zcmp_decode_op(
                                    eff_data[31:16]
                                ),
                                4'd0,
                                zcmp_rcount_f(
                                    eff_data[23:20]
                                ),
                                zcmp_min_stack(
                                    eff_data[23:20]
                                ) + {2'b0, eff_data[19:18], 4'b0},
                                eff_data[25:23],
                                eff_data[20:18]
                            );
                            mem_ready = 1'b0;
                        end
                        else begin
                            instr_data = expand_c(eff_data[31:16]);
                            mem_ready  = 1'b1;
                        end
                    end
                    else begin
                        // upper half is split32 marker: advance to fetch the completing word
                        mem_ready = 1'b1;
                    end
                end
                else if (eff_data[1:0] == 2'b11) begin
                    instr_valid = 1'b1;
                    instr_data  = eff_data;
                    orig_instr  = eff_data;
                    instr_pc    = eff_pc;
                    mem_ready   = 1'b1;
                end
                else begin
                    instr_valid   = 1'b1;
                    orig_instr    = {16'h0, eff_data[15:0]};
                    instr_pc      = eff_pc;
                    is_compressed = 1'b1;
                    if (ZCMP_EN && is_zcmp(eff_data[15:0])) begin
                        instr_data = zcmp_microop(
                            zcmp_decode_op(
                                eff_data[15:0]
                            ),
                            4'd0,
                            zcmp_rcount_f(
                                eff_data[7:4]
                            ),
                            zcmp_min_stack(
                                eff_data[7:4]
                            ) + {2'b0, eff_data[3:2], 4'b0},
                            eff_data[9:7],
                            eff_data[4:2]
                        );
                        mem_ready = 1'b0;
                    end
                    else begin
                        instr_data = expand_c(eff_data[15:0]);
                        // If upper half is a 32-bit lower-half (split32), advance pc_if so the
                        // next fetch word supplies the upper 16 bits to complete the 32-bit instr.
                        // If upper half is compressed, set mem_ready=0; hold is set and will be
                        // output next cycle with mem_ready=1.
                        mem_ready  = (eff_data[17:16] == 2'b11) ? 1'b1 : 1'b0;
                    end
                end
            end
            // eff_valid=0 with no hold/split32: mem_ready stays 0, pc_if does not advance
        end
    end

    // Zcmp detection combinational logic
    always_comb begin
        // Default
        zcmp_det_hold    = 1'b0;
        zcmp_det_eff_lo  = 1'b0;
        zcmp_det_eff_hi  = 1'b0;
        zcmp_det_ci      = 16'h0;
        zcmp_det_op      = 3'b0;
        zcmp_det_rcount  = 4'd0;
        zcmp_det_sadj    = 8'd0;
        zcmp_det_sreg1   = 3'b0;
        zcmp_det_sreg2   = 3'b0;
        zcmp_det_pc      = 32'h0;
        zcmp_det_last_mr = 1'b0;
        zcmp_det_total   = 4'd1;

        if (ZCMP_EN && !zcmp_seq) begin
            if (!split32 && hold_valid && is_zcmp(hold)) begin
                // Zcmp in hold path
                zcmp_det_hold    = 1'b1;
                zcmp_det_ci      = hold;
                zcmp_det_op      = zcmp_decode_op(hold);
                zcmp_det_rcount  = zcmp_rcount_f(hold[7:4]);
                zcmp_det_sadj    = zcmp_min_stack(hold[7:4]) + {2'b0, hold[3:2], 4'b0};
                zcmp_det_sreg1   = hold[9:7];
                zcmp_det_sreg2   = hold[4:2];
                zcmp_det_pc      = hold_pc;
                zcmp_det_last_mr = !hold_from_split;  // same as normal hold path
                zcmp_det_total   = zcmp_total_f(zcmp_decode_op(hold), zcmp_rcount_f(hold[7:4]));
            end
            else if (!hold_valid && eff_valid && !init_offset && !split32 && (eff_data[1:0] != 2'b11) && is_zcmp(
                    eff_data[15:0]
                )) begin
                // Zcmp in eff_data lower half
                zcmp_det_eff_lo  = 1'b1;
                zcmp_det_ci      = eff_data[15:0];
                zcmp_det_op      = zcmp_decode_op(eff_data[15:0]);
                zcmp_det_rcount  = zcmp_rcount_f(eff_data[7:4]);
                zcmp_det_sadj    = zcmp_min_stack(eff_data[7:4]) + {2'b0, eff_data[3:2], 4'b0};
                zcmp_det_sreg1   = eff_data[9:7];
                zcmp_det_sreg2   = eff_data[4:2];
                zcmp_det_pc      = eff_pc;
                // After sequence, hold has eff_data[31:16] (parked next cycle).
                // The hold path will then handle the next instr with hold_from_split=0 → mr=1.
                // So the Zcmp last micro-op: mem_ready=0, let hold take over.
                // BUT if upper half is a split32 lower part ([17:16]==11), after the Zcmp
                // sequence hold_valid=1 (split32 hold), and that will drive mem_ready=1 next.
                // In the split32 case we must advance fetch on the Zcmp last micro-op,
                // otherwise split32 completion reuses stale eff_data and corrupts assembly
                // of the 32-bit instruction straddling this word boundary.
                zcmp_det_last_mr = (eff_data[17:16] == 2'b11) ? 1'b1 : 1'b0;
                zcmp_det_total   = zcmp_total_f(zcmp_decode_op(eff_data[15:0]), zcmp_rcount_f(eff_data[7:4]));
            end
            else if (!hold_valid && eff_valid && init_offset && (eff_data[17:16] != 2'b11) && is_zcmp(
                    eff_data[31:16]
                )) begin
                // Zcmp in eff_data upper half (init_offset path)
                zcmp_det_eff_hi  = 1'b1;
                zcmp_det_ci      = eff_data[31:16];
                zcmp_det_op      = zcmp_decode_op(eff_data[31:16]);
                zcmp_det_rcount  = zcmp_rcount_f(eff_data[23:20]);
                zcmp_det_sadj    = zcmp_min_stack(eff_data[23:20]) + {2'b0, eff_data[19:18], 4'b0};
                zcmp_det_sreg1   = eff_data[25:23];
                zcmp_det_sreg2   = eff_data[20:18];
                zcmp_det_pc      = eff_pc + 32'd2;
                zcmp_det_last_mr = 1'b1;  // init_offset path: advance fetch after sequence
                zcmp_det_total   = zcmp_total_f(zcmp_decode_op(eff_data[31:16]), zcmp_rcount_f(eff_data[23:20]));
            end
        end
    end

    // Sequential state (Zcmp sequencer + fetch state machine)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_valid      <= 1'b0;
            hold            <= 16'h0;
            hold_pc         <= 32'h0;
            hold_from_split <= 1'b0;
            init_offset     <= 1'b0;
            stale_rsp       <= 1'b0;
            zcmp_seq        <= 1'b0;
            zcmp_step       <= 4'd0;
            zcmp_total      <= 4'd0;
            zcmp_op         <= 3'b0;
            zcmp_pc         <= 32'h0;
            zcmp_orig       <= 16'h0;
            zcmp_rcount     <= 4'd0;
            zcmp_sadj       <= 8'd0;
            zcmp_sreg1      <= 3'b0;
            zcmp_sreg2      <= 3'b0;
            zcmp_last_mr    <= 1'b0;
        end
        else if (flush) begin
            hold_valid      <= 1'b0;
            hold_from_split <= 1'b0;
            init_offset     <= flush_pc[1];
            stale_rsp       <= 1'b0;
            zcmp_seq        <= 1'b0;
            zcmp_step       <= 4'd0;
        end
        else begin
            // IFETCH_PREADVANCE: the SRAM already sees the next address at the
            // same posedge mem_ready fires, so the response one cycle later
            // carries the correct new data, not a stale echo.
            stale_rsp <= 1'b0;

            if (!stall) begin
                // ---------------------------------------------------------------
                // Zcmp microsequencer advancement
                // ---------------------------------------------------------------
                if (ZCMP_EN && zcmp_seq) begin
                    // Continuing a Zcmp sequence (step >= 1)
                    if (zcmp_step == zcmp_total - 4'd1) begin
                        // Last micro-op presented this cycle: sequence complete
                        zcmp_seq  <= 1'b0;
                        zcmp_step <= 4'd0;
                    end
                    else begin
                        zcmp_step <= zcmp_step + 4'd1;
                    end
                end
                else if (ZCMP_EN && (zcmp_det_hold || zcmp_det_eff_lo || zcmp_det_eff_hi)) begin
                    // First micro-op (step=0) being presented this cycle: latch state
                    if (zcmp_det_total > 4'd1) begin
                        zcmp_seq  <= 1'b1;
                        zcmp_step <= 4'd1;
                    end
                    // else: single micro-op Zcmp (shouldn't happen, but be safe)
                    zcmp_total   <= zcmp_det_total;
                    zcmp_op      <= zcmp_det_op;
                    zcmp_pc      <= zcmp_det_pc;
                    zcmp_orig    <= zcmp_det_ci;
                    zcmp_rcount  <= zcmp_det_rcount;
                    zcmp_sadj    <= zcmp_det_sadj;
                    zcmp_sreg1   <= zcmp_det_sreg1;
                    zcmp_sreg2   <= zcmp_det_sreg2;
                    zcmp_last_mr <= zcmp_det_last_mr;
                    // For eff_data lower-half Zcmp: park upper half into hold
                    if (zcmp_det_eff_lo) begin
                        hold_valid      <= 1'b1;
                        hold            <= eff_data[31:16];
                        hold_pc         <= eff_pc + 32'd2;
                        hold_from_split <= (eff_data[17:16] == 2'b11) ? 1'b1 : 1'b0;
                    end
                    // For hold Zcmp: clear hold (instruction consumed into sequencer)
                    else if (zcmp_det_hold) begin
                        hold_valid      <= 1'b0;
                        hold_from_split <= 1'b0;
                    end
                    // For eff_data upper-half Zcmp (init_offset): clear init_offset
                    else if (zcmp_det_eff_hi) begin
                        init_offset <= 1'b0;
                    end
                end
                else begin
                    // Normal (non-Zcmp) fetch state machine
                    if (split32 && eff_valid) begin
                        // split32 consumed: eff_data[31:16] is the upper bits of the completing
                        // word.  They form the start of the next instruction after the split32.
                        // pc_if was advanced by the split32 mr=1, so hold_from_split=1.
                        hold_valid      <= 1'b1;
                        hold            <= eff_data[31:16];
                        hold_pc         <= {eff_pc[31:2], 2'b10};  // byte addr of eff_data[31:16]
                        hold_from_split <= 1'b1;
                    end
                    else if (hold_valid && !split32) begin
                        // Hold consumed (mem_ready was asserted in comb).
                        hold_valid      <= 1'b0;
                        hold_from_split <= 1'b0;
                    end
                    else if (eff_valid) begin
                        if (init_offset) begin
                            init_offset <= 1'b0;
                            if (eff_data[17:16] == 2'b11) begin
                                hold_valid      <= 1'b1;
                                hold            <= eff_data[31:16];
                                hold_pc         <= eff_pc + 32'd2;
                                hold_from_split <= 1'b0;
                            end
                        end
                        else if (eff_data[1:0] != 2'b11) begin
                            // Compressed lower half: park upper half in hold.
                            hold_valid      <= 1'b1;
                            hold            <= eff_data[31:16];
                            hold_pc         <= eff_pc + 32'd2;
                            hold_from_split <= 1'b0;
                        end
                        // else: full 32-bit - nothing to hold
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst_n);
        else begin
            `DEBUG2(`DBG_GRP_FETCH,
                    ("[RVC] pc=%08x iv=%b mr=%b hv=%b s32=%b io=%b stl=%b fl=%b fl_pc=%08x eff_pc=%08x eff_data=%08x eff_v=%b",
                     instr_pc, instr_valid, mem_ready, hold_valid, split32, init_offset, stall,
                     flush, flush_pc, eff_pc, eff_data, eff_valid));
        end
    end
`endif

endmodule
