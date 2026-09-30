--!strict

--> Measures the generated code instead of estimating it: both modules are
--> loaded in Lune against stub remotes, every endpoint sends sample payloads,
--> and the bytes on the wire and the time to encode and decode are recorded.

local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local Generator = require("../../Generator")
local Parser = require("../../Parser")
local Wire = require("../../Generator/Wire")

export type Measurement = {
	Name: string,
	Kind: string,
	Direction: string,
	Bytes: number,
	EncodeMicroseconds: number,
	DecodeMicroseconds: number,
	Delivered: number,
	Sent: number,
	Skipped: string?,
	--> Drop reasons the receiver recorded while this endpoint ran.
	Dropped: string?,
}

local ITERATIONS = 256

--> Options that would start background work or reject synthetic traffic.
--> The benchmark measures serialization and the receive pipeline, not policy.
local OVERRIDES: { [string]: any } = {
	ManualReplication = true,
	EnableClientShield = false,
	EnableClientIntegrity = false,
	EnableCharacterIntegrity = false,
	EnableRemoteNameRotation = false,
	EnableRemoteDecoys = false,
	EnableProtocolHandshake = false,
	EnableMicroProfiler = false,
	EnableHoneypots = false,
	EnablePacketCapture = false,
	RequirePolicies = false,
	SyncValidation = false,
	WriteValidations = false,
	RateLimitPerSecond = 0,
	RateLimitBurst = 0,
}

local CLEARED_OPTIONS = { "RuntimeOutput", "RuntimeRequire", "RemoteScope", "FutureLibrary", "PromiseLibrary" }

local STRIPPED_FIELDS = {
	"Auth",
	"Policy",
	"PolicyGroup",
	"CooldownSeconds",
	"Idempotency",
	"Honeypot",
	"MaxDistance",
	"RequireOwnership",
	"RequireTeam",
	"RequireZone",
	"RequireMatch",
	"RequireInventoryOwnership",
	"RequireCharacterState",
	"RequireObjectHandle",
	"RequireServerKnownId",
	"RateLimitPerSecond",
	"RateLimitBurst",
	"MaxPacketBytes",
}

local Benchmark = {}

---- Sample values ----

local function Length(Range: any, Default: number): number
	if Range == nil then
		return Default
	end
	if Range.Min > 0 then
		return Range.Min
	end
	return math.min(Default, Range.Max)
end

local function NumberIn(Range: any, Default: number): number
	if Range == nil then
		return Default
	end
	return math.clamp(Default, Range.Min, Range.Max)
end

local ROBLOX_SAMPLES: { [string]: () -> any } = {
	vector = function()
		return roblox.Vector3.new(1, 2, 3)
	end,
	Vector3 = function()
		return roblox.Vector3.new(1, 2, 3)
	end,
	CFrame = function()
		return roblox.CFrame.new(1, 2, 3)
	end,
	Color3 = function()
		return roblox.Color3.fromRGB(10, 20, 30)
	end,
	Vector2 = function()
		return roblox.Vector2.new(1, 2)
	end,
	Vector2int16 = function()
		return roblox.Vector2int16.new(1, 2)
	end,
	Vector3int16 = function()
		return roblox.Vector3int16.new(1, 2, 3)
	end,
	UDim = function()
		return roblox.UDim.new(0.5, 4)
	end,
	UDim2 = function()
		return roblox.UDim2.new(0.5, 4, 0.5, 4)
	end,
	Rect = function()
		return roblox.Rect.new(0, 0, 4, 4)
	end,
	Ray = function()
		return roblox.Ray.new(roblox.Vector3.new(0, 0, 0), roblox.Vector3.new(0, 1, 0))
	end,
	NumberRange = function()
		return roblox.NumberRange.new(1, 2)
	end,
	Region3 = function()
		return roblox.Region3.new(roblox.Vector3.new(0, 0, 0), roblox.Vector3.new(2, 2, 2))
	end,
}

