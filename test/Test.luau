local Format = require("../src/Modules/Format")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

--> A silent stall used to be indistinguishable from slow work, because the
--> Heartbeat driver in Shared.luau is a `while true` loop that keeps Lune alive
--> forever once the main thread is gone. This turns that into a hard failure with
--> the thread's state attached. Generous on purpose: a passing run is ~14s.
local MainThread = coroutine.running()
task.delay(120, function()
	stdio.write(`\n[{stdio.color("red")}TIMEOUT{stdio.color("reset")}] suite stalled for 120s\n`)
	stdio.write(`main thread status: {coroutine.status(MainThread)}\n`)
	if coroutine.status(MainThread) == "dead" then
		stdio.write("The main thread was killed or finished early -- see TESTING.md.\n")
	end
	process.exit(19)
end)

local Compiler = "init"
local Sources = fs.readDir("./Sources")
--> Compile in a deterministic order; fs.readDir ordering is platform dependent
--> (NTFS sorts, ext4 does not), which otherwise makes builds non-reproducible.
table.sort(Sources)

local COMPILE_TEST_FILE = "../../test/Sources/Test"
local CI_MODE = table.find(process.args, "--ci") ~= nil
local FORCE_COMPILE = table.find(process.args, "--compile") ~= nil
local SKIP_COMPILE = table.find(process.args, "--no-compile") ~= nil

local function OkPrint(Message: string)
	stdio.write(`\r[{stdio.color("green")}OK{stdio.color("reset")}] {Message}\n`)
end

local function ErrorPrint(Message: string)
	stdio.write(`\r[{stdio.color("red")}ERROR{stdio.color("reset")}] {Message}\n`)
	process.exit(20)
end

local function PrettyPrint(Color: stdio.Color, Message: string, DontReturn: boolean?)
	stdio.write(`{stdio.color(Color)}{Message}{not DontReturn and "\n" or ""}{stdio.color("reset")}`)
end

if CI_MODE or FORCE_COMPILE or (not SKIP_COMPILE and stdio.prompt("confirm" :: "confirm", "Compile files?")) then
	PrettyPrint("blue", "Clearing Network folder...")
	if fs.isDir("../Network") then
		fs.removeDir("../Network")
		fs.writeDir("../Network")
		OkPrint(`Cleared Network folder.`)
	end

	PrettyPrint("blue", "Compiling source files...")
	for _, File in Sources do
		local Metadata = fs.metadata(`./Sources/{File}`)
		if Metadata.kind ~= "file" then
			continue
		end
		if not string.match(File, "%.cheeto$") then
			continue
		end
		if string.find(File, "Bad", 1, true) then
			continue
		end
		if File == "HardeningGood.cheeto" then
			continue
		end

		local Path = `../../test/Sources/{File}`
		PrettyPrint("cyan", `Compiling: {File}...`, true)
		local Result = process.exec("lune", { "run", Compiler, Path, "--", "--yes" }, { cwd = "../src/CLI" })
		if not Result.ok then
			ErrorPrint(`{File} failed to compile!\n{Result.stderr}`)
		else
			OkPrint(`{File} compiled successfully.`)
		end
	end

	PrettyPrint("green", `Successfully compiled {#Sources}/{#Sources} source files!`)
end

local Shared = require("./Shared")
local BaseEnvironment = Shared.GetEnvironment()
local ClientEnvironment = require("./Client")
local ServerEnvironment = require("./Server")

local function MockTypeof(a: any)
	local TypeofA = typeof(a)
	if TypeofA == "table" and a.__typeof then
		return a.__typeof
	end

	return TypeofA
end

local CapturedWarnings: { string } = {}

local function CaptureWarn(...)
	local Parts = {}
	for Index = 1, select("#", ...) do
		Parts[Index] = tostring((select(Index, ...)))
	end

	local Message = table.concat(Parts, " ")
	table.insert(CapturedWarnings, Message)
	warn(Message)
end

local function FindWarning(Fragment: string): string?
	for _, Message in CapturedWarnings do
		if string.find(Message, Fragment, 1, true) then
			return Message
		end
	end
	return nil
end

