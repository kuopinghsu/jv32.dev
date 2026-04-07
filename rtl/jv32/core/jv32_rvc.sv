// ============================================================================
// File: jv32_rvc.sv
// Project: JV32 RISC-V Processor
// Description: RVC (Zca + Zcb) Compressed-Instruction Expander
//
// Simplified from kv32_rvc: single-issue, no Zcmp micro-sequencer, no IB.
// Handles: (1) two compressed per word, (2) split 32-bit across words,
// (3) halfword-aligned fetch targets.
//
// hold[1:0]==11 → case_d (split 32-bit lower half buffered)
// hold[1:0]!=11 → case_c (compressed instruction buffered)
// init_offset   → skip lower halfword on first post-flush fetch
// ============================================================================

`ifdef SYNTHESIS
import jv32_pkg::*;
`endif

module jv32_rvc #(
    parameter bit RVM23_EN = 1'b1
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

`ifndef SYNTHESIS
    import jv32_pkg::*;
`endif

    logic        hold_valid;
    logic [15:0] hold;
    logic [31:0] hold_pc;
    logic        init_offset;
    logic        pend_valid;
    logic [31:0] pend_data;
    logic [31:0] pend_pc;

    /* verilator lint_off WIDTHEXPAND */
    function automatic logic [31:0] c_sext6 (input logic [5:0]  v);
        c_sext6  = 32'(v); if (v[5])  c_sext6  |= 32'hFFFF_FFC0; endfunction
    function automatic logic [31:0] c_sext9 (input logic [8:0]  v);
        c_sext9  = 32'(v); if (v[8])  c_sext9  |= 32'hFFFF_FF00; endfunction
    function automatic logic [31:0] c_sext10(input logic [9:0]  v);
        c_sext10 = 32'(v); if (v[9])  c_sext10 |= 32'hFFFF_FE00; endfunction
    function automatic logic [31:0] c_sext12(input logic [11:0] v);
        c_sext12 = 32'(v); if (v[11]) c_sext12 |= 32'hFFFF_F000; endfunction
    /* verilator lint_on WIDTHEXPAND */

    /* verilator lint_off UNUSEDSIGNAL */
    /* verilator lint_off WIDTHEXPAND */
    function automatic logic [31:0] c_j_off(input logic [15:0] ci);
        c_j_off = c_sext12({ci[12],ci[8],ci[10:9],ci[6],ci[7],ci[2],ci[11],ci[5:3],1'b0});
    endfunction
    function automatic logic [31:0] c_b_off(input logic [15:0] ci);
        c_b_off = c_sext9({ci[12],ci[6:5],ci[2],ci[11:10],ci[4:3],1'b0});
    endfunction
    function automatic logic [31:0] enc_jal(input logic [4:0] rd, input logic [31:0] im);
        enc_jal = {im[20],im[10:1],im[11],im[19:12],rd,7'h6F};
    endfunction
    function automatic logic [31:0] enc_br(
        input logic [2:0] f3, input logic [4:0] rs1,
        input logic [4:0] rs2, input logic [31:0] im);
        enc_br = {im[12],im[10:5],rs2,rs1,f3,im[4:1],im[11],7'h63};
    endfunction

    function automatic logic [31:0] expand_c(input logic [15:0] ci);
        logic [1:0]  quad, funct2;
        logic [2:0]  funct3;
        logic [4:0]  rd_rs1, rs2, rd_p, rs1_p, rs2_p;
        logic [11:0] nzuimm12, uimm12;
        logic [31:0] nzimm, imm;
        logic        f1;
        logic [1:0]  f2_low;

        quad   = ci[1:0]; funct3 = ci[15:13];
        rd_p   = {2'b01, ci[4:2]};
        rs1_p  = {2'b01, ci[9:7]};
        rs2_p  = {2'b01, ci[4:2]};
        expand_c = 32'h0;

        case (quad)
        2'b00: case (funct3)
            3'h0: begin
                nzuimm12 = {ci[10:7],ci[12:11],ci[5],ci[6],2'b00};
                expand_c = (nzuimm12==12'h0) ? 32'h0 : {nzuimm12,5'd2,3'h0,rd_p,7'h13};
            end
            3'h2: expand_c = {{5'b0,ci[5],ci[12:10],ci[6],2'b00},rs1_p,3'h2,rd_p,7'h03};
            3'h6: begin
                uimm12 = {5'b0,ci[5],ci[12:10],ci[6],2'b00};
                expand_c = {uimm12[11:5],rs2_p,rs1_p,3'h2,uimm12[4:0],7'h23};
            end
            3'h4: if (!RVM23_EN) expand_c = 32'h0;
                  else case (ci[12:10])
                    3'b000: expand_c = {{10'b0,ci[5],ci[6]},rs1_p,3'h4,rd_p,7'h03};
                    3'b001: expand_c = !ci[6] ? {{10'b0,ci[5],1'b0},rs1_p,3'h5,rd_p,7'h03}
                                              : {{10'b0,ci[5],1'b0},rs1_p,3'h1,rd_p,7'h03};
                    3'b010: begin uimm12={10'b0,ci[5],ci[6]}; expand_c={uimm12[11:5],rs2_p,rs1_p,3'h0,uimm12[4:0],7'h23}; end
                    3'b011: begin uimm12={10'b0,ci[5],1'b0};  expand_c={uimm12[11:5],rs2_p,rs1_p,3'h1,uimm12[4:0],7'h23}; end
                    default: expand_c = 32'h0;
                  endcase
            default: expand_c = 32'h0;
        endcase

        2'b01: begin
            rd_rs1 = ci[11:7];
            case (funct3)
            3'h0: expand_c = {c_sext6({ci[12],ci[6:2]})[11:0],rd_rs1,3'h0,rd_rs1,7'h13};
            3'h1: expand_c = enc_jal(5'd1, c_j_off(ci));
            3'h2: expand_c = {c_sext6({ci[12],ci[6:2]})[11:0],5'd0,3'h0,rd_rs1,7'h13};
            3'h3: begin
                if (rd_rs1 == 5'd2) begin
                    nzimm = c_sext10({ci[12],ci[4:3],ci[5],ci[2],ci[6],4'b0});
                    expand_c = (nzimm==32'h0) ? 32'h0 : {nzimm[11:0],5'd2,3'h0,5'd2,7'h13};
                end else begin
                    nzimm = c_sext6({ci[12],ci[6:2]});
                    expand_c = (nzimm==32'h0) ? 32'h0 : {nzimm[19:0],rd_rs1,7'h37};
                end
            end
            3'h4: begin
                funct2 = ci[11:10];
                rd_p   = {2'b01,ci[9:7]}; rs2_p = {2'b01,ci[4:2]};
                case (funct2)
                2'h0: expand_c = {7'h00,ci[6:2],rd_p,3'h5,rd_p,7'h13};
                2'h1: expand_c = {7'h20,ci[6:2],rd_p,3'h5,rd_p,7'h13};
                2'h2: expand_c = {c_sext6({ci[12],ci[6:2]})[11:0],rd_p,3'h7,rd_p,7'h13};
                2'h3: begin
                    f1=ci[12]; f2_low=ci[6:5];
                    if (!f1) case (f2_low)
                        2'h0: expand_c={7'h20,rs2_p,rd_p,3'h0,rd_p,7'h33};
                        2'h1: expand_c={7'h00,rs2_p,rd_p,3'h4,rd_p,7'h33};
                        2'h2: expand_c={7'h00,rs2_p,rd_p,3'h6,rd_p,7'h33};
                        2'h3: expand_c={7'h00,rs2_p,rd_p,3'h7,rd_p,7'h33};
                    endcase
                    else if (RVM23_EN) case (f2_low)
                        2'h2: expand_c={7'h01,rs2_p,rd_p,3'h0,rd_p,7'h33};
                        2'h3: case (ci[4:2])
                            3'b000: expand_c={12'hFF, rd_p,3'h7,rd_p,7'h13};
                            3'b101: expand_c={12'hFFF,rd_p,3'h4,rd_p,7'h13};
                            default: expand_c=32'h0;
                        endcase
                        default: expand_c=32'h0;
                    endcase
                end
                endcase
            end
            3'h5: expand_c = enc_jal(5'd0, c_j_off(ci));
            3'h6: expand_c = enc_br(3'h0,{2'b01,ci[9:7]},5'd0,c_b_off(ci));
            3'h7: expand_c = enc_br(3'h1,{2'b01,ci[9:7]},5'd0,c_b_off(ci));
            endcase
        end

        2'b10: begin
            rd_rs1=ci[11:7]; rs2=ci[6:2];
            case (funct3)
            3'h0: expand_c={7'h00,ci[6:2],rd_rs1,3'h1,rd_rs1,7'h13};
            3'h2: begin
                if (rd_rs1==5'd0) expand_c=32'h0;
                else begin
                    uimm12={4'b0,ci[3:2],ci[12],ci[6:4],2'b00};
                    expand_c={uimm12,5'd2,3'h2,rd_rs1,7'h03};
                end
            end
            3'h4: begin
                f1=ci[12];
                if (!f1) begin
                    if (rs2==5'd0) expand_c=(rd_rs1==5'd0)?32'h0:{12'h0,rd_rs1,3'h0,5'd0,7'h67};
                    else expand_c={7'h00,rs2,5'd0,3'h0,rd_rs1,7'h33};
                end else begin
                    if      (rd_rs1==5'd0 && rs2==5'd0) expand_c=32'h00100073;
                    else if (rs2==5'd0) expand_c={12'h0,rd_rs1,3'h0,5'd1,7'h67};
                    else    expand_c={7'h00,rs2,rd_rs1,3'h0,rd_rs1,7'h33};
                end
            end
            3'h6: begin
                uimm12={4'b0,ci[8:7],ci[12:9],2'b00};
                expand_c={uimm12[11:5],rs2,5'd2,3'h2,uimm12[4:0],7'h23};
            end
            default: expand_c=32'h0;
            endcase
        end

        default: expand_c=32'h0;
        endcase
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_on WIDTHEXPAND */

    // Effective memory response
    logic eff_valid; logic [31:0] eff_data, eff_pc;
    always_comb begin
        if (pend_valid) begin eff_valid=1'b1; eff_data=pend_data; eff_pc=pend_pc; end
        else begin eff_valid=imem_resp_valid; eff_data=imem_resp_data; eff_pc=imem_resp_pc; end
    end

    logic split32;
    assign split32 = hold_valid && (hold[1:0] == 2'b11);

    // Combinational output
    always_comb begin
        instr_valid=1'b0; instr_data=32'h13; orig_instr=32'h13;
        instr_pc=32'h0; is_compressed=1'b0; mem_ready=1'b1;
        if (!stall) begin
            if (split32) begin
                if (eff_valid) begin
                    instr_valid=1'b1; instr_data={eff_data[15:0],hold}; orig_instr={eff_data[15:0],hold};
                    instr_pc=hold_pc; is_compressed=1'b0;
                end
            end else if (hold_valid) begin
                instr_valid=1'b1; instr_data=expand_c(hold); orig_instr={16'h0,hold};
                instr_pc=hold_pc; is_compressed=1'b1; mem_ready=1'b0;
            end else if (eff_valid) begin
                if (init_offset) begin
                    if (eff_data[17:16]!=2'b11) begin
                        instr_valid=1'b1; instr_data=expand_c(eff_data[31:16]);
                        orig_instr={16'h0,eff_data[31:16]}; instr_pc=eff_pc+32'd2; is_compressed=1'b1;
                    end
                end else if (eff_data[1:0]==2'b11) begin
                    instr_valid=1'b1; instr_data=eff_data; orig_instr=eff_data; instr_pc=eff_pc;
                end else begin
                    instr_valid=1'b1; instr_data=expand_c(eff_data[15:0]);
                    orig_instr={16'h0,eff_data[15:0]}; instr_pc=eff_pc; is_compressed=1'b1;
                    mem_ready=1'b0;
                end
            end
        end else begin mem_ready=1'b0; instr_valid=1'b0; end
    end

    // Sequential state
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_valid<=1'b0; hold<=16'h0; hold_pc<=32'h0;
            init_offset<=1'b0; pend_valid<=1'b0; pend_data<=32'h0; pend_pc<=32'h0;
        end else if (flush) begin
            hold_valid<=1'b0; pend_valid<=1'b0; init_offset<=flush_pc[1];
        end else begin
            // Park fresh response while hold is consuming (prevent loss)
            if (hold_valid && !pend_valid && imem_resp_valid && !stall)
                begin pend_valid<=1'b1; pend_data<=imem_resp_data; pend_pc<=imem_resp_pc; end

            if (!stall) begin
                if (split32 && eff_valid) begin
                    hold_valid<=1'b0;
                    if (pend_valid) pend_valid<=1'b0;
                end else if (hold_valid && !split32) begin
                    hold_valid<=1'b0;
                    if (pend_valid) pend_valid<=1'b0;
                end else if (eff_valid) begin
                    if (init_offset) begin
                        init_offset<=1'b0;
                        if (eff_data[17:16]==2'b11)
                            begin hold_valid<=1'b1; hold<=eff_data[31:16]; hold_pc<=eff_pc+32'd2; end
                        if (pend_valid) pend_valid<=1'b0;
                    end else if (eff_data[1:0]==2'b11) begin
                        if (pend_valid) pend_valid<=1'b0;
                    end else begin
                        hold_valid<=1'b1; hold<=eff_data[31:16]; hold_pc<=eff_pc+32'd2;
                        if (pend_valid) pend_valid<=1'b0;
                    end
                end
            end
        end
    end

endmodule
