// ============================================================================
// File        : jv32_csr.sv
// Project     : JV32 RISC-V Processor
// Description : Machine-mode CSRs with CLIC support
//
// Implements M-mode CSRs: mstatus, misa, mie, mtvec, mscratch, mepc, mcause,
// mtval, mip, mcycle[h], minstret[h], mtvt, mnxti, mintstatus, mintthresh,
// plus read-only mvendorid/marchid/mimpid/mhartid.
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

module jv32_csr #(
    parameter bit RV32E_EN = 1'b0,  // 1=RV32E (E-bit in MISA, I-bit cleared)
    parameter bit RV32M_EN = 1'b1,  // 1=M-extension (M-bit in MISA)
    parameter bit AMO_EN   = 1'b1   // 1=A-extension (A-bit in MISA)
) (
    input logic clk,
    input logic rst_n,

    // CSR access from EX stage
    input  logic [11:0] csr_addr,
    input  logic [ 2:0] csr_op,
    input  logic [31:0] csr_wdata,
    input  logic [ 4:0] csr_zimm,
    output logic [31:0] csr_rdata,

    // Exception/MRET (from WB)
    input logic              exception,
`ifndef SYNTHESIS
    input exc_cause_e        exception_cause,
`else
    input logic       [ 4:0] exception_cause,
`endif
    input logic       [31:0] exception_pc,
    input logic       [31:0] exception_tval,
    input logic              mret,
    input logic              wb_valid,         // gate counter increment

    // PC of the instruction squashed due to interrupt (EX-stage PC).
    // Saved as mepc when taking an interrupt so that the squashed instruction
    // is re-executed after mret, not the already-retired WB instruction.
    input logic [31:0] irq_mepc,

    output logic [31:0] mtvec_o,
    output logic [31:0] mepc_o,

    // Interrupts (CLINT-style)
    input logic timer_irq,
    input logic external_irq,
    input logic software_irq,

    // CLIC sideband (from axi_clic)
    input  logic       clic_irq,    // level-triggered interrupt present
    input  logic [7:0] clic_level,  // interrupt level
    input  logic [7:0] clic_prio,   // interrupt priority
    input  logic [4:0] clic_id,     // winning IRQ index (0..NUM_IRQ-1)
    output logic       clic_ack,    // accepted CLIC interrupt

    // Tail-chain: asserted on mret when a CLIC IRQ is pending above threshold;
    // core should redirect to tail_chain_pc instead of mepc.
    output logic        tail_chain_o,
    output logic [31:0] tail_chain_pc_o,

    output logic        irq_pending,
    output logic [31:0] irq_cause,
    output logic [31:0] irq_pc,

    // Heartbeat: toggles every 2^24 retired instructions (= minstret[24])
    output logic heartbeat_o,

    // Instruction-retired pulse
    input logic instret_inc,

    // mtime from platform timer (for time/timeh CSR shadow)
    input logic [63:0] mtime_i,

    // Debug halt status (from jv32_core dbg_halted_r); used to gate performance
    // counters when dcsr.stopcount=1, per Debug Spec v1.0 §3.7.1.
    input logic dbg_halted_i,

    // Direct debug CSR access path from the DTM (abstract CSR commands).
    // Writes are only committed while halted; reads are combinational.
    input  logic [11:0] dbg_csr_addr_i,
    input  logic [31:0] dbg_csr_wdata_i,
    input  logic        dbg_csr_we_i,
    output logic [31:0] dbg_csr_rdata_o,

    // dcsr.stopcount from the DM's dcsr_reg[10] (jv32_dtm owns the dcsr register;
    // OpenOCD writes it via abstract CSR command, which never touches jv32_csr).
    // When 1, mcycle/minstret freeze while the hart is in Debug Mode.
    input logic dcsr_stopcount_i
);
    import jv32_pkg::*;

    // MISA value derived from compile-time parameters.
    // Bit assignments: [31:30]=MXL(01=RV32), [12]=M, [8]=I, [4]=E, [2]=C, [0]=A
    // E and I are mutually exclusive: E-mode clears I, sets E.
    localparam bit [31:0] MISA_VAL = {
        2'b01,      // [31:30] MXL = 1 (RV32)
        4'b0,       // [29:26]
        13'b0,      // [25:13]
        RV32M_EN,   // [12] M
        3'b0,       // [11:9]
        ~RV32E_EN,  // [8]  I (cleared when E-mode)
        3'b0,       // [7:5]
        RV32E_EN,   // [4]  E
        1'b0,       // [3]
        1'b1,       // [2]  C (always: compressed support is always present)
        1'b0,       // [1]
        AMO_EN      // [0]  A
    };

    // mstatus: MIE(3), MPIE(7), MPP(12:11)=11 always (M-only system)
    logic        mstatus_mie;
    logic        mstatus_mpie;

    logic [31:0] mtvec_reg;  // [1:0]=mode: 0=direct,1=vectored
    logic [31:0] mscratch_reg;
    logic [31:0] mepc_reg;
    logic [31:0] mcause_reg;
    logic [31:0] mtval_reg;
    // mie / mip: bit3=MSIP, bit7=MTIP, bit11=MEIP
    logic [31:0] mie_reg;
    // mip is read-only (reflects live IRQ lines)
    // CLIC CSRs
    logic [31:0] mtvt_reg;
    logic [ 7:0] mintthresh_reg;  // current interrupt threshold
    logic [ 7:0] mintstatus_mil;  // current interrupt level (in mintstatus[31:24])
    logic [31:0] clic_vec_pc;

    // Cycle / instret counters (64-bit)
    logic [63:0] mcycle_cnt;
    logic [63:0] minstret_cnt;
    // mcountinhibit: bit[0]=CY (inhibit mcycle), bit[2]=IR (inhibit minstret)
    logic        mcountinhibit_cy;
    logic        mcountinhibit_ir;

    // dcsr.stopcount is owned by jv32_dtm (dcsr_reg[10]).  It arrives here as
    // dcsr_stopcount_i; no local register needed.

    // Counter next-value computation ─────────────────────────────────────────
    // mcycle_cnt_nxt / minstret_cnt_nxt: combinatorial +1 adder (keep outside
    // always_ff so Yosys does not fold the carry chain into D, which would
    // produce $adff instead of $adffe and block Lighter ICG insertion).
    //
    // mcycle_cnt_en / minstret_cnt_en: UNIFIED enable that covers BOTH the
    // free-running increment path AND the CSR-write override path (e.g. OS
    // zeroing perf counters).  A single enable wire shared by all 64 bits
    // lets Lighter insert ONE CLKGATE_X* cell per counter.
    //
    // Without unification the two 32-bit halves have different enables
    // (CSR_MCYCLE touches [31:0], CSR_MCYCLEH touches [63:32]), so Lighter
    // either gates them separately or skips the register entirely.
    logic [63:0] mcycle_cnt_nxt;
    logic [63:0] minstret_cnt_nxt;
    assign mcycle_cnt_nxt   = mcycle_cnt + 64'd1;
    assign minstret_cnt_nxt = minstret_cnt + 64'd1;

    logic [63:0] mcycle_cnt_d, minstret_cnt_d;
    logic mcycle_cnt_en, minstret_cnt_en;

    // =====================================================================
    // Write data helper (CSRRW / CSRRS / CSRRC)
    // Declared here (before comb_counter_nxt) to satisfy forward-reference rules.
    // =====================================================================
    logic [31:0] csr_src;  // effective source: rs1 or zimm-extended
    logic [31:0] wd;       // value to write into CSR

    always_comb begin
        csr_src = (csr_op[2]) ? {27'd0, csr_zimm} : csr_wdata;
        case (csr_op[1:0])
            2'b01:   wd = csr_src;               // CSRRW /CSRRWI
            2'b10:   wd = csr_rdata | csr_src;   // CSRRS /CSRRSI
            2'b11:   wd = csr_rdata & ~csr_src;  // CSRRC /CSRRCI
            default: wd = csr_rdata;
        endcase
    end

    logic csr_we;
    assign csr_we = (csr_op != 3'b0) && !((csr_op[1:0] != 2'b01) && (csr_src == 32'd0));

    logic        dbg_csr_write;
    logic [11:0] csr_wr_addr_sel;
    logic [31:0] csr_wd_sel;

    assign dbg_csr_write   = dbg_csr_we_i && dbg_halted_i;
    assign csr_wr_addr_sel = dbg_csr_write ? dbg_csr_addr_i : csr_addr;
    assign csr_wd_sel      = dbg_csr_write ? dbg_csr_wdata_i : wd;

    always_comb begin : comb_counter_nxt
        // mcycle: free-running increment; hold when inhibited or debug-frozen.
        mcycle_cnt_en = !mcountinhibit_cy && !(dbg_halted_i && dcsr_stopcount_i);
        mcycle_cnt_d  = mcycle_cnt_en ? mcycle_cnt_nxt : mcycle_cnt;
        // CSR-write override: OR into the enable so the same wire drives all 64
        // bits, then patch only the written 32-bit half in the data path.
        if ((csr_we || dbg_csr_write) && csr_wr_addr_sel == CSR_MCYCLE) begin
            mcycle_cnt_d[31:0] = csr_wd_sel;
            mcycle_cnt_en      = 1'b1;
        end
        if ((csr_we || dbg_csr_write) && csr_wr_addr_sel == CSR_MCYCLEH) begin
            mcycle_cnt_d[63:32] = csr_wd_sel;
            mcycle_cnt_en       = 1'b1;
        end

        // minstret: incremented once per retired instruction.
        minstret_cnt_en = instret_inc && !mcountinhibit_ir && !(dbg_halted_i && dcsr_stopcount_i);
        minstret_cnt_d  = minstret_cnt_en ? minstret_cnt_nxt : minstret_cnt;
        if ((csr_we || dbg_csr_write) && csr_wr_addr_sel == CSR_MINSTRET) begin
            minstret_cnt_d[31:0] = csr_wd_sel;
            minstret_cnt_en      = 1'b1;
        end
        if ((csr_we || dbg_csr_write) && csr_wr_addr_sel == CSR_MINSTRETH) begin
            minstret_cnt_d[63:32] = csr_wd_sel;
            minstret_cnt_en       = 1'b1;
        end
    end

    // =====================================================================
    // MIP (read-only reflection of live interrupts)
    // =====================================================================
    logic [31:0] mip;
    assign mip = {20'd0, external_irq, 3'd0, timer_irq, 3'd0, software_irq, 3'd0};

    // =====================================================================
    // CSR read
    // =====================================================================
    // Forward instret_inc into minstret reads so the EX-stage sees the count
    // including the preceding WB-stage instruction's retirement, matching
    // the software-simulator model.
    logic [63:0] mcycle_cnt_fwd;
    logic [63:0] minstret_cnt_fwd;
    assign mcycle_cnt_fwd   = mcycle_cnt;                           // mcycle: no forwarding needed (counts clocks)
    assign minstret_cnt_fwd = minstret_cnt + {63'h0, instret_inc};  // minstret: forward pending retirement

    always_comb begin
        csr_rdata = 32'd0;
        case (csr_addr)
            CSR_MSTATUS: csr_rdata = {19'd0, 2'b11, 3'd0, mstatus_mpie, 3'd0, mstatus_mie, 3'd0};
            CSR_MSTATUSH: csr_rdata = 32'h0;  // RV32 little-endian M-mode: MBE=0, all bits 0
            CSR_MISA: csr_rdata = MISA_VAL;   // computed from RV32E_EN/RV32M_EN/AMO_EN
            CSR_MIE: csr_rdata = mie_reg;
            CSR_MTVEC: csr_rdata = mtvec_reg;
            CSR_MSCRATCH: csr_rdata = mscratch_reg;
            CSR_MEPC: csr_rdata = mepc_reg;
            CSR_MCAUSE: csr_rdata = mcause_reg;
            CSR_MTVAL: csr_rdata = mtval_reg;
            CSR_MIP: csr_rdata = mip;
            // CLIC
            CSR_MTVT: csr_rdata = mtvt_reg;
            CSR_MNXTI:
            csr_rdata = (clic_irq && (clic_level > mintthresh_reg)) ? (mtvt_reg + {25'd0, clic_id, 2'b00}) : 32'd0;
            CSR_MINTSTATUS: csr_rdata = {mintstatus_mil, 24'd0};
            CSR_MINTTHRESH: csr_rdata = {24'd0, mintthresh_reg};
            // Counters
            // Forward instret_inc so the reading instruction sees the count
            // including the preceding instruction's retirement, matching the
            // software-simulator model where csr_minstret is incremented
            // before the next instruction reads it.
            CSR_MCYCLE: csr_rdata = mcycle_cnt_fwd[31:0];
            CSR_MCYCLEH: csr_rdata = mcycle_cnt_fwd[63:32];
            CSR_MINSTRET: csr_rdata = minstret_cnt_fwd[31:0];
            CSR_MINSTRETH: csr_rdata = minstret_cnt_fwd[63:32];
            CSR_CYCLE: csr_rdata = mcycle_cnt_fwd[31:0];
            CSR_TIME: csr_rdata = mtime_i[31:0];
            CSR_INSTRET: csr_rdata = minstret_cnt_fwd[31:0];
            CSR_CYCLEH: csr_rdata = mcycle_cnt_fwd[63:32];
            CSR_TIMEH: csr_rdata = mtime_i[63:32];
            CSR_INSTRETH: csr_rdata = minstret_cnt_fwd[63:32];
            // Counter inhibit
            CSR_MCOUNTINHIBIT: csr_rdata = {29'd0, mcountinhibit_ir, 1'b0, mcountinhibit_cy};
            // Machine info (read-only)
            CSR_MVENDORID: csr_rdata = 32'h0;
            CSR_MARCHID: csr_rdata = 32'h0;
            CSR_MIMPID: csr_rdata = 32'h1;
            CSR_MHARTID: csr_rdata = 32'h0;
            // Debug CSRs
            // dcsr and dpc are owned by jv32_dtm and handled there via abstract
            // CSR commands (CMD_CSR_READ/WRITE).  No entries needed here.
            default: csr_rdata = 32'd0;
        endcase
    end

    // Debug-side CSR read path used by DTM abstract CSR commands.
    always_comb begin
        dbg_csr_rdata_o = 32'd0;
        case (dbg_csr_addr_i)
            CSR_MSTATUS: dbg_csr_rdata_o = {19'd0, 2'b11, 3'd0, mstatus_mpie, 3'd0, mstatus_mie, 3'd0};
            CSR_MSTATUSH: dbg_csr_rdata_o = 32'h0;
            CSR_MISA: dbg_csr_rdata_o = MISA_VAL;
            CSR_MIE: dbg_csr_rdata_o = mie_reg;
            CSR_MTVEC: dbg_csr_rdata_o = mtvec_reg;
            CSR_MSCRATCH: dbg_csr_rdata_o = mscratch_reg;
            CSR_MEPC: dbg_csr_rdata_o = mepc_reg;
            CSR_MCAUSE: dbg_csr_rdata_o = mcause_reg;
            CSR_MTVAL: dbg_csr_rdata_o = mtval_reg;
            CSR_MIP: dbg_csr_rdata_o = mip;
            CSR_MTVT: dbg_csr_rdata_o = mtvt_reg;
            CSR_MNXTI:
            dbg_csr_rdata_o = (clic_irq && (clic_level > mintthresh_reg)) ? (mtvt_reg + {25'd0, clic_id, 2'b00}) : 32'd0;
            CSR_MINTSTATUS: dbg_csr_rdata_o = {mintstatus_mil, 24'd0};
            CSR_MINTTHRESH: dbg_csr_rdata_o = {24'd0, mintthresh_reg};
            CSR_MCYCLE: dbg_csr_rdata_o = mcycle_cnt_fwd[31:0];
            CSR_MCYCLEH: dbg_csr_rdata_o = mcycle_cnt_fwd[63:32];
            CSR_MINSTRET: dbg_csr_rdata_o = minstret_cnt_fwd[31:0];
            CSR_MINSTRETH: dbg_csr_rdata_o = minstret_cnt_fwd[63:32];
            CSR_CYCLE: dbg_csr_rdata_o = mcycle_cnt_fwd[31:0];
            CSR_TIME: dbg_csr_rdata_o = mtime_i[31:0];
            CSR_INSTRET: dbg_csr_rdata_o = minstret_cnt_fwd[31:0];
            CSR_CYCLEH: dbg_csr_rdata_o = mcycle_cnt_fwd[63:32];
            CSR_TIMEH: dbg_csr_rdata_o = mtime_i[63:32];
            CSR_INSTRETH: dbg_csr_rdata_o = minstret_cnt_fwd[63:32];
            CSR_MCOUNTINHIBIT: dbg_csr_rdata_o = {29'd0, mcountinhibit_ir, 1'b0, mcountinhibit_cy};
            CSR_MVENDORID: dbg_csr_rdata_o = 32'h0;
            CSR_MARCHID: dbg_csr_rdata_o = 32'h0;
            CSR_MIMPID: dbg_csr_rdata_o = 32'h1;
            CSR_MHARTID: dbg_csr_rdata_o = 32'h0;
            default: dbg_csr_rdata_o = 32'd0;
        endcase
    end

    // =====================================================================
    // CSR write + exception + MRET sequencer
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus_mie      <= 1'b0;
            mstatus_mpie     <= 1'b0;
            mtvec_reg        <= 32'h0;
            mscratch_reg     <= 32'h0;
            mepc_reg         <= 32'h0;
            mcause_reg       <= 32'h0;
            mtval_reg        <= 32'h0;
            mie_reg          <= 32'h0;
            mtvt_reg         <= 32'h0;
            mintthresh_reg   <= 8'h0;
            mintstatus_mil   <= 8'h0;
            mcountinhibit_cy <= 1'b0;
            mcountinhibit_ir <= 1'b0;
        end
        else begin
            // ---- exception trap ----
            if (exception) begin
                mstatus_mpie   <= mstatus_mie;
                mstatus_mie    <= 1'b0;
                mepc_reg       <= exception_pc & ~32'h1;  // clear bit0
                mcause_reg     <= {1'b0, 26'd0, exception_cause};
                mtval_reg      <= exception_tval;
                mintstatus_mil <= 8'h0;
                `DEBUG1(
                    ("[TRAP] Exception: cause=%0d pc=0x%h tval=0x%h mie=%b->0",
                    exception_cause, exception_pc, exception_tval, mstatus_mie));
                // ---- interrupt trap ----
                // Only accept interrupt when a valid instruction occupies WB
                // (so irq_mepc = ex_wb_r.pc is the correct return address).
            end
            else if (irq_pending && mstatus_mie && wb_valid) begin
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
                mepc_reg     <= irq_mepc;
                mcause_reg   <= irq_cause;
                mtval_reg    <= 32'h0;
                // CLIC: update mintstatus with the level of the accepted interrupt
                if (clic_irq) mintstatus_mil <= clic_level;
                `DEBUG1(("[TRAP] Interrupt: cause=0x%h mepc=0x%h mie=%b->0", irq_cause, exception_pc, mstatus_mie));
                `DEBUG2(`DBG_GRP_IRQ, ("CLIC accepted: id=%0d level=%0d vec=0x%h", clic_id, clic_level, clic_vec_pc));
                // ---- MRET ----
            end
            else if (mret) begin
                if (clic_irq && (clic_level > mintthresh_reg)) begin
                    // Tail-chain: a CLIC IRQ is pending above threshold.
                    // Skip full context restore; go directly to the next handler.
                    //  - mstatus_mie stays 0  (entering new handler)
                    //  - mstatus_mpie stays 1 (so eventual chain-ending mret re-enables MIE)
                    //  - mepc_reg unchanged    (still the preempted code's return address)
                    mstatus_mpie   <= 1'b1;
                    mcause_reg     <= {1'b1, 31'd11};  // machine external interrupt
                    mintstatus_mil <= clic_level;
                    `DEBUG1(("[MRET] Tail-chain: clic_id=%0d level=%0d vec=0x%h", clic_id, clic_level, clic_vec_pc));
                end
                else begin
                    // Normal mret: restore interrupt state
                    mstatus_mie    <= mstatus_mpie;
                    mstatus_mpie   <= 1'b1;
                    mintstatus_mil <= 8'h0;
                    `DEBUG1(("[MRET] Return to mepc=0x%h mie=%b->%b", mepc_reg, mstatus_mie, mstatus_mpie));
                end
                // ---- CSR write ----
            end
            else if (csr_we || dbg_csr_write) begin
                case (csr_wr_addr_sel)
                    CSR_MSTATUS: begin
                        mstatus_mie  <= csr_wd_sel[3];
                        mstatus_mpie <= csr_wd_sel[7];
                    end
                    CSR_MIE:        mie_reg <= csr_wd_sel & 32'h0000_0888;
                    CSR_MTVEC:      mtvec_reg <= {csr_wd_sel[31:2], 1'b0, csr_wd_sel[0]};
                    CSR_MSCRATCH:   mscratch_reg <= csr_wd_sel;
                    CSR_MEPC:       mepc_reg <= csr_wd_sel & ~32'h1;
                    CSR_MCAUSE:     mcause_reg <= csr_wd_sel;
                    CSR_MTVAL:      mtval_reg <= csr_wd_sel;
                    CSR_MTVT:       mtvt_reg <= {csr_wd_sel[31:6], 6'd0};
                    CSR_MINTTHRESH: mintthresh_reg <= csr_wd_sel[7:0];
                    CSR_MCOUNTINHIBIT: begin
                        mcountinhibit_cy <= csr_wd_sel[0];
                        mcountinhibit_ir <= csr_wd_sel[2];
                    end
                    // dcsr is owned by jv32_dtm; no case needed here.
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
                    default:        ;
                endcase
                `DEBUG2(`DBG_GRP_CSR, ("CSR write: addr=0x%h src=0x%h wd=0x%h", csr_wr_addr_sel, csr_src, csr_wd_sel));
            end
        end
    end

    // =====================================================================
    // Performance counters — dedicated always_ff for clean ICG
    // =====================================================================
    // Separate block so each 64-bit register has ONE shared enable wire
    // (mcycle_cnt_en / minstret_cnt_en computed above in comb_counter_nxt).
    // Lighter inserts a single CLKGATE_X* per counter, covering all 64 bits.
    always_ff @(posedge clk or negedge rst_n) begin : ff_perf_counters
        if (!rst_n) begin
            mcycle_cnt   <= '0;
            minstret_cnt <= '0;
        end
        else begin
            if (mcycle_cnt_en) mcycle_cnt <= mcycle_cnt_d;
            if (minstret_cnt_en) minstret_cnt <= minstret_cnt_d;
        end
    end

    // =====================================================================
    // CLIC vector PC: mtvt base + IRQ index * 4
    // =====================================================================
    assign clic_vec_pc     = mtvt_reg + {25'd0, clic_id, 2'b00};

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
        end
        else if (mstatus_mie) begin
            if ((mip[11] && mie_reg[11])) begin
                irq_pending = 1'b1;
                irq_cause   = {1'b1, 31'd11};
                irq_pc      = (mtvec_reg[0]) ? {mtvec_reg[31:2], 2'b0} + 32'd44 : {mtvec_reg[31:2], 2'b0};
            end
            else if ((mip[7] && mie_reg[7])) begin
                irq_pending = 1'b1;
                irq_cause   = {1'b1, 31'd7};
                irq_pc      = (mtvec_reg[0]) ? {mtvec_reg[31:2], 2'b0} + 32'd28 : {mtvec_reg[31:2], 2'b0};
            end
            else if ((mip[3] && mie_reg[3])) begin
                irq_pending = 1'b1;
                irq_cause   = {1'b1, 31'd3};
                irq_pc      = (mtvec_reg[0]) ? {mtvec_reg[31:2], 2'b0} + 32'd12 : {mtvec_reg[31:2], 2'b0};
            end
        end
    end

    assign mtvec_o     = mtvec_reg;
    assign mepc_o      = mepc_reg;
    assign heartbeat_o = minstret_cnt[24];

    // Suppress unused
    logic _unused;
    assign _unused = &{1'b0, wb_valid, clic_prio};

endmodule
