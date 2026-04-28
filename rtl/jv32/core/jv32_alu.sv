// ============================================================================
// File        : jv32_alu.sv
// Project     : JV32 RISC-V Processor
// Description : RISC-V 32-bit ALU - RV32IM subset
//
// Supports RV32I base + M extension (multiply/divide).
// No B-extension.  FAST_SHIFT adds optional barrel shifter.
//
// FAST_MUL=1, MUL_MC=1 : 2-stage pipelined multiply - stage 1 computes four unsigned 16x16
//                         partial products; stage 2 accumulates + sign-corrects; 2 cycles.
// FAST_MUL=1, MUL_MC=0 : 1-cycle combinatorial 32x32 multiply (no pipeline stall).
// FAST_MUL=0            : serial shift-and-add, variable latency
// FAST_DIV=1            : combinatorial divide (1 cycle)
// FAST_DIV=0            : serial restoring divider, variable latency
// FAST_SHIFT=1          : barrel shifter (1 cycle)
// FAST_SHIFT=0          : 1-bit-per-cycle serial shifter
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

module jv32_alu #(
    parameter bit RV32M_EN   = 1'b1,  // 1=M-extension (mul/div); 0=no multiply/divide hardware
    parameter bit FAST_MUL   = 1'b1,
    parameter bit MUL_MC     = 1'b1,  // 1=2-stage pipelined (2 cyc); 0=1-cycle comb. (requires FAST_MUL=1)
    parameter bit FAST_DIV   = 1'b0,
    parameter bit FAST_SHIFT = 1'b1,
    parameter bit ZB_EN      = 1'b1   // 1=Zba/Zbb/Zbs enabled; 0=only base ops (synthesized away)
) (
    input  logic           clk,
    input  logic           rst_n,
`ifndef SYNTHESIS
    input  alu_op_e        alu_op,
`else
    input  logic    [ 5:0] alu_op,
`endif
    input  logic    [31:0] operand_a,
    input  logic    [31:0] operand_b,
    input  logic           operand_stall,
    input  logic           result_hold,
    output logic    [31:0] result,
    output logic           ready
);
    import jv32_pkg::*;

    // ========================================================================
    // Shift Logic
    // ========================================================================
    logic [31:0] result_sll, result_srl, result_sra;
    logic shift_ready;

    generate
        if (FAST_SHIFT == 1) begin : gen_barrel_shift
            // SRL and SRA share a single right-shift barrel tree.
            // fill_mask sets the vacated MSBs to operand_a[31] for SRA;
            // it is zero for SRL (unsigned fill), so no extra mux is needed.
            logic [31:0] result_sr;
            logic [31:0] fill_mask;
            assign result_sr   = operand_a >> operand_b[4:0];
            assign fill_mask   = ~(32'hFFFF_FFFF >> operand_b[4:0]) & {32{operand_a[31]}};
            assign result_sll  = operand_a << operand_b[4:0];
            assign result_srl  = result_sr;
            assign result_sra  = result_sr | fill_mask;
            assign shift_ready = 1'b1;
        end
        else begin : gen_serial_shift
            logic [4:0] sh_count, sh_total;
            logic [31:0] sh_val;
            logic [31:0] sh_result;
            logic sh_active, sh_valid;
            logic        sh_arith;
            logic        sh_left;
            logic [31:0] sh_sign_fill;  // sign extension for SRA

            logic        is_shift_op;
            assign is_shift_op = (alu_op == ALU_SLL || alu_op == ALU_SRL || alu_op == ALU_SRA);

            logic [31:0] sh_next_val;
            assign sh_next_val = sh_left ? {sh_val[30:0], 1'b0} :
                                 sh_arith ? {sh_sign_fill[31], sh_val[31:1]} :
                                            {1'b0, sh_val[31:1]};

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    sh_count     <= 5'd0;
                    sh_total     <= 5'd0;
                    sh_val       <= 32'd0;
                    sh_active    <= 1'b0;
                    sh_result    <= 32'd0;
                    sh_valid     <= 1'b0;
                    sh_arith     <= 1'b0;
                    sh_left      <= 1'b0;
                    sh_sign_fill <= 32'd0;
                end
                else begin
                    if (sh_valid && !result_hold) sh_valid <= 1'b0;

                    if (is_shift_op && !sh_active && !sh_valid && !operand_stall) begin
                        sh_total     <= operand_b[4:0];
                        sh_arith     <= (alu_op == ALU_SRA);
                        sh_left      <= (alu_op == ALU_SLL);
                        sh_sign_fill <= {32{operand_a[31]}};
                        if (operand_b[4:0] == 5'd0) begin
                            sh_val    <= operand_a;
                            sh_result <= operand_a;
                            sh_valid  <= 1'b1;
                        end
                        else begin
                            sh_count  <= 5'd0;
                            sh_val    <= operand_a;
                            sh_active <= 1'b1;
                        end
                    end
                    else if (sh_active) begin
                        sh_val <= sh_next_val;
                        if (sh_count + 1 >= sh_total) begin
                            sh_result <= sh_next_val;
                            sh_valid  <= 1'b1;
                            sh_active <= 1'b0;
                        end
                        else sh_count <= sh_count + 1;
                    end
                end
            end

            assign result_sll  = sh_valid ? sh_result : sh_val;
            assign result_srl  = sh_valid ? sh_result : sh_val;
            assign result_sra  = sh_valid ? sh_result : sh_val;

            // shift_ready is only asserted once sh_valid is set.
            // The operand_b==0 shortcut was removed: it caused shift_ready to
            // fire one cycle early (before the FF latches sh_result), producing
            // stale sh_val as the result for shift-by-0 operations.
            assign shift_ready = !is_shift_op || (!sh_active && (operand_stall || sh_valid));
        end
    endgenerate

    // ========================================================================
    // Multiplication Logic
    // ========================================================================
    logic [31:0] result_mul_lo, result_mulh_hi, result_mulhsu_hi, result_mulhu_hi;
    logic mul_ready;

    generate
        if (!RV32M_EN) begin : gen_no_mul
            assign result_mul_lo    = 32'h0;
            assign result_mulh_hi   = 32'h0;
            assign result_mulhsu_hi = 32'h0;
            assign result_mulhu_hi  = 32'h0;
            assign mul_ready        = 1'b1;
        end
        else if (FAST_MUL == 1 && MUL_MC == 1) begin : gen_fast_mul_pipe
            // ----------------------------------------------------------------
            // 2-stage pipelined multiplier.
            // Stage 1 (dispatch cycle): compute four unsigned 16x16 partial
            //   products and register them.  Pipeline stalls (mul_ready=0).
            // Stage 2 (result cycle):   accumulate partial products into a
            //   64-bit unsigned product, then subtract sign-correction terms
            //   for MULH / MULHSU variants.  Pipeline released (mul_ready=1).
            //
            // Breaking the 32x32 multiply into four 16x16 multiplications
            // halves the combinatorial depth of the critical path and
            // eliminates the need for any STA multicycle-path constraint.
            //
            // Sign-correction identity (upper 32 bits only):
            //   signed_a x signed_b = unsigned_a x unsigned_b
            //                           op_a_r[31] x op_b_r x 2^32   (a<0)
            //                           op_b_r[31] x op_a_r x 2^32   (b<0)
            //   For MULHSU only the first correction applies.
            // ----------------------------------------------------------------
            logic is_mul_op;
            assign is_mul_op = (alu_op == ALU_MUL || alu_op == ALU_MULH || alu_op == ALU_MULHSU || alu_op == ALU_MULHU);

            // Stage-1 combinatorial partial products (unsigned 16x16 -> 32-bit)
            logic [31:0] pp_ll, pp_lh, pp_hl, pp_hh;
            assign pp_ll = {16'b0, operand_a[15:0]} * {16'b0, operand_b[15:0]};
            assign pp_lh = {16'b0, operand_a[15:0]} * {16'b0, operand_b[31:16]};
            assign pp_hl = {16'b0, operand_a[31:16]} * {16'b0, operand_b[15:0]};
            assign pp_hh = {16'b0, operand_a[31:16]} * {16'b0, operand_b[31:16]};

            // Stage-1 -> Stage-2 pipeline registers
            logic [31:0] pp_ll_r, pp_lh_r, pp_hl_r, pp_hh_r;
            logic [31:0] op_a_r, op_b_r;  // latched operands for sign correction
            logic s1_valid;               // stage-1 partial products are ready

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pp_ll_r  <= 32'd0;
                    pp_lh_r  <= 32'd0;
                    pp_hl_r  <= 32'd0;
                    pp_hh_r  <= 32'd0;
                    op_a_r   <= 32'd0;
                    op_b_r   <= 32'd0;
                    s1_valid <= 1'b0;
                end
                else begin
                    if (s1_valid && !result_hold) s1_valid <= 1'b0;  // result consumed
                    else if (is_mul_op && !s1_valid && !operand_stall) begin
                        pp_ll_r  <= pp_ll;
                        pp_lh_r  <= pp_lh;
                        pp_hl_r  <= pp_hl;
                        pp_hh_r  <= pp_hh;
                        op_a_r   <= operand_a;
                        op_b_r   <= operand_b;
                        s1_valid <= 1'b1;
                    end
                end
            end

            assign mul_ready = !is_mul_op || operand_stall || s1_valid;

            // Stage-2 accumulation:
            //   unsigned_product = pp_hh*2^32 + (pp_hl+pp_lh)*2^16 + pp_ll
            logic [63:0] acc;
            assign acc = {pp_hh_r, 32'b0} + {16'b0, pp_hl_r, 16'b0} + {16'b0, pp_lh_r, 16'b0} + {32'b0, pp_ll_r};

            // Sign-correction terms (32-bit, applied to upper half of result)
            logic [31:0] corr_a, corr_b;
            assign corr_a           = op_a_r[31] ? op_b_r : 32'b0;
            assign corr_b           = op_b_r[31] ? op_a_r : 32'b0;

            assign result_mul_lo    = acc[31:0];
            assign result_mulhu_hi  = acc[63:32];
            assign result_mulh_hi   = acc[63:32] - corr_a - corr_b;
            assign result_mulhsu_hi = acc[63:32] - corr_a;
        end
        else if (FAST_MUL == 1 && MUL_MC == 0) begin : gen_fast_mul_1c
            // ----------------------------------------------------------------
            // 1-cycle combinatorial 32x32 multiplier.  No pipeline stall.
            // ----------------------------------------------------------------
            logic [63:0] result_mul, result_mulu, result_mulsu;
            assign result_mul = $signed({{32{operand_a[31]}}, operand_a}) * $signed({{32{operand_b[31]}}, operand_b});
            assign result_mulu = $unsigned({{32{1'b0}}, operand_a}) * $unsigned({{32{1'b0}}, operand_b});
            assign result_mulsu = $signed({{32{operand_a[31]}}, operand_a}) * $unsigned({{32{1'b0}}, operand_b});
            assign result_mul_lo = result_mul[31:0];
            assign result_mulh_hi = result_mul[63:32];
            assign result_mulhsu_hi = result_mulsu[63:32];
            assign result_mulhu_hi = result_mulu[63:32];
            assign mul_ready = 1'b1;
            logic _unused_mul_1c;
            assign _unused_mul_1c = &{1'b0, result_mulu[31:0], result_mulsu[31:0]};
        end
        else begin : gen_serial_mul
            logic [5:0] mul_count, mul_total;
            logic [63:0] mul_a_shift;
            logic [31:0] mul_b_reg;
            logic [63:0] mul_acc;
            logic mul_valid, mul_active, mul_neg;
            logic [63:0] mul_result;

            logic is_mul_op, is_signed_a_mul, is_signed_b_mul;
            assign is_mul_op = (alu_op == ALU_MUL || alu_op == ALU_MULH || alu_op == ALU_MULHSU || alu_op == ALU_MULHU);
            assign is_signed_a_mul = (alu_op == ALU_MULH || alu_op == ALU_MULHSU);
            assign is_signed_b_mul = (alu_op == ALU_MULH);

            logic [31:0] abs_a_mul, abs_b_mul;
            assign abs_a_mul = (is_signed_a_mul && operand_a[31]) ? (~operand_a + 1) : operand_a;
            assign abs_b_mul = (is_signed_b_mul && operand_b[31]) ? (~operand_b + 1) : operand_b;

            logic [5:0] clz_b_mul;
            always_comb begin
                clz_b_mul = 6'd32;
                for (int i = 0; i <= 31; i++) if (abs_b_mul[i]) clz_b_mul = 6'(31 - i);
            end

            logic [63:0] mul_next_acc, mul_next_a_shift;
            logic [31:0] mul_next_b_reg;
            assign mul_next_acc     = mul_b_reg[0] ? (mul_acc + mul_a_shift) : mul_acc;
            assign mul_next_a_shift = mul_a_shift << 1;
            assign mul_next_b_reg   = mul_b_reg >> 1;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    mul_count   <= 6'd0;
                    mul_total   <= 6'd0;
                    mul_a_shift <= 64'd0;
                    mul_b_reg   <= 32'd0;
                    mul_acc     <= 64'd0;
                    mul_valid   <= 1'b0;
                    mul_active  <= 1'b0;
                    mul_neg     <= 1'b0;
                    mul_result  <= 64'd0;
                end
                else begin
                    if (mul_valid && !result_hold) mul_valid <= 1'b0;
                    if (is_mul_op && !mul_active && !mul_valid && clz_b_mul != 6'd32 && !operand_stall) begin
                        mul_total   <= 6'd32 - clz_b_mul;
                        mul_count   <= 6'd0;
                        mul_a_shift <= {32'd0, abs_a_mul};
                        mul_b_reg   <= abs_b_mul;
                        mul_acc     <= 64'd0;
                        mul_neg     <= (is_signed_a_mul && operand_a[31]) ^ (is_signed_b_mul && operand_b[31]);
                        mul_active  <= 1'b1;
                    end
                    else if (mul_active) begin
                        if (mul_count + 1 >= mul_total) begin
                            mul_result <= mul_neg ? (~mul_next_acc + 1) : mul_next_acc;
                            mul_valid  <= 1'b1;
                            mul_active <= 1'b0;
                        end
                        else begin
                            mul_acc     <= mul_next_acc;
                            mul_a_shift <= mul_next_a_shift;
                            mul_b_reg   <= mul_next_b_reg;
                            mul_count   <= mul_count + 1;
                        end
                    end
                end
            end

            logic use_mul_result;
            assign use_mul_result   = mul_active || mul_valid;
            assign result_mul_lo    = use_mul_result ? mul_result[31:0] : 32'd0;
            assign result_mulh_hi   = use_mul_result ? mul_result[63:32] : 32'd0;
            assign result_mulhsu_hi = use_mul_result ? mul_result[63:32] : 32'd0;
            assign result_mulhu_hi  = use_mul_result ? mul_result[63:32] : 32'd0;
            assign mul_ready        = !is_mul_op || (!mul_active && (operand_stall || clz_b_mul == 6'd32 || mul_valid));
        end
    endgenerate

    // ========================================================================
    // Division Logic
    // ========================================================================
    logic [31:0] result_div, result_divu, result_rem, result_remu;
    logic div_ready;

    generate
        if (!RV32M_EN) begin : gen_no_div
            assign result_div  = 32'h0;
            assign result_divu = 32'h0;
            assign result_rem  = 32'h0;
            assign result_remu = 32'h0;
            assign div_ready   = 1'b1;
        end
        else if (FAST_DIV == 1) begin : gen_fast_div
            assign result_div  = (operand_b==32'h0) ? 32'hffffffff :
                                 ((operand_a==32'h80000000)&&(operand_b==32'hffffffff)) ? 32'h80000000 :
                                 $signed(
                $signed(operand_a) / $signed(operand_b)
            );
            assign result_divu = (operand_b == 32'h0) ? 32'hffffffff : $unsigned(
                $unsigned(operand_a) / $unsigned(operand_b)
            );
            assign result_rem  = (operand_b==32'h0) ? operand_a :
                                 ((operand_a==32'h80000000)&&(operand_b==32'hffffffff)) ? 32'h0 :
                                 $signed(
                $signed(operand_a) % $signed(operand_b)
            );
            assign result_remu = (operand_b == 32'h0) ? operand_a : $unsigned(
                $unsigned(operand_a) % $unsigned(operand_b)
            );
            assign div_ready = 1'b1;
        end
        else begin : gen_serial_div
            logic [5:0] div_count, div_total;
            logic [31:0] div_q, div_r, div_abs_b;
            logic div_valid, div_active, div_neg_q, div_neg_r;
            logic div_by_zero_lat, div_signed_ovf_lat;
            logic [31:0] div_operand_a_lat, div_result_q, div_result_r;

            logic is_div_op, is_signed_div;
            assign is_div_op     = (alu_op == ALU_DIV || alu_op == ALU_DIVU || alu_op == ALU_REM || alu_op == ALU_REMU);
            assign is_signed_div = (alu_op == ALU_DIV || alu_op == ALU_REM);

            logic [31:0] abs_a, abs_b;
            assign abs_a = (is_signed_div && operand_a[31]) ? (~operand_a + 1) : operand_a;
            assign abs_b = (is_signed_div && operand_b[31]) ? (~operand_b + 1) : operand_b;

            logic [5:0] clz_a;
            always_comb begin
                clz_a = 6'd32;
                for (int i = 0; i <= 31; i++) if (abs_a[i]) clz_a = 6'(31 - i);
            end

            logic div_by_zero, signed_ovf;

            assign div_by_zero = (operand_b == 32'h0);

            // DIV overflow special case applies only to signed DIV/REM.
            assign signed_ovf  = is_signed_div && (operand_a == 32'h80000000) && (operand_b == 32'hffffffff);

            logic [32:0] r_trial;
            logic        q_bit;
            logic [31:0] next_q, next_r;

            assign r_trial = {div_r[31:0], div_q[31]};
            assign q_bit   = (r_trial >= {1'b0, div_abs_b});
            assign next_q  = {div_q[30:0], q_bit};
            assign next_r  = q_bit ? r_trial[31:0] - div_abs_b : r_trial[31:0];

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    div_count          <= 6'd0;
                    div_total          <= 6'd0;
                    div_q              <= 32'd0;
                    div_r              <= 32'd0;
                    div_abs_b          <= 32'd0;
                    div_valid          <= 1'b0;
                    div_active         <= 1'b0;
                    div_neg_q          <= 1'b0;
                    div_neg_r          <= 1'b0;
                    div_by_zero_lat    <= 1'b0;
                    div_signed_ovf_lat <= 1'b0;
                    div_operand_a_lat  <= 32'd0;
                    div_result_q       <= 32'd0;
                    div_result_r       <= 32'd0;
                end
                else begin
                    if (div_valid && !result_hold) begin
                        div_valid <= 1'b0;
                    end

                    if (is_div_op && !div_active && !div_valid && !operand_stall) begin
                        if (!div_by_zero && !signed_ovf) begin
                            div_total          <= 6'd32 - clz_a;
                            div_count          <= 6'd0;
                            div_q              <= abs_a << clz_a;
                            div_r              <= 32'd0;
                            div_abs_b          <= abs_b;
                            div_neg_q          <= is_signed_div && (operand_a[31] ^ operand_b[31]);
                            div_neg_r          <= is_signed_div && operand_a[31];
                            div_by_zero_lat    <= div_by_zero;
                            div_signed_ovf_lat <= signed_ovf;
                            div_operand_a_lat  <= operand_a;
                            if (clz_a == 6'd32) begin
                                div_result_q <= 32'd0;
                                div_result_r <= 32'd0;
                                div_valid    <= 1'b1;
                            end
                            else begin
                                div_active <= 1'b1;
                            end
                        end
                    end
                    else if (div_active) begin
                        div_q <= next_q;
                        div_r <= next_r;
                        if (div_count + 1 >= div_total) begin
                            div_result_q <= div_neg_q ? (~next_q + 1) : next_q;
                            div_result_r <= div_neg_r ? (~next_r + 1) : next_r;
                            div_valid    <= 1'b1;
                            div_active   <= 1'b0;
                        end
                        else begin
                            div_count <= div_count + 1;
                        end
                    end
                end
            end

            logic use_latched;

            assign use_latched = div_active || div_valid;

            logic eff_by_zero, eff_signed_ovf;
            logic [31:0] eff_operand_a;

            assign eff_by_zero = use_latched ? div_by_zero_lat : div_by_zero;
            assign eff_signed_ovf = use_latched ? div_signed_ovf_lat : signed_ovf;
            assign eff_operand_a = use_latched ? div_operand_a_lat : operand_a;
            assign result_div = eff_by_zero ? 32'hffffffff : eff_signed_ovf ? 32'h80000000 : div_result_q;
            assign result_divu = eff_by_zero ? 32'hffffffff : div_result_q;
            assign result_rem = eff_by_zero ? eff_operand_a : eff_signed_ovf ? 32'h0 : div_result_r;
            assign result_remu = eff_by_zero ? eff_operand_a : div_result_r;
            assign div_ready = !is_div_op || (!div_active && (operand_stall || div_by_zero || signed_ovf || div_valid));
        end
    endgenerate

    // ========================================================================
    // Zba / Zbb / Zbs Logic
    // ========================================================================
    logic [31:0] zb_result;
    logic        zb_ready;

    generate
        if (!ZB_EN) begin : gen_no_zb
            assign zb_result = 32'h0;
            assign zb_ready  = 1'b1;
        end
        else begin : gen_zb
            // ------------------------------------------------------------------
            // Rotate left/right.
            // FAST_SHIFT=1 : barrel combinatorial (1 cycle, shares barrel tree
            //                built in gen_barrel_shift).
            // FAST_SHIFT=0 : serial 1-bit-per-cycle rotator (same latency as
            //                serial shifter; shares the ready handshake style).
            // ------------------------------------------------------------------
            logic [31:0] result_rol, result_ror;
            logic rot_ready;

            if (FAST_SHIFT == 1) begin : gen_zb_fast_rot
                logic [4:0] rot_amt;
                assign rot_amt    = operand_b[4:0];
                assign result_rol = (operand_a << rot_amt) | (operand_a >> (5'(32) - rot_amt));
                assign result_ror = (operand_a >> rot_amt) | (operand_a << (5'(32) - rot_amt));
                assign rot_ready  = 1'b1;
            end
            else begin : gen_zb_slow_rot
                logic [4:0] rot_count, rot_total;
                logic [31:0] rot_val;
                logic [31:0] rot_res;
                logic rot_active, rot_valid;
                logic rot_left;

                logic is_rot_op;
                assign is_rot_op = (alu_op == ALU_ROL || alu_op == ALU_ROR);

                logic [31:0] rot_next_val;
                assign rot_next_val = rot_left ? {rot_val[30:0], rot_val[31]} : {rot_val[0], rot_val[31:1]};

                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        rot_count  <= 5'd0;
                        rot_total  <= 5'd0;
                        rot_val    <= 32'd0;
                        rot_res    <= 32'd0;
                        rot_active <= 1'b0;
                        rot_valid  <= 1'b0;
                        rot_left   <= 1'b0;
                    end
                    else begin
                        if (rot_valid && !result_hold) rot_valid <= 1'b0;
                        if (is_rot_op && !rot_active && !rot_valid && !operand_stall) begin
                            rot_left <= (alu_op == ALU_ROL);
                            if (operand_b[4:0] == 5'd0) begin
                                rot_res   <= operand_a;
                                rot_valid <= 1'b1;
                            end
                            else begin
                                rot_count  <= 5'd0;
                                rot_total  <= operand_b[4:0];
                                rot_val    <= operand_a;
                                rot_active <= 1'b1;
                            end
                        end
                        else if (rot_active) begin
                            rot_val <= rot_next_val;
                            if (rot_count + 1 >= rot_total) begin
                                rot_res    <= rot_next_val;
                                rot_valid  <= 1'b1;
                                rot_active <= 1'b0;
                            end
                            else rot_count <= rot_count + 1;
                        end
                    end
                end

                assign result_rol = rot_valid ? rot_res : rot_val;
                assign result_ror = rot_valid ? rot_res : rot_val;
                assign rot_ready  = !is_rot_op || (!rot_active && (operand_stall || rot_valid));
            end

            // ------------------------------------------------------------------
            // CLZ (count leading zeros)
            // ------------------------------------------------------------------
            logic [5:0] clz_count;
            always_comb begin
                clz_count = 6'd32;
                for (int i = 0; i <= 31; i++) begin
                    if (operand_a[i]) clz_count = 6'(31 - i);
                end
            end

            // ------------------------------------------------------------------
            // CTZ (count trailing zeros)
            // ------------------------------------------------------------------
            logic [5:0] ctz_count;
            always_comb begin
                ctz_count = 6'd32;
                for (int i = 31; i >= 0; i--) begin
                    if (operand_a[i]) ctz_count = 6'(i);
                end
            end

            // ------------------------------------------------------------------
            // CPOP (population count)
            // ------------------------------------------------------------------
            logic [5:0] cpop_count;
            always_comb begin
                cpop_count = 6'd0;
                for (int i = 0; i <= 31; i++) cpop_count = cpop_count + 6'(operand_a[i]);
            end

            // ------------------------------------------------------------------
            // ORC.B (or-combine: OR all bits of each byte, broadcast to byte)
            // ------------------------------------------------------------------
            logic [31:0] orcb_result;
            assign orcb_result = {
                {8{|operand_a[31:24]}}, {8{|operand_a[23:16]}}, {8{|operand_a[15:8]}}, {8{|operand_a[7:0]}}
            };

            // ------------------------------------------------------------------
            // REV8 (byte-reverse)
            // ------------------------------------------------------------------
            logic [31:0] rev8_result;
            assign rev8_result = {operand_a[7:0], operand_a[15:8], operand_a[23:16], operand_a[31:24]};

            // ------------------------------------------------------------------
            // Zb result mux
            // ------------------------------------------------------------------
            always_comb begin
                case (alu_op)
                    // Zba
                    ALU_SH1ADD: zb_result = (operand_a << 1) + operand_b;
                    ALU_SH2ADD: zb_result = (operand_a << 2) + operand_b;
                    ALU_SH3ADD: zb_result = (operand_a << 3) + operand_b;
                    // Zbb
                    ALU_CLZ:    zb_result = {26'd0, clz_count};
                    ALU_CTZ:    zb_result = {26'd0, ctz_count};
                    ALU_CPOP:   zb_result = {26'd0, cpop_count};
                    ALU_ANDN:   zb_result = operand_a & ~operand_b;
                    ALU_ORN:    zb_result = operand_a | ~operand_b;
                    ALU_XNOR:   zb_result = operand_a ^ ~operand_b;
                    ALU_MIN:    zb_result = ($signed(operand_a) < $signed(operand_b)) ? operand_a : operand_b;
                    ALU_MINU:   zb_result = (operand_a < operand_b) ? operand_a : operand_b;
                    ALU_MAX:    zb_result = ($signed(operand_a) > $signed(operand_b)) ? operand_a : operand_b;
                    ALU_MAXU:   zb_result = (operand_a > operand_b) ? operand_a : operand_b;
                    ALU_SEXTB:  zb_result = {{24{operand_a[7]}},  operand_a[7:0]};
                    ALU_SEXTH:  zb_result = {{16{operand_a[15]}}, operand_a[15:0]};
                    ALU_ZEXTH:  zb_result = {16'd0, operand_a[15:0]};
                    ALU_ROL:    zb_result = result_rol;
                    ALU_ROR:    zb_result = result_ror;
                    ALU_ORCB:   zb_result = orcb_result;
                    ALU_REV8:   zb_result = rev8_result;
                    // Zbs
                    ALU_BCLR:   zb_result = operand_a & ~(32'd1 << operand_b[4:0]);
                    ALU_BEXT:   zb_result = {31'd0, operand_a[operand_b[4:0]]};
                    ALU_BINV:   zb_result = operand_a ^ (32'd1 << operand_b[4:0]);
                    ALU_BSET:   zb_result = operand_a | (32'd1 << operand_b[4:0]);
                    default:    zb_result = 32'd0;
                endcase
            end

            assign zb_ready = rot_ready;
        end
    endgenerate

    // ========================================================================
    // Output Mux
    // ========================================================================
    always_comb begin
        case (alu_op)
            ALU_ADD:    result = operand_a + operand_b;
            ALU_SUB:    result = operand_a - operand_b;
            ALU_SLL:    result = result_sll;
            ALU_SLT:    result = ($signed(operand_a) < $signed(operand_b)) ? 32'd1 : 32'd0;
            ALU_SLTU:   result = (operand_a < operand_b) ? 32'd1 : 32'd0;
            ALU_XOR:    result = operand_a ^ operand_b;
            ALU_SRL:    result = result_srl;
            ALU_SRA:    result = result_sra;
            ALU_OR:     result = operand_a | operand_b;
            ALU_AND:    result = operand_a & operand_b;
            ALU_MUL:    result = result_mul_lo;
            ALU_MULH:   result = result_mulh_hi;
            ALU_MULHSU: result = result_mulhsu_hi;
            ALU_MULHU:  result = result_mulhu_hi;
            ALU_DIV:    result = result_div;
            ALU_DIVU:   result = result_divu;
            ALU_REM:    result = result_rem;
            ALU_REMU:   result = result_remu;
            // Zba/Zbb/Zbs: routed through zb_result
            default:    result = ZB_EN ? zb_result : 32'd0;
        endcase
    end

    assign ready = div_ready && mul_ready && shift_ready && zb_ready;

`ifndef SYNTHESIS
    // Suppress unused clk/rst_n warnings for all-combinatorial configurations
    // (FAST_MUL=1,MUL_MC=0 + FAST_DIV=1 + FAST_SHIFT=1).
    logic _unused_clk;
    assign _unused_clk = &{1'b0, clk, rst_n, operand_stall, result_hold};
`endif

endmodule
