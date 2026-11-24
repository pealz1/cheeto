--> Isolated roundtrip coverage for the extended datatype prefabs.
--> Uses cheeto's `export type` Read/Write pair so each type is serialized and
--> deserialized directly through a buffer, with no networking harness involved.
--> Real @lune/roblox datatypes are used where they exist; TweenInfo is mocked
--> because Lune does not implement it.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

local function OkPrint(Message: string)
	stdio.write(`\r[{stdio.color("green")}OK{stdio.color("reset")}] {Message}\n`)
end

local function ErrorPrint(Message: string)
	stdio.write(`\r[{stdio.color("red")}ERROR{stdio.color("reset")}] {Message}\n`)
	process.exit(21)
end

local function MockTypeof(Value: any): string
	local Type = typeof(Value)
	if Type == "table" and (Value :: any).__typeof then
		return (Value :: any).__typeof
	end
	return Type
end

local function Equals(a: any, b: any): boolean
	if a == b then
		return true
	end

	local TypeA, TypeB = type(a), type(b)
	if TypeA ~= TypeB or TypeA ~= "table" then
		return false
	end

	for Key, Value in a do
		if not Equals(Value, b[Key]) then
			return false
		end
	end
	for Key in b do
		if a[Key] == nil then
			return false
		end
	end
	return true
end

--> Lune has no TweenInfo; mock it as a tagged table so MockTypeof + Equals work.
local TweenInfo = {}
function TweenInfo.new(Time, Style, Direction, RepeatCount, Reverses, DelayTime)
	return table.freeze({
		__typeof = "TweenInfo",
		Time = Time,
		EasingStyle = Style,
		EasingDirection = Direction,
		RepeatCount = RepeatCount,
		Reverses = Reverses,
		DelayTime = DelayTime,
	})
end

local Environment = {
	Vector2 = roblox.Vector2,
	Vector2int16 = roblox.Vector2int16,
	Vector3int16 = roblox.Vector3int16,
	Vector3 = roblox.Vector3,
	Region3 = roblox.Region3,
	Region3int16 = roblox.Region3int16,
	UDim = roblox.UDim,
	UDim2 = roblox.UDim2,
	Rect = roblox.Rect,
	Ray = roblox.Ray,
	NumberRange = roblox.NumberRange,
	PhysicalProperties = roblox.PhysicalProperties,
	Axes = roblox.Axes,
	Faces = roblox.Faces,
	Enum = roblox.Enum,
	Font = roblox.Font,
	NumberSequence = roblox.NumberSequence,
	NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
	ColorSequence = roblox.ColorSequence,
	ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
	Color3 = roblox.Color3,
	CFrame = roblox.CFrame,
	TweenInfo = TweenInfo,
	_G = {},
	task = task,
	typeof = MockTypeof,
	require = function()
		error("require is not supported")
	end,
}

--> The two generated modules share synchronous remote signals for the
--> transport tests. Manual steps drive delivery without a Heartbeat loop.
local TestPlayer = { Parent = {}, UserId = 1 }
local SentParts = {}
local HoldParts = false
do
	local function StubSignal()
		return {
			Connect = function(self, Callback)
				self.Callback = Callback
				return {
					Disconnect = function()
						self.Callback = nil
					end,
				}
			end,
		}
	end
	local function StubRemote()
		return {
			OnClientEvent = StubSignal(),
			OnServerEvent = StubSignal(),
			FireServer = function(self, Packet, Instances)
				if HoldParts then
					table.insert(SentParts, { Packet, Instances })
				else
					self.OnServerEvent.Callback(TestPlayer, Packet, Instances)
				end
			end,
			FireClient = function(self, _, Packet, Instances)
				self.OnClientEvent.Callback(Packet, Instances)
			end,
		}
	end
	local Instances = {
		CHEETO_RELIABLE_REMOTE = StubRemote(),
		CHEETO_UNRELIABLE_REMOTE = StubRemote(),
	}
	local Services = {
		ReplicatedStorage = {
			WaitForChild = function(_, Name: string)
				return Instances[Name]
			end,
			FindFirstChild = function(_, Name: string)
				return Instances[Name]
			end,
		},
		RunService = {
			Heartbeat = StubSignal(),
			IsClient = function()
				return true
			end,
			IsServer = function()
				return true
			end,
			IsRunning = function()
				return true
			end,
		},
		Players = {
			PlayerRemoving = StubSignal(),
			GetPlayers = function()
				return { TestPlayer }
			end,
		},
	}
	Environment.game = {
		GetService = function(_, Name: string)
			return Services[Name]
		end,
	}
