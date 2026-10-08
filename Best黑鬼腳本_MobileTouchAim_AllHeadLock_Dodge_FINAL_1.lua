-- ARGUS
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

local RunService = game:GetService("RunService")
-- Client-only guard: ESP / Aim / Head Lock / UI / health monitor all run locally.
if not RunService:IsClient() then
    return
end

-- Prevent duplicate runtime instances from stacking RenderStep/Input connections.
-- The existing running instance remains authoritative.
if _G.ArgusRuntimeLoaded then
    return
end
_G.ArgusRuntimeLoaded = true

local Players = game:GetService("Players")
local Camera = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    return
end

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
            instance.TextTransparency = 1 - transparency
            instance.TextStrokeTransparency = props.Outline and (1 - transparency) or 1
            instance.TextStrokeColor3 = props.OutlineColor or Color3.new(0,0,0)
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
    or game:GetService("UserInputService").TouchEnabled

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

local function isSameTeam(player, scope)
    local enabled = scope == "Target"
        and _G.TargetAssistTeamCheck
        or _G.TeamCheck

    if not enabled then return false end
    if not LocalPlayer.Team or not player.Team then return false end
    return LocalPlayer.Team == player.Team
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
        esp.Skeleton[i] = newLine()
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
    if _G.TargetAssistVisualsHidden and not (_G.ESPEnabled and _G.SkeletonESP) then
        return
    end
    if not argusShouldUpdateESP() then
        return
    end
    for _, player in ipairs(Players:GetPlayers()) do
        
        if isSameTeam(player) then
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
                        esp.Skeleton[i].Visible = true
                        esp.Skeleton[i].Color = Color3.fromRGB(0, 255, 0)
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

-- 可選：
-- "Head" / "UpperTorso" / "LowerTorso" / "HumanoidRootPart" / "Auto"
_G.TargetAssistPart = "Head"

-- 數值越大，鏡頭轉向越快；數值越小，轉向越慢。
_G.TargetAssistSmoothness = 8

-- 手機 Aimbot 強度（僅手機觸控模式使用）
-- 100 = 強鎖；數值越低，鏡頭跟隨越柔和。
_G.MobileAimStrength = 100
-- 手機鎖頭強度：0 = 以身體為主；100 = 優先鎖頭。
_G.MobileHeadLockStrength = 100
-- 手機鎖頭進階判定
_G.MobileHeadLockThreshold = 65
_G.MobileHeadLockGrace = 0.12
_G.MobileHeadLockSwitchMargin = 0.10
_G.MobileHeadLockReacquireDelay = 0.08
_G.MobileHeadLockPreferred = true
_G.MobileHeadLockState = "Body"

-- 最大鎖定距離；0 = 不限制距離。
_G.TargetAssistMaxDistance = 500

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
_G.TargetAssistFOVColor = Color3.fromRGB(255,255,255)
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
    local rawVelocity = targetPart.AssemblyLinearVelocity
    local velocity = rawVelocity

    -- Smooth target velocity to reduce prediction noise from animation/network jitter.
    local previousVelocity = ArgusRuntime.TargetVelocity[targetPart]
    if previousVelocity then
        velocity = previousVelocity:Lerp(rawVelocity, 0.35)
    end
    ArgusRuntime.TargetVelocity[targetPart] = velocity

    if not _G.TargetAssistPredictionEnabled then
        return position + _G.TargetAssistOffset
    end

    local predictionTime = math.max(
        0,
        tonumber(_G.TargetAssistPredictionTime) or 0
    )

    local projectileTime = 0
    local projectileSpeed = tonumber(_G.TargetAssistProjectileSpeed) or 0
    if projectileSpeed > 0 then
        local distance = (Camera.CFrame.Position - targetPart.Position).Magnitude
        projectileTime = distance / projectileSpeed
    end

    -- Avoid double-leading when both movement and projectile prediction are enabled.
    -- Use the stronger estimate, then clamp it to prevent extreme over-leading.
    local leadTime = 0
    if _G.TargetAssistMovementPrediction then
        leadTime = math.max(leadTime, predictionTime)
    end
    if projectileSpeed > 0 then
        leadTime = math.max(leadTime, projectileTime)
    end

    local maxPrediction = math.clamp(
        tonumber(_G.TargetAssistMaxPredictionTime) or 0.35,
        0,
        1.5
    )
    leadTime = math.min(leadTime, maxPrediction)
    if leadTime > 0 then
        position += velocity * leadTime
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

    if isSameTeam(player, "Target") then
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
    local crosshairWeight = math.max(0, tonumber(_G.ArgusWeightCrosshair) or 1.0)
    local distanceWeight = math.max(0, tonumber(_G.ArgusWeightDistance) or 0.15)
    local healthWeight = math.max(0, tonumber(_G.ArgusWeightHealth) or 0.0)

    local score
    if mode == "Distance" then
        score = distanceNorm
    elseif mode == "Health" then
        score = healthNorm
    elseif mode == "Balanced" then
        score = (screenNorm * crosshairWeight)
            + (distanceNorm * distanceWeight)
            + (healthNorm * healthWeight)
    else
        -- Crosshair remains the default and therefore keeps the original feel.
        score = screenNorm * crosshairWeight
    end

    return score, screenDistance, worldDistance
end

local function getMobileHeadLockInfo(character, screenCenter)
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

    local threshold = math.clamp(tonumber(_G.MobileHeadLockThreshold) or 65, 0, 100)
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

local function resetMobileHeadState()
    TargetAssist.HeadState = "Body"
    TargetAssist.HeadLostAt = 0
    TargetAssist.HeadLockStartedAt = 0
    TargetAssist.HeadReacquireAt = 0
    TargetAssist.LastHeadScore = math.huge
    _G.MobileHeadLockState = "Body"
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
        if player ~= LocalPlayer and not isSameTeam(player, "Target") then
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
                        if not fovEnabled or screenDistance <= fovRadius then
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

local MobileTouchState = {
    Active = false,
    Touches = {},
}

_G.ArgusMobileAimRegion = _G.ArgusMobileAimRegion or "RightHalf"
_G.ArgusMobileAimTouchMinX = tonumber(_G.ArgusMobileAimTouchMinX) or 0.45

local function isMobileAimTouchAllowed(position)
    if not position then return false end
    if _G.ArgusMobileAimRegion == "FullScreen" then return true end
    local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280,720)
    local minX = math.clamp(tonumber(_G.ArgusMobileAimTouchMinX) or 0.45,0,0.9)
    return position.X >= viewport.X * minX
end

local function isMobileTouchMode()
    local deviceType = _G.ArgusDeviceType or "Desktop"
    local source = _G.ArgusInputSource or "Auto"
    return UserInputService.TouchEnabled
        and (deviceType == "Mobile" or source == "Touch" or (source == "Auto" and deviceType == "Hybrid"))
end

local function isTouchOnMobileUI(position)
    -- 只攔截真正可互動的遊戲 UI，避免 ESP/裝飾用透明 GuiObject 阻擋瞄準觸控。
    local ok, objects = pcall(function()
        return game:GetService("GuiService"):GetGuiObjectsAtPosition(position.X, position.Y)
    end)
    if not ok or not objects then return false end

    for _, object in ipairs(objects) do
        if object and object:IsA("GuiObject") and object.Visible then
            if object.Active
                or object:IsA("GuiButton")
                or object:IsA("TextBox")
                or object:IsA("ScrollingFrame") then
                return true
            end
        end
    end
    return false
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    -- 手機：按住遊戲畫面即可進入 Target Assist。
    -- 不需要 Q / Aim 按鈕；控制面板觸控不會觸發鎖定。
    if input.UserInputType == Enum.UserInputType.Touch and isMobileTouchMode() then
        if not isTouchOnMobileUI(input.Position) and isMobileAimTouchAllowed(input.Position) then
            MobileTouchState.Touches[input] = true
            _G.ArgusTouchStartedAt = _G.ArgusTouchStartedAt or {}
            _G.ArgusTouchStartedAt[input] = os.clock()
            MobileTouchState.Active = true
            _G.ArgusMobileAimActive = true
        end
        return
    end

    if gameProcessed then return end

    if input.KeyCode == Enum.KeyCode.RightShift then
        _G.TargetAssistVisualsHidden = not _G.TargetAssistVisualsHidden
        return
    end

    if input.KeyCode == _G.TargetAssistToggleKey then
        TargetAssist.ToggleState = not TargetAssist.ToggleState
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.Touch then return end
    if not isMobileTouchMode() then return end

    MobileTouchState.Touches[input] = nil
    if _G.ArgusTouchStartedAt then
        _G.ArgusTouchStartedAt[input] = nil
    end
    MobileTouchState.Active = next(MobileTouchState.Touches) ~= nil
    _G.ArgusMobileAimActive = MobileTouchState.Active
