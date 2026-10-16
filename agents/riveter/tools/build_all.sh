#!/usr/bin/env bash
# FLOODLINE: one command, full pipeline.
#
#   build -> structure -> compile -> static wiring -> headless gameplay -> client smoke -> evidence
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

step "1/7 generate baked district + build place"
lune run agents/riveter/tools/build_game.luau

step "2/7 inspect the exported place (structure + geometry hooks)"
lune run agents/riveter/tools/inspect_place.luau | tail -30

step "3/7 compile every script (source tree and shipped place)"
lune run agents/riveter/tools/compile_check.luau | tail -5

step "4/7 static cross-reference checks (script <-> geometry <-> remotes)"
python3 agents/riveter/tools/logic_check.py

step "5/7 headless gameplay simulation of the shipped place"
lune run agents/riveter/tests/headless/sim.luau | tail -35

step "6/7 client interface smoke test"
lune run agents/riveter/tests/headless/client_smoke.luau | tail -25

# Rebuilt from the reports above, so evidence/VERIFICATION.md and the release asset
# evidence/VALIDATION.json always describe the build that was just measured.
step "7/7 verification report + machine-readable validation"
python3 agents/riveter/tools/make_verification.py

step "evidence"
ls -la "$AGENT/evidence"
printf '\npipeline OK\n'