end

--> Compile the definition ourselves so the export module is guaranteed to exist
--> regardless of how the surrounding harness orders or clears the Network folder.
local Compile = process.exec(
	"lune",
	{ "run", "init", "../../test/Sources/Datatypes.cheeto", "--", "--yes" },
	{ cwd = "../src/CLI" }
)
if not Compile.ok then
	ErrorPrint(`Failed to compile Datatypes.cheeto:\n{Compile.stderr}`)
end

local Bytecode = luau.compile(fs.readFile("../Network/DatatypesClient.luau"), { optimizationLevel = 1, debugLevel = 2 })
local Cheeto = luau.load(Bytecode, { debugName = "DatatypesClient", environment = Environment })()

local ServerEnv = table.clone(Environment)
ServerEnv._G = {}
local Now = 100
ServerEnv.os = table.clone(os)
ServerEnv.os.clock = function()
	return Now
end
local Server = luau.load(fs.readFile("../Network/DatatypesServer.luau"), { environment = ServerEnv })()
local Config =
	{ EnableProtocolHandshake = false, ReliableFragmentBytes = 8, MaxReliablePacketBytes = 512, RateLimitPerSecond = 0 }
Cheeto.Configure(Config)
Server.Configure(Config)

local function Roundtrip(Name: string, Export: string, Value: any)
	stdio.write(`{stdio.color("cyan")}Testing: {Name}...{stdio.color("reset")}`)
	local Api = (Cheeto :: any)[Export]
	if not Api then
		ErrorPrint(`Export "{Export}" was not generated.`)
	end

	local WriteOk, Buffer = pcall(Api.Write, Value)
	if not WriteOk then
		ErrorPrint(`"{Name}" failed to write: {Buffer}`)
	end
	local ReadOk, Result = pcall(Api.Read, Buffer)
	if not ReadOk then
		ErrorPrint(`"{Name}" failed to read: {Result}`)
	end
	if not Equals(Result, Value) then
		ErrorPrint(`"{Name}" roundtrip mismatch.\nExpected: {Value}\nGot: {Result}`)
	end
	OkPrint(`Datatype "{Name}" passed!`)
end

local Enum = roblox.Enum
local V3 = roblox.Vector3

