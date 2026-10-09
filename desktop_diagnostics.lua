-- ARGUS desktop diagnostics utilities.
-- Provides read-only target telemetry, frame-time sampling, and protected external-call
-- instrumentation. It does not steer the camera, select an aim part, or move the cursor.

local Diagnostics = {}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

Diagnostics.Config = {
    RangeStuds = 1000,
    MaxTargets = 3,
    RefreshInterval = 0.25,
    HistoryWindowSeconds = 10,
}

local stats = {
    Frames = 0,
    FPS = 0,
    FrameTimeMs = 0,
    LastSampleAt = os.clock(),
    LastFrameAt = nil,
    ApiCalls = 0,
    ApiErrors = 0,
    LastApiName = "None",
    LastApiError = "",
    LastApiDurationMs = 0,
}

local function getRoot(character)
    if not character then return nil end
    return character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChild("UpperTorso")
        or character:FindFirstChild("Torso")
end

local function isOpponent(localPlayer, otherPlayer)
    if not localPlayer or not otherPlayer or localPlayer == otherPlayer then return false end
    if localPlayer.Team ~= nil and otherPlayer.Team ~= nil and localPlayer.Team == otherPlayer.Team then
        return false
    end
    local character = otherPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0 and getRoot(character) ~= nil
end

function Diagnostics.GetTargetSnapshot(localPlayer, rangeStuds, maxTargets)
    local snapshot = {
        Count = 0,
        Targets = {},
        RangeStuds = math.max(0, tonumber(rangeStuds) or Diagnostics.Config.RangeStuds),
    }
    if not localPlayer then return snapshot end

    local localRoot = getRoot(localPlayer.Character)
    if not localRoot then return snapshot end

    maxTargets = math.clamp(math.floor(tonumber(maxTargets) or Diagnostics.Config.MaxTargets), 1, 3)
    for _, player in ipairs(Players:GetPlayers()) do
        if isOpponent(localPlayer, player) then
            local root = getRoot(player.Character)
            local distance = (root.Position - localRoot.Position).Magnitude
            if distance <= snapshot.RangeStuds then
                snapshot.Targets[#snapshot.Targets + 1] = {
                    Player = player,
                    Name = player.DisplayName ~= "" and player.DisplayName or player.Name,
                    Distance = distance,
                    Visible = Diagnostics.IsVisible(localPlayer, player.Character),
                }
            end
        end
    end

    table.sort(snapshot.Targets, function(a, b) return a.Distance < b.Distance end)
    while #snapshot.Targets > maxTargets do table.remove(snapshot.Targets) end
    snapshot.Count = #snapshot.Targets
    return snapshot
end

function Diagnostics.IsVisible(localPlayer, character, camera)
    if not localPlayer or not character then return false end
    camera = camera or Workspace.CurrentCamera
    if not camera then return false end
    local part = character:FindFirstChild("UpperTorso")
        or character:FindFirstChild("Torso")
        or character:FindFirstChild("HumanoidRootPart")
    if not part then return false end

    local origin = camera.CFrame.Position
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {localPlayer.Character, camera}
    params.IgnoreWater = true
    local hit = Workspace:Raycast(origin, part.Position - origin, params)
    return hit ~= nil and hit.Instance ~= nil and hit.Instance:IsDescendantOf(character)
end

function Diagnostics.GetInputSnapshot()
    local mouseAvailable = UserInputService.MouseEnabled
    local keyboardAvailable = UserInputService.KeyboardEnabled
    local rightHeld = false
    if mouseAvailable then
        local ok, result = pcall(function()
            return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
        end)
        rightHeld = ok and result == true
    end
    return {
        DesktopAvailable = mouseAvailable and keyboardAvailable,
        RightMouseHeld = rightHeld,
        AimFeatureEnabled = _G.TargetAssistEnabled == true,
        -- This describes the configured input gate, not whether aim is currently moving.
        ActivationGateSatisfied = rightHeld and _G.TargetAssistEnabled == true,
    }
end

function Diagnostics.RecordExternalCall(name, callback, ...)
    assert(type(callback) == "function", "callback must be a function")
    local args = table.pack(...)
    local startedAt = os.clock()
    local result = table.pack(pcall(function()
        return callback(table.unpack(args, 1, args.n))
    end))

    stats.ApiCalls += 1
    stats.LastApiName = tostring(name or "Unnamed API")
    stats.LastApiDurationMs = (os.clock() - startedAt) * 1000
    if not result[1] then
        stats.ApiErrors += 1
        stats.LastApiError = tostring(result[2]):sub(1, 300)
        warn("[ARGUS API] " .. stats.LastApiName .. " failed: " .. stats.LastApiError)
        return false, result[2], stats.LastApiDurationMs
    end
    stats.LastApiError = ""
    return true, table.unpack(result, 2, result.n)