end)

local function isAimActive()
    if not _G.TargetAssistEnabled then
        return false
    end

    local deviceType = _G.ArgusDeviceType or "Desktop"
    local source = _G.ArgusInputSource or "Auto"

    -- 手機：只使用「按住遊戲畫面」作為啟動條件，不依賴 Aim/Q 按鍵。
    -- Hybrid 在觸控輸入時也使用相同規則；電腦滑鼠鍵盤邏輯保持原樣。
    if source == "Touch" or (source == "Auto" and deviceType == "Mobile") then
        return MobileTouchState.Active == true
    end

    if source == "Auto" and deviceType == "Hybrid" and MobileTouchState.Active then
        return true
    end

    if source == "MouseKeyboard" and deviceType == "Mobile" then
        return false
    end

    local rightMouse = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
    local toggle = TargetAssist.ToggleState
    local mode = _G.TargetAssistActivationMode

    if mode == "Toggle" then
        return toggle
    elseif mode == "Both" then
        return rightMouse or toggle
    end

    return rightMouse
end

local function updateTargetAssist(dt)
    TargetAssistFOV.Radius = tonumber(_G.TargetAssistFOVRadius) or 180
    TargetAssistFOV.Color = _G.TargetAssistFOVColor
    TargetAssistFOV.Thickness = tonumber(_G.TargetAssistFOVThickness) or 1
    TargetAssistFOV.Filled = _G.TargetAssistFOVFilled
    TargetAssistFOV.Transparency = _G.TargetAssistFOVTransparency
    TargetAssistFOV.Visible = _G.TargetAssistEnabled and _G.TargetAssistFOVEnabled and not _G.TargetAssistVisualsHidden

    if TargetAssistFOV.Visible then
        local viewportSize = Camera.ViewportSize
        TargetAssistFOV.Position = Vector2.new(viewportSize.X * 0.5, viewportSize.Y * 0.5)
    end

    if not isAimActive() then
        TargetAssist.CurrentTarget = nil
        TargetAssist.LockStartedAt = 0
        TargetAssist.ReacquireAt = 0
        TargetAssist.State = "Idle"
        resetMobileHeadState()
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
        resetMobileHeadState()
        return
    end

    local cameraPosition = Camera.CFrame.Position
    local smoothness = math.max(0.01, tonumber(_G.TargetAssistSmoothness) or 8)
    local predictedPosition

    -- 手機專用強度：Aimbot 開啟即為強鎖，滑桿只調整跟隨力度。
    if isMobileTouchMode() then
        local strength = math.clamp(tonumber(_G.MobileAimStrength) or 100, 0, 100) / 100
        -- Non-linear response: low values stay controllable, high values become noticeably stronger.
        local strengthCurve = strength ^ 1.25
        local mobileSmooth = 1.5 + strengthCurve * 48
        smoothness = math.max(smoothness, mobileSmooth)
    end

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
            smoothness = math.max(0.01, tonumber(_G.TargetAssistSecondarySmoothness) or smoothness)
        end
    else
        predictedPosition = getPredictedPosition(targetPart)
    end

    -- 手機鎖頭完整狀態機：Body -> Head Candidate -> Head Lock -> Grace -> Reacquire。
    if isMobileTouchMode() then
        local headInfo = getMobileHeadLockInfo(character, screenCenter)
        local headStrength = math.clamp(tonumber(_G.MobileHeadLockStrength) or 100, 0, 100) / 100
        local nowHead = os.clock()
        local qualified = headInfo and headInfo.Qualified and headStrength > 0
        local grace = math.max(0, tonumber(_G.MobileHeadLockGrace) or 0.12)
        local reacquireDelay = math.max(0, tonumber(_G.MobileHeadLockReacquireDelay) or 0.08)
        local switchMargin = math.clamp(tonumber(_G.MobileHeadLockSwitchMargin) or 0.10, 0, 1)

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
        _G.MobileHeadLockState = TargetAssist.HeadState
    end

    predictedPosition += getHumanizedOffset(dt)
    local targetCFrame = CFrame.lookAt(cameraPosition, predictedPosition)
    local alpha = 1 - math.exp(-smoothness * math.max(dt, 0))

    -- Deadzone prevents tiny one-pixel corrections from producing visible micro-jitter.
    local currentLook = Camera.CFrame.LookVector
    local desiredLook = targetCFrame.LookVector
    local dot = math.clamp(currentLook:Dot(desiredLook), -1, 1)
    local angularError = math.deg(math.acos(dot))
    local deadzone = math.max(0, tonumber(_G.TargetAssistDeadzone) or 0.12)

    if angularError > deadzone then
        Camera.CFrame = Camera.CFrame:Lerp(targetCFrame, math.clamp(alpha, 0, 1))
    end
end

RunService:BindToRenderStep(
    "NexusStudioTargetAssist",
    Enum.RenderPriority.Camera.Value + 1,
    updateTargetAssist
)

-- ============================================================
-- ARGUS CONTROL CENTER
-- Added: Dashboard / Target Status / Sliders / Profiles /
-- Keybind Manager / Debug / ESP Performance / Target Weighting /
-- Secondary Lock State / Notifications / UI Animation
-- ============================================================
-- THIRD PERSON / MOBILE CAMERA CONTROL
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

_G.ArgusUIEnabled = false
_G.ArgusUIKey = Enum.KeyCode.RightControl
_G.ArgusDebugMode = false
_G.TargetAssistMaxPredictionTime = tonumber(_G.TargetAssistMaxPredictionTime) or 0.35
_G.TargetAssistDeadzone = tonumber(_G.TargetAssistDeadzone) or 0.12
_G.ArgusESPPerformance = true
_G.ArgusESPUpdateRate = 60
_G.ArgusTargetSelectionMode = "Crosshair"
_G.ArgusWeightCrosshair = 1.0
_G.ArgusWeightDistance = 0.35
_G.ArgusWeightHealth = 0.15
_G.ArgusWeightCustom = 0.0
_G.ArgusProfile = "Default"
_G.ArgusUIAccent = Color3.fromRGB(255, 255, 255)

local ArgusUI = {
    Open = true,
    Tab = "Dashboard",
    X = 70,
    Y = 90,
    W = 620,
    H = 600,
    Dragging = false,
    DragOffset = Vector2.zero,
    ActiveSlider = nil,
    Toast = nil,
    ToastUntil = 0,
    Status = "Idle",
    FPS = 0,
    FrameCount = 0,
    FPSClock = os.clock(),
}

