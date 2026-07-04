-- Under Map No-Fall Script
-- Press E to toggle

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local underMap = false
local depth = -8  -- Change this value for deeper/shallower (negative = under)

local connection

local function toggleUnderMap()
    underMap = not underMap

    local char = player.Character
    if char and char:FindFirstChild("HumanoidRootPart") then
        local root = char.HumanoidRootPart
        local humanoid = char:FindFirstChild("Humanoid")

        if humanoid then
            humanoid.PlatformStand = underMap
        end

        if underMap then
            print("🔻 Under Map ENABLED (Depth: " .. depth .. " studs)")
        else
            print("🔺 Under Map DISABLED")
        end
    end
end

-- Main anti-fall + position lock loop
connection = RunService.RenderStepped:Connect(function()
    if not underMap then return end

    local char = player.Character
    if not char then return end

    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    local pos = root.Position
    -- Lock Y position under map
    root.CFrame = CFrame.new(pos.X, root.CFrame.Position.Y + depth, pos.Z) * root.CFrame.Rotation

    -- Zero velocity to prevent falling
    root.Velocity = Vector3.new(0, 0, 0)
    root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
end)

-- Toggle with E key
UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.E then
        toggleUnderMap()
    end
end)

print("📥 Under Map Script Loaded! Press E to toggle.")
