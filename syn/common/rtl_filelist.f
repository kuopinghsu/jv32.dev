# RTL file list for jv32 synthesis
# Used by OpenLane2 via VERILOG_FILES in openlane/config.yaml
# (and optionally by Yosys/Genus if used standalone)
#
# Order matters for tools that do not parse packages before use.
# Packages and interfaces must precede the modules that reference them.

# Core package (types, opcodes, pipeline structs)
../rtl/jv32/core/jv32_pkg.sv

# Core pipeline stages
../rtl/jv32/core/jv32_rvc.sv
../rtl/jv32/core/jv32_decoder.sv
../rtl/jv32/core/jv32_alu.sv
../rtl/jv32/core/jv32_regfile.sv
../rtl/jv32/core/jv32_csr.sv
../rtl/jv32/core/jv32_core.sv

# JTAG / debug transport
../rtl/jv32/core/jtag/cjtag_bridge.sv
../rtl/jv32/core/jtag/jv32_dtm.sv
../rtl/jv32/core/jtag/jtag_tap.sv
../rtl/jv32/core/jtag/jtag_top.sv

# Synthesisable SRAM wrapper (maps to OpenRAM macro)
../syn/lib/sram_1rw.sv

# AXI infrastructure
../rtl/axi/axi_pkg.sv
../rtl/axi/axi_xbar.sv
../rtl/axi/axi_uart.sv
../rtl/axi/axi_clic.sv
../rtl/axi/axi_ram_ctrl.sv
../rtl/axi/axi_magic.sv

# JV32 top (core + TCM)
../rtl/jv32/jv32_top.sv

# SoC top
../rtl/jv32_soc.sv
