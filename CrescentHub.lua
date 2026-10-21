-- ARGUS
-- Release baseline: the project owner requested versioning to start at v0.0.01.
_G.ArgusVersion = "v0.0.01"
_G.__ARGUS_INIT_STATUS = "initializing"
_G.ESPEnabled   = true
_G.BoxESP       = true
_G.BoxFilled    = true
_G.HighlightESP = true
_G.HealthESP    = true
_G.NameESP      = true
_G.ToolESP      = true
_G.TracerESP    = true
_G.SkeletonESP  = true
_G.TeamCheck    = true
_G.TeamColorESP = true
-- ESP render range is measured in Roblox studs (not real-world meters).
_G.ESPMaxDistance = tonumber(_G.ESPMaxDistance) or 1000
_G.ESPShowTeammates = false

local RunService = game:GetService("RunService")
-- Client-only guard: ESP / Aim / Head Lock / UI / health monitor all run locally.
if not RunService:IsClient() then
    return
end

-- Desktop-only runtime gate: require both keyboard and mouse before initializing any modules.
local DesktopInput = game:GetService("UserInputService")
if not DesktopInput.KeyboardEnabled or not DesktopInput.MouseEnabled then
    _G.__ARGUS_INIT_STATUS = "unsupported_device"
    return
end

local Players = game:GetService("Players")
local Camera = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    return
end

-- Remove only stale Nexus Control Center overlays from previous script runs.
-- This prevents an older ScreenGui from remaining visible after the script is updated.
local function argusRemoveLegacyNexusControlCenter()
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui")
    for _, descendant in ipairs(playerGui:GetDescendants()) do
        if descendant:IsA("ScreenGui") then
            local normalizedName = string.lower(descendant.Name):gsub("[%s%p_]", "")
            local isNexusControlCenter = normalizedName:find("nexus", 1, true)
                and normalizedName:find("control", 1, true)
                and normalizedName:find("center", 1, true)
            if not isNexusControlCenter then
                for _, child in ipairs(descendant:GetDescendants()) do
                    if child:IsA("TextLabel") or child:IsA("TextButton") then
                        local label = string.upper(tostring(child.Text or "")):gsub("%s+", " ")
                        if label:find("NEXUS", 1, true)
                            and label:find("CONTROL", 1, true)
                            and label:find("CENTER", 1, true) then
                            isNexusControlCenter = true
                            break
                        end
                    end
                end
            end
            if isNexusControlCenter then
                descendant:Destroy()
            end
        end
    end
end
argusRemoveLegacyNexusControlCenter()

local ESPObjects = {}


-- ============================================================
-- ARGUS Native Roblox Drawing Backend
-- 用 Roblox 原生 GUI 取代一般環境不存在的 executor Drawing API。
-- ============================================================
local function argusCreateNativeDrawingBackend()
    local playerGui = LocalPlayer:WaitForChild("PlayerGui")
    local oldGui = playerGui:FindFirstChild("ARGUS_DrawingOverlay")
    if oldGui then
        oldGui:Destroy()
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "ARGUS_DrawingOverlay"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 999998
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
    gui.Parent = playerGui

    local function clampTransparency(value)
        return math.clamp(tonumber(value) or 1, 0, 1)
    end

    local function applyCommon(instance, props, kind)
        local visible = props.Visible == true
        instance.Visible = visible

        local color = props.Color or Color3.new(1,1,1)
        local transparency = clampTransparency(props.Transparency)

        if kind == "Text" then
            instance.TextColor3 = color
            -- Keep text outline opt-in; disable stroke by default for a clean sans-serif UI.
            instance.TextStrokeTransparency = props.Outline == true and (1 - transparency) or 1
            instance.TextStrokeColor3 = props.OutlineColor or Color3.new(0,0,0)
            instance.TextTransparency = 1 - transparency
            instance.TextSize = math.max(1, tonumber(props.Size) or 14)
            instance.Font = Enum.Font.Gotham
            instance.Text = tostring(props.Text or "")
            instance.TextWrapped = false
        else
            instance.BackgroundColor3 = color
            instance.BackgroundTransparency = props.Filled == false and 1 or (1 - transparency)
        end
    end

    local function update(obj)
        local p = obj._props
        local instance = obj._instance
        if not instance or not instance.Parent then return end

        applyCommon(instance, p, obj._kind)

        if obj._kind == "Square" then
            local pos = p.Position or Vector2.zero
            local size = p.Size or Vector2.zero
            instance.AnchorPoint = Vector2.new(0,0)
            instance.Position = UDim2.fromOffset(pos.X, pos.Y)
            instance.Size = UDim2.fromOffset(math.max(0,size.X), math.max(0,size.Y))

            local stroke = obj._stroke
            if stroke then
                stroke.Enabled = p.Filled ~= true and p.Visible == true
                stroke.Thickness = math.max(1, tonumber(p.Thickness) or 1)
                stroke.Color = p.Color or Color3.new(1,1,1)
                stroke.Transparency = 1 - clampTransparency(p.Transparency)
            end
        elseif obj._kind == "Circle" then
            local center = p.Position or p.Center or Vector2.zero
            local radius = math.max(0, tonumber(p.Radius) or 0)
            instance.AnchorPoint = Vector2.new(0.5,0.5)
            instance.Position = UDim2.fromOffset(center.X, center.Y)
            instance.Size = UDim2.fromOffset(radius * 2, radius * 2)

            local stroke = obj._stroke
            if stroke then
                stroke.Enabled = p.Visible == true
                stroke.Thickness = math.max(1, tonumber(p.Thickness) or 1)
                stroke.Color = p.Color or Color3.new(1,1,1)
                stroke.Transparency = 1 - clampTransparency(p.Transparency)
            end
        elseif obj._kind == "Line" then
            local from = p.From or Vector2.zero
            local to = p.To or from
            local delta = to - from
            local length = delta.Magnitude
            instance.AnchorPoint = Vector2.new(0.5,0.5)
            instance.Position = UDim2.fromOffset((from.X + to.X) * 0.5, (from.Y + to.Y) * 0.5)
            instance.Size = UDim2.fromOffset(math.max(1, length), math.max(1, tonumber(p.Thickness) or 1))
            instance.Rotation = math.deg(math.atan2(delta.Y, delta.X))
            instance.BackgroundTransparency = 1 - clampTransparency(p.Transparency)
        elseif obj._kind == "Text" then
            local pos = p.Position or Vector2.zero
            instance.AnchorPoint = p.Center and Vector2.new(0.5,0.5) or Vector2.new(0,0)
            instance.Position = UDim2.fromOffset(pos.X, pos.Y)
            instance.Size = UDim2.fromOffset(800, math.max(18, (tonumber(p.Size) or 14) + 8))
        end
    end

    local function newDrawing(kind)
        local instance
        local stroke

        if kind == "Text" then
            instance = Instance.new("TextLabel")
            instance.BackgroundTransparency = 1
            instance.AutomaticSize = Enum.AutomaticSize.X
            instance.Size = UDim2.fromOffset(800, 24)
        else
            instance = Instance.new("Frame")
            instance.BorderSizePixel = 0
            instance.Active = false
            if kind == "Circle" then
                local corner = Instance.new("UICorner")
                corner.CornerRadius = UDim.new(1,0)
                corner.Parent = instance
            end
            stroke = Instance.new("UIStroke")
            stroke.Parent = instance
        end

        instance.Name = "ARGUS_DrawingObject"
        instance.ZIndex = 1
        instance.Parent = gui

        local obj = {
            _kind = kind,
            _instance = instance,
            _stroke = stroke,
            _props = {
                Visible = false,
                Color = Color3.new(1,1,1),
                Transparency = 1,
                Thickness = 1,
                Filled = false,
                Position = Vector2.zero,
                Size = Vector2.zero,
                From = Vector2.zero,
                To = Vector2.zero,
                Radius = 0,
                Center = false,
                Outline = false,
                OutlineColor = Color3.new(0,0,0),
                Text = "",
                Font = 2,
            },
        }

        local proxy = setmetatable(obj, {
            __index = function(self, key)
                if key == "Remove" or key == "Destroy" then
                    return function()
                        if self._instance then
                            self._instance:Destroy()
                            self._instance = nil
                        end
                    end
                end
                return self._props[key]
            end,
            __newindex = function(self, key, value)
                -- Skip redundant property writes: the UI/ESP loops assign many
                -- unchanged values every frame, especially in the native backend.
                if self._props[key] == value then
                    return
                end
                self._props[key] = value
                update(self)
            end,
        })

        update(proxy)
        return proxy
    end

    return {
        new = function(kind)
            if kind ~= "Square" and kind ~= "Line" and kind ~= "Text" and kind ~= "Circle" then
                error("ARGUS native Drawing backend 不支援類型: "..tostring(kind))
            end
            return newDrawing(kind)
        end,
        _Gui = gui,
    }
end

local useNativeDrawing =
    type(Drawing) ~= "table"
    or type(Drawing.new) ~= "function"

if useNativeDrawing then
    local backend = argusCreateNativeDrawingBackend()
    Drawing = backend
    _G.ArgusDrawingBackend = "RobloxScreenGui"
else
    _G.ArgusDrawingBackend = "ExecutorDrawing"
end


local BonesR15 = {
    {"Head","UpperTorso"},{"UpperTorso","LowerTorso"},
    {"UpperTorso","LeftUpperArm"},{"LeftUpperArm","LeftLowerArm"},{"LeftLowerArm","LeftHand"},
    {"UpperTorso","RightUpperArm"},{"RightUpperArm","RightLowerArm"},{"RightLowerArm","RightHand"},
    {"LowerTorso","LeftUpperLeg"},{"LeftUpperLeg","LeftLowerLeg"},{"LeftLowerLeg","LeftFoot"},
    {"LowerTorso","RightUpperLeg"},{"RightUpperLeg","RightLowerLeg"},{"RightLowerLeg","RightFoot"},
}
local BonesR6 = {
    {"Head","Torso"},{"Torso","Left Arm"},{"Torso","Right Arm"},
    {"Torso","Left Leg"},{"Torso","Right Leg"},
}

local function isSameTeam(player)
    if not player or player == LocalPlayer then return player == LocalPlayer end

    -- Players with the same non-nil Team are teammates.
    if LocalPlayer.Team and player.Team then
        return LocalPlayer.Team == player.Team
    end

    -- Neutral players are not automatically teammates (common in FFA/test places).
    -- Their default TeamColor can match even when they should still be visible to ESP.
    if LocalPlayer.Neutral or player.Neutral then
        return false
    end

    -- Only use TeamColor as a fallback for non-neutral players without Team instances.
    if LocalPlayer.TeamColor and player.TeamColor then
        return LocalPlayer.TeamColor == player.TeamColor
    end
    return false
end

local function getPlayerColor(player)
    if _G.TeamColorESP and player.Team and player.Team.TeamColor then
        return player.Team.TeamColor.Color
    end
    return Color3.fromRGB(255,255,255)
end

-- Drawing 工具
local function newSquare()
    local sq = Drawing.new("Square")
    sq.Thickness = 1
    sq.Filled = false
    sq.Color = Color3.fromRGB(255,255,255)
    sq.Visible = false
    return sq
end
local function newLine()
    local ln = Drawing.new("Line")
    ln.Thickness = 2
    ln.Visible = false
    -- Skeleton lines must stay plain green without a dark outline.
    pcall(function() ln.Outline = false end)
    pcall(function() ln.OutlineColor = Color3.fromRGB(0, 255, 0) end)
    return ln
end
local function newText()
    local txt = Drawing.new("Text")
    txt.Size = 14
    txt.Color = Color3.fromRGB(255,255,255)
    txt.Center = true
    txt.Outline = true
    txt.Visible = false
    return txt
end

local function createSkeleton(esp, isR6)
    local bones = isR6 and BonesR6 or BonesR15
    for i = 1,#bones do
        local line = newLine()
        -- Skeleton style only: thin, plain green Drawing lines without an outline.
        line.Thickness = 1
        line.Color = Color3.fromRGB(0, 255, 0)
        pcall(function() line.Outline = false end)
        esp.Skeleton[i] = line
    end
end

local function createESP(player)
    if ESPObjects[player] then return end
    local char = player.Character
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    local isR6 = humanoid and humanoid.RigType == Enum.HumanoidRigType.R6
    local esp = {
        Box = newSquare(),
        BoxFill = newSquare(),
        HealthOutline = newLine(),
        HealthBar = newLine(),
        NameTag = newText(),
        ToolText = newText(),
        Tracer = newLine(),
        Skeleton = {},
        Highlight = nil,
        IsR6 = isR6,
    }
    createSkeleton(esp, isR6)
    ESPObjects[player] = esp
end

local function clearESP(player)
    local esp = ESPObjects[player]
    if not esp then return end

    -- Box、BoxFill、Health、Name、Tool、Tracer
    local singles = {"Box","BoxFill","HealthOutline","HealthBar","NameTag","ToolText","Tracer","Highlight"}
    for _, name in pairs(singles) do
        local obj = esp[name]
        if obj then
            if typeof(obj) == "Instance" then
                obj:Destroy()
            elseif obj.Visible ~= nil then
                obj.Visible = false
            end
            esp[name] = nil
        end
    end

    -- Skeleton 特殊處理
    if esp.Skeleton then
        for _, line in pairs(esp.Skeleton) do
            if line and line.Visible ~= nil then
                line.Visible = false
            end
        end
        esp.Skeleton = nil
    end

    ESPObjects[player] = nil
end


local function updateHighlight(player, char)
    local esp = ESPObjects[player]
    if not esp then return end

    if not _G.HighlightESP or isSameTeam(player) then
        if esp.Highlight then
            esp.Highlight:Destroy()
            esp.Highlight = nil
        end
        return
    end

    if not esp.Highlight or not esp.Highlight.Parent then
        if esp.Highlight then esp.Highlight:Destroy() end

        local h = Instance.new("Highlight")
        h.Name = "ESPHighlight"
        h.FillTransparency = 0.5
        h.OutlineTransparency = 1
        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop

        if char and char.Parent then
            h.Parent = char
        end

        esp.Highlight = h
    end

    -- ✅ 每次都更新顏色
    if esp.Highlight then
        esp.Highlight.FillColor = getPlayerColor(player)
    end
end


-- 監聽玩家死亡
local function onCharacterAdded(player, char)
    local humanoid = char:WaitForChild("Humanoid",5)
    if humanoid then
        humanoid.Died:Connect(function()
            clearESP(player)
        end)
    end
    createESP(player)
    updateHighlight(player, char)
end

-- 玩家加入
Players.PlayerAdded:Connect(function(p)
    p.CharacterAdded:Connect(function(c)
        onCharacterAdded(p, c)
    end)
end)

for _, p in ipairs(Players:GetPlayers()) do
    p.CharacterAdded:Connect(function(c)
        onCharacterAdded(p, c)
    end)
end

-- 玩家退出
Players.PlayerRemoving:Connect(function(player)
    clearESP(player)
end)


