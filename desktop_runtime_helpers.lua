-- Desktop runtime helpers for the Argus offline/demo environment.
-- This module provides input state, opponent census, visibility metadata, and UI bounds.
-- It intentionally does not move the camera or implement automatic target locking.

local DesktopRuntime = {}

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

DesktopRuntime.Config = {
    MaxDistance = 1000,
    MaxTrackedOpponents = 3,
    VisibilityDwellSeconds = 2,
}

function DesktopRuntime.IsDesktop()
    return UserInputService.MouseEnabled and UserInputService.KeyboardEnabled
end

function DesktopRuntime.IsRightMouseHeld()
    return UserInputService.MouseEnabled
        and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
end

local function getRoot(character)
    if not character then return nil end
    return character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChild("UpperTorso")
        or character:FindFirstChild("Torso")
end

function DesktopRuntime.IsOpponent(localPlayer, otherPlayer)
    if not localPlayer or not otherPlayer or localPlayer == otherPlayer then
        return false
    end

    -- Team is authoritative when assigned. If either side has no Team, keep the
    -- player as a candidate instead of silently excluding everyone in FFA games.
    if localPlayer.Team ~= nil and otherPlayer.Team ~= nil
        and localPlayer.Team == otherPlayer.Team then
        return false
    end

    local character = otherPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0 and getRoot(character) ~= nil
end

function DesktopRuntime.GetNearbyOpponents(localPlayer, maxDistance, maxCount)
    local results = {}
    if not localPlayer then return results end

    local localRoot = getRoot(localPlayer.Character)
    if not localRoot then return results end

    maxDistance = math.max(0, tonumber(maxDistance) or DesktopRuntime.Config.MaxDistance)
    maxCount = math.clamp(
        math.floor(tonumber(maxCount) or DesktopRuntime.Config.MaxTrackedOpponents),
        1,
        3
    )

    for _, player in ipairs(Players:GetPlayers()) do
        if DesktopRuntime.IsOpponent(localPlayer, player) then
            local root = getRoot(player.Character)
            local distance = (root.Position - localRoot.Position).Magnitude
            if distance <= maxDistance then
                results[#results + 1] = {
                    Player = player,
                    Character = player.Character,
                    Root = root,
                    Distance = distance,
                }
            end
        end
    end

    table.sort(results, function(a, b)
        return a.Distance < b.Distance
    end)

    while #results > maxCount do
        table.remove(results)
    end

    return results
end

function DesktopRuntime.IsCharacterVisible(localPlayer, targetCharacter, camera)
    if not localPlayer or not targetCharacter then return false end
    camera = camera or Workspace.CurrentCamera
    if not camera then return false end

    local targetPart = targetCharacter:FindFirstChild("UpperTorso")
        or targetCharacter:FindFirstChild("Torso")
        or targetCharacter:FindFirstChild("HumanoidRootPart")
    if not targetPart then return false end

    local origin = camera.CFrame.Position
    local direction = targetPart.Position - origin
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { localPlayer.Character, camera }
    params.IgnoreWater = true

    local hit = Workspace:Raycast(origin, direction, params)
    return hit ~= nil and hit.Instance ~= nil
        and hit.Instance:IsDescendantOf(targetCharacter)
end

-- Returns whether a target has remained visible for the configured dwell time.
-- Call from a regular update loop with the same target key and current timestamp.
-- This is informational state only; it never steers the camera or changes aim.
function DesktopRuntime.UpdateVisibilityDwell(state, targetKey, isVisible, now, dwellSeconds)
    state = state or {}
    now = tonumber(now) or os.clock()
    dwellSeconds = math.max(0, tonumber(dwellSeconds)
        or DesktopRuntime.Config.VisibilityDwellSeconds)

    if not isVisible or targetKey == nil then
        state.TargetKey = nil
        state.VisibleSince = nil
        return state, false
    end

    if state.TargetKey ~= targetKey then
        state.TargetKey = targetKey
        state.VisibleSince = now
        return state, dwellSeconds == 0
    end

    state.VisibleSince = state.VisibleSince or now
    return state, (now - state.VisibleSince) >= dwellSeconds
end

function DesktopRuntime.ClampPanelPosition(x, y, panelWidth, panelHeight, viewportWidth, viewportHeight, margin)
    margin = math.max(0, tonumber(margin) or 8)
    panelWidth = math.max(0, tonumber(panelWidth) or 0)
    panelHeight = math.max(0, tonumber(panelHeight) or 0)
    viewportWidth = math.max(0, tonumber(viewportWidth) or 1280)
    viewportHeight = math.max(0, tonumber(viewportHeight) or 720)

    local maxX = math.max(margin, viewportWidth - panelWidth - margin)
    local maxY = math.max(margin, viewportHeight - panelHeight - margin)
    return math.clamp(tonumber(x) or margin, margin, maxX),
        math.clamp(tonumber(y) or margin, margin, maxY)
end

return DesktopRuntime
