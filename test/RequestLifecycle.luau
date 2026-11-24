local task = require("@lune/task")

return function(Client, Server, Player, Removing, Advance)
	local Settings = {
		MaxBurstBytes = 1,
		ReliableFragmentBytes = 0,
		MaxActiveRequestsPerPlayer = 1,
		EnableCharacterIntegrity = false,
	}
	Client.Configure(Settings)
	Server.Configure(Settings)
	local Object = {}
	local Permissions = { Use = true }
	local Token = Server.Handles.IssueCapability(Object, Player, Permissions, 0.5)
	Permissions.Use = false
	assert(Server.Handles.ValidateCapability(Token, nil, "Use") == nil, "Owned grants require their owner")
	assert(Server.Handles.ConsumeCapability(Token, {}, "Use") == nil, "A failed owner check must preserve the grant")
	assert(
		Server.Handles.ConsumeCapability(Token, Player, "Other") == nil,
		"A failed permission check must preserve the grant"
	)
	assert(Server.Handles.ConsumeCapability(Token, Player, "Use") == Object, "Issued permissions must be a snapshot")
	assert(Server.Handles.ConsumeCapability(Token, Player, "Use") == nil, "One-time grants must be spent atomically")
	local Revoked = Server.Handles.IssueCapability(Object, Player, nil, 10)
	Server.Handles.RevokeCapability(Revoked)
	assert(
		Server.Handles.ValidateCapability(Revoked, Player) == nil,
		"Explicit revocation must take effect immediately"
	)
	local Expired = Server.Handles.IssueCapability(Object, Player, nil, 0.5)
	Advance(1)
	Server.StepReplication()
	assert(Server.Handles.ValidateCapability(Expired, Player) == nil, "An unused grant must expire")
	local Shared = Server.Handles.Register({}, nil)
	local Owned = Server.Handles.Register(Object, Player)
	local Leaving = Server.Handles.IssueCapability(Object, Player, nil)

	local Results = {}
	local function Call(Value)
		task.spawn(function()
			Results[Value] = table.pack(pcall(Client.Lookup.Invoke, Value))
		end)
		Client.StepReplication()
	end
	local function Flush()
		Server.StepReplication()
		task.wait()
	end
	Client.Capture.Start({ Limit = 8 })
	Call(1)
	Call(2)
	local Waiting
	local Disconnect = Server.Lookup.On(function(_, Value)
		if Value == 1 then
			Waiting = coroutine.running()
			coroutine.yield()
		end
		return Value
	end)
	Flush()
	assert(
		Waiting and Results[2] and not Results[2][1] and string.find(Results[2][2], "RequestBusy"),
		"A queued call must receive a busy reply while its predecessor is waiting"
	)
	local Stats = Server.Diagnostics.Requests(Player)
	assert(
		Stats.Active == 1 and Stats.Peak == 1 and Stats.Limited == 1,
		"Diagnostics must distinguish active and limited requests"
	)
	local Other = { Parent = {}, UserId = 2 }
	local Request = Client.Capture.Entries({ Name = "Lookup", Direction = "send", Limit = 1 })
	Server.Configure({ MaxActiveRequests = 1 })
	Server.Capture.ReplayRaw(Request, Other)
	assert(Server.Diagnostics.Requests(Other).Limited == 1, "The global ceiling must apply across players")
	Server.Configure({ MaxActiveRequests = 0 })
	Server.Capture.ReplayRaw(Request, Other)
	assert(Server.Diagnostics.Requests(Other).Accepted == 1, "An available global slot must admit a different player")
	Client.Capture.Stop()
	task.spawn(Waiting)
	Flush()
	assert(
		Results[1][1] and Results[1][2] == 1 and Server.Diagnostics.Requests().Active == 0,
		"Completing the handler must release its slot"
	)
	local Remove = Client.Use("AfterSend", function(Context)
		if Context.Name == "Lookup" then
			Client.StepReplication()
			Server.StepReplication()
		end
	end)
	Call(3)
	Remove()
	assert(
		Results[3] and Results[3][1] and Results[3][2] == 3,
		"Immediate replies during send middleware must reach their own caller"
	)
	Disconnect()
	local Failed = Server.Lookup.On(function()
		error("expected handler failure")
	end)
	Call(4)
	Flush()
	Failed()
	assert(
		not Results[4][1]
			and Server.Diagnostics.Requests(Player).Failed == 1
			and Server.Diagnostics.Requests().Active == 0,
		"Handler errors must release capacity"
	)
	Client.Configure({ MaxPendingInvokes = 320, MaxReliablePacketBytes = 65536 })
	Server.Configure({ MaxQueuedEvents = 320, MaxReliablePacketBytes = 65536 })
	assert(
		not pcall(Client.Configure, { WideRequestIds = false }),
		"Request identifier width must remain fixed on a running connection"
	)
	local Count = 0
	for i = 1, 300 do
		task.spawn(function()
			local value = Client.Lookup.Invoke(i % 256)
			assert(value == i % 256, "Each wide reply should match its own request")
			Count += 1
		end)
	end
	assert(Client.Stats().PendingInvokes == 300, "Wide identifiers must fit 300 outstanding calls")
	Client.StepReplication()
	local UnbindWide = Server.Lookup.On(function(_, value)
		return value
	end)
	Flush()
	assert(Count == 300 and Client.Stats().PendingInvokes == 0, "All 300 waiting threads must resume once")
	UnbindWide()
	local Interrupted
	local UnbindSlow = Server.Lookup.On(function()
		Interrupted = coroutine.running()
		coroutine.yield()
		return 0
	end)
	Call(6)
	task.cancel(Interrupted)
	Advance(2)
	Server.StepReplication()
	assert(
		Server.Diagnostics.Requests().Active == 0 and Server.Diagnostics.Requests(Player).Cancelled == 1,
		"Cancelling a yielding handler must release its slot"
	)
	UnbindSlow()
	Client.CancelInvocations("handler cancelled")
	Call(5)
	Client.DeferredNote.Fire(8, nil)
	Client.StepReplication()
	local TupleSize, TupleValue
	local RemoveDeferred = Server.DeferredNote.On(function(_, ...)
		TupleSize, TupleValue = select("#", ...), ...
	end)
	assert(TupleSize == 2 and TupleValue == 8, "Queued delivery must preserve trailing nil arguments")
	RemoveDeferred()
	Client.DeferredNote.Fire(9, nil)
	Client.StepReplication()
	Server.Configure({ MaxQueuedEvents = 1 })
	Client.PollRequest.Fire(23)
	Client.PollRequest.Fire(24)
	Client.StepReplication()
	local iter = Server.PollRequest.Iter()
	local _, _, value = iter()
	assert(value == 23 and iter() == nil, "The live queue limit must apply to polling endpoints")
	Client.PollRequest.Fire(25)
	Client.StepReplication()
	Server.Security.RegisterKnownId(42, Player)
	Server.Security.RegisterKnownId(43, Player)
	Server.Security.RegisterKnownId(43)
	local Seen = {}
	Server.RedeemId.On(function(_, id)
		Seen[id] = true
	end)
	Removing.Callback(Player)
	Client.RedeemId.Fire(42)
	Client.RedeemId.Fire(43)
	Client.StepReplication()
	assert(not Seen[42] and Seen[43], "Departure removes owned ids and preserves ids transferred into shared use")
	assert(Server.PollRequest.Iter()() == nil, "Polling must release a departed player's buffered messages")
	assert(
		Server.Handles.Resolve(Owned) == nil and Server.Handles.ValidateCapability(Leaving, Player) == nil,
		"Player removal must revoke owned handles and grants"
	)
	assert(
		Server.Handles.Resolve(Shared) ~= nil and Server.Diagnostics.Requests(Player) == nil,
		"Player cleanup must preserve shared handles"
	)
	local Called = false
	Server.Lookup.On(function()
		Called = true
		return 0
	end)
	Server.DeferredNote.On(function()
		Called = true
	end)
	assert(not Called, "Requests and events queued by a departed player must be removed")
	Client.CancelInvocations("test cleanup")
end
