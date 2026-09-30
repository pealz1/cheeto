--!strict

---- Imports ----

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local Benchmark = require("./Benchmark")
local Error = require("../../Modules/Error")
local Generator = require("../../Generator")
local GetDefinitionFilePath = require("./GetDefinitionFilePath")
local Parser = require("../../Parser")
local PathParser = require("../../Modules/Path")
local Wire = require("../../Generator/Wire")

---- Settings ----

export type CompileOptions = {
	Debug: boolean,
	Silent: boolean,
	Compact: boolean,
	YesToEverything: boolean,
	OutputAbstractSyntaxTree: boolean,
}

type Span = {
	Start: number,
	End: number,
}

type Diagnostic = {
	Message: string,
	File: string?,
	Span: Span?,
}

---- Constants ----

local Utility = {}

---- Variables ----

---- Private Functions ----

local function Message(Color: stdio.Color, Options: CompileOptions, ...)
	if Options.Silent then
		return
	end

	stdio.write(stdio.color(Color))
	print(...)
	stdio.write(stdio.color("reset"))
end

local function FormatTime(Time: number): string
	if Time < 1E-6 then
		return `{Time * 1E+9} ns`
	elseif Time < 0.001 then
		return `{Time * 1E+6} μs`
	elseif Time < 1 then
		return `{Time * 1000} ms`
	else
		return `{Time} seconds`
	end
end

local function CreateDirectoryIfNotFound(Path: string, Options: CompileOptions)
	local Directory = PathParser.Directory(Path) or "./"
	if fs.isDir(Directory) then
		return
	end

	local Result = Options.YesToEverything
		or stdio.prompt("confirm", `Directory {Directory} doesn't exist, create directory?`)

	if Result then
		fs.writeDir(Directory)
		return
	end

	error("User refused prompt to create directory")
end

local function LockPath(FilePath: string): string
	return `{PathParser.Directory(FilePath) or "./"}cheeto.lock`
end

--> cheeto.lock next to the schema pins endpoint ids across edits. A lock
--> written before ids were recorded per channel carries no usable ids and is
--> ignored until it is rewritten.
local function ReadLock(FilePath: string): Wire.Lock?
	local Target = LockPath(FilePath)
	if not fs.isFile(Target) then
		return nil
	end

	local Success, Lock = pcall(serde.decode, "json" :: "json", fs.readFile(Target))
	if not Success or type(Lock) ~= "table" then
		error(`{Target} is not valid JSON. Fix it or delete it and run --write-lock.`)
	end

	if type(Lock.endpoints) ~= "table" then
		return nil
	end
	return Lock :: any
end

local function AttachLock(Ast: Parser.Body, FilePath: string)
	(Ast.Value :: any).Lock = ReadLock(FilePath)
end

---- Public Functions ----