local function Sample(Node: any): (any, string?)
	local Value = Node.Value or {}
	local Kind = Node.Type
	if Kind == "Primitive" then
		local Primitive = Node.Tokens.Primitive.Value
		local Range = Value.Range
		if string.match(Primitive, "^[ui]%d+$") then
			return NumberIn(Range, 7), nil
		elseif string.match(Primitive, "^f%d+$") then
			return NumberIn(Range, 1.5), nil
		elseif Primitive == "boolean" then
			return true, nil
		elseif Primitive == "string" then
			return string.rep("a", Length(Range, 8)), nil
		elseif Primitive == "buffer" then
			return buffer.create(Length(Range, 8)), nil
		elseif Primitive == "unknown" then
			return 1, nil
		elseif Primitive == "Instance" then
			local Success, Object = pcall(roblox.Instance.new, Value.Class or "Folder")
			if Success then
				return Object, nil
			end
			return nil, `Instance({Value.Class})`
		elseif ROBLOX_SAMPLES[Primitive] then
			return ROBLOX_SAMPLES[Primitive](), nil
		end
		return nil, Primitive
	elseif Kind == "Optional" then
		return Sample(Value.Of)
	elseif Kind == "Array" then
		local Element, Missing = Sample(Value.Of)
		if Missing then
			return nil, Missing
		end
		local Result = {}
		for Index = 1, Length(Value.Range, 4) do
			Result[Index] = Element
		end
		return Result, nil
	elseif Kind == "Map" then
		local Key, MissingKey = Sample(Value.Values[1])
		local Element, MissingValue = Sample(Value.Values[2])
		if MissingKey or MissingValue then
			return nil, MissingKey or MissingValue
		end
		return { [Key] = Element }, nil
	elseif Kind == "Struct" then
		local Result = {}
		for _, Field in Value.Values do
			local FieldValue, Missing = Sample(Field)
			if Missing then
				return nil, Missing
			end
			Result[Field.Name] = FieldValue
		end
		return Result, nil
	elseif Kind == "Enum" then
		return Value.Values[1], nil
	elseif Kind == "Set" then
		local Result = {}
		for _, Flag in Value.Values do
			Result[Flag] = true
		end
		return Result, nil
	elseif Kind == "TagEnum" then
		local Variant = Value.Values[1]
		local Result, Missing = Sample(Variant)
		if Missing then
			return nil, Missing
		end
		Result[Value.Tag] = Variant.Name
		return Result, nil
	end
	return nil, Kind
end