end

function Diagnostics.GetPerformanceSnapshot()
    local now = os.clock()
    local elapsed = now - stats.LastSampleAt
    if elapsed >= 1 then
        stats.FPS = stats.Frames / elapsed
        stats.FrameTimeMs = stats.FPS > 0 and (1000 / stats.FPS) or 0
        stats.Frames = 0
        stats.LastSampleAt = now
    end
    local errorRate = stats.ApiCalls > 0 and (stats.ApiErrors / stats.ApiCalls) * 100 or 0
    return {
        FPS = stats.FPS,
        FrameTimeMs = stats.FrameTimeMs,
        ApiCalls = stats.ApiCalls,
        ApiErrors = stats.ApiErrors,
        ApiErrorRate = errorRate,
        LastApiName = stats.LastApiName,
        LastApiError = stats.LastApiError,
        LastApiDurationMs = stats.LastApiDurationMs,
    }
end

-- Call once per script execution to enable low-overhead FPS sampling.
function Diagnostics.StartPerformanceSampling()
    if Diagnostics._frameConnection then
        Diagnostics._frameConnection:Disconnect()
    end
    stats.Frames = 0
    stats.LastSampleAt = os.clock()
    Diagnostics._frameConnection = RunService.RenderStepped:Connect(function()
        stats.Frames += 1
    end)
    return Diagnostics._frameConnection
end

function Diagnostics.StopPerformanceSampling()
    if Diagnostics._frameConnection then
        Diagnostics._frameConnection:Disconnect()
        Diagnostics._frameConnection = nil
    end
end

-- Builds a compact card under an existing UI container. The caller owns the parent
-- and can place the card in its existing Debug tab without creating a duplicate window.
function Diagnostics.CreatePanel(parent, localPlayer)
    assert(parent and parent:IsA("GuiObject"), "parent must be a GuiObject")
    local card = Instance.new("Frame")
    card.Name = "ArgusDiagnosticsCard"
    card.Size = UDim2.new(1, -8, 0, 206)
    card.BackgroundColor3 = Color3.fromRGB(22, 27, 25)
    card.BorderSizePixel = 0
    card.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = card

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(100, 205, 135)
    stroke.Transparency = 0.45
    stroke.Thickness = 1
    stroke.Parent = card

    local label = Instance.new("TextLabel")
    label.Name = "Telemetry"
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(12, 8)
    label.Size = UDim2.new(1, -24, 1, -16)
    label.Font = Enum.Font.Code
    label.TextSize = 12
    label.TextColor3 = Color3.fromRGB(225, 235, 229)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Top
    label.TextWrapped = true
    label.Parent = card

    local running = true
    local elapsed = 0
    local connection = RunService.Heartbeat:Connect(function(dt)
        elapsed += dt
        if not running or elapsed < Diagnostics.Config.RefreshInterval then return end
        elapsed = 0
        if not card.Parent then
            running = false
            connection:Disconnect()
            return
        end

        local targets = Diagnostics.GetTargetSnapshot(localPlayer)
        local input = Diagnostics.GetInputSnapshot()
        local perf = Diagnostics.GetPerformanceSnapshot()
        local lines = {
            "ARGUS DIAGNOSTICS",
            string.format("Nearby opponents: %d / %d (%.0f studs)", targets.Count, Diagnostics.Config.MaxTargets, targets.RangeStuds),
            string.format("Desktop input: %s | RMB: %s", input.DesktopAvailable and "READY" or "UNAVAILABLE", input.RightMouseHeld and "HELD" or "UP"),
            string.format("Aim enabled: %s | Activation gate: %s", tostring(input.AimFeatureEnabled), tostring(input.ActivationGateSatisfied)),
            string.format("FPS: %.0f | Frame: %.1f ms", perf.FPS, perf.FrameTimeMs),
            string.format("External calls: %d | errors: %d (%.1f%%)", perf.ApiCalls, perf.ApiErrors, perf.ApiErrorRate),
            string.format("Last API: %s (%.1f ms)", perf.LastApiName, perf.LastApiDurationMs),
        }
        for i, target in ipairs(targets.Targets) do
            lines[#lines + 1] = string.format("%d. %s — %.0f studs — %s", i, target.Name, target.Distance, target.Visible and "VISIBLE" or "BLOCKED")
        end
        if perf.LastApiError ~= "" then
            lines[#lines + 1] = "Last API error: " .. perf.LastApiError
        end
        label.Text = table.concat(lines, "\n")
    end)

    card.Destroying:Connect(function()
        running = false
        if connection then connection:Disconnect() end
    end)

    return card
end

return Diagnostics
