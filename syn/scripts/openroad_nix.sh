#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# openroad_nix.sh — Run OpenROAD inside nix-shell for full dependency
# isolation (same Nix environment used by OpenLane2).
#
# Usage:
#   openroad_nix.sh [openroad-args...]
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

if [ ! -f "$SHELL_NIX" ]; then
    echo "ERROR: shell.nix not found at $SHELL_NIX" >&2
    echo "       Set OPENLANE in env.config to the openlane2 source tree." >&2
    exit 1
fi

# Safely quote all arguments for passing through nix-shell --run
args=""
for arg in "$@"; do
    args="$args $(printf '%q' "$arg")"
done

exec "$NIX_SHELL_BIN" "$SHELL_NIX" --run "openroad$args"
