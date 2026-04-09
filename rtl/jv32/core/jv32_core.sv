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
    parameter bit          FAST_MUL   = 1'b1,
    parameter bit          FAST_DIV   = 1'b1,
    parameter bit          FAST_SHIFT = 1'b1,
    parameter bit          BP_EN      = 1'b1,
    parameter logic [31:0] BOOT_ADDR  = 32'h8000_0000
) (
    input  logic        clk,
    input  logic        rst_n,

    // Instruction memory request/response
    output logic        imem_req_valid,
    output logic [31:0] imem_req_addr,
    input  logic        imem_resp_valid,
    input  logic [31:0] imem_resp_data,
    input  logic [31:0] imem_resp_pc,
    input  logic        imem_resp_fault,      // AXI DECERR on I-fetch
    input  logic [31:0] imem_resp_fault_pc,   // exact request PC for the faulting fetch

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
    output logic [31:0] trace_rd_data,
    output logic [31:0] trace_instr,
    output logic        trace_mem_we,
    output logic        trace_mem_re,
    output logic [31:0] trace_mem_addr,
    output logic [31:0] trace_mem_data
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
        // A faulting I-fetch response must not be decompressed/consumed as a
        // real instruction; the IF/EX fault slot is injected separately below.
        .imem_resp_valid  (imem_resp_valid && !imem_resp_fault),
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
    // irq_cancel declared here (defined in Trace output section below)
    logic        irq_cancel;

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
        .irq_mepc         (ex_wb_r.pc),
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
        .instret_inc      (trace_valid)
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
            end else if (imem_resp_fault) begin
                // Preserve the original request PC for an instruction-access fault
                // without letting the RVC path consume/advance the bad fetch word.
                if_ex_r.valid         <= 1'b1;
                if_ex_r.pc            <= imem_resp_fault_pc;
                if_ex_r.instr         <= 32'h0000_0013;
                if_ex_r.orig_instr    <= 32'h0000_0000;
                if_ex_r.is_compressed <= imem_resp_fault_pc[1];
                if_ex_r.bp_taken      <= 1'b0;
                if_ex_r.ifetch_fault  <= 1'b1;
            end else if (rvc_instr_valid) begin
                if_ex_r.valid         <= 1'b1;
                if_ex_r.pc            <= rvc_instr_pc;
                if_ex_r.instr         <= rvc_instr_data;
                if_ex_r.orig_instr    <= rvc_orig_instr;
                if_ex_r.is_compressed <= rvc_is_compressed;
                if_ex_r.bp_taken      <= bp_redirect;     // BTFNT: record prediction
                if_ex_r.ifetch_fault  <= 1'b0;
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
        // AMO checked first: decoder sets mem_read=1 for AMO too,
        // but the writeback result is the old (pre-operation) loaded value.
        if (ex_wb_r.is_amo)
            wb_rd_data = (ex_wb_r.amo_op == AMO_SC) ?
                         ((lr_valid && (lr_addr == ex_wb_r.mem_addr)) ? 32'd0 : 32'd1) :
                         (ex_wb_r.amo_op == AMO_LR) ? load_result :  // LR returns loaded value
                         amo_load_data; // AMO forwards old memory value
        else if (ex_wb_r.mem_read)
            wb_rd_data = load_result; // sign/zero-extended byte/half/word load result
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
            MEM_HALF:   wstrb_ex = 4'b0011 << mem_addr_ex[1:0];
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
            if (if_ex_r.ifetch_fault) begin
                // AXI DECERR on I-fetch raises EXC_INSTR_ACCESS_FAULT (cause=1).
                // Checked before dec_illegal since the instruction data is meaningless.
                // `mepc` already records the faulting PC; ACT4 expects `mtval=0` here.
                ex_exception = 1'b1;
                ex_exc_cause = EXC_INSTR_ACCESS_FAULT;
                ex_exc_tval  = 32'h0;
            end else if (dec_illegal) begin
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
            end
            // Misaligned loads/stores are handled transparently by the MSA state
            // machine in WB — no exception raised here.
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

    // Misaligned-access (MSA) state machine
    // MSA_IDLE     : no misalign operation in progress
    // MSA_HIGH_WAIT: first (low) word done, second (high) word request in flight
    typedef enum logic {MSA_IDLE, MSA_HIGH_WAIT} msa_state_e;
    msa_state_e  msa_state;
    logic [31:0] msa_lo_data;    // first word captured for cross-word load

    // Misalign detection (evaluated in WB stage using ex_wb_r)
    logic msa_detect;   // any misaligned load/store
    logic msa_within;   // halfword at byte offset 1: within one aligned word
    logic msa_cross;    // access spans two aligned words: needs 2 accesses
    assign msa_detect = !ex_wb_r.exception && !ex_wb_r.is_amo &&
                        ((ex_wb_r.mem_read || ex_wb_r.mem_write)) &&
                        (((ex_wb_r.mem_op == MEM_HALF || ex_wb_r.mem_op == MEM_HALF_U) && ex_wb_r.mem_addr[0]) ||
                         (ex_wb_r.mem_op == MEM_WORD && ex_wb_r.mem_addr[1:0] != 2'b00));
    assign msa_within = msa_detect &&
                        ((ex_wb_r.mem_op == MEM_HALF || ex_wb_r.mem_op == MEM_HALF_U) && ex_wb_r.mem_addr[1:0] == 2'b01);
    assign msa_cross  = msa_detect && !msa_within;

    // Precomputed shift amounts and wstrb masks for cross-word accesses
    logic [5:0]  msa_lo_shift;   // byte-offset * 8: 0, 8, 16, 24
    logic [5:0]  msa_hi_shift;   // complement: 32, 24, 16, 8
    logic [3:0]  msa_base_wstrb; // 4'b0011 for HALF, 4'b1111 for WORD
    logic [3:0]  msa_lo_wstrb;   // wstrb for low aligned word
    logic [3:0]  msa_hi_wstrb;   // wstrb for high aligned word
    logic [31:0] msa_lo_wdata;   // write data for low word  (cross-word store)
    logic [31:0] msa_hi_wdata;   // write data for high word (cross-word store)
    assign msa_lo_shift    = {1'b0, ex_wb_r.mem_addr[1:0], 3'b0};
    assign msa_hi_shift    = 6'd32 - msa_lo_shift;
    assign msa_base_wstrb  = ((ex_wb_r.mem_op == MEM_HALF) || (ex_wb_r.mem_op == MEM_HALF_U)) ? 4'b0011 : 4'b1111;
    assign msa_lo_wstrb    = msa_base_wstrb << ex_wb_r.mem_addr[1:0];
    assign msa_hi_wstrb    = msa_base_wstrb >> (3'd4 - {1'b0, ex_wb_r.mem_addr[1:0]});
    assign msa_lo_wdata    = ex_wb_r.store_data << msa_lo_shift[4:0];
    assign msa_hi_wdata    = ex_wb_r.store_data >> msa_hi_shift[4:0];

    always_comb begin
        case (ex_wb_r.amo_op)
            AMO_SWAP: amo_store_val = ex_wb_r.store_data;
            AMO_ADD:  amo_store_val = amo_load_data + ex_wb_r.store_data;
            AMO_XOR:  amo_store_val = amo_load_data ^ ex_wb_r.store_data;
            AMO_AND:  amo_store_val = amo_load_data & ex_wb_r.store_data;
            AMO_OR:   amo_store_val = amo_load_data | ex_wb_r.store_data;
            AMO_MIN:  amo_store_val = ($signed(amo_load_data) < $signed(ex_wb_r.store_data)) ? amo_load_data : ex_wb_r.store_data;
            AMO_MAX:  amo_store_val = ($signed(amo_load_data) > $signed(ex_wb_r.store_data)) ? amo_load_data : ex_wb_r.store_data;
            AMO_MINU: amo_store_val = (amo_load_data < ex_wb_r.store_data) ? amo_load_data : ex_wb_r.store_data;
            AMO_MAXU: amo_store_val = (amo_load_data > ex_wb_r.store_data) ? amo_load_data : ex_wb_r.store_data;
            default:  amo_store_val = ex_wb_r.store_data;
        endcase
    end

    // Dmem driver
    logic        dmem_stall;

    always_comb begin
        dmem_req_valid = 1'b0; dmem_req_write = 1'b0;
        dmem_req_addr  = 32'h0; dmem_req_wdata = 32'h0; dmem_req_wstrb = 4'h0;
        dmem_stall     = 1'b0;

        if (ex_wb_r.valid && !alu_stall && !irq_cancel) begin
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
            end else if (msa_cross) begin
                // -------------------------------------------------------
                // Cross-word misaligned access: two AXI transactions
                // MSA_IDLE:      issue first (low) request, always stall
                // MSA_HIGH_WAIT: issue second (high) request, stall until done
                // -------------------------------------------------------
                case (msa_state)
                    MSA_IDLE: begin
                        dmem_req_valid = 1'b1;
                        dmem_req_addr  = {ex_wb_r.mem_addr[31:2], 2'b00};
                        if (ex_wb_r.mem_write) begin
                            dmem_req_write = 1'b1;
                            dmem_req_wdata = msa_lo_wdata;
                            dmem_req_wstrb = msa_lo_wstrb;
                        end
                        dmem_stall = 1'b1;   // always stall: transition to HIGH_WAIT
                    end
                    MSA_HIGH_WAIT: begin
                        dmem_req_valid = 1'b1;
                        dmem_req_addr  = {ex_wb_r.mem_addr[31:2] + 30'd1, 2'b00};
                        if (ex_wb_r.mem_write) begin
                            dmem_req_write = 1'b1;
                            dmem_req_wdata = msa_hi_wdata;
                            dmem_req_wstrb = msa_hi_wstrb;
                        end
                        if (!dmem_resp_valid) dmem_stall = 1'b1;
                        // resp_valid: stall clears, instruction completes
                    end
                    default: ;
                endcase
            end else if (msa_within) begin
                // -------------------------------------------------------
                // Within-word misaligned halfword (A[1:0]=01):
                // Single read/write to the containing aligned word.
                // For stores: shift data so low byte lands at byte 1, high at byte 2.
                // -------------------------------------------------------
                dmem_req_valid = 1'b1;
                dmem_req_addr  = {ex_wb_r.mem_addr[31:2], 2'b00};
                if (ex_wb_r.mem_write) begin
                    dmem_req_write = 1'b1;
                    dmem_req_wdata = msa_lo_wdata;  // store_data << 8: [lo,hi] at bytes [1,2]
                    dmem_req_wstrb = 4'b0110;        // bytes 1 & 2
                end
                if (!dmem_resp_valid) dmem_stall = 1'b1;
            end else if (ex_wb_r.mem_read) begin
                dmem_req_valid = 1'b1; dmem_req_addr = ex_wb_r.mem_addr;
                if (!dmem_resp_valid) dmem_stall = 1'b1;
            end else if (ex_wb_r.mem_write) begin
                dmem_req_valid = 1'b1; dmem_req_write = 1'b1;
                dmem_req_addr  = ex_wb_r.mem_addr;
                dmem_req_wdata = ex_wb_r.store_data;
                dmem_req_wstrb = ex_wb_r.mem_op == MEM_BYTE ? (4'b0001 << ex_wb_r.mem_addr[1:0]) :
                                 ex_wb_r.mem_op == MEM_HALF ? (4'b0011 << ex_wb_r.mem_addr[1:0]) : 4'b1111;
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
        end else if (ex_wb_r.valid && ex_wb_r.is_amo) begin            case (amo_state)
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

    // MSA state machine sequential
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msa_state   <= MSA_IDLE;
            msa_lo_data <= 32'h0;
        end else if (ex_wb_r.valid) begin
            case (msa_state)
                MSA_IDLE: begin
                    if (msa_cross && dmem_resp_valid) begin
                        msa_lo_data <= dmem_resp_data;  // save first word
                        msa_state   <= MSA_HIGH_WAIT;
                    end
                end
                MSA_HIGH_WAIT: begin
                    if (dmem_resp_valid)
                        msa_state <= MSA_IDLE;
                end
                default: msa_state <= MSA_IDLE;
            endcase
        end else begin
            msa_state <= MSA_IDLE;
        end
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
        end else if (csr_irq_pending && ex_wb_r.valid) begin
            if_flush    = 1'b1;
            if_flush_pc = csr_irq_pc;
        end else if (redirect_ex && !ex_stall) begin
            if_flush    = 1'b1;
            if_flush_pc = redirect_pc_ex;
        end
    end

    // ex_flush: squash IF/EX content (branch resolved, inserting bubble)
    assign ex_flush = redirect_ex && !ex_stall;

    // wb_redirect: WB stage is redirecting the PC (exception/mret/irq).
    // When this fires, the instruction currently in IF/EX must be squashed
    // (not promoted to EX/WB), because it's on the wrong control-flow path.
    logic wb_redirect;
    assign wb_redirect = ex_wb_r.valid && (ex_wb_r.exception || ex_wb_r.mret
                                           || (csr_irq_pending && !ex_wb_r.exception && !ex_wb_r.mret));

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
            if (load_use_stall || !if_ex_r.valid || wb_redirect) begin
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
    // Combined 64-bit window for cross-word loads: {hi_word, lo_word}
    // Shifted by byte offset to extract the misaligned value.
    logic [63:0] msa_window;
    logic [31:0] load_result;
    logic  [7:0] load_byte;
    logic [15:0] load_half;
    assign msa_window = {dmem_resp_data, msa_lo_data};
    // load_byte: always within one word (byte accesses are always aligned)
    assign load_byte = dmem_resp_data[8*ex_wb_r.mem_addr[1:0] +: 8];
    // load_half:
    //   - aligned/within-word (A[1:0]=00,01,10): extract from single word
    //   - cross-word (A[1:0]=11, MSA_HIGH_WAIT): combine lo_word[31:24] + hi_word[7:0]
    assign load_half = (msa_state == MSA_HIGH_WAIT) ?
                       {dmem_resp_data[7:0], msa_lo_data[31:24]} :
                       dmem_resp_data[8*ex_wb_r.mem_addr[1:0] +: 16];
    always_comb begin
        case (ex_wb_r.mem_op)
            MEM_BYTE:   load_result = {{24{load_byte[7]}},  load_byte};
            MEM_HALF:   load_result = {{16{load_half[15]}}, load_half};
            MEM_BYTE_U: load_result = {24'd0, load_byte};
            MEM_HALF_U: load_result = {16'd0, load_half};
            default: begin
                // Word: cross-word case uses msa_window; aligned uses dmem_resp_data
                if (msa_state == MSA_HIGH_WAIT)
                    load_result = msa_window[msa_lo_shift +: 32];
                else
                    load_result = dmem_resp_data;
            end
        endcase
    end

    // Register writeback
    always_comb begin
        rf_we    = 1'b0;
        rf_rd    = ex_wb_r.rd_addr;
        rf_wdata = ex_wb_r.rd_data;
        if (ex_wb_r.valid && ex_wb_r.reg_we && !irq_cancel) begin
            rf_we = 1'b1;
            // AMO checked first: decoder sets mem_read=1 for AMO too.
            if (ex_wb_r.is_amo) begin
                if (ex_wb_r.amo_op == AMO_SC)
                    rf_wdata = (lr_valid && (lr_addr == ex_wb_r.mem_addr)) ? 32'd0 : 32'd1;
                else if (ex_wb_r.amo_op == AMO_LR)
                    rf_wdata = load_result; // LR returns loaded value (amo_load_data never set for LR)
                else rf_wdata = amo_load_data; // AMO returns old (pre-operation) value
            end else if (ex_wb_r.mem_read) begin
                rf_wdata = load_result;
            end
        end
    end

    // =====================================================================
    // Trace output
    // =====================================================================
    // irq_cancel: instruction in WB is canceled by a pending interrupt.
    // The interrupt is serviced instead; the WB instruction is NOT retired
    // (no register write, no trace) but its PC is saved as mepc so that
    // it re-executes after mret — matching software-simulator behaviour.
    assign irq_cancel = csr_irq_pending && ex_wb_r.valid && !ex_wb_r.exception && !ex_wb_r.mret;

    assign trace_valid    = ex_wb_r.valid && !ex_wb_r.exception && !dmem_stall && !irq_cancel;
    assign trace_reg_we   = ex_wb_r.valid && ex_wb_r.reg_we
                            && (ex_wb_r.rd_addr != 5'd0)
                            && !ex_wb_r.exception && !dmem_stall && !irq_cancel;
    assign trace_pc       = ex_wb_r.pc;
    assign trace_rd       = ex_wb_r.rd_addr;
    assign trace_rd_data  = rf_wdata;
    assign trace_instr    = ex_wb_r.orig_instr;
    assign trace_mem_we   = ex_wb_r.valid && ex_wb_r.mem_write
                            && !ex_wb_r.exception && !dmem_stall && !irq_cancel;
    assign trace_mem_re   = ex_wb_r.valid && ex_wb_r.mem_read
                            && !ex_wb_r.exception && !dmem_stall && !irq_cancel;
    assign trace_mem_addr = ex_wb_r.mem_addr;
    assign trace_mem_data = ex_wb_r.mem_op == MEM_BYTE ? {24'h0, ex_wb_r.store_data[7:0]} :
                            ex_wb_r.mem_op == MEM_HALF ? {16'h0, ex_wb_r.store_data[15:0]} :
                                                         ex_wb_r.store_data;

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
        `DEBUG2(`DBG_GRP_FETCH, ("[IFT] pc_if=%08x if_stall=%b bp_redir=%b if_flush=%b mr=%b rvc_valid=%b",
            pc_if, if_stall, bp_redirect, if_flush, rvc_mem_ready, rvc_instr_valid));

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