local ArgusProfiles = {}
local ArgusKeybinds = {
    AimToggle = _G.TargetAssistToggleKey,
    UI = _G.ArgusUIKey,
    VisualHide = Enum.KeyCode.RightShift,
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
    Sidebar = argusNewSquare(true),
    ContentPanel = argusNewSquare(true),
    TopMeta = argusNewText(10),
    Title = argusNewText(18),
    Subtitle = argusNewText(11),
    TabTexts = {},
    BodyTexts = {},
    Buttons = {},
    Sliders = {},
    Status = argusNewText(12),
    Footer = argusNewText(10),
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
end

local function argusBoolText(value)
    return value and "ON" or "OFF"
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

    -- ImGui-inspired two-column layout: compact navigation rail + dense content inspector.
    local x = ArgusUI.X + 168
    local y = ArgusUI.Y + 91
    local w = ArgusUI.W - 190

    if ArgusUI.Tab == "Dashboard" then
        local status, target = argusGetTargetStatus()
        argusText("ARGUS STATUS", x, y, 11, Color3.fromRGB(170,170,170))
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
        argusMakeSlider("Smoothness", "TargetAssistSmoothness", x, y+360, w, 1, 30, 0.5)
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
        argusMakeButton("UI Theme: Black & White", x, y+91, w, 28, function()
            _G.ArgusUIAccent=Color3.fromRGB(255,255,255)
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
        argusText("UI toggle uses RightControl to avoid the existing RightShift visual hide.", x, y+155, 10, Color3.fromRGB(150,150,150))

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

local ArgusInput = _G.ArgusUIEnabled and UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if _G.ArgusUIEnabled and input.KeyCode == _G.ArgusUIKey then
        ArgusUI.Open = not ArgusUI.Open
        argusRebuildBody()
        return
    end

    if input.UserInputType == Enum.UserInputType.MouseButton1 and ArgusUI.Open then
        local mouse=UserInputService:GetMouseLocation()
        if mouse.Y >= ArgusUI.Y and mouse.Y <= ArgusUI.Y+48 and mouse.X >= ArgusUI.X and mouse.X <= ArgusUI.X+ArgusUI.W then
            ArgusUI.Dragging=true
            ArgusUI.DragOffset=mouse-Vector2.new(ArgusUI.X,ArgusUI.Y)
            return
        end
        for i,tab in ipairs(ArgusTabs) do
            local t=ArgusDraw.TabTexts[tab]
            local tabY=ArgusUI.Y+70+(i-1)*36
            if t and mouse.X >= ArgusUI.X+8 and mouse.X <= ArgusUI.X+146 and mouse.Y >= tabY-8 and mouse.Y <= tabY+25 then
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
                button.Callback()
                return
            end
        end
    end
end)

if _G.ArgusUIEnabled then
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            ArgusUI.Dragging=false
            ArgusUI.ActiveSlider=nil
        end
    end)
end)

if _G.ArgusUIEnabled then
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
end

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

if _G.ArgusUIEnabled then
RunService.RenderStepped:Connect(function()
    ArgusUI.FrameCount += 1
    local now=os.clock()
    if now-ArgusUI.FPSClock >= 0.5 then
        ArgusUI.FPS=ArgusUI.FrameCount/(now-ArgusUI.FPSClock)
        ArgusUI.FrameCount=0
        ArgusUI.FPSClock=now
    end

    argusUpdateTargetWeights()

    if ArgusUI.Open then
        local mx,my=ArgusUI.X,ArgusUI.Y
        ArgusDraw.Shadow.Position=Vector2.new(mx+4,my+5)
        ArgusDraw.Shadow.Size=Vector2.new(ArgusUI.W,ArgusUI.H)
        ArgusDraw.Shadow.Color=Color3.fromRGB(0,0,0)
        ArgusDraw.Shadow.Visible=true

        ArgusDraw.Panel.Position=Vector2.new(mx,my)
        ArgusDraw.Panel.Size=Vector2.new(ArgusUI.W,ArgusUI.H)
        ArgusDraw.Panel.Color=Color3.fromRGB(12,12,12)
        ArgusDraw.Panel.Visible=true

        ArgusDraw.Header.Position=Vector2.new(mx,my)
        ArgusDraw.Header.Size=Vector2.new(ArgusUI.W,48)
        ArgusDraw.Header.Color=Color3.fromRGB(18,18,18)
        ArgusDraw.Header.Visible=true

        ArgusDraw.Accent.Position=Vector2.new(mx+2,my+70+(table.find(ArgusTabs,ArgusUI.Tab)-1)*36)
        ArgusDraw.Accent.Size=Vector2.new(3,30)
        ArgusDraw.Accent.Color=_G.ArgusUIAccent
        ArgusDraw.Accent.Visible=true

        ArgusDraw.TabLine.Position=Vector2.new(mx+150,my+48)
        ArgusDraw.TabLine.Size=Vector2.new(ArgusUI.W-150,1)
        ArgusDraw.TabLine.Color=Color3.fromRGB(45,45,45)
        ArgusDraw.TabLine.Visible=true

        ArgusDraw.Sidebar.Position=Vector2.new(mx,my+48)
        ArgusDraw.Sidebar.Size=Vector2.new(150,ArgusUI.H-48)
        ArgusDraw.Sidebar.Color=Color3.fromRGB(9,9,9)
        ArgusDraw.Sidebar.Visible=true

        ArgusDraw.ContentPanel.Position=Vector2.new(mx+150,my+49)
        ArgusDraw.ContentPanel.Size=Vector2.new(ArgusUI.W-150,ArgusUI.H-49)
        ArgusDraw.ContentPanel.Color=Color3.fromRGB(13,13,13)
        ArgusDraw.ContentPanel.Visible=true

        ArgusDraw.Title.Text="NEXUS"
        ArgusDraw.Title.Position=Vector2.new(mx+18,my+9)
        ArgusDraw.Title.Visible=true
        ArgusDraw.Title.Color=_G.ArgusUIAccent
        ArgusDraw.Subtitle.Text="AI CONTROL CENTER"
        ArgusDraw.Subtitle.Position=Vector2.new(mx+86,my+13)
        ArgusDraw.Subtitle.Visible=true
        ArgusDraw.TopMeta.Text=string.format("FPS %.0f  |  %s  |  %s",ArgusUI.FPS,tostring(_G.ArgusDeviceType or "Desktop"),tostring(_G.ArgusDrawingBackend or "Unknown"))
        ArgusDraw.TopMeta.Position=Vector2.new(mx+ArgusUI.W-250,my+15)
        ArgusDraw.TopMeta.Color=Color3.fromRGB(165,165,165)
        ArgusDraw.TopMeta.Visible=true

        local tabHeight=36
        for i,tab in ipairs(ArgusTabs) do
            local t=ArgusDraw.TabTexts[tab]
            t.Text=string.upper(tab)
            t.Position=Vector2.new(mx+18,my+70+(i-1)*tabHeight)
            t.Color=(ArgusUI.Tab==tab) and _G.ArgusUIAccent or Color3.fromRGB(145,145,145)
            t.Visible=true
        end

        ArgusDraw.Status.Text="STATUS: "..argusGetTargetStatus()
        ArgusDraw.Status.Position=Vector2.new(mx+18,my+ArgusUI.H-32)
        ArgusDraw.Status.Color=argusStatusColor(argusGetTargetStatus())
        ArgusDraw.Status.Visible=true

        ArgusDraw.Footer.Text="RCTRL UI   |   RSHIFT Visual Hide"
        ArgusDraw.Footer.Position=Vector2.new(mx+ArgusUI.W-215,my+ArgusUI.H-32)
        ArgusDraw.Footer.Visible=true

        if ArgusUI.Toast and os.clock()<ArgusUI.ToastUntil then
            ArgusDraw.Status.Text=ArgusUI.Toast
            ArgusDraw.Status.Color=_G.ArgusUIAccent
        elseif ArgusUI.Toast then
            ArgusUI.Toast=nil
        end
    else
        ArgusDraw.Shadow.Visible=false
        ArgusDraw.Panel.Visible=false
        ArgusDraw.Header.Visible=false
        ArgusDraw.Accent.Visible=false
        ArgusDraw.TabLine.Visible=false
        ArgusDraw.Sidebar.Visible=false
        ArgusDraw.ContentPanel.Visible=false
        ArgusDraw.Title.Visible=false
        ArgusDraw.Subtitle.Visible=false
        ArgusDraw.TopMeta.Visible=false
        ArgusDraw.Status.Visible=false
        ArgusDraw.Footer.Visible=false
        for _,t in pairs(ArgusDraw.TabTexts) do t.Visible=false end
    end

    argusUpdateLivePanel()
    if ArgusUI.Open then
        argusRenderSliders()
    end
end)
end

