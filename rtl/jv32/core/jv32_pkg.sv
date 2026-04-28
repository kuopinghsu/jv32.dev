// ============================================================================
// File        : jv32_pkg.sv
// Project     : JV32 RISC-V Processor
// Description : RV32IMAC Core Package
//
// Defines types, enums, top-level parameters, and pipeline register structs
// used by the JV32 3-stage (IF->EX->WB) RV32IMAC processor core.
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

// Macros are defined in jv32_dbgmsg.svh (Vivado global include).
// The `include here ensures simulation tools that compile jv32_pkg.sv
// directly also have the macros available.
`include "jv32_dbgmsg.svh"

package jv32_pkg;

    // ========================================================================
    // Debug group name helper (used by DEBUG2 macro)
    // ========================================================================
`ifndef SYNTHESIS
    function automatic string dbg_grp_name(int unsigned idx);
        case (idx)
            `DBG_GRP_FETCH: return "FETCH ";
            `DBG_GRP_PIPE:  return "PIPE  ";
            `DBG_GRP_EX:    return "EX    ";
            `DBG_GRP_MEM:   return "MEM   ";
            `DBG_GRP_CSR:   return "CSR   ";
            `DBG_GRP_IRQ:   return "IRQ   ";
            `DBG_GRP_UART:  return "UART  ";
            `DBG_GRP_CLIC:  return "CLIC  ";
            `DBG_GRP_MAGIC: return "MAGIC ";
            `DBG_GRP_JTAG:  return "JTAG  ";
            `DBG_GRP_DTM:   return "DTM   ";
            default:        return "???   ";
        endcase
    endfunction
`endif

    // ========================================================================
    // Top-Level SoC Configuration Parameters
    // ========================================================================
    /* verilator lint_off UNUSEDPARAM */
    localparam int unsigned FAST_MUL       = 1;              // 1=comb, 0=serial (32 cyc)
    localparam int unsigned MUL_MC         = 1;              // 1=2-stage pipelined (2 cyc); 0=1-cycle comb.
    localparam int unsigned FAST_DIV       = 0;              // 1=comb, 0=serial (33 cyc)
    localparam int unsigned FAST_SHIFT     = 1;              // 1=barrel, 0=serial 1-bit/cyc
    localparam int unsigned BP_EN          = 1;              // 1=BTB+RAS, 0=predict-not-taken
    localparam int unsigned AMO_EN         = 1;              // 1=full A-extension, 0=AMO decode as illegal
    localparam bit          RV32E_EN       = 0;              // 1=RV32E (16 GPRs), 0=RV32I (32 GPRs)
    localparam bit          RV32M_EN       = 1;              // 1=M-extension (mul/div), 0=illegal
    localparam bit          JTAG_EN        = 1;              // 1=JTAG debug port present, 0=no JTAG
    localparam bit          TRACE_EN       = 1;              // 1=trace outputs active, 0=tied to 0 in synthesis
    localparam bit          RV32B_EN       = 1;              // 1=Zba/Zbb/Zbs bit-manip extensions, 0=illegal
    localparam int unsigned IRAM_SIZE      = 262144;         // bytes (256 KB)
    localparam int unsigned DRAM_SIZE      = 262144;         // bytes (256 KB)
    localparam int unsigned AXI_DATA_WIDTH = 32;             // 32-bit AXI data bus
    localparam logic [31:0] BOOT_ADDR      = 32'h8000_0000;  // reset PC
    /* verilator lint_on UNUSEDPARAM */

    // ========================================================================
    // Opcodes (7-bit)
    // ========================================================================
    typedef enum logic [6:0] {
        OPCODE_LOAD     = 7'b0000011,
        OPCODE_STORE    = 7'b0100011,
        OPCODE_BRANCH   = 7'b1100011,
        OPCODE_JAL      = 7'b1101111,
        OPCODE_JALR     = 7'b1100111,
        OPCODE_OP_IMM   = 7'b0010011,
        OPCODE_OP       = 7'b0110011,
        OPCODE_LUI      = 7'b0110111,
        OPCODE_AUIPC    = 7'b0010111,
        OPCODE_SYSTEM   = 7'b1110011,
        OPCODE_MISC_MEM = 7'b0001111,
        OPCODE_AMO      = 7'b0101111
    } opcode_e;

    // ========================================================================
    // ALU operations - RV32IM + optional Zba/Zbb/Zbs
    // ========================================================================
    typedef enum logic [5:0] {
        // Base RV32I / M-extension
        ALU_ADD,     // 0
        ALU_SUB,     // 1
        ALU_SLL,     // 2
        ALU_SLT,     // 3
        ALU_SLTU,    // 4
        ALU_XOR,     // 5
        ALU_SRL,     // 6
        ALU_SRA,     // 7
        ALU_OR,      // 8
        ALU_AND,     // 9
        ALU_MUL,     // 10
        ALU_MULH,    // 11
        ALU_MULHSU,  // 12
        ALU_MULHU,   // 13
        ALU_DIV,     // 14
        ALU_DIVU,    // 15
        ALU_REM,     // 16
        ALU_REMU,    // 17
        // Zba — address generation
        ALU_SH1ADD,  // 18  rd = (rs1 << 1) + rs2
        ALU_SH2ADD,  // 19  rd = (rs1 << 2) + rs2
        ALU_SH3ADD,  // 20  rd = (rs1 << 3) + rs2
        // Zbb — basic bit manipulation
        ALU_CLZ,    // 21  count leading zeros
        ALU_CTZ,    // 22  count trailing zeros
        ALU_CPOP,   // 23  popcount
        ALU_ANDN,   // 24  rs1 & ~rs2
        ALU_ORN,    // 25  rs1 | ~rs2
        ALU_XNOR,   // 26  rs1 ^ ~rs2
        ALU_MIN,    // 27  signed min
        ALU_MINU,   // 28  unsigned min
        ALU_MAX,    // 29  signed max
        ALU_MAXU,   // 30  unsigned max
        ALU_SEXTB,  // 31  sign-extend byte
        ALU_SEXTH,  // 32  sign-extend halfword
        ALU_ZEXTH,  // 33  zero-extend halfword
        ALU_ROL,    // 34  rotate left  (also used for RORI with imm operand)
        ALU_ROR,    // 35  rotate right (also used for RORI with imm operand)
        ALU_ORCB,   // 36  or-combine bytes
        ALU_REV8,   // 37  byte-reverse
        // Zbs — single-bit operations
        ALU_BCLR,  // 38  bit clear  (also used for BCLRI)
        ALU_BEXT,  // 39  bit extract (also used for BEXTI)
        ALU_BINV,  // 40  bit invert  (also used for BINVI)
        ALU_BSET   // 41  bit set     (also used for BSETI)
    } alu_op_e;

    // ========================================================================
    // Branch types (matches funct3 for branch instructions)
    // ========================================================================
    typedef enum logic [2:0] {
        BRANCH_EQ  = 3'b000,
        BRANCH_NE  = 3'b001,
        BRANCH_LT  = 3'b100,
        BRANCH_GE  = 3'b101,
        BRANCH_LTU = 3'b110,
        BRANCH_GEU = 3'b111
    } branch_op_e;

    // ========================================================================
    // Memory access size / sign (matches funct3 for load/store)
    // ========================================================================
    typedef enum logic [2:0] {
        MEM_BYTE   = 3'b000,  // LB  / SB
        MEM_HALF   = 3'b001,  // LH  / SH
        MEM_WORD   = 3'b010,  // LW  / SW
        MEM_BYTE_U = 3'b100,  // LBU
        MEM_HALF_U = 3'b101   // LHU
    } mem_size_e;

    // ========================================================================
    // Atomic Memory Operation types (funct5)
    // ========================================================================
    typedef enum logic [4:0] {
        AMO_LR   = 5'b00010,
        AMO_SC   = 5'b00011,
        AMO_SWAP = 5'b00001,
        AMO_ADD  = 5'b00000,
        AMO_XOR  = 5'b00100,
        AMO_AND  = 5'b01100,
        AMO_OR   = 5'b01000,
        AMO_MIN  = 5'b10000,
        AMO_MAX  = 5'b10100,
        AMO_MINU = 5'b11000,
        AMO_MAXU = 5'b11100
    } amo_op_e;

    // ========================================================================
    // Exception / Interrupt Cause codes  (mcause[4:0])
    // ========================================================================
    typedef enum logic [4:0] {
        EXC_INSTR_ADDR_MISALIGNED = 5'd0,
        EXC_INSTR_ACCESS_FAULT    = 5'd1,
        EXC_ILLEGAL_INSTR         = 5'd2,
        EXC_BREAKPOINT            = 5'd3,
        EXC_LOAD_ADDR_MISALIGNED  = 5'd4,
        EXC_LOAD_ACCESS_FAULT     = 5'd5,
        EXC_STORE_ADDR_MISALIGNED = 5'd6,
        EXC_STORE_ACCESS_FAULT    = 5'd7,
        EXC_ECALL_UMODE           = 5'd8,
        EXC_ECALL_MMODE           = 5'd11
    } exc_cause_e;

    // ========================================================================
    // CSR addresses
    // ========================================================================
    typedef enum logic [11:0] {
        // Unprivileged floating-point (not used, kept for completeness)
        // Machine Trap Setup
        CSR_MSTATUS  = 12'h300,
        CSR_MISA     = 12'h301,
        CSR_MIE      = 12'h304,
        CSR_MTVEC    = 12'h305,
        CSR_MSTATUSH = 12'h310,  // RV32 high bits of mstatus (MBE=0, all others 0)

        // Machine Trap Handling
        CSR_MSCRATCH = 12'h340,
        CSR_MEPC     = 12'h341,
        CSR_MCAUSE   = 12'h342,
        CSR_MTVAL    = 12'h343,
        CSR_MIP      = 12'h344,

        // CLIC extensions (RVM23)
        CSR_MTVT       = 12'h307,  // CLIC vector table base
        CSR_MNXTI      = 12'h345,  // CLIC next-interrupt CSR
        CSR_MINTSTATUS = 12'hFB1,  // CLIC interrupt status (current level)
        CSR_MINTTHRESH = 12'h347,  // CLIC interrupt threshold

        // Machine Counters/Timers
        CSR_MCOUNTINHIBIT = 12'h320,  // counter-inhibit: bit0=CY, bit2=IR
        CSR_MCYCLE        = 12'hB00,
        CSR_MINSTRET      = 12'hB02,
        CSR_MCYCLEH       = 12'hB80,
        CSR_MINSTRETH     = 12'hB82,

        // User-mode read-only shadows
        CSR_CYCLE    = 12'hC00,
        CSR_TIME     = 12'hC01,
        CSR_INSTRET  = 12'hC02,
        CSR_CYCLEH   = 12'hC80,
        CSR_TIMEH    = 12'hC81,
        CSR_INSTRETH = 12'hC82,

        // Machine information (read-only)
        CSR_MVENDORID = 12'hF11,
        CSR_MARCHID   = 12'hF12,
        CSR_MIMPID    = 12'hF13,
        CSR_MHARTID   = 12'hF14
    } csr_addr_e;

    // ========================================================================
    // Pipeline Register Structs
    // ========================================================================

    // IF -> EX pipeline register
    typedef struct packed {
        logic        valid;          // instruction is valid (not a bubble)
        logic [31:0] pc;             // PC of this instruction
        logic [31:0] instr;          // expanded 32-bit instruction
        logic [31:0] orig_instr;     // original encoding (16-bit zero-ext for RVC)
        logic        is_compressed;  // was originally 16-bit RVC
        logic        bp_taken;       // front-end pre-redirected: BTFNT taken-branch, JAL, or RAS pop
        logic [31:0] bp_pred_pc;     // predicted target PC when bp_taken=1 (RAS pop return address)
        logic        ifetch_fault;   // AXI DECERR on I-fetch -> EXC_INSTR_ACCESS_FAULT
    } if_ex_t;

    // EX -> WB pipeline register
    typedef struct packed {
        logic        valid;       // slot is valid
        logic [31:0] pc;          // PC of this instruction (for trace & mepc)
        logic [31:0] orig_instr;  // original encoding (for trace)

        // Writeback
        logic [4:0]  rd_addr;  // destination register address
        logic        reg_we;   // register write enable
        logic [31:0] rd_data;  // result (ALU / LUI / AUIPC / JAL(R) link)

        // Memory
        logic        mem_read;    // load in flight
        logic        mem_write;   // store in flight
        mem_size_e   mem_op;      // access size/sign  (mem_size_e)
        logic [31:0] mem_addr;    // effective address
        logic [31:0] store_data;  // data to write (stores)

        // AMO
        logic    is_amo;  // AMO in flight
        amo_op_e amo_op;  // AMO operation

        // CSR
        logic [2:0]  csr_op;     // CSR operation (3'b0 = no CSR access)
        logic [11:0] csr_addr;   // CSR address
        logic [31:0] csr_wdata;  // CSR write value
        logic [4:0]  csr_zimm;   // CSR immediate (CSRRWI/CSRRSI/CSRRCI)

        // Control
        logic        exception;  // synchronous exception in EX
        exc_cause_e  exc_cause;  // exception cause code
        logic [31:0] exc_tval;   // trap value (bad PC/addr or instr)
        logic        mret;       // MRET instruction

        // Redirect (branches/jumps resolved in EX)
        logic        redirect;     // EX computed a new PC
        logic [31:0] redirect_pc;  // target PC for branch/jump
    } ex_wb_t;

endpackage
