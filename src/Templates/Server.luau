return [[local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local PlayersMap: {[Player]: any} = {}

-- SPLIT --
if not RunService:IsServer() then
    error("Server network module can only be required from the server.")
end

local Reliable: RemoteEvent
local Unreliable: UnreliableRemoteEvent

do
    local RemoteRoot: Folder? = nil
    if RuntimeConfig.EnableRemoteNameRotation then
        local ExistingRoot = ReplicatedStorage:FindFirstChild(BASE_EVENT_NAME .. "_REMOTE_ROOT")
        if ExistingRoot and ExistingRoot:IsA("Folder") then
            RemoteRoot = ExistingRoot :: Folder
        else
            local Folder = Instance.new("Folder")
            Folder.Name = BASE_EVENT_NAME .. "_REMOTE_ROOT"
            Folder.Parent = ReplicatedStorage
            RemoteRoot = Folder
        end
    end

    local function GetRemoteParent(): Instance
        return RemoteRoot or ReplicatedStorage
    end

	local function GetInitialRemoteName(Prefix: string, Fallback: string): string
		if RuntimeConfig.EnableRemoteNameRotation then
			return RuntimeSupport.CreateRemoteName(Prefix)
		end

		return Fallback
	end

	local function HasRemoteShape(Object: any, ClassName: string): boolean
		if Object == nil then
			return false
		end

		local IsAOk, IsAResult = pcall(function()
			return Object:IsA(ClassName)
		end)
		if IsAOk then
			return IsAResult == true
		end

		return type(Object) == "table" and Object.FireClient ~= nil
	end

	function RuntimeSupport.FindPublishedRemote(Attribute: string, ClassName: string): Instance?
		if RemoteRoot == nil then
			return nil
		end

		local PublishedName = RemoteRoot:GetAttribute(Attribute)
		local Published = if type(PublishedName) == "string" then RemoteRoot:FindFirstChild(PublishedName) else nil
		if HasRemoteShape(Published, ClassName) then
			return Published
		end
		return nil
	end

	local ReliableName = GetInitialRemoteName("R", BASE_EVENT_NAME .. "_RELIABLE_REMOTE")
	Reliable = (RuntimeSupport.FindPublishedRemote("ReliableName", "RemoteEvent") or GetRemoteParent():FindFirstChild(ReliableName)) :: RemoteEvent
	if not HasRemoteShape(Reliable, "RemoteEvent") then
		Reliable = Instance.new("RemoteEvent")
		Reliable.Name = ReliableName
		Reliable.Parent = GetRemoteParent()
	end

	local UnreliableName = GetInitialRemoteName("U", BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE")
	Unreliable = (RuntimeSupport.FindPublishedRemote("UnreliableName", "UnreliableRemoteEvent") or GetRemoteParent():FindFirstChild(UnreliableName)) :: UnreliableRemoteEvent
	if not HasRemoteShape(Unreliable, "UnreliableRemoteEvent") then
		Unreliable = Instance.new("UnreliableRemoteEvent")
		Unreliable.Name = UnreliableName
        Unreliable.Parent = GetRemoteParent()
    end

    if RemoteRoot then
        for _, Child in RemoteRoot:GetChildren() do
            if Child ~= Reliable and Child ~= Unreliable and (Child:IsA("RemoteEvent") or Child:IsA("UnreliableRemoteEvent")) then
                Child:Destroy()
            end
        end
    end

    local function PublishRemoteNames()
        if RemoteRoot == nil then
            return
        end

        RemoteRoot:SetAttribute("ReliableName", Reliable.Name)
        RemoteRoot:SetAttribute("UnreliableName", Unreliable.Name)
        RemoteRoot:SetAttribute("Epoch", (RemoteRoot:GetAttribute("Epoch") :: number? or 0) + 1)
    end

    PublishRemoteNames()

    if
        RuntimeConfig.EnableRemoteNameRotation
        and RuntimeConfig.RemoteNameRotationSeconds > 0
        and RemoteRoot
        and RemoteRoot:GetAttribute("RotationLoopActive") ~= true
    then
        RemoteRoot:SetAttribute("RotationLoopActive", true)
        task.spawn(function()
            while Reliable.Parent ~= nil and Unreliable.Parent ~= nil do
                task.wait(RuntimeConfig.RemoteNameRotationSeconds)
                Reliable.Name = RuntimeSupport.CreateRemoteName("R")
                Unreliable.Name = RuntimeSupport.CreateRemoteName("U")
                PublishRemoteNames()
            end
        end)
    end

    RuntimeSupport.InstallRemoteDecoys(GetRemoteParent(), RuntimeConfig.RemoteDecoyCount)
end

RuntimeSupport.IsServer = true

--> Appends an encoded event to a player's pending reliable batch, counting
--> its bytes against that player's backpressure budget.
function RuntimeSupport.CopyReliable(Player: Player, Source: buffer, Size: number, Instances: {Instance}, Priority: string)
    if not IsPlayerActive(Player) then
        return
    end
    if not RuntimeSupport.RecordQueuedEvent(Player, "Reliable", Size, Priority) then
        return
    end

    Load(PlayersMap[Player], true)
    local Position = Allocate(Size)
    buffer.copy(SendBuffer, Position, Source, 0, Size)
    table.move(Instances, 1, #Instances, #SendInstances + 1, SendInstances)
    PlayersMap[Player] = Save()
end

--> Copies the event sitting in the loaded scratch buffer into each
--> recipient's pending reliable batch.
function RuntimeSupport.BroadcastReliable(List: {Player}, Except: Player?, Priority: string)
    local Source = SendBuffer
    local Size = SendCursor
    local Instances = SendInstances
    for _, Player in List do
        if Player ~= Except then
            RuntimeSupport.CopyReliable(Player, Source, Size, Instances, Priority)
        end
    end
end

function RuntimeSupport.SendUnreliableBatch(Player: Player, Batch: any)
    if not IsPlayerActive(Player) then
        return
    end

    local Packet = buffer.create(Batch.Size)
    buffer.copy(Packet, 0, Batch.Buffer, 0, Batch.Size)
    Unreliable:FireClient(Player, Packet, InstancePayload(Batch.Instances))
    TrackSend("Unreliable", Batch.Size, Player)
end

--> Queues an encoded unreliable event for one player. With BatchUnreliable
--> (the default) events for the same player share one remote call per
--> frame, up to MaxUnreliablePacketBytes.
function RuntimeSupport.QueueUnreliable(Player: Player, Source: buffer, Size: number, Instances: {Instance}, Priority: string)
    if not IsPlayerActive(Player) then
        return
    end
    if not RuntimeSupport.AdmitEvent(Player, "Unreliable", Size, Priority) then
        return
    end

    if RuntimeConfig.BatchUnreliable then
        RuntimeSupport.AppendUnreliable(Player, Source, Size, Instances)
        return
    end

    RuntimeSupport.SendUnreliableBatch(Player, { Buffer = Source, Size = Size, Instances = Instances })
end

--> Answers a call or prediction the server dropped before its handler ran,
--> so the client can fail fast with the reason. Events sent without a
--> prediction get no answer; nothing on the client is waiting for one.
function RuntimeSupport.RejectReceive(Player: Player, Name: string, Index: number, InvocationIdentifier: number?, Reason: string?)
    if InvocationIdentifier == nil and not Frame.HasPredictionId() then
        return
    end
    if not IsPlayerActive(Player) then
        return
    end

    Load(PlayersMap[Player], true)
    if InvocationIdentifier ~= nil then
        RuntimeSupport.WriteInvocationFailure(Index, InvocationIdentifier, Reason)
    else
        WritePredictionAckPayload(Name, false, Reason)
    end
    PlayersMap[Player] = Save()
end

--> Sends the event in the loaded scratch buffer on the unreliable remote.
--> Targets is one player, a list of players, or nil for everyone.
function RuntimeSupport.SendUnreliable(Targets: any, Except: Player?, Priority: string?)
    local Size = SendCursor
    if RuntimeConfig.MaxUnreliablePacketBytes > 0 and Size > RuntimeConfig.MaxUnreliablePacketBytes then
        DropPacket(if type(Targets) == "table" then nil else Targets, "Unreliable", "MaxPacketBytes", Size)
        return
    end

    local Lane = Priority or "Gameplay"
    if Targets == nil and Except == nil and not RuntimeConfig.BatchUnreliable then
        local Packet = buffer.create(Size)
        buffer.copy(Packet, 0, SendBuffer, 0, Size)
        Unreliable:FireAllClients(Packet, InstancePayload(SendInstances))
        TrackSend("Unreliable", Size, nil)
        return
    end

    local Source = SendBuffer
    local Instances = SendInstances
    local List = if Targets == nil then Players:GetPlayers() elseif type(Targets) == "table" then Targets else { Targets }
    for _, Player in List do
        if Player ~= Except then
            RuntimeSupport.QueueUnreliable(Player, Source, Size, Instances, Lane)
        end
    end
end

local function QueueClientIntegrityChallenge(Player: Player, ChallengeId: number, Nonce: number)
    Load(PlayersMap[Player], true)
    RuntimeSupport.WriteClientIntegrityChallenge(ChallengeId, Nonce)
    PlayersMap[Player] = Save()
end

local function ChallengeClientIntegrity(Player: Player): number?
    local ChallengeId, Nonce = RuntimeSupport.CreateClientIntegrityChallenge(Player, true)
    if ChallengeId == nil or Nonce == nil then
        return nil
    end

    QueueClientIntegrityChallenge(Player, ChallengeId, Nonce)
    return ChallengeId
end

Players.PlayerRemoving:Connect(function(Player)
    PlayersMap[Player] = nil
    ClearPlayerRuntimeState(Player)
end)

local function StepReplication()
    ProfileBegin("Cheeto.Flush.Server")
    --> Invocation timeouts are only meaningful if something sweeps them. Without
    --> this an Invoke whose reply never arrives leaves its thread suspended for
    --> the life of the server -- a lost reply, or a peer that simply never
    --> answers, silently leaks a coroutine and hangs that caller forever.
    ExpireInvocations()
    RuntimeSupport.FlushLatest()
    RuntimeSupport.FlushUnreliableBatches()
    local ActivePlayers = Players:GetPlayers()
    RuntimeSupport.StepClientIntegrity(ActivePlayers, QueueClientIntegrityChallenge)
    RuntimeSupport.StepCharacterIntegrity(ActivePlayers)
    RunStateFlushers()
    --> Every player gets the server's handshake once, even one the server
    --> never sends anything else to, so its client can check the schema.
    if RuntimeConfig.EnableProtocolHandshake then
        for _, Player in ActivePlayers do
            if not RuntimeState.PeerHandshakesSent[Player] then
                Load(PlayersMap[Player], true)
                RuntimeSupport.WriteCapabilityHandshake()
                PlayersMap[Player] = Save()
                RuntimeState.PeerHandshakesSent[Player] = true
            end
        end
    end
    for Player, Send in PlayersMap do
        Load(Send)
        FlushBits()
        PlayersMap[Player] = Save()
        Send = PlayersMap[Player]
        if Send.Cursor <= 0 then
            continue
        end
        if not RuntimeSupport.ShouldFlush(Player, "Reliable", Send.Cursor, "Gameplay") then
            continue
        end

        local Buffer = buffer.create(Send.Cursor)
        buffer.copy(Buffer, 0, Send.Buffer, 0, Send.Cursor)
        if RuntimeConfig.MaxReliablePacketBytes > 0 and Send.Cursor > RuntimeConfig.MaxReliablePacketBytes then
            DropPacket(Player, "Reliable", "MaxPacketBytes", Send.Cursor)
            RuntimeSupport.RecordFlush(Player, "Reliable", 0)
        elseif IsPlayerActive(Player) then
            for _, Fragment in RuntimeSupport.FragmentReliablePacket(Player, Buffer, InstancePayload(Send.Instances)) do
                Reliable:FireClient(Player, Fragment.Buffer, Fragment.Instances)
                TrackSend("Reliable", buffer.len(Fragment.Buffer), Player)
            end
            RuntimeSupport.RecordFlush(Player, "Reliable", Send.Cursor)
        end

        Send.Size = 64
        Send.Cursor = 0
        Send.Buffer = AcquireBuffer(64)
        Send.BitByte = 0
        Send.BitCount = 0
        Send.StringIds = {}
        Send.NextStringId = 1
        table.clear(Send.Instances)
    end
    ProfileEnd()
end
]]