ArgusUI.Open = false
if _G.ArgusUIEnabled then
    argusRebuildBody()
else
    -- The desktop Control Center is disabled by design; remove all fixed Drawing objects.
    for _, obj in pairs(ArgusDraw) do
        if type(obj) == "table" then
            for _, item in pairs(obj) do
                pcall(function() if item.Remove then item:Remove() end end)
                pcall(function() if item.Destroy then item:Destroy() end end)
            end
        elseif obj then
            pcall(function() if obj.Remove then obj:Remove() end end)
            pcall(function() if obj.Destroy then obj:Destroy() end end)
        end
    end
end


-- =========================================================
-- ARGUS DEVICE DETECTION / FULL MOBILE UI
-- =========================================================
local ArgusDevice = {
    IsTouch = UserInputService.TouchEnabled,
    HasKeyboard = UserInputService.KeyboardEnabled,
    HasMouse = UserInputService.MouseEnabled,
}

if ArgusDevice.IsTouch and not ArgusDevice.HasKeyboard then
    _G.ArgusDeviceType = "Mobile"
elseif ArgusDevice.IsTouch and ArgusDevice.HasKeyboard then
    _G.ArgusDeviceType = "Hybrid"
else
    _G.ArgusDeviceType = "Desktop"
end

_G.ArgusMobileUIEnabled = (_G.ArgusDeviceType ~= "Desktop")
_G.ArgusMobileAimActive = false
_G.ArgusInputSource = "Auto" -- Auto / Touch / MouseKeyboard
_G.ArgusDeviceVersion = "Dual"

local ArgusMobile = {
    Gui = nil,
    Frame = nil,
    Scroll = nil,
    Content = nil,
    Tab = "Dashboard",
    Visible = true,
    Reopen = nil,
    Dragging = false,
    DragStart = nil,
    FrameStart = nil,
}

local function argusGetUIParent()
    return LocalPlayer:WaitForChild("PlayerGui")
end

local function mobileClear(parent)
    for _, child in ipairs(parent:GetChildren()) do
        if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
            child:Destroy()
        end
    end
end

local function mobileButton(parent, text, callback, height)
    local b = Instance.new("TextButton")
    b.BackgroundColor3 = Color3.fromRGB(24,24,24)
    b.BorderColor3 = Color3.fromRGB(90,90,90)
    b.BorderSizePixel = 1
    b.TextColor3 = Color3.fromRGB(255,255,255)
    b.Font = Enum.Font.GothamSemibold
    b.TextSize = 13
    b.Text = text
    b.Size = UDim2.new(1,0,0,height or 38)
    b.AutoButtonColor = true
    b.Parent = parent
    b.Activated:Connect(function()
        pcall(callback)
    end)
    return b
end

local function mobileLabel(parent, text, size, height)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Size = UDim2.new(1,0,0,height or 28)
    l.Font = Enum.Font.Gotham
    l.TextSize = size or 12
    l.TextColor3 = Color3.fromRGB(205,205,205)
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextWrapped = true
    l.Text = text
    l.Parent = parent
    return l
end

local function mobileToggle(parent, label, key)
    return mobileButton(parent, label .. ": " .. argusBoolText(_G[key]), function()
        _G[key] = not _G[key]
        argusMobileRebuild()
    end)
end

