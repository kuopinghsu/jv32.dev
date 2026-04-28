// ============================================================================
// File: jv32_core.sv
// Project: JV32 RISC-V Processor
// Description: RV32IMAC 3-Stage Pipeline Core (IF -> EX -> WB)
//
// Pipeline stages:
//   IF  : PC + instruction fetch request (via jv32_rvc)
//   EX  : decode, register read, ALU, address calc, CSR, hazard detect
//   WB  : memory result, writeback, redirect, exception
//
// Hazards:
//   - Load-use : 1-cycle stall (EX->WB stall + IF hold)
//   - Branch/jump : 1-cycle flush on misprediction (EX squashes IF)
//   - Multi-cycle ALU (mul/div/shift) : stall entire pipeline
//   - AMO : IDLE -> LOAD_WAIT -> STORE_WAIT state machine
//
// Forwarding: WB->EX same-cycle forwarding (register data available in WB)
// ============================================================================

module jv32_core #(
    parameter bit                 RV32E_EN   = 1'b0,  // 1=RV32E (16 GPRs); 0=RV32I (32 GPRs)
    parameter bit                 RV32M_EN   = 1'b1,  // 1=M-extension; 0=illegal for MUL/DIV
    parameter bit                 TRACE_EN   = 1'b1,  // 1=trace outputs active; 0=tied to 0
    parameter bit                 FAST_MUL   = 1'b1,
    parameter bit                 MUL_MC     = 1'b1,
    parameter bit                 FAST_DIV   = 1'b0,
    parameter bit                 FAST_SHIFT = 1'b1,
    parameter bit                 BP_EN      = 1'b1,
    parameter bit                 RAS_EN     = 1'b1,  // 1=Return Address Stack enabled; 0=JALR always 1-cycle
    parameter bit                 AMO_EN     = 1'b1,  // 1=full A-extension; 0=AMO decode as illegal
    parameter bit                 RV32B_EN   = 1'b1,  // 1=Zba/Zbb/Zbs; 0=illegal (synthesized away)
    parameter int                 N_TRIGGERS = 2,     // number of hardware breakpoints (0..4)
    parameter bit          [31:0] BOOT_ADDR  = 32'h8000_0000,
    parameter bit          [31:0] IRAM_BASE  = 32'h8000_0000,
    parameter int unsigned        IRAM_SIZE  = 128 * 1024,
    parameter bit          [31:0] DRAM_BASE  = 32'hC000_0000,
    parameter int unsigned        DRAM_SIZE  = 128 * 1024
) (
    input logic clk,
    input logic rst_n,

    // Instruction memory request/response
    output logic        imem_req_valid,
    output logic [31:0] imem_req_addr,
    input  logic        imem_resp_valid,
    input  logic [31:0] imem_resp_data,
    input  logic [31:0] imem_resp_pc,
    input  logic        imem_resp_fault,     // AXI DECERR on I-fetch
    input  logic [31:0] imem_resp_fault_pc,  // exact request PC for the faulting fetch

    // Data memory request/response
    output logic        dmem_req_valid,
    output logic        dmem_req_write,
    output logic [31:0] dmem_req_addr,
    output logic [31:0] dmem_req_wdata,
    output logic [ 3:0] dmem_req_wstrb,
    input  logic        dmem_resp_valid,
    input  logic [31:0] dmem_resp_data,
    input  logic        dmem_resp_fault,  // AXI DECERR on data load/store response

    // Interrupts
    input  logic       timer_irq,
    input  logic       external_irq,
    input  logic       software_irq,
    // CLIC sideband
    input  logic       clic_irq,
    input  logic [7:0] clic_level,
    input  logic [7:0] clic_prio,
    input  logic [4:0] clic_id,       // winning IRQ index for mtvt table
    output logic       clic_ack,

    // External debug interface (JTAG DM)
    input  logic                        halt_req_i,
    output logic                        halted_o,
    input  logic                        resume_req_i,
    output logic                        resumeack_o,
    input  logic [           4:0]       dbg_reg_addr_i,
    input  logic [          31:0]       dbg_reg_wdata_i,
    input  logic                        dbg_reg_we_i,
    output logic [          31:0]       dbg_reg_rdata_o,
    input  logic [          31:0]       dbg_pc_wdata_i,
    input  logic                        dbg_pc_we_i,
    output logic [          31:0]       dbg_pc_o,
    input  logic                        dbg_singlestep_i,
    input  logic                        dbg_ebreakm_i,
    // Trigger interface (Debug Spec 0.13 Sec.5.2 Trigger Module)
    output logic                        trigger_halt_o,  // trigger caused current halt
    output logic [N_TRIGGERS-1:0]       trigger_hit_o,   // per-trigger: which trigger(s) fired
    input  logic [N_TRIGGERS-1:0][31:0] tdata1_i,        // mcontrol config per trigger
    input  logic [N_TRIGGERS-1:0][31:0] tdata2_i,        // match address per trigger

    // I-fetch flush: asserted on branch/jump/exception/mret/IRQ redirect.
    // Allows jv32_top to suppress the stale TCM response arriving one cycle later.
    output logic imem_flush,
    // FENCE.I-specific flush: only for fence.i redirects.  jv32_top uses this
    // to suppress the 1-cycle stale TCM response that arrives after a fence.i
    // redirect WITHOUT adding a bubble to every other branch/jump redirect.
    output logic fencei_iflush,

    // Trace (one entry per retired instruction)
    // trace_en=0 suppresses all trace outputs to save power.
    input  logic        trace_en,
    output logic        trace_valid,
    output logic        trace_reg_we,
    output logic [31:0] trace_pc,
    output logic [ 4:0] trace_rd,
    output logic [31:0] trace_rd_data,
    output logic [31:0] trace_instr,
    output logic        trace_mem_we,
    output logic        trace_mem_re,
    output logic [31:0] trace_mem_addr,
    output logic [31:0] trace_mem_data,
    // IRQ-taken hint: fires for one cycle when an interrupt is accepted
    output logic        trace_irq_taken,
    output logic [31:0] trace_irq_cause,
    output logic [31:0] trace_irq_epc,
    // Squashed-store hint: fires together with trace_irq_taken when the
    // interrupted instruction was a store that had already committed its
    // memory write in the pipeline (irq fired during 2nd WB cycle).
    output logic        trace_irq_store_we,
    output logic [31:0] trace_irq_store_addr,
    output logic [31:0] trace_irq_store_data,

    // Branch predictor performance counters (valid only when BP_EN=1; tied to 0 otherwise)
    output logic perf_bp_branch,    // 1 conditional branch retired this cycle
    output logic perf_bp_taken,     // 1 branch was actually taken
    output logic perf_bp_mispred,   // 1 branch misprediction (EX redirect)
    output logic perf_bp_jal,       // 1 JAL retired this cycle
    output logic perf_bp_jal_miss,  // 1 JAL not pre-decoded (caused EX redirect)
    output logic perf_bp_jalr,      // 1 JALR retired (always causes EX redirect)

    // D-preload active during WB DRAM response cycle (consecutive loads; used by jv32_top tracking)
    output logic d_preload_active,

    // mtime from platform timer (for time/timeh CSR)
    input logic [63:0] mtime_i
);
    import jv32_pkg::*;

    localparam logic [31:0] DEBUG_ROM_BASE = 32'h0F80_0000;

    // RV32B_EN=1 only valid when not RV32E. Enforced here so child modules
    // see a single clean parameter without needing to know about RV32E_EN.
    localparam bit ZB_ACTIVE = RV32B_EN && !RV32E_EN;

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

    jv32_rvc #(
        .RVM23_EN(1'b1)
    ) u_rvc (
        .clk            (clk),
        .rst_n          (rst_n),
        // A faulting I-fetch response must not be decompressed/consumed as a
        // real instruction; the IF/EX fault slot is injected separately below.
        .imem_resp_valid(imem_resp_valid && !imem_resp_fault),
        .imem_resp_data (imem_resp_data),
        .imem_resp_pc   (imem_resp_pc),
        .stall          (rvc_stall),
        .flush          (rvc_flush),
        .flush_pc       (rvc_flush_pc),
        .instr_valid    (rvc_instr_valid),
        .instr_data     (rvc_instr_data),
        .orig_instr     (rvc_orig_instr),
        .instr_pc       (rvc_instr_pc),
        .is_compressed  (rvc_is_compressed),
        .mem_ready      (rvc_mem_ready)
    );

    // =====================================================================
    // Regfile
    // =====================================================================
    logic [4:0] rs1_addr_d, rs2_addr_d;
    logic [31:0] rs1_data, rs2_data;
    logic                  rf_we;
    logic [           4:0] rf_rd;
    logic [          31:0] rf_wdata;

    // Debug / halt control
    logic                  dbg_halted_r;
    logic                  dbg_resumeack_r;
    logic                  dbg_step_pending_r;
    logic                  dbg_step_served_r;  // Prevents re-resume after single-step halt
    logic                  dbg_enter_debug;
    logic                  trigger_match;
    logic                  trigger_halt_r;     // trigger module caused current halt (dcsr.cause=2)
    logic [N_TRIGGERS-1:0] trigger_hit_r;      // which trigger(s) caused the halt
    assign trigger_halt_o = trigger_halt_r;
    assign trigger_hit_o  = trigger_hit_r;

    jv32_regfile #(
        .RV32E_EN(RV32E_EN)
    ) u_regfile (
        .clk      (clk),
        .rst_n    (rst_n),
        .rs1_addr (rs1_addr_d),
        .rs2_addr (rs2_addr_d),
        .rs1_data (rs1_data),
        .rs2_data (rs2_data),
        .we       (rf_we),
        .rd_addr  (rf_rd),
        .rd_data  (rf_wdata),
        .dbg_addr (dbg_reg_addr_i),
        .dbg_we   (dbg_reg_we_i && dbg_halted_r),
        .dbg_wdata(dbg_reg_wdata_i),
        .dbg_rdata(dbg_reg_rdata_o)
    );

    // =====================================================================
    // ALU
    // =====================================================================
    alu_op_e alu_op_d;
    logic [31:0] alu_op_a, alu_op_b;
    logic        alu_operand_stall;
    logic        alu_result_hold;
    logic [31:0] alu_result;
    logic        alu_ready;

    // Forward-declared helpers used by earlier combinational blocks.
    logic [31:0] amo_load_data;
    logic        lr_valid;
    logic [31:0] lr_addr;
    logic [31:0] load_result;
    logic        alu_stall;

    jv32_alu #(
        .RV32M_EN  (RV32M_EN),
        .FAST_MUL  (FAST_MUL),
        .MUL_MC    (MUL_MC),
        .FAST_DIV  (FAST_DIV),
        .FAST_SHIFT(FAST_SHIFT),
        .RV32B_EN  (ZB_ACTIVE)
    ) u_alu (
        .clk          (clk),
        .rst_n        (rst_n),
        .alu_op       (alu_op_d),
        .operand_a    (alu_op_a),
        .operand_b    (alu_op_b),
        .operand_stall(alu_operand_stall),
        .result_hold  (alu_result_hold),
        .result       (alu_result),
        .ready        (alu_ready)
    );

    // =====================================================================
    // Decoder
    // =====================================================================
    // Decoder wires driven from IF/EX pipeline register
    if_ex_t if_ex_r;

    logic [4:0] dec_rs1, dec_rs2, dec_rd;
    logic    [31:0] dec_imm;
    alu_op_e        dec_alu_op;
    logic           dec_alu_src;
    logic           dec_reg_we;
    logic dec_mem_read, dec_mem_write;
    mem_size_e  dec_mem_op;
    logic       dec_branch;
    branch_op_e dec_branch_op;
    logic dec_jal, dec_jalr;
    logic dec_lui, dec_auipc;
    logic        dec_illegal;
    logic [ 2:0] dec_csr_op;
    logic [11:0] dec_csr_addr;
    logic dec_is_mret, dec_is_ecall, dec_is_ebreak;
    logic    dec_is_amo;
    amo_op_e dec_amo_op;
    logic dec_is_fence, dec_is_fence_i;
    logic dec_is_wfi;

    jv32_decoder #(
        .AMO_EN  (AMO_EN),
        .RV32E_EN(RV32E_EN),
        .RV32M_EN(RV32M_EN),
        .RV32B_EN(ZB_ACTIVE)
    ) u_decoder (
        .instr     (if_ex_r.instr),
        .valid     (if_ex_r.valid),
        .rs1_addr  (dec_rs1),
        .rs2_addr  (dec_rs2),
        .rd_addr   (dec_rd),
        .imm       (dec_imm),
        .alu_op    (dec_alu_op),
        .alu_src   (dec_alu_src),
        .reg_we    (dec_reg_we),
        .mem_read  (dec_mem_read),
        .mem_write (dec_mem_write),
        .mem_op    (dec_mem_op),
        .branch    (dec_branch),
        .branch_op (dec_branch_op),
        .jal       (dec_jal),
        .jalr      (dec_jalr),
        .lui       (dec_lui),
        .auipc     (dec_auipc),
        .illegal   (dec_illegal),
        .csr_op    (dec_csr_op),
        .csr_addr  (dec_csr_addr),
        .is_mret   (dec_is_mret),
        .is_ecall  (dec_is_ecall),
        .is_ebreak (dec_is_ebreak),
        .is_amo    (dec_is_amo),
        .amo_op    (dec_amo_op),
        .is_fence  (dec_is_fence),
        .is_fence_i(dec_is_fence_i),
        .is_wfi    (dec_is_wfi)
    );

    // =====================================================================
    // CSR
    // =====================================================================
    logic       [31:0] csr_rdata;
    logic       [31:0] mtvec_csr;
    logic       [31:0] mepc_csr;
    logic              csr_irq_pending;
    logic       [31:0] csr_irq_cause;
    logic       [31:0] csr_irq_pc;
    logic              csr_tail_chain;
    logic       [31:0] csr_tail_chain_pc;
    logic              wb_exception;
    exc_cause_e        wb_exc_cause;
    logic       [31:0] wb_exc_tval;

    // Forward declarations - defined/driven in the Trace output section below
    logic              irq_cancel;
    logic              trace_valid_r;
    logic              wb_retire;
    logic              wb_redirect;

    // Forward declarations - defined in the IF stage section below
    logic              if_stall;
    logic              bp_redirect;
    logic       [31:0] bp_redirect_pc;
    logic              bp_l0_valid;
    logic       [31:0] bp_l0_pc;
    logic       [31:0] bp_l0_target;
    logic              bp_l0_taken;

    // RAS (Return Address Stack) forward declarations
    logic              bp_ras_push;
    logic              bp_ras_pop;
    logic       [31:0] bp_ras_top;

    // Forward declarations - defined in the D-mem / WB section below
    logic              dmem_resp_valid_rd;
    logic              dmem_stall;

    // EX->WB pipeline register
    ex_wb_t            ex_wb_r;

    jv32_csr #(
        .RV32E_EN(RV32E_EN),
        .RV32M_EN(RV32M_EN),
        .AMO_EN  (AMO_EN)
    ) u_csr (
        .clk     (clk),
        .rst_n   (rst_n),
        .csr_addr(dec_csr_addr),

        // Gate csr_op so CSR writes don't fire while the pipeline is stalled.
        // When if_stall=1 (WB instruction waiting on memory), the EX instruction
        // (if_ex_r) is frozen but the decoder still drives csr_op != 0 for any
        // CSR instruction. Without gating, csr_we fires prematurely, writing
        // mstatus_mie before the store in WB has retired.  This creates a race
        // where an incoming interrupt (e.g. MSIP from the just-issued store) sees
        // mstatus_mie=1 and takes the interrupt with mepc pointing to the store
        // rather than to the first instruction after the CSR write.
        .csr_op         (if_stall ? 3'b000 : dec_csr_op),
        .csr_wdata      (alu_op_a),  // forwarded rs1
        .csr_zimm       (dec_rs1),   // zimm from rs1 field
        .csr_rdata      (csr_rdata),
        .exception      (wb_exception),
        .exception_cause(wb_exc_cause),
        .exception_pc   (ex_wb_r.pc),
        .exception_tval (wb_exc_tval),
        .mret           (ex_wb_r.mret && wb_retire),
        .wb_valid       (wb_retire),
        .irq_mepc       (ex_wb_r.pc),
        .mtvec_o        (mtvec_csr),
        .mepc_o         (mepc_csr),
        .timer_irq      (timer_irq),
        .external_irq   (external_irq),
        .software_irq   (software_irq),
        .clic_irq       (clic_irq),
        .clic_level     (clic_level),
        .clic_prio      (clic_prio),
        .clic_id        (clic_id),
        .clic_ack       (clic_ack),
        .tail_chain_o   (csr_tail_chain),
        .tail_chain_pc_o(csr_tail_chain_pc),
        .irq_pending    (csr_irq_pending),
        .irq_cause      (csr_irq_cause),
        .irq_pc         (csr_irq_pc),
        .instret_inc    (trace_valid_r),
        .mtime_i        (mtime_i)
    );

    // =====================================================================
    // IF Stage
    // =====================================================================
    logic [31:0] pc_if;
    logic        if_flush;
    logic [31:0] if_flush_pc;

    assign halted_o    = dbg_halted_r;
    assign resumeack_o = dbg_resumeack_r;

    // Capture the PC of the instruction that caused the current debug halt.
    // This register latches if_ex_r.pc (EX-stage instruction) on any halt entry:
    // dbg_enter_debug (EBREAK), trigger_match, or halt_req.  It ensures the
    // reported DPC reflects the actual halted instruction even after the pipeline
    // is flushed and pc_if has advanced further.
    logic [31:0] dbg_halt_pc_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) dbg_halt_pc_r <= BOOT_ADDR;
        else if (dbg_pc_we_i) dbg_halt_pc_r <= dbg_pc_wdata_i;  // PC write from debugger
        else if (dbg_step_pending_r && trace_valid_r)
            // For single-step, DPC must point to the next instruction.
            dbg_halt_pc_r <= ex_wb_r.pc + ((ex_wb_r.orig_instr[1:0] == 2'b11) ? 32'd4 : 32'd2);
        else if ((dbg_enter_debug || trigger_match || (halt_req_i && !dbg_halted_r)) && if_ex_r.valid)
            dbg_halt_pc_r <= if_ex_r.pc;  // latch at halt
    end

    assign dbg_pc_o       = dbg_halted_r ? dbg_halt_pc_r : pc_if;

    assign imem_req_valid = !dbg_halted_r;

    // Pre-advance: drive the *next* fetch address combinatorially so the SRAM
    // sees the new address in the same cycle that mem_ready/flush fires.
    // This eliminates the 1-cycle stale-echo after each fetch word, reducing
    // the CPI floor from 2.0 (32-bit) / 1.5 (compressed) to ~1.0 / 0.67.
    always_comb begin
        if (dbg_halted_r) imem_req_addr = pc_if;
        else if (dbg_pc_we_i) imem_req_addr = dbg_pc_wdata_i;
        else if (if_stall) imem_req_addr = pc_if;
        else if (if_flush) imem_req_addr = if_flush_pc;
        else if (bp_redirect) imem_req_addr = bp_redirect_pc;
        else if (rvc_mem_ready) imem_req_addr = pc_if + 32'd4;
        else imem_req_addr = pc_if;
    end

    // =====================================================================
    // Static Branch Predictor: Backward-Taken / Forward-Not-Taken (BTFNT)
    // + Unconditional JAL pre-decode
    // + L0 last-branch target fast path (helps recurring forward-taken branches)
    //
    // Pre-decode runs on the expanded instruction at the RVC output, one
    // cycle before it is latched into the IF/EX register.
    //
    // For a BRANCH (opcode 7'b110_0011) the B-immediate sign bit is
    // instr[31].  A negative offset means a backward (likely loop-back)
    // branch -> predict taken.  A positive offset -> predict not-taken.
    //
    // For JAL (opcode 7'b110_1111) the target is always PC+J-imm and the
    // redirect is always correct -> zero penalty unconditionally.
    //
    // When predicting taken (branch) or pre-decoding JAL:
    //   - pc_if is steered to the target (replaces the next sequential fetch)
    //   - The RVC buffer is flushed to discard any instruction already fetched
    //     from PC+4 that is now on the wrong path
    //   - bp_taken=1 is recorded in the IF/EX register so EX skips its own
    //     redirect (front-end already handled it)
    //
    // In EX the actual outcome is compared against the prediction:
    //   - JAL with bp_taken         -> no EX redirect (always correct)
    //   - BRANCH correct prediction -> no redirect (0-cycle penalty)
    //   - BRANCH misprediction      -> 1-cycle flush to corrected PC
    // =====================================================================
    logic        bp_is_branch;
    logic        bp_is_jal;
    logic        bp_l0_hit;
    logic [31:0] bp_imm;        // sign-extended B-type immediate
    logic [31:0] bp_jal_imm;    // sign-extended J-type immediate for JAL
    logic [31:0] bp_target_if;  // predicted branch/JAL target

    // Identify BRANCH and JAL opcodes on the expanded instruction
    assign bp_is_branch = (rvc_instr_data[6:0] == 7'b110_0011);
    assign bp_is_jal = (rvc_instr_data[6:0] == 7'b110_1111);

    // Reconstruct B-immediate: {signx19, imm[12], imm[11], imm[10:5], imm[4:1], 1'b0}
    assign bp_imm = {
        {19{rvc_instr_data[31]}},
        rvc_instr_data[31],     // imm[12]
        rvc_instr_data[7],      // imm[11]
        rvc_instr_data[30:25],  // imm[10:5]
        rvc_instr_data[11:8],   // imm[4:1]
        1'b0
    };

    // Reconstruct J-immediate: {signx11, imm[20], imm[10:1], imm[11], imm[19:12], 1'b0}
    assign bp_jal_imm = {
        {11{rvc_instr_data[31]}},
        rvc_instr_data[31],     // imm[20]
        rvc_instr_data[19:12],  // imm[19:12]
        rvc_instr_data[20],     // imm[11]
        rvc_instr_data[30:21],  // imm[10:1]
        1'b0
    };

    // Mux branch vs JAL target
    assign bp_target_if = rvc_instr_pc + (bp_is_jal ? bp_jal_imm : bp_imm);

    // L0 last-branch fast path: if this PC recently resolved taken, reuse target.
    assign bp_l0_hit = BP_EN && bp_l0_valid && bp_l0_taken && bp_is_branch
                       && rvc_instr_valid && (rvc_instr_pc == bp_l0_pc);

    // -----------------------------------------------------------------------
    // RAS (Return Address Stack) pre-decode
    // -----------------------------------------------------------------------
    // RISC-V calling convention link registers: x1 (ra), x5 (t0)
    //   Push: JAL or JALR with rd in {x1, x5}  (call instruction)
    //   Pop:  JALR with rs1 in {x1, x5} and rd not in {x1, x5}  (return)
    logic       bp_is_jalr;
    logic [4:0] bp_rd;
    logic [4:0] bp_rs1;
    logic       bp_rd_is_link;
    logic       bp_rs1_is_link;

    assign bp_is_jalr     = (rvc_instr_data[6:0] == 7'b110_0111);
    assign bp_rd          = rvc_instr_data[11:7];
    assign bp_rs1         = rvc_instr_data[19:15];
    assign bp_rd_is_link  = (bp_rd == 5'd1) || (bp_rd == 5'd5);
    assign bp_rs1_is_link = (bp_rs1 == 5'd1) || (bp_rs1 == 5'd5);

    // RAS_EN is forced off for RV32E minimum configurations (RV32E_EN=1)
    localparam bit RAS_ACTIVE = RAS_EN && !RV32E_EN;

    // Push: any JAL or JALR that writes a link register (call instruction)
    assign bp_ras_push = BP_EN && RAS_ACTIVE && rvc_instr_valid && !if_stall && !if_flush
                         && (bp_is_jal || bp_is_jalr) && bp_rd_is_link;

    // Pop: JALR that reads a link register and does not write one (return)
    assign bp_ras_pop  = BP_EN && RAS_ACTIVE && rvc_instr_valid && !if_stall && !if_flush
                         && bp_is_jalr && bp_rs1_is_link && !bp_rd_is_link;

    // Redirect for:
    //   - Backward-taken branches (BTFNT: imm[31]=1 means negative offset)
    //   - L0-hit branches that were recently resolved as taken (any direction)
    //   - All JAL instructions (always-taken unconditional jump)
    //   - JALR return instructions predicted by the RAS
    // Suppress if a higher-priority flush is in flight or pipeline is stalled.
    assign bp_redirect = BP_EN && rvc_instr_valid && !if_stall && !if_flush &&
                         ((bp_is_branch && (rvc_instr_data[31] || bp_l0_hit)) || bp_is_jal ||
                          bp_ras_pop);

    assign bp_redirect_pc = bp_ras_pop ? bp_ras_top : bp_l0_hit ? bp_l0_target : bp_target_if;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) pc_if <= BOOT_ADDR;
        else if (dbg_pc_we_i) pc_if <= dbg_pc_wdata_i;
        else if (!if_stall) begin
            if (if_flush) pc_if <= if_flush_pc;
            else if (bp_redirect) pc_if <= bp_redirect_pc;
            else if (rvc_mem_ready) pc_if <= pc_if + 32'd4;
        end
    end

    logic ex_stall;  // stall EX stage (and upstream)
    logic ex_flush;  // inject bubble into EX
    logic load_use_stall;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if_ex_r               <= '0;
            if_ex_r.valid         <= 1'b0;
            if_ex_r.pc            <= 32'h0;
            if_ex_r.instr         <= 32'h0;
            if_ex_r.orig_instr    <= 32'h0;
            if_ex_r.is_compressed <= 1'b0;
            if_ex_r.bp_taken      <= 1'b0;
            if_ex_r.bp_pred_pc    <= 32'h0;
            if_ex_r.ifetch_fault  <= 1'b0;
        end
        else if (dbg_pc_we_i) begin
            if_ex_r <= '0;
        end
        else if (halt_req_i && !dbg_halted_r) begin
            // Flush pipeline on debug halt so the stale IF/EX instruction
            // does not execute as the first step on resume.  ebreak already
            // flushes via dbg_enter_debug; haltreq needs an explicit flush.
            if_ex_r <= '0;
        end
        else if (resume_req_i && dbg_halted_r && !dbg_step_served_r && !dbg_resumeack_r) begin
            // Flush pipeline on debug resume to discard any stale instruction
            // that may have been in if_ex_r since the previous debug halt.
            if_ex_r <= '0;
        end
        else if (!ex_stall) begin
            if (ex_flush || if_flush || dbg_enter_debug) begin
                if_ex_r <= '0;
            end
            else if (load_use_stall) begin
                // Extra bubble stall: the dependent instruction must stay in the
                // IF->EX slot while the register file is written by the load WB.
                // Do NOT advance if_ex_r; hold it implicitly (no assignment).
                // (if_stall=1 has already prevented pc_if from advancing.)
            end
            else if (imem_resp_fault) begin
                // Preserve the original request PC for an instruction-access fault
                // without letting the RVC path consume/advance the bad fetch word.
                if_ex_r.valid         <= 1'b1;
                if_ex_r.pc            <= imem_resp_fault_pc;
                if_ex_r.instr         <= 32'h0000_0013;
                if_ex_r.orig_instr    <= 32'h0000_0000;
                if_ex_r.is_compressed <= imem_resp_fault_pc[1];
                if_ex_r.bp_taken      <= 1'b0;
                if_ex_r.ifetch_fault  <= 1'b1;
            end
            else if (rvc_instr_valid) begin
                if_ex_r.valid         <= 1'b1;
                if_ex_r.pc            <= rvc_instr_pc;
                if_ex_r.instr         <= rvc_instr_data;
                if_ex_r.orig_instr    <= rvc_orig_instr;
                if_ex_r.is_compressed <= rvc_is_compressed;
                if_ex_r.bp_taken      <= bp_redirect;     // BTFNT/JAL/RAS: record prediction
                if_ex_r.bp_pred_pc    <= bp_redirect_pc;  // RAS predicted return target
                if_ex_r.ifetch_fault  <= 1'b0;
            end
            else begin
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
            amo_load_data;  // AMO forwards old memory value
        else if (ex_wb_r.mem_read) wb_rd_data = load_result;  // sign/zero-extended byte/half/word load result
        else wb_rd_data = ex_wb_r.rd_data;
    end

    // =====================================================================
    // Forwarding: WB->EX (single forwarding path)
    // =====================================================================
    // For non-load instructions, wb_rd_data is a registered FF (ex_wb_r.rd_data),
    // so forwarding is unconditionally safe.
    //
    // For loads (load_uses_sram=1), wb_rd_data is computed combinatorially from
    // dmem_resp_data (the SRAM registered output).  The SRAM captures the
    // address at posedge N and presents stable data from posedge N onward,
    // so the forward path (dmem_resp_data -> sign-extend -> fwd-mux -> ALU ->
    // ex_wb_r latch) has a full clock cycle when dmem_resp_valid=1.  We
    // therefore allow forwarding as soon as dmem_resp_valid is asserted.
    //
    // When dmem_resp_valid=0 (SRAM has not responded yet) the load_use_stall
    // below inserts a bubble and keeps the consumer in EX until the data
    // arrives.  AMO non-LR operations forward from amo_load_data (registered)
    // and are excluded from load_uses_sram.
    logic load_uses_sram;  // true when WB write-back data comes from live SRAM
    assign load_uses_sram = ex_wb_r.mem_read && (!ex_wb_r.is_amo || ex_wb_r.amo_op == AMO_LR);

    logic [31:0] fwd_rs1, fwd_rs2;
    always_comb begin
        fwd_rs1 = rs1_data;
        fwd_rs2 = rs2_data;
        if (ex_wb_r.valid && ex_wb_r.reg_we && ex_wb_r.rd_addr != 5'd0 && (!load_uses_sram || dmem_resp_valid_rd)) begin
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

    // Update L0 last-branch entry on each resolved branch.
    // This is intentionally tiny and conservative: one entry, no tags beyond PC.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bp_l0_valid  <= 1'b0;
            bp_l0_pc     <= 32'h0;
            bp_l0_target <= 32'h0;
            bp_l0_taken  <= 1'b0;
        end
        else if (dbg_pc_we_i) begin
            bp_l0_valid <= 1'b0;
        end
        else if (if_ex_r.valid && dec_branch && !ex_stall && !load_use_stall) begin
            bp_l0_valid  <= 1'b1;
            bp_l0_pc     <= pc_ex;
            bp_l0_target <= branch_target;
            bp_l0_taken  <= branch_taken;
        end
    end

    // =====================================================================
    // Return Address Stack (RAS) — 2-entry circular buffer
    // =====================================================================
    // Enabled when RAS_ACTIVE=1 (BP_EN=1 && RAS_EN=1 && !RV32E_EN).
    // Push on JAL/JALR with rd=link; pop on JALR with rs1=link, rd=non-link.
    // The write pointer wraps naturally in a circular fashion (modulo 2).
    // Flushed only on exception/mret/interrupt/debug (wb_redirect) to preserve
    // call-depth state across branch mispredictions and fence.i.
    // When RAS_ACTIVE=0 the generate-else branch ties bp_ras_top to 0 and
    // no flip-flops or combinatorial RAS logic are emitted.
    localparam int unsigned RAS_DEPTH = 2;
    localparam int unsigned RAS_BITS  = 1;

    generate
        if (RAS_ACTIVE) begin : g_ras
            logic [RAS_DEPTH-1:0][31:0] ras_stack;
            logic [ RAS_BITS-1:0]       ras_wr_ptr;
            logic [ RAS_BITS-1:0]       ras_rd_ptr;  // top-of-stack slot
            logic [         31:0]       bp_ras_push_pc;

            assign ras_rd_ptr     = ras_wr_ptr - RAS_BITS'(1);
            assign bp_ras_top     = ras_stack[ras_rd_ptr];

            // Link address to push: next sequential PC after the call instruction
            assign bp_ras_push_pc = rvc_instr_pc + (rvc_is_compressed ? 32'd2 : 32'd4);

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    ras_wr_ptr <= '0;
                    for (int i = 0; i < RAS_DEPTH; i++) ras_stack[i] <= 32'h0;
                end
                else if (wb_redirect || dbg_pc_we_i) begin
                    // Flush on non-speculative redirect (exception/mret/interrupt/debug)
                    ras_wr_ptr <= '0;
                end
                else if (bp_ras_push && bp_ras_pop) begin
                    // Coroutine (e.g. jalr ra, 0(ra)): overwrite top entry; pointer unchanged
                    ras_stack[ras_rd_ptr] <= bp_ras_push_pc;
                end
                else if (bp_ras_push) begin
                    ras_stack[ras_wr_ptr] <= bp_ras_push_pc;
                    ras_wr_ptr            <= ras_wr_ptr + RAS_BITS'(1);
                end
                else if (bp_ras_pop) begin
                    ras_wr_ptr <= ras_wr_ptr - RAS_BITS'(1);
                end
            end
        end
        else begin : g_ras_disabled
            // RAS_ACTIVE=0: no FFs instantiated; bp_ras_top is a constant zero.
            assign bp_ras_top = 32'h0;
        end
    endgenerate

    // Redirect PC
    logic [31:0] redirect_pc_ex;
    logic        redirect_ex;
    always_comb begin
        redirect_ex    = 1'b0;
        redirect_pc_ex = 32'h0;
        if (if_ex_r.valid) begin
            if (dec_jal) begin
                // If the front-end already pre-decoded this JAL (bp_taken=1),
                // pc_if is already pointing at the target -- no EX redirect needed.
                if (!if_ex_r.bp_taken) begin
                    redirect_ex    = 1'b1;
                    redirect_pc_ex = pc_ex + dec_imm;
                end
            end
            if (dec_jalr) begin
                // If the RAS pre-predicted this return (bp_taken=1), suppress the EX
                // redirect only when the actual target matches the prediction.
                // A RAS misprediction still corrects the PC via redirect.
                redirect_pc_ex = (fwd_rs1 + dec_imm) & ~32'h1;
                redirect_ex    = !if_ex_r.bp_taken || (redirect_pc_ex != if_ex_r.bp_pred_pc);
            end
            if (dec_branch) begin
                if (!BP_EN) begin
                    // Predict-not-taken fallback
                    if (branch_taken) begin
                        redirect_ex    = 1'b1;
                        redirect_pc_ex = branch_target;
                    end
                end
                else begin
                    // BTFNT: redirect only on misprediction
                    if (branch_taken && !if_ex_r.bp_taken)
                        // predicted not-taken, actually taken
                        begin
                        redirect_ex    = 1'b1;
                        redirect_pc_ex = branch_target;
                    end
                    else if (!branch_taken && if_ex_r.bp_taken)
                        // predicted taken, actually not-taken -> squash speculative fetch
                        begin
                        redirect_ex    = 1'b1;
                        redirect_pc_ex = pc_ex + (if_ex_r.is_compressed ? 32'd2 : 32'd4);
                    end
                end
            end
            if (dec_is_fence_i) begin
                // FENCE.I: flush the fetch pipeline so subsequent instruction
                // fetches see any data writes that preceded this instruction.
                // Without this flush, pre-fetched stale instructions sitting in
                // the RVC buffer would be executed instead of the newly written
                // ones.  Redirect to PC+4 (fence.i is never compressed).
                redirect_ex    = 1'b1;
                redirect_pc_ex = pc_ex + 32'd4;
            end
        end
    end

    // CSR: write data
    logic [31:0] csr_wdata_ex;
    always_comb begin
        csr_wdata_ex = alu_op_a;  // CSRRW/CSRRS/CSRRC: rs1
        // CSRRWI/CSRRSI/CSRRCI: zimm
        if (dec_csr_op[2]) csr_wdata_ex = {27'd0, dec_rs1};
    end

    // Link address for JAL/JALR
    logic [31:0] link_addr;
    assign link_addr = pc_ex + (if_ex_r.is_compressed ? 32'd2 : 32'd4);

    // EX result
    logic [31:0] ex_result;
    always_comb begin
        if (dec_jal || dec_jalr) ex_result = link_addr;
        else if (dec_lui) ex_result = dec_imm;
        else if (dec_auipc) ex_result = alu_result;
        else if (dec_csr_op != 3'b0) ex_result = csr_rdata;
        else ex_result = alu_result;
    end

    // Memory address and store data
    logic [31:0] mem_addr_ex;
    logic [31:0] store_data_ex;
    assign mem_addr_ex   = fwd_rs1 + dec_imm;  // for loads/stores
    assign store_data_ex = fwd_rs2;

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
    logic              ex_exception;
    exc_cause_e        ex_exc_cause;
    logic       [31:0] ex_exc_tval;
    always_comb begin
        ex_exception = 1'b0;
        ex_exc_cause = EXC_ILLEGAL_INSTR;
        ex_exc_tval  = if_ex_r.orig_instr;
        if (if_ex_r.valid) begin
            if (if_ex_r.ifetch_fault) begin
                // AXI DECERR on I-fetch raises EXC_INSTR_ACCESS_FAULT (cause=1).
                // Checked before dec_illegal since the instruction data is meaningless.
                // Report the faulting fetch address in mtval.
                ex_exception = 1'b1;
                ex_exc_cause = EXC_INSTR_ACCESS_FAULT;
                ex_exc_tval  = if_ex_r.pc;
            end
            else if (dec_illegal) begin
                ex_exception = 1'b1;
                ex_exc_cause = EXC_ILLEGAL_INSTR;
                ex_exc_tval  = if_ex_r.orig_instr;
            end
            else if (dec_is_ebreak && !dbg_enter_debug) begin
                ex_exception = 1'b1;
                ex_exc_cause = EXC_BREAKPOINT;
                ex_exc_tval  = if_ex_r.pc;
            end
            else if (dec_is_ecall) begin
                ex_exception = 1'b1;
                ex_exc_cause = EXC_ECALL_MMODE;
                ex_exc_tval  = 32'h0;
            end
            else if ((dec_mem_read || dec_mem_write) && !dec_is_amo &&
                     (((dec_mem_op == MEM_HALF || dec_mem_op == MEM_HALF_U) && mem_addr_ex[0]) ||
                      (dec_mem_op == MEM_WORD && mem_addr_ex[1:0] != 2'b00))) begin
                // Misaligned load/store: raise address-misaligned exception.
                // tval = faulting virtual address (RISC-V spec Sec.3.1.16).
                ex_exception = 1'b1;
                ex_exc_cause = dec_mem_write ? EXC_STORE_ADDR_MISALIGNED : EXC_LOAD_ADDR_MISALIGNED;
                ex_exc_tval  = mem_addr_ex;
            end
        end
    end

    assign dbg_enter_debug = if_ex_r.valid && dec_is_ebreak
                             && (dbg_ebreakm_i || (if_ex_r.pc[31:4] == DEBUG_ROM_BASE[31:4]));

    // -------------------------------------------------------------------------
    // Hardware trigger matching (Debug Spec 0.13 Sec.5.2 mcontrol, type=2)
    // Checked in EX stage (timing=before): fires before instruction executes.
    // Conditions: type=2, M-mode enabled, action=1 (enter debug mode),
    //             plus one of execute/store/load address match.
    //
    // Address matching supports:
    //   match=0 (exact): trigger fires when address == tdata2
    //   match=1 (NAPOT): trigger fires when address is in the NAPOT range
    //     encoded by tdata2 = base | (size/2 - 1).  Formula:
    //       napot_p = (~tdata2) & (tdata2+1)   -- one-hot at position n
    //       napot_rmask = (napot_p << 1) - 1   -- 2^(n+1)-1
    //       match if: (addr ^ tdata2) & ~napot_rmask == 0
    // -------------------------------------------------------------------------
    logic [N_TRIGGERS-1:0] trigger_match_vec;  // per-trigger: which trigger(s) matched

    // Address-match helper: supports exact (match=0) and NAPOT (match=1)
    function automatic logic trig_addr_match(input logic [31:0] addr, input logic [31:0] tdata1,
                                             input logic [31:0] tdata2);
        logic [31:0] napot_p, napot_rmask;
        napot_p     = (~tdata2) & (tdata2 + 32'd1);
        napot_rmask = (napot_p << 1) - 32'd1;
        case (tdata1[10:7])  // match field
            4'd0:    return (addr == tdata2);
            4'd1:    return (((addr ^ tdata2) & ~napot_rmask) == 32'd0);
            default: return (addr == tdata2);
        endcase
    endfunction

    always_comb begin
        trigger_match     = 1'b0;
        trigger_match_vec = '0;
        for (int i = 0; i < N_TRIGGERS; i++) begin
            if (!dbg_halted_r && if_ex_r.valid && tdata1_i[i][31:28] == 4'd2  // mcontrol type
                && tdata1_i[i][6]               // M-mode trigger enable
                && tdata1_i[i][15:12] == 4'd1)  // action=1 (enter debug mode)
            begin
                // Execute trigger: match instruction PC (always exact)
                if (tdata1_i[i][2] && (if_ex_r.pc == tdata2_i[i])) begin
                    trigger_match        = 1'b1;
                    trigger_match_vec[i] = 1'b1;
                end
                // Store trigger: match effective address (timing=before)
                if (tdata1_i[i][1] && dec_mem_write && trig_addr_match(mem_addr_ex, tdata1_i[i], tdata2_i[i])) begin
                    trigger_match        = 1'b1;
                    trigger_match_vec[i] = 1'b1;
                end
                // Load trigger: match effective address (timing=before)
                if (tdata1_i[i][0] && dec_mem_read && trig_addr_match(mem_addr_ex, tdata1_i[i], tdata2_i[i])) begin
                    trigger_match        = 1'b1;
                    trigger_match_vec[i] = 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbg_halted_r       <= 1'b0;
            dbg_resumeack_r    <= 1'b0;
            dbg_step_pending_r <= 1'b0;
            dbg_step_served_r  <= 1'b0;
            trigger_halt_r     <= 1'b0;
            trigger_hit_r      <= '0;
        end
        else begin
            // Clear step_served and resumeack when resumereq de-asserts (OpenOCD cleared it)
            if (!resume_req_i) begin
                dbg_step_served_r <= 1'b0;
                dbg_resumeack_r   <= 1'b0;  // resumeack is sticky until resumereq falls
            end

            if (resume_req_i && dbg_halted_r && !dbg_step_served_r && !dbg_resumeack_r) begin
                dbg_halted_r       <= 1'b0;
                dbg_resumeack_r    <= 1'b1;  // sticky: stays 1 until resumereq deasserts
                dbg_step_pending_r <= dbg_singlestep_i;
                trigger_halt_r     <= 1'b0;  // clear trigger cause on resume
                trigger_hit_r      <= '0;    // clear per-trigger hit bits on resume
            end
            else if ((dbg_enter_debug || trigger_match
                      || (halt_req_i && !dbg_halted_r)
                      || (dbg_step_pending_r && trace_valid_r))
                      && !dmem_stall) begin
                dbg_halted_r       <= 1'b1;
                trigger_halt_r     <= trigger_match;      // record: trigger module caused halt
                trigger_hit_r      <= trigger_match_vec;  // which trigger(s) fired
                // resumeack stays 1 (sticky) - TCK synchronizer needs time to capture it
                dbg_step_pending_r <= 1'b0;
                // After a single-step halt, block re-resume until resumereq deasserts
                if (dbg_step_pending_r && trace_valid_r) dbg_step_served_r <= 1'b1;
            end
        end
    end

    // Distinguish read responses from write-ack pulses.
    // When the store buffer fires a DRAM write, dram_used_by_core_d_d=1 makes
    // dmem_resp_valid=1 the following cycle.  But the SRAM output carries the
    // write-cycle data (NO_CHANGE = undefined/'x), not the load's read data.
    // dmem_was_write_d tracks dmem_req_write one cycle back so we can gate
    // all load-data uses on a clean read-only response flag.
    //
    // dmem_resp_valid        (unchanged) — still used for: sb_fire,
    //                        strict-store dmem_stall, AMO_STORE_WAIT.
    // dmem_resp_valid_rd     — load_use_stall, forwarding, read dmem_stall.
    logic dmem_was_write_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) dmem_was_write_d <= 1'b0;
        else dmem_was_write_d <= dmem_req_valid && dmem_req_write;
    end
    assign dmem_resp_valid_rd = dmem_resp_valid && !dmem_was_write_d;

    // Load-use hazard: stall only when WB holds a load/LR result whose SRAM
    // data is not yet available (dmem_resp_valid_rd=0).  When dmem_resp_valid_rd=1
    // the load result is forwarded combinatorially via load_result -> wb_rd_data
    // -> fwd_rs1/fwd_rs2 directly into the EX ALU, eliminating the bubble.
    // Non-LR AMO ops use amo_load_data (registered) and are therefore excluded.
    assign load_use_stall = ex_wb_r.valid && load_uses_sram && !dmem_resp_valid_rd &&
                            ((ex_wb_r.rd_addr == dec_rs1 && dec_rs1 != 5'd0) ||
                             (ex_wb_r.rd_addr == dec_rs2 && dec_rs2 != 5'd0 &&
                              (!dec_alu_src || dec_mem_write || dec_branch || dec_is_amo)));

    // AMO state machine
    typedef enum logic [1:0] {
        AMO_IDLE,
        AMO_LOAD_WAIT,
        AMO_STORE_WAIT
    } amo_state_e;
    amo_state_e        amo_state;
    logic       [31:0] amo_store_val;

    // Misaligned loads/stores raise EXC_LOAD/STORE_ADDR_MISALIGNED in the EX stage
    // (detected above in the ex_exception always_comb block).  No hardware
    // misalignment-splitting state machine is present.

    always_comb begin
        case (ex_wb_r.amo_op)
            AMO_SWAP: amo_store_val = ex_wb_r.store_data;
            AMO_ADD: amo_store_val = amo_load_data + ex_wb_r.store_data;
            AMO_XOR: amo_store_val = amo_load_data ^ ex_wb_r.store_data;
            AMO_AND: amo_store_val = amo_load_data & ex_wb_r.store_data;
            AMO_OR: amo_store_val = amo_load_data | ex_wb_r.store_data;
            AMO_MIN:
            amo_store_val = ($signed(amo_load_data) < $signed(ex_wb_r.store_data)) ? amo_load_data : ex_wb_r.store_data;
            AMO_MAX:
            amo_store_val = ($signed(amo_load_data) > $signed(ex_wb_r.store_data)) ? amo_load_data : ex_wb_r.store_data;
            AMO_MINU: amo_store_val = (amo_load_data < ex_wb_r.store_data) ? amo_load_data : ex_wb_r.store_data;
            AMO_MAXU: amo_store_val = (amo_load_data > ex_wb_r.store_data) ? amo_load_data : ex_wb_r.store_data;
            default: amo_store_val = ex_wb_r.store_data;
        endcase
    end

    // Dmem driver
    logic        sb_valid;
    logic [31:0] sb_addr;
    logic [31:0] sb_wdata;
    logic [ 3:0] sb_wstrb;
    logic        sb_fire;
    logic        sb_commit_ex;

    function automatic logic is_tcm_addr(input logic [31:0] addr);
        logic hit_iram, hit_dram;
        hit_iram = (addr & ~(32'(IRAM_SIZE) - 32'h1)) == (IRAM_BASE & ~(32'(IRAM_SIZE) - 32'h1));
        hit_dram = (addr & ~(32'(DRAM_SIZE) - 32'h1)) == (DRAM_BASE & ~(32'(DRAM_SIZE) - 32'h1));
        return hit_iram || hit_dram;
    endfunction

    // Relaxed store path: only for non-atomic stores into local TCM regions.
    // These stores can retire without waiting on dmem_resp_valid.
    // Loads/AMO and non-TCM stores remain strict and keep precise fault behavior.
    assign sb_commit_ex = ex_wb_r.valid && ex_wb_r.mem_write && !ex_wb_r.is_amo && !irq_cancel && is_tcm_addr(
        ex_wb_r.mem_addr
    );

    // D-path pre-advance: issue a TCM load request from EX (using mem_addr_ex) one
    // cycle before the instruction enters WB.  The TCM SRAM responds with a 1-cycle
    // registered latency, so the data is ready the moment the load reaches WB --
    // eliminating the dmem_stall cycle that would otherwise occur.
    //
    // Conditions (all must hold):
    //   - Load in EX with no address-exception
    //   - Pipeline not stalled or redirected (no WB exception/mret/irq in flight)
    //   - Store buffer idle (prevents D-bus contention)
    //   - WB has no active memory op (prevents D-bus double-booking)
    //   - Target address is TCM (AXI loads are not pre-advanced)
    logic d_preload_valid;

    // Helper: true when the D-load address is in DRAM (not IRAM).
    // IRAM loads share the single-port SRAM with I-fetch.  Pre-advancing a DRAM
    // load uses a separate SRAM and does not displace any I-fetch, so it is
    // always safe to pre-advance.  Pre-advancing an IRAM load would steal the
    // IRAM port 1 cycle early (outside the normal dmem_stall window where the
    // pipeline is already frozen), creating a net-zero trade: the 1-cycle dmem_stall
    // saving is offset by a 1-cycle I-fetch bubble.  Skip IRAM loads.
    function automatic logic in_dram_addr(input logic [31:0] addr);
        return (addr & ~(32'(DRAM_SIZE) - 32'h1)) == (DRAM_BASE & ~(32'(DRAM_SIZE) - 32'h1));
    endfunction

    // Base preload conditions (without WB-mem guard): used when stealing the SRAM
    // port during the WB DRAM-load response cycle (consecutive DRAM loads).
    logic d_preload_valid_base;
    assign d_preload_valid_base = if_ex_r.valid && dec_mem_read && !ex_exception
                                  && !ex_stall && !load_use_stall && !wb_redirect
                                  && !sb_valid
                                  && in_dram_addr(
        mem_addr_ex
    );

    // Full d_preload guard: additionally requires WB to have no active memory op.
    assign d_preload_valid = d_preload_valid_base
                             && (!ex_wb_r.valid
                                 || (!ex_wb_r.mem_read && !ex_wb_r.mem_write && !ex_wb_r.is_amo));

    always_comb begin
        dmem_req_valid   = 1'b0;
        dmem_req_write   = 1'b0;
        dmem_req_addr    = 32'h0;
        dmem_req_wdata   = 32'h0;
        dmem_req_wstrb   = 4'h0;
        dmem_stall       = 1'b0;
        sb_fire          = 1'b0;
        d_preload_active = 1'b0;

        // Drain the queued relaxed store independently from EX/WB progress.
        if (sb_valid) begin
            dmem_req_valid = 1'b1;
            dmem_req_write = 1'b1;
            dmem_req_addr  = sb_addr;
            dmem_req_wdata = sb_wdata;
            dmem_req_wstrb = sb_wstrb;
            sb_fire        = dmem_resp_valid;
            // If EX/WB currently needs memory, hold it until the older queued store drains.
            if (ex_wb_r.valid && (ex_wb_r.mem_read || ex_wb_r.mem_write || ex_wb_r.is_amo)) dmem_stall = 1'b1;
        end
        else if (ex_wb_r.valid && !alu_stall && !irq_cancel && !dbg_halted_r) begin
            if (ex_wb_r.is_amo) begin
                case (amo_state)
                    AMO_IDLE: begin
                        if (ex_wb_r.amo_op == AMO_LR) begin
                            dmem_req_valid = 1'b1;
                            dmem_req_addr  = ex_wb_r.mem_addr;
                            if (!dmem_resp_valid) dmem_stall = 1'b1;
                        end
                        else if (ex_wb_r.amo_op == AMO_SC) begin
                            // SC: check reservation
                            if (lr_valid && (lr_addr == ex_wb_r.mem_addr)) begin
                                dmem_req_valid = 1'b1;
                                dmem_req_write = 1'b1;
                                dmem_req_addr  = ex_wb_r.mem_addr;
                                dmem_req_wdata = ex_wb_r.store_data;
                                dmem_req_wstrb = 4'hF;
                                if (!dmem_resp_valid) dmem_stall = 1'b1;
                            end
                            // SC fails: rd=1, no store needed
                        end
                        else begin
                            dmem_req_valid = 1'b1;
                            dmem_req_addr  = ex_wb_r.mem_addr;
                            if (!dmem_resp_valid) dmem_stall = 1'b1;
                            else dmem_stall = 1'b1;  // need STORE_WAIT
                        end
                    end
                    AMO_LOAD_WAIT: begin
                        if (dmem_resp_valid) begin
                            // issue store next
                            dmem_req_valid = 1'b1;
                            dmem_req_write = 1'b1;
                            dmem_req_addr  = ex_wb_r.mem_addr;
                            dmem_req_wdata = amo_store_val;
                            dmem_req_wstrb = 4'hF;
                            dmem_stall     = 1'b1;
                        end
                        else begin
                            dmem_req_valid = 1'b1;
                            dmem_req_addr  = ex_wb_r.mem_addr;
                            dmem_stall     = 1'b1;
                        end
                    end
                    AMO_STORE_WAIT: begin
                        dmem_req_valid = 1'b1;
                        dmem_req_write = 1'b1;
                        dmem_req_addr  = ex_wb_r.mem_addr;
                        dmem_req_wdata = amo_store_val;
                        dmem_req_wstrb = 4'hF;
                        if (!dmem_resp_valid) dmem_stall = 1'b1;
                    end
                    default: ;
                endcase
            end
            else if (ex_wb_r.mem_read) begin
                dmem_req_valid = 1'b1;
                if (!dmem_resp_valid_rd) begin
                    // First stall cycle (or stale write-ack): issue the SRAM
                    // read address normally.
                    dmem_req_addr = ex_wb_r.mem_addr;
                    dmem_stall    = 1'b1;
                end
                else if (d_preload_valid_base) begin
                    // Response cycle: steal SRAM port for the next DRAM load
                    // so it arrives 1 cycle earlier (consecutive DRAM loads).
                    dmem_req_addr    = mem_addr_ex;
                    d_preload_active = 1'b1;
                end
                else begin
                    // Response cycle, no preload: re-drive old address
                    // (spurious; jv32_top tracking gate suppresses it).
                    dmem_req_addr = ex_wb_r.mem_addr;
                end
            end
            else if (ex_wb_r.mem_write) begin
                // TCM stores are enqueued and retired without waiting for a response.
                // Non-TCM stores stay strict to preserve precise fault behavior.
                if (sb_commit_ex) begin
                    if (sb_valid) dmem_stall = 1'b1;
                end
                else begin
                    dmem_req_valid = 1'b1;
                    dmem_req_write = 1'b1;
                    dmem_req_addr = ex_wb_r.mem_addr;
                    dmem_req_wdata = ex_wb_r.store_data;
                    dmem_req_wstrb = ex_wb_r.mem_op == MEM_BYTE ? (4'b0001 << ex_wb_r.mem_addr[1:0]) :
                                     ex_wb_r.mem_op == MEM_HALF ? (4'b0011 << ex_wb_r.mem_addr[1:0]) : 4'b1111;
                    if (!dmem_resp_valid) dmem_stall = 1'b1;
                end
            end
            else begin
                // Non-memory WB (ALU, branch, JAL, etc.): DRAM port is idle;
                // allow d_preload for the next instruction if available.
                if (d_preload_valid) begin
                    dmem_req_valid = 1'b1;
                    dmem_req_addr  = mem_addr_ex;
                end
            end
        end
        // D-path pre-advance: WB is empty — issue TCM load address from EX so
        // the SRAM response is already valid when the instruction reaches WB.
        else if (d_preload_valid) begin
            dmem_req_valid = 1'b1;
            dmem_req_addr  = mem_addr_ex;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sb_valid <= 1'b0;
            sb_addr  <= 32'h0;
            sb_wdata <= 32'h0;
            sb_wstrb <= 4'h0;
        end
        else begin
            if (sb_fire) sb_valid <= 1'b0;

            // Queue relaxed store on WB commit when the store queue is free.
            if (wb_retire && sb_commit_ex && !sb_valid) begin
                sb_valid <= 1'b1;
                sb_addr <= ex_wb_r.mem_addr;
                sb_wdata <= ex_wb_r.store_data;
                sb_wstrb <= ex_wb_r.mem_op == MEM_BYTE ? (4'b0001 << ex_wb_r.mem_addr[1:0]) :
                           ex_wb_r.mem_op == MEM_HALF ? (4'b0011 << ex_wb_r.mem_addr[1:0]) : 4'b1111;
            end
        end
    end

    // AMO state machine sequential
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            amo_state     <= AMO_IDLE;
            amo_load_data <= 32'h0;
            lr_valid      <= 1'b0;
            lr_addr       <= 32'h0;
        end
        else if (ex_wb_r.valid && ex_wb_r.is_amo && !sb_valid) begin
            case (amo_state)
                AMO_IDLE: begin
                    if (ex_wb_r.amo_op == AMO_LR && dmem_resp_valid) begin
                        lr_valid  <= 1'b1;
                        lr_addr   <= ex_wb_r.mem_addr;
                        amo_state <= AMO_IDLE;  // done
                    end
                    else if (ex_wb_r.amo_op == AMO_SC) begin
                        if (lr_valid && dmem_resp_valid) lr_valid <= 1'b0;
                        amo_state <= AMO_IDLE;
                    end
                    else if (ex_wb_r.amo_op != AMO_LR && ex_wb_r.amo_op != AMO_SC) begin
                        if (dmem_resp_valid) begin
                            amo_load_data <= dmem_resp_data;
                            amo_state     <= AMO_STORE_WAIT;
                        end
                        else amo_state <= AMO_LOAD_WAIT;
                    end
                end
                AMO_LOAD_WAIT: begin
                    if (dmem_resp_valid) begin
                        amo_load_data <= dmem_resp_data;
                        amo_state     <= AMO_STORE_WAIT;
                    end
                end
                AMO_STORE_WAIT: begin
                    if (dmem_resp_valid) amo_state <= AMO_IDLE;
                end
                default: amo_state <= AMO_IDLE;
            endcase
        end
        else if (!ex_wb_r.valid) amo_state <= AMO_IDLE;
    end

    // Multi-cycle ALU stall
    assign alu_stall         = if_ex_r.valid && !alu_ready;

    // Operand stall: forwarding not yet available (load in WB not done)
    assign alu_operand_stall = load_use_stall;

    // External EX holds can delay retirement of a completed multi-cycle ALU op.
    assign alu_result_hold   = dmem_stall || dbg_halted_r;

    // =====================================================================
    // Hazard control
    // =====================================================================
    // ex_stall: stall EX stage (freeze EX/WB, freeze IF/EX, hold IF)
    assign ex_stall          = dmem_stall || alu_stall || dbg_halted_r;

    // if_stall: hold IF (do not advance PC or consume RVC output)
    assign if_stall          = ex_stall || load_use_stall;

    // WB retirement pulse (single-cycle commit point for side effects).
    assign wb_retire         = ex_wb_r.valid && !ex_stall && !dbg_halted_r;

    // -------------------------------------------------------------------------
    // WB-phase data-memory fault: AXI DECERR on load or store response.
    // Raises EXC_LOAD_ACCESS_FAULT (cause=5) or EXC_STORE_ACCESS_FAULT (cause=7).
    // Supplements EX-phase exceptions (ex_wb_r.exception); both can't fire together
    // because ex_wb_r.exception suppresses mem_read/mem_write in ex_wb_r.
    // -------------------------------------------------------------------------
    logic dmem_fault_active;

    assign dmem_fault_active = dmem_resp_fault && ex_wb_r.valid
                             && (ex_wb_r.mem_read || ex_wb_r.mem_write)
                             && !ex_wb_r.exception;
    assign wb_exception = (ex_wb_r.valid && ex_wb_r.exception) || dmem_fault_active;
    assign wb_exc_cause = dmem_fault_active
                        ? (ex_wb_r.mem_write ? EXC_STORE_ACCESS_FAULT : EXC_LOAD_ACCESS_FAULT)
                        : ex_wb_r.exc_cause;
    assign wb_exc_tval = dmem_fault_active ? ex_wb_r.mem_addr : ex_wb_r.exc_tval;

    // Flush IF stage when branch/jump/exception/interrupt redirect
    always_comb begin
        if_flush    = 1'b0;
        if_flush_pc = BOOT_ADDR;
        // WB redirects (exception, mret, interrupt take priority)
        if (wb_exception) begin
            if_flush    = 1'b1;
            if_flush_pc = mtvec_csr;
        end
        else if (ex_wb_r.valid && ex_wb_r.mret) begin
            if_flush    = 1'b1;
            // Tail-chain: if a CLIC IRQ is pending above threshold, redirect
            // directly to the next handler instead of returning to mepc.
            if_flush_pc = csr_tail_chain ? csr_tail_chain_pc : mepc_csr;
        end
        else if (csr_irq_pending && ex_wb_r.valid && !dbg_step_pending_r) begin
            if_flush    = 1'b1;
            if_flush_pc = csr_irq_pc;
        end
        else if (redirect_ex && !ex_stall && !load_use_stall) begin
            if_flush    = 1'b1;
            if_flush_pc = redirect_pc_ex;
        end
    end

    // ex_flush: squash IF/EX content (branch resolved, inserting bubble).
    // Must be suppressed during a load_use_stall cycle: in that cycle the EX
    // computation uses stale operands (the dependent load result is not yet in
    // the register file) and the bubble injected into ex_wb_r discards the
    // result, so any branch decision made here is meaningless.
    assign ex_flush = redirect_ex && !ex_stall && !load_use_stall;

    // =====================================================================
    // Branch predictor performance counters
    // =====================================================================
    // When TRACE_EN=1: combinatorial pulses, one per retiring branch/JAL/JALR.
    // When TRACE_EN=0 + simulation (!SYNTHESIS): same, so testbench can print
    //   stats even in TRACE_EN=0 builds.
    // When TRACE_EN=0 + synthesis: all tied to 0 — no logic generated.
    generate
        if (TRACE_EN) begin : gen_perf_bp
            logic ex_valid_retire;
            assign ex_valid_retire  = if_ex_r.valid && !ex_stall && !load_use_stall && !ex_exception;

            assign perf_bp_branch   = ex_valid_retire && dec_branch;
            assign perf_bp_taken    = ex_valid_retire && dec_branch && branch_taken;
            assign perf_bp_mispred  = ex_valid_retire && dec_branch && (branch_taken != if_ex_r.bp_taken);
            assign perf_bp_jal      = ex_valid_retire && dec_jal;
            assign perf_bp_jal_miss = ex_valid_retire && dec_jal && !if_ex_r.bp_taken;
            assign perf_bp_jalr     = ex_valid_retire && dec_jalr;
        end
        else begin : gen_no_perf_bp
`ifndef SYNTHESIS
            // Simulation only: keep logic active so testbench stats remain valid
            // even when TRACE_EN=0.  The `ifndef SYNTHESIS guard means the synthesis
            // tool never sees these nets — gate count is unchanged.
            logic ex_valid_retire;
            assign ex_valid_retire  = if_ex_r.valid && !ex_stall && !load_use_stall && !ex_exception;

            assign perf_bp_branch   = ex_valid_retire && dec_branch;
            assign perf_bp_taken    = ex_valid_retire && dec_branch && branch_taken;
            assign perf_bp_mispred  = ex_valid_retire && dec_branch && (branch_taken != if_ex_r.bp_taken);
            assign perf_bp_jal      = ex_valid_retire && dec_jal;
            assign perf_bp_jal_miss = ex_valid_retire && dec_jal && !if_ex_r.bp_taken;
            assign perf_bp_jalr     = ex_valid_retire && dec_jalr;
`else
            // Synthesis with TRACE_EN=0: tie all counters to 0 (no logic added).
            assign perf_bp_branch   = 1'b0;
            assign perf_bp_taken    = 1'b0;
            assign perf_bp_mispred  = 1'b0;
            assign perf_bp_jal      = 1'b0;
            assign perf_bp_jal_miss = 1'b0;
            assign perf_bp_jalr     = 1'b0;
`endif
        end
    endgenerate

    // wb_redirect: WB stage is redirecting the PC (exception/mret/irq).
    // When this fires, the instruction currently in IF/EX must be squashed
    // (not promoted to EX/WB), because it's on the wrong control-flow path.
    // (declared as a forward reference above, near line 313)
    assign wb_redirect = wb_exception
                      || (ex_wb_r.valid && ex_wb_r.mret)
                      || (csr_irq_pending && ex_wb_r.valid
                          && !ex_wb_r.exception && !dmem_fault_active && !ex_wb_r.mret
                          && !dbg_step_pending_r);

    // RVC stall/flush
    // bp_redirect also flushes the RVC buffer to discard the instruction
    // speculatively fetched from PC+4 when a backward branch is predicted taken.
    // Debug PC writes also flush any stale prefetched halfword(s).
    // Debug resume flushes the RVC buffer to discard any instruction buffered
    // while the core was halted (prevents stale instructions from executing on step).
    logic dbg_resume_flush;

    assign dbg_resume_flush = resume_req_i && dbg_halted_r && !dbg_step_served_r && !dbg_resumeack_r;
    assign rvc_stall = if_stall;
    assign rvc_flush = if_flush || bp_redirect || dbg_pc_we_i || dbg_resume_flush;
    assign rvc_flush_pc = if_flush         ? if_flush_pc      :
                          dbg_pc_we_i      ? dbg_pc_wdata_i   :
                          dbg_resume_flush ? pc_if             :
                                             bp_redirect_pc;

    // Expose flush so jv32_top can suppress stale TCM SRAM responses
    assign imem_flush = rvc_flush;

    // fencei_iflush: 1 on the cycle fence.i fires its pipeline redirect.
    // Used by jv32_top to gate the next SRAM I-fetch response (which was issued
    // before the preceding store committed).  Only applies to fence.i — not to
    // normal branches/JALR — so no performance penalty on other redirects.
    assign fencei_iflush = if_ex_r.valid && dec_is_fence_i && !ex_stall && !load_use_stall;

    // =====================================================================
    // EX->WB Pipeline Register
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_wb_r             <= '0;
            ex_wb_r.valid       <= 1'b0;
            ex_wb_r.pc          <= 32'h0;
            ex_wb_r.orig_instr  <= 32'h0;
            ex_wb_r.rd_addr     <= 5'd0;
            ex_wb_r.reg_we      <= 1'b0;
            ex_wb_r.rd_data     <= 32'h0;
            ex_wb_r.mem_read    <= 1'b0;
            ex_wb_r.mem_write   <= 1'b0;
            ex_wb_r.mem_op      <= MEM_BYTE;
            ex_wb_r.mem_addr    <= 32'h0;
            ex_wb_r.store_data  <= 32'h0;
            ex_wb_r.is_amo      <= 1'b0;
            ex_wb_r.amo_op      <= AMO_ADD;
            ex_wb_r.csr_op      <= 3'b000;
            ex_wb_r.csr_addr    <= 12'h000;
            ex_wb_r.csr_wdata   <= 32'h0;
            ex_wb_r.csr_zimm    <= 5'd0;
            ex_wb_r.exception   <= 1'b0;
            ex_wb_r.exc_cause   <= EXC_INSTR_ADDR_MISALIGNED;
            ex_wb_r.exc_tval    <= 32'h0;
            ex_wb_r.mret        <= 1'b0;
            ex_wb_r.redirect    <= 1'b0;
            ex_wb_r.redirect_pc <= 32'h0;
        end
        else if (dbg_pc_we_i) begin
            ex_wb_r <= '0;
        end
        else if ((halt_req_i && !dbg_halted_r)
                  || trigger_match
                  || (resume_req_i && dbg_halted_r && !dbg_step_served_r && !dbg_resumeack_r)) begin
            // Drop stale WB state across debug entry/exit.
            // Without this, single-step may retire a pre-halt instruction or
            // execute an old redirect (e.g. trap/mret) instead of DPC.
            ex_wb_r <= '0;
        end
        else if (!ex_stall) begin
            if (load_use_stall || !if_ex_r.valid || wb_redirect || dbg_enter_debug || trigger_match) begin
                // inject bubble
                ex_wb_r <= '0;
            end
            else begin
                ex_wb_r.valid       <= if_ex_r.valid;
                ex_wb_r.pc          <= if_ex_r.pc;
                ex_wb_r.orig_instr  <= if_ex_r.orig_instr;
                ex_wb_r.rd_addr     <= dec_rd;
                ex_wb_r.reg_we      <= dec_reg_we && !ex_exception;
                ex_wb_r.rd_data     <= ex_result;
                ex_wb_r.mem_read    <= dec_mem_read && !ex_exception;
                ex_wb_r.mem_write   <= dec_mem_write && !ex_exception;
                ex_wb_r.mem_op      <= dec_mem_op;
                ex_wb_r.mem_addr    <= dec_is_amo ? fwd_rs1 : mem_addr_ex;
                ex_wb_r.store_data  <= store_data_aligned;
                ex_wb_r.is_amo      <= dec_is_amo && !ex_exception;
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
    // WB-stage load data extraction (all accesses are aligned: misaligned
    // accesses raise an exception in EX and never reach here with mem_read=1).
    logic [ 7:0] load_byte;
    logic [15:0] load_half;

    assign load_byte = dmem_resp_data[8*ex_wb_r.mem_addr[1:0]+:8];
    assign load_half = dmem_resp_data[8*ex_wb_r.mem_addr[1:0]+:16];

    always_comb begin
        case (ex_wb_r.mem_op)
            MEM_BYTE:   load_result = {{24{load_byte[7]}}, load_byte};
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
        if (wb_retire && ex_wb_r.reg_we && !irq_cancel && !dmem_fault_active) begin
            rf_we = 1'b1;
            // AMO checked first: decoder sets mem_read=1 for AMO too.
            if (ex_wb_r.is_amo) begin
                if (ex_wb_r.amo_op == AMO_SC) rf_wdata = (lr_valid && (lr_addr == ex_wb_r.mem_addr)) ? 32'd0 : 32'd1;
                else if (ex_wb_r.amo_op == AMO_LR)
                    rf_wdata = load_result;  // LR returns loaded value (amo_load_data never set for LR)
                else rf_wdata = amo_load_data;  // AMO returns old (pre-operation) value
            end
            else if (ex_wb_r.mem_read) begin
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
    // it re-executes after mret - matching software-simulator behaviour.
    // During single-step (dbg_step_pending_r=1), interrupts are suppressed
    // to implement dcsr.stepie=0 (the reset / default value of dcsr.stepie):
    // the Debug Spec says "interrupt enable is cleared while in single step mode".
    assign irq_cancel = csr_irq_pending && ex_wb_r.valid && !dbg_halted_r
                        && !ex_wb_r.exception && !dmem_fault_active
                        && !ex_wb_r.mret && !dbg_step_pending_r;

    // =====================================================================
    // Trace output registers
    // All trace outputs are registered.  trace_en gates the clock enable so
    // that when trace_en=0 the flops never toggle, saving dynamic power.
    // When TRACE_EN=0 at compile time, all trace output flops are removed from
    // synthesis; only trace_valid_r is kept (used for instret and debug single-step).
    // =====================================================================
    logic trace_retire;  // one-cycle retire pulse (combinational, not output)
    assign trace_retire = wb_retire && !ex_wb_r.exception && !dmem_fault_active && !dmem_stall && !irq_cancel;

    logic [31:0] trace_mem_data_c;

    // For AMO: use amo_store_val (the value actually written to memory).
    // For LR specifically: amo_load_data is not used; the loaded value is
    // dmem_resp_data (valid when LR retires with dmem_resp_valid=1).
    assign trace_mem_data_c =
        (ex_wb_r.is_amo && ex_wb_r.amo_op == AMO_LR) ? dmem_resp_data :
        ex_wb_r.is_amo                               ? amo_store_val  :
        ex_wb_r.mem_op == MEM_BYTE ? {24'h0, ex_wb_r.store_data[7:0]} :
        ex_wb_r.mem_op == MEM_HALF ? {16'h0, ex_wb_r.store_data[15:0]} :
                                     ex_wb_r.store_data;

    generate
        if (TRACE_EN) begin : gen_trace_outputs
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    trace_valid_r  <= 1'b0;
                    trace_reg_we   <= 1'b0;
                    trace_mem_we   <= 1'b0;
                    trace_mem_re   <= 1'b0;
                    trace_pc       <= 32'h0;
                    trace_rd       <= 5'h0;
                    trace_rd_data  <= 32'h0;
                    trace_instr    <= 32'h0;
                    trace_mem_addr <= 32'h0;
                    trace_mem_data <= 32'h0;
                end
                else if (trace_en) begin
                    trace_valid_r  <= trace_retire;
                    trace_reg_we   <= trace_retire && ex_wb_r.reg_we && (ex_wb_r.rd_addr != 5'd0);

                    // AMO instructions are logged as memory writes (matching jv32sim which
                    // emits trace_is_store=true for all AMO/LR/SC). The write data is
                    // amo_store_val for non-LR AMO, or the loaded value (dmem_resp_data)
                    // for LR (jv32sim writes the loaded value back and logs it as a store).
                    trace_mem_we   <= trace_retire && (ex_wb_r.mem_write || ex_wb_r.is_amo);
                    trace_mem_re   <= trace_retire && ex_wb_r.mem_read && !ex_wb_r.is_amo;
                    trace_pc       <= ex_wb_r.pc;
                    trace_rd       <= ex_wb_r.rd_addr;
                    trace_rd_data  <= rf_wdata;
                    trace_instr    <= ex_wb_r.orig_instr;
                    trace_mem_addr <= ex_wb_r.mem_addr;
                    trace_mem_data <= trace_mem_data_c;
                end
                else begin
                    // trace_en=0: clear valid/we flags so no spurious events appear;
                    // data registers are not clocked (CE=0) to save power.
                    trace_valid_r <= 1'b0;
                    trace_reg_we  <= 1'b0;
                    trace_mem_we  <= 1'b0;
                    trace_mem_re  <= 1'b0;
                end
            end

            assign trace_valid = trace_valid_r;

            // IRQ-taken trace: fires for one cycle (registered) when the core accepts
            // an interrupt and squashes the instruction currently in WB.
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    trace_irq_taken      <= 1'b0;
                    trace_irq_cause      <= 32'h0;
                    trace_irq_epc        <= 32'h0;
                    trace_irq_store_we   <= 1'b0;
                    trace_irq_store_addr <= 32'h0;
                    trace_irq_store_data <= 32'h0;
                end
                else if (trace_en) begin
                    // Gate on !ex_stall: the CSR only commits the interrupt when
                    // wb_retire=1 (wb_valid=1 in jv32_csr).  If ex_stall=1 (e.g.
                    // sb_valid draining while a DRAM load is in WB), irq_cancel is
                    // asserted one cycle early before the interrupt is accepted.
                    // Without this gate a spurious extra hint fires, causing the
                    // software sim to replay two interrupts for one RTL event.
                    trace_irq_taken      <= irq_cancel && !ex_stall;
                    trace_irq_cause      <= csr_irq_cause;
                    trace_irq_epc        <= ex_wb_r.pc;  // mepc = interrupted PC (return address)

                    // squashed-store: the interrupt fires in the 2nd WB cycle of a
                    // store (dmem_resp_valid=1 means the DRAM write already committed)
                    trace_irq_store_we   <= irq_cancel && !ex_stall && ex_wb_r.mem_write && dmem_resp_valid;
                    trace_irq_store_addr <= ex_wb_r.mem_addr;
                    trace_irq_store_data <= trace_mem_data_c;
                end
                else begin
                    trace_irq_taken    <= 1'b0;
                    trace_irq_store_we <= 1'b0;
                end
            end

        end
        else begin : gen_no_trace

`ifndef SYNTHESIS
            // TRACE_EN=0 but not synthesis: still generate full trace flops so
            // simulation (Verilator) can produce trace logs for compare targets.
            // The `ifndef SYNTHESIS guard means these flops are never seen by
            // the synthesis tool — gate count is unchanged.
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    trace_valid_r  <= 1'b0;
                    trace_reg_we   <= 1'b0;
                    trace_mem_we   <= 1'b0;
                    trace_mem_re   <= 1'b0;
                    trace_pc       <= 32'h0;
                    trace_rd       <= 5'h0;
                    trace_rd_data  <= 32'h0;
                    trace_instr    <= 32'h0;
                    trace_mem_addr <= 32'h0;
                    trace_mem_data <= 32'h0;
                end
                else if (trace_en) begin
                    trace_valid_r  <= trace_retire;
                    trace_reg_we   <= trace_retire && ex_wb_r.reg_we && (ex_wb_r.rd_addr != 5'd0);
                    trace_mem_we   <= trace_retire && (ex_wb_r.mem_write || ex_wb_r.is_amo);
                    trace_mem_re   <= trace_retire && ex_wb_r.mem_read && !ex_wb_r.is_amo;
                    trace_pc       <= ex_wb_r.pc;
                    trace_rd       <= ex_wb_r.rd_addr;
                    trace_rd_data  <= rf_wdata;
                    trace_instr    <= ex_wb_r.orig_instr;
                    trace_mem_addr <= ex_wb_r.mem_addr;
                    trace_mem_data <= trace_mem_data_c;
                end
                else begin
                    trace_valid_r <= 1'b0;
                    trace_reg_we  <= 1'b0;
                    trace_mem_we  <= 1'b0;
                    trace_mem_re  <= 1'b0;
                end
            end

            assign trace_valid = trace_valid_r;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    trace_irq_taken      <= 1'b0;
                    trace_irq_cause      <= 32'h0;
                    trace_irq_epc        <= 32'h0;
                    trace_irq_store_we   <= 1'b0;
                    trace_irq_store_addr <= 32'h0;
                    trace_irq_store_data <= 32'h0;
                end
                else if (trace_en) begin
                    trace_irq_taken      <= irq_cancel && !ex_stall;
                    trace_irq_cause      <= csr_irq_cause;
                    trace_irq_epc        <= ex_wb_r.pc;
                    trace_irq_store_we   <= irq_cancel && !ex_stall && ex_wb_r.mem_write && dmem_resp_valid;
                    trace_irq_store_addr <= ex_wb_r.mem_addr;
                    trace_irq_store_data <= trace_mem_data_c;
                end
                else begin
                    trace_irq_taken    <= 1'b0;
                    trace_irq_store_we <= 1'b0;
                end
            end
`else
            // TRACE_EN=0 in synthesis: keep trace_valid_r for instret/debug-step,
            // tie all trace data outputs to 0 (no extra gate count).
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) trace_valid_r <= 1'b0;
                else trace_valid_r <= trace_retire;
            end

            assign trace_valid          = 1'b0;
            assign trace_reg_we         = 1'b0;
            assign trace_pc             = 32'd0;
            assign trace_rd             = 5'd0;
            assign trace_rd_data        = 32'd0;
            assign trace_instr          = 32'd0;
            assign trace_mem_we         = 1'b0;
            assign trace_mem_re         = 1'b0;
            assign trace_mem_addr       = 32'd0;
            assign trace_mem_data       = 32'd0;
            assign trace_irq_taken      = 1'b0;
            assign trace_irq_cause      = 32'd0;
            assign trace_irq_epc        = 32'd0;
            assign trace_irq_store_we   = 1'b0;
            assign trace_irq_store_addr = 32'd0;
            assign trace_irq_store_data = 32'd0;

            logic _unused_trace_no;
            assign _unused_trace_no = &{1'b0, trace_en, trace_mem_data_c};
`endif

        end
    endgenerate

    // Suppress unused warnings for WFI/fence (treated as NOPs here)
    logic _unused;
    assign _unused = &{1'b0, dec_is_wfi, dec_is_fence,
                       ex_wb_r.csr_op, ex_wb_r.csr_addr, ex_wb_r.csr_wdata, ex_wb_r.csr_zimm,
                       ex_wb_r.redirect, ex_wb_r.redirect_pc};

`ifndef SYNTHESIS
    // =====================================================================
    // Debug trace (simulation only; guarded by DEBUG1 / DEBUG2 macros)
    // =====================================================================
    always_ff @(posedge clk) begin
        // FETCH: instruction latching into IF/EX stage
        if (!ex_stall && !ex_flush && !if_flush && rvc_instr_valid)
            `DEBUG2(`DBG_GRP_FETCH, ("IF  pc=0x%h instr=0x%h", rvc_instr_pc, rvc_instr_data));

        // CORE IF: pc_if advancement trace
        `DEBUG2(`DBG_GRP_FETCH,
                ("[IFT] pc_if=%08x if_stall=%b bp_redir=%b if_flush=%b mr=%b rvc_valid=%b",
            pc_if, if_stall, bp_redirect, if_flush, rvc_mem_ready, rvc_instr_valid));

        // PIPE: pipeline flush events
        if (if_flush) begin
            if (ex_wb_r.valid && ex_wb_r.exception) begin
                `DEBUG1(
                    ("[FLUSH] Exception: cause=%0d pc=0x%h -> mtvec=0x%h", ex_wb_r.exc_cause, ex_wb_r.pc, if_flush_pc));
            end
            else if (ex_wb_r.valid && ex_wb_r.mret) begin
                `DEBUG1(("[FLUSH] MRET -> 0x%h%s", if_flush_pc, csr_tail_chain ? " [tail-chain]" : ""));
            end
            else if (csr_irq_pending) begin
                `DEBUG1(("[FLUSH] IRQ -> 0x%h cause=0x%h", if_flush_pc, csr_irq_cause));
            end
            else begin
                `DEBUG2(`DBG_GRP_EX,
                        ("REDIRECT -> 0x%h (bp_mispred from pc=0x%h bp_taken=%b)",
                    if_flush_pc, if_ex_r.pc, if_ex_r.bp_taken));
            end
        end

        // MEM: data memory request issued (completed, not stalling)
        if (dmem_req_valid && !dmem_stall) begin
            `DEBUG2(`DBG_GRP_MEM,
                    ("%s @ 0x%h data=0x%h strb=%04b",
                dmem_req_write ? "STORE" : "LOAD ",
                dmem_req_addr, dmem_req_wdata, dmem_req_wstrb));
        end

        // PIPE: instruction retired (WB stage)
        if (trace_retire) begin
            `DEBUG2(`DBG_GRP_PIPE, ("WB  pc=0x%h rd=x%-2d data=0x%h", ex_wb_r.pc, ex_wb_r.rd_addr, rf_wdata));
        end
    end
`endif

endmodule
