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

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
	lastChallengeAt: number,
	windowStart: number,
	reportsInWindow: number,
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

	local now = os.clock()
	local session = sessions[player]
	--> Retry with fresh tokens, preserving the original heartbeat deadline.
	if message.k == "hello" then
		if session and now - session.lastChallengeAt < 1 then
			return
		end
		session = {
			secret = newToken(),
			nonce = newToken(),
			seq = 0,
			lastSeen = if session then session.lastSeen else now,
			handshakeAt = if session then session.handshakeAt else now,
			lastChallengeAt = now,
			windowStart = if session then session.windowStart else now,
			reportsInWindow = if session then session.reportsInWindow else 0,
		}
		sessions[player] = session
		remote:FireClient(player, {
			k = "challenge",
			secret = session.secret,
			nonce = session.nonce,
		})
		return
	end

	if not session then
		return
	end

	--> Signed message: { seq, kind, payload, sig }.
	local seq = message.seq
	local kind = message.kind
	local payload = if message.payload == nil then "" else message.payload
	local sig = message.sig
	if kind ~= "heartbeat" and kind ~= "detect" then
		return
	end

	--> Strictly increasing sequence rejects replays and reordered captures.
	if type(seq) ~= "number" or seq % 1 ~= 0 or seq <= session.seq or seq > 9007199254740991 then
		return
	end
	if type(payload) ~= "string" or #payload > 512 then
		return
	end
	if now - session.windowStart >= 1 then
		session.windowStart = now
		session.reportsInWindow = 0
	end
	if session.reportsInWindow >= 12 then
		return
	end
	session.reportsInWindow += 1
	if not SecureReport.verify(session.secret, session.nonce, seq, kind, payload, sig) then
		return
	end

	session.seq = seq
	session.lastSeen = now

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
local nextSweep = lastTick
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

	if now < nextSweep then
		return
	end
	nextSweep = now + 1
	for player, session in sessions do
		if (now - session.handshakeAt) < Config.JoinGraceSeconds then
			continue
		end
		if (now - session.lastSeen) > Config.HeartbeatTimeout then
			kick(player)
		end
	end
end)