local function mobileCycle(parent, label, key, values)
    return mobileButton(parent, label .. ": " .. tostring(_G[key]), function()
        local index = 1
        for i,v in ipairs(values) do
            if v == _G[key] then index = i break end
        end
        _G[key] = values[index % #values + 1]
        argusMobileRebuild()
    end)
end

local function mobileNumber(parent, label, key, min, max, step)
    local row = Instance.new("Frame")
    row.BackgroundColor3 = Color3.fromRGB(18,18,18)
    row.BorderColor3 = Color3.fromRGB(65,65,65)
    row.Size = UDim2.new(1,0,0,42)
    row.Parent = parent

    local name = Instance.new("TextLabel")
    name.BackgroundTransparency = 1
    name.Position = UDim2.fromOffset(8,0)
    name.Size = UDim2.new(0.48,0,1,0)
    name.Font = Enum.Font.GothamSemibold
    name.TextSize = 12
    name.TextColor3 = Color3.fromRGB(230,230,230)
    name.TextXAlignment = Enum.TextXAlignment.Left
    name.Text = label
    name.Parent = row

    local minus = Instance.new("TextButton")
    minus.BackgroundColor3 = Color3.fromRGB(35,35,35)
    minus.BorderSizePixel = 0
    minus.TextColor3 = Color3.fromRGB(255,255,255)
    minus.Font = Enum.Font.GothamBold
    minus.TextSize = 16
    minus.Text = "−"
    minus.Size = UDim2.fromOffset(32,30)
    minus.Position = UDim2.new(1,-148,0,6)
    minus.Parent = row

    local box = Instance.new("TextBox")
    box.BackgroundColor3 = Color3.fromRGB(10,10,10)
    box.BorderColor3 = Color3.fromRGB(80,80,80)
    box.TextColor3 = Color3.fromRGB(255,255,255)
    box.Font = Enum.Font.Gotham
    box.TextSize = 12
    box.Text = tostring(_G[key])
    box.ClearTextOnFocus = false
    box.Size = UDim2.fromOffset(78,30)
    box.Position = UDim2.new(1,-112,0,6)
    box.Parent = row

    local plus = Instance.new("TextButton")
    plus.BackgroundColor3 = Color3.fromRGB(35,35,35)
    plus.BorderSizePixel = 0
    plus.TextColor3 = Color3.fromRGB(255,255,255)
    plus.Font = Enum.Font.GothamBold
    plus.TextSize = 16
    plus.Text = "+"
    plus.Size = UDim2.fromOffset(32,30)
    plus.Position = UDim2.new(1,-32,0,6)
    plus.Parent = row

    local function setValue(v)
        v = tonumber(v) or tonumber(_G[key]) or min
        v = math.clamp(v, min, max)
        if step and step > 0 then
            v = math.floor(v / step + 0.5) * step
            v = math.clamp(v, min, max)
        end
        _G[key] = v
        if key == "TargetAssistOffsetX" or key == "TargetAssistOffsetY" or key == "TargetAssistOffsetZ" then
            argusMobileSyncAimValues()
        end
        box.Text = tostring(v)
    end

    minus.Activated:Connect(function()
        setValue((tonumber(_G[key]) or min) - step)
    end)
    plus.Activated:Connect(function()
        setValue((tonumber(_G[key]) or min) + step)
    end)
    box.FocusLost:Connect(function()
        setValue(box.Text)
    end)

    return row
end

local function argusMobileSyncAimValues()
    _G.TargetAssistOffset = Vector3.new(
        tonumber(_G.TargetAssistOffsetX) or 0,
        tonumber(_G.TargetAssistOffsetY) or 0,
        tonumber(_G.TargetAssistOffsetZ) or 0
    )
end

_G.TargetAssistOffsetX = _G.TargetAssistOffset.X
_G.TargetAssistOffsetY = _G.TargetAssistOffset.Y
_G.TargetAssistOffsetZ = _G.TargetAssistOffset.Z

function argusMobileRebuild()
    argusMobileSyncAimValues()
    if not ArgusMobile.Content then return end
    mobileClear(ArgusMobile.Content)

    mobileLabel(ArgusMobile.Content, "ARGUS  /  " .. tostring(_G.ArgusDeviceType), 11, 25)

    if ArgusMobile.Tab == "Dashboard" then
        local status,target = argusGetTargetStatus()
        mobileLabel(ArgusMobile.Content, "STATUS: "..status, 18, 35)
        mobileLabel(ArgusMobile.Content, "Target: "..(target and target.Name or "None"), 12, 26)
        mobileLabel(ArgusMobile.Content, string.format("FPS: %.0f", ArgusUI.FPS), 12, 26)
        mobileLabel(ArgusMobile.Content, "ESP Backend: "..tostring(_G.ArgusDrawingBackend or "Unknown"), 11, 24)
        mobileLabel(ArgusMobile.Content, "ESP Rate: "..string.format("%.0f Hz", tonumber(_G.ArgusESPEffectiveRate) or tonumber(_G.ArgusESPUpdateRate) or 60), 11, 24)
        mobileLabel(ArgusMobile.Content, "Aim State: "..tostring(TargetAssist.State), 11, 24)
        mobileLabel(ArgusMobile.Content, "Head State: "..tostring(TargetAssist.HeadState), 11, 24)
        mobileLabel(ArgusMobile.Content, "Touch Aim: "..argusBoolText(MobileTouchState.Active), 11, 24)
        mobileButton(ArgusMobile.Content, "AIM: "..argusBoolText(_G.TargetAssistEnabled), function()
            _G.TargetAssistEnabled = not _G.TargetAssistEnabled
            _G.ArgusMobileAimActive = _G.TargetAssistEnabled
            if not _G.TargetAssistEnabled then TargetAssist.CurrentTarget=nil end
            argusMobileRebuild()
        end)
        mobileButton(ArgusMobile.Content,"Third Person / 第三人稱: "..argusBoolText(ThirdPersonState.Enabled),function() toggleThirdPerson(); argusMobileRebuild() end)
        mobileNumber(ArgusMobile.Content,"Third Person Distance / 第三人稱距離","ThirdPersonDistance",4,20,0.5)
        mobileCycle(ArgusMobile.Content,"Aim Touch Region / 觸控瞄準區","ArgusMobileAimRegion",{"RightHalf","FullScreen"})
        mobileButton(ArgusMobile.Content, "Visual Hide: "..argusBoolText(_G.TargetAssistVisualsHidden), function()
            _G.TargetAssistVisualsHidden = not _G.TargetAssistVisualsHidden
            argusMobileRebuild()
        end)
        mobileButton(ArgusMobile.Content, "FOV: "..argusBoolText(_G.TargetAssistFOVEnabled), function()
            _G.TargetAssistFOVEnabled = not _G.TargetAssistFOVEnabled
            argusMobileRebuild()
        end)
        mobileLabel(ArgusMobile.Content, "所有 ESP、瞄準與參數都由同一套核心控制。", 11, 42)

    elseif ArgusMobile.Tab == "Visuals" then
        mobileLabel(ArgusMobile.Content, "VISUAL MODULES", 14, 30)
        local rows = {
            {"ESPEnabled","ESP Master"},{"BoxESP","Box"},{"BoxFilled","Filled Box"},
            {"HighlightESP","Highlight"},{"HealthESP","Health"},{"NameESP","Name"},
            {"ToolESP","Tool"},{"TracerESP","Tracer"},{"SkeletonESP","Skeleton"},
            {"TeamCheck","Team Check"},{"TeamColorESP","Team Color"},
        }
        for _,row in ipairs(rows) do mobileToggle(ArgusMobile.Content,row[2],row[1]) end
        mobileLabel(ArgusMobile.Content, "Skeleton 使用原本 Drawing 骨骼系統，不移除。", 11, 34)

    elseif ArgusMobile.Tab == "Target" then
        mobileLabel(ArgusMobile.Content, "TARGET ASSIST", 14, 30)
        mobileToggle(ArgusMobile.Content,"Aimbot","TargetAssistEnabled")















        mobileNumber(ArgusMobile.Content,"Aim Strength / 鎖定強度","MobileAimStrength",0,100,5)
        mobileNumber(ArgusMobile.Content,"Head Lock Strength / 鎖頭強度","MobileHeadLockStrength",0,100,5)
        mobileNumber(ArgusMobile.Content,"Head Threshold / 鎖頭門檻","MobileHeadLockThreshold",0,100,5)
        mobileNumber(ArgusMobile.Content,"Head Grace / 鎖頭容錯","MobileHeadLockGrace",0,0.5,0.01)
        mobileNumber(ArgusMobile.Content,"Head Switch Margin / 鎖頭滯後","MobileHeadLockSwitchMargin",0,0.5,0.01)
        mobileNumber(ArgusMobile.Content,"Head Reacquire / 鎖頭重取","MobileHeadLockReacquireDelay",0,0.5,0.01)
        mobileLabel(ArgusMobile.Content,"Head State: "..tostring(_G.MobileHeadLockState),11,26)
        mobileCycle(ArgusMobile.Content,"Target Part","TargetAssistPart",{"Head","UpperTorso","LowerTorso","HumanoidRootPart","Auto"})
        mobileCycle(ArgusMobile.Content,"Activation","TargetAssistActivationMode",{"RightMouse","Toggle","Both"})
        mobileToggle(ArgusMobile.Content,"Wall Check","TargetAssistWallCheck")
        mobileToggle(ArgusMobile.Content,"Team Check","TargetAssistTeamCheck")
        mobileToggle(ArgusMobile.Content,"On Screen Only","TargetAssistRequireOnScreen")
        mobileToggle(ArgusMobile.Content,"FOV","TargetAssistFOVEnabled")
        mobileToggle(ArgusMobile.Content,"Prediction","TargetAssistPredictionEnabled")
        mobileToggle(ArgusMobile.Content,"Movement Prediction","TargetAssistMovementPrediction")
        mobileToggle(ArgusMobile.Content,"Secondary Lock / 二次定位","TargetAssistSecondaryLock")
        mobileToggle(ArgusMobile.Content,"Auto Head","TargetAssistAutoHead")
        mobileToggle(ArgusMobile.Content,"Humanized Aim","TargetAssistHumanizedAim")
        mobileCycle(ArgusMobile.Content,"Selection","ArgusTargetSelectionMode",{"Crosshair","Distance","Health","Balanced"})
        mobileCycle(ArgusMobile.Content,"Auto Body Part","TargetAssistAutoBodyPart",{"UpperTorso","HumanoidRootPart","LowerTorso"})
        mobileCycle(ArgusMobile.Content,"Secondary Part / 二次定位部位","TargetAssistSecondaryPart",{"Head","UpperTorso","LowerTorso","HumanoidRootPart"})
        mobileCycle(ArgusMobile.Content,"Secondary Primary / 二次定位初始部位","TargetAssistSecondaryPrimaryPart",{"UpperTorso","HumanoidRootPart","LowerTorso","Head"})
        mobileNumber(ArgusMobile.Content,"Smoothness","TargetAssistSmoothness",1,30,0.5)
        mobileNumber(ArgusMobile.Content,"Secondary Smoothness","TargetAssistSecondarySmoothness",1,40,0.5)
        mobileNumber(ArgusMobile.Content,"FOV Radius","TargetAssistFOVRadius",20,600,5)
        mobileNumber(ArgusMobile.Content,"Max Distance","TargetAssistMaxDistance",0,2000,10)
        mobileNumber(ArgusMobile.Content,"Prediction Time","TargetAssistPredictionTime",0,0.5,0.01)
        mobileNumber(ArgusMobile.Content,"Max Prediction","TargetAssistMaxPredictionTime",0,1.5,0.01)
        mobileNumber(ArgusMobile.Content,"Aim Deadzone","TargetAssistDeadzone",0,2,0.05)
        mobileNumber(ArgusMobile.Content,"Projectile Speed","TargetAssistProjectileSpeed",0,10000,50)
        mobileNumber(ArgusMobile.Content,"Secondary Delay / 二次定位延遲","TargetAssistSecondaryDelay",0,0.5,0.01)
        mobileNumber(ArgusMobile.Content,"Secondary Blend / 二次定位過渡","TargetAssistSecondaryBlendTime",0.01,0.5,0.01)
        mobileNumber(ArgusMobile.Content,"Aim Error","TargetAssistAimError",0,0.2,0.001)
        mobileNumber(ArgusMobile.Content,"Jitter Speed","TargetAssistJitterSpeed",0,30,0.5)
        mobileNumber(ArgusMobile.Content,"Offset X","TargetAssistOffsetX",-10,10,0.1)
        mobileNumber(ArgusMobile.Content,"Offset Y","TargetAssistOffsetY",-10,10,0.1)
        mobileNumber(ArgusMobile.Content,"Offset Z","TargetAssistOffsetZ",-10,10,0.1)
        mobileNumber(ArgusMobile.Content,"FOV Thickness","TargetAssistFOVThickness",1,5,1)
        mobileNumber(ArgusMobile.Content,"FOV Transparency","TargetAssistFOVTransparency",0,1,0.05)
        mobileToggle(ArgusMobile.Content,"FOV Filled","TargetAssistFOVFilled")

    elseif ArgusMobile.Tab == "Settings" then
        mobileLabel(ArgusMobile.Content,"FINE CONTROL",14,30)
        mobileToggle(ArgusMobile.Content,"ESP Performance","ArgusESPPerformance")
        mobileToggle(ArgusMobile.Content,"ESP Adaptive Rate","ArgusESPAdaptive")
        mobileCycle(ArgusMobile.Content,"ESP Update Rate","ArgusESPUpdateRate",{15,30,60,120})
        mobileToggle(ArgusMobile.Content,"Target Cache","ArgusTargetCacheEnabled")
        mobileToggle(ArgusMobile.Content,"State Watchdog","ArgusStateWatchdog")
        mobileToggle(ArgusMobile.Content,"Camera Recovery","ArgusCameraRecovery")
        mobileToggle(ArgusMobile.Content,"Fail Safe","ArgusFailSafe")
        mobileToggle(ArgusMobile.Content,"Debug Mode","ArgusDebugMode")
        mobileLabel(ArgusMobile.Content,"UI / device: "..tostring(_G.ArgusDeviceType),11,28)
        mobileLabel(ArgusMobile.Content,"右半屏啟動瞄準，左半屏保留給虛擬搖桿。",11,34)
        mobileNumber(ArgusMobile.Content,"Aim Touch Start X","ArgusMobileAimTouchMinX",0.25,0.8,0.05)
        mobileNumber(ArgusMobile.Content,"Weight Crosshair","ArgusWeightCrosshair",0,2,0.05)
        mobileNumber(ArgusMobile.Content,"Weight Distance","ArgusWeightDistance",0,2,0.05)
        mobileNumber(ArgusMobile.Content,"Weight Health","ArgusWeightHealth",0,2,0.05)
        mobileNumber(ArgusMobile.Content,"Weight Custom","ArgusWeightCustom",0,2,0.05)

    elseif ArgusMobile.Tab == "Profiles" then
        mobileLabel(ArgusMobile.Content,"PROFILE MANAGER",14,30)
        mobileLabel(ArgusMobile.Content,"Current: "..tostring(_G.ArgusProfile),12,28)
        for _,name in ipairs({"Default","Profile 1","Profile 2","Profile 3"}) do
            mobileButton(ArgusMobile.Content,"Load "..name,function()
                if ArgusProfiles[name] then
                    argusApplyProfile(ArgusProfiles[name])
                    _G.ArgusProfile=name
                    _G.ArgusMobileAimActive=_G.TargetAssistEnabled
                    argusMobileRebuild()
                end
            end)
            mobileButton(ArgusMobile.Content,"Save "..name,function()
                ArgusProfiles[name]=argusCaptureProfile()
                _G.ArgusProfile=name
                argusMobileRebuild()
            end)
        end

    elseif ArgusMobile.Tab == "Keybinds" then
        mobileLabel(ArgusMobile.Content,"KEYBINDS",14,30)
        mobileLabel(ArgusMobile.Content,"Desktop UI: ".._G.ArgusUIKey.Name,12,26)
        mobileCycle(ArgusMobile.Content,"Aim Key","TargetAssistToggleKey",{Enum.KeyCode.Q,Enum.KeyCode.E,Enum.KeyCode.T,Enum.KeyCode.LeftAlt})
        mobileCycle(ArgusMobile.Content,"Input Source / 輸入來源","ArgusInputSource",{"Auto","Touch","MouseKeyboard"})
        mobileLabel(ArgusMobile.Content,"Auto：手機使用觸控；Hybrid 可同時保留滑鼠鍵盤。",11,38)
        mobileLabel(ArgusMobile.Content,"RightShift = Visual Hide",11,28)
        mobileLabel(ArgusMobile.Content,"面板關閉後，右上角 ARGUS 可重新開啟。",11,34)

    elseif ArgusMobile.Tab == "Debug" then
        local status,target=argusGetTargetStatus()
        local char=target and target.Character
        local root=char and char:FindFirstChild("HumanoidRootPart")
        local localChar=LocalPlayer.Character
        local localRoot=localChar and localChar:FindFirstChild("HumanoidRootPart")
        local distance=root and localRoot and (root.Position-localRoot.Position).Magnitude or 0
        mobileLabel(ArgusMobile.Content,"DEBUG / DIAGNOSTICS",14,30)
        mobileLabel(ArgusMobile.Content,"State: "..status,13,28)
        mobileLabel(ArgusMobile.Content,"Target: "..(target and target.Name or "None"),12,26)
        mobileLabel(ArgusMobile.Content,string.format("Distance: %.1f",distance),12,26)
        mobileLabel(ArgusMobile.Content,"FOV: "..tostring(_G.TargetAssistFOVRadius),12,26)
        mobileLabel(ArgusMobile.Content,"Selection: "..tostring(_G.ArgusTargetSelectionMode),12,26)
        mobileLabel(ArgusMobile.Content,"ESP Update: "..tostring(_G.ArgusESPUpdateRate),12,26)
        mobileLabel(ArgusMobile.Content,"ESP Effective: "..string.format("%.0f Hz", tonumber(_G.ArgusESPEffectiveRate) or tonumber(_G.ArgusESPUpdateRate) or 60),12,26)
        mobileLabel(ArgusMobile.Content,"ESP Backend: "..tostring(_G.ArgusDrawingBackend or "Unknown"),12,26)
        mobileLabel(ArgusMobile.Content,"Aim State: "..tostring(TargetAssist.State),12,26)
        mobileLabel(ArgusMobile.Content,"Head State: "..tostring(TargetAssist.HeadState),12,26)
        mobileLabel(ArgusMobile.Content,"Touch Active: "..argusBoolText(MobileTouchState.Active),12,26)
        mobileLabel(ArgusMobile.Content,"Device: "..tostring(_G.ArgusDeviceType),12,26)
        mobileLabel(ArgusMobile.Content,"Skeleton: "..argusBoolText(_G.SkeletonESP),12,26)
    end
end

local function argusCreateMobileUI()
    if not _G.ArgusMobileUIEnabled then return end
    if ArgusMobile.Gui then
        ArgusMobile.Gui.Enabled=true
        return
    end

    local gui=Instance.new("ScreenGui")
    gui.Name="ArgusFullControlUI"
    gui.ResetOnSpawn=false
    -- Respect Roblox mobile top-bar / safe-area insets.
    gui.IgnoreGuiInset=false
    pcall(function()
        gui.ScreenInsets=Enum.ScreenInsets.DeviceSafeInsets
    end)
    gui.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
    gui.DisplayOrder=999999
    gui.ResetOnSpawn=false
    gui.Parent=argusGetUIParent()
    ArgusMobile.Gui=gui

    local frame=Instance.new("Frame")
    frame.Name="ControlPanel"
    -- Use a top-left anchor so drag coordinates and resize coordinates always
    -- refer to the same point. This prevents the mobile panel from jumping.
    frame.AnchorPoint=Vector2.new(0,0)
    frame.BackgroundColor3=Color3.fromRGB(8,8,8)
    frame.BorderColor3=Color3.fromRGB(255,255,255)
    frame.BorderSizePixel=1
    frame.Parent=gui
    ArgusMobile.Frame=frame

    local function argusApplyResponsiveSize()
        local camera = workspace.CurrentCamera
        local viewport = camera and camera.ViewportSize or Vector2.new(1280,720)
        local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

        -- Compact mobile layout: never occupy most of the entire screen.
        local width = math.min(touchOnly and 460 or 560, math.max(300, viewport.X * (touchOnly and 0.86 or 0.72)))
        local height = math.min(touchOnly and 620 or 720, math.max(430, viewport.Y * (touchOnly and 0.78 or 0.78)))
        frame.Size = UDim2.fromOffset(width,height)

        -- Always start / reset at the center. While dragging, preserve the
        -- current position and only clamp it back into the safe viewport.
        if not ArgusMobile.Dragging then
            frame.Position=UDim2.fromOffset(
                math.max(6,(viewport.X-width)*0.5),
                math.max(6,(viewport.Y-height)*0.5)
            )
        else
            local pos=frame.AbsolutePosition
            frame.Position=UDim2.fromOffset(
                math.clamp(pos.X,6,math.max(6,viewport.X-width-6)),
                math.clamp(pos.Y,6,math.max(6,viewport.Y-height-6))
            )
        end
    end

    local camera = workspace.CurrentCamera
    if camera then
        camera:GetPropertyChangedSignal("ViewportSize"):Connect(argusApplyResponsiveSize)
    end
    task.defer(argusApplyResponsiveSize)

    local sizeConstraint=Instance.new("UISizeConstraint")
    sizeConstraint.MinSize=Vector2.new(300,430)
    sizeConstraint.MaxSize=Vector2.new(520,760)
    sizeConstraint.Parent=frame

    local title=Instance.new("TextButton")
    title.Name="DragHeader"
    title.BackgroundColor3=Color3.fromRGB(18,18,18)
    title.BorderSizePixel=0
    title.Size=UDim2.new(1,0,0,46)
    title.Text="NEXUS AI  /  "..tostring(_G.ArgusDeviceType)
    title.TextColor3=Color3.fromRGB(255,255,255)
    title.TextSize=16
    title.Font=Enum.Font.GothamBold
    title.TextXAlignment=Enum.TextXAlignment.Left
    title.AutoButtonColor=false
    title.Parent=frame

    local padding=Instance.new("UIPadding")
    padding.PaddingLeft=UDim.new(0,14)
    padding.Parent=title

    local tabs=Instance.new("ScrollingFrame")
    tabs.Name="Navigation"
    tabs.BackgroundColor3=Color3.fromRGB(9,9,9)
    tabs.BorderSizePixel=0
    tabs.Position=UDim2.fromOffset(0,46)
    tabs.Size=UDim2.fromOffset(112,0)
    tabs.Size=UDim2.new(0,112,1,-46)
    tabs.ScrollBarThickness=2
    tabs.ScrollingDirection=Enum.ScrollingDirection.Y
    tabs.AutomaticCanvasSize=Enum.AutomaticSize.Y
    tabs.CanvasSize=UDim2.new()
    tabs.Parent=frame

    local tabLayout=Instance.new("UIListLayout")
    tabLayout.FillDirection=Enum.FillDirection.Vertical
    tabLayout.Padding=UDim.new(0,3)
    tabLayout.Parent=tabs

    local tabPadding=Instance.new("UIPadding")
    tabPadding.PaddingTop=UDim.new(0,12)
    tabPadding.PaddingLeft=UDim.new(0,8)
    tabPadding.PaddingRight=UDim.new(0,8)
    tabPadding.Parent=tabs

    local tabNames={"Dashboard","Visuals","Target","Settings","Profiles","Keybinds","Debug"}
    for _,name in ipairs(tabNames) do
        local b=Instance.new("TextButton")
        b.Size=UDim2.new(1,0,0,38)
        b.BackgroundColor3=Color3.fromRGB(16,16,16)
        b.BorderSizePixel=0
        b.TextColor3=Color3.fromRGB(175,175,175)
        b.Font=Enum.Font.GothamSemibold
        b.TextSize=11
        b.TextXAlignment=Enum.TextXAlignment.Left
        b.Text="  "..string.upper(name)
        b.Parent=tabs
        b.Activated:Connect(function()
            ArgusMobile.Tab=name
            argusMobileRebuild()
            for _,other in ipairs(tabs:GetChildren()) do
                if other:IsA("TextButton") then
                    other.BackgroundColor3=(other==b) and Color3.fromRGB(38,38,38) or Color3.fromRGB(16,16,16)
                    other.TextColor3=(other==b) and Color3.fromRGB(255,255,255) or Color3.fromRGB(175,175,175)
                end
            end
        end)
    end

    -- Initial active state mirrors the selected navigation item.
    for _,other in ipairs(tabs:GetChildren()) do
        if other:IsA("TextButton") then
            local active = other.Text:find(string.upper(ArgusMobile.Tab), 1, true) ~= nil
            other.BackgroundColor3 = active and Color3.fromRGB(38,38,38) or Color3.fromRGB(16,16,16)
            other.TextColor3 = active and Color3.fromRGB(255,255,255) or Color3.fromRGB(175,175,175)
        end
    end

    local scroll=Instance.new("ScrollingFrame")
    scroll.Name="Content"
    scroll.Position=UDim2.fromOffset(122,56)
    scroll.Size=UDim2.new(1,-132,1,-66)
    scroll.BackgroundColor3=Color3.fromRGB(13,13,13)
    scroll.BorderColor3=Color3.fromRGB(45,45,45)
    scroll.ScrollBarThickness=5
    scroll.AutomaticCanvasSize=Enum.AutomaticSize.Y
    scroll.CanvasSize=UDim2.new()
    scroll.Parent=frame
    ArgusMobile.Scroll=scroll

    local content=Instance.new("Frame")
    content.BackgroundTransparency=1
    content.Size=UDim2.new(1,-16,0,0)
    content.AutomaticSize=Enum.AutomaticSize.Y
    content.Parent=scroll
    ArgusMobile.Content=content

    local layout=Instance.new("UIListLayout")
    layout.Padding=UDim.new(0,6)
    layout.Parent=content

    local contentPadding=Instance.new("UIPadding")
    contentPadding.PaddingTop=UDim.new(0,8)
    contentPadding.PaddingBottom=UDim.new(0,12)
    contentPadding.Parent=content

    local close=Instance.new("TextButton")
    close.Text="×"
    close.TextColor3=Color3.fromRGB(255,255,255)
    close.TextSize=22
    close.Font=Enum.Font.GothamBold
    close.BackgroundTransparency=1
    close.Size=UDim2.fromOffset(42,42)
    close.Position=UDim2.new(1,-45,0,2)
    close.Parent=frame
    close.Activated:Connect(function()
        ArgusMobile.Visible=false
        frame.Visible=false
        if ArgusMobile.Reopen then ArgusMobile.Reopen.Visible=true end
    end)

    local reopen=Instance.new("TextButton")
    reopen.Text="ARGUS"
    reopen.TextColor3=Color3.fromRGB(255,255,255)
    reopen.TextSize=12
    reopen.Font=Enum.Font.GothamBold
    reopen.BackgroundColor3=Color3.fromRGB(10,10,10)
    reopen.BorderColor3=Color3.fromRGB(255,255,255)
    reopen.Size=UDim2.fromOffset(76,36)
    reopen.AnchorPoint=Vector2.new(1,0)
    -- Top-right reopen button stays below the Roblox mobile top bar / safe area.
    reopen.Position=UDim2.new(1,-12,0,12)
    reopen.Visible=false
    reopen.Parent=gui
    ArgusMobile.Reopen=reopen
    reopen.Activated:Connect(function()
        ArgusMobile.Visible=true
        frame.Visible=true
        reopen.Visible=false
    end)

    -- Drag: header works with both touch and mouse.
    title.InputBegan:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.Touch
            or input.UserInputType==Enum.UserInputType.MouseButton1 then
            ArgusMobile.Dragging=true
            ArgusMobile.DragInput=input
            ArgusMobile.DragStart=input.Position
            ArgusMobile.FrameStart=frame.AbsolutePosition
        end
    end)

    title.InputChanged:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.MouseMovement
            or input.UserInputType==Enum.UserInputType.Touch then
            ArgusMobile.DragInput=input
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not ArgusMobile.Dragging then return end
        if input~=ArgusMobile.DragInput
            and input.UserInputType~=Enum.UserInputType.MouseMovement
            and input.UserInputType~=Enum.UserInputType.Touch then
            return
        end

        local delta=input.Position-ArgusMobile.DragStart
        local viewport=workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(800,600)
        local fs=frame.AbsoluteSize
        local nx=math.clamp(ArgusMobile.FrameStart.X+delta.X,6,math.max(6,viewport.X-fs.X-6))
        local ny=math.clamp(ArgusMobile.FrameStart.Y+delta.Y,6,math.max(6,viewport.Y-fs.Y-6))
        frame.Position=UDim2.fromOffset(nx,ny)
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.Touch
            or input.UserInputType==Enum.UserInputType.MouseButton1 then
            ArgusMobile.Dragging=false
            ArgusMobile.DragInput=nil
        end
    end)

    argusMobileRebuild()