function Utility.Compile(Path: string, Options: CompileOptions)
	local FilePath = GetDefinitionFilePath(Path)
	Error.SetCompact(Options.Compact)

	Message("cyan", Options, `Reading source from {FilePath}...`)
	local Source = fs.readFile(FilePath)

	Message("blue", Options, "Parsing source into AST...")
	local FileDirectory = PathParser.Directory(FilePath) or "./"
	local SourceParser = Parser.new(FileDirectory, PathParser.NameWithExtension(FilePath))

	local ParseStart = os.clock()
	local AbstractSyntaxTree = SourceParser:Parse(Source)
	AttachLock(AbstractSyntaxTree, FilePath)
	local ParseTime = (os.clock() - ParseStart)

	if Options.OutputAbstractSyntaxTree then
		print(AbstractSyntaxTree.Value.Options)
		print(AbstractSyntaxTree.Value.Declarations)
		return
	end

	local FileOptions = AbstractSyntaxTree.Value.Options
	if FileOptions.StrictProduction then
		Utility.Strict(Path, Options)
	end

	local ClientOutputPath = FileOptions.ClientOutput
	local ServerOutputPath = FileOptions.ServerOutput

	assert(ClientOutputPath, "A client output path must be defined.")
	assert(ServerOutputPath, "A server output path must be defined.")

	local ClientTypescriptPath
	local ServerTypescriptPath

	do
		local Directory, Filename = PathParser.Components(ClientOutputPath)
		local TypescriptFilename = if Filename == "init" then "index" else Filename
		ClientOutputPath = `{Directory}/{Filename}.luau`
		ClientTypescriptPath = if PathParser.PathType(ClientOutputPath) == "absolute"
			then `{Directory}/{TypescriptFilename}.d.ts`
			else `{FileDirectory}{Directory}/{TypescriptFilename}.d.ts`
	end

	do
		local Directory, Filename = PathParser.Components(ServerOutputPath)
		local TypescriptFilename = if Filename == "init" then "index" else Filename
		ServerOutputPath = `{Directory}/{Filename}.luau`
		ServerTypescriptPath = if PathParser.PathType(ServerOutputPath) == "absolute"
			then `{Directory}/{TypescriptFilename}.d.ts`
			else `{FileDirectory}{Directory}/{TypescriptFilename}.d.ts`
	end

	local TypesOutput: string

	local ClientOutput: string
	local ServerOutput: string

	if PathParser.PathType(ClientOutputPath) == "absolute" then
		ClientOutput = ClientOutputPath
	else
		ClientOutput = `{FileDirectory}{ClientOutputPath}`
	end

	if PathParser.PathType(ServerOutputPath) == "absolute" then
		ServerOutput = ServerOutputPath
	else
		ServerOutput = `{FileDirectory}{ServerOutputPath}`
	end

	CreateDirectoryIfNotFound(ClientOutput, Options)
	CreateDirectoryIfNotFound(ServerOutput, Options)

	Message("blue", Options, "Generating output files...")
	local FilesStart = os.clock()

	local ServerGenerateStart = os.clock()
	local ServerSource = Generator.Generate("Server", AbstractSyntaxTree)
	local ServerGenerateTime = (os.clock() - ServerGenerateStart)

	local ClientGenerateStart = os.clock()
	local ClientSource = Generator.Generate("Client", AbstractSyntaxTree)
	local ClientGenerateTime = (os.clock() - ClientGenerateStart)

	local TypesSource: string?
	if FileOptions.TypesOutput then
		TypesOutput = if PathParser.PathType(Path) == "absolute"
			then FileOptions.TypesOutput
			else `{FileDirectory}{FileOptions.TypesOutput}`
		TypesSource = Generator.GenerateShared(AbstractSyntaxTree)
	end

	local ClientTypescriptSource: string?
	local ServerTypescriptSource: string?
	if FileOptions.Typescript then
		ClientTypescriptSource = Generator.GenerateTypescript("Client", AbstractSyntaxTree)
		ServerTypescriptSource = Generator.GenerateTypescript("Server", AbstractSyntaxTree)
	end

	local FilesTime = (os.clock() - FilesStart)
	fs.writeFile(ServerOutput, ServerSource)
	fs.writeFile(ClientOutput, ClientSource)

	--> Opt-in: with RuntimeOutput set, the runtime is emitted once as its own
	--> factory module and the generated modules require it instead of inlining
	--> ~135KB each. Schemas without the option are unaffected.
	if FileOptions.RuntimeOutput then
		assert(FileOptions.RuntimeRequire, "RuntimeRequire must be set alongside RuntimeOutput.")

		local RuntimeDirectory, RuntimeFilename = PathParser.Components(FileOptions.RuntimeOutput)
		local RuntimePath = `{RuntimeDirectory}/{RuntimeFilename}.luau`
		local RuntimeOutput = if PathParser.PathType(RuntimePath) == "absolute"
			then RuntimePath
			else `{FileDirectory}{RuntimePath}`

		CreateDirectoryIfNotFound(RuntimeOutput, Options)
		fs.writeFile(RuntimeOutput, Generator.GenerateRuntime("Server", AbstractSyntaxTree))

		local ClientRuntimeOutput = string.gsub(RuntimeOutput, "%.luau$", "Client.luau")
		fs.writeFile(ClientRuntimeOutput, Generator.GenerateRuntime("Client", AbstractSyntaxTree))
	end

	if TypesSource and TypesOutput then
		CreateDirectoryIfNotFound(TypesOutput, Options)
		fs.writeFile(TypesOutput, TypesSource)
	end

	if ClientTypescriptSource and ServerTypescriptSource then
		fs.writeFile(ClientTypescriptPath, ClientTypescriptSource)
		fs.writeFile(ServerTypescriptPath, ServerTypescriptSource)
	end

	Message("green", Options, "Network files generated!")

	if Options.Debug and not Options.Silent then
		print(`[DEBUG]: Parsed source in {FormatTime(ParseTime)}.`)
		print(`[DEBUG]: Generated server luau in {FormatTime(ServerGenerateTime)}.`)
		print(`[DEBUG]: Generated client luau in {FormatTime(ClientGenerateTime)}.`)
		print(`[DEBUG]: Generated files in {FormatTime(FilesTime)}.`)
		print(`[DEBUG]: Completed everything in {FormatTime(ParseTime + FilesTime)}.`)
	end
end