-- Argus performance gate for the original ESP renderer.
-- Forward declaration: the adaptive-rate implementation is defined later.
local finalAdaptiveRate
local ArgusESPNextUpdate = 0
local function argusShouldUpdateESP()
    if not _G.ArgusESPPerformance then
        return true
    end

    local rate = math.max(10, tonumber(_G.ArgusESPUpdateRate) or 60)
    if type(finalAdaptiveRate) == "function" then
        rate = math.min(rate, math.max(10, tonumber(finalAdaptiveRate()) or rate))
    end
    local now = os.clock()
    if now < ArgusESPNextUpdate then
        return false
    end
    ArgusESPNextUpdate = now + (1 / rate)
    return true
end

-- RenderStepped
RunService.RenderStepped:Connect(function()
    -- Stream mode suppresses ESP overlays without changing targeting/gameplay state.
    if _G.ArgusStreamMode then
        for _, esp in pairs(ESPObjects) do
            for _, key in ipairs({"Box","BoxFill","HealthBar","HealthOutline","NameTag","ToolText","Tracer"}) do
                local obj = esp[key]
                if obj and obj.Visible then obj.Visible = false end
            end
            for _, line in pairs(esp.Skeleton or {}) do
                if line and line.Visible then line.Visible = false end
            end
            if esp.Highlight then esp.Highlight.Enabled = false end
        end
        return
    end
    -- CurrentCamera can be replaced during respawn/camera scripts; refresh it on the client.
    Camera = workspace.CurrentCamera
    if not Camera or not argusShouldUpdateESP() then
        return
    end
    for _, player in ipairs(Players:GetPlayers()) do
        
        if player ~= LocalPlayer and not _G.ESPShowTeammates and isSameTeam(player) then
    local esp = ESPObjects[player]
    if esp then
        -- 隱藏所有 ESP
        esp.Box.Visible = false
        esp.BoxFill.Visible = false
        esp.HealthBar.Visible = false
        esp.HealthOutline.Visible = false
        esp.NameTag.Visible = false
        esp.ToolText.Visible = false
        esp.Tracer.Visible = false
        for _, l in pairs(esp.Skeleton) do
            l.Visible = false
        end
        if esp.Highlight then
            esp.Highlight:Destroy()
            esp.Highlight = nil
        end
    end
    continue
end

        if player == LocalPlayer then
            if ESPObjects[player] then clearESP(player) end
            continue
        end

        local char = player.Character
        local humanoid = char and char:FindFirstChildOfClass("Humanoid")
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local head = char and char:FindFirstChild("Head")

        -- Custom/non-standard character models: use Highlight directly instead of trying
        -- to draw R6/R15 skeleton bones. These models may have no Humanoid, Head, or
        -- HumanoidRootPart, but still contain BaseParts that Highlight can render.
        local hasStandardRig = char and humanoid and root and head
        if _G.ESPEnabled and player ~= LocalPlayer and char and char.Parent and not hasStandardRig then
            local anyPart = char:FindFirstChildWhichIsA("BasePart", true)
            if anyPart then
                createESP(player)
                local customEsp = ESPObjects[player]
                if _G.HighlightESP and customEsp and not isSameTeam(player) then
                    if not customEsp.Highlight or not customEsp.Highlight.Parent then
                        local h = Instance.new("Highlight")
                        h.Name = "ESPHighlight_CustomModel"
                        h.Adornee = char
                        h.FillTransparency = 0.35
                        h.OutlineTransparency = 1
                        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                        h.Parent = char
                        customEsp.Highlight = h
                    end
                    customEsp.Highlight.Adornee = char
                    customEsp.Highlight.FillColor = getPlayerColor(player)
                    customEsp.Highlight.Enabled = true
                elseif customEsp and customEsp.Highlight then
                    customEsp.Highlight:Destroy()
                    customEsp.Highlight = nil
                end
                if customEsp then
                    customEsp.Box.Visible = false
                    customEsp.BoxFill.Visible = false
                    customEsp.HealthBar.Visible = false
                    customEsp.HealthOutline.Visible = false
                    customEsp.NameTag.Visible = false
                    customEsp.ToolText.Visible = false
                    customEsp.Tracer.Visible = false
                    for _, line in pairs(customEsp.Skeleton) do
                        if line then line.Visible = false end
                    end
                end
                continue
            end
        end

        if not (_G.ESPEnabled and player ~= LocalPlayer and char and humanoid and root and head and humanoid.Health > 0) then
    local esp = ESPObjects[player]
    if esp then
        esp.Box.Visible = false
        esp.BoxFill.Visible = false
        esp.HealthBar.Visible = false
        esp.HealthOutline.Visible = false
        esp.NameTag.Visible = false
        esp.ToolText.Visible = false
        esp.Tracer.Visible = false
        -- 清理 Skeleton
        for _, l in pairs(esp.Skeleton) do
            if l then l.Visible = false end
        end
        if esp.Highlight then
            esp.Highlight:Destroy()
            esp.Highlight = nil
        end
    end
    continue
end


        createESP(player)
        updateHighlight(player, char)

        local rootPos, onScreen = Camera:WorldToViewportPoint(root.Position)
        local headPos = Camera:WorldToViewportPoint(head.Position + Vector3.new(0,0.5,0))
        local esp = ESPObjects[player]
        local teamColor = getPlayerColor(player)
        local localCharacter = LocalPlayer.Character
        local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")
        local maxESPDistance = math.max(0, tonumber(_G.ESPMaxDistance) or 1000)
        local distance = localRoot and (localRoot.Position - root.Position).Magnitude or math.huge

        if distance > maxESPDistance then
            esp.Box.Visible = false
            esp.BoxFill.Visible = false
            esp.HealthBar.Visible = false
            esp.HealthOutline.Visible = false
            esp.NameTag.Visible = false
            esp.ToolText.Visible = false
            esp.Tracer.Visible = false
            for _, line in pairs(esp.Skeleton) do line.Visible = false end
            if esp.Highlight then
                esp.Highlight:Destroy()
                esp.Highlight = nil
            end
            continue
        end

        if not onScreen then
            esp.Box.Visible = false
            esp.BoxFill.Visible = false
            esp.HealthBar.Visible = false
            esp.HealthOutline.Visible = false
            esp.NameTag.Visible = false
            esp.ToolText.Visible = false
            esp.Tracer.Visible = false
            for _,l in pairs(esp.Skeleton) do l.Visible = false end
            continue
        end

        local height = math.abs(headPos.Y - rootPos.Y) * 2
        local width = height / 2

        -- Box
        esp.Box.Size = Vector2.new(width, height)
        esp.Box.Position = Vector2.new(rootPos.X - width/2, rootPos.Y - height/2)
        esp.Box.Color = teamColor
        esp.Box.Visible = _G.BoxESP

        -- BoxFill
        esp.BoxFill.Size = esp.Box.Size
        esp.BoxFill.Position = esp.Box.Position
        esp.BoxFill.Color = teamColor
        esp.BoxFill.Filled = true
        esp.BoxFill.Transparency = 0.15
        esp.BoxFill.Visible = _G.BoxFilled and _G.BoxESP

        -- Tracer
        esp.Tracer.From = Vector2.new(Camera.ViewportSize.X/2, Camera.ViewportSize.Y)
        esp.Tracer.To = Vector2.new(rootPos.X, rootPos.Y)
        esp.Tracer.Color = teamColor
        esp.Tracer.Visible = _G.TracerESP and _G.ESPEnabled

        -- Skeleton
        local bones = esp.IsR6 and BonesR6 or BonesR15
        if _G.SkeletonESP then
            for i,b in ipairs(bones) do
                local p1 = char:FindFirstChild(b[1])
                local p2 = char:FindFirstChild(b[2])
                if p1 and p2 then
                    local v1,o1 = Camera:WorldToViewportPoint(p1.Position)
                    local v2,o2 = Camera:WorldToViewportPoint(p2.Position)
                    if o1 and o2 then
                        esp.Skeleton[i].From = Vector2.new(v1.X,v1.Y)
                        esp.Skeleton[i].To   = Vector2.new(v2.X,v2.Y)
                        esp.Skeleton[i].Thickness = 1
                        esp.Skeleton[i].Color = Color3.fromRGB(0, 255, 0)
                        pcall(function() esp.Skeleton[i].Outline = false end)
                        pcall(function() esp.Skeleton[i].OutlineColor = Color3.fromRGB(0, 255, 0) end)
                        esp.Skeleton[i].Visible = true
                    else
                        esp.Skeleton[i].Visible = false
                    end
                else
                    esp.Skeleton[i].Visible = false
                end
            end
        else
            for _,l in pairs(esp.Skeleton) do l.Visible = false end
        end

        -- Health (舊邏輯)
        if _G.HealthESP then
            local hpPercent = humanoid.Health / humanoid.MaxHealth
            esp.HealthOutline.From = Vector2.new(esp.Box.Position.X - 6, esp.Box.Position.Y)
            esp.HealthOutline.To   = Vector2.new(esp.Box.Position.X - 6, esp.Box.Position.Y + height)
            esp.HealthBar.From     = Vector2.new(esp.Box.Position.X - 6, esp.Box.Position.Y + height)
            esp.HealthBar.To       = Vector2.new(esp.Box.Position.X - 6, esp.Box.Position.Y + height - height*hpPercent)
            esp.HealthBar.Color    = Color3.fromRGB(255 - hpPercent*255, hpPercent*255, 0)
            esp.HealthOutline.Visible = true
            esp.HealthBar.Visible = true
        else
            esp.HealthOutline.Visible = false
            esp.HealthBar.Visible = false
        end

        -- Name
        if _G.NameESP then
            local distance = (LocalPlayer.Character.HumanoidRootPart.Position - root.Position).Magnitude
            esp.NameTag.Text = string.format("%s [%.1f]", player.Name, distance)
            esp.NameTag.Position = Vector2.new(rootPos.X, headPos.Y - 15)
            esp.NameTag.Visible = true
            esp.NameTag.Color = teamColor
        else
            esp.NameTag.Visible = false
        end

        -- ToolESP
        if _G.ToolESP then
            local tool = char:FindFirstChildOfClass("Tool")
            esp.ToolText.Text = "Tool: "..(tool and tool.Name or "None")
            esp.ToolText.Position = Vector2.new(rootPos.X, headPos.Y)
            esp.ToolText.Visible = true
            esp.ToolText.Color = teamColor
        else
            esp.ToolText.Visible = false
        end
    end

    -- 右 Shift 隱藏視覺輔助；不停止 Target Assist 本身
    if _G.TargetAssistVisualsHidden then
        for _, esp in pairs(ESPObjects) do
            if esp.Box then esp.Box.Visible = false end
            if esp.BoxFill then esp.BoxFill.Visible = false end
            if esp.HealthBar then esp.HealthBar.Visible = false end
            if esp.HealthOutline then esp.HealthOutline.Visible = false end
            if esp.NameTag then esp.NameTag.Visible = false end
            if esp.ToolText then esp.ToolText.Visible = false end
            if esp.Tracer then esp.Tracer.Visible = false end
            if esp.Skeleton then
                for _, line in pairs(esp.Skeleton) do
                    if line then line.Visible = false end
                end
            end
            if esp.Highlight then
                esp.Highlight:Destroy()
                esp.Highlight = nil
            end
        end
    end
end)

Players.PlayerRemoving:Connect(clearESP)


-- ============================================================
-- 教學用：輔助瞄準 / Target Assist
-- 注意：本區塊獨立於上方 ESP 邏輯，不修改原有 ESP 行為。
-- 可由面板開關控制是否啟用。
-- ============================================================

_G.TargetAssistEnabled = false

-- 自動單目標模式：僅當 1000 studs 內恰好有一名可見、存活且非隊友玩家時自動啟動。
_G.TargetAssistAutoSingleVisible = true
_G.TargetAssistAutoVisibleRange = 1000
_G.TargetAssistAutoCountInterval = 0.035

-- 可選：
-- "Head" / "UpperTorso" / "LowerTorso" / "HumanoidRootPart" / "Auto"
_G.TargetAssistPart = "Head"

-- 數值越大，鏡頭轉向越快；數值越小，轉向越慢。
_G.TargetAssistSmoothness = 8

-- Desktop head-lock strength: 0 = body priority; 100 = head priority.
_G.TargetAssistHeadLockStrength = 100
-- Desktop head-lock qualification settings
_G.TargetAssistHeadLockThreshold = 65
_G.TargetAssistHeadLockGrace = 0.12
_G.TargetAssistHeadLockSwitchMargin = 0.10
_G.TargetAssistHeadLockReacquireDelay = 0.08
_G.TargetAssistHeadLockPreferred = true
_G.TargetAssistHeadLockState = "Body"

-- 最大鎖定距離；0 = 不限制距離。
_G.TargetAssistMaxDistance = 1000

-- 是否排除同隊玩家
_G.TargetAssistTeamCheck = true

-- 是否只選擇目前螢幕內的玩家
_G.TargetAssistRequireOnScreen = true

-- ============================================================
-- 教學用 Target Assist 擴充設定
-- ============================================================

-- FOV 圓圈半徑（像素）
_G.TargetAssistFOVEnabled = true
_G.TargetAssistFOVRadius = 180
-- FOV 狀態色：紅色代表沒有有效目標，綠色代表有符合條件的目標。
_G.TargetAssistFOVColor = Color3.fromRGB(255, 0, 0)
_G.TargetAssistFOVNoTargetColor = Color3.fromRGB(255, 0, 0)
_G.TargetAssistFOVTargetColor = Color3.fromRGB(0, 255, 0)
_G.TargetAssistFOVHasTarget = false
_G.TargetAssistFOVThickness = 1
_G.TargetAssistFOVFilled = false
_G.TargetAssistFOVTransparency = 1

-- 右 Shift：隱藏所有視覺輔助（ESP / FOV / 骨骼 / 畫線等），不影響輔助瞄準
_G.TargetAssistVisualsHidden = false

-- 鎖定方式：
-- "RightMouse" = 按住滑鼠右鍵才鎖定
-- "Toggle" = 按 Toggle 按鍵切換
-- "Both" = 右鍵按住或 Toggle 開啟時鎖定
_G.TargetAssistActivationMode = "RightMouse"
_G.TargetAssistToggleKey = Enum.KeyCode.Q

-- 可見性 Raycast / Wall Check
_G.TargetAssistWallCheck = true

-- Auto 會依序優先選擇 Head，再退回身體部位
_G.TargetAssistAutoHead = true
_G.TargetAssistAutoBodyPart = "UpperTorso"

-- 移動預測 / Aim Prediction
_G.TargetAssistPredictionEnabled = true
_G.TargetAssistPredictionTime = 0.08
_G.TargetAssistMovementPrediction = true

-- 子彈速度預測；<= 0 時不使用 projectile speed
_G.TargetAssistProjectileSpeed = 0

-- XYZ 偏移
_G.TargetAssistOffset = Vector3.new(0, 0, 0)

-- 真人晃動 / 微小瞄準誤差（獨立開關）
_G.TargetAssistHumanizedAim = false
_G.TargetAssistAimError = 0.001
_G.TargetAssistJitterSpeed = 8

-- 二次定位（獨立開關）
-- 第一次先鎖定目標附近，延遲後再進行第二次精定位
_G.TargetAssistSecondaryLock = false
_G.TargetAssistSecondaryPart = "Head"
_G.TargetAssistSecondaryPrimaryPart = "UpperTorso"
_G.TargetAssistSecondaryDelay = 0.10
_G.TargetAssistSecondaryBlendTime = 0.16
_G.TargetAssistSecondarySmoothness = 18