end


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
    TargetVelocity={},
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
    _G.MobileAimStrength=argusSafeNumber(_G.MobileAimStrength,100,0,100)
    _G.MobileHeadLockStrength=argusSafeNumber(_G.MobileHeadLockStrength,100,0,100)
    _G.MobileHeadLockThreshold=argusSafeNumber(_G.MobileHeadLockThreshold,65,0,100)
    _G.MobileHeadLockGrace=argusSafeNumber(_G.MobileHeadLockGrace,0.12,0,0.5)
    _G.TargetAssistFOVRadius=argusSafeNumber(_G.TargetAssistFOVRadius,180,1,2000)
    _G.TargetAssistMaxDistance=argusSafeNumber(_G.TargetAssistMaxDistance,500,0,10000)
    _G.TargetAssistTargetSwitchDelay=argusSafeNumber(_G.TargetAssistTargetSwitchDelay,0.15,0,2)
    _G.TargetAssistMinimumLockTime=argusSafeNumber(_G.TargetAssistMinimumLockTime,0.12,0,3)
    _G.TargetAssistReacquireDelay=argusSafeNumber(_G.TargetAssistReacquireDelay,0.12,0,2)
    _G.TargetAssistMaxPredictionTime=argusSafeNumber(_G.TargetAssistMaxPredictionTime,0.35,0,1.5)
    _G.TargetAssistDeadzone=argusSafeNumber(_G.TargetAssistDeadzone,0.12,0,2)
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
        resetMobileHeadState()
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

