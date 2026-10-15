# OPEN IN STUDIO — FLOODLINE: Last District

Version: r01 (initial build). Place: FLOODLINE.rbxlx (XML) or FLOODLINE.rbxl (binary).

## Open
1. Download `FLOODLINE.rbxlx`.
2. Open in Roblox Studio (File > Open).
3. Press Play (F5) or click Play. No Command Bar, plugin, model import, or wiring required.

## Controls
- WASD: move, Space: jump.
- Walk into a power cell (glowing yellow cube) to pick it up.
- Walk to a socket (orange cube in terminal) to insert/remove cell.
- Walk to a survivor and use ProximityPrompt to lead them to the SafeZone (amber floor in terminal).
- Press Start button or START ROUND UI button to begin.
- CALL LIFT button / LiftCall prompt when lift is powered.

## Objective
Power the right systems (pump/bridge/lift) with only 2 cells. Rescue survivors, call the lift, extract before the district floods.

## Solo / Multiplayer
- Solo: auto-starts ~8s after join. Win by extracting with at least half survivors rescued.
- Multiplayer: up to 4 players; same round.

## Known issues (honest)
- Studio runtime physics/network/input NOT verified by builder; only file serialization and Luau compile checked.
- Lift carrying reliability depends on Roblox physics; platform moves by CFrame increments.
- No custom audio; uses no external assets.
