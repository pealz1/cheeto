local Parser = require("../Parser")

type Scope = Parser.Scope

local function GetScopePrefix(ReferenceScope: Scope?, Dots: boolean?, CurrentScope: Scope): string
	local Prefix = ""
	local WorkingScope: Scope? = ReferenceScope or CurrentScope
	while WorkingScope and WorkingScope.Name.Value ~= "" do
		Prefix = `{WorkingScope.Name.Value}{Dots and "." or "_"}` .. Prefix
		WorkingScope = WorkingScope.Parent
	end

	return Prefix
end

local function GetScopeIndent(CurrentScope: Scope): number
	return math.max(#string.split(GetScopePrefix(nil, true, CurrentScope), "."), 1)
end

local function GetTypesPath(Name: string, Write: boolean, CurrentScope: Scope): string
	return `SerdesFunctions.{GetScopePrefix(nil, false, CurrentScope)}{Write and "Write" or "Read"}{Name}`
end

local function GetExportName(Name: string, CurrentScope: Scope): string
	return `{GetScopePrefix(nil, false, CurrentScope)}{Name}`
end

--> A schema string as a double-quoted Luau or TypeScript literal. The lexer
--> keeps escapes as written, so an escape pair is copied through untouched;
--> a bare quote, a newline or a trailing backslash is escaped. Splicing the
--> raw text broke the generated module for 'single "quoted"' strings.
local function Quote(Value: string): string
	local Parts = {}
	local Index = 1
	local Length = #Value
	while Index <= Length do
		local Character = string.sub(Value, Index, Index)
		if Character == "\\" then
			if Index == Length then
				table.insert(Parts, "\\\\")
			else
				table.insert(Parts, string.sub(Value, Index, Index + 1))
				Index += 1
			end
		elseif Character == '"' then
			table.insert(Parts, '\\"')
		elseif Character == "\n" then
			table.insert(Parts, "\\n")
		elseif Character == "\r" then
			table.insert(Parts, "\\r")
		else
			table.insert(Parts, Character)
		end
		Index += 1
	end
	return `"{table.concat(Parts)}"`
end

local function GenerateEnumLiterals(Variants: { string }): string
	local Literals = {}
	for Index, EnumItem in Variants do
		table.insert(Literals, `"{EnumItem}"`)
	end
	return `{table.concat(Literals, " | ")}`
end

return {
	GetPath = GetTypesPath,
	GetExportName = GetExportName,
	GetScopePrefix = GetScopePrefix,
	GetScopeIndent = GetScopeIndent,
	GenerateEnumLiterals = GenerateEnumLiterals,
	Quote = Quote,
}