local function ParseForUtility(Path: string, Options: CompileOptions): (Parser.Body, string, string)
	local FilePath = GetDefinitionFilePath(Path)
	Error.SetCompact(Options.Compact)
	local Source = fs.readFile(FilePath)
	local FileDirectory = PathParser.Directory(FilePath) or "./"
	local SourceParser = Parser.new(FileDirectory, PathParser.NameWithExtension(FilePath))
	local Ast = SourceParser:Parse(Source)
	AttachLock(Ast, FilePath)
	return Ast, Source, FilePath
end

local function WalkDeclarations(Declarations: { Parser.Declaration }, Callback: (Parser.Declaration) -> ())
	for _, Declaration in Declarations do
		Callback(Declaration)
		if Declaration.Type == "Scope" then
			WalkDeclarations((Declaration :: Parser.ScopeNode).Value.Values, Callback)
		end
	end
end

local function EscapePattern(Text: string): string
	return string.gsub(Text, "([^%w])", "%%%1")
end

local function FindOptionSpan(Source: string, Name: string): Span?
	local Start, Finish = string.find(Source, `option%s+{EscapePattern(Name)}`)
	if Start == nil or Finish == nil then
		return nil
	end

	return {
		Start = Start,
		End = Finish,
	}
end

local function FindDeclarationSpan(Source: string, Kind: string, Name: string): Span?
	local Start, Finish = string.find(Source, `{Kind}%s+{EscapePattern(Name)}`)
	if Start == nil or Finish == nil then
		return nil
	end

	return {
		Start = Start,
		End = Finish,
	}
end

local function LineColumn(Source: string, Offset: number): (number, number)
	local Line = 1
	local LineStart = 1
	for Index = 1, math.max(1, Offset - 1) do
		if string.sub(Source, Index, Index) == "\n" then
			Line += 1
			LineStart = Index + 1
		end
	end

	return Line, math.max(1, Offset - LineStart + 1)
end

local function SchemaVersion(FileOptions: Parser.Options): number
	return FileOptions.SchemaVersion or FileOptions.Version or 1
end

local function IsUnsafeOutputPath(Path: string?): boolean
	if Path == nil then
		return true
	end

	local Lower = string.lower(Path)
	return string.find(Lower, "..", 1, true) ~= nil or PathParser.PathType(Path) == "absolute"
end

