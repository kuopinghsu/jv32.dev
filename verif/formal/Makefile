# Formal verification Makefile
# Usage:
#   make              — run all formal checks
#   make csr          — run jv32_csr BMC (generates flat file, runs sby)
#   make decoder      — run jv32_decoder prove (generates flat file, runs sby)
#   make rvc          — run jv32_rvc BMC (generates flat file, runs sby)
#   make alu          — run jv32_alu BMC (generates flat file, runs sby)
#   make gen          — regenerate all flat SV files without running sby
#   make gen_csr      — regenerate jv32_csr_flat.sv only
#   make gen_decoder  — regenerate jv32_decoder_flat.sv only
#   make gen_rvc      — regenerate jv32_rvc_flat.sv only
#   make gen_alu      — regenerate jv32_alu_flat.sv only
#   make clean        — remove sby work directories
#   make cleanall     — also remove generated flat SV files

.PHONY: all csr decoder rvc alu gen gen_csr gen_decoder gen_rvc gen_alu clean cleanall

all: csr decoder rvc alu

# ---- CSR formal verification ----
# gen_flat_csr.py strips the package wrapper, inlines jv32_dbgmsg.svh,
# and injects FORMAL assertion blocks into jv32_csr.
# Engine: smtbmc --nopresat --unroll z3  (depth 20, ~23 s)
csr: jv32_csr_flat.sv
	sby -f jv32_csr.sby

gen_csr: jv32_csr_flat.sv

jv32_csr_flat.sv: gen_flat_csr.py \
	../../rtl/jv32/core/jv32_csr.sv \
	../../rtl/jv32/core/jv32_pkg.sv \
	../../rtl/jv32/jv32_dbgmsg.svh
	python3 gen_flat_csr.py

# ---- Decoder formal verification ----
# gen_flat_decoder.py strips the package wrapper and injects FORMAL assertion
# blocks into jv32_decoder (purely combinational; mode prove, depth 1).
# Properties: mutual exclusion, register-field wiring, load/store outputs, etc.
decoder: jv32_decoder_flat.sv
	sby -f jv32_decoder.sby

gen_decoder: jv32_decoder_flat.sv

jv32_decoder_flat.sv: gen_flat_decoder.py \
	../../rtl/jv32/core/jv32_decoder.sv \
	../../rtl/jv32/core/jv32_pkg.sv \
	../../rtl/jv32/jv32_dbgmsg.svh
	python3 gen_flat_decoder.py

# ---- RVC expander formal verification ----
# gen_flat_rvc.py strips the package wrapper, removes the `ifndef SYNTHESIS
# debug block, and injects FORMAL assertion blocks into jv32_rvc.
# Engine: smtbmc --nopresat --unroll z3  (depth 20)
rvc: jv32_rvc_flat.sv
	sby -f jv32_rvc.sby

gen_rvc: jv32_rvc_flat.sv

jv32_rvc_flat.sv: gen_flat_rvc.py \
	../../rtl/jv32/core/jv32_rvc.sv \
	../../rtl/jv32/core/jv32_pkg.sv \
	../../rtl/jv32/jv32_dbgmsg.svh
	python3 gen_flat_rvc.py

# Convenience target to regenerate all flat files at once
gen: gen_csr gen_decoder gen_rvc gen_alu

# ---- ALU formal verification ----
# gen_flat_alu.py strips the package wrapper, removes `ifndef SYNTHESIS blocks,
# and injects FORMAL assertion blocks into jv32_alu.
# sby chparam overrides: FAST_MUL=1, MUL_MC=0, FAST_DIV=1 -> fully combinational.
# Engine: smtbmc --nopresat --unroll z3  (depth 1, ~2 s)
alu: jv32_alu_flat.sv
	sby -f jv32_alu.sby

gen_alu: jv32_alu_flat.sv

jv32_alu_flat.sv: gen_flat_alu.py \
	../../rtl/jv32/core/jv32_alu.sv \
	../../rtl/jv32/core/jv32_pkg.sv \
	../../rtl/jv32/jv32_dbgmsg.svh
	python3 gen_flat_alu.py

# ---- Cleanup ----
clean:
	rm -rf jv32_csr/ jv32_decoder/ jv32_rvc/ jv32_alu/

cleanall: clean
	rm -f jv32_csr_flat.sv jv32_decoder_flat.sv jv32_rvc_flat.sv jv32_alu_flat.sv