Roundtrip("Vector2", "EVector2", roblox.Vector2.new(3.5, -7.25))
Roundtrip("Vector2<i16>", "EVector2Encoded", roblox.Vector2.new(120, -40))
assert(
	Equals(
		Cheeto.EVector2Encoded.Read(Cheeto.EVector2Encoded.Write(roblox.Vector2.new(1.75, -2.75))),
		roblox.Vector2.new(1, -2)
	),
	"Signed vector components must truncate toward zero"
)
Roundtrip("Vector2int16", "EVector2int16", roblox.Vector2int16.new(120, -40))
Roundtrip("Vector3int16", "EVector3int16", roblox.Vector3int16.new(1, -2, 3))
Roundtrip("Region3", "ERegion3", roblox.Region3.new(V3.new(0, 0, 0), V3.new(2, 4, 6)))
Roundtrip("UDim", "EUDim", roblox.UDim.new(0.5, 20))
Roundtrip("UDim2", "EUDim2", roblox.UDim2.new(0.5, 20, 0.25, -10))
Roundtrip("Rect", "ERect", roblox.Rect.new(0, 0, 4, 8))
Roundtrip("Ray", "ERay", roblox.Ray.new(V3.new(1, 2, 3), V3.new(0, 1, 0)))
Roundtrip("NumberRange", "ENumberRange", roblox.NumberRange.new(2, 8))
Roundtrip("PhysicalProperties", "EPhysicalProperties", roblox.PhysicalProperties.new(0.7, 0.3, 0.5, 1, 1))
Roundtrip("Axes", "EAxes", roblox.Axes.new(Enum.Axis.X, Enum.Axis.Z))
Roundtrip("Faces", "EFaces", roblox.Faces.new(Enum.NormalId.Top, Enum.NormalId.Front))
Roundtrip("Enum", "EEnum", Enum.KeyCode.Space)
Roundtrip("TweenInfo", "ETweenInfo", TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 3, true, 0.25))
Roundtrip(
	"Font",
	"EFont",
	roblox.Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.Bold, Enum.FontStyle.Italic)
)
Roundtrip(
	"NumberSequence",
	"ENumberSequence",
	roblox.NumberSequence.new({
		roblox.NumberSequenceKeypoint.new(0, 1, 0),
		roblox.NumberSequenceKeypoint.new(0.5, 0.25, 0),
		roblox.NumberSequenceKeypoint.new(1, 0, 0),
	})
)
Roundtrip(
	"ColorSequence",
	"EColorSequence",
	roblox.ColorSequence.new({
		roblox.ColorSequenceKeypoint.new(0, roblox.Color3.new(1, 0, 0)),
		roblox.ColorSequenceKeypoint.new(1, roblox.Color3.new(0, 0, 1)),
	})
)
Roundtrip(
	"Region3int16",
	"ERegion3int16",
	roblox.Region3int16.new(roblox.Vector3int16.new(-32, 0, 1), roblox.Vector3int16.new(30, 1, 90))
)
Roundtrip(
	"ColorSequenceKeypoint",
	"EColorSequenceKeypoint",
	roblox.ColorSequenceKeypoint.new(0.25, roblox.Color3.fromRGB(1, 25, 250))
)
Roundtrip("NumberSequenceKeypoint", "ENumberSequenceKeypoint", roblox.NumberSequenceKeypoint.new(0.5, 3, 1))
Roundtrip("UDim2? (absent)", "EOptionalUDim", nil)
Roundtrip("boolean (true)", "EFlag", true)
Roundtrip("boolean (false)", "EFlag", false)
Roundtrip("UDim2? (present)", "EOptionalUDim", roblox.UDim2.new(1, 0, 1, 0))
Roundtrip("Vector2[4]", "EArrayVector2", {
	roblox.Vector2.new(1, 1),
	roblox.Vector2.new(2, 2),
	roblox.Vector2.new(3, 3),
	roblox.Vector2.new(4, 4),
})

