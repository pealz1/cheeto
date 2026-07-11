--[[
	Shared configuration for the security channel, required by both the client
	detector and the server guard so the two never drift.
]]

return {
	--> Single, non-descriptive RemoteEvent name. Per-call renaming is deliberately
	--> NOT done: a remote spy hooks the FireServer C-closure, not the instance
	--> name, so renaming every call costs replication churn for zero security. One
	--> obfuscated name is the honest, useful version.
	RemoteName = "f9c3a7d1",

	--> How often the client sweeps readable GUI containers for IY fingerprints.
	ScanInterval = 3,

	--> Signed heartbeat cadence and the server-side timeout before a silent client
	--> (detector removed/blocked) is kicked. Timeout comfortably exceeds several
	--> missed heartbeats to tolerate network jitter.
	HeartbeatInterval = 3,
	HeartbeatTimeout = 15,

	--> Grace after handshake before timeout enforcement begins, so a freshly joined
	--> or still-loading client is never kicked.
	JoinGraceSeconds = 20,

	--> A single server frame slower than this is treated as a lag hitch: heartbeat
	--> timers are forgiven for that tick so a laggy server never mass-kicks.
	LagHitchSeconds = 2,

	--> Neutral kick text — never reveal which signal fired to the exploiter.
	KickMessage = "Disconnected.",
}
