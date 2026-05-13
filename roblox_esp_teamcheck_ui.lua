-- Roblox ESP with TeamCheck + Simple UI + Auto Enemy Detection
-- Press INSERT to toggle the whole ESP

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local ESP_ENABLED = true
local SHOW_TEAMMATES = false  -- Auto handled, but you can force it

local drawings = {}

-- Simple UI
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "ESP_Control"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local Frame = Instance.new("Frame")
Frame.Size = UDim2.new(0, 220, 0, 180)
Frame.Position = UDim2.new(0, 10, 0, 10)
Frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
Frame.BorderSizePixel = 0
Frame.Parent = ScreenGui

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, 0, 0, 30)
Title.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
Title.Text = "ESP Control - Auto TeamCheck"
Title.TextColor3 = Color3.new(1,1,1)
Title.Font = Enum.Font.SourceSansBold
Title.TextSize = 16
Title.Parent = Frame

local ToggleESP = Instance.new("TextButton")
ToggleESP.Size = UDim2.new(0.9, 0, 0, 35)
ToggleESP.Position = UDim2.new(0.05, 0, 0, 40)
ToggleESP.BackgroundColor3 = Color3.fromRGB(0, 170, 0)
ToggleESP.Text = "ESP: ENABLED"
ToggleESP.TextColor3 = Color3.new(1,1,1)
ToggleESP.Font = Enum.Font.SourceSansBold
ToggleESP.TextSize = 14
ToggleESP.Parent = Frame

local ToggleTeammates = Instance.new("TextButton")
ToggleTeammates.Size = UDim2.new(0.9, 0, 0, 35)
ToggleTeammates.Position = UDim2.new(0.05, 0, 0, 85)
ToggleTeammates.BackgroundColor3 = Color3.fromRGB(100, 100, 100)
ToggleTeammates.Text = "Show Teammates: OFF"
ToggleTeammates.TextColor3 = Color3.new(1,1,1)
ToggleTeammates.Font = Enum.Font.SourceSansBold
ToggleTeammates.TextSize = 14
ToggleTeammates.Parent = Frame

local Status = Instance.new("TextLabel")
Status.Size = UDim2.new(0.9, 0, 0, 40)
Status.Position = UDim2.new(0.05, 0, 0, 130)
Status.BackgroundTransparency = 1
Status.Text = "Auto detecting teams..."
Status.TextColor3 = Color3.fromRGB(200, 200, 200)
Status.TextScaled = true
Status.Parent = Frame

-- Draggable UI
local dragging, dragInput, dragStart, startPos
Frame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = input.Position
        startPos = Frame.Position
    end
end)
Frame.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = false
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        local delta = input.Position - dragStart
        Frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)

ToggleESP.MouseButton1Click:Connect(function()
    ESP_ENABLED = not ESP_ENABLED
    ToggleESP.Text = "ESP: " .. (ESP_ENABLED and "ENABLED" or "DISABLED")
    ToggleESP.BackgroundColor3 = ESP_ENABLED and Color3.fromRGB(0,170,0) or Color3.fromRGB(170,0,0)
end)

ToggleTeammates.MouseButton1Click:Connect(function()
    SHOW_TEAMMATES = not SHOW_TEAMMATES
    ToggleTeammates.Text = "Show Teammates: " .. (SHOW_TEAMMATES and "ON" or "OFF")
end)

-- ESP Functions (same as before but cleaner)
local function createDrawing(player)
    if drawings[player] then return end
    -- ... (box, name, health code same as previous version)
    local box = Drawing.new("Square")
    box.Thickness = 2
    box.Filled = false
    box.Transparency = 1

    local nameTag = Drawing.new("Text")
    nameTag.Size = 14
    nameTag.Center = true
    nameTag.Outline = true
    nameTag.OutlineColor = Color3.new(0,0,0)
    nameTag.Font = 2

    local healthOutline = Drawing.new("Square")
    healthOutline.Thickness = 1
    healthOutline.Filled = false
    healthOutline.Color = Color3.new(0,0,0)

    local healthBar = Drawing.new("Square")
    healthBar.Thickness = 1
    healthBar.Filled = true
    healthBar.Transparency = 1

    drawings[player] = {Box = box, Name = nameTag, HealthOutline = healthOutline, Health = healthBar}
end

local function removeESP(player)
    if drawings[player] then
        for _, v in pairs(drawings[player]) do
            if v.Remove then v:Remove() end
        end
        drawings[player] = nil
    end
end

local function updateESP()
    if not ESP_ENABLED then return end

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer or not player.Character then
            removeESP(player)
            continue
        end

        local character = player.Character
        local root = character:FindFirstChild("HumanoidRootPart")
        local humanoid = character:FindFirstChild("Humanoid")
        local head = character:FindFirstChild("Head")

        if not root or not humanoid then
            removeESP(player)
            continue
        end

        -- Auto TeamCheck
        local isTeammate = false
        if player.Team and LocalPlayer.Team then
            isTeammate = (player.Team == LocalPlayer.Team)
        end

        if isTeammate and not SHOW_TEAMMATES then
            removeESP(player)
            continue
        end

        local color = isTeammate and Color3.fromRGB(0, 255, 0) or Color3.fromRGB(255, 0, 0)

        if not drawings[player] then createDrawing(player) end
        local esp = drawings[player]

        local rootPos, onScreen = Camera:WorldToViewportPoint(root.Position)
        if not onScreen then
            esp.Box.Visible = false
            esp.Name.Visible = false
            esp.Health.Visible = false
            esp.HealthOutline.Visible = false
            continue
        end

        local headPos = head and Camera:WorldToViewportPoint(head.Position + Vector3.new(0,0.5,0)) or rootPos
        local legPos = Camera:WorldToViewportPoint(root.Position - Vector3.new(0,3,0))

        local height = math.abs(headPos.Y - legPos.Y)
        local width = height * 0.55

        esp.Box.Size = Vector2.new(width, height)
        esp.Box.Position = Vector2.new(rootPos.X - width/2, headPos.Y)
        esp.Box.Color = color
        esp.Box.Visible = true

        esp.Name.Text = string.format("%s [%d]", player.Name, math.floor(humanoid.Health))
        esp.Name.Position = Vector2.new(rootPos.X, headPos.Y - 18)
        esp.Name.Color = color
        esp.Name.Visible = true

        local hp = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
        esp.Health.Size = Vector2.new(4, height * hp)
        esp.Health.Position = Vector2.new(esp.Box.Position.X - 8, esp.Box.Position.Y + height * (1 - hp))
        esp.Health.Color = Color3.fromRGB(255 * (1 - hp), 255 * hp, 0)
        esp.Health.Visible = true

        esp.HealthOutline.Size = Vector2.new(4, height)
        esp.HealthOutline.Position = Vector2.new(esp.Box.Position.X - 8, esp.Box.Position.Y)
        esp.HealthOutline.Visible = true
    end
end

-- Cleanup
Players.PlayerRemoving:Connect(removeESP)

-- Toggle with INSERT
UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.Insert then
        ESP_ENABLED = not ESP_ENABLED
        ToggleESP.Text = "ESP: " .. (ESP_ENABLED and "ENABLED" or "DISABLED")
        ToggleESP.BackgroundColor3 = ESP_ENABLED and Color3.fromRGB(0,170,0) or Color3.fromRGB(170,0,0)
    end
end)

-- Main loop
RunService.RenderStepped:Connect(updateESP)

print("✅ ESP with UI + Auto Team Detection loaded!")
print("UI is in top-left. Drag it around. INSERT to toggle.")