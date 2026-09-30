return [[local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- SPLIT --
if not RunService:IsClient() then
    error("Client network module can only be required from the client.")
end

local Reliable: RemoteEvent
local Unreliable: UnreliableRemoteEvent
local RemoteRoot: Folder? = nil

local function WaitForNamedRemote(Attribute: string): Instance
    local Root = RemoteRoot
    if Root == nil then
        error("Rotating Cheeto remote root is unavailable.")
    end

    while true do
        local Name = Root:GetAttribute(Attribute)
        while type(Name) ~= "string" or Name == "" do
            Root:GetAttributeChangedSignal(Attribute):Wait()
            Name = Root:GetAttribute(Attribute)
        end

        local Remote = Root:WaitForChild(Name, 5)
        if Remote then
            return Remote
        end
    end
end

if RuntimeConfig.EnableRemoteNameRotation then
    RemoteRoot = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_REMOTE_ROOT") :: Folder

    Reliable = WaitForNamedRemote("ReliableName") :: RemoteEvent
    Unreliable = WaitForNamedRemote("UnreliableName") :: UnreliableRemoteEvent
else
    Reliable = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_RELIABLE_REMOTE") :: RemoteEvent
    Unreliable = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE") :: UnreliableRemoteEvent
end

local function BindClientRemotes(
    ReliableProcessor: (buffer, {Instance}?) -> (),
    UnreliableProcessor: (buffer, {Instance}?) -> ()
)
    local ReliableConnection: RBXScriptConnection? = nil
    local UnreliableConnection: RBXScriptConnection? = nil

    local function BindReliable()
        local NextReliable = if RemoteRoot then WaitForNamedRemote("ReliableName") :: RemoteEvent else Reliable
        if ReliableConnection and Reliable == NextReliable then
            return
        end
        if ReliableConnection then
            ReliableConnection:Disconnect()
        end
        Reliable = NextReliable
        ReliableConnection = Reliable.OnClientEvent:Connect(ReliableProcessor)
    end

    local function BindUnreliable()
        local NextUnreliable = if RemoteRoot then WaitForNamedRemote("UnreliableName") :: UnreliableRemoteEvent else Unreliable
        if UnreliableConnection and Unreliable == NextUnreliable then
            return
        end
        if UnreliableConnection then
            UnreliableConnection:Disconnect()
        end
        Unreliable = NextUnreliable
        UnreliableConnection = Unreliable.OnClientEvent:Connect(UnreliableProcessor)
    end

    BindReliable()
    BindUnreliable()
    if RemoteRoot then
        RemoteRoot:GetAttributeChangedSignal("ReliableName"):Connect(BindReliable)
        RemoteRoot:GetAttributeChangedSignal("UnreliableName"):Connect(BindUnreliable)
    end
end

function RuntimeSupport.CopyReliable(_Target: any, Source: buffer, Size: number, Instances: {Instance}, Priority: string)
    if not RuntimeSupport.RecordQueuedEvent("Server", "Reliable", Size, Priority) then
        return
    end

    local Position = Allocate(Size)
    buffer.copy(SendBuffer, Position, Source, 0, Size)
    table.move(Instances, 1, #Instances, #SendInstances + 1, SendInstances)
end

function RuntimeSupport.SendUnreliableBatch(_Target: any, Batch: any)
    local Packet = buffer.create(Batch.Size)
    buffer.copy(Packet, 0, Batch.Buffer, 0, Batch.Size)
    Unreliable:FireServer(Packet, InstancePayload(Batch.Instances))
    TrackSend("Unreliable", Batch.Size, nil)
end

function RuntimeSupport.QueueUnreliable(_Target: any, Source: buffer, Size: number, Instances: {Instance}, Priority: string)
    if not RuntimeSupport.AdmitEvent("Server", "Unreliable", Size, Priority) then
        return
    end

    if RuntimeConfig.BatchUnreliable then
        RuntimeSupport.AppendUnreliable("Server", Source, Size, Instances)
        return
    end

    RuntimeSupport.SendUnreliableBatch("Server", { Buffer = Source, Size = Size, Instances = Instances })
end

--> Sends the event in the loaded scratch buffer on the unreliable remote.
function RuntimeSupport.SendUnreliable(_Targets: any?, _Except: any?, Priority: string?)
    local Size = SendCursor
    if RuntimeConfig.MaxUnreliablePacketBytes > 0 and Size > RuntimeConfig.MaxUnreliablePacketBytes then
        DropPacket("Client", "Unreliable", "MaxPacketBytes", Size)
        return
    end

    RuntimeSupport.QueueUnreliable("Server", SendBuffer, Size, SendInstances, Priority or "Gameplay")
end

RuntimeSupport.StartClientShield()

local function StepReplication()
    ProfileBegin("Cheeto.Flush.Client")
    --> Invocation timeouts are only meaningful if something sweeps them. Without
    --> this an Invoke whose reply never arrives leaves its thread suspended for
    --> the life of the server -- a lost reply, or a peer that simply never
    --> answers, silently leaks a coroutine and hangs that caller forever.
    ExpireInvocations()
    RuntimeSupport.FlushLatest()
    RuntimeSupport.FlushUnreliableBatches()
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
        RuntimeSupport.RecordFlush("Server", "Reliable", 0)
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
