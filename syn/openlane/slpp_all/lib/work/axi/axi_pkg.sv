// ============================================================================
// File: axi_pkg.sv
// Project: JV32 RISC-V Processor
// Description: AXI4-Lite Interface Package
//
// Defines AXI4-Lite protocol types parameterized on DATA_WIDTH.
// JV32 uses AXI4-Lite (no IDs, no bursts, no last signal) for all bus
// transactions.
// ============================================================================

package axi_pkg;

    // AXI Response codes
    typedef enum logic [1:0] {
        RESP_OKAY   = 2'b00,
        RESP_EXOKAY = 2'b01,
        RESP_SLVERR = 2'b10,
        RESP_DECERR = 2'b11
    } axi_resp_e;

endpackage