local UserInputService = game:GetService("UserInputService")

local TargetAssist = {
    CurrentTarget = nil,
    ToggleState = false,
    LockStartedAt = 0,
    ReacquireAt = 0,
    LastSwitchAt = 0,
    State = "Idle",
    HeadState = "Body",
    HeadLostAt = 0,
    HeadLockStartedAt = 0,
    HeadReacquireAt = 0,
    LastHeadScore = math.huge,
}

-- Target validation / hysteresis. 這些只控制判定，不改電腦端輸入。
_G.TargetAssistTargetSwitchDelay = tonumber(_G.TargetAssistTargetSwitchDelay) or 0.15
_G.TargetAssistMinimumLockTime = tonumber(_G.TargetAssistMinimumLockTime) or 0.12
_G.TargetAssistTargetSticky = (_G.TargetAssistTargetSticky ~= false)
_G.TargetAssistSwitchScoreRatio = tonumber(_G.TargetAssistSwitchScoreRatio) or 0.78
_G.TargetAssistReacquireDelay = tonumber(_G.TargetAssistReacquireDelay) or 0.12

local humanizedTime = 0

local TargetAssistFOV = Drawing.new("Circle")
TargetAssistFOV.Visible = false
TargetAssistFOV.Radius = _G.TargetAssistFOVRadius
TargetAssistFOV.Color = _G.TargetAssistFOVColor
TargetAssistFOV.Thickness = _G.TargetAssistFOVThickness
TargetAssistFOV.Filled = _G.TargetAssistFOVFilled
TargetAssistFOV.Transparency = _G.TargetAssistFOVTransparency

local function getTargetPart(character)
    if not character then return nil end

    local requested = _G.TargetAssistPart
    if requested ~= "Auto" then
        return character:FindFirstChild(requested)
            or character:FindFirstChild("HumanoidRootPart")
    end

    if _G.TargetAssistAutoHead then
        local head = character:FindFirstChild("Head")
        if head then return head end
    end

    return character:FindFirstChild(_G.TargetAssistAutoBodyPart)
        or character:FindFirstChild("UpperTorso")
        or character:FindFirstChild("Torso")
        or character:FindFirstChild("HumanoidRootPart")
end

local function getPredictedPosition(targetPart)
    local position = targetPart.Position
    local velocity = targetPart.AssemblyLinearVelocity

    if not _G.TargetAssistPredictionEnabled then
        return position + _G.TargetAssistOffset
    end

    local predictionTime = math.max(
        0,
        tonumber(_G.TargetAssistPredictionTime) or 0
    )

    -- 移動預測
    if _G.TargetAssistMovementPrediction then
        position += velocity * predictionTime
    end

    -- 子彈速度預測：使用目前相機到目標的距離 / projectile speed
    local projectileSpeed = tonumber(_G.TargetAssistProjectileSpeed) or 0
    if projectileSpeed > 0 then
        local distance = (Camera.CFrame.Position - targetPart.Position).Magnitude
        local projectileTime = distance / projectileSpeed
        position += velocity * projectileTime
    end

    return position + _G.TargetAssistOffset
end

local function getHumanizedOffset(dt)
    if not _G.TargetAssistHumanizedAim then
        return Vector3.zero
    end

    humanizedTime += math.max(dt, 0) * (tonumber(_G.TargetAssistJitterSpeed) or 8)
    local errorAmount = math.max(0, tonumber(_G.TargetAssistAimError) or 0)

    -- 使用連續的 sin/cos，不會每幀突然跳動
    return Vector3.new(
        math.sin(humanizedTime * 1.37) * errorAmount,
        math.cos(humanizedTime * 0.91) * errorAmount,
        math.sin(humanizedTime * 1.11) * errorAmount * 0.5
    )
end

local function getSecondaryTargetPart(character)
    if not character then return nil end
    return character:FindFirstChild(_G.TargetAssistSecondaryPart)
        or getTargetPart(character)
end

local function getSecondaryPrimaryPart(character)
    if not character then return nil end

    return character:FindFirstChild(_G.TargetAssistSecondaryPrimaryPart)
        or character:FindFirstChild("UpperTorso")
        or character:FindFirstChild("Torso")
        or character:FindFirstChild("HumanoidRootPart")
        or getTargetPart(character)
end

local function hasLineOfSight(targetPart)
    if not _G.TargetAssistWallCheck then
        return true
    end

    local localCharacter = LocalPlayer.Character
    if not localCharacter then return false end

    local origin = Camera.CFrame.Position
    local direction = targetPart.Position - origin

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {localCharacter}
    params.IgnoreWater = true

    local result = workspace:Raycast(origin, direction, params)

    if not result then
        return true
    end

    return result.Instance and result.Instance:IsDescendantOf(targetPart.Parent)
end

local function targetAssistIsValid(player)
    if not player or player == LocalPlayer then
        return false
    end

    if _G.TargetAssistTeamCheck and isSameTeam(player) then
        return false
    end

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local targetPart = getTargetPart(character)

    if not character or not humanoid or humanoid.Health <= 0
        or not root or not targetPart then
        return false
    end

    -- 防止角色重建/異常座標造成錯誤鎖定。
    local targetPosition = targetPart.Position
    if targetPosition.X ~= targetPosition.X
        or targetPosition.Y ~= targetPosition.Y
        or targetPosition.Z ~= targetPosition.Z then
        return false
    end

    local localCharacter = LocalPlayer.Character
    local localRoot = localCharacter
        and localCharacter:FindFirstChild("HumanoidRootPart")

    if not localRoot then
        return false
    end

    if _G.TargetAssistMaxDistance > 0 then
        local distance = (localRoot.Position - root.Position).Magnitude
        if distance > _G.TargetAssistMaxDistance then
            return false
        end
    end

    local viewportPoint, visible =
        Camera:WorldToViewportPoint(targetPart.Position)

    if _G.TargetAssistRequireOnScreen then
        if not visible or viewportPoint.Z <= 0 then
            return false
        end
    end

    if _G.TargetAssistFOVEnabled then
        local viewportSize = Camera.ViewportSize
        local center = Vector2.new(
            viewportSize.X * 0.5,
            viewportSize.Y * 0.5
        )
        local screenPosition = Vector2.new(viewportPoint.X, viewportPoint.Y)

        if (screenPosition - center).Magnitude > _G.TargetAssistFOVRadius then
            return false
        end
    end

    if not hasLineOfSight(targetPart) then
        return false
    end

    return true
end

local function getTargetScore(player, screenCenter, localRoot)
    if not targetAssistIsValid(player) then
        return nil
    end

    local character = player.Character
    local targetPart = getTargetPart(character)
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not targetPart or not humanoid or not root then
        return nil
    end

    local point, visible = Camera:WorldToViewportPoint(targetPart.Position)
    if not visible or point.Z <= 0 then
        return nil
    end

    local screenPosition = Vector2.new(point.X, point.Y)
    local screenDistance = (screenPosition - screenCenter).Magnitude
    local fovRadius = math.max(1, tonumber(_G.TargetAssistFOVRadius) or 180)
    local screenNorm = math.clamp(screenDistance / fovRadius, 0, 1)

    local worldDistance = localRoot and (localRoot.Position - root.Position).Magnitude or 0
    local maxDistance = math.max(1, tonumber(_G.TargetAssistMaxDistance) or 500)
    local distanceNorm = math.clamp(worldDistance / maxDistance, 0, 1)

    local healthNorm = 1
    if humanoid.MaxHealth > 0 then
        healthNorm = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
    end

    local mode = _G.ArgusTargetSelectionMode or "Crosshair"
    local score
    if mode == "Distance" then
        score = distanceNorm
    elseif mode == "Health" then
        score = healthNorm
    elseif mode == "Balanced" then
        score = (screenNorm * 1.0) + (distanceNorm * 0.35) + (healthNorm * 0.15)
    else
        score = screenNorm
    end

    return score, screenDistance, worldDistance
end

local function getTargetHeadLockInfo(character, screenCenter)
    if not character then return nil end
    local head = character:FindFirstChild("Head")
    local body = character:FindFirstChild("UpperTorso")
        or character:FindFirstChild("Torso")
        or character:FindFirstChild("HumanoidRootPart")
    if not head or not body then return nil end

    local point, visible = Camera:WorldToViewportPoint(head.Position)
    if not visible or point.Z <= 0 then return nil end

    local headPos = Vector2.new(point.X, point.Y)
    local distance = (headPos - screenCenter).Magnitude
    local fov = math.max(1, tonumber(_G.TargetAssistFOVRadius) or 180)
    if _G.TargetAssistFOVEnabled and distance > fov then return nil end
    if _G.TargetAssistWallCheck and not hasLineOfSight(head) then return nil end

    local threshold = math.clamp(tonumber(_G.TargetAssistHeadLockThreshold) or 65, 0, 100)
    local proximity = 1 - math.clamp(distance / fov, 0, 1)
    local visibilityScore = 1
    local headScore = proximity * 70 + visibilityScore * 30
    return {
        Part = head,
        Body = body,
        Distance = distance,
        Score = headScore,
        Qualified = headScore >= threshold,
    }
end

local function resetTargetHeadState()
    TargetAssist.HeadState = "Body"
    TargetAssist.HeadLostAt = 0
    TargetAssist.HeadLockStartedAt = 0
    TargetAssist.HeadReacquireAt = 0
    TargetAssist.LastHeadScore = math.huge
    _G.TargetAssistHeadLockState = "Body"
end

local function getBestTarget()
    local bestPlayer = nil
    local bestScore = math.huge

    local viewportSize = Camera.ViewportSize
    local screenCenter = Vector2.new(
        viewportSize.X * 0.5,
        viewportSize.Y * 0.5
    )

    local localCharacter = LocalPlayer.Character
    local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")

    local maxDistance = math.max(0, tonumber(_G.TargetAssistMaxDistance) or 500)
    local fovEnabled = _G.TargetAssistFOVEnabled
    local fovRadius = math.max(1, tonumber(_G.TargetAssistFOVRadius) or 180)

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and not (_G.TargetAssistTeamCheck and isSameTeam(player)) then
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local root = character and character:FindFirstChild("HumanoidRootPart")

            -- Cheap filters first: avoid LOS/raycast work for obviously invalid candidates.
            if character and humanoid and humanoid.Health > 0 and root and localRoot then
                local worldDistance = (localRoot.Position - root.Position).Magnitude
                if maxDistance <= 0 or worldDistance <= maxDistance then
                    local part = getTargetPart(character)
                    local point, visible = part and Camera:WorldToViewportPoint(part.Position)
                    if part and visible and point.Z > 0 then
                        local screenDistance = (Vector2.new(point.X, point.Y) - screenCenter).Magnitude
                        if not fovEnabled or _G.TargetAssistAutoSingleVisible == true or screenDistance <= fovRadius then
                            local score = getTargetScore(player, screenCenter, localRoot)
                            if score and score < bestScore then
                                bestScore = score
                                bestPlayer = player
                            end
                        end
                    end
                end
            end
        end
    end

    return bestPlayer, bestScore
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    -- RightShift is reserved for the main panel toggle; do not bind a second action here.
    if input.KeyCode == _G.ArgusUIKey then
        return
    end
    if input.KeyCode == _G.TargetAssistToggleKey then
        TargetAssist.ToggleState = not TargetAssist.ToggleState
    end
end)

local AutoSingleVisibleState = { At = 0, Count = 0, Target = nil }

local function getAutoSingleVisibleTarget()
    if _G.TargetAssistAutoSingleVisible ~= true then return nil, 0 end
    local now = os.clock()
    local interval = math.clamp(tonumber(_G.TargetAssistAutoCountInterval) or 0.035, 0.01, 0.2)
    if now - AutoSingleVisibleState.At < interval then
        return AutoSingleVisibleState.Target, AutoSingleVisibleState.Count
    end

    AutoSingleVisibleState.At = now
    AutoSingleVisibleState.Count = 0
    AutoSingleVisibleState.Target = nil

    local localCharacter = LocalPlayer.Character
    local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")
    local camera = workspace.CurrentCamera
    if not localRoot or not camera then return nil, 0 end

    local maxDistance = math.clamp(tonumber(_G.TargetAssistAutoVisibleRange) or 1000, 1, 1000)
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and not (_G.TargetAssistTeamCheck and isSameTeam(player)) then
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local root = character and character:FindFirstChild("HumanoidRootPart")
            local part = character and getTargetPart(character)
            if humanoid and humanoid.Health > 0 and root and part
                and (localRoot.Position - root.Position).Magnitude <= maxDistance then
                local screenPoint, onScreen = camera:WorldToViewportPoint(part.Position)
                if onScreen and screenPoint.Z > 0 and hasLineOfSight(part) then
                    AutoSingleVisibleState.Count += 1
                    AutoSingleVisibleState.Target = player
                    if AutoSingleVisibleState.Count > 1 then
                        AutoSingleVisibleState.Target = nil
                        break
                    end
                end
            end
        end
    end
    return AutoSingleVisibleState.Target, AutoSingleVisibleState.Count
end

-- Camera-FOV based ADS detection. A sustained FOV reduction is treated as zoom-in.
-- The first unzoomed camera FOV observed becomes the baseline; games using non-FOV zoom
-- effects will need a game-specific ADS signal instead.
local ArgusADSState = {
    Camera = nil,
    BaseFOV = nil,
    Active = false,
}

local function isCameraADSActive()
    local camera = workspace.CurrentCamera
    if not camera then
        ArgusADSState.Camera = nil
        ArgusADSState.BaseFOV = nil
        ArgusADSState.Active = false
        return false
    end

    local currentFOV = tonumber(camera.FieldOfView)
    if not currentFOV then return false end

    if ArgusADSState.Camera ~= camera or not ArgusADSState.BaseFOV then
        ArgusADSState.Camera = camera
        ArgusADSState.BaseFOV = currentFOV
        ArgusADSState.Active = false
        return false
    end

    local baseFOV = ArgusADSState.BaseFOV
    local threshold = math.clamp(tonumber(_G.TargetAssistADSZoomThreshold) or 6, 1, 25)
    if currentFOV <= baseFOV - threshold then
        ArgusADSState.Active = true
    elseif currentFOV >= baseFOV - threshold * 0.35 then
        ArgusADSState.Active = false
    end

    -- Track wider, non-ADS camera FOV changes without following a zoom-in downward.
    if not ArgusADSState.Active and currentFOV > baseFOV + 8 then
        ArgusADSState.BaseFOV = currentFOV
    end

    _G.ArgusADSActive = ArgusADSState.Active
    _G.ArgusADSFOV = currentFOV
    _G.ArgusADSBaseFOV = ArgusADSState.BaseFOV
    return ArgusADSState.Active
end

-- Forward declaration: the cached target selector is implemented later in the runtime section.
local argusCachedBestTarget

local function isAimActive()
    if not _G.TargetAssistEnabled then
        return false
    end

    -- 不要求開鏡或按住滑鼠：只要 FOV 內存在有效目標便可輔助。
    -- FOV 外、被遮擋、隊友、死亡或超距離目標都不能啟動輔助。
    local currentTarget = TargetAssist.CurrentTarget
    if currentTarget and targetAssistIsValid(currentTarget) then
        return true
    end

    local candidate = argusCachedBestTarget()
    return candidate ~= nil and targetAssistIsValid(candidate)
