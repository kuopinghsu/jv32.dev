`timescale 1ns/1ps
import jv32_pkg::*;
module tb_disabled_isa;
    logic [31:0] instr = 0;
    wire illegal, is_amo, mem_read, mem_write, reg_we;
    jv32_decoder #(.AMO_EN(0), .RV32M_EN(0), .RV32B_EN(0)) dut (
        .instr(instr), .valid(1'b1), .illegal(illegal), .is_amo(is_amo),
        .mem_read(mem_read), .mem_write(mem_write), .reg_we(reg_we)
    );
    int checks = 0;
    task automatic expect_illegal;
        #1; checks++;
        if (!illegal) $fatal(1, "disabled instruction decoded: %h", instr);
    endtask
    initial begin
        // All AMO funct7/funct3/rs2 combinations, including every aq/rl pair.
        for (int f7 = 0; f7 < 128; f7++)
            for (int f3 = 0; f3 < 8; f3++)
                for (int rs2 = 0; rs2 < 32; rs2++) begin
                    instr = {7'(f7), 5'(rs2), 5'd11, 3'(f3), 5'd13, 7'h2f};
                    expect_illegal();
                    if (is_amo || mem_read || mem_write || reg_we)
                        $fatal(1, "disabled AMO has side-effect controls");
                end
        for (int f3 = 0; f3 < 8; f3++) begin
            instr = {7'h01, 5'd12, 5'd11, 3'(f3), 5'd13, 7'h33};
            expect_illegal();
        end
        // Representative encodings for each disabled B extension group.
        instr = 32'h20c5a6b3; expect_illegal(); // sh1add (Zba)
        instr = 32'h40c5f6b3; expect_illegal(); // andn (Zbb)
        instr = 32'h28c596b3; expect_illegal(); // bset (Zbs)
        instr = 32'h00c586b3; #1;
        if (illegal) $fatal(1, "RV32I ADD rejected");
        $display("PASS tb_disabled_isa (%0d illegal encodings + RV32I ADD)", checks);
        $finish;
    end
endmodule
