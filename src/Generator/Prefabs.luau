--!native
--!optimize 2

local Blocks = require("./Blocks")
local Parser = require("../Parser")

type Block = Blocks.Block
type Writer = (Value: string, Block: Block, Range: NumberRange?, Components: { string }?) -> ()
type Reader = (Variable: string, Block: Block, Range: NumberRange?, Components: { string }?) -> ()
type Generate = (
	Declaration: Parser.Primitive,
	Variable: string?,
	Read: Block,
	Write: Block,
	WriteValidations: boolean?
) -> ()

type TypePrefab = {
	Read: Reader,
	Write: Writer,
}

type AssertPrefab = {
	Lower: string,
	Upper: string,
	Exact: string?,
}

type AssertGenerator = (Variable: string, ...any) -> AssertPrefab

local SEND_BUFFER = "SendBuffer"
local RECIEVE_BUFFER = "RecieveBuffer"
local SEND_POSITION = "SendOffset"

local BYTE = 1
local SHORT = 2
local INTEGER = 4
local HALF_FLOAT = 2
local FLOAT = 4
local DOUBLE = 8

local Types = {}
local Asserts = {
	number = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if {Variable} < {Min} then error(\`Expected "{Variable}" to be larger than {Min}, got \{{Variable}} instead.\`) end`,
			Upper = `if {Variable} > {Max} then error(\`Expected "{Variable}" to be smaller than {Max}, got \{{Variable}} instead.\`) end`,
			Exact = `if {Variable} ~= {Max} then error(\`Expected "{Variable}" to be equal to {Max}, got \{{Variable}\} instead.\`) end`,
		}
	end,

	string = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if #{Variable} < {Min} then error(\`Expected length of "{Variable}" to be larger than {Min}, got \{#{Variable}} instead.\`) end`,
			Upper = `if #{Variable} > {Max} then error(\`Expected length of "{Variable}" to be smaller than {Max}, got \{#{Variable}} instead.\`) end`,
			Exact = `if #{Variable} ~= {Max} then error(\`Expected length of "{Variable}" to equal to {Max}, got \{#{Variable}} instead.\`) end`,
		}
	end,

	vector = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if {Variable}.Magnitude < {Min} then error(\`Expected magnitude of "{Variable}" to be larger than {Min}, got \{{Variable}.Magnitude} instead.\`) end`,
			Upper = `if {Variable}.Magnitude > {Max} then error(\`Expected magnitude of "{Variable}" to be smaller than {Max}, got \{{Variable}.Magnitude} instead.\`) end`,
			Exact = `if {Variable}.Magnitude ~= {Max} then error(\`Expected magnitude of "{Variable}" to equal to {Max}, got \{{Variable}.Magnitude} instead.\`) end`,
		}
	end,

	buffer = function(Variable: string, Min: number, Max: number): AssertPrefab
		return {
			Lower = `if buffer.len({Variable}) < {Min} then error(\`Expected size of "{Variable}" to be larger than {Min}, got \{buffer.len({Variable})} instead.\`) end`,
			Upper = `if buffer.len({Variable}) > {Max} then error(\`Expected size of "{Variable}" to be smaller than {Max}, got \{buffer.len({Variable})} instead.\`) end`,
			Exact = `if buffer.len({Variable}) ~= {Max} then error(\`Expected size of "{Variable}" to equal to {Max}, got \{buffer.len({Variable})} instead.\`) end`,
		}
	end,

	Instance = function(Variable: string, Class: string): AssertPrefab
		local TypeAssertion =
			`if typeof({Variable}) ~= "Instance" then error(\`Expected an Instance, got \{typeof({Variable})} instead.\`) end`
		return {
			Lower = `error("Something has gone wrong")`,
			Upper = `error("Something has gone wrong")`,
			Exact = if Class == "Instance"
				then TypeAssertion
				else `{TypeAssertion}\nif not {Variable}:IsA("{Class}") then error(\`Expected an Instance of type "{Class}", got "\{{Variable}.ClassName}" instead.\`) end`,
		}
	end,
}
local Structures = {
	Array = nil :: any,
}
local Primitives: { [string]: {
	Type: string | (Declaration: Parser.Primitive) -> string,
	Generate: Generate,
} } = {}

local NumberTypeBounds = {
	{ Bits = 8, Maximum = 255, Type = "u8" },
	{ Bits = 16, Maximum = 65535, Type = "u16" },
	{ Bits = 32, Maximum = 4294967295, Type = "u32" },
}

local function GetTypeToUse(UpperSize: number): TypePrefab
	for _, NumberType in NumberTypeBounds do
		if NumberType.Maximum >= UpperSize then
			return Types[NumberType.Type]
		end
	end

	error("Value is too large to be written to a buffer.")
end

local function GetLengthBytes(UpperSize: number): number
	for _, NumberType in NumberTypeBounds do
		if NumberType.Maximum >= UpperSize then
			return NumberType.Bits // 8
		end
	end

	error("Value is too large to be written to a buffer.")
