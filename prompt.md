Desing a RISCV 32-bit IMAC 3-stage pipeline by SystemVerilog, processor name JV32
1. Refer to ~/Projects/kv32/rtl as reference (this is RISCV IMAC 5-stage pipeline processor)
2. Share software simulator ~/Project/kv32/sim, the same RTL trace output
3. Simulator: Verilator
4. No cahce. Seperate instruction RAM and data RAM (configurable, default 64KB)
5. Spec: refer to README.md
6. Provide Low-area and High-performance selection (configurable)
7. RVM23 profile requirements
8. AXI4 lite 32-/64-bit interface (configurable)
9. UART, CLIC, Magic (for exit and console output).
10. support ebreak, trap, interrupt.
