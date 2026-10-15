# Riveter operations

Read the complete root RIVETER.md. All source/game/build/tests belong in `agents/riveter/`; root ops are self-contained commissioning conveniences, not a dependency on another agent.

## Actual toolchain

`export PATH="$(python3 ops/bootstrap_tools.py):$PATH"` restores pinned official Linuxx86_64 Rojo/Lune/Luau binaries into excluded cache, checking recorded archive/binary hashes. No root, paid service, Studio plugin or Roblox login. Other systems should use the official OS builds. `ops/toolchain-lock.json` records exact versions/source URLs/checksums. Cache can disappear on restore: reinstall.

The commissioner's **non-game fixture** used Lune `serializeModel(...,true)` for baked geometry, Rojo `build` for actual XML place export, Lune `deserializePlace` on the exported bytes and assertions on anchored geometry/spawn/embedded Script.Source. `tests/toolchain_smoke.luau` writes to a disposable `FLOODLINE_PROBE_DIR`; do not mistake it for the requested game. Actual receipt: `evidence/TOOLCHAIN_PROOF.json`.

Lune file manipulation is not Roblox physics/runtime. A compiler is not a Studio playtest. Use appropriate source/type tests and actual-export assertions; mark engine tests NOT RUN if Studio is genuinely absent. Do not use Lune auth-cookie helpers, scrape credentials, request paid tools or revive Mars/Windows/PC access. Local export needs none of those.

## Journal / five-minute observed heartbeat

From repo root:

```
python3 ops/field.py event riveter --kind action --stage implementation --action '<real action>' --result '<real result/discovery/failure/fix>' --artifact '<evidence path>' --next '<exact next step>'
python3 ops/field.py publish riveter
python3 ops/field.py run riveter --stage build --push -- python3 tools/build.py
```

The wrapper executes from agents/riveter/, records actual child start/end/exit/output, observes only a genuinely live child every300s and strips known crew auth variables from the child. Partial lines cannot block the timer, rapid commands have distinct raw logs, interruptions terminate the child and failures do not become “delivered.” No detached fake pulse/percentage or claim of continued AI thought after a session stops. Manual code/design/research needs real journal entries and <=5min publication too.

`events.jsonl` is append-only and generates ONE exhaustive HANDOFF.md plus status/riveter.json. Do not hand-edit generated sections; record through `event`. Concise decision reasons/results, not private hidden chain-of-thought. Preserve all failed attempts and working fixes, URLs/versions/hashes/commands, actually inspected images and exact resume instructions. Archive this MD at delivery or an unfinished stop.

`publish` stages only your own tree/status, rejects foreign staged content/known keys, commits/rebases/pushes without force and records the source SHA in storagecode/PUSHES.md. Source-push success followed by ledger failure is reported as partial sync. Preserve state and retry, don't claim both succeeded. Actual board lease heartbeat <=30min during real activity; board writes use the API, reads prefer fresh clones. A prepared card/log is not a registration.

## Actual artifacts → sole primary archive

After the complete build and its real validation exist:

```
python3 ops/release.py riveter --place agents/riveter/releases/FLOODLINE.rbxlx --title 'FLOODLINE: Last District' --revision r03 --asset agents/riveter/releases/FLOODLINE-source.zip --asset agents/riveter/evidence/VALIDATION.json
```

Only your own physical tree and selected allowed game/evidence formats; no foreign/symlink/private files. Known credentials are refused in selected bytes and individually decompressed source-ZIP entries; unsafe/private archive paths are refused. No whole-workspace ZIP. Never upload the private stamped RIVETER.md, its private ZIP or envs. The public template may be included in clean source but never its stamped counterpart.

Uploads stream to **storagecode only**, immutable `floodline/riveter/rNN-<place-hash12>` tags, actual URLs/bytes/SHA receipts and remote digest where available; different existing assets cannot be overwritten. Root artifact is an actual .rbxlx/.rbxl, not source renamed as a place. The uploader is a distribution helper, not a game-validity or Studio-runtime certificate. Capture and review actual VALIDATION evidence; don't claim unsupported engine tests. Inspect/download/hash final remote artifacts when feasible.

Small text evidence/handoff can be separately archived:

```
python3 ops/archive.py riveter --run r03-HASH12-closeout --file agents/riveter/HANDOFF.md --file agents/riveter/evidence/VALIDATION.json --file agents/riveter/evidence/visual-review.md
```

Use the actual hash/run identifier. Archive writes/indexes small own documents under `data/floodline/riveter/`, refuses private/known-secret content and immutable path collisions. Large place/source/visual/video artifacts belong in Releases. Append-only INDEX/PUSHES; do not replace other agents' lines. Normal final card state is review pending actual room quorum; no invented ballots and no dependency on external reviewers to make/publish the game.

Game source stays in floodline; durable data/places/evidence on primary storagecode. Formalcode uses the existing reusable record workflow; no competing empire-state publisher. Retired storage is read-only. Mars stays paused. Red lines remain. Complete game, truthful evidence, no assembly required.
