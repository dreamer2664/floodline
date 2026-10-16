# FLOODLINE: Last District — verification report

Artifact: `releases/FLOODLINE.rbxlx` — 852,923 bytes, SHA256 `ff8685c8b3161d1ed162fddef2fdab45b99ce1fc0686e603142e3de6020544ba`
Scripts: 56 compiled (6081 server, 2702 client, 717 shared lines)
World: 731 parts, 50 proximity prompts, 3 climbable trusses, 4 lift seats

## 1. What was verified, and how

| Stage | Tool | Result |
|---|---|---|
| Baked geometry export | `tools/build_game.luau` (Lune + Rojo) | 731 parts, 28 scripts embedded in the place |
| Place structure | `tools/inspect_place.luau` | 627 named world objects, 0 required hooks missing |
| Luau compilation | `tools/compile_check.luau` (`luau.compile` on every script, in both the source tree and the shipped place) | 56 checked, 0 failures |
| Static wiring | `tools/logic_check.py` | 17/17 checks |
| Headless gameplay | `tests/headless/sim.luau` (real geometry + real scripts + stub engine + virtual clock) | 38/38 scenarios |
| Client interface | `tests/headless/client_smoke.luau` | 12/12 checks |

Everything above runs with one command: `bash agents/riveter/tools/build_all.sh`.

### 1.1 Headless gameplay scenarios (server logic actually executed)

| Result | Scenario | Measured |
|---|---|---|
| PASS | server boots with a lobbyless, fully wired world | 5 sockets, 12 survivors, 9 objectives, 3 water volumes |
| PASS | solo round auto-starts and scales difficulty | state=Prep quota=5/12 prepCountdown active |
| PASS | power grid enforces capacity and brownout priority | capacity=2 load=2 pump=true lift=true bridge=false |
| PASS | relay fuse repair raises capacity and powers the bridge | capacity=3 bridge=true |
| PASS | flood rises, pump suppresses the rate, surges add water | pumped=0.002/s unpumped=0.008/s surge sector1 2.83->3.33 |
| PASS | escorting a survivor into the safe zone rescues them | rescued=1/12 (quota 5) after escort |
| PASS | lift loads survivors, travels and unloads them at the pad | boarded=2, lift at 70%, passengers left=0, pad rescues +2 (total 4) |
| PASS | live cables shock and the gas leak is fixable | health 100 -> 64, leak fixed=true |
| PASS | round reaches a win when the quota is met and the team extracts | outcome=win grade=S score=1636 rescued=5 elapsed=1:11s |
| PASS | results screen rematch vote returns the server to the lobby | reset clean, second round in Prep |
| PASS | losing every survivor fails the round honestly | outcome=fail reason=every survivor was lost dead=12 |
| PASS | a second round deploys the full survivor crew again | 12/12 survivors restored and visible |
| PASS | scaling tables react to a second player | 2p fraction=0.45, back to 1 player |
| PASS | difficulty modifiers re-scale the round and lock once it starts | storm: rise x1.00, hazards x0.81, prep 90s |
| PASS | closing a door seals the room and slows its flooding | interior depth open=0.12m closed=0.00m (8 doors wired) |
| PASS | team pings validate distance, type and cooldown | 4 ping types, 1 broadcasts, validations enforced |
| PASS | session ledger records rounds, grades and personal bests | rounds=2 wins=1 best=S/1636 rescue=5 history=2 |
| PASS | telemetry wrote an inspectable round log | 2 round log(s), 7300 bytes in the newest |
| PASS | skybridge is baked, retracted at round start and walkable when extended | 4 segments, 8 rail members, tucked at (0.0, 0.0, 0.0) |
| PASS | a powered winch extends the skybridge without any cranking | extended to 1% in 5.5s on 1 cell, routes=Skybridge |
| PASS | hand cranking opens the skybridge with the grid dark | 14 turns accepted, 2 refused, span at 1% with zero power |
| PASS | survivors cross the roof span on route waypoints, not through the air | crossed the span on waypoints: t 0.00 -> 0.46 over 240 ticks |
| PASS | the service cut opens only after the collapse is dug out | cleared in 3 digs, +20 salvage, routes=ServiceCut |
| PASS | sealing the service cut slows its flooding (it floods first when open) | cut depth open=2.02m closed=0.00m |
| PASS | salvage crates pay out once and the bench spends the pool | crate paid 18, pool 20 -> 18, SealKit fitted |
| PASS | the capacitor upgrade lifts a real brownout | capacity 2 -> 3, brownout cleared without touching the sockets |
| PASS | impeller and rebreather upgrades change water and air numbers | air 22s -> 31s, 12s of water: 0.10 dry, 0.03 pumped, 0.01 fitted |
| PASS | the lift servo upgrade speeds travel and adds a passenger slot | 3s of travel: 15% -> 21%, seats 3 -> 4 |
| PASS | the field hospital upgrade halves revive time and restores full health | baseline revive needed 5s, upgraded revive landed in 2.4s at full health |
| PASS | medic and engineer roles change what the team can do | crank 1.00 -> 1.66 per turn, trip cleared by the engineer, medic held the leader at 100, medkits=2 |
| PASS | children refuse to wade and are carried instead | child held position in 1.45m water, then rode the carrier (offset 1.0m) |
| PASS | garage, ferry and the cut expose their content to the simulation | 4 cells, 9 zones, garage roof at 25 studs |
| PASS | objectives cover both routes and the salvage bench | 9 objectives, skybridge flips to done when the span is out |
| PASS | route mastery is scored in the round summary | outcome=win routes=Skybridge+ServiceCut score=1713 salvage=165 |
| PASS | route and upgrade changes only happen through server-owned paths | no client-side setter exists; unaffordable purchases are refused with a reason |
| PASS | a rematch restores world items, doors, routes and the salvage pool | radio/fuse/crate/span/cut/salvage all restored; 1 doors resealed, fuse re-collectable |
| PASS | unclaimed survivors climb to a refuge when the water reaches them | climbed 1.0 -> 9.1 studs (nil), state=Idle |
| PASS | a surge-forced evacuation still schedules the evac vehicle | surge forced the call at t=870s, vehicle landed, pad accepted the crew |

