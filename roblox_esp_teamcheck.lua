-- Roblox ESP Script with TeamCheck (Highlight/Box ESP)
-- Fully updated with strong TeamCheck

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local ESP_ENABLED = true
local SHOW_TEAMMATES = false        -- Change to true if you want teammates highlighted too
local ESP_COLOR = Color3.fromRGB(255, 0, 0)      -- Enemy color (red)
local TEAM_COLOR = Color3.fromRGB(0, 255, 0)     -- Teammate color (green)

local drawings = {}

local function createDrawing(player)
    if drawings[player] then return end
    
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
    
    local healthBarOutline = Drawing.new("Square")
    healthBarOutline.Thickness = 1
    healthBarOutline.Filled = false
    healthBarOutline.Transparency = 1
    healthBarOutline.Color = Color3.new(0,0,0)
    
    local healthBar = Drawing.new("Square")
    healthBar.Thickness = 1
    healthBar.Filled = true
    healthBar.Transparency = 1
    
    drawings[player] = {
        Box = box,
        Name = nameTag,
        HealthOutline = healthBarOutline,
        Health = healthBar
    }
end

local function removeESP(player)
    if drawings[player] then
        for _, v in pairs(drawings[player]) do
            if v and v.Remove then v:Remove() end
        end
        drawings[player] = nil
    end
end

local function updateESP()
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

        -- === TEAMCHECK ===
        local isTeammate = (player.Team ~= nil and LocalPlayer.Team ~= nil and player.Team == LocalPlayer.Team)
        
        if isTeammate and not SHOW_TEAMMATES then
            removeESP(player)
            continue
        end

        local color = isTeammate and TEAM_COLOR or ESP_COLOR

        if not drawings[player] then
            createDrawing(player)
        end

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

        -- Box
        esp.Box.Size = Vector2.new(width, height)
        esp.Box.Position = Vector2.new(rootPos.X - width/2, headPos.Y)
        esp.Box.Color = color
        esp.Box.Visible = true

        -- Name
        esp.Name.Text = string.format("%s [%d]", player.Name, math.floor(humanoid.Health))
        esp.Name.Position = Vector2.new(rootPos.X, headPos.Y - 18)
        esp.Name.Color = color
        esp.Name.Visible = true

        -- Health Bar
        local healthPercent = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
        esp.Health.Size = Vector2.new(4, height * healthPercent)
        esp.Health.Position = Vector2.new(esp.Box.Position.X - 8, esp.Box.Position.Y + height * (1 - healthPercent))
        esp.Health.Color = Color3.fromRGB(255 * (1 - healthPercent), 255 * healthPercent, 0)
        esp.Health.Visible = true

        esp.HealthOutline.Size = Vector2.new(4, height)
        esp.HealthOutline.Position = Vector2.new(esp.Box.Position.X - 8, esp.Box.Position.Y)
        esp.HealthOutline.Visible = true
    end
end

-- Cleanup
Players.PlayerRemoving:Connect(removeESP)

-- Toggle
game:GetService("UserInputService").InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.Insert then
        ESP_ENABLED = not ESP_ENABLED
        print("ESP " .. (ESP_ENABLED and "ENABLED ✅" or "DISABLED ❌"))
    end
end)

RunService.RenderStepped:Connect(function()
    if ESP_ENABLED then
        updateESP()
    else
        for plr,_ in pairs(drawings) do
            removeESP(plr)
        end
    end
end)

print("✅ Advanced ESP with TeamCheck loaded! Press INSERT to toggle.")
print("Teammates are hidden by default. Change SHOW_TEAMMATES = true if you want them.")