end

local function updateTargetAssist(dt)
    TargetAssistFOV.Radius = tonumber(_G.TargetAssistFOVRadius) or 180
    TargetAssistFOV.Thickness = tonumber(_G.TargetAssistFOVThickness) or 1
    TargetAssistFOV.Filled = _G.TargetAssistFOVFilled
    TargetAssistFOV.Transparency = _G.TargetAssistFOVTransparency
    TargetAssistFOV.Visible = _G.TargetAssistEnabled and _G.TargetAssistFOVEnabled and not _G.TargetAssistVisualsHidden

    -- 以同一套目標驗證條件決定 FOV 顏色，避免顏色與實際瞄準狀態不一致。
    local hasFOVTarget = false
    if _G.TargetAssistEnabled then
        local currentTarget = TargetAssist.CurrentTarget
        if currentTarget and targetAssistIsValid(currentTarget) then
            hasFOVTarget = true
        else
            local candidate = argusCachedBestTarget()
            hasFOVTarget = candidate ~= nil and targetAssistIsValid(candidate)
        end
    end
    _G.TargetAssistFOVHasTarget = hasFOVTarget
    _G.TargetAssistFOVColor = hasFOVTarget
        and (_G.TargetAssistFOVTargetColor or Color3.fromRGB(0, 255, 0))
        or (_G.TargetAssistFOVNoTargetColor or Color3.fromRGB(255, 0, 0))
    TargetAssistFOV.Color = _G.TargetAssistFOVColor

    if TargetAssistFOV.Visible then
        local viewportSize = Camera.ViewportSize
        TargetAssistFOV.Position = Vector2.new(viewportSize.X * 0.5, viewportSize.Y * 0.5)
    end

    if not isAimActive() then
        TargetAssist.CurrentTarget = nil
        TargetAssist.LockStartedAt = 0
        TargetAssist.ReacquireAt = 0
        TargetAssist.State = "Idle"
        resetTargetHeadState()
        return
    end

    local now = os.clock()
    TargetAssist.State = TargetAssist.CurrentTarget and "Locked" or "Searching"

    local currentTarget = TargetAssist.CurrentTarget
    local currentCharacter = currentTarget and currentTarget.Character
    local currentHumanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")

    -- 死亡是硬失效：不在同一幀把準心直接交給另一個目標。
    if currentTarget and (not currentHumanoid or currentHumanoid.Health <= 0) then
        TargetAssist.CurrentTarget = nil
        TargetAssist.LockStartedAt = 0
        TargetAssist.ReacquireAt = now + math.max(0, tonumber(_G.TargetAssistReacquireDelay) or 0.12)
        TargetAssist.State = "Reacquiring"
        return
    end

    if now < (TargetAssist.ReacquireAt or 0) then
        TargetAssist.State = "Reacquiring"
        return
    end

    local viewportSize = Camera.ViewportSize
    local screenCenter = Vector2.new(viewportSize.X * 0.5, viewportSize.Y * 0.5)
    local localCharacter = LocalPlayer.Character
    local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")

    -- 現有目標只要失去硬性條件（死亡、出屏、超距離、牆壁）就立即解除。
    local currentValid = currentTarget and targetAssistIsValid(currentTarget) or false
    if currentTarget and not currentValid then
        TargetAssist.CurrentTarget = nil
        TargetAssist.LockStartedAt = 0
        TargetAssist.State = "Searching"
        currentTarget = nil
    end

    local candidate, candidateScore = argusCachedBestTarget()

    if not currentTarget then
        if candidate then
            TargetAssist.CurrentTarget = candidate
            TargetAssist.LockStartedAt = now
            TargetAssist.LastSwitchAt = now
            TargetAssist.State = "Locked"
        else
            TargetAssist.State = "Searching"
            return
        end
    elseif candidate and candidate ~= currentTarget then
        -- Sticky + hysteresis：新目標必須明顯更好，且經過切換冷卻才允許換人。
        local currentScore = getTargetScore(currentTarget, screenCenter, localRoot)
        local switchDelay = math.max(0, tonumber(_G.TargetAssistTargetSwitchDelay) or 0.15)
        local minimumLock = math.max(0, tonumber(_G.TargetAssistMinimumLockTime) or 0.12)
        local lockedFor = now - (TargetAssist.LockStartedAt or now)
        local sinceSwitch = now - (TargetAssist.LastSwitchAt or 0)
        local ratio = math.clamp(tonumber(_G.TargetAssistSwitchScoreRatio) or 0.78, 0.1, 1)
        local shouldSwitch = true

        if _G.TargetAssistTargetSticky then
            shouldSwitch = currentScore == nil or (candidateScore and candidateScore < currentScore * ratio)
        end

        if lockedFor < minimumLock or sinceSwitch < switchDelay then
            shouldSwitch = false
        end

        if shouldSwitch then
            TargetAssist.CurrentTarget = candidate
            TargetAssist.LockStartedAt = now
            TargetAssist.LastSwitchAt = now
            TargetAssist.State = "Locked"
        end
    end

    local target = TargetAssist.CurrentTarget
    if not target or not targetAssistIsValid(target) then
        TargetAssist.CurrentTarget = nil
        TargetAssist.State = "Searching"
        return
    end

    local character = target.Character
    local targetPart = getTargetPart(character)
    if not targetPart or not hasLineOfSight(targetPart) then
        TargetAssist.CurrentTarget = nil
        TargetAssist.State = "Searching"
        resetTargetHeadState()
        return
    end

    local cameraPosition = Camera.CFrame.Position
    -- Smoothness 越大，轉向速度越低；不再被自動單目標模式覆寫。
    local smoothness = math.clamp(tonumber(_G.TargetAssistSmoothness) or 8, 1, 30)
    local predictedPosition

    -- Desktop-only aiming response is controlled by Smoothness.
    if _G.TargetAssistSecondaryLock then
        local elapsed = now - (TargetAssist.LockStartedAt or now)
        local delay = math.max(0, tonumber(_G.TargetAssistSecondaryDelay) or 0.10)
        local blendTime = math.max(0.01, tonumber(_G.TargetAssistSecondaryBlendTime) or 0.16)
        local primaryPart = getSecondaryPrimaryPart(character) or targetPart
        local secondaryPart = getSecondaryTargetPart(character) or targetPart
        local primaryPosition = getPredictedPosition(primaryPart)
        local secondaryPosition = getPredictedPosition(secondaryPart)

        if elapsed < delay then
            predictedPosition = primaryPosition
        else
            local blendAlpha = math.clamp((elapsed - delay) / blendTime, 0, 1)
            blendAlpha = blendAlpha * blendAlpha * (3 - 2 * blendAlpha)
            predictedPosition = primaryPosition:Lerp(secondaryPosition, blendAlpha)
            smoothness = math.clamp(tonumber(_G.TargetAssistSecondarySmoothness) or smoothness, 1, 40)
        end
    else
        predictedPosition = getPredictedPosition(targetPart)
    end

    -- Desktop head-lock state machine: Body -> Head Lock -> Grace -> Reacquire.
    do
        local headInfo = getTargetHeadLockInfo(character, screenCenter)
        local headStrength = math.clamp(tonumber(_G.TargetAssistHeadLockStrength) or 100, 0, 100) / 100
        local nowHead = os.clock()
        local qualified = headInfo and headInfo.Qualified and headStrength > 0
        local grace = math.max(0, tonumber(_G.TargetAssistHeadLockGrace) or 0.12)
        local reacquireDelay = math.max(0, tonumber(_G.TargetAssistHeadLockReacquireDelay) or 0.08)
        local switchMargin = math.clamp(tonumber(_G.TargetAssistHeadLockSwitchMargin) or 0.10, 0, 1)

        if qualified then
            local betterEnough = TargetAssist.LastHeadScore == math.huge
                or headInfo.Score >= TargetAssist.LastHeadScore * (1 - switchMargin)
            if TargetAssist.HeadState == "Body" or TargetAssist.HeadState == "HeadCandidate" then
                TargetAssist.HeadState = "HeadLock"
                TargetAssist.HeadLockStartedAt = nowHead
            elseif TargetAssist.HeadState == "HeadGrace" and nowHead >= TargetAssist.HeadReacquireAt then
                TargetAssist.HeadState = "HeadLock"
            end
            if betterEnough then
                TargetAssist.LastHeadScore = headInfo.Score
            end
            TargetAssist.HeadLostAt = 0
        elseif TargetAssist.HeadState == "HeadLock" then
            TargetAssist.HeadState = "HeadGrace"
            TargetAssist.HeadLostAt = nowHead
            TargetAssist.HeadReacquireAt = nowHead + reacquireDelay
        elseif TargetAssist.HeadState == "HeadGrace" then
            if nowHead - TargetAssist.HeadLostAt > grace then
                TargetAssist.HeadState = "Body"
                TargetAssist.LastHeadScore = math.huge
            end
        end

        if TargetAssist.HeadState == "HeadLock" and headInfo then
            local headPosition = getPredictedPosition(headInfo.Part)
            local bodyPosition = getPredictedPosition(headInfo.Body)
            predictedPosition = bodyPosition:Lerp(headPosition, headStrength)
        elseif TargetAssist.HeadState == "HeadGrace" and headInfo then
            local headPosition = getPredictedPosition(headInfo.Part)
            local bodyPosition = getPredictedPosition(headInfo.Body)
            local graceAlpha = math.clamp(1 - ((nowHead - TargetAssist.HeadLostAt) / math.max(grace, 0.001)), 0, 1)
            predictedPosition = bodyPosition:Lerp(headPosition, headStrength * graceAlpha)
        else
            local body = character:FindFirstChild("UpperTorso")
                or character:FindFirstChild("Torso")
                or character:FindFirstChild("HumanoidRootPart")
            if body then predictedPosition = getPredictedPosition(body) end
        end
        _G.TargetAssistHeadLockState = TargetAssist.HeadState
    end

    predictedPosition += getHumanizedOffset(dt)
    local targetCFrame = CFrame.lookAt(cameraPosition, predictedPosition)
    -- 將平滑值轉為反比追蹤速度：值越大，alpha 越小，輔助效力越弱。
    local response = (24 / math.max(smoothness, 1))
    local alpha = 1 - math.exp(-response * math.max(dt, 0))
    Camera.CFrame = Camera.CFrame:Lerp(targetCFrame, math.clamp(alpha, 0, 1))
end

RunService:BindToRenderStep(
    "NexusStudioTargetAssist",
    Enum.RenderPriority.Camera.Value + 1,
    updateTargetAssist
)

-- ============================================================
-- CRESCENT HUB CONTROL CENTER
-- Added: Dashboard / Target Status / Sliders / Profiles /
-- Keybind Manager / Debug / ESP Performance / Target Weighting /
-- Secondary Lock State / Notifications / UI Animation
-- ============================================================
-- THIRD PERSON CAMERA CONTROL
-- ============================================================
_G.ThirdPersonEnabled = _G.ThirdPersonEnabled == true
_G.ThirdPersonDistance = tonumber(_G.ThirdPersonDistance) or 8
_G.ThirdPersonShoulderOffset = _G.ThirdPersonShoulderOffset or Vector3.new(2,1,0)
local ThirdPersonState = {Enabled=_G.ThirdPersonEnabled==true,PreviousMinZoom=nil,PreviousMaxZoom=nil,PreviousCameraOffset=nil}
local function applyThirdPerson(enabled)
    enabled=enabled==true; ThirdPersonState.Enabled=enabled; _G.ThirdPersonEnabled=enabled
    local character=LocalPlayer.Character; local humanoid=character and character:FindFirstChildOfClass("Humanoid")
    if enabled then
        if ThirdPersonState.PreviousMinZoom==nil then ThirdPersonState.PreviousMinZoom=LocalPlayer.CameraMinZoomDistance; ThirdPersonState.PreviousMaxZoom=LocalPlayer.CameraMaxZoomDistance end
        if humanoid and ThirdPersonState.PreviousCameraOffset==nil then ThirdPersonState.PreviousCameraOffset=humanoid.CameraOffset end
        local d=math.max(tonumber(_G.ThirdPersonDistance) or 8,4); LocalPlayer.CameraMinZoomDistance=d; LocalPlayer.CameraMaxZoomDistance=d
        if humanoid then humanoid.CameraOffset=_G.ThirdPersonShoulderOffset end
    else
        if ThirdPersonState.PreviousMinZoom~=nil then LocalPlayer.CameraMinZoomDistance=ThirdPersonState.PreviousMinZoom; LocalPlayer.CameraMaxZoomDistance=ThirdPersonState.PreviousMaxZoom or ThirdPersonState.PreviousMinZoom end
        if humanoid and ThirdPersonState.PreviousCameraOffset~=nil then humanoid.CameraOffset=ThirdPersonState.PreviousCameraOffset end
    end
end
local function toggleThirdPerson() applyThirdPerson(not ThirdPersonState.Enabled) end
LocalPlayer.CharacterAdded:Connect(function(character)
    if not ThirdPersonState.Enabled then return end
    task.defer(function() local h=character:WaitForChild("Humanoid",5); if h then h.CameraOffset=_G.ThirdPersonShoulderOffset; local d=math.max(tonumber(_G.ThirdPersonDistance) or 8,4); LocalPlayer.CameraMinZoomDistance=d; LocalPlayer.CameraMaxZoomDistance=d end end)
end)
RunService:BindToRenderStep("NexusArgusThirdPerson",Enum.RenderPriority.Camera.Value+1,function()
    if not ThirdPersonState.Enabled then return end
    local c=LocalPlayer.Character; local h=c and c:FindFirstChildOfClass("Humanoid"); if not h then return end
    local d=math.max(tonumber(_G.ThirdPersonDistance) or 8,4); if LocalPlayer.CameraMinZoomDistance~=d then LocalPlayer.CameraMinZoomDistance=d end; if LocalPlayer.CameraMaxZoomDistance~=d then LocalPlayer.CameraMaxZoomDistance=d end; if h.CameraOffset~=_G.ThirdPersonShoulderOffset then h.CameraOffset=_G.ThirdPersonShoulderOffset end
end)
if ThirdPersonState.Enabled then task.defer(function() applyThirdPerson(true) end) end

-- ============================================================

_G.ArgusUIEnabled = true
_G.ArgusUIKey = Enum.KeyCode.RightShift
_G.ArgusDebugMode = false
_G.ArgusESPPerformance = true
_G.ArgusESPUpdateRate = 60
_G.ArgusStreamMode = _G.ArgusStreamMode == true
_G.ArgusPrivacyCurtain = _G.ArgusPrivacyCurtain == true
_G.ArgusTargetSelectionMode = "Crosshair"
_G.ArgusWeightCrosshair = 1.0
_G.ArgusWeightDistance = 0.35
_G.ArgusWeightHealth = 0.15
_G.ArgusWeightCustom = 0.0
_G.ArgusProfile = "Default"
_G.ArgusUIAccent = Color3.fromRGB(174, 224, 255)

