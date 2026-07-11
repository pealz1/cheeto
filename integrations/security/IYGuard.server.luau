--!nonstrict
--[[
	Server guard for the IY detection channel.

	- Issues each client a per-session secret + nonce on handshake.
	- Verifies every signed client message (monotonic sequence blocks replay).
	- Kicks on a verified detection report.
	- Kicks a client that completed the handshake then goes silent past the
	  heartbeat timeout (detector removed or its reports blocked) — with a grace
	  window after join and lag-hitch forgiveness so legitimate players are never
	  falsely kicked.

	Place this Script and its sibling modules (Config, SecureReport) in
	ServerScriptService (or anywhere the server runs it).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)
local SecureReport = require(script.Parent.SecureReport)

local remote = Instance.new("RemoteEvent")
remote.Name = Config.RemoteName
remote.Parent = ReplicatedStorage

type Session = {
	secret: string,
	nonce: string,
	seq: number,
	lastSeen: number,
	handshakeAt: number,
}

local sessions: { [Player]: Session } = {}

local function kick(player: Player)
	sessions[player] = nil
	pcall(function()
		player:Kick(Config.KickMessage)
	end)
end

local function newToken(): string
	return (HttpService:GenerateGUID(false):gsub("%-", ""))
end

remote.OnServerEvent:Connect(function(player: Player, message)
	if type(message) ~= "table" then
		return
	end

	--> Handshake: (re)issue a fresh session.
	if message.k == "hello" then
		local now = os.clock()
		sessions[player] = {
			secret = newToken(),
			nonce = newToken(),
			seq = 0,
			lastSeen = now,
			handshakeAt = now,
		}
		remote:FireClient(player, {
			k = "challenge",
			secret = sessions[player].secret,
			nonce = sessions[player].nonce,
		})
		return
	end

	local session = sessions[player]
	if not session then
		return
	end

	--> Signed message: { seq, kind, payload, sig }.
	local seq = message.seq
	local kind = message.kind
	local payload = message.payload or ""
	local sig = message.sig
	if type(seq) ~= "number" or type(kind) ~= "string" then
		return
	end

	--> Strictly increasing sequence rejects replays and reordered captures.
	if seq <= session.seq then
		return
	end
	if not SecureReport.verify(session.secret, session.nonce, seq, kind, payload, sig) then
		return
	end

	session.seq = seq
	session.lastSeen = os.clock()

	if kind == "detect" then
		kick(player)
	end
	--> "heartbeat" only needs to refresh lastSeen, done above.
end)

Players.PlayerRemoving:Connect(function(player)
	sessions[player] = nil
end)

--> Timeout enforcement with lag forgiveness.
local lastTick = os.clock()
RunService.Heartbeat:Connect(function()
	local now = os.clock()
	local delta = now - lastTick
	lastTick = now

	--> Server hitched this frame: forgive everyone so lag never counts against a
	--> player's heartbeat timer.
	if delta > Config.LagHitchSeconds then
		for _, session in sessions do
			session.lastSeen = now
		end
		return
	end

	for player, session in sessions do
		if (now - session.handshakeAt) < Config.JoinGraceSeconds then
			continue
		end
		if (now - session.lastSeen) > Config.HeartbeatTimeout then
			kick(player)
		end
	end
end)
