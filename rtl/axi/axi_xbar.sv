// ============================================================================
// File: axi_xbar.sv
// Project: JV32 RISC-V Processor
// Description: AXI4-Lite 1-master N-slave address decoder / crossbar
//
// Memory map (fixed at instantiation via BASE/MASK parameters):
//   Slave 0: IRAM  @ 0x8000_0000 (mask 0xFFFF_0000)
//   Slave 1: DRAM  @ 0xC000_0000 (mask 0xFFFF_0000)
//   Slave 2: UART  @ 0x2001_0000 (mask 0xFFFF_FF00)
//   Slave 3: CLIC  @ 0x0200_0000 (mask 0xFFE0_0000)
//   Slave 4: Magic @ 0x4000_0000 (mask 0xF000_0000)
//
// If no slave address matches, DECERR is returned.
// ============================================================================

module axi_xbar #(
    parameter int unsigned N_SLAVES = 5,
    parameter logic [31:0] SLAVE_BASE [N_SLAVES] = '{32'h8000_0000, 32'hC000_0000,
                                                      32'h2001_0000, 32'h0200_0000,
                                                      32'h4000_0000},
    parameter logic [31:0] SLAVE_MASK [N_SLAVES] = '{32'hFFFF_0000, 32'hFFFF_0000,
                                                      32'hFFFF_FF00, 32'hFFE0_0000,
                                                      32'hF000_0000}
)(
    input  logic        clk,
    input  logic        rst_n,

    // Master port
    input  logic [31:0] m_awaddr,
    input  logic        m_awvalid,
    output logic        m_awready,
    input  logic [31:0] m_wdata,
    input  logic [3:0]  m_wstrb,
    input  logic        m_wvalid,
    output logic        m_wready,
    output logic [1:0]  m_bresp,
    output logic        m_bvalid,
    input  logic        m_bready,
    input  logic [31:0] m_araddr,
    input  logic        m_arvalid,
    output logic        m_arready,
    output logic [31:0] m_rdata,
    output logic [1:0]  m_rresp,
    output logic        m_rvalid,
    input  logic        m_rready,

    // Slave ports (flattened arrays)
    output logic [N_SLAVES-1:0][31:0] s_awaddr,
    output logic [N_SLAVES-1:0]       s_awvalid,
    input  logic [N_SLAVES-1:0]       s_awready,
    output logic [N_SLAVES-1:0][31:0] s_wdata,
    output logic [N_SLAVES-1:0][3:0]  s_wstrb,
    output logic [N_SLAVES-1:0]       s_wvalid,
    input  logic [N_SLAVES-1:0]       s_wready,
    input  logic [N_SLAVES-1:0][1:0]  s_bresp,
    input  logic [N_SLAVES-1:0]       s_bvalid,
    output logic [N_SLAVES-1:0]       s_bready,
    output logic [N_SLAVES-1:0][31:0] s_araddr,
    output logic [N_SLAVES-1:0]       s_arvalid,
    input  logic [N_SLAVES-1:0]       s_arready,
    input  logic [N_SLAVES-1:0][31:0] s_rdata,
    input  logic [N_SLAVES-1:0][1:0]  s_rresp,
    input  logic [N_SLAVES-1:0]       s_rvalid,
    output logic [N_SLAVES-1:0]       s_rready
);

    // =====================================================================
    // Address decode
    // =====================================================================
    function automatic int decode_addr(input logic [31:0] addr);
        for (int i = 0; i < N_SLAVES; i++) begin
            if ((addr & SLAVE_MASK[i]) == (SLAVE_BASE[i] & SLAVE_MASK[i]))
                return i;
        end
        return -1;
    endfunction

    // =====================================================================
    // Read channel routing
    // =====================================================================
    logic [$clog2(N_SLAVES)-1:0] rd_sel;
    logic        rd_active;
    logic [31:0] rd_addr_r;
    logic        rd_err;   // DECERR

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rd_active <= 1'b0; rd_sel <= '0; rd_err <= 1'b0; rd_addr_r <= 32'h0; end
        else if (!rd_active) begin
            if (m_arvalid) begin
                automatic int s = decode_addr(m_araddr);
                rd_active <= 1'b1;
                rd_addr_r <= m_araddr;
                if (s < 0) begin rd_sel <= '0; rd_err <= 1'b1; end
                else begin rd_sel <= $clog2(N_SLAVES)'(s); rd_err <= 1'b0; end
            end
        end else begin
            if (m_rvalid && m_rready) rd_active <= 1'b0;
        end
    end

    // AR: accept immediately when idle
    assign m_arready = !rd_active;

    // Route AR to selected slave
    always_comb begin
        for (int i = 0; i < N_SLAVES; i++) begin
            s_araddr[i]  = rd_addr_r;
            s_arvalid[i] = rd_active && !rd_err && ($clog2(N_SLAVES)'(i) == rd_sel);
            s_rready[i]  = m_rready && ($clog2(N_SLAVES)'(i) == rd_sel);
        end
    end

    // Route R back to master
    assign m_rvalid = rd_err ? 1'b1 :
                      (rd_active ? s_rvalid[rd_sel] : 1'b0);
    assign m_rdata  = rd_active && !rd_err ? s_rdata[rd_sel] : 32'hDEAD_BEEF;
    assign m_rresp  = rd_err ? 2'b11 :  // DECERR
                      (rd_active ? s_rresp[rd_sel] : 2'b00);

    // =====================================================================
    // Write channel routing
    // =====================================================================
    logic [$clog2(N_SLAVES)-1:0] wr_sel;
    logic        wr_active;
    logic [31:0] wr_addr_r;
    logic        wr_err;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wr_active <= 1'b0; wr_sel <= '0; wr_err <= 1'b0; wr_addr_r <= 32'h0; end
        else if (!wr_active) begin
            if (m_awvalid) begin
                automatic int s = decode_addr(m_awaddr);
                wr_active <= 1'b1;
                wr_addr_r <= m_awaddr;
                if (s < 0) begin wr_sel <= '0; wr_err <= 1'b1; end
                else begin wr_sel <= $clog2(N_SLAVES)'(s); wr_err <= 1'b0; end
            end
        end else begin
            if (m_bvalid && m_bready) wr_active <= 1'b0;
        end
    end

    assign m_awready = !wr_active;

    always_comb begin
        for (int i = 0; i < N_SLAVES; i++) begin
            s_awaddr[i]  = wr_addr_r;
            s_awvalid[i] = wr_active && !wr_err && ($clog2(N_SLAVES)'(i) == wr_sel);
            s_wdata[i]   = m_wdata;
            s_wstrb[i]   = m_wstrb;
            s_wvalid[i]  = m_wvalid && wr_active && !wr_err && ($clog2(N_SLAVES)'(i) == wr_sel);
            s_bready[i]  = m_bready && ($clog2(N_SLAVES)'(i) == wr_sel);
        end
    end

    assign m_wready = wr_err ? 1'b1 :
                      (wr_active ? s_wready[wr_sel] : 1'b0);
    assign m_bvalid = wr_err ? 1'b1 :
                      (wr_active ? s_bvalid[wr_sel] : 1'b0);
    assign m_bresp  = wr_err ? 2'b11 :
                      (wr_active ? s_bresp[wr_sel] : 2'b00);

endmodule
