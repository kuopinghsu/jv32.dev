// ============================================================================
// File        : jtag_tap.sv
// Project     : JV32 RISC-V Processor
// Description : JTAG TAP Controller (IEEE 1149.1) with CDC to/from DTM
//
// Clock domains
// -------------
//  TCK domain : TAP state machine, IR, IDCODE/BYPASS/DTMCS shift registers,
//               DMI shift register, all TCK-clocked DMI register bank.
//               Reset: ntrst_i (async active-low) OR TMS 5-cycle sequence.
//
//  CLK domain : None in this file.  jv32_dtm owns all CLK-domain logic.
//
//  CDC boundary (this file)
//    TCK->CLK : toggle-sync for command dispatch, SBA triggers, W1C clears.
//              Payload held stable in TCK domain until toggle propagates.
//    CLK->TCK : 2-stage synchronisers for result signals (cmderr, data0/1
//              results, SBA data/address results, cmd_busy, sba_busy,
//              halted, resumeack, sb_err).
//              All CDC FFs reset by soc_rst_n (async active-low) so that
//              the CDC boundary is clean even when CLK is absent.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Kuoping Hsu
// ============================================================================

`include "jv32_dbgmsg.svh"

module jtag_tap #(
    parameter bit          [31:0] IDCODE     = 32'h1DEAD3FF,
    parameter int unsigned        IR_LEN     = 5,
    parameter int                 N_TRIGGERS = 2
) (
    // -- JTAG interface (TCK domain) -----------------------------------------
    input  logic tck_i,
    input  logic tms_i,
    input  logic tdi_i,
    output logic tdo_o,
    input  logic ntrst_i, // Optional async JTAG reset (active-low)

    // -- Core clock domain ---------------------------------------------------
    input logic clk,    // Core system clock (feeds jv32_dtm)
    input logic rst_n,  // SoC async reset -- CDC FFs in this module and
                       // all FFs in jv32_dtm reset by this signal

    // -- Debug interface to CPU (all CLK domain, driven through jv32_dtm) ---
    output logic halt_req_o,
    input  logic halted_i,
    output logic resume_req_o,
    input  logic resumeack_i,

    output logic [ 4:0] dbg_reg_addr_o,
    output logic [31:0] dbg_reg_wdata_o,
    output logic        dbg_reg_we_o,
    input  logic [31:0] dbg_reg_rdata_i,

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
    input  logic                        ebreak_halt_i,   // ebreak caused current halt
    input  logic [N_TRIGGERS-1:0]       trigger_hit_i,
    output logic [N_TRIGGERS-1:0][31:0] tdata1_o,
    output logic [N_TRIGGERS-1:0][31:0] tdata2_o
);

    // =========================================================================
    // Instruction opcodes
    // =========================================================================
    localparam logic [IR_LEN-1:0] IR_IDCODE = 5'h01;
    localparam logic [IR_LEN-1:0] IR_DTMCS  = 5'h10;
    localparam logic [IR_LEN-1:0] IR_DMI    = 5'h11;
    localparam logic [IR_LEN-1:0] IR_BYPASS = 5'h1F;

    // =========================================================================
    // TAP state machine -- TCK domain, reset by ntrst_i
    // =========================================================================
    typedef enum logic [3:0] {
        TEST_LOGIC_RESET = 4'h0,
        RUN_TEST_IDLE    = 4'h1,
        SELECT_DR_SCAN   = 4'h2,
        CAPTURE_DR       = 4'h3,
        SHIFT_DR         = 4'h4,
        EXIT1_DR         = 4'h5,
        PAUSE_DR         = 4'h6,
        EXIT2_DR         = 4'h7,
        UPDATE_DR        = 4'h8,
        SELECT_IR_SCAN   = 4'h9,
        CAPTURE_IR       = 4'hA,
        SHIFT_IR         = 4'hB,
        EXIT1_IR         = 4'hC,
        PAUSE_IR         = 4'hD,
        EXIT2_IR         = 4'hE,
        UPDATE_IR        = 4'hF
    } tap_state_t;

    tap_state_t state, state_next;

    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) state <= TEST_LOGIC_RESET;
        else state <= state_next;
    end

    always_comb begin
        case (state)
            TEST_LOGIC_RESET: state_next = tms_i ? TEST_LOGIC_RESET : RUN_TEST_IDLE;
            RUN_TEST_IDLE:    state_next = tms_i ? SELECT_DR_SCAN : RUN_TEST_IDLE;
            SELECT_DR_SCAN:   state_next = tms_i ? SELECT_IR_SCAN : CAPTURE_DR;
            CAPTURE_DR:       state_next = tms_i ? EXIT1_DR : SHIFT_DR;
            SHIFT_DR:         state_next = tms_i ? EXIT1_DR : SHIFT_DR;
            EXIT1_DR:         state_next = tms_i ? UPDATE_DR : PAUSE_DR;
            PAUSE_DR:         state_next = tms_i ? EXIT2_DR : PAUSE_DR;
            EXIT2_DR:         state_next = tms_i ? UPDATE_DR : SHIFT_DR;
            UPDATE_DR:        state_next = tms_i ? SELECT_DR_SCAN : RUN_TEST_IDLE;
            SELECT_IR_SCAN:   state_next = tms_i ? TEST_LOGIC_RESET : CAPTURE_IR;
            CAPTURE_IR:       state_next = tms_i ? EXIT1_IR : SHIFT_IR;
            SHIFT_IR:         state_next = tms_i ? EXIT1_IR : SHIFT_IR;
            EXIT1_IR:         state_next = tms_i ? UPDATE_IR : PAUSE_IR;
            PAUSE_IR:         state_next = tms_i ? EXIT2_IR : PAUSE_IR;
            EXIT2_IR:         state_next = tms_i ? UPDATE_IR : SHIFT_IR;
            UPDATE_IR:        state_next = tms_i ? SELECT_DR_SCAN : RUN_TEST_IDLE;
            default:          state_next = TEST_LOGIC_RESET;
        endcase
    end

    wire               capture_dr = (state == CAPTURE_DR);
    wire               shift_dr = (state == SHIFT_DR);
    wire               update_dr = (state == UPDATE_DR);

    // =========================================================================
    // Instruction Register -- TCK domain
    // =========================================================================
    logic [IR_LEN-1:0] ir_reg;
    logic [IR_LEN-1:0] ir_shift;

    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            ir_reg   <= IR_IDCODE;
            ir_shift <= '0;
        end
        else begin
            case (state)
                TEST_LOGIC_RESET: ir_reg <= IR_IDCODE;
                CAPTURE_IR:       ir_shift <= {ir_reg[IR_LEN-1:2], 2'b01};
                SHIFT_IR:         ir_shift <= {tdi_i, ir_shift[IR_LEN-1:1]};
                UPDATE_IR:        ir_reg <= ir_shift;
                default:          ;
            endcase
        end
    end

    // =========================================================================
    // BYPASS register -- TCK domain
    // =========================================================================
    logic bypass_reg;

    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) bypass_reg <= 1'b0;
        else begin
            case (state)
                CAPTURE_DR: if (ir_reg == IR_BYPASS) bypass_reg <= 1'b0;
                SHIFT_DR: if (ir_reg == IR_BYPASS) bypass_reg <= tdi_i;
                default: ;
            endcase
        end
    end

    // =========================================================================
    // IDCODE shift register -- TCK domain
    // =========================================================================
    logic [31:0] idcode_shift;

    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) idcode_shift <= '0;
        else begin
            case (state)
                CAPTURE_DR: if (ir_reg == IR_IDCODE) idcode_shift <= IDCODE;
                SHIFT_DR: if (ir_reg == IR_IDCODE) idcode_shift <= {tdi_i, idcode_shift[31:1]};
                default: ;
            endcase
        end
    end

    // =========================================================================
    // DTMCS shift register -- TCK domain
    // abits=7, version=1 (DTM 0.13), idle=0, dmistat=0 (constant read-only)
    // =========================================================================
    localparam [31:0] DTMCS_VALUE = {14'b0, 1'b0, 1'b0, 1'b0, 3'd0, 2'b00, 6'd7, 4'd1};

    logic [31:0] dtmcs_shift;

    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) dtmcs_shift <= '0;
        else begin
            case (state)
                CAPTURE_DR: if (ir_reg == IR_DTMCS) dtmcs_shift <= DTMCS_VALUE;
                SHIFT_DR: if (ir_reg == IR_DTMCS) dtmcs_shift <= {tdi_i, dtmcs_shift[31:1]};
                default: ;
            endcase
        end
    end

    // =========================================================================
    // DMI register addresses
    // =========================================================================
    localparam [6:0] DMI_DATA0        = 7'h04;
    localparam [6:0] DMI_DATA1        = 7'h05;
    localparam [6:0] DMI_DMCONTROL    = 7'h10;
    localparam [6:0] DMI_DMSTATUS     = 7'h11;
    localparam [6:0] DMI_HARTINFO     = 7'h12;
    localparam [6:0] DMI_ABSTRACTCS   = 7'h16;
    localparam [6:0] DMI_COMMAND      = 7'h17;
    localparam [6:0] DMI_ABSTRACTAUTO = 7'h18;
    localparam [6:0] DMI_PROGBUF0     = 7'h20;
    localparam [6:0] DMI_PROGBUF1     = 7'h21;
    localparam [6:0] DMI_HALTSUM0     = 7'h40;
    localparam [6:0] DMI_SBCS         = 7'h38;
    localparam [6:0] DMI_SBADDRESS0   = 7'h39;
    localparam [6:0] DMI_SBDATA0      = 7'h3c;

    // Misc constants
    localparam [2:0]  CMDERR_BUSY            = 3'd1;
    localparam [2:0]  SBA_ACCESS32           = 3'd2;
    localparam [6:0]  SBA_ASIZE              = 7'd32;
    localparam [4:0]  ABSTRACTCS_PROGBUFSIZE = 5'd2;
    localparam [3:0]  ABSTRACTCS_DATACOUNT   = 4'd2;
    localparam [31:0] HARTINFO_VALUE         = {8'b0, 4'd2, 3'b0, 1'b0, 4'd1, 12'd0};

    // =========================================================================
    // TCK-domain DMI register bank
    // =========================================================================
    logic haltreq, resumereq, hartreset, ndmreset, dmactive;
    logic [9:0] hartsello;
    logic       havereset_r;
    logic [31:0] data0, data1;
    logic [31:0] progbuf0, progbuf1;
    logic [31:0] command_reg;
    logic [1:0] autoexec_data, autoexec_pbuf;
    logic sb_readonaddr, sb_autoincr, sb_readondata;
    logic [ 2:0] sb_access;
    logic        sb_busyerr;
    logic [31:0] sbaddress0;
    logic [31:0] sbdata0;
    logic [ 6:0] dmi_address;

    // =========================================================================
    // CLK->TCK synchronised status (sync FFs reset by rst_n)
    // =========================================================================
    // cmd_busy
    logic        cmd_busy_clk;  // driven by dtm
    (* ASYNC_REG = "TRUE" *)logic [ 1:0] busy_tck_chain;
    logic        busy_tck;
    logic        cmd_busy_tck_pending;
    logic [ 1:0] cmd_busy_holdoff_tck;

    // sba_busy
    logic        sba_busy_clk;  // driven by dtm
    (* ASYNC_REG = "TRUE" *)logic [ 1:0] sba_busy_tck_chain;
    logic        sba_busy_tck;

    // halted / resumeack
    (* ASYNC_REG = "TRUE" *) logic [1:0] halted_tck_chain, resumeack_tck_chain;
    logic halted_tck, resumeack_tck;

    // cmderr (CLK->TCK)
    logic [2:0] cmderr_clk;  // driven by dtm
    (* ASYNC_REG = "TRUE" *) logic [2:0] cmderr_sync[1:0];
    logic [2:0] cmderr_tck;  // TCK-stable copy

    // sb_err (CLK->TCK)
    logic [2:0] sb_err_clk;  // driven by dtm
    (* ASYNC_REG = "TRUE" *) logic [2:0] sb_err_tck_chain[1:0];
    logic [2:0] sb_err_tck;

    // data0 result
    logic [31:0] data0_result_clk;  // driven by dtm
    logic data0_result_valid_clk;   // driven by dtm
    // data0 requires a 2-stage sync for the 32-bit data because data0 is dual-role:
    // OpenOCD can write it (input) AND dtm can produce a result into it (output).
    // A level-based combinational mux (valid ? sync[1] : data0) is the only correct
    // approach -- edge-detect or continuous-sample both corrupt the input side.
    (* ASYNC_REG = "TRUE" *) logic [31:0] data0_result_sync[1:0];
    (* ASYNC_REG = "TRUE" *) logic data0_result_valid_sync[1:0];

    // data1 result (aampostincrement)
    logic [31:0] data1_result_clk;
    logic data1_result_valid_clk;
    (* ASYNC_REG = "TRUE" *) logic data1_result_valid_sync[1:0];  // 1-bit only
    logic data1_result_valid_sync_r;

    // SBA data result
    logic [31:0] sbdata0_clk;
    logic sbdata0_result_valid_clk;
    (* ASYNC_REG = "TRUE" *) logic sbdata0_result_valid_sync[1:0];  // 1-bit only
    logic sbdata0_result_valid_sync_r;

    // SBA address result (autoincrement)
    logic [31:0] sbaddress0_clk;
    logic sbaddress0_result_valid_clk;
    (* ASYNC_REG = "TRUE" *) logic sbaddress0_result_valid_sync[1:0];  // 1-bit only
    logic sbaddress0_result_valid_sync_r;

    // Derived status (hart existence / halt)
    wire any_noexist = (hartsello != 10'b0);
    wire all_noexist = (hartsello != 10'b0);
    wire any_halted = any_noexist ? 1'b0 : halted_tck;
    wire all_halted = all_noexist ? 1'b0 : halted_tck;
    wire any_running = any_noexist ? 1'b0 : !halted_tck;
    wire all_running = any_noexist ? 1'b0 : !halted_tck;
    wire any_resumeack = any_noexist ? 1'b0 : resumeack_tck;
    wire all_resumeack = any_noexist ? 1'b0 : resumeack_tck;

    // =========================================================================
    // TCK->CLK toggle/payload signals
    // =========================================================================
    logic cmd_wr_toggle_tck;
    logic cmd_wr_toggle_tck_nx;
    logic [2:0] cmderr_clr_tck;
    logic cmderr_clr_tog_tck;
    logic [2:0] sb_err_clr_tck;
    logic sb_err_clr_tog_tck;
    logic sba_wr_toggle_tck;
    logic sba_rd_toggle_tck;
    logic sba_rd_toggle_tck_nx;
    logic sbdata0_clr_toggle_tck;
    logic sbaddress0_clr_toggle_tck;
    logic data1_clr_toggle_tck;
    logic sb_busyerr_nx;

    // =========================================================================
    // DMI register read mux -- combinational
    // =========================================================================
    wire [31:0] dmcontrol_rdata = {1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, hartsello, 10'b0, 4'b0, ndmreset, dmactive};

    wire [31:0] dmstatus_rdata = {
        9'b0,
        1'b1,         // [22] impebreak
        2'b00,
        havereset_r,
        havereset_r,  // all/any_havereset
        all_resumeack,
        any_resumeack,
        all_noexist,
        any_noexist,
        1'b0,
        1'b0,         // allunavail, anyunavail
        all_running,
        any_running,
        all_halted,
        any_halted,
        1'b1,
        1'b0,
        1'b0,
        1'b0,         // authenticated, authbusy, hasresethaltreq, confstrptrvalid
        4'b0010       // version=2
    };

    wire [31:0] abstractcs_rdata = {
        3'b0,
        ABSTRACTCS_PROGBUFSIZE,
        11'b0,
        (busy_tck || cmd_busy_tck_pending),  // [12] busy
        1'b0,
        cmderr_tck,
        4'b0,
        ABSTRACTCS_DATACOUNT
    };

    wire [31:0] haltsum0_rdata = {31'b0, any_halted};

    logic [40:0] dmi_capture_data;
    always_comb begin
        dmi_capture_data = {dmi_address, 32'h0, 2'b00};
        case (dmi_address)
            DMI_DATA0:
            dmi_capture_data = {dmi_address, data0_result_valid_sync[1] ? data0_result_sync[1] : data0, 2'b00};
            DMI_DATA1: dmi_capture_data = {dmi_address, data1, 2'b00};
            DMI_DMCONTROL: dmi_capture_data = {dmi_address, dmcontrol_rdata, 2'b00};
            DMI_DMSTATUS: dmi_capture_data = {dmi_address, dmstatus_rdata, 2'b00};
            DMI_HARTINFO: dmi_capture_data = {dmi_address, HARTINFO_VALUE, 2'b00};
            DMI_ABSTRACTCS: dmi_capture_data = {dmi_address, abstractcs_rdata, 2'b00};
            DMI_COMMAND: dmi_capture_data = {dmi_address, command_reg, 2'b00};
            DMI_PROGBUF0: dmi_capture_data = {dmi_address, progbuf0, 2'b00};
            DMI_PROGBUF1: dmi_capture_data = {dmi_address, progbuf1, 2'b00};
            DMI_ABSTRACTAUTO: dmi_capture_data = {dmi_address, {14'b0, autoexec_pbuf, 14'b0, autoexec_data}, 2'b00};
            DMI_HALTSUM0: dmi_capture_data = {dmi_address, haltsum0_rdata, 2'b00};
            DMI_SBCS:
            dmi_capture_data = {
                dmi_address,
                {
                    3'd1,
                    6'b0,
                    sb_busyerr,
                    sba_busy_tck,
                    sb_readonaddr,
                    sb_access,
                    sb_autoincr,
                    sb_readondata,
                    sb_err_tck,
                    SBA_ASIZE,
                    1'b0,
                    1'b0,
                    1'b1,
                    1'b1,
                    1'b1
                },
                2'b00
            };
            DMI_SBADDRESS0: dmi_capture_data = {dmi_address, sbaddress0, 2'b00};
            DMI_SBDATA0: dmi_capture_data = {dmi_address, sbdata0, 2'b00};
            default: dmi_capture_data = {dmi_address, 32'h0, 2'b00};
        endcase
    end

    // =========================================================================
    // DMI shift register -- TCK domain
    // =========================================================================
    logic [40:0] dmi_shift;

    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) dmi_shift <= '0;
        else begin
            if (capture_dr && ir_reg == IR_DMI) dmi_shift <= dmi_capture_data;
            else if (shift_dr && ir_reg == IR_DMI) dmi_shift <= {tdi_i, dmi_shift[40:1]};
        end
    end

    // =========================================================================
    // cmd_wr_toggle / sba_rd_toggle / sb_busyerr next-value logic -- comb
    // =========================================================================
    always_comb begin
        cmd_wr_toggle_tck_nx = cmd_wr_toggle_tck;
        sb_busyerr_nx        = sb_busyerr;
        sba_rd_toggle_tck_nx = sba_rd_toggle_tck;

        if (capture_dr && ir_reg == IR_DMI) begin
            case (dmi_address)
                DMI_DATA0: if (autoexec_data[0]) cmd_wr_toggle_tck_nx = ~cmd_wr_toggle_tck;
                DMI_DATA1: if (autoexec_data[1]) cmd_wr_toggle_tck_nx = ~cmd_wr_toggle_tck;
                DMI_SBDATA0:
                if (sb_readondata && sb_err_tck == 3'b0) begin
                    if (sba_busy_tck) sb_busyerr_nx = 1'b1;
                    else sba_rd_toggle_tck_nx = ~sba_rd_toggle_tck;
                end
                default:   ;
            endcase
        end
        else if (update_dr && ir_reg == IR_DMI) begin

            if (dmi_shift[1:0] == 2'b10) begin
                case (dmi_shift[40:34])
                    DMI_DATA0: if (!busy_tck && autoexec_data[0]) cmd_wr_toggle_tck_nx = ~cmd_wr_toggle_tck;
                    DMI_DATA1: if (!busy_tck && autoexec_data[1]) cmd_wr_toggle_tck_nx = ~cmd_wr_toggle_tck;
                    DMI_COMMAND:
                    if (!busy_tck && !cmd_busy_tck_pending && dmactive) cmd_wr_toggle_tck_nx = ~cmd_wr_toggle_tck;
                    DMI_PROGBUF0: if (!busy_tck && autoexec_pbuf[0]) cmd_wr_toggle_tck_nx = ~cmd_wr_toggle_tck;
                    DMI_PROGBUF1: if (!busy_tck && autoexec_pbuf[1]) cmd_wr_toggle_tck_nx = ~cmd_wr_toggle_tck;
                    DMI_SBCS: if (dmi_shift[24]) sb_busyerr_nx = 1'b0;
                    DMI_SBDATA0: if (sb_err_tck == 3'b0 && sba_busy_tck) sb_busyerr_nx = 1'b1;
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // Main TCK-domain always_ff
    // Holds: DMI register bank, toggle signals, busy-pending, clear toggles
    // =========================================================================
    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            dmi_address               <= 7'b0;
            haltreq                   <= 1'b0;
            resumereq                 <= 1'b0;
            hartreset                 <= 1'b0;
            ndmreset                  <= 1'b0;
            dmactive                  <= 1'b0;
            hartsello                 <= 10'b0;
            havereset_r               <= 1'b0;
            data0                     <= 32'b0;
            data1                     <= 32'b0;
            progbuf0                  <= 32'h0010_0073;  // EBREAK
            progbuf1                  <= 32'h0010_0073;
            command_reg               <= 32'b0;
            cmderr_tck                <= 3'b0;
            cmderr_clr_tck            <= 3'b0;
            cmderr_clr_tog_tck        <= 1'b0;
            autoexec_data             <= 2'b0;
            autoexec_pbuf             <= 2'b0;
            sb_readonaddr             <= 1'b1;
            sb_access                 <= SBA_ACCESS32;
            sb_autoincr               <= 1'b0;
            sb_readondata             <= 1'b0;
            sb_err_clr_tck            <= 3'b0;
            sb_err_clr_tog_tck        <= 1'b0;
            sbaddress0                <= 32'b0;
            sbdata0                   <= 32'b0;
            sba_wr_toggle_tck         <= 1'b0;
            cmd_wr_toggle_tck         <= 1'b0;
            sba_rd_toggle_tck         <= 1'b0;
            sb_busyerr                <= 1'b0;
            cmd_busy_tck_pending      <= 1'b0;
            cmd_busy_holdoff_tck      <= 2'd0;
            sbdata0_clr_toggle_tck    <= 1'b0;
            sbaddress0_clr_toggle_tck <= 1'b0;
            data1_clr_toggle_tck      <= 1'b0;
        end
        else begin
            // -- Sync cmderr from CLK domain -------------------------------
            cmderr_tck <= cmderr_sync[1];

            // -- CLK->TCK result writebacks ---------------------------------
            // data0 uses the 2-stage sync + level mux (see declaration comment).
            // data1/sbdata0/sbaddress0 use direct latch on valid rising edge:
            // safe because CLK >> TCK and their valid is toggle-cleared (single producer).

            if (data1_result_valid_sync[1] && !data1_result_valid_sync_r) begin
                data1                <= data1_result_clk;
                data1_clr_toggle_tck <= ~data1_clr_toggle_tck;
            end

            if (sbaddress0_result_valid_sync[1] && !sbaddress0_result_valid_sync_r) begin
                sbaddress0                <= sbaddress0_clk;
                sbaddress0_clr_toggle_tck <= ~sbaddress0_clr_toggle_tck;
            end

            if (sbdata0_result_valid_sync[1] && !sbdata0_result_valid_sync_r) begin
                sbdata0                <= sbdata0_clk;
                sbdata0_clr_toggle_tck <= ~sbdata0_clr_toggle_tck;
            end

            // -- Toggle/nx latching ----------------------------------------
            cmd_wr_toggle_tck <= cmd_wr_toggle_tck_nx;
            sb_busyerr        <= sb_busyerr_nx;
            sba_rd_toggle_tck <= sba_rd_toggle_tck_nx;

            // cmd_busy immediate-pending holdoff
            if (cmd_wr_toggle_tck_nx != cmd_wr_toggle_tck) begin
                cmd_busy_tck_pending <= 1'b1;
                cmd_busy_holdoff_tck <= 2'd3;
            end
            else begin
                if (cmd_busy_holdoff_tck != 2'd0) cmd_busy_holdoff_tck <= cmd_busy_holdoff_tck - 2'd1;
                if (cmd_busy_holdoff_tck == 2'd0 && !busy_tck) cmd_busy_tck_pending <= 1'b0;
            end

            // -- DTMCS write handling ---------------------------------------
            if (update_dr && ir_reg == IR_DTMCS && dmi_shift[17]) begin
                // dmihardreset: wipe TCK-domain soft state
                dmi_address   <= 7'b0;
                data0         <= 32'b0;
                data1         <= 32'b0;
                command_reg   <= 32'b0;
                cmderr_tck    <= 3'b0;
                autoexec_data <= 2'b0;
                autoexec_pbuf <= 2'b0;
                sbaddress0    <= 32'b0;
                sbdata0       <= 32'b0;
            end

            // -- UPDATE_DR DMI write processing -----------------------------
            if (update_dr && ir_reg == IR_DMI) begin
                dmi_address <= dmi_shift[40:34];

                if (dmi_shift[1:0] == 2'b10) begin  // Write operation
                    case (dmi_shift[40:34])
                        DMI_DATA0: if (!busy_tck) data0 <= dmi_shift[33:2];
                        DMI_DATA1: if (!busy_tck) data1 <= dmi_shift[33:2];

                        DMI_DMCONTROL: begin
                            dmactive  <= dmi_shift[2];
                            ndmreset  <= dmi_shift[3];
                            haltreq   <= dmi_shift[33];
                            resumereq <= dmi_shift[32];
                            hartreset <= dmi_shift[31];
                            hartsello <= dmi_shift[27:18];
                            if (dmi_shift[31] || dmi_shift[3]) havereset_r <= 1'b1;
                            if (dmi_shift[30]) havereset_r <= 1'b0;  // ackhavereset W1C
                        end

                        DMI_ABSTRACTCS: begin
                            if (dmi_shift[12:10] != 3'b0) begin
                                // W1C cmderr -- also clear local shadow
                                cmderr_tck         <= cmderr_tck & ~dmi_shift[12:10];
                                cmderr_clr_tck     <= dmi_shift[12:10];
                                cmderr_clr_tog_tck <= ~cmderr_clr_tog_tck;
                            end
                        end

                        DMI_COMMAND: begin
                            if (!busy_tck && !cmd_busy_tck_pending && dmactive) command_reg <= dmi_shift[33:2];
                            else if (busy_tck || cmd_busy_tck_pending)
                                if (cmderr_tck == 3'b0) cmderr_tck <= CMDERR_BUSY;
                        end

                        DMI_PROGBUF0: if (!busy_tck) progbuf0 <= dmi_shift[33:2];
                        DMI_PROGBUF1: if (!busy_tck) progbuf1 <= dmi_shift[33:2];

                        DMI_ABSTRACTAUTO: begin
                            autoexec_data <= dmi_shift[3:2];
                            autoexec_pbuf <= dmi_shift[19:18];
                        end

                        DMI_SBCS: begin
                            sb_readonaddr <= dmi_shift[22];
                            sb_access     <= dmi_shift[21:19];
                            sb_autoincr   <= dmi_shift[18];
                            sb_readondata <= dmi_shift[17];
                            if (dmi_shift[16:14] != 3'b0) begin
                                sb_err_clr_tck     <= dmi_shift[16:14];
                                sb_err_clr_tog_tck <= ~sb_err_clr_tog_tck;
                            end
                        end

                        DMI_SBADDRESS0: begin
                            sbaddress0 <= dmi_shift[33:2];
                            // Fire SBA read immediately if sb_readonaddr is set
                            if (sb_readonaddr && sb_err_tck == 3'b0 && !sba_busy_tck)
                                sba_rd_toggle_tck <= ~sba_rd_toggle_tck;
                        end

                        DMI_SBDATA0: begin
                            sbdata0 <= dmi_shift[33:2];
                            if (sb_err_tck == 3'b0 && !sba_busy_tck) sba_wr_toggle_tck <= ~sba_wr_toggle_tck;
                        end

                        default: ;
                    endcase
                end
            end  // update_dr && IR_DMI
        end
    end  // always_ff TCK

    // =========================================================================
    // CLK->TCK synchronisers -- reset by rst_n (core async reset)
    // =========================================================================
    always_ff @(posedge tck_i or negedge rst_n) begin
        if (!rst_n) begin
            busy_tck_chain                  <= 2'b0;
            busy_tck                        <= 1'b0;
            sba_busy_tck_chain              <= 2'b0;
            sba_busy_tck                    <= 1'b0;
            halted_tck_chain                <= 2'b0;
            halted_tck                      <= 1'b0;
            resumeack_tck_chain             <= 2'b0;
            resumeack_tck                   <= 1'b0;
            cmderr_sync[0]                  <= 3'b0;
            cmderr_sync[1]                  <= 3'b0;
            sb_err_tck_chain[0]             <= 3'b0;
            sb_err_tck_chain[1]             <= 3'b0;
            sb_err_tck                      <= 3'b0;
            data0_result_sync[0]            <= 32'b0;
            data0_result_sync[1]            <= 32'b0;
            data0_result_valid_sync[0]      <= 1'b0;
            data0_result_valid_sync[1]      <= 1'b0;
            data1_result_valid_sync[0]      <= 1'b0;
            data1_result_valid_sync[1]      <= 1'b0;
            data1_result_valid_sync_r       <= 1'b0;
            sbdata0_result_valid_sync[0]    <= 1'b0;
            sbdata0_result_valid_sync[1]    <= 1'b0;
            sbdata0_result_valid_sync_r     <= 1'b0;
            sbaddress0_result_valid_sync[0] <= 1'b0;
            sbaddress0_result_valid_sync[1] <= 1'b0;
            sbaddress0_result_valid_sync_r  <= 1'b0;
        end
        else begin
            // cmd_busy and sba_busy
            busy_tck_chain                  <= {busy_tck_chain[0], cmd_busy_clk};
            busy_tck                        <= busy_tck_chain[1];
            sba_busy_tck_chain              <= {sba_busy_tck_chain[0], sba_busy_clk};
            sba_busy_tck                    <= sba_busy_tck_chain[1];

            // halted / resumeack
            halted_tck_chain                <= {halted_tck_chain[0], halted_i};
            halted_tck                      <= halted_tck_chain[1];
            resumeack_tck_chain             <= {resumeack_tck_chain[0], resumeack_i};
            resumeack_tck                   <= resumeack_tck_chain[1];

            // cmderr
            cmderr_sync[0]                  <= cmderr_clk;
            cmderr_sync[1]                  <= cmderr_sync[0];

            // sb_err
            sb_err_tck_chain[0]             <= sb_err_clk;
            sb_err_tck_chain[1]             <= sb_err_tck_chain[0];
            sb_err_tck                      <= sb_err_tck_chain[1];

            // data0 result -- 2-stage sync needed (dual input/output role, level-based mux)
            data0_result_sync[0]            <= data0_result_clk;
            data0_result_sync[1]            <= data0_result_sync[0];
            data0_result_valid_sync[0]      <= data0_result_valid_clk;
            data0_result_valid_sync[1]      <= data0_result_valid_sync[0];

            // data1 result
            data1_result_valid_sync[0]      <= data1_result_valid_clk;
            data1_result_valid_sync[1]      <= data1_result_valid_sync[0];
            data1_result_valid_sync_r       <= data1_result_valid_sync[1];

            // SBA data result
            sbdata0_result_valid_sync[0]    <= sbdata0_result_valid_clk;
            sbdata0_result_valid_sync[1]    <= sbdata0_result_valid_sync[0];
            sbdata0_result_valid_sync_r     <= sbdata0_result_valid_sync[1];

            // SBA address result
            sbaddress0_result_valid_sync[0] <= sbaddress0_result_valid_clk;
            sbaddress0_result_valid_sync[1] <= sbaddress0_result_valid_sync[0];
            sbaddress0_result_valid_sync_r  <= sbaddress0_result_valid_sync[1];
        end
    end

    // =========================================================================
    // jv32_dtm instantiation (CLK domain only, no TCK port)
    // =========================================================================
    jv32_dtm #(
        .N_TRIGGERS(N_TRIGGERS)
    ) u_dtm (
        // Core clock / reset
        .clk  (clk),
        .rst_n(rst_n),

        // -- TCK->CLK: command dispatch (toggle + payload) ------------------
        .cmd_wr_toggle_i(cmd_wr_toggle_tck),
        .command_reg_i  (command_reg),
        .data0_i        (data0),
        .data1_i        (data1),
        .progbuf0_i     (progbuf0),
        .progbuf1_i     (progbuf1),
        .dmactive_i     (dmactive),
        .haltreq_i      (haltreq),
        .resumereq_i    (resumereq),
        .hartreset_i    (hartreset),
        .ndmreset_i     (ndmreset),
        .any_noexist_i  (any_noexist),

        // -- TCK->CLK: SBA triggers + payload ------------------------------
        .sba_wr_toggle_i(sba_wr_toggle_tck),
        .sba_rd_toggle_i(sba_rd_toggle_tck),

        .sbaddress0_i (sbaddress0),
        .sbdata0_i    (sbdata0),
        .sb_access_i  (sb_access),
        .sb_autoincr_i(sb_autoincr),

        // -- TCK->CLK: W1C clear toggles ------------------------------------
        .cmderr_clr_tog_i (cmderr_clr_tog_tck),
        .cmderr_clr_mask_i(cmderr_clr_tck),
        .sb_err_clr_tog_i (sb_err_clr_tog_tck),
        .sb_err_clr_mask_i(sb_err_clr_tck),

        // -- TCK->CLK: result clear toggles ---------------------------------
        .sbdata0_clr_tog_i   (sbdata0_clr_toggle_tck),
        .sbaddress0_clr_tog_i(sbaddress0_clr_toggle_tck),
        .data1_clr_tog_i     (data1_clr_toggle_tck),

        // -- CLK->TCK: status outputs ---------------------------------------
        .cmd_busy_o               (cmd_busy_clk),
        .sba_busy_o               (sba_busy_clk),
        .cmderr_o                 (cmderr_clk),
        .sb_err_o                 (sb_err_clk),
        .data0_result_o           (data0_result_clk),
        .data0_result_valid_o     (data0_result_valid_clk),
        .data1_result_o           (data1_result_clk),
        .data1_result_valid_o     (data1_result_valid_clk),
        .sbdata0_clk_o            (sbdata0_clk),
        .sbdata0_result_valid_o   (sbdata0_result_valid_clk),
        .sbaddress0_clk_o         (sbaddress0_clk),
        .sbaddress0_result_valid_o(sbaddress0_result_valid_clk),

        // -- CPU debug interface (CLK domain) -----------------------------
        .halt_req_o      (halt_req_o),
        .halted_i        (halted_i),
        .resume_req_o    (resume_req_o),
        .resumeack_i     (resumeack_i),
        .dbg_reg_addr_o  (dbg_reg_addr_o),
        .dbg_reg_wdata_o (dbg_reg_wdata_o),
        .dbg_reg_we_o    (dbg_reg_we_o),
        .dbg_reg_rdata_i (dbg_reg_rdata_i),
        .dbg_pc_wdata_o  (dbg_pc_wdata_o),
        .dbg_pc_we_o     (dbg_pc_we_o),
        .dbg_pc_i        (dbg_pc_i),
        .dbg_mem_req_o   (dbg_mem_req_o),
        .dbg_mem_addr_o  (dbg_mem_addr_o),
        .dbg_mem_we_o    (dbg_mem_we_o),
        .dbg_mem_wdata_o (dbg_mem_wdata_o),
        .dbg_mem_ready_i (dbg_mem_ready_i),
        .dbg_mem_error_i (dbg_mem_error_i),
        .dbg_mem_rdata_i (dbg_mem_rdata_i),
        .dbg_ndmreset_o  (dbg_ndmreset_o),
        .dbg_hartreset_o (dbg_hartreset_o),
        .dbg_singlestep_o(dbg_singlestep_o),
        .dbg_ebreakm_o   (dbg_ebreakm_o),
        .dcsr_stopcount_o(dcsr_stopcount_o),
        .progbuf0_o      (progbuf0_o),
        .progbuf1_o      (progbuf1_o),
        .trigger_halt_i  (trigger_halt_i),
        .ebreak_halt_i   (ebreak_halt_i),
        .trigger_hit_i   (trigger_hit_i),
        .tdata1_o        (tdata1_o),
        .tdata2_o        (tdata2_o)
    );

    // =========================================================================
    // TDO output -- TCK domain, registered on negedge for glitch-free output
    // =========================================================================
    logic tdo_comb;

    always_comb begin
        case (state)
            CAPTURE_IR, SHIFT_IR, EXIT1_IR:
                tdo_comb = ir_shift[0];
            CAPTURE_DR, SHIFT_DR, EXIT1_DR: begin
                case (ir_reg)
                    IR_IDCODE: tdo_comb = idcode_shift[0];
                    IR_DTMCS:  tdo_comb = dtmcs_shift[0];
                    IR_DMI:    tdo_comb = dmi_shift[0];
                    default:   tdo_comb = bypass_reg;
                endcase
            end
            default: tdo_comb = 1'b0;
        endcase
    end

    always_ff @(negedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) tdo_o <= 1'b0;
        else tdo_o <= tdo_comb;
    end

endmodule
