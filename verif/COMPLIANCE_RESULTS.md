# v1.4 RTL verification and datasheet alignment

Updated 2026-09-17. Baseline Git revision:
`e144336cf129d108a3aa57a1b60b9ac8811e7a8f`, plus the recorded working-tree changes.
Architectural-test revision: `c2fe5dc72e1ca898d9ea8410b8130e0e1ebd422a`.
Tools: Verilator 5.051 development revision v5.050-309-g228635918,
RISC-V GCC 15.2.0, project Sail/OpenOCD/GDB installations, and Icarus Verilog.

## Reproduction and provenance

Run `make compliance COMPLIANCE_GROUPS=full`, or select groups such as
`make compliance COMPLIANCE_GROUPS="amo csr axi reset"`.
`python3 scripts/compliance_regression.py full --list` prints the commands.
On this macOS host the installed standalone compiler tools are selected with
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`; the runner prefers GNU
`gmake` when available.

The runner retains command lines, exit status, durations, RTL digest, revision,
source hashes, and working-tree patch in `build/compliance/runs/<UTC>/`.
The ISA matrix additionally saves each configuration, generated test selection,
compiler/reference-model configuration, build log, execution log, and hashes
in `build/compliance/isa-matrix/`. No missing prerequisite is silently skipped.
Checked-in summaries under `verif/results/` identify the final measured runs.

CI runs the directed AMO, CSR, trap, interrupt, timer, memory, AXI, UART, JTAG,
CDC, and reset groups and uploads their logs. The complete local release run
also includes the independent-reference ISA matrix, parameter matrix, and
OpenOCD/GDB interoperability, whose dependencies are not provisioned by CI.

## Final result

The final run `build/compliance/runs/20260917T012150Z/` passed **42 of 42
commands**, with **zero failures**. Its RTL digest and every recorded source
hash match the final implementation and tests. The checked-in records are
[full summary](results/v1.4-20260917.json),
[ISA matrix](results/isa-matrix-20260917.json), and
[source hashes](results/sources-20260917.json).
Earlier runs that exposed regressions remain in the build tree; they are not
reported as passing releases. The final OpenOCD results are 29 JTAG, 29 cJTAG,
and nine GDB tests passed with zero skips, plus the extended checks listed below.

The datasheet was rendered with Asciidoctor. All internal links resolve and
all section headings parse correctly. `git diff --check` and Python script
compilation pass. No commit or staging changes were made by this task.

## Defects reproduced before correction

The failure excerpts in `results/reproductions-20260916.txt` preserve the
original symptoms. The new tests were written and failed before the relevant
RTL behavior was changed.

1. **MSIP byte strobes:** zero-strobe/other-lane writes changed MSIP. Gate the
   update with lane 0. **MTIME zero-strobe writes:** updating an unchanged
   slice suppressed the free-running increment. Only update enabled lanes.
2. **RAM stale read:** the controller captured SRAM data before its registered
   output updated. Add a pending read cycle before capturing the response.
3. **RAM lost B response:** accepting another write while the prior B response
   was stalled overwrote response state. Gate AW/W acceptance while B is pending
   and form writes only from actual handshakes or buffered channel data.
4. **UART W-before-AW deadlock:** add independent W buffering and combine it
   with the accepted/buffered AW. **UART BAUDDIV strobes:** update low/high bytes
   only under WSTRB[0]/[1]. **UART stalled read overwrite:** capture read data
   at AR acceptance and hold both data and response until consumed.
5. **Magic stalled RRESP overwrite:** stop accepting an AR while its prior
   response is stalled; allow replacement when that response is consumed.
6. **TCM simultaneous AR/AW deadlock:** IRAM and DRAM advertised two accepts but
   could service only one. Give reads priority and change state only on an
   actual channel handshake. Both real SoC TCM ports pass the reproducer.
7. **Crossbar repeated read address:** suppress AR after the selected slave
   accepts it. Gate R responses to active transactions. **Premature DECERR B:**
   wait for W acceptance even for an unmapped write and suppress repeated W.
8. **Debug command replay after independent system reset:** the receiving
   engine reset while the TAP retained its old dispatch toggle. System reset
   now resets the TAP as well, so a completed command cannot replay. `ndmreset`
   still leaves the Debug Module active. The focused test checks exactly one
   register-write acknowledgement and no replay across independent resets.
9. **Debugger TCM response leaked to CPU AXI:** OpenOCD's alias-access test
   tripped the new CPU-port BVALID stability assertion. A stale CPU alias
   address selected a TCM response belonging to the debugger. Gate TCM RVALID
   and BVALID by the CPU's per-bank pending flags. The original OpenOCD test
   passes with assertions after this correction.

Other corrections required no datapath change: `AMO_EN=0` disables LR/SC as well
as other AMOs; the old parameter comment was wrong. Software now receives the
configured TCM bases/sizes in its linker script. ACT configuration now reports
EBREAK's PC in `mtval` and address-misaligned LR/SC exceptions, matching executed
trap tests. The RV32E test harness defines RVTEST_E and uses a generated overlay
that omits impossible x16–x31 saves from the upstream failure reporter. The
upstream checkout is not edited. Zcmp directed tests use the hardware parameter
instead of silently skipping RV32E, and avoid an incompatible libc multilib.

## Measured coverage

### ISA, atomic operations, and traps

- The effective ISA matrix contains **24 configurations**: 16 RV32I and eight
  RV32E combinations of M, A, B, and Zcmp. RV32E forces the B group off; C,
  Zicsr, and Zifencei are always present. `scripts/isa_matrix.py --list` is the
  executable enumeration. All configurations elaborate and execute their
  applicable architectural tests: **2,120 test executions** in total.
- The existing default ACT flow additionally passes **128 ELFs**, including
  its local Zcmp tests. Sail is the reference for applicable independent ACT
  tests; the project's ISS is used for the local Zcmp reference path. The
  matrix separately executes all six Zcmp instruction classes when enabled.
  These results are not independent Zcmp certification. Where the upstream
  suite lacks an RV32E extension test, project directed tests provide coverage.
- All eleven LR/SC/AMO instruction forms are checked with positive and negative
  operands (**22 probes per configuration**). Enabled operations return the
  expected old value and update memory correctly. Disabled operations trap
  once with exact cause/PC/instruction value and no register or memory changes.
- `tb_disabled_isa` checks **32,779 disabled/reserved encodings**, including
  the AMO encoding sweep, all M operations, and representative B operations.
  `trap_contract` executes disabled M/B/Zcmp probes at the CPU, rather than
  relying solely on decoder outputs.
- `tb_csr` passes **82 cycle-level checks**. CPU-generated tests check exact
  `mcause`, `mepc`, and `mtval` for ECALL, EBREAK, unsupported/read-only CSR
  accesses, instruction/load/store access faults, misaligned LW/SW and
  LR/SC/AMO. Normal control transfers cannot generate instruction-address
  misalignment with always-present C (IALIGN=16); cause-0 CSR capture is
  separately injected and checked. There is no claim of U/S-mode behavior.
- Existing atomic compatibility, nested-interrupt, trap, and fence regressions
  cover reservation behavior, ordering, and interrupt/trap sequencing.

### Bus, memory, interrupts, and reset

- Generic slave tests exercise RAM RW/RO, UART, Magic, and both actual SoC TCM
  ports. AW and W arrive together or in either order. Randomized B/R stalls,
  byte writes, consecutive and concurrent operations, reset with a partial
  request, unsupported offsets, and SRAM retention are checked.
- Default-seed slave checks: RAM RW **1,191**, RAM RO **18**, UART **112**,
  Magic **38**, IRAM TCM **1,199**, DRAM TCM **1,199**. Timing-dependent check
  counts can vary with seed or added stimulus.
- Crossbar tests check duplicate requests, unmapped writes, overlapping decode
  priority, one-hot routing, and error-state invariants. Stability assertions
  monitor every crossbar slave, both master paths, and the external AXI port.
- `+AXI_STALLS` independently delays all five external-memory channels without
  withdrawing an exposed VALID. External instruction/data access, byte/halfword/
  word transfers, ordering, and atomic compatibility tests pass with these
  delays. Fault probes separately verify error-to-trap propagation.
- `memory_map` checks **34** first/last/below/above data addresses across TCM,
  aliases, peripherals, external RAM, and catch-all regions. Existing TCM alias
  and external-RAM tests exercise instruction paths separately.
- The controller runs **100 randomized register transactions**, plus timer,
  strobe, priority, pending, reset, and unsupported-register checks: **1,176**
  checks at the default seed. Counts 2, 16, and 32 exercise the standalone
  interrupt-count parameter; the SoC wiring is fixed at 16. `uart_route`
  verifies the actual UART interrupt OR-routing into source 0.
- Reset tests observe immediate assertion, no between-edge release, release
  on the second system-clock edge, a nondefault external boot vector, TCM
  retention, pending interrupts, and JTAG-disabled operation. OpenOCD covers
  reset while halted, default boot PC, hartreset, ndmreset, and havereset.
- The meaningful implementation matrix includes default, no-A, no-debug,
  minimum RV32EC, serial arithmetic/shift, no-B/Zcmp, and 64 KB TCM; trigger
  counts 0/1/2/4 and interrupt counts 2/16/32 are separately elaborated/tested.
  This does not enumerate arbitrary numeric base/size/clock Cartesian products.
- All **27 disabled-debug constant assignments** pass isolated four-state
  Icarus evaluation; runtime SoC assertions check branch selection and safe
  outputs. This is deliberately not described as whole-chip X propagation.

### Debug, JTAG, and CDC

- **246 directed checks** pass at default, slow, and fast/jittered TCK timing.
  Coverage includes every unsupported IR and DMI address, independent resets,
  exactly-once register writes, busy handling, and the implemented optional
  feature fields. Separate short-timeout tests verify completion with errors
  when the memory target withholds acknowledgement.
- Interoperability covers **29 JTAG, 29 cJTAG, and nine GDB tests**, plus GDB
  hello/Zcmp trace comparison, stepping without tracing, and FTDI cJTAG
  activation. Raw pass/fail/skip counts are retained in the run logs.
- [CDC_REVIEW.md](CDC_REVIEW.md) inventories each crossing and its protocol.
  Assertions check bundled command/SBA payload stability through both
  synchronization stages and dispatch. Busy/clear protocols, asynchronous
  ratios, and clock jitter are exercised. No installed dedicated structural
  CDC/formal tool was available. Physical metastability, bundled-path timing,
  multibit status coherency, and reset recovery/removal remain integration
  responsibilities. Hartreset does not use the SoC two-flop release path.

## Interpretation and release boundary

“Verified” means the configuration and stimulus identified above passed.
It does not mean exhaustive state-space coverage or formal certification.
The local controller remains project-specific and CLIC-like; debug remains a
RISC-V Debug Specification 1.0-oriented subset. The architectural suite's
privileged/interrupt exclusions in `verif/Makefile` remain explicit and are
supplemented by directed tests, not silently promoted to certification.

The datasheet now links register definitions instead of duplicating them,
distinguishes software guidance from integration limits, and describes the
measured UART, AXI, exception, memory, and reset behavior.

## Traceability

- ISA → core/decoder/RVC → ACT matrix, disabled decoder, Zcmp tests → Processor Core.
- Traps/CSRs → core/CSR → `tb_csr`, `trap_contract`, nested IRQ → Exceptions and CSRs.
- AMO → core/decoder → `amo_config`, atomic compatibility → Atomic Memory Operations.
- Interrupts/timer → CLIC/CSR → `tb_clic`, `uart_route`, nested IRQ → Local Controller.
- AXI/TCM → AXI modules/SoC/top → slave/crossbar benches, stalled external RAM,
  OpenOCD alias access → Memory Map and AXI Interfaces.
- UART → UART → generic slave and software UART tests → UART Register Map.
- Reset/CDC/debug → SoC/JTAG/top → independent reset, JTAG, OpenOCD/GDB,
  disabled-debug checks → Clock and Reset, Debug and JTAG.

## Register metadata feasibility

A shared metadata source could generate register addresses and documentation.
Behavioral checks must remain independently authored so generated expected
values do not repeat an RTL error. No stable RTL register refactoring was
introduced solely for documentation generation.
