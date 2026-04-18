// ============================================================================
// File: jv32_decoder.sv
// Project: JV32 RISC-V Processor
// Description: RV32IMAC + Zicsr Instruction Decoder
//
// Decodes 32-bit pre-expanded instructions (C instructions already expanded
// by jv32_rvc) into control signals for the 3-stage pipeline.
// ============================================================================

module jv32_decoder (
    input logic [31:0] instr,
    input logic        valid,

    output logic       [ 4:0] rs1_addr,
    output logic       [ 4:0] rs2_addr,
    output logic       [ 4:0] rd_addr,
    output logic       [31:0] imm,
`ifndef SYNTHESIS
    output alu_op_e           alu_op,
`else
    output logic       [ 4:0] alu_op,
`endif
    output logic              alu_src,     // 0=rs2, 1=imm
    output logic              reg_we,
    output logic              mem_read,
    output logic              mem_write,
`ifndef SYNTHESIS
    output mem_size_e         mem_op,
`else
    output logic       [ 2:0] mem_op,
`endif
    output logic              branch,
`ifndef SYNTHESIS
    output branch_op_e        branch_op,
`else
    output logic       [ 2:0] branch_op,
`endif
    output logic              jal,
    output logic              jalr,
    output logic              lui,
    output logic              auipc,
    output logic              illegal,
    output logic       [ 2:0] csr_op,
    output logic       [11:0] csr_addr,
    output logic              is_mret,
    output logic              is_ecall,
    output logic              is_ebreak,
    output logic              is_amo,
`ifndef SYNTHESIS
    output amo_op_e           amo_op,
`else
    output logic       [ 4:0] amo_op,
`endif
    output logic              is_fence,
    output logic              is_fence_i,
    output logic              is_wfi
);
    import jv32_pkg::*;

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [4:0] funct5;

    assign opcode   = instr[6:0];
    assign funct3   = instr[14:12];
    assign funct7   = instr[31:25];
    assign funct5   = instr[31:27];

    assign rs1_addr = instr[19:15];
    assign rs2_addr = instr[24:20];
    assign rd_addr  = instr[11:7];
    assign csr_addr = instr[31:20];

    // Immediate generation
    always_comb begin
        case (opcode)
            OPCODE_OP_IMM, OPCODE_LOAD, OPCODE_JALR, OPCODE_SYSTEM: imm = {{20{instr[31]}}, instr[31:20]};
            OPCODE_STORE: imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            OPCODE_BRANCH: imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
            OPCODE_LUI, OPCODE_AUIPC: imm = {instr[31:12], 12'b0};
            OPCODE_JAL: imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
            default: imm = 32'd0;
        endcase
    end

    // Control signal generation
    always_comb begin
        alu_op     = ALU_ADD;
        alu_src    = 1'b0;
        reg_we     = 1'b0;
        mem_read   = 1'b0;
        mem_write  = 1'b0;
        mem_op     = MEM_WORD;
        branch     = 1'b0;
        branch_op  = BRANCH_EQ;
        jal        = 1'b0;
        jalr       = 1'b0;
        lui        = 1'b0;
        auipc      = 1'b0;
        illegal    = 1'b0;
        csr_op     = 3'b0;
        is_mret    = 1'b0;
        is_ecall   = 1'b0;
        is_ebreak  = 1'b0;
        is_amo     = 1'b0;
        amo_op     = AMO_ADD;
        is_fence   = 1'b0;
        is_fence_i = 1'b0;
        is_wfi     = 1'b0;

        if (valid) begin
            case (opcode)
                OPCODE_OP_IMM: begin
                    alu_src = 1'b1;
                    reg_we  = 1'b1;
                    case (funct3)
                        3'b000:  alu_op = ALU_ADD;
                        3'b010:  alu_op = ALU_SLT;
                        3'b011:  alu_op = ALU_SLTU;
                        3'b100:  alu_op = ALU_XOR;
                        3'b110:  alu_op = ALU_OR;
                        3'b111:  alu_op = ALU_AND;
                        3'b001: begin
                            if (funct7 == 7'h00) alu_op = ALU_SLL;
                            else illegal = 1'b1;
                        end
                        3'b101: begin
                            if (funct7 == 7'h00) alu_op = ALU_SRL;
                            else if (funct7 == 7'h20) alu_op = ALU_SRA;
                            else illegal = 1'b1;
                        end
                        default: ;
                    endcase
                end

                OPCODE_OP: begin
                    reg_we = 1'b1;
                    if (funct7 == 7'h01) begin  // M extension
                        case (funct3)
                            3'b000:  alu_op = ALU_MUL;
                            3'b001:  alu_op = ALU_MULH;
                            3'b010:  alu_op = ALU_MULHSU;
                            3'b011:  alu_op = ALU_MULHU;
                            3'b100:  alu_op = ALU_DIV;
                            3'b101:  alu_op = ALU_DIVU;
                            3'b110:  alu_op = ALU_REM;
                            3'b111:  alu_op = ALU_REMU;
                            default: ;
                        endcase
                    end
                    else begin
                        case ({
                            funct7, funct3
                        })
                            {7'h00, 3'b000} : alu_op = ALU_ADD;
                            {7'h20, 3'b000} : alu_op = ALU_SUB;
                            {7'h00, 3'b001} : alu_op = ALU_SLL;
                            {7'h00, 3'b010} : alu_op = ALU_SLT;
                            {7'h00, 3'b011} : alu_op = ALU_SLTU;
                            {7'h00, 3'b100} : alu_op = ALU_XOR;
                            {7'h00, 3'b101} : alu_op = ALU_SRL;
                            {7'h20, 3'b101} : alu_op = ALU_SRA;
                            {7'h00, 3'b110} : alu_op = ALU_OR;
                            {7'h00, 3'b111} : alu_op = ALU_AND;
                            default: illegal = 1'b1;
                        endcase
                    end
                end

                OPCODE_LOAD: begin
                    alu_src  = 1'b1;
                    reg_we   = 1'b1;
                    mem_read = 1'b1;
`ifndef SYNTHESIS
                    mem_op = mem_size_e'(funct3);
`else
                    mem_op = funct3;
`endif
                    if (funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111) illegal = 1'b1;
                end

                OPCODE_STORE: begin
                    alu_src   = 1'b1;
                    mem_write = 1'b1;
`ifndef SYNTHESIS
                    mem_op = mem_size_e'(funct3);
`else
                    mem_op = funct3;
`endif
                    if (funct3 > 3'b010) illegal = 1'b1;
                end

                OPCODE_BRANCH: begin
                    branch = 1'b1;
`ifndef SYNTHESIS
                    branch_op = branch_op_e'(funct3);
`else
                    branch_op = funct3;
`endif
                    if (funct3 == 3'b010 || funct3 == 3'b011) illegal = 1'b1;
                end

                OPCODE_JAL: begin
                    jal    = 1'b1;
                    reg_we = 1'b1;
                end
                OPCODE_JALR: begin
                    jalr    = 1'b1;
                    reg_we  = 1'b1;
                    alu_src = 1'b1;
                    if (funct3 != 3'b000) illegal = 1'b1;
                end
                OPCODE_LUI: begin
                    lui    = 1'b1;
                    reg_we = 1'b1;
                end
                OPCODE_AUIPC: begin
                    auipc   = 1'b1;
                    alu_src = 1'b1;
                    reg_we  = 1'b1;
                end

                OPCODE_SYSTEM: begin
                    if (funct3 == 3'b000) begin
                        if (instr[31:20] == 12'h000) is_ecall = 1'b1;
                        else if (instr[31:20] == 12'h001) is_ebreak = 1'b1;
                        else if (instr[31:20] == 12'h302) is_mret = 1'b1;
                        else if (instr[31:20] == 12'h105) is_wfi = 1'b1;
                        else illegal = 1'b1;
                    end
                    else begin
                        csr_op = funct3;
                        reg_we = 1'b1;
                        // Write to read-only CSR is illegal
                        if (instr[31:30] == 2'b11 && (funct3[1:0] == 2'b01 || rs1_addr != 5'd0)) illegal = 1'b1;
                        // Unknown CSR → illegal
                        if (instr[31:20] != CSR_MSTATUS    &&
                            instr[31:20] != CSR_MSTATUSH   &&
                            instr[31:20] != CSR_MISA       &&
                            instr[31:20] != CSR_MIE        &&
                            instr[31:20] != CSR_MTVEC      &&
                            instr[31:20] != CSR_MSCRATCH   &&
                            instr[31:20] != CSR_MEPC       &&
                            instr[31:20] != CSR_MCAUSE     &&
                            instr[31:20] != CSR_MTVAL      &&
                            instr[31:20] != CSR_MIP        &&
                            instr[31:20] != CSR_MTVT       &&
                            instr[31:20] != CSR_MNXTI      &&
                            instr[31:20] != CSR_MINTSTATUS &&
                            instr[31:20] != CSR_MINTTHRESH &&
                            instr[31:20] != CSR_MCYCLE     &&
                            instr[31:20] != CSR_MCYCLEH    &&
                            instr[31:20] != CSR_MINSTRET   &&
                            instr[31:20] != CSR_MINSTRETH  &&
                            instr[31:20] != CSR_MVENDORID  &&
                            instr[31:20] != CSR_MARCHID    &&
                            instr[31:20] != CSR_MIMPID     &&
                            instr[31:20] != CSR_MHARTID)
                            illegal = 1'b1;
                    end
                end

                OPCODE_AMO: begin
                    is_amo   = 1'b1;
                    reg_we   = 1'b1;
                    mem_read = 1'b1;
                    alu_src  = 1'b1;
                    if (funct3 != 3'b010) illegal = 1'b1;
`ifndef SYNTHESIS
                    amo_op = amo_op_e'(funct5);
`else
                    amo_op = funct5;
`endif
                end

                OPCODE_MISC_MEM: begin
                    is_fence   = (funct3 == 3'b000);
                    is_fence_i = (funct3 == 3'b001);
                    if (funct3 > 3'b001) illegal = 1'b1;
                end

                default: illegal = 1'b1;
            endcase
        end
    end

endmodule
