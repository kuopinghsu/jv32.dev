#!/usr/bin/env python3
"""Run independently selectable RTL regression groups and retain provenance.

Group membership is coverage, not a claim that every release TODO is satisfied.
No test is silently skipped. Full includes architectural generation and debugger
interoperability, which require the tools described in verif/README.md.
"""
import argparse
import datetime
import hashlib
import json
import shutil
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def plan():
    default = "BUILD_DIR=build/compliance/default"
    def rtl(*names):
        return [["make", default, *["rtl-" + name for name in names]]]
    groups = {
        "smoke": rtl("hello", "simple"),
        "isa": [["make", "disabled-isa-tb"], ["make", "arch-test-run"],
                [sys.executable, "scripts/isa_matrix.py"]],
        "csr": [["make", "csr-tb"], *rtl("trap")],
        "trap": [["make", "csr-tb"], *rtl("trap", "trap_contract", "atomic_compat")],
        "interrupt": [["make", "clic-tb"], ["make", "csr-tb"], *rtl("clic", "nested_irq", "uart_route")],
        "timer": [["make", "clic-tb"], *rtl("trap")],
        "amo": [
            ["make", "disabled-isa-tb"],
            ["make", "BUILD_DIR=build/compliance/amo0", "AMO_EN=0", "rtl-amo_config"],
            ["make", "BUILD_DIR=build/compliance/amo1", "AMO_EN=1",
             "rtl-amo_config", "rtl-atomic", "rtl-atomic_compat"],
        ],
        "memory": rtl("memory_map", "tcm_alias", "extram", "mem_ordering", "fence", "fencei_smc"),
        "axi": [["make", "clic-tb"], ["make", "xbar-tb"],
                *[["make", "axi-slave-tb", f"SLAVE_KIND={kind}"] for kind in range(6)],
                *rtl("extram", "mem_ordering", "uart")],
        "uart": rtl("uart", "uart_route"),
        "debug": [["make", "jtag-tb"], ["make", "-C", "openocd", "all-with-gdb",
                                          "VPI_PORT=15555", "GDB_PORT=13333"]],
        "jtag": [["make", "jtag-tb"],
                 ["make", "jtag-tb", "TMO_W=5", "JTAG_TB_ARGS=+TEST=sba_timeout"]],
        "cdc": [["make", "jtag-tb", "JTAG_TB_ARGS=+TCK_LOW=31 +TCK_HIGH=37 +TCK_SETTLE=3"],
                ["make", "jtag-tb", "JTAG_TB_ARGS=+TCK_LOW=2 +TCK_HIGH=2 +TCK_SETTLE=1 +TCK_JITTER"]],
        "reset": [["make", "clic-tb"], ["make", "jtag-tb"]],
        "parameter": [[sys.executable, "scripts/check_debug_tieoffs.py"]],
    }
    for name, params in [
        ("default", []), ("noamo", ["AMO_EN=0"]),
        ("nodebug", ["JTAG_EN=0"]), ("minimal", ["RV32EC=1"]),
        ("serial", ["FAST_MUL=0", "MUL_MC=0", "FAST_DIV=0", "FAST_SHIFT=0"]),
        ("nob", ["RV32B_EN=0", "ZCMP_EN=0"]),
        ("smalltcm", ["IRAM_SIZE=65536", "DRAM_SIZE=65536"]),
    ]:
        groups["parameter"].append(["make", f"BUILD_DIR=build/compliance/param-{name}",
                                     *params, "lint-full", "rtl-amo_config"])
    for count in (2, 16, 32):
        groups["parameter"].append(["make", "clic-tb", f"CLIC_IRQ_COUNT={count}"])
    groups["axi"].append(["make", "BUILD_DIR=build/compliance/stalls", "RTL_PLUSARGS=+AXI_STALLS", "rtl-extram", "rtl-mem_ordering", "rtl-atomic_compat"])
    for count in (0, 1, 2, 4):
        groups["parameter"].append(["make", "jtag-tb-elab", f"NTRIG={count}"])
    # GNU make is required; prefer Homebrew gmake on macOS.
    make = shutil.which("gmake") or shutil.which("make") or "make"
    for commands in groups.values():
        for command in commands:
            if command[0] == "make": command[0] = make
    return groups


def main():
    groups = plan()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("groups", nargs="+", choices=[*groups, "full"])
    parser.add_argument("--list", action="store_true", help="print commands without running")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    selected = list(groups) if "full" in args.groups else args.groups
    commands = []
    for group in selected:
        for command in groups[group]:
            if command not in commands:
                commands.append(command)
    if args.list:
        print(json.dumps(commands, indent=2))
        return 0
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = args.output or ROOT / "build" / "compliance" / "runs" / stamp
    output.mkdir(parents=True, exist_ok=False)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    digest = hashlib.sha256()
    for path in sorted((ROOT / "rtl").rglob("*")):
        if path.is_file():
            digest.update(str(path.relative_to(ROOT)).encode())
            digest.update(path.read_bytes())
    report = {"utc": stamp, "revision": revision, "rtl_sha256": digest.hexdigest(),
              "groups": selected, "results": []}
    (output / "working-tree.patch").write_bytes(subprocess.check_output(["git", "diff", "HEAD"], cwd=ROOT))
    sources = {}
    for directory in ("rtl", "testbench", "sw", "scripts"):
        for path in sorted((ROOT / directory).rglob("*")):
            if path.is_file() and path.suffix in (".sv", ".svh", ".c", ".cpp", ".h", ".S", ".ld", ".py", ".mak"):
                sources[str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
    for name in ("Makefile", "Makefile.cfg", "sw/Makefile", "verif/Makefile", "env.config"):
        sources[name] = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
    (output / "source-hashes.json").write_text(json.dumps(sources, indent=2) + "\n")
    for i, command in enumerate(commands):
        log = output / f"{i:03d}.log"
        print(f"[{i+1}/{len(commands)}] {' '.join(command)}", flush=True)
        start = time.monotonic()
        with log.open("w") as stream:
            result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        report["results"].append({"command": command, "returncode": result.returncode,
                                  "seconds": round(time.monotonic() - start, 3), "log": log.name})
        (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"  {'PASS' if result.returncode == 0 else 'FAIL'}: {log}", flush=True)
    failures = sum(row["returncode"] != 0 for row in report["results"])
    print(f"{len(commands) - failures} passed, {failures} failed; {output / 'summary.json'}")
    return int(failures != 0)


if __name__ == "__main__":
    sys.exit(main())
