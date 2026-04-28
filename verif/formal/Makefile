# Formal verification Makefile
# Usage:
#   make          — run all formal checks
#   make csr      — run jv32_csr BMC (generates flat file, runs sby)
#   make clean    — remove sby work directories
#   make cleanall — also remove generated flat SV files

.PHONY: all csr clean cleanall

all: csr

# ---- CSR formal verification ----
# gen_flat_csr.py strips the package wrapper, inlines jv32_dbgmsg.svh,
# and injects FORMAL assertion blocks into jv32_csr.
# Engine: smtbmc --nopresat --unroll z3  (depth 20, ~23 s)
csr: jv32_csr_flat.sv
	sby -f jv32_csr.sby

jv32_csr_flat.sv: gen_flat_csr.py \
	../../rtl/jv32/core/jv32_csr.sv \
	../../rtl/jv32/core/jv32_pkg.sv \
	../../rtl/jv32/jv32_dbgmsg.svh
	python3 gen_flat_csr.py

# ---- Cleanup ----
clean:
	rm -rf jv32_csr/

cleanall: clean
	rm -f jv32_csr_flat.sv
