--!strict

--> Wire identity for a schema: which number every endpoint is sent under,
--> and a fingerprint of everything that decides the bytes on the wire.

local Parser = require("../Parser")

export type Assignment = {
	Name: string,
	Kind: string,
	Channel: string,
	Id: number,
	Alias: number?,
	Declaration: Parser.Declaration,
}

export type LockEntry = {
	kind: string?,
	channel: string?,
	id: number?,
	retired: boolean?,
}

export type Lock = {
	endpoints: { [string]: LockEntry }?,
}

--> One byte per endpoint number; 252-255 are control frames.
local MAX_ID = 251

local Wire = {}

local function ChannelOf(Declaration: Parser.Declaration): string
	if Declaration.Type == "Function" then
		return "Reliable"
	end

	return (Declaration.Value :: any).Type or "Reliable"
end

local function IsEndpoint(Declaration: Parser.Declaration): boolean
	return Declaration.Type == "Event" or Declaration.Type == "Function" or Declaration.Type == "Channel"
end

--> Endpoints in declaration order, with their scope-qualified names.
function Wire.Endpoints(Declarations: { Parser.Declaration }): { { Name: string, Declaration: Parser.Declaration } }
	local Found = {}
	local function Walk(List: { Parser.Declaration }, Prefix: string)
		for _, Declaration in List do
			if Declaration.Type == "Scope" then
				Walk((Declaration :: any).Value.Values, `{Prefix}{Declaration.Name}.`)
			elseif IsEndpoint(Declaration) then
				table.insert(Found, { Name = `{Prefix}{Declaration.Name}`, Declaration = Declaration })
			end
		end
	end

	Walk(Declarations, "")
	return Found
end

local function CheckId(Name: string, Field: string, Id: number)
	if Id % 1 ~= 0 or Id < 0 or Id > MAX_ID then
		error(`{Name}: {Field} {Id} is out of range; endpoint ids are whole numbers from 0 to {MAX_ID}.`, 0)
	end
end

--> Assigns every endpoint its number on its channel, in this order:
-->  1. an explicit WireId,
-->  2. the id recorded for the same name, kind and channel in cheeto.lock,
-->  3. the lowest free id, in declaration order.
--> ReservedId and DeprecatedId values, and ids of endpoints the lock marks as
--> retired, are never handed out. Without a lock and without pins this is
--> exactly declaration order.
function Wire.Assign(Declarations: { Parser.Declaration }, Lock: Lock?): { [Parser.Declaration]: Assignment }
	local Endpoints = Wire.Endpoints(Declarations)
	local Taken: { [string]: { [number]: string } } = { Reliable = {}, Unreliable = {} }
	local Result: { [Parser.Declaration]: Assignment } = {}
	local LockedEndpoints = if Lock and Lock.endpoints then Lock.endpoints else {}

	local function Claim(Channel: string, Id: number, Owner: string)
		local Existing = Taken[Channel][Id]
		if Existing ~= nil and Existing ~= Owner then
			error(`{Owner}: {string.lower(Channel)} id {Id} is already used by {Existing}.`, 0)
		end
		Taken[Channel][Id] = Owner
	end

	--> Reservations first, so no later step can hand them out.
	for Name, Entry in LockedEndpoints do
		if Entry.retired and Entry.channel and Entry.id then
			Taken[Entry.channel] = Taken[Entry.channel] or {}
			Taken[Entry.channel][Entry.id] = `retired endpoint "{Name}"`
		end
	end
	for _, Endpoint in Endpoints do
		local Value = Endpoint.Declaration.Value :: any
		local Channel = ChannelOf(Endpoint.Declaration)
		for _, Field in { "ReservedId", "DeprecatedId" } do
			local Id = Value[Field]
			if Id ~= nil then
				CheckId(Endpoint.Name, Field, Id)
				Claim(Channel, Id, `{Field} of "{Endpoint.Name}"`)
			end
		end
	end

	local Pending = {}
	for _, Endpoint in Endpoints do
		local Declaration = Endpoint.Declaration
		local Value = Declaration.Value :: any
		local Channel = ChannelOf(Declaration)
		local Id: number? = Value.WireId
		if Id ~= nil then
			CheckId(Endpoint.Name, "WireId", Id)
			Claim(Channel, Id, `"{Endpoint.Name}"`)
		else
			local Entry = LockedEndpoints[Endpoint.Name]
			if
				Entry
				and not Entry.retired
				and Entry.channel == Channel
				and Entry.kind == Declaration.Type
				and type(Entry.id) == "number"
				and Taken[Channel][Entry.id] == nil
			then
				Id = Entry.id
				Claim(Channel, Id :: number, `"{Endpoint.Name}"`)
			end
		end

		if Id == nil then
			table.insert(Pending, Endpoint)
		else
			Result[Declaration] = {
				Name = Endpoint.Name,
				Kind = Declaration.Type,
				Channel = Channel,
				Id = Id,
				Alias = Value.DeprecatedId,
				Declaration = Declaration,
			}
		end
	end

	local Next = { Reliable = 0, Unreliable = 0 }
	for _, Endpoint in Pending do
		local Declaration = Endpoint.Declaration
		local Channel = ChannelOf(Declaration)
		local Id = Next[Channel]
		while Taken[Channel][Id] ~= nil do
			Id += 1
		end
		if Id > MAX_ID then
			error(
				`A schema can declare at most {MAX_ID + 1} {string.lower(Channel)} endpoints; "{Endpoint.Name}" does not fit. Split the schema, or move endpoints to the other channel.`,
				0
			)
		end

		Claim(Channel, Id, `"{Endpoint.Name}"`)
		Next[Channel] = Id + 1
		Result[Declaration] = {
			Name = Endpoint.Name,
			Kind = Declaration.Type,
			Channel = Channel,
			Id = Id,
			Alias = (Declaration.Value :: any).DeprecatedId,
			Declaration = Declaration,
		}
	end

	return Result