local function argusCachedBestTarget()
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
        if player and player.Parent==Players then
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            if humanoid and humanoid.Health > 0 and targetAssistIsValid(player) then
                return player
            end
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
        resetMobileHeadState()
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
    if player.Character then
        for part in pairs(ArgusRuntime.TargetVelocity) do
            if part and part:IsDescendantOf(player.Character) then
                ArgusRuntime.TargetVelocity[part] = nil
            end
        end
    end
    if ArgusRuntime.TargetCache==player then
        ArgusRuntime.TargetCache=nil
        if TargetAssist.CurrentTarget==player then
            TargetAssist.CurrentTarget=nil
            resetMobileHeadState()
        end
    end
end)

-- ============================================================
-- FINAL OPTIMIZATION LAYER
-- Target/LOS cache, performance budgets, cleanup, config repair,
-- touch safety, camera recovery, state telemetry and fail-safe.
-- ============================================================
_G.ArgusLOSCacheLifetime = 0.055
_G.ArgusTargetSearchInterval = 0.035
_G.ArgusESPAdaptive = true
_G.ArgusESPMinUpdateRate = 20
_G.ArgusESPMaxUpdateRate = 60
_G.ArgusTouchLongPress = true
_G.ArgusTouchMinHold = 0.045
_G.ArgusTouchCancelOnUI = true
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
    TouchStarted = {},
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
    _G.ArgusTouchMinHold = finalSafeNumber(_G.ArgusTouchMinHold,0.045,0,0.5)
    if _G.ArgusESPMinUpdateRate > _G.ArgusESPMaxUpdateRate then
        _G.ArgusESPMinUpdateRate, _G.ArgusESPMaxUpdateRate = _G.ArgusESPMaxUpdateRate, _G.ArgusESPMinUpdateRate
    end
