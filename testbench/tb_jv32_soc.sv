// ============================================================================
// File: tb_jv32_soc.sv
// Project: JV32 RISC-V Processor
// Description: Verilator Testbench Wrapper for JV32 SoC
// ============================================================================

`timescale 1ns/1ps

module tb_jv32_soc #(
    parameter int unsigned CLK_FREQ  = 100_000_000,
    parameter int unsigned BAUD_RATE = 115_200,
    parameter int unsigned IRAM_SIZE = 128*1024,
    parameter int unsigned DRAM_SIZE = 128*1024,
    parameter bit          FAST_MUL  = 1'b1,
    parameter bit          FAST_DIV  = 1'b1,
    parameter bit          FAST_SHIFT= 1'b1,
    parameter bit          BP_EN     = 1'b1,
    parameter logic [31:0] BOOT_ADDR = 32'h8000_0000,
    parameter logic [31:0] IRAM_BASE = 32'h8000_0000,
    parameter logic [31:0] DRAM_BASE = 32'hC000_0000
)(
    input  logic clk,
    input  logic rst_n,

    // Trace outputs
    output logic        trace_valid,
    output logic        trace_reg_we,
    output logic [31:0] trace_pc,
    output logic [4:0]  trace_rd,
    output logic [31:0] trace_rd_data,
    output logic [31:0] trace_instr,
    output logic        trace_mem_we,
    output logic        trace_mem_re,
    output logic [31:0] trace_mem_addr,
    output logic [31:0] trace_mem_data,

    // DPI-C memory init
    input  logic        uart_rx_i,
    output logic        uart_tx_o_monitor  // UART TX line for exit-drain detection
);
    import "DPI-C" function void sim_request_exit(input int exit_code);

    // DPI-C exports for ELF loading (called from elfloader.cpp)
    export "DPI-C" function mem_write_byte;
    export "DPI-C" function mem_read_byte;

    localparam int unsigned IRAM_LIMIT = IRAM_BASE + IRAM_SIZE;
    localparam int unsigned DRAM_LIMIT = DRAM_BASE + DRAM_SIZE;

    function void mem_write_byte(input int addr, input byte data);
        automatic int unsigned uaddr = unsigned'(addr);
        if (uaddr >= IRAM_BASE && uaddr < IRAM_LIMIT) begin
            automatic int offset = uaddr - IRAM_BASE;
            automatic int bank   = offset & 3;
            automatic int widx   = offset >> 2;
            // Unrolled case: Verilator lint requires constant generate indices
            case (bank)
                0: u_soc.u_jv32.gen_iram_byte[0].u_sram.mem[widx] = data;
                1: u_soc.u_jv32.gen_iram_byte[1].u_sram.mem[widx] = data;
                2: u_soc.u_jv32.gen_iram_byte[2].u_sram.mem[widx] = data;
                3: u_soc.u_jv32.gen_iram_byte[3].u_sram.mem[widx] = data;
                default: ;
            endcase
        end else if (uaddr >= DRAM_BASE && uaddr < DRAM_LIMIT) begin
            automatic int offset = uaddr - DRAM_BASE;
            automatic int bank   = offset & 3;
            automatic int widx   = offset >> 2;
            case (bank)
                0: u_soc.u_jv32.gen_dram_byte[0].u_sram.mem[widx] = data;
                1: u_soc.u_jv32.gen_dram_byte[1].u_sram.mem[widx] = data;
                2: u_soc.u_jv32.gen_dram_byte[2].u_sram.mem[widx] = data;
                3: u_soc.u_jv32.gen_dram_byte[3].u_sram.mem[widx] = data;
                default: ;
            endcase
        end
    endfunction

    function byte mem_read_byte(input int addr);
        automatic int unsigned uaddr = unsigned'(addr);
        if (uaddr >= IRAM_BASE && uaddr < IRAM_LIMIT) begin
            automatic int offset = uaddr - IRAM_BASE;
            automatic int bank   = offset & 3;
            automatic int widx   = offset >> 2;
            case (bank)
                0: return byte'(u_soc.u_jv32.gen_iram_byte[0].u_sram.mem[widx]);
                1: return byte'(u_soc.u_jv32.gen_iram_byte[1].u_sram.mem[widx]);
                2: return byte'(u_soc.u_jv32.gen_iram_byte[2].u_sram.mem[widx]);
                3: return byte'(u_soc.u_jv32.gen_iram_byte[3].u_sram.mem[widx]);
                default: ;
            endcase
        end else if (uaddr >= DRAM_BASE && uaddr < DRAM_LIMIT) begin
            automatic int offset = uaddr - DRAM_BASE;
            automatic int bank   = offset & 3;
            automatic int widx   = offset >> 2;
            case (bank)
                0: return byte'(u_soc.u_jv32.gen_dram_byte[0].u_sram.mem[widx]);
                1: return byte'(u_soc.u_jv32.gen_dram_byte[1].u_sram.mem[widx]);
                2: return byte'(u_soc.u_jv32.gen_dram_byte[2].u_sram.mem[widx]);
                3: return byte'(u_soc.u_jv32.gen_dram_byte[3].u_sram.mem[widx]);
                default: ;
            endcase
        end
        return 8'hFF;
    endfunction

    logic uart_tx_o;
    logic uart_loopback_tx;

    assign uart_tx_o_monitor = uart_tx_o;

    // SIM_CLKS_PER_BIT: must be >= 4 for uart_loopback to centre-sample correctly.
    // Use 8 cycles/bit; the large TX FIFO prevents back-pressure on the CPU.
    localparam int unsigned  SIM_CLKS_PER_BIT   = 8;
    localparam int unsigned  SIM_BAUD_RATE       = CLK_FREQ / SIM_CLKS_PER_BIT;
    localparam logic [15:0]  LOOPBACK_CLKS_PER_BIT = 16'(SIM_CLKS_PER_BIT);

    uart_loopback u_uart_loopback (
        .clk          (clk),
        .rst_n        (rst_n),
        .rx           (uart_tx_o),
        .tx           (uart_loopback_tx),
        .clks_per_bit (LOOPBACK_CLKS_PER_BIT)
    );

    jv32_soc #(
        .CLK_FREQ        (CLK_FREQ),
        .BAUD_RATE       (SIM_BAUD_RATE),  // 8 cycles/bit — fast yet loopback-safe
        .UART_FIFO_DEPTH (4096),           // deep FIFO; CPU never stalls on TX
        .IRAM_SIZE       (IRAM_SIZE),
        .DRAM_SIZE       (DRAM_SIZE),
        .FAST_MUL        (FAST_MUL),
        .FAST_DIV        (FAST_DIV),
        .FAST_SHIFT      (FAST_SHIFT),
        .BP_EN           (BP_EN),
        .BOOT_ADDR       (BOOT_ADDR),
        .IRAM_BASE       (IRAM_BASE),
        .DRAM_BASE       (DRAM_BASE)
    ) u_soc (
        .clk            (clk),
        .rst_n          (rst_n),
        .uart_rx_i      (uart_rx_i),
        .uart_tx_o      (uart_tx_o),
        .ext_irq_i      (16'h0),
        // TCM slave: tied off (ELF loading uses DPI mem_write_byte)
        .s_tcm_araddr   (32'h0), .s_tcm_arvalid (1'b0), .s_tcm_arready (),
        .s_tcm_rdata    (),      .s_tcm_rresp   (),     .s_tcm_rvalid  (), .s_tcm_rready(1'b1),
        .s_tcm_awaddr   (32'h0), .s_tcm_awvalid (1'b0), .s_tcm_awready (),
        .s_tcm_wdata    (32'h0), .s_tcm_wstrb   (4'h0), .s_tcm_wvalid  (1'b0), .s_tcm_wready(),
        .s_tcm_bresp    (),      .s_tcm_bvalid  (),     .s_tcm_bready  (1'b1),
        .trace_valid    (trace_valid),
        .trace_reg_we   (trace_reg_we),
        .trace_pc       (trace_pc),
        .trace_rd       (trace_rd),
        .trace_rd_data  (trace_rd_data),
        .trace_instr    (trace_instr),
        .trace_mem_we   (trace_mem_we),
        .trace_mem_re   (trace_mem_re),
        .trace_mem_addr (trace_mem_addr),
        .trace_mem_data (trace_mem_data)
    );

endmodule
