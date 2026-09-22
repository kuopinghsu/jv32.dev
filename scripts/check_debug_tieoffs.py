#!/usr/bin/env python3
"""Check JTAG_EN=0 tie-offs and evaluate their actual expressions in four states.

This isolates constant assignments from the disabled generate branch. It is
not a four-state simulation of the complete processor. The SoC bench separately
checks that this branch is selected and its outputs are quiescent at runtime.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
required = set('''dbg_halt_req dbg_resume_req dbg_reg_we dbg_reg_addr dbg_reg_wdata
    dbg_csr_we dbg_csr_addr dbg_csr_wdata dbg_pc_we dbg_pc_wdata dbg_mem_req
    dbg_mem_addr dbg_mem_we dbg_mem_wdata dbg_ndmreset dbg_hartreset dbg_singlestep
    dbg_ebreakm dbg_dcsr_stopcount progbuf0 progbuf1 dbg_tdata1 dbg_tdata2
    jtag_pin1_tms_o jtag_pin1_tms_oe jtag_pin3_tdo_o jtag_pin3_tdo_oe'''.split())
source = (ROOT/'rtl/jv32_soc.sv').read_text().split('begin : gen_no_jtag',1)[1].split('logic _unused_jtag_pins',1)[0]
assignments = dict(re.findall(r'assign\s+(\w+)\s*=\s*([^;]+);',source))
if assignments.keys() != required:
    raise SystemExit(f'Tie-off coverage changed: missing={required-assignments.keys()}, extra={assignments.keys()-required}')
bench = ['module tb;']
for name, expression in assignments.items():
    # Reject logic/payload dependencies: disabled outputs must be constants.
    if not re.fullmatch(r"(?:\d+)?'[bhd]?[0-9a-fA-F_xXzZ]+",expression.strip()):
        raise SystemExit(f'{name} is not a constant tie-off: {expression}')
    bench += [f'wire [127:0] {name}; assign {name} = {expression};',
              f'initial begin #1; if (^{name} === 1\'bx) $fatal(1,"unknown tie-off: {name}"); end']
bench += ['initial begin #2; $display("PASS 27 disabled-debug constant tie-offs (four-state)"); $finish; end','endmodule']
with tempfile.TemporaryDirectory(prefix='jv32-tieoffs-') as tmp:
    path=Path(tmp); (path/'tb.sv').write_text('\n'.join(bench)+'\n')
    subprocess.run(['iverilog','-g2012','-s','tb','-o',str(path/'tb'),str(path/'tb.sv')],check=True)
    subprocess.run(['vvp',str(path/'tb')],check=True)
