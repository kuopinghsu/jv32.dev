// ============================================================================
// File: jv32_csr.sv
// Project: JV32 RISC-V Processor
// Description: Machine-mode CSRs with CLIC support
//
// Implements M-mode CSRs: mstatus, misa, mie, mtvec, mscratch, mepc, mcause,
// mtval, mip, mcycle[h], minstret[h], mtvt, mnxti, mintstatus, mintthresh,
// plus read-only mvendorid/marchid/mimpid/mhartid.
// ============================================================================

`ifdef SYNTHESIS
import jv32_pkg::*;
`endif

module jv32_csr (
    input  logic        clk,
    input  logic        rst_n,

    // CSR access from EX stage
    input  logic [11:0] csr_addr,
    input  logic [2:0]  csr_op,
    input  logic [31:0] csr_wdata,
    input  logic [4:0]  csr_zimm,
    output logic [31:0] csr_rdata,

    // Exception/MRET (from WB)
    input  logic        exception,
`ifndef SYNTHESIS
    input  exc_cause_e  exception_cause,
`else
    input  logic [4:0]  exception_cause,
`endif
    input  logic [31:0] exception_pc,
    input  logic [31:0] exception_tval,
    input  logic        mret,
    input  logic        wb_valid,         // gate counter increment

    output logic [31:0] mtvec_o,
    output logic [31:0] mepc_o,

    // Interrupts (CLINT-style)
    input  logic        timer_irq,
    input  logic        external_irq,
    input  logic        software_irq,

    // CLIC sideband (from axi_clic)
    input  logic        clic_irq,            // level-triggered interrupt present
    input  logic [7:0]  clic_level,          // interrupt level
    input  logic [7:0]  clic_prio,           // interrupt priority
    input  logic [4:0]  clic_id,             // winning IRQ index (0..NUM_IRQ-1)
    output logic        clic_ack,            // accepted CLIC interrupt

    // Tail-chain: asserted on mret when a CLIC IRQ is pending above threshold;
    // core should redirect to tail_chain_pc instead of mepc.
    output logic        tail_chain_o,
    output logic [31:0] tail_chain_pc_o,

    output logic        irq_pending,
    output logic [31:0] irq_cause,
    output logic [31:0] irq_pc,

    // Instruction-retired pulse
    input  logic        instret_inc
);
`ifndef SYNTHESIS
    import jv32_pkg::*;
`endif

    // =====================================================================
    // CSR registers
    // =====================================================================
    // mstatus: MIE(3), MPIE(7), MPP(12:11)=11 always (M-only system)
    logic        mstatus_mie;
    logic        mstatus_mpie;

    logic [31:0] mtvec_reg;    // [1:0]=mode: 0=direct,1=vectored
    logic [31:0] mscratch_reg;
    logic [31:0] mepc_reg;
    logic [31:0] mcause_reg;
    logic [31:0] mtval_reg;
    // mie / mip: bit3=MSIP, bit7=MTIP, bit11=MEIP
    logic [31:0] mie_reg;
    // mip is read-only (reflects live IRQ lines)
    // CLIC CSRs
    logic [31:0] mtvt_reg;
    logic [7:0]  mintthresh_reg; // current interrupt threshold
    logic [7:0]  mintstatus_mil; // current interrupt level (in mintstatus[31:24])

    // Cycle / instret counters (64-bit)
    logic [63:0] mcycle_cnt;
    logic [63:0] minstret_cnt;

    // =====================================================================
    // Write data helper (CSRRW / CSRRS / CSRRC)
    // =====================================================================
    logic [31:0] csr_src;    // effective source: rs1 or zimm-extended
    logic [31:0] wd;         // value to write into CSR

    always_comb begin
        csr_src = (csr_op[2]) ? {27'd0, csr_zimm} : csr_wdata;
        case (csr_op[1:0])
            2'b01: wd = csr_src;                 // CSRRW /CSRRWI
            2'b10: wd = csr_rdata | csr_src;     // CSRRS /CSRRSI
            2'b11: wd = csr_rdata & ~csr_src;    // CSRRC /CSRRCI
            default: wd = csr_rdata;
        endcase
    end

    logic csr_we;
    assign csr_we = (csr_op != 3'b0) &&
                    !((csr_op[1:0] != 2'b01) && (csr_src == 32'd0));

    // =====================================================================
    // MIP (read-only reflection of live interrupts)
    // =====================================================================
    logic [31:0] mip;
    assign mip = {20'd0, external_irq, 3'd0, timer_irq, 3'd0, software_irq, 3'd0};

    // =====================================================================
    // CSR read
    // =====================================================================
    always_comb begin
        csr_rdata = 32'd0;
        case (csr_addr)
            CSR_MSTATUS:   csr_rdata = {19'd0, 2'b11, 3'd0, mstatus_mpie, 3'd0, mstatus_mie, 3'd0};
            CSR_MISA:      csr_rdata = 32'h4000_1105; // RV32IMAC
            CSR_MIE:       csr_rdata = mie_reg;
            CSR_MTVEC:     csr_rdata = mtvec_reg;
            CSR_MSCRATCH:  csr_rdata = mscratch_reg;
            CSR_MEPC:      csr_rdata = mepc_reg;
            CSR_MCAUSE:    csr_rdata = mcause_reg;
            CSR_MTVAL:     csr_rdata = mtval_reg;
            CSR_MIP:       csr_rdata = mip;
            // CLIC
            CSR_MTVT:      csr_rdata = mtvt_reg;
            CSR_MNXTI:     csr_rdata = (clic_irq && (clic_level > mintthresh_reg))
                                       ? (mtvt_reg + {25'd0, clic_id, 2'b00})
                                       : 32'd0;
            CSR_MINTSTATUS:csr_rdata = {mintstatus_mil, 24'd0};
            CSR_MINTTHRESH:csr_rdata = {24'd0, mintthresh_reg};
            // Counters
            CSR_MCYCLE:    csr_rdata = mcycle_cnt[31:0];
            CSR_MCYCLEH:   csr_rdata = mcycle_cnt[63:32];
            CSR_MINSTRET:  csr_rdata = minstret_cnt[31:0];
            CSR_MINSTRETH: csr_rdata = minstret_cnt[63:32];
            CSR_CYCLE:     csr_rdata = mcycle_cnt[31:0];
            CSR_TIME:      csr_rdata = mcycle_cnt[31:0];
            CSR_INSTRET:   csr_rdata = minstret_cnt[31:0];
            CSR_CYCLEH:    csr_rdata = mcycle_cnt[63:32];
            CSR_TIMEH:     csr_rdata = mcycle_cnt[63:32];
            CSR_INSTRETH:  csr_rdata = minstret_cnt[63:32];
            // Machine info (read-only)
            CSR_MVENDORID: csr_rdata = 32'h0;
            CSR_MARCHID:   csr_rdata = 32'h0;
            CSR_MIMPID:    csr_rdata = 32'h1;
            CSR_MHARTID:   csr_rdata = 32'h0;
            default:       csr_rdata = 32'd0;
        endcase
    end

    // =====================================================================
    // CSR write + exception + MRET sequencer
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus_mie   <= 1'b0;
            mstatus_mpie  <= 1'b0;
            mtvec_reg     <= 32'h0;
            mscratch_reg  <= 32'h0;
            mepc_reg      <= 32'h0;
            mcause_reg    <= 32'h0;
            mtval_reg     <= 32'h0;
            mie_reg       <= 32'h0;
            mtvt_reg      <= 32'h0;
            mintthresh_reg<= 8'h0;
            mintstatus_mil<= 8'h0;
            mcycle_cnt    <= 64'h0;
            minstret_cnt  <= 64'h0;
        end else begin
            // ---- performance counters ----
            mcycle_cnt <= mcycle_cnt + 64'd1;
            if (instret_inc) minstret_cnt <= minstret_cnt + 64'd1;

            // ---- exception trap ----
            if (exception) begin
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
                mepc_reg     <= exception_pc & ~32'h1; // clear bit0
                mcause_reg   <= {1'b0, 26'd0, exception_cause};
                mtval_reg    <= exception_tval;
                mintstatus_mil <= 8'h0;
                `DEBUG1(("[TRAP] Exception: cause=%0d pc=0x%h tval=0x%h mie=%b->0",
                    exception_cause, exception_pc, exception_tval, mstatus_mie));
            // ---- interrupt trap ----
            end else if (irq_pending && mstatus_mie) begin
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
                mepc_reg     <= exception_pc;
                mcause_reg   <= irq_cause;
                mtval_reg    <= 32'h0;
                // CLIC: update mintstatus with the level of the accepted interrupt
                if (clic_irq) mintstatus_mil <= clic_level;
                `DEBUG1(("[TRAP] Interrupt: cause=0x%h mepc=0x%h mie=%b->0",
                    irq_cause, exception_pc, mstatus_mie));
                `DEBUG2(`DBG_GRP_IRQ, ("CLIC accepted: id=%0d level=%0d vec=0x%h",
                    clic_id, clic_level, clic_vec_pc));
            // ---- MRET ----
            end else if (mret) begin
                if (clic_irq && (clic_level > mintthresh_reg)) begin
                    // Tail-chain: a CLIC IRQ is pending above threshold.
                    // Skip full context restore; go directly to the next handler.
                    //  - mstatus_mie stays 0  (entering new handler)
                    //  - mstatus_mpie stays 1 (so eventual chain-ending mret re-enables MIE)
                    //  - mepc_reg unchanged    (still the preempted code's return address)
                    mstatus_mpie   <= 1'b1;
                    mcause_reg     <= {1'b1, 31'd11};  // machine external interrupt
                    mintstatus_mil <= clic_level;
                    `DEBUG1(("[MRET] Tail-chain: clic_id=%0d level=%0d vec=0x%h",
                        clic_id, clic_level, clic_vec_pc));
                end else begin
                    // Normal mret: restore interrupt state
                    mstatus_mie    <= mstatus_mpie;
                    mstatus_mpie   <= 1'b1;
                    mintstatus_mil <= 8'h0;
                    `DEBUG1(("[MRET] Return to mepc=0x%h mie=%b->%b",
                        mepc_reg, mstatus_mie, mstatus_mpie));
                end
            // ---- CSR write ----
            end else if (csr_we) begin
                case (csr_addr)
                    CSR_MSTATUS:   begin
                        mstatus_mie  <= wd[3];
                        mstatus_mpie <= wd[7];
                    end
                    CSR_MIE:       mie_reg       <= wd & 32'h0000_0888;
                    CSR_MTVEC:     mtvec_reg     <= {wd[31:2], 1'b0, wd[0]};
                    CSR_MSCRATCH:  mscratch_reg  <= wd;
                    CSR_MEPC:      mepc_reg      <= wd & ~32'h1;
                    CSR_MCAUSE:    mcause_reg    <= wd;
                    CSR_MTVAL:     mtval_reg     <= wd;
                    CSR_MTVT:      mtvt_reg      <= {wd[31:6], 6'd0};
                    CSR_MINTTHRESH:mintthresh_reg <= wd[7:0];
                    // mnxti write side-effect: if a qualifying CLIC IRQ is pending,
                    // atomically claim it (update mcause + mintstatus, re-enable MIE)
                    // so the handler can branch directly to tail_chain_pc_o.
                    CSR_MNXTI: begin
                        if (clic_irq && (clic_level > mintthresh_reg)) begin
                            mcause_reg     <= {1'b1, 31'd11};
                            mintstatus_mil <= clic_level;
                            mstatus_mie    <= 1'b1;  // re-enable for next handler (nesting)
                        end
                    end
                    CSR_MCYCLE:    mcycle_cnt[31:0]   <= wd;
                    CSR_MCYCLEH:   mcycle_cnt[63:32]  <= wd;
                    CSR_MINSTRET:  minstret_cnt[31:0] <= wd;
                    CSR_MINSTRETH: minstret_cnt[63:32]<= wd;
                    default: ;
                endcase
                `DEBUG2(`DBG_GRP_CSR, ("CSR write: addr=0x%h src=0x%h wd=0x%h",
                    csr_addr, csr_src, wd));
            end
        end
    end

    // =====================================================================
    // CLIC vector PC: mtvt base + IRQ index * 4
    // =====================================================================
    logic [31:0] clic_vec_pc;
    assign clic_vec_pc = mtvt_reg + {25'd0, clic_id, 2'b00};

    // Tail-chain: asserted the cycle mret fires if a CLIC IRQ above threshold is pending.
    assign tail_chain_o    = mret && clic_irq && (clic_level > mintthresh_reg);
    assign tail_chain_pc_o = clic_vec_pc;

    // =====================================================================
    // Interrupt priority arbiter (CLINT-style)
    // =====================================================================
    // mie bits: bit3=MSIE, bit7=MTIE, bit11=MEIE
    // CLIC overrides if clic_irq present
    always_comb begin
        irq_pending = 1'b0;
        irq_cause   = 32'h0;
        irq_pc      = 32'h0;
        clic_ack    = 1'b0;

        if (clic_irq && (clic_level > mintthresh_reg) && mstatus_mie) begin
            irq_pending = 1'b1;
            irq_cause   = {1'b1, 31'd11};  // machine external interrupt
            irq_pc      = clic_vec_pc;
            clic_ack    = 1'b1;
        end else if (mstatus_mie) begin
            if ((mip[11] && mie_reg[11])) begin
                irq_pending = 1'b1;
                irq_cause   = {1'b1, 31'd11};
                irq_pc      = (mtvec_reg[0]) ? {mtvec_reg[31:2], 2'b0} + 32'd44 : {mtvec_reg[31:2], 2'b0};
            end else if ((mip[7] && mie_reg[7])) begin
                irq_pending = 1'b1;
                irq_cause   = {1'b1, 31'd7};
                irq_pc      = (mtvec_reg[0]) ? {mtvec_reg[31:2], 2'b0} + 32'd28 : {mtvec_reg[31:2], 2'b0};
            end else if ((mip[3] && mie_reg[3])) begin
                irq_pending = 1'b1;
                irq_cause   = {1'b1, 31'd3};
                irq_pc      = (mtvec_reg[0]) ? {mtvec_reg[31:2], 2'b0} + 32'd12 : {mtvec_reg[31:2], 2'b0};
            end
        end
    end

    assign mtvec_o = mtvec_reg;
    assign mepc_o  = mepc_reg;

    // Suppress unused
    logic _unused; assign _unused = &{1'b0, wb_valid, clic_prio};

endmodule
