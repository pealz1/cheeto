--!nonstrict
--[[
	Client detector for the IY detection channel.

	Completes the handshake, then on a timer sweeps every GUI container a game
	script can read for Infinite Yield fingerprints and reports a verified hit over
	the signed channel. A steady signed heartbeat lets the server kick the client
	if this script is removed or its reports are blocked.

	Place this LocalScript and its sibling modules (Config, SecureReport,
	IYSignatures) somewhere the client runs it (e.g. StarterPlayerScripts).

	Honest limit: this can only inspect containers a game script is allowed to read
	(PlayerGui, and CoreGui/gethui on a best-effort basis). A fully cloaked
	executor evades it — see IYSignatures.luau.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(script.Parent.Config)
local SecureReport = require(script.Parent.SecureReport)
local IYSignatures = require(script.Parent.IYSignatures)

local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild(Config.RemoteName)

local secret: string? = nil
local nonce: string? = nil
local sequence = 0

local function established(): boolean
	return secret ~= nil and nonce ~= nil
end

local function send(kind: string, payload: string?)
	if not established() then
		return
	end
	sequence += 1
	local body = payload or ""
	remote:FireServer({
		seq = sequence,
		kind = kind,
		payload = body,
		sig = SecureReport.sign(secret :: string, nonce :: string, sequence, kind, body),
	})
end

remote.OnClientEvent:Connect(function(message)
	if type(message) == "table" and message.k == "challenge" then
		secret = message.secret
		nonce = message.nonce
		sequence = 0
	end
end)

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

--> Handshake, retried until the server answers.
task.spawn(function()
	while not established() do
		remote:FireServer({ k = "hello" })
		task.wait(2)
	end
end)

--> Scan loop.
task.spawn(function()
	while true do
		task.wait(Config.ScanInterval)
		if not established() then
			continue
		end
		for _, container in readableContainers() do
			local ok, result = pcall(IYSignatures.scan, container)
			if ok and result.detected then
				send("detect", result.signal)
				break
			end
		end
	end
end)

--> Heartbeat loop.
task.spawn(function()
	while true do
		task.wait(Config.HeartbeatInterval)
		send("heartbeat")
	end
end)