end

local function GetTypeToUseByBits(UpperBits: number): TypePrefab
	for _, NumberType in NumberTypeBounds do
		if NumberType.Bits >= UpperBits then
			return Types[NumberType.Type]
		end
	end

	error("Value is too large to be written to a buffer.")
end

local function GeneratePrimitivePrefab(Type: string, Prefab: TypePrefab, AssertGenerator: AssertGenerator?): Generate
	return function(
		Declaration: Parser.Primitive,
		Variable: string?,
		Read: Block,
		Write: Block,
		WriteValidations: boolean?
	)
		local Value = Declaration.Value
		local Tokens = Declaration.Tokens
		local Variable = Variable or "Value"

		local Range = Value.Range
		local Class = Value.Class
		local Components = Value.Components
		local Primitive = Tokens.Primitive.Value
		local IsVariableSize = (Range and Range.Max ~= Range.Min)

		local function GenerateValidation(Block: Block, Variable: string)
			if Block == Write and WriteValidations ~= true then
				return
			end

			if Block == Write and Type ~= "any" then
				Block:Compare(`typeof({Variable})`, `"{Type}"`, "Not")
					:Line(`error(\`Expected {Variable} to be of type {Type}, got \{type({Variable})} instead.\`)`)
					:End()
			end

			if not AssertGenerator then
				return
			end

			if Range then
				local Assert = AssertGenerator(Variable, Range.Min, Range.Max)
				if not IsVariableSize and Assert.Exact then
					Block:Line(Assert.Exact)
				else
					Block:Line(Assert.Lower)
					Block:Line(Assert.Upper)
				end
			elseif Primitive == "Instance" and Class then
				local Assert = AssertGenerator(Variable, Class)
				if Block == Write then
					Block:Compare(Variable, "nil", "Not"):Multiline(Assert.Exact, Block.Indent + 1):End()
				else
					Block:Multiline(Assert.Exact, Block.Indent)
				end
			end
		end

		GenerateValidation(Write, Variable)
		Prefab.Read(Variable, Read, Range, Components)
		Prefab.Write(Variable, Write, Range, Components)
		GenerateValidation(Read, Variable)
	end
end

local function GenerateNumberGenerator(Type: string, Size: number): (TypePrefab, { Type: string, Generate: Generate })
	local Prefix = string.sub(Type, 1, 1)
	local IsInteger = Prefix == "u" or Prefix == "i"
	local IsVarintCandidate = IsInteger and Size > BYTE and (string.sub(Type, 2) == "16" or string.sub(Type, 2) == "32")
	local IsSigned = Prefix == "i"
	local Prefab = {
		Read = function(Variable: string, Block: Block)
			if IsVarintCandidate then
				Block:Declare(Variable, true)
				Block:Line("if UseVarints() then")
				Block:Line(`{Variable} = {IsSigned and "ReadSignedVarint" or "ReadVarint"}()`, Block.Indent + 1)
				Block:Line("else")
				Block:Line(`{Variable} = buffer.read{Type}({RECIEVE_BUFFER}, Read({Size}))`, Block.Indent + 1)
				Block:Line("end")
			else
				Block:Line(`{Block:Declare(Variable)} = buffer.read{Type}({RECIEVE_BUFFER}, {Block:Read(Size)})`)
			end
		end,
		Write = function(Value: string, Block: Block)
			if IsVarintCandidate then
				Block:Line("if UseVarints() then")
				Block:Line(`{IsSigned and "WriteSignedVarint" or "WriteVarint"}({Value})`, Block.Indent + 1)
				Block:Line("else")
				Block:Line(`local Offset = Allocate({Size})`, Block.Indent + 1)
				Block:Line(`buffer.write{Type}({SEND_BUFFER}, Offset, {Value})`, Block.Indent + 1)
				Block:Line("end")
			else
				Block:Line(`buffer.write{Type}({SEND_BUFFER}, {Block:Allocate(Size)}, {Value})`)
			end
		end,
	}

	local Primitive = {
		Type = "number",
		Generate = GeneratePrimitivePrefab("number", Prefab, Asserts.number),
	}

	return Prefab, Primitive
end

--> Numbers
Types.u8, Primitives.u8 = GenerateNumberGenerator("u8", BYTE)
Types.u16, Primitives.u16 = GenerateNumberGenerator("u16", SHORT)
Types.u32, Primitives.u32 = GenerateNumberGenerator("u32", INTEGER)

Types.i8, Primitives.i8 = GenerateNumberGenerator("i8", BYTE)
Types.i16, Primitives.i16 = GenerateNumberGenerator("i16", SHORT)
Types.i32, Primitives.i32 = GenerateNumberGenerator("i32", INTEGER)

Types.f32, Primitives.f32 = GenerateNumberGenerator("f32", FLOAT)
Types.f64, Primitives.f64 = GenerateNumberGenerator("f64", DOUBLE)