local ArgusUI = {
    Open = false,
    Tab = "Dashboard",
    X = 70,
    Y = 90,
    W = 480,
    H = 560,
    Dragging = false,
    DragOffset = Vector2.zero,
    ActiveSlider = nil,
    Toast = nil,
    ToastUntil = 0,
    Status = "Idle",
    FPS = 0,
    FrameCount = 0,
    FPSClock = os.clock(),
    Anim = {Open=0,TargetOpen=0,Alpha=0,Tab=0,TargetTab=0,Toast=0,ToastY=10,Pressed=nil},
}

local ArgusProfiles = {}
local ArgusKeybinds = {
    AimToggle = _G.TargetAssistToggleKey,
    UI = _G.ArgusUIKey,
    VisualHide = nil,
}

local function argusNewSquare(filled, thickness)
    local x = Drawing.new("Square")
    x.Filled = filled or false
    x.Thickness = thickness or 1
    x.Color = Color3.fromRGB(20, 20, 20)
    x.Visible = false
    return x
end

local function argusNewText(size)
    local x = Drawing.new("Text")
    x.Size = size or 14
    x.Font = 2
    x.Color = Color3.fromRGB(235, 235, 235)
    x.Outline = true
    x.OutlineColor = Color3.fromRGB(0, 0, 0)
    x.Visible = false
    return x
end

local ArgusDraw = {
    LiveTexts = {},
    Shadow = argusNewSquare(true),
    Panel = argusNewSquare(true),
    Header = argusNewSquare(true),
    Accent = argusNewSquare(true),
    TabLine = argusNewSquare(true),
    TabIndicator = argusNewSquare(true),
    Title = argusNewText(18),
    Subtitle = argusNewText(11),
    TabTexts = {},
    BodyTexts = {},
    Buttons = {},
    Sliders = {},
    Status = argusNewText(12),
    Footer = argusNewText(10),
    ToastBox = argusNewSquare(true),
    ToastText = argusNewText(11),
}

local ArgusTabs = {"Dashboard", "Visuals", "Target", "Settings", "Profiles", "Keybinds", "Debug"}
for _, tab in ipairs(ArgusTabs) do
    ArgusDraw.TabTexts[tab] = argusNewText(12)
end

local function argusClearList(list)
    for _, obj in pairs(list) do
        if obj then obj.Visible = false end
    end
end

local function argusDestroyList(list)
    for _, obj in pairs(list) do
        if obj then
            pcall(function() obj:Remove() end)
            pcall(function() obj:Destroy() end)
        end
    end
end

local function argusDestroyControls()
    argusDestroyList(ArgusDraw.BodyTexts)
    ArgusDraw.BodyTexts = {}
    ArgusDraw.LiveTexts = {}

    for _, slider in ipairs(ArgusDraw.Sliders) do
        pcall(function() slider.Back:Remove() end)
        pcall(function() slider.Fill:Remove() end)
        pcall(function() slider.Text:Remove() end)
    end
    ArgusDraw.Sliders = {}

    for _, button in ipairs(ArgusDraw.Buttons) do
        pcall(function() button.Box:Remove() end)
        pcall(function() button.Text:Remove() end)
    end
    ArgusDraw.Buttons = {}
end

local function argusText(text, x, y, size, color)
    local t = argusNewText(size or 13)
    t.Text = tostring(text)
    t.Position = Vector2.new(x, y)
    t.Color = color or Color3.fromRGB(235,235,235)
    t.Visible = ArgusUI.Open
    table.insert(ArgusDraw.BodyTexts, t)
    return t
end

local function argusLiveText(key, text, x, y, size, color)
    local t = argusText(text, x, y, size, color)
    ArgusDraw.LiveTexts[key] = t
    return t
end

local function argusSetLiveText(key, text, color)
    local t = ArgusDraw.LiveTexts[key]
    if not t then return end
    t.Text = tostring(text)
    if color then t.Color = color end
end

local function argusToast(message)
    ArgusUI.Toast = tostring(message)
    ArgusUI.ToastUntil = os.clock() + 2.2
    ArgusUI.Anim.Toast=0
    ArgusUI.Anim.ToastY=10
end

local function argusBoolText(value)
    return value and "ON" or "OFF"
end

