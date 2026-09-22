`timescale 1ns/1ps
import jv32_pkg::*;
module tb_csr;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0;
    logic [11:0] csr_addr = 0, dbg_csr_addr_i = 0;
    logic [2:0] csr_op = 0;
    logic [31:0] csr_wdata = 0, exception_pc = 'h80000102, exception_tval = 'hdeadbeef;
    logic [4:0] csr_zimm = 0;
    logic exception = 0, mret = 0, wb_valid = 0;
    exc_cause_e exception_cause = EXC_ILLEGAL_INSTR;
    logic [31:0] irq_mepc = 'h80000202;
    logic timer_irq = 0, external_irq = 0, software_irq = 0, clic_irq = 0;
    logic [7:0] clic_level = 0, clic_prio = 0;
    logic [4:0] clic_id = 0;
    logic instret_inc = 0, dbg_halted_i = 0, dbg_csr_we_i = 0, dcsr_stopcount_i = 0;
    logic [63:0] mtime_i = 0;
    logic [31:0] dbg_csr_wdata_i = 0;
    wire [31:0] csr_rdata, mtvec_o, mepc_o, tail_chain_pc_o, irq_cause, irq_pc, dbg_csr_rdata_o;
    wire clic_ack, tail_chain_o, irq_pending, heartbeat_o, dbg_csr_illegal_o;
    jv32_csr dut (.*);
    assert property (@(posedge clk) disable iff(!rst_n)
        exception |=> mepc_o == ($past(exception_pc) & 32'hfffffffe));
    assert property (@(posedge clk) disable iff(!rst_n)
        clic_ack |-> clic_irq && clic_level > dut.mintthresh_reg);
    int checks = 0;
    task automatic check(input bit ok, input string label);
        checks++;
        if (!ok) $fatal(1, "FAIL %s", label);
    endtask
    task automatic tick;
        @(posedge clk); #1;
    endtask
    task automatic read_csr(input logic [11:0] addr, input logic [31:0] value);
        csr_addr = addr; #1;
        check(csr_rdata == value, $sformatf("CSR %h got %h expected %h", addr, csr_rdata, value));
    endtask
    task automatic write_csr(input logic [11:0] addr, input logic [31:0] value,
                             input logic [2:0] op = 1);
        @(negedge clk); csr_addr = addr; csr_wdata = value; csr_zimm = value[4:0]; csr_op = op;
        tick(); @(negedge clk); csr_op = 0;
    endtask
    task automatic return_trap;
        @(negedge clk); mret = 1; tick(); @(negedge clk); mret = 0;
    endtask
    int causes[9] = '{0,1,2,3,4,5,6,7,11};
    initial begin
        #1; rst_n = 1; #1; rst_n = 0; #1;
        read_csr('h300, 'h1800);
        read_csr('h304, 0); read_csr('h344, 0); read_csr('h305, 0);
        read_csr('h340, 0); read_csr('h341, 0); read_csr('h342, 0); read_csr('h343, 0);
        @(negedge clk); rst_n = 1;
        write_csr('h340, 'h55); read_csr('h340, 'h55);
        write_csr('h340, 'haa, 2); read_csr('h340, 'hff);
        write_csr('h340, 'h0f, 3); read_csr('h340, 'hf0);
        write_csr('h340, 3, 5); read_csr('h340, 3);
        write_csr('h340, 4, 6); read_csr('h340, 7);
        write_csr('h340, 1, 7); read_csr('h340, 6);
        write_csr('h340, 0, 2); read_csr('h340, 6);
        write_csr('h341, 'h123); read_csr('h341, 'h122);
        write_csr('h305, 'h103); read_csr('h305, 'h101);
        write_csr('h304, '1); read_csr('h304, 'h888);
        timer_irq = 1; software_irq = 1; external_irq = 1; #1;
        read_csr('h344, 'h888); check(!irq_pending, "global interrupt mask");
        write_csr('h300, 8); #1;
        check(irq_pending && irq_cause == 'h8000000b && irq_pc == 'h12c, "external priority/vector");
        external_irq = 0; #1;
        check(irq_cause == 'h80000007 && irq_pc == 'h11c, "timer priority/vector");
        timer_irq = 0; #1;
        check(irq_cause == 'h80000003 && irq_pc == 'h10c, "software vector");
        write_csr('h304, 0); #1; check(!irq_pending, "mie mask");
        software_irq = 0;
        for (int i = 0; i < 9; i++) begin
            write_csr('h300, 8);
            @(negedge clk); exception = 1; exception_cause = exc_cause_e'(causes[i]);
            tick(); exception = 0;
            read_csr('h341, exception_pc); read_csr('h342, 32'(causes[i]));
            read_csr('h343, exception_tval); read_csr('h300, 'h1880);
            return_trap(); read_csr('h300, 'h1888);
        end
        write_csr('h305, 'h200); write_csr('h304, 'h888);
        @(negedge clk); external_irq = 1; wb_valid = 1; exception = 1;
        exception_cause = EXC_ILLEGAL_INSTR; tick(); read_csr('h342, 2);
        @(negedge clk); external_irq = 0; wb_valid = 0; exception = 0;
        return_trap();
        @(negedge clk); external_irq = 1; #1; check(irq_pc == 'h200, "direct vector");
        tick(); check(mepc_o == exception_pc, "no interrupt commit without WB");
        @(negedge clk); wb_valid = 1; tick();
        read_csr('h341, irq_mepc); read_csr('h342, 'h8000000b); read_csr('h343, 0);
        @(negedge clk); external_irq = 0; wb_valid = 0; return_trap();
        write_csr('h307, 'h43f); write_csr('h347, 10);
        clic_irq = 1; clic_level = 10; clic_id = 3; #1;
        check(!irq_pending, "CLIC threshold equality blocked");
        clic_level = 11; #1; check(irq_pending && clic_ack && irq_pc == 'h40c, "CLIC threshold/vector");
        @(negedge clk); wb_valid = 1; tick();
        @(negedge clk); wb_valid = 0; mret = 1; #1;
        check(tail_chain_o && tail_chain_pc_o == 'h40c, "tail-chain redirect");
        tick(); check(mepc_o == irq_mepc, "tail-chain preserves return PC");
        @(negedge clk); mret = 0; clic_irq = 0;
        return_trap(); read_csr('h300, 'h1888);
        dbg_csr_addr_i = 'hfff; #1; check(dbg_csr_illegal_o, "unsupported debug CSR");
        @(negedge clk); rst_n = 0; #1; read_csr('h300, 'h1800);
        $display("PASS tb_csr (%0d checks)", checks); $finish;
    end
    initial begin #100000; $fatal(1, "timeout"); end
endmodule
