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

function RuntimeSupport.GetCharacterIntegrityPlayer(Player: any): any
    local Key = RuntimeSupport.PeerKey(Player)
    local PlayerState = RuntimeState.CharacterIntegrity.Players[Key]
    if PlayerState ~= nil then
        PlayerState.Player = Player
        return PlayerState
    end

    local Now = os.clock()
    PlayerState = {
        Player = Player,
        Character = nil,
        LastPosition = nil,
        LastSafeCFrame = nil,
        LastSampleAt = 0,
        NextSampleAt = Now,
        LastDecayAt = Now,
        GraceUntil = Now + math.max(0, RuntimeConfig.CharacterIntegrityJoinGraceSeconds),
        Score = 0,
        ConsecutiveBreaches = 0,
        LastCorrectionAt = 0,
        LastReason = "",
        LastAction = "none",
        Reasons = {} :: {[string]: number},
        History = {},
    }
    RuntimeState.CharacterIntegrity.Players[Key] = PlayerState
    return PlayerState
end

function RuntimeSupport.DecayCharacterIntegrityPlayer(PlayerState: any, Now: number)
    local Delta = math.max(0, Now - (PlayerState.LastDecayAt or Now))
    PlayerState.LastDecayAt = Now
    local Decay = Delta * math.max(0, RuntimeConfig.CharacterIntegrityScoreDecayPerSecond)
    PlayerState.Score = math.max(0, PlayerState.Score - Decay)
    if Decay > 0 then
        for Reason, Score in PlayerState.Reasons do
            local Next = math.max(0, Score - Decay)
            PlayerState.Reasons[Reason] = if Next > 0 then Next else nil
        end
    end
end

function RuntimeSupport.CharacterIntegrityAction(PlayerState: any): string
    local Mode = string.lower(tostring(RuntimeConfig.CharacterIntegrityMode))
    if
        Mode == "kick"
        and RuntimeConfig.CharacterIntegrityKick
        and PlayerState.Score >= RuntimeConfig.CharacterIntegrityKickScore
        and PlayerState.ConsecutiveBreaches >= math.max(1, RuntimeConfig.CharacterIntegrityMaxConsecutiveBreaches)
    then
        return "kick"
    end

    if
        (Mode == "correct" or Mode == "kick")
        and PlayerState.Score >= RuntimeConfig.CharacterIntegrityCorrectionScore
        and os.clock() >= PlayerState.LastCorrectionAt
    then
        return "correct"
    end
    return if Mode == "observe" then "observe" else "report"
end

function RuntimeSupport.ReportCharacterIntegrity(Player: any, Reason: string, Weight: number?, Detail: string?): (number, string)
    local PlayerState = RuntimeSupport.GetCharacterIntegrityPlayer(Player)
    local Now = os.clock()
    RuntimeSupport.DecayCharacterIntegrityPlayer(PlayerState, Now)
    local Amount = math.max(1, math.floor(Weight or 1))
    PlayerState.Score = math.min(1000, PlayerState.Score + Amount)
    PlayerState.Reasons[Reason] = math.min(1000, (PlayerState.Reasons[Reason] or 0) + Amount)
    PlayerState.LastReason = Reason
    local Action = RuntimeSupport.CharacterIntegrityAction(PlayerState)
    PlayerState.LastAction = Action

    local Key = RuntimeSupport.PeerKey(Player)
    local ByReason = RuntimeState.CharacterIntegrity.LastEvidence[Key]
    if ByReason == nil then
        ByReason = {}
        RuntimeState.CharacterIntegrity.LastEvidence[Key] = ByReason
    end
    local Last = ByReason[Reason]
    local Throttled = Last ~= nil and Now - Last < math.max(0, RuntimeConfig.CharacterIntegrityReportCooldownSeconds)
    if not Throttled or Action == "kick" then
        ByReason[Reason] = Now
        local Entry = {
            Player = Player,
            UserId = TryGetUserId(Player),
            Reason = Reason,
            Detail = Detail or "",
            Weight = Amount,
            Score = PlayerState.Score,
            ConsecutiveBreaches = PlayerState.ConsecutiveBreaches,
            Action = Action,
            Time = Now,
        }
        table.insert(RuntimeState.CharacterIntegrity.Evidence, Entry)
        while #RuntimeState.CharacterIntegrity.Evidence > math.max(1, RuntimeConfig.CharacterIntegrityHistoryLimit * 8) do
            table.remove(RuntimeState.CharacterIntegrity.Evidence, 1)
        end
        table.insert(PlayerState.History, Entry)
        while #PlayerState.History > math.max(1, RuntimeConfig.CharacterIntegrityHistoryLimit) do
            table.remove(PlayerState.History, 1)
        end

        MetricAdd("CharacterIntegrityActions", Action)
        if Action ~= "observe" then
            ReportViolation(Player, "$characterIntegrity", "CharacterIntegrity", Reason, Amount, Action)
        end
        EmitTelemetry("security.characterIntegrity", Entry)
    end

    if Action == "kick" then
        KickClientShieldSource(Player)
    end
    return PlayerState.Score, Action