Types.f16 = {
	Read = function(Variable: string, Block: Block)
		Block:Line(`local Encoded = buffer.readu16({RECIEVE_BUFFER}, {Block:Read(HALF_FLOAT)})`)
		Block:Declare(Variable, true)
		Block:Line(`local MantissaExponent = Encoded % 0x8000`)
		Block:Compare("MantissaExponent", "0b0_11111_0000000000 ", "Equals")
			:Compare("Encoded // 0x8000", "1", "Equals")
			:Line(`{Variable} = -math.huge`)
			:Branch("Default")
			:Line(`{Variable} = math.huge`)
			:End()
			:Branch("Conditional", "MantissaExponent", "0b1_11111_0000000000  ", "Equals")
			:Line(`{Variable} = 0 / 0`)
			:Branch("Conditional", "MantissaExponent", "0b0_00000_0000000000  ", "Equals")
			:Line(`{Variable} = 0`)
			:Branch("Default")
			:Lines({
				"local Mantissa = MantissaExponent % 0x400\n",
				"local Exponent = MantissaExponent // 0x400\n",
				"local Fraction;\n",
				"if Exponent == 0 then\n",
				"	Fraction = Mantissa / 0x400\n",
				"else\n",
				"	Fraction = Mantissa / 0x800 + 0.5\n",
				"end\n",
				"local Result = math.ldexp(Fraction, Exponent - 14)\n",
			}, Block.Indent + 1)
			:Line(`{Variable} = if Encoded // 0x8000 == 1 then -Result else Result`)
			:End()
	end,
	Write = function(Value: string, Block: Block)
		local Allocation = Block:Allocate(HALF_FLOAT)
		Block:Compare(Value, "65504", "Greater")
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, 0b0_11111_0000000000)`)
			:Branch("Conditional", Value, "-65504", "Less")
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, 0b1_11111_0000000000)`)
			:Branch("Conditional", Value, Value, "Not")
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, 0b1_11111_0000000001)`)
			:Branch("Conditional", Value, "0", "Equals")
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, 0)`)
			:Branch("Default")
			:Line(`local float = {Value}`)
			:Lines({
				"local Abosulte = math.abs(float)\n",
				"local Interval = math.ldexp(1, math.floor(math.log(Abosulte, 2)) - 10)\n",
				"local RoundedValue = (Abosulte // Interval) * Interval\n",
				"local Fraction, Exponent = math.frexp(RoundedValue)\n",
				"Exponent += 14\n",
				"local Mantissa = math.round(if Exponent <= 0\n",
				"	then Fraction * 0x400 / math.ldexp(1, math.abs(Exponent))\n",
				"	else Fraction * 0x800) % 0x400\n",
				"local Result = Mantissa\n",
				"	+ math.max(Exponent, 0) * 0x400\n",
				"	+ if float < 0 then 0x8000 else 0\n",
			}, Block.Indent + 1)
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, Result)`)
			:End()
	end,
}

Primitives.f16 = {
	Type = "number",
	Generate = GeneratePrimitivePrefab("number", Types.f16, Asserts.number),
}

--> Boolean
do
	Types.boolean = {
		Read = function(Variable: string, Block: Block)
			Block:Declare(Variable, true)
			Block:Line("if UseBitPacking() then")
			Block:Line(`{Variable} = ReadBit()`, Block.Indent + 1)
			Block:Line("else")
			Block:Line(`{Variable} = (buffer.readu8({RECIEVE_BUFFER}, Read({BYTE})) == 1)`, Block.Indent + 1)
			Block:Line("end")
		end,
		Write = function(Value: string, Block: Block)
			Block:Line("if UseBitPacking() then")
			Block:Line(`WriteBit({Value})`, Block.Indent + 1)
			Block:Line("else")
			Block:Line(`local Offset = Allocate({BYTE})`, Block.Indent + 1)
			Block:Line(`buffer.writeu8({SEND_BUFFER}, Offset, {Value} and 1 or 0)`, Block.Indent + 1)
			Block:Line("end")
		end,
	}

	Primitives.boolean = {
		Type = "boolean",
		Generate = GeneratePrimitivePrefab("boolean", Types.boolean),
	}
end

--> String
do
	Types.string = {
		Read = function(Variable: string, Block: Block, Range: NumberRange?)
			--> Fixed size string
			if Range and Range.Min == Range.Max then
				Block:Line(
					`{Block:Declare(Variable)} = buffer.readstring({RECIEVE_BUFFER}, {Block:Read(Range.Min)}, {Range.Min})`
				)
				return
			end

			local Upper = Range and Range.Max or (2 ^ 16 - 1)
			local LengthBytes = GetLengthBytes(Upper)

			Block:Line(`{Block:Declare(Variable)} = ReadStringValue({LengthBytes})`)
		end,
		Write = function(Value: string, Block: Block, Range: NumberRange?)
			if Range and Range.Min == Range.Max then
				Block:Line(`buffer.writestring({SEND_BUFFER}, {Block:Allocate(Range.Min)}, {Value}, {Range.Min})`)
				return
			end

			local Upper = Range and Range.Max or (2 ^ 16 - 1)
			local LengthBytes = GetLengthBytes(Upper)
			Block:Line(`WriteStringValue({Value}, {LengthBytes})`)
		end,
	}

	Primitives.string = {
		Type = "string",
		Generate = GeneratePrimitivePrefab("string", Types.string, Asserts.string),
	}
end

--> Vector
do
	Types.vector = {
		Read = function(Variable: string, Block: Block, _, Components: { string }?)
			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[#Components]] or Prefab
			end

			Prefab.Read("X", Block)
			Prefab.Read("Y", Block)
			Prefab.Read("Z", Block)
			Block:Line(`{Block:Declare(Variable)} = Vector3.new(X, Y, Z)`)
		end,
		Write = function(Value: string, Block: Block, _, Components: { string }?)
			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[#Components]] or Prefab
			end

			Block:Line(`local Vector = {Value}`)
			Prefab.Write("Vector.X", Block)
			Prefab.Write("Vector.Y", Block)
			Prefab.Write("Vector.Z", Block)
		end,
	}

	Primitives.vector = {
		Type = "Vector3",
		Generate = GeneratePrimitivePrefab("Vector3", Types.vector, Asserts.vector),
	}
end

--> Buffer
do
	Types.buffer = {
		Read = function(Variable: string, Block: Block, Range: NumberRange?)
			if Range and Range.Min == Range.Max then
				local Length = Range.Max
				Block:Line(`{Block:Declare(Variable)} = buffer.create({Length})`)
				Block:Line(`buffer.copy({Variable}, 0, {RECIEVE_BUFFER}, {Block:Read(Length)}, {Length})`)
				return
			end

			local Upper = Range and Range.Max or (2 ^ 16 - 1)
			local LengthBytes = GetLengthBytes(Upper)
			Block:Line(`local Length = ReadLength({LengthBytes})`)
			Block:Line(`{Block:Declare(Variable)} = buffer.create(Length)`)
			Block:Line(`buffer.copy({Variable}, 0, {RECIEVE_BUFFER}, Read(Length), Length)`)
		end,
		Write = function(Value: string, Block: Block, Range: NumberRange?)
			if Range and Range.Min == Range.Max then
				Block:Line(`buffer.copy({SEND_BUFFER}, {Block:Allocate(Range.Max)}, {Value}, 0, {Range.Max})`)
				return
			end

			local Upper = Range and Range.Max or (2 ^ 16 - 1)
			local LengthBytes = GetLengthBytes(Upper)
			Block:Line(`local Length = buffer.len({Value})`)
			Block:Line(`WriteLength(Length, {LengthBytes})`)
			Block:Line(`Allocate(Length)`)
			Block:Line(`buffer.copy({SEND_BUFFER}, {SEND_POSITION}, {Value}, 0, Length)`)
		end,
	}

	Primitives.buffer = {
		Type = "buffer",
		Generate = GeneratePrimitivePrefab("buffer", Types.buffer, Asserts.buffer),
	}
end

--> CFrame
do
	Types.CFrame = {
		Read = function(Variable: string, Block: Block, _, Components: { string }?)
			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[1]]
			end

			Types.vector.Read("Position", Block, nil, Components)
			Prefab.Read("rX", Block)
			Prefab.Read("rY", Block)
			Prefab.Read("rZ", Block)
			Block:Line(`{Block:Declare(Variable)} = CFrame.new(Position) * CFrame.fromOrientation(rX, rY, rZ)`)
		end,
		Write = function(Value: string, Block: Block, _, Components: { string }?)
			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[1]]
			end

			Types.vector.Write(`{Value}.Position`, Block, nil, Components)
			Block:Line(`local rX, rY, rZ = {Value}:ToOrientation()`)
			Prefab.Write("rX", Block)
			Prefab.Write("rY", Block)
			Prefab.Write("rZ", Block)
		end,
	}

	Primitives.CFrame = {
		Type = "CFrame",
		Generate = GeneratePrimitivePrefab("CFrame", Types.CFrame),
	}
end

--> Color3
do
	Types.Color3 = {
		Read = function(Variable: string, Block: Block)
			local R = Block:Read(BYTE)
			local G = Block:Read(BYTE)
			local B = Block:Read(BYTE)
			Block:Line(
				`{Block:Declare(Variable)} = Color3.fromRGB(buffer.readu8({RECIEVE_BUFFER}, {R}), buffer.readu8({RECIEVE_BUFFER}, {G}), buffer.readu8({RECIEVE_BUFFER}, {B}))`
			)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local Color = {Value}`)
			Types.u8.Write("Color.R * 255", Block)
			Types.u8.Write("Color.G * 255", Block)
			Types.u8.Write("Color.B * 255", Block)
		end,
	}

	Primitives.Color3 = {
		Type = "Color3",
		Generate = GeneratePrimitivePrefab("Color3", Types.Color3),
	}
