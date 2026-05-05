// ============================================================================
// File        : jv32_dtm.sv
// Project     : JV32 RISC-V Processor
// Description : RISC-V Debug Transport Module (DTM) with Debug Module
//
// Implements the JTAG Debug Transport Module interface per RISC-V Debug Spec 0.13
// Includes full Debug Module with register access, memory access, halt/resume control
//
// Supported Instructions:
//   - IDCODE (0x01): Returns device ID
//   - DTMCS  (0x10): DTM Control and Status register
//   - DMI    (0x11): Debug Module Interface access
//   - BYPASS (0x1F): Bypass register
//
// Debug Module Registers:
//   - 0x04-0x0f: data0-data11 (Abstract data registers)
//   - 0x10: dmcontrol (Debug Module Control)
//   - 0x11: dmstatus (Debug Module Status)
//   - 0x12: hartinfo (Hart Information)
//   - 0x16: abstractcs (Abstract Control and Status)
//   - 0x17: command (Abstract Command)
//   - 0x20-0x2f: progbuf0-progbuf15 (Program Buffer)
//   - 0x40: haltsum0 (Halt Summary)
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

module jv32_dtm #(
    parameter bit [31:0] IDCODE     = 32'h1DEAD3FF,
    parameter int        N_TRIGGERS = 2              // number of hardware triggers (>=1)
) (
    // JTAG Interface (from TAP controller)
    input  logic       tck_i,         // JTAG clock
    input  logic       tdi_i,         // JTAG data in
    output logic       tdo_o,         // JTAG data out
    input  logic       capture_dr_i,  // Capture-DR state
    input  logic       shift_dr_i,    // Shift-DR state
    input  logic       update_dr_i,   // Update-DR state
    input  logic [4:0] ir_i,          // Current instruction register

    // System
    input logic ntrst_i,  // JTAG reset (active low)
    input logic clk,      // System clock
    input logic rst_n,    // System reset (active low)

    // Debug Interface to CPU Core
    output logic        dbg_halt_req_o,    // Request CPU to halt
    input  logic        dbg_halted_i,      // CPU is halted
    output logic        dbg_resume_req_o,  // Request CPU to resume
    input  logic        dbg_resumeack_i,   // CPU has resumed
    output logic [ 4:0] dbg_reg_addr_o,    // GPR address for access
    output logic [31:0] dbg_reg_wdata_o,   // GPR write data
    output logic        dbg_reg_we_o,      // GPR write enable
    input  logic [31:0] dbg_reg_rdata_i,   // GPR read data
    input  logic [31:0] dbg_pc_i,          // Current PC from CPU
    output logic [31:0] dbg_pc_wdata_o,    // PC write data
    output logic        dbg_pc_we_o,       // PC write enable

    // Debug memory access interface
    output logic        dbg_mem_req_o,    // Memory request valid
    output logic [31:0] dbg_mem_addr_o,   // Memory address
    output logic [ 3:0] dbg_mem_we_o,     // Memory write enable (byte mask)
    output logic [31:0] dbg_mem_wdata_o,  // Memory write data
    input  logic        dbg_mem_ready_i,  // Memory ready
    input  logic        dbg_mem_error_i,  // Memory access error (AXI DECERR/SLVERR)
    input  logic [31:0] dbg_mem_rdata_i,  // Memory read data

    // System reset outputs
    output logic dbg_ndmreset_o,   // Non-debug module reset (reset whole SoC except DM)
    output logic dbg_hartreset_o,  // Hart reset request

    // Debug control outputs derived from dcsr register
    output logic dbg_singlestep_o,  // dcsr[2]: single-step mode
    output logic dbg_ebreakm_o,     // dcsr[15]: ebreak enters debug mode (M-mode)

    // Program buffer contents (for debug ROM intercept in jv32_top)
    output logic [31:0] progbuf0_o,  // Program buffer register 0
    output logic [31:0] progbuf1_o,  // Program buffer register 1

    // Trigger interface (Debug Spec 0.13 Sec.5.2 Trigger Module)
    input  logic                        trigger_halt_i,  // core: trigger caused this halt
    input  logic [N_TRIGGERS-1:0]       trigger_hit_i,   // core: per-trigger hit bits
    output logic [N_TRIGGERS-1:0][31:0] tdata1_o,        // mcontrol config per trigger
    output logic [N_TRIGGERS-1:0][31:0] tdata2_o         // match address per trigger
);

    // ========================================================================
    // Instruction Opcodes
    // ========================================================================
    localparam IR_IDCODE = 5'h01;  // IDCODE instruction
    localparam IR_DTMCS  = 5'h10;  // DTM Control and Status
    localparam IR_DMI    = 5'h11;  // Debug Module Interface
    localparam IR_BYPASS = 5'h1F;  // Bypass

    // ========================================================================
    // DMI Register Addresses (6 bits)
    // ========================================================================
    localparam DMI_DATA0        = 7'h04;  // Abstract data 0
    localparam DMI_DATA1        = 7'h05;  // Abstract data 1
    localparam DMI_DMCONTROL    = 7'h10;  // Debug Module Control
    localparam DMI_DMSTATUS     = 7'h11;  // Debug Module Status
    localparam DMI_HARTINFO     = 7'h12;  // Hart Information
    localparam DMI_ABSTRACTCS   = 7'h16;  // Abstract Control and Status
    localparam DMI_COMMAND      = 7'h17;  // Abstract Command
    localparam DMI_ABSTRACTAUTO = 7'h18;  // Abstract Auto-Execute
    localparam DMI_PROGBUF0     = 7'h20;  // Program Buffer 0
    localparam DMI_PROGBUF1     = 7'h21;  // Program Buffer 1
    localparam DMI_HALTSUM0     = 7'h40;  // Halt Summary 0
    localparam DMI_SBCS         = 7'h38;  // System Bus Control/Status
    localparam DMI_SBADDRESS0   = 7'h39;  // System Bus Address (lower 32 bits)
    localparam DMI_SBDATA0      = 7'h3c;  // System Bus Data (lower 32 bits)

    // ========================================================================
    // Abstract Command Encoding
    // ========================================================================
    localparam CMD_ACCESS_REG = 8'h00;  // Register access command
    localparam CMD_ACCESS_MEM = 8'h02;  // Memory access command

    // Abstract command status
    localparam CMDERR_BUSY       = 3'd1;  // Command is busy
    localparam CMDERR_NOTSUP     = 3'd2;  // Command not supported
    localparam CMDERR_EXCEPTION  = 3'd3;  // Exception during command
    localparam CMDERR_HALTRESUME = 3'd4;  // Hart not in correct state
    localparam CMDERR_BUS        = 3'd5;  // Bus error

    // ========================================================================
    // DTMCS Register (32 bits) - capture value (read fields)
    // ========================================================================
    // Bits [31:18]: Reserved (0)
    // Bits [17]:    dmihardreset (W1; ignored on readback - write accepted per spec Sec.6.1.2)
    // Bits [16]:    dmireset (W1; clears dmistat - accepted, no sticky error state in this DM)
    // Bits [15]:    Reserved (0)
    // Bits [14:12]: idle (0 - no idle cycles required)
    // Bits [11:10]: dmistat (0 - no error)
    // Bits [9:4]:   abits (7 - DMI address width is 7 bits)
    // Bits [3:0]:   version (1 - DTM version 0.13)
    localparam [31:0] DTMCS_VALUE = {
        14'b0,  // [31:18] Reserved
        1'b0,   // [17] dmihardreset
        1'b0,   // [16] dmireset
        1'b0,   // [15] Reserved
        3'd0,   // [14:12] idle (no idle cycles needed)
        2'b00,  // [11:10] dmistat (no error)
        6'd7,   // [9:4] abits (DMI address = 7 bits)
        4'd1    // [3:0] version (0.13)
    };

    // ========================================================================
    // DMI Register (41 bits for abits=7)
    // ========================================================================
    // Bits [40:34]: address (7 bits)
    // Bits [33:2]:  data (32 bits)
    // Bits [1:0]:   op (2 bits: 0=NOP, 1=Read, 2=Write, 3=Reserved)

    // ========================================================================
    // Debug Module Registers
    // ========================================================================

    // dmcontrol register (0x10)
    logic       haltreq;    // Halt request
    logic       resumereq;  // Resume request
    logic       hartreset;  // Hart reset
    logic       ndmreset;   // Non-debug module reset
    logic       dmactive;   // Debug module active

    // Single-hart SoC: hartsello is kept to report anynonexistent when hart>=1 is selected.
    // hartselhi (selects harts 1024+) is hardwired to 0 - saving 10 FFs.
    logic [9:0] hartsello;  // Hart select lower bits [25:16] of dmcontrol

    // dmstatus register (0x11) - Read only, reflects current state
    wire        all_resumeack;
    wire        any_resumeack;
    wire        all_running;
    wire        any_running;
    wire        all_halted;
    wire        any_halted;
    wire        all_havereset;  // Hart has been reset since last ackhavereset
    wire        any_havereset;
    wire        all_noexist;    // Selected hart does not exist
    wire        any_noexist;
    logic       havereset_r;    // sticky: set when hartreset/ndmreset fires

    // hartinfo register (0x12) - Read only
    localparam [31:0] HARTINFO_VALUE = {
        8'b0,  // [31:24] Reserved
        4'd2,  // [23:20] nscratch (2 scratch registers: dscratch0, dscratch1)
        3'b0,  // [19:17] Reserved
        1'b0,  // [16] dataaccess (no direct data access)
        4'd1,  // [15:12] datasize (1 = 32-bit data width)
        12'd0  // [11:0] dataaddr
    };

    // abstractcs register (0x16) - split between TCK and system domains
    logic [2:0] cmderr;      // Command error (TCK domain)
    logic [2:0] cmderr_sys;  // Command error (system clock domain)
    logic       cmd_busy;    // Command busy (system clock domain)

    // W1C cmderr clear from TCK->CLK via toggle-sync
    logic [2:0] cmderr_clr_tck;                               // TCK domain clear mask
    logic       cmderr_clr_tog_tck;
    (* ASYNC_REG = "TRUE" *)logic [2:0] cmderr_clr_tog_sync;  // CLK domain toggle sync chain
    logic       cmderr_clr_tog_r;                             // CLK edge detect
    localparam [3:0] ABSTRACTCS_DATACOUNT   = 4'd2;           // data0+data1 (RV32 abstract mem uses both)
    localparam [4:0] ABSTRACTCS_PROGBUFSIZE = 5'd2;           // 2 program buffer registers

    // abstractauto register (0x18) - auto re-execute on data/progbuf access
    // Only data[1:0] and pbuf[1:0] can ever fire (DATACOUNT=2, PROGBUFSIZE=2).
    logic [           1:0]       autoexec_data;  // bit[i]=1: re-exec when data[i] accessed
    logic [           1:0]       autoexec_pbuf;  // bit[i]=1: re-exec when progbuf[i] accessed

    // Synthetic debug CSRs - owned exclusively by CLK domain (read via Capture-DR sync)
    // ntrst_i reset is NOT needed; rst_n resets these via the CLK always_ff block below.
    logic [          31:0]       dcsr_reg;       // CSR 0x7b0 - debug control/status; bits[8:6] reserved
    logic [          31:0]       dscratch0_reg;  // CSR 0x7b2 - debug scratch 0
    logic [          31:0]       dscratch1_reg;  // CSR 0x7b3 - debug scratch 1

    // Trigger CSR shadow registers (Debug Spec 0.13 Sec.5.2 Trigger Module)
    // Owned by CLK domain; OpenOCD access via CMD_CSR_READ/WRITE.
    // tdata1 reset value: type=2 (mcontrol), all mode/action bits=0 (disabled).
    logic [          31:0]       tselect_reg;  // CSR 0x7A0: trigger select
    logic [N_TRIGGERS-1:0][31:0] tdata1_reg;   // CSR 0x7A1: mcontrol config
    logic [N_TRIGGERS-1:0][31:0] tdata2_reg;   // CSR 0x7A2: match address

    // Per-trigger hit bits (tdata1[20]) maintained separately to avoid
    // tdata1_reg RMW conflicts.  Folded into CMD_CSR_READ result for 0x7A1.
    logic [N_TRIGGERS-1:0]       trigger_hit_latch;  // set on trigger halt; cleared by SW write

    // Trigger address matching is currently exact-address only.
    // Advertise maskmax=0 so OpenOCD does not program NAPOT watchpoint ranges
    // that the hardware comparator does not yet implement.
    localparam [5:0] HARDWARE_MASKMAX = 6'd0;

    // tdata1_o: inject read-only maskmax into bits [26:21]; rest from tdata1_reg.
    genvar trig_idx;
    generate
        for (trig_idx = 0; trig_idx < N_TRIGGERS; trig_idx++) begin : gen_tdata1_out
            assign tdata1_o[trig_idx] = {tdata1_reg[trig_idx][31:27], HARDWARE_MASKMAX, tdata1_reg[trig_idx][20:0]};
        end
    endgenerate

    assign tdata2_o = tdata2_reg;

    logic        sb_busyerr;     // Sticky error: SBA started while busy
    logic        sb_readonaddr;  // Trigger SBA read when sbaddress0 written
    logic [ 2:0] sb_access;      // Access width: 2=32-bit (only supported)
    logic        sb_autoincr;    // Auto-increment sbaddress0 after access
    logic        sb_readondata;  // Trigger SBA read when sbdata0 read

    // sb_err is owned exclusively by CLK domain.
    // W1C from TCK domain uses a toggle-sync: TCK latches the clear-mask and
    // pulses sb_err_clr_tog_tck; CLK applies the W1C on the edge.
    logic [ 2:0] sb_err;                                       // SBA error status (CLK domain)
    logic [ 2:0] sb_err_clr_tck;                               // TCK domain: mask of bits to clear (W1C)
    logic        sb_err_clr_tog_tck;                           // TCK domain: toggles to trigger W1C
    (* ASYNC_REG = "TRUE" *)logic [ 2:0] sb_err_clr_tog_sync;  // 3-stage sync for toggle (CLK domain)
    logic        sb_err_clr_tog_r;                             // Edge-detect for toggle (CLK domain)

    // sb_access synced to CLK domain so FSM can check access width at SBA trigger
    logic [ 2:0] sb_access_clk;            // CLK-domain copy of sb_access (2-stage sync)
    logic [31:0] sbaddress0;               // SBA address (TCK domain - written by TCK/DMI only)
    logic [31:0] sbaddress0_stable;        // Holding register: captured when toggle fires, stable during CDC
    logic        sbaddress0_stable_ready;  // Flag: sbaddress0_stable captured and ready for toggle (TCK domain)
    logic [31:0] sbdata0;                  // SBA data (TCK domain - written by TCK/DMI only)

    // CLK-domain copies driven exclusively by the SBA FSM.
    // sbaddress0_clk is seeded from sbaddress0 at trigger and auto-incremented here;
    // sbdata0_clk captures SBA read results here and is synced back to TCK.
    logic [31:0] sbaddress0_clk;  // CLK domain: SBA address (seeded + auto-incremented)
    logic [31:0] sbdata0_clk;     // CLK domain: SBA data (write operand / read result)

    // Handshake flags: CLK sets when an SBA op completes; edge-detect in TCK domain
    logic        sbdata0_result_valid;     // CLK domain: new SBA read result in sbdata0_clk
    logic        sbaddress0_result_valid;  // CLK domain: sbaddress0_clk updated (autoincrement)
    logic        sba_wr_toggle_tck;        // TCK domain: toggles to trigger SBA write
    logic        sba_rd_toggle_tck;        // TCK domain: toggles to trigger SBA read

    // SBA byte enable and data positioning (computed in FSM)
    logic [ 3:0] sba_wstrb;             // Computed byte enables for write
    logic [31:0] sba_wdata_positioned;  // Data positioned within 32-bit word
    logic [31:0] sba_rdata_masked;      // Read data extracted/masked based on width

    // Remaining SBA localparams
    localparam [2:0] SBA_ACCESS8  = 3'd0;   // 8-bit access width code
    localparam [2:0] SBA_ACCESS16 = 3'd1;   // 16-bit access width code
    localparam [2:0] SBA_ACCESS32 = 3'd2;   // 32-bit access width code
    localparam [6:0] SBA_ASIZE    = 7'd32;  // Address size: 32-bit bus

    // Abstract data registers (TCK domain)
    logic [31:0] data0;  // data0 register
    logic [31:0] data1;  // data1 register (for 64-bit accesses, TCK domain)

    // Program buffer registers
    logic [31:0] progbuf0;
    logic [31:0] progbuf1;

    // Abstract command register (TCK domain)
    logic [31:0] command_reg;

    // System clock domain shadow registers for abstract command execution
    logic [31:0] data0_sys;           // CLK-domain stable copy of data0
    logic [31:0] data1_sys;           // CLK-domain stable copy of data1 (for abstract mem addr)
    logic [31:0] data0_result;        // Result written by system domain
    logic        data0_result_valid;  // Result valid flag
    logic [31:0] command_reg_sys;
    logic        command_valid_sys;

    // ========================================================================
    // State Machine for Abstract Command Execution
    // ========================================================================
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
    logic [15:0] cmd_regno;          // Register number per debug spec: GPR=0x1000-0x101f, DPC CSR=0x7b1
    logic [ 2:0] cmd_size;           // Access size (0=byte, 1=half, 2=word, 3=double)
    logic        cmd_write;          // Command is write (vs read)
    logic        cmd_postexec;       // Execute progbuf after command
    logic        exec_resume_req;    // FSM-driven resume for progbuf execution
    logic        exec_waiting_halt;  // CMD_EXEC: waiting for CPU to re-halt
    logic        exec_seen_running;  // CMD_EXEC: hart observed running after resume
    logic [23:0] exec_wait_cnt;      // CMD_EXEC timeout while waiting for re-halt
    logic        exec_halt_req;      // CMD_EXEC: issue halt after fault/timeout

    localparam [23:0] EXEC_TIMEOUT_CYCLES = 24'h00_FFFF;  // 65535 cycles (~655 us @100 MHz); fires before OpenOCD 10 s timeout in simulation

    logic exec_fault_halting;                          // CMD_EXEC: waiting for halt after fault
    logic read_after_exec;                             // CMD_EXEC runs before register read (read+postexec)
    logic exec_phase_done;                             // exec phase done; CMD_WAIT → CMD_DONE, not CMD_EXEC
    localparam [31:0] DEBUG_ROM_BASE = 32'h0F80_0000;  // Progbuf intercept address
    logic cmd_transfer;                                // Perform transfer

    // CPU Control Signals (TCK domain)
    logic halted_tck;     // dbg_halted_i synced to TCK domain
    logic resumeack_tck;  // dbg_resumeack_i synced to TCK domain

    // CPU Control Signals (system clock domain)
    logic halted_clk;  // dbg_halted_i synchronized to clk domain (reserved for future use)

    // Memory access tracking
    logic mem_req_pending;
    logic [3:0] mem_wait_cnt;  // 16-cycle timeout for memory operations

    // Command trigger: toggle-sync from TCK->clk domain
    logic cmd_wr_toggle_tck;                                          // toggles in TCK domain when COMMAND is written
    (* ASYNC_REG = "TRUE" *) logic [2:0] cmd_wr_toggle_sync;          // 3-stage sync chain in clk domain
    logic cmd_wr_toggle_r;                                            // delayed version for edge detect
    (* ASYNC_REG = "TRUE" *) logic [31:0] command_reg_tck_sync[2:0];  // TCK->CLK sync chain for command payload
    (* ASYNC_REG = "TRUE" *) logic [31:0] data0_tck_sync[2:0];        // TCK->CLK sync chain for data0 payload
    (* ASYNC_REG = "TRUE" *) logic [31:0] data1_tck_sync[2:0];        // TCK->CLK sync chain for data1 payload

    // SBA trigger: separate toggle-syncs for SBA reads and writes (TCK->clk)
    (* ASYNC_REG = "TRUE" *) logic [2:0] sba_wr_toggle_sync;  // SBA write toggle sync chain
    logic sba_wr_toggle_r;
    (* ASYNC_REG = "TRUE" *) logic [2:0] sba_rd_toggle_sync;  // SBA read toggle sync chain
    logic sba_rd_toggle_r;
    logic [3:0] sba_wait_cnt;                                 // SBA timeout counter

    // SBA busy: sync from clk domain back to TCK domain for SBCS.sbbusy read
    logic sba_busy_clk;                                       // clk domain: SBA FSM is active
    (* ASYNC_REG = "TRUE" *) logic [2:0] sba_busy_tck_chain;  // 3-stage sync to TCK
    logic sba_busy_tck;                                       // TCK domain: SBA is busy

    // ========================================================================
    // Status signals derived from CPU state
    // ========================================================================
    assign any_halted      = halted_tck;   // TCK domain: for dmstatus reads
    assign all_halted      = halted_tck;
    assign any_running     = !halted_tck;
    assign all_running     = !halted_tck;
    assign any_resumeack   = resumeack_tck;
    assign all_resumeack   = resumeack_tck;
    assign any_havereset   = havereset_r;  // sticky, cleared by ackhavereset
    assign all_havereset   = havereset_r;

    // nonexistent: hart 0 exists; any nonzero hartsello selects a non-existent hart
    assign any_noexist     = (hartsello != 10'b0);
    assign all_noexist     = (hartsello != 10'b0);

    // ndmreset / hartreset output wires
    assign dbg_ndmreset_o  = ndmreset;
    assign dbg_hartreset_o = hartreset;

    // ========================================================================
    // Clock Domain Crossing Synchronizers
    // ========================================================================
    // Combined JTAG/system reset: active-low OR of ntrst_i and rst_n.
    // Yosys only supports a single async reset edge per always_ff block;
    // merging the two resets into one net covers both (ntrst_i OR rst_n).
    logic jtag_rst_n;
    assign jtag_rst_n = ntrst_i & rst_n;

    // Synchronize CPU signals from system clock domain to TCK domain
    (* ASYNC_REG = "TRUE" *) logic [2:0] halted_tck_chain;
    (* ASYNC_REG = "TRUE" *) logic [2:0] resumeack_tck_chain;

    // CLK->TCK sync for cmd_busy (used to guard TCK-domain write checks)
    (* ASYNC_REG = "TRUE" *) logic [2:0] busy_tck_chain;
    logic busy_tck;                    // TCK-domain stable copy (lags CLK domain by sync latency)
    logic cmd_busy_tck_pending;        // Assert busy immediately when COMMAND dispatched
    logic [1:0] cmd_busy_holdoff_tck;  // Counts 3..0 after dispatch; prevents premature clear

    // CLK->TCK sync for sb_err (read in CAPTURE_DR for SBCS register)
    (* ASYNC_REG = "TRUE" *) logic [2:0] sb_err_tck_chain[2:0];  // 3 pipeline stages, each holding 3-bit error
    logic [2:0] sb_err_tck;                                      // TCK-domain stable copy

    // Next-value combinational signals (declared here so they are in scope for
    // the always_ff block below that reads them before the always_comb that
    // drives them is defined).
    logic cmd_wr_toggle_tck_nx;
    logic sb_busyerr_nx;
    logic sba_rd_toggle_tck_nx;

    // Track if we have a pending SBA read (toggled but not yet result received)
    logic sba_rd_pending_tck;

    always_ff @(posedge tck_i or negedge jtag_rst_n) begin
        if (!jtag_rst_n) begin
            halted_tck_chain     <= 3'b0;
            resumeack_tck_chain  <= 3'b0;
            halted_tck           <= 1'b0;
            resumeack_tck        <= 1'b0;
            sba_busy_tck_chain   <= 3'b0;
            sba_busy_tck         <= 1'b0;
            busy_tck_chain       <= 3'b0;
            busy_tck             <= 1'b0;
            cmd_busy_tck_pending <= 1'b0;
            cmd_busy_holdoff_tck <= 2'd0;
            sb_err_tck_chain[0]  <= 3'b0;
            sb_err_tck_chain[1]  <= 3'b0;
            sb_err_tck_chain[2]  <= 3'b0;
            sb_err_tck           <= 3'b0;
        end
        else begin
            // Double-synchronize CPU status signals
            halted_tck_chain    <= {halted_tck_chain[1:0], dbg_halted_i};
            halted_tck          <= halted_tck_chain[2];

            resumeack_tck_chain <= {resumeack_tck_chain[1:0], dbg_resumeack_i};
            resumeack_tck       <= resumeack_tck_chain[2];

            // Sync SBA busy from clk domain back to TCK domain
            sba_busy_tck_chain  <= {sba_busy_tck_chain[1:0], sba_busy_clk};
            sba_busy_tck        <= sba_busy_tck_chain[2];

            // Sync cmd_busy from CLK domain to TCK domain
            busy_tck_chain      <= {busy_tck_chain[1:0], cmd_busy};
            busy_tck            <= busy_tck_chain[2];

            // Set pending flag immediately when a COMMAND is dispatched (toggle changes).
            // The holdoff counter keeps it asserted for at least 3 TCK cycles so that
            // OpenOCD sees busy=1 in the scan immediately following COMMAND dispatch.
            // Cleared when the holdoff expires AND busy_tck=0 (command done or fast).
            // This avoids deadlock when commands complete within a single TCK period.
            if (cmd_wr_toggle_tck_nx != cmd_wr_toggle_tck) begin
                cmd_busy_tck_pending <= 1'b1;
                cmd_busy_holdoff_tck <= 2'd3;
            end
            else begin
                if (cmd_busy_holdoff_tck != 2'd0) cmd_busy_holdoff_tck <= cmd_busy_holdoff_tck - 2'd1;
                if (cmd_busy_holdoff_tck == 2'd0 && !busy_tck) cmd_busy_tck_pending <= 1'b0;
            end

            // Sync sb_err from CLK domain to TCK domain (each bit independently)
            sb_err_tck_chain[0] <= sb_err;
            sb_err_tck_chain[1] <= sb_err_tck_chain[0];
            sb_err_tck_chain[2] <= sb_err_tck_chain[1];
            sb_err_tck          <= sb_err_tck_chain[2];
        end
    end

    // Synchronize debug requests from TCK domain to system clock domain
    (* ASYNC_REG = "TRUE" *)logic [ 2:0] halt_req_sync_chain;
    (* ASYNC_REG = "TRUE" *)logic [ 2:0] resume_req_sync_chain;
    logic [ 2:0] halted_clk_chain;     // same-domain pipeline (not CDC)
    logic [ 2:0] dcsr_cause_r;         // dcsr.cause bits updated on debug mode entry
    logic        dbg_halted_prev;      // edge detector driven by sync always_ff
    logic        dbg_halted_prev_fsm;  // independent edge detector driven by FSM always_ff
    logic        trigger_halt_pulse;   // one-cycle pulse: trigger caused this halt (sync always_ff)
    logic [31:0] dpc_reg;              // Saved DPC - persists through CMD_EXEC progbuf operations

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            halt_req_sync_chain   <= 3'b0;
            resume_req_sync_chain <= 3'b0;
            halted_clk_chain      <= 3'b0;
            halted_clk            <= 1'b0;
            dbg_halted_prev       <= 1'b0;
            trigger_halt_pulse    <= 1'b0;
        end
        else begin
            halt_req_sync_chain   <= {halt_req_sync_chain[1:0], haltreq};
            resume_req_sync_chain <= {resume_req_sync_chain[1:0], resumereq};
            halted_clk_chain      <= {halted_clk_chain[1:0], dbg_halted_i};
            halted_clk            <= halted_clk_chain[2];

            // dcsr.cause update: detect rising edge of dbg_halted_i
            dbg_halted_prev       <= dbg_halted_i;
            trigger_halt_pulse    <= dbg_halted_i && !dbg_halted_prev && trigger_halt_i;
        end
    end

    assign dbg_halt_req_o   = (cmd_busy ? 1'b0 : halt_req_sync_chain[2]) | exec_halt_req;
    assign dbg_resume_req_o = (cmd_busy ? 1'b0 : resume_req_sync_chain[2]) || exec_resume_req;

    // ========================================================================
    // Shift Registers
    // ========================================================================
    logic [31:0] idcode_shift;
    logic [31:0] dtmcs_shift;
    logic [40:0] dmi_shift;
    logic bypass_shift;

    // DMI state
    logic [6:0] dmi_address;

    // ========================================================================
    // Construct dmcontrol read value
    // ========================================================================
    wire [31:0] dmcontrol_rdata = {
        1'b0,       // [31] haltreq
        1'b0,       // [30] resumereq
        1'b0,       // [29] hartreset
        1'b0,       // [28] ackhavereset
        1'b0,       // [27] Reserved
        1'b0,       // [26] hasel (single-hart; hartsel selects one hart)
        hartsello,  // [25:16] hartsello (10 bits)
        10'b0,      // [15:6]  hartselhi (hardwired 0: single hart)
        4'b0,       // [5:2] Reserved
        ndmreset,   // [1] ndmreset
        dmactive    // [0] dmactive
    };

    // ========================================================================
    // Construct dmstatus read value
    // ========================================================================
    wire [31:0] dmstatus_rdata = {
        9'b0,           // [31:23] Reserved
        1'b1,           // [22] impebreak (implicit ebreak after last progbuf entry)
        2'b00,          // [21:20] Reserved
        all_havereset,  // [19] all_havereset
        any_havereset,  // [18] any_havereset
        all_resumeack,  // [17] all_resumeack
        any_resumeack,  // [16] any_resumeack
        all_noexist,    // [15] all_noexist
        any_noexist,    // [14] any_noexist
        1'b0,           // [13] allunavail
        1'b0,           // [12] anyunavail
        all_running,    // [11] all_running
        any_running,    // [10] any_running
        all_halted,     // [9] all_halted
        any_halted,     // [8] any_halted
        1'b1,           // [7] authenticated
        1'b0,           // [6] authbusy
        1'b0,           // [5] hasresethaltreq
        1'b0,           // [4] confstrptrvalid
        4'b0010         // [3:0] version (2 = debug spec 0.13)
    };

    // ========================================================================
    // Construct abstractcs read value
    // ========================================================================
    wire [31:0] abstractcs_rdata = {
        3'b0,                              // [31:29] Reserved
        ABSTRACTCS_PROGBUFSIZE,            // [28:24] progbufsize
        11'b0,                             // [23:13] Reserved
        busy_tck || cmd_busy_tck_pending,  // [12] busy (stable sync OR pending dispatch)
        1'b0,                              // [11] Reserved
        cmderr,                            // [10:8] cmderr
        4'b0,                              // [7:4] Reserved
        ABSTRACTCS_DATACOUNT               // [3:0] datacount
    };

    // ========================================================================
    // Construct haltsum0 read value
    // ========================================================================
    wire [31:0] haltsum0_rdata = {
        31'b0, any_halted  // Hart 0 halted
    };

    // ========================================================================
    // Synchronize system domain status back to TCK domain (declarations)
    // ========================================================================
    (* ASYNC_REG = "TRUE" *) logic [2:0] cmderr_sync[2:0];
    (* ASYNC_REG = "TRUE" *) logic [31:0] data0_result_sync[2:0];
    (* ASYNC_REG = "TRUE" *) logic data0_result_valid_sync[2:0];
    logic data0_result_valid_sync_r;  // One-cycle delayed [2] for rising-edge detect

    // CLK->TCK sync chains for SBA results (mirrors data0_result_sync mechanism)
    (* ASYNC_REG = "TRUE" *) logic [31:0] sbdata0_result_sync[2:0];
    (* ASYNC_REG = "TRUE" *) logic sbdata0_result_valid_sync[2:0];
    logic sbdata0_result_valid_sync_r;     // One-cycle delayed [2]
    (* ASYNC_REG = "TRUE" *) logic [31:0] sbaddress0_result_sync[2:0];
    (* ASYNC_REG = "TRUE" *) logic sbaddress0_result_valid_sync[2:0];
    logic sbaddress0_result_valid_sync_r;  // One-cycle delayed [2]
    logic sbaddress0_written_tck;          // Flag: SBADDRESS0 explicitly written this cycle

    // ========================================================================
    // Next-value logic for signals assigned in both capture_dr_i and
    // update_dr_i branches.  A single always_comb + dedicated always_ff gives
    // each register exactly one sequential driver, eliminating CDFG2G-622
    // (Genus "multiple drivers") warnings.
    // ========================================================================

    always_comb begin
        cmd_wr_toggle_tck_nx = cmd_wr_toggle_tck;
        sb_busyerr_nx        = sb_busyerr;
        sba_rd_toggle_tck_nx = sba_rd_toggle_tck;
        if (capture_dr_i && ir_i == IR_DMI) begin
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
        else if (update_dr_i && ir_i == IR_DMI && dmi_shift[1:0] == 2'b10) begin
            case (dmi_shift[40:34])
                DMI_DATA0: if (!busy_tck && autoexec_data[0]) cmd_wr_toggle_tck_nx = ~cmd_wr_toggle_tck;
                DMI_DATA1: if (!busy_tck && autoexec_data[1]) cmd_wr_toggle_tck_nx = ~cmd_wr_toggle_tck;
                DMI_COMMAND:
                if (!busy_tck && !cmd_busy_tck_pending && dmactive) cmd_wr_toggle_tck_nx = ~cmd_wr_toggle_tck;
                DMI_PROGBUF0: if (!busy_tck && autoexec_pbuf[0]) cmd_wr_toggle_tck_nx = ~cmd_wr_toggle_tck;
                DMI_PROGBUF1: if (!busy_tck && autoexec_pbuf[1]) cmd_wr_toggle_tck_nx = ~cmd_wr_toggle_tck;
                DMI_SBCS: if (dmi_shift[24]) sb_busyerr_nx = 1'b0;
                // DMI_SBADDRESS0: read-on-addr trigger is now delayed (see always_ff block)
                // to ensure address stabilizes before toggle fires
                DMI_SBDATA0: if (sb_err_tck == 3'b0 && sba_busy_tck) sb_busyerr_nx = 1'b1;
                default: ;
            endcase
        end
    end

    always_ff @(posedge tck_i or negedge jtag_rst_n) begin
        if (!jtag_rst_n) begin
            halted_tck_chain    <= 3'b0;
            resumeack_tck_chain <= 3'b0;
            cmd_wr_toggle_tck   <= 1'b0;
            sb_busyerr          <= 1'b0;
            sba_rd_toggle_tck   <= 1'b0;
            sba_rd_pending_tck  <= 1'b0;
        end
        else begin
            cmd_wr_toggle_tck <= cmd_wr_toggle_tck_nx;
            sb_busyerr        <= sb_busyerr_nx;
            sba_rd_toggle_tck <= sba_rd_toggle_tck_nx;

            // Track pending read: set when toggle changes, clear when result arrives
            if (sba_rd_toggle_tck_nx != sba_rd_toggle_tck) sba_rd_pending_tck <= 1'b1;
            else if (sbdata0_result_valid_sync[2] && sbdata0_result_valid_sync_r == 1'b0)
                sba_rd_pending_tck <= 1'b0;  // Rising edge of result_valid = new result arrived
        end
    end

    // ========================================================================
    // TCK-domain registers: Capture-DR, Shift-DR, and Update-DR
    // ========================================================================
    always_ff @(posedge tck_i or negedge jtag_rst_n) begin
        if (!jtag_rst_n) begin
            // Shift registers (loaded during CAPTURE_DR)
            idcode_shift            <= 32'b0;
            dtmcs_shift             <= 32'b0;
            dmi_shift               <= 41'b0;
            bypass_shift            <= 1'b0;

            // DMI address and control registers
            dmi_address             <= 7'b0;
            haltreq                 <= 1'b0;
            resumereq               <= 1'b0;
            hartreset               <= 1'b0;
            ndmreset                <= 1'b0;
            dmactive                <= 1'b0;
            hartsello               <= 10'b0;
            data0                   <= 32'b0;
            data1                   <= 32'b0;

            // Default to EBREAK so a progbuf execute with untouched entries
            // immediately returns to debug mode instead of running garbage.
            progbuf0                <= 32'h0010_0073;
            progbuf1                <= 32'h0010_0073;
            command_reg             <= 32'b0;
            cmderr                  <= 3'b0;
            cmderr_clr_tck          <= 3'b0;
            cmderr_clr_tog_tck      <= 1'b0;

            // abstractauto
            autoexec_data           <= 2'b0;
            autoexec_pbuf           <= 2'b0;

            // Synthetic debug CSRs: owned by CLK domain, reset there; not here.
            // SBA
            sb_readonaddr           <= 1'b1;  // Default ON so OpenOCD doesn't need to configure
            sb_access               <= SBA_ACCESS32;
            sb_autoincr             <= 1'b0;
            sb_readondata           <= 1'b0;

            // sb_err owned by CLK domain; only the clr-request fields live here
            sb_err_clr_tck          <= 3'b0;
            sb_err_clr_tog_tck      <= 1'b0;
            sbaddress0              <= 32'b0;
            sbaddress0_stable       <= 32'b0;
            sbaddress0_stable_ready <= 1'b0;
            sbdata0                 <= 32'b0;
            sba_wr_toggle_tck       <= 1'b0;
            havereset_r             <= 1'b0;
        end
        else if (capture_dr_i) begin
            case (ir_i)
                IR_IDCODE: begin
                    idcode_shift <= IDCODE;
                    `DEBUG2(`DBG_GRP_DTM, ("CAPTURE_DR IDCODE, loading %h", IDCODE));
                end
                IR_DTMCS: begin
                    dtmcs_shift <= DTMCS_VALUE;
                end
                IR_DMI: begin
                    // Capture: Return data from previous operation
                    // Read the requested DMI register
                    case (dmi_address)
                        DMI_DATA0: begin
                            // Return the freshest CLK-domain result during CAPTURE_DR.
                            // Waiting for the shadow DATA0 register to be updated in a
                            // later UPDATE_DR makes abstract reads visible one scan late.
                            dmi_shift <= {
                                dmi_address, data0_result_valid_sync[2] ? data0_result_sync[2] : data0, 2'b00
                            };
                        end
                        DMI_DATA1: begin
                            dmi_shift <= {dmi_address, data1, 2'b00};
                        end
                        DMI_DMCONTROL: dmi_shift <= {dmi_address, dmcontrol_rdata, 2'b00};
                        DMI_DMSTATUS: dmi_shift <= {dmi_address, dmstatus_rdata, 2'b00};
                        DMI_HARTINFO: dmi_shift <= {dmi_address, HARTINFO_VALUE, 2'b00};
                        DMI_ABSTRACTCS: dmi_shift <= {dmi_address, abstractcs_rdata, 2'b00};
                        DMI_COMMAND: dmi_shift <= {dmi_address, command_reg, 2'b00};
                        DMI_PROGBUF0: dmi_shift <= {dmi_address, progbuf0, 2'b00};
                        DMI_PROGBUF1: dmi_shift <= {dmi_address, progbuf1, 2'b00};
                        DMI_ABSTRACTAUTO:
                        dmi_shift <= {dmi_address, {14'b0, autoexec_pbuf, 14'b0, autoexec_data}, 2'b00};
                        DMI_HALTSUM0: dmi_shift <= {dmi_address, haltsum0_rdata, 2'b00};
                        DMI_SBCS: begin
                            dmi_shift <= {
                                dmi_address,
                                {
                                    3'd1,           // [31:29] sbversion=1
                                    6'b0,           // [28:23] reserved
                                    sb_busyerr,     // [22]
                                    sba_busy_tck,   // [21] sbbusy: live from clk domain
                                    sb_readonaddr,  // [20]
                                    sb_access,      // [19:17]
                                    1'b0,           // [16] sbautoincrement (DISABLED: CDC timing bug)
                                    sb_readondata,  // [15]
                                    sb_err_tck,     // [14:12] CLK->TCK synchronised copy
                                    SBA_ASIZE,      // [11:5] asize=32
                                    1'b0,           // [4] no 128-bit
                                    1'b0,           // [3] no 64-bit
                                    1'b1,           // [2] access32=1
                                    1'b1,           // [1] access16=1
                                    1'b1
                                },  // [0] access8=1
                                2'b00
                            };
                        end
                        DMI_SBADDRESS0:
                        dmi_shift <= {
                            dmi_address, sbaddress0, 2'b00  // Autoincrement disabled: always return explicit value
                        };
                        DMI_SBDATA0: begin
                            // Return synchronized result only if valid and operation complete
                            // If busy or no valid result, return 0 (OpenOCD should check sbbusy first)
                            dmi_shift <= {
                                dmi_address,
                                (sbdata0_result_valid_sync[2] && !sba_busy_tck) ? sbdata0_result_sync[2] : 32'h0,
                                2'b00
                            };
                        end
                        default: dmi_shift <= {dmi_address, 32'h0, 2'b00};
                    endcase
                end
                IR_BYPASS: begin
                    bypass_shift <= 1'b0;
                end
                default: begin
                    bypass_shift <= 1'b0;
                end
            endcase
        end
        else if (shift_dr_i) begin
            case (ir_i)
                IR_IDCODE: begin
                    idcode_shift <= {tdi_i, idcode_shift[31:1]};
                    `DEBUG2(`DBG_GRP_DTM,
                            ("SHIFT_DR IDCODE, tdo=%b, idcode_shift=%h -> %h", idcode_shift[0], idcode_shift, {
                            tdi_i, idcode_shift[31:1]}));
                end
                IR_DTMCS: begin
                    dtmcs_shift <= {tdi_i, dtmcs_shift[31:1]};
                end
                IR_DMI: begin
                    dmi_shift <= {tdi_i, dmi_shift[40:1]};
                end
                IR_BYPASS: begin
                    bypass_shift <= tdi_i;
                end
                default: begin
                    bypass_shift <= tdi_i;
                end
            endcase
        end
        else if (update_dr_i && ir_i == IR_DTMCS) begin
            // DTMCS write: handle dmireset (bit[16]) and dmihardreset (bit[17]).
            // Per RISC-V Debug Spec Sec.6.1.2:
            //   dmireset     [16]: W1: recover from DMI error; clears any sticky dmistat.
            //   dmihardreset [17]: W1: hard-reset the DTM (like a power-on reset of the DTMCS).
            // This DM does not implement dmistat sticky error bits (dmistat is always 0),
            // so dmireset has no live state to clear.  We accept the write silently so
            // a JTAG host can always invoke dmireset without seeing a protocol error.
            `DEBUG2(`DBG_GRP_DTM,
                    ("DTMCS UPDATE: dtmcs_shift=0x%h dmireset=%b dmihardreset=%b",
                   dtmcs_shift, dtmcs_shift[16], dtmcs_shift[17]));

        end
        else if (update_dr_i && ir_i == IR_DMI) begin
            // Extract address field from shifted data
            dmi_address <= dmi_shift[40:34];
            `DEBUG2(`DBG_GRP_DTM,
                    ("DMI UPDATE: op=%0d addr=0x%02h data=0x%08h", dmi_shift[1:0], dmi_shift[40:34], dmi_shift[33:2]));

            // Sync results from system domain even when not writing.
            // Update whenever valid_sync[2] is high: by the time UPDATE-DR fires after
            // a command completes, the sync chain has stabilized and data0_result holds
            // the correct result. OpenOCD always reads DATA0 after seeing abstractcs.busy=0.
            if (data0_result_valid_sync[2] && !data0_result_valid_sync_r) begin
                data0 <= data0_result_sync[2];
                `DEBUG2(`DBG_GRP_DTM, ("Sync DATA0 result = 0x%h", data0_result_sync[2]));
            end
            if (cmderr_sync[2] != cmderr) begin
                cmderr <= cmderr_sync[2];
                `DEBUG2(`DBG_GRP_DTM, ("Sync ABSTRACTCS cmderr = %0d", cmderr_sync[2]));
            end
            // Sync SBA results back from CLK domain
            if (sbdata0_result_valid_sync[2] && !sbdata0_result_valid_sync_r) begin
                sbdata0 <= sbdata0_result_sync[2];
                `DEBUG2(`DBG_GRP_DTM, ("Sync SBDATA0 result = 0x%h", sbdata0_result_sync[2]));
            end
            // Sync autoincremented address back from CLK domain: DISABLED (autoincrement disabled)
            // The following sync-back logic is disabled because autoincrement is not supported
            // due to CDC timing issues. Leaving it active could cause stale values to corrupt reads.
            /*
            if (sbaddress0_written_tck) begin
                // Explicit write detected - do NOT sync autoincrement this cycle
                `DEBUG2(`DBG_GRP_DTM, ("SBADDRESS0 explicit write - suppressing autoincr sync"));
            end
            else if (sbaddress0_result_valid_sync[2] && !sbaddress0_result_valid_sync_r) begin
                sbaddress0 <= sbaddress0_result_sync[2];
                `DEBUG2(`DBG_GRP_DTM, ("Sync SBADDRESS0 autoincr = 0x%h", sbaddress0_result_sync[2]));
            end
            */

            // Always capture sbaddress0 into stable holding register when written
            // This ensures data stability for CDC regardless of sb_readonaddr/sb_readondata mode
            if (sbaddress0_written_tck) begin
                sbaddress0_stable       <= sbaddress0;
                sbaddress0_stable_ready <= 1'b1;  // Mark as ready for toggle next cycle
                `DEBUG2(`DBG_GRP_DTM, ("Capture SBADDRESS0 stable = 0x%h", sbaddress0));
            end

            // Delayed SBA read trigger: fire toggle one cycle AFTER sbaddress0_stable captured (if sb_readonaddr)
            // This ensures sbaddress0_stable has been stable for one full cycle before CLK domain samples it
            if (sbaddress0_stable_ready && sb_readonaddr && sb_err_tck == 3'b0 && !sba_busy_tck) begin
                sba_rd_toggle_tck       <= ~sba_rd_toggle_tck;
                sbaddress0_stable_ready <= 1'b0;  // Clear after toggle fires
                `DEBUG2(`DBG_GRP_DTM, ("Fire delayed SBA read toggle for addr=0x%h", sbaddress0_stable));
            end

            // Clear the explicit-write flag unconditionally (autoincrement is disabled)
            if (sbaddress0_written_tck) begin
                sbaddress0_written_tck <= 1'b0;
            end

            // Process write operations (op == 2'b10)
            if (dmi_shift[1:0] == 2'b10) begin  // Write operation
                case (dmi_shift[40:34])
                    DMI_DATA0: begin
                        if (!busy_tck) begin
                            data0 <= dmi_shift[33:2];
                            `DEBUG2(`DBG_GRP_DTM, ("Write DATA0 = 0x%h", dmi_shift[33:2]));
                        end
                    end
                    DMI_DATA1: begin
                        if (!busy_tck) begin
                            data1 <= dmi_shift[33:2];
                            `DEBUG2(`DBG_GRP_DTM, ("Write DATA1 = 0x%h", dmi_shift[33:2]));
                        end
                    end
                    DMI_DMCONTROL: begin
                        dmactive  <= dmi_shift[2];      // bit[0]
                        ndmreset  <= dmi_shift[3];      // bit[1]
                        haltreq   <= dmi_shift[33];     // bit[31]
                        resumereq <= dmi_shift[32];     // bit[30]
                        hartreset <= dmi_shift[31];     // bit[29]
                        hartsello <= dmi_shift[27:18];  // bits[25:16]
                        // hartselhi writes are ignored (hardwired 0)
                        // Set havereset sticky when hartreset or ndmreset goes high
                        if (dmi_shift[31] || dmi_shift[3]) havereset_r <= 1'b1;
                        // bit[28] ackhavereset W1C - must be last so it wins over the set above
                        if (dmi_shift[30]) havereset_r <= 1'b0;
                        `DEBUG2(`DBG_GRP_DTM,
                                ("Write DMCONTROL: dmactive=%b haltreq=%b resumereq=%b ndmreset=%b hartsel=%h",
                               dmi_shift[2], dmi_shift[33], dmi_shift[32], dmi_shift[3], dmi_shift[27:18]));
                    end
                    DMI_ABSTRACTCS: begin
                        // W1C: abstractcs.cmderr is at data[10:8] = dmi_shift[12:10]
                        // (dmi_shift = {addr[40:34], data[33:2], op[1:0]}, so data[N] = dmi_shift[N+2])
                        if (dmi_shift[12:10] != 3'b0) begin
                            cmderr             <= cmderr & ~dmi_shift[12:10];
                            cmderr_clr_tck     <= dmi_shift[12:10];
                            cmderr_clr_tog_tck <= ~cmderr_clr_tog_tck;
                            `DEBUG2(`DBG_GRP_DTM, ("Clear ABSTRACTCS cmderr mask=%0b", dmi_shift[12:10]));
                        end
                    end
                    DMI_COMMAND: begin
                        if (!busy_tck && !cmd_busy_tck_pending && dmactive) begin
                            command_reg <= dmi_shift[33:2];
                            `DEBUG2(`DBG_GRP_DTM, ("Write COMMAND = 0x%h", dmi_shift[33:2]));
                        end
                        else if (busy_tck || cmd_busy_tck_pending) begin
                            // Spec 3.7.1.1: set cmderr=1 (busy) and discard command
                            if (cmderr == 3'b0) cmderr <= CMDERR_BUSY;
                            `DEBUG2(`DBG_GRP_DTM, ("COMMAND write rejected: busy, cmderr set"));
                        end
                    end
                    DMI_PROGBUF0: begin
                        if (!busy_tck) begin
                            progbuf0 <= dmi_shift[33:2];
                            `DEBUG2(`DBG_GRP_DTM, ("Write PROGBUF0 = 0x%h", dmi_shift[33:2]));
                        end
                    end
                    DMI_PROGBUF1: begin
                        if (!busy_tck) begin
                            progbuf1 <= dmi_shift[33:2];
                            `DEBUG2(`DBG_GRP_DTM, ("Write PROGBUF1 = 0x%h", dmi_shift[33:2]));
                        end
                    end
                    DMI_ABSTRACTAUTO: begin
                        autoexec_data <= dmi_shift[3:2];    // data[1:0]  (data0/data1 only)
                        autoexec_pbuf <= dmi_shift[19:18];  // data[17:16] (pbuf0/pbuf1 only)
                        `DEBUG2(`DBG_GRP_DTM,
                                ("Write ABSTRACTAUTO execdata=%h execprogbuf=%h", dmi_shift[3:2], dmi_shift[19:18]));
                    end
                    DMI_SBCS: begin
                        // [24] W1C sbbusyerror (handled by always_comb); [22] readonaddr
                        // [21:19] sbaccess; [18] autoincrement; [17] readondata; [16:14] W1C error
                        sb_readonaddr <= dmi_shift[22];     // bit[20]
                        sb_access     <= dmi_shift[21:19];  // bits[19:17]
                        sb_autoincr   <= 1'b0;              // FORCE DISABLED (CDC timing bug with autoincr)
                        sb_readondata <= dmi_shift[17];     // bit[15]
                        // W1C sb_err: request CLK domain to clear via toggle-sync
                        if (dmi_shift[16:14] != 3'b0) begin
                            sb_err_clr_tck     <= dmi_shift[16:14];
                            sb_err_clr_tog_tck <= ~sb_err_clr_tog_tck;
                        end
                        `DEBUG2(`DBG_GRP_DTM,
                                ("Write SBCS: readonaddr=%b sbaccess=%0d", dmi_shift[22], dmi_shift[21:19]));
                    end
                    DMI_SBADDRESS0: begin
                        sbaddress0             <= dmi_shift[33:2];
                        sbaddress0_written_tck <= 1'b1;  // Suppress autoincr sync next cycle
                        `DEBUG2(`DBG_GRP_DTM, ("Write SBADDRESS0 = 0x%h (overrides any autoincr)", dmi_shift[33:2]));
                    end
                    DMI_SBDATA0: begin
                        sbdata0 <= dmi_shift[33:2];
                        if (sb_err_tck == 3'b0 && !sba_busy_tck)
                            sba_wr_toggle_tck <= ~sba_wr_toggle_tck;  // CLK checks width
                        `DEBUG2(`DBG_GRP_DTM, ("Write SBDATA0 = 0x%h", dmi_shift[33:2]));
                    end
                    default: begin
                        // Other registers are read-only
                    end
                endcase
            end
        end
    end

    // ========================================================================
    // Synchronize system domain status back to TCK domain
    // ========================================================================
    always_ff @(posedge tck_i or negedge jtag_rst_n) begin
        if (!jtag_rst_n) begin
            cmderr_sync[0]                  <= 3'b0;
            cmderr_sync[1]                  <= 3'b0;
            cmderr_sync[2]                  <= 3'b0;
            data0_result_sync[0]            <= 32'b0;
            data0_result_sync[1]            <= 32'b0;
            data0_result_sync[2]            <= 32'b0;
            data0_result_valid_sync[0]      <= 1'b0;
            data0_result_valid_sync[1]      <= 1'b0;
            data0_result_valid_sync[2]      <= 1'b0;
            data0_result_valid_sync_r       <= 1'b0;
            sbdata0_result_sync[0]          <= 32'b0;
            sbdata0_result_sync[1]          <= 32'b0;
            sbdata0_result_sync[2]          <= 32'b0;
            sbdata0_result_valid_sync[0]    <= 1'b0;
            sbdata0_result_valid_sync[1]    <= 1'b0;
            sbdata0_result_valid_sync[2]    <= 1'b0;
            sbdata0_result_valid_sync_r     <= 1'b0;
            sbaddress0_result_sync[0]       <= 32'b0;
            sbaddress0_result_sync[1]       <= 32'b0;
            sbaddress0_result_sync[2]       <= 32'b0;
            sbaddress0_result_valid_sync[0] <= 1'b0;
            sbaddress0_result_valid_sync[1] <= 1'b0;
            sbaddress0_result_valid_sync[2] <= 1'b0;
            sbaddress0_result_valid_sync_r  <= 1'b0;
            sbaddress0_written_tck          <= 1'b0;
        end
        else begin
            cmderr_sync[0]                  <= cmderr_sys;
            cmderr_sync[1]                  <= cmderr_sync[0];
            cmderr_sync[2]                  <= cmderr_sync[1];
            data0_result_sync[0]            <= data0_result;
            data0_result_sync[1]            <= data0_result_sync[0];
            data0_result_sync[2]            <= data0_result_sync[1];
            data0_result_valid_sync[0]      <= data0_result_valid;
            data0_result_valid_sync[1]      <= data0_result_valid_sync[0];
            data0_result_valid_sync[2]      <= data0_result_valid_sync[1];
            data0_result_valid_sync_r       <= data0_result_valid_sync[2];  // delayed for edge detect
            // SBA result sync chains (CLK->TCK)
            sbdata0_result_sync[0]          <= sbdata0_clk;
            sbdata0_result_sync[1]          <= sbdata0_result_sync[0];
            sbdata0_result_sync[2]          <= sbdata0_result_sync[1];
            sbdata0_result_valid_sync[0]    <= sbdata0_result_valid;
            sbdata0_result_valid_sync[1]    <= sbdata0_result_valid_sync[0];
            sbdata0_result_valid_sync[2]    <= sbdata0_result_valid_sync[1];
            sbdata0_result_valid_sync_r     <= sbdata0_result_valid_sync[2];
            sbaddress0_result_sync[0]       <= sbaddress0_clk;
            sbaddress0_result_sync[1]       <= sbaddress0_result_sync[0];
            sbaddress0_result_sync[2]       <= sbaddress0_result_sync[1];
            sbaddress0_result_valid_sync[0] <= sbaddress0_result_valid;
            sbaddress0_result_valid_sync[1] <= sbaddress0_result_valid_sync[0];
            sbaddress0_result_valid_sync[2] <= sbaddress0_result_valid_sync[1];
            sbaddress0_result_valid_sync_r  <= sbaddress0_result_valid_sync[2];
        end
    end

    // ========================================================================
    // Synchronize command and data from TCK to system clock domain (toggle-sync)
    // ========================================================================
    // cmd_wr_toggle_tck declared above; toggles once per COMMAND write in TCK domain.
    // The 3-stage sync chain converts the toggle to a reliable edge in clk domain.

    // Toggle-sync, W1C, and command-execution FSM are combined into one
    // always_ff block so every CLK-domain signal has exactly one driver.
    // Splitting across two always_ff blocks with overlapping non-blocking
    // assignments is a Verilator multi-driver blind spot (see axi_clint.sv).

    // Decode command when written
    wire cmd_is_access_reg = (command_reg_sys[31:24] == CMD_ACCESS_REG);
    wire cmd_is_access_mem = (command_reg_sys[31:24] == CMD_ACCESS_MEM);

    // sba_busy_clk: true while any SBA state is active in clk domain
    assign sba_busy_clk = (cmd_state == CMD_SBA_READ) || (cmd_state == CMD_SBA_WRITE);

    // ========================================================================
    // SBA byte enable and data positioning (combinational)
    // ========================================================================
    always_comb begin
        // Default values
        sba_wstrb            = 4'b1111;
        sba_wdata_positioned = sbdata0_clk;
        sba_rdata_masked     = dbg_mem_rdata_i;  // Default: full 32-bit word

        case (sb_access_clk)
            SBA_ACCESS8: begin
                // Byte access - position based on address[1:0]
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
                // Halfword access - position based on address[1]
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

    // Register access command fields (cmdtype == 0)
    assign cmd_size     = command_reg_sys[22:20];  // Size: 2=32-bit, 3=64-bit
    assign cmd_postexec = command_reg_sys[18];     // Execute progbuf after
    assign cmd_transfer = command_reg_sys[17];     // Perform transfer
    assign cmd_write    = command_reg_sys[16];     // 1=write, 0=read
    assign cmd_regno    = command_reg_sys[15:0];   // Register number (GPR: 0x1000-0x101f, CSR DPC: 0x7b1)

    // Memory access command fields (cmdtype == 2)
    logic [31:0] mem_addr;
    logic [31:0] mem_post_addr;                               // Holds incremented address for postincrement
    wire         mem_write_cmd = command_reg_sys[16];
    wire         mem_aarpostincrement = command_reg_sys[19];  // Auto-increment address after access
    logic        mem_aarpostincrement_r;                      // Registry for postincrement flag during current operation

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Toggle-sync state
            cmd_wr_toggle_sync      <= 3'b0;
            cmd_wr_toggle_r         <= 1'b0;
            command_reg_sys         <= 32'b0;
            data0_sys               <= 32'b0;
            command_valid_sys       <= 1'b0;
            command_reg_tck_sync[0] <= 32'b0;
            command_reg_tck_sync[1] <= 32'b0;
            command_reg_tck_sync[2] <= 32'b0;
            data0_tck_sync[0]       <= 32'b0;
            data0_tck_sync[1]       <= 32'b0;
            data0_tck_sync[2]       <= 32'b0;
            data1_tck_sync[0]       <= 32'b0;
            data1_tck_sync[1]       <= 32'b0;
            data1_tck_sync[2]       <= 32'b0;
            sba_wr_toggle_sync      <= 3'b0;
            sba_wr_toggle_r         <= 1'b0;
            sba_rd_toggle_sync      <= 3'b0;
            sba_rd_toggle_r         <= 1'b0;
            sba_wait_cnt            <= 4'b0;
            cmderr_clr_tog_sync     <= 3'b0;
            cmderr_clr_tog_r        <= 1'b0;
            sb_err_clr_tog_sync     <= 3'b0;
            sb_err_clr_tog_r        <= 1'b0;
            sb_access_clk           <= SBA_ACCESS32;

            // CLK-domain SBA registers
            sbaddress0_clk          <= 32'b0;
            sbdata0_clk             <= 32'b0;
            sbdata0_result_valid    <= 1'b0;
            sbaddress0_result_valid <= 1'b0;

            // State machine
            cmd_state               <= CMD_IDLE;
            cmd_busy                <= 1'b0;
            cmderr_sys              <= 3'b0;
            data0_result            <= 32'b0;
            data0_result_valid      <= 1'b0;
            data0_sys               <= 32'b0;
            data1_sys               <= 32'b0;
            dbg_reg_we_o            <= 1'b0;
            dbg_pc_we_o             <= 1'b0;
            dbg_mem_req_o           <= 1'b0;
            dbg_mem_we_o            <= 4'b0;
            exec_resume_req         <= 1'b0;
            exec_waiting_halt       <= 1'b0;
            exec_seen_running       <= 1'b0;
            exec_wait_cnt           <= '0;
            exec_halt_req           <= 1'b0;
            exec_fault_halting      <= 1'b0;
            read_after_exec         <= 1'b0;
            exec_phase_done         <= 1'b0;
            mem_req_pending         <= 1'b0;
            mem_wait_cnt            <= 4'b0;
            mem_aarpostincrement_r  <= 1'b0;
            mem_post_addr           <= 32'b0;

            // Synthetic CSRs - CLK domain only
            dcsr_reg                <= 32'h40000003;   // xdebugver=4 [31:28], prv=3 [1:0]
            dcsr_cause_r            <= 3'd0;
            dscratch0_reg           <= 32'b0;
            dscratch1_reg           <= 32'b0;
            dpc_reg                 <= 32'h8000_0000;  // Boot address (matches jv32 BOOT_ADDR)

            // Trigger register reset: type=2 (mcontrol), all mode/action bits=0 (disabled)
            tselect_reg             <= 32'b0;
            tdata1_reg[0]           <= 32'h2000_0000;  // type=2, disabled
            tdata2_reg[0]           <= 32'b0;
            tdata1_reg[1]           <= 32'h2000_0000;
            tdata2_reg[1]           <= 32'b0;

            sb_err                  <= 3'b0;
            // Debug command output registers
            dbg_reg_addr_o          <= '0;
            dbg_reg_wdata_o         <= '0;
            dbg_pc_wdata_o          <= '0;
            dbg_mem_addr_o          <= '0;
            dbg_mem_wdata_o         <= '0;
            mem_addr                <= '0;
            dbg_halted_prev_fsm     <= 1'b0;
            trigger_hit_latch       <= '0;
        end
        else begin
            // ----------------------------------------------------------------
            // Part 1: Unconditional synchronizer advances (always run)
            // ----------------------------------------------------------------
            cmd_wr_toggle_sync      <= {cmd_wr_toggle_sync[1:0], cmd_wr_toggle_tck};
            cmd_wr_toggle_r         <= cmd_wr_toggle_sync[2];

            // Synchronize TCK-domain command payload buses into CLK domain.
            // Payload is held stable in TCK domain until next write.
            command_reg_tck_sync[0] <= command_reg;
            command_reg_tck_sync[1] <= command_reg_tck_sync[0];
            command_reg_tck_sync[2] <= command_reg_tck_sync[1];
            data0_tck_sync[0]       <= data0;
            data0_tck_sync[1]       <= data0_tck_sync[0];
            data0_tck_sync[2]       <= data0_tck_sync[1];
            data1_tck_sync[0]       <= data1;
            data1_tck_sync[1]       <= data1_tck_sync[0];
            data1_tck_sync[2]       <= data1_tck_sync[1];

            // Sync sb_access to CLK (stable before any SBA trigger toggle fires)
            sb_access_clk           <= sb_access;

            // abstractcs.cmderr W1C clear from TCK domain
            cmderr_clr_tog_sync     <= {cmderr_clr_tog_sync[1:0], cmderr_clr_tog_tck};
            cmderr_clr_tog_r        <= cmderr_clr_tog_sync[2];

            if (cmderr_clr_tog_sync[2] != cmderr_clr_tog_r) cmderr_sys <= cmderr_sys & ~cmderr_clr_tck;

            // sb_err W1C: priority LOWER than the state-machine error-set
            // below (NBA ordering: state machine assignment later in source wins
            // if both fire on the same cycle - a new bus error beats an old clear).
            sb_err_clr_tog_sync <= {sb_err_clr_tog_sync[1:0], sb_err_clr_tog_tck};
            sb_err_clr_tog_r    <= sb_err_clr_tog_sync[2];

            if (sb_err_clr_tog_sync[2] != sb_err_clr_tog_r) begin
                sb_err <= sb_err & ~sb_err_clr_tck;
            end

            // SBA write/read toggle syncs
            sba_wr_toggle_sync <= {sba_wr_toggle_sync[1:0], sba_wr_toggle_tck};
            sba_rd_toggle_sync <= {sba_rd_toggle_sync[1:0], sba_rd_toggle_tck};
            sba_wr_toggle_r    <= sba_wr_toggle_sync[2];
            sba_rd_toggle_r    <= sba_rd_toggle_sync[2];

            // ----------------------------------------------------------------
            // Part 2: Command-write toggle edge detection
            // ----------------------------------------------------------------
            if (cmd_wr_toggle_sync[2] != cmd_wr_toggle_r) begin
                // New command edge from TCK domain - latch command & data
                command_reg_sys    <= command_reg_tck_sync[2];
                data0_sys          <= data0_tck_sync[2];
                data1_sys          <= data1_tck_sync[2];
                command_valid_sys  <= 1'b1;

                // Start each new command with a clean cmderr state.
                // OpenOCD clears cmderr explicitly, but this avoids stale
                // cross-domain residue from blocking a subsequent command.
                cmderr_sys         <= 3'b0;
                data0_result_valid <= 1'b0;
                read_after_exec    <= 1'b0;
                exec_phase_done    <= 1'b0;

                `DEBUG2(`DBG_GRP_DTM, ("Toggle-sync: command latched = 0x%h", command_reg_tck_sync[2]));
            end
            else if (cmd_state == CMD_DONE || (command_valid_sys && cmderr_sys != 3'b0)) begin
                // Clear after FSM finishes or rejected (error set)
                command_valid_sys <= 1'b0;
            end

            // ----------------------------------------------------------------
            // Part 2b: Trigger hit latch - record which trigger(s) fired
            // ----------------------------------------------------------------
            // Part 2b: Trigger hit latch - record which trigger(s) fired
            // ----------------------------------------------------------------
            // trigger_halt_pulse (from sync always_ff) is 1 for exactly ONE
            // cycle on the halt edge of a trigger-caused halt.  The second
            // always_ff reads the COMMITTED value from the previous cycle, which
            // is exactly when trigger_halt_pulse transitions to 1.
            // trigger_hit_i is stable (driven from trigger_hit_r in jv32_core)
            // for the entire debug session until the next resume.
            // The latch is cleared by CMD_CSR_WRITE to 0x7A1 with bit20=0,
            // OR by the next resume (clearing via dbg_halted_i falling edge).
            if (trigger_halt_pulse) begin
                if (trigger_hit_i[0]) trigger_hit_latch[0] <= 1'b1;
                if (trigger_hit_i[1]) trigger_hit_latch[1] <= 1'b1;
            end

            // Clear latch on resume (falling edge of dbg_halted_i)
            if (!dbg_halted_i && dbg_halted_prev_fsm) trigger_hit_latch <= '0;

            if (dbg_halted_i && !dbg_halted_prev_fsm) begin
                // Hart just entered debug mode. Skip DPC capture for CMD_EXEC,
                // because that halt comes from the debug ROM ebreak.
                if (!exec_waiting_halt) dpc_reg <= dbg_pc_i;

                if (dcsr_reg[2]) dcsr_cause_r <= 3'd4;  // step (prio 4) > haltreq (prio 3)
                else if (trigger_halt_i) dcsr_cause_r <= 3'd2;
                else dcsr_cause_r <= 3'd3;
            end

            dbg_halted_prev_fsm <= dbg_halted_i;  // keep edge detector current

            // ----------------------------------------------------------------
            // Part 3: Abstract command FSM (defaults then case)
            // ----------------------------------------------------------------
            cmd_state           <= cmd_state_nx;

            // Default: deassert control signals
            dbg_reg_we_o        <= 1'b0;
            dbg_pc_we_o         <= 1'b0;

            case (cmd_state)
                CMD_IDLE: begin
                    cmd_busy        <= 1'b0;
                    dbg_mem_req_o   <= 1'b0;
                    mem_req_pending <= 1'b0;

                    // Check if new command written (transition from TCK domain)
                    if (command_valid_sys && !cmd_busy) begin
                        if (!dbg_halted_i) begin
                            // Hart must be halted to execute commands
                            cmderr_sys <= CMDERR_HALTRESUME;
                            `DEBUG2(`DBG_GRP_DTM, ("Command rejected: hart not halted"));
                        end
                        else if (cmd_is_access_reg && cmd_transfer) begin
                            // Only 32-bit access size (aarsize=2) is supported.
                            // Rejecting other sizes lets OpenOCD probe DXLEN correctly
                            // (it tries aarsize=3 first; NOTSUP -> falls back to aarsize=2).
                            if (cmd_size != 3'd2) begin
                                cmderr_sys <= CMDERR_NOTSUP;
                                `DEBUG2(`DBG_GRP_DTM, ("Unsupported aarsize=%0d (only 32-bit supported)", cmd_size));
                            end
                            else begin
                                cmd_busy <= 1'b1;
                                if (cmd_regno >= 16'h1000 && cmd_regno < 16'h1020) begin  // GPR x0-x31
                                    if (cmd_write) begin
                                        cmd_state <= CMD_REG_WRITE;
                                        `DEBUG2(`DBG_GRP_DTM,
                                                ("Execute: Write GPR x%0d = 0x%h", cmd_regno - 16'h1000, data0_sys));
                                    end
                                    else begin
                                        // Per Debug Spec 3.7.1.1: postexec runs BEFORE the
                                        // register transfer on a read.  Redirect to CMD_EXEC
                                        // first; after CPU re-halts, CMD_REG_READ captures
                                        // the value the progbuf loaded into the register.
                                        if (cmd_postexec) begin
                                            read_after_exec <= 1'b1;
                                            dbg_pc_wdata_o  <= DEBUG_ROM_BASE;
                                            dbg_pc_we_o     <= 1'b1;
                                            cmd_state       <= CMD_EXEC;
                                            `DEBUG2(`DBG_GRP_DTM,
                                                    ("Execute: Read GPR x%0d with postexec (exec first)", cmd_regno - 16'h1000));
                                        end
                                        else begin
                                            cmd_state <= CMD_REG_READ;
                                            `DEBUG2(`DBG_GRP_DTM, ("Execute: Read GPR x%0d", cmd_regno - 16'h1000));
                                        end
                                    end
                                end
                                else if (cmd_regno == 16'h07b1) begin  // CSR DPC (program counter)
                                    if (cmd_write) begin
                                        cmd_state <= CMD_REG_WRITE;
                                        `DEBUG2(`DBG_GRP_DTM, ("Execute: Write DPC = 0x%h", data0_sys));
                                    end
                                    else begin
                                        if (cmd_postexec) begin
                                            read_after_exec <= 1'b1;
                                            dbg_pc_wdata_o  <= DEBUG_ROM_BASE;
                                            dbg_pc_we_o     <= 1'b1;
                                            cmd_state       <= CMD_EXEC;
                                            `DEBUG2(`DBG_GRP_DTM, ("Execute: Read DPC with postexec (exec first)"));
                                        end
                                        else begin
                                            cmd_state <= CMD_REG_READ;
                                            `DEBUG2(`DBG_GRP_DTM, ("Execute: Read DPC"));
                                        end
                                    end
                                end
                                else if (cmd_regno == 16'h07b0 ||
                                         cmd_regno == 16'h07b2 ||
                                         cmd_regno == 16'h07b3 ||
                                         cmd_regno == 16'h07A0 ||  // tselect
                                    cmd_regno == 16'h07A1 ||      // tdata1
                                    cmd_regno == 16'h07A2 ||      // tdata2
                                    cmd_regno == 16'h07A4 ||      // tinfo (read-only)
                                    cmd_regno == 16'h0301 ||      // misa (read-only)
                                    cmd_regno == 16'h0C22 ||      // vlenb (no vector extension -> 0)
                                    cmd_regno == 16'h0FB0 ||      // mtopi (optional interrupt-top CSR, absent -> 0)
                                    cmd_regno == 16'h0F14 ||      // mhartid (read-only)
                                    cmd_regno == 16'h0F11 ||      // mvendorid (read-only)
                                    cmd_regno == 16'h0F12 ||      // marchid (read-only)
                                    cmd_regno == 16'h0F13) begin  // mimpid (read-only)
                                    if (cmd_write) begin
                                        cmd_state <= CMD_CSR_WRITE;
                                        `DEBUG2(`DBG_GRP_DTM, ("Execute: Write CSR 0x%h = 0x%h", cmd_regno, data0_sys));
                                    end
                                    else begin
                                        cmd_state <= CMD_CSR_READ;
                                        `DEBUG2(`DBG_GRP_DTM, ("Execute: Read CSR 0x%h", cmd_regno));
                                    end
                                end
                                else if (cmd_regno == 16'h0300 ||  // mstatus
                                    cmd_regno == 16'h0304 ||      // mie
                                    cmd_regno == 16'h0305 ||      // mtvec
                                    cmd_regno == 16'h0340 ||      // mscratch
                                    cmd_regno == 16'h0341 ||      // mepc
                                    cmd_regno == 16'h0342 ||      // mcause
                                    cmd_regno == 16'h0343 ||      // mtval
                                    cmd_regno == 16'h0344) begin  // mip
                                    // M-mode CSRs are not owned by the DM.
                                    // CMDERR_NOTSUP causes OpenOCD to fall back to progbuf
                                    // execution (CSRRW on the real CPU), which reads/writes
                                    // the live CPU CSR state correctly.
                                    cmderr_sys <= CMDERR_NOTSUP;
                                    `DEBUG2(`DBG_GRP_DTM,
                                            ("M-mode CSR 0x%h: NOTSUP -> OpenOCD will use progbuf", cmd_regno));
                                end
                                else begin
                                    // Unknown register: return 0 for reads, silently accept writes.
                                    // Do NOT issue CMDERR_NOTSUP - that would cause OpenOCD to fall
                                    // back to progbuf execution, injecting an illegal-instruction CSR
                                    // access in M-mode that corrupts the hart state.
                                    if (!cmd_write) begin
                                        data0_result       <= 32'h0;
                                        data0_result_valid <= 1'b1;
                                    end
                                    cmd_state <= CMD_DONE;
                                    `DEBUG2(`DBG_GRP_DTM, ("Unknown register 0x%h: returning 0", cmd_regno));
                                end
                            end  // end else begin (aarsize==2 supported)
                        end
                        else if (cmd_is_access_reg && !cmd_transfer && cmd_postexec) begin
                            // postexec without transfer: execute progbuf only
                            cmd_busy       <= 1'b1;
                            dbg_pc_wdata_o <= DEBUG_ROM_BASE;
                            dbg_pc_we_o    <= 1'b1;
                            cmd_state      <= CMD_EXEC;
                            `DEBUG2(`DBG_GRP_DTM, ("execute progbuf (no transfer): DPC=0x%h", DEBUG_ROM_BASE));
                        end
                        else if (cmd_is_access_mem) begin
                            cmd_busy <= 1'b1;
                            // Load address: use data1 if address hasn't been postincremented yet,
                            // otherwise use the pre-incremented value from previous mem op.
                            // Check if data1 has changed since last dispatch by comparing with stored value.
                            // For simplicity, always load from data1 or mem_post_addr.
                            // If postincrement was enabled, mem_post_addr holds the next address.
                            // First access: mem_post_addr = 0 (or use data1).
                            // Use: if (mem_aarpostincrement_r && mem_post_addr != 0) then use pre-incremented,
                            // else load fresh from data1.
                            if (mem_aarpostincrement_r && mem_post_addr != 0) begin
                                // Continuing postincrement sequence
                                mem_addr <= mem_post_addr;
                            end
                            else begin
                                // New sequence or no postincrement: load from data1
                                mem_addr <= data1_sys;
                            end
                            mem_aarpostincrement_r <= mem_aarpostincrement;  // Capture postincrement flag for current op
                            if (mem_write_cmd) begin
                                cmd_state <= CMD_MEM_WRITE;
                                `DEBUG2(`DBG_GRP_DTM,
                                        ("Execute: Write memory[0x%h] = 0x%h", (mem_aarpostincrement_r && mem_post_addr != 0) ? mem_post_addr : data1, data0_sys));
                            end
                            else begin
                                cmd_state <= CMD_MEM_READ;
                                `DEBUG2(`DBG_GRP_DTM,
                                        ("Execute: Read memory[0x%h]", (mem_aarpostincrement_r && mem_post_addr != 0) ? mem_post_addr : data1));
                            end
                        end
                        else begin
                            cmderr_sys <= CMDERR_NOTSUP;
                            `DEBUG2(`DBG_GRP_DTM, ("Unsupported command type"));
                        end
                    end

                    // SBA: handle pending SBA read/write (independent of halt/abstract state)
                    if (!command_valid_sys || cmd_busy) begin
                        if (sba_rd_toggle_sync[2] != sba_rd_toggle_r && !mem_req_pending) begin
                            // Toggle synced: data in TCK domain is stable, safe to sample from holding register
                            sbaddress0_clk          <= sbaddress0_stable;  // Use stable holding register for CDC
                            sbdata0_result_valid    <= 1'b0;
                            sbaddress0_result_valid <= 1'b0;
                            cmd_state               <= CMD_SBA_READ;
                            sba_wait_cnt            <= 4'b0;
                        end
                        else if (sba_wr_toggle_sync[2] != sba_wr_toggle_r && !mem_req_pending) begin
                            // Toggle synced: data in TCK domain is stable, safe to sample directly
                            sbaddress0_clk          <= sbaddress0;
                            sbdata0_clk             <= sbdata0;
                            sbdata0_result_valid    <= 1'b0;
                            sbaddress0_result_valid <= 1'b0;
                            cmd_state               <= CMD_SBA_WRITE;
                            sba_wait_cnt            <= 4'b0;
                        end
                    end
                end  // CMD_IDLE

                CMD_REG_READ: begin
                    // Set register address so the combinatorial read port settles.
                    // Data is captured one cycle later in CMD_WAIT.
                    if (cmd_regno >= 16'h1000 && cmd_regno < 16'h1020) begin  // GPR
                        dbg_reg_addr_o <= 5'(cmd_regno - 16'h1000);
                        `DEBUG2(`DBG_GRP_DTM, ("Read GPR x%0d: addr set, waiting 1 cycle", cmd_regno - 16'h1000));
                    end
                    // DPC (0x7b1) needs no address change; handled in CMD_WAIT
                    // cmd_state_nx will transition to CMD_WAIT
                end

                CMD_WAIT: begin
                    // Register file address has settled; capture the read data now.
                    if (cmd_regno >= 16'h1000 && cmd_regno < 16'h1020) begin  // GPR
                        data0_result       <= dbg_reg_rdata_i;
                        data0_result_valid <= 1'b1;
                        `DEBUG2(`DBG_GRP_DTM, ("Read GPR x%0d = 0x%h", cmd_regno - 16'h1000, dbg_reg_rdata_i));
                    end
                    else if (cmd_regno == 16'h07b1) begin  // CSR DPC
                        data0_result       <= dpc_reg;
                        data0_result_valid <= 1'b1;
                        `DEBUG2(`DBG_GRP_DTM, ("Read DPC = 0x%h (dpc_reg)", dpc_reg));
                    end
                    // Only redirect to progbuf when exec has NOT already run.
                    // exec_phase_done=1 means we arrived here from CMD_EXEC (read_after_exec
                    // path) so the progbuf already executed; just capture and finish.
                    if (cmd_postexec && !exec_phase_done) begin
                        // Redirect CPU to progbuf for post-execute
                        dbg_pc_wdata_o <= DEBUG_ROM_BASE;
                        dbg_pc_we_o    <= 1'b1;
                        `DEBUG2(`DBG_GRP_DTM, ("Postexec: redirect DPC to progbuf 0x%h", DEBUG_ROM_BASE));
                    end
                    // cmd_state transition is handled in cmd_state_nx (always_comb)
                end

                CMD_REG_WRITE: begin
                    // Write register value
                    if (cmd_regno >= 16'h1000 && cmd_regno < 16'h1020) begin  // GPR
                        dbg_reg_addr_o  <= 5'(cmd_regno - 16'h1000);
                        dbg_reg_wdata_o <= data0_sys;
                        dbg_reg_we_o    <= 1'b1;
                        `DEBUG2(`DBG_GRP_DTM, ("Write GPR x%0d = 0x%h", cmd_regno - 16'h1000, data0_sys));
                    end
                    else if (cmd_regno == 16'h07b1) begin  // CSR DPC
                        dbg_pc_wdata_o <= data0_sys;
                        dbg_pc_we_o    <= 1'b1;
                        dpc_reg        <= data0_sys;  // Save user DPC - survives CMD_EXEC
                        `DEBUG2(`DBG_GRP_DTM, ("Write DPC = 0x%h", data0_sys));
                    end
                    if (cmd_postexec) begin
                        // Redirect CPU to progbuf for post-execute
                        dbg_pc_wdata_o <= DEBUG_ROM_BASE;
                        dbg_pc_we_o    <= 1'b1;
                        `DEBUG2(`DBG_GRP_DTM, ("Postexec: redirect DPC to progbuf 0x%h", DEBUG_ROM_BASE));
                    end
                    // cmd_state transition is handled in cmd_state_nx (always_comb)
                end

                CMD_CSR_READ: begin
                    // Synthetic CSR read (stored in DTM registers or hardcoded)
                    case (cmd_regno)
                        16'h07b0: begin  // dcsr: overlay cause bits from dcsr_cause_r
                            data0_result <= {4'd4, dcsr_reg[27:9], dcsr_cause_r, dcsr_reg[5:0]};
                            `DEBUG2(`DBG_GRP_DTM, ("Read DCSR = 0x%h", {
                                    4'd4, dcsr_reg[27:9], dcsr_cause_r, dcsr_reg[5:0]}));
                        end
                        16'h07b2: begin  // dscratch0
                            data0_result <= dscratch0_reg;
                            `DEBUG2(`DBG_GRP_DTM, ("Read DSCRATCH0 = 0x%h", dscratch0_reg));
                        end
                        16'h07b3: begin  // dscratch1
                            data0_result <= dscratch1_reg;
                            `DEBUG2(`DBG_GRP_DTM, ("Read DSCRATCH1 = 0x%h", dscratch1_reg));
                        end
                        // Machine-mode CSRs - synthesized values (hart is halted)
                        16'h0301: begin  // misa: RV32IMAC (no F/D/V so OpenOCD won't probe those files)
                            // MXL=1(RV32)|A(0)|C(2)|I(8)|M(12) = 0x40001105
                            data0_result <= 32'h40001105;
                            `DEBUG2(`DBG_GRP_DTM, ("Read MISA = 0x40001105 (RV32IMAC)"));
                        end
                        16'h0C22: begin  // vlenb: no vector extension present
                            data0_result <= 32'h0;
                            `DEBUG2(`DBG_GRP_DTM, ("Read vlenb = 0 (no vector extension)"));
                        end
                        16'h0FB0: begin  // mtopi: optional interrupt-top CSR not implemented
                            data0_result <= 32'h0;
                            `DEBUG2(`DBG_GRP_DTM, ("Read mtopi = 0 (not implemented)"));
                        end
                        16'h0F14: begin  // mhartid: single hart, ID=0
                            data0_result <= 32'h0;
                            `DEBUG2(`DBG_GRP_DTM, ("Read mhartid = 0"));
                        end
                        16'h0F11: begin  // mvendorid
                            data0_result <= 32'h0;
                            `DEBUG2(`DBG_GRP_DTM, ("Read mvendorid = 0"));
                        end
                        16'h0F12: begin  // marchid
                            data0_result <= 32'h0;
                            `DEBUG2(`DBG_GRP_DTM, ("Read marchid = 0"));
                        end
                        16'h0F13: begin  // mimpid
                            data0_result <= 32'h0;
                            `DEBUG2(`DBG_GRP_DTM, ("Read mimpid = 0"));
                        end
                        16'h07A0: begin  // tselect
                            data0_result <= tselect_reg;
                            `DEBUG2(`DBG_GRP_DTM, ("Read tselect = %0d", tselect_reg));
                        end
                        16'h07A1: begin  // tdata1 (indexed by tselect): fold in hit latch bit 20
                            begin
                                // bits[31:27]=dmode+type(fixed), bits[26:21]=HARDWARE_MASKMAX(RO),
                                // bit[20]=hit latch, bits[19:0]=stored fields
                                data0_result <= {
                                    tdata1_reg[tselect_reg[$clog2(N_TRIGGERS)-1:0]][31:27],
                                    HARDWARE_MASKMAX,
                                    trigger_hit_latch[tselect_reg[$clog2(N_TRIGGERS)-1:0]],
                                    tdata1_reg[tselect_reg[$clog2(N_TRIGGERS)-1:0]][19:0]
                                };
                                `DEBUG2(`DBG_GRP_DTM, ("Read tdata1[%0d] = 0x%h (hit=%0b)", tselect_reg[$clog2(
                                        N_TRIGGERS)-1:0], tdata1_reg[tselect_reg[$clog2(N_TRIGGERS
                                        )-1:0]], trigger_hit_latch[tselect_reg[$clog2(N_TRIGGERS)-1:0]]));
                            end
                        end
                        16'h07A2: begin  // tdata2 (indexed by tselect)
                            data0_result <= tdata2_reg[tselect_reg[$clog2(N_TRIGGERS)-1:0]];
                            `DEBUG2(`DBG_GRP_DTM,
                                    ("Read tdata2[%0d] = 0x%h", tselect_reg, tdata2_reg[tselect_reg[$clog2(N_TRIGGERS
                                    )-1:0]]));
                        end
                        16'h07A4: begin  // tinfo: VERSION=0, INFO=4 (type-2/mcontrol supported)
                            data0_result <= 32'h0000_0004;
                            `DEBUG2(`DBG_GRP_DTM, ("Read tinfo = 0x4 (mcontrol type-2)"));
                        end
                        default: begin
                            // Return 0 for unknown CSRs - prevents OpenOCD from
                            // falling back to progbuf execution which would cause
                            // an illegal-instruction exception in M-mode.
                            data0_result <= 32'h0;
                        end
                    endcase
                    data0_result_valid <= 1'b1;
                    cmd_state          <= CMD_DONE;
                end

                CMD_CSR_WRITE: begin
                    // Synthetic CSR write; xdebugver[31:28] always read-only = 4
                    case (cmd_regno)
                        16'h07b0: begin  // dcsr: preserve xdebugver in upper nibble
                            dcsr_reg     <= {4'd4, data0_sys[27:0]};
                            dcsr_cause_r <= data0_sys[8:6];  // Track cause from write
                            `DEBUG2(`DBG_GRP_DTM, ("Write DCSR = 0x%h", {4'd4, data0_sys[27:0]}));
                        end
                        16'h07b2: begin  // dscratch0
                            dscratch0_reg <= data0_sys;
                            `DEBUG2(`DBG_GRP_DTM, ("Write DSCRATCH0 = 0x%h", data0_sys));
                        end
                        16'h07b3: begin  // dscratch1
                            dscratch1_reg <= data0_sys;
                            `DEBUG2(`DBG_GRP_DTM, ("Write DSCRATCH1 = 0x%h", data0_sys));
                        end
                        // Accept writes silently (no error) for CSRs not owned by DM
                        16'h0300,        // mstatus
                        16'h0304,        // mie
                        16'h0305,        // mtvec
                        16'h0340,        // mscratch
                        16'h0341,        // mepc
                        16'h0342,        // mcause
                        16'h0343,        // mtval
                        16'h0344,        // mip
                        16'h0301,        // misa
                        16'h0C22,        // vlenb
                        16'h0FB0,        // mtopi
                        16'h0F14,        // mhartid
                        16'h0F11,        // mvendorid
                        16'h0F12,        // marchid
                        16'h0F13: begin  // mimpid
                            `DEBUG2(`DBG_GRP_DTM, ("Write to non-DM CSR 0x%h, ignored", cmd_regno));
                        end
                        16'h07A0: begin  // tselect: only accept values 0..N_TRIGGERS-1
                            if (data0_sys < 32'(N_TRIGGERS)) tselect_reg <= data0_sys;
                            `DEBUG2(`DBG_GRP_DTM,
                                    ("Write tselect = %0d (accepted=%0b)", data0_sys, data0_sys < 32'(N_TRIGGERS)));
                        end
                        16'h07A1: begin  // tdata1: preserve type=2 in bits[31:28]
                            tdata1_reg[tselect_reg[$clog2(N_TRIGGERS)-1:0]]        <= {4'd2, data0_sys[27:0]};
                            // Mirror bit 20 (hit) from the write into trigger_hit_latch.
                            // HW sets the bit on trigger halt; SW can also set/clear it.
                            // This makes bit 20 fully readable via CMD_CSR_READ.
                            trigger_hit_latch[tselect_reg[$clog2(N_TRIGGERS)-1:0]] <= data0_sys[20];
                            `DEBUG2(`DBG_GRP_DTM, ("Write tdata1[%0d] = 0x%h", tselect_reg, {4'd2, data0_sys[27:0]}));
                        end
                        16'h07A2: begin  // tdata2
                            tdata2_reg[tselect_reg[$clog2(N_TRIGGERS)-1:0]] <= data0_sys;
                            `DEBUG2(`DBG_GRP_DTM, ("Write tdata2[%0d] = 0x%h", tselect_reg, data0_sys));
                        end
                        default: begin
                            // Silently ignore writes to unknown CSRs - same as read-only
                            `DEBUG2(`DBG_GRP_DTM, ("Write to unknown CSR 0x%h, ignored", cmd_regno));
                        end
                    endcase
                    cmd_state <= CMD_DONE;
                end

                CMD_MEM_READ: begin
                    if (!mem_req_pending) begin
                        dbg_mem_req_o   <= 1'b1;
                        dbg_mem_addr_o  <= mem_addr;
                        dbg_mem_we_o    <= 4'b0;  // Read
                        mem_req_pending <= 1'b1;
                        mem_wait_cnt    <= 4'b0;
                    end
                    else if (dbg_mem_ready_i) begin
                        // Memory read complete - check for AXI error (DECERR/SLVERR)
                        if (dbg_mem_error_i) begin
                            cmderr_sys <= CMDERR_EXCEPTION;  // Bus error -> abstractcs.cmderr
                            `DEBUG2(`DBG_GRP_DTM, ("Memory read error at 0x%h (DECERR/SLVERR)", mem_addr));
                        end
                        else begin
                            data0_result       <= dbg_mem_rdata_i;
                            data0_result_valid <= 1'b1;
                            // Implement aarpostincrement: auto-increment addr1 by 4 (for aarsize=2)
                            if (mem_aarpostincrement_r) begin
                                mem_post_addr <= mem_addr + 32'd4;
                                `DEBUG2(`DBG_GRP_DTM,
                                        ("Memory read complete: 0x%h; postincrement: addr1 += 4 (next=0x%h)", dbg_mem_rdata_i, mem_addr + 32'd4));
                            end
                            else begin
                                mem_post_addr <= 32'b0;  // Clear for next sequence
                                `DEBUG2(`DBG_GRP_DTM, ("Memory read complete: 0x%h", dbg_mem_rdata_i));
                            end
                        end
                        dbg_mem_req_o   <= 1'b0;
                        mem_req_pending <= 1'b0;
                        cmd_state       <= CMD_DONE;
                    end
                    else begin
                        // Wait for memory
                        mem_wait_cnt <= mem_wait_cnt + 1;
                        if (mem_wait_cnt == 4'b1111) begin
                            // Timeout (16 cycles)
                            cmderr_sys      <= CMDERR_BUS;
                            dbg_mem_req_o   <= 1'b0;
                            mem_req_pending <= 1'b0;
                            cmd_state       <= CMD_DONE;
                            `DEBUG2(`DBG_GRP_DTM, ("Memory read timeout"));
                        end
                    end
                end

                CMD_MEM_WRITE: begin
                    if (!mem_req_pending) begin
                        // Issue memory write request
                        dbg_mem_req_o   <= 1'b1;
                        dbg_mem_addr_o  <= mem_addr;
                        dbg_mem_wdata_o <= data0_sys;
                        dbg_mem_we_o    <= 4'b1111;  // Write all bytes
                        mem_req_pending <= 1'b1;
                        mem_wait_cnt    <= 4'b0;
                    end
                    else if (dbg_mem_ready_i) begin
                        // Memory write complete - check for AXI error
                        dbg_mem_req_o   <= 1'b0;
                        mem_req_pending <= 1'b0;
                        if (dbg_mem_error_i) begin
                            cmderr_sys <= CMDERR_EXCEPTION;
                            `DEBUG2(`DBG_GRP_DTM, ("Memory write error at 0x%h (DECERR/SLVERR)", mem_addr));
                        end
                        else begin
                            // Implement aarpostincrement: auto-increment addr1 by 4 (for aarsize=2)
                            if (mem_aarpostincrement_r) begin
                                mem_post_addr <= mem_addr + 32'd4;
                                `DEBUG2(
                                    `DBG_GRP_DTM,
                                    ("Memory write complete; postincrement: addr1 += 4 (next=0x%h)", mem_addr + 32'd4));
                            end
                            else begin
                                mem_post_addr <= 32'b0;  // Clear for next sequence
                                `DEBUG2(`DBG_GRP_DTM, ("Memory write complete"));
                            end
                        end
                        cmd_state <= CMD_DONE;
                    end
                    else begin
                        // Wait for memory
                        mem_wait_cnt <= mem_wait_cnt + 1;
                        if (mem_wait_cnt == 4'b1111) begin
                            // Timeout (16 cycles)
                            cmderr_sys      <= CMDERR_BUS;
                            dbg_mem_req_o   <= 1'b0;
                            mem_req_pending <= 1'b0;
                            cmd_state       <= CMD_DONE;
                            `DEBUG2(`DBG_GRP_DTM, ("Memory write timeout"));
                        end
                    end
                end

                CMD_SBA_READ: begin
                    if (!mem_req_pending) begin
                        // Use address already sampled when toggle was detected (line ~1531)
                        // Issue SBA memory read (always read full 32-bit word)
                        dbg_mem_req_o   <= 1'b1;
                        dbg_mem_addr_o  <= {sbaddress0_clk[31:2], 2'b00};
                        dbg_mem_we_o    <= 4'b0;
                        mem_req_pending <= 1'b1;
                        sba_wait_cnt    <= 4'b0;
                    end
                    else if (dbg_mem_ready_i) begin
                        // Store extracted result (from always_comb) in CLK-domain register
                        sbdata0_clk             <= sba_rdata_masked;
                        sbdata0_result_valid    <= 1'b1;
                        dbg_mem_req_o           <= 1'b0;
                        mem_req_pending         <= 1'b0;
                        // Autoincrement DISABLED (removed to fix CDC bug)
                        sbaddress0_result_valid <= 1'b0;
                        cmd_state               <= CMD_IDLE;
                        `DEBUG2(`DBG_GRP_DTM, ("SBA Read [0x%h] = 0x%h", sbaddress0_clk, sba_rdata_masked));
                    end
                    else begin
                        sba_wait_cnt <= sba_wait_cnt + 1;
                        if (sba_wait_cnt == 4'b1111) begin
                            sb_err          <= 3'd2;  // error=2: timeout
                            dbg_mem_req_o   <= 1'b0;
                            mem_req_pending <= 1'b0;
                            cmd_state       <= CMD_IDLE;
                            `DEBUG2(`DBG_GRP_DTM, ("SBA Read timeout"));
                        end
                    end
                end

                CMD_SBA_WRITE: begin
                    if (!mem_req_pending) begin
                        // Issue SBA memory write with computed byte enables (from always_comb block)
                        dbg_mem_req_o   <= 1'b1;
                        dbg_mem_addr_o  <= {sbaddress0_clk[31:2], 2'b00};  // Word-aligned
                        dbg_mem_wdata_o <= sba_wdata_positioned;
                        dbg_mem_we_o    <= sba_wstrb;
                        mem_req_pending <= 1'b1;
                        sba_wait_cnt    <= 4'b0;
                    end
                    else if (dbg_mem_ready_i) begin
                        dbg_mem_req_o           <= 1'b0;
                        mem_req_pending         <= 1'b0;
                        // Autoincrement DISABLED (removed to fix CDC bug)
                        sbaddress0_result_valid <= 1'b0;
                        cmd_state               <= CMD_IDLE;
                        `DEBUG2(`DBG_GRP_DTM,
                                ("SBA Write [0x%h] = 0x%h (wstrb=%b)", sbaddress0_clk, sbdata0_clk, sba_wstrb));
                    end
                    else begin
                        sba_wait_cnt <= sba_wait_cnt + 1;
                        if (sba_wait_cnt == 4'b1111) begin
                            sb_err          <= 3'd2;  // error=2: timeout
                            dbg_mem_req_o   <= 1'b0;
                            mem_req_pending <= 1'b0;
                            cmd_state       <= CMD_IDLE;
                            `DEBUG2(`DBG_GRP_DTM, ("SBA Write timeout"));
                        end
                    end
                end

                CMD_EXEC: begin
                    // Execute progbuf: DPC was already written; issue resume then wait for re-halt
                    if (!exec_waiting_halt) begin
                        // Issue resume to CPU
                        exec_resume_req    <= 1'b1;
                        exec_waiting_halt  <= 1'b1;
                        exec_seen_running  <= 1'b0;
                        exec_wait_cnt      <= '0;
                        exec_fault_halting <= 1'b0;
                        exec_halt_req      <= 1'b0;
                        `DEBUG2(`DBG_GRP_DTM, ("CMD_EXEC: resuming CPU for progbuf execution"));
                    end
                    else if (exec_fault_halting) begin
                        // Fault/timeout detected: waiting for CPU to halt via exec_halt_req
                        exec_resume_req <= 1'b0;
                        if (dbg_halted_i) begin
                            exec_halt_req      <= 1'b0;
                            exec_fault_halting <= 1'b0;
                            exec_waiting_halt  <= 1'b0;
                            read_after_exec    <= 1'b0;  // abort deferred read on fault
                            cmd_state          <= CMD_DONE;
                            `DEBUG2(`DBG_GRP_DTM, ("CMD_EXEC: CPU halted after fault, progbuf done with exception"));
                        end
                    end
                    else begin
                        // Pulse resume request for one cycle, then watch for run->halt.
                        exec_resume_req <= 1'b0;

                        if (!dbg_halted_i) begin
                            exec_seen_running <= 1'b1;
                        end

                        if (dbg_halted_i && exec_seen_running) begin
                            // CPU has re-halted after executing progbuf.
                            exec_waiting_halt <= 1'b0;
                            if (read_after_exec) begin
                                // This exec was the first step of a read+postexec.
                                // Now do the deferred register read.
                                read_after_exec <= 1'b0;
                                exec_phase_done <= 1'b1;
                                cmd_state       <= CMD_REG_READ;
                                `DEBUG2(`DBG_GRP_DTM, ("CMD_EXEC: progbuf done, proceeding to deferred register read"));
                            end
                            else begin
                                cmd_state <= CMD_DONE;
                                `DEBUG2(`DBG_GRP_DTM, ("CMD_EXEC: CPU re-halted, progbuf done"));
                            end
                        end
                        else begin
                            exec_wait_cnt <= exec_wait_cnt + 24'd1;
                            if (exec_wait_cnt == EXEC_TIMEOUT_CYCLES) begin
                                cmderr_sys         <= CMDERR_EXCEPTION;
                                exec_fault_halting <= 1'b1;
                                exec_halt_req      <= 1'b1;
                                `DEBUG2(`DBG_GRP_DTM,
                                        ("CMD_EXEC: timeout waiting re-halt after %0d cycles, cmderr=exception, halting CPU", EXEC_TIMEOUT_CYCLES));
                            end
                        end
                    end
                end

                CMD_DONE: begin
                    cmd_busy        <= 1'b0;
                    exec_phase_done <= 1'b0;  // clear for next command

                    // Restore pc_if to the saved DPC.  This undoes any CMD_EXEC side-effect
                    // (CMD_EXEC redirects pc_if to DEBUG_ROM_BASE for progbuf execution).
                    // For non-CMD_EXEC commands dpc_reg already equals the current pc_if.
                    dbg_pc_we_o     <= 1'b1;
                    dbg_pc_wdata_o  <= dpc_reg;

                    // Don't clear command_reg here - it's in TCK domain
                    cmd_state       <= CMD_IDLE;
                end

                default: begin
                    cmd_state <= CMD_IDLE;
                end
            endcase
        end
    end

    // Command state machine next-state logic
    always_comb begin
        cmd_state_nx = cmd_state;
        case (cmd_state)
            CMD_IDLE: begin
                // Handled in sequential block
                cmd_state_nx = cmd_state;
            end
            CMD_REG_READ: begin
                cmd_state_nx = CMD_WAIT;  // Address setup; data captured in CMD_WAIT
            end
            CMD_WAIT: begin
                // If postexec is set AND exec has not already run, jump to CMD_EXEC.
                // exec_phase_done=1 means we arrived here after CMD_EXEC (read_after_exec
                // path): the progbuf already ran, so go straight to CMD_DONE.
                cmd_state_nx = (cmd_postexec && !exec_phase_done) ? CMD_EXEC : CMD_DONE;
            end
            CMD_REG_WRITE: begin
                // If postexec is set, jump to CMD_EXEC (DPC redirect issued in sequential block)
                cmd_state_nx = cmd_postexec ? CMD_EXEC : CMD_DONE;
            end
            CMD_CSR_READ, CMD_CSR_WRITE: begin
                cmd_state_nx = CMD_DONE;
            end
            CMD_MEM_READ, CMD_MEM_WRITE, CMD_SBA_READ, CMD_SBA_WRITE, CMD_EXEC: begin
                // Stays in state until memory/exec completes (handled in sequential block)
                cmd_state_nx = cmd_state;
            end
            CMD_DONE: begin
                cmd_state_nx = CMD_IDLE;
            end
            default: begin
                cmd_state_nx = CMD_IDLE;
            end
        endcase
    end
    // ========================================================================
    // TDO Output Multiplexer
    // ========================================================================
    always_comb begin
        case (ir_i)
            IR_IDCODE: tdo_o = idcode_shift[0];
            IR_DTMCS:  tdo_o = dtmcs_shift[0];
            IR_DMI:    tdo_o = dmi_shift[0];
            IR_BYPASS: tdo_o = bypass_shift;
            default:   tdo_o = bypass_shift;
        endcase
    end

    // Debug control signals derived from dcsr register
    assign dbg_singlestep_o = cmd_busy ? 1'b0 : dcsr_reg[2];  // Suppress during cmd_busy (progbuf execution)
    assign dbg_ebreakm_o    = dcsr_reg[15];                   // dcsr.ebreakm = bit[15] per Debug Spec 0.13
    assign progbuf0_o       = progbuf0;
    assign progbuf1_o       = progbuf1;

`ifndef SYNTHESIS
    // Lint sink: signals not consumed in current implementation.
    logic _unused_ok_dtm;
    assign _unused_ok_dtm = &{1'b0, dcsr_reg[31:28],  // xdebugver always forced to 4'd4; these bits never used
        dcsr_reg[14:13],                           // ebreaks/ebreaku: not individually consumed here
        dcsr_reg[12:9],                            // stepie/stopcount/stoptime/halt: forwarded but not consumed individually
        dcsr_reg[3],                               // nmip: not implemented in this core
        command_reg_sys[23], command_reg_sys[19],  // reserved bits in AC_ACCESS_REGISTER
        data0_result_valid_sync_r,                 // retained for future edge-detect use
        halted_clk,                                // synchronized debug-halted status (reserved)
        sbdata0_result_valid_sync_r, sbaddress0_result_valid_sync_r};
`endif  // SYNTHESIS

endmodule