end

function RuntimeSupport.SetMovementLimits(Player: any, Limits: {[string]: number}?)
    if Limits ~= nil then
        assert(type(Limits) == "table", "[Cheeto]: Expected a movement limits table.")
        for Key, Value in Limits do
            assert((Key == "Horizontal" or Key == "Vertical") and RuntimeSupport.FiniteNumber(Value) and Value >= 1,
                "[Cheeto]: Movement limits must be finite speeds of at least one stud per second.")
        end
    end
    RuntimeSupport.GetCharacterIntegrityPlayer(Player).Limits = if Limits then table.clone(Limits) else nil
end

function RuntimeSupport.GrantCharacterIntegrityGrace(Player: any, Seconds: number?, Reason: string?)
    local PlayerState = RuntimeSupport.GetCharacterIntegrityPlayer(Player)
    local Now = os.clock()
    assert(Seconds == nil or RuntimeSupport.FiniteNumber(Seconds), "[Cheeto]: Expected finite grace seconds.")
    local Duration = math.max(0, Seconds or RuntimeConfig.CharacterIntegrityTeleportGraceSeconds)
    PlayerState.GraceUntil = math.max(PlayerState.GraceUntil, Now + Duration)
    PlayerState.LastReason = Reason or "grace"
    PlayerState.ConsecutiveBreaches = 0
end

function RuntimeSupport.ReadCharacterSnapshot(Player: any): (any, any, any, any)
    local Success, Character, Root, Humanoid = pcall(function()
        local Character = Player.Character
        if Character == nil then
            return nil, nil, nil
        end
        return Character, Character:FindFirstChild("HumanoidRootPart"), Character:FindFirstChildOfClass("Humanoid")
    end)
    if not Success or Character == nil or Root == nil or Humanoid == nil then
        return nil, nil, nil, nil
    end
    return Character, Root, Humanoid, Root.CFrame
end

function RuntimeSupport.ReconcileCharacterIntegrity(Player: any, ResetScore: boolean?): boolean
    local PlayerState = RuntimeSupport.GetCharacterIntegrityPlayer(Player)
    local Character, Root, Humanoid, RootCFrame = RuntimeSupport.ReadCharacterSnapshot(Player)
    if Character == nil or Root == nil or Humanoid == nil then
        return false
    end

    if not RuntimeSupport.FiniteComponents(RootCFrame:GetComponents()) then
        return false
    end
    PlayerState.Character = Character
    PlayerState.LastPosition = Root.Position
    PlayerState.LastSafeCFrame = RootCFrame
    PlayerState.LastSampleAt = os.clock()
    PlayerState.NextSampleAt = PlayerState.LastSampleAt + math.max(0.05, RuntimeConfig.CharacterIntegritySampleIntervalSeconds)
    PlayerState.ConsecutiveBreaches = 0
    if ResetScore == true then
        PlayerState.Score = 0
        table.clear(PlayerState.Reasons)
    end
    return true
end

function RuntimeSupport.TeleportCharacterIntegrity(Player: any, Target: CFrame, GraceSeconds: number?): boolean
    if typeof(Target) ~= "CFrame" or not RuntimeSupport.FiniteComponents(Target:GetComponents()) then
        return false
    end

    assert(GraceSeconds == nil or RuntimeSupport.FiniteNumber(GraceSeconds), "[Cheeto]: Expected finite grace seconds.")
    local Character, Root = RuntimeSupport.ReadCharacterSnapshot(Player)
    if Character == nil or Root == nil then
        return false
    end

    local Success = pcall(function()
        Character:PivotTo(Target)
        Root.AssemblyLinearVelocity = Vector3.zero
        Root.AssemblyAngularVelocity = Vector3.zero
    end)
    if Success then
        RuntimeSupport.GrantCharacterIntegrityGrace(Player, GraceSeconds, "server-teleport")
        RuntimeSupport.ReconcileCharacterIntegrity(Player, false)
    end
    return Success
