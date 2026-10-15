# FLOODLINE: Last District — verification report

Artifact: `releases/FLOODLINE.rbxlx` — 547,701 bytes, SHA256 `bb01ea529a623871497f19e35af063eaa19c8c9939fcaabb304ff2155d74be55`
Scripts: 48 compiled (4802 server, 1946 client, 583 shared lines)
World: 433 parts, 33 proximity prompts, 2 climbable trusses, 4 lift seats

## 1. What was verified, and how

| Stage | Tool | Result |
|---|---|---|
| Baked geometry export | `tools/build_game.luau` (Lune + Rojo) | 433 parts, 24 scripts embedded in the place |
| Place structure | `tools/inspect_place.luau` | 352 named world objects, 0 required hooks missing |
| Luau compilation | `tools/compile_check.luau` (`luau.compile` on every script, in both the source tree and the shipped place) | 48 checked, 0 failures |
| Static wiring | `tools/logic_check.py` | 12/12 checks |
| Headless gameplay | `tests/headless/sim.luau` (real geometry + real scripts + stub engine + virtual clock) | 18/18 scenarios |
| Client interface | `tests/headless/client_smoke.luau` | 10/10 checks |

Everything above runs with one command: `bash agents/riveter/tools/build_all.sh`.

### 1.1 Headless gameplay scenarios (server logic actually executed)

| Result | Scenario | Measured |
|---|---|---|
| PASS | server boots with a lobbyless, fully wired world | 4 sockets, 8 survivors, 6 objectives, 3 water volumes |
| PASS | solo round auto-starts and scales difficulty | state=Prep quota=3/8 prepCountdown active |
| PASS | power grid enforces capacity and brownout priority | capacity=2 load=2 pump=true lift=true bridge=false |
| PASS | relay fuse repair raises capacity and powers the bridge | capacity=3 bridge=true |
| PASS | flood rises, pump suppresses the rate, surges add water | pumped=0.002/s unpumped=0.008/s surge sector1 2.83->3.33 |
| PASS | escorting a survivor into the safe zone rescues them | rescued=1/8 (quota 3) after escort |
| PASS | lift loads survivors, travels and unloads them at the pad | boarded=2, lift at 70%, passengers left=0, pad rescues +2 (total 4) |
| PASS | live cables shock and the gas leak is fixable | health 100 -> 64, leak fixed=true |
| PASS | round reaches a win when the quota is met and the team extracts | outcome=win grade=A score=1347 rescued=3 elapsed=0:08s |
| PASS | results screen rematch vote returns the server to the lobby | reset clean, second round in Prep |
| PASS | losing every survivor fails the round honestly | outcome=fail reason=every survivor was lost dead=8 |
| PASS | a second round deploys the full survivor crew again | 8/8 survivors restored and visible |
| PASS | scaling tables react to a second player | 2p fraction=0.45, back to 1 player |
| PASS | difficulty modifiers re-scale the round and lock once it starts | storm: rise x1.00, hazards x0.81, prep 90s |
| PASS | closing a door seals the room and slows its flooding | interior depth open=0.12m closed=0.00m (5 doors wired) |
| PASS | team pings validate distance, type and cooldown | 4 ping types, 1 broadcasts, validations enforced |
| PASS | session ledger records rounds, grades and personal bests | rounds=2 wins=1 best=A/1347 rescue=3 history=2 |
| PASS | telemetry wrote an inspectable round log | 2 round log(s), 4355 bytes in the newest |

The harness loads `FLOODLINE.rbxlx`, mirrors the 433-part district and the shipped
module sources into a stub runtime (Instance tree, Vector3/CFrame math, AABB raycasts, DataModel
services, virtual clock) and then plays the game: prompts are fired, remotes are used, the clock is
fast-forwarded through Prep → Rising → Surge → Extraction → Results.

### 1.2 Client interface checks

| Result | Check | Measured |
|---|---|---|
| PASS | client scripts are present in the shipped place | modules=true client=true |
| PASS | HUD builds its full interface tree | 8 panels built |
| PASS | objective + power + roster panels accept live payloads | power rows=5 roster rows=4 |
| PASS | state/water/tick updates drive the banner, gauge and status strip | timer=01:32 gauge=0.36 carry='Carrying: power cell' |
| PASS | notifications stack and expire | notes 1 -> 3, 1 after expiry |
| PASS | world markers bind to survivors and the active objective | markers=3, objective anchor=true |
| PASS | results screen renders a real round summary and votes for a rematch | summary rendered, rematch vote path armed |
| PASS | ping markers render and expire, and the modifier selector reacts | modifier selector, session line and 1 ping marker(s) verified |
| PASS | effects respond to submersion, drowning and downed states | underwater tint, blur and downed grading all applied |
| PASS | client bootstrap runs end to end on live payload shapes | client ticked 3s of live payloads, banner=SURGE |

### 1.3 Static wiring checks

| Result | Check | Measured |
|---|---|---|
| PASS | services reference only existing geometry | 23 named hooks present in the place |
| PASS | every socket maps to a configured consumer | sockets=['Socket_Bridge', 'Socket_Lift', 'Socket_Pump'] consumers=['Bridge', 'Lift', 'Pump', 'Relay'] |
| PASS | all remote usages are declared | 24 remotes used, all declared |
| PASS | bootstrap modules exported | 15 modules required, all present |
| PASS | client modules exported | 4 modules required, all present |
| PASS | shared modules exported | 3 shared modules required, all present |
| PASS | eight survivors with interaction prompts | models=8 survivorPrompts=8 (all prompts=33) |
| PASS | lift cabin has four seats | seats=4 |
| PASS | power cell count matches config | geometry=3 config=3 |
| PASS | no loadstring / http code / external asset ids | {} |
| PASS | numeric client input is constrained | client-sent scalars: [('sprinting', 'boolean')] |
| PASS | audio uses only bundled engine sounds | only rbxasset:// engine sounds |

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
- **Performance is unmeasured.** Part count (433) is modest, but draw calls, lighting cost, and script activity under load have not been profiled.

## 4. Reproduction

```bash
# from the repository root
bash agents/riveter/tools/build_all.sh        # build + all five verification stages
lune run agents/riveter/tools/build_game.luau # build only
```