The harness loads `FLOODLINE.rbxlx`, mirrors the 731-part district and the shipped
module sources into a stub runtime (Instance tree, Vector3/CFrame math, AABB raycasts, DataModel
services, virtual clock) and then plays the game: prompts are fired, remotes are used, the clock is
fast-forwarded through Prep → Rising → Surge → Extraction → Results.

## 1.2 Bot playtests (7 timed rounds)

Autonomous bots play complete rounds through the shipped server modules on the virtual clock
(`tests/headless/playtest.luau`): 5 wins, 2 fails,
0 unresolved.

| Crew | Modifier | Outcome | Elapsed | Reason | Rescued/Required | Lost | Salvage | Score | Grade |
|---|---|---|---|---|---|---|---|---|---|
| 1p | Calm | win | 109.8s | team evacuated with the required survivors | 4/3 | 0 | 140 | 1440 | S |
| 1p | Standard | win | 302.8s | team evacuated with the required survivors | 7/5 | 1 | 215 | 1843 | S |
| 1p | Storm | win | 695.3s | team evacuated with the required survivors | 8/6 | 1 | 264 | 1780 | S |
| 2p | Standard | win | 102s | team evacuated with the required survivors | 8/6 | 0 | 240 | 2249 | S |
| 2p | Storm | win | 570.9s | extraction window closed with the quota met | 7/7 | 5 | 129 | 2225 | S |
| 4p | Standard | fail | 643s | the district drowned | 6/7 | 5 | 224 | 2560 | S |
| 4p | Catastrophe | fail | 264.8s | not enough survivors can still be saved | 3/9 | 4 | 133 | 1059 | B |

What this does **not** measure:

- No engine physics: bots teleport in straight lines at the server-set walk speed (0.5x past waist depth).
- No client input latency, no camera, no fumbling a hold, no missed prompts.
- Bots never get stuck on props, never stagger on ramps and never collide with each other.
- Rendering, audio and framerate are not exercised at all.

Result counts in this table are the bots' own; they are a lower bound on a competent human crew
and they are not player telemetry.

### 1.3 Client interface checks

