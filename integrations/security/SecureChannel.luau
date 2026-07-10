--!nonstrict
--[[
	Shared client secure channel.

	Owns the handshake, the signed heartbeat, and the signed `send`, so every
	client detector (IY, movement, …) reports over ONE session instead of each
	opening its own. A ModuleScript is cached per environment, so all detectors
	that require this share the same secret/nonce/sequence.

	Call `start()` once (idempotent); call `send(kind, payload)` to report.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(script.Parent.Config)
local SecureReport = require(script.Parent.SecureReport)

local remote = ReplicatedStorage:WaitForChild(Config.RemoteName)

local secret: string? = nil
local nonce: string? = nil
local sequence = 0
local started = false

local function established(): boolean
	return secret ~= nil and nonce ~= nil
end

local function send(kind: string, payload: string?): boolean
	if not established() then
		return false
	end
	sequence += 1
	local body = payload or ""
	remote:FireServer({
		seq = sequence,
		kind = kind,
		payload = body,
		sig = SecureReport.sign(secret :: string, nonce :: string, sequence, kind, body),
	})
	return true
end

local function start()
	if started then
		return
	end
	started = true

	remote.OnClientEvent:Connect(function(message)
		if type(message) == "table" and message.k == "challenge" then
			secret = message.secret
			nonce = message.nonce
			sequence = 0
		end
	end)

	--> Handshake, retried until the server answers.
	task.spawn(function()
		while not established() do
			remote:FireServer({ k = "hello" })
			task.wait(2)
		end
	end)

	--> Heartbeat so the server can kick a client whose detectors were removed.
	task.spawn(function()
		while true do
			task.wait(Config.HeartbeatInterval)
			send("heartbeat")
		end
	end)
end

return {
	start = start,
	send = send,
	established = established,
}
