--!strict
-- export_binary.luau — writes the binary .rbxl sibling of the XML place.
-- Some Studio workflows and diff tools prefer the binary form; both hold identical content.
-- Run from the repository root:  lune run agents/riveter/tools/export_binary.luau

local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local process = require("@lune/process")

local AGENT = process.cwd .. "/agents/riveter"
local xml = AGENT .. "/releases/FLOODLINE.rbxlx"
local binary = AGENT .. "/releases/FLOODLINE.rbxl"

local place = roblox.deserializePlace(fs.readFile(xml))
fs.writeFile(binary, roblox.serializePlace(place))
print(`wrote {binary} ({#fs.readFile(binary)} bytes)`)