end

local function finalInvalidateTarget()
    ArgusFinal.Target = nil
    ArgusFinal.TargetAt = 0
    ArgusRuntime.TargetCache = nil
    ArgusRuntime.TargetCacheAt = 0
    ArgusRuntime.TargetVelocity = {}
    ArgusFinal.LOS = {}
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

    local ok, valid = pcall(_originalTargetAssistIsValid, player)

    _G.TargetAssistWallCheck = wallCheck

    if not ok or not valid then
        return false
    end

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

local function finalTouchCleanup()
    local activeCount = 0
    local now = os.clock()
    local startedMap = _G.ArgusTouchStartedAt or {}

    for input, startedAt in pairs(startedMap) do
        ArgusFinal.TouchStarted[input] = startedAt
    end

    for input, startedAt in pairs(ArgusFinal.TouchStarted) do
        local alive = input
            and input.UserInputState ~= Enum.UserInputState.End
            and input.UserInputState ~= Enum.UserInputState.Cancel

        if not alive or (startedAt and now - startedAt > 10) then
            ArgusFinal.TouchStarted[input] = nil
            startedMap[input] = nil
        else
            activeCount += 1
        end
    end

    if activeCount == 0 and MobileTouchState.Active then
        MobileTouchState.Active = false
        MobileTouchState.Touches = {}
        _G.ArgusMobileAimActive = false
    end
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
    MobileTouchState.Active = false
    MobileTouchState.Touches = {}
end))

finalTrackConnection(LocalPlayer.CharacterRemoving:Connect(function()
    finalInvalidateTarget()
    ArgusFinal.LOS = {}
    MobileTouchState.Active = false
    MobileTouchState.Touches = {}
end))

finalTrackConnection(Players.PlayerRemoving:Connect(function(player)
    ArgusFinal.LOS = {}
    if ArgusFinal.Target == player then finalInvalidateTarget() end
end))

RunService:BindToRenderStep('NexusArgusFinalGuard',Enum.RenderPriority.First.Value+1,function(dt)
    finalValidate()
    finalCameraGuard()
    ArgusFinal.ESPAccumulator += math.max(dt,0)
    finalTouchCleanup()

    local now = os.clock()
    local searchInterval = _G.ArgusTargetSearchInterval
    local fps = ArgusRuntime.FPS or 60
    if fps < 30 then
        searchInterval = math.max(searchInterval, 0.08)
    elseif fps < 45 then
        searchInterval = math.max(searchInterval, 0.05)
    end
    if isMobileTouchMode() then
        searchInterval = math.max(searchInterval, 0.028)
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
        resetMobileHeadState()
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
    if not _G.TargetAssistEnabled or _G.ArgusFailSafe == false then
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
        resetMobileHeadState()
        ArgusModuleHealth.HeadRepairs += 1
        return
    end

    local requestedPart = _G.TargetAssistPart
    local wantsHead = requestedPart == "Head"
        or requestedPart == "Auto"
        or _G.MobileHeadLockPreferred == true

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
            resetMobileHeadState()
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

local ArgusHealthAccumulator = 0
RunService.Heartbeat:Connect(function(dt)
    ArgusHealthAccumulator += math.max(dt, 0)
    if ArgusHealthAccumulator < 1 then return end
    ArgusHealthAccumulator = 0
    argusRunModuleHealthCheck()
end)

-- 啟動後第一秒立即完成第一次檢查，而不是等使用者操作。
task.defer(function()
    task.wait(1)
    argusRunModuleHealthCheck()
end)


argusCreateMobileUI()

if _G.ArgusMobileUIEnabled then
    task.spawn(function()
        while ArgusMobile.Gui and ArgusMobile.Gui.Parent do
            if ArgusMobile.Frame and ArgusMobile.Frame.Visible then
                local status=argusGetTargetStatus()
                ArgusMobile.Frame:SetAttribute("Status",tostring(status))
            end
            task.wait(0.15)
        end
    end)
end