local function CollectProductionDiagnostics(
	Ast: Parser.Body,
	Strict: boolean,
	Source: string,
	FilePath: string
): ({ Diagnostic }, { Diagnostic })
	local FileOptions = Ast.Value.Options
	local Warnings = {}
	local Errors = {}

	local function CreateDiagnostic(MessageText: string, Span: Span?): Diagnostic
		return {
			Message = MessageText,
			File = FilePath,
			Span = Span,
		}
	end

	local function Warn(MessageText: string, Span: Span?)
		table.insert(Warnings, CreateDiagnostic(MessageText, Span))
	end

	local function Fail(MessageText: string, Span: Span?)
		if Strict then
			table.insert(Errors, CreateDiagnostic(MessageText, Span))
		else
			table.insert(Warnings, CreateDiagnostic(MessageText, Span))
		end
	end

	local Profile = FileOptions.SecurityProfile or "Development"
	local RateLimit = FileOptions.RateLimitPerSecond
	local ReliableLimit = FileOptions.MaxReliablePacketBytes or FileOptions.MaxPacketBytes
	local UnreliableLimit = FileOptions.MaxUnreliablePacketBytes or FileOptions.MaxPacketBytes
	local InvokeTimeout = FileOptions.InvokeTimeoutSeconds

	if (ReliableLimit or math.huge) > 1024 * 1024 then
		Warn(
			"MaxReliablePacketBytes/MaxPacketBytes is above 1 MiB; lower this for public servers.",
			FindOptionSpan(
				Source,
				if FileOptions.MaxReliablePacketBytes then "MaxReliablePacketBytes" else "MaxPacketBytes"
			)
		)
	end

	if Strict then
		if Profile ~= "Production" and Profile ~= "Competitive" then
			Fail(
				"Strict production mode requires SecurityProfile = Production or Competitive.",
				FindOptionSpan(Source, "SecurityProfile")
			)
		end

		if ReliableLimit == nil or ReliableLimit <= 0 then
			Fail(
				"Reliable packet size is unlimited; set MaxReliablePacketBytes or MaxPacketBytes.",
				FindOptionSpan(Source, "MaxReliablePacketBytes") or FindOptionSpan(Source, "MaxPacketBytes")
			)
		end

		if UnreliableLimit == nil or UnreliableLimit <= 0 then
			Fail(
				"Unreliable packet size is unlimited; set MaxUnreliablePacketBytes or MaxPacketBytes.",
				FindOptionSpan(Source, "MaxUnreliablePacketBytes") or FindOptionSpan(Source, "MaxPacketBytes")
			)
		end

		if RateLimit == nil or RateLimit <= 0 then
			Fail("RateLimitPerSecond is missing or disabled.", FindOptionSpan(Source, "RateLimitPerSecond"))
		end

		if InvokeTimeout == nil or InvokeTimeout <= 0 then
			Fail("InvokeTimeoutSeconds is missing or disabled.", FindOptionSpan(Source, "InvokeTimeoutSeconds"))
		end

		if FileOptions.SyncValidation == true then
			Fail("SyncValidation is enabled in a production build.", FindOptionSpan(Source, "SyncValidation"))
		end

		if FileOptions.WriteValidations == true then
			Fail("WriteValidations is enabled in a production build.", FindOptionSpan(Source, "WriteValidations"))
		end

		if IsUnsafeOutputPath(FileOptions.ClientOutput) then
			Fail(
				"ClientOutput is unsafe for strict production builds; use a contained relative path.",
				FindOptionSpan(Source, "ClientOutput")
			)
		end

		if IsUnsafeOutputPath(FileOptions.ServerOutput) then
			Fail(
				"ServerOutput is unsafe for strict production builds; use a contained relative path.",
				FindOptionSpan(Source, "ServerOutput")
			)
		end
	end

	if (RateLimit or 0) == 0 and Profile ~= "Development" then
		Warn(
			"RateLimitPerSecond is disabled outside the Development profile.",
			FindOptionSpan(Source, "RateLimitPerSecond")
		)
	end

	if not FileOptions.ClientOutput then
		Warn("ClientOutput is missing; CLI generation requires it.", nil)
	end
	if not FileOptions.ServerOutput then
		Warn("ServerOutput is missing; CLI generation requires it.", nil)
	end

	WalkDeclarations(Ast.Value.Declarations, function(Declaration)
		if Declaration.Type == "Event" then
			local Event = Declaration :: Parser.Event
			if
				Event.Value.From == "Client"
				and Event.Value.Auth == nil
				and Event.Value.Policy == nil
				and Event.Value.PolicyGroup == nil
			then
				Fail(
					`Client-origin event "{Declaration.Name}" has no Auth, Policy, or PolicyGroup rule.`,
					FindDeclarationSpan(Source, "event", Declaration.Name)
				)
			end
		elseif Declaration.Type == "Function" then
			local Function = Declaration :: Parser.Function
			if Function.Value.Auth == nil and Function.Value.Policy == nil and Function.Value.PolicyGroup == nil then
				Fail(
					`Function "{Declaration.Name}" has no Auth, Policy, or PolicyGroup rule.`,
					FindDeclarationSpan(Source, "function", Declaration.Name)
				)
			end
		end
	end)

	return Warnings, Errors
end

local function FormatDiagnostic(Diagnostic: Diagnostic, Source: string): string
	if Diagnostic.Span == nil or Diagnostic.File == nil then
		return Diagnostic.Message
	end

	local Line, Column = LineColumn(Source, Diagnostic.Span.Start)
	return `{Diagnostic.File}:{Line}:{Column}: {Diagnostic.Message}`
end

local function PrintDiagnostics(
	Title: string,
	Options: CompileOptions,
	Warnings: { Diagnostic },
	Errors: { Diagnostic },
	Source: string
)
	local Total = #Warnings + #Errors
	if Total == 0 then
		Message("green", Options, `{Title} passed with no diagnostics.`)
		return
	end

	local Color: stdio.Color = if #Errors > 0 then "red" else "yellow"
	Message(Color, Options, `{Title} found {#Errors} error(s), {#Warnings} warning(s):`)
	for _, ErrorMessage in Errors do
		print(`- ERROR: {FormatDiagnostic(ErrorMessage, Source)}`)
	end
	for _, Warning in Warnings do
		print(`- WARN: {FormatDiagnostic(Warning, Source)}`)
	end
end

local function CountDeclarations(Declarations: { Parser.Declaration }): { [string]: number }
	local Counts: { [string]: number } = {
		Event = 0,
		Function = 0,
		Channel = 0,
		Type = 0,
	}

	WalkDeclarations(Declarations, function(Declaration)
		if Declaration.Type == "Event" then
			Counts.Event += 1
		elseif Declaration.Type == "Function" then
			Counts.Function += 1
		elseif Declaration.Type == "Channel" then
			Counts.Channel += 1
		elseif Declaration.Type ~= "Scope" then
			Counts.Type += 1
		end
	end)

	return Counts
