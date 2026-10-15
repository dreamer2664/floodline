# FLOODLINE: Last District

Co-op flood-rescue extraction game for 1–4 players. Hold back a rising flood, triage a two-cell
power grid across four consumers, escort eight trait-distinct survivors out of a drowning
district, and ride the evacuation lift to the relay-tower pad before the surge.

## Layout

```
agents/riveter/
  releases/          FLOODLINE.rbxlx (XML) + FLOODLINE.rbxl (binary) + source ZIP
  src/shared/        Config, Net, Util          (ModuleScripts in ReplicatedStorage.Shared)
  src/server/        Bootstrap.server.luau      (Script in ServerScriptService)
  src/server/Modules 12 gameplay services       (Folder in ServerScriptService)
  src/client/        Client.client.luau         (LocalScript in StarterPlayerScripts)
  src/client/Modules Hud, Markers, Effects, Results
  tools/             build, inspect, compile-check, logic-check, verification, pipeline script
  tests/headless/    stub Roblox runtime + gameplay simulation + client smoke test
  evidence/          machine-generated reports and the verification write-up
  generated/         build output (the baked World model + the Rojo project)
```

## Build and verify

```bash
bash agents/riveter/tools/build_all.sh
```

That single command regenerates the district, builds the place, and runs every verification stage:
place structure, Luau compilation, static wiring, headless gameplay scenarios, and the client
interface smoke test. Read `evidence/VERIFICATION.md` before quoting any claim about this build —
in particular it states plainly that no Roblox Studio session has been run yet.

## Play

Open `releases/FLOODLINE.rbxlx` in Studio and press Play; see `OPEN_IN_STUDIO.md`.
