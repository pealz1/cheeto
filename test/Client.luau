local Shared = require("./Shared")

local Signal = Shared.Signal
local ClientEnviornment = Shared.GetEnvironment()

local function Clone(Source: buffer): buffer
	local Size = buffer.len(Source)
	local Target = buffer.create(Size)
	buffer.copy(Target, 0, Source, 0, Size)
	return Target
end

local function Fire(Reliable: boolean, ...)
	local Arguments = { ... }
	local Buffer = if typeof(Arguments[1]) == "buffer" then Arguments[1] else Arguments[2]
	local Instances = Arguments[#Arguments]

	Buffer = Clone(Buffer)
	Instances = if typeof(Instances) == "table" then table.clone(Instances) else {}

	Shared.Bridge:Fire("Client", Reliable and "CHEETO_RELIABLE_REMOTE" or "CHEETO_UNRELIABLE_REMOTE", Buffer, Instances)
end

ClientEnviornment.Instances.CHEETO_RELIABLE_REMOTE = {
	FireServer = function(self, ...)
		Fire(true, ...)
	end,
	OnClientEvent = Signal.new(),
}

ClientEnviornment.Instances.CHEETO_UNRELIABLE_REMOTE = {
	FireServer = function(self, ...)
		Fire(false, ...)
	end,
	OnClientEvent = Signal.new(),
}

Shared.Bridge:Connect(function(From: string, Remote: string, Buffer: buffer, Instances: { Instance })
	if From == "Client" then
		return
	end

	for Index, Value in Instances do
		if Value == Shared.ServerOnlyInstance then
			Instances[Index] = nil
		end
	end

	ClientEnviornment.Instances[Remote].OnClientEvent:Fire(Buffer, Instances)
end)

return ClientEnviornment
