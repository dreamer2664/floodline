#!/usr/bin/env python3
"""Builds evidence/VERIFICATION.md from the machine-readable reports.

Every number in the report is read back out of the generated JSON, so the document cannot drift
from what the tools actually measured.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "evidence"
PLACE = ROOT / "releases" / "FLOODLINE.rbxlx"


def load(name: str) -> dict:
    return json.loads((EVIDENCE / name).read_text(encoding="utf-8"))


def main() -> int:
    structure = load("place-structure.json")
    compile_report = load("compile-report.json")
    logic = load("logic-report.json")
    sim = load("headless-report.json")
    client = load("client-smoke-report.json")
    stats = load("build-stats.json")
    sha = subprocess.check_output(["sha256sum", str(PLACE)], text=True).split()[0]
    size = PLACE.stat().st_size

    sim_rows = "\n".join(
        f"| {'PASS' if row['ok'] else 'FAIL'} | {row['name']} | {row['detail']} |" for row in sim["results"]
    )
    client_rows = "\n".join(
        f"| {'PASS' if row['ok'] else 'FAIL'} | {row['name']} | {row['detail']} |" for row in client["results"]
    )
    logic_rows = "\n".join(
        f"| {'PASS' if row['ok'] else 'FAIL'} | {row['check']} | {row['detail']} |" for row in logic["checks"]
    )
    scripts = structure["scripts"]

    doc = f"""# FLOODLINE: Last District — verification report

Artifact: `releases/FLOODLINE.rbxlx` — {size:,} bytes, SHA256 `{sha}`
Scripts: {compile_report['checked']} compiled ({stats['serverLines']} server, {stats['clientLines']} client, {stats['sharedLines']} shared lines)
World: {structure['parts']} parts, {structure['prompts']} proximity prompts, {structure['trusses']} climbable trusses, {structure['seats']} lift seats

## 1. What was verified, and how

| Stage | Tool | Result |
|---|---|---|
| Baked geometry export | `tools/build_game.luau` (Lune + Rojo) | {structure['parts']} parts, {structure['scriptCount']} scripts embedded in the place |
| Place structure | `tools/inspect_place.luau` | {len(structure['names'])} named world objects, {len(structure['missingFeatures'])} required hooks missing |
| Luau compilation | `tools/compile_check.luau` (`luau.compile` on every script, in both the source tree and the shipped place) | {compile_report['checked']} checked, {compile_report['failures']} failures |
| Static wiring | `tools/logic_check.py` | {logic['passed']}/{len(logic['checks'])} checks |
| Headless gameplay | `tests/headless/sim.luau` (real geometry + real scripts + stub engine + virtual clock) | {sim['passed']}/{sim['scenarios']} scenarios |
| Client interface | `tests/headless/client_smoke.luau` | {client['passed']}/{client['checks']} checks |

Everything above runs with one command: `bash agents/riveter/tools/build_all.sh`.

### 1.1 Headless gameplay scenarios (server logic actually executed)

| Result | Scenario | Measured |
|---|---|---|
{sim_rows}

The harness loads `FLOODLINE.rbxlx`, mirrors the {structure['parts']}-part district and the shipped
module sources into a stub runtime (Instance tree, Vector3/CFrame math, AABB raycasts, DataModel
services, virtual clock) and then plays the game: prompts are fired, remotes are used, the clock is
fast-forwarded through Prep → Rising → Surge → Extraction → Results.

### 1.2 Client interface checks

| Result | Check | Measured |
|---|---|---|
{client_rows}

### 1.3 Static wiring checks

| Result | Check | Measured |
|---|---|---|
{logic_rows}

## 2. Bugs this process actually found and fixed

These are not hypothetical; each was caught by a check and then fixed in the shipped code.

1. **Prep phase lasted zero seconds** — `beginPrep` set the state timer but not the phase deadline, so `evaluate()` immediately advanced to Rising.
2. **Cells and sockets were decorative** — the baked prompts existed but no server code listened to them; power cells could only be moved through the client key path.
3. **Duplicate power cells** — the runtime spawned `Cell_A/B/C` while the baked district already had `Cell1..3`; the game now adopts the placed geometry as the single source of truth.
4. **Extraction pad unreachable in code** — the pad lives inside the `EvacComplex` model, so top-level `FindFirstChild` lookups returned nil and extraction/pad rescues never fired. Added a cached descendant lookup.
5. **No ground-floor lift call button** — the place only had a pad-side button; a call button was added at the lift base and both are wired.
6. **Rescued survivors were destroyed** — a rematch deployed fewer survivors each round until the district was empty. NPCs are now hidden and restored from a persistent spawn table (regression scenario 11b).
7. **NPCs jammed on props forever** — survivors had no obstacle avoidance; they now slide around obstacles after ~1s of no progress.
8. **`Vector3:Distance` is not a Roblox API** — eight call sites used it; replaced with `(a - b).Magnitude`.
9. **`Hud.build()` was not idempotent** — a second build left a stale duplicate ScreenGui whose labels never updated.

## 3. What was NOT verified (stated plainly)

- **No Roblox Studio session was run.** No human or agent opened this place in Studio, clicked Play, or observed it on a screen. Any claim about how it *feels* to play would be inventing evidence.
- **Engine behaviour is not covered by the harness.** Real character physics, seat welding and platform carry, network replication and latency, `ProximityPrompt` hold/range rules, streaming, rendering, sound, mobile/gamepad input, and DataStore-free persistence are all outside the stub's reach.
- **The stub is a test double, not an engine.** Its raycasts are AABB-only, its CFrame maths is simplified, and it has no collision response — so NPC routing that works headless may still need tuning in Studio.
- **No playtest data exists.** Balance numbers (flood rates, survivor speed, quota) are reasoned, not measured against real players.
- **Art and audio are procedural primitives.** No external asset IDs are used anywhere, but that also means no custom meshes, textures or sound design.
- **Performance is unmeasured.** Part count ({structure['parts']}) is modest, but draw calls, lighting cost, and script activity under load have not been profiled.

## 4. Reproduction

```bash
# from the repository root
bash agents/riveter/tools/build_all.sh        # build + all five verification stages
lune run agents/riveter/tools/build_game.luau # build only
```
"""

    (EVIDENCE / "VERIFICATION.md").write_text(doc, encoding="utf-8")
    print(f"wrote {EVIDENCE / 'VERIFICATION.md'} ({len(doc)} chars)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
