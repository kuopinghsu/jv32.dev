// rvtest_config.svh
// JV32 RV32IMAC SystemVerilog test configuration (used by coverage collection)
// SPDX-License-Identifier: Apache-2.0

`define XLEN32

// JV32 IRAM base: 0x80000000
`define RAM_BASE_ADDR       32'h80000000
// JV32 IRAM size: 64KB
`define LARGEST_PROGRAM     32'h00010000

// Unmapped address → axi_xbar returns DECERR → JV32 core raises EXC_LOAD/STORE_ACCESS_FAULT
`define ACCESS_FAULT_ADDRESS 64'h00000000

// JV32 CLIC base at same address as standard CLINT
`define CLINT_BASE 64'h02000000