local function argusUIAnim(dt)
    local a=ArgusUI.Anim
    -- Soft ice-blue pulse; UI accents stay within the blue/black/white palette.
    local pulse = 0.5 + 0.5 * math.sin(os.clock() * 1.2)
    _G.ArgusUIAccent = Color3.fromRGB(
        math.floor(145 + 45 * pulse),
        math.floor(205 + 25 * pulse),
        math.floor(238 + 17 * pulse)
    )
    a.Open=a.Open+(a.TargetOpen-a.Open)*math.clamp(dt*14,0,1)
    a.Alpha=a.Alpha+(a.Open-a.Alpha)*math.clamp(dt*16,0,1)
    local idx=1
    for i,tab in ipairs(ArgusTabs) do if tab==ArgusUI.Tab then idx=i break end end
    a.TargetTab=(idx-1)/math.max(1,#ArgusTabs-1)
    a.Tab=a.Tab+(a.TargetTab-a.Tab)*math.clamp(dt*14,0,1)
    if ArgusUI.Toast and os.clock()<ArgusUI.ToastUntil then
        a.Toast=a.Toast+(1-a.Toast)*math.clamp(dt*18,0,1)
        a.ToastY=a.ToastY+(0-a.ToastY)*math.clamp(dt*16,0,1)
    else
        a.Toast=a.Toast+(0-a.Toast)*math.clamp(dt*12,0,1)
        a.ToastY=a.ToastY+(10-a.ToastY)*math.clamp(dt*12,0,1)
    end
end


local function argusStatusColor(status)
    if status == "Locked" or status == "Secondary Lock" then
        return Color3.fromRGB(255,255,255)
    elseif status == "Acquiring" or status == "Primary Lock" then
        return Color3.fromRGB(210,210,210)
    elseif status == "Error" then
        return Color3.fromRGB(160,160,160)
    end
    return Color3.fromRGB(180,180,180)
end

local function argusGetTargetStatus()
    if not _G.TargetAssistEnabled then
        return "Disabled", nil
    end

    local target = TargetAssist.CurrentTarget
    if not target then
        if isAimActive() then return "Acquiring", nil end
        return "Ready", nil
    end

    if _G.TargetAssistSecondaryLock then
        local elapsed = os.clock() - (TargetAssist.LockStartedAt or 0)
        local delay = math.max(0, tonumber(_G.TargetAssistSecondaryDelay) or 0.10)
        local blend = math.max(0.01, tonumber(_G.TargetAssistSecondaryBlendTime) or 0.16)
        if elapsed < delay then return "Primary Lock", target end
        if elapsed < delay + blend then return "Acquiring", target end
        return "Secondary Lock", target
    end

    return "Locked", target
end

local function argusCycleSelectionMode()
    local modes = {"Crosshair", "Distance", "Health", "Balanced"}
    local index = 1
    for i, mode in ipairs(modes) do
        if mode == _G.ArgusTargetSelectionMode then index = i break end
    end
    index = index % #modes + 1
    _G.ArgusTargetSelectionMode = modes[index]
    argusToast("Selection: " .. modes[index])
end

local function argusCaptureProfile()
    return {
        ESPEnabled = _G.ESPEnabled,
        BoxESP = _G.BoxESP,
        BoxFilled = _G.BoxFilled,
        HighlightESP = _G.HighlightESP,
        HealthESP = _G.HealthESP,
        NameESP = _G.NameESP,
        ToolESP = _G.ToolESP,
        TracerESP = _G.TracerESP,
        SkeletonESP = _G.SkeletonESP,
        TeamCheck = _G.TeamCheck,
        TargetAssistEnabled = _G.TargetAssistEnabled,
        TargetAssistPart = _G.TargetAssistPart,
        TargetAssistSmoothness = _G.TargetAssistSmoothness,
        TargetAssistMaxDistance = _G.TargetAssistMaxDistance,
        TargetAssistFOVEnabled = _G.TargetAssistFOVEnabled,
        TargetAssistFOVRadius = _G.TargetAssistFOVRadius,
        TargetAssistWallCheck = _G.TargetAssistWallCheck,
        TargetAssistTeamCheck = _G.TargetAssistTeamCheck,
        TargetAssistRequireOnScreen = _G.TargetAssistRequireOnScreen,
        TargetAssistActivationMode = _G.TargetAssistActivationMode,
        TargetAssistToggleKey = _G.TargetAssistToggleKey,
        TargetAssistPredictionEnabled = _G.TargetAssistPredictionEnabled,
        TargetAssistPredictionTime = _G.TargetAssistPredictionTime,
        TargetAssistMovementPrediction = _G.TargetAssistMovementPrediction,
        TargetAssistProjectileSpeed = _G.TargetAssistProjectileSpeed,
        TargetAssistOffset = _G.TargetAssistOffset,
        TargetAssistSecondaryLock = _G.TargetAssistSecondaryLock,
        TargetAssistSecondaryPart = _G.TargetAssistSecondaryPart,
        TargetAssistSecondaryPrimaryPart = _G.TargetAssistSecondaryPrimaryPart,
        TargetAssistSecondaryDelay = _G.TargetAssistSecondaryDelay,
        TargetAssistSecondaryBlendTime = _G.TargetAssistSecondaryBlendTime,
        TargetAssistSecondarySmoothness = _G.TargetAssistSecondarySmoothness,
        TargetAssistAutoHead = _G.TargetAssistAutoHead,
        TargetAssistAutoBodyPart = _G.TargetAssistAutoBodyPart,
        TargetAssistHumanizedAim = _G.TargetAssistHumanizedAim,
        TargetAssistAimError = _G.TargetAssistAimError,
        TargetAssistJitterSpeed = _G.TargetAssistJitterSpeed,
        TargetAssistSelectionMode = _G.ArgusTargetSelectionMode,
    }
end

local function argusApplyProfile(profile)
    if not profile then return end
    for key, value in pairs(profile) do
        if key == "TargetAssistSelectionMode" then
            _G.ArgusTargetSelectionMode = value
        else
            _G[key] = value
        end
    end
end

ArgusProfiles.Default = argusCaptureProfile()

local function argusMakeButton(label, x, y, w, h, callback)
    local b = argusNewSquare(true)
    b.Position = Vector2.new(x, y)
    b.Size = Vector2.new(w, h)
    b.Color = Color3.fromRGB(28,28,28)
    b.Visible = ArgusUI.Open
    local t = argusNewText(12)
    t.Text = label
    t.Position = Vector2.new(x + 10, y + 6)
    t.Color = Color3.fromRGB(235,235,235)
    t.Visible = ArgusUI.Open
    table.insert(ArgusDraw.Buttons, {Box=b, Text=t, Callback=callback})
end

local function argusMakeSlider(label, key, x, y, w, min, max, step)
    local back = argusNewSquare(true)
    back.Position = Vector2.new(x, y + 24)
    back.Size = Vector2.new(w, 5)
    back.Color = Color3.fromRGB(55,55,55)
    back.Visible = ArgusUI.Open

    local fill = argusNewSquare(true)
    fill.Position = Vector2.new(x, y + 24)
    fill.Size = Vector2.new(0, 5)
    fill.Color = _G.ArgusUIAccent
    fill.Visible = ArgusUI.Open

    local txt = argusNewText(12)
    txt.Position = Vector2.new(x, y)
    txt.Visible = ArgusUI.Open

    table.insert(ArgusDraw.Sliders, {
        Key=key, Label=label, X=x, Y=y, W=w, Min=min, Max=max, Step=step,
        Back=back, Fill=fill, Text=txt,
    })
end

local function argusSetSlider(slider, mouseX)
    local ratio = math.clamp((mouseX - slider.X) / slider.W, 0, 1)
    local raw = slider.Min + (slider.Max - slider.Min) * ratio
    local value = math.floor(raw / slider.Step + 0.5) * slider.Step
    _G[slider.Key] = math.clamp(value, slider.Min, slider.Max)
end

local function argusUpdateLivePanel()
    if not ArgusUI.Open then return end
    if ArgusUI.Tab == "Dashboard" then
        local status, target = argusGetTargetStatus()
        argusSetLiveText("dash_status", status, argusStatusColor(status))
        argusSetLiveText("dash_target", "Target: " .. (target and target.Name or "None"))
        argusSetLiveText("dash_fps", string.format("FPS: %.0f", ArgusUI.FPS))
        argusSetLiveText("dash_modules", "ESP: "..argusBoolText(_G.ESPEnabled).."   Target Assist: "..argusBoolText(_G.TargetAssistEnabled))
        argusSetLiveText("dash_selection", "Selection: ".._G.ArgusTargetSelectionMode)
        argusSetLiveText("dash_secondary", "Secondary: "..argusBoolText(_G.TargetAssistSecondaryLock))
    elseif ArgusUI.Tab == "Debug" then
        local status, target = argusGetTargetStatus()
        local localRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        local targetRoot = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
        local distance = (localRoot and targetRoot) and (localRoot.Position-targetRoot.Position).Magnitude or 0
        local los = target and target.Character and getTargetPart(target.Character) and hasLineOfSight(getTargetPart(target.Character)) or false
        argusSetLiveText("debug_target", "Target: "..(target and target.Name or "None"))
        argusSetLiveText("debug_distance", string.format("Distance: %.1f", distance))
        argusSetLiveText("debug_fov", "FOV: "..tostring(_G.TargetAssistFOVRadius))
        argusSetLiveText("debug_los", "LOS: "..argusBoolText(los))
        argusSetLiveText("debug_selection", "Selection: ".._G.ArgusTargetSelectionMode)
        argusSetLiveText("debug_perf", "ESP Performance: "..argusBoolText(_G.ArgusESPPerformance))
        argusSetLiveText("debug_rate", "Update Rate: "..tostring(_G.ArgusESPUpdateRate))
        argusSetLiveText("debug_humanized", "Humanized: "..argusBoolText(_G.TargetAssistHumanizedAim))
    end
end

local function argusRenderSliders()
    for _, slider in ipairs(ArgusDraw.Sliders) do
        local value = tonumber(_G[slider.Key]) or slider.Min
        local ratio = math.clamp((value-slider.Min)/(slider.Max-slider.Min),0,1)
        slider.Fill.Size = Vector2.new(slider.W * ratio, 5)
        slider.Text.Text = string.format("%s: %.2f", slider.Label, value)
        slider.Text.Visible = ArgusUI.Open
        slider.Back.Visible = ArgusUI.Open
        slider.Fill.Visible = ArgusUI.Open
    end
end

local function argusRebuildBody()
    argusDestroyControls()

    local x = ArgusUI.X + 22
    local y = ArgusUI.Y + 91
    local w = ArgusUI.W - 44

    if ArgusUI.Tab == "Dashboard" then
        local status, target = argusGetTargetStatus()
        argusText("CRESCENT HUB STATUS", x, y, 11, Color3.fromRGB(170,170,170))
        argusLiveText("dash_status", status, x, y+24, 22, argusStatusColor(status))
        argusLiveText("dash_target", "Target: " .. (target and target.Name or "None"), x, y+56, 13)
        argusLiveText("dash_fps", string.format("FPS: %.0f", ArgusUI.FPS), x, y+80, 12)
        argusLiveText("dash_modules", "ESP: "..argusBoolText(_G.ESPEnabled).."   Target Assist: "..argusBoolText(_G.TargetAssistEnabled), x, y+103, 12)
        argusLiveText("dash_selection", "Selection: ".._G.ArgusTargetSelectionMode, x, y+126, 12)
        argusLiveText("dash_secondary", "Secondary: "..argusBoolText(_G.TargetAssistSecondaryLock), x, y+149, 12)
        argusMakeButton("Toggle Target Assist", x, y+180, w, 30, function()
            _G.TargetAssistEnabled = not _G.TargetAssistEnabled
            argusToast("Target Assist "..argusBoolText(_G.TargetAssistEnabled))
        end)
        argusMakeButton("Selection Mode: ".._G.ArgusTargetSelectionMode, x, y+218, w, 30, argusCycleSelectionMode)
        argusMakeButton("Reload Dashboard", x, y+256, w, 30, function() argusToast("Dashboard refreshed") end)

    elseif ArgusUI.Tab == "Visuals" then
        argusText("VISUAL MODULES", x, y, 11, Color3.fromRGB(170,170,170))
        local rows = {
            {"ESPEnabled","ESP Master"},{"BoxESP","Box"},{"BoxFilled","Filled Box"},
            {"HighlightESP","Highlight"},{"HealthESP","Health"},{"NameESP","Name"},
            {"ToolESP","Tool"},{"TracerESP","Tracer"},{"SkeletonESP","Skeleton"},
            {"TeamCheck","Team Check"},
        }
        local yy = y+28
        for _, row in ipairs(rows) do
            argusMakeButton(row[2]..": "..argusBoolText(_G[row[1]]), x, yy, w, 27, function()
                _G[row[1]] = not _G[row[1]]
                argusToast(row[2].." "..argusBoolText(_G[row[1]]))
                argusRebuildBody()
            end)
            yy += 31
        end

    elseif ArgusUI.Tab == "Target" then
        argusText("TARGET ASSIST", x, y, 11, Color3.fromRGB(170,170,170))
        argusMakeButton("Part: "..tostring(_G.TargetAssistPart), x, y+25, w, 28, function()
            local parts={"Head","UpperTorso","LowerTorso","HumanoidRootPart","Auto"}
            local idx=1
            for i,v in ipairs(parts) do if v==_G.TargetAssistPart then idx=i break end end
            _G.TargetAssistPart=parts[idx%#parts+1]
            argusRebuildBody()
        end)
        argusMakeButton("Activation: "..tostring(_G.TargetAssistActivationMode), x, y+58, w, 28, function()
            local modes={"RightMouse","Toggle","Both"}
            local idx=1
            for i,v in ipairs(modes) do if v==_G.TargetAssistActivationMode then idx=i break end end
            _G.TargetAssistActivationMode=modes[idx%#modes+1]
            argusRebuildBody()
        end)
        argusMakeButton("Wall Check: "..argusBoolText(_G.TargetAssistWallCheck), x, y+91, w, 28, function()
            _G.TargetAssistWallCheck=not _G.TargetAssistWallCheck
            argusRebuildBody()
        end)
        argusMakeButton("FOV: "..argusBoolText(_G.TargetAssistFOVEnabled), x, y+124, w, 28, function()
            _G.TargetAssistFOVEnabled=not _G.TargetAssistFOVEnabled
            argusRebuildBody()
        end)
        argusMakeButton("Secondary Lock: "..argusBoolText(_G.TargetAssistSecondaryLock), x, y+157, w, 28, function()
            _G.TargetAssistSecondaryLock=not _G.TargetAssistSecondaryLock
            argusRebuildBody()
        end)
        argusMakeButton("Prediction: "..argusBoolText(_G.TargetAssistPredictionEnabled), x, y+190, w, 28, function()
            _G.TargetAssistPredictionEnabled=not _G.TargetAssistPredictionEnabled
            argusRebuildBody()
        end)
        argusMakeButton("Selection: ".._G.ArgusTargetSelectionMode, x, y+223, w, 28, argusCycleSelectionMode)
        argusMakeButton("Humanized Aim: "..argusBoolText(_G.TargetAssistHumanizedAim), x, y+256, w, 28, function()
            _G.TargetAssistHumanizedAim=not _G.TargetAssistHumanizedAim
            argusRebuildBody()
        end)
        argusMakeButton("Team Check: "..argusBoolText(_G.TargetAssistTeamCheck), x, y+289, w, 28, function()
            _G.TargetAssistTeamCheck=not _G.TargetAssistTeamCheck
            argusRebuildBody()
        end)
        argusMakeButton("On Screen Only: "..argusBoolText(_G.TargetAssistRequireOnScreen), x, y+322, w, 28, function()
            _G.TargetAssistRequireOnScreen=not _G.TargetAssistRequireOnScreen
            argusRebuildBody()
        end)
        argusMakeSlider("Smoothness (higher = weaker)", "TargetAssistSmoothness", x, y+360, w, 1, 30, 0.5)
        argusMakeSlider("Secondary Smoothness", "TargetAssistSecondarySmoothness", x, y+406, w, 1, 40, 0.5)
        argusMakeSlider("FOV Radius", "TargetAssistFOVRadius", x, y+452, w, 20, 600, 5)
        argusMakeSlider("Max Distance", "TargetAssistMaxDistance", x, y+498, w, 0, 2000, 10)

    elseif ArgusUI.Tab == "Settings" then
        argusText("FINE CONTROL", x, y, 11, Color3.fromRGB(170,170,170))
        argusMakeButton("ESP Performance: "..argusBoolText(_G.ArgusESPPerformance), x, y+25, w, 28, function()
            _G.ArgusESPPerformance=not _G.ArgusESPPerformance
            argusRebuildBody()
        end)
        argusMakeButton("Update Rate: "..tostring(_G.ArgusESPUpdateRate).." FPS", x, y+58, w, 28, function()
            local rates={15,30,60,120}
            local idx=1 for i,v in ipairs(rates) do if v==_G.ArgusESPUpdateRate then idx=i break end end
            _G.ArgusESPUpdateRate=rates[idx%#rates+1]
            argusRebuildBody()
        end)
        argusMakeButton("UI Theme: Monochrome Gradient", x, y+91, w, 28, function()
            _G.ArgusUIAccent=Color3.fromRGB(220,220,220)
            argusRebuildBody()
        end)
        argusMakeSlider("Prediction Time", "TargetAssistPredictionTime", x, y+138, w, 0, 0.5, 0.01)
        argusMakeSlider("Secondary Delay", "TargetAssistSecondaryDelay", x, y+184, w, 0, 0.5, 0.01)
        argusMakeSlider("Blend Time", "TargetAssistSecondaryBlendTime", x, y+230, w, 0.01, 0.5, 0.01)
        argusMakeSlider("Aim Error", "TargetAssistAimError", x, y+276, w, 0, 0.2, 0.001)
        argusMakeSlider("Jitter Speed", "TargetAssistJitterSpeed", x, y+322, w, 0, 30, 0.5)
        argusMakeSlider("Projectile Speed", "TargetAssistProjectileSpeed", x, y+368, w, 0, 10000, 50)
        argusMakeSlider("Secondary Smooth", "TargetAssistSecondarySmoothness", x, y+414, w, 1, 40, 0.5)
        argusMakeSlider("FOV Thickness", "TargetAssistFOVThickness", x, y+460, w, 1, 5, 1)
        argusMakeSlider("FOV Transparency", "TargetAssistFOVTransparency", x, y+506, w, 0, 1, 0.05)

    elseif ArgusUI.Tab == "Profiles" then
        argusText("PROFILE MANAGER", x, y, 11, Color3.fromRGB(170,170,170))
        argusText("Current: ".._G.ArgusProfile, x, y+24, 13)
        local slots={"Default","Profile 1","Profile 2","Profile 3"}
        local yy=y+54
        for _, name in ipairs(slots) do
            argusMakeButton("Load "..name, x, yy, w*0.47, 28, function()
                if ArgusProfiles[name] then
                    argusApplyProfile(ArgusProfiles[name])
                    _G.ArgusProfile=name
                    argusToast("Loaded "..name)
                    argusRebuildBody()
                end
            end)
            argusMakeButton("Save", x+w*0.51, yy, w*0.47, 28, function()
                ArgusProfiles[name]=argusCaptureProfile()
                _G.ArgusProfile=name
                argusToast("Saved "..name)
                argusRebuildBody()
            end)
            yy+=36
        end
        argusText("Profiles are kept for this script session.", x, yy+12, 10, Color3.fromRGB(150,150,150))

    elseif ArgusUI.Tab == "Keybinds" then
        argusText("KEYBIND MANAGER", x, y, 11, Color3.fromRGB(170,170,170))
        argusText("RightControl = UI", x, y+28, 13)
        argusMakeButton("Aim Key: "..tostring(ArgusKeybinds.AimToggle.Name), x, y+55, w, 30, function()
            local keys={Enum.KeyCode.Q,Enum.KeyCode.E,Enum.KeyCode.T,Enum.KeyCode.LeftAlt}
            local idx=1 for i,v in ipairs(keys) do if v==ArgusKeybinds.AimToggle then idx=i break end end
            ArgusKeybinds.AimToggle=keys[idx%#keys+1]
            _G.TargetAssistToggleKey=ArgusKeybinds.AimToggle
            argusToast("Aim key: "..ArgusKeybinds.AimToggle.Name)
            argusRebuildBody()
        end)
        argusMakeButton("Visual Hide: "..tostring(ArgusKeybinds.VisualHide.Name), x, y+91, w, 30, function()
            argusToast("Visual hide remains "..ArgusKeybinds.VisualHide.Name)
        end)
        argusText("Click the Aim Key button to cycle Q / E / T / LeftAlt.", x, y+135, 10, Color3.fromRGB(150,150,150))
        argusText("RightShift toggles the main panel.", x, y+155, 10, Color3.fromRGB(150,150,150))

    elseif ArgusUI.Tab == "Debug" then
        argusText("DEBUG / DIAGNOSTICS", x, y, 11, Color3.fromRGB(170,170,170))
        argusMakeButton("Debug Mode: "..argusBoolText(_G.ArgusDebugMode), x, y+25, w, 30, function()
            _G.ArgusDebugMode=not _G.ArgusDebugMode
            argusToast("Debug Mode "..argusBoolText(_G.ArgusDebugMode))
            argusRebuildBody()
        end)
        local status,target=argusGetTargetStatus()
        local char=target and target.Character
        local root=char and char:FindFirstChild("HumanoidRootPart")
        local localChar=LocalPlayer.Character
        local localRoot=localChar and localChar:FindFirstChild("HumanoidRootPart")
        local distance=root and localRoot and (root.Position-localRoot.Position).Magnitude or 0
        argusText("Target State: "..status, x, y+68, 13, argusStatusColor(status))
        argusLiveText("debug_target", "Target: "..(target and target.Name or "None"), x, y+92, 12)
        argusLiveText("debug_distance", string.format("Distance: %.1f",distance), x, y+115, 12)
        argusLiveText("debug_fov", "FOV: "..tostring(_G.TargetAssistFOVRadius), x, y+138, 12)
        argusLiveText("debug_los", "LOS: "..argusBoolText(target and target.Character and hasLineOfSight(getTargetPart(target.Character)) or false), x, y+161, 12)
        argusLiveText("debug_selection", "Selection: ".._G.ArgusTargetSelectionMode, x, y+184, 12)
        argusLiveText("debug_perf", "ESP Performance: "..argusBoolText(_G.ArgusESPPerformance), x, y+207, 12)
        argusLiveText("debug_rate", "Update Rate: "..tostring(_G.ArgusESPUpdateRate), x, y+230, 12)
        argusLiveText("debug_humanized", "Humanized: "..argusBoolText(_G.TargetAssistHumanizedAim), x, y+253, 12)
        argusText("No gameplay state is changed by Debug Mode.", x, y+285, 10, Color3.fromRGB(150,150,150))
    end

    argusRenderSliders()
end

local function argusPointInBox(point, box)
    return point.X >= box.Position.X and point.X <= box.Position.X+box.Size.X
        and point.Y >= box.Position.Y and point.Y <= box.Position.Y+box.Size.Y
end

local ArgusInput = UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == _G.ArgusUIKey then
        if _G.ArgusPrivacyCurtain then
            _G.ArgusPrivacyCurtain = false
        end
        ArgusUI.Open = not ArgusUI.Open
        ArgusUI.Anim.TargetOpen = ArgusUI.Open and 1 or 0
        if ArgusUI.Open then argusRebuildBody() end
        return
    end

    if input.UserInputType == Enum.UserInputType.MouseButton1 and ArgusUI.Open then
        local mouse=UserInputService:GetMouseLocation()
        if mouse.Y >= ArgusUI.Y and mouse.Y <= ArgusUI.Y+48 and mouse.X >= ArgusUI.X and mouse.X <= ArgusUI.X+ArgusUI.W then
            ArgusUI.Dragging=true
            ArgusUI.DragOffset=mouse-Vector2.new(ArgusUI.X,ArgusUI.Y)
            return
        end
        for _,tab in ipairs(ArgusTabs) do
            local t=ArgusDraw.TabTexts[tab]
            if t and mouse.X >= t.Position.X-4 and mouse.X <= t.Position.X+92 and mouse.Y >= t.Position.Y-4 and mouse.Y <= t.Position.Y+22 then
                ArgusUI.Tab=tab
                argusRebuildBody()
                return
            end
        end
        for _,slider in ipairs(ArgusDraw.Sliders) do
            if mouse.X>=slider.X-5 and mouse.X<=slider.X+slider.W+5 and mouse.Y>=slider.Y+15 and mouse.Y<=slider.Y+38 then
                ArgusUI.ActiveSlider=slider
                argusSetSlider(slider,mouse.X)
                return
            end
        end
        for _,button in ipairs(ArgusDraw.Buttons) do
            if argusPointInBox(mouse,button.Box) then
                ArgusUI.Anim.Pressed=button
                button.Callback()
                return
            end
        end
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        ArgusUI.Dragging=false
        ArgusUI.ActiveSlider=nil
        ArgusUI.Anim.Pressed=nil
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
    local mouse=UserInputService:GetMouseLocation()
    if ArgusUI.Dragging then
        local oldX, oldY = ArgusUI.X, ArgusUI.Y
        ArgusUI.X=math.clamp(mouse.X-ArgusUI.DragOffset.X, 4, math.max(4, Camera.ViewportSize.X-ArgusUI.W-4))
        ArgusUI.Y=math.clamp(mouse.Y-ArgusUI.DragOffset.Y, 4, math.max(4, Camera.ViewportSize.Y-ArgusUI.H-4))
        local dx, dy = ArgusUI.X-oldX, ArgusUI.Y-oldY
        if dx ~= 0 or dy ~= 0 then
            for _, obj in ipairs(ArgusDraw.BodyTexts) do
                obj.Position = obj.Position + Vector2.new(dx, dy)
            end
            for _, button in ipairs(ArgusDraw.Buttons) do
                button.Box.Position = button.Box.Position + Vector2.new(dx, dy)
                button.Text.Position = button.Text.Position + Vector2.new(dx, dy)
            end
            for _, slider in ipairs(ArgusDraw.Sliders) do
                slider.Back.Position = slider.Back.Position + Vector2.new(dx, dy)
                slider.Fill.Position = slider.Fill.Position + Vector2.new(dx, dy)
                slider.Text.Position = slider.Text.Position + Vector2.new(dx, dy)
                slider.X = slider.X + dx
                slider.Y = slider.Y + dy
            end
        end
    elseif ArgusUI.ActiveSlider then
        argusSetSlider(ArgusUI.ActiveSlider,mouse.X)
    end
end)

local function argusUpdateTargetWeights()
    -- Selection weighting is exposed as a scoring configuration for future target modes.
    -- Current selection remains compatible with the original closest-to-crosshair behavior.
    if _G.ArgusTargetSelectionMode == "Distance" then
        _G.ArgusWeightCrosshair=0.25
        _G.ArgusWeightDistance=1.0
        _G.ArgusWeightHealth=0.0
    elseif _G.ArgusTargetSelectionMode == "Health" then
        _G.ArgusWeightCrosshair=0.25
        _G.ArgusWeightDistance=0.1
        _G.ArgusWeightHealth=1.0
    elseif _G.ArgusTargetSelectionMode == "Balanced" then
        _G.ArgusWeightCrosshair=1.0
        _G.ArgusWeightDistance=0.35
        _G.ArgusWeightHealth=0.15
    else
        _G.ArgusWeightCrosshair=1.0
        _G.ArgusWeightDistance=0.15
        _G.ArgusWeightHealth=0.0
    end
end

RunService.RenderStepped:Connect(function(dt)
    ArgusUI.FrameCount += 1
    dt=math.clamp(tonumber(dt) or 1/60,0,0.1)
    argusUIAnim(dt)
    local now=os.clock()
    if now-ArgusUI.FPSClock >= 0.5 then
        ArgusUI.FPS=ArgusUI.FrameCount/(now-ArgusUI.FPSClock)
        ArgusUI.FrameCount=0
        ArgusUI.FPSClock=now
    end

    argusUpdateTargetWeights()

    if ArgusUI.Open then
        local mx,my=ArgusUI.X,ArgusUI.Y
        local anim=ArgusUI.Anim
        local alpha=math.clamp(anim.Alpha,0,1)
        local slide=(1-anim.Open)*18
        ArgusDraw.Shadow.Position=Vector2.new(mx+4+slide,my+5+slide)
        ArgusDraw.Shadow.Size=Vector2.new(ArgusUI.W,ArgusUI.H)
        ArgusDraw.Shadow.Color=Color3.fromRGB(0,0,0)
        ArgusDraw.Shadow.Transparency=0.72*alpha
        ArgusDraw.Shadow.Visible=alpha>0.01

        ArgusDraw.Panel.Position=Vector2.new(mx+slide,my+slide)
        ArgusDraw.Panel.Size=Vector2.new(ArgusUI.W,ArgusUI.H)
        ArgusDraw.Panel.Color=Color3.fromRGB(7,9,13)
        ArgusDraw.Panel.Transparency=alpha
        ArgusDraw.Panel.Visible=alpha>0.01

        ArgusDraw.Header.Position=Vector2.new(mx+slide,my+slide)
        ArgusDraw.Header.Size=Vector2.new(ArgusUI.W,48)
        ArgusDraw.Header.Color=Color3.fromRGB(14,20,27)
        ArgusDraw.Header.Transparency=alpha
        ArgusDraw.Header.Visible=alpha>0.01

        ArgusDraw.Accent.Position=Vector2.new(mx,my+46)
        ArgusDraw.Accent.Size=Vector2.new(ArgusUI.W,2)
        ArgusDraw.Accent.Color=_G.ArgusUIAccent
        ArgusDraw.Accent.Visible=true

        ArgusDraw.TabLine.Position=Vector2.new(mx+slide,my+70+slide)
        ArgusDraw.TabLine.Size=Vector2.new(ArgusUI.W,1)
        ArgusDraw.TabLine.Color=Color3.fromRGB(44,65,79)
        ArgusDraw.TabLine.Transparency=alpha
        ArgusDraw.TabLine.Visible=alpha>0.01
        local indicatorWidth=ArgusUI.W/#ArgusTabs
        ArgusDraw.TabIndicator.Position=Vector2.new(mx+anim.Tab*(#ArgusTabs-1)*indicatorWidth+slide,my+69+slide)
        ArgusDraw.TabIndicator.Size=Vector2.new(indicatorWidth,2)
        ArgusDraw.TabIndicator.Color=_G.ArgusUIAccent
        ArgusDraw.TabIndicator.Transparency=alpha
        ArgusDraw.TabIndicator.Visible=alpha>0.01

        ArgusDraw.Title.Text="CRESCENT HUB"
        ArgusDraw.Title.Position=Vector2.new(mx+18+slide,my+9+slide)
        ArgusDraw.Title.Transparency=alpha
        ArgusDraw.Title.Visible=alpha>0.01
        ArgusDraw.Title.Color=_G.ArgusUIAccent
        ArgusDraw.Subtitle.Text="MONOCHROME INTERFACE"
        ArgusDraw.Subtitle.Position=Vector2.new(mx+82+slide,my+13+slide)
        ArgusDraw.Subtitle.Transparency=alpha
        ArgusDraw.Subtitle.Visible=alpha>0.01

        local tabWidth=ArgusUI.W/#ArgusTabs
        for i,tab in ipairs(ArgusTabs) do
            local t=ArgusDraw.TabTexts[tab]
            t.Text=tab
            t.Position=Vector2.new(mx+(i-1)*tabWidth+8+slide,my+54+slide)
            t.Color=(ArgusUI.Tab==tab) and _G.ArgusUIAccent or Color3.fromRGB(174,190,201)
            t.Transparency=alpha
            t.Visible=alpha>0.01
        end

        ArgusDraw.Status.Text="STATUS: "..argusGetTargetStatus()
        ArgusDraw.Status.Position=Vector2.new(mx+18+slide,my+ArgusUI.H-32+slide)
        ArgusDraw.Status.Color=argusStatusColor(argusGetTargetStatus())
        ArgusDraw.Status.Transparency=alpha
        ArgusDraw.Status.Visible=alpha>0.01

        ArgusDraw.Footer.Text="RightShift: UI"
        ArgusDraw.Footer.Position=Vector2.new(mx+ArgusUI.W-225+slide,my+ArgusUI.H-32+slide)
        ArgusDraw.Footer.Transparency=alpha
        ArgusDraw.Footer.Visible=alpha>0.01

        if ArgusUI.Toast and os.clock()<ArgusUI.ToastUntil then
            ArgusDraw.Status.Text=ArgusUI.Toast
            ArgusDraw.Status.Color=_G.ArgusUIAccent
        elseif ArgusUI.Toast then
            ArgusUI.Toast=nil
        end

        -- Body / control transition
        local bodyAlpha=math.clamp(anim.Alpha,0,1)
        local bodyOffset=(1-anim.Open)*10
        for _,obj in ipairs(ArgusDraw.BodyTexts) do
            obj.Transparency=bodyAlpha
            obj.Position=Vector2.new(obj.Position.X,obj.Position.Y)
            obj.Visible=bodyAlpha>0.01
        end
        for _,button in ipairs(ArgusDraw.Buttons) do
            local mouse=UserInputService:GetMouseLocation()
            local hover=argusPointInBox(mouse,button.Box)
            local pressed=(ArgusUI.Anim.Pressed==button)
            button.Box.Color=hover and Color3.fromRGB(42,42,42) or Color3.fromRGB(28,28,28)
            button.Box.Transparency=pressed and 0.78 or bodyAlpha
            button.Text.Transparency=bodyAlpha
            button.Text.Position=Vector2.new(button.Box.Position.X+10,button.Box.Position.Y+(pressed and 7 or 6))
            button.Box.Visible=bodyAlpha>0.01
            button.Text.Visible=bodyAlpha>0.01
        end
        for _,slider in ipairs(ArgusDraw.Sliders) do
            slider.Back.Transparency=bodyAlpha
            slider.Fill.Transparency=bodyAlpha
            slider.Text.Transparency=bodyAlpha
        end

        local toastAlpha=math.clamp(ArgusUI.Anim.Toast*bodyAlpha,0,1)
        if ArgusUI.Toast and toastAlpha>0.01 then
            local tx=mx+ArgusUI.W-190
            local ty=my+54+ArgusUI.Anim.ToastY
            ArgusDraw.ToastBox.Position=Vector2.new(tx,ty)
            ArgusDraw.ToastBox.Size=Vector2.new(172,30)
            ArgusDraw.ToastBox.Color=Color3.fromRGB(24,24,24)
            ArgusDraw.ToastBox.Transparency=toastAlpha
            ArgusDraw.ToastBox.Visible=true
            ArgusDraw.ToastText.Text=tostring(ArgusUI.Toast)
            ArgusDraw.ToastText.Position=Vector2.new(tx+10,ty+8)
            ArgusDraw.ToastText.Color=_G.ArgusUIAccent
            ArgusDraw.ToastText.Transparency=toastAlpha
            ArgusDraw.ToastText.Visible=true
        else
            ArgusDraw.ToastBox.Visible=false
            ArgusDraw.ToastText.Visible=false
        end
    else
        ArgusDraw.Shadow.Visible=false
        ArgusDraw.Panel.Visible=false
        ArgusDraw.Header.Visible=false
        ArgusDraw.Accent.Visible=false
        ArgusDraw.TabLine.Visible=false
        ArgusDraw.TabIndicator.Visible=false
        ArgusDraw.ToastBox.Visible=false
        ArgusDraw.ToastText.Visible=false
        ArgusDraw.Title.Visible=false
        ArgusDraw.Subtitle.Visible=false
        ArgusDraw.Status.Visible=false
        ArgusDraw.Footer.Visible=false
        for _,t in pairs(ArgusDraw.TabTexts) do t.Visible=false end
        for _,obj in ipairs(ArgusDraw.BodyTexts) do
            obj.Visible=false
        end
        for _,button in ipairs(ArgusDraw.Buttons) do
            button.Box.Visible=false
            button.Text.Visible=false
        end
        for _,slider in ipairs(ArgusDraw.Sliders) do
            slider.Back.Visible=false
            slider.Fill.Visible=false
            slider.Text.Visible=false
        end
    end

    argusUpdateLivePanel()
    if ArgusUI.Open then
        argusRenderSliders()
    end
end)

argusRebuildBody()
argusToast("Crescent Hub ready")


-- ============================================================
-- Stability / Performance / Recovery Layer
-- ============================================================
_G.ArgusSafetyEnabled = true
_G.ArgusAdaptivePerformance = true
_G.ArgusTargetCacheLifetime = 0.08
_G.ArgusStateWatchdog = true
_G.ArgusConfigAutoRepair = true
_G.ArgusDebugMonitor = false

local ArgusRuntime = {
    FPS=60,
    FrameEMA=60,
    TargetCache=nil,
    TargetCacheAt=0,
    LastCamera=Camera,
    LastCharacter=nil,
    Connections={},
    LastWatchdog=0,
}

local function argusSafeNumber(v, default, minv, maxv)
    v=tonumber(v)
    if not v or v~=v then return default end
    return math.clamp(v,minv,maxv)
end

_G.ArgusTargetCacheEnabled = (_G.ArgusTargetCacheEnabled ~= false)

local function argusValidateConfig()
    if not _G.ArgusConfigAutoRepair then return end
    _G.TargetAssistHeadLockStrength=argusSafeNumber(_G.TargetAssistHeadLockStrength,100,0,100)
    _G.TargetAssistHeadLockThreshold=argusSafeNumber(_G.TargetAssistHeadLockThreshold,65,0,100)
    _G.TargetAssistHeadLockGrace=argusSafeNumber(_G.TargetAssistHeadLockGrace,0.12,0,0.5)
    _G.TargetAssistFOVRadius=argusSafeNumber(_G.TargetAssistFOVRadius,180,1,2000)
    _G.TargetAssistMaxDistance=argusSafeNumber(_G.TargetAssistMaxDistance,500,0,10000)
    _G.TargetAssistTargetSwitchDelay=argusSafeNumber(_G.TargetAssistTargetSwitchDelay,0.15,0,2)
    _G.TargetAssistMinimumLockTime=argusSafeNumber(_G.TargetAssistMinimumLockTime,0.12,0,3)
    _G.TargetAssistReacquireDelay=argusSafeNumber(_G.TargetAssistReacquireDelay,0.12,0,2)
end
argusValidateConfig()

local function argusGetCamera()
    local current=workspace.CurrentCamera
    if current and current~=Camera then
        Camera=current
        ArgusRuntime.LastCamera=current
        if TargetAssistFOV then
            TargetAssistFOV.Radius=_G.TargetAssistFOVRadius
        end
    end
    return Camera
end

local function argusGetCharacterState()
    local character=LocalPlayer.Character
    if character~=ArgusRuntime.LastCharacter then
        ArgusRuntime.LastCharacter=character
        resetTargetHeadState()
        if TargetAssist then
            TargetAssist.CurrentTarget=nil
            TargetAssist.ToggleState=false
        end
    end
    return character
end

local function argusUpdateFPS(dt)
    if dt and dt>0 then
        local instant=1/dt
        ArgusRuntime.FrameEMA=ArgusRuntime.FrameEMA*0.92+instant*0.08
        ArgusRuntime.FPS=math.clamp(ArgusRuntime.FrameEMA,1,240)
        -- Publish a lightweight FPS sample for UI quality-of-life decisions.
        _G.ArgusRuntimeFPS = ArgusRuntime.FPS
    end
end

local function argusGetPerformanceTier()
    if not _G.ArgusAdaptivePerformance then return 3 end
    local fps=ArgusRuntime.FPS
    if fps>=55 then return 3 end
    if fps>=40 then return 2 end
    if fps>=30 then return 1 end
    return 0
end

argusCachedBestTarget = function()
    if _G.ArgusTargetCacheEnabled == false then
        local player = getBestTarget()
        ArgusRuntime.TargetCache = player
        ArgusRuntime.TargetCacheAt = os.clock()
        return player
    end

    local now=os.clock()
    local lifetime=argusSafeNumber(_G.ArgusTargetCacheLifetime,0.08,0.02,0.3)
    if ArgusRuntime.TargetCache and now-ArgusRuntime.TargetCacheAt<=lifetime then
        local player=ArgusRuntime.TargetCache
        if player and player.Parent==Players and targetAssistIsValid(player) then
            return player
        end
    end
    local player=getBestTarget()
    ArgusRuntime.TargetCache=player
    ArgusRuntime.TargetCacheAt=now
    return player
end

local function argusWatchdog()
    if not _G.ArgusStateWatchdog then return end
    local now=os.clock()
    if now-ArgusRuntime.LastWatchdog<0.5 then return end
    ArgusRuntime.LastWatchdog=now
    argusValidateConfig()
    argusGetCamera()
    argusGetCharacterState()
    if TargetAssist.CurrentTarget and not targetAssistIsValid(TargetAssist.CurrentTarget) then
        TargetAssist.CurrentTarget=nil
        resetTargetHeadState()
    end
end

RunService:BindToRenderStep('NexusArgusRuntimeGuard',Enum.RenderPriority.First.Value,function(dt)
    argusUpdateFPS(dt)
    argusWatchdog()
end)

-- Camera / viewport changes invalidate cached target scoring.
workspace:GetPropertyChangedSignal('CurrentCamera'):Connect(function()
    ArgusRuntime.TargetCache=nil
    argusGetCamera()
end)

-- Player lifecycle invalidates target cache without rebuilding the whole ESP system.
Players.PlayerAdded:Connect(function()
    ArgusRuntime.TargetCache=nil
end)
Players.PlayerRemoving:Connect(function(player)
    if ArgusRuntime.TargetCache==player then
        ArgusRuntime.TargetCache=nil
        if TargetAssist.CurrentTarget==player then
            TargetAssist.CurrentTarget=nil
            resetTargetHeadState()
        end
    end
end)

-- ============================================================
-- FINAL OPTIMIZATION LAYER
-- Target/LOS cache, performance budgets, cleanup, config repair,
-- desktop input safety, camera recovery, state telemetry and fail-safe.
-- ============================================================
_G.ArgusLOSCacheLifetime = 0.055
_G.ArgusTargetSearchInterval = 0.035
_G.ArgusESPAdaptive = true
_G.ArgusESPMinUpdateRate = 20
_G.ArgusESPMaxUpdateRate = 60
_G.ArgusCameraRecovery = true
_G.ArgusFailSafe = true
_G.ArgusRuntimeTelemetry = true

local ArgusFinal = {
    LOS = {},
    Target = nil,
    TargetAt = 0,
    LastSearch = 0,
    ESPAccumulator = 0,
    LastUIRefresh = 0,
    LastCameraCFrame = nil,
    LastCameraType = nil,
    LastViewportSize = nil,
    LastGoodCharacter = nil,
    Connections = {},
    Errors = 0,
}

local function finalSafeNumber(v, d, lo, hi)
    v = tonumber(v)
    if not v or v ~= v then return d end
    return math.clamp(v, lo, hi)
end

local function finalValidate()
    if not _G.ArgusConfigAutoRepair then return end
    _G.ArgusLOSCacheLifetime = finalSafeNumber(_G.ArgusLOSCacheLifetime,0.055,0.01,0.25)
    _G.ArgusTargetSearchInterval = finalSafeNumber(_G.ArgusTargetSearchInterval,0.035,0.01,0.25)
    _G.ArgusESPMinUpdateRate = finalSafeNumber(_G.ArgusESPMinUpdateRate,20,10,60)
    _G.ArgusESPMaxUpdateRate = finalSafeNumber(_G.ArgusESPMaxUpdateRate,60,20,120)
    if _G.ArgusESPMinUpdateRate > _G.ArgusESPMaxUpdateRate then
        _G.ArgusESPMinUpdateRate, _G.ArgusESPMaxUpdateRate = _G.ArgusESPMaxUpdateRate, _G.ArgusESPMinUpdateRate
    end
end

local function finalInvalidateTarget()
    ArgusFinal.Target = nil
    ArgusFinal.TargetAt = 0
    ArgusRuntime.TargetCache = nil
    ArgusRuntime.TargetCacheAt = 0
end

-- Short LOS cache: enough to reduce repeated raycasts while still reacting quickly to walls.
local function finalLOS(targetPart)
    if not _G.TargetAssistWallCheck then return true end
    if not targetPart or not targetPart.Parent then return false end
    local now = os.clock()
    local entry = ArgusFinal.LOS[targetPart]
    if entry and now - entry.t <= _G.ArgusLOSCacheLifetime then
        return entry.ok
    end
    local ok = hasLineOfSight(targetPart)
    ArgusFinal.LOS[targetPart] = {t=now, ok=ok}
    return ok
end

-- Replace only the expensive LOS decision with the bounded cache.
local _originalTargetAssistIsValid = targetAssistIsValid
targetAssistIsValid = function(player)
    local wallCheck = _G.TargetAssistWallCheck
    _G.TargetAssistWallCheck = false
    local valid = _originalTargetAssistIsValid(player)
    _G.TargetAssistWallCheck = wallCheck
    if not valid then return false end

    local character = player and player.Character
    local part = character and getTargetPart(character)
    return part and finalLOS(part) or false
end

finalAdaptiveRate = function()
    if not _G.ArgusESPAdaptive then return _G.ArgusESPUpdateRate end
    local fps = ArgusRuntime.FPS or 60
    local maxRate = finalSafeNumber(_G.ArgusESPMaxUpdateRate,60,20,120)
    local minRate = finalSafeNumber(_G.ArgusESPMinUpdateRate,20,10,60)
    if fps >= 55 then return math.min(maxRate,60) end
    if fps >= 45 then return math.max(minRate,50) end
    if fps >= 35 then return math.max(minRate,35) end
    return minRate
end

-- Camera recovery: only repairs invalid/current-camera transitions; it does not fight normal camera control.
local function finalCameraGuard()
    if not _G.ArgusCameraRecovery then return end
    local cam = workspace.CurrentCamera
    if not cam then return end
    Camera = cam
    if Camera.CFrame.X ~= Camera.CFrame.X then
        if ArgusFinal.LastCameraCFrame then
            Camera.CFrame = ArgusFinal.LastCameraCFrame
        end
        return
    end
    ArgusFinal.LastCameraCFrame = Camera.CFrame
    ArgusFinal.LastCameraType = Camera.CameraType
end

-- Connection-safe cleanup registry for every new connection created by this layer.
local function finalTrackConnection(connection)
    if connection then table.insert(ArgusFinal.Connections, connection) end
    return connection
end

finalValidate()

finalTrackConnection(workspace:GetPropertyChangedSignal('CurrentCamera'):Connect(function()
    finalInvalidateTarget()
    ArgusFinal.LOS = {}
    finalCameraGuard()
end))

finalTrackConnection(RunService.RenderStepped:Connect(function()
    local cam = workspace.CurrentCamera
    if cam and cam.ViewportSize ~= ArgusFinal.LastViewportSize then
        ArgusFinal.LastViewportSize = cam.ViewportSize
        finalInvalidateTarget()
        ArgusFinal.LOS = {}
    end
end))

finalTrackConnection(LocalPlayer.CharacterAdded:Connect(function(character)
    finalInvalidateTarget()
    ArgusFinal.LOS = {}
    ArgusFinal.LastGoodCharacter = character
end))

finalTrackConnection(LocalPlayer.CharacterRemoving:Connect(function()
    finalInvalidateTarget()
    ArgusFinal.LOS = {}
end))

finalTrackConnection(Players.PlayerRemoving:Connect(function(player)
    ArgusFinal.LOS = {}
    if ArgusFinal.Target == player then finalInvalidateTarget() end
end))

RunService:BindToRenderStep('NexusArgusFinalGuard',Enum.RenderPriority.First.Value+1,function(dt)
    finalValidate()
    finalCameraGuard()
    ArgusFinal.ESPAccumulator += math.max(dt,0)

    local now = os.clock()
    local searchInterval = _G.ArgusTargetSearchInterval
    local fps = ArgusRuntime.FPS or 60
    if fps < 30 then
        searchInterval = math.max(searchInterval, 0.08)
    elseif fps < 45 then
        searchInterval = math.max(searchInterval, 0.05)
    end

    if now - ArgusFinal.LastSearch >= searchInterval then
        ArgusFinal.LastSearch = now
        if isAimActive() then
            local candidate = argusCachedBestTarget()
            if candidate then ArgusFinal.Target = candidate; ArgusFinal.TargetAt = now end
        else
            ArgusFinal.Target = nil
        end
    end

    if _G.ArgusRuntimeTelemetry then
        _G.ArgusRuntimeFPS = ArgusRuntime.FPS
        _G.ArgusRuntimePerformanceTier = argusGetPerformanceTier()
        _G.ArgusESPEffectiveRate = finalAdaptiveRate()
        _G.ArgusTargetState = TargetAssist.State
        _G.ArgusHeadState = TargetAssist.HeadState
    end
end)

-- Lightweight emergency protection: never leave a stale lock after character/target removal.
RunService.Heartbeat:Connect(function()
    if not _G.ArgusFailSafe then return end
    local target = TargetAssist.CurrentTarget
    if target and (target.Parent ~= Players or not target.Character) then
        TargetAssist.CurrentTarget = nil
        TargetAssist.State = 'Reacquiring'
        TargetAssist.ReacquireAt = os.clock() + finalSafeNumber(_G.TargetAssistReacquireDelay,0.12,0,2)
        resetTargetHeadState()
        finalInvalidateTarget()
    end
end)

-- ============================================================
-- END FINAL OPTIMIZATION LAYER
-- ============================================================


-- ============================================================
-- MODULE HEALTH MONITOR / 每秒自動檢測 ESP、Target Assist、Head Lock
-- 只在功能已開啟時進行檢測；不會強制打開使用者關閉的功能。
-- ============================================================
_G.ArgusModuleHealth = _G.ArgusModuleHealth or {
    ESP = "Unknown",
    TargetAssist = "Unknown",
    HeadLock = "Unknown",
    LastCheck = 0,
    ESPRepairs = 0,
    AimRepairs = 0,
    HeadRepairs = 0,
    LastError = nil,
}

local ArgusModuleHealth = _G.ArgusModuleHealth

local function argusHealthEligiblePlayer(player)
    if not player or player == LocalPlayer then return false end
    if isSameTeam(player) then return false end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local head = character and character:FindFirstChild("Head")
    return character and humanoid and root and head and humanoid.Health > 0
end

local function argusCheckESPHealth()
    if not _G.ESPEnabled then
        ArgusModuleHealth.ESP = "Disabled"
        return
    end

    local eligible = 0
    local initialized = 0
    local missing = 0

    for _, player in ipairs(Players:GetPlayers()) do
        if argusHealthEligiblePlayer(player) then
            eligible += 1
            local esp = ESPObjects[player]
            if not esp then
                missing += 1
                createESP(player)
                esp = ESPObjects[player]
                ArgusModuleHealth.ESPRepairs += 1
            end

            if esp then
                initialized += 1
                -- Highlight 是 Instance 型視覺元件；若使用者開啟 Highlight，確保它重新掛載。
                if _G.HighlightESP then
                    updateHighlight(player, player.Character)
                end
            end
        end
    end

    if eligible == 0 then
        ArgusModuleHealth.ESP = "Ready_NoTargets"
    elseif initialized >= eligible and missing == 0 then
        ArgusModuleHealth.ESP = "Healthy"
    else
        ArgusModuleHealth.ESP = "Repairing"
    end
end

local function argusCheckTargetAssistHealth()
    if not _G.TargetAssistEnabled then
        ArgusModuleHealth.TargetAssist = "Disabled"
        ArgusModuleHealth.HeadLock = "Disabled"
        return
    end

    -- 功能已開啟但尚未按下右鍵/觸控：這不是故障。
    local active = false
    local okActive, resultActive = pcall(isAimActive)
    if okActive then active = resultActive == true end

    if not active then
        ArgusModuleHealth.TargetAssist = "Ready_WaitingInput"
        ArgusModuleHealth.HeadLock = "Ready_WaitingInput"
        return
    end

    local target = TargetAssist.CurrentTarget
    if target and targetAssistIsValid(target) then
        ArgusModuleHealth.TargetAssist = "Healthy"
    else
        -- 每秒檢測時主動補一次目標取得，避免主 RenderStep 因暫時性錯誤一直停在 Searching。
        local okTarget, candidate = pcall(getBestTarget)
        if okTarget and candidate and targetAssistIsValid(candidate) then
            TargetAssist.CurrentTarget = candidate
            TargetAssist.LockStartedAt = os.clock()
            TargetAssist.LastSwitchAt = os.clock()
            TargetAssist.State = "Locked"
            TargetAssist.ReacquireAt = 0
            ArgusModuleHealth.AimRepairs += 1
            ArgusModuleHealth.TargetAssist = "Repaired"
        else
            ArgusModuleHealth.TargetAssist = "Ready_NoTarget"
        end
    end

    -- Head Lock 健康檢測：Auto/Head 模式需要 Head 存在；沒有目標時不判定為故障。
    local targetNow = TargetAssist.CurrentTarget
    if not targetNow or not targetNow.Character then
        ArgusModuleHealth.HeadLock = "Ready_NoTarget"
        return
    end

    local head = targetNow.Character:FindFirstChild("Head")
    if not head then
        ArgusModuleHealth.HeadLock = "Repairing_NoHead"
        resetTargetHeadState()
        ArgusModuleHealth.HeadRepairs += 1
        return
    end

    local requestedPart = _G.TargetAssistPart
    local wantsHead = requestedPart == "Head"
        or requestedPart == "Auto"
        or _G.TargetAssistHeadLockPreferred == true

    if not wantsHead then
        ArgusModuleHealth.HeadLock = "Ready_BodyMode"
        return
    end

    local state = TargetAssist.HeadState
    if state == "HeadLock" or state == "HeadGrace" then
        ArgusModuleHealth.HeadLock = "Healthy"
    else
        -- 不強行改相機；只把 Head Lock 狀態重置，交給下一個 RenderStep 正常重新取得。
        if state ~= "HeadCandidate" then
            resetTargetHeadState()
            ArgusModuleHealth.HeadRepairs += 1
        end
        ArgusModuleHealth.HeadLock = "Reacquiring"
    end
end

local function argusRunModuleHealthCheck()
    local ok, err = pcall(function()
        argusCheckESPHealth()
        argusCheckTargetAssistHealth()
    end)

    ArgusModuleHealth.LastCheck = os.clock()
    if not ok then
        ArgusModuleHealth.LastError = tostring(err)
        ArgusModuleHealth.ESP = "Error"
        ArgusModuleHealth.TargetAssist = "Error"
        ArgusModuleHealth.HeadLock = "Error"
    else
        ArgusModuleHealth.LastError = nil
    end

    -- 提供給 Dashboard / Debug / 手機面板使用。
    _G.ArgusESPHealth = ArgusModuleHealth.ESP
    _G.ArgusTargetAssistHealth = ArgusModuleHealth.TargetAssist
    _G.ArgusHeadLockHealth = ArgusModuleHealth.HeadLock
end

-- Show the shared Crescent notice once when the module health monitor catches a runtime/API failure.
-- Avoid spamming the screen every second if the same issue persists.
local ArgusSupportNoticeShownForError = false
local ArgusHealthAccumulator = 0
RunService.Heartbeat:Connect(function(dt)
    ArgusHealthAccumulator += math.max(dt, 0)
    if ArgusHealthAccumulator < 1 then return end
    ArgusHealthAccumulator = 0
    argusRunModuleHealthCheck()
    if ArgusModuleHealth.LastError then
        if not ArgusSupportNoticeShownForError then
            ArgusSupportNoticeShownForError = true
            local showNotice = _G.__ARGUS_SHOW_SUPPORT_NOTICE
            if type(showNotice) == "function" then
                pcall(showNotice)
            end
        end
    else
        ArgusSupportNoticeShownForError = false
    end
end)

-- 啟動後第一秒立即完成第一次檢查，而不是等使用者操作。
task.defer(function()
    task.wait(1)
    argusRunModuleHealthCheck()
end)


-- Loader handshake: set only after the entrypoint reaches its final initialization section.
_G.__ARGUS_INIT_STATUS = "ready"
