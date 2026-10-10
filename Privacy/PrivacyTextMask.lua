-- PrivacyTextMask.lua
-- Opt-in privacy helper for UI owned by your experience.
-- Scope: pass a ScreenGui that your own code creates; this does not OCR the game screen.
-- It intentionally does not hide gameplay overlays or alter what spectators can see.
local RunService = game:GetService("RunService")

local PrivacyTextMask = {}
PrivacyTextMask.__index = PrivacyTextMask

local DEFAULT_NAME = "^@[%w_]+$"
local DEFAULT_ID_PATTERNS = {
    "[Uu]ser[Ii][Dd]%s*:%s*%d%d%d%d%d+",
    "[Pp]layer[Ii][Dd]%s*:%s*%d%d%d%d%d+",
}

local function defaultShouldMask(text)
    text = tostring(text or "")
    if text:match(DEFAULT_NAME) then
        return true
    end
    for _, pattern in ipairs(DEFAULT_ID_PATTERNS) do
        if text:match(pattern) then
            return true
        end
    end
    return false
end

function PrivacyTextMask.new(screenGui, options)
    assert(typeof(screenGui) == "Instance" and screenGui:IsA("ScreenGui"),
        "PrivacyTextMask.new expects a ScreenGui owned by your UI")
    options = options or {}

    local self = setmetatable({}, PrivacyTextMask)
    self.Gui = screenGui
    self.Enabled = options.Enabled ~= false
    self.ShouldMask = options.ShouldMask or defaultShouldMask
    self.Allowlist = options.Allowlist or {}
    self._masks = {}
    self._connections = {}
    self._destroyed = false
    self._overlayName = options.OverlayName or "PrivacyTextMaskOverlay"
    self._zIndex = tonumber(options.ZIndex) or 100

    local function removeMask(label)
        local record = self._masks[label]
        if record then
            if record.Overlay then record.Overlay:Destroy() end
            if record.Connection then record.Connection:Disconnect() end
            self._masks[label] = nil
        end
    end

    local function refresh(label)
        if self._destroyed or not label.Parent then
            removeMask(label)
            return
        end
        local text = tostring(label.Text or "")
        local shouldMask = self.Enabled
            and not self.Allowlist[text]
            and self.ShouldMask(text, label) == true

        local record = self._masks[label]
        if not shouldMask then
            if record and record.Overlay then
                record.Overlay.Visible = false
            end
            return
        end

        -- Parent the cover to the text object itself. This avoids sibling overlays
        -- participating in UIListLayout/UIGridLayout and shifting the original UI.
        if not record or not record.Overlay then
            local overlay = Instance.new("Frame")
            overlay.Name = self._overlayName
            overlay.BackgroundColor3 = Color3.new(0, 0, 0)
            overlay.BackgroundTransparency = 0
            overlay.BorderSizePixel = 0
            overlay.Visible = false
            overlay.Active = false
            overlay.Selectable = false
            overlay.AnchorPoint = Vector2.zero
            overlay.Position = UDim2.fromScale(0, 0)
            overlay.Size = UDim2.fromScale(1, 1)
            overlay.ZIndex = math.max(label.ZIndex + 1, self._zIndex)
            overlay.Parent = label
            record = record or {}
            record.Overlay = overlay
            self._masks[label] = record
        end

        local overlay = record.Overlay
        if overlay.Parent ~= label then
            overlay.Parent = label
        end
        overlay.Position = UDim2.fromScale(0, 0)
        overlay.Size = UDim2.fromScale(1, 1)
        overlay.ZIndex = math.max(label.ZIndex + 1, self._zIndex)
        overlay.Visible = label.Visible and label.AbsoluteSize.X > 0 and label.AbsoluteSize.Y > 0
    end

    local function track(instance)
        if not (instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox")) then
            return
        end
        if instance.Name == self._overlayName then return end
        local changed = instance:GetPropertyChangedSignal("Text"):Connect(function()
            refresh(instance)
        end)
        self._masks[instance] = self._masks[instance] or {}
        self._masks[instance].Connection = changed
        refresh(instance)
    end

    for _, descendant in ipairs(screenGui:GetDescendants()) do
        track(descendant)
    end
    table.insert(self._connections, screenGui.DescendantAdded:Connect(track))
    table.insert(self._connections, screenGui.DescendantRemoving:Connect(removeMask))
    table.insert(self._connections, RunService.RenderStepped:Connect(function()
        if self._destroyed then return end
        for label in pairs(self._masks) do
            refresh(label)
        end
    end))

    self._refreshAll = function()
        for label in pairs(self._masks) do
            refresh(label)
        end
    end
    return self
end

function PrivacyTextMask:SetEnabled(enabled)
    self.Enabled = enabled == true
    if self._refreshAll then self._refreshAll() end
end

function PrivacyTextMask:Destroy()
    if self._destroyed then return end
    self._destroyed = true
    for _, connection in ipairs(self._connections) do
        connection:Disconnect()
    end
    for label, record in pairs(self._masks) do
        if record.Connection then record.Connection:Disconnect() end
        if record.Overlay then record.Overlay:Destroy() end
        self._masks[label] = nil
    end
end

return PrivacyTextMask