end

local function DeclarationNames(Declarations: { Parser.Declaration }, Kind: string): { string }
	local Names = {}
	WalkDeclarations(Declarations, function(Declaration)
		if Declaration.Type == Kind then
			table.insert(Names, Declaration.Name)
		end
	end)
	table.sort(Names)
	return Names
end

local function JsonString(Value: string): string
	Value = string.gsub(Value, "\\", "\\\\")
	Value = string.gsub(Value, '"', '\\"')
	Value = string.gsub(Value, "\n", "\\n")
	return `"{Value}"`
end

local function SortedKeys(Map: { [string]: any }): { string }
	local Keys = {}
	for Key in Map do
		table.insert(Keys, Key)
	end
	table.sort(Keys)
	return Keys
end

local function LockContent(Ast: Parser.Body): string
	local FileOptions = Ast.Value.Options
	local Schema = SchemaVersion(FileOptions)
	local Assignments = Wire.Assign(Ast.Value.Declarations, (Ast.Value :: any).Lock)
	local Lines = {
		"{",
		`\t"schemaVersion": {Schema},`,
		`\t"minimumSchemaVersion": {FileOptions.MinimumSchemaVersion or 1},`,
		`\t"schemaHash": {JsonString(Wire.Fingerprint(Ast, Assignments))},`,
		`\t"options": \{`,
		`\t\t"securityProfile": {JsonString(FileOptions.SecurityProfile or "Development")},`,
		`\t\t"requirePolicies": {tostring(FileOptions.RequirePolicies == true)},`,
		`\t\t"maxReliablePacketBytes": {FileOptions.MaxReliablePacketBytes or FileOptions.MaxPacketBytes or 1048576},`,
		`\t\t"maxUnreliablePacketBytes": {FileOptions.MaxUnreliablePacketBytes or FileOptions.MaxPacketBytes or 1000}`,
		"\t},",
		`\t"endpoints": \{`,
	}

	--> Endpoints that left the schema stay in the lock as retired, so their
	--> ids are never handed to something else.
	local Entries: { [string]: string } = {}
	for _, Assignment in Assignments do
		local Value = Assignment.Declaration.Value :: any
		local Shape = Wire.Hash(Wire.EndpointDescription(Assignment))
		local Alias = if Assignment.Alias ~= nil then `, "deprecatedId": {Assignment.Alias}` else ""
		local Reserved = if Value.ReservedId ~= nil then `, "reservedId": {Value.ReservedId}` else ""
		Entries[Assignment.Name] =
			`\{ "kind": {JsonString(Assignment.Kind)}, "channel": {JsonString(Assignment.Channel)}, "id": {Assignment.Id}{Alias}{Reserved}, "shape": {JsonString(
				Shape
			)} \}`
	end
	local Previous = (Ast.Value :: any).Lock
	if Previous and Previous.endpoints then
		for Name, Entry in Previous.endpoints do
			if Entries[Name] == nil and type(Entry.id) == "number" and type(Entry.channel) == "string" then
				Entries[Name] =
					`\{ "kind": {JsonString(tostring(Entry.kind))}, "channel": {JsonString(Entry.channel)}, "id": {Entry.id}, "retired": true \}`
			end
		end
	end

	local Names = SortedKeys(Entries)
	for Index, Name in Names do
		table.insert(Lines, `\t\t{JsonString(Name)}: {Entries[Name]}{if Index < #Names then "," else ""}`)
	end

	table.insert(Lines, "\t},")
	table.insert(Lines, `\t"types": \{`)
	local Types: { [string]: string } = {}
	WalkDeclarations(Ast.Value.Declarations, function(Declaration)
		if
			Declaration.Type ~= "Scope"
			and Declaration.Type ~= "Event"
			and Declaration.Type ~= "Function"
			and Declaration.Type ~= "Channel"
		then
			Types[Declaration.Name] = Wire.Hash(Wire.Describe(Declaration))
		end
	end)
	local TypeNames = SortedKeys(Types)
	for Index, Name in TypeNames do
		table.insert(Lines, `\t\t{JsonString(Name)}: {JsonString(Types[Name])}{if Index < #TypeNames then "," else ""}`)
	end
	table.insert(Lines, "\t}")
	table.insert(Lines, "}")
	return table.concat(Lines, "\n") .. "\n"
end

function Utility.Doctor(Path: string, Options: CompileOptions)
	local Ast, Source, FilePath = ParseForUtility(Path, Options)
	local Warnings, Errors = CollectProductionDiagnostics(Ast, false, Source, FilePath)
	PrintDiagnostics("Doctor", Options, Warnings, Errors, Source)
