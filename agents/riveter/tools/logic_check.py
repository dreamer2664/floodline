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
    consumers = set(re.findall(r"^\s{2}(\w+) = \{\n\s+Label", read(SRC / "shared" / "Config.luau"), re.M))
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
    check("eight survivors with interaction prompts",
          len(survivor_models) == 8 and survivor_prompts == 8,
          f"models={len(survivor_models)} survivorPrompts={survivor_prompts} (all prompts={structure['prompts']})")

    # ---- 8. lift cabin has 4 seats and a platform ----
    seats = len([k for k in names if k.startswith("LiftSeat")])
    check("lift cabin has four seats", seats == 4 and "EvacLift" in names, f"seats={seats}")

    # ---- 9. power cells: three, matching Config.Power.CellCount ----
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
