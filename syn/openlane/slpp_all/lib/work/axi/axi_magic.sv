// ============================================================================
// File: axi_magic.sv
// Project: KV32 RISC-V Processor
// Description: AXI4-Lite Magic Device for Simulation Control
//
// Provides special memory-mapped registers and a Non-Cacheable Memory (NCM)
// region used exclusively in simulation/testbench environments.  Not
// synthesised for FPGA/ASIC targets.
//
// Base address: 0x4000_0000
//
// Register Map:
//   Offset 0x000 (0x4000_0000): CONSOLE_MAGIC - Write a character to stdout
//   Offset 0x004 (0x4000_0004): EXIT_MAGIC    - Trigger simulation exit
//
// Non-Cacheable Memory (NCM):
//   Base:  0x4000_1000  (NCM_BASE_ADDR)
//   Size:  512 B  (128    32-bit words)
//
//   The NCM region lives below bit[31]=0, which falls outside the main DRAM
//   window (0x8000_0000+) and therefore hits neither the I-cache PMA range
//   nor the D-cache PMA range.  Every access is forced through the AXI bypass
//   path, making this region ideal for testing cache-bypass behaviour:
//     - Firmware can write arbitrary machine code into NCM and invoke it via a
//       function pointer, exercising the uncached instruction-fetch path.
//     - Data read/write to NCM verifies that the D-cache bypass path correctly
//       forwards data and propagates AXI error responses (SLVERR) to the core.
// ============================================================================






module axi_magic (
    input  logic        clk,
    input  logic        rst_n,

    // AXI4-Lite Slave Interface
    input  logic [31:0] axi_awaddr,
    input  logic        axi_awvalid,
    output logic        axi_awready,

    input  logic [31:0] axi_wdata,
    input  logic [3:0]  axi_wstrb,
    input  logic        axi_wvalid,
    output logic        axi_wready,

    output logic [1:0]  axi_bresp,
    output logic        axi_bvalid,
    input  logic        axi_bready,

    input  logic [31:0] axi_araddr,
    input  logic        axi_arvalid,
    output logic        axi_arready,

    output logic [31:0] axi_rdata,
    output logic [1:0]  axi_rresp,
    output logic        axi_rvalid,
    input  logic        axi_rready
);


    assign axi_awready      = 1'b1;
    assign axi_wready       = 1'b1;
    assign axi_bresp[1:0]   = 2'b00;  // RESP_OKAY
    assign axi_bvalid       = 1'b1;
    assign axi_arready      = 1'b1;
    assign axi_rdata[31:0]  = 32'b0;
    assign axi_rresp[1:0]   = 2'b00;  // RESP_OKAY
    assign axi_rvalid       = 1'b1;







































































































































































































































































































































































endmodule

