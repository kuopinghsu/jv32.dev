// ============================================================================
// File: axi_clic.sv
// Project: JV32 RISC-V Processor
// Description: RISC-V CLIC with CLINT-compatible Timer/Software registers
//
// Provides:
//   - CLINT-compatible mtime/mtimecmp (64-bit), msip
//   - 16 external interrupt lines with per-IRQ enable/level/priority
//   - Sideband signals to jv32_csr for interrupt delivery
//
// Register Map (base 0x0200_0000):
//   0x0000: MSIP        [0]=software interrupt request
//   0x4000: MTIME_LO    [31:0] of mtime
//   0x4004: MTIME_HI    [63:32] of mtime
//   0x4008: MTIMECMP_LO [31:0] of mtimecmp
//   0x400C: MTIMECMP_HI [63:32] of mtimecmp
//   0x1000+n*4: CLICINT[n] [0]=ip(RO), [1]=ie, [15:8]=attr, [23:16]=ctl(prio)
//
// Timer IRQ: when mtime >= mtimecmp
// Software IRQ: msip[0]
// External IRQ: any enabled pending CLIC interrupt with level > threshold
// ============================================================================

module axi_clic #(
    parameter int unsigned CLK_FREQ = 100_000_000,
    parameter int unsigned NUM_IRQ  = 16
) (
    input logic clk,
    input logic rst_n,

    // Instruction retirement pulse: when 1, mtime increments by 1.
    // Connect to trace_valid from the CPU core so that mtime advances at
    // instruction-retire rate (matching the software simulator).
    input logic instret_inc,

    // AXI4-Lite slave
    input  logic [31:0] s_awaddr,
    input  logic        s_awvalid,
    output logic        s_awready,
    input  logic [31:0] s_wdata,
    input  logic [ 3:0] s_wstrb,
    input  logic        s_wvalid,
    output logic        s_wready,
    output logic [ 1:0] s_bresp,
    output logic        s_bvalid,
    input  logic        s_bready,
    input  logic [31:0] s_araddr,
    input  logic        s_arvalid,
    output logic        s_arready,
    output logic [31:0] s_rdata,
    output logic [ 1:0] s_rresp,
    output logic        s_rvalid,
    input  logic        s_rready,

    // External interrupt inputs (active-high)
    input logic [NUM_IRQ-1:0] ext_irq_i,

    // IRQ outputs to CPU
    output logic       timer_irq_o,
    output logic       software_irq_o,
    output logic       clic_irq_o,
    output logic [7:0] clic_level_o,
    output logic [7:0] clic_prio_o,
    output logic [4:0] clic_id_o        // winning IRQ index (for mtvt vector lookup)
);

    // =====================================================================
    // Internal state
    // =====================================================================
    logic [       63:0] mtime;
    logic [       63:0] mtimecmp;
    logic               msip;

    // Per-IRQ registers: [0]=ip(from ext), [1]=ie, [23:16]=ctl/prio, [31:24]=level
    logic [NUM_IRQ-1:0] clicint_ie;
    logic [        7:0] clicint_ctl[NUM_IRQ];  // priority/level

    assign timer_irq_o    = ((mtime + {63'd0, instret_inc}) >= mtimecmp) && (mtimecmp != 64'hFFFF_FFFF_FFFF_FFFF);
    assign software_irq_o = msip;

    // =====================================================================
    // CLIC interrupt arbiter
    // =====================================================================
    always_comb begin
        clic_irq_o   = 1'b0;
        clic_level_o = 8'h0;
        clic_prio_o  = 8'h0;
        clic_id_o    = 5'h0;
        for (int i = 0; i < NUM_IRQ; i++) begin
            if (clicint_ie[i] && ext_irq_i[i]) begin
                if (!clic_irq_o || (clicint_ctl[i] > clic_prio_o)) begin
                    clic_irq_o   = 1'b1;
                    clic_level_o = clicint_ctl[i];
                    clic_prio_o  = clicint_ctl[i];
                    clic_id_o    = 5'(i);  // winning IRQ index
                end
            end
        end
    end

    // =====================================================================
    // AXI4-Lite slave: simple single-beat interface
    // =====================================================================
    // Write channel
    logic        aw_active;
    logic [31:0] aw_addr_r;
    logic        w_active;
    logic [31:0] w_data_r;
    logic [ 3:0] w_strb_r;
    logic [31:0] wr_addr_sel;
    logic [31:0] wr_data_sel;
    logic [ 3:0] wr_strb_sel;
    logic [31:0] wr_msk;

    assign wr_addr_sel = aw_active ? aw_addr_r : s_awaddr;
    assign wr_data_sel = w_active ? w_data_r : s_wdata;
    assign wr_strb_sel = w_active ? w_strb_r : s_wstrb;
    assign wr_msk      = {{8{wr_strb_sel[3]}}, {8{wr_strb_sel[2]}}, {8{wr_strb_sel[1]}}, {8{wr_strb_sel[0]}}};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_active <= 1'b0;
            aw_addr_r <= 32'h0;
            w_active  <= 1'b0;
            w_data_r  <= 32'h0;
            w_strb_r  <= 4'h0;
            s_bvalid  <= 1'b0;
            mtime     <= 64'h0;
            mtimecmp  <= 64'hFFFF_FFFF_FFFF_FFFF;
            msip      <= 1'b0;
            for (int i = 0; i < NUM_IRQ; i++) begin
                clicint_ie[i]  <= 1'b0;
                clicint_ctl[i] <= 8'h0;
            end
        end
        else begin
            // Auto-increment mtime on instruction retirement
            if (instret_inc) mtime <= mtime + 64'd1;
            // Accept AW
            if (s_awvalid && s_awready) begin
                aw_active <= 1'b1;
                aw_addr_r <= s_awaddr;
            end
            // Accept W
            if (s_wvalid && s_wready) begin
                w_active <= 1'b1;
                w_data_r <= s_wdata;
                w_strb_r <= s_wstrb;
            end
            // Process write when both have arrived
            if ((aw_active || (s_awvalid && s_awready)) && (w_active || (s_wvalid && s_wready))) begin
                aw_active <= 1'b0;
                w_active  <= 1'b0;
                s_bvalid  <= 1'b1;
                // Perform write
                begin
`ifndef SYNTHESIS
                    `DEBUG1(
                        ("[CLIC] AXI write: addr=0x%h data=0x%h aw_active=%b w_active=%b s_awaddr=0x%h aw_addr_r=0x%h",
                        wr_addr_sel,
                        wr_data_sel,
                        aw_active, w_active, s_awaddr, aw_addr_r));
`endif
                    casez (wr_addr_sel[15:0])
                        16'h0000: msip <= wr_data_sel[0];
                        16'h4000: mtime[31:0] <= (mtime[31:0] & ~wr_msk) | (wr_data_sel & wr_msk);
                        16'h4004: mtime[63:32] <= (mtime[63:32] & ~wr_msk) | (wr_data_sel & wr_msk);
                        16'h4008: mtimecmp[31:0] <= (mtimecmp[31:0] & ~wr_msk) | (wr_data_sel & wr_msk);
                        16'h400C: mtimecmp[63:32] <= (mtimecmp[63:32] & ~wr_msk) | (wr_data_sel & wr_msk);
                        default: begin
                            if (wr_addr_sel[15:12] == 4'h1) begin
                                // CLICINT[n]: 0x1000 + n*4
                                if (int'({22'b0, wr_addr_sel[11:2]}) < NUM_IRQ) begin
                                    if (wr_strb_sel[0]) clicint_ie[int'({22'b0, wr_addr_sel[11:2]})] <= wr_data_sel[1];
                                    if (wr_strb_sel[2])
                                        clicint_ctl[int'({22'b0, wr_addr_sel[11:2]})] <= wr_data_sel[23:16];
                                end
                            end
                        end
                    endcase
                end
            end
            else if (s_bvalid && s_bready) s_bvalid <= 1'b0;
        end
    end

    assign s_awready = !aw_active && !s_bvalid;
    assign s_wready  = !w_active;
    assign s_bresp   = 2'b00;

    // Read channel
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_rvalid <= 1'b0;
            s_rdata  <= 32'h0;
        end
        else if (s_arvalid && s_arready) begin
            s_rvalid <= 1'b1;
            casez (s_araddr[15:0])
                16'h0000: s_rdata <= {31'd0, msip};
                16'h4000: s_rdata <= mtime[31:0];
                16'h4004: s_rdata <= mtime[63:32];
                16'h4008: s_rdata <= mtimecmp[31:0];
                16'h400C: s_rdata <= mtimecmp[63:32];
                default: begin
                    s_rdata <= 32'h0;
                    if (s_araddr[15:12] == 4'h1) begin
                        if (int'({22'b0, s_araddr[11:2]}) < NUM_IRQ)
                            s_rdata <= {
                                8'h0,
                                clicint_ctl[int'({22'b0, s_araddr[11:2]})],
                                14'h0,
                                clicint_ie[int'({22'b0, s_araddr[11:2]})],
                                ext_irq_i[int'({22'b0, s_araddr[11:2]})]
                            };
                    end
                end
            endcase
        end
        else if (s_rvalid && s_rready) begin
            s_rvalid <= 1'b0;
        end
    end

    assign s_arready = !s_rvalid;
    assign s_rresp   = 2'b00;

    // Suppress unused
    logic _unused;
    assign _unused = &{1'b0, CLK_FREQ};

`ifndef SYNTHESIS
    // Debug: log CLIC arbiter state changes on clock edges
    logic        clic_irq_r;
    logic        timer_irq_r;
    logic [63:0] mtimecmp_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clic_irq_r  <= 1'b0;
            timer_irq_r <= 1'b0;
            mtimecmp_r  <= 64'hFFFF_FFFF_FFFF_FFFF;
        end
        else begin
            clic_irq_r  <= clic_irq_o;
            timer_irq_r <= timer_irq_o;
            mtimecmp_r  <= mtimecmp;
        end
    end
    always_ff @(posedge clk) begin
        if (clic_irq_o && !clic_irq_r)
            `DEBUG2(`DBG_GRP_CLIC, ("IRQ raised:   id=%0d level=%0d prio=%0d", clic_id_o, clic_level_o, clic_prio_o));
        if (!clic_irq_o && clic_irq_r) `DEBUG2(`DBG_GRP_CLIC, ("IRQ cleared:  id=%0d", clic_id_o));
        if (timer_irq_o && !timer_irq_r)
            `DEBUG1(("[CLIC] timer_irq ASSERTED: mtime=0x%h mtimecmp=0x%h", mtime, mtimecmp));
        if (!timer_irq_o && timer_irq_r)
            `DEBUG1(("[CLIC] timer_irq CLEARED: mtime=0x%h mtimecmp=0x%h", mtime, mtimecmp));
        if (mtimecmp != mtimecmp_r)
            `DEBUG1(("[CLIC] mtimecmp written: old=0x%h new=0x%h mtime=0x%h", mtimecmp_r, mtimecmp, mtime));
    end
`endif

endmodule
