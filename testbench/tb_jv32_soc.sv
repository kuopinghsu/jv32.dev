// ============================================================================
// File: tb_jv32_soc.sv
// Project: JV32 RISC-V Processor
// Description: Verilator Testbench Wrapper for JV32 SoC
// ============================================================================

`timescale 1ns / 1ps

/* verilator coverage_off */
module tb_jv32_soc #(
    parameter int unsigned        CLK_FREQ   = 80_000_000,
    parameter int unsigned        BAUD_RATE  = 115_200,
    parameter bit                 USE_CJTAG  = 1'b0,
    parameter int unsigned        IRAM_SIZE  = 128 * 1024,
    parameter int unsigned        DRAM_SIZE  = 128 * 1024,
    parameter bit                 RV32E_EN   = 1'b0,
    parameter bit                 RV32M_EN   = 1'b1,
    parameter bit                 JTAG_EN    = 1'b1,
    parameter bit                 TRACE_EN   = 1'b1,
    parameter bit                 AMO_EN     = 1'b1,
    parameter bit                 FAST_MUL   = 1'b1,
    parameter bit                 MUL_MC     = 1'b1,
    parameter bit                 FAST_DIV   = 1'b0,
    parameter bit                 FAST_SHIFT = 1'b1,
    parameter bit                 BP_EN      = 1'b1,
    parameter bit                 RAS_EN     = 1'b1,
    parameter bit                 IBUF_EN    = 1'b1,
    parameter bit                 RV32B_EN   = 1'b1,
    parameter logic        [31:0] BOOT_ADDR  = 32'h8000_0000,
    parameter logic        [31:0] IRAM_BASE  = 32'h8000_0000,
    parameter logic        [31:0] DRAM_BASE  = 32'hC000_0000
) (
    input logic clk,
    input logic rst_n,

    // Trace enable: set 1 to enable trace outputs, 0 to suppress (save power)
    input logic trace_en,

    // Trace outputs
    output logic        trace_valid,
    output logic        trace_reg_we,
    output logic [31:0] trace_pc,
    output logic [ 4:0] trace_rd,
    output logic [31:0] trace_rd_data,
    output logic [31:0] trace_instr,
    output logic        trace_mem_we,
    output logic        trace_mem_re,
    output logic [31:0] trace_mem_addr,
    output logic [31:0] trace_mem_data,
    output logic        trace_irq_taken,
    output logic [31:0] trace_irq_cause,
    output logic [31:0] trace_irq_epc,
    output logic        trace_irq_store_we,
    output logic [31:0] trace_irq_store_addr,
    output logic [31:0] trace_irq_store_data,

    // Branch predictor performance counters
    output logic perf_bp_branch,
    output logic perf_bp_taken,
    output logic perf_bp_mispred,
    output logic perf_bp_jal,
    output logic perf_bp_jal_miss,
    output logic perf_bp_jalr,
    output logic heartbeat_o,

    // DPI-C memory init
    input  logic uart_rx_i,
    output logic uart_tx_o_monitor, // UART TX line for exit-drain detection

    // Exposed JTAG / cJTAG pins for debugger-driven simulation
    input  logic jtag_ntrst_i,
    input  logic jtag_pin0_tck_i,
    input  logic jtag_pin1_tms_i,
    output logic jtag_pin1_tms_o,
    output logic jtag_pin1_tms_oe,
    input  logic jtag_pin2_tdi_i,
    output logic jtag_pin3_tdo_o,
    output logic jtag_pin3_tdo_oe
);
    import "DPI-C" function void sim_request_exit(input int exit_code);

    // DPI-C exports for ELF loading (called from elfloader.cpp)
    export "DPI-C" function mem_write_byte;
    export "DPI-C" function mem_read_byte;

    // DPI-C export: read GPR by index (used for Ctrl-C register dump)
    export "DPI-C" function get_gpr;

    localparam int unsigned IRAM_LIMIT      = IRAM_BASE + IRAM_SIZE;
    localparam int unsigned DRAM_LIMIT      = DRAM_BASE + DRAM_SIZE;
    localparam logic [31:0] IRAM_ALIAS_BASE = 32'h6000_0000;
    localparam logic [31:0] DRAM_ALIAS_BASE = 32'h7000_0000;

    // External TCM AXI master wires (driven by testbench alias bridge)
    logic [31:0] s_iram_tcm_araddr;
    logic        s_iram_tcm_arvalid;
    logic        s_iram_tcm_arready;
    logic [31:0] s_iram_tcm_rdata;
    logic [ 1:0] s_iram_tcm_rresp;
    logic        s_iram_tcm_rvalid;
    logic        s_iram_tcm_rready;
    logic [31:0] s_iram_tcm_awaddr;
    logic        s_iram_tcm_awvalid;
    logic        s_iram_tcm_awready;
    logic [31:0] s_iram_tcm_wdata;
    logic [ 3:0] s_iram_tcm_wstrb;
    logic        s_iram_tcm_wvalid;
    logic        s_iram_tcm_wready;
    logic [ 1:0] s_iram_tcm_bresp;
    logic        s_iram_tcm_bvalid;
    logic        s_iram_tcm_bready;

    logic [31:0] s_dram_tcm_araddr;
    logic        s_dram_tcm_arvalid;
    logic        s_dram_tcm_arready;
    logic [31:0] s_dram_tcm_rdata;
    logic [ 1:0] s_dram_tcm_rresp;
    logic        s_dram_tcm_rvalid;
    logic        s_dram_tcm_rready;
    logic [31:0] s_dram_tcm_awaddr;
    logic        s_dram_tcm_awvalid;
    logic        s_dram_tcm_awready;
    logic [31:0] s_dram_tcm_wdata;
    logic [ 3:0] s_dram_tcm_wstrb;
    logic        s_dram_tcm_wvalid;
    logic        s_dram_tcm_wready;
    logic [ 1:0] s_dram_tcm_bresp;
    logic        s_dram_tcm_bvalid;
    logic        s_dram_tcm_bready;

    // SoC external AXI slave interface (out-of-peripheral path).
    logic [31:0] ext_axi_araddr;
    logic        ext_axi_arvalid;
    logic        ext_axi_rready;
    logic [31:0] ext_axi_awaddr;
    logic        ext_axi_awvalid;
    logic [31:0] ext_axi_wdata;
    logic [ 3:0] ext_axi_wstrb;
    logic        ext_axi_wvalid;
    logic        ext_axi_bready;
    logic        ext_axi_arready;
    logic [31:0] ext_axi_rdata;
    logic [ 1:0] ext_axi_rresp;
    logic        ext_axi_rvalid;
    logic        ext_axi_awready;
    logic        ext_axi_wready;
    logic [ 1:0] ext_axi_bresp;
    logic        ext_axi_bvalid;

    function automatic logic in_iram_alias(input logic [31:0] addr);
        return (addr & ~(32'(IRAM_SIZE) - 32'h1)) == (IRAM_ALIAS_BASE & ~(32'(IRAM_SIZE) - 32'h1));
    endfunction

    function automatic logic in_dram_alias(input logic [31:0] addr);
        return (addr & ~(32'(DRAM_SIZE) - 32'h1)) == (DRAM_ALIAS_BASE & ~(32'(DRAM_SIZE) - 32'h1));
    endfunction

    function automatic logic [31:0] alias_to_tcm_addr(input logic [31:0] addr);
        if (in_iram_alias(addr)) return IRAM_BASE + (addr - IRAM_ALIAS_BASE);
        if (in_dram_alias(addr)) return DRAM_BASE + (addr - DRAM_ALIAS_BASE);
        return addr;
    endfunction

    typedef enum logic [2:0] {
        TB_ALIAS_IDLE,
        TB_ALIAS_RD_ADDR,
        TB_ALIAS_RD_RESP,
        TB_ALIAS_WR_REQ,
        TB_ALIAS_WR_RESP
    } tb_alias_state_e;

    tb_alias_state_e        tb_alias_state;
    logic            [31:0] tb_alias_addr_r;
    logic tb_alias_aw_done, tb_alias_w_done;
    logic tb_alias_is_iram;
    logic tb_alias_rd_sel, tb_alias_wr_sel;
    logic tb_alias_active;
    logic decerr_bpending;
    logic alias_arready, alias_rvalid, alias_awready, alias_wready, alias_bvalid;
    logic [31:0] alias_rdata;
    logic [1:0] alias_rresp, alias_bresp;

    assign tb_alias_rd_sel = (tb_alias_state == TB_ALIAS_IDLE) && ext_axi_arvalid && (in_iram_alias(
        ext_axi_araddr
    ) || in_dram_alias(
        ext_axi_araddr
    ));

    assign tb_alias_wr_sel = (tb_alias_state == TB_ALIAS_IDLE) && ext_axi_awvalid && (in_iram_alias(
        ext_axi_awaddr
    ) || in_dram_alias(
        ext_axi_awaddr
    ));

    assign tb_alias_active = (tb_alias_state != TB_ALIAS_IDLE);

    assign alias_arready = tb_alias_is_iram ? s_iram_tcm_arready : s_dram_tcm_arready;
    assign alias_rvalid = tb_alias_is_iram ? s_iram_tcm_rvalid : s_dram_tcm_rvalid;
    assign alias_rdata = tb_alias_is_iram ? s_iram_tcm_rdata : s_dram_tcm_rdata;
    assign alias_rresp = tb_alias_is_iram ? s_iram_tcm_rresp : s_dram_tcm_rresp;
    assign alias_awready = tb_alias_is_iram ? s_iram_tcm_awready : s_dram_tcm_awready;
    assign alias_wready = tb_alias_is_iram ? s_iram_tcm_wready : s_dram_tcm_wready;
    assign alias_bvalid = tb_alias_is_iram ? s_iram_tcm_bvalid : s_dram_tcm_bvalid;
    assign alias_bresp = tb_alias_is_iram ? s_iram_tcm_bresp : s_dram_tcm_bresp;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tb_alias_state   <= TB_ALIAS_IDLE;
            tb_alias_addr_r  <= 32'h0;
            tb_alias_aw_done <= 1'b0;
            tb_alias_w_done  <= 1'b0;
            tb_alias_is_iram <= 1'b0;
        end
        else begin
            case (tb_alias_state)
                TB_ALIAS_IDLE: begin
                    tb_alias_aw_done <= 1'b0;
                    tb_alias_w_done  <= 1'b0;
                    if (tb_alias_rd_sel) begin
                        tb_alias_addr_r  <= alias_to_tcm_addr(ext_axi_araddr);
                        tb_alias_is_iram <= in_iram_alias(ext_axi_araddr);
                        tb_alias_state   <= TB_ALIAS_RD_ADDR;
                    end
                    else if (tb_alias_wr_sel) begin
                        tb_alias_addr_r  <= alias_to_tcm_addr(ext_axi_awaddr);
                        tb_alias_is_iram <= in_iram_alias(ext_axi_awaddr);
                        tb_alias_state   <= TB_ALIAS_WR_REQ;
                    end
                end

                TB_ALIAS_RD_ADDR: begin
                    if (alias_arready) tb_alias_state <= TB_ALIAS_RD_RESP;
                end

                TB_ALIAS_RD_RESP: begin
                    if (alias_rvalid && ext_axi_rready) tb_alias_state <= TB_ALIAS_IDLE;
                end

                TB_ALIAS_WR_REQ: begin
                    if (!tb_alias_aw_done && alias_awready) tb_alias_aw_done <= 1'b1;
                    if (!tb_alias_w_done && ext_axi_wvalid && alias_wready) tb_alias_w_done <= 1'b1;
                    if ((tb_alias_aw_done || alias_awready) && (tb_alias_w_done || (ext_axi_wvalid && alias_wready)))
                        tb_alias_state <= TB_ALIAS_WR_RESP;
                end

                TB_ALIAS_WR_RESP: begin
                    if (alias_bvalid && ext_axi_bready) tb_alias_state <= TB_ALIAS_IDLE;
                end

                default: tb_alias_state <= TB_ALIAS_IDLE;
            endcase
        end
    end

    // Latch a pending DECERR B-response for non-alias unmapped writes.
    // bvalid must stay asserted until bready, but wvalid drops before
    // jv32_top transitions from BUS_DAW to BUS_DB and asserts bready.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decerr_bpending <= 1'b0;
        end
        else begin
            if (!tb_alias_active && !tb_alias_wr_sel && ext_axi_wvalid && !decerr_bpending) decerr_bpending <= 1'b1;
            else if (decerr_bpending && ext_axi_bready) decerr_bpending <= 1'b0;
        end
    end

    // Drive external TCM slave interfaces from testbench alias bridge.
    always_comb begin
        s_iram_tcm_araddr = tb_alias_addr_r;
        s_iram_tcm_arvalid = (tb_alias_state == TB_ALIAS_RD_ADDR) && tb_alias_is_iram;
        s_iram_tcm_rready = (tb_alias_state == TB_ALIAS_RD_RESP && tb_alias_is_iram) ? ext_axi_rready : 1'b0;
        s_iram_tcm_awaddr = tb_alias_addr_r;
        s_iram_tcm_awvalid = (tb_alias_state == TB_ALIAS_WR_REQ) && !tb_alias_aw_done && tb_alias_is_iram;
        s_iram_tcm_wdata = ext_axi_wdata;
        s_iram_tcm_wstrb = ext_axi_wstrb;
        s_iram_tcm_wvalid  = (tb_alias_state == TB_ALIAS_WR_REQ) && !tb_alias_w_done && ext_axi_wvalid && tb_alias_is_iram;
        s_iram_tcm_bready = (tb_alias_state == TB_ALIAS_WR_RESP && tb_alias_is_iram) ? ext_axi_bready : 1'b0;

        s_dram_tcm_araddr = tb_alias_addr_r;
        s_dram_tcm_arvalid = (tb_alias_state == TB_ALIAS_RD_ADDR) && !tb_alias_is_iram;
        s_dram_tcm_rready = (tb_alias_state == TB_ALIAS_RD_RESP && !tb_alias_is_iram) ? ext_axi_rready : 1'b0;
        s_dram_tcm_awaddr = tb_alias_addr_r;
        s_dram_tcm_awvalid = (tb_alias_state == TB_ALIAS_WR_REQ) && !tb_alias_aw_done && !tb_alias_is_iram;
        s_dram_tcm_wdata = ext_axi_wdata;
        s_dram_tcm_wstrb = ext_axi_wstrb;
        s_dram_tcm_wvalid  = (tb_alias_state == TB_ALIAS_WR_REQ) && !tb_alias_w_done && ext_axi_wvalid && !tb_alias_is_iram;
        s_dram_tcm_bready = (tb_alias_state == TB_ALIAS_WR_RESP && !tb_alias_is_iram) ? ext_axi_bready : 1'b0;

        // Alias hits are rerouted into TCM; non-alias external accesses
        // return DECERR so unmatched traffic does not hang simulation.
        // Treat pending alias selection in IDLE as owned by alias path to
        // avoid issuing a premature DECERR response in the handoff cycle.
        if (tb_alias_active || tb_alias_rd_sel || tb_alias_wr_sel) begin
            ext_axi_arready = (tb_alias_state == TB_ALIAS_RD_ADDR) ? alias_arready : 1'b0;
            ext_axi_rvalid  = (tb_alias_state == TB_ALIAS_RD_RESP) ? alias_rvalid : 1'b0;
            ext_axi_rdata   = alias_rdata;
            ext_axi_rresp   = (tb_alias_state == TB_ALIAS_RD_RESP) ? alias_rresp : 2'b00;
            ext_axi_awready = (tb_alias_state == TB_ALIAS_WR_REQ && !tb_alias_aw_done) ? alias_awready : 1'b0;
            ext_axi_wready  = (tb_alias_state == TB_ALIAS_WR_REQ && !tb_alias_w_done) ? alias_wready : 1'b0;
            ext_axi_bvalid  = (tb_alias_state == TB_ALIAS_WR_RESP) ? alias_bvalid : 1'b0;
            ext_axi_bresp   = (tb_alias_state == TB_ALIAS_WR_RESP) ? alias_bresp : 2'b00;
        end
        else begin
            ext_axi_arready = 1'b1;
            ext_axi_rvalid  = ext_axi_arvalid;
            ext_axi_rdata   = 32'h0;
            ext_axi_rresp   = 2'b11;
            ext_axi_awready = 1'b1;
            ext_axi_wready  = 1'b1;
            ext_axi_bvalid  = decerr_bpending;
            ext_axi_bresp   = 2'b11;
        end
    end

    function void mem_write_byte(input int addr, input byte data);
        automatic int unsigned uaddr = unsigned'(addr);
        if (uaddr >= IRAM_BASE && uaddr < IRAM_LIMIT) begin
            automatic int offset = uaddr - IRAM_BASE;
            automatic int bank = offset & 3;
            automatic int widx = offset >> 2;
            u_soc.u_jv32.u_iram.mem[widx][bank*8+:8] = data;
        end
        else if (uaddr >= DRAM_BASE && uaddr < DRAM_LIMIT) begin
            automatic int offset = uaddr - DRAM_BASE;
            automatic int bank = offset & 3;
            automatic int widx = offset >> 2;
            u_soc.u_jv32.u_dram.mem[widx][bank*8+:8] = data;
        end
    endfunction

    function byte mem_read_byte(input int addr);
        automatic int unsigned uaddr = unsigned'(addr);
        if (uaddr >= IRAM_BASE && uaddr < IRAM_LIMIT) begin
            automatic int offset = uaddr - IRAM_BASE;
            automatic int bank = offset & 3;
            automatic int widx = offset >> 2;
            return byte'(u_soc.u_jv32.u_iram.mem[widx][bank*8+:8]);
        end
        else if (uaddr >= DRAM_BASE && uaddr < DRAM_LIMIT) begin
            automatic int offset = uaddr - DRAM_BASE;
            automatic int bank = offset & 3;
            automatic int widx = offset >> 2;
            return byte'(u_soc.u_jv32.u_dram.mem[widx][bank*8+:8]);
        end
        return 8'hFF;
    endfunction

    // Read GPR by index (0=zero..31=t6) for Ctrl-C register dump
    function int get_gpr(input int idx);
        if (idx <= 0 || idx > 31) return 0;
        return int'(u_soc.u_jv32.u_core.u_regfile.regs[idx]);
    endfunction

    logic uart_tx_o;
    logic uart_loopback_tx;

    assign uart_tx_o_monitor = uart_tx_o;

    // SIM_CLKS_PER_BIT: must be >= 4 for uart_loopback to centre-sample correctly.
    // Use 8 cycles/bit; the large TX FIFO prevents back-pressure on the CPU.
    localparam int unsigned SIM_CLKS_PER_BIT      = 8;
    localparam int unsigned SIM_BAUD_RATE         = CLK_FREQ / SIM_CLKS_PER_BIT;
    localparam logic [15:0] LOOPBACK_CLKS_PER_BIT = 16'(SIM_CLKS_PER_BIT);

    uart_loopback u_uart_loopback (
        .clk         (clk),
        .rst_n       (rst_n),
        .rx          (uart_tx_o),
        .tx          (uart_loopback_tx),
        .clks_per_bit(LOOPBACK_CLKS_PER_BIT)
    );

    jv32_soc #(
        .CLK_FREQ       (CLK_FREQ),
        .BAUD_RATE      (SIM_BAUD_RATE),  // 8 cycles/bit — fast yet loopback-safe
        .UART_FIFO_DEPTH(4096),           // deep FIFO; CPU never stalls on TX
        .USE_CJTAG      (USE_CJTAG),
        .IRAM_SIZE      (IRAM_SIZE),
        .DRAM_SIZE      (DRAM_SIZE),
        .RV32E_EN       (RV32E_EN),
        .RV32M_EN       (RV32M_EN),
        .JTAG_EN        (JTAG_EN),
        .TRACE_EN       (TRACE_EN),
        .AMO_EN         (AMO_EN),
        .FAST_MUL       (FAST_MUL),
        .MUL_MC         (MUL_MC),
        .FAST_DIV       (FAST_DIV),
        .FAST_SHIFT     (FAST_SHIFT),
        .BP_EN          (BP_EN),
        .RAS_EN         (RAS_EN),
        .IBUF_EN        (IBUF_EN),
        .RV32B_EN       (RV32B_EN),
        .IRAM_BASE      (IRAM_BASE),
        .DRAM_BASE      (DRAM_BASE)
    ) u_soc (
        .clk             (clk),
        .rst_n           (rst_n),
        .uart_rx_i       (uart_rx_i),
        .uart_tx_o       (uart_tx_o),
        .jtag_ntrst_i    (jtag_ntrst_i),
        .jtag_pin0_tck_i (jtag_pin0_tck_i),
        .jtag_pin1_tms_i (jtag_pin1_tms_i),
        .jtag_pin1_tms_o (jtag_pin1_tms_o),
        .jtag_pin1_tms_oe(jtag_pin1_tms_oe),
        .jtag_pin2_tdi_i (jtag_pin2_tdi_i),
        .jtag_pin3_tdo_o (jtag_pin3_tdo_o),
        .jtag_pin3_tdo_oe(jtag_pin3_tdo_oe),
        .ext_irq_i       (16'h0),

        // TCM slaves driven by testbench alias bridge
        .s_iram_tcm_araddr   (s_iram_tcm_araddr),
        .s_iram_tcm_arvalid  (s_iram_tcm_arvalid),
        .s_iram_tcm_arready  (s_iram_tcm_arready),
        .s_iram_tcm_rdata    (s_iram_tcm_rdata),
        .s_iram_tcm_rresp    (s_iram_tcm_rresp),
        .s_iram_tcm_rvalid   (s_iram_tcm_rvalid),
        .s_iram_tcm_rready   (s_iram_tcm_rready),
        .s_iram_tcm_awaddr   (s_iram_tcm_awaddr),
        .s_iram_tcm_awvalid  (s_iram_tcm_awvalid),
        .s_iram_tcm_awready  (s_iram_tcm_awready),
        .s_iram_tcm_wdata    (s_iram_tcm_wdata),
        .s_iram_tcm_wstrb    (s_iram_tcm_wstrb),
        .s_iram_tcm_wvalid   (s_iram_tcm_wvalid),
        .s_iram_tcm_wready   (s_iram_tcm_wready),
        .s_iram_tcm_bresp    (s_iram_tcm_bresp),
        .s_iram_tcm_bvalid   (s_iram_tcm_bvalid),
        .s_iram_tcm_bready   (s_iram_tcm_bready),
        .s_dram_tcm_araddr   (s_dram_tcm_araddr),
        .s_dram_tcm_arvalid  (s_dram_tcm_arvalid),
        .s_dram_tcm_arready  (s_dram_tcm_arready),
        .s_dram_tcm_rdata    (s_dram_tcm_rdata),
        .s_dram_tcm_rresp    (s_dram_tcm_rresp),
        .s_dram_tcm_rvalid   (s_dram_tcm_rvalid),
        .s_dram_tcm_rready   (s_dram_tcm_rready),
        .s_dram_tcm_awaddr   (s_dram_tcm_awaddr),
        .s_dram_tcm_awvalid  (s_dram_tcm_awvalid),
        .s_dram_tcm_awready  (s_dram_tcm_awready),
        .s_dram_tcm_wdata    (s_dram_tcm_wdata),
        .s_dram_tcm_wstrb    (s_dram_tcm_wstrb),
        .s_dram_tcm_wvalid   (s_dram_tcm_wvalid),
        .s_dram_tcm_wready   (s_dram_tcm_wready),
        .s_dram_tcm_bresp    (s_dram_tcm_bresp),
        .s_dram_tcm_bvalid   (s_dram_tcm_bvalid),
        .s_dram_tcm_bready   (s_dram_tcm_bready),
        .ext_axi_araddr      (ext_axi_araddr),
        .ext_axi_arvalid     (ext_axi_arvalid),
        .ext_axi_rready      (ext_axi_rready),
        .ext_axi_awaddr      (ext_axi_awaddr),
        .ext_axi_awvalid     (ext_axi_awvalid),
        .ext_axi_wdata       (ext_axi_wdata),
        .ext_axi_wstrb       (ext_axi_wstrb),
        .ext_axi_wvalid      (ext_axi_wvalid),
        .ext_axi_bready      (ext_axi_bready),
        .ext_axi_arready     (ext_axi_arready),
        .ext_axi_rdata       (ext_axi_rdata),
        .ext_axi_rresp       (ext_axi_rresp),
        .ext_axi_rvalid      (ext_axi_rvalid),
        .ext_axi_awready     (ext_axi_awready),
        .ext_axi_wready      (ext_axi_wready),
        .ext_axi_bresp       (ext_axi_bresp),
        .ext_axi_bvalid      (ext_axi_bvalid),
        .trace_en            (trace_en),
        .trace_valid         (trace_valid),
        .trace_reg_we        (trace_reg_we),
        .trace_pc            (trace_pc),
        .trace_rd            (trace_rd),
        .trace_rd_data       (trace_rd_data),
        .trace_instr         (trace_instr),
        .trace_mem_we        (trace_mem_we),
        .trace_mem_re        (trace_mem_re),
        .trace_mem_addr      (trace_mem_addr),
        .trace_mem_data      (trace_mem_data),
        .trace_irq_taken     (trace_irq_taken),
        .trace_irq_cause     (trace_irq_cause),
        .trace_irq_epc       (trace_irq_epc),
        .trace_irq_store_we  (trace_irq_store_we),
        .trace_irq_store_addr(trace_irq_store_addr),
        .trace_irq_store_data(trace_irq_store_data),
        .perf_bp_branch      (perf_bp_branch),
        .perf_bp_taken       (perf_bp_taken),
        .perf_bp_mispred     (perf_bp_mispred),
        .perf_bp_jal         (perf_bp_jal),
        .perf_bp_jal_miss    (perf_bp_jal_miss),
        .perf_bp_jalr        (perf_bp_jalr),
        .heartbeat_o         (heartbeat_o)
    );

endmodule
/* verilator coverage_on */
