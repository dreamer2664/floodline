#!/usr/bin/env python3
"""Static cross-reference check between the Luau source and the exported place.

Catches the failure mode that a compile check cannot: a script that is syntactically valid but
references a part, module, remote or geometry name that does not exist in FLOODLINE.rbxlx.

Writes evidence/logic-report.json and exits non-zero when a check fails.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
EVIDENCE = ROOT / "evidence"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def main() -> int:
    structure = json.loads(read(EVIDENCE / "place-structure.json"))
    names: dict[str, int] = structure["names"]
    prompt_parents: dict[str, int] = structure["promptParents"]

    server_files = sorted((SRC / "server").rglob("*.luau"))
    client_files = sorted((SRC / "client").rglob("*.luau"))
    shared_files = sorted((SRC / "shared").rglob("*.luau"))
    server_src = "\n".join(read(f) for f in server_files)
    client_src = "\n".join(read(f) for f in client_files)
    shared_src = "\n".join(read(f) for f in shared_files)
    all_src = server_src + client_src + shared_src

    checks: list[dict] = []

    def check(name: str, ok: bool, detail: str) -> None:
        checks.append({"check": name, "ok": bool(ok), "detail": detail})

    # ---- 1. geometry the server names explicitly must exist in the place ----
    required_geometry = [
        "Terminal", "PumpHouse", "ApartmentBlock", "Workshop", "Clinic", "RelayTower",
        "SafeZone", "SpawnLocation", "EvacLift", "ExtractionPad", "Cells", "Survivors",
        "Socket_Pump", "Socket_Bridge", "Socket_Lift", "Charger", "Valve", "RelaySlot",
        "Radio", "EvacConsole", "LiftCallTop", "RelayFuse", "BridgeGate",
    ]
    missing = [name for name in required_geometry if name not in names]
    check("services reference only existing geometry", not missing,
          "missing: " + ", ".join(missing) if missing else f"{len(required_geometry)} named hooks present in the place")

    # ---- 2. every Socket_* in the place has a matching consumer in Config ----
    consumers = set(re.findall(r"^\s{2}(\w+) = \{\n\s+Label = [^\n]+\n\s+Load = ", read(SRC / "shared" / "Config.luau"), re.M))
    sockets = sorted(k for k in names if k.startswith("Socket_"))
    socket_consumers = {k.split("_", 1)[1] for k in sockets}
    check("every socket maps to a configured consumer", socket_consumers <= consumers,
          f"sockets={sockets} consumers={sorted(consumers)}")

    # ---- 3. client/server remote names must exist in Net.Remotes ----
    declared = set(re.findall(r"^\t(\w+) = \"Remote(?:Event|Function)\",", read(SRC / "shared" / "Net.luau"), re.M))
    used = set(re.findall(r"remotes\.(\w+)", server_src)) | set(re.findall(r"remotes\.(\w+)", client_src))
    unknown = sorted(used - declared)
    check("all remote usages are declared", not unknown,
          f"unknown={unknown}" if unknown else f"{len(used)} remotes used, all declared")

    # ---- 4. every module the bootstrap requires exists in the exported place ----
    boot = read(SRC / "server" / "Bootstrap.server.luau")
    boot_modules = set(re.findall(r'Modules:WaitForChild\("(\w+)"\)', boot))
    place_modules = {p.split(".")[-1] for p in structure_scripts_paths(structure) if "ServerScriptService.Modules." in p}
    missing_modules = sorted(boot_modules - place_modules)
    check("bootstrap modules exported", not missing_modules,
          f"missing={missing_modules}" if missing_modules else f"{len(boot_modules)} modules required, all present")

    # ---- 5. client modules exist ----
    client_boot = read(SRC / "client" / "Client.client.luau")
    client_modules = set(re.findall(r'ClientModules:WaitForChild\("(\w+)"\)', client_boot))
    place_client_modules = {p.split(".")[-1] for p in structure_scripts_paths(structure)
                            if "StarterPlayerScripts.Modules." in p}
    missing_client = sorted(client_modules - place_client_modules)
    check("client modules exported", not missing_client,
          f"missing={missing_client}" if missing_client else f"{len(client_modules)} modules required, all present")

    # ---- 6. shared modules exist for both realms ----
    shared_required = set(re.findall(r'Shared:WaitForChild\("(\w+)"\)', all_src))
    shared_present = {p.split(".")[-1] for p in structure_scripts_paths(structure)
                      if "ReplicatedStorage.Shared." in p}
    missing_shared = sorted(shared_required - shared_present)
    check("shared modules exported", not missing_shared,
          f"missing={missing_shared}" if missing_shared else f"{len(shared_required)} shared modules required, all present")

    # ---- 7. survivors have a prompt + humanoid, one per configured survivor ----
    survivor_models = [k for k in names if re.fullmatch(r"Survivor\d+", k)]
    survivor_prompts = prompt_parents.get("Part:HumanoidRootPart", 0)
    survivor_total = int(re.search(r"Config\.Survivors = \{\n\tTotal = (\d+)", read(SRC / "shared" / "Config.luau")).group(1))
    check("survivor rigs and prompts match Config.Survivors.Total",
          len(survivor_models) == survivor_total and survivor_prompts == survivor_total,
          f"models={len(survivor_models)} survivorPrompts={survivor_prompts} config={survivor_total} (all prompts={structure['prompts']})")

    # ---- 8. lift cabin has 4 seats and a platform ----
    seats = len([k for k in names if k.startswith("LiftSeat")])
    check("lift cabin has four seats", seats == 4 and "EvacLift" in names, f"seats={seats}")

    # ---- 9. power cells match Config.Power.CellCount ----
    cells = len([k for k in names if re.fullmatch(r"Cell\d+", k)])
    cell_count = int(re.search(r"CellCount = (\d+)", read(SRC / "shared" / "Config.luau")).group(1))
    check("power cell count matches config", cells == cell_count, f"geometry={cells} config={cell_count}")

    # ---- 10. no forbidden constructs anywhere in the source ----
    banned = {
        "loadstring": r"\bloadstring\s*\(",
        "HttpGet": r"HttpService:GetAsync|:HttpGet\(",
        "require(assetId)": r"require\(\s*\d{4,}",
        "external asset id": r"rbxassetid://\d+",
        "marketplace asset": r"MarketplaceService",
    }
    found_banned = {label: len(re.findall(pattern, all_src)) for label, pattern in banned.items()
                    if re.search(pattern, all_src)}
    check("no loadstring / http code / external asset ids", not found_banned, json.dumps(found_banned))

    # ---- 11. server must not trust client-owned state for scoring/round decisions ----
    trusted = re.findall(r"OnServerEvent:Connect\(function\(player: Player, (\w+): (number|boolean)\)", server_src)
    check("numeric client input is constrained", all(name not in ("score", "damage", "health") for name, _ in trusted),
          f"client-sent scalars: {trusted}")

    # ---- 12. sound usage limited to engine-internal rbxasset:// paths ----
    external_sounds = re.findall(r'"rbxassetid://[^"]+"', all_src)
    check("audio uses only bundled engine sounds", not external_sounds,
          f"external={external_sounds}" if external_sounds else "only rbxasset:// engine sounds")

    # ---- 13. skybridge span geometry: decks, rails, cranks, and matching joints ----
    decks = sorted(k for k in names if re.fullmatch(r"BridgeDeck_[A-D]", k))
    rails = [k for k in names if k.startswith("BridgeRail_")]
    cranks = [k for k in names if k.startswith("BridgeCrank_") and not k.startswith("BridgeCrankBase")]
    config_text = read(SRC / "shared" / "Config.luau")
    joint = re.search(r"NearJoint = Vector3\.new\(([-\d.]+), ([-\d.]+), ([-\d.]+)\)", config_text)
    deck_positions = [structure["partPositions"][k] for k in decks] if "partPositions" in structure else []
    joints_ok = True
    detail = f"decks={decks} rails={len(rails)} cranks={cranks}"
    if joint and deck_positions:
        near = tuple(float(joint.group(i)) for i in (1, 2, 3))
        closest = min(deck_positions, key=lambda p: (p[0] - near[0]) ** 2 + (p[1] - near[1]) ** 2 + (p[2] - near[2]) ** 2)
        distance = sum((closest[i] - near[i]) ** 2 for i in range(3)) ** 0.5
        joints_ok = distance < 6.5
        detail += f" nearest deck to NearJoint={round(distance, 2)} studs"
    check("skybridge span is baked in the place",
          len(decks) == 4 and len(rails) >= 8 and len(cranks) == 2 and joints_ok, detail)

    # ---- 14. second-route content: cut, barricade, bench, crates ----
    route_parts = ["TunnelBarricade", "UpgradeBench", "ServiceCut", "ParkingGarage", "FerryTerminal", "Skybridge"]
    crates = sorted(k for k in names if re.fullmatch(r"SupplyCrate_\d", k))
    missing_route = [k for k in route_parts if k not in names]
    check("second-route geometry is present",
          not missing_route and len(crates) == 4,
          f"missing={missing_route} crates={crates}")

    # ---- 15. new landmarks are registered in WorldService zones ----
    world_src = read(SRC / "server" / "Modules" / "WorldService.luau")
    zone_names = set(re.findall(r'\{ name = "(\w+)"', world_src))
    expected_zones = {"ParkingGarage", "FerryTerminal", "ServiceCut"}
    check("new landmarks registered as world zones", expected_zones <= zone_names,
          f"zones={sorted(zone_names)}")

    # ---- 16. upgrade catalog is wired end to end ----
    upgrade_src = read(SRC / "server" / "Modules" / "UpgradeService.luau")
    # Scoped to the Upgrades block: Config.Crew also has an Order list, and an unscoped regex
    # silently started validating the crew roles as if they were salvage upgrades.
    upgrades_block = re.search(r"Config\.Upgrades = \{(.*?)\n\}\n", config_text, re.S)
    upgrades_text = upgrades_block.group(1) if upgrades_block else ""
    catalog = re.findall(r"^\t(\w+) = \{\n\t\tLabel", upgrades_text, re.M)
    order = re.search(r"Order = \{ ([^}]+) \}", upgrades_text)
    order_ids = re.findall(r'"(\w+)"', order.group(1)) if order else []
    kinds = set(re.findall(r'Kind = "(\w+)"', config_text))
    readers = {
        "flood": "floodMultiplier",
        "oxygen": "oxygenBonus",
        "capacity": "capacityBonus",
        "seal": "sealMultiplier",
        "revive": "reviveSpeed",
        "lift": "liftServo",
    }
    unread = [k for k in kinds if readers.get(k) and readers[k] not in all_src]
    check("upgrade catalog is complete and consumed",
          len(order_ids) == 6 and set(order_ids) <= set(catalog) and not unread,
          f"order={order_ids} unreadEffects={unread}")

    # ---- 17. survivor roles have effects implemented ----
    roles = set(re.findall(r'Role = "(\w+)"', config_text))
    role_hooks = {
        "Medic": "medicAura",
        "Engineer": "engineerNear",
        "Child": "MaxWadeDepth",
    }
    missing_roles = [r for r in roles if role_hooks.get(r) and role_hooks[r] not in all_src]
    check("survivor role effects are implemented", not missing_roles,
          f"roles={sorted(roles)} missing={missing_roles}")

    # ---- 18. crew roles are complete, wired, and every passive is read somewhere ----
    crew_block = re.search(r"Config\.Crew = \{(.*?)\n\}\n", config_text, re.S)
    crew_roles = re.findall(r"\n\t(\w+) = \{\n\t\tLabel = \"(\w+)\"", crew_block.group(1) if crew_block else "")
    crew_ids = [name for name, _ in crew_roles]
    crew_order = re.search(r"Order = \{ ([^}]+) \}", crew_block.group(1) if crew_block else "")
    ordered = re.findall(r'"(\w+)"', crew_order.group(1)) if crew_order else []
    abilities = re.findall(r"Id = \"(\w+)\"", crew_block.group(1) if crew_block else "")
    crew_service = read(SRC / "server" / "Modules" / "CrewService.luau")
    # Every ability must have a handler in the ABILITIES table, and every role an order entry.
    unhandled = [a for a in abilities if f"ABILITIES.{a}" not in crew_service]
    check("crew roles and abilities are complete and ordered",
          ordered == crew_ids and len(abilities) == len(crew_ids) and not unhandled,
          f"order={ordered} roles={crew_ids} abilities={abilities} unhandled={unhandled}")

    # ---- 19. outfall geometry, prompt and model wiring exist in the place ----
    outfall_names = re.findall(r'P\(outfall, "(\w+)"', read(ROOT / "tools" / "build_game.luau"))
    outfall_service = read(SRC / "server" / "Modules" / "OutfallService.luau")
    missing_outfall = [n for n in ("OutfallGate", "OutfallWheel") if n not in names or n not in outfall_names]
    check("outfall sluice is baked and adopted by the server",
          not missing_outfall and "Wheel = \"OutfallWheel\"" in config_text and "Outfall.gate" in outfall_service,
          f"parts={outfall_names} missing={missing_outfall}")

    # ---- 20. the outfall actually moves the water, and the breaker has a hand reset ----
    flood_service = read(SRC / "server" / "Modules" / "FloodService.luau")
    power_service = read(SRC / "server" / "Modules" / "PowerService.luau")
    check("outfall drain is subtracted from the district water level",
          "ctx.outfall" in flood_service and "drainRate" in flood_service,
          "FloodService applies the outfall pull each tick: " + str("ctx.outfall" in flood_service))
    check("tripped breakers can be reset by hand and re-wire their prompt",
          "function Power.resetBreaker" in power_service and "Reset Breaker" in power_service
          and "BreakerResetSeconds" in config_text,
          "resetBreaker + prompt text + config hold present")

    # ---- 21. the client exposes the crew board and its inputs ----
    systems_client = read(SRC / "client" / "Modules" / "Systems.luau")
    client_src = read(SRC / "client" / "Client.client.luau")
    check("client ships a crew board with role rows, an ability button and the outfall gauge",
          all(token in systems_client for token in ("Systems.crewRows", "Systems.abilityButton", "Systems.outfallLabel"))
          and "RequestRole" in client_src and "RequestAbility" in client_src,
          "crew board widgets + role/ability remotes present in the client")

    # ---- 22. every remote the client uses is declared by Net and created by the server ----
    declared = set(re.findall(r"\n\t(\w+) = \"Remote(?:Event|Function)\"", read(SRC / "shared" / "Net.luau")))
    used = set(re.findall(r"remotes\.(\w+)", client_src + read(SRC / "client" / "Modules" / "Systems.luau")))
    bootstrap = read(SRC / "server" / "Bootstrap.server.luau")
    server_services = set(re.findall(r'require\(Modules:WaitForChild\("(\w+)"\)\)', bootstrap))
    world_modules = dict(re.findall(r'\{ name = "(\w+)", service = (\w+) \}', bootstrap))
    check("client remotes exist and every server service is registered in the lifecycle",
          used <= declared
          and world_modules.get("Crew") == "CrewService"
          and world_modules.get("Outfall") == "OutfallService"
          and {"CrewService", "OutfallService"} <= server_services,
          f"undeclared={sorted(used - declared)} lifecycle={world_modules.get('Crew')}/{world_modules.get('Outfall')}")

    # ---- 23. dragging a downed teammate is wired from the prompt to the readout ----
    player_service = read(SRC / "server" / "Modules" / "PlayerService.luau")
    hud_client = read(SRC / "client" / "Modules" / "Hud.luau")
    bootstrap = read(SRC / "server" / "Bootstrap.server.luau")
    check("a downed teammate can be dragged, and the client shows who has whom",
          all(token in player_service for token in
              ("startDrag", "stopDrag", "DragTeammate", "draggedBy", "detachDragPrompt"))
          and "PlayerService.dragging(player)" in bootstrap
          and all(token in hud_client for token in ("me.dragging", "me.draggedBy", "Hud.bleedBar")),
          "prompt + start/stop + payload + HUD readouts present")

    # ---- 24. the drag actually moves the casualty and stretches the bleedout window ----
    stretch = re.search(r"DRAG_BLEED_STRETCH = ([\d.]+)", player_service)
    check("hauling a casualty moves them and buys them time",
          "rootPart.CFrame = CFrame.new(trail.Position)" in player_service
          and stretch is not None and float(stretch.group(1)) > 1.0
          and "PlayerService.drags[player]" in player_service,
          f"casualty rides the carrier, bleed stretch x{stretch.group(1) if stretch else '?'}")

    failures = [c for c in checks if not c["ok"]]
    report = {
        "checks": checks,
        "passed": len(checks) - len(failures),
        "failed": len(failures),
        "sourceFiles": {
            "server": [str(f.relative_to(ROOT)) for f in server_files],
            "client": [str(f.relative_to(ROOT)) for f in client_files],
            "shared": [str(f.relative_to(ROOT)) for f in shared_files],
        },
    }
    EVIDENCE.mkdir(exist_ok=True)
    (EVIDENCE / "logic-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    for entry in checks:
        print(f"[{'PASS' if entry['ok'] else 'FAIL'}] {entry['check']}")
        print(f"        {entry['detail']}")
    print(f"\n{len(checks) - len(failures)}/{len(checks)} logic checks passed")
    return 1 if failures else 0


def structure_scripts_paths(structure: dict) -> list[str]:
    return [entry["path"] for entry in structure["scripts"]]


if __name__ == "__main__":
    sys.exit(main())
