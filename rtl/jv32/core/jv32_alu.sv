// ============================================================================
// File: jv32_alu.sv
// Project: JV32 RISC-V Processor
// Description: RISC-V 32-bit ALU — RV32IM subset
//
// Supports RV32I base + M extension (multiply/divide).
// No B-extension.  FAST_SHIFT adds optional barrel shifter.
//
// FAST_MUL=1  : combinatorial multiply (1 cycle)
// FAST_MUL=0  : serial shift-and-add, variable latency
// FAST_DIV=1  : combinatorial divide (1 cycle)
// FAST_DIV=0  : serial restoring divider, variable latency
// FAST_SHIFT=1: barrel shifter (1 cycle)
// FAST_SHIFT=0: 1-bit-per-cycle serial shifter
// ============================================================================

module jv32_alu #(
    parameter bit FAST_MUL   = 1'b1,
    parameter bit FAST_DIV   = 1'b0,
    parameter bit FAST_SHIFT = 1'b1
) (
    input  logic           clk,
    input  logic           rst_n,
`ifndef SYNTHESIS
    input  alu_op_e        alu_op,
`else
    input  logic    [ 4:0] alu_op,
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
            assign result_sll  = operand_a << operand_b[4:0];
            assign result_srl  = operand_a >> operand_b[4:0];
            assign result_sra  = $signed(operand_a) >>> operand_b[4:0];
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
        if (FAST_MUL == 1) begin : gen_fast_mul
            logic [63:0] result_mul, result_mulu, result_mulsu;
            assign result_mul = $signed({{32{operand_a[31]}}, operand_a}) * $signed({{32{operand_b[31]}}, operand_b});
            assign result_mulu = $unsigned({{32{1'b0}}, operand_a}) * $unsigned({{32{1'b0}}, operand_b});
            assign result_mulsu = $signed({{32{operand_a[31]}}, operand_a}) * $unsigned({{32{1'b0}}, operand_b});
            assign result_mul_lo = result_mul[31:0];
            assign result_mulh_hi = result_mul[63:32];
            assign result_mulhsu_hi = result_mulsu[63:32];
            assign result_mulhu_hi = result_mulu[63:32];
            assign mul_ready = 1'b1;
            logic _unused_mul;
            assign _unused_mul = &{1'b0, result_mulu[31:0], result_mulsu[31:0]};
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
        if (FAST_DIV == 1) begin : gen_fast_div
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
                    if (div_valid && !result_hold) div_valid <= 1'b0;
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
                            else div_active <= 1'b1;
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
                        else div_count <= div_count + 1;
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
            default:    result = 32'd0;
        endcase
    end

    assign ready = div_ready && mul_ready && shift_ready;

`ifndef SYNTHESIS
    logic _unused_clk;
    assign _unused_clk = &{1'b0, clk, rst_n, operand_stall, result_hold};
`endif

endmodule
