local RunService = game:GetService("RunService")
if RunService:IsServer() then
	return require("../cheeto/Server")
elseif RunService:IsClient() then
	return require("../cheeto/Client")
end
