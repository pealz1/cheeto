return [[local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- SPLIT --
if not RunService:IsClient() then
    error("Client network module can only be required from the client.")
end

local Reliable: RemoteEvent
local Unreliable: UnreliableRemoteEvent

if RuntimeConfig.EnableRemoteNameRotation then
    local RemoteRoot = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_REMOTE_ROOT")

    local function WaitForRemoteName(Attribute: string): string
        local Name = RemoteRoot:GetAttribute(Attribute)
        while type(Name) ~= "string" or Name == "" do
            RemoteRoot:GetAttributeChangedSignal(Attribute):Wait()
            Name = RemoteRoot:GetAttribute(Attribute)
        end

        return Name
    end

    local function WaitForNamedRemote(Attribute: string): Instance
        while true do
            local Name = WaitForRemoteName(Attribute)
            local Remote = RemoteRoot:WaitForChild(Name, 5)
            if Remote then
                return Remote
            end
        end
    end

    Reliable = WaitForNamedRemote("ReliableName") :: RemoteEvent
    Unreliable = WaitForNamedRemote("UnreliableName") :: UnreliableRemoteEvent
else
    Reliable = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_RELIABLE_REMOTE") :: RemoteEvent
    Unreliable = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE") :: UnreliableRemoteEvent
end

RuntimeSupport.StartClientShield()

local function StepReplication()
    ProfileBegin("Cheeto.Flush.Client")
    FlushBits()
    if SendCursor <= 0 then
        ProfileEnd()
        return
    end
    if not RuntimeSupport.ShouldFlush("Server", "Reliable", SendCursor, "Gameplay") then
        ProfileEnd()
        return
    end

    local Buffer = buffer.create(SendCursor)
    buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)
    if RuntimeConfig.MaxReliablePacketBytes > 0 and SendCursor > RuntimeConfig.MaxReliablePacketBytes then
        DropPacket("Client", "Reliable", "MaxPacketBytes", SendCursor)
    else
        for _, Fragment in RuntimeSupport.FragmentReliablePacket("Server", Buffer, InstancePayload(SendInstances)) do
            Reliable:FireServer(Fragment.Buffer, Fragment.Instances)
            TrackSend("Reliable", buffer.len(Fragment.Buffer), nil)
        end
        RuntimeSupport.RecordFlush("Server", "Reliable", SendCursor)
    end

    SendSize = 64
    SendCursor = 0
    SendOffset = 0
    SendBuffer = AcquireBuffer(64)
    State.SendBuffer = SendBuffer
    table.clear(SendInstances)
    SendBitByte = 0
    SendBitCount = 0
    SendStringIds = {}
    NextSendStringId = 1
    ProfileEnd()
end
]]
