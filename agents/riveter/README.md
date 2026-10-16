# FLOODLINE: Last District

Co-op flood-rescue extraction game for 1–4 players. Hold back a rising flood, triage a power grid
across five consumers, escort twelve trait-distinct survivors out of a drowning district, and ride
the evacuation lift to the relay-tower pad before the surge.

Four things decide whether the district survives the round:

- **The grid.** Four cells, five sockets, capacity 2 until the relay fuse is fitted. A brownout
  drops consumers in priority order (pump → lift → winch → bridge → relay), and flood water trips
  breakers that have to be reset by hand — three holds on a socket that is not under water.
- **Water control.** The pump is the powered answer; the outfall is the unpowered one. Eleven holds
  on the sluice wheel drains every sector and drops the gate, and the water keeps you honest by
  swinging it shut again about twenty seconds after you stop cranking.
- **The crew.** Everyone picks a role in the lobby and keeps it for the round: Diver (air and swim
  speed), Engineer (crank and breaker speed, flood trips cleared on their rescue), Medic (faster
  revives and a healing aura) and Rigger (carries cells at full speed, owns the withered rigging).
  V spends the role ability, N cycles the role in the lobby.
- **The survivors.** Twelve of them, with traits that change how you move them — children refuse to
  wade and must be carried, the deaf must be touched, the injured slow you down. Get a survivor down
  and they bleed out on a clock; nine of them in the water and the round is losing itself.

## Layout

```
agents/riveter/
  releases/          FLOODLINE.rbxlx (XML) + FLOODLINE.rbxl (binary) + source ZIP
  src/shared/        Config, Net, Util          (ModuleScripts in ReplicatedStorage.Shared)
  src/server/        Bootstrap.server.luau      (Script in ServerScriptService)
  src/server/Modules 15 gameplay services       (Folder in ServerScriptService)
  src/client/        Client.client.luau         (LocalScript in StarterPlayerScripts)
  src/client/Modules Hud, Markers, Effects, Results, Systems, Minimap
  tools/             build, inspect, compile-check, logic-check, verification, pipeline script
  tests/headless/    stub Roblox runtime + gameplay simulation + client smoke test
  evidence/          machine-generated reports and the verification write-up
  generated/         build output (the baked World model + the Rojo project)
```

## Build and verify

```bash
bash agents/riveter/tools/build_all.sh
```

That single command (8 stages) regenerates the district, builds the place, runs every verification
stage — place structure, Luau compilation, static wiring, 44 headless gameplay scenarios, 13 client
interface checks — then writes the verification report, the machine-readable validation gate and the
source archive. Read `evidence/VERIFICATION.md` before quoting any claim about this build: in
particular it states plainly that no Roblox Studio session has been run, and the bot playtests in
`evidence/playtest-report.json` are a lower bound played by straight-line bots on a virtual clock,
not a substitute for four humans in Studio.

## Play

Open `releases/FLOODLINE.rbxlx` in Studio and press Play; see `OPEN_IN_STUDIO.md`.
