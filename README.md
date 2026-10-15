# FLOODLINE: Last District

**A full original Roblox game, commissioned to the new independent agent Riveter.**

1–4-player co-op rescue/extraction in a flooding industrial district. Carry scarce power cells, reroute electricity between drainage/bridges/the evacuation lift, lead survivors across disappearing routes and extract before the district is lost. Fair solo play, useful cooperation, a complete round→results→rematch loop.

## Start here

- **[RIVETER.md](RIVETER.md)** — complete standalone charter (~4,800words), all creative/technical decisions delegated. The public file has credential placeholders only; Director privately supplies the stamped file.
- **[Own action/discovery/failure/fix/handoff log](agents/riveter/HANDOFF.md)** — the central working memory; initial entry is explicitly commissioner's setup, not fabricated producer activity.
- **[Actual observed status](status/riveter.json)** · [Progress page](https://dreamer2664.github.io/floodline/)
- **[Goal card t-20261015-ffaa](https://github.com/dreamer2664/chatcode/blob/main/board/tasks/t-20261015-ffaa.json)** — reserved for Riveter on actual first wake, not claimed on its behalf.

## What “the game” means

Deliver an actual **FLOODLINE.rbxlx**, optionally .rbxl too, directly openable in Studio. The district is **already baked and visible in EDIT mode**: at least six distinct explorable landmark buildings/interiors, cohesive original prop kit, streets/roofs/bridges/cables, complete UI, server/client code and templates. Carlo downloads, opens and presses Play—no Command Bar paste, plugin, manual model import or assembly.

Core systems: limited power graph, flood/route phases, safe transactional item carrying, route-aware survivor rescue, reliable passenger-carrying evacuation lift, secured server-authoritative co-op, solo scaling, join/leave/death/recovery, clean multi-round reset and touch-friendly interface. No placeholder endgame or “coming soon” core features.

One polished complete district before feature creep. Original assets/builders, no unlicensed Toolbox dependencies or arbitrary uploaded-code loaders. All gameplay in Luau; supporting build tools may use appropriate languages. No paid tool or Roblox credential dependency for local export.

## Concrete tools and honest evidence

```
export PATH="$(python3 ops/bootstrap_tools.py):$PATH"
python3 -m unittest discover -s tests -v
# Riveter implements the whole game/build under its own source tree:
python3 agents/riveter/tools/build.py
```

Pinned official tools: Rojo7.7.1, Lune0.11.0, Luau0.742. Local installer requires no root/Studio/login; source and binary hashes in [toolchain lock](ops/toolchain-lock.json). The commissioner actually tested Lune model serialisation→Rojo `.rbxlx` export→Lune exact-file parse, with baked floor, SpawnLocation and embedded server Luau. [Receipt](evidence/TOOLCHAIN_PROOF.json).

**That disposable fixture is NOT the game and NOT a Studio playtest.** No game has been built by the commissioner. No Riveter session was registered/activated on its behalf. Only real future work updates its state. Studio engine-dependent physics/network/input tests cannot be certified by a serializer or mock; report PASS/FAIL/NOT RUN accurately. If Studio is unavailable, continue building/exporting and state the exact runtime-validation gap—never invent a test session or screenshot.

## Work and publication

Source is isolated in `agents/riveter/`, with independent renderer/build/test/assets and mandatory <=5min evidence-bearing observed progress. The exhaustive HANDOFF preserves every meaningful action, discovery, failed attempt, working fix, inspected export and exact continuation. No fake heartbeat timer or claim of AI thought after a session stops. At least two material visual/gameplay revisions on actual exports precede final delivery.

[Operations](ops/README.md). Durable place files, clean full-source ZIP, validation, actual-export visuals, rights/build manifests and handoff copies go to **dreamer2664/storagecode**, sole primary archive: `floodline/riveter/rNN-<hash12>` Releases and `data/floodline/riveter/...`. Automatic formalcode record; append primary INDEX/PUSHES without dropping others' work. Retired storage is read-only.

No dependency on the three video agents, old V01–V04, OCR onboarding, paid tools or the paused Mars/Windows/PC bridge. All standing secret/access/red-line rules remain. A brief, toolchain fixture, generated source or green mock suite is not a completed game.
