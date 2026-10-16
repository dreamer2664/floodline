# OPEN IN STUDIO — FLOODLINE: Last District

Revision: r07 (see `src/shared/Config.luau` `Config.Game.Version` for the exact string the place
reports at runtime). Place: `releases/FLOODLINE.rbxlx` (XML) or `FLOODLINE.rbxl` (binary).

## Open
1. Download `releases/FLOODLINE.rbxlx`.
2. Open in Roblox Studio (File > Open).
3. Press Play (F5). No Command Bar, plugin, model import or wiring required — the district is baked
   into the place in edit mode, and the scripts are already inside it.

## Controls
- WASD move, Space jump, Left Shift sprint.
- E: use the nearest prompt / insert or remove a power cell.
- F: lead (or set down) the nearest survivor · G: call the evac lift.
- Q: let go of whatever you are holding (casualty → cell → survivor).
- V: spend your crew ability (Second Wind / Socket Jumper / Triage / Rope Line).
- N: cycle your crew role in the lobby (roles lock when the round starts).
- 1–4: ping a point for the team (danger / survivor / power / regroup).
- M: minimap · B: systems panel (crew board, routes, upgrades, outfall gauge).
- Walk up to a downed teammate and hold the **Drag to safety** prompt to haul them clear.

## The round
1. Prep — pick a role, loot crates, plan the two-cell grid.
2. Rising → Surge phases — the water climbs, surges hit a random sector, cables arc and debris falls.
3. Power the pump (water), the lift (extraction), the winch (skybridge) and the relay (capacity +1)
   from four cells, or open the outfall sluice by hand when the grid is dark.
4. Rescue the quota of survivors (children must be carried, the deaf must be touched).
5. Call the lift, ride the pad, extract before the window closes.

## Solo / multiplayer
- Solo: the round auto-starts, the water rises 18% slower, the quota is 35% of the survivors, and
  going down starts a self-recovery timer instead of waiting for a teammate.
- 2–4 players: quota and surge timings scale up; two people can split the grid and the rescues, and
  a downed player can be dragged instead of abandoned.

## Verification status (honest)
- Verified: place structure, 60/60 scripts compiled (source tree and the shipped place), 25/25
  static cross-reference checks, 45/45 headless gameplay scenarios, 14/14 client interface checks
  and 7 bot playtests — all reproduced by `bash agents/riveter/tools/build_all.sh`. Exact counts and
  the last measured build are in `evidence/VALIDATION.json` and `evidence/VERIFICATION.md`.
- NOT verified: no Roblox Studio session has been run by the builder. Engine physics, networking,
  input handling, rendering, audio and real-player latency are untested. The bot playtests are a
  lower bound played by straight-line bots on a virtual clock.
- No external asset IDs, no HTTP-loaded code, no loadstring.