end

--> DateTime
do
	Types.DateTime = {
		Read = function(Variable: string, Block: Block)
			local UnixTimestamp = Block:Read(DOUBLE)
			Block:Line(
				`{Block:Declare(Variable)} = DateTime.fromUnixTimestamp(buffer.readf64({RECIEVE_BUFFER}, {UnixTimestamp}))`
			)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local DateTime = {Value}`)
			Types.f64.Write(`DateTime.UnixTimestamp`, Block)
		end,
	}

	Primitives.DateTime = {
		Type = "DateTime",
		Generate = GeneratePrimitivePrefab("DateTime", Types.DateTime),
	}
end

--> DateTimeMillis
do
	Types.DateTimeMillis = {
		Read = function(Variable: string, Block: Block)
			local UnixTimestampMillis = Block:Read(DOUBLE)
			Block:Line(
				`{Block:Declare(Variable)} = DateTime.fromUnixTimestampMillis(buffer.readf64({RECIEVE_BUFFER}, {UnixTimestampMillis}))`
			)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local DateTimeMillis = {Value}`)
			Types.f64.Write(`DateTimeMillis.UnixTimestampMillis`, Block)
		end,
	}

	Primitives.DateTimeMillis = {
		Type = "DateTime",
		Generate = GeneratePrimitivePrefab("DateTime", Types.DateTimeMillis),
	}
