// ============================================================================
// File        : axi_xbar.sv
// Project     : JV32 RISC-V Processor
// Description : AXI4-Lite 1-master N-slave address decoder / crossbar
//
// Memory map (fixed at instantiation via BASE/MASK parameters):
//   Slave 0: IRAM  @ 0x8000_0000 (mask 0xFFFF_0000)
//   Slave 1: DRAM  @ 0xC000_0000 (mask 0xFFFF_0000)
//   Slave 2: UART  @ 0x2001_0000 (mask 0xFFFF_FF00)
//   Slave 3: CLIC  @ 0x0200_0000 (mask 0xFFE0_0000)
//   Slave 4: Magic @ 0x4000_0000 (mask 0xF000_0000)
//
// If no slave address matches, DECERR is returned.
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

module axi_xbar #(
    parameter int unsigned N_SLAVES = 5,
    parameter bit [31:0] SLAVE_BASE[N_SLAVES] = '{
        32'h8000_0000,
        32'hC000_0000,
        32'h2001_0000,
        32'h0200_0000,
        32'h4000_0000
    },
    parameter bit [31:0] SLAVE_MASK[N_SLAVES] = '{
        32'hFFFF_0000,
        32'hFFFF_0000,
        32'hFFFF_FF00,
        32'hFFE0_0000,
        32'hF000_0000
    }
) (
    input logic clk,
    input logic rst_n,

    // Master port
    input  logic [31:0] m_awaddr,
    input  logic        m_awvalid,
    output logic        m_awready,
    input  logic [31:0] m_wdata,
    input  logic [ 3:0] m_wstrb,
    input  logic        m_wvalid,
    output logic        m_wready,
    output logic [ 1:0] m_bresp,
    output logic        m_bvalid,
    input  logic        m_bready,
    input  logic [31:0] m_araddr,
    input  logic        m_arvalid,
    output logic        m_arready,
    output logic [31:0] m_rdata,
    output logic [ 1:0] m_rresp,
    output logic        m_rvalid,
    input  logic        m_rready,

    // Slave ports (flattened arrays)
    output logic [N_SLAVES-1:0][31:0] s_awaddr,
    output logic [N_SLAVES-1:0]       s_awvalid,
    input  logic [N_SLAVES-1:0]       s_awready,
    output logic [N_SLAVES-1:0][31:0] s_wdata,
    output logic [N_SLAVES-1:0][ 3:0] s_wstrb,
    output logic [N_SLAVES-1:0]       s_wvalid,
    input  logic [N_SLAVES-1:0]       s_wready,
    input  logic [N_SLAVES-1:0][ 1:0] s_bresp,
    input  logic [N_SLAVES-1:0]       s_bvalid,
    output logic [N_SLAVES-1:0]       s_bready,
    output logic [N_SLAVES-1:0][31:0] s_araddr,
    output logic [N_SLAVES-1:0]       s_arvalid,
    input  logic [N_SLAVES-1:0]       s_arready,
    input  logic [N_SLAVES-1:0][31:0] s_rdata,
    input  logic [N_SLAVES-1:0][ 1:0] s_rresp,
    input  logic [N_SLAVES-1:0]       s_rvalid,
    output logic [N_SLAVES-1:0]       s_rready
);

    // =====================================================================
    // Address decode
    // =====================================================================
    function automatic int decode_addr(input logic [31:0] addr);
        for (int i = 0; i < N_SLAVES; i++) begin
            if ((addr & SLAVE_MASK[i]) == (SLAVE_BASE[i] & SLAVE_MASK[i])) return i;
        end
        return -1;
    endfunction

    // =====================================================================
    // Read channel routing
    // =====================================================================
    logic [$clog2(N_SLAVES)-1:0] rd_sel;
    logic                        rd_active;
    logic [                31:0] rd_addr_r;
    logic                        rd_err;  // DECERR

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_active <= 1'b0;
            rd_sel    <= '0;
            rd_err    <= 1'b0;
            rd_addr_r <= 32'h0;
        end
        else if (!rd_active) begin
            if (m_arvalid) begin
                rd_active <= 1'b1;
                rd_addr_r <= m_araddr;
                if (decode_addr(m_araddr) < 0) begin
                    rd_sel <= '0;
                    rd_err <= 1'b1;
                end
                else begin
                    rd_sel <= $clog2(N_SLAVES)'(decode_addr(m_araddr));
                    rd_err <= 1'b0;
                end
            end
        end
        else begin
            if (m_rvalid && m_rready) begin
                rd_active <= 1'b0;
                rd_err    <= 1'b0;
            end
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

    // Route R back to master.
    // NOTE: rd_active is NOT used to gate m_rdata/m_rvalid here so that
    // combinatorial evaluation returns the correct slave data.
    // Spurious responses are safe: the bus-state machine only samples
    // m_rvalid when bus_state==BUS_DR or BUS_IR.
    assign m_rvalid = rd_err ? rd_active : s_rvalid[rd_sel];
    assign m_rdata  = rd_err ? 32'h0000_0000 : s_rdata[rd_sel];
    assign m_rresp  = rd_err ? 2'b11 : s_rresp[rd_sel];

    // =====================================================================
    // Write channel routing
    // =====================================================================
    logic [$clog2(N_SLAVES)-1:0] wr_sel;
    logic                        wr_active;
    logic [                31:0] wr_addr_r;
    logic                        wr_err;
    logic                        aw_sent;  // AW handshake with slave has completed

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_active <= 1'b0;
            wr_sel    <= '0;
            wr_err    <= 1'b0;
            wr_addr_r <= 32'h0;
            aw_sent   <= 1'b0;
        end
        else if (!wr_active) begin
            if (m_awvalid) begin
                wr_active <= 1'b1;
                wr_addr_r <= m_awaddr;
                aw_sent   <= 1'b0;
                if (decode_addr(m_awaddr) < 0) begin
                    wr_sel <= '0;
                    wr_err <= 1'b1;
                end
                else begin
                    wr_sel <= $clog2(N_SLAVES)'(decode_addr(m_awaddr));
                    wr_err <= 1'b0;
                end
            end
        end
        else begin
            // Deassert s_awvalid after slave accepts the AW transaction
            if (!aw_sent && s_awvalid[wr_sel] && s_awready[wr_sel]) aw_sent <= 1'b1;
            if (m_bvalid && m_bready) wr_active <= 1'b0;
        end
    end

    assign m_awready = !wr_active;

    always_comb begin
        for (int i = 0; i < N_SLAVES; i++) begin
            s_awaddr[i]  = wr_addr_r;
            s_awvalid[i] = wr_active && !wr_err && ($clog2(N_SLAVES)'(i) == wr_sel) && !aw_sent;
            s_wdata[i]   = m_wdata;
            s_wstrb[i]   = m_wstrb;
            s_wvalid[i]  = m_wvalid && wr_active && !wr_err && ($clog2(N_SLAVES)'(i) == wr_sel);
            s_bready[i]  = m_bready && ($clog2(N_SLAVES)'(i) == wr_sel);
        end
    end

    // Gate m_wready and m_bvalid by wr_active to prevent stale wr_err
    // from the previous transaction from leaking into a new one.
    assign m_wready = wr_active ? (wr_err ? 1'b1 : s_wready[wr_sel]) : 1'b0;
    assign m_bvalid = wr_active ? (wr_err ? 1'b1 : s_bvalid[wr_sel]) : 1'b0;
    assign m_bresp  = wr_active ? (wr_err ? 2'b11 : s_bresp[wr_sel]) : 2'b00;

`ifndef SYNTHESIS
    logic _unused_ok;
    assign _unused_ok = &{1'b0, s_arready};
`endif

endmodule
