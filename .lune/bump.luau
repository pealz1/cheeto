local darklua_version = require("./libs/darklua_version")
local log = require("./libs/log")
local pesde_version = require("./libs/pesde_version")
local stdio = require("@lune/stdio")

local PESDE_CONFIG = "pesde.toml"
local DARKLUA_CONFIGS = { "build/.darklua.json", "plugin/.darklua.json" }

local curr_version = darklua_version.read_from(DARKLUA_CONFIGS[1])
local new_version = stdio.prompt("text" :: "text", `What version is being built? (Current version is {curr_version})`)

for _, config in DARKLUA_CONFIGS do
	darklua_version.write_to(config, new_version)
end
pesde_version.write_to(PESDE_CONFIG, new_version)

log(`Bumped {curr_version} -> {new_version}. Add a CHANGELOG entry before tagging.`)