| Result | Check | Measured |
|---|---|---|
| PASS | client scripts are present in the shipped place | modules=true minimap=true systems=true client=true |
| PASS | HUD builds its full interface tree | 8 panels built |
| PASS | objective + power + roster panels accept live payloads | power rows=5 roster rows=4 |
| PASS | state/water/tick updates drive the banner, gauge and status strip | timer=01:32 gauge=0.36 carry='Carrying: power cell' |
| PASS | notifications stack and expire | notes 1 -> 3, 1 after expiry |
| PASS | world markers bind to survivors and the active objective | markers=3, objective anchor=true |
| PASS | minimap builds the district plan and tracks live state | 18 map layers, 5 live dots (cells/sockets/objective/survivors), 2 hidden, span line solid, ping fade + M toggle verified |
| PASS | systems board shows both routes and buys an upgrade through the server | routes Lift/Skybridge/Cut + 6 upgrade rows, purchase of SealKit forwarded to the server, B toggle verified |
| PASS | results screen renders a real round summary and votes for a rematch | summary rendered, rematch vote path armed |
| PASS | ping markers render and expire, and the modifier selector reacts | modifier selector, session line and 1 ping marker(s) verified |
| PASS | effects respond to submersion, drowning and downed states | underwater tint, blur and downed grading all applied |
| PASS | client bootstrap runs end to end on live payload shapes | client ticked 3s of live payloads: banner=SURGE, map built, route board=Skybridge — walkable (roof route) |

### 1.4 Static wiring checks

| Result | Check | Measured |
|---|---|---|
| PASS | services reference only existing geometry | 23 named hooks present in the place |
| PASS | every socket maps to a configured consumer | sockets=['Socket_Bridge', 'Socket_Lift', 'Socket_Pump', 'Socket_Winch'] consumers=['Bridge', 'Lift', 'Pump', 'Relay', 'Winch'] |
| PASS | all remote usages are declared | 27 remotes used, all declared |
| PASS | bootstrap modules exported | 17 modules required, all present |
| PASS | client modules exported | 6 modules required, all present |
| PASS | shared modules exported | 3 shared modules required, all present |
| PASS | survivor rigs and prompts match Config.Survivors.Total | models=12 survivorPrompts=12 config=12 (all prompts=50) |
| PASS | lift cabin has four seats | seats=4 |
| PASS | power cell count matches config | geometry=4 config=4 |
| PASS | no loadstring / http code / external asset ids | {} |
| PASS | numeric client input is constrained | client-sent scalars: [('sprinting', 'boolean')] |
| PASS | audio uses only bundled engine sounds | only rbxasset:// engine sounds |
| PASS | skybridge span is baked in the place | decks=['BridgeDeck_A', 'BridgeDeck_B', 'BridgeDeck_C', 'BridgeDeck_D'] rails=8 cranks=['BridgeCrank_Far', 'BridgeCrank_Near'] nearest deck to NearJoint=4.07 studs |
| PASS | second-route geometry is present | missing=[] crates=['SupplyCrate_1', 'SupplyCrate_2', 'SupplyCrate_3', 'SupplyCrate_4'] |
| PASS | new landmarks registered as world zones | zones=['ApartmentBlock', 'Clinic', 'FerryTerminal', 'Mid', 'North', 'ParkingGarage', 'PumpHouse', 'RelayTower', 'ServiceCut', 'South', 'Terminal', 'Workshop'] |
| PASS | upgrade catalog is complete and consumed | order=['Impeller', 'Rebreather', 'Capacitor', 'SealKit', 'FieldHospital', 'LiftServo'] unreadEffects=[] |
| PASS | survivor role effects are implemented | roles=['Child', 'Engineer', 'Medic'] missing=[] |

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
- **Balance is measured with bots, not players.** The round timings in §1.2 come from scripted bots walking straight lines at the server-set speed; they bound pacing from below and say nothing about difficulty for a real crew, let alone for a crew of four people talking to each other.
- **Art and audio are procedural primitives.** No external asset IDs are used anywhere, but that also means no custom meshes, textures or sound design.
- **Performance is unmeasured.** Part count (731) is modest, but draw calls, lighting cost, and script activity under load have not been profiled.

## 4. Reproduction

```bash
# from the repository root
bash agents/riveter/tools/build_all.sh        # build + all five verification stages
lune run agents/riveter/tools/build_game.luau # build only
```
