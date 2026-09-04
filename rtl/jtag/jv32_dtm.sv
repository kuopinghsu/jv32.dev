// ============================================================================
// File        : jv32_dtm.sv
// Project     : JV32 RISC-V Processor
// Description : RISC-V Debug Module (DM) -- pure CLK domain
//
// This module is PURE CLK domain.  All TCK-domain logic (TAP state machine,
// shift registers, DMI register bank) lives in jtag_tap.sv.
//
// The interface to jtag_tap uses toggle-sync pairs:
//   TCK->CLK: toggle input + stable payload input (jtag_tap holds payload)
//   CLK->TCK: result output + valid flag (jtag_tap syncs these into TCK domain)
//
// Reset: rst_n = soc_rst_n, async active-low.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Kuoping Hsu
// ============================================================================

`include "jv32_dbgmsg.svh"

module jv32_dtm #(
    parameter int N_TRIGGERS        = 2,
    // Width of the debug-bus (SBA + abstract-memory) response timeout counter.
    // Old fixed value was 4 bits (~15 cycles) -- far too short for real AXI
    // slaves.  Integrators can widen this for very slow debug targets.
    parameter int DBG_BUS_TIMEOUT_W = 12
) (
    // -- Core clock / reset -------------------------------------------------
    input logic clk,
    input logic rst_n, // soc_rst_n (async active-low)

    // -- TCK->CLK: command dispatch (toggle + stable payload) ----------------
    // jtag_tap holds all payloads stable until the next toggle.
    input logic        cmd_wr_toggle_i,  // Toggles each time a new COMMAND is dispatched
    input logic [31:0] command_reg_i,    // DMI COMMAND register (stable)
    input logic [31:0] data0_i,          // DMI DATA0 register (stable)
    input logic [31:0] data1_i,          // DMI DATA1 register (stable)
    input logic [31:0] progbuf0_i,       // DMI PROGBUF0 (stable)
    input logic [31:0] progbuf1_i,       // DMI PROGBUF1 (stable)
    input logic        dmactive_i,       // DMI DMCONTROL.dmactive (level)
    input logic        haltreq_i,        // DMI DMCONTROL.haltreq (level, TCK domain)
    input logic        resumereq_i,      // DMI DMCONTROL.resumereq (level, TCK domain)
    input logic        hartreset_i,      // DMI DMCONTROL.hartreset (level)
    input logic        ndmreset_i,       // DMI DMCONTROL.ndmreset (level)
    input logic        any_noexist_i,    // No hart selected (level)

    // -- TCK->CLK: SBA triggers + payload ------------------------------------
    input logic        sba_wr_toggle_i,  // Toggles each time SBDATA0 is written
    input logic        sba_rd_toggle_i,  // Toggles for each SBA read trigger
    input logic [31:0] sbaddress0_i,     // SBADDRESS0 (stable, held by jtag_tap)
    input logic [31:0] sbdata0_i,        // SBDATA0 (stable until next write)
    input logic [ 2:0] sb_access_i,      // SBCS.sbaccess (stable)
    input logic        sb_autoincr_i,    // SBCS.sbautoincrement (stable)

    // -- TCK->CLK: W1C clear toggles -----------------------------------------
    input logic       cmderr_clr_tog_i,   // Toggles to clear cmderr bits
    input logic [2:0] cmderr_clr_mask_i,  // Mask of bits to W1C
    input logic       sb_err_clr_tog_i,   // Toggles to clear sb_err bits
    input logic [2:0] sb_err_clr_mask_i,  // Mask of bits to W1C

    // -- TCK->CLK: result-valid clear toggles --------------------------------
    input logic sbdata0_clr_tog_i,     // Toggles to clear sbdata0_result_valid
    input logic sbaddress0_clr_tog_i,  // Toggles to clear sbaddress0_result_valid
    input logic data1_clr_tog_i,       // Toggles to clear data1_result_valid

    // -- CLK->TCK: status outputs (synced by jtag_tap) -----------------------
    output logic        cmd_busy_o,
    output logic        sba_busy_o,
    output logic [ 2:0] cmderr_o,
    output logic [ 2:0] sb_err_o,
    output logic [31:0] data0_result_o,
    output logic        data0_result_valid_o,
    output logic [31:0] data1_result_o,
    output logic        data1_result_valid_o,
    output logic [31:0] sbdata0_clk_o,
    output logic        sbdata0_result_valid_o,
    output logic [31:0] sbaddress0_clk_o,
    output logic        sbaddress0_result_valid_o,

    // -- CPU debug interface (all CLK domain) -------------------------------
    output logic halt_req_o,
    input  logic halted_i,
    output logic resume_req_o,
    input  logic resumeack_i,

    output logic [ 4:0] dbg_reg_addr_o,
    output logic [31:0] dbg_reg_wdata_o,
    output logic        dbg_reg_we_o,
    input  logic [31:0] dbg_reg_rdata_i,
    output logic [11:0] dbg_csr_addr_o,
    output logic [31:0] dbg_csr_wdata_o,
    output logic        dbg_csr_we_o,
    input  logic [31:0] dbg_csr_rdata_i,
    input  logic        dbg_csr_illegal_i,  // 1 = cmd_regno is a CSR the core does not implement

    output logic [31:0] dbg_pc_wdata_o,
    output logic        dbg_pc_we_o,
    input  logic [31:0] dbg_pc_i,

    output logic        dbg_mem_req_o,
    output logic [31:0] dbg_mem_addr_o,
    output logic [ 3:0] dbg_mem_we_o,
    output logic [31:0] dbg_mem_wdata_o,
    input  logic        dbg_mem_ready_i,
    input  logic        dbg_mem_error_i,
    input  logic [31:0] dbg_mem_rdata_i,

    output logic        dbg_ndmreset_o,
    output logic        dbg_hartreset_o,
    output logic        dbg_singlestep_o,
    output logic        dbg_ebreakm_o,
    output logic        dcsr_stopcount_o,  // dcsr[10]: freeze counters during debug halt
    output logic [31:0] progbuf0_o,
    output logic [31:0] progbuf1_o,

    input  logic                        trigger_halt_i,
    input  logic                        ebreak_halt_i,   // ebreak (with ebreakm=1) caused current halt
    input  logic [N_TRIGGERS-1:0]       trigger_hit_i,
    output logic [N_TRIGGERS-1:0][31:0] tdata1_o,
    output logic [N_TRIGGERS-1:0][31:0] tdata2_o
);

    // =========================================================================
    // Constants
    // =========================================================================
    localparam CMD_ACCESS_REG = 8'h00;
    localparam CMD_ACCESS_MEM = 8'h02;

    localparam CMDERR_BUSY       = 3'd1;
    localparam CMDERR_NOTSUP     = 3'd2;
    localparam CMDERR_EXCEPTION  = 3'd3;
    localparam CMDERR_HALTRESUME = 3'd4;
    localparam CMDERR_BUS        = 3'd5;

    // dcsr WARL-writable bits (Debug Spec §3.7.1):
    //   [15]=ebreakm  [11]=stepie  [10]=stopcount  [9]=stoptime  [4]=mprven  [2]=step
    // [1:0]=prv is intentionally excluded: for an M-mode-only implementation prv must
    //   always be 3 (WARL), so writes are ignored and the override below forces 3.
    // All other bits are WIRI, WPRI, or read-only (cause, nmip, ebreaks, ebreaku,
    // reserved).  Applying this mask on write prevents the debugger from storing
    // garbage in reserved fields.
    localparam [31:0] DCSR_WRITE_MASK = 32'h0000_8E14;

    localparam [2:0] SBA_ACCESS8  = 3'd0;
    localparam [2:0] SBA_ACCESS16 = 3'd1;
    localparam [2:0] SBA_ACCESS32 = 3'd2;

    localparam [31:0] DEBUG_ROM_BASE      = 32'h0F80_0000;
    localparam [23:0] EXEC_TIMEOUT_CYCLES = 24'h00_FFFF;

    // =========================================================================
    // Toggle-sync chain inputs (CLK domain)
    // =========================================================================
    // Command dispatch toggle
    (* ASYNC_REG = "TRUE" *)logic [           1:0]       cmd_wr_toggle_sync;
    logic                        cmd_wr_toggle_r;

    // SBA triggers
    (* ASYNC_REG = "TRUE" *)logic [           1:0]       sba_wr_toggle_sync;
    logic                        sba_wr_toggle_r;
    logic                        sba_wr_pending_clk;
    (* ASYNC_REG = "TRUE" *)logic [           1:0]       sba_rd_toggle_sync;
    logic                        sba_rd_toggle_r;
    logic                        sba_rd_pending_clk;

    // W1C clear toggles
    (* ASYNC_REG = "TRUE" *)logic [           1:0]       cmderr_clr_tog_sync;
    logic                        cmderr_clr_tog_r;
    (* ASYNC_REG = "TRUE" *)logic [           1:0]       sb_err_clr_tog_sync;
    logic                        sb_err_clr_tog_r;

    // Result-valid clear toggles
    (* ASYNC_REG = "TRUE" *)logic [           1:0]       sbdata0_clr_toggle_sync;
    logic                        sbdata0_clr_toggle_r;
    (* ASYNC_REG = "TRUE" *)logic [           1:0]       sbaddress0_clr_toggle_sync;
    logic                        sbaddress0_clr_toggle_r;
    (* ASYNC_REG = "TRUE" *)logic [           1:0]       data1_clr_toggle_sync;
    logic                        data1_clr_toggle_r;

    // No payload sync chains needed: payloads are guaranteed stable in TCK domain
    // by the toggle-sync handshake.  Data is latched directly on the toggle edge
    // (safe: by the time toggle_sync[1] propagates, payload has been stable >=4 CLK cycles).

    // dmactive level, synchronised into the CLK domain.  While low, the abstract
    // command / SBA engine is held idle so a dmactive=0 pulse resets DM state
    // (RISC-V Debug Spec).  dcsr/dpc/dscratch/trigger CSRs are hart state and
    // are intentionally left untouched here.
    (* ASYNC_REG = "TRUE" *) logic [1:0] dmactive_sync;
    wire dm_soft_rst = ~dmactive_sync[1];

    // =========================================================================
    // CLK-domain working registers
    // =========================================================================
    logic [          31:0]       command_reg_sys;
    logic [          31:0]       data0_sys;
    logic [          31:0]       data1_sys;
    logic                        command_valid_sys;
    logic [           2:0]       cmderr_sys;
    logic [           2:0]       sb_err;
    logic [          31:0]       data0_result;
    logic                        data0_result_valid;
    logic [          31:0]       data1_result;
    logic                        data1_result_valid;
    logic [           2:0]       sb_access_latched;
    logic                        sb_autoincr_latched;
    logic [          31:0]       sbaddress0_clk;
    logic [          31:0]       sbdata0_clk;
    logic                        sbdata0_result_valid;
    logic                        sbaddress0_result_valid;

    // SBA byte enable / data positioning
    logic [           3:0]       sba_wstrb;
    logic [          31:0]       sba_wdata_positioned;
    logic [          31:0]       sba_rdata_masked;

    // Abstract memory byte enable and data positioning
    logic [           3:0]       mem_wstrb;
    logic [          31:0]       mem_wdata_positioned;

    // =========================================================================
    // Synthetic debug CSRs
    // =========================================================================
    logic [          31:0]       dcsr_reg;
    logic [          31:0]       dscratch0_reg;
    logic [          31:0]       dscratch1_reg;
    logic [          31:0]       dpc_reg;
    logic [           2:0]       dcsr_cause_r;
    logic [          31:0]       tselect_reg;
    logic [N_TRIGGERS-1:0][31:0] tdata1_reg;
    logic [N_TRIGGERS-1:0][31:0] tdata2_reg;
    logic [N_TRIGGERS-1:0]       trigger_hit_latch;

    // Width of the tselect index into the trigger arrays.  $clog2(1)==0, so
    // clamp to 1 to keep the slice legal when N_TRIGGERS==1.  tselect is WARL
    // to [0, N_TRIGGERS), so the index is always in range regardless.
    localparam int TSEL_W = (N_TRIGGERS < 2) ? 1 : $clog2(N_TRIGGERS);
    wire [TSEL_W-1:0] tsel_idx = tselect_reg[TSEL_W-1:0];

    localparam [5:0] HARDWARE_MASKMAX = 6'd0;

    genvar trig_idx;
    generate
        for (trig_idx = 0; trig_idx < N_TRIGGERS; trig_idx++) begin : gen_tdata1_out
            assign tdata1_o[trig_idx] = {tdata1_reg[trig_idx][31:27], HARDWARE_MASKMAX, tdata1_reg[trig_idx][20:0]};
        end
    endgenerate
    assign tdata2_o = tdata2_reg;

    // =========================================================================
    // Abstract command FSM
    // =========================================================================
    typedef enum logic [3:0] {
        CMD_IDLE,
        CMD_REG_READ,
        CMD_REG_WRITE,
        CMD_CSR_READ,
        CMD_CSR_WRITE,
        CMD_MEM_READ,
        CMD_MEM_WRITE,
        CMD_SBA_READ,
        CMD_SBA_WRITE,
        CMD_EXEC,
        CMD_WAIT,
        CMD_DONE
    } cmd_state_t;

    cmd_state_t cmd_state, cmd_state_nx;
    logic [15:0] cmd_regno;
    logic [ 2:0] cmd_size;
    logic        cmd_write;
    logic        cmd_postexec;
    logic        cmd_transfer;
    logic        exec_resume_req;
    logic        exec_waiting_halt;
    logic        exec_seen_running;
    logic [23:0] exec_wait_cnt;
    logic        exec_halt_req;
    logic        exec_fault_halting;
    logic        read_after_exec;
    logic        exec_phase_done;
    logic        mem_req_pending;
    logic [DBG_BUS_TIMEOUT_W-1:0] mem_wait_cnt;
    logic        mem_aarpostincrement_r;
    logic [ 2:0] mem_aamsize_r;
    logic [31:0] mem_addr;
    logic [DBG_BUS_TIMEOUT_W-1:0] sba_wait_cnt;
    logic        cmd_busy;

    wire         cmd_is_access_reg = (command_reg_sys[31:24] == CMD_ACCESS_REG);
    wire         cmd_is_access_mem = (command_reg_sys[31:24] == CMD_ACCESS_MEM);
    wire         mem_write_cmd = command_reg_sys[16];
    wire         mem_aarpostincrement = command_reg_sys[19];

    assign cmd_size     = command_reg_sys[22:20];
    assign cmd_postexec = command_reg_sys[18];
    assign cmd_transfer = command_reg_sys[17];
    assign cmd_write    = command_reg_sys[16];
    assign cmd_regno    = command_reg_sys[15:0];

    // =========================================================================
    // Halt/resume sync (TCK->CLK for haltreq/resumereq level signals)
    // =========================================================================
    (* ASYNC_REG = "TRUE" *)logic [1:0] halt_req_sync_chain;
    (* ASYNC_REG = "TRUE" *)logic [1:0] resume_req_sync_chain;
    logic       dbg_halted_prev;
    logic       dbg_halted_prev_fsm;
    logic       trigger_halt_pulse;

    // Outputs driven by ndmreset/hartreset are directly from TCK-domain inputs
    // (level signals, held stable by TCK-domain FFs)
    assign dbg_ndmreset_o            = ndmreset_i;
    assign dbg_hartreset_o           = hartreset_i;

    assign dbg_singlestep_o          = cmd_busy ? 1'b0 : dcsr_reg[2];
    assign dbg_ebreakm_o             = dcsr_reg[15];
    assign dcsr_stopcount_o          = dcsr_reg[10];
    assign progbuf0_o                = progbuf0_i;
    assign progbuf1_o                = progbuf1_i;

    assign cmd_busy_o                = cmd_busy;
    assign sba_busy_o                = (cmd_state == CMD_SBA_READ) || (cmd_state == CMD_SBA_WRITE);
    assign cmderr_o                  = cmderr_sys;
    assign sb_err_o                  = sb_err;
    assign data0_result_o            = data0_result;
    assign data0_result_valid_o      = data0_result_valid;
    assign data1_result_o            = data1_result;
    assign data1_result_valid_o      = data1_result_valid;
    assign sbdata0_clk_o             = sbdata0_clk;
    assign sbdata0_result_valid_o    = sbdata0_result_valid;
    assign sbaddress0_clk_o          = sbaddress0_clk;
    assign sbaddress0_result_valid_o = sbaddress0_result_valid;

    // =========================================================================
    // halt_req / resume_req logic
    // =========================================================================
    assign halt_req_o                = (cmd_busy || any_noexist_i ? 1'b0 : halt_req_sync_chain[1]) | exec_halt_req;
    assign resume_req_o              = (cmd_busy || any_noexist_i ? 1'b0 : resume_req_sync_chain[1]) | exec_resume_req;

    // =========================================================================
    // SBA byte enable and data positioning (combinational)
    // =========================================================================
    always_comb begin
        sba_wstrb            = 4'b1111;
        sba_wdata_positioned = sbdata0_clk;
        sba_rdata_masked     = dbg_mem_rdata_i;
        case (sb_access_latched)
            SBA_ACCESS8: begin
                case (sbaddress0_clk[1:0])
                    2'b00: begin
                        sba_wstrb            = 4'b0001;
                        sba_wdata_positioned = {24'b0, sbdata0_clk[7:0]};
                        sba_rdata_masked     = {24'b0, dbg_mem_rdata_i[7:0]};
                    end
                    2'b01: begin
                        sba_wstrb            = 4'b0010;
                        sba_wdata_positioned = {16'b0, sbdata0_clk[7:0], 8'b0};
                        sba_rdata_masked     = {24'b0, dbg_mem_rdata_i[15:8]};
                    end
                    2'b10: begin
                        sba_wstrb            = 4'b0100;
                        sba_wdata_positioned = {8'b0, sbdata0_clk[7:0], 16'b0};
                        sba_rdata_masked     = {24'b0, dbg_mem_rdata_i[23:16]};
                    end
                    2'b11: begin
                        sba_wstrb            = 4'b1000;
                        sba_wdata_positioned = {sbdata0_clk[7:0], 24'b0};
                        sba_rdata_masked     = {24'b0, dbg_mem_rdata_i[31:24]};
                    end
                    default: begin
                        sba_wstrb            = 4'b0001;
                        sba_wdata_positioned = {24'b0, sbdata0_clk[7:0]};
                        sba_rdata_masked     = {24'b0, dbg_mem_rdata_i[7:0]};
                    end
                endcase
            end
            SBA_ACCESS16: begin
                if (sbaddress0_clk[1]) begin
                    sba_wstrb            = 4'b1100;
                    sba_wdata_positioned = {sbdata0_clk[15:0], 16'b0};
                    sba_rdata_masked     = {16'b0, dbg_mem_rdata_i[31:16]};
                end
                else begin
                    sba_wstrb            = 4'b0011;
                    sba_wdata_positioned = {16'b0, sbdata0_clk[15:0]};
                    sba_rdata_masked     = {16'b0, dbg_mem_rdata_i[15:0]};
                end
            end
            default: begin  // SBA_ACCESS32
                sba_wstrb            = 4'b1111;
                sba_wdata_positioned = sbdata0_clk;
                sba_rdata_masked     = dbg_mem_rdata_i;
            end
        endcase
    end

    // Abstract memory byte enable and positioning (combinational)
    always_comb begin
        mem_wstrb            = 4'b1111;
        mem_wdata_positioned = data0_sys;
        case (mem_aamsize_r)
            3'd0: begin
                case (mem_addr[1:0])
                    2'b00: begin
                        mem_wstrb            = 4'b0001;
                        mem_wdata_positioned = {24'b0, data0_sys[7:0]};
                    end
                    2'b01: begin
                        mem_wstrb            = 4'b0010;
                        mem_wdata_positioned = {16'b0, data0_sys[7:0], 8'b0};
                    end
                    2'b10: begin
                        mem_wstrb            = 4'b0100;
                        mem_wdata_positioned = {8'b0, data0_sys[7:0], 16'b0};
                    end
                    2'b11: begin
                        mem_wstrb            = 4'b1000;
                        mem_wdata_positioned = {data0_sys[7:0], 24'b0};
                    end
                    default: begin
                        mem_wstrb            = 4'b0001;
                        mem_wdata_positioned = {24'b0, data0_sys[7:0]};
                    end
                endcase
            end
            3'd1: begin
                if (mem_addr[1]) begin
                    mem_wstrb            = 4'b1100;
                    mem_wdata_positioned = {data0_sys[15:0], 16'b0};
                end
                else begin
                    mem_wstrb            = 4'b0011;
                    mem_wdata_positioned = {16'b0, data0_sys[15:0]};
                end
            end
            default: begin
                mem_wstrb            = 4'b1111;
                mem_wdata_positioned = data0_sys;
            end
        endcase
    end

    // =========================================================================
    // Main CLK-domain always_ff
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Toggle-sync state
            dmactive_sync              <= 2'b0;
            cmd_wr_toggle_sync         <= 2'b0;
            cmd_wr_toggle_r            <= 1'b0;
            command_reg_sys            <= 32'b0;
            data0_sys                  <= 32'b0;
            data1_sys                  <= 32'b0;
            command_valid_sys          <= 1'b0;
            sba_wr_toggle_sync         <= 2'b0;
            sba_wr_toggle_r            <= 1'b0;
            sba_wr_pending_clk         <= 1'b0;
            sba_rd_toggle_sync         <= 2'b0;
            sba_rd_toggle_r            <= 1'b0;
            sba_rd_pending_clk         <= 1'b0;
            sba_wait_cnt               <= '0;
            sbdata0_clr_toggle_sync    <= 2'b0;
            sbdata0_clr_toggle_r       <= 1'b0;
            sbaddress0_clr_toggle_sync <= 2'b0;
            sbaddress0_clr_toggle_r    <= 1'b0;
            data1_clr_toggle_sync      <= 2'b0;
            data1_clr_toggle_r         <= 1'b0;
            cmderr_clr_tog_sync        <= 2'b0;
            cmderr_clr_tog_r           <= 1'b0;
            sb_err_clr_tog_sync        <= 2'b0;
            sb_err_clr_tog_r           <= 1'b0;
            sb_access_latched          <= SBA_ACCESS32;
            sb_autoincr_latched        <= 1'b0;
            sbaddress0_clk             <= 32'b0;
            sbdata0_clk                <= 32'b0;
            sbdata0_result_valid       <= 1'b0;
            sbaddress0_result_valid    <= 1'b0;

            // State machine
            cmd_state                  <= CMD_IDLE;
            cmd_busy                   <= 1'b0;
            cmderr_sys                 <= 3'b0;
            sb_err                     <= 3'b0;
            data0_result               <= 32'b0;
            data0_result_valid         <= 1'b0;
            data1_result               <= 32'b0;
            data1_result_valid         <= 1'b0;
            dbg_reg_we_o               <= 1'b0;
            dbg_reg_addr_o             <= '0;
            dbg_reg_wdata_o            <= '0;
            dbg_csr_we_o               <= 1'b0;
            dbg_csr_addr_o             <= '0;
            dbg_csr_wdata_o            <= '0;
            dbg_pc_we_o                <= 1'b0;
            dbg_pc_wdata_o             <= '0;
            dbg_mem_req_o              <= 1'b0;
            dbg_mem_we_o               <= 4'b0;
            dbg_mem_addr_o             <= '0;
            dbg_mem_wdata_o            <= '0;
            exec_resume_req            <= 1'b0;
            exec_waiting_halt          <= 1'b0;
            exec_seen_running          <= 1'b0;
            exec_wait_cnt              <= '0;
            exec_halt_req              <= 1'b0;
            exec_fault_halting         <= 1'b0;
            read_after_exec            <= 1'b0;
            exec_phase_done            <= 1'b0;
            mem_req_pending            <= 1'b0;
            mem_wait_cnt               <= '0;
            mem_aarpostincrement_r     <= 1'b0;
            mem_aamsize_r              <= 3'b0;
            mem_addr                   <= '0;

            // Halt/resume sync
            halt_req_sync_chain        <= 2'b0;
            resume_req_sync_chain      <= 2'b0;
            dbg_halted_prev            <= 1'b0;
            dbg_halted_prev_fsm        <= 1'b0;
            trigger_halt_pulse         <= 1'b0;

            // Synthetic CSRs
            dcsr_reg                   <= 32'h40000003;
            dcsr_cause_r               <= 3'd0;
            dscratch0_reg              <= 32'b0;
            dscratch1_reg              <= 32'b0;
            dpc_reg                    <= 32'h8000_0000;
            tselect_reg                <= 32'b0;
            // All N_TRIGGERS slots reset to type=2 (mcontrol), disabled.
            for (int ti = 0; ti < N_TRIGGERS; ti++) begin
                tdata1_reg[ti] <= 32'h2000_0000;
                tdata2_reg[ti] <= 32'b0;
            end
            trigger_hit_latch          <= '0;
        end
        else begin
            // ----------------------------------------------------------------
            // Synchronizer advances (unconditional)
            // ----------------------------------------------------------------
            dmactive_sync <= {dmactive_sync[0], dmactive_i};

            // Command dispatch
            cmd_wr_toggle_sync <= {cmd_wr_toggle_sync[0], cmd_wr_toggle_i};
            cmd_wr_toggle_r    <= cmd_wr_toggle_sync[1];

            // Payloads (command_reg_i, data0_i, data1_i, sbaddress0_i, sb_access_i,
            // sb_autoincr_i) are held stable in the TCK domain by the toggle-sync handshake.
            // No continuous sync chains needed -- they are latched directly on the toggle edge.

            // SBA write/read toggle syncs
            sba_wr_toggle_sync <= {sba_wr_toggle_sync[0], sba_wr_toggle_i};
            sba_rd_toggle_sync <= {sba_rd_toggle_sync[0], sba_rd_toggle_i};
            sba_wr_toggle_r    <= sba_wr_toggle_sync[1];
            sba_rd_toggle_r    <= sba_rd_toggle_sync[1];
            if (sba_wr_toggle_sync[1] != sba_wr_toggle_r) sba_wr_pending_clk <= 1'b1;
            if (sba_rd_toggle_sync[1] != sba_rd_toggle_r) sba_rd_pending_clk <= 1'b1;

            // W1C clear toggles
            cmderr_clr_tog_sync <= {cmderr_clr_tog_sync[0], cmderr_clr_tog_i};
            cmderr_clr_tog_r    <= cmderr_clr_tog_sync[1];
            if (cmderr_clr_tog_sync[1] != cmderr_clr_tog_r) cmderr_sys <= cmderr_sys & ~cmderr_clr_mask_i;

            sb_err_clr_tog_sync <= {sb_err_clr_tog_sync[0], sb_err_clr_tog_i};
            sb_err_clr_tog_r    <= sb_err_clr_tog_sync[1];
            if (sb_err_clr_tog_sync[1] != sb_err_clr_tog_r) sb_err <= sb_err & ~sb_err_clr_mask_i;

            // Result-valid clear toggles
            sbdata0_clr_toggle_sync    <= {sbdata0_clr_toggle_sync[0], sbdata0_clr_tog_i};
            sbaddress0_clr_toggle_sync <= {sbaddress0_clr_toggle_sync[0], sbaddress0_clr_tog_i};
            data1_clr_toggle_sync      <= {data1_clr_toggle_sync[0], data1_clr_tog_i};
            sbdata0_clr_toggle_r       <= sbdata0_clr_toggle_sync[1];
            sbaddress0_clr_toggle_r    <= sbaddress0_clr_toggle_sync[1];
            data1_clr_toggle_r         <= data1_clr_toggle_sync[1];

            if (sbdata0_clr_toggle_sync[1] != sbdata0_clr_toggle_r &&
                    cmd_state != CMD_SBA_READ && cmd_state != CMD_SBA_WRITE)
                sbdata0_result_valid <= 1'b0;
            if (sbaddress0_clr_toggle_sync[1] != sbaddress0_clr_toggle_r) sbaddress0_result_valid <= 1'b0;
            if (data1_clr_toggle_sync[1] != data1_clr_toggle_r &&
                    cmd_state != CMD_MEM_READ && cmd_state != CMD_MEM_WRITE)
                data1_result_valid <= 1'b0;

            // Halt/resume sync
            halt_req_sync_chain   <= {halt_req_sync_chain[0], haltreq_i};
            resume_req_sync_chain <= {resume_req_sync_chain[0], resumereq_i};
            dbg_halted_prev       <= halted_i;
            trigger_halt_pulse    <= halted_i && !dbg_halted_prev && trigger_halt_i;

            // Trigger hit latch
            if (trigger_halt_pulse) begin
                for (int ti = 0; ti < N_TRIGGERS; ti++)
                    if (trigger_hit_i[ti]) trigger_hit_latch[ti] <= 1'b1;
            end
            if (!halted_i && dbg_halted_prev_fsm) trigger_hit_latch <= '0;

            if (halted_i && !dbg_halted_prev_fsm) begin
                if (!exec_waiting_halt) dpc_reg <= dbg_pc_i;
                // prv records the privilege mode at halt entry (§3.7.1);
                // M-mode-only implementation: prv is always 3.
                dcsr_reg[1:0] <= 2'd3;
                // cause priority: trigger(2) > ebreak(1) > single-step(4) > haltreq(3)
                if (trigger_halt_i) dcsr_cause_r <= 3'd2;
                else if (ebreak_halt_i) dcsr_cause_r <= 3'd1;
                else if (dcsr_reg[2]) dcsr_cause_r <= 3'd4;
                else dcsr_cause_r <= 3'd3;
            end
            dbg_halted_prev_fsm <= halted_i;

            // ----------------------------------------------------------------
            // Command-write toggle edge detection
            // ----------------------------------------------------------------
            if (cmd_wr_toggle_sync[1] != cmd_wr_toggle_r) begin
                command_reg_sys <= command_reg_i;  // stable: held by jtag_tap until next toggle
                data0_sys       <= data0_i;
                data1_sys       <= data1_i;
                // §3.5.1: if cmderr is non-zero, new commands are silently ignored.
                // cmderr is only cleared by the debugger via W1C (cmderr_clr_tog).
                // §3.5.1: if a command is dispatched while busy=1, set cmderr=1 (busy) and ignore.
                if (cmderr_sys != 3'b0) begin
                    command_valid_sys <= 1'b0;  // sticky cmderr: silently ignored
                end
                else if (cmd_busy) begin
                    cmderr_sys        <= CMDERR_BUSY;  // new command while busy
                    command_valid_sys <= 1'b0;
                end
                else begin
                    command_valid_sys <= 1'b1;
                end
                data0_result_valid <= 1'b0;
                data1_result_valid <= 1'b0;
                read_after_exec    <= 1'b0;
                exec_phase_done    <= 1'b0;
            end
            else if (cmd_state == CMD_DONE || (command_valid_sys && cmderr_sys != 3'b0)) begin
                command_valid_sys <= 1'b0;
            end

            // ----------------------------------------------------------------
            // Abstract command FSM
            // ----------------------------------------------------------------
            cmd_state    <= cmd_state_nx;
            dbg_reg_we_o <= 1'b0;
            dbg_csr_we_o <= 1'b0;
            dbg_pc_we_o  <= 1'b0;

            case (cmd_state)
                CMD_IDLE: begin
                    cmd_busy        <= 1'b0;
                    dbg_mem_req_o   <= 1'b0;
                    mem_req_pending <= 1'b0;

                    if (command_valid_sys && !cmd_busy) begin
                        if (any_noexist_i) begin
                            // §3.5.1: selected hart does not exist — not accessible
                            cmderr_sys <= CMDERR_EXCEPTION;
                        end
                        else if (!halted_i) begin
                            cmderr_sys <= CMDERR_HALTRESUME;
                        end
                        else if (cmd_is_access_reg && cmd_transfer) begin
                            if (cmd_size != 3'd2) begin
                                cmderr_sys <= CMDERR_NOTSUP;
                            end
                            else begin
                                cmd_busy <= 1'b1;
                                if (cmd_regno >= 16'h1000 && cmd_regno < 16'h1020) begin
                                    if (cmd_write) begin
                                        cmd_state <= CMD_REG_WRITE;
                                    end
                                    else begin
                                        if (cmd_postexec) begin
                                            read_after_exec <= 1'b1;
                                            dbg_pc_wdata_o  <= DEBUG_ROM_BASE;
                                            dbg_pc_we_o     <= 1'b1;
                                            cmd_state       <= CMD_EXEC;
                                        end
                                        else begin
                                            cmd_state <= CMD_REG_READ;
                                        end
                                    end
                                end
                                else if (cmd_regno == 16'h07b1) begin
                                    if (cmd_write) begin
                                        cmd_state <= CMD_REG_WRITE;
                                    end
                                    else begin
                                        if (cmd_postexec) begin
                                            read_after_exec <= 1'b1;
                                            dbg_pc_wdata_o  <= DEBUG_ROM_BASE;
                                            dbg_pc_we_o     <= 1'b1;
                                            cmd_state       <= CMD_EXEC;
                                        end
                                        else begin
                                            cmd_state <= CMD_REG_READ;
                                        end
                                    end
                                end
                                else if (cmd_regno < 16'h1000) begin
                                    dbg_csr_addr_o <= cmd_regno[11:0];
                                    if (cmd_write) cmd_state <= CMD_CSR_WRITE;
                                    else cmd_state <= CMD_CSR_READ;
                                end
                                else begin
                                    if (!cmd_write) begin
                                        data0_result       <= 32'h0;
                                        data0_result_valid <= 1'b1;
                                    end
                                    cmd_state <= CMD_DONE;
                                end
                            end
                        end
                        else if (cmd_is_access_reg && !cmd_transfer && cmd_postexec) begin
                            cmd_busy       <= 1'b1;
                            dbg_pc_wdata_o <= DEBUG_ROM_BASE;
                            dbg_pc_we_o    <= 1'b1;
                            cmd_state      <= CMD_EXEC;
                        end
                        else if (cmd_is_access_reg && !cmd_transfer && !cmd_postexec) begin
                            // transfer=0 + postexec=0 is a valid no-op (Debug Spec §3.5.1)
                            cmd_state <= CMD_DONE;
                        end
                        else if (cmd_is_access_mem) begin
                            if (command_reg_sys[23] || command_reg_sys[22:20] > 3'd2) begin
                                // §3.5.6: aamvirtual not supported; aamsize>2 (64/128-bit) not supported
                                cmderr_sys <= CMDERR_NOTSUP;
                            end
                            else begin
                                cmd_busy               <= 1'b1;
                                mem_addr               <= data1_sys;
                                mem_aarpostincrement_r <= mem_aarpostincrement;
                                mem_aamsize_r          <= command_reg_sys[22:20];
                                if (mem_write_cmd) cmd_state <= CMD_MEM_WRITE;
                                else cmd_state <= CMD_MEM_READ;
                            end
                        end
                        else begin
                            cmderr_sys <= CMDERR_NOTSUP;
                        end
                    end

                    // SBA handling (independent of abstract command)
                    if (!command_valid_sys || cmd_busy) begin
                        if ((sba_rd_toggle_sync[1] != sba_rd_toggle_r || sba_rd_pending_clk) && !mem_req_pending
                                && (sb_err == 3'b0)) begin  // §3.12.11: no SBA while sberror is set
                            sba_rd_pending_clk <= 1'b0;
                            if (sb_access_i > 3'd2) begin
                                sb_err <= 3'd4;  // §3.12.11: sbaccess value not supported
                            end
                            else begin
                                sbaddress0_clk       <= sbaddress0_i;  // stable: held by jtag_tap
                                sbdata0_result_valid <= 1'b0;
                                sb_access_latched    <= sb_access_i;
                                sb_autoincr_latched  <= sb_autoincr_i;
                                cmd_state            <= CMD_SBA_READ;
                                sba_wait_cnt         <= '0;
                            end
                        end
                        else if ((sba_wr_toggle_sync[1] != sba_wr_toggle_r || sba_wr_pending_clk)
                                  && !mem_req_pending && (sb_err == 3'b0)) begin  // §3.12.11: no SBA while sberror is set
                            sba_wr_pending_clk <= 1'b0;
                            if (sb_access_i > 3'd2) begin
                                sb_err <= 3'd4;  // §3.12.11: sbaccess value not supported
                            end
                            else begin
                                sbaddress0_clk          <= sbaddress0_i;
                                sbdata0_clk             <= sbdata0_i;
                                sbdata0_result_valid    <= 1'b0;
                                sbaddress0_result_valid <= 1'b0;
                                sb_access_latched       <= sb_access_i;
                                sb_autoincr_latched     <= sb_autoincr_i;
                                cmd_state               <= CMD_SBA_WRITE;
                                sba_wait_cnt            <= '0;
                            end
                        end
                    end
                end  // CMD_IDLE

                CMD_REG_READ: begin
                    if (cmd_regno >= 16'h1000 && cmd_regno < 16'h1020) dbg_reg_addr_o <= 5'(cmd_regno - 16'h1000);
                    // cmd_state_nx will go to CMD_WAIT
                end

                CMD_WAIT: begin
                    if (cmd_regno >= 16'h1000 && cmd_regno < 16'h1020) begin
                        data0_result       <= dbg_reg_rdata_i;
                        data0_result_valid <= 1'b1;
                    end
                    else if (cmd_regno == 16'h07b1) begin
                        data0_result       <= dpc_reg;
                        data0_result_valid <= 1'b1;
                    end
                    if (cmd_postexec && !exec_phase_done) begin
                        dbg_pc_wdata_o <= DEBUG_ROM_BASE;
                        dbg_pc_we_o    <= 1'b1;
                    end
                end

                CMD_REG_WRITE: begin
                    if (cmd_regno >= 16'h1000 && cmd_regno < 16'h1020) begin
                        dbg_reg_addr_o  <= 5'(cmd_regno - 16'h1000);
                        dbg_reg_wdata_o <= data0_sys;
                        dbg_reg_we_o    <= 1'b1;
                    end
                    else if (cmd_regno == 16'h07b1) begin
                        dbg_pc_wdata_o <= data0_sys;
                        dbg_pc_we_o    <= 1'b1;
                        dpc_reg        <= data0_sys;
                    end
                    if (cmd_postexec) begin
                        dbg_pc_wdata_o <= DEBUG_ROM_BASE;
                        dbg_pc_we_o    <= 1'b1;
                    end
                end

                CMD_CSR_READ: begin
                    case (cmd_regno)
                        // dcsr §3.7.1: reconstruct with proper WIRI/RO zeroing.
                        // [31:28]=xdebugver=4  [27:16]=0(WIRI)  [15]=ebreakm
                        // [14:12]=0(reserved/no-S/no-U)  [11:9]=stepie/stopcount/stoptime
                        // [8:6]=cause(RO,hw-written)  [5]=0  [4]=mprven  [3]=0(nmip)  [2:0]=step/prv
                        16'h07b0:
                        data0_result <= {
                            4'd4,
                            12'd0,
                            dcsr_reg[15],
                            3'b000,
                            dcsr_reg[11:9],
                            dcsr_cause_r,
                            1'b0,
                            dcsr_reg[4],
                            1'b0,
                            dcsr_reg[2:0]
                        };
                        16'h07b1: data0_result <= dpc_reg;
                        16'h07b2: data0_result <= dscratch0_reg;
                        16'h07b3: data0_result <= dscratch1_reg;
                        16'h07A0: data0_result <= tselect_reg;
                        16'h07A1:
                        data0_result <= {
                            tdata1_reg[tsel_idx][31:27],
                            HARDWARE_MASKMAX,
                            trigger_hit_latch[tsel_idx],
                            tdata1_reg[tsel_idx][19:0]
                        };
                        16'h07A2: data0_result <= tdata2_reg[tsel_idx];
                        16'h07A4: data0_result <= 32'h0000_0004;
                        default: begin
                            // A CSR the core does not implement -> the implied
                            // csrr raises illegal-instruction, so the abstract
                            // command fails with cmderr = 3 (exception).  This
                            // keeps a debugger probing for optional CSRs
                            // (vector, AIA, ...) from being misled by a bogus
                            // "success, value 0".
                            if (dbg_csr_illegal_i && cmderr_sys == 3'b0)
                                cmderr_sys <= CMDERR_EXCEPTION;
                            else
                                data0_result <= dbg_csr_rdata_i;
                        end
                    endcase
                    data0_result_valid <= 1'b1;
                    cmd_state          <= CMD_DONE;
                end

                CMD_CSR_WRITE: begin
                    case (cmd_regno)
                        16'h07b0: begin
                            // Only update the WARL-writable fields; cause[8:6] is
                            // read-only (§3.7.1) — written by hardware on halt, never
                            // by the debugger.  prv is forced to 3 (WARL, M-mode only).
                            dcsr_reg      <= data0_sys & DCSR_WRITE_MASK;
                            dcsr_reg[1:0] <= 2'd3;  // WARL: M-mode-only, prv always 3
                        end
                        16'h07b1: dpc_reg <= data0_sys;
                        16'h07b2: dscratch0_reg <= data0_sys;
                        16'h07b3: dscratch1_reg <= data0_sys;
                        16'h07A0: if (data0_sys < 32'(N_TRIGGERS)) tselect_reg <= data0_sys;
                        16'h07A1: begin
                            // WARL-coerce every mcontrol field to a value JV32
                            // actually implements, so the debugger reads back
                            // only supported behaviour (Debug Spec / Sdtrig):
                            //   type      = 2  (mcontrol, fixed)
                            //   dmode     = kept (M-mode-only core)
                            //   maskmax   = 0  (exact / NAPOT only)
                            //   hit       = reported from trigger_hit_latch
                            //   select    = 0  (address match only, no data value)
                            //   timing    = 0  (fire before the instruction)
                            //   sizelo/hi = 0  (any access size)
                            //   action    = 1  (enter Debug Mode -- the only one)
                            //   chain     = 0  (not implemented)
                            //   match     = 0 or 1 (exact / NAPOT); others -> 0
                            //   m         = kept ; execute/store/load = kept
                            tdata1_reg[tsel_idx] <= {
                                4'd2,                 // [31:28] type
                                data0_sys[27],        // [27]    dmode
                                6'd0,                 // [26:21] maskmax
                                1'b0,                 // [20]    hit
                                1'b0,                 // [19]    select
                                1'b0,                 // [18]    timing
                                2'd0,                 // [17:16] sizelo
                                4'd1,                 // [15:12] action
                                1'b0,                 // [11]    chain
                                (data0_sys[10:7] == 4'd1) ? 4'd1 : 4'd0,  // [10:7] match
                                data0_sys[6],         // [6]     m
                                1'b0,                 // [5]     reserved
                                2'd0,                 // [4:3]   sizehi
                                data0_sys[2:0]        // [2:0]   execute/store/load
                            };
                            // hit (tdata1[20]) is write-0-to-clear only (Debug Spec §5.2.2);
                            // writing 1 has no effect (WARL, set only by hardware trigger).
                            if (!data0_sys[20]) trigger_hit_latch[tsel_idx] <= 1'b0;
                        end
                        16'h07A2: tdata2_reg[tsel_idx] <= data0_sys;
                        default:
                            // Unimplemented CSR write -> illegal instruction ->
                            // abstract command fails with cmderr = 3.
                            if (dbg_csr_illegal_i && cmderr_sys == 3'b0)
                                cmderr_sys <= CMDERR_EXCEPTION;
                    endcase
                    // Only drive the core CSR write strobe for a CSR the core
                    // actually implements.
                    dbg_csr_addr_o  <= cmd_regno[11:0];
                    dbg_csr_wdata_o <= data0_sys;
                    dbg_csr_we_o    <= !dbg_csr_illegal_i;
                    cmd_state       <= CMD_DONE;
                end

                CMD_MEM_READ: begin
                    if (!mem_req_pending) begin
                        dbg_mem_req_o <= 1'b1;
                        dbg_mem_addr_o <= {
                            mem_addr[31:2], 2'b00
                        };  // word-aligned; byte/half extracted from response using mem_addr[1:0]
                        dbg_mem_we_o <= 4'b0;
                        mem_req_pending <= 1'b1;
                        mem_wait_cnt <= '0;
                    end
                    else if (dbg_mem_ready_i) begin
                        if (dbg_mem_error_i) begin
                            cmderr_sys <= CMDERR_EXCEPTION;
                        end
                        else begin
                            data0_result <= (mem_aamsize_r == 3'd0) ?
                                ((mem_addr[1:0] == 2'b00) ? {24'b0, dbg_mem_rdata_i[7:0]}  :
                                 (mem_addr[1:0] == 2'b01) ? {24'b0, dbg_mem_rdata_i[15:8]} :
                                 (mem_addr[1:0] == 2'b10) ? {24'b0, dbg_mem_rdata_i[23:16]}:
                                                             {24'b0, dbg_mem_rdata_i[31:24]}) :
                                (mem_aamsize_r == 3'd1) ?
                                (mem_addr[1] ? {16'b0, dbg_mem_rdata_i[31:16]} :
                                               {16'b0, dbg_mem_rdata_i[15:0]}) :
                                dbg_mem_rdata_i;
                            data0_result_valid <= 1'b1;
                            if (mem_aarpostincrement_r) begin
                                data1_result       <= mem_addr + (32'd1 << mem_aamsize_r);
                                data1_result_valid <= 1'b1;
                            end
                        end
                        dbg_mem_req_o   <= 1'b0;
                        mem_req_pending <= 1'b0;
                        cmd_state       <= CMD_DONE;
                    end
                    else begin
                        mem_wait_cnt <= mem_wait_cnt + 1;
                        if (mem_wait_cnt == {DBG_BUS_TIMEOUT_W{1'b1}}) begin
                            cmderr_sys      <= CMDERR_BUS;
                            dbg_mem_req_o   <= 1'b0;
                            mem_req_pending <= 1'b0;
                            cmd_state       <= CMD_DONE;
                        end
                    end
                end

                CMD_MEM_WRITE: begin
                    if (!mem_req_pending) begin
                        dbg_mem_req_o   <= 1'b1;
                        dbg_mem_addr_o  <= {mem_addr[31:2], 2'b00};
                        dbg_mem_wdata_o <= mem_wdata_positioned;
                        dbg_mem_we_o    <= mem_wstrb;
                        mem_req_pending <= 1'b1;
                        mem_wait_cnt    <= '0;
                    end
                    else if (dbg_mem_ready_i) begin
                        dbg_mem_req_o   <= 1'b0;
                        mem_req_pending <= 1'b0;
                        if (dbg_mem_error_i) begin
                            cmderr_sys <= CMDERR_EXCEPTION;
                        end
                        else if (mem_aarpostincrement_r) begin
                            data1_result       <= mem_addr + (32'd1 << mem_aamsize_r);
                            data1_result_valid <= 1'b1;
                        end
                        cmd_state <= CMD_DONE;
                    end
                    else begin
                        mem_wait_cnt <= mem_wait_cnt + 1;
                        if (mem_wait_cnt == {DBG_BUS_TIMEOUT_W{1'b1}}) begin
                            cmderr_sys      <= CMDERR_BUS;
                            dbg_mem_req_o   <= 1'b0;
                            mem_req_pending <= 1'b0;
                            cmd_state       <= CMD_DONE;
                        end
                    end
                end

                CMD_SBA_READ: begin
                    if (!mem_req_pending) begin
                        dbg_mem_req_o           <= 1'b1;
                        dbg_mem_addr_o          <= {sbaddress0_clk[31:2], 2'b00};
                        dbg_mem_we_o            <= 4'b0;
                        mem_req_pending         <= 1'b1;
                        sba_wait_cnt            <= '0;
                        sbaddress0_result_valid <= 1'b0;
                    end
                    else if (dbg_mem_ready_i) begin
                        dbg_mem_req_o   <= 1'b0;
                        mem_req_pending <= 1'b0;
                        if (dbg_mem_error_i) begin
                            sb_err    <= 3'd2;  // bad address / bus error (Debug Spec §3.12.11)
                            cmd_state <= CMD_IDLE;
                        end
                        else begin
                            sbdata0_clk          <= sba_rdata_masked;
                            sbdata0_result_valid <= 1'b1;
                            if (sb_access_latched == SBA_ACCESS32 && sb_autoincr_latched) begin
                                sbaddress0_clk          <= sbaddress0_clk + 32'd4;
                                sbaddress0_result_valid <= 1'b1;
                            end
                            else if (sb_access_latched == SBA_ACCESS16 && sb_autoincr_latched) begin
                                sbaddress0_clk          <= sbaddress0_clk + 32'd2;
                                sbaddress0_result_valid <= 1'b1;
                            end
                            else if (sb_access_latched == SBA_ACCESS8 && sb_autoincr_latched) begin
                                sbaddress0_clk          <= sbaddress0_clk + 32'd1;
                                sbaddress0_result_valid <= 1'b1;
                            end
                            else begin
                                sbaddress0_result_valid <= 1'b0;
                            end
                            cmd_state <= CMD_IDLE;
                        end
                    end
                    else begin
                        sba_wait_cnt <= sba_wait_cnt + 1;
                        if (sba_wait_cnt == {DBG_BUS_TIMEOUT_W{1'b1}}) begin
                            sb_err          <= 3'd1;  // timeout (Debug Spec §3.12.11)
                            dbg_mem_req_o   <= 1'b0;
                            mem_req_pending <= 1'b0;
                            cmd_state       <= CMD_IDLE;
                        end
                    end
                end

                CMD_SBA_WRITE: begin
                    if (!mem_req_pending) begin
                        dbg_mem_req_o   <= 1'b1;
                        dbg_mem_addr_o  <= {sbaddress0_clk[31:2], 2'b00};
                        dbg_mem_wdata_o <= sba_wdata_positioned;
                        dbg_mem_we_o    <= sba_wstrb;
                        mem_req_pending <= 1'b1;
                        sba_wait_cnt    <= '0;
                    end
                    else if (dbg_mem_ready_i) begin
                        dbg_mem_req_o   <= 1'b0;
                        mem_req_pending <= 1'b0;
                        if (dbg_mem_error_i) begin
                            sb_err    <= 3'd2;  // bad address / bus error (Debug Spec §3.12.11)
                            cmd_state <= CMD_IDLE;
                        end
                        else begin
                            if (sb_access_latched == SBA_ACCESS8 && sb_autoincr_latched) begin
                                sbaddress0_clk          <= sbaddress0_clk + 32'd1;
                                sbaddress0_result_valid <= 1'b1;
                            end
                            else if (sb_access_latched == SBA_ACCESS16 && sb_autoincr_latched) begin
                                sbaddress0_clk          <= sbaddress0_clk + 32'd2;
                                sbaddress0_result_valid <= 1'b1;
                            end
                            else if (sb_access_latched == SBA_ACCESS32 && sb_autoincr_latched) begin
                                sbaddress0_clk          <= sbaddress0_clk + 32'd4;
                                sbaddress0_result_valid <= 1'b1;
                            end
                            else begin
                                sbaddress0_result_valid <= 1'b0;
                            end
                            cmd_state <= CMD_IDLE;
                        end
                    end
                    else begin
                        sba_wait_cnt <= sba_wait_cnt + 1;
                        if (sba_wait_cnt == {DBG_BUS_TIMEOUT_W{1'b1}}) begin
                            sb_err          <= 3'd1;  // timeout (Debug Spec §3.12.11)
                            dbg_mem_req_o   <= 1'b0;
                            mem_req_pending <= 1'b0;
                            cmd_state       <= CMD_IDLE;
                        end
                    end
                end

                CMD_EXEC: begin
                    if (!exec_waiting_halt) begin
                        exec_resume_req    <= 1'b1;
                        exec_waiting_halt  <= 1'b1;
                        exec_seen_running  <= 1'b0;
                        exec_wait_cnt      <= '0;
                        exec_fault_halting <= 1'b0;
                        exec_halt_req      <= 1'b0;
                    end
                    else if (exec_fault_halting) begin
                        exec_resume_req <= 1'b0;
                        if (halted_i) begin
                            exec_halt_req      <= 1'b0;
                            exec_fault_halting <= 1'b0;
                            exec_waiting_halt  <= 1'b0;
                            read_after_exec    <= 1'b0;
                            cmd_state          <= CMD_DONE;
                        end
                    end
                    else begin
                        exec_resume_req <= 1'b0;
                        if (!halted_i) exec_seen_running <= 1'b1;
                        if (halted_i && exec_seen_running) begin
                            exec_waiting_halt <= 1'b0;
                            if (read_after_exec) begin
                                read_after_exec <= 1'b0;
                                exec_phase_done <= 1'b1;
                                cmd_state       <= CMD_REG_READ;
                            end
                            else begin
                                cmd_state <= CMD_DONE;
                            end
                        end
                        else begin
                            exec_wait_cnt <= exec_wait_cnt + 24'd1;
                            if (exec_wait_cnt == EXEC_TIMEOUT_CYCLES) begin
                                cmderr_sys         <= CMDERR_EXCEPTION;
                                exec_fault_halting <= 1'b1;
                                exec_halt_req      <= 1'b1;
                            end
                        end
                    end
                end

                CMD_DONE: begin
                    cmd_busy        <= 1'b0;
                    exec_phase_done <= 1'b0;
                    dbg_pc_we_o     <= 1'b1;
                    dbg_pc_wdata_o  <= dpc_reg;
                    cmd_state       <= CMD_IDLE;
                end

                default: cmd_state <= CMD_IDLE;
            endcase

            // ----------------------------------------------------------------
            // dmactive = 0 : hold the abstract-command / SBA engine and all
            // DM-owned status at reset values (RISC-V Debug Spec).  Overrides
            // the FSM above.  Hart state (dcsr/dpc/dscratch, tselect/tdataN)
            // is deliberately preserved -- it follows hart reset, not DM reset.
            // ----------------------------------------------------------------
            if (dm_soft_rst) begin
                cmd_state               <= CMD_IDLE;
                cmd_busy                <= 1'b0;
                command_valid_sys       <= 1'b0;
                cmderr_sys              <= 3'b0;
                sb_err                  <= 3'b0;
                data0_result_valid      <= 1'b0;
                data1_result_valid      <= 1'b0;
                sbdata0_result_valid    <= 1'b0;
                sbaddress0_result_valid <= 1'b0;
                sba_wr_pending_clk      <= 1'b0;
                sba_rd_pending_clk      <= 1'b0;
                mem_req_pending         <= 1'b0;
                dbg_mem_req_o           <= 1'b0;
                dbg_reg_we_o            <= 1'b0;
                dbg_csr_we_o            <= 1'b0;
                exec_resume_req         <= 1'b0;
                exec_halt_req           <= 1'b0;
                exec_waiting_halt       <= 1'b0;
                exec_phase_done         <= 1'b0;
                read_after_exec         <= 1'b0;
                sb_access_latched       <= SBA_ACCESS32;
                sb_autoincr_latched     <= 1'b0;
                // The dispatch-toggle shadow regs (cmd_wr_toggle_r etc.) are
                // NOT reset: the TCK side keeps its toggles across a dmactive=0
                // window, so letting the shadows track them naturally keeps the
                // handshake in sync.  Any stale edge that slips through while
                // dm_soft_rst is asserted is harmless -- command_valid_sys is
                // forced to 0 here and cmd_state is held at CMD_IDLE.
            end
        end
    end  // always_ff

    // =========================================================================
    // Command state machine next-state logic
    // =========================================================================
    always_comb begin
        cmd_state_nx = cmd_state;
        case (cmd_state)
            CMD_IDLE: cmd_state_nx = cmd_state;
            CMD_REG_READ: cmd_state_nx = CMD_WAIT;
            CMD_WAIT: cmd_state_nx = (cmd_postexec && !exec_phase_done) ? CMD_EXEC : CMD_DONE;
            CMD_REG_WRITE: cmd_state_nx = cmd_postexec ? CMD_EXEC : CMD_DONE;
            CMD_CSR_READ, CMD_CSR_WRITE: cmd_state_nx = CMD_DONE;
            CMD_MEM_READ, CMD_MEM_WRITE, CMD_SBA_READ, CMD_SBA_WRITE, CMD_EXEC: cmd_state_nx = cmd_state;
            CMD_DONE: cmd_state_nx = CMD_IDLE;
            default: cmd_state_nx = CMD_IDLE;
        endcase
    end

    // =========================================================================
    // Bundled-data CDC checks (JTAG_DEBUG_TODO P2 s6)
    // -------------------------------------------------------------------------
    // The TCK->CLK dispatch handshakes are bundled-data: jtag_tap toggles a
    // single-bit "go" and holds the wide payload stable until the next toggle.
    // These assertions catch any payload that moves while its dispatch toggle
    // is still propagating through the 2-FF synchroniser (i.e. a broken
    // hold on the jtag_tap side).
    // =========================================================================
`ifndef SYNTHESIS
    wire _cmd_disp_edge = (cmd_wr_toggle_sync[1] != cmd_wr_toggle_r);
    wire _sba_wr_edge   = (sba_wr_toggle_sync[1] != sba_wr_toggle_r);
    wire _sba_rd_edge   = (sba_rd_toggle_sync[1] != sba_rd_toggle_r);

    a_cmd_payload_stable: assert property (@(posedge clk) disable iff (!rst_n)
        _cmd_disp_edge |-> $stable(command_reg_i) && $stable(data0_i) && $stable(data1_i))
        else $error("CDC: abstract-command payload changed during dispatch toggle sync");

    a_sba_wr_payload_stable: assert property (@(posedge clk) disable iff (!rst_n)
        _sba_wr_edge |-> $stable(sbaddress0_i) && $stable(sbdata0_i)
                      && $stable(sb_access_i) && $stable(sb_autoincr_i))
        else $error("CDC: SBA write payload changed during dispatch toggle sync");

    a_sba_rd_payload_stable: assert property (@(posedge clk) disable iff (!rst_n)
        _sba_rd_edge |-> $stable(sbaddress0_i) && $stable(sb_access_i) && $stable(sb_autoincr_i))
        else $error("CDC: SBA read payload changed during dispatch toggle sync");

    // W1C clear toggles carry a bundled mask; it must be stable at the edge.
    a_cmderr_clr_mask_stable: assert property (@(posedge clk) disable iff (!rst_n)
        (cmderr_clr_tog_sync[1] != cmderr_clr_tog_r) |-> $stable(cmderr_clr_mask_i))
        else $error("CDC: cmderr W1C mask changed during clear toggle sync");
    a_sberr_clr_mask_stable: assert property (@(posedge clk) disable iff (!rst_n)
        (sb_err_clr_tog_sync[1] != sb_err_clr_tog_r) |-> $stable(sb_err_clr_mask_i))
        else $error("CDC: sberror W1C mask changed during clear toggle sync");

    logic _unused_dtm;
    assign _unused_dtm = &{1'b0, dcsr_reg[31:28],  // xdebugver: stored at reset (=4) but hardcoded in read
        dcsr_reg[27:16],           // reserved WIRI: always 0 after DCSR_WRITE_MASK
        dcsr_reg[14:12],           // reserved/ebreaks/ebreaku: RO-0 (no S/U-mode)
        dcsr_reg[8:6],             // cause shadow: always 0 (cause stored in dcsr_cause_r)
        dcsr_reg[5], dcsr_reg[3],  // reserved, nmip: RO-0
        command_reg_sys[19], dmactive_i, resumeack_i};
`endif

endmodule