--> Arguments for a payload, packed; a tuple is several arguments.
local function Arguments(Data: any): ({ n: number, [number]: any }?, string?)
	if Data == nil then
		return table.pack(nil), nil
	end
	if Data.Type == "Tuple" then
		local Values = { n = #Data.Value.Values }
		for Index, Child in Data.Value.Values do
			local Value, Missing = Sample(Child)
			if Missing then
				return nil, Missing
			end
			Values[Index] = Value
		end
		return Values :: any, nil
	end
	local Value, Missing = Sample(Data)
	if Missing then
		return nil, Missing
	end
	return table.pack(Value), nil
end

---- Harness ----

local function Signal()
	local Connections = {}
	return {
		Connections = Connections,
		Connect = function(_, Callback)
			table.insert(Connections, Callback)
			return {
				Disconnect = function()
					local Index = table.find(Connections, Callback)
					if Index then
						table.remove(Connections, Index)
					end
				end,
			}
		end,
	}
end

local function Environment(IsServer: boolean, Player: any, Outbox: { any })
	--> Roblox serializes remote arguments when they are fired, and the runtime
	--> reuses its instance list afterwards, so the stub takes copies.
	local function Capture(Buffer: buffer, Instances: any)
		local Copy = buffer.create(buffer.len(Buffer))
		buffer.copy(Copy, 0, Buffer)
		table.insert(Outbox, {
			Channel = "",
			Buffer = Copy,
			Instances = if type(Instances) == "table" then table.clone(Instances) else Instances,
		})
		return Outbox[#Outbox]
	end

	local function Remote(Channel: string)
		return {
			Name = Channel,
			OnServerEvent = Signal(),
			OnClientEvent = Signal(),
			FireServer = function(_, Buffer, Instances)
				Capture(Buffer, Instances).Channel = Channel
			end,
			FireClient = function(_, _Player, Buffer, Instances)
				Capture(Buffer, Instances).Channel = Channel
			end,
			FireAllClients = function(_, Buffer, Instances)
				Capture(Buffer, Instances).Channel = Channel
			end,
		}
	end

	local Remotes = {
		CHEETO_RELIABLE_REMOTE = Remote("Reliable"),
		CHEETO_UNRELIABLE_REMOTE = Remote("Unreliable"),
	}
	local Services = {
		Players = {
			LocalPlayer = Player,
			PlayerAdded = Signal(),
			PlayerRemoving = Signal(),
			GetPlayers = function()
				return { Player }
			end,
		},
		ReplicatedStorage = {
			FindFirstChild = function(_, Name)
				return Remotes[Name]
			end,
			WaitForChild = function(_, Name)
				return Remotes[Name]
			end,
		},
		RunService = {
			Heartbeat = Signal(),
			IsServer = function()
				return IsServer
			end,
			IsClient = function()
				return not IsServer
			end,
			IsRunning = function()
				return true
			end,
		},
		HttpService = {
			GenerateGUID = function()
				return "00000000000000000000000000000000"
			end,
		},
	}

	return {
		game = {
			GetService = function(_, Name)
				return Services[Name]
			end,
		},
		_G = {},
		task = task,
		warn = function() end,
		print = function() end,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		Vector2int16 = roblox.Vector2int16,
		Vector3int16 = roblox.Vector3int16,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Rect = roblox.Rect,
		Ray = roblox.Ray,
		NumberRange = roblox.NumberRange,
		Region3 = roblox.Region3,
		Instance = roblox.Instance,
		Enum = roblox.Enum,
		require = function()
			error("require is not available in the benchmark")
		end,
	},
		Remotes
end

local function Load(Source: string, Name: string, Env: any): any
	local Bytecode = luau.compile(Source, { optimizationLevel = 2 })
	return luau.load(Bytecode, { debugName = Name, environment = Env })()
end

local function Resolve(Module: any, Path: string): any
	local Current = Module
	for _, Part in string.split(Path, ".") do
		Current = Current and Current[Part]
	end
	return Current
end

local function Deliver(Packets: { any }, Remotes: any, Player: any?)
	for _, Packet in Packets do
		local Remote = if Packet.Channel == "Reliable"
			then Remotes.CHEETO_RELIABLE_REMOTE
			else Remotes.CHEETO_UNRELIABLE_REMOTE
		local Signal = if Player ~= nil then Remote.OnServerEvent else Remote.OnClientEvent
		for _, Callback in Signal.Connections do
			if Player ~= nil then
				Callback(Player, Packet.Buffer, Packet.Instances)
			else
				Callback(Packet.Buffer, Packet.Instances)
			end
		end
	end
end

local function Prepare(Ast: Parser.Body)
	local Options = Ast.Value.Options :: any
	for Key, Value in OVERRIDES do
		Options[Key] = Value
	end
	for _, Key in CLEARED_OPTIONS do
		Options[Key] = nil
	end
	for _, Endpoint in Wire.Endpoints(Ast.Value.Declarations) do
		local Value = Endpoint.Declaration.Value :: any
		for _, Field in STRIPPED_FIELDS do
			Value[Field] = nil
		end
		if Value.Yield == "Future" or Value.Yield == "Promise" then
			Value.Yield = "Coroutine"
		end
	end
end

--> Runs every endpoint of the schema and returns one measurement each.
function Benchmark.Measure(Ast: Parser.Body): { Measurement }
	Prepare(Ast)
	local ServerSource = Generator.Generate("Server", Ast)
	local ClientSource = Generator.Generate("Client", Ast)

	local Player = { Name = "Benchmark", UserId = 1, Parent = {}, Kick = function() end }
	local ToClient, ToServer = {}, {}
	local ServerEnv, ServerRemotes = Environment(true, Player, ToClient)
	local ClientEnv, ClientRemotes = Environment(false, Player, ToServer)
	local Server = Load(ServerSource, "BenchmarkServer", ServerEnv)
	local Client = Load(ClientSource, "BenchmarkClient", ClientEnv)
	for _, Module in { Server, Client } do
		Module.Configure({
			MaxReliablePacketBytes = 0,
			ReliableFragmentBytes = 0,
			MaxQueuedBytes = 0,
			MaxDecodeOperations = 1e9,
			MaxPendingInvokes = 0,
			--> Flush on every step; pacing would carry one endpoint into the next.
			MaxBurstBytes = 1,
		})
	end

	local Results: { Measurement } = {}
	local function Record(Name: string, Kind: string, Direction: string, Skipped: string?)
		local Entry: Measurement = {
			Name = Name,
			Kind = Kind,
			Direction = Direction,
			Bytes = 0,
			EncodeMicroseconds = 0,
			DecodeMicroseconds = 0,
			Delivered = 0,
			Sent = 0,
			Skipped = Skipped,
		}
		table.insert(Results, Entry)
		return Entry
	end

	local function Run(Entry: Measurement, Send: () -> (), Flush: () -> (), Outbox: { any }, Remotes: any, From: any?)
		table.clear(Outbox)
		local Start = os.clock()
		for _ = 1, ITERATIONS do
			Send()
		end
		Flush()
		local Encoded = os.clock() - Start
		local Packets = table.clone(Outbox)
		table.clear(Outbox)

		local Bytes = 0
		for _, Packet in Packets do
			Bytes += buffer.len(Packet.Buffer)
		end

		local Receiver = if From ~= nil then Server else Client
		local Before = table.clone(Receiver.Stats().DroppedPackets)
		Start = os.clock()
		Deliver(Packets, Remotes, From)
		local Decoded = os.clock() - Start
		local Reasons = {}
		for Reason, Count in Receiver.Stats().DroppedPackets do
			local New = Count - (Before[Reason] or 0)
			if New > 0 then
				table.insert(Reasons, `{Reason} x{New}`)
			end
		end
		Entry.Dropped = if #Reasons > 0 then table.concat(Reasons, ", ") else nil

		Entry.Sent = ITERATIONS
		Entry.Bytes = Bytes / ITERATIONS
		Entry.EncodeMicroseconds = Encoded / ITERATIONS * 1e6
		Entry.DecodeMicroseconds = Decoded / ITERATIONS * 1e6
	end

	for _, Endpoint in Wire.Endpoints(Ast.Value.Declarations) do
		local Declaration = Endpoint.Declaration :: any
		local Value = Declaration.Value
		local Kind = Declaration.Type
		local Args, Missing = Arguments(Value.Data)
		if Kind == "Event" then
			local Direction = if Value.From == "Server" then "server → client" else "client → server"
			local Entry = Record(Endpoint.Name, Kind, Direction, if Missing then `no sample for {Missing}` else nil)
			if Missing then
				continue
			end
			local Latest = Value.CoalesceKey ~= nil or Value.ReliabilityMode == "Latest"
			local Polling = Value.Call == "Polling" or Ast.Value.Options.UsePolling
			if Value.From == "Server" then
				local Api, Receiver = Resolve(Server, Endpoint.Name), Resolve(Client, Endpoint.Name)
				local Release = if Polling
					then nil
					else Receiver.On(function()
						Entry.Delivered += 1
					end)
				Run(Entry, function()
					Api.FireAll(table.unpack(Args :: any, 1, (Args :: any).n))
					if Latest then
						Server.StepReplication()
					end
				end, Server.StepReplication, ToClient, ClientRemotes, nil)
				if Polling then
					for _ in Receiver.Iter() do
						Entry.Delivered += 1
					end
				elseif Release then
					Release()
				end
			else
				local Api, Receiver = Resolve(Client, Endpoint.Name), Resolve(Server, Endpoint.Name)
				local Release = if Polling
					then nil
					else Receiver.On(function()
						Entry.Delivered += 1
					end)
				Run(Entry, function()
					Api.Fire(table.unpack(Args :: any, 1, (Args :: any).n))
					if Latest then
						Client.StepReplication()
					end
				end, Client.StepReplication, ToServer, ServerRemotes, Player)
				if Polling then
					for _ in Receiver.Iter() do
						Entry.Delivered += 1
					end
				elseif Release then
					Release()
				end
			end
		elseif Kind == "Function" then
			local Entry =
				Record(Endpoint.Name, Kind, "client → server", if Missing then `no sample for {Missing}` else nil)
			if Missing then
				continue
			end
			local Api, Receiver = Resolve(Client, Endpoint.Name), Resolve(Server, Endpoint.Name)
			local Returned = if Value.Return then (Arguments(Value.Return)) else nil
			local Release = Receiver.On(function()
				Entry.Delivered += 1
				if Returned then
					return table.unpack(Returned :: any, 1, (Returned :: any).n)
				end
				return nil
			end)
			--> Invokes park until answered; 200 fit inside the one-byte id space.
			local Previous = ITERATIONS
			ITERATIONS = 200
			Run(Entry, function()
				task.spawn(pcall, Api.Invoke, table.unpack(Args :: any, 1, (Args :: any).n))
			end, Client.StepReplication, ToServer, ServerRemotes, Player)
			ITERATIONS = Previous
			Client.CancelInvocations("benchmark finished")
			Server.StepReplication()
			table.clear(ToClient)
			if typeof(Release) == "function" then
				Release()
			end
		elseif Kind == "Channel" then
			local Entry =
				Record(Endpoint.Name, Kind, "server → client", if Missing then `no sample for {Missing}` else nil)
			if Missing then
				continue
			end
			local Api, Receiver = Resolve(Server, Endpoint.Name), Resolve(Client, Endpoint.Name)
			local Release = Receiver.On(function()
				Entry.Delivered += 1
			end)
			Run(Entry, function()
				Api.SetPlayer(Player, (Args :: any)[1])
				Api.FlushPlayer(Player, true)
			end, Server.StepReplication, ToClient, ClientRemotes, nil)
			Release()
		end
	end

	return Results
end

return Benchmark
