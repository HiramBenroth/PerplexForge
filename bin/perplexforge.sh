#!/bin/bash
# Standalone PerplexForge launcher (macOS / Linux).
#   bin/perplexforge.sh path/to/board.kicad_pcb
# Set PERPLEXFORGE_JULIA to use a julia that isn't on PATH.

PF_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PF_JULIA="${PERPLEXFORGE_JULIA:-$(command -v julia || echo "$HOME/.juliaup/bin/julia")}"

if [ -z "${1:-}" ]; then
    echo "Usage: perplexforge.sh path/to/board.kicad_pcb"
    exit 1
fi
BOARD="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"

exec "$PF_JULIA" --project="$PF_HOME" "$PF_HOME/bin/launch.jl" "$BOARD"