end

function RuntimeSupport.CharacterPathBlocked(PlayerState: any, Root: any, Origin: Vector3, Delta: Vector3): boolean
    if Delta.Magnitude <= 4 then
        return false
    end

    local Success, Blocked = pcall(function()
        local Workspace = game:GetService("Workspace")
        local Params = PlayerState.RaycastParams
        if Params == nil or PlayerState.RaycastCharacter ~= PlayerState.Character then
            Params = RaycastParams.new()
            Params.FilterType = Enum.RaycastFilterType.Exclude
            Params.FilterDescendantsInstances = { PlayerState.Character }
            Params.IgnoreWater = true
            Params.RespectCanCollide = true
            PlayerState.RaycastParams = Params
            PlayerState.RaycastCharacter = PlayerState.Character
        end
        Params.CollisionGroup = Root.CollisionGroup
        local Hit = Workspace:Raycast(Origin, Delta, Params)
        return Hit ~= nil and Hit.Instance ~= nil and Hit.Instance:IsA("BasePart") and Hit.Instance.CanCollide
    end)
    return Success and Blocked == true
end

function RuntimeSupport.CorrectCharacter(PlayerState: any, Character: any, Root: any, Now: number): boolean
    if PlayerState.LastSafeCFrame == nil or PlayerState.Character ~= Character then
        return false
    end
    local Corrected = pcall(function()
        Character:PivotTo(PlayerState.LastSafeCFrame)
        Root.AssemblyLinearVelocity = Vector3.zero
        Root.AssemblyAngularVelocity = Vector3.zero
    end)
    if Corrected then
        PlayerState.LastCorrectionAt = Now + math.max(0, RuntimeConfig.CharacterIntegrityCorrectionCooldownSeconds)
        PlayerState.GraceUntil = Now + math.max(0, RuntimeConfig.CharacterIntegrityTeleportGraceSeconds)
        PlayerState.LastPosition = PlayerState.LastSafeCFrame.Position
        PlayerState.LastSampleAt = Now
        MetricAdd("CharacterIntegrityActions", "corrected")
    end
    return Corrected
end

function RuntimeSupport.StepCharacterIntegrityPlayer(Player: any, Now: number)
    local PlayerState = RuntimeSupport.GetCharacterIntegrityPlayer(Player)
    if Now < PlayerState.NextSampleAt then
        return
    end
    RuntimeSupport.DecayCharacterIntegrityPlayer(PlayerState, Now)
    PlayerState.NextSampleAt = Now + math.max(0.05, RuntimeConfig.CharacterIntegritySampleIntervalSeconds)

    local Character, Root, Humanoid, RootCFrame = RuntimeSupport.ReadCharacterSnapshot(Player)
    if Character == nil or Root == nil or Humanoid == nil then
        PlayerState.Character = nil
        PlayerState.LastPosition = nil
        PlayerState.LastSampleAt = 0
        return
    end

    if not RuntimeSupport.FiniteComponents(RootCFrame:GetComponents()) then
        PlayerState.ConsecutiveBreaches += 1
        local _, Action = RuntimeSupport.ReportCharacterIntegrity(Player, "NonFiniteMovement", 12, "root transform")
        if Action == "correct" then
            RuntimeSupport.CorrectCharacter(PlayerState, Character, Root, Now)
        end
        return
    end

    if PlayerState.Character ~= Character or PlayerState.LastPosition == nil or PlayerState.LastSampleAt <= 0 then
        PlayerState.Character = Character
        PlayerState.LastPosition = Root.Position
        PlayerState.LastSafeCFrame = RootCFrame
        PlayerState.LastSampleAt = Now
        PlayerState.GraceUntil = math.max(
            PlayerState.GraceUntil,
            Now + math.max(0, RuntimeConfig.CharacterIntegrityJoinGraceSeconds)
        )
        return
    end

    local Position = Root.Position
    local Delta = Position - PlayerState.LastPosition
    local DeltaTime = Now - PlayerState.LastSampleAt
    PlayerState.LastSampleAt = Now

    if Now < PlayerState.GraceUntil then
        PlayerState.LastPosition = Position
        PlayerState.LastSafeCFrame = RootCFrame
        PlayerState.ConsecutiveBreaches = 0
        return
    end

    local Seat = Humanoid.SeatPart
    local Seated = Seat ~= nil and Seat.Occupant == Humanoid
    local Ping = 0
    pcall(function()
        Ping = Player:GetNetworkPing()
    end)
    local HorizontalDelta = Vector3.new(Delta.X, 0, Delta.Z)
    local Velocity = Root.AssemblyLinearVelocity
    local HorizontalVelocity = Vector3.new(Velocity.X, 0, Velocity.Z).Magnitude
    local Evaluation = RuntimeSupport.EvaluateCharacterMovement({
        DeltaTime = DeltaTime,
        HorizontalDistance = HorizontalDelta.Magnitude,
        VerticalDistance = math.abs(Delta.Y),
        WalkSpeed = Humanoid.WalkSpeed,
        HorizontalVelocity = HorizontalVelocity,
        VerticalVelocity = Velocity.Y,
        Ping = Ping,
        Seated = Seated,
        Grounded = Humanoid.FloorMaterial ~= Enum.Material.Air,
        PathBlocked = not Seated and DeltaTime <= RuntimeConfig.CharacterIntegrityMaxStepSeconds
            and HorizontalDelta.Magnitude > math.max(4, RuntimeConfig.CharacterIntegrityDistanceSlack * 0.5)
            and RuntimeSupport.CharacterPathBlocked(PlayerState, Root, PlayerState.LastPosition, Delta),
    }, PlayerState.Limits)

    if Evaluation.Resync then
        PlayerState.LastPosition = Position
        PlayerState.LastSafeCFrame = RootCFrame
        PlayerState.ConsecutiveBreaches = 0
        return
    end

    if not Evaluation.Suspicious then
        PlayerState.LastPosition = Position
        PlayerState.LastSafeCFrame = RootCFrame
        PlayerState.ConsecutiveBreaches = 0
        return
    end

    PlayerState.ConsecutiveBreaches += 1
    local Reason = table.concat(Evaluation.Reasons, "+")
    local _, Action = RuntimeSupport.ReportCharacterIntegrity(
        Player,
        Reason,
        Evaluation.Weight,
        `horizontal:{math.floor(HorizontalDelta.Magnitude * 100) / 100};vertical:{math.floor(Delta.Y * 100) / 100};dt:{math.floor(DeltaTime * 1000) / 1000}`
    )

    if Action ~= "correct" or not RuntimeSupport.CorrectCharacter(PlayerState, Character, Root, Now) then
        PlayerState.LastPosition = Position
    end
