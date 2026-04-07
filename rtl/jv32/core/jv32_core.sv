// ============================================================================
// File: jv32_core.sv
// Project: JV32 RISC-V Processor
// Description: RV32IMAC 3-Stage Pipeline Core (IF → EX → WB)
//
// Pipeline stages:
//   IF  : PC + instruction fetch request (via jv32_rvc)
//   EX  : decode, register read, ALU, address calc, CSR, hazard detect
//   WB  : memory result, writeback, redirect, exception
//
// Hazards:
//   - Load-use : 1-cycle stall (EX→WB stall + IF hold)
//   - Branch/jump : 1-cycle flush on misprediction (EX squashes IF)
//   - Multi-cycle ALU (mul/div/shift) : stall entire pipeline
//   - AMO : IDLE → LOAD_WAIT → STORE_WAIT state machine
//
// Forwarding: WB→EX same-cycle forwarding (register data available in WB)
// ============================================================================

`ifdef SYNTHESIS
import jv32_pkg::*;
`endif

module jv32_core #(
    parameter bit        FAST_MUL   = 1'b1,
    parameter bit        FAST_DIV   = 1'b1,
    parameter bit        FAST_SHIFT = 1'b1,
    parameter bit        BP_EN      = 1'b1,
    parameter logic [31:0] BOOT_ADDR = 32'h8000_0000
) (
    input  logic        clk,
    input  logic        rst_n,

    // Instruction memory request/response
    output logic        imem_req_valid,
    output logic [31:0] imem_req_addr,
    input  logic        imem_resp_valid,
    input  logic [31:0] imem_resp_data,
    input  logic [31:0] imem_resp_pc,

    // Data memory request/response
    output logic        dmem_req_valid,
    output logic        dmem_req_write,
    output logic [31:0] dmem_req_addr,
    output logic [31:0] dmem_req_wdata,
    output logic [3:0]  dmem_req_wstrb,
    input  logic        dmem_resp_valid,
    input  logic [31:0] dmem_resp_data,

    // Interrupts
    input  logic        timer_irq,
    input  logic        external_irq,
    input  logic        software_irq,
    // CLIC sideband
    input  logic        clic_irq,
    input  logic [7:0]  clic_level,
    input  logic [7:0]  clic_prio,
    input  logic [4:0]  clic_id,            // winning IRQ index for mtvt table
    output logic        clic_ack,

    // I-fetch flush: asserted on branch/jump/exception/mret/IRQ redirect.
    // Allows jv32_top to suppress the stale TCM response arriving one cycle later.
    output logic        imem_flush,

    // Trace (one entry per retired instruction)
    output logic        trace_valid,
    output logic        trace_reg_we,
    output logic [31:0] trace_pc,
    output logic [4:0]  trace_rd,
    output logic [31:0] trace_rd_data
);
`ifndef SYNTHESIS
    import jv32_pkg::*;
`endif

    // =====================================================================
    // RVC expander
    // =====================================================================
    logic        rvc_instr_valid;
    logic [31:0] rvc_instr_data;
    logic [31:0] rvc_orig_instr;
    logic [31:0] rvc_instr_pc;
    logic        rvc_is_compressed;
    logic        rvc_mem_ready;
    logic        rvc_flush;
    logic [31:0] rvc_flush_pc;
    logic        rvc_stall;

    jv32_rvc #(.RVM23_EN(1'b1)) u_rvc (
        .clk              (clk),
        .rst_n            (rst_n),
        .imem_resp_valid  (imem_resp_valid),
        .imem_resp_data   (imem_resp_data),
        .imem_resp_pc     (imem_resp_pc),
        .stall            (rvc_stall),
        .flush            (rvc_flush),
        .flush_pc         (rvc_flush_pc),
        .instr_valid      (rvc_instr_valid),
        .instr_data       (rvc_instr_data),
        .orig_instr       (rvc_orig_instr),
        .instr_pc         (rvc_instr_pc),
        .is_compressed    (rvc_is_compressed),
        .mem_ready        (rvc_mem_ready)
    );

    // =====================================================================
    // Regfile
    // =====================================================================
    logic [4:0]  rs1_addr_d, rs2_addr_d;
    logic [31:0] rs1_data,   rs2_data;
    logic        rf_we;
    logic [4:0]  rf_rd;
    logic [31:0] rf_wdata;

    jv32_regfile u_regfile (
        .clk      (clk),
        .rst_n    (rst_n),
        .rs1_addr (rs1_addr_d),
        .rs2_addr (rs2_addr_d),
        .rs1_data (rs1_data),
        .rs2_data (rs2_data),
        .we       (rf_we),
        .rd_addr  (rf_rd),
        .rd_data  (rf_wdata)
    );

    // =====================================================================
    // ALU
    // =====================================================================
    alu_op_e     alu_op_d;
    logic [31:0] alu_op_a, alu_op_b;
    logic        alu_operand_stall;
    logic [31:0] alu_result;
    logic        alu_ready;

    jv32_alu #(
        .FAST_MUL   (FAST_MUL),
        .FAST_DIV   (FAST_DIV),
        .FAST_SHIFT (FAST_SHIFT)
    ) u_alu (
        .clk           (clk),
        .rst_n         (rst_n),
        .alu_op        (alu_op_d),
        .operand_a     (alu_op_a),
        .operand_b     (alu_op_b),
        .operand_stall (alu_operand_stall),
        .result        (alu_result),
        .ready         (alu_ready)
    );

    // =====================================================================
    // Decoder
    // =====================================================================
    // Decoder wires driven from IF/EX pipeline register
    if_ex_t if_ex_r;

    logic [4:0]  dec_rs1, dec_rs2, dec_rd;
    logic [31:0] dec_imm;
    alu_op_e     dec_alu_op;
    logic        dec_alu_src;
    logic        dec_reg_we;
    logic        dec_mem_read, dec_mem_write;
    mem_size_e   dec_mem_op;
    logic        dec_branch;
    branch_op_e  dec_branch_op;
    logic        dec_jal, dec_jalr;
    logic        dec_lui, dec_auipc;
    logic        dec_illegal;
    logic [2:0]  dec_csr_op;
    logic [11:0] dec_csr_addr;
    logic        dec_is_mret, dec_is_ecall, dec_is_ebreak;
    logic        dec_is_amo;
    amo_op_e     dec_amo_op;
    logic        dec_is_fence, dec_is_fence_i;
    logic        dec_is_wfi;

    jv32_decoder u_decoder (
        .instr      (if_ex_r.instr),
        .valid      (if_ex_r.valid),
        .rs1_addr   (dec_rs1),
        .rs2_addr   (dec_rs2),
        .rd_addr    (dec_rd),
        .imm        (dec_imm),
        .alu_op     (dec_alu_op),
        .alu_src    (dec_alu_src),
        .reg_we     (dec_reg_we),
        .mem_read   (dec_mem_read),
        .mem_write  (dec_mem_write),
        .mem_op     (dec_mem_op),
        .branch     (dec_branch),
        .branch_op  (dec_branch_op),
        .jal        (dec_jal),
        .jalr       (dec_jalr),
        .lui        (dec_lui),
        .auipc      (dec_auipc),
        .illegal    (dec_illegal),
        .csr_op     (dec_csr_op),
        .csr_addr   (dec_csr_addr),
        .is_mret    (dec_is_mret),
        .is_ecall   (dec_is_ecall),
        .is_ebreak  (dec_is_ebreak),
        .is_amo     (dec_is_amo),
        .amo_op     (dec_amo_op),
        .is_fence   (dec_is_fence),
        .is_fence_i (dec_is_fence_i),
        .is_wfi     (dec_is_wfi)
    );

    // =====================================================================
    // CSR
    // =====================================================================
    logic [31:0] csr_rdata;
    logic [31:0] mtvec_csr;
    logic [31:0] mepc_csr;
    logic        csr_irq_pending;
    logic [31:0] csr_irq_cause;
    logic [31:0] csr_irq_pc;
    logic        csr_tail_chain;
    logic [31:0] csr_tail_chain_pc;

    // EX→WB pipeline register
    ex_wb_t ex_wb_r;

    jv32_csr u_csr (
        .clk              (clk),
        .rst_n            (rst_n),
        .csr_addr         (dec_csr_addr),
        .csr_op           (dec_csr_op),
        .csr_wdata        (alu_op_a),   // forwarded rs1
        .csr_zimm         (dec_rs1),    // zimm from rs1 field
        .csr_rdata        (csr_rdata),
        .exception        (ex_wb_r.valid && ex_wb_r.exception),
        .exception_cause  (ex_wb_r.exc_cause),
        .exception_pc     (ex_wb_r.pc),
        .exception_tval   (ex_wb_r.exc_tval),
        .mret             (ex_wb_r.valid && ex_wb_r.mret),
        .wb_valid         (ex_wb_r.valid),
        .mtvec_o          (mtvec_csr),
        .mepc_o           (mepc_csr),
        .timer_irq        (timer_irq),
        .external_irq     (external_irq),
        .software_irq     (software_irq),
        .clic_irq         (clic_irq),
        .clic_level       (clic_level),
        .clic_prio        (clic_prio),
        .clic_id          (clic_id),
        .clic_ack         (clic_ack),
        .tail_chain_o     (csr_tail_chain),
        .tail_chain_pc_o  (csr_tail_chain_pc),
        .irq_pending      (csr_irq_pending),
        .irq_cause        (csr_irq_cause),
        .irq_pc           (csr_irq_pc),
        .instret_inc      (ex_wb_r.valid && !ex_wb_r.exception && !ex_wb_r.mret)
    );

    // =====================================================================
    // IF Stage
    // =====================================================================
    logic [31:0] pc_if;
    logic        if_stall;
    logic        if_flush;
    logic [31:0] if_flush_pc;

    assign imem_req_valid = 1'b1;
    assign imem_req_addr  = pc_if;

    // =====================================================================
    // Static Branch Predictor: Backward-Taken / Forward-Not-Taken (BTFNT)
    //
    // Pre-decode runs on the expanded instruction at the RVC output, one
    // cycle before it is latched into the IF/EX register.
    //
    // For a BRANCH (opcode 7'b110_0011) the B-immediate sign bit is
    // instr[31].  A negative offset means a backward (likely loop-back)
    // branch → predict taken.  A positive offset → predict not-taken.
    //
    // When predicting taken:
    //   - pc_if is steered to the target (replaces the next sequential fetch)
    //   - The RVC buffer is flushed to discard any instruction already fetched
    //     from PC+4 that is now on the wrong path
    //   - bp_taken=1 is recorded in the IF/EX register for the branch itself
    //
    // In EX the actual outcome is compared against the prediction:
    //   - predicted NOT-taken but actually taken  → redirect to branch_target
    //   - predicted     taken  but actually not   → redirect to PC+instr_size
    //   - correct prediction                      → no redirect (0-cycle penalty)
    // =====================================================================
    logic        bp_is_branch;
    logic [31:0] bp_imm;       // sign-extended B-type immediate
    logic [31:0] bp_target_if; // predicted branch target
    logic        bp_redirect;  // fire the BP redirect this cycle
    logic [31:0] bp_redirect_pc;

    // Identify BRANCH opcode on the expanded instruction
    assign bp_is_branch = (rvc_instr_data[6:0] == 7'b110_0011);

    // Reconstruct B-immediate: {sign×19, imm[12], imm[11], imm[10:5], imm[4:1], 1'b0}
    assign bp_imm = {{19{rvc_instr_data[31]}},
                     rvc_instr_data[31],   // imm[12]
                     rvc_instr_data[7],    // imm[11]
                     rvc_instr_data[30:25],// imm[10:5]
                     rvc_instr_data[11:8], // imm[4:1]
                     1'b0};

    assign bp_target_if  = rvc_instr_pc + bp_imm;

    // Predict taken only for backward branches (negative offset → imm signed < 0).
    // Suppress if a higher-priority flush is already in flight or pipeline is stalled.
    assign bp_redirect    = BP_EN && bp_is_branch && rvc_instr_data[31] &&
                            rvc_instr_valid && !if_stall && !if_flush;
    assign bp_redirect_pc = bp_target_if;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) pc_if <= BOOT_ADDR;
        else if (!if_stall) begin
            if      (if_flush)    pc_if <= if_flush_pc;
            else if (bp_redirect) pc_if <= bp_redirect_pc;
            else if (rvc_mem_ready) pc_if <= pc_if + 32'd4;
        end
    end
    logic ex_stall;   // stall EX stage (and upstream)
    logic ex_flush;   // inject bubble into EX

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if_ex_r <= '0;
        end else if (!ex_stall) begin
            if (ex_flush || if_flush) begin
                if_ex_r <= '0;
            end else if (rvc_instr_valid) begin
                if_ex_r.valid         <= 1'b1;
                if_ex_r.pc            <= rvc_instr_pc;
                if_ex_r.instr         <= rvc_instr_data;
                if_ex_r.orig_instr    <= rvc_orig_instr;
                if_ex_r.is_compressed <= rvc_is_compressed;
                if_ex_r.bp_taken      <= bp_redirect; // BTFNT: record prediction
            end else begin
                if_ex_r <= '0;
            end
        end
    end

    assign rs1_addr_d = dec_rs1;
    assign rs2_addr_d = dec_rs2;

    // =====================================================================
    // WB result (needed for forwarding)
    // =====================================================================
    logic [31:0] wb_rd_data;
    always_comb begin
        if (ex_wb_r.mem_read)
            wb_rd_data = dmem_resp_data; // load data (already available in WB)
        else
            wb_rd_data = ex_wb_r.rd_data;
    end

    // =====================================================================
    // Forwarding: WB→EX (single forwarding path)
    // =====================================================================
    logic [31:0] fwd_rs1, fwd_rs2;
    always_comb begin
        fwd_rs1 = rs1_data;
        fwd_rs2 = rs2_data;
        if (ex_wb_r.valid && ex_wb_r.reg_we && ex_wb_r.rd_addr != 5'd0) begin
            if (ex_wb_r.rd_addr == dec_rs1) fwd_rs1 = wb_rd_data;
            if (ex_wb_r.rd_addr == dec_rs2) fwd_rs2 = wb_rd_data;
        end
    end

    // =====================================================================
    // EX Stage: operand + address calculation
    // =====================================================================
    logic [31:0] pc_ex;
    assign pc_ex = if_ex_r.pc;

    // ALU operands
    always_comb begin
        alu_op_a = fwd_rs1;
        alu_op_b = dec_alu_src ? dec_imm : fwd_rs2;
        if (dec_auipc || dec_jal) alu_op_a = pc_ex;
        alu_op_d = dec_alu_op;
    end

    logic [31:0] branch_target;
    assign branch_target = pc_ex + dec_imm;

    // Branch evaluation
    logic branch_taken;
    always_comb begin
        case (dec_branch_op)
            BRANCH_EQ:  branch_taken = (fwd_rs1 == fwd_rs2);
            BRANCH_NE:  branch_taken = (fwd_rs1 != fwd_rs2);
            BRANCH_LT:  branch_taken = ($signed(fwd_rs1) < $signed(fwd_rs2));
            BRANCH_GE:  branch_taken = ($signed(fwd_rs1) >= $signed(fwd_rs2));
            BRANCH_LTU: branch_taken = (fwd_rs1 < fwd_rs2);
            BRANCH_GEU: branch_taken = (fwd_rs1 >= fwd_rs2);
            default:    branch_taken = 1'b0;
        endcase
    end

    // Redirect PC
    logic [31:0] redirect_pc_ex;
    logic        redirect_ex;
    always_comb begin
        redirect_ex    = 1'b0;
        redirect_pc_ex = 32'h0;
        if (if_ex_r.valid) begin
            if (dec_jal)  begin redirect_ex = 1'b1; redirect_pc_ex = pc_ex + dec_imm; end
            if (dec_jalr) begin redirect_ex = 1'b1; redirect_pc_ex = (fwd_rs1 + dec_imm) & ~32'h1; end
            if (dec_branch) begin
                if (!BP_EN) begin
                    // Predict-not-taken fallback
                    if (branch_taken)
                        begin redirect_ex = 1'b1; redirect_pc_ex = branch_target; end
                end else begin
                    // BTFNT: redirect only on misprediction
                    if (branch_taken && !if_ex_r.bp_taken)
                        // predicted not-taken, actually taken
                        begin redirect_ex = 1'b1; redirect_pc_ex = branch_target; end
                    else if (!branch_taken && if_ex_r.bp_taken)
                        // predicted taken, actually not-taken → squash speculative fetch
                        begin redirect_ex = 1'b1;
                              redirect_pc_ex = pc_ex + (if_ex_r.is_compressed ? 32'd2 : 32'd4);
                        end
                end
            end
        end
    end

    // CSR: write data
    logic [31:0] csr_wdata_ex;
    always_comb begin
        csr_wdata_ex = alu_op_a; // CSRRW/CSRRS/CSRRC: rs1
        // CSRRWI/CSRRSI/CSRRCI: zimm
        if (dec_csr_op[2]) csr_wdata_ex = {27'd0, dec_rs1};
    end

    // Link address for JAL/JALR
    logic [31:0] link_addr;
    assign link_addr = pc_ex + (if_ex_r.is_compressed ? 32'd2 : 32'd4);

    // EX result
    logic [31:0] ex_result;
    always_comb begin
        if      (dec_jal || dec_jalr)    ex_result = link_addr;
        else if (dec_lui)                 ex_result = dec_imm;
        else if (dec_auipc)              ex_result = alu_result;
        else if (dec_csr_op != 3'b0)     ex_result = csr_rdata;
        else                             ex_result = alu_result;
    end

    // Memory address and store data
    logic [31:0] mem_addr_ex;
    logic [31:0] store_data_ex;
    assign mem_addr_ex  = fwd_rs1 + dec_imm; // for loads/stores
    assign store_data_ex= fwd_rs2;

    // Store byte enable
    logic [3:0] wstrb_ex;
    always_comb begin
        case (dec_mem_op)
            MEM_BYTE:   wstrb_ex = 4'b0001 << mem_addr_ex[1:0];
            MEM_HALF:   wstrb_ex = 4'b0011 << {mem_addr_ex[1], 1'b0};
            default:    wstrb_ex = 4'b1111;
        endcase
    end

    // Store data alignment
    logic [31:0] store_data_aligned;
    always_comb begin
        case (dec_mem_op)
            MEM_BYTE: store_data_aligned = {4{store_data_ex[7:0]}};
            MEM_HALF: store_data_aligned = {2{store_data_ex[15:0]}};
            default:  store_data_aligned = store_data_ex;
        endcase
    end

    // Exception detection in EX
    logic        ex_exception;
    exc_cause_e  ex_exc_cause;
    logic [31:0] ex_exc_tval;
    always_comb begin
        ex_exception = 1'b0;
        ex_exc_cause = EXC_ILLEGAL_INSTR;
        ex_exc_tval  = if_ex_r.orig_instr;
        if (if_ex_r.valid) begin
            if (dec_illegal) begin
                ex_exception = 1'b1;
                ex_exc_cause = EXC_ILLEGAL_INSTR;
                ex_exc_tval  = if_ex_r.orig_instr;
            end else if (dec_is_ebreak) begin
                ex_exception = 1'b1;
                ex_exc_cause = EXC_BREAKPOINT;
                ex_exc_tval  = 32'h0;
            end else if (dec_is_ecall) begin
                ex_exception = 1'b1;
                ex_exc_cause = EXC_ECALL_MMODE;
                ex_exc_tval  = 32'h0;
            end else if ((dec_mem_read || dec_mem_write) &&
                         ((dec_mem_op == MEM_HALF && mem_addr_ex[0]) ||
                          (dec_mem_op == MEM_WORD && mem_addr_ex[1:0] != 2'b00))) begin
                ex_exception = 1'b1;
                ex_exc_cause = dec_mem_read ? EXC_LOAD_ADDR_MISALIGNED : EXC_STORE_ADDR_MISALIGNED;
                ex_exc_tval  = mem_addr_ex;
            end
        end
    end

    // Load-use hazard: EX has a load, WB still waiting for data
    // (simplified: stall if previous instruction was a load targeting any rs of current)
    logic load_use_stall;
    assign load_use_stall = ex_wb_r.valid && ex_wb_r.mem_read && !dmem_resp_valid &&
                            ((ex_wb_r.rd_addr == dec_rs1 && dec_rs1 != 5'd0) ||
                             (ex_wb_r.rd_addr == dec_rs2 && dec_rs2 != 5'd0 && !dec_alu_src));

    // AMO state machine
    typedef enum logic [1:0] {AMO_IDLE, AMO_LOAD_WAIT, AMO_STORE_WAIT} amo_state_e;
    amo_state_e amo_state;
    logic [31:0] amo_load_data;
    logic [31:0] amo_store_val;
    logic        lr_valid;
    logic [31:0] lr_addr;

    always_comb begin
        case (dec_amo_op)
            AMO_SWAP: amo_store_val = fwd_rs2;
            AMO_ADD:  amo_store_val = amo_load_data + fwd_rs2;
            AMO_XOR:  amo_store_val = amo_load_data ^ fwd_rs2;
            AMO_AND:  amo_store_val = amo_load_data & fwd_rs2;
            AMO_OR:   amo_store_val = amo_load_data | fwd_rs2;
            AMO_MIN:  amo_store_val = ($signed(amo_load_data) < $signed(fwd_rs2)) ? amo_load_data : fwd_rs2;
            AMO_MAX:  amo_store_val = ($signed(amo_load_data) > $signed(fwd_rs2)) ? amo_load_data : fwd_rs2;
            AMO_MINU: amo_store_val = (amo_load_data < fwd_rs2) ? amo_load_data : fwd_rs2;
            AMO_MAXU: amo_store_val = (amo_load_data > fwd_rs2) ? amo_load_data : fwd_rs2;
            default:  amo_store_val = fwd_rs2;
        endcase
    end

    // Dmem driver
    logic        dmem_stall;

    always_comb begin
        dmem_req_valid = 1'b0; dmem_req_write = 1'b0;
        dmem_req_addr  = 32'h0; dmem_req_wdata = 32'h0; dmem_req_wstrb = 4'h0;
        dmem_stall     = 1'b0;

        if (ex_wb_r.valid && !alu_stall) begin
            if (ex_wb_r.is_amo) begin
                case (amo_state)
                    AMO_IDLE: begin
                        if (ex_wb_r.amo_op == AMO_LR) begin
                            dmem_req_valid = 1'b1; dmem_req_addr = ex_wb_r.mem_addr;
                            if (!dmem_resp_valid) dmem_stall = 1'b1;
                        end else if (ex_wb_r.amo_op == AMO_SC) begin
                            // SC: check reservation
                            if (lr_valid && (lr_addr == ex_wb_r.mem_addr)) begin
                                dmem_req_valid = 1'b1; dmem_req_write = 1'b1;
                                dmem_req_addr = ex_wb_r.mem_addr;
                                dmem_req_wdata = ex_wb_r.store_data; dmem_req_wstrb = 4'hF;
                                if (!dmem_resp_valid) dmem_stall = 1'b1;
                            end
                            // SC fails: rd=1, no store needed
                        end else begin
                            dmem_req_valid = 1'b1; dmem_req_addr = ex_wb_r.mem_addr;
                            if (!dmem_resp_valid) dmem_stall = 1'b1;
                            else dmem_stall = 1'b1; // need STORE_WAIT
                        end
                    end
                    AMO_LOAD_WAIT: begin
                        if (dmem_resp_valid) begin
                            // issue store next
                            dmem_req_valid = 1'b1; dmem_req_write = 1'b1;
                            dmem_req_addr  = ex_wb_r.mem_addr;
                            dmem_req_wdata = amo_store_val; dmem_req_wstrb = 4'hF;
                            dmem_stall = 1'b1;
                        end else begin
                            dmem_req_valid = 1'b1; dmem_req_addr = ex_wb_r.mem_addr;
                            dmem_stall = 1'b1;
                        end
                    end
                    AMO_STORE_WAIT: begin
                        dmem_req_valid = 1'b1; dmem_req_write = 1'b1;
                        dmem_req_addr  = ex_wb_r.mem_addr;
                        dmem_req_wdata = amo_store_val; dmem_req_wstrb = 4'hF;
                        if (!dmem_resp_valid) dmem_stall = 1'b1;
                    end
                    default: ;
                endcase
            end else if (ex_wb_r.mem_read) begin
                dmem_req_valid = 1'b1; dmem_req_addr = ex_wb_r.mem_addr;
                if (!dmem_resp_valid) dmem_stall = 1'b1;
            end else if (ex_wb_r.mem_write) begin
                dmem_req_valid = 1'b1; dmem_req_write = 1'b1;
                dmem_req_addr  = ex_wb_r.mem_addr;
                dmem_req_wdata = ex_wb_r.store_data;
                dmem_req_wstrb = ex_wb_r.mem_op == MEM_BYTE ? (4'b0001 << ex_wb_r.mem_addr[1:0]) :
                                 ex_wb_r.mem_op == MEM_HALF ? (4'b0011 << {ex_wb_r.mem_addr[1],1'b0}) : 4'b1111;
                if (!dmem_resp_valid) dmem_stall = 1'b1;
            end
        end
    end

    // AMO state machine sequential
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            amo_state    <= AMO_IDLE;
            amo_load_data<= 32'h0;
            lr_valid     <= 1'b0;
            lr_addr      <= 32'h0;
        end else if (ex_wb_r.valid && ex_wb_r.is_amo) begin
            case (amo_state)
                AMO_IDLE: begin
                    if (ex_wb_r.amo_op == AMO_LR && dmem_resp_valid) begin
                        lr_valid <= 1'b1; lr_addr <= ex_wb_r.mem_addr;
                        amo_state <= AMO_IDLE; // done
                    end else if (ex_wb_r.amo_op == AMO_SC) begin
                        if (lr_valid && dmem_resp_valid) lr_valid <= 1'b0;
                        amo_state <= AMO_IDLE;
                    end else if (ex_wb_r.amo_op != AMO_LR && ex_wb_r.amo_op != AMO_SC) begin
                        if (dmem_resp_valid) begin
                            amo_load_data <= dmem_resp_data; amo_state <= AMO_STORE_WAIT;
                        end else amo_state <= AMO_LOAD_WAIT;
                    end
                end
                AMO_LOAD_WAIT: begin
                    if (dmem_resp_valid) begin amo_load_data <= dmem_resp_data; amo_state <= AMO_STORE_WAIT; end
                end
                AMO_STORE_WAIT: begin
                    if (dmem_resp_valid) amo_state <= AMO_IDLE;
                end
                default: amo_state <= AMO_IDLE;
            endcase
        end else if (!ex_wb_r.valid) amo_state <= AMO_IDLE;
    end

    // Multi-cycle ALU stall
    logic alu_stall;
    assign alu_stall = if_ex_r.valid && !alu_ready;

    // Operand stall: forwarding not yet available (load in WB not done)
    assign alu_operand_stall = load_use_stall;

    // =====================================================================
    // Hazard control
    // =====================================================================
    // ex_stall: stall EX stage (freeze EX/WB, freeze IF/EX, hold IF)
    assign ex_stall = dmem_stall || alu_stall;

    // if_stall: hold IF (do not advance PC or consume RVC output)
    assign if_stall = ex_stall || load_use_stall;

    // Flush IF stage when branch/jump/exception/interrupt redirect
    always_comb begin
        if_flush    = 1'b0;
        if_flush_pc = BOOT_ADDR;
        // WB redirects (exception, mret, interrupt take priority)
        if (ex_wb_r.valid && ex_wb_r.exception) begin
            if_flush    = 1'b1;
            if_flush_pc = mtvec_csr;
        end else if (ex_wb_r.valid && ex_wb_r.mret) begin
            if_flush    = 1'b1;
            // Tail-chain: if a CLIC IRQ is pending above threshold, redirect
            // directly to the next handler instead of returning to mepc.
            if_flush_pc = csr_tail_chain ? csr_tail_chain_pc : mepc_csr;
        end else if (csr_irq_pending) begin
            if_flush    = 1'b1;
            if_flush_pc = csr_irq_pc;
        end else if (redirect_ex && !ex_stall) begin
            if_flush    = 1'b1;
            if_flush_pc = redirect_pc_ex;
        end
    end

    // ex_flush: squash IF/EX content (branch resolved, inserting bubble)
    assign ex_flush = redirect_ex && !ex_stall;

    // RVC stall/flush
    // bp_redirect also flushes the RVC buffer to discard the instruction
    // speculatively fetched from PC+4 when a backward branch is predicted taken.
    assign rvc_stall    = if_stall;
    assign rvc_flush    = if_flush || bp_redirect;
    assign rvc_flush_pc = if_flush ? if_flush_pc : bp_redirect_pc;

    // Expose flush so jv32_top can suppress stale TCM SRAM responses
    assign imem_flush = rvc_flush;

    // =====================================================================
    // EX→WB Pipeline Register
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_wb_r <= '0;
        end else if (!ex_stall) begin
            if (load_use_stall || !if_ex_r.valid) begin
                // inject bubble
                ex_wb_r <= '0;
            end else begin
                ex_wb_r.valid       <= if_ex_r.valid;
                ex_wb_r.pc          <= if_ex_r.pc;
                ex_wb_r.orig_instr  <= if_ex_r.orig_instr;
                ex_wb_r.rd_addr     <= dec_rd;
                ex_wb_r.reg_we      <= dec_reg_we && !ex_exception;
                ex_wb_r.rd_data     <= ex_result;
                ex_wb_r.mem_read    <= dec_mem_read  && !ex_exception;
                ex_wb_r.mem_write   <= dec_mem_write && !ex_exception;
                ex_wb_r.mem_op      <= dec_mem_op;
                ex_wb_r.mem_addr    <= dec_is_amo ? fwd_rs1 : mem_addr_ex;
                ex_wb_r.store_data  <= store_data_aligned;
                ex_wb_r.is_amo      <= dec_is_amo   && !ex_exception;
                ex_wb_r.amo_op      <= dec_amo_op;
                ex_wb_r.csr_op      <= dec_csr_op;
                ex_wb_r.csr_addr    <= dec_csr_addr;
                ex_wb_r.csr_wdata   <= csr_wdata_ex;
                ex_wb_r.csr_zimm    <= dec_rs1;
                ex_wb_r.exception   <= ex_exception;
                ex_wb_r.exc_cause   <= ex_exc_cause;
                ex_wb_r.exc_tval    <= ex_exc_tval;
                ex_wb_r.mret        <= dec_is_mret;
                ex_wb_r.redirect    <= redirect_ex;
                ex_wb_r.redirect_pc <= redirect_pc_ex;
            end
        end
    end

    // =====================================================================
    // WB Stage: load data sign extension + register writeback
    // =====================================================================
    logic [31:0] load_result;
    logic  [7:0] load_byte;
    logic [15:0] load_half;
    assign load_byte = dmem_resp_data[8*ex_wb_r.mem_addr[1:0] +: 8];
    assign load_half = dmem_resp_data[16*ex_wb_r.mem_addr[1]  +: 16];
    always_comb begin
        case (ex_wb_r.mem_op)
            MEM_BYTE:   load_result = {{24{load_byte[7]}},  load_byte};
            MEM_HALF:   load_result = {{16{load_half[15]}}, load_half};
            MEM_BYTE_U: load_result = {24'd0, load_byte};
            MEM_HALF_U: load_result = {16'd0, load_half};
            default:    load_result = dmem_resp_data;
        endcase
    end

    // Register writeback
    always_comb begin
        rf_we    = 1'b0;
        rf_rd    = ex_wb_r.rd_addr;
        rf_wdata = ex_wb_r.rd_data;
        if (ex_wb_r.valid && ex_wb_r.reg_we) begin
            rf_we = 1'b1;
            if (ex_wb_r.mem_read) rf_wdata = load_result;
            else if (ex_wb_r.is_amo) begin
                if (ex_wb_r.amo_op == AMO_SC)
                    rf_wdata = (lr_valid && (lr_addr == ex_wb_r.mem_addr)) ? 32'd0 : 32'd1;
                else rf_wdata = load_result; // AMO returns old value
            end
        end
    end

    // =====================================================================
    // Trace output
    // =====================================================================
    assign trace_valid   = ex_wb_r.valid && !ex_wb_r.exception && !dmem_stall;
    assign trace_reg_we  = ex_wb_r.valid && ex_wb_r.reg_we
                           && (ex_wb_r.rd_addr != 5'd0)
                           && !ex_wb_r.exception && !dmem_stall;
    assign trace_pc      = ex_wb_r.pc;
    assign trace_rd      = ex_wb_r.rd_addr;
    assign trace_rd_data = rf_wdata;

    // Suppress unused warnings for WFI/fence/fence_i (treated as NOPs here)
    logic _unused;
    assign _unused = &{1'b0, dec_is_wfi, dec_is_fence, dec_is_fence_i,
                       ex_wb_r.csr_op, ex_wb_r.csr_addr, ex_wb_r.csr_wdata, ex_wb_r.csr_zimm,
                       ex_wb_r.redirect, ex_wb_r.redirect_pc};

`ifndef SYNTHESIS
    // =====================================================================
    // Debug trace (simulation only; guarded by DEBUG1 / DEBUG2 macros)
    // =====================================================================
    always_ff @(posedge clk) begin
        // FETCH: instruction latching into IF/EX stage
        if (!ex_stall && !ex_flush && !if_flush && rvc_instr_valid)
            `DEBUG2(`DBG_GRP_FETCH, ("IF  pc=0x%h instr=0x%h",
                rvc_instr_pc, rvc_instr_data));

        // CORE IF: pc_if advancement trace
        $display("[IFT] pc_if=%08x if_stall=%b bp_redir=%b if_flush=%b mr=%b rvc_valid=%b",
            pc_if, if_stall, bp_redirect, if_flush, rvc_mem_ready, rvc_instr_valid);

        // PIPE: pipeline flush events
        if (if_flush) begin
            if (ex_wb_r.valid && ex_wb_r.exception)
                `DEBUG1(("[FLUSH] Exception: cause=%0d pc=0x%h → mtvec=0x%h",
                    ex_wb_r.exc_cause, ex_wb_r.pc, if_flush_pc));
            else if (ex_wb_r.valid && ex_wb_r.mret)
                `DEBUG1(("[FLUSH] MRET → 0x%h%s", if_flush_pc,
                    csr_tail_chain ? " [tail-chain]" : ""));
            else if (csr_irq_pending)
                `DEBUG1(("[FLUSH] IRQ → 0x%h cause=0x%h",
                    if_flush_pc, csr_irq_cause));
            else
                `DEBUG2(`DBG_GRP_EX, ("REDIRECT → 0x%h (bp_mispred from pc=0x%h bp_taken=%b)",
                    if_flush_pc, if_ex_r.pc, if_ex_r.bp_taken));
        end

        // MEM: data memory request issued (completed, not stalling)
        if (dmem_req_valid && !dmem_stall)
            `DEBUG2(`DBG_GRP_MEM, ("%s @ 0x%h data=0x%h strb=%04b",
                dmem_req_write ? "STORE" : "LOAD ",
                dmem_req_addr, dmem_req_wdata, dmem_req_wstrb));

        // PIPE: instruction retired (WB stage)
        if (trace_valid)
            `DEBUG2(`DBG_GRP_PIPE, ("WB  pc=0x%h rd=x%-2d data=0x%h",
                trace_pc, trace_rd, trace_rd_data));
    end
`endif

endmodule
