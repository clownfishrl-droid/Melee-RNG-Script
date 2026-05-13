-- HeadshotDamage.server.lua
-- Legitimate Roblox Studio server-side example:
-- Apply extra damage only when your own weapon system reports a validated hit on a character's Head.
-- Put this in ServerScriptService and adapt the RemoteEvent path/name to your game.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Create or replace this with your existing RemoteEvent.
-- Example hierarchy: ReplicatedStorage/WeaponEvents/ReportHit
local weaponEvents = ReplicatedStorage:FindFirstChild("WeaponEvents")
if not weaponEvents then
    weaponEvents = Instance.new("Folder")
    weaponEvents.Name = "WeaponEvents"
    weaponEvents.Parent = ReplicatedStorage
end

local reportHit = weaponEvents:FindFirstChild("ReportHit")
if not reportHit then
    reportHit = Instance.new("RemoteEvent")
    reportHit.Name = "ReportHit"
    reportHit.Parent = weaponEvents
end

local BODY_DAMAGE = 25
local HEADSHOT_MULTIPLIER = 2
local MAX_VALID_DISTANCE = 500

local function getHumanoidFromPart(part)
    if not part or not part:IsA("BasePart") then
        return nil
    end

    local character = part:FindFirstAncestorOfClass("Model")
    if not character then
        return nil
    end

    return character:FindFirstChildOfClass("Humanoid"), character
end

local function isValidHit(shooter, hitPart, origin)
    if not shooter or not shooter.Character then
        return false
    end

    if typeof(origin) ~= "Vector3" then
        return false
    end

    if not hitPart or not hitPart:IsA("BasePart") then
        return false
    end

    local humanoid, targetCharacter = getHumanoidFromPart(hitPart)
    if not humanoid or humanoid.Health <= 0 then
        return false
    end

    local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)
    if targetPlayer and shooter.Team and targetPlayer.Team and shooter.Team == targetPlayer.Team then
        return false
    end

    local shooterRoot = shooter.Character:FindFirstChild("HumanoidRootPart")
    if not shooterRoot then
        return false
    end

    if (shooterRoot.Position - origin).Magnitude > 15 then
        return false
    end

    if (hitPart.Position - origin).Magnitude > MAX_VALID_DISTANCE then
        return false
    end

    -- Basic line-of-sight validation.
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = { shooter.Character }

    local direction = hitPart.Position - origin
    local result = workspace:Raycast(origin, direction, rayParams)

    if not result then
        return false
    end

    return result.Instance == hitPart or result.Instance:IsDescendantOf(targetCharacter)
end

reportHit.OnServerEvent:Connect(function(shooter, hitPart, origin)
    if not isValidHit(shooter, hitPart, origin) then
        return
    end

    local humanoid = getHumanoidFromPart(hitPart)
    if not humanoid then
        return
    end

    local damage = BODY_DAMAGE
    if hitPart.Name == "Head" then
        damage *= HEADSHOT_MULTIPLIER
    end

    humanoid:TakeDamage(damage)
end)

print("HeadshotDamage.server.lua loaded")