--> Exercise the normal client-to-server listener, including out-of-order and
--> duplicate delivery of frames produced by the sender's own fragmenter.
local Payload = {
	Bounds = roblox.Region3int16.new(roblox.Vector3int16.new(-2, 0, 1), roblox.Vector3int16.new(2, 4, 6)),
	Opacity = roblox.NumberSequenceKeypoint.new(0.25, 1, 0),
	Tint = roblox.ColorSequenceKeypoint.new(0.5, roblox.Color3.fromRGB(12, 34, 56)),
	Size = roblox.UDim2.new(0.5, 4, 0.5, -4),
}
local Delivered = 0
local CheckNestedRead = false
Server.Appearance.On(function(Player, Data)
	assert(
		Player == TestPlayer and Equals(Data, Payload),
		"Decoded appearance must match the sending player and payload"
	)
	if CheckNestedRead then
		assert(not pcall(Server.EByte.Read, buffer.create(0)), "A truncated export must raise")
	end
	Delivered += 1
end)
HoldParts = true
Cheeto.Appearance.Fire(Payload)
Cheeto.StepReplication()
assert(#SentParts > 2, "Expected a multi-fragment batch")
local Remote = Environment.game:GetService("ReplicatedStorage"):FindFirstChild("CHEETO_RELIABLE_REMOTE")
local function Deliver(Index)
	Remote.OnServerEvent.Callback(TestPlayer, table.unpack(SentParts[Index]))
end
local function DeliverAll()
	for Index = #SentParts, 1, -1 do
		Deliver(Index)
	end
end
Server.Configure({ MaxFragmentBufferBytes = 1 })
DeliverAll()
assert(
	Delivered == 0 and Server.Stats().DroppedPackets.FragmentOverflow > 0,
	"Fragment reservation must respect the peer budget"
)
Server.Configure({ MaxFragmentBufferBytes = 4096, MaxReliablePacketBytes = 20 })
DeliverAll()
assert(
	Delivered == 0 and Server.Stats().DroppedPackets.MaxPacketBytes > 0,
	"Logical size must respect the reliable packet limit"
)
Server.Configure({ MaxReliablePacketBytes = 512, FragmentTimeoutSeconds = 0 })
Deliver(1)
Server.StepReplication()
assert(Server.Stats().DroppedPackets.FragmentTimeout > 0, "An idle incomplete assembly must expire during replication")
Server.Configure({ FragmentTimeoutSeconds = 10 })
Deliver(#SentParts)
DeliverAll()
assert(Delivered == 1, "Expected one validated reassembled payload")
HoldParts = false
task.wait(0.02)
CheckNestedRead = true
Cheeto.Appearance.Fire(Payload)
assert(not pcall(Cheeto.EByte.Write, 300), "Invalid export must raise")
Cheeto.Appearance.Fire(Payload)
Cheeto.StepReplication()
assert(Delivered == 3, "Failed standalone codecs must preserve the queued batch and active receive frame")

--> Exercise both transports with the same deterministic server clock.
do
	local Settings =
		{ MaxBurstBytes = 1, UseStringDictionaries = true, ReliableFragmentBytes = 0, NoRawCaptureInProduction = false }
	Cheeto.Configure(Settings)
	Server.Configure(Settings)
	Cheeto.Capture.Start({ Limit = 8 })
	Server.Capture.Start({ Limit = 3, Redactions = "Secret" })
	Server.Configure({ IngressBytesPerSecond = 16, IngressBurstBytes = 1 })
	assert(Server.Transport.Ingress(TestPlayer) == nil, "An unread peer must have no ingress allocation")
	local Pulses = 0
	Server.Pulse.On(function()
		Pulses += 1
	end)
	Cheeto.Pulse.Fire(1)
	Cheeto.StepReplication()
	local Drop = Server.Capture.Entries({ Reason = "IngressByteLimit", UserId = 1 })[1]
	assert(
		Pulses == 0 and Drop and Drop.Channel == "Unreliable" and Drop.Buffer == nil and Drop.Instances == nil,
		"A dropped packet must carry only its own metadata"
	)
	local PacketBytes = Drop.Size
	assert(
		PacketBytes > 1 and Server.Transport.Ingress(TestPlayer).DroppedBytes == PacketBytes,
		"The shared budget must count the physical packet bytes"
	)
	Server.Configure({ IngressBytesPerSecond = PacketBytes, IngressBurstBytes = PacketBytes })
	Cheeto.Pulse.Fire(2)
	Cheeto.StepReplication()
	Deliver(1)
	local Budget = Server.Transport.Ingress(TestPlayer)
	assert(
		Pulses == 1 and Budget.AdmittedBytes == PacketBytes and Budget.AvailableBytes == 0,
		"An admitted unreliable packet must consume the balance"
	)
	assert(
		Budget.DroppedPackets == 1 and Budget.DroppedBytes == buffer.len(SentParts[1][1]),
		"Reliable fragments must use the same byte budget"
	)
	local Other = { Parent = {}, UserId = 2 }
	local Unreliable = Environment.game:GetService("ReplicatedStorage"):FindFirstChild("CHEETO_UNRELIABLE_REMOTE")
	local Accepted = Server.Capture.Entries({ Name = "Pulse", Direction = "receive" })[1]
	Unreliable.OnServerEvent.Callback(Other, Accepted.Buffer)
	assert(
		Pulses == 2 and Server.Transport.Ingress(Other).AdmittedPackets == 1,
		"A second peer must have an independent allowance"
	)
	Now += 1
	assert(
		Server.Transport.Ingress(TestPlayer).AvailableBytes == PacketBytes,
		"Reading the budget must reflect elapsed refill time"
	)
	Cheeto.Pulse.Fire(3)
	Cheeto.StepReplication()
	assert(
		Pulses == 3 and Server.Transport.Ingress(TestPlayer).AdmittedPackets == 2,
		"The next packet must spend the refilled balance"
	)
	assert(
		Server.Stats().CapturedPackets == 3 and #Server.Capture.Entries({ Limit = 0 }) == 0,
		"The ring must enforce capacity and an empty query limit"
	)
	local Latest = Server.Capture.Entries({ Status = "accepted", Limit = 2 })
	assert(
		#Latest == 2 and Latest[1].UserId == 2 and Latest[2].UserId == 1,
		"Newest matches must be returned in chronological order"
	)
	assert(
		Latest[1].Redaction.Fields.Secret and Latest[2].Redaction.Fields.Secret,
		"Configuring a traffic budget must preserve capture redactions"
	)
	Server.Capture.Start({ Limit = 1 })
	assert(
		#Server.Capture.Entries() == 1 and Server.Capture.Entries()[1].UserId == 1,
		"Shrinking a ring must immediately retain its newest entry"
	)
	assert(
		not pcall(Server.Capture.Start, { Limit = -1 }) and not pcall(Server.Configure, { CaptureLimit = 1.5 }),
		"Invalid capture limits must be rejected"
	)
	Server.Configure({ IngressBytesPerSecond = 0 })
	assert(
		Server.Transport.Ingress(TestPlayer) == nil and Server.Transport.Ingress(Other) == nil,
		"Disabling ingress must release both peer budgets"
	)
	Server.Capture.Start({ Limit = 8 })

	local Notes = {}
	local removeNotes = Server.InventoryNote.On(function(_, Note)
		table.insert(Notes, Note)
	end)
	Cheeto.InventoryNote.Fire({ Label = "inventory", Reference = "first" })
	Cheeto.InventoryNote.Fire({ Label = "inventory", Reference = "second" })
	Cheeto.StepReplication()
	local Received = Server.Capture.Entries({ Name = "InventoryNote" })
	local Sent = Cheeto.Capture.Entries({ Name = "InventoryNote" })
	assert(#Notes == 2 and #Received == 2 and #Sent == 2, "Both messages must reach the listener and both recorders")
	for _, Entries in { Received, Sent } do
		local Entry = Entries[2]
		assert(
			#Entry.Instances == 1 and Entry.Instances[1] == "second",
			"Each recording must contain only its own reference"
		)
		assert(
			Entry.StringContext and Entry.StringContext.Strings[1] == "inventory",
			"A repeated label must retain its original dictionary id"
		)
		assert(
			Server.Capture.ReplayRaw({ Entry }, TestPlayer).Replayed == 1,
			"Raw replay must dispatch a standalone accepted entry"
		)
		assert(
			Notes[#Notes].Label == "inventory" and Notes[#Notes].Reference == "second",
			"Replay must resolve the original label and reference"
		)
	end
	assert(#Notes == 4, "Both send-side and receive-side captures must replay")
	assert(
		Server.Capture.ReplayRaw({ { Status = "dropped", Buffer = Received[1].Buffer } }, TestPlayer).Replayed == 0,
		"Historical dropped frames must never be injected"
	)
	assert(#Notes == 4, "Skipping a dropped frame must preserve the listener count")
	local FirstByte = buffer.readu8(Received[1].Buffer, 0)
	buffer.writeu8(Received[1].Buffer, 0, (FirstByte + 1) % 256)
	assert(
		buffer.readu8(Server.Capture.Entries({ Name = "InventoryNote" })[1].Buffer, 0) == FirstByte,
		"Mutating a snapshot must preserve the recorded bytes"
	)
	Server.Configure({ MaxPacketReferences = 1 })
	Cheeto.InventoryNote.Fire({ Label = "a", Reference = "one" })
	Cheeto.InventoryNote.Fire({ Label = "b", Reference = "two" })
	Cheeto.StepReplication()
	assert(
		#Notes == 4 and Server.Stats().DroppedPackets.ReferenceLimit == 1,
		"Ordinary batched references must respect the configured cap"
	)
	Server.Configure({ MaxPacketReferences = 0 })
	removeNotes()
	local nested = false
	local disconnect = Server.InventoryNote.On(function(_, note)
		table.insert(Notes, note)
		if note.Reference == "outer" then
			nested = Server.Capture.ReplayRaw({ Received[2] }, TestPlayer).Replayed == 1
		end
	end)
	Cheeto.InventoryNote.Fire({ Label = "nested", Reference = "outer" })
	Cheeto.InventoryNote.Fire({ Label = "nested", Reference = "tail" })
	Cheeto.StepReplication()
	assert(
		nested and #Notes == 7 and Notes[7].Reference == "tail",
		"Replaying from a listener must preserve the rest of its outer batch"
	)
	disconnect()
	local sheds = 0
	local removeHook = Cheeto.Use("Telemetry", function(entry)
		if entry.Name == "transport.drop" and entry.Payload.Direction == "send" then
			sheds += 1
		end
	end)
	Cheeto.Security.Kill("Pulse")
	Cheeto.Pulse.Fire(5)
	Cheeto.Security.Unkill("Pulse")
	removeHook()
	assert(
		sheds == 1 and Cheeto.Stats().DroppedPackets.KillSwitch == 1,
		"An outgoing kill switch must emit one transport drop"
	)
	assert(
		Cheeto.Security.AbuseScores("Server").Pulse == nil,
		"Local send failures must not increase a remote peer's abuse score"
	)
	assert(
		#Cheeto.Capture.Entries({ Name = "Pulse", Direction = "send", Status = "dropped" }) == 1,
		"Send-side drops must remain attributable"
	)
	Server.Capture.Start({ Limit = 0 })
	Cheeto.Pulse.Fire(4)
	Cheeto.StepReplication()
	assert(Server.Stats().CapturedPackets == 0, "A zero limit must disable capture storage")
	Cheeto.Capture.Stop()
	Server.Capture.Stop()
end

--> Keep the live sampler on server-owned movement limits throughout a sprint.
local Root =
	{ Position = V3.zero, CFrame = roblox.CFrame.new(), AssemblyLinearVelocity = V3.zero, CollisionGroup = "Default" }
local Humanoid = { WalkSpeed = 16, Sit = true, FloorMaterial = Enum.Material.Grass }
TestPlayer.Character = {
	FindFirstChild = function()
		return Root
	end,
	FindFirstChildOfClass = function()
		return Humanoid
	end,
	PivotTo = function(_, Target)
		Root.CFrame = Target
		Root.Position = Target.Position
	end,
}
Server.Configure({
	EnableCharacterIntegrity = true,
	CharacterIntegrityMode = "Observe",
	CharacterIntegrityJoinGraceSeconds = 0,
	CharacterIntegritySampleIntervalSeconds = 0.05,
	CharacterIntegrityDistanceSlack = 0,
})
Server.StepReplication()
local function MoveAndSample(X)
	Now += 0.125
	TestPlayer.Character:PivotTo(roblox.CFrame.new(X, 0, 0))
	Server.StepReplication()
	return Server.Security.CharacterIntegrity(TestPlayer)
end
local Limits = { Horizontal = 2000 }
Server.Security.SetMovementLimits(TestPlayer, Limits)
Limits.Horizontal = 1
assert(MoveAndSample(60).ConsecutiveBreaches == 0, "The server-granted sprint must stay within its limits")
assert(Server.Security.CharacterIntegrity(TestPlayer).Limits.Horizontal == 2000, "Movement limits must be copied")
assert(
	not pcall(Server.Security.SetMovementLimits, TestPlayer, { Horizontal = math.huge }),
	"Movement limits must be finite"
)
Server.Security.SetMovementLimits(TestPlayer, nil)
assert(MoveAndSample(120).ConsecutiveBreaches == 1, "Sitting without an occupied seat must still be scored")
Humanoid.SeatPart = { Occupant = Humanoid }
assert(MoveAndSample(180).ConsecutiveBreaches == 0, "An occupied seat must exempt vehicle movement")
Humanoid.SeatPart = nil
Server.Configure({
	CharacterIntegrityWindowSeconds = 0.5,
	CharacterIntegrityDistanceSlack = 8,
	CharacterIntegrityMaxHorizontalSpeed = 32,
	CharacterIntegritySpeedMultiplier = 1,
	CharacterIntegrityMode = "Correct",
	CharacterIntegrityCorrectionScore = 1,
})
assert(Server.Security.ReconcileCharacter(TestPlayer, true), "The starting character sample must be valid")
for X = 190, 210, 10 do
	assert(MoveAndSample(X).ConsecutiveBreaches == 0, "Individual samples should fit within the burst allowance")
end
local Evidence = MoveAndSample(220)
assert(
	Evidence.LastReason == "SustainedHorizontalDisplacement" and Evidence.LastAction == "correct",
	"Sustained excess must reach the configured correction action"
)
assert(Root.Position.X == 180, "Correction must use the last completed safe window")
Server.Configure({ CharacterIntegrityMode = "Observe" })
Now += 3
assert(Server.Security.ReconcileCharacter(TestPlayer, true), "Reconciliation must establish the new movement baseline")
for X = 184, 196, 4 do
	assert(MoveAndSample(X).Score == 0, "Allowed movement across the full window should be accepted")
end
MoveAndSample(206)
MoveAndSample(216)
Server.Security.GrantMovementGrace(TestPlayer, 0.5)
MoveAndSample(400)
Now += 0.5
assert(MoveAndSample(404).Score == 0, "Grace must discard the partial movement window")
TestPlayer.Character = nil
local Grace = Server.Security.CharacterIntegrity(TestPlayer).GraceUntil
assert(
	not Server.Security.TeleportCharacter(TestPlayer, roblox.CFrame.new(), 50),
	"Teleport must fail without a character"
)
assert(
	Server.Security.CharacterIntegrity(TestPlayer).GraceUntil == Grace,
	"A failed teleport must preserve the grace deadline"
)

--> CFrame<Position, Rotation>: whole-number position, half-float rotation.
do
	stdio.write(`{stdio.color("cyan")}Testing: CFrame<i16, f16>...{stdio.color("reset")}`)
	local Api = (Cheeto :: any).ECFrameMixed
	local Value = roblox.CFrame.new(10, 20, -30) * roblox.CFrame.fromOrientation(0.5, 1.25, -0.75)
	local Result = Api.Read(Api.Write(Value))
	if Result.Position ~= Value.Position then
		ErrorPrint(`CFrame<i16, f16> position changed: {Result.Position}`)
	end
	local X, Y, Z = Value:ToOrientation()
	local RX, RY, RZ = Result:ToOrientation()
	if math.abs(X - RX) > 0.01 or math.abs(Y - RY) > 0.01 or math.abs(Z - RZ) > 0.01 then
		ErrorPrint(`CFrame<i16, f16> lost its rotation: {RX}, {RY}, {RZ}`)
	end
	OkPrint(`Datatype "CFrame<i16, f16>" passed!`)
end

--> Integers that do not fit raise instead of wrapping (300 used to arrive as 44).
do
	stdio.write(`{stdio.color("cyan")}Testing: u8 range...{stdio.color("reset")}`)
	local Api = (Cheeto :: any).EByte
	if Api.Read(Api.Write(255)) ~= 255 then
		ErrorPrint("u8 255 did not roundtrip")
	end
	if pcall(Api.Write, 300) then
		ErrorPrint("u8 accepted 300")
	end
	if pcall(Api.Write, -1) then
		ErrorPrint("u8 accepted -1")
	end
	OkPrint(`Datatype "u8 range" passed!`)
end

stdio.write(`{stdio.color("green")}All datatype roundtrips passed!{stdio.color("reset")}\n`)

return true
