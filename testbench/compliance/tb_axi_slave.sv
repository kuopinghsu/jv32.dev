`timescale 1ns/1ps
module tb_axi_slave #(parameter int KIND=0);
    logic clk=0, rst_n=0;
    always #5 clk=~clk;
    logic [31:0] awaddr = 0;
    logic awvalid = 0;
    wire awready;
    logic [31:0] wdata = 0;
    logic [3:0] wstrb = 0;
    logic wvalid = 0;
    wire wready;
    wire [1:0] bresp;
    wire bvalid;
    logic bready = 0;
    logic [31:0] araddr = 0;
    logic arvalid = 0;
    wire arready;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rvalid;
    logic rready = 0;
    if(KIND>=4) begin : soc_case
        wire [0:0] iram_awready;
        wire [0:0] iram_wready;
        wire [1:0] iram_bresp;
        wire [0:0] iram_bvalid;
        wire [0:0] iram_arready;
        wire [31:0] iram_rdata;
        wire [1:0] iram_rresp;
        wire [0:0] iram_rvalid;
        wire [0:0] dram_awready;
        wire [0:0] dram_wready;
        wire [1:0] dram_bresp;
        wire [0:0] dram_bvalid;
        wire [0:0] dram_arready;
        wire [31:0] dram_rdata;
        wire [1:0] dram_rresp;
        wire [0:0] dram_rvalid;
        assign arready = KIND==4 ? iram_arready : dram_arready;
        assign wready = KIND==4 ? iram_wready : dram_wready;
        assign awready = KIND==4 ? iram_awready : dram_awready;
        assign bvalid = KIND==4 ? iram_bvalid : dram_bvalid;
        assign bresp = KIND==4 ? iram_bresp : dram_bresp;
        assign rdata = KIND==4 ? iram_rdata : dram_rdata;
        assign rresp = KIND==4 ? iram_rresp : dram_rresp;
        assign rvalid = KIND==4 ? iram_rvalid : dram_rvalid;
        jv32_soc #(.JTAG_EN(0),.IRAM_SIZE(64),.DRAM_SIZE(64),.BOOT_ADDR(32'ha0000000)) dut (
.clk(clk),
.rst_n(rst_n),
.uart_rx_i(1'b1),
.jtag_ntrst_i(1'b1),
.jtag_pin0_tck_i('0),
.jtag_pin1_tms_i(1'b1),
.jtag_pin2_tdi_i('0),
.ext_irq_i(16'hffff),
.ext_axi_arready('0),
.ext_axi_rdata('0),
.ext_axi_rresp('0),
.ext_axi_rvalid('0),
.ext_axi_awready('0),
.ext_axi_wready('0),
.ext_axi_bresp('0),
.ext_axi_bvalid('0),
.trace_en('0),
.s_iram_tcm_awaddr(KIND==4 ? awaddr : '0),
.s_iram_tcm_awvalid(KIND==4 ? awvalid : '0),
.s_iram_tcm_awready(iram_awready),
.s_iram_tcm_wdata(KIND==4 ? wdata : '0),
.s_iram_tcm_wstrb(KIND==4 ? wstrb : '0),
.s_iram_tcm_wvalid(KIND==4 ? wvalid : '0),
.s_iram_tcm_wready(iram_wready),
.s_iram_tcm_bresp(iram_bresp),
.s_iram_tcm_bvalid(iram_bvalid),
.s_iram_tcm_bready(KIND==4 ? bready : '0),
.s_iram_tcm_araddr(KIND==4 ? araddr : '0),
.s_iram_tcm_arvalid(KIND==4 ? arvalid : '0),
.s_iram_tcm_arready(iram_arready),
.s_iram_tcm_rdata(iram_rdata),
.s_iram_tcm_rresp(iram_rresp),
.s_iram_tcm_rvalid(iram_rvalid),
.s_iram_tcm_rready(KIND==4 ? rready : '0),
.s_dram_tcm_awaddr(KIND==5 ? awaddr : '0),
.s_dram_tcm_awvalid(KIND==5 ? awvalid : '0),
.s_dram_tcm_awready(dram_awready),
.s_dram_tcm_wdata(KIND==5 ? wdata : '0),
.s_dram_tcm_wstrb(KIND==5 ? wstrb : '0),
.s_dram_tcm_wvalid(KIND==5 ? wvalid : '0),
.s_dram_tcm_wready(dram_wready),
.s_dram_tcm_bresp(dram_bresp),
.s_dram_tcm_bvalid(dram_bvalid),
.s_dram_tcm_bready(KIND==5 ? bready : '0),
.s_dram_tcm_araddr(KIND==5 ? araddr : '0),
.s_dram_tcm_arvalid(KIND==5 ? arvalid : '0),
.s_dram_tcm_arready(dram_arready),
.s_dram_tcm_rdata(dram_rdata),
.s_dram_tcm_rresp(dram_rresp),
.s_dram_tcm_rvalid(dram_rvalid),
.s_dram_tcm_rready(KIND==5 ? rready : '0)
);
        // Check release at each edge, including reset during a pending IRQ.
        always @(posedge rst_n) if($time>3) begin
            #1; check(!dut.soc_rst_n,"reset cannot release between clock edges");
            @(posedge clk); #1; check(!dut.soc_rst_n,"first release stage");
            @(posedge clk); #1; check(dut.soc_rst_n,"second release stage");
        end
        always @(negedge rst_n) begin
            #1; check(!dut.soc_rst_n,"asynchronous SoC reset assertion");
        end
        assert property (@(posedge clk) disable iff(!dut.soc_rst_n)
            dut.ext_axi_arvalid |-> dut.ext_axi_araddr==32'ha0000000);
        assert property (@(posedge clk) !rst_n |-> !dut.soc_rst_n);
        assert property (@(posedge clk) disable iff(!dut.soc_rst_n) {dut.dbg_halt_req,dut.dbg_resume_req,dut.dbg_reg_we,dut.dbg_csr_we,
             dut.dbg_pc_we,dut.dbg_mem_req,dut.dbg_mem_we,dut.dbg_ndmreset,
             dut.dbg_hartreset,dut.dbg_singlestep,dut.dbg_ebreakm,
             dut.dbg_dcsr_stopcount,dut.dbg_tdata1,dut.dbg_tdata2} == '0);
        assert property (@(posedge clk)
            dut.progbuf0==32'h00100073 && dut.progbuf1==32'h00100073 &&
            dut.jtag_pin1_tms_o && dut.jtag_pin3_tdo_o &&
            !dut.jtag_pin1_tms_oe && !dut.jtag_pin3_tdo_oe);
    end else if (KIND < 2) begin : axi_ram_ctrl_case
        axi_ram_ctrl #(.DEPTH(16),.WR_EN(KIND==0)) dut (.clk(clk),.rst_n(rst_n),.s_awaddr(awaddr),.s_awvalid(awvalid),.s_awready(awready),.s_wdata(wdata),.s_wstrb(wstrb),.s_wvalid(wvalid),.s_wready(wready),.s_bresp(bresp),.s_bvalid(bvalid),.s_bready(bready),.s_araddr(araddr),.s_arvalid(arvalid),.s_arready(arready),.s_rdata(rdata),.s_rresp(rresp),.s_rvalid(rvalid),.s_rready(rready));
    end
    else if (KIND == 2) begin : axi_uart_case
        axi_uart  dut (.clk(clk),.rst_n(rst_n),.axi_awaddr(awaddr),.axi_awvalid(awvalid),.axi_awready(awready),.axi_wdata(wdata),.axi_wstrb(wstrb),.axi_wvalid(wvalid),.axi_wready(wready),.axi_bresp(bresp),.axi_bvalid(bvalid),.axi_bready(bready),.axi_araddr(araddr),.axi_arvalid(arvalid),.axi_arready(arready),.axi_rdata(rdata),.axi_rresp(rresp),.axi_rvalid(rvalid),.axi_rready(rready),.uart_rx(1'b1),.uart_tx(),.irq());
    end
    else begin : axi_magic_case
        axi_magic  dut (.clk(clk),.rst_n(rst_n),.axi_awaddr(awaddr),.axi_awvalid(awvalid),.axi_awready(awready),.axi_wdata(wdata),.axi_wstrb(wstrb),.axi_wvalid(wvalid),.axi_wready(wready),.axi_bresp(bresp),.axi_bvalid(bvalid),.axi_bready(bready),.axi_araddr(araddr),.axi_arvalid(arvalid),.axi_arready(arready),.axi_rdata(rdata),.axi_rresp(rresp),.axi_rvalid(rvalid),.axi_rready(rready));
    end

    wire [15:0] observed_baud;
    if(KIND==2) assign observed_baud=axi_uart_case.dut.baud_div_r;
    else assign observed_baud=0;
    int checks=0;
    int aw_count=0, w_count=0, b_count=0, ar_count=0, r_count=0;
    always @(posedge clk) if(rst_n) begin
        if(awvalid && awready) aw_count++;
        if(wvalid && wready) w_count++;
        if(bvalid && bready) b_count++;
        if(arvalid && arready) ar_count++;
        if(rvalid && rready) r_count++;
    end
    task automatic check(input bit ok, input string label);
        checks++;
        if (!ok) $fatal(1,"KIND=%0d: %s",KIND,label);
    endtask
    task automatic tick;
        @(posedge clk); #1;
    endtask
    task automatic send_aw(input logic [31:0] addr,input int delay_cycles=0);
        repeat(delay_cycles) @(negedge clk);
        @(negedge clk); awaddr=addr; awvalid=1;
        do @(posedge clk); while(!awready);
        @(negedge clk); awvalid=0;
    endtask
    task automatic send_w(input logic [31:0] data,input logic [3:0] strb,input int delay_cycles=0);
        repeat(delay_cycles) @(negedge clk);
        @(negedge clk); wdata=data; wstrb=strb; wvalid=1;
        do @(posedge clk); while(!wready);
        @(negedge clk); wvalid=0;
    endtask
    task automatic consume_b(input logic [1:0] expected);
        while(!bvalid) tick();
        repeat($urandom_range(2,8)) begin check(bvalid && bresp==expected,"B response"); tick(); end
        @(negedge clk); bready=1; tick(); @(negedge clk); bready=0;
    endtask
    task automatic write_reg(input logic [31:0] addr,data,input logic [3:0] strb=15,input int order=0,input logic [1:0] resp=0);
        fork
            send_aw(addr,order==2 ? 4:0);
            send_w(data,strb,order==1 ? 4:0);
        join
        consume_b(resp);
    endtask
    task automatic send_ar(input logic [31:0] addr);
        @(negedge clk); araddr=addr; arvalid=1;
        do @(posedge clk); while(!arready);
        @(negedge clk); arvalid=0;
    endtask
    task automatic consume_r(input logic [31:0] expected,input logic [1:0] resp=0);
        while(!rvalid) tick();
        repeat($urandom_range(2,8)) begin
            check(rvalid && rresp==resp && rdata==expected,$sformatf("read got %h/%h expected %h/%h",rdata,rresp,expected,resp)); tick();
        end
        @(negedge clk); rready=1; tick(); @(negedge clk); rready=0;
    endtask
    task automatic read_reg(input logic [31:0] addr,expected,input logic [1:0] resp=0);
        send_ar(addr); consume_r(expected,resp);
    endtask
    assert property (@(posedge clk) disable iff(!rst_n) rvalid && !rready |=> rvalid && $stable({rdata,rresp}));
    assert property (@(posedge clk) disable iff(!rst_n) bvalid && !bready |=> bvalid && $stable(bresp));
    logic [31:0] model[16];
    logic [31:0] data,mask;
    logic [3:0] strb;
    int index;
    initial begin
        #1; rst_n=1; #1; rst_n=0; repeat(3) tick(); @(negedge clk); rst_n=1;
        // SoC slaves become operational after the two-clock reset release.
        repeat(4) tick();
        if(KIND==0 || KIND>=4) begin
            for(int i=0;i<16;i++) begin model[i]=32'(i+1); write_reg(32'(i*4),model[i]); end
            for(int i=0;i<16;i++) read_reg(32'(i*4),model[i]);
            for(int i=0;i<100;i++) begin
                index=int'($urandom_range(0,15)); data=$urandom; strb=4'($urandom);
                mask={{8{strb[3]}},{8{strb[2]}},{8{strb[1]}},{8{strb[0]}}};
                model[index]=(model[index]&~mask)|(data&mask);
                write_reg(32'(4*index),data,strb,i%3); read_reg(32'(4*index),model[index]);
            end
            // Independent read and write to a single-port SRAM must both complete.
            fork write_reg(0,'h12345678); read_reg(4,model[1]); join
            model[0]='h12345678;
            read_reg(0,model[0]);
            // Two writes while the first B is stalled must yield two responses.
            fork send_aw(0); send_w(9,15); join
            fork
                begin send_aw(4); end
                begin send_w(10,15); end
                begin repeat(8) tick(); consume_b(0); consume_b(0); end
            join
            read_reg(0,9); read_reg(4,10);
        end else if(KIND==1) begin
            for(int i=0;i<3;i++) write_reg(0,32'hfeedface,15,i,2);
        end else if(KIND==2) begin
            for(int i=0;i<3;i++) begin write_reg(8,3,15,i); read_reg(8,3); write_reg(8,0,1); end
            write_reg(8,3,0); read_reg(8,0);
            write_reg('h10,'h1234,15); check(observed_baud=='h1234,"baud write"); read_reg('h10,0);
            write_reg('h10,0,0); check(observed_baud=='h1234,"zero-strobe baud write");
            write_reg('h10,'hff,1); check(observed_baud=='h12ff,"baud byte write");
            write_reg('hfc,0,15,0,2); read_reg('hfc,0,2);
            send_ar(8);
            fork send_ar('hfc); begin repeat(8) tick(); consume_r(0); consume_r(0,2); end join
        end else begin
            for(int i=0;i<3;i++) write_reg('h40000008,0,15,i,2);
            read_reg('h40000000,0);
            send_ar('h40000000);
            fork send_ar('h40000008); begin repeat(8) tick(); consume_r(0); consume_r(0,2); end join
        end
        // Reset cancels incomplete requests and releases all responses.
        send_aw(KIND==2 ? 8:0);
        @(negedge clk); rst_n=0; #1; check(!bvalid && !rvalid,"asynchronous reset clears VALID");
        repeat(2) tick(); @(negedge clk); rst_n=1;
        repeat(10) tick(); check(!bvalid && !rvalid,"no phantom response after reset");
        if(KIND==0 || KIND>=4) read_reg(0,9); // SRAM contents survive reset
        $display("PASS tb_axi_slave KIND=%0d checks=%0d",KIND,checks); $finish;
    end
    initial begin #200000; $fatal(1,"slave timeout KIND=%0d AW/W/B=%0d/%0d/%0d AR/R=%0d/%0d",KIND,aw_count,w_count,b_count,ar_count,r_count); end
endmodule
