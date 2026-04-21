// ============================================================================
// File: jv32_macros.svh
// Project: JV32 RISC-V Processor
// Description: Preprocessor macro definitions for debug display and groups.
//
// This file is a plain header (no package/module) so it can be marked as a
// Vivado global include, ensuring the macros are visible to all compilation
// units regardless of compile order.
//
// In simulation the file is included by jv32_pkg.sv.
// ============================================================================

`ifndef JV32_MACROS_SVH
`define JV32_MACROS_SVH

// ----------------------------------------------------------------------------
// Debug group bit indices
// ----------------------------------------------------------------------------
`define DBG_GRP_FETCH  0   // Instruction fetch, PC tracking
`define DBG_GRP_PIPE   1   // Pipeline stalls and flushes
`define DBG_GRP_EX     2   // Execute stage (ALU, branch, forward)
`define DBG_GRP_MEM    3   // Memory stage (load/store)
`define DBG_GRP_CSR    4   // CSR read/write
`define DBG_GRP_IRQ    5   // Interrupts and exceptions
`define DBG_GRP_UART   6   // UART peripheral
`define DBG_GRP_CLIC   7   // CLIC interrupt controller
`define DBG_GRP_MAGIC  8   // Magic simulation device (exit, NCM)
`define DBG_GRP_JTAG   9   // JTAG / cJTAG transport and TAP activity
`define DBG_GRP_DTM   10   // RISC-V debug transport / debug-module activity
`define DBG_GRP_ICACHE 13  // NCM / magic-device icache-bypass (legacy)

// Default: all groups enabled. Override with +define+DEBUG_GROUP=<decimal>
`ifndef DEBUG_GROUP
`define DEBUG_GROUP 32'hFFFF_FFFF
`endif

// ----------------------------------------------------------------------------
// Debug display macros
//   DEBUG1(msg)          – print always when DEBUG_LEVEL_1 or DEBUG_LEVEL_2
//   DEBUG2(grp, msg)     – print per-group when DEBUG_LEVEL_2
// Use double parentheses for msg: DEBUG1(("val=%0d", x))
// ----------------------------------------------------------------------------
`ifdef SYNTHESIS
`define DEBUG1(msg)
`define DEBUG2(grp, msg)
`else
`ifdef DEBUG_LEVEL_1
`define DEBUG1(msg) $display("[DBG1] %s", $sformatf msg)
`else
`define DEBUG1(msg)
`endif
`ifdef DEBUG_LEVEL_2
`define DEBUG2(grp, msg) \
        if (|((`DEBUG_GROUP >> (grp)) & 32'h1)) \
            $display("[%s] %s", jv32_pkg::dbg_grp_name(grp), $sformatf msg)
`else
`define DEBUG2(grp, msg)
`endif
`endif

`endif // JV32_MACROS_SVH
