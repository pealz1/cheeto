--[[
	Coverage for the IY detection matcher and the signed-report helpers.

	The matcher is pure, so we build real instance trees with @lune/roblox: IY
	shaped trees must be detected, and legitimate game GUIs must NOT be (the
	false-positive guard). No networking or Roblox runtime is involved.
]]

local process = require("@lune/process")
local roblox = require("@lune/roblox")
local stdio = require("@lune/stdio")

local IYSignatures = require("../extras/security/IYSignatures")
local SecureReport = require("../extras/security/SecureReport")

local Instance = roblox.Instance

local function Ok(message: string)
	stdio.write(`[{stdio.color("green")}OK{stdio.color("reset")}] {message}\n`)
end

local function Fail(message: string)
	stdio.write(`[{stdio.color("red")}FAIL{stdio.color("reset")}] {message}\n`)
	process.exit(22)
end

local function make(class: string, name: string, parent: Instance?): Instance
	local instance = Instance.new(class)
	instance.Name = name
	if parent then
		instance.Parent = parent
	end
	return instance
end

--> IY-shaped trees: each must be detected with the expected signal.

local function detectExpect(name: string, container: Instance, expected: string)
	local result = IYSignatures.scan(container)
	if not result.detected then
		Fail(`"{name}" should have been detected but was not`)
	end
	if result.signal ~= expected then
		Fail(`"{name}" detected via "{tostring(result.signal)}", expected "{expected}"`)
	end
	Ok(`Detected IY via {expected} ({name})`)
end

do
	local gui = make("ScreenGui", "aXk29fZ") -- randomized root, like IY
	local label = make("TextLabel", "Title", gui);
	(label :: any).Text = "Infinite Yield FE v6.4.1 \u{1F383}"
	detectExpect("brand text with emoji + version", gui, "brand-text")
end

do
	local gui = make("ScreenGui", "qq11")
	local label = make("TextLabel", "Credits", gui);
	(label :: any).Text = IYSignatures.Signals.CreditsText
	detectExpect("credits string", gui, "credits-text")
end

do
	local gui = make("ScreenGui", "zzz")
	local holder = make("Frame", "Holder", gui)
	local box = make("TextBox", "Cmdbar", holder);
	(box :: any).PlaceholderText = "Command Bar"
	detectExpect("cmdbar textbox with placeholder", gui, "cmdbar-textbox")
end

do
	--> Cmdbar with a changed placeholder still caught by the structural signal.
	local gui = make("ScreenGui", "www")
	local scaled = make("Frame", "ScaledHolder", gui)
	local holder = make("Frame", "Holder", scaled)
	local box = make("TextBox", "Cmdbar", holder);
	(box :: any).PlaceholderText = "type here"
	detectExpect("holder>cmdbar structure", gui, "holder-cmdbar-structure")
end

--> False-positive guard: none of these legitimate trees may be detected.

local function noDetect(name: string, container: Instance)
	local result = IYSignatures.scan(container)
	if result.detected then
		Fail(`false positive on "{name}" (signal {tostring(result.signal)})`)
	end
	Ok(`No false positive: {name}`)
end

do
	local gui = make("ScreenGui", "MainMenu")
	local frame = make("Frame", "Holder", gui) -- "Holder" is a common frame name
	local play = make("TextButton", "Play", frame);
	(play :: any).Text = "Play"
	local search = make("TextBox", "SearchBox", frame);
	(search :: any).PlaceholderText = "Search..."
	local label = make("TextLabel", "Welcome", frame);
	(label :: any).Text = "Welcome to my game"
	noDetect("legit menu with a Holder frame and a search box", gui)
end

do
	--> A lone TextBox named "Cmdbar" but with a normal placeholder and no Holder
	--> parent must not trip the matcher.
	local gui = make("ScreenGui", "Console")
	local box = make("TextBox", "Cmdbar", gui);
	(box :: any).PlaceholderText = "enter command"
	noDetect("lone Cmdbar without placeholder or Holder", gui)
end

do
	local gui = make("ScreenGui", "Shop")
	local label = make("TextLabel", "Info", gui);
	(label :: any).Text = "Infinite coins available!" -- contains "Infinite" but not "Infinite Yield"
	noDetect("text mentioning Infinite but not the brand", gui)
end

--> Signed report roundtrip + tamper detection.

do
	local secret = "server-issued-secret-abc"
	local nonce = "nonce-01"
	local seq = 7
	local kind = "detect"
	local payload = "cmdbar-textbox"

	local signature = SecureReport.sign(secret, nonce, seq, kind, payload)
	assert(SecureReport.verify(secret, nonce, seq, kind, payload, signature), "valid signature must verify")
	assert(not SecureReport.verify(secret, nonce, seq, kind, "tampered", signature), "tampered payload must fail")
	assert(not SecureReport.verify("other-secret", nonce, seq, kind, payload, signature), "wrong secret must fail")
	assert(not SecureReport.verify(secret, "nonce-02", seq, kind, payload, signature), "replayed nonce must fail")
	assert(not SecureReport.verify(secret, nonce, seq + 1, kind, payload, signature), "wrong seq must fail")
	assert(not SecureReport.verify(secret, nonce, seq, kind, payload, "short"), "malformed signature must fail")
	Ok("Signed report verifies, and tamper/replay/malformed all rejected")
end

stdio.write(`{stdio.color("green")}All security tests passed!{stdio.color("reset")}\n`)

return true