end

function Utility.Strict(Path: string, Options: CompileOptions)
	local Ast, Source, FilePath = ParseForUtility(Path, Options)
	local Warnings, Errors = CollectProductionDiagnostics(Ast, true, Source, FilePath)
	PrintDiagnostics("Strict production build", Options, Warnings, Errors, Source)
	if #Errors > 0 then
		error("Strict production build failed.")
	end
end

local function Pad(Text: string, Width: number): string
	return Text .. string.rep(" ", math.max(1, Width - #Text))
end

local function Round(Value: number, Places: number): number
	local Scale = 10 ^ Places
	return math.round(Value * Scale) / Scale
end

type Totals = { Bytes: number, Encode: number, Decode: number, Measured: number, Skipped: number }

local function Summarize(Results: { Benchmark.Measurement }): Totals
	local Totals = { Bytes = 0, Encode = 0, Decode = 0, Measured = 0, Skipped = 0 }
	for _, Result in Results do
		if Result.Skipped then
			Totals.Skipped += 1
		else
			Totals.Measured += 1
			Totals.Bytes += Result.Bytes
			Totals.Encode += Result.EncodeMicroseconds
			Totals.Decode += Result.DecodeMicroseconds
		end
	end
	return Totals
end

function Utility.Benchmark(Path: string, Options: CompileOptions)
	local Ast = ParseForUtility(Path, Options)
	local Counts = CountDeclarations(Ast.Value.Declarations)
	local Start = os.clock()
	local ServerSource = Generator.Generate("Server", Ast)
	local ClientSource = Generator.Generate("Client", Ast)
	local TypesSource = Generator.GenerateShared(Ast)
	local Elapsed = os.clock() - Start

	--> Measured on its own parse: the harness rewrites options and strips
	--> access rules so every endpoint accepts the synthetic traffic.
	local Results = Benchmark.Measure((ParseForUtility(Path, Options)))
	local Totals = Summarize(Results)

	local BaseEvents = math.max(1, Counts.Event + Counts.Function + Counts.Channel)
	local EndpointHeadroom = math.max(0, BaseEvents - 80)
	local Thresholds = {
		ServerBytes = 700_000 + (EndpointHeadroom * 2_250),
		ClientBytes = 560_000 + (EndpointHeadroom * 1_500),
		--> The shared artifact embeds the whole runtime, so it tracks runtime size.
		TypesBytes = 250_000,
		GenerateSeconds = 2,
		--> Per message, averaged over every measured endpoint. Generous on
		--> purpose: CI machines are slow and noisy; this catches regressions
		--> of an order of magnitude, not a few percent.
		EncodeMicroseconds = 250,
		DecodeMicroseconds = 250,
	}
	local Failures = {}
	local function Check(Name: string, Value: number, Limit: number)
		if Value > Limit then
			table.insert(Failures, `{Name}={Value} exceeds {Limit}`)
		end
	end

	local Average = if Totals.Measured > 0 then 1 / Totals.Measured else 0
	Check("serverBytes", #ServerSource, Thresholds.ServerBytes)
	Check("clientBytes", #ClientSource, Thresholds.ClientBytes)
	Check("typesBytes", #TypesSource, Thresholds.TypesBytes)
	Check("generateSeconds", Elapsed, Thresholds.GenerateSeconds)
	Check("encodeMicroseconds", Round(Totals.Encode * Average, 2), Thresholds.EncodeMicroseconds)
	Check("decodeMicroseconds", Round(Totals.Decode * Average, 2), Thresholds.DecodeMicroseconds)
	for _, Result in Results do
		if not Result.Skipped and Result.Kind ~= "Function" and Result.Delivered < 1 then
			table.insert(Failures, `{Result.Name} delivered nothing ({Result.Dropped or "no drop recorded"})`)
		end
	end

	Message("green", Options, "Cheeto benchmark (measured):")
	print(
		`generated in {FormatTime(Elapsed)}: server={#ServerSource} bytes client={#ClientSource} bytes types={#TypesSource} bytes`
	)
	print(`{Pad("endpoint", 44)}{Pad("direction", 18)}{Pad("bytes/msg", 11)}{Pad("encode µs", 11)}decode µs`)
	for _, Result in Results do
		if Result.Skipped then
			print(`{Pad(Result.Name, 44)}{Pad(Result.Direction, 18)}skipped: {Result.Skipped}`)
		else
			print(
				`{Pad(Result.Name, 44)}{Pad(Result.Direction, 18)}{Pad(tostring(Round(Result.Bytes, 1)), 11)}{Pad(
					tostring(Round(Result.EncodeMicroseconds, 2)),
					11
				)}{Round(Result.DecodeMicroseconds, 2)}`
			)
		end
	end
	print(
		`average over {Totals.Measured} endpoints: bytes/msg={Round(Totals.Bytes * Average, 1)} encode={Round(
			Totals.Encode * Average,
			2
		)} µs decode={Round(Totals.Decode * Average, 2)} µs ({Totals.Skipped} skipped)`
	)
	print(
		`thresholds: server<={Thresholds.ServerBytes} client<={Thresholds.ClientBytes} types<={Thresholds.TypesBytes} generate<={Thresholds.GenerateSeconds}s encode<={Thresholds.EncodeMicroseconds}µs decode<={Thresholds.DecodeMicroseconds}µs`
	)

	if #Failures > 0 then
		error(`Benchmark threshold failure: {table.concat(Failures, "; ")}`)
	end
end

--> Scales the measured average message to a server at a given number of
--> clients and messages per client per second (sent and received).
function Utility.LoadSim(Path: string, Options: CompileOptions)
	local Ast = ParseForUtility(Path, Options)
	local FileOptions = Ast.Value.Options
	local Results = Benchmark.Measure(Ast)
	local Totals = Summarize(Results)
	local Average = if Totals.Measured > 0 then 1 / Totals.Measured else 0
	local Bytes = Totals.Bytes * Average
	local Cost = (Totals.Encode + Totals.Decode) * Average

	Message("green", Options, "Cheeto load projection (from measured per-message costs):")
	print(
		`schemaVersion={SchemaVersion(FileOptions)} endpoints={Totals.Measured} averageMessage={Round(Bytes, 1)} bytes, {Round(
			Cost,
			2
		)} µs to encode and decode`
	)
	print("clients,messagesPerClientPerSecond,kilobytesPerSecond,cpuMillisecondsPerSecond,percentOfOneCore")
	for _, Clients in { 10, 50, 100, 200 } do
		for _, Rate in { 10, 30, 60 } do
			local Messages = Clients * Rate
			local CpuMs = Messages * Cost / 1000
			print(`{Clients},{Rate},{Round(Messages * Bytes / 1024, 1)},{Round(CpuMs, 2)},{Round(CpuMs / 10, 1)}`)
		end
	end
end

function Utility.CaptureReplay(Path: string, Options: CompileOptions)
	local Ast = ParseForUtility(Path, Options)
	local Counts = CountDeclarations(Ast.Value.Declarations)
	Message("green", Options, "Cheeto capture/replay report:")
	print(`events={Counts.Event} functions={Counts.Function} channels={Counts.Channel}`)
	print(
		"runtimeApis=Capture.Start,Capture.Stop,Capture.Entries,Capture.Replay,Capture.ReplayRaw,Capture.Redact,Inspector.Snapshot"
	)
end

function Utility.GoldenSnapshots(Path: string, Options: CompileOptions)
	local Ast = ParseForUtility(Path, Options)
	local FileOptions = Ast.Value.Options
	local Counts = CountDeclarations(Ast.Value.Declarations)
	local ServerSource = Generator.Generate("Server", Ast)
	local ClientSource = Generator.Generate("Client", Ast)
	Message("green", Options, "Cheeto golden snapshot metadata:")
	print(`schemaVersion={SchemaVersion(FileOptions)}`)
	print(`schemaHash={Wire.Fingerprint(Ast, Wire.Assign(Ast.Value.Declarations, (Ast.Value :: any).Lock))}`)
	print(`sizes={#ServerSource}:{#ClientSource} types={Counts.Type}`)
	print(`events={table.concat(DeclarationNames(Ast.Value.Declarations, "Event"), ",")}`)
	print(`functions={table.concat(DeclarationNames(Ast.Value.Declarations, "Function"), ",")}`)
	print(`channels={table.concat(DeclarationNames(Ast.Value.Declarations, "Channel"), ",")}`)
end

function Utility.Compatibility(Path: string, Options: CompileOptions)
	local Ast = ParseForUtility(Path, Options)
	local FileOptions = Ast.Value.Options
	local RuntimeSchema = SchemaVersion(FileOptions)
	local MinimumSchema = FileOptions.MinimumSchemaVersion or 1
	local Hash = Wire.Fingerprint(Ast, Wire.Assign(Ast.Value.Declarations, (Ast.Value :: any).Lock))
	Message("green", Options, "Cheeto schema compatibility:")
	print("peerSchema,peerHash,result")
	print(`{MinimumSchema - 1},{Hash},reject:schema-too-old`)
	print(`{RuntimeSchema},wrong-hash,reject:schema-hash-mismatch`)
	print(`{RuntimeSchema},{Hash},accept`)
end

function Utility.SchemaDocs(Path: string, Options: CompileOptions)
	local Ast = ParseForUtility(Path, Options)
	local Counts = CountDeclarations(Ast.Value.Declarations)
	local FileOptions = Ast.Value.Options
	Message("green", Options, "Cheeto schema documentation:")
	print(`# Cheeto schema v{SchemaVersion(FileOptions)}`)
	print("")
	if FileOptions.CaptureRedactions and FileOptions.CaptureRedactions ~= "" then
		print(`Capture redactions: {FileOptions.CaptureRedactions}`)
	end
	print(`Types: {Counts.Type}`)
	print(`Events: {Counts.Event}`)
	for _, Name in DeclarationNames(Ast.Value.Declarations, "Event") do
		print(`- event {Name}`)
	end
	print(`Functions: {Counts.Function}`)
	for _, Name in DeclarationNames(Ast.Value.Declarations, "Function") do
		print(`- function {Name}`)
	end
	print(`State channels: {Counts.Channel}`)
	for _, Name in DeclarationNames(Ast.Value.Declarations, "Channel") do
		print(`- channel {Name}`)
	end
end

function Utility.WriteLock(Path: string, Options: CompileOptions)
	local Ast, _, FilePath = ParseForUtility(Path, Options)
	local Target = LockPath(FilePath)
	fs.writeFile(Target, LockContent(Ast))
	Message("green", Options, `Cheeto lockfile written: {Target}`)
end

function Utility.CheckLock(Path: string, Options: CompileOptions)
	local Ast, _, FilePath = ParseForUtility(Path, Options)
	local Target = LockPath(FilePath)
	local Expected = LockContent(Ast)
	if not fs.isFile(Target) then
		error(`Missing cheeto.lock at {Target}. Run --write-lock intentionally.`)
	end
	--> Git may check the file out with CRLF line endings.
	local Actual = string.gsub(fs.readFile(Target), "\r\n", "\n")
	if Actual ~= Expected then
		local ExpectedLines = string.split(Expected, "\n")
		local ActualSet = {}
		for _, Line in string.split(Actual, "\n") do
			ActualSet[Line] = true
		end
		local Changed = {}
		for _, Line in ExpectedLines do
			if not ActualSet[Line] and #Changed < 12 then
				table.insert(Changed, `  {Line}`)
			end
		end
		error(
			`cheeto.lock differs from the current schema. Lines the schema now produces:\n{table.concat(Changed, "\n")}\nReview the wire changes and run --write-lock only if they are intentional.`
		)
	end
	Message("green", Options, "cheeto.lock matches the current schema.")
end

function Utility.HardeningChecklist(Path: string, Options: CompileOptions)
	local Ast, Source, FilePath = ParseForUtility(Path, Options)
	local Warnings, Errors = CollectProductionDiagnostics(Ast, true, Source, FilePath)
	local FileOptions = Ast.Value.Options
	if FileOptions.SecurityProfile ~= "Production" and FileOptions.SecurityProfile ~= "Competitive" then
		table.insert(Errors, {
			Message = "Release hardening requires SecurityProfile = Production or Competitive.",
			File = FilePath,
			Span = FindOptionSpan(Source, "SecurityProfile"),
		})
	end
	if FileOptions.RequirePolicies ~= true then
		table.insert(Errors, {
			Message = "Release hardening requires RequirePolicies = true.",
			File = FilePath,
			Span = FindOptionSpan(Source, "RequirePolicies"),
		})
	end
	if FileOptions.NoRawCaptureInProduction == false then
		table.insert(Errors, {
			Message = "Release hardening requires raw capture redaction in production.",
			File = FilePath,
			Span = FindOptionSpan(Source, "NoRawCaptureInProduction"),
		})
	end

	PrintDiagnostics("Production hardening checklist", Options, Warnings, Errors, Source)
	if #Errors > 0 then
		error("Production hardening checklist failed.")
	end
end

function Utility.Ci(Path: string, Options: CompileOptions)
	Message("green", Options, "Cheeto CI report suite:")
	Utility.Doctor(Path, Options)
	Utility.Benchmark(Path, Options)
	Utility.LoadSim(Path, Options)
	Utility.CaptureReplay(Path, Options)
	Utility.GoldenSnapshots(Path, Options)
	Utility.Compatibility(Path, Options)
	Utility.SchemaDocs(Path, Options)
	Utility.CheckLock(Path, Options)
end

---- Initialization ----

---- Connections ----

return Utility