end

--> BrickColor
do
	Types.BrickColor = {
		Read = function(Variable: string, Block: Block)
			Types.u16.Read("BrickColorNumber", Block)
			Block:Line(`{Block:Declare(Variable)} = BrickColor.new(BrickColorNumber)`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local BrickColor = {Value}`)
			Types.u16.Write("BrickColor.Number", Block)
		end,
	}

	Primitives.BrickColor = {
		Type = "BrickColor",
		Generate = GeneratePrimitivePrefab("BrickColor", Types.BrickColor),
	}
end

--> Instance
do
	Types.Instance = {
		Read = function(Variable: string, Block: Block)
			--Block:Line("RecieveInstanceCursor += 1")
			Block:Line(`{Block:Declare(Variable)} = RecieveInstances[RecieveInstanceCursor]`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`table.insert(SendInstances, {Value} or Null)`)
		end,
	}

	Primitives.Instance = {
		Type = function(Declaration)
			return Declaration.Value.Class
		end,
		Generate = GeneratePrimitivePrefab("any", Types.Instance, Asserts.Instance),
	}
end

--> unknown
do
	Types.unknown = {
		Read = function(Variable: string, Block: Block)
			Block:Line("RecieveInstanceCursor += 1")
			Block:Line(`{Block:Declare(Variable)} = RecieveInstances[RecieveInstanceCursor]`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`table.insert(SendInstances, if {Value} == nil then Null else {Value})`)
		end,
	}

	Primitives.unknown = {
		Type = "any",
		Generate = GeneratePrimitivePrefab("any", Types.unknown),
	}
end

--> Vector2
do
	Types.Vector2 = {
		Read = function(Variable: string, Block: Block, _, Components: { string }?)
			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[#Components]] or Prefab
			end

			Prefab.Read("X", Block)
			Prefab.Read("Y", Block)
			Block:Line(`{Block:Declare(Variable)} = Vector2.new(X, Y)`)
		end,
		Write = function(Value: string, Block: Block, _, Components: { string }?)
			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[#Components]] or Prefab
			end

			Prefab.Write(`{Value}.X`, Block)
			Prefab.Write(`{Value}.Y`, Block)
		end,
	}

	Primitives.Vector2 = {
		Type = "Vector2",
		Generate = GeneratePrimitivePrefab("Vector2", Types.Vector2),
	}
end

--> Vector2int16
do
	Types.Vector2int16 = {
		Read = function(Variable: string, Block: Block)
			Types.i16.Read("X", Block)
			Types.i16.Read("Y", Block)
			Block:Line(`{Block:Declare(Variable)} = Vector2int16.new(X, Y)`)
		end,
		Write = function(Value: string, Block: Block)
			Types.i16.Write(`{Value}.X`, Block)
			Types.i16.Write(`{Value}.Y`, Block)
		end,
	}

	Primitives.Vector2int16 = {
		Type = "Vector2int16",
		Generate = GeneratePrimitivePrefab("Vector2int16", Types.Vector2int16),
	}
end

--> Vector3int16
do
	Types.Vector3int16 = {
		Read = function(Variable: string, Block: Block)
			Types.i16.Read("X", Block)
			Types.i16.Read("Y", Block)
			Types.i16.Read("Z", Block)
			Block:Line(`{Block:Declare(Variable)} = Vector3int16.new(X, Y, Z)`)
		end,
		Write = function(Value: string, Block: Block)
			Types.i16.Write(`{Value}.X`, Block)
			Types.i16.Write(`{Value}.Y`, Block)
			Types.i16.Write(`{Value}.Z`, Block)
		end,
	}

	Primitives.Vector3int16 = {
		Type = "Vector3int16",
		Generate = GeneratePrimitivePrefab("Vector3int16", Types.Vector3int16),
	}
end

--> Region3 (axis-aligned; serialized as min/max corners)
do
	Types.Region3 = {
		Read = function(Variable: string, Block: Block)
			Types.vector.Read("Minimum", Block)
			Types.vector.Read("Maximum", Block)
			Block:Line(`{Block:Declare(Variable)} = Region3.new(Minimum, Maximum)`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local Region = {Value}`)
			Block:Line(`local RegionHalf = Region.Size / 2`)
			Block:Line(`local RegionCenter = Region.CFrame.Position`)
			Types.vector.Write("RegionCenter - RegionHalf", Block)
			Types.vector.Write("RegionCenter + RegionHalf", Block)
		end,
	}

	Primitives.Region3 = {
		Type = "Region3",
		Generate = GeneratePrimitivePrefab("Region3", Types.Region3),
	}