local function MockRequire(Path: string, Environment)
	local Source = fs.readFile(Path)
	local Bytecode = luau.compile(Source, {
		optimizationLevel = 1,
		debugLevel = 2,
	})

	Environment._G = {}
	Environment.task = task
	Environment.typeof = MockTypeof
	Environment.require = function()
		error("require is not supported")
	end
	--> Some runtime diagnostics have no observable effect other than the warning
	--> they print (SyncValidation's "Yielded in a Sync call" is one), so capturing
	--> warn is the only way to assert they still fire.
	Environment.warn = CaptureWarn

	local Execute = luau.load(Bytecode, {
		debugName = Path,
		environment = Environment,
	})

	return Execute()
end

local Client: typeof(require("../Network/Client")) = MockRequire("../Network/Client.luau", {
	game = ClientEnvironment.game,
	Color3 = ClientEnvironment.Color3,
	DateTime = ClientEnvironment.DateTime,
	BrickColor = ClientEnvironment.BrickColor,
})

local Server: typeof(require("../Network/Server")) = MockRequire("../Network/Server.luau", {
	game = ServerEnvironment.game,
	Color3 = ServerEnvironment.Color3,
	DateTime = ServerEnvironment.DateTime,
	BrickColor = ServerEnvironment.BrickColor,
})

--> Helper functions
local function GetFlags(Amount: number): { [string]: boolean }
	local Flags = {}
	for Index = 1, Amount do
		Flags[`F{Index}`] = (math.random(1, 2) == 2)
	end
	return Flags
end

local function Fail(Name: string, Expect: any, Got: any)
	ErrorPrint(`Failed "{Name}"\nExpected: {Format(Expect)}\nGot: {Format(Got)}.`)
end

local function Equals(a: any, b: any)
	local Cyclic = {}
	local function Compare(a: any, b: any)
		local TypeA = type(a)
		local TypeB = type(b)

		if TypeA ~= TypeB then
			return false
		end

		if TypeA == "table" then
			if Cyclic[a] then
				return Cyclic[a] == b
			end

			Cyclic[a] = b

			local KeysB = {}
			local TableKeysB = {}

			for Key in b do
				if type(Key) == "table" then
					table.insert(TableKeysB, Key)
				end

				KeysB[Key] = true
			end

			for KeyA, ValueA in pairs(a) do
				local ValueB = b[KeyA]
				if type(KeyA) == "table" then
					local Match = false
					for Index, Key in TableKeysB do
						if Equals(KeyA, Key) and Compare(ValueA, b[Key]) then
							Match = true
							KeysB[Key] = nil
							table.remove(TableKeysB, Index)
							break
						end
					end

					if Match == false then
						return false
					end
				else
					if ValueB == nil then
						return false
					end

					KeysB[KeyA] = nil

					if not Compare(ValueA, ValueB) then
						return false
					end
				end
			end

			if next(KeysB) then
				return false
			end

			return true
		elseif TypeA == "buffer" then
			return buffer.tostring(a) == buffer.tostring(b)
		end

		return a == b
	end

	return Compare(a, b)
end

local function FireAndFail(Name: string, OutgoingEvent: any, IncomingEvent: any, Data: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	local Disconnect = IncomingEvent.On(function(First, Second)
		Result = if Second ~= nil then Second else First
	end)

	local Success = pcall(function()
		if OutgoingEvent.FireAll then
			OutgoingEvent.FireAll(Data)
		else
			OutgoingEvent.Fire(Data)
		end
	end)

	if not Success then
		OkPrint(`Event "{Name}" passed!`)
		return
	end

	--> Wait for replication
	task.wait(1 / 30)

	if Result ~= nil then
		ErrorPrint(`Failed "{Name}", expected it to fail, got "{Result}" instead.`)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpect(Name: string, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)

	local Disconnect = IncomingEvent.On(function(First, Second)
		if IsServerRecieving then
			if tostring(First) ~= "Player" then
				ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
			end

			Result = Second
		else
			Result = First
		end
	end)

	if IsServerSending then
		OutgoingEvent.FireAll(Expect)
	else
		OutgoingEvent.Fire(Expect)
	end

	--> Wait for replication
	task.wait(1 / 30)

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function InvokeAndExpect(
	Name: string,
	ClientFunction: any,
	ServerFunction: any,
	Data: any,
	Return: boolean?,
	YieldFor: number?
)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local ServerRecieve: unknown
	ServerFunction.On(function(Player, Recieve: any)
		if tostring(Player) ~= "Player" then
			ErrorPrint(`Expected argument #1 to {Name} to be Player, got {Player} instead.`)
		end

		ServerRecieve = Recieve
		if not Return then
			error("Expects fail")
		end

		if YieldFor then
			task.wait(YieldFor)
		end

		return Recieve
	end)

	local Success, Result = pcall(function()
		return ClientFunction.Invoke(Data)
	end)

	if not Return and Success then
		ErrorPrint(`Expected {Name} to encounter an error but it succeeded.`)
	elseif not Success and Return then
		ErrorPrint(`Expected {Name} to succeed but it encountered an error, {Result}.`)
	elseif Success and Return then
		if ServerRecieve ~= Data then
			ErrorPrint(`Expected server {Name} to recieve {Data}, got {ServerRecieve} instead.`)
		end

		if not Equals(Result, Data) then
			ErrorPrint(`Expected client {Name} to recieve {Data}, got {Result} instead.`)
		end
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function QueueAndExpect(Name: string, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	if OutgoingEvent.FireAll then
		OutgoingEvent.FireAll(Expect)
	else
		OutgoingEvent.Fire(Expect)
	end

	--> Let it sit in queue
	task.wait(0.5)

	local Disconnect = IncomingEvent.On(function(First, Second)
		Result = if Second ~= nil then Second else First
	end)

	--> Wait for queue to empty
	task.wait(1 / 30)

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpectAll(Name: string, OutgoingEvent: any, IncomingEvent: any, Values: { any })
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Events = 0
	local Results: { unknown } = {}
	local Disconnect = IncomingEvent.On(function(First, Second)
		local Value = (if Second ~= nil then Second else First)

		Events += 1
		Results[Events] = Value
	end)

	local Method = OutgoingEvent.FireAll or OutgoingEvent.Fire
	for Index = 1, table.maxn(Values) do
		Method(Values[Index])
	end

	--> Wait for replication
	task.wait(1 / 30)

	for Index, Expect in Values do
		local Result = Results[Index]
		if not Equals(Expect, Result) then
			Fail(Name, Expect, Result)
		end
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function FireAllAndExpectAll(
	Name: string,
	Times: number,
	Events: { [string]: { Outgoing: any, Incoming: any, Data: { any } } }
)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Results: { { unknown } } = {}
	local Disconnects: { () -> () } = {}

	--> Connect to events
	for Index, Event in Events do
		local EventResults = {}
		Results[Index] = EventResults
		table.insert(
			Disconnects,
			Event.Incoming.On(function(...)
				table.insert(EventResults, { ... })
			end)
		)
	end

	--> Fire events
	for Index, Event in Events do
		local Outgoing = Event.Outgoing
		local Method = Outgoing.FireAll or Outgoing.Fire
		for Index = 1, Times do
			Method(table.unpack(Event.Data))
		end
	end

	--> Wait for replication
	task.wait(1 / 30)

	for Index, Event in Events do
		local Data = Event.Data
		local EventResults = Results[Index]
		for ResultIndex = 1, Times do
			local Result = EventResults[ResultIndex]
			if not Equals(Data, Result) then
				ErrorPrint(`Failed "{Name}" at {Index}, mismatched value at {ResultIndex}.`)
			end
		end
	end

	for _, Disconnect in Disconnects do
		Disconnect()
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpectTuple(Name: string, OutgoingEvent: any, IncomingEvent: any, ...: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Results: { unknown } = {}
	local Disconnect = IncomingEvent.On(function(...)
		Results = { ... }
	end)

	local Method = OutgoingEvent.FireAll or OutgoingEvent.Fire
	Method(...)

	--> Wait for replication
	task.wait(1 / 30)

	for Index, Expect in { ... } do
		local Result = Results[Index]
		if not Equals(Expect, Result) then
			ErrorPrint(`Failed "{Name}", mismatched value at {Index}. Expected {Expect}, got {Result} instead.`)
		end
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function InvokeAndExpectTuple(
	Name: string,
	ClientFunction: any,
	ServerFunction: any,
	Data: { any },
	Return: { any }
)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local ServerRecieve: { unknown }
	ServerFunction.On(function(Player, ...)
		if tostring(Player) ~= "Player" then
			ErrorPrint(`Expected argument #1 to {Name} to be Player, got {Player} instead.`)
		end

		ServerRecieve = { ... }
		return table.unpack(Return)
	end)

	local ClientRecieve: { unknown }
	local Success, Error = pcall(function()
		ClientRecieve = { ClientFunction.Invoke(table.unpack(Data)) }
	end)

	if not Success then
		ErrorPrint(`Expected {Name} to succeed but it encountered an error, {Error}.`)
	elseif Success and Return then
		if not Equals(ServerRecieve, Data) then
			ErrorPrint(`Expected server {Name} to recieve {Data}, got {ServerRecieve} instead.`)
		end

		if not Equals(ClientRecieve, Return) then
			ErrorPrint(`Expected client {Name} to recieve {Data}, got {ClientRecieve} instead.`)
		end
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireManyAndExpectMany(Name: string, Count: number, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Results: { unknown } = {}
	local Disconnects: { () -> () } = {}

	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)

	for _ = 1, Count do
		table.insert(
			Disconnects,
			IncomingEvent.On(function(First, Second)
				local Value: unknown
				if IsServerRecieving then
					if tostring(First) ~= "Player" then
						ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
					end

					Value = Second
				else
					Value = First
				end

				table.insert(Results, Value)
			end)
		)
	end

	if IsServerSending then
		OutgoingEvent.FireAll(Expect)
	else
		OutgoingEvent.Fire(Expect)
	end

	--> Wait for replication
	task.wait(1 / 30)

	if #Results ~= Count then
		ErrorPrint(`Failed "{Name}", expected to recieve {Count} events, got {#Results} instead.`)
	end

	for _, Result in Results do
		if not Equals(Result, Expect) then
			Fail(Name, Expect, Result)
		end
	end

	for _, Disconnect in Disconnects do
		Disconnect()
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndPollExpect(Name: string, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result = "this is wrong"
	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)
	local FireEvent = IsServerSending and OutgoingEvent.FireAll or OutgoingEvent.Fire

	FireEvent(Expect)

	--> Wait for replication
	task.wait(1 / 30)

	for Index, First, Second in IncomingEvent.Iter() do
		if Index ~= 1 then
			ErrorPrint(`Failed "{Name}", expected only 1 event in the queue.`)
		end

		if IsServerRecieving then
			if tostring(First) ~= "Player" then
				ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
			end

			Result = Second
		else
			Result = First
		end
	end

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpectSeparate(Name: string, OutgoingEvent: any, IncomingEvent: any, Value: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)

	local Disconnect = IncomingEvent.On(function(First, Second)
		if IsServerRecieving then
			if tostring(First) ~= "Player" then
				ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
			end

			Result = Second
		else
			Result = First
		end
	end)

	if IsServerSending then
		OutgoingEvent.FireAll(Value)
	else
		OutgoingEvent.Fire(Value)
	end

	--> Wait for replication
	task.wait(1 / 30)

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function RunClosure(Name: string, Closure: () -> ())
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Trace: string?
	local Success = xpcall(Closure, function(Error)
		Trace = debug.traceback(`Failed "{Name}": {Error}`, 2)
	end)

	if not Success then
		ErrorPrint(Trace or `Failed "{Name}"`)
	end

	OkPrint(`Test "{Name}" passed!`)

	-- cleanup
	if Name == "Fuzz malformed packets" then
		return
	end

	pcall(function()
		Client.StepReplication()
		Server.StepReplication()
	end)
end

local function FireSignalSync(Signal, ...)
	for _, Callback in Signal.Connections do
		local Success, Error = pcall(Callback, ...)
		if not Success then
			ErrorPrint(`Malformed packet handler threw: {Error}`)
		end
	end
end

local function CloneBuffer(Source: buffer): buffer
	local Size = buffer.len(Source)
	local Target = buffer.create(Size)
	buffer.copy(Target, 0, Source, 0, Size)
	return Target
end

local function InstallScopedRemote(RemoteName: string)
	ClientEnvironment.Instances[RemoteName] = {
		FireServer = function(_self, Buffer, Instances)
			Shared.Bridge:Fire(
				"Client",
				RemoteName,
				CloneBuffer(Buffer),
				if typeof(Instances) == "table" then table.clone(Instances) else {}
			)
		end,
		OnClientEvent = Shared.Signal.new(),
	}

	ServerEnvironment.Instances[RemoteName] = {
		FireClient = function(_self, _Player, Buffer, Instances)
			Shared.Bridge:Fire(
				"Server",
				RemoteName,
				CloneBuffer(Buffer),
				if typeof(Instances) == "table" then table.clone(Instances) else {}
			)
		end,
		FireAllClients = function(_self, Buffer, Instances)
			Shared.Bridge:Fire(
				"Server",
				RemoteName,
				CloneBuffer(Buffer),
				if typeof(Instances) == "table" then table.clone(Instances) else {}
			)
		end,
		OnServerEvent = Shared.Signal.new(),
	}
end

local function InstallRemoteScope(Scope: string)
	InstallScopedRemote(`{Scope}_CHEETO_RELIABLE_REMOTE`)
	InstallScopedRemote(`{Scope}_CHEETO_UNRELIABLE_REMOTE`)
end

local function RandomBuffer(Size: number): buffer
	local Buffer = buffer.create(Size)
	for Offset = 0, Size - 1 do
		buffer.writeu8(Buffer, Offset, math.random(0, 255))
	end

	return Buffer
end

local BufferBytes: (buffer) -> { number }

local function ExpectBytes(Name: string, Buffer: buffer, Expected: { number })
	if buffer.len(Buffer) ~= #Expected then
		ErrorPrint(
			`Golden snapshot "{Name}" expected {#Expected} bytes, got {buffer.len(Buffer)}: {Format(BufferBytes(Buffer))}.`
		)
	end

	for Offset = 0, #Expected - 1 do
		local Got = buffer.readu8(Buffer, Offset)
		local Expect = Expected[Offset + 1]
		if Got ~= Expect then
			ErrorPrint(
				`Golden snapshot "{Name}" byte {Offset} expected {Expect}, got {Got}. Full bytes: {Format(
					BufferBytes(Buffer)
				)}.`
			)
		end
	end
end

function BufferBytes(Buffer: buffer): { number }
	local Bytes = {}
	for Offset = 0, buffer.len(Buffer) - 1 do
		table.insert(Bytes, buffer.readu8(Buffer, Offset))
	end
	return Bytes
end

local function FindCaptureBuffer(Entries: { any }, Name: string, Direction: string, Status: string?): buffer
	local Seen = {}
	for _, Entry in Entries do
		table.insert(Seen, `{tostring(Entry.Name)}:{tostring(Entry.Direction)}:{tostring(Entry.Status)}`)
		if Entry.Name == Name and Entry.Direction == Direction and (Status == nil or Entry.Status == Status) then
			assert(typeof(Entry.Buffer) == "buffer", `Expected capture entry {Name}/{Direction} to include raw buffer.`)
			return Entry.Buffer
		end
	end

	error(`Expected capture entry {Name}/{Direction}. Saw: {table.concat(Seen, ", ")}`)
end

local function DroppedTotal(Module): number
	local Metrics = Module.Stats()
	local DroppedPackets = Metrics.DroppedPackets or {}
	local Total = 0
	for _, Count in DroppedPackets do
		Total += Count
	end

	return Total
end

--> Tests
local Instance = setmetatable({
	__typeof = "Instance",
	IsA = function(self)
		return true
	end,
}, {
	__tostring = function()
		return "Instance"
	end,
})

local InstanceNeverIsA = setmetatable({
	__typeof = "Instance",
	ClassName = "Never",
	IsA = function(self)
		return false
	end,
}, {
	__tostring = function()
		return "Instance (Invalid)"
	end,
})

local Example: Client.Example = {
	Field = 0,
	Float16Field = 0,
	Enum = "A",
	Nested = {
		Guh = 1,
		Array = table.create(10, 0),
	},
}

PrettyPrint("blue", "Running output tests...")

--> Policies fail closed: a name nobody registered drops every packet on the
--> endpoint. Test.cheeto uses "damage", so register it the way a game would.
local function AllowDamage()
	return true
end
Server.Security.RegisterPolicy("damage", AllowDamage)

FireAndExpect("Reliable Server", Server.ReliableServer, Client.ReliableServer, 1)
FireAndExpect("Unreliable Server", Server.UnreliableServer, Client.UnreliableServer, 1)
FireAndExpect("Empty Reliable Server", Server.EmptyEvent, Client.EmptyEvent, nil)
FireAndExpect("Empty Unreliable Server", Server.EmptyUnreliableEvent, Client.EmptyUnreliableEvent, nil)

RunClosure("State Channel Snapshot And Patch", function()
	local Updates = {}
	local Disconnect = Client.PlayerState.On(function(Value, Version, Patch)
		table.insert(Updates, {
			Value = Value,
			Version = Version,
			Patch = Patch,
		})
	end)

	Server.PlayerState.SetAll({
		Health = 100,
		Stamina = 80,
		Equipped = "Sword",
	})
	task.wait(1 / 10)

	local Snapshot = Client.PlayerState.Get()
	assert(Snapshot, "Expected PlayerState snapshot")
	assert(Snapshot.Health == 100, `Expected Health 100, got {Snapshot.Health}`)
	assert(Snapshot.Stamina == 80, `Expected Stamina 80, got {Snapshot.Stamina}`)
	assert(Snapshot.Equipped == "Sword", `Expected Equipped Sword, got {Snapshot.Equipped}`)
	assert(Client.PlayerState.Version() == 1, `Expected version 1, got {Client.PlayerState.Version()}`)

	Server.PlayerState.PatchAll({
		Stamina = 50,
	})
	task.wait(1 / 10)

	Snapshot = Client.PlayerState.Get()
	assert(Snapshot, "Expected PlayerState snapshot after patch")
	assert(Snapshot.Health == 100, `Expected Health 100 after patch, got {Snapshot.Health}`)
	assert(Snapshot.Stamina == 50, `Expected Stamina 50 after patch, got {Snapshot.Stamina}`)
	assert(Client.PlayerState.Version() == 2, `Expected version 2, got {Client.PlayerState.Version()}`)
	assert(#Updates == 2, `Expected 2 channel updates, got {#Updates}`)
	assert(Updates[2].Patch.Stamina == 50, "Expected patch payload to include Stamina")

	Disconnect()
end)

RunClosure("Controller Connection Routes And State", function()
	local SentTarget
	local SentValue
	local RouteListener
	local RouteDisconnected = false
	local StateListener
	local StateDisconnected = false
	local Target = { Name = "Player" }
	local Snapshot = { Visible = true, Title = "Ready" }

	local Connection = Client.Connection.new({
		Target = Target,
		Routes = {
			ControllerMessage = {
				Fire = function(RouteTarget, Value)
					SentTarget = RouteTarget
					SentValue = Value
				end,
				On = function(Listener)
					RouteListener = Listener
					return function()
						RouteDisconnected = true
						RouteListener = nil
					end
				end,
			},
		},
		State = {
			UI = {
				Get = function(RouteTarget)
					assert(RouteTarget == Target, "Expected state read to use the connection target.")
					return Snapshot
				end,
				Version = function()
					return 7
				end,
				On = function(Listener)
					StateListener = Listener
					return function()
						StateDisconnected = true
						StateListener = nil
					end
				end,
			},
		},
	})

	Connection:Send("ControllerMessage", "refresh")
	assert(SentTarget == Target, "Expected connection target to be prepended to sends.")
	assert(SentValue == "refresh", "Expected connection payload to reach the Cheeto route.")

	local Received
	Connection:On("ControllerMessage", function(Value)
		Received = Value
	end)
	RouteListener("update")
	assert(Received == "update", "Expected route listener to receive messages.")

	local StateValue
	local StateVersion
	Connection:OnState("UI", function(Value, Version)
		StateValue = Value
		StateVersion = Version
	end, true)
	assert(StateValue == Snapshot and StateVersion == 7, "Expected immediate state delivery.")
	assert(Connection:GetState("UI") == Snapshot, "Expected state reads through the connection.")

	Connection:Disconnect()
	assert(not Connection:IsConnected(), "Expected the connection to report disconnected.")
	assert(RouteDisconnected and StateDisconnected, "Expected connection cleanup to release every listener.")
	assert(RouteListener == nil and StateListener == nil, "Expected listener references to be released.")
	assert(not pcall(function()
		Connection:Send("ControllerMessage", "ignored")
	end), "Expected sends after disconnect to fail.")
end)

RunClosure("Controller Connection State Writes", function()
	local Calls = {}
	local Target = { Name = "Player" }

	local function Channel()
		return {
			Set = function(...)
				table.insert(Calls, { "Set", ... })
			end,
			Patch = function(...)
				table.insert(Calls, { "Patch", ... })
			end,
			Clear = function(...)
				table.insert(Calls, { "Clear", ... })
			end,
			FlushPlayer = function(...)
				table.insert(Calls, { "FlushPlayer", ... })
			end,
			FlushAll = function(...)
				table.insert(Calls, { "FlushAll", ... })
			end,
		}
	end

	--> Targeted: the player is prefixed for you, exactly like Send.
	local Targeted = Client.Connection.new({ Target = Target, State = { UI = Channel() } })
	Targeted:SetState("UI", { Visible = true })
	assert(Calls[1][1] == "Set" and Calls[1][2] == Target, "Expected SetState to prefix the connection target.")
	Targeted:PatchState("UI", { Visible = false })
	assert(Calls[2][1] == "Patch" and Calls[2][2] == Target, "Expected PatchState to prefix the connection target.")
	Targeted:ClearState("UI")
	assert(Calls[3][1] == "Clear" and Calls[3][2] == Target, "Expected ClearState to prefix the connection target.")
	Targeted:FlushState("UI")
	assert(Calls[4][1] == "FlushPlayer", "Expected a targeted flush to use the per-player flush.")

	--> Untargeted: caller supplies the player, and flush falls back to broadcast.
	table.clear(Calls)
	local Broadcast = Client.Connection.new({ State = { UI = Channel() } })
	Broadcast:SetState("UI", Target, { Visible = true })
	assert(Calls[1][2] == Target, "Expected an untargeted write to pass the caller's arguments through.")
	Broadcast:FlushState("UI")
	assert(Calls[2][1] == "FlushAll", "Expected an untargeted flush to broadcast.")

	--> A read-only channel must refuse writes rather than silently no-op.
	local ReadOnly = Client.Connection.new({ State = { UI = { Get = function() end, On = function() end } } })
	assert(not pcall(function()
		ReadOnly:SetState("UI", {})
	end), "Expected writes to a read-only channel to error.")

	ReadOnly:Disconnect()
	assert(not pcall(function()
		ReadOnly:SetState("UI", {})
	end), "Expected state writes after disconnect to fail.")
end)

FireAndExpect("Reliable Client", Client.ReliableClient, Server.ReliableClient, 1)
FireAndExpect("Unreliable Client", Client.UnreliableClient, Server.UnreliableClient, 1)
FireAndExpect("Empty Reliable Client", Client.ClientEmptyEvent, Server.ClientEmptyEvent, nil)
FireAndExpect("Empty Unreliable Client", Client.ClientEmptyUnreliableEvent, Server.ClientEmptyUnreliableEvent, nil)

FireManyAndExpectMany("Many Reliable Sync Server", 8, Server.ManyReliableSync, Client.ManyReliableSync, 1)
FireManyAndExpectMany("Many Reliable Async Server", 8, Server.ManyReliableAsync, Client.ManyReliableAsync, 1)
FireManyAndExpectMany("Many Unreliable Sync Server", 8, Server.ManyUnreliableSync, Client.ManyUnreliableSync, 1)
FireManyAndExpectMany("Many Unreliable Async Server", 8, Server.ManyUnreliableAsync, Client.ManyUnreliableAsync, 1)

FireAndExpect("Unknown", Server.Unknown, Client.Unknown, newproxy())
FireAndExpect("Unknown (false)", Server.Unknown, Client.Unknown, false)
FireAndExpectAll("Unknown (nil mixed)", Server.Unknown, Client.Unknown, { "a", nil, "b", nil, nil, nil, "c" })

RunClosure("Color3 canonical validation", function()
	local Received = false
	local Disconnect = Client.Unknown.On(function()
		Received = true
	end)
	local DroppedBefore = DroppedTotal(Client)
	Server.Unknown.FireAll(BaseEnvironment.Color3.new(0 / 0, 0, 0))
	Server.StepReplication()
	task.wait(1 / 30)
	Disconnect()
	assert(not Received, "Expected a non-finite Color3 to be dropped before its listener.")
	assert(DroppedTotal(Client) > DroppedBefore, "Expected non-finite Color3 canonicalization to record a drop.")
end)

FireAndExpect(
	"Generic",
	Server.Generic,
	Client.Generic,
	{ Data = 0, Array = { 0 }, Optional = nil, Nested = { Value = 0 } }
)

FireAndExpect("Set 8", Server.Flags8, Client.Flags8, GetFlags(8))
FireAndExpect("Set 16", Server.Flags16, Client.Flags16, GetFlags(16))
FireAndExpect("Set 32", Server.Flags32, Client.Flags32, GetFlags(32))
FireAndExpect("Set >32", Server.Flags33, Client.Flags33, GetFlags(33))

FireAndExpect("Map", Server.MapEvent, Client.MapEvent, { ["string"] = 1 })
FireAndExpect("Map Struct", Server.MapStructEvent, Client.MapStructEvent, { Map = { string = 1 } })
FireAndExpect("Map Complex", Server.MapComplexEvent, Client.MapComplexEvent, { string = table.create(8, 1) })
FireAndExpect("Map Reference", Server.MapReferenceEvent, Client.MapReferenceEvent, { A = "A" })

FireAndExpect("Struct", Server.Reference, Client.Reference, Example)
FireAndExpect("Array", Server.ArrayPrimitive, Client.ArrayPrimitive, { 1, 2, 3, 4, 5, 6, 7, 8 })
FireAndExpect("Optional", Server.OptionalPrimitive, Client.OptionalPrimitive, 1)
FireAndExpect("Optional (nil)", Server.OptionalPrimitive, Client.OptionalPrimitive, nil)

FireAndExpect("Instance Any", Server.InstanceAny, Client.InstanceAny, Instance)
FireAndExpect("Instance Type", Server.InstanceOfType, Client.InstanceOfType, Instance)
FireAndFail("Instance Type (Fail)", Server.InstanceOfType, Client.InstanceOfType, nil)
FireAndExpect("Instance Optional", Server.InstanceOptional, Client.InstanceOptional, Instance)
FireAndExpectSeparate(
	"Instance Optional (nil)",
	Server.InstanceOptional,
	Client.InstanceOptional,
	Shared.ServerOnlyInstance,
	nil
)

local Array = table.create(8, Example)
FireAndExpect("Reference", Server.Reference, Client.Reference, Example)
FireAndExpect("Referency Array", Server.ReferenceArray, Client.ReferenceArray, Array)
FireAndExpect("Referency Optional", Server.ReferenceOptional, Client.ReferenceOptional, Example)
FireAndExpect("Referency Optional (nil)", Server.ReferenceOptional, Client.ReferenceOptional, nil)

InvokeAndExpect("Remote Function", Client.RemoteFunction, Server.RemoteFunction, 1, true)
InvokeAndExpect("Remote Function (yield)", Client.RemoteFunction, Server.RemoteFunction, 1, true, 1)
InvokeAndExpect("Remote Function (error)", Client.RemoteFunction, Server.RemoteFunction, 1, false)
InvokeAndExpect("Empty Remote Function", Client.EmptyFunction, Server.EmptyFunction, nil, true)
InvokeAndExpect("Unit Remote Function", Client.UnitFunction, Server.UnitFunction, nil, true)

QueueAndExpect("Reliable Queue", Server.ReliableServer, Client.ReliableServer, 1)
QueueAndExpect("Many Reliable Sync Queue", Server.ManyReliableSync, Client.ManyReliableSync, 1)
QueueAndExpect("Many Reliable Async Queue", Server.ManyReliableAsync, Client.ManyReliableAsync, 1)
--QueueAndExpect("Unreliable Queue", Server.UnreliableServer, Client.UnreliableServer, 1)

FireAndFail("Invalid Instance Any", Server.InstanceAny, Client.InstanceAny, true)
FireAndFail("Invalid Instance Type", Server.InstanceOfType, Client.InstanceOfType, InstanceNeverIsA)

FireAndExpectAll("Correct order", Server.ReliableServer, Client.ReliableServer, { 1, 2, 3, 4 })
FireAndExpectAll(
	"Multiple instances (nil and non nil)",
	Server.InstanceOptional,
	Client.InstanceOptional,
	{ nil, Instance, nil, Instance, Instance }
)

FireAndExpectAll("Many primitive", Server.ReliableServer, Client.ReliableServer, table.create(255, 1))
FireAndExpectAll("Many structs", Server.Reference, Client.Reference, table.create(255, Example))

FireAndExpectTuple(
	"Reliable Tuple",
	Server.Tuple,
	Client.Tuple,
	255,
	"A",
	65535,
	Instance,
	Instance,
	table.create(8, 0)
)
FireAndExpectTuple(
	"Unreliable Tuple",
	Server.TupleUnreliable,
	Client.TupleUnreliable,
	255,
	"A",
	65535,
	Instance,
	Instance
)
InvokeAndExpectTuple(
	"Function Tuple",
	Client.TupleFunction,
	Server.TupleFunction,
	{ 255, "A", 65535, Instance, Instance },
	{ Instance, Instance, 65535, "A", 255 }
)

FireAllAndExpectAll("Many events", 32, {
	Reliable = {
		Data = { 0 },
		Outgoing = Server.ReliableServer,
		Incoming = Client.ReliableServer,
	},
	Unreliable = {
		Data = { 0 },
		Outgoing = Server.UnreliableServer,
		Incoming = Client.UnreliableServer,
	},
	Reference = {
		Data = { Example },
		Outgoing = Server.Reference,
		Incoming = Client.Reference,
	},
	ReliableTuple = {
		Data = { 255, "A", 65535, Instance, Instance, table.create(8, 0) },
		Outgoing = Server.Tuple,
		Incoming = Client.Tuple,
	},
	UnreliableTuple = {
		Data = { 255, "A", 65535, Instance, Instance },
		Outgoing = Server.TupleUnreliable,
		Incoming = Client.TupleUnreliable,
	},
})

FireAndExpect("TagEnum Join", Server.PlayerEvent, Client.PlayerEvent, { Type = "Join", Name = "Player", UserId = 5 })
FireAndExpect("TagEnum Chat", Server.PlayerEvent, Client.PlayerEvent, { Type = "Chat", UserId = 5, Message = "Hello" })
FireAndExpect("TagEnum Leave", Server.PlayerEvent, Client.PlayerEvent, { Type = "Leave", UserId = 5 })

RunClosure("Color3", function()
	local Color = BaseEnvironment.Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255))

	local Serialized = Server.Color.Write(Color)
	local Deserialized = Server.Color.Read(Serialized)

	assert(Color.R == Deserialized.R, `Expected {Color.R}, got {Deserialized.R}`)
	assert(Color.G == Deserialized.G, `Expected {Color.G}, got {Deserialized.G}`)
	assert(Color.B == Deserialized.B, `Expected {Color.B}, got {Deserialized.B}`)
end)

RunClosure("Color3 Array", function()
	local Array = {}
	for _ = 1, 32 do
		table.insert(
			Array,
			BaseEnvironment.Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255))
		)
	end

	local Serialized = Server.ColorArray.Write(Array)
	local Deserialized = Server.ColorArray.Read(Serialized)

	assert(#Array == #Deserialized, `Expected {#Array} elements`)

	for Index, Got in Deserialized do
		local Expected = Array[Index]
		assert(Expected.R == Got.R, `Expected {Expected.R}, got {Got.R}`)
		assert(Expected.G == Got.G, `Expected {Expected.G}, got {Got.G}`)
		assert(Expected.B == Got.B, `Expected {Expected.B}, got {Got.B}`)
	end
end)

RunClosure("DateTime", function()
	for n = 1, 30 do
		local DateTime = BaseEnvironment.DateTime.fromUnixTimestamp(2 ^ n)
		local Serialized = Server.DateSeconds.Write(DateTime)
		local Deserialized = Server.DateSeconds.Read(Serialized)
		assert(
			DateTime.UnixTimestamp == Deserialized.UnixTimestamp,
			`Expected timestamp {DateTime.UnixTimestamp}, got {Deserialized.UnixTimestamp}`
		)
	end
end)

RunClosure("DateTimeMillis", function()
	for n = 1, 30 do
		local DateTime = BaseEnvironment.DateTime.fromUnixTimestampMillis(2 ^ n)
		local Serialized = Server.DateMilliseconds.Write(DateTime)
		local Deserialized = Server.DateMilliseconds.Read(Serialized)
		assert(
			DateTime.UnixTimestampMillis == Deserialized.UnixTimestampMillis,
			`Expected timestamp {DateTime.UnixTimestampMillis}, got {Deserialized.UnixTimestampMillis}`
		)
	end
end)

RunClosure("BrickColor", function()
	local BrickColor = BaseEnvironment.BrickColor.new(373)
	local Serialized = Server.BrickkColor.Write(BrickColor)
	local Deserialized = Server.BrickkColor.Read(Serialized)

	assert(
		BrickColor.Number == Deserialized.Number,
		`Expected BrickColor number to be {BrickColor.Number}, got {Deserialized.Number}`
	)
end)

RunClosure("Nested Map", function()
	local Map = { string = 1 }
	local Serialized = Server.MapNested.Write({ [Map] = Map })
	local Deserialized = Server.MapNested.Read(Serialized)

	local Elements = 0
	for KeyMap, ValueMap in Deserialized do
		if Elements >= 1 then
			error("Deserialized doesn't match original")
		end

		Elements += 1
		assert(type(KeyMap) == "table", "Deserialized doesn't match original")
		assert(type(ValueMap) == "table", "Deserialized doesn't match original")
		assert(type(KeyMap.string) == "number", "Deserialized doesn't match original")
		assert(type(ValueMap.string) == "number", "Deserialized doesn't match original")
	end
end)

RunClosure("Standalone", function()
	local Original = {
		One = 1,
		Two = 2,
		Three = 3,
		Event = { Type = "Join", Name = "JohnDoe", UserId = 1 },
		Nested = {
			Four = "ABC",
			Five = "DEF",
		},
	}

	local Serialized = Server.Standalone.Write(Original)
	local Deserialized = Server.Standalone.Read(Serialized)

	assert(Equals(Original, Deserialized), "Deserialized doesn't match original")
end)

RunClosure("Disconnect & Queue", function()
	local Expect = 1
	local Events = {
		"ReliableServer",
		"UnreliableServer",
		"ManyReliableSync",
		"ManyReliableAsync",
		"ManyUnreliableSync",
		"ManyUnreliableAsync",
	}

	for _, Event in Events do
		local Outgoing = Server[Event]
		local Incoming = Client[Event]

		local NeverRecieve: never
		Incoming.On(function(Value: never)
			NeverRecieve = Value
		end)()

		local Recieve: typeof(Expect)
		local RecieveDisconnect = Incoming.On(function(Value: typeof(Expect))
			Recieve = Value
		end)

		Outgoing.FireAll(Expect)

		task.wait(0.5)

		if Recieve ~= Expect then
			error(`Failed queue test on {Event}, expected "{Expect}", got "{Recieve}"`)
		end

		if NeverRecieve ~= nil then
			error(`Failed disconnect test on {Event}, disconnected listener still recieving.`)
		end

		RecieveDisconnect()
	end
end)

local Element = { Static = 0, Dynamic = buffer.create(64) }

FireAndExpect("Dynamic Array Data Integrity", Server.DynamicArray, Client.DynamicArray, table.create(12, Element))
FireAndExpect("Dynamic Map Data Integrity", Server.DynamicMap, Client.DynamicMap, table.create(64, Element))

RunClosure("CLI compile prompt", function()
	pcall(function()
		fs.removeDir("../Network")
	end)

	--> Without --yes the CLI must ask before creating the output directory.
	--> Give the child a non-interactive stdin so the confirm prompt fails fast
	--> instead of blocking on a stdin read forever. A blocked child is only
	--> detached by task.cancel on the Lua side, leaving an orphan process that
	--> hangs lune on exit under Linux CI (the job then runs to the 6h timeout).
	local Result = process.exec("lune", { "run", Compiler, COMPILE_TEST_FILE }, {
		cwd = "../src/CLI",
		stdin = "",
	})

	assert(not Result.ok, "Expected compile without --yes to refuse instead of compiling.")
	assert(not fs.isDir("../Network"), "Expected CLI not to create output without confirmation.")
end)

RunClosure("CLI compile --yes", function()
	local Result = process.exec("lune", { "run", Compiler, COMPILE_TEST_FILE, "--", "--yes" }, { cwd = "../src/CLI" })
	assert(Result.ok, Result.stderr)
end)

RunClosure("CI utility modes", function()
	for _, Flag in
		{
			"--doctor",
			"--benchmark",
			"--load-sim",
			"--capture-replay",
			"--golden-snapshots",
			"--compatibility",
			"--schema-docs",
			"--write-lock",
			"--check-lock",
			"--ci",
		}
	do
		local Result = process.exec(
			"lune",
			{ "run", Compiler, COMPILE_TEST_FILE, "--", Flag, "--yes" },
			{ cwd = "../src/CLI" }
		)
		assert(Result.ok, `{Flag} failed:\n{Result.stderr}`)
		if Flag == "--schema-docs" then
			assert(
				string.find(Result.stdout, "Secret,Token,Password", 1, true),
				"Expected schema docs to include capture redactions."
			)
		end
	end

	local StrictResult = process.exec(
		"lune",
		{ "run", Compiler, "../../test/Sources/StrictBad", "--", "--strict", "--yes" },
		{ cwd = "../src/CLI" }
	)
	assert(not StrictResult.ok, "Expected strict production mode to reject StrictBad.cheeto.")
	assert(
		string.find(`{StrictResult.stdout}\n{StrictResult.stderr}`, "StrictBad.cheeto:%d+:%d+") ~= nil,
		"Expected strict diagnostics to include file, line, and column."
	)

	local HardeningResult = process.exec(
		"lune",
		{ "run", Compiler, "../../test/Sources/HardeningGood", "--", "--hardening-checklist", "--yes" },
		{ cwd = "../src/CLI" }
	)
	assert(HardeningResult.ok, `Expected hardening checklist to pass:\n{HardeningResult.stderr}`)
end)

RunClosure("Removed protocol options are rejected", function()
	for _, Options in
		{
			{ ProtocolVersion = 1 },
			{ ProtocolMode = "Legacy" },
			{ AcceptProtocolVersion1 = true },
		}
	do
		local Success = pcall(function()
			Client.Configure(Options)
		end)
		assert(not Success, "Expected a removed protocol runtime option to fail.")
	end

	local Result = process.exec(
		"lune",
		{ "run", Compiler, "../../test/Sources/LegacyBad", "--", "--yes" },
		{ cwd = "../src/CLI" }
	)
	assert(not Result.ok, "Expected a schema using a removed protocol option to fail compilation.")
	assert(
		string.find(Result.stdout .. Result.stderr, "was removed", 1, true) ~= nil,
		"Expected the compiler to say the protocol option was removed."
	)

	local IntegrityModeResult = process.exec(
		"lune",
		{ "run", Compiler, "../../test/Sources/CharacterIntegrityBad", "--", "--yes" },
		{ cwd = "../src/CLI" }
	)
	assert(not IntegrityModeResult.ok, "Expected an unknown character-integrity mode to fail compilation.")
	local RuntimeModeSuccess = pcall(function()
		Server.Configure({ CharacterIntegrityMode = "ImmediateBan" })
	end)
	assert(not RuntimeModeSuccess, "Expected an unknown runtime character-integrity mode to fail configuration.")

	local Info = Client.Protocol.Info()
	assert(Info.ProtocolMode == nil and Info.LocalProtocolVersion == nil, "Protocol.Info still reports protocol modes.")
	assert(Info.SchemaHash == Client.Schema.Hash, "Expected Protocol.Info to report the local schema hash.")
end)

RunClosure("Capture replay inspector and schema helpers", function()
	Client.Capture.Clear()
	Server.Capture.Clear()
	Client.Capture.Start({ Limit = 64 })
	Server.Capture.Start({ Limit = 64 })

	local Disconnect = Client.ReliableServer.On(function() end)
	Server.ReliableServer.FireAll(42)
	Server.StepReplication()
	task.wait(1 / 30)
	Disconnect()

	local SensitiveDisconnect = Client.SensitiveEvent.On(function() end)
	Server.SensitiveEvent.FireAll({
		Secret = "hide",
		Token = "token",
		Public = 7,
	})
	Server.StepReplication()
	task.wait(1 / 30)
	SensitiveDisconnect()

	local Entries = Client.Capture.Entries()
	local FoundReceive = false
	local FoundRedaction = false
	for _, Entry in Entries do
		if Entry.Name == "ReliableServer" and Entry.Direction == "receive" and Entry.Status == "accepted" then
			FoundReceive = true
			assert(
				string.find(Entry.PayloadSummary or "", "42", 1, true),
				"Expected capture payload summary to include decoded value."
			)
			assert(typeof(Entry.Buffer) == "buffer", "Expected accepted capture entry to include raw buffer.")
		elseif Entry.Name == "SensitiveEvent" and Entry.Direction == "receive" and Entry.Status == "accepted" then
			FoundRedaction = true
			assert(string.find(Entry.PayloadSummary or "", "Secret=%[redacted%]"), "Expected Secret to be redacted.")
			assert(string.find(Entry.PayloadSummary or "", "Token=%[redacted%]"), "Expected Token to be redacted.")
			assert(not string.find(Entry.PayloadSummary or "", "hide", 1, true), "Expected secret value to be removed.")
		end
	end
	assert(FoundReceive, "Expected an accepted ReliableServer receive capture.")
	assert(FoundRedaction, "Expected SensitiveEvent capture redaction.")

	local Replayed = 0
	local Replay = Client.Capture.Replay(Entries, {
		ReliableServer = function()
			Replayed += 1
		end,
	})
	assert(Replay.Accepted > 0, "Expected replay to count accepted entries.")
	assert(Replayed > 0, "Expected replay handler to be called.")

	local RawReplayed
	local RawDisconnect = Client.ReliableServer.On(function(Value)
		RawReplayed = Value
	end)
	local RawReplay = Client.Capture.ReplayRaw(Entries)
	task.wait(1 / 30)
	assert(RawReplay.Replayed > 0, "Expected raw replay to inject captured buffers.")
	assert(RawReplay.MissingRaw < RawReplay.Accepted, "Expected accepted capture entries to retain raw buffers.")
	assert(RawReplayed == 42, `Expected raw replay to decode ReliableServer value 42, got {RawReplayed}.`)
	RawDisconnect()

	Client.Inspector.Enable(true)
	local Snapshot = Client.Inspector.Snapshot()
	assert(Snapshot.Metrics.CapturedPackets >= 1, "Expected inspector snapshot to include captured packet count.")
	assert(Snapshot.Protocol.LocalSchemaVersion == 2, "Expected inspector protocol schema version.")

	Client.Schema.SetDefault("Defaulted", 99)
	Client.Schema.RenameField("OldName", "NewName")
	Client.Schema.DeprecateField("RemoveMe")
	Client.Schema.RegisterMigration(1, function(Payload)
		Payload.Migrated = true
		return Payload
	end)

	local Migrated, Version = Client.Schema.Migrate({
		OldName = 1,
		RemoveMe = true,
	}, 1)
	assert(Version == 2, `Expected migrated version 2, got {Version}.`)
	assert(Migrated.NewName == 1, "Expected renamed field to migrate.")
	assert(Migrated.Defaulted == 99, "Expected default field to be applied.")
	assert(Migrated.RemoveMe == nil, "Expected deprecated field to be removed.")
	assert(Migrated.Migrated == true, "Expected migration stub callback to run.")

	Client.Capture.Stop()
	Server.Capture.Stop()
end)

RunClosure("Replication adapter stubs", function()
	local Published
	local MessagingService = {
		PublishAsync = function(self, Topic, Data)
			Published = {
				Topic = Topic,
				Data = Data,
			}
			return true
		end,
		SubscribeAsync = function(self, Topic, Callback)
			return {
				Disconnect = function() end,
			}
		end,
	}

	local Messaging = Server.Replication.MessagingService("cheeto:test", MessagingService)
	Messaging.PublishGroup("party-a", { Score = 10 })
	assert(Published.Topic == "cheeto:test", "Expected MessagingService topic.")
	assert(Published.Data.Channel == "group:party-a", "Expected MessagingService group channel.")
	assert(Published.Data.SchemaVersion == 2, "Expected MessagingService schema version.")

	local Stored
	local MemoryStoreService = {
		GetSortedMap = function(self, Name)
			return {
				SetAsync = function(self, Key, Value, Expiration)
					Stored = {
						Name = Name,
						Key = Key,
						Value = Value,
						Expiration = Expiration,
					}
				end,
				GetAsync = function(self, Key)
					return Stored and Stored.Value
				end,
				RemoveAsync = function(self, Key)
					Stored = nil
				end,
			}
		end,
	}

	local Memory = Server.Replication.MemoryStore("cheeto:state", MemoryStoreService)
	Memory.SetZone("PlayerState", "lobby", "snapshot", { Health = 100 }, 30)
	assert(Stored.Name == "cheeto:state", "Expected MemoryStore map name.")
	assert(Stored.Key == "zone:PlayerState:lobby:snapshot", "Expected scoped MemoryStore key.")
	assert(Stored.Value.SchemaVersion == 2, "Expected MemoryStore schema version.")
	assert(Stored.Expiration == 30, "Expected MemoryStore expiration.")
end)

RunClosure("Golden binary snapshots", function()
	local Exact = buffer.create(9)
	for Offset = 0, 8 do
		buffer.writeu8(Exact, Offset, Offset)
	end

	local TypeSnapshots = {
		{
			Name = "primitive:u8",
			Buffer = Client.Byte.Write(5),
			Expected = { 5 },
		},
		{
			Name = "set:flags8",
			Buffer = Client.GoldenFlags8.Write({
				F1 = true,
				F2 = false,
				F3 = false,
				F4 = false,
				F5 = false,
				F6 = false,
				F7 = false,
				F8 = true,
			}),
			Expected = { 129 },
		},
		{
			Name = "set:golden-set",
			Buffer = Client.GoldenSet.Write({
				Alpha = true,
				Beta = false,
				Gamma = true,
			}),
			Expected = { 5 },
		},
		{
			Name = "optional:nil",
			Buffer = Client.GoldenOptional.Write(nil),
			Expected = {},
		},
		{
			Name = "optional:u16",
			Buffer = Client.GoldenOptional.Write(258),
			Expected = { 1, 130, 2 },
		},
		{
			Name = "buffer:exact",
			Buffer = Client.ExactBuffer.Write(Exact),
			Expected = { 0, 1, 2, 3, 4, 5, 6, 7, 8 },
		},
		{
			Name = "array:nested",
			Buffer = Client.MultiDimensionalArray.Write({ { { 1, 2 }, { 3 } } }),
			Expected = { 1, 2, 2, 1, 2, 1, 3 },
		},
		{
			Name = "map:string-u8",
			Buffer = Client.GoldenMap.Write({
				alpha = 3,
				beta = 4,
			}),
			Expected = { 2, 5, 97, 108, 112, 104, 97, 3, 4, 98, 101, 116, 97, 4 },
		},
		{
			Name = "struct:nested",
			Buffer = Client.GoldenNested.Write({
				A = 7,
				B = {
					C = 258,
					D = "ok",
				},
				E = { 1, 2, 3 },
				F = 513,
			}),
			Expected = { 7, 130, 2, 2, 111, 107, 1, 2, 3, 1, 129, 4 },
		},
	}

	for _, Snapshot in TypeSnapshots do
		ExpectBytes(Snapshot.Name, Snapshot.Buffer, Snapshot.Expected)
	end

	Client.Configure({
		EnableProtocolHandshake = false,
		RateLimitPerSecond = 0,
	})
	Server.Configure({
		EnableProtocolHandshake = false,
		RateLimitPerSecond = 0,
	})
	Client.Capture.Clear()
	Server.Capture.Clear()
	Client.Capture.Start({ Limit = 128 })
	Server.Capture.Start({ Limit = 128 })

	local EventDisconnect = Client.ReliableServer.On(function() end)
	Server.ReliableServer.FireAll(9)
	Server.StepReplication()
	task.wait(1 / 30)
	EventDisconnect()
	ExpectBytes(
		"wire:event",
		FindCaptureBuffer(Server.Capture.Entries(), "ReliableServer", "send", "accepted"),
		{ 27, 0, 1, 0, 9 }
	)

	Server.RemoteFunction.On(function(_Player, Value)
		return Value + 1
	end)
	local InvokeResult = Client.RemoteFunction.Invoke(10)
	assert(InvokeResult == 11, `Expected invoke result 11, got {InvokeResult}.`)
	ExpectBytes(
		"wire:invoke",
		FindCaptureBuffer(Client.Capture.Entries(), "RemoteFunction", "send", "accepted"),
		{ 37, 0, 2, 0, 6, 10 }
	)

	Client.ReliableClient.Predict(11)
	Client.StepReplication()
	task.wait(1 / 30)
	ExpectBytes(
		"wire:prediction",
		FindCaptureBuffer(Client.Capture.Entries(), "ReliableClient", "send", "accepted"),
		{ 30, 1, 1, 0, 1, 11 }
	)

	local StateDisconnect = Client.PlayerState.On(function() end)
	Server.PlayerState.SetAll({
		Health = 44,
		Stamina = 55,
		Equipped = "Bow",
	})
	task.wait(1 / 10)
	Server.StepReplication()
	task.wait(1 / 30)
	StateDisconnect()
	ExpectBytes(
		"wire:state-channel",
		FindCaptureBuffer(Server.Capture.Entries(), "PlayerState", "send", "accepted"),
		{ 0, 0, 8, 0, 0, 44, 55, 1, 3, 66, 111, 119 }
	)

	Client.Capture.Stop()
	Server.Capture.Stop()
	Client.Configure({
		EnableProtocolHandshake = true,
		RateLimitPerSecond = 0,
	})
	Server.Configure({
		EnableProtocolHandshake = true,
		RateLimitPerSecond = 0,
	})
end)

RunClosure("Transport hardening runtime APIs", function()
	Client.Configure({
		ReliableFragmentBytes = 4,
		MaxReliablePacketBytes = 1024,
		EnableProtocolHandshake = false,
		RateLimitPerSecond = 0,
	})
	Server.Configure({
		ReliableFragmentBytes = 4,
		MaxReliablePacketBytes = 1024,
		EnableProtocolHandshake = false,
		RateLimitPerSecond = 0,
	})

	local FragmentedResult
	local FragmentDisconnect = Client.ReliableServer.On(function(Value)
		FragmentedResult = Value
	end)
	Server.ReliableServer.FireAll(77)
	Server.StepReplication()
	task.wait(1 / 30)
	assert(FragmentedResult == 77, `Expected fragmented reliable packet to reassemble, got {FragmentedResult}.`)
	FragmentDisconnect()

	local Violations = 0
	local ReleaseViolation = Server.Security.OnViolation(function(Context)
		if Context.Reason == "KillSwitch" or Context.Reason == "PolicyRejected" then
			Violations += 1
		end
	end)
	Server.Security.Kill("ReliableClient", "test")
	Client.ReliableClient.Fire(15)
	Client.StepReplication()
	task.wait(1 / 30)
	Server.Security.Unkill("ReliableClient")
	Server.Configure({ RequirePolicies = true })
	Client.ClientEmptyEvent.Fire()
	Client.StepReplication()
	task.wait(1 / 30)
	Server.Configure({ RequirePolicies = false })
	ReleaseViolation()
	assert(Violations >= 2, "Expected kill-switch and required-policy violations.")

	--> SyncValidation must not kill a bystander. The thread that processes a packet
	--> containing a Sync event used to be recorded and never cleared, so the NEXT
	--> packet closed it if it was suspended -- for any reason at all. A thread that
	--> fired a Cheeto event and then waited on something unrelated was killed
	--> mid-wait, silently, because coroutine.close is not a catchable error.
	--> This drove the intermittent suite stall: the main thread waited on a
	--> `require` and a later packet closed it.
	Server.Security.RegisterPolicy("damage", function()
		return true
	end)
	local SyncListenerRelease = Server.ReliableClient.On(function() end)

	local Bystander = coroutine.create(function()
		--> Runs the server's packet processor on THIS thread, which is what got
		--> recorded, then parks on something that has nothing to do with Cheeto.
		Client.ReliableClient.Fire(1)
		Client.StepReplication()
		coroutine.yield()
		return "survived"
	end)
	assert(coroutine.resume(Bystander))
	assert(coroutine.status(Bystander) == "suspended", "Expected the bystander to park.")

	--> A second Sync packet: this is the dispatch that used to close the bystander.
	Client.ReliableClient.Fire(2)
	Client.StepReplication()
	task.wait(1 / 30)

	assert(
		coroutine.status(Bystander) == "suspended",
		`SyncValidation closed a bystander thread that merely happened to be suspended (status {coroutine.status(
			Bystander
		)}).`
	)
	local Resumed, Value = coroutine.resume(Bystander)
	assert(Resumed and Value == "survived", `Bystander could not finish: {tostring(Value)}`)
	SyncListenerRelease()

	--> The other half: SyncValidation must still CATCH a Sync handler that really
	--> does yield. Without this, "stop closing bystanders" could have been
	--> implemented by disabling the check altogether and every test would pass.
	--> The warning is the only observable effect, hence the warn capture.
	assert(FindWarning("Yielded in a Sync call") == nil, "Expected no sync-yield warning before this check.")

	local YieldingRelease = Server.ReliableClient.On(function()
		task.wait(0.05) --> exactly what a Sync call must not do
	end)
	Client.ReliableClient.Fire(3)
	Client.StepReplication()
	task.wait(1 / 30)
	--> The NEXT dispatch is what inspects the thread left parked by the handler.
	Client.ReliableClient.Fire(4)
	Client.StepReplication()
	task.wait(1 / 30)
	YieldingRelease()

	assert(
		FindWarning("Yielded in a Sync call") ~= nil,
		"SyncValidation stopped reporting a Sync handler that genuinely yielded."
	)

	--> An unregistered policy must drop, not admit. The built-in names used to
	--> resolve to a rule that only checked the sender was connected.
	Server.Security.RegisterPolicy("damage", nil :: any)
	local UnregisteredSeen = 0
	local ReleaseUnregistered = Server.ReliableClient.On(function()
		UnregisteredSeen += 1
	end)
	Client.ReliableClient.Fire(5)
	Client.StepReplication()
	task.wait(1 / 30)
	ReleaseUnregistered()
	assert(UnregisteredSeen == 0, "An endpoint whose policy is not registered delivered a packet.")
	assert(
		FindWarning('Policy "damage" is not registered') ~= nil,
		"Expected a warning naming the unregistered policy."
	)
	Server.Security.RegisterPolicy("damage", AllowDamage)

	--> Auth: a registered rule gates the event, and an UNREGISTERED rule must fail
	--> closed without raising. CheckAuth used to error() on an unknown rule, which
	--> propagated out of the batched receive loop and dropped every sibling event
	--> in the same packet -- so this asserts the sibling survives, not just that
	--> the bad event is rejected.
	local AuthAllow = false
	local AuthedSeen, UnknownAuthSeen = 0, 0
	Server.UseAuth("unittest", function(Context)
		assert(Context.Name == "AuthedClient", `Auth context carried the wrong event name: {Context.Name}`)
		return AuthAllow
	end)
	local ReleaseAuthed = Server.AuthedClient.On(function()
		AuthedSeen += 1
	end)
	local ReleaseUnknownAuth = Server.UnknownAuthClient.On(function()
		UnknownAuthSeen += 1
	end)

	Client.AuthedClient.Fire(1)
	Client.StepReplication()
	task.wait(1 / 30)
	assert(AuthedSeen == 0, "Expected a denying auth rule to drop the event.")

	AuthAllow = true
	Client.AuthedClient.Fire(2)
	Client.StepReplication()
	task.wait(1 / 30)
	assert(AuthedSeen == 1, "Expected an allowing auth rule to deliver the event.")

	--> Both fired before a single flush, so they ride ONE packet.
	Client.UnknownAuthClient.Fire(3)
	Client.AuthedClient.Fire(4)
	Client.StepReplication()
	task.wait(1 / 30)
	assert(UnknownAuthSeen == 0, "Expected an unregistered auth rule to drop its event.")
	assert(
		AuthedSeen == 2,
		`Unregistered auth rule took its packet-mate down with it: AuthedClient arrived {AuthedSeen} times, expected 2.`
	)
	ReleaseAuthed()
	ReleaseUnknownAuth()

	--> The Validate hook: the post-decode gate that makes the payload-dependent
	--> constraint fields (MaxDistance, RequireOwnership, ...) enforceable at all.
	--> Policies run BEFORE deserialization, so before this existed those fields were
	--> parsed, handed to policies and acted on by nothing.
	local Seen, Contexts = 0, {}
	local ReleaseConstrained = Server.ConstrainedClient.On(function()
		Seen += 1
	end)

	--> Rejects odd payloads, so the hook is proven to see the DECODED value -- the
	--> thing a policy cannot do.
	local ReleaseValidate = Server.Use("Validate", function(Context)
		table.insert(Contexts, Context)
		local Value = Context.Payload and Context.Payload[1]
		return type(Value) ~= "number" or Value % 2 == 0
	end)

	Client.ConstrainedClient.Fire(4) --> even, allowed
	Client.StepReplication()
	task.wait(1 / 30)
	assert(Seen == 1, `Expected the allowed payload to arrive, got {Seen}.`)

	Client.ConstrainedClient.Fire(7) --> odd, rejected on payload
	Client.StepReplication()
	task.wait(1 / 30)
	assert(Seen == 1, "Expected the Validate hook to drop a packet on its decoded payload.")

	assert(#Contexts >= 2, `Expected the hook to run for both sends, ran {#Contexts}.`)
	local First = Contexts[1]
	assert(First.Name == "ConstrainedClient", `Wrong event name in context: {tostring(First.Name)}`)
	assert(First.Constraints ~= nil, "Expected the declared constraints in the context.")
	assert(
		First.Constraints.MaxDistance == 50,
		`Expected MaxDistance 50 in the context, got {tostring(First.Constraints.MaxDistance)}.`
	)
	assert(First.Constraints.RequireOwnership == true, "Expected RequireOwnership true in the context.")
	assert(First.Payload ~= nil, "Expected the decoded payload in the context.")
	ReleaseValidate()
	ReleaseConstrained()

	--> An event declaring NO payload constraint must not get the hook at all: this is
	--> the receive path for every packet, and the context table is a per-packet
	--> allocation. Proven by the hook never firing for it.
	local UnconstrainedSeen, HookRuns = 0, 0
	local ReleaseUnconstrained = Server.UnconstrainedClient.On(function()
		UnconstrainedSeen += 1
	end)
	local ReleaseCounter = Server.Use("Validate", function()
		HookRuns += 1
		return true
	end)
	Client.UnconstrainedClient.Fire(9)
	Client.StepReplication()
	task.wait(1 / 30)
	ReleaseCounter()
	ReleaseUnconstrained()
	assert(UnconstrainedSeen == 1, "Expected the unconstrained event to arrive.")
	assert(HookRuns == 0, `Validate hook emitted for an event that declares no payload constraint ({HookRuns} runs).`)

	--> Honeypot: the attribute used to parse and then emit nothing at all, so a
	--> honeypot endpoint was an ordinary event that happily delivered traffic.
	local HoneypotSeen, HoneypotViolations = 0, 0
	local ReleaseHoneypotViolation = Server.Security.OnViolation(function(Context)
		if Context.Reason == "Honeypot" then
			HoneypotViolations += 1
		end
	end)
	local ReleaseHoneypot = Server.HoneypotClient.On(function()
		HoneypotSeen += 1
	end)
	Client.HoneypotClient.Fire(9)
	Client.StepReplication()
	task.wait(1 / 30)
	ReleaseHoneypot()
	ReleaseHoneypotViolation()
	assert(HoneypotSeen == 0, "Expected a honeypot event to never reach its listener.")
	assert(HoneypotViolations == 1, "Expected a honeypot hit to raise exactly one violation.")

	--> Idempotency: also enforced by nothing before -- the flag reached policies as
	--> advice and the runtime ignored it.
	-->
	--> READ THIS BEFORE TRUSTING IT: this asserts only that declaring Idempotency
	--> does not BREAK the event. It cannot assert deduplication, because the key is
	--> the packet sequence number and this event carries no prediction id, so
	--> enforcement is inert here by design (see CheckPolicy). Covering the dedup
	--> itself needs a prediction-carrying event; until then that path is untested.
	local IdempotentSeen = 0
	local ReleaseIdempotent = Server.IdempotentClient.On(function()
		IdempotentSeen += 1
	end)
	Client.IdempotentClient.Fire(1)
	Client.StepReplication()
	task.wait(1 / 30)
	local AfterFirst = IdempotentSeen
	Client.IdempotentClient.Fire(1)
	Client.StepReplication()
	task.wait(1 / 30)
	ReleaseIdempotent()
	assert(AfterFirst == 1, `Expected the first idempotent send to arrive, got {AfterFirst}.`)

	local ShieldViolations = 0
	local ReleaseShieldViolation = Server.Security.OnViolation(function(Context)
		if Context.Event == "$clientShield" and Context.Reason == "UnitTestShield" then
			ShieldViolations += 1
		end
	end)
	local ShieldScore = Server.Security.ReportClientShield(Shared.Player, "UnitTestShield", "test", 5, false)
	local ShieldSnapshot = Server.Security.ClientShield()
	ReleaseShieldViolation()
	assert(ShieldScore >= 5, "Expected client shield report to add weighted abuse score.")
	assert(ShieldViolations == 1, "Expected client shield report to emit a violation.")
	assert(#ShieldSnapshot.Reports >= 1, "Expected client shield report to be retained in the snapshot.")

	--> Server-issued integrity challenges share Cheeto's typed transport. The client
	--> coalesces overlapping work, and the server accepts only the current one-time
	--> receipt. This covers the liveness path that catches a stopped sampler.
	Client.Configure({
		EnableClientIntegrity = true,
		ClientIntegrityChallengeIntervalSeconds = 1000,
		ClientIntegrityJoinGraceSeconds = 0,
	})
	Server.Configure({
		EnableClientIntegrity = true,
		ClientIntegrityChallengeIntervalSeconds = 1000,
		ClientIntegrityJoinGraceSeconds = 0,
		ClientIntegrityReceiptTimeoutSeconds = 5,
		ClientIntegrityScoreThreshold = 100,
	})

	local IntegritySamples = 0
	local ReleaseIntegritySampler = Client.Security.OnIntegritySample(function(Context)
		IntegritySamples += 1
		assert(Context.ChallengeId > 0, "Expected a positive one-time challenge id.")
		assert(Context.WireFormat ~= nil, "Expected the integrity sample to carry the wire format.")
		return true
	end)

	local FirstChallenge = Server.Security.ChallengeIntegrity(Shared.Player)
	assert(FirstChallenge ~= nil, "Expected the server to queue an integrity challenge.")
	Server.StepReplication()
	task.wait(1 / 30)
	Client.StepReplication()
	task.wait(1 / 30)
	local FirstIntegrity = Server.Security.ClientIntegrity(Shared.Player)
	assert(FirstIntegrity ~= nil and FirstIntegrity.ValidReceipts == 1, "Expected one valid integrity receipt.")
	assert(FirstIntegrity.PendingChallenge == nil, "Expected a valid receipt to consume its challenge.")

	local Superseded = Server.Security.ChallengeIntegrity(Shared.Player)
	local Current = Server.Security.ChallengeIntegrity(Shared.Player)
	assert(Superseded ~= nil and Current ~= nil and Current > Superseded, "Expected monotonic forced challenges.")
	Server.StepReplication()
	task.wait(1 / 30)
	Client.StepReplication()
	task.wait(1 / 30)
	local CoalescedIntegrity = Server.Security.ClientIntegrity(Shared.Player)
	assert(CoalescedIntegrity.ValidReceipts == 2, "Expected only the newest overlapping challenge to complete.")
	assert(IntegritySamples == 2, `Expected overlapping samples to coalesce, sampler ran {IntegritySamples} times.`)
	ReleaseIntegritySampler()

	local IntegrityFailures = 0
	local ReleaseIntegrityViolation = Server.Security.OnViolation(function(Context)
		if Context.Event == "$clientIntegrity" and Context.Reason == "IntegrityEvaluatorFailed" then
			IntegrityFailures += 1
		end
	end)
	local ReleaseFailingSampler = Client.Security.OnIntegritySample(function()
		return false
	end)
	assert(Server.Security.ChallengeIntegrity(Shared.Player) ~= nil, "Expected a challenge for the failing sampler.")
	Server.StepReplication()
	task.wait(1 / 30)
	Client.StepReplication()
	task.wait(1 / 30)
	local FailedIntegrity = Server.Security.ClientIntegrity(Shared.Player)
	assert(FailedIntegrity.ConsecutiveFailures == 1, "Expected an unhealthy completion to add evidence.")
	assert(FailedIntegrity.Score > 0, "Expected an unhealthy completion to raise the decaying evidence score.")
	assert(IntegrityFailures == 1, "Expected one structured evaluator-failure violation.")
	ReleaseFailingSampler()
	ReleaseIntegrityViolation()

	--> A completed local sweep is not enough by itself: if its receipt never
	--> crosses the client transport, the server must expire the one-time challenge.
	Server.Configure({
		ClientIntegrityReceiptTimeoutSeconds = 0.5,
		ClientIntegrityScoreThreshold = 100,
	})
	local MissingReceipts = 0
	local ReleaseMissingReceipt = Server.Security.OnViolation(function(Context)
		if Context.Event == "$clientIntegrity" and Context.Reason == "IntegrityReceiptMissing" then
			MissingReceipts += 1
		end
	end)
	assert(Server.Security.ChallengeIntegrity(Shared.Player) ~= nil, "Expected a challenge for timeout coverage.")
	Server.StepReplication()
	--> Lune pauses its os.clock during task.wait, while the generated Roblox
	--> runtime uses os.clock as its monotonic deadline source. Advance that exact
	--> clock here so this remains a deterministic expiry test in both runtimes.
	local ReceiptDeadline = os.clock() + 0.55
	while os.clock() < ReceiptDeadline do
		-- Intentional bounded spin for the standalone Luau clock.
	end
	Server.StepReplication()
	local MissedIntegrity = Server.Security.ClientIntegrity(Shared.Player)
	assert(MissedIntegrity.ConsecutiveMisses == 1, "Expected an unreturned receipt to count as one miss.")
	assert(MissedIntegrity.PendingChallenge == nil, "Expected the expired challenge to be cleared.")
	assert(MissingReceipts == 1, "Expected one structured missing-receipt violation.")
	ReleaseMissingReceipt()

	--> Pure server movement classification: ordinary movement passes, a long frame
	--> resyncs, sitting is exempt, and impossible displacement yields named evidence.
	Server.Configure({
		CharacterIntegrityMaxHorizontalSpeed = 64,
		CharacterIntegrityMaxVerticalSpeed = 120,
		CharacterIntegritySpeedMultiplier = 1.75,
		CharacterIntegrityDistanceSlack = 12,
		CharacterIntegrityPingAllowance = 1.5,
		CharacterIntegrityMaxStepSeconds = 1.5,
	})
	local NormalMovement = Server.Security.EvaluateMovement({
		DeltaTime = 0.25,
		HorizontalDistance = 10,
		VerticalDistance = 2,
		WalkSpeed = 16,
		HorizontalVelocity = 16,
		VerticalVelocity = 8,
		Ping = 0.08,
	})
	assert(not NormalMovement.Suspicious and not NormalMovement.Resync, "Expected ordinary movement to pass.")
	local HitchMovement = Server.Security.EvaluateMovement({
		DeltaTime = 2,
		HorizontalDistance = 500,
		VerticalDistance = 500,
	})
	assert(HitchMovement.Resync and not HitchMovement.Suspicious, "Expected a long server frame to resync, not accuse.")
	local SeatedMovement = Server.Security.EvaluateMovement({
		DeltaTime = 0.25,
		HorizontalDistance = 500,
		VerticalDistance = 500,
		Seated = true,
	})
	assert(not SeatedMovement.Suspicious, "Expected seated/vehicle movement to be exempt.")
	local ImpossibleMovement = Server.Security.EvaluateMovement({
		DeltaTime = 0.25,
		HorizontalDistance = 250,
		VerticalDistance = 200,
		WalkSpeed = 16,
		HorizontalVelocity = 0,
		VerticalVelocity = 0,
		Ping = 0.05,
		PathBlocked = true,
	})
	assert(ImpossibleMovement.Suspicious and ImpossibleMovement.Weight >= 7, "Expected impossible movement evidence.")
	assert(table.find(ImpossibleMovement.Reasons, "HorizontalDisplacement"), "Expected horizontal evidence.")
	assert(table.find(ImpossibleMovement.Reasons, "VerticalDisplacement"), "Expected vertical evidence.")
	assert(table.find(ImpossibleMovement.Reasons, "CollidableTraversal"), "Expected traversal evidence.")

	Server.Configure({
		EnableCharacterIntegrity = true,
		CharacterIntegrityMode = "Observe",
		CharacterIntegrityKick = true,
		CharacterIntegrityCorrectionScore = 1,
		CharacterIntegrityKickScore = 1,
	})
	local _, ObserveAction = Server.Security.ObserveCharacter(Shared.Player, "UnitTestObserve", 10)
	assert(ObserveAction == "observe", "Expected Observe mode to retain evidence without escalating it.")
	Server.Configure({ CharacterIntegrityMode = "Report" })
	local _, ReportAction = Server.Security.ObserveCharacter(Shared.Player, "UnitTestReport", 1)
	assert(ReportAction == "report", "Expected Report mode to emit evidence without correction.")

	Server.Configure({ EnableClientIntegrity = false, EnableCharacterIntegrity = false })
	Client.Configure({ EnableClientIntegrity = false, EnableCharacterIntegrity = false })

	local Handle = Server.Handles.Register(Shared.ServerOnlyInstance, Shared.Player, os.clock() + 10)
	assert(
		Server.Handles.Resolve(Handle, Shared.Player) == Shared.ServerOnlyInstance,
		"Expected handle to resolve for owner."
	)
	local Capability = Server.Handles.IssueCapability(Shared.ServerOnlyInstance, Shared.Player, { Use = true }, 10)
	assert(
		Server.Handles.ValidateCapability(Capability, Shared.Player, "Use") == Shared.ServerOnlyInstance,
		"Expected capability to validate."
	)
	local RefreshObject = {}
	local RefreshHandle = Server.Handles.Register(RefreshObject, Shared.Player, os.clock() + 0.01)
	local RefreshedHandle = Server.Handles.Register(RefreshObject, Shared.Player, os.clock() + 10)
	task.wait(0.02)
	assert(RefreshedHandle == RefreshHandle, "Expected repeated handle registration to retain its stable id.")
	assert(
		Server.Handles.Resolve(RefreshedHandle, Shared.Player) == RefreshObject,
		"Expected repeated handle registration to refresh its owner and expiry."
	)

	local BeforePeerState = Client.Transport.Snapshot().__server
	local QueuedBefore = if BeforePeerState then BeforePeerState.QueuedEvents else 0
	local SentBefore = if BeforePeerState then BeforePeerState.SentPackets else 0
	assert(Client.Transport.RecordQueuedEvent(nil, "Reliable", 7, "Critical"), "Expected client event to queue.")
	local QueuedPeerState = Client.Transport.Snapshot()
	assert(QueuedPeerState.Server == nil, "Expected the descriptive Server peer key to be canonicalized.")
	assert(
		QueuedPeerState.__server.QueuedEvents == QueuedBefore + 1,
		"Expected nil client target to queue under the canonical server peer."
	)
	Client.Transport.RecordFlush("Server", "Reliable", 7)
	local FlushedPeerState = Client.Transport.Snapshot()
	assert(FlushedPeerState.Server == nil, "Expected client flush to reuse the canonical server peer.")
	assert(FlushedPeerState.__server.QueuedEvents == QueuedBefore, "Expected the queued client event to flush.")
	assert(FlushedPeerState.__server.SentPackets == SentBefore + 1, "Expected the client flush to be recorded.")

	Client.Transport.Coalesce("Server", "aim", "Cosmetic", 1)
	Client.Transport.Coalesce("Server", "aim", "Cosmetic", 2)
	local Coalesced = Client.Transport.FlushCoalesced("Server")
	assert(Coalesced.aim.Payload == 2, "Expected last-value-wins coalescing.")

	Server.Replication.SetParty("party-a", Shared.Player, true)
	local Graph = Server.Replication.Graph()
	local Routed = 0
	Graph:Route("Party", "party-a", function()
		Routed += 1
	end)
	assert(Routed == 1, "Expected replication graph to route to party member.")

	local Patch = Client.State.MakePatch({ A = 1, Nested = { B = 2 }, Gone = true }, { A = 2, Nested = { B = 3 } })
	local Patched = Client.State.ApplyPatch({ A = 1, Nested = { B = 2 }, Gone = true }, Patch)
	assert(Patched.A == 2 and Patched.Nested.B == 3 and Patched.Gone == nil, "Expected nested patch to apply.")
	assert(
		Client.Codecs.DequantizeNumber(Client.Codecs.QuantizeNumber(1.25, 100), 100) == 1.25,
		"Expected fixed-point codec roundtrip."
	)

	local ListenerEvents = 0
	local ReleaseListenerHook = Client.Use("Listener", function()
		ListenerEvents += 1
	end)
	local Disconnect = Client.ReliableServer.On(function() end)
	Disconnect()
	ReleaseListenerHook()
	assert(ListenerEvents >= 2, "Expected listener lifecycle diagnostics.")
end)

local MergeStruct: Server.MergeStruct = {
	Data = 1,
	Field = 0,
	Float16Field = 0,
	Enum = "A",
	Nested = {
		Guh = 1,
		Array = table.create(10, 0),
	},
	AnotherNested = {
		Value = 1,
	},
	Map = {
		[{ 0 }] = 0,
	},
	Struct = {
		Data = 0,
		Array = { 0 },
		Nested = {
			Value = "hi",
		},
	},
}

FireAndPollExpect("Poll Reliable Client", Client.ClientPollEvent, Server.ClientPollEvent, MergeStruct)
FireAndPollExpect("Poll Reliable Server", Server.ServerPollEvent, Client.ServerPollEvent, MergeStruct)
FireAndPollExpect(
	"Poll Unreliable Client",
	Client.ClientUnreliablePollEvent,
	Server.ClientUnreliablePollEvent,
	MergeStruct
)
FireAndPollExpect(
	"Poll Unreliable Server",
	Server.ServerUnreliablePollEvent,
	Client.ServerUnreliablePollEvent,
	MergeStruct
)
FireAndPollExpect("Poll Empty Reliable Client", Client.ClientEmptyPollEvent, Server.ClientEmptyPollEvent, nil)
FireAndPollExpect("Poll Empty Reliable Server", Server.ServerEmptyPollEvent, Client.ServerEmptyPollEvent, nil)
FireAndPollExpect(
	"Poll Empty Unreliable Client",
	Client.ClientEmptyUnreliablePollEvent,
	Server.ClientEmptyUnreliablePollEvent,
	nil
)
FireAndPollExpect(
	"Poll Empty Unreliable Server",
	Server.ServerEmptyUnreliablePollEvent,
	Client.ServerEmptyUnreliablePollEvent,
	nil
)

RunClosure("Queue up and poll", function()
	local Expect = 10
	local Results = {
		Client = {},
		Server = {},
	}

	for _ = 1, Expect do
		Client.ClientPollEvent.Fire(MergeStruct)
		Server.ServerPollEvent.FireAll(MergeStruct)
	end

	task.wait(1 / 30)

	for Index, Value in Client.ServerPollEvent.Iter() do
		table.insert(Results.Client, Value)
	end

	for Index, Player, Value in Server.ClientPollEvent.Iter() do
		if tostring(Player) ~= "Player" then
			ErrorPrint(`Expected argument #1 to be Player, got {Player} instead.`)
		end

		table.insert(Results.Server, Value)
	end

	for _, Context in Results do
		if #Context ~= Expect then
			ErrorPrint(`Expected to poll {Expect} events, got {#Results.Client} instead`)
		end

		for _, Result in Context do
			if not Equals(Result, MergeStruct) then
				Fail("Closure", Expect, Result)
			end
		end
	end
end)

RunClosure("Ranges should be enforced", function()
	do
		local UpperSuccess = pcall(function()
			Client.NegativeRange.Write(11)
		end)

		local LowerSuccess = pcall(function()
			Client.NegativeRange.Write(-6)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected integer range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			Client.DecimalRange.Write(10.6)
		end)

		local LowerSuccess = pcall(function()
			Client.DecimalRange.Write(-5.6)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected decimal range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			Client.UnboundUpper.Write(2 ^ 53 + 1)
		end)

		local LowerSuccess = pcall(function()
			Client.UnboundUpper.Write(-1)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected unbound upper range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			Client.UnboundLower.Write(1)
		end)

		local LowerSuccess = pcall(function()
			Client.UnboundLower.Write(-(2 ^ 53 + 1))
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected unbound upper range to be enforced.")
		end
	end

	Client.ExactRange.Write(0)

	Client.DecimalRange.Write(-5.5)
	Client.DecimalRange.Write(10)

	Client.NegativeRange.Write(-5)
	Client.NegativeRange.Write(10)

	Client.UnboundUpper.Write(0)
	Client.UnboundUpper.Write(16777216)

	Client.UnboundLower.Write(-16777216)
	Client.UnboundLower.Write(0)
end)

RunClosure("Multi Dimensional Array", function()
	local Array = { { { 1, 2, 3, 4, 5, 6 } } }
	local Serialized = Client.MultiDimensionalArray.Write(Array)
	local Deserialized = Client.MultiDimensionalArray.Read(Serialized)

	if not Equals(Array, Deserialized) then
		ErrorPrint(`Expected: {Format(Array)}, got: {Format(Deserialized)} instead`)
	end
end)

do
	local foo: Client.Issue33_Foo = "One"
	local map: Client.Issue33_Map<number> = { [foo] = 0 }
	local enum: Client.Issue33_Enum<number> = { Tag = "Variant", field = foo }
	local struct: Client.Issue33_Struct<number> = { field = foo }

	FireAndExpectTuple(
		"Generics containing a unit enum value",
		Server.Issue33.Event,
		Client.Issue33.Event,
		map,
		enum,
		struct
	)
end

RunClosure("Export buffer trimming", function()
	local Buffer = Client.Byte.Write(0)
	if buffer.len(Buffer) ~= 1 then
		ErrorPrint(`Expected buffer to be trimmed to 1 byte`)
	end
end)

do
	local enum: Client.Indexers_TestEnums = "b b"
	local flags: Client.Indexers_TestFlags = { ["a a"] = true }
	local struct: Client.Indexers_TestStruct = {
		["z z"] = 0,
		["1 1"] = 1,
		["2 2"] = 2,
		["3 3"] = 3,
	}
	local tagged: Client.Indexers_TestTaggedEnums = {
		Type = "c c",
		Test = 1,
	}

	FireAndExpectTuple("Indexers", Server.Indexers.TestEvent, Client.Indexers.TestEvent, struct, flags, enum, tagged)
end

RunClosure("Buffer (Default, Fixed, Bounded)", function()
	local ExactBuffer = buffer.create(9)
	local BoundedBuffer = buffer.create(256)

	-- write some random bytes
	for offset = 0, 8, 4 do
		buffer.writeu8(ExactBuffer, offset, math.random(0, 2 ^ 30))
	end

	for offset = 0, 255, 4 do
		buffer.writeu8(BoundedBuffer, offset, math.random(0, 2 ^ 30))
	end

	-- test serdes
	do
		local Serialised = Client.Buffer.Write(BoundedBuffer)
		local Deserialised = Client.Buffer.Read(Serialised)
		assert(Equals(BoundedBuffer, Deserialised), `Default buffer serdes failed`)
	end

	do
		local Serialised = Client.ExactBuffer.Write(ExactBuffer)
		local Deserialised = Client.ExactBuffer.Read(Serialised)
		assert(Equals(ExactBuffer, Deserialised), `Fixed buffer serdes failed`)
	end

	do
		local Serialised = Client.BoundedBuffer.Write(BoundedBuffer)
		local Deserialised = Client.BoundedBuffer.Read(Serialised)
		assert(Equals(BoundedBuffer, Deserialised), `Bounded buffer serdes failed`)
	end
end)

RunClosure("RequirePolicies accepts Auth and PolicyGroup", function()
	Server.UseAuth("unittest", function()
		return true
	end)
	Server.Configure({ RequirePolicies = true })
	local Seen = 0
	local Release = Server.AuthedClient.On(function()
		Seen += 1
	end)
	Client.AuthedClient.Fire(1)
	Client.StepReplication()
	task.wait(1 / 30)
	Server.Configure({ RequirePolicies = false })
	Release()
	assert(Seen == 1, `An Auth-only endpoint was dropped by RequirePolicies ({Seen} delivered).`)
end)

RunClosure("A send that fails to serialize leaves the batch intact", function()
	local Seen = {}
	local Release = Server.StrideClient.On(function(_, Stride)
		table.insert(Seen, Stride)
	end)
	Client.StrideClient.Fire("Walk")
	local Sent = pcall(Client.StrideClient.Fire, "Fly" :: any)
	assert(not Sent, "Expected an invalid enum value to raise.")
	Client.StrideClient.Fire("Run")
	Client.StepReplication()
	task.wait(1 / 30)
	Release()
	assert(
		#Seen == 2 and Seen[1] == "Walk" and Seen[2] == "Run",
		`A failed write corrupted its batch: received {Format(Seen)}.`
	)
end)

RunClosure("Per-endpoint MaxPacketBytes measures the event, not the packet", function()
	local SmallSeen = 0
	local ReleaseSmall = Server.SmallCapClient.On(function()
		SmallSeen += 1
	end)
	local ReleaseLarge = Server.LargeClient.On(function() end)
	Client.LargeClient.Fire(string.rep("x", 200))
	Client.SmallCapClient.Fire(1)
	Client.StepReplication()
	task.wait(1 / 30)
	ReleaseSmall()
	ReleaseLarge()
	assert(SmallSeen == 1, "A small event was dropped because it shared a packet with a large one.")
end)

RunClosure("Broadcasts and unreliable sends do not leak queued bytes", function()
	for _ = 1, 50 do
		Server.ReliableServer.FireAll(1)
		Server.ReliableServer.FireList({ Shared.Player }, 1)
		Server.UnreliableServer.FireAll(1)
		Server.UnreliableServer.Fire(Shared.Player, 1)
	end
	Server.StepReplication()
	task.wait(1 / 30)
	local PlayerState = Server.Transport.Snapshot(Shared.Player)
	assert(PlayerState.QueuedBytes == 0, `Queued bytes survived a flush: {PlayerState.QueuedBytes}.`)
	for Key, State in Server.Transport.Snapshot() do
		assert(State.QueuedBytes == 0, `Peer {Key} still counts {State.QueuedBytes} queued bytes after a flush.`)
	end
end)

RunClosure("Invokes use the runtime timeout", function()
	Server.SlowFunction.On(function(_, Value)
		task.wait(0.4)
		return Value
	end)
	Client.Configure({ InvokeTimeoutSeconds = 0.1 })
	local Ok, Error = pcall(Client.SlowFunction.Invoke, 1)
	Client.Configure({ InvokeTimeoutSeconds = 0 })
	assert(not Ok, "Expected the invoke to time out.")
	assert(string.find(tostring(Error), "timed out", 1, true), `Expected a timeout error, got {tostring(Error)}.`)
	task.wait(0.5)
end)

RunClosure("Prediction ids survive wrapping past 65535", function()
	local Delivered = 0
	local Release = Server.UnconstrainedClient.On(function()
		Delivered += 1
	end)
	--> Test.cheeto fragments reliable packets at 64 bytes to exercise
	--> reassembly; large batches here would exceed MaxInFlightFragments.
	Client.Configure({ ReliableFragmentBytes = 1048576, MaxReliablePacketBytes = 1048576 })
	Server.Configure({ MaxReliablePacketBytes = 1048576 })
	local Total = 0
	for _ = 1, 7 do
		for _ = 1, 10000 do
			Client.UnconstrainedClient.Predict(1)
			Total += 1
		end
		task.wait(1 / 20)
	end
	task.wait(1 / 20)
	Client.Configure({ ReliableFragmentBytes = 64 })
	Release()
	assert(Delivered == Total, `Predicted events were dropped after the id wrapped: {Delivered} of {Total} delivered.`)
end)

RunClosure("Access fields on server-sent endpoints are rejected", function()
	local Result = process.exec(
		"lune",
		{ "run", Compiler, "../../test/Sources/ServerOnlyFieldBad", "--", "--yes" },
		{ cwd = "../src/CLI" }
	)
	assert(not Result.ok, "Expected Policy on a server-sent event to fail compilation.")
	assert(
		string.find(Result.stdout .. Result.stderr, "cannot be used here", 1, true) ~= nil,
		"Expected the compiler to explain why the field was rejected."
	)
end)

RunClosure("A call the server drops is answered with the reason", function()
	Server.Security.RegisterPolicy("guarded", function()
		return false, "NotAllowed"
	end)
	Server.GuardedFunction.On(function(_, Value)
		return Value
	end)
	Client.Configure({ InvokeTimeoutSeconds = 2 })
	local Started = os.clock()
	local Ok, Error = pcall(Client.GuardedFunction.Invoke, 1)
	Client.Configure({ InvokeTimeoutSeconds = 0 })
	assert(not Ok, "Expected the denied call to fail.")
	assert(string.find(tostring(Error), "NotAllowed", 1, true), `Expected the policy's reason, got {tostring(Error)}.`)
	assert(os.clock() - Started < 1, "The client waited for its timeout instead of the server's answer.")

	Server.Security.RegisterPolicy("guarded", function()
		return true
	end)
	assert(Client.GuardedFunction.Invoke(7) == 7, "Expected the allowed call to return its value.")
end)

RunClosure("A dropped prediction is rolled back with the reason", function()
	local Reasons = {}
	local Release = Client.Use("Rollback", function(Context)
		table.insert(Reasons, Context.Reason)
	end)
	Server.Security.RegisterPolicy("damage", nil :: any)
	Client.ReliableClient.Predict(3)
	Client.StepReplication()
	task.wait(1 / 30)
	Server.StepReplication()
	task.wait(1 / 30)
	Server.Security.RegisterPolicy("damage", AllowDamage)
	Release()
	assert(Reasons[1] == "PolicyRejected", `Expected a PolicyRejected rollback, got {tostring(Reasons[1])}.`)
end)

RunClosure("Every player receives the server handshake", function()
	Server.StepReplication()
	task.wait(1 / 30)
	local Peer = Client.Protocol.Info().Peer
	assert(Peer ~= nil, "The client never received the server's handshake.")
	assert(Peer.SchemaHash == Server.Schema.Hash, `Handshake carried {tostring(Peer.SchemaHash)}.`)
	assert(Peer.Compatible == true, "The client rejected a server on the same schema.")
	assert(#Server.Schema.Hash == 16, `Expected a 16-digit schema fingerprint, got {Server.Schema.Hash}.`)
end)

RunClosure("A peer on another schema is not decoded", function()
	local function Handshake(Hash: string): buffer
		local Payload = buffer.create(7 + #Hash)
		buffer.writeu8(Payload, 0, 2)
		buffer.writeu8(Payload, 1, 2)
		buffer.writeu16(Payload, 2, 2)
		buffer.writeu16(Payload, 4, 1)
		buffer.writeu8(Payload, 6, #Hash)
		buffer.writestring(Payload, 7, Hash)
		local Packet = buffer.create(4 + buffer.len(Payload))
		buffer.writeu8(Packet, 0, 254)
		buffer.writeu8(Packet, 1, 0)
		buffer.writeu8(Packet, 2, buffer.len(Payload))
		buffer.writeu8(Packet, 3, 0)
		buffer.copy(Packet, 4, Payload)
		return Packet
	end

	local Seen = 0
	local Release = Server.UnconstrainedClient.On(function()
		Seen += 1
	end)
	local ServerReliable = ServerEnvironment.Instances.CHEETO_RELIABLE_REMOTE.OnServerEvent
	FireSignalSync(ServerReliable, Shared.Player, Handshake("0000000000000000"), {})
	assert(Server.Protocol.Peers[Shared.Player].Compatible == false, "Expected the wrong fingerprint to be recorded.")
	Client.UnconstrainedClient.Fire(1)
	Client.StepReplication()
	task.wait(1 / 30)
	assert(Seen == 0, "The server decoded a packet from a peer on another schema.")

	--> Back to a matching handshake for the rest of the suite.
	Server.Protocol.Peers[Shared.Player] = nil
	Client.UnconstrainedClient.Fire(1)
	Client.StepReplication()
	task.wait(1 / 30)
	Release()
	assert(Seen == 1, "Expected delivery again once the peer matched.")
end)

RunClosure("Broadcast strings stay correct with string dictionaries", function()
	Server.Configure({ UseStringDictionaries = true })
	Client.Configure({ UseStringDictionaries = true })
	local Received = {}
	local Release = Client.ServerPair.On(function(First, Second)
		table.insert(Received, `{First}/{Second}`)
	end)
	Server.ServerPair.Fire(Shared.Player, "alpha", "alpha")
	Server.ServerPair.FireAll("beta", "beta")
	Server.ServerPair.Fire(Shared.Player, "alpha", "gamma")
	Server.StepReplication()
	task.wait(1 / 30)
	Release()
	Server.Configure({ UseStringDictionaries = false })
	Client.Configure({ UseStringDictionaries = false })
	assert(
		table.concat(Received, " ") == "alpha/alpha beta/beta alpha/gamma",
		`Strings were decoded against the wrong table: {table.concat(Received, " ")}`
	)
end)

RunClosure("Wire ids honour WireId, reservations, aliases and the lock", function()
	local Parser = require("../src/Parser")
	local Wire = require("../src/Generator/Wire")
	local function Parse(Source: string)
		return Parser.new("./", "WireIds.cheeto"):Parse(Source)
	end
	local function Ids(Body, Lock)
		local Result = {}
		for _, Assignment in Wire.Assign(Body.Value.Declarations, Lock) do
			Result[Assignment.Name] = Assignment.Id
		end
		return Result
	end
	local function Event(Name: string, Extra: string?): string
		return `event {Name} \{ From: Client, Type: Reliable, Call: SingleAsync, {Extra or ""} Data: u8 \}\n`
	end

	local Pinned = Ids(Parse(Event("A") .. Event("B", "WireId: 0,") .. Event("C", "ReservedId: 1,")))
	assert(Pinned.B == 0 and Pinned.A == 2 and Pinned.C == 3, `Unexpected ids: {Format(Pinned)}`)

	local Aliased = Parse(Event("A") .. Event("B", "DeprecatedId: 0,"))
	for _, Assignment in Wire.Assign(Aliased.Value.Declarations, nil) do
		if Assignment.Name == "B" then
			assert(Assignment.Alias == 0 and Assignment.Id ~= 0, "Expected B to keep answering on its old id.")
		end
	end

	--> Reordering and removing endpoints keeps the ids the lock recorded.
	local Lock = {
		endpoints = {
			A = { kind = "Event", channel = "Reliable", id = 0 },
			B = { kind = "Event", channel = "Reliable", id = 1 },
			Gone = { kind = "Event", channel = "Reliable", id = 2, retired = true },
		},
	}
	local Stable = Ids(Parse(Event("C") .. Event("B") .. Event("A")), Lock)
	assert(Stable.A == 0 and Stable.B == 1 and Stable.C == 3, `Lock ids were not kept: {Format(Stable)}`)

	local Conflict = pcall(Ids, Parse(Event("A", "WireId: 4,") .. Event("B", "WireId: 4,")))
	assert(not Conflict, "Expected two endpoints pinned to one id to fail.")
end)

RunClosure("Fuzz malformed packets", function()
	Server.Configure({
		MaxReliablePacketBytes = 256,
		MaxUnreliablePacketBytes = 256,
		RateLimitPerSecond = 0,
	})
	Client.Configure({
		MaxReliablePacketBytes = 256,
		MaxUnreliablePacketBytes = 256,
		RateLimitPerSecond = 0,
	})

	local ServerReliable = ServerEnvironment.Instances.CHEETO_RELIABLE_REMOTE.OnServerEvent
	local ServerUnreliable = ServerEnvironment.Instances.CHEETO_UNRELIABLE_REMOTE.OnServerEvent
	local ClientReliable = ClientEnvironment.Instances.CHEETO_RELIABLE_REMOTE.OnClientEvent
	local ClientUnreliable = ClientEnvironment.Instances.CHEETO_UNRELIABLE_REMOTE.OnClientEvent

	--> Seeded so a failure is reproducible. This closure drives 128 random
	--> buffers through every endpoint; unseeded, a packet that fails to
	--> terminate shows up as an intermittent hang that cannot be replayed and
	--> looks exactly like a regression in whatever change is being tested.
	--> Replay a specific run with CHEETO_FUZZ_SEED=<n>.
	local FuzzSeed = tonumber(process.env.CHEETO_FUZZ_SEED) or 0x0C4EE70
	math.randomseed(FuzzSeed)
	PrettyPrint("cyan", `Fuzzing with seed {FuzzSeed} (set CHEETO_FUZZ_SEED to replay)`)

	local Before = DroppedTotal(Server) + DroppedTotal(Client)
	local Oversized = buffer.create(257)
	FireSignalSync(ServerReliable, Shared.Player, Oversized, {})
	FireSignalSync(ClientReliable, Oversized, {})

	local Empty = buffer.create(0)
	FireSignalSync(ServerReliable, Shared.Player, Empty, { "not an instance" })
	FireSignalSync(ServerReliable, Shared.Player, Empty, "not a table")
	FireSignalSync(ClientReliable, Empty, { "not an instance" })
	FireSignalSync(ClientReliable, Empty, "not a table")

	--> CHEETO_FUZZ_N narrows the loop when bisecting a bad packet
	for _ = 1, tonumber(process.env.CHEETO_FUZZ_N) or 128 do
		local Size = math.random(1, 96)
		local Packet = RandomBuffer(Size)
		--> A random handshake frame can mark the peer incompatible; forget it
		--> so every iteration still reaches the decoder.
		table.clear(Server.Protocol.Peers)
		FireSignalSync(ServerReliable, Shared.Player, Packet, {})
		FireSignalSync(ServerUnreliable, Shared.Player, Packet, {})
		FireSignalSync(ClientReliable, Packet, {})
		FireSignalSync(ClientUnreliable, Packet, {})
	end

	local After = DroppedTotal(Server) + DroppedTotal(Client)
	if After <= Before then
		ErrorPrint("Expected malformed packet fuzzing to record dropped packets.")
	end
end)

require("./Datatypes")
require("./Security")
require("./Movement")
require("./Knockback")

PrettyPrint("green", `All tests passed successfully!`)

process.exit(0)
