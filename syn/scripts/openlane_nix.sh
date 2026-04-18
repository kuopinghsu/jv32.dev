#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# openlane_nix.sh — Run OpenLane2 inside nix-shell for full dependency
# isolation (libparse, klayout, OpenROAD, etc. are provided by Nix).
#
# Usage:
#   openlane_nix.sh [openlane-args...]
#
# Environment variables honoured:
#   OPENLANE   — path to the openlane2 source tree (contains shell.nix)
#                Defaults to $HOME/opt/openlane2
#   NIX_SHELL  — nix-shell binary to use (default: nix-shell)
# ---------------------------------------------------------------------------
set -euo pipefail

OPENLANE_ROOT="${OPENLANE:-$HOME/opt/openlane2}"
NIX_SHELL_BIN="${NIX_SHELL:-nix-shell}"
SHELL_NIX="$OPENLANE_ROOT/shell.nix"

# Optional cross-invocation lock keyed by --force-run-dir.
# This prevents overlapping wrapper invocations (including direct calls that
# bypass make) from deleting/recreating the same run directory mid-flow.
FORCE_RUN_DIR=""
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "--force-run-dir" ]]; then
        j=$((i + 1))
        if [[ $j -le $# ]]; then
            FORCE_RUN_DIR="${!j}"
        fi
        break
    fi
done

LOCK_DIR=""
if [[ -n "$FORCE_RUN_DIR" ]]; then
    lock_parent="$(dirname "$FORCE_RUN_DIR")"
    LOCK_DIR="$lock_parent/.openlane-wrapper.lock"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "ERROR: another OpenLane wrapper invocation is active (lock: $LOCK_DIR)" >&2
        echo "       Wait for it to finish, or remove the lock if it is stale." >&2
        exit 1
    fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
fi

if [ ! -f "$SHELL_NIX" ]; then
    echo "ERROR: OpenLane2 shell.nix not found at $SHELL_NIX" >&2
    echo "       Set OPENLANE in env.config to your openlane2 directory." >&2
    exit 1
fi

if ! command -v "$NIX_SHELL_BIN" >/dev/null 2>&1; then
    echo "ERROR: nix-shell not found. Install Nix or set NIX_SHELL to its path." >&2
    exit 1
fi

# Build a properly-quoted command string for --run.
# Prefix with key env vars that nix-shell may not inherit from devshell hooks.
ENV_PREFIX=""
for var in NANGATE_HOME PDK_ROOT; do
    if [ -n "${!var+x}" ]; then
        ENV_PREFIX="$ENV_PREFIX $var=$(printf '%q' "${!var}")"
    fi
done

CMD="env${ENV_PREFIX} python3 -m openlane"
for a in "$@"; do
    CMD="$CMD $(printf '%q' "$a")"
done

exec "$NIX_SHELL_BIN" "$SHELL_NIX" --run "$CMD"