end

--> UDim
do
	Types.UDim = {
		Read = function(Variable: string, Block: Block)
			Types.f32.Read("Scale", Block)
			Types.i32.Read("Offset", Block)
			Block:Line(`{Block:Declare(Variable)} = UDim.new(Scale, Offset)`)
		end,
		Write = function(Value: string, Block: Block)
			Types.f32.Write(`{Value}.Scale`, Block)
			Types.i32.Write(`{Value}.Offset`, Block)
		end,
	}

	Primitives.UDim = {
		Type = "UDim",
		Generate = GeneratePrimitivePrefab("UDim", Types.UDim),
	}
end

--> UDim2
do
	Types.UDim2 = {
		Read = function(Variable: string, Block: Block)
			Types.UDim.Read("HorizontalUDim", Block)
			Types.UDim.Read("VerticalUDim", Block)
			Block:Line(
				`{Block:Declare(Variable)} = UDim2.new(HorizontalUDim.Scale, HorizontalUDim.Offset, VerticalUDim.Scale, VerticalUDim.Offset)`
			)
		end,
		Write = function(Value: string, Block: Block)
			Types.UDim.Write(`{Value}.X`, Block)
			Types.UDim.Write(`{Value}.Y`, Block)
		end,
	}

	Primitives.UDim2 = {
		Type = "UDim2",
		Generate = GeneratePrimitivePrefab("UDim2", Types.UDim2),
	}
end

--> Rect
do
	Types.Rect = {
		Read = function(Variable: string, Block: Block)
			Types.Vector2.Read("MinimumCorner", Block)
			Types.Vector2.Read("MaximumCorner", Block)
			Block:Line(`{Block:Declare(Variable)} = Rect.new(MinimumCorner, MaximumCorner)`)
		end,
		Write = function(Value: string, Block: Block)
			Types.Vector2.Write(`{Value}.Min`, Block)
			Types.Vector2.Write(`{Value}.Max`, Block)
		end,
	}

	Primitives.Rect = {
		Type = "Rect",
		Generate = GeneratePrimitivePrefab("Rect", Types.Rect),
	}
end

--> Ray
do
	Types.Ray = {
		Read = function(Variable: string, Block: Block)
			Types.vector.Read("Origin", Block)
			Types.vector.Read("Direction", Block)
			Block:Line(`{Block:Declare(Variable)} = Ray.new(Origin, Direction)`)
		end,
		Write = function(Value: string, Block: Block)
			Types.vector.Write(`{Value}.Origin`, Block)
			Types.vector.Write(`{Value}.Direction`, Block)
		end,
	}

	Primitives.Ray = {
		Type = "Ray",
		Generate = GeneratePrimitivePrefab("Ray", Types.Ray),
	}
end

--> NumberRange
do
	Types.NumberRange = {
		Read = function(Variable: string, Block: Block)
			Types.f32.Read("Minimum", Block)
			Types.f32.Read("Maximum", Block)
			Block:Line(`{Block:Declare(Variable)} = NumberRange.new(Minimum, Maximum)`)
		end,
		Write = function(Value: string, Block: Block)
			Types.f32.Write(`{Value}.Min`, Block)
			Types.f32.Write(`{Value}.Max`, Block)
		end,
	}

	Primitives.NumberRange = {
		Type = "NumberRange",
		Generate = GeneratePrimitivePrefab("NumberRange", Types.NumberRange),
	}
end

