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
	TweenInfo = TweenInfo,
	_G = {},
	task = task,
	typeof = MockTypeof,
	require = function()
		error("require is not supported")
	end,
}

--> The generated module resolves ReplicatedStorage/RunService and the two
--> remotes at load time, even though the export Read/Write functions never touch
--> the network. Provide a minimal, loop-free game so init succeeds and the
--> process still exits cleanly (no Heartbeat driver task).
do
	local function StubSignal()
		return {
			Connect = function()
				return { Disconnect = function() end }
			end,
		}
	end
	local function StubRemote()
		return {
			OnClientEvent = StubSignal(),
			OnServerEvent = StubSignal(),
			FireServer = function() end,
			FireClient = function() end,
			FireAllClients = function() end,
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
				return false
			end,
			IsRunning = function()
				return true
			end,
		},
		Players = {
			PlayerRemoving = StubSignal(),
			GetPlayers = function()
				return {}
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
--> Optional-present exercises the optional wrapper around a new type. The nil
--> case is not tested here: cheeto's export Read cannot roundtrip a top-level nil
--> optional (the existing `u16?` export fails identically), so it is a property
--> of the export API, not of these datatype prefabs.
Roundtrip("UDim2? (present)", "EOptionalUDim", roblox.UDim2.new(1, 0, 1, 0))
Roundtrip("Vector2[4]", "EArrayVector2", {
	roblox.Vector2.new(1, 1),
	roblox.Vector2.new(2, 2),
	roblox.Vector2.new(3, 3),
	roblox.Vector2.new(4, 4),
})

stdio.write(`{stdio.color("green")}All datatype roundtrips passed!{stdio.color("reset")}\n`)

return true