end

--> A canonical description of a payload type: everything that changes its
--> encoding or its decoded shape, nothing about spelling or layout.
function Wire.Describe(Node: any): string
	if Node == nil then
		return "none"
	end

	local Value = Node.Value or {}
	local Parts = {}
	if Node.Type == "Primitive" then
		--> The token's text, not Value.Primitive: that is the primitive's
		--> settings table, and its address changes on every run.
		local Primitive = Node.Tokens and Node.Tokens.Primitive and Node.Tokens.Primitive.Value
		table.insert(Parts, tostring(Primitive))
		if Value.Class then
			table.insert(Parts, `class={Value.Class}`)
		end
		if Value.Components then
			table.insert(Parts, `components={table.concat(Value.Components, ",")}`)
		end
	elseif Node.Type == "Enum" or Node.Type == "Set" then
		table.insert(Parts, table.concat(Value.Values, ","))
	elseif Node.Type == "TagEnum" then
		table.insert(Parts, `tag={Value.Tag}`)
		for _, Variant in Value.Values do
			table.insert(Parts, `{Variant.Name}={Wire.Describe(Variant)}`)
		end
	elseif Node.Type == "Struct" then
		for _, Field in Value.Values do
			table.insert(Parts, `{Field.Name}={Wire.Describe(Field)}`)
		end
	elseif Node.Type == "Map" or Node.Type == "Tuple" then
		for _, Child in Value.Values do
			table.insert(Parts, Wire.Describe(Child))
		end
	elseif Node.Type == "Array" or Node.Type == "Optional" then
		table.insert(Parts, Wire.Describe(Value.Of))
	elseif Node.Type == "Generic" then
		table.insert(Parts, tostring(Value.Generic))
	end

	if Value.Range then
		table.insert(Parts, `range={Value.Range.Min}..{Value.Range.Max}`)
	end

	return `{Node.Type}({table.concat(Parts, ";")})`
end

--> FNV-1a over the text. The multiply by the FNV prime (2^24 + 403) is
--> split so every intermediate stays an exact integer in a double.
local function Fnv1a(Text: string, Basis: number): number
	local Hash = Basis
	for Index = 1, #Text do
		Hash = bit32.bxor(Hash, string.byte(Text, Index))
		Hash = (bit32.lshift(Hash, 24) + Hash * 403) % 4294967296
	end
	return Hash
end

function Wire.Hash(Text: string): string
	return string.format("%08x%08x", Fnv1a(Text, 2166136261), Fnv1a(Text, 3735928559))
end

function Wire.EndpointDescription(Assignment: Assignment): string
	local Declaration = Assignment.Declaration
	local Value = Declaration.Value :: any
	local Parts = {
		Assignment.Kind,
		Assignment.Name,
		`{Assignment.Channel}:{Assignment.Id}`,
		`alias={Assignment.Alias or "none"}`,
		`data={Wire.Describe(Value.Data)}`,
	}
	if Declaration.Type == "Function" then
		table.insert(Parts, `return={Wire.Describe(Value.Return)}`)
	elseif Declaration.Type == "Channel" then
		table.insert(Parts, `delta={tostring(Value.Delta ~= false)}`)
	else
		table.insert(Parts, `mode={Value.ReliabilityMode or "Default"}`)
	end
	return table.concat(Parts, " ")
end

--> The schema fingerprint the handshake compares. Two builds with the same
--> fingerprint number and encode every endpoint identically.
function Wire.Fingerprint(Body: Parser.Body, Assignments: { [Parser.Declaration]: Assignment }): string
	local Options = Body.Value.Options
	local Lines = {
		`varints={tostring(Options.UseVarints ~= false)}`,
		`bitpacking={tostring(Options.UseBitPacking ~= false)}`,
		`strings={tostring(Options.UseStringDictionaries == true)}`,
	}
	for _, Assignment in Assignments do
		table.insert(Lines, Wire.EndpointDescription(Assignment))
	end
	table.sort(Lines)
	return Wire.Hash(table.concat(Lines, "\n"))
end

return Wire