--> PhysicalProperties
do
	Types.PhysicalProperties = {
		Read = function(Variable: string, Block: Block)
			Types.f32.Read("Density", Block)
			Types.f32.Read("Friction", Block)
			Types.f32.Read("Elasticity", Block)
			Types.f32.Read("FrictionWeight", Block)
			Types.f32.Read("ElasticityWeight", Block)
			Block:Line(
				`{Block:Declare(Variable)} = PhysicalProperties.new(Density, Friction, Elasticity, FrictionWeight, ElasticityWeight)`
			)
		end,
		Write = function(Value: string, Block: Block)
			Types.f32.Write(`{Value}.Density`, Block)
			Types.f32.Write(`{Value}.Friction`, Block)
			Types.f32.Write(`{Value}.Elasticity`, Block)
			Types.f32.Write(`{Value}.FrictionWeight`, Block)
			Types.f32.Write(`{Value}.ElasticityWeight`, Block)
		end,
	}

	Primitives.PhysicalProperties = {
		Type = "PhysicalProperties",
		Generate = GeneratePrimitivePrefab("PhysicalProperties", Types.PhysicalProperties),
	}
end

--> Axes (X/Y/Z packed into one byte)
do
	Types.Axes = {
		Read = function(Variable: string, Block: Block)
			Types.u8.Read("AxesBits", Block)
			Block:Line("local AxesList = {}")
			Block:Line(`if AxesBits // 1 % 2 == 1 then table.insert(AxesList, Enum.Axis.X) end`)
			Block:Line(`if AxesBits // 2 % 2 == 1 then table.insert(AxesList, Enum.Axis.Y) end`)
			Block:Line(`if AxesBits // 4 % 2 == 1 then table.insert(AxesList, Enum.Axis.Z) end`)
			Block:Line(`{Block:Declare(Variable)} = Axes.new(table.unpack(AxesList))`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local AxesValue = {Value}`)
			Block:Line(
				`local AxesBits = (AxesValue.X and 1 or 0) + (AxesValue.Y and 2 or 0) + (AxesValue.Z and 4 or 0)`
			)
			Types.u8.Write("AxesBits", Block)
		end,
	}

	Primitives.Axes = {
		Type = "Axes",
		Generate = GeneratePrimitivePrefab("Axes", Types.Axes),
	}
end

--> Faces (six normals packed into one byte)
do
	Types.Faces = {
		Read = function(Variable: string, Block: Block)
			Types.u8.Read("FacesBits", Block)
			Block:Line("local FacesList = {}")
			Block:Line(`if FacesBits // 1 % 2 == 1 then table.insert(FacesList, Enum.NormalId.Right) end`)
			Block:Line(`if FacesBits // 2 % 2 == 1 then table.insert(FacesList, Enum.NormalId.Top) end`)
			Block:Line(`if FacesBits // 4 % 2 == 1 then table.insert(FacesList, Enum.NormalId.Back) end`)
			Block:Line(`if FacesBits // 8 % 2 == 1 then table.insert(FacesList, Enum.NormalId.Left) end`)
			Block:Line(`if FacesBits // 16 % 2 == 1 then table.insert(FacesList, Enum.NormalId.Bottom) end`)
			Block:Line(`if FacesBits // 32 % 2 == 1 then table.insert(FacesList, Enum.NormalId.Front) end`)
			Block:Line(`{Block:Declare(Variable)} = Faces.new(table.unpack(FacesList))`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local FacesValue = {Value}`)
			Block:Line(
				`local FacesBits = (FacesValue.Right and 1 or 0) + (FacesValue.Top and 2 or 0) + (FacesValue.Back and 4 or 0) + (FacesValue.Left and 8 or 0) + (FacesValue.Bottom and 16 or 0) + (FacesValue.Front and 32 or 0)`
			)
			Types.u8.Write("FacesBits", Block)
		end,
	}

	Primitives.Faces = {
		Type = "Faces",
		Generate = GeneratePrimitivePrefab("Faces", Types.Faces),
	}
end

--> Enum (generic EnumItem; portable across Roblox and Lune via name double-index)
do
	Types.EnumItem = {
		Read = function(Variable: string, Block: Block)
			Types.string.Read("EnumTypeName", Block)
			Types.string.Read("EnumItemName", Block)
			Block:Line(`{Block:Declare(Variable)} = Enum[EnumTypeName][EnumItemName]`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local EnumItem = {Value}`)
			Block:Line(`local EnumTypeName = string.sub(tostring(EnumItem.EnumType), 6)`)
			Types.string.Write("EnumTypeName", Block)
			Types.string.Write("EnumItem.Name", Block)
		end,
	}

	Primitives.EnumItem = {
		Type = "EnumItem",
		Generate = GeneratePrimitivePrefab("EnumItem", Types.EnumItem),
	}
end

--> TweenInfo
do
	Types.TweenInfo = {
		Read = function(Variable: string, Block: Block)
			Types.f32.Read("TweenTime", Block)
			Types.EnumItem.Read("EasingStyle", Block)
			Types.EnumItem.Read("EasingDirection", Block)
			Types.i32.Read("RepeatCount", Block)
			Types.boolean.Read("Reverses", Block)
			Types.f32.Read("DelayTime", Block)
			Block:Line(
				`{Block:Declare(Variable)} = TweenInfo.new(TweenTime, EasingStyle, EasingDirection, RepeatCount, Reverses, DelayTime)`
			)
		end,
		Write = function(Value: string, Block: Block)
			Types.f32.Write(`{Value}.Time`, Block)
			Types.EnumItem.Write(`{Value}.EasingStyle`, Block)
			Types.EnumItem.Write(`{Value}.EasingDirection`, Block)
			Types.i32.Write(`{Value}.RepeatCount`, Block)
			Types.boolean.Write(`{Value}.Reverses`, Block)
			Types.f32.Write(`{Value}.DelayTime`, Block)
		end,
	}

	Primitives.TweenInfo = {
		Type = "TweenInfo",
		Generate = GeneratePrimitivePrefab("TweenInfo", Types.TweenInfo),
	}
end

--> Font
do
	Types.Font = {
		Read = function(Variable: string, Block: Block)
			Types.string.Read("FontFamily", Block)
			Types.EnumItem.Read("FontWeight", Block)
			Types.EnumItem.Read("FontStyle", Block)
			Block:Line(`{Block:Declare(Variable)} = Font.new(FontFamily, FontWeight, FontStyle)`)
		end,
		Write = function(Value: string, Block: Block)
			Types.string.Write(`{Value}.Family`, Block)
			Types.EnumItem.Write(`{Value}.Weight`, Block)
			Types.EnumItem.Write(`{Value}.Style`, Block)
		end,
	}

	Primitives.Font = {
		Type = "Font",
		Generate = GeneratePrimitivePrefab("Font", Types.Font),
	}
end

--> NumberSequence (variable-length keypoints)
do
	Types.NumberSequence = {
		Read = function(Variable: string, Block: Block)
			Block:Line(`local NumberSequenceCount = ReadLength(2)`)
			Block:Line(`local NumberSequenceKeypoints = table.create(NumberSequenceCount)`)
			local Loop = Block:Loop("Index = 1", "NumberSequenceCount")
			Types.f32.Read("KeypointTime", Loop)
			Types.f32.Read("KeypointValue", Loop)
			Types.f32.Read("KeypointEnvelope", Loop)
			Loop:Line(
				`table.insert(NumberSequenceKeypoints, NumberSequenceKeypoint.new(KeypointTime, KeypointValue, KeypointEnvelope))`
			)
			Loop:End()
			Block:Line(`{Block:Declare(Variable)} = NumberSequence.new(NumberSequenceKeypoints)`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local NumberSequenceKeypoints = ({Value}).Keypoints`)
			Block:Line(`WriteLength(#NumberSequenceKeypoints, 2)`)
			local Loop = Block:Loop("Index = 1", "#NumberSequenceKeypoints")
			Loop:Line(`local Keypoint = NumberSequenceKeypoints[Index]`)
			Types.f32.Write("Keypoint.Time", Loop)
			Types.f32.Write("Keypoint.Value", Loop)
			Types.f32.Write("Keypoint.Envelope", Loop)
			Loop:End()
		end,
	}

	Primitives.NumberSequence = {
		Type = "NumberSequence",
		Generate = GeneratePrimitivePrefab("NumberSequence", Types.NumberSequence),
	}
end

--> ColorSequence (variable-length keypoints)
do
	Types.ColorSequence = {
		Read = function(Variable: string, Block: Block)
			Block:Line(`local ColorSequenceCount = ReadLength(2)`)
			Block:Line(`local ColorSequenceKeypoints = table.create(ColorSequenceCount)`)
			local Loop = Block:Loop("Index = 1", "ColorSequenceCount")
			Types.f32.Read("KeypointTime", Loop)
			Types.Color3.Read("KeypointColor", Loop)
			Loop:Line(`table.insert(ColorSequenceKeypoints, ColorSequenceKeypoint.new(KeypointTime, KeypointColor))`)
			Loop:End()
			Block:Line(`{Block:Declare(Variable)} = ColorSequence.new(ColorSequenceKeypoints)`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local ColorSequenceKeypoints = ({Value}).Keypoints`)
			Block:Line(`WriteLength(#ColorSequenceKeypoints, 2)`)
			local Loop = Block:Loop("Index = 1", "#ColorSequenceKeypoints")
			Loop:Line(`local Keypoint = ColorSequenceKeypoints[Index]`)
			Types.f32.Write("Keypoint.Time", Loop)
			Types.Color3.Write("Keypoint.Value", Loop)
			Loop:End()
		end,
	}

	Primitives.ColorSequence = {
		Type = "ColorSequence",
		Generate = GeneratePrimitivePrefab("ColorSequence", Types.ColorSequence),
	}
end

return {
	Types = Types,
	Asserts = Asserts,
	Primitives = Primitives,
	Structures = Structures,
	GetTypeToUse = GetTypeToUse,
	GetTypeToUseByBits = GetTypeToUseByBits,
	GetLengthBytes = GetLengthBytes,
}
