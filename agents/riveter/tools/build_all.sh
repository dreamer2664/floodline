#!/usr/bin/env bash
# FLOODLINE: one command, full pipeline.
#
#   build -> structure -> compile -> static wiring -> headless gameplay -> client smoke
#
# Any stage that fails stops the run with a non-zero exit code (set -e).
# Usage:  bash agents/riveter/tools/build_all.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AGENT="$ROOT/agents/riveter"
TOOLS="${FLOODLINE_TOOLS:-/home/user/.cache/floodline-tools/bin}"
export PATH="$TOOLS:$PATH"

cd "$ROOT"

echo "=============================================================="
echo " FLOODLINE build + verification pipeline"
echo " repo:   $ROOT"
echo " tools:  $TOOLS"
echo "=============================================================="

step() { printf '\n--- %s ---\n' "$1"; }

step "1/6 generate baked district + build place"
lune run agents/riveter/tools/build_game.luau

step "2/6 inspect the exported place (structure + geometry hooks)"
lune run agents/riveter/tools/inspect_place.luau | tail -30

step "3/6 compile every script (source tree and shipped place)"
lune run agents/riveter/tools/compile_check.luau | tail -5

step "4/6 static cross-reference checks (script <-> geometry <-> remotes)"
python3 agents/riveter/tools/logic_check.py

step "5/6 headless gameplay simulation of the shipped place"
lune run agents/riveter/tests/headless/sim.luau | tail -35

step "6/6 client interface smoke test"
lune run agents/riveter/tests/headless/client_smoke.luau | tail -25

step "evidence"
ls -la "$AGENT/evidence"
printf '\npipeline OK\n'
