type NumberRange = { Min: number, Max: number }
local NumberRange = {
	new = function(Min: number, Max: number?): NumberRange
		return {
			Min = Min,
			Max = Max or Min,
		}
	end,
}

export type Case = "Camel" | "Snake" | "Pascal"
export type Cases = {
	Fire: string,
	FireAll: string,
	FireList: string,
	FireExcept: string,
	FireGroup: string,
	On: string,
	Invoke: string,
	Predict: string,
	StepReplication: string,
	Next: string,
	Iter: string,
	Read: string,
	Write: string,
}

export type Primitive = {
	Bounds: NumberRange?,
	Integer: boolean?,
	Component: boolean,
	AllowsRange: boolean,
	AllowsOptional: boolean,
	AllowedComponents: number,
}

local Indexes = {
	Pascal = 1,
	Camel = 2,
	Snake = 3,
}

local Cases = {
	On = { "On", "on", "on" },
	Invoke = { "Invoke", "invoke", "invoke" },
	Predict = { "Predict", "predict", "predict" },
	Fire = { "Fire", "fire", "fire" },
	FireAll = { "FireAll", "fireAll", "fire_all" },
	FireList = { "FireList", "fireList", "fire_list" },
	FireExcept = { "FireExcept", "fireExcept", "fire_except" },
	FireGroup = { "FireGroup", "fireGroup", "fire_group" },
	StepReplication = { "StepReplication", "stepReplication", "step_replication" },
	Next = { "Next", "next", "next" },
	Iter = { "Iter", "iter", "iter" },
	Read = { "Read", "read", "read" },
	Write = { "Write", "write", "write" },
}

local Primitives: { [string]: Primitive } = {
	u8 = {
		Bounds = NumberRange.new(0, 255),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	u16 = {
		Bounds = NumberRange.new(0, 65535),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	u32 = {
		Bounds = NumberRange.new(0, 4294967295),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	i8 = {
		Bounds = NumberRange.new(-128, 127),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	i16 = {
		Bounds = NumberRange.new(-32768, 32767),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	i32 = {
		Bounds = NumberRange.new(-2147483648, 2147483647),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	f16 = {
		Bounds = NumberRange.new(-65504, 65504),
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	f32 = {
		Bounds = NumberRange.new(-16777216, 16777216),
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	f64 = {
		Bounds = NumberRange.new(-2 ^ 53, 2 ^ 53),
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	boolean = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	string = {
		Bounds = NumberRange.new(0, 4294967295),
		Integer = true,
		Component = false,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	vector = {
		Component = false,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 1,
	},
	buffer = {
		Bounds = NumberRange.new(0, 4294967295),
		Integer = true,
		Component = false,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	Color3 = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	CFrame = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 2,
	},
	Instance = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	BrickColor = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	unknown = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = false,
		AllowedComponents = 0,
	},
	DateTime = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	DateTimeMillis = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	Vector2 = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 1,
	},
	Vector2int16 = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	Vector3int16 = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	Region3 = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	Region3int16 = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	NumberSequenceKeypoint = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	ColorSequenceKeypoint = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	UDim = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	UDim2 = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	Rect = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	Ray = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	NumberRange = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	PhysicalProperties = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	Axes = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	Faces = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	EnumItem = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	TweenInfo = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	Font = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	NumberSequence = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
	ColorSequence = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
	},
}

local ProfileDefaults = {
	Development = {
		MaxPacketBytes = 1048576,
		MaxUnreliablePacketBytes = 1000,
		RateLimitPerSecond = 0,
		RateLimitBurst = 0,
		MaxQueuedEvents = 256,
		MaxQueuedBytes = 262144,
		MaxBurstBytes = 65536,
		MaxPendingInvokes = 256,
		InvokeTimeoutSeconds = 0,
	},
	Production = {
		MaxPacketBytes = 262144,
		MaxUnreliablePacketBytes = 1000,
		RateLimitPerSecond = 120,
		RateLimitBurst = 240,
		MaxQueuedEvents = 128,
		MaxQueuedBytes = 131072,
		MaxBurstBytes = 32768,
		MaxPendingInvokes = 64,
		InvokeTimeoutSeconds = 10,
	},
	Competitive = {
		MaxPacketBytes = 65536,
		MaxUnreliablePacketBytes = 900,
		RateLimitPerSecond = 60,
		RateLimitBurst = 120,
		MaxQueuedEvents = 64,
		MaxQueuedBytes = 65536,
		MaxBurstBytes = 16384,
		MaxPendingInvokes = 32,
		InvokeTimeoutSeconds = 5,
	},
}

return {
	Keywords = {
		map = true,
		set = true,
		type = true,
		enum = true,
		struct = true,

		event = true,
		["function"] = true,
		channel = true,

		scope = true,
		option = true,

		export = true,
	},

	GetProfile = function(Profile: string?, Preset: string?)
		local Name = Profile or (if Preset == "Maximum" then "Competitive" else "Development")
		return Name, ProfileDefaults[Name] or ProfileDefaults.Development
	end,
	Primtives = Primitives,
	GetCasing = function(Case: Case): Cases
		local Index = Indexes[Case]
		if not Index then
			error(`Unknown casing "{Case}", expectd one of "Pascal" or "Camel" or "Snake"`)
		end

		local Casing: any = {}
		for Key, Options in Cases do
			Casing[Key] = Options[Index]
		end
		return Casing
	end,
}
