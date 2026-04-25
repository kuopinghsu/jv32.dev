#!/usr/bin/env python3

import re
import sys
from pathlib import Path

RUNNING_STEP_RE = re.compile(r"Running '([^']+)' at ")

def main() -> int:
    if len(sys.argv) != 2:
        print("usage: openlane_resume_step.py /path/to/flow.log", file=sys.stderr)
        return 2

    flow_log = Path(sys.argv[1])
    if not flow_log.is_file():
        print(f"flow log not found: {flow_log}", file=sys.stderr)
        return 1

    last_step = None
    with flow_log.open("r", encoding="utf8", errors="replace") as handle:
        for line in handle:
            match = RUNNING_STEP_RE.search(line)
            if match:
                last_step = match.group(1)

    if last_step is None:
        print("", end="")
        return 1

    # Odb.CheckDesignAntennaProperties requires the design LEF produced by
    # Magic.WriteLEF.  When RUN_MAGIC_WRITE_LEF: false the LEF is never
    # generated and this step errors with "missing required input 'LEF'".
    # classic.py now gates this step on RUN_MAGIC_WRITE_LEF, but keep this
    # bypass for runs started before that patch.
    if last_step == "Odb.CheckDesignAntennaProperties":
        print("KLayout.XOR")
        return 0

    print(last_step)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())