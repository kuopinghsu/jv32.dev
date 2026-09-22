# Debug clock-domain inventory

Reviewed against `jtag_top.sv`, `jtag_tap.sv`, `jv32_dtm.sv`,
`cjtag_bridge.sv`, `jv32_soc.sv`, and `jv32_top.sv`.
This is an RTL inventory and simulation record, not physical CDC signoff.

## TCK to system clock

- `cmd_wr_toggle`: two synchronizer flops and an edge-history flop. Bundled
  `command_reg`, `data0`, `data1` are sampled on the detected edge. Program
  buffer words remain stable while the abstract command executes. The TAP
  busy/holdoff logic blocks further abstract-command writes during execution.
- `sba_wr_toggle`, `sba_rd_toggle`: two flops, edge detection, and pending
  latches. Bundled address, write data, access size, and autoincrement fields
  accompany the request. Busy responses prevent another accepted transaction.
- `cmderr_clr_tog`, `sb_err_clr_tog`: two-flop toggle synchronizers carrying
  stable three-bit W1C masks.
- `data1_clr_tog`, `sbdata0_clr_tog`, `sbaddress0_clr_tog`: two-flop toggle
  synchronizers acknowledge consumption/overwrite of result-valid state.
- `dmactive`, `haltreq`, `resumereq`: two-flop synchronized levels.
- `any_noexist`: stable hart-selection decode, used directly by the engine.
  Hart selection is blocked while an abstract command is busy; selection must
  settle before command dispatch. It is not a separately synchronized level.
- `progbuf0`, `progbuf1`: stable multibit command payload, directly exposed to
  the core during program-buffer execution; no independent data synchronizers.
- `ndmreset`: direct asynchronous reset request. The SoC synchronizes release
  through two system-clock flops. It must not reset the Debug Module itself.
- `hartreset`: direct core-local reset request. It bypasses the SoC reset
  synchronizer; recovery/removal timing remains an integration requirement.

There is no unprotected one-cycle dispatch pulse crossing. Dispatch pulses are
formed after synchronization from toggles. Busy and result-valid serve as
protocol acknowledgements; they are not a universal request/ack toggle pair.

## System clock to TCK

- `cmd_busy`, `sba_busy`, `halted`, `resumeack`: two-flop level chains, then
  TCK-domain status registers.
- `cmderr`, `sb_err`: multibit status sampled through two stages and then a
  TCK status register. Software polls after busy clears. These chains alone
  do not establish coherency during a multibit transition.
- `data0_result` and its valid level: two-stage data and valid chains; the
  DMI read mux selects the result while valid is set.
- `data1_result`, `sbdata0`, `sbaddress0`: stable bundled results. Two-stage
  valid chains and rising-edge detection cause the TAP to capture the data;
  the corresponding clear toggles return to the engine.

## Pin and generated-clock crossings

In four-wire mode the TAP uses external TCK directly. TDO updates on its
falling edge. In cJTAG mode, `tckc` and `tmsc` have two system-clock sampling
flops followed by edge detection. The bridge generates TAP TCK/TMS/TDI and
samples TDO as described in `cjtag_bridge.sv`; its documented sampling
requirement is system clock at least six times TCKC. Four-wire fast-TCK tests
must not be interpreted as cJTAG timing qualification.

## Checks and boundaries

The existing engine assertions check command, SBA, and clear-mask stability
through both synchronization stages and at dispatch. They are enabled by `--assert` in the directed JTAG target.
The regression runs slow, fast, and jittered TCK against a 10 ns system clock;
checks busy rejection, timeout completion, data transfer, resets, and external
OpenOCD/GDB interoperability. Timeout tests explicitly exercise missing target
acknowledgements and require an error response instead of an infinite wait.

No dedicated structural CDC/formal tool was found in the installed PATH.
Verilator simulation cannot model metastability or prove all asynchronous
phases. Physical implementation must constrain bundled-data paths and audit
reset release, multibit status coherency, and direct stable-level paths. Do not
claim full structural CDC signoff from the simulation results.

## Reset interaction

The independent-reset test reproduced a completed-command replay when only
system reset cleared the receiving engine while the TAP retained a dispatch
toggle. `jtag_top` now combines external system reset into the TAP reset input.
This clears both sides of each dispatch handshake. `ndmreset` remains separate
and leaves debug state active. The focused reproduction passes after the fix;
the regression also tests TAP reset, DMI reset, DMI hard reset, and DM soft reset.