end

function RuntimeSupport.StepCharacterIntegrity(PlayersList: {any})
    if not RuntimeConfig.EnableCharacterIntegrity then
        return
    end

    local Now = os.clock()
    for _, Player in PlayersList do
        if not IsPlayerActive(Player) then
            continue
        end
        local Success, Failure = pcall(RuntimeSupport.StepCharacterIntegrityPlayer, Player, Now)
        if not Success then
            EmitTelemetry("security.characterIntegrityError", {
                Player = Player,
                UserId = TryGetUserId(Player),
                Error = tostring(Failure),
                Time = Now,
            })
        end
    end
end

Players.PlayerRemoving:Connect(function(Player)
    PlayersMap[Player] = nil
    ClearPlayerRuntimeState(Player)
end)

function RuntimeSupport.EmitReliable(Target: any, Packet: buffer, Instances: {Instance}?)
    Reliable:FireClient(Target, Packet, Instances)
    TrackSend("Reliable", buffer.len(Packet), Target)
end

local function StepReplication()
    ProfileBegin("Cheeto.Flush.Server")
    --> Invocation timeouts are only meaningful if something sweeps them. Without
    --> this an Invoke whose reply never arrives leaves its thread suspended for
    --> the life of the server -- a lost reply, or a peer that simply never
    --> answers, silently leaks a coroutine and hangs that caller forever.
    ExpireInvocations()
    RuntimeSupport.ExpireFragments()
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
        if Send.BitCount > 0 then
            Load(Send)
            FlushBits()
            Send = Save()
            PlayersMap[Player] = Send
        end
        if Send.Cursor <= 0 then
            continue
        end
        if not RuntimeSupport.ShouldFlush(Player, "Reliable", Send.Cursor, "Gameplay") then
            continue
        end

        if RuntimeConfig.MaxReliablePacketBytes > 0 and Send.Cursor > RuntimeConfig.MaxReliablePacketBytes then
            DropPacket(Player, "Reliable", "MaxPacketBytes", Send.Cursor)
            RuntimeSupport.RecordFlush(Player, "Reliable", 0)
        elseif IsPlayerActive(Player) then
            RuntimeSupport.SendReliablePacket(Player, Send.Buffer, Send.Cursor, InstancePayload(Send.Instances))
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
