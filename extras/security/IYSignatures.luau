--!nonstrict
--[[
	Infinite Yield fingerprint matcher.

	Pure and side-effect free: it takes a GUI container and reports whether that
	container holds an Infinite Yield instance, and which signal matched. Every
	signal is individually high-confidence — a single match means IY is present,
	with effectively zero false positives against legitimate games, because each
	one keys off a string or structure that IY renders and normal games do not.

	The client scanner (IYDetector.client.luau) feeds this every readable GUI
	container; the server guard kicks on a verified positive.

	Honest limit: this only sees IY when its UI lands in a container a game script
	can read. A fully cloaked executor that parents IY into protected CoreGui via
	gethui() and neuters this script evades it — no game-side Luau can beat
	higher-privilege code. It catches stock IY (the common case), it is not an
	absolute guarantee.
]]

export type Detection = {
	detected: boolean,
	signal: string?,
	instance: Instance?,
}

--> Exact brand strings IY renders. No legitimate game ships these.
local BRAND_TEXT = "Infinite Yield"
local CREDITS_TEXT = "Edge // Zwolf // Moon // Toon // Peyton // ATP"
local CMDBAR_PLACEHOLDER = "Command Bar"
local CMDBAR_NAME = "Cmdbar"
local HOLDER_NAME = "Holder"

local TEXT_CLASSES = {
	TextLabel = true,
	TextButton = true,
	TextBox = true,
}

--> Reads a property only when the class actually has it, so scanning arbitrary
--> instances never errors on a missing property.
local function safeText(instance: Instance): string?
	if TEXT_CLASSES[instance.ClassName] then
		return (instance :: any).Text
	end
	return nil
end

local function containsText(instance: Instance, needle: string): boolean
	local text = safeText(instance)
	return text ~= nil and string.find(text, needle, 1, true) ~= nil
end

--> Tests a single instance against every text/structure signal.
--> Returns the matched signal name, or nil.
local function matchInstance(instance: Instance): string?
	--> Brand text — survives version bumps and seasonal emoji injection because
	--> we match the "Infinite Yield" substring, not the full title.
	if containsText(instance, BRAND_TEXT) then
		return "brand-text"
	end

	--> Credits string — verbatim and unique to IY.
	if containsText(instance, CREDITS_TEXT) then
		return "credits-text"
	end

	--> Command bar: a TextBox literally named "Cmdbar" whose placeholder is
	--> "Command Bar". Both together are IY-specific; requiring both keeps a lone
	--> "Cmdbar" name in some other game from ever tripping it.
	if instance.ClassName == "TextBox" and instance.Name == CMDBAR_NAME then
		if (instance :: any).PlaceholderText == CMDBAR_PLACEHOLDER then
			return "cmdbar-textbox"
		end
	end

	return nil
end

--> Structural fallback: a Frame named "Holder" that has a descendant TextBox
--> named "Cmdbar". Catches the command bar even if IY changes the placeholder.
local function matchStructure(container: Instance): Instance?
	for _, holder in container:GetDescendants() do
		if holder.ClassName == "Frame" and holder.Name == HOLDER_NAME then
			for _, child in holder:GetDescendants() do
				if child.ClassName == "TextBox" and child.Name == CMDBAR_NAME then
					return holder
				end
			end
		end
	end
	return nil
end

--> Scans a container's descendants once and returns the first detection.
local function scan(container: Instance): Detection
	for _, instance in container:GetDescendants() do
		local signal = matchInstance(instance)
		if signal then
			return { detected = true, signal = signal, instance = instance }
		end
	end

	local structural = matchStructure(container)
	if structural then
		return { detected = true, signal = "holder-cmdbar-structure", instance = structural }
	end

	return { detected = false }
end

return {
	scan = scan,
	--> Exposed for tests and for callers that already hold a single instance.
	matchInstance = matchInstance,
	Signals = {
		BrandText = BRAND_TEXT,
		CreditsText = CREDITS_TEXT,
		CmdbarPlaceholder = CMDBAR_PLACEHOLDER,
		CmdbarName = CMDBAR_NAME,
		HolderName = HOLDER_NAME,
	},
}
