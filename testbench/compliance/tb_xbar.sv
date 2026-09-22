`timescale 1ns/1ps
module tb_xbar;
localparam N_SLAVES=2;
logic clk = '0;
logic rst_n = '0;
logic [31:0] m_awaddr = '0;
logic m_awvalid = '0;
logic m_awready;
logic [31:0] m_wdata = '0;
logic [ 3:0] m_wstrb = '0;
logic m_wvalid = '0;
logic m_wready;
logic [ 1:0] m_bresp;
logic m_bvalid;
logic m_bready = '0;
logic [31:0] m_araddr = '0;
logic m_arvalid = '0;
logic m_arready;
logic [31:0] m_rdata;
logic [ 1:0] m_rresp;
logic m_rvalid;
logic m_rready = '0;
logic [N_SLAVES-1:0][31:0] s_awaddr;
logic [N_SLAVES-1:0]       s_awvalid;
logic [N_SLAVES-1:0]       s_awready = '0;
logic [N_SLAVES-1:0][31:0] s_wdata;
logic [N_SLAVES-1:0][ 3:0] s_wstrb;
logic [N_SLAVES-1:0]       s_wvalid;
logic [N_SLAVES-1:0]       s_wready = '0;
logic [N_SLAVES-1:0][ 1:0] s_bresp = '0;
logic [N_SLAVES-1:0]       s_bvalid = '0;
logic [N_SLAVES-1:0]       s_bready;
logic [N_SLAVES-1:0][31:0] s_araddr;
logic [N_SLAVES-1:0]       s_arvalid;
logic [N_SLAVES-1:0]       s_arready;
logic [N_SLAVES-1:0][31:0] s_rdata = '0;
logic [N_SLAVES-1:0][ 1:0] s_rresp = '0;
logic [N_SLAVES-1:0]       s_rvalid = '0;
logic [N_SLAVES-1:0]       s_rready;
always #5 clk=~clk;
localparam logic [31:0] BASE[2]='{32'h1000,32'h1080};
localparam logic [31:0] MASK[2]='{32'hffffff00,32'hffffff80};
axi_xbar #(.N_SLAVES(2),.SLAVE_BASE(BASE),.SLAVE_MASK(MASK)) dut (.*);
assert property (@(posedge clk) disable iff(!rst_n)
    dut.rd_err |-> dut.rd_active && !dut.ar_sent);
assert property (@(posedge clk) disable iff(!rst_n)
    dut.wr_err && dut.wr_active |-> !dut.aw_sent);
assert property (@(posedge clk) disable iff(!rst_n)
    $onehot0(s_awvalid) && $onehot0(s_arvalid) && $onehot0(s_wvalid));
int accepted=0;
always @(posedge clk) begin
    if(!rst_n) begin s_rvalid<=0; accepted<=0; end
    else for(int i=0;i<2;i++) begin
        if(s_rvalid[i] && s_rready[i]) s_rvalid[i]<=0;
        if(s_arvalid[i] && s_arready[i]) begin
            accepted<=accepted+1;
            s_rvalid[i]<=1; s_rdata[i]<=s_araddr[i]; s_rresp[i]<=0;
        end
    end
end
assign s_arready=~s_rvalid | s_rready;
assert property (@(posedge clk) disable iff(!rst_n)
    m_rvalid && !m_rready |=> m_rvalid && $stable({m_rdata,m_rresp}));
initial begin
    repeat(3) @(negedge clk); rst_n=1;
    m_araddr='h1080; m_arvalid=1;
    do @(posedge clk); while(!m_arready);
    @(negedge clk); m_arvalid=0;
    repeat(5) @(negedge clk);
    if(!m_rvalid || m_rdata!='h1080 || s_arvalid[1]) $fatal(1,"read route/overlap priority");
    m_rready=1; @(negedge clk); m_rready=0;
    repeat(2) @(negedge clk);
    if(accepted!=1) $fatal(1,"duplicate AR: %0d slave requests for one master read",accepted);
    // Unmapped write must collect W before generating its DECERR response.
    m_awaddr='h2000; m_awvalid=1;
    do @(posedge clk); while(!m_awready);
    @(negedge clk); m_awvalid=0;
    repeat(4) begin @(negedge clk); if(m_bvalid) $fatal(1,"DECERR before W accepted"); end
    m_wvalid=1; m_wstrb=15;
    do @(posedge clk); while(!m_wready);
    @(negedge clk); m_wvalid=0;
    while(!m_bvalid) @(negedge clk);
    if(m_bresp!=3) $fatal(1,"missing DECERR");
    m_bready=1; @(negedge clk); m_bready=0;
    $display("PASS tb_xbar"); $finish;
end
initial begin #10000; $fatal(1,"xbar timeout"); end
endmodule
