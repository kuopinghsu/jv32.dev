`timescale 1ns/1ps
module tb_clic #(parameter int IRQ_COUNT=16);
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0;
    logic [31:0] s_awaddr = 0, s_wdata = 0, s_araddr = 0;
    logic [3:0] s_wstrb = 0;
    logic s_awvalid = 0, s_wvalid = 0, s_bready = 0;
    logic s_arvalid = 0, s_rready = 0;
    wire s_awready, s_wready, s_bvalid, s_arready, s_rvalid;
    wire [1:0] s_bresp, s_rresp;
    wire [31:0] s_rdata;
    logic [IRQ_COUNT-1:0] ext_irq_i = 0;
    wire [63:0] mtime_o;
    wire timer_irq_o, software_irq_o, clic_irq_o;
    wire [7:0] clic_level_o, clic_prio_o;
    wire [4:0] clic_id_o;
    axi_clic #(.NUM_IRQ(IRQ_COUNT)) dut (.*);
    int checks = 0;

    task automatic check(input bit ok, input string label);
        checks++;
        if (!ok) $fatal(1, "FAIL %s", label);
    endtask
    task automatic tick;
        @(posedge clk); #1;
    endtask
    task automatic aw(input logic [31:0] addr);
        @(negedge clk); s_awaddr = addr; s_awvalid = 1;
        do @(posedge clk); while (!s_awready);
        @(negedge clk); s_awvalid = 0;
    endtask
    task automatic wd(input logic [31:0] data, input logic [3:0] strb);
        @(negedge clk); s_wdata = data; s_wstrb = strb; s_wvalid = 1;
        do @(posedge clk); while (!s_wready);
        @(negedge clk); s_wvalid = 0;
    endtask
    task automatic write_reg(input logic [31:0] addr, data,
                             input logic [3:0] strb = 15, input int order = 0);
        if (order == 1) begin aw(addr); repeat (3) tick(); wd(data, strb); end
        else if (order == 2) begin wd(data, strb); repeat (3) tick(); aw(addr); end
        else fork aw(addr); wd(data, strb); join
        while (!s_bvalid) tick();
        repeat ($urandom_range(1, 8)) begin tick(); check(s_bvalid && s_bresp == 0, "B backpressure"); end
        @(negedge clk); s_bready = 1;
        tick(); @(negedge clk); s_bready = 0;
    endtask
    task automatic read_reg(input logic [31:0] addr, expected);
        @(negedge clk); s_araddr = addr; s_arvalid = 1;
        do @(posedge clk); while (!s_arready);
        @(negedge clk); s_arvalid = 0;
        while (!s_rvalid) tick();
        repeat ($urandom_range(1, 8)) begin
            check(s_rvalid && s_rresp == 0 && s_rdata == expected, "read/backpressure"); tick();
        end
        @(negedge clk); s_rready = 1;
        tick(); @(negedge clk); s_rready = 0;
    endtask

    assert property (@(posedge clk) disable iff (!rst_n)
        s_rvalid && !s_rready |=> s_rvalid && $stable({s_rdata,s_rresp}));
    assert property (@(posedge clk) disable iff (!rst_n)
        s_bvalid && !s_bready |=> s_bvalid && $stable(s_bresp));
    assert property (@(posedge clk) disable iff (!rst_n)
        clic_irq_o |-> ext_irq_i[clic_id_o] && dut.clicint_ie[clic_id_o]);
    assert property (@(posedge clk) disable iff (!rst_n)
        ((dut.aw_active || (s_awvalid && s_awready)) &&
         (dut.w_active || (s_wvalid && s_wready)) && dut.wr_strb_sel == 0)
        |=> mtime_o == $past(mtime_o) + 64'd1);

    logic [63:0] before_time;
    logic [31:0] random_data;
    int random_index;
    initial begin
        #1; rst_n = 1; #1; rst_n = 0; #1;
        check(mtime_o == 0 && !software_irq_o && !timer_irq_o && !clic_irq_o, "async reset");
        repeat (2) tick(); @(negedge clk); rst_n = 1;
        before_time = mtime_o;
        repeat (10) tick(); check(mtime_o == before_time + 10, "timer clock rate");
        read_reg('h4008, 'hffffffff); read_reg('h400c, 'hffffffff);
        write_reg('h4000, 0, 0); write_reg('h4004, 0, 0);
        for (int i = 0; i < IRQ_COUNT; i++) read_reg(32'h1000 + 4*i, 0);
        read_reg(32'h1000 + 4*IRQ_COUNT, 0); read_reg('h2000, 0);
        write_reg('h2000, '1); read_reg('h2000, 0);
        for (int order = 0; order < 3; order++) begin
            write_reg(0, 1, 1, order); check(software_irq_o, "MSIP set");
            write_reg(0, 0, 0, order); check(software_irq_o, "MSIP zero strobe ignored");
            write_reg(0, 0, 14, order); check(software_irq_o, "MSIP other lanes ignored");
            write_reg(0, 0, 1, order); check(!software_irq_o, "MSIP clear");
        end
        write_reg('h1000, 'hff55ff03); read_reg('h1000, 'h00550002);
        write_reg('h1004, 'h00660002);
        @(negedge clk); ext_irq_i = 3; #1;
        check(clic_irq_o && clic_id_o == 1 && clic_prio_o == 'h66, "higher ctl wins");
        read_reg('h1000, 'h00550003);
        write_reg('h1000, 'h00660000, 4);
        check(clic_id_o == 0 && clic_level_o == 'h66, "equal ctl lowest ID wins");
        write_reg('h1000, 0, 1); check(clic_id_o == 1, "enable lane independently writable");
        write_reg('h1004, 0, 1); check(!clic_irq_o, "masked pending sources");
        write_reg('h4008, 'h12345678); write_reg('h4008, 'haabbccdd, 5);
        read_reg('h4008, 'h12bb56dd);
        write_reg('h400c, 'h12345678); write_reg('h400c, 'haabbccdd, 10);
        read_reg('h400c, 'haa34cc78);
        // Safe comparator programming: low=max, high, final low.
        write_reg('h4008, '1); write_reg('h400c, 1); write_reg('h4008, 'h100);
        write_reg('h4004, 0); write_reg('h4000, 'hfffffff0);
        repeat (32) tick();
        check(mtime_o[63:32] == 1 && !timer_irq_o, "rollover and 64-bit compare");
        repeat (300) tick(); check(timer_irq_o, "timer >= comparator");
        write_reg('h4008, '1); write_reg('h400c, '1);
        check(!timer_irq_o, "reset sentinel disables timer");
        ext_irq_i = 0;
        for (int transaction = 0; transaction < 100; transaction++) begin
            random_data = $urandom;
            random_index = int'($urandom_range(0, IRQ_COUNT-1));
            write_reg(32'h1000 + 4*random_index, random_data, 15,
                      int'($urandom_range(0, 2)));
            read_reg(32'h1000 + 4*random_index, random_data & 32'h00ff0002);
        end
        write_reg(0, 1);
        @(negedge clk); ext_irq_i = '1; rst_n = 0; #1;
        check(mtime_o == 0 && !s_bvalid && !s_rvalid && !clic_irq_o, "reset clears state");
        $display("PASS tb_clic (%0d checks)", checks); $finish;
    end
    initial begin #100000; $fatal(1, "timeout"); end
endmodule
