--!nonstrict
--[[
	Client detector for Infinite Yield.

	Sweeps every GUI container a game script can read for IY fingerprints and
	reports a verified hit over the shared secure channel. Handshake and heartbeat
	are owned by SecureChannel, so this script only scans and reports.

	Place this LocalScript and its sibling modules somewhere the client runs it
	(e.g. StarterPlayerScripts).

	Honest limit: this can only inspect containers a game script is allowed to read
	(PlayerGui, and CoreGui/gethui on a best-effort basis). A fully cloaked
	executor evades it — see IYSignatures.luau.
]]

local Players = game:GetService("Players")

local Config = require(script.Parent.Config)
local IYSignatures = require(script.Parent.IYSignatures)
local SecureChannel = require(script.Parent.SecureChannel)

local player = Players.LocalPlayer

--> Every GUI container this script is permitted to read. CoreGui and gethui are
--> attempted defensively — in a normal client gethui is nil and the pcall is a
--> harmless no-op; in an executor context they may expose the cloaked UI.
local function readableContainers(): { Instance }
	local containers = {}

	local ok, playerGui = pcall(function()
		return player:WaitForChild("PlayerGui", 5)
	end)
	if ok and playerGui then
		table.insert(containers, playerGui)
	end

	pcall(function()
		table.insert(containers, game:GetService("CoreGui"))
	end)

	pcall(function()
		local hui = (gethui :: any)()
		if hui then
			table.insert(containers, hui)
		end
	end)

	return containers
end

SecureChannel.start()

task.spawn(function()
	while true do
		task.wait(Config.ScanInterval)
		if not SecureChannel.established() then
			continue
		end
		for _, container in readableContainers() do
			local ok, result = pcall(IYSignatures.scan, container)
			if ok and result.detected then
				SecureChannel.send("detect", result.signal)
				break
			end
		end
	end
end)
