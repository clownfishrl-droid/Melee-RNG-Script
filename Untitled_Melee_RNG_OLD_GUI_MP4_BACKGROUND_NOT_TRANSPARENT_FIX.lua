--[[
  Melee RNG — Untitled mellee.lua
  ---------------------------------------------------------------------------
  Main chunk order (top → bottom):
    1. Bootstrap     — NexusLib, services, LocalPlayer, GEN, cleanup
    2. Core helpers  — character, leaderstats, remotes (R, fireR, invokeR, invokeR2)
    3. Game data     — guild/AP constants, mobs, damage, state, settings JSON
    4. Feature code  — GUI click helpers, ascend TP/aura, upgrade math, farm…
    5. UI IIFE       — Lib window (tabs); kept separate for Luau local limit
    6. Tail          — re-exec arm, deferred PlayerGui, ready status
  ---------------------------------------------------------------------------
]]

local NEXUSLIB_URL = "https://raw.githubusercontent.com/headshot7535-png/Nexuslib/main/Nexuslib"
local SCRIPT_URL   = "https://raw.githubusercontent.com/headshot7535-png/Untitled-Melee-RNG/main/Untitled%20Melee%20RNG"

-- ── Load NexusLib ─────────────────────────────────────────────
local Lib
if readfile and pcall then
    local ok, data = pcall(readfile, "NexusLib.lua")
    if ok and type(data) == "string" and #data > 500 then
        local loadOk, result = pcall(loadstring, data)
        if loadOk then Lib = result() end
    end
end
if not Lib then
    local ok, err = pcall(function()
        Lib = loadstring(game:HttpGet(NEXUSLIB_URL))()
    end)
    if not ok or not Lib then
        error("[MeleeRNG] NexusLib failed to load: " .. tostring(err))
    end
end

-- ── Services ──────────────────────────────────────────────────
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local VirtualUser      = game:GetService("VirtualUser")
local Lighting         = game:GetService("Lighting")
local HttpService      = game:GetService("HttpService")
local RS               = game:GetService("ReplicatedStorage")
local CollectionService= game:GetService("CollectionService")

-- ── Wait for full load ────────────────────────────────────────
task.wait(2)
local LP
for _ = 1, 60 do
    LP = Players.LocalPlayer
    if LP and LP:FindFirstChildOfClass("PlayerGui") then break end
    task.wait(0.3)
end
if not LP then error("[MeleeRNG] LocalPlayer not ready") end

-- ── Re-exec generation token ──────────────────────────────────
_G.MeleeRNG_Gen = (_G.MeleeRNG_Gen or 0) + 1
local GEN = _G.MeleeRNG_Gen

-- OFF = no [MeleeRNG/Sac] / Totem spam in F9 (same logic; only console output gated).
local MeleeRNG_VERBOSE_CONSOLE = false
local function vprint(...)
    if MeleeRNG_VERBOSE_CONSOLE then print(...) end
end

-- ── Cleanup system ────────────────────────────────────────────
local _conns    = {}
local _threads  = {}
local _stopped  = false

local function addConn(c)  _conns[#_conns+1] = c end
local function addThread(t) _threads[#_threads+1] = t end
local function cleanupAll()
    _stopped = true
    for _, c in ipairs(_conns)   do pcall(function() c:Disconnect() end) end
    for _, t in ipairs(_threads) do pcall(function() task.cancel(t) end) end
    _conns = {}; _threads = {}
end

-- ── Base helpers ──────────────────────────────────────────────
local function getChar()  return LP.Character end
local function getRoot()  local c=getChar() return c and c:FindFirstChild("HumanoidRootPart") end
local function getHuman() local c=getChar() return c and c:FindFirstChildOfClass("Humanoid") end
local function alive()    local h=getHuman() return h and h.Health > 0 end

-- ── Leaderstats discovery (emoji keys — confirmed from dump) ──
-- Uses WaitForChild polling so emoji bytes resolve correctly
local _ls = nil
local function getLS()
    if _ls and _ls.Parent then return _ls end
    _ls = LP:FindFirstChild("leaderstats")
    return _ls
end
-- Cached leaderstat references (avoid repeated FindFirstChild scans)
local _cachedStats = {}
local function getCachedStat(name)
    if _cachedStats[name] and _cachedStats[name].Parent then
        return _cachedStats[name].Value
    end
    local ls = getLS(); if not ls then return 0 end
    for _, child in ipairs(ls:GetChildren()) do
        if child.Name:find(name, 1, true) then
            _cachedStats[name] = child
            return child.Value
        end
    end
    return 0
end
local function getKills()   return getCachedStat("Kills") end
local function getMana()    return getCachedStat("Mana") end
local function getSP()      return getCachedStat("SP") end
local function getAscends() return getCachedStat("Ascends") end
-- Ascend kill gate (AscendUIController): "2 + v8 .. M Kills" where v8 = current ascend count — not area MinimumKills
local function getAscendKillsRequired()
    return (2 + (tonumber(getAscends()) or 0)) * 1000000
end

-- Default post-ascend TP (Forgotten Valley — original log); player can override in Misc → Ascend
local DEF_ASCEND_TP_X, DEF_ASCEND_TP_Y, DEF_ASCEND_TP_Z = 496.9, 222.1, -7380.4

-- ── Remote cache ─────────────────────────────────────────────
local _remotes = {}
local function R(name)
    if _remotes[name] and _remotes[name].Parent then return _remotes[name] end
    local r = RS:FindFirstChild("Remotes")
    if not r then return nil end
    _remotes[name] = r:FindFirstChild(name)
    return _remotes[name]
end
local function fireR(name, ...)
    local r = R(name); if not r then return end
    local args = table.pack(...)
    return pcall(function() r:FireServer(table.unpack(args, 1, args.n)) end)
end
local function invokeR(name, ...)
    local r = R(name); if not r then return nil end
    local args = table.pack(...)
    local ok, res = pcall(function() return r:InvokeServer(table.unpack(args, 1, args.n)) end)
    return ok and res or nil
end

--- Multi-return InvokeServer: ok, first, second (guild buff / AP level + GP).
local function invokeR2(name, ...)
    local r = R(name)
    if not r then return false, nil, nil end
    local args = table.pack(...)
    local pack = { pcall(function()
        return r:InvokeServer(table.unpack(args, 1, args.n))
    end) }
    if not pack[1] then return false, nil, nil end
    return true, pack[2], pack[3]
end

-- ── Guild (GuildUIController + SharedConstants.GuildConstants) ─────────
local _guildBuffDefs = nil
pcall(function()
    local sc = RS:FindFirstChild("SharedConstants")
    local m = sc and sc:FindFirstChild("GuildConstants")
    if m and m:IsA("ModuleScript") then
        local gc = require(m)
        if type(gc) == "table" and type(gc.GuildBuffs) == "table" then
            _guildBuffDefs = gc.GuildBuffs
        end
    end
end)

local GUILD_BUFF_ORDER = {
    "Roll Speed", "Kill Multiplier", "Mana Multiplier", "Damage Multiplier", "Max Guild Members",
}

local GUILD_BUFF_COST_FALLBACK = {
    ["Roll Speed"] = function(l) return 5 + l * 20 end,
    ["Kill Multiplier"] = function(l) return 20 + l * 10 end,
    ["Mana Multiplier"] = function(l) return 7 + l * 15 end,
    ["Damage Multiplier"] = function(l) return 10 + l * 10 end,
    ["Max Guild Members"] = function(l) return 10 + l * 20 end,
}

local function guildBuffNextCost(buffName, currentLevel)
    local l = math.max(0, math.floor(tonumber(currentLevel) or 0))
    local def = _guildBuffDefs and _guildBuffDefs[buffName]
    if def and type(def.Cost) == "function" then
        return def.Cost(l)
    end
    local f = GUILD_BUFF_COST_FALLBACK[buffName]
    return f and f(l) or math.huge
end

local function fetchGuildState()
    local r = R("GetAssignedGuild")
    if not r then return nil end
    local ok, g = pcall(function() return r:InvokeServer(true) end)
    if ok and type(g) == "table" and g.GuildID then return g end
    ok, g = pcall(function() return r:InvokeServer() end)
    if ok and type(g) == "table" and g.GuildID then return g end
    return nil
end

local function guildPlayerIsMember(g)
    if not g or type(g.Members) ~= "table" then return false end
    local id = LP.UserId
    return g.Members[tostring(id)] ~= nil or g.Members[id] ~= nil
end

-- ── Ascend AP statues (AscendUpgradesController + AscendUpgrades) ───────
-- Dump: GetAscendUpgrades, GetAscendPoints, UpgradeAscend(upgradeName); max L10
local _ascendApDefs = nil
pcall(function()
    local sc = RS:FindFirstChild("SharedConstants")
    local m = sc and sc:FindFirstChild("AscendUpgrades")
    if m and m:IsA("ModuleScript") then
        local t = require(m)
        if type(t) == "table" then _ascendApDefs = t end
    end
end)

local ASCEND_AP_MAX_LEVEL = 10

local ASCEND_AP_ORDER = {
    "Boss Raid SP Multiplier",
    "Faster Rolls",
    "Zombie with weapon chance",
    "Double weapon chance",
    "Ascend points upgrade",
    "Chance to keep upgrade when ascend",
    "Totem Of Fortune Sacrifices",
}

local ASCEND_AP_COST_FALLBACK = {
    ["Boss Raid SP Multiplier"] = function(nextL) return 2 * nextL end,
    ["Faster Rolls"] = function(nextL) return 2 * nextL end,
    ["Zombie with weapon chance"] = function(nextL) return 3 * nextL end,
    ["Double weapon chance"] = function(nextL) return 3 * nextL end,
    ["Ascend points upgrade"] = function(nextL) return 4 * nextL end,
    ["Chance to keep upgrade when ascend"] = function(nextL) return 4 * nextL end,
    ["Totem Of Fortune Sacrifices"] = function(nextL) return 2 * nextL end,
}

local function ascendApNextCost(name, currentLevel)
    local lv = math.max(0, math.floor(tonumber(currentLevel) or 0))
    if lv >= ASCEND_AP_MAX_LEVEL then return math.huge end
    local nextL = lv + 1
    local def = _ascendApDefs and _ascendApDefs[name]
    if def and type(def.Cost) == "function" then
        return def.Cost(nextL)
    end
    local f = ASCEND_AP_COST_FALLBACK[name]
    return f and f(nextL) or math.huge
end

local function parseAscendPoints(raw)
    if type(raw) == "number" and raw == raw then return math.floor(math.max(0, raw)) end
    if type(raw) == "string" then
        local stripped = raw:gsub("[^%d]", "")
        if stripped ~= "" then
            local n = tonumber(stripped)
            if n then return math.floor(math.max(0, n)) end
        end
        local n2 = tonumber(raw)
        return n2 and math.floor(math.max(0, n2)) or 0
    end
    return 0
end

-- ── Live mob table (mirrors MobsClientController u19) ─────────
-- workspace.Mobs: Model + HumanoidRootPart + attribute "ID". No Humanoid on mobs.
local MOB_DATA = {} -- [modelRef] = { id, model, root, boss, megaBoss }

local function isMobAlive(model)
    if not (model and model.Parent) then return false end
    local hrp = model:FindFirstChild("HumanoidRootPart")
    return hrp ~= nil and model:GetAttribute("ID") ~= nil
end

local function getNearestMob(filterFn)
    local root = getRoot(); if not root then return nil end
    local mobsFolder = workspace:FindFirstChild("Mobs")
    if not mobsFolder then return nil end
    local best, bestDist = nil, math.huge
    for _, model in ipairs(mobsFolder:GetChildren()) do
        if model:IsA("Model") and isMobAlive(model) then
            if not filterFn or filterFn(model) then
                local hrp = model:FindFirstChild("HumanoidRootPart")
                local d = (root.Position - hrp.Position).Magnitude
                if d < bestDist then bestDist = d; best = model end
            end
        end
    end
    return best, bestDist
end

local function countAliveMobs()
    local mobsFolder = workspace:FindFirstChild("Mobs"); if not mobsFolder then return 0 end
    local n = 0
    for _, m in pairs(mobsFolder:GetChildren()) do
        if m:IsA("Model") and isMobAlive(m) then n = n + 1 end
    end
    return n
end

local function refreshMobData()
    MOB_DATA = {}
    local mobsFolder = workspace:FindFirstChild("Mobs")
    if not mobsFolder then return end
    for _, model in ipairs(mobsFolder:GetChildren()) do
        if model:IsA("Model") and isMobAlive(model) then
            local hrp = model:FindFirstChild("HumanoidRootPart")
            local id  = model:GetAttribute("ID") or model.Name
            MOB_DATA[model] = {
                id       = id,
                model    = model,
                root     = hrp,
                boss     = model:GetAttribute("Boss") == true,
                megaBoss = model:GetAttribute("MegaBoss") == true,
            }
        end
    end
end

-- ── Damage multiplier (live from server) ──────────────────────
local _dmgMulti = 0
local function getDmgMulti()
    local v = invokeR("GetUpgradeValue", "Damage Multiplier")
    if type(v) == "number" then _dmgMulti = v end
    return _dmgMulti
end
-- ── State ─────────────────────────────────────────────────────
local states = {
    autoEquipBest  = false,
    autoAscend     = false,
    -- Auto Farm cycle: TP → raid/upgrades if needed → farm → then ⬆️ Auto Ascend handles ConfirmAscend; turn both ON together
    autoCycleFarm  = false,
    farmBoss       = true,   -- ON by default: higher areas spawn bosses
    farmMegaBoss   = false,
    skipRegular    = false,
    noclip         = false,
    godMode        = false,
    fly            = false,
    infJump        = false,
    antiAfk        = false,
    fullBright     = false,
    espMobs        = false,
    autoSave       = true,
    showAutoRaid   = false,
    showHideMobs   = false,
    mouseUnlockN   = false, -- N hotkey: keep Roblox mouse free/unlocked in first person
    uiVideoBackground = true, -- old GUI only: local PNG background behind NexusLib window
    -- MainGUI.GeneralUI (client visibility only; see applyMeleeGameUiHiding)
    uiHideManaKills = false, -- ManaFrame + KillsFrame + StageProgress (combat bar)
    uiHideMiniRoll  = false, -- MiniRollFrame (mini-roll animations UI)
    uiHideHud       = false, -- entire GeneralUI (hides all of the above while ON)
    uiHideNotifications = false, -- MainGUI.NotifFrame (NotifUIManager / SP & sacrifice toasts)
    autoReExec     = false,
    hitboxPulse    = false,
    hitboxDutyCycle  = 2,  -- BIG on 1 frame per N heartbeats (2 = half the frames big, old behavior; 6+ = mostly tiny, less physics lag)
    autoUpgradeOn  = false,  -- master Auto Upgrade loop (saved with other toggles)
    upgradeSequentialMode = true, -- Ordered Chain: buy first ON upgrade to its target level, then move to the next.
    autoManaToSP   = false,  -- Heartbeat: price check + ConvertMana(1); backoff if server returns false
    -- Guild: BuyGP(SP) → GP; BuyGuildBuff(guildId, name) — dump GuildUIController
    autoGuildSpToGp = false,  -- members: spend SP down to guildSpReserve
    guildSpReserve  = 0,      -- min SP to keep when auto SP→GP
    autoGuildBuffs  = false,  -- guild owner: buy cheapest affordable buff each tick
    -- Ascend Points statues (castle): GetAscendUpgrades + UpgradeAscend — dump AscendUpgradesController
    autoApUpgrades  = false,  -- buy cheapest affordable AP upgrade among toggled rows (L0–L10)
    -- After ascend: TP target (HumanoidRootPart + 3 studs Y); set via Misc → Ascend
    ascendAfterTpX = DEF_ASCEND_TP_X,
    ascendAfterTpY = DEF_ASCEND_TP_Y,
    ascendAfterTpZ = DEF_ASCEND_TP_Z,
    -- After ascend, AuraRollUI (KEEP AURA = Options.ConfirmBtn) — wait, confirm, then TP (AuraRollController dump)
    ascendAuraKeepBeforeTp = true,
    -- Equipped = Character.SelectedAura; remotes GetUnlockedAuras / SelectAura (AuraSelectionController dump)
    auraPreferredName = "",
    auraMaintainSelection = false,
    -- Sacrifice (Fountain) — OneIn tiers from RS.Assets.Weapons; only By color + By name
    autoSacrifice    = false,
    sacFilterColor   = false,  -- OneIn ≤ selected tier max (game color / rarity)
    sacFilterName    = false,
    sacRarityCapIdx  = 1,     -- 1–9 = dropdown tier cap (see SAC_TIERS)
    sacKeepQty       = 0,    -- 0–999; persisted + synced on load
    -- Totem of Fortune — TotemConfirm(weaponName); cap 25 + AP level×5; 1h CD when server returns false
    -- Filters are separate from Fountain sacrifice (own color cap + keep qty)
    autoTotem           = false,
    totemFilterColor    = true,   -- Totem requires this ON; default ON for Galactic-band auto
    totemRarityCapIdx   = 7,      -- 7 = Galactic (1M,7M] OneIn; change dropdown for other tiers
    totemKeepQty        = 0,
    totemDoneThisCycle  = 0,
    totemCapHitUnix     = nil, -- os.time() when server capped (starts 1h cycle lock)
    totemSavedServerCap = nil, -- parsed/confirmed max; survives re-exec (see LS merge below)
    totemCapFromServerNotify = false, -- "server confirmed" banner until CD ends
    -- Totem color = OneIn range; ticked rows = which names in that range may be sacrificed (like Cobalt)
    totemOnlyTickedNames    = false,
    -- Client-only performance (no matching remotes in dump): spinning weapons live under workspace.[PlayerName]
    perfHideOtherWeapons = false,
    perfHideOwnWeapons   = false,
    perfHideAllEffects   = false,
    perfDisableShadows   = false, -- Lighting.GlobalShadows
    perfHideLootDrops    = false, -- workspace.Loot (dump LootController)
    perfHideMobManaOrbs  = false, -- MobsClientController: script.Mana → workspace (pink pickup; not under Loot)
    perfHideHitboxVisuals = false, -- parts named Hitbox under workspace[you] weapons (white range rings); skip if Hide Own Weapons on
    perfMuteWorldSounds  = false, -- Sound instances under workspace
    perfCompatLighting   = false, -- Lighting.Technology → Compatibility
    perfLowGraphicsQuality = false, -- UserGameSettings quality (executor/client dependent)
    perfHideOtherCharacters = false, -- other players’ Character rigs invisible locally (intrusive)
}

-- Auto Farm cycle: live status (not in states — avoids persisting to settings JSON)
-- raidPhaseActive = raid+upgrade inner loop only. farmPhaseActive = farm-kills inner loop only.
-- Nudge raid ON only when raid phase and not farm phase (never touch raid during farming).
local meleeAutoFarmStatus = { line = "🔁 Farm cycle: OFF", raidPhaseActive = false, farmPhaseActive = false }

-- Upgrade names for save/load (must exist before saveSettings references upgradeSelected)
local UPGRADE_ORDER = {
    -- Priority order: top rows are handled first by Ordered Chain mode.
    "Skill Point Multiplier",
    "Mana Multiplier",
    "Enemy Limit",
    "Enemy Spawn Rate",
    "Weapons Equipped",
    "Damage Multiplier",
    "Spin Speed",
    "Kill Multiplier",
}

local upgradeSelected = {}  -- [upgradeName] = bool — filled from LS below
local upgradeLevelCap = {} -- [upgradeName] = target/stop level; Ordered Chain uses it as the required level before moving to the next row. nil = no target/no cap
local guildBuffSelected = {} -- [buffName] = bool — which guild buffs auto-buy may purchase
for _, gn in ipairs(GUILD_BUFF_ORDER) do
    guildBuffSelected[gn] = true
end
local apUpgradeSelected = {} -- [AscendUpgrades key] = bool
for _, an in ipairs(ASCEND_AP_ORDER) do
    apUpgradeSelected[an] = true
end
local _sacNameSelected = {} -- [weaponName] = bool — Sacrifice "By Name" picks (persisted)

local walkSpeedVal   = 16
-- BIG-phase default: map-tuned — huge boxes add overlap pairs and tank KPM vs ~500 (Test 8b ~5.5x).
local hitboxSize     = 500
local flyBV, flyBG
local espBillboards  = {}
local _hitboxCacheDirty = true

-- ── Settings persistence ──────────────────────────────────────
local SETTINGS_FILE = "meleernq_settings.json"
local function saveSettings()
    pcall(function()
        local t = {}
        for k, v in pairs(states) do t[k] = v end
        t.walkSpeedVal = walkSpeedVal
        local up = {}
        for _, name in ipairs(UPGRADE_ORDER) do
            up[name] = upgradeSelected[name] == true
        end
        t.upgradeSelected = up
        local gbs = {}
        for _, gn in ipairs(GUILD_BUFF_ORDER) do
            gbs[gn] = guildBuffSelected[gn] == true
        end
        t.guildBuffSelected = gbs
        local aps = {}
        for _, an in ipairs(ASCEND_AP_ORDER) do
            aps[an] = apUpgradeSelected[an] == true
        end
        t.apUpgradeSelected = aps
        local ucaps = {}
        for _, un in ipairs(UPGRADE_ORDER) do
            local c = upgradeLevelCap[un]
            if type(c) == "number" and c >= 1 then ucaps[un] = math.floor(c) end
        end
        t.upgradeLevelCap = ucaps
        t.hitboxSize = hitboxSize
        local sacNames = {}
        for name, on in pairs(_sacNameSelected) do
            if on then sacNames[#sacNames + 1] = name end
        end
        table.sort(sacNames)
        t.sacNamesSelected = sacNames
        writefile(SETTINGS_FILE, HttpService:JSONEncode(t))
    end)
end
local function forceSave()
    saveSettings()
end
local LS = {}
pcall(function()
    if isfile and isfile(SETTINGS_FILE) then
        local ok, d = pcall(function()
            return HttpService:JSONDecode(readfile(SETTINGS_FILE))
        end)
        if ok and type(d) == "table" then LS = d end
    end
end)
for k in pairs(states) do if LS[k] ~= nil then states[k] = LS[k] end end
if LS.walkSpeedVal then walkSpeedVal = LS.walkSpeedVal end
if LS.autoSave     then states.autoSave     = LS.autoSave     end
if LS.showAutoRaid then states.showAutoRaid = LS.showAutoRaid end
if LS.showHideMobs then states.showHideMobs = LS.showHideMobs end
if LS.hitboxSize ~= nil then
    local n = tonumber(LS.hitboxSize)
    if n then
        n = math.max(10, math.min(100000, math.floor(n)))
        -- Old presets used 100k / 60k / 25k BIG; map-tuned targets are 500 / 500 / 350.
        if n >= 50000 then
            n = 500
        elseif n >= 15000 then
            n = 350
        end
        hitboxSize = n
    end
end
if type(LS.upgradeSelected) == "table" then
    for _, name in ipairs(UPGRADE_ORDER) do
        local v = LS.upgradeSelected[name]
        upgradeSelected[name] = (v == true or v == 1)
    end
end
if type(LS.guildBuffSelected) == "table" then
    for _, gn in ipairs(GUILD_BUFF_ORDER) do
        local v = LS.guildBuffSelected[gn]
        if v ~= nil then
            guildBuffSelected[gn] = (v == true or v == 1)
        end
    end
end
if type(LS.apUpgradeSelected) == "table" then
    for _, an in ipairs(ASCEND_AP_ORDER) do
        local v = LS.apUpgradeSelected[an]
        if v ~= nil then
            apUpgradeSelected[an] = (v == true or v == 1)
        end
    end
end
if type(LS.upgradeLevelCap) == "table" then
    for _, name in ipairs(UPGRADE_ORDER) do
        local v = tonumber(LS.upgradeLevelCap[name])
        if v and v >= 1 then upgradeLevelCap[name] = math.floor(v) end
    end
end
if type(LS.sacNamesSelected) == "table" then
    _sacNameSelected = {}
    for _, n in ipairs(LS.sacNamesSelected) do
        if type(n) == "string" then _sacNameSelected[n] = true end
    end
end
states.autoUpgradeOn = states.autoUpgradeOn == true
-- Force ordered upgrades only; ignore older saved non-ordered mode.
states.upgradeSequentialMode = true
states.autoAscend    = states.autoAscend == true
states.autoCycleFarm = states.autoCycleFarm == true
states.autoSacrifice = states.autoSacrifice == true
states.autoManaToSP  = states.autoManaToSP == true
states.autoEquipBest = states.autoEquipBest == true
if LS.sacFilterColor ~= nil then
    states.sacFilterColor = LS.sacFilterColor == true
elseif LS.sacFilterRarity ~= nil then
    states.sacFilterColor = LS.sacFilterRarity == true
end
states.sacFilterColor = states.sacFilterColor == true
states.sacFilterName  = states.sacFilterName == true
states.sacRarityCapIdx = math.clamp(math.floor(tonumber(states.sacRarityCapIdx) or 1), 1, 9)
states.sacKeepQty      = math.clamp(math.floor(tonumber(states.sacKeepQty) or 0), 0, 999)
states.ascendAfterTpX  = tonumber(states.ascendAfterTpX) or DEF_ASCEND_TP_X
states.ascendAfterTpY  = tonumber(states.ascendAfterTpY) or DEF_ASCEND_TP_Y
states.ascendAfterTpZ  = tonumber(states.ascendAfterTpZ) or DEF_ASCEND_TP_Z
if LS.ascendAuraKeepBeforeTp ~= nil then
    states.ascendAuraKeepBeforeTp = LS.ascendAuraKeepBeforeTp == true
else
    states.ascendAuraKeepBeforeTp = states.ascendAuraKeepBeforeTp ~= false
end
if type(states.auraPreferredName) == "string" then
    states.auraPreferredName = states.auraPreferredName:gsub("^%s+", ""):gsub("%s+$", "")
else
    states.auraPreferredName = ""
end
states.auraMaintainSelection = states.auraMaintainSelection == true

states.autoTotem = states.autoTotem == true
states.totemOnlyTickedNames = states.totemOnlyTickedNames == true
states.totemFilterColor = states.totemFilterColor == true
states.totemRarityCapIdx = math.clamp(math.floor(tonumber(states.totemRarityCapIdx) or 1), 1, 9)
states.totemKeepQty = math.clamp(math.floor(tonumber(states.totemKeepQty) or 0), 0, 999)
states.totemDoneThisCycle = math.max(0, math.floor(tonumber(states.totemDoneThisCycle) or 0))
states.autoGuildSpToGp = states.autoGuildSpToGp == true
states.autoGuildBuffs = states.autoGuildBuffs == true
states.autoApUpgrades = states.autoApUpgrades == true
states.perfHideOtherWeapons = states.perfHideOtherWeapons == true
states.perfHideOwnWeapons = states.perfHideOwnWeapons == true
states.perfHideAllEffects = states.perfHideAllEffects == true
states.perfDisableShadows = states.perfDisableShadows == true
states.perfHideLootDrops = states.perfHideLootDrops == true
states.perfHideMobManaOrbs = states.perfHideMobManaOrbs == true
states.perfHideHitboxVisuals = states.perfHideHitboxVisuals == true
states.perfMuteWorldSounds = states.perfMuteWorldSounds == true
states.perfCompatLighting = states.perfCompatLighting == true
states.perfLowGraphicsQuality = states.perfLowGraphicsQuality == true
states.perfHideOtherCharacters = states.perfHideOtherCharacters == true
states.uiHideManaKills = states.uiHideManaKills == true
states.uiHideMiniRoll  = states.uiHideMiniRoll == true
states.uiHideHud       = states.uiHideHud == true
states.uiHideNotifications = states.uiHideNotifications == true
states.guildSpReserve = math.clamp(math.floor(tonumber(states.guildSpReserve) or 0), 0, 100000000)
states.mouseUnlockN = states.mouseUnlockN == true
states.uiVideoBackground = states.uiVideoBackground ~= false
-- Totem CD/cap from LS applied in totem block (after TOTEM_CYCLE_SEC) + sanitize vs os.time()

-- ── Mouse unlock hotkey (N) ───────────────────────────────────
-- Correct Roblox-native method for forced first person:
-- keep a visible GuiButton with Modal=true while unlock is ON.
-- GuiButton.Modal releases first-person mouse lock without changing zoom/camera.
local mouseUnlockToggle = nil
local mouseUnlockStatusLbl = nil
local MOUSE_UNLOCK_GUI_NAME = "MeleeRNG_MouseUnlockN_Modal"
local MOUSE_UNLOCK_BUTTON_NAME = "ModalMouseUnlockButton"

local function mouseUnlockStatusText()
    return states.mouseUnlockN and "Mouse unlock: ON — Modal button active (press N to lock normally)" or "Mouse unlock: OFF — press N to unlock mouse in first person"
end

local function mouseUnlockRefreshUi()
    pcall(function()
        if mouseUnlockStatusLbl and mouseUnlockStatusLbl.Set then
            mouseUnlockStatusLbl.Set(mouseUnlockStatusText())
        end
        if mouseUnlockToggle and mouseUnlockToggle.Set then
            mouseUnlockToggle.Set(states.mouseUnlockN == true)
        end
    end)
end

local function mouseUnlockGetPlayerGui()
    return LP and LP:FindFirstChildOfClass("PlayerGui")
end

local function mouseUnlockGetOrCreateModalButton()
    local pg = mouseUnlockGetPlayerGui()
    if not pg then return nil end

    local sg = pg:FindFirstChild(MOUSE_UNLOCK_GUI_NAME)
    if not sg then
        sg = Instance.new("ScreenGui")
        sg.Name = MOUSE_UNLOCK_GUI_NAME
        sg.ResetOnSpawn = false
        sg.IgnoreGuiInset = true
        sg.DisplayOrder = 2147483647
        sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        sg.Parent = pg
    end

    local btn = sg:FindFirstChild(MOUSE_UNLOCK_BUTTON_NAME)
    if not btn then
        btn = Instance.new("TextButton")
        btn.Name = MOUSE_UNLOCK_BUTTON_NAME
        btn.Text = ""
        btn.BackgroundTransparency = 1
        btn.TextTransparency = 1
        btn.BorderSizePixel = 0
        -- 0×0 keeps it from covering/capturing normal UI clicks, but Visible+Modal
        -- still tells Roblox first-person camera to release the cursor.
        btn.Size = UDim2.new(0, 0, 0, 0)
        btn.Position = UDim2.new(0, 0, 0, 0)
        btn.AutoButtonColor = false
        btn.Active = true
        btn.Selectable = false
        btn.ZIndex = 2147483647
        btn.Parent = sg
    end

    return btn, sg
end

local function applyMouseUnlockN()
    local btn, sg = mouseUnlockGetOrCreateModalButton()
    if not btn or not sg then return end

    local on = states.mouseUnlockN == true
    sg.Enabled = on
    btn.Visible = on
    btn.Modal = on

    if on then
        -- Keep the icon visible, but do not change zoom/camera mode.
        pcall(function()
            UserInputService.MouseIconEnabled = true
        end)
    end
end

local function setMouseUnlockN(on)
    states.mouseUnlockN = on == true
    applyMouseUnlockN()
    saveSettings()
    mouseUnlockRefreshUi()
end

addConn(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if GEN ~= _G.MeleeRNG_Gen then return end
    if UserInputService:GetFocusedTextBox() then return end
    if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.N then
        setMouseUnlockN(not states.mouseUnlockN)
    end
end))

-- Re-apply when PlayerGui is rebuilt after respawn; no camera/zoom changes.
addConn(LP.CharacterAdded:Connect(function()
    task.defer(function()
        if GEN ~= _G.MeleeRNG_Gen then return end
        applyMouseUnlockN()
    end)
end))

task.defer(applyMouseUnlockN)

-- ── Local GUI PNG animated background ─────────────────────────
-- This keeps all existing feature logic on the client and only rebuilds the
-- window skin/background inside LocalPlayer.PlayerGui. The preferred source is
-- the local 60 FPS PNG frame folder; MP4/embedded frames are fallback paths.
local UI_BG_VIDEO_FILE = "MeleeRNG_UI_Background.mp4"
-- Upload this MP4 next to the Lua in your GitHub repo, or change this URL.
local UI_BG_GITHUB_RAW_URL = "https://raw.githubusercontent.com/headshot7535-png/Untitled-Melee-RNG/main/MeleeRNG_UI_Background.mp4"
-- Optional: if you upload the video to Roblox and get an approved video id,
-- put the id here. This is the most reliable way to use an actual VideoFrame.
local UI_BG_ASSET_ID = ""

local UI_BG_LAST_STATUS = "not checked"
local UI_BG_SCREEN_ATTR = "MeleeRNG_OldGuiMp4Background"
local UI_BG_LAYER_NAME = "MeleeRNG_OldGui_BG_Layer"
local UI_BG_VIDEO_NAME = "MeleeRNG_OldGui_MP4_Video"
local UI_BG_IMAGE_NAME = "MeleeRNG_OldGui_Animated_Frame"
local UI_BG_DIM_NAME = "MeleeRNG_OldGui_BG_Dim"
local UI_BG_PANEL_ALPHA_ATTR = "MeleeRNG_OldGuiBgPanelAlphaFixed"
-- Lower = more solid panels. 0.26 lets the background show without making text unreadable.
local UI_BG_PANEL_TRANSPARENCY = 0.68
-- Higher = less black over the background. 0.28 is dark enough for readability.
local UI_BG_DIM_TRANSPARENCY = 0.92
local UI_BG_FRAME_SECONDS = 10.5
local UI_BG_LOCAL_FRAME_FOLDER = "MeleeRNG_UI_Background_manifest/extracted_frames"
local UI_BG_LOCAL_FRAME_COUNT = 630
local UI_BG_LOCAL_FRAME_FPS = 60
local _uiBgRoot = nil
local _uiBgPanelConn = nil
local _uiBgAnimToken = 0
local _uiBgCachedAssets = nil
local _uiBgCachedLocalAssets = nil

local UI_BG_EMBEDDED_FRAMES = {
    { name = "MeleeRNG_UI_BG_Frame_001.jpg", data = [==[
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
0xskIAyY2SECxCuSIQNwEWxIQLThIQiIQhCI/9k=
]==] },
    { name = "MeleeRNG_UI_BG_Frame_002.jpg", data = [==[
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
IQQDIQKJCEA//9k=
]==] },
    { name = "MeleeRNG_UI_BG_Frame_003.jpg", data = [==[
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
SEAIrIQoVitbEIUVSW4CEAKGIQI//9k=
]==] },
    { name = "MeleeRNG_UI_BG_Frame_004.jpg", data = [==[
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
]==] },
    { name = "MeleeRNG_UI_BG_Frame_005.jpg", data = [==[
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
]==] },
    { name = "MeleeRNG_UI_BG_Frame_006.jpg", data = [==[
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
ABSEAEUAAAf/2Q==
]==] },
    { name = "MeleeRNG_UI_BG_Frame_007.jpg", data = [==[
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
IgABSAAIpMTAABiAAP/Z
]==] },
    { name = "MeleeRNG_UI_BG_Frame_008.jpg", data = [==[
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
]==] },
    { name = "MeleeRNG_UI_BG_Frame_009.jpg", data = [==[
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
/9k=
]==] },
    { name = "MeleeRNG_UI_BG_Frame_010.jpg", data = [==[
/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAA0JCgwKCA0MCwwPDg0QFCIWFBISFCkdHxgiMSszMjArLy42PE1CNjlJOi4vQ1xESVBSV1dXNEFfZl5UZU1VV1P/
2wBDAQ4PDxQSFCcWFidTNy83U1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1P/wAARCAFoAoADASIAAhEBAxEB/8QA
GwAAAwEBAQEBAAAAAAAAAAAAAAECAwQFBgf/xAA4EAACAgEEAQEHAgUCBQUAAAAAAQIRAwQSITEFQRMiMjNRYXEUkQY0QnKBI1IkQ1OhsRVigsHR/8QAGAEB
AQEBAQAAAAAAAAAAAAAAAAECAwT/xAAbEQEBAQEBAQEBAAAAAAAAAAAAARECEjEhMv/aAAwDAQACEQMRAD8A8YAA5vSBA2KwAljsRQgHQqIE2Q1ZbQqKQRia
rhCiqKIAAQ6KBFIFCX0KWOXomQBnkOhafK/6GVg0OfU5lDHjlJ/ZAc+KPumqjwe7pv4b1L4klFP7hr/BZtJhU1769a9ASvBaA3njaMtpWiQDoCMs5ImEpYpq
UW019DVozkijtlro6mWH2nGSMv3R06vUwutySX37PCmvev6GU5yb5dgd+s1UJ4lCDt3yzHBszZYRcbdo4m2a6fK8WRSXa5RWn2nnsW/TYsVJ1wPTeIx/pYKW
NW4ps5/D5s3lpqeeNYsX09WfRGmK/NP4g8YtHqPawVY93L+hpp8i9mkfS/xVopT0GXJBX7tUfHaKd46vlCpHr46OiK4OLDM64y4MVuNEx2RuCzLSnyY5Ibo0
a+ggPPyYtsuhKJ25IbjCeNooiPBrGaRikx0yovJPc+Dlyx3cG9AoWwYy02Fb+j1cUNqOfT4+TsQUyZLgojPP2WCU3xSEiPmfLzeXVKCJ0+mtJhNSy6jfLts7
4VGKR15/GLFYsNJHu+L06jieSu+Dx8PvSVy2r6npS8lHDp/Z4E3P6vo3qY18rnjhx7bW99I+Y1VybZ35JTyzc8k90n6nLqMboelx5x1aYz9m9x0YMUvRGOqY
3h0VQ44pV0X7OX0MDOgo02NdoTi/oQZtCLcX9A2sipAraw2sGIEzTaxOLBiAK2MKommJAbJKAAFYFA2RuByQRQrRjPMkuzCeob6TA7HkUV2Zzzr0OTdknw7K
hgfbYV6O4GzD2ge0INbFZnvDeBqUjFTNIyAuhOJ0YMLyM6f0K+oHBHE30jfHo5zkko8vo7IaVQV1dHp4cEVmwKKq6CPJfisse0v3Kw+KlPIoydJ/Q+j1OBR3
WuLMtHiX6iNoJrhh4GC7bZ0Y/B4fVHuxxq+UaLHEJ6eRi8TgxqvZxf5RvHx2FdYofsejsQUkD04v0MK+CJ1+M0mOE5NY4xf1SLR1aNdiJ6bezQ3ji400mjRi
N4z6fKed8MoOWbBH3e2j5icKP0zUYvaY2quz4zzXjHp827HH/Tlz+GSx046/XgiNHCnTFsMOuIM5o22kyiNRyzjyYzgdjgZzgaHE0a6fTvPmjBcW+/oNw5On
SZYYsqcvRBX3Whw49Jpo4sMUopdr1OlOz5jF5OWo24sak74Pod60uigpL3kuTcc65fOamGHQSi2ves/OcK2ZZ/dnt/xBrpZ8tRfCPFx8ydmrykd2GR2RnwcW
FcHQnSOValbbyozOfcNSI061KxnPHIaRnZBoJxsE7KKMZYVfQvZHQNIK5/Y2VDCjehoCYR2mlErs0iuQHGHJ5flc2+Xso/DHv7no6jMscGv6jxppybb7ZvmI
54xpmq5QbCox5OrNVGNlbWXCJqoJktGCh9RZcdxO2OJBKCSqjO6PLjpnKZ7HjvGTzTjCEeZcEaXBvzLjg+58Lo44NOp7Vvl/2RKWvLh/CsXFXl2v8WZ5f4Vz
L5coS/7H1yVICOd6fCZP4e1cO8Lf9vJzZPD6mP8Ayci/+J+iAMPb81fi9R/05/sQ/HZ1/wAuX7H6bS+gtkf9q/YmHt+Yfocn+2X7C/Q5P9r/AGP054sf+xfs
S8GKvgj+xMX3H5k9Fk+jE9JNdo/SJafD/wBOP7GUtLgl3ji/8EX0/O3pmZz00u6P0SXj9LLvDH9iH43Sf9GJF9PzaeJx9DCctvZ9/wCSzeJ0GOXtMOOcq6ir
PiPMeSWsvFptLj02J9uMbk/8lXXHLPEzlq0jneBvuTYewKLlq/ojN5cs/saxwr6GigvoBzxxyb5ZtDGomiiikgJjEtRGkUBgJs22IiUDIy3EOZU4/QxfZRpG
TOrBK5KzlgjqxKmmB7Wjrg9WOOLimeBp822XZ62n1S6sK7HhTi/ubY41qMP2ojDkUvodMEnOMvoyM10ate639zDR/wAxE6NTJOLMdN8+JWK9L1LRBSYZUAAQ
COrR/wBRyo6tH/UWDqYhsR0QHHrtNDNjcZK0zsFOO6NA+Pg/I+NenyNrmL6Z588dH3Wp00ZpqStHi6vxPbgc67c9PnFjsfskejPx2WL4iZS0uSPcWZbllcEs
X2MZwPReMyyYbXKKryskOGYwxyyZVFHoZMfdmvitN7TWxVcLssV6nhdCsaWafEl0jv1k5Ti3KR0JJKkuEcPk01p5NWdeY5V8l5GcZZWo00cCdSZ3ywKm3ZwT
hUnZ0sZ1vjz1wzojmT9Ty5ScUYvVuD7ONi69xZUx7rPCWvafZ0Y9cn2zOLr1oyLjNnm49ZF9G8dSmTFlejjmbRdnnQzfc6ceVNdhrXUikYLIilNfUDYRG6/U
qLsK1irdI7FgcYJyVMnx+JTzK/Q9HURSX4A+Y1+5Z2n0cyjZ9Bn02PLGbkkuOzxFCpNdnXmsstpUY8myx/YuOPnotERgdGPHyXixW+joWNIz1fxGSgkZZFyd
WwMGmln1EYRi22SUrt8Not9Ta4R9fpYKONHBg08cGOGKPoelBbcaRXK1oIQBgAAFAAAAMljYjNozkZMvJOMfikl+TzNT5BRtY2vyZV2ZM0Mae6SR5mq1spxa
TpfY4NRrLtymeRrfKbU1B2yNYy83KM2lut+qPCkuTbLmllyNtmbVhuM9o9qKoKK0nah0VQ6AmgooAAYFJEECb4HTFtAycbMp4+TsUaREsdsK5ox5OqCoUMdM
0oIE6dm+PM16mFCA9bTaxppWerg1Sa7Pl4ycWdOHUteoR9XHMpR5ZrgdZIs+fwa3hJs7sWs+5Ex9DHIn6lxfJ40NYuOTox6tSfEgzY9Sxp2cUNRzyzeGVP1C
Y3OrRf1HGppnZovUsZdTENiOoAAH0RGGZJnLKJ1ZTCSM1XLkh9jny4k/Q7JmUkZxdedPSQcroyzaKMsb2rk9KSRElaGN89Pmc+n2tpo18VFYs745Z6Ot0++N
pcnHo8Mo5+V0I7Sx7KXBweayx0/jZzku+EvuehFNwteh4ebf5TyrxrnTad+8/SUvodeXLp5K0s8mn3tHkaxbT7fXY8WLSPhQUT4jyMrm69Tojz8jtM4c/J2S
T6ZyZ4Svo51lz+pabI2tMpIymtscpL1N4aiUfU54FlxNrrhqps68WraXvM83G6KlKkTGp1XsQ8hG6NoayElfR4OLdJOf9PRqs21dksanb38epjL+o68GRXyz
5L9dtnw2d2k8rFOpEanT6jLr1oMftfQ9bHrMWr0qzY5Jp8nwXktf+occcfgj6/U18Zr8sMc9OrcZeqGL6e/rddLLP2eJ+6u2ZYoOuRYMPuKTXJ14cbbpo6cq
UMLkujXHp230duDTuSXHZ6um0kMcE2rYqa4NL46c+dqS+50vxEe5Ta/B6UeOgnKotvoxWL08r9Bixu3cl9zfxuNRzSyKNL+lE6nJ1Ff1P/sdmCCjBBPTtwrd
ks6zHTw2wv1ZsWMWgAA0gAAAB0Zzywx/FJI4tT5KMVWNE1XdOagrk6R5+fymKMZKKd+j9DyNd5Ptzlx9LPn9Z5VzdY3wYta8vb1vknNv2kv8I8bU+Vq1A8rJ
qZybuTOdysmtTl05tZkyX7xyybl2xAGsKgGACoKAZVKh0AwFQ6HQ0gBIdDoaVkEUNIYAAmkMAJAdAAqJosQEjGICoza9Tox52l2coWEegtW/qb4dbT5bPJtj
UmFfS4dcpdSOzFqvufJQyyi+zrxa2S7ZDI+ojrtvqj09BrYt9nwuXXP0ZeDy2TE+JMrN5fpkMqmrTLTR8ZoP4gVLdKj6HTeQhninGSbNTpi8vSB9GMM1lvIq
NazjPIYS6NZyMpdGajKRlM1ZlMispElSJAmcbRh7NKTddnScPktfi0GmllyXJ9RhHuT+ga2svJ6uWHFHT6f3tTqHtivovVsvBjxeN0cMTlbS95v+p+rZxeNj
LBv1+ualq8i+C+IL6Hl+R18s+SSvhm4qvI62Wpm/SK6R81rsu7K0j0cmWk3Z4s5+11H5ZrVbwxb4o0/SKXZtiVRSN4oxaY4H4+EvQiXi4tcWevGJqoGZV8x8
7Lx04O1bRjPDOD5iz6iUODKWCMu42XUvL5pJplJOclFK23SPan4+Dk3VBpdDCOsg66djU8vI18nhyrBGqgufycjyycaZ363SSlqJySbcm2cOTTZI26YTGRcX
ydEdOv0bnNNS9DnhHk1Ijswx3I+o8F4/FsWXJdfZ9nzmki7PpfFaj3dj7Qkaj1pRjvpLg7tJpU5b5Lv0OXAt8r+h7Gn9DXxu1rjxKKujePQqFifD/LMWudrV
GGsybcOyK96bpG10cmtyKL3X8uLlQZY1v1TjdqHu39z08MG+Ged43G9kck/il7z/ACe3p4f1P1CN4KopFCQSnGK95pFQw9LODU+Uw4LSabo8HX/xA5LbGX7E
tbk19JqNdh0696cW/pZ5uXzjm9uHakv8nx+r8hky22+znwa1457jPpry+rz6zhzyT5Z4+s8wo2oO2eXqvISy8Lo4ZSchq+W+o1c8z95s5nKxMRGhYDoKCkAD
AQDodBE0Oh0FFUkikh0FAKhpDSKSASRokCRaRCMAAAAAAAEMAESUSAAAwEAwAQDACbDcDJYBknwKE7ZOToWLkDqhKuzs02uzYZLZN19DhRcQuPqvH+ck6U3+
572DXRyxXJ+eY5uMrTo9fx+tlGlNljF5faqVq7sUnweRh10ZVGzrx6hBzvLokYyYSy7uiHIIUiG0uxSmkrbMMmVP1VgPU6rHgxOcn+Eu2zw5b8+f9Rqac18u
PpBf/p2atrbb79DztRqIwx/cN8o1epUMbfqzx55NzsWp1G/K+ePQ58uXbA1GmetzbcbSfLOLSQcsm59IjLk9pl74OzRw900OvGqRpF8kropdnOtRvA2XRhA2
XRlVCARTDaFFKMr9QEwYxy41Jto482C74O+TMJdlZsc+fDGWFQrpehxfo6Z6b6M2XUxnhxKCOrBNwyproyRUeGXWsfVaHInD8ns6d9Hy2gzXhSvk9vRah2k2
bSvbIjxN10GOalFDfDsxXKqs87NefLkj37yj/g9C7hweRjyr9ZkSatO+wj19OlvpdI74T2/g4NM9kHJ9mer8hHDB20FkehqNbHFFts+f1/nKbSZ4/kPKyySa
T4PIy5ZTfZK1OXdqvI5MzfNI4ZZG+2Z2DZK6YU5ujB5HZpPo575INN9huIKQFAAIIYANIKkY6CgBDBIdFBQUOh0AqHQ0hpAJItISRokQJItIEikgOQAGAgAA
ATGAEgMQAABYAMVhYAAWKwEyZFMhgRk6KxLgmfLSNYcIDRDQkMiqUqOzBkSRwopSpcFivXhrNp2afyFumz53fIqORxfZvWLH1a1vBlk8k4nhY9XJKrM8uRy7
ZWcenn8vK2kjm/Xtu2+TyZtt9kb3H1LJDHrZtd7tnkarVynfJnlz2mrOOcm2MhinL1Mcs3MrsccdsjTljjbmejgW2KHjwKKuuTXbRLTFopImKNYowsXA2XRl
FGnoFMVg2SFMBAyCJMyl2aS7IaKiGQabRNBEFBQF0dWkz7HTdI9jSahOSSZ81J0bafUShNc8G4lfe6fUJR5dG+TPFY7ckkfKw1b2cM5tTr8rhtUu2ZYfX5NV
HFhd+i+p8x4rXqflZKXSk5M482vySg05Oqo8/RZHDPJ/7lRYY+41XlYQjUWuuUmfPa3XzzSfvOvQ5smVtVZzvlirIe+3bCxUOjNbkADoGiKzn8Jzf1HY1wc0
1UmAkUhIpIIaGCGkAIYIdAIB0NIBFJBRSQE0NIqhpAKhpWUomiiBKiUolqJcYkVCiWolqJpGFkV5IABpkCHQNAIAABCKokAEMmwGKwsVgNsVg2IAbIbHJkNg
OKuVs2iZ416mkQLQxIaIoSKoBgAAAQA7aCjbDicnbNaMYYHJWYajFVnsNKEDzc73SZdTHmODsSxX2jt9n9hqH2GmOWOBfQ1jiro3UfsVFImrjPaDgaUFE0Zp
FwXI6HFckFIpMkYU2xAFlUCY7EQS+SaNKBoJWdCaLaJYRFEspkso580qRONthm7LwI3B3Ypy2E5E5SRCbRvgW7siY5snRzY57ZnbqobTz+pFHoKdlJ8HNjlw
bwZmi0rKoIovaSqgKLoKIMpI55r3mdc1wc01yBKQ0hpDKBIaBFIBFJANIBUNIdFJAJIaQ0ikiBUUojoqKoKaRaiCRcUQCiXGJSRtgxSyzUYRbb+iCM4wtnfo
9DPNJOqguzv0filj2zyU2vQ9GMVHoJen5xQ6NHEpYuCmsRM0lCmS0UQBVBQVJLNKJaAkllMTAkBksAYmwbJbAUmRY2xRVsDaK91GkVQoqkWgGNCGiBgMABDo
C4RcnSArFBykd0IqMScOJRiGbIoxpAY6jLdpHC427NpO22QUZpMdF0AaiKBJl0FECoKKoKCIodDodAITdKyqMs1qLAh5lZUZbujkqTfR1YIOgNUmOikqCwgo
Gg3C3BUtESRo2SwjJktGjRlkdLgo4s8/eN9MrimceZ7slI9DBGoJG4LNcU9rM3wTZEb53v6OLNCuUjsxK2PNi3RdCDgxvk6cbs5q2TpmuOXvIVXbB8Gi6M8f
RqujNAyaKYiCWuDHJE3JnG0BzJDG1TIb5AtDQolJFDSKEikgBIpIEikiKSRSRSiUkQJIpRspRLigCMeDSMSoQvhK2epoPGSzNSyKoBLXLpNHPUSSUWl9T6DS
6WGlglDv1bNseGGGKjBUkMOd6AhiDL8/rk6VFUcy7R1rorUZSx2YyxHWJxTKuuFxa7Jo654rMZYwsrElmkoUQ0RUslotksqpIZo+jNgSJlMlkESNMK9SP6jW
AGqKRKKABoQAWAkMBx5Z26fHXLMsGO+WbymoR4AueVRRxTnukwyZHJmYDAQwCgoAClQ6AZAUFDABUFFAUKhOKa5KADH2MS4xUVwXQUQKjOXZozOQEtisQmUV
YrJcqIcwi5S4OfNk90qUrMZrcUYYcW7PufSPRh0YYYUjdLjgoJCUbGos0jGgHjVM27RmuzSI0ceqxc7kYRdM9hYlPEzzcmB45v6F0dOGVxN4nBCTizqx5LM0
atCoadjMiBFtcEgY5I+pjNVydM1wYtFCh0WiIGiAaLQkikgppWWkKKNVEgSiWolRiaKIEqJriwOcqSN9LpJ5mkkz39DoIaeKlNJyCWubQ+LUankr8HqpKKqP
CG2Sw53rQxDEVggAAr4Bdo6l0csPiOpdIqwAA0FKhezTKLguQMZ4U0cuTC4vrg9RxVETx2uiNPIlGiWjvyafdKkuWcmTHKLpplVjRDRqJoisWQzWaoxk6AS7
NoGcDSPAGgIVhaAsLM3IqAFo2xY9z+xEI2dUVsiBTlsjSOeeRv1Hln9zGwKsBIYAA/QRAIdiAKZSEikAUOiqCgFQUOgoBUFDodAKgHQgJkjGXZtIiSAwYmat
EuJRjJGbN2iVAqMmgjA22FRgBnGJaRoo0OgJSKoaRSQE0NFUDRBvp3zTK1GBSjdGEHtZ3wqeMqPJeFIqEEujozY9smRFEqwIpDSHRFS+iGuTWiZx4sIzoznA
1BoDkrbL7G0FYZIcWaYo8FBFFqJcYmigRURiaRiXGBpHG2+AaUY/Q9HQ+PlqHbTSOnx/i26yZeF9D2oRjCNJKgzemWn02PBjqK5+pqMRXO0hDEGQIGIEAABF
fAQ+NHSmcsPjR1Lo2sMaEBBRUOyC4dhWyAEOuCNLwY1PPBfWRpi0Uc08iatUPRL/AInH/cd2gX+pkBr53WeOeGT2q16HnyjTpo+y1mJS9ODgXjoZnJS449EF
18zKJz5Y0e3q/G5MLlxx6M8jUQafIGMTQiKLCixCbKSsAirZ0QgLFC/Q6oYys6vT47a4K1HuLo6dPClZz6xWxienFLkVDGRuBIqgSGkFFBRVBRETtHtKodBU
KJSQ6CgABhQAFAMBUOhoAEIdCYRLIZbIYVLJaKYUURQJF0KghFUFDAVBRQAKikgKQAkWo2JI0iQZygbaaTjwwaF68FGuaG6No5WqdHdp6nGn2jPUYqd0E1zJ
FpCRSI0KFKPBaQ2uAOZqgqzSUeRxiBlKFwHijx0dWy4dChj+wExiaRiXGB26TQZNTKoql9WEc2HDLJLbFWz3tB4tYayZacvRV0dmn0eLTQVRW76m9lYvRdcI
QxBjSsAEEArBiABDEAAABXwEF7yOldHPD4jpXRogBDoCKC4dkFw7CtkUuiUURXRo/wCYh+T0PHK55Dz9H/MQ/LPR8cucn4QFalchoYpzn+A1PZfjvjl+ALy6
dZE01wfM+d8RLEnnxr3V2j7FJGepwxz4ZY5L3ZKmE2vzF8Etm2px+yz5If7ZNGAbNcs6McHRGHE27Z2QhSKHjhRskEI8FKLNY5Xp04X7tGeohas0xLhGmSNo
Ykrx5xpiSN9RCmZJGa7w0ikgSGkRQA6AgKGkCQ6IFQUOmACoKGACoYAUAAAASyiWBLIZbIYQmAAUAAMgQDAoY6BIdEBQ0A0gGi0SWgKFQwEGuj+bTOvLDcqO
LTfOPQfRti15uTG4y6Ii+Tuye8zknD3jNa5porbaJijaKMtMJRoIK2bThwLFGmBpGPulKBrCPB6mh8cpRWTKqd2kVGPj/GSy1PItsb/c9zFjhijtgkkVFJRS
XSAOd6D5JKZLKyQAIIBDEAmIbEACGIAEMRFfCQXvHQjDF8R0I2QJDoYEUqLxx5EXj7A1SHQAGm+k+fH/AD/4PQ8b1k/wcGj+cv7X/wCDv8b8OT/BA9R8Rt4/
+t/Yx1Pxm/j+phHUhgY6jKsWNtlZfAeXgsfk9VFek2cMIuUjv8znjqPI5Zx+qTObTxuTDpPjowx4N0jOKpFm5HPqto8Iq0Yxk+jSPZvHJvifKOh8o5IumdWN
7iWNRx6qHFnIonp6iFxOCUdrOdjvylIpISLRhoqBIqgoKKCikBBNBRQgJoKKEBIIYAAABQiWWTIIhkFyIAAACgAAAY6BDAaQ0hoaICgodFJASkUh0OgABlQj
bKNMEOUzrfwmeKNI1fwmo5dOd9kzimi32NJMWJK54xafJrHsJwp2NGHaU3G0KEadFxLjC5cIivR8XplkyqUlcY8ntSVLg5/GYfZ6SMmqcuTql0acbSh8Iycf
wFBhMhDYgpCYxMIQAAUmIbEACGIgBDEFfDYviNzDF8Z0UbIEMSGQM0xmZpi7Cth+gqGGm2k+a/7Weh474Mn5RwaPnJL+xnoeP+Xk/KIFqPjN9B1Mw1Hxm+g6
mEdb6s8Hz+uWDDJJ8tcI9nU5PZ4n9z4Hzes/ValqLe2PARwbt0m32zr08Kjf1OXDHdM9HHFJGlCRcYlJFRo6xyv0lE0jFUJFJlYUkb4eznTNcUqfIG847o0c
GaFNnoRaZhqYWrMWOvNcBSFJUxo5V25MaBIZGiGAAAhiAQAACAYECEUJlCJkUTIIhklMkBAAFDBANANFIQ4gUhoEikiAotISKRQUFDSHQEpWa44hCNs3jGis
9VUeETklSKaowyO2b5caTkOMmmQNJ2VNdKamjNrbII2i5LdG/oYsdOacFyeh43Te21EW/hT5ODD2fR+Ow+y0ybXMuTGN662/RdEt+8kMlte0Ss056IfD/kbF
D4X+RsiJYAwAQmMTCEAARSYhsQUCGIAEMQHw2H4jp9Dnwr3joNkIaAaICjXF2ZmmLsK2AADUb6P5kv7WejoPlT/J5+kXvz+0GehoflT/ACQTqPjN9D8Mn9zD
O/fZ0aL5UvyEcH8S6xaXS0n70uEfCt23Z7n8W6n2vkFgXWNcv7nhtBHRpIXydvRjo41gt+ppfJuJaqyrIXZaR0jnVJsasUUWkVkKzSDEXFcgbY3yaTW6LIx9
m3oZrfNebmhTM4nZqI8HNtOXTvzUjHtYbWZbABTCmAhFbX9A2hEAVtDaBID2htCkJjCmBLJkU0yWmBDJLaJookaQ6NseNSjYRhRSRrLH9DTHgv0AwouKNsuK
l0ZxQAkUkCRSQAkUkJIoARUY2wijWKoYzaqMaLRF0NzpG5HO1UmqOWfxFyymUpW7NyOa4mlIyhItSKi0i488EJo0xupEsWXEwe2VH1OjyRy6XG4+kUj5XLxk
PY8Hmbc8d8VZyx2+x7JG1e0uivQyk5WGFQfD/I30RjTV/ctgIAEQAn2MTAQABAmIbEFAhiAQAAHxGL4jdGGL42bGyGMQ0QM0xdmZpi7CtwoBhqN9L3kf/tPQ
0PyZf3HBpfhy/wBp36H5Ev7iDPP8xnTovlS/JzZ/jZ06TjDL8hHw38QX/wCtZ2/VnBE9X+I8W3yTn9UeVHsD1MKrTR/BCXvF4fkR/AjbnfppUWiLBSNstU6H
uM9wWUxpu5LjOjFFoaY6YZOTpjJSj9zhXBtjkS1ZGuVrazDj6FylwZ2c67Q+PoFISY7MtikFILCygpBSGBAqX0DahgAtqFtRQgJ9mhPHRdhuIrJwE4GrkiXI
qMXisj2LOiwsDmeFpHRpoXCg7NcHEkAez+xrihbNG0ODVhnU5ce6NHI8Tiz0XyROP7BNcGxlwx/U3lj+gowYNYuNMFHk1nGhRXJV1UIF7So9DLjlaylGjORv
J8GEnybkc6ydiaNKDaaRkrRSbNFDgPZhUqTRccnKJcCNrsDqy+9j3eqOrwk2tUkcz5wNF+MbhqE06Zxv16J/L6sQk7Qw5kKxskgAAAATAAEAAQJiGxAAhiCk
AAB8Rh+Jmxlg7ZsaIENAMANcXZkb4ewrQBgFdGl+DL+Eeho/5d/k4NJ8vL/g79H/AC/+SKyzfGdOl+RL8nNm+NnVpFeD/IR83/FODc45EvyfNpcn2/nNP7bS
SS7o+KSalT7ToI7sUv8ASSHZlHpDs6RmxdhZnuDcXU8tVIpSMLKTsavlspFKRkikS1vy23suMzFFxRNMa7/uLcSBluKTHZKCyKuwsiwsaNNwbjOwsC9wbiLC
wL3A5GbYtzApyByM5PgwWRqQHTuCzPfYb0BrYrM94bwNbKhNxlZjvBTCO1ZL5LjI4lkLjlKmO9TG3fRx+0NYZPdCY1oKCEkzSgjHIZL4jfMqRzt8hpsnSByM
t/BlLJZuOVjWWQz3Mz3C3M3GLGtlKRjuGpFZdCkO7OfeWphWolFWQplwmrINX8tleP8AnxE/hZp4756OPX16J/L6XG90EUZ4PgRoHMmSUDIJAAAQAIAAAIEx
AwKAQxMKTAAIPi8C5ka0Z4PU1KQhoAKGjbD2Yo3w9hWgwodBXRpeMWT/AAd+l/ll+Tg0/wAnJ+Uehpl/wyIrny/Gzs0nyDjy/Gdml+QBGphug012fEeUwew1
kuKTdn3suYnzn8Q6RSwvIlzEqPn1LghzbZMn6El1F7mVFkI0j0XVxaRpFEI0Q1cUkUkEehojUUkXFEI0gQMdAMCWgopiIpUFDFYCAGBFAhiAGJgDAmXRy9zN
8zqBhh5mFxslwJo1pEyRUrMBiCAYAAFxdEoYGimaRkzBGsSo6cU/e5O6C4PMXDO7Bk3RDODUdHJJnXm6OOXYWJk3Rk2avlENFMZ2xWy2hUXU8ptlJhtLjEsr
F4OKsuuAiuBl1i8olaFjb3rk2UdyFDHUjSOnuB1+Ox+8pHHB+h6vjcb2rg5dfXafy9XCqgixR6AjAsBAQIAEwAQAQAmNkgAABQrENiIoAAA+MwdM1M8C4ZrR
SFQ6BDKoSN8KMUb4QNQAArfB8if3kj0MH8ujz8HyJf3HoYP5eP4Ia58nM2dul+Qjin8bO3S/IiBpR5fnIf8AAZH6V/8AZ6pz6/GsukyQau0EfncuxFZIuM5R
appskqxaLj0Qio9Faax6NImUWaRYVomUiEy0yCkXEhFRYVdjJGAwAQDEAmQACAgYgsLCkIGxXwBlnfumWn+MvP8ACZ4HUirHWJlUJoJWbEU0KghBYCApDFEt
ACRa4JXZRRaZvgybWcxUXTCO3NNHNJ2wcrJbCBshjbJChgDAKC0SUEWuhiiMupYqDpmyXBhHs68fvQ/Br0x5TCNzVHv6PHtxx49DzNFg3ZLrg9vHGkYtXfzF
roABkYIAABCYxAIAAgBUMTAQAACYhsQUAAAfHYfhZoZ4fgLKQ0USiiqaNsRgjfEBqACCx1YfkS/uO/Fxpo/g4MPyH/cd+P8AlokVyZH7zO/Tfy8Tgn8TPQ0v
yIhGqFkXuOigDL8/81pnp9bN/wBM3aPPR9h5/Re3wOUVzHk+RaplWVUSkTEorakaJmaKQGqZcWZItEVrY0zMpBWiZVkJjsgqwsVhYDsTYrE2AwsmxWBYMlSB
yQA2JvgzlPnglzdBSySvgWFe+ZzkLHk2yCvQQUZRzRbXJqmmBLRLRoyGgyzfYDa5EA4lIlFJgUiiEyrKKCxWMB2DZLAB2FiEBQCACkUiEaJEFRRSQkjSCAag
b4Vw19SUuDr0OFzy2+kVLHoaHFsgjvXCM8UKRoRypWAAEAhiABDEQIAAoBWMkgBDEAmAAFAAID4/D8CLIxL3EWVYaKRKRSKA3w9GBvi4QGljI9RhXTj40/8A
k9GP8vH8HnQ/l1+WeivkR/AHI+ZM9DT8YYHA/iZ34F/pRINwEhhK58+Lcnxa9T43zWg/T6hzhGscnxXofcvlM83yejjqNLONc9ohHwyVDNMmJwlJS4adEUaa
hoaENFVaLTMkykwrVMdkJjsg0TKsxTK3BWm4HIjcQ5AaSmTvM3IW4g13huMrLiBTlwZe05LfRzSuwq5TbKj70TG+DTG6QaRkVExjZeR2ysVVyBm7izpxZlSt
mc6b4M2voB3qaY3ycmC7OtPgMoaEW+SGEAEjsChkgUUVZA7AdhYgIGmMQ0UMBjSAIo0Qki4ogqKNoRJgjaEQKjC2keto8W2KOTSYt0uuEetihSDFrRKkMADn
SAAAQAIBiACBAAFCEAEAIYgpAAAAAAHyGL5aLADRDGABQuzaHQABQwAK6Yfy8Pyz0n8pfgAJRyPtno4flQ/AAEaAABDJlFNABB8d5/AsHkppL3ZLcjymAFjU
IYAaaAWABVKQ9wAQCkPcABT38Et2AECsaQABSK6AABvhmEVbYAFRJUy4dAAaKYvQACnG2OSqIABWKVM6E+AAIFJNjAAyloQAEFhbAADcNS5AAHuHYAQNMpAB
RaRaQABpGJaiAEG0YpI3ww3zSACo9vT4lCCVG64AA5UMAAIQAAAAAQIAABCYAAgAAATAApAAAAgAD//Z
]==] },
    { name = "MeleeRNG_UI_BG_Frame_011.jpg", data = [==[
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
]==] },
    { name = "MeleeRNG_UI_BG_Frame_012.jpg", data = [==[
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
]==] },
    { name = "MeleeRNG_UI_BG_Frame_013.jpg", data = [==[
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
]==] },
    { name = "MeleeRNG_UI_BG_Frame_014.jpg", data = [==[
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
]==] },
    { name = "MeleeRNG_UI_BG_Frame_015.jpg", data = [==[
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
]==] },
    { name = "MeleeRNG_UI_BG_Frame_016.jpg", data = [==[
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
]==] },
    { name = "MeleeRNG_UI_BG_Frame_017.jpg", data = [==[
/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAA0JCgwKCA0MCwwPDg0QFCIWFBISFCkdHxgiMSszMjArLy42PE1CNjlJOi4vQ1xESVBSV1dXNEFfZl5UZU1VV1P/
2wBDAQ4PDxQSFCcWFidTNy83U1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1P/wAARCAFoAoADASIAAhEBAxEB/8QA
GwAAAgMBAQEAAAAAAAAAAAAAAgMAAQQFBgf/xAA4EAACAgEDAwIEBAYCAgEFAAAAAQIDEQQhMQUSQRNRIjJhcQZCUpEUFSMzNIFiclOCsSRDY6Hh/8QAGAEB
AQEBAQAAAAAAAAAAAAAAAAECAwT/xAAbEQEBAQEBAQEBAAAAAAAAAAAAARECEiExA//aAAwDAQACEQMRAD8A54ysAOow0MshAIWQtAFEsiCwVQnRq/zKP/Uw
YOhX/mU/+pFdDXfI/uzP0/8AyYfcfr/lYjp3+TD/AGEdnO7CQGfiCRBZEQhEXg16L5ZfcxmzRfLIsVqIQh0YQkvlISXyiqx2meZptETRzqlEI9mVkIsw67T9
8c+25uJjJqVY8F+I+mKtwvqXwvk5FFWcx/Y+ka7Qw1WnlW+H4PL39Dv09nwVuUfdHSVtyfR9WiKltJbHL1VctPbGa/K8npZ6O6vGa2svArW9PcpOFsMbZS9y
2NRt0c/4nQ1W+8Ued63Ht1tWPc7fQJOPqaWb2i8xz7HN/ENaj1TTx99znYptXCNEeBMFiKHLgzWosVbLCGMRe0luRSJzKqsakLc1k0aeKk+QN1FnBsjLKMkK
0o5GxlhEalaMlNgJ5LyG1MospgCxdq7q5L3Q0prJUri6mHZFsV0qParNZOKbi3Gv7m3qVb9J4F9ihTVTHZV7tf8AJ8nSONiqKkksLc2RWBdMNh6RTFBorBOD
nWoIorJTZFGDJlJlTYQuT3LiA3uHEMmx4CJFbBYABlINoECFFlSAGS3BCKIIMrtlB7MWwchHTp1+PmY6HUY5w2cbILYTHp6dUpLKZqruT4Z5Gu2dbTjJr/Z0
dN1LDSnt9S4zeXqabMrA05ek1ULI5TOjXNSREGUyFBElwAGwAPBh1ADK+DSDLKLAhaIRcgMQSKiEg0mNjdX/AJlP/qYsbG+n/Np/0Ubdd8rE9P21MP8AY3XP
EWec1/WJaefbp38aym/Yhj112qoonFXXQg5cJsdXbCxJwkpZ9j5dLUTnY5Sk3J77m/p/WLdJdCTnJwTWVnwGvL6NnBE8nk4fipT1S74tU59tx/UfxHX/AASj
opP1JbNtcImJ5d6rVU3XOquyMprwjpaL5ZHzPp2osp1ddkZyTUs5zg+k9MmravUi00yw65xuIQhtyQkvlIW/lCslpnmabREzFUiXIIcxREGXkXkJMKLJTSfK
JkhZVK1FELqHBx+qa8HG6tVK3Su6vPr6XeUf1x8nfyI1VfyXVrFkHv8A8l7G50srwz1MaNbRrIL+nJpSX08jut6KV/Uq9Ql/TjHZmbrdUdJrbNL24ou/qRl+
mXlHU6Tf/FaGVFu869slrpHPUcBeBl9brsaYs5VuJ4MerbUHhZNb4MuoWYkHJmpyklHYL/6uC/puW3sOUcSzg1VXRjyaCdNrdZ2KEoyfu2jdTfNfMwoampUy
3Sl7e4xz06prnGUXN8rGO0Ym4002dyG5MUbIqSxJPK8GqDyRuUZCFhdCQvBCNM+prU459jC18b+505GGUcTbNSsWGVfKMQqAxGtZwRTCSKaMKBgthMBgTO5J
vYFvDKlLYIDyNr5FLkdWGT4oLBIhAC0C0GwWAJUlsEU+AFsoJrJMMgFgDGgGgBBYRRRE9xixgWg4sI2aLUvT2Lf4Wek0eoU0mjyCOp0zW+nOMJMjNj1XgoGq
XfBMNhhTBCAfIHgxtYobVwaQZZRALLRRaYUyPAaBXASCi8G6rH8bV9MHPlJQWZPAGq1SlKXoyeXHGV4C4Lr/AFauSdGnll928kzzFkstvyadRFp5e78maSyR
05hEnuRNhuJWCtjrb8jlOKWPJnzhBQWWFkdDSP44n0T8MSb0s1nbY+eaKLckkj6N+HqZV6fMuJIRn+n47JCCLNbp65xhK2PdJ4SRvXlw8t/KKrvhZJqMstDH
wBmtM8zRaZpcmKUuYpjJIWyCiyiBVl5ByTIB5JKa7MMVKaSMl9rx9DpOR5X8XTjLWVVxkn2vLM/S9R6N85J4SayN6vV61upuWMQjs2zD02LnU/eckdLPjpHd
1Uo2LuRhlsarl2S7X4MtnJ566QLYuxZQRGRXPmsSaKNVtCluuREqpIoFIrL9wu2SXBW/sUHVY4STydaizuSOPFN+DqaXaKC/jYg0gIjFwDUBYTBI1oJIRZFL
JpYmyOQMucMdDcRNfEPq4KGJEaCKIyTLZgPgbNCpALlyC2XIBlQS5H1iIGmsM0+JeCRLArBTQZTRAtopoNgSAEhCICmA0HIEBTKDkDgCBJFYCAiG6aDndFfU
WjodOqafc1yGa9FoJ/0sN8GvJg02zRuXBHOoA+QwHyQeDG1cCR9Xym0EQhYVC0tyItFDI8EnYq45ZI8HM6jfmXYvBFDqNVK2x7/D7FQsRkyWpBuNVqU4swzi
4s0wswSXbLlEaYmQ0uuPgr0kVYzYyxtcR0ao5N2l01E8d0sMjWtXRNO7LE3F498H0DR2V01KDkl2rjJ5XpcHpX3VyhbU9sY3RV904al9+zYjHX10+q9dn3Oq
jKj5fDONG1ysct85zljZQVq7vIWlhRVb3amXbXHn6lrM5d7olU5RjbLKXj6nafBxq+vdPjCMa5tJbdqN2m6jptVH+nbHPs9ixjqCt5M81uFZq6XqPSjNOT8I
kgzSJoTIfLgTNGagWykyisJ8lUXegW2/oXhIplkAuJg6hNKrGfifC9zfJ7HE61PE5OO8opQjFeW+DtzYrh9asdWnVNee6x/H9iumRUdVUktlJPB0OoaJaemm
MvjutsSk/Bz9LNw1cIxjmbk8fXArcbupSzfPHhmD1M8i7tY7M2T27t2Zf4qHKZ563K3KS9y8mGOpg/zD4Wp+Qa0clNIpMmQ1qdiLVMfYtMOL2KKjVFeB0NuA
U9i+5Lkg0RY1My1z7nsaIsAymi8lNhQsFrIRMBqMl1bS7iVSNMlmLRkinGePqBpW5CR4RbCUuSFTQ2QuYRnmLGz4Et7lQyHJogzNA0QKjRFhdwEeCyINMmQS
ARsBvJJAgQsogFSACYLIK5JghAIgkslIZXBykkuQD01DutUeEdqmlQikvArR0di+puhEVm02iPDNi4M9SwjRHgjnVgtbhFPkDwA+v5RA6v5TSDIQgVeQkAKv
vVUfqVR6nUqqDS+Y5M25ycnyyWXOTbbEepuRuQ7BRIvKCCqRe5CBVZZMssogtS3HV2NMQXFgdTS6qVbXbJpnTjrY21taiKc4/LPG552ubTNMLG9gOnLWY2ix
U7XNb7iYVt4bRv0mht1ElGuOSDLRU5z32Ru02lutsXpRlzjKPS9M6JVRVm6PfN+/g60Kq6o4hCMV9Eaxz6rj9P6fLTx77Yrv8M2SH2iJBjSpCZodITMiUprB
SIyhoshEQsqk6q6OnolbLiKOX0rTu/VPV2x+GP8Aby+X7g9TlPqPUq+n0uSrrffdNcf9TtQgoQjCKSSWEkdI05GtXqdW01a+WOZNf6OB0xep12j2Wokv/k70
H39X1F2fhqg1/s4f4eXf1LT2PzKc2bbjkdWi6LdRTlpQsko/Y89O2eX8TPWfiivt190lxJ5PI2fMzljFRX2LibH19R1EOJJ/dGQhcZ13NL1rhWpL6o61eojZ
BSi8pnjTVp7rotRg/wDRLG509Wpk9ZLl4OJbrpaePbKXdL6eDLqNc7Y/C5J/cmNe3pJayEY/MgY6j1Hs8nknbN8yZIWzhLKk8/cvk9vd6WSZp9Rd+Is8Zo9f
fCSxNnodDf6kfie79xnwldXOS8iovYJMzjpBkKT2LI1EEzh8eRwMll5ChXBGywWEoJMVJjJCmEKmxMuR0luLmtyouDNEGZocmiHJRoiwsi0XkiUWSdwGSZCI
2QFsiYBFlFsAZAMKQIRCEIFRcm3QQctRHbbyZILLOz0+jtSYSttcMLY0QiSEdhsYkYtXFYGrgpIMjKiEIB8/HV8CR9fBtBEIQjQZyUIts5equc5Ns06y/D7Y
7ryYZLuCyEPLB4Y7swxc0SuhtT2GoyqTiMjqI5w8gsPKJGSa2LCKIX2kUfoFRItIOEGxqpATGOTZpNPOyxKKbH6Pp1l80oQl98cHsei9Iq06UnFOxeWGbcYu
n9AslGM7dovfGD0ul0lOlglVBL6+WPSwiG5HO9ahHwQj4LWWax7iZjrORMjCEyFzGSFyIEyFjJi2FHFmTqOqemqxUu++fw1wXl+/2GW2xpplZN4jFbidHVOd
j1WoWLZLEY/+OPt9/csUXTdH/CabE2pXT+K2fmUjTZNV1ynJ4UVksw9Qn3zhpVJZm8z+kVubVh12dD0K+6TUbbY/7yzkdDXp3OS+WEO1P6mz8U6rvjRp45w3
mX2Rk6euzS/WTyNb5Z+u0Svm5LfKPK36C2Lfws9nqXmG5iljPBnV868hKiyPMWD2P2PWyqhJbxQieiql+XcTpnw8z2nQ0EVXpb72uGopm2zpsJPYdLp7XSZQ
i1vYmX0nlwr93kQzq2dPk38y/Yzvp1mdmhqWMLTSIs5Ol1OmTlWo1pOMEngxRpnlJxLKHad5lHB3dFPE4nM09Kik2tzdW+1po1fxqPRR3RedxWnl3URf0Dys
mK6GxYQtBIy2shCENUwWEwWClSAYyQuQC5iZDpci5BAofB7CUNgVTohAxLIimU2WwSii0D5LQZMXBTZWdgWwLb3IA2FHggsmCFooZRHutivdo9Hpa8RRzen6
bZTeG/8A4O1TDCIzTIxGRRIxCSIwtFlFhFEIQD5+aIfKZzRD5TSCM2sv9Kv4eR832xZytZb3ceA0TKxye+Su4jucqlXhbPOSkiNxGwWshOIPAbC4i2viGSYK
WZIK1UrYfGOXgXUvhNmkqdlqSKlRaeUsKMW/sjdR0bUWLPY4/dHptBoYVUw7oruS3ZvSSRli15rTfh6WM2ySfsjpUdG01XMe5/U6iwQM+g01xqWIxUV9Eb9F
+YxI26LyWM260kIQ6soR8EKfBKM9rESH2iJGEKkLkMkLkgpMuRc2oRcm8JbtjZHMsb6hdOqOf4auXxtcWP2X09wJp29dctRhrTxf9OLXzf8AI3kilFJJYS4S
KnJRi2y4obbY1QlObxFLLZxY2SnfK+fzTeEvZDdVZLVSVecxTyc/q+sjpoqqve2Sw8ePqa/GpHL6hfLWdRk4/JD4Ym6pdsEvoZ9DpspTceTe68LdC343yy38
GJ8m68wy5ObSimTJMkFNF97VcovhlZF2MoGWMi28PYtgtFZwufxS3FupZ4NHaXgqYz9uB0FsDNYG07xNSmO5pH3dNTWMwlv9mTDF9KtXpzqf5lg1KCawStgj
LAakKeFLAUWZw03JEBkJMjWrYEg2wJA0EhUkNYDKmkyW4uQ+SFSQUC5HQ5FLkbW9wGkIQgjBfJb5B8gqFF4KKysFkyRsCglwCWuCAwoL4lkCI1NYCPQ6CKVM
cHRhE43SrnKKi/c7kUSsdCSLIiBlCEIBRCEA+fpj4vETOHdYoU84eCoz67UflizntthWScpNgoOki4xCIiw3gorYGVeWHHgsDNKBUY4kaWkwHELptXGDvdDo
7roto87CTjNe2T2XQKv6dc9sNZDNd6K2QRSLI5VZCECLNui4ZiRs0fEjUGkhCGxCpcFgz4JUZ7BMuBtgt8GQmXIubwhk3gz2r1VhPAGPUSnqZejTJxh/9yz6
ey+o2qqFNarrXbCPCNCrjCCWVsjPddGHyvLNYuCbUVlnL1monfP06to+ZB6rUx7M3Wxqj533OZPqLlL09BR3/wD5J7R//pqLILX62rpunzzbL5V5bOTo9HZq
b3fqE93nDN8Onx9d6jVT9a5+XxH7B26hQswiWt4dGEYLxhCtRdCMHvv4M1mpyZbLXNnNpdlncIlyWwWAL4K8BMFhVAyReSAA4lYDJgBeCmtg2gXwAmfDC07f
aKveEN039tG4jpdMmlc8+Wa9bc6JyicvTWdlyaG9bv7pxmtl2pfdgaNPa5pNvOTUcjp024o6sctZawLKCTCTALMqZkpsEmSC2C0TJCgJITJbmliZx5CwgZB7
gPkKIU9MIXFjCAWCw2C0UUUyymRFFMvJOQgQkTtLSAuIyKyAkGngDb0630tVFeG0eorkmeOhLEk1s1udrQa/vxGx7+5Kx1HbRBdc01yMIwhGQhRRCEA+dt45
Meoudk/ogtVdl9sWZirJUzkiJgtIrrglwEgUg48hRrghZCIEvBAooB+j0/rWduD1nQ6fQ+DPhnF6ZQ8Of0O/03+6/wDqRmuoggVwEHOoQhaCIjZo+JGQ16Pi
RYNJCm8C5aiuGe6a2NaGAWSSW5jt6lGO0UvuzPLW927lli0karJoVKxGSWqz5Ez1CJq41WWIxXPue0mvsBO9e5nlZ3PYasiWRnLi6aObrK3Fb6q1/RYRr1Wo
VNTbeH4OPK12z7my61IOGnpUu5w7n7yeTR6qhHCwjN34QudnsNaaLNRtyYbp90soKUmxckTVwOcldpMYYXggHtBaDckgG8gUwWg8ZKwAvtJgZgmCBWC8BYKY
ANASQxi5vCKMerfBo021Zktffaka4PtikbiGReJJoLqWZdNhPnFjTEuT5JbKVuj7Fx38FU/p8lCtM6cZNx7n8P0OPpsqBpVkm92y6Oh6iL788GJSYyuW5ijV
3E7hSkEmZDckFqQakUWDNbFphYyBkktyIdbXh7AqIai4jECkEQQGRbBYSqKZZAgC0WkXgCFohAC8EKZTfggLuwMrsaafsZ8jIvYiO9oNd3JRk9zr1WKR4+ux
weUdjQa7hSe4Zsd1kF12qaW4wrCiEIB8nbInuTBcVhmnYaRZWS0w0tLJOGFHgjW4BReUWCiyMrQ2qDnJJLIqKyztdE0ysuy1wEdWqhU6WtY+JrLNfTv7z/6g
alY7fsM6d/df2IldOPBZS4LDnULRRUpxj8zS+4QYcNVDT1ycpLPtk42s6rGEuyH7nF1fUZSfLwGpy9Hq+tLiDx9jnT6i5Zy2cD+KbYaubRG/LrPV58lx1Lxs
zkeq/cKNzwVrzHVeqfuBLUnP9ZgSsb4IY3q5zbSDnNU1uc2Ipgqa3ZZtLBzdVqJWy52KmK1N89Rb3Sk8LgFSFospg+4rJSLIqiYLIUBKILXbGUpNqMVl4Qxl
SlL05QztLkBCSlpZ2TzGbkuyP0AgmG4e5aSRASWxCZRTAjKZYL5ApgsLyU2lyAD2Mmqu7Vhck1WtjDKisy9kZqaJ6iz1Lc49iwHp63J9zRqjAbCtRSSQaiaQ
lw2Jp6+6xQfHI5wyhmihnUqPnwy6pKr7HhBxiOvg/Xk8c7gxW5NFpBx2KCMi87E72kCU+CBisCU9jN3DIz2KHKwbXYnhGGVmGHVbugOp6fcgHTgfppKUEHKI
TWPsSBawaJxETW4XQMFhFMASEZQFospFgQtFIICeAGEwJAA+Q4sX5DiQOT2DhNx4EphJhK7Gg6g4/DY8+x2qdTGaXk8hCWDbpNbKuaUn8IZsepTyQy6XUqcV
vyasoMPlWxaQCbzwNSNPRgcBxjkpoKMkgCSwQqU0A7AGEAjPLDIyZTHMkeo6HWouXv2nn9DX3TR6fpccWTX/ABIh2q5QfTv7z+wGqXxIPp/92T+hEdNcFgrg
yazXw08dpLu9is5tOv1NdEW5yWV4OFr+pu2T7HhGbW6yV7bk+TmznuG5ybbdKXkxXTYc5GayWxG4Oqe+5o79jDU/iNHeFw71C1YI7i8lQ5TyzfpK+1epYsLx
kzaLT98lOe0V/wDsbrdRj4Uwzodbqu/MYvYw8kzkJICYLwXgiRREXgmCYIIUWUwKKayQgAtASi2thrKAwWu+L+BZFPUXpbwOm0mA64vwgjFHVTS3iyp6yX5a
2zY6o44QPox/SgrBPVXS2hBoB0X6h/FNxR01VFcJBKAGOnRQgt13P6mmNaXCGqIcUUK7S1Ed2hKA0I7VgvTv09TB/Ue4CLIuLTXuNG7qdGJRtS2aMMVudbVf
1NDGS8I5naBTRRZeSASmtg8gy4AS3uXnYGS3KyUKtk8krsaaBu5KQHc0VuyOjLdHB0VmMJvydqM81osSqnwZ7EaJboTZwUJ8AtkYLMiMEJvYBsKvISF5LTAM
sHJeQLBlwWUwpeNw4g+QkARaBLQQxMjYBGRMbtJqpU4Se3szu6TWK6Cw9/Y8opYZq018q5qUWEsedSGRQMY5HJYNN6CUdhfazQC4kQmVbxkXg1YBcV7FUmK3
H1rLQtrc06aOZIDqdNp2y0dvpv8Ads+xztFHDR0enbTnnxEzUN1Pzl6KcK5ScnjYTq74Re0k37HK1GqeWs7fchjqdQ6skuynP1Zw7tRKcm2xc7GxEpBrBzsy
KlIFsCTAk5CJsOTFSeWXAdSHCq+BiBqzZpdL6jUpbRF0U95rnYqq1GIQd18ao9sVwc6bdkssKTlZLcOFYQEYMYojFHBeAF9pMBsFgUUy2AwKZRGQCiEIBCJE
DSAW0TA3tKwAporA3BWEACLwXsQCYLSIi0BaQ2KAihsUQWoi7q/hew9EksxKG6T+po3CW+xilDDaN+gWMoXq6+2eVwyprBKOAB81kTKOCKopk4KbAGaWBPkb
J5FT2AVcgIsKbyhaZRoqn2yR1qL+6COGmbdLdhYYR1vV2AnPJl9Qv1MlBt7lA9xMkFvgBsJ7oBhVZLTAyWmA1MvICZaYBFlZIFVgssgFFlFgWRlEIimFGWGB
IrIHPrGoVWMKLIQgFFNlsEAcZZs0i+NGaEcs6Ojpfc3jZAdGmSi+SpaqVbfZLCfODBO74vhYt2v3M61I0WXOTb8sRKWRbn7sHvQaFKQtskpAORU1GwZMmSpB
ASYqT3GSYiT3KjRU9jTp6pW2JJGfTQlZhJbnVj26SpJLNkuQCm40RxHdiMSse4UISm8yHKKREBCpIKSwW5IGUgKID3MrIBMFsmQJMCNgshQEZRbKArJMkKAN
BRBiFEAinyWUwBZTLZTAosEsC0EuQUEuQGRQ2IuIyIBoJLLBTHUQ7pZCVpprUIpoHVQ76/qP8YAS5TNSOeuRKOGKktjbq6XCXdH5WZGiV0lZ7EKbwaJx2M00
ZVO4CbymU2C2UJslsAmMuj8OUZoz3A0IZGTixMZB5yUao25W4asMaDUvqVG6EsxCyZqp7Ds5ID7gZMrIMnsBMlpgZLTAamEhaYyIURZRYFkKLCoQhAIQhCAW
CEwGBiigi0i8FQOSssLBMACRILBADrXxHUVkaen2TfscqL3GdQ1KWkrpXMnlhYGuXw/UtyEVSyhjZFtE2VkHJMg1bYLZGwWypavJTZTYLYRJPYV2uc1GKzkP
eTwjq9L0UYzVk/ADNLQtLR6k1vjYFy759zeX7jeo2pyUFwZFPCA1KSSBlZ7GZzJ3kDnPJXcKUshZAPuKyCWBGymRkAohZQFMrIQDAhCiIBi4LQKZeQCyU2Dk
psC8kyCWgLIQsCIJFJFoA08DYsSg4sBy3Zu08e2OWY6Id0kb8YhhFxjoN+ojVHLYivW1TeHLDMWuVs7WlCTS9kZHCae8ZL7o6TlxvT0LUbK2uU0cq2HZNpl6
C+UJ+nJ/C+DVqqu6LkuUZ6jpx1rnTQicR82LfBh1Y7FgXk02RyZpLDAj3WDDZH07Dahd0FKD9wFQkNTMsHjY0JlDUWCiZAbCWB8ZZRlQyueNmBoyU2DF5Iwi
eS0wS0UMixkWKiw0wpuSFJlkFllZLAhCEAhCEChYE3hDGKt+UgQWQhUQotlAUwchMBgX39pj1VzncvZDbZYi15Mj92CNlMtkaFwYaZGuEsoi0ZTIRlRWSmRg
tgRsHlkyP0dLtnnwEp+h0ve+58I69cexbGJ6mFOIQS2NVdnfHPg0579c7VWN3STYjvK1Es6mftkFGXSDUi02CgkRRrgJFIJAQsiLAohZeABIE0CwIKkxguYA
5LQGSJgMJkDuJkA8kyBktMAgkAgkAaCSKQaQEwUE0UBEFFZeAMmjTV90s+Cpa6GkpSh3M0NLAh3RqrObb1Wak1FLH1NyOPXTrvDYE6oSW6TOP/MLeU0XHqVm
fiw0bkc/Ub7NHGaTjtJbpjoxbh8XONzFDqcPzRZpq1Nd3yS/0ydRrmxz9XX6djXgzPg62up76+5co5LOVeiXSp8GeaNMlsImiKSR7oJoEDHdDtnlcBweUOnD
uTFQi0UMTLTKIAaLKysEyA2qeNmNbyZU8DoSyggyyEKLQxC0MiAyIQEQyKhaKLQFkIQCFEJkgpi7PlDYux7BSiEKbwVF5KBUs8F5AqQuTwg5PYz2S2YC7H3P
YXOGw2uHc8sZOGxFjNDKRpolkpVpxGVV9u4Ww3wCwm9gGyso2BJlsCT3AKC7pJHUppcKko8sx6KtSsUmdF2Qr8mpGOrkLWjcnlmyuHbHHsY3rorjc06e5Ww7
jVjjL9crULF8/uAjRroYub9xCRzd+RxDSAiMSI0JBFJFgQshaQESLIQggLLbBe5QLYubGSEzABvcmSpckTALJEyiFBZIii0AaCQCYSIGxGxFQHxWwFNbC2Nk
thct9kBIR7pYRtr/AKccA6ejCyxtlexuRz6rBrdTn4UYcSk9kdN6eOctZChCEOIo6Rwv1zlXP9LC9Gb/ACs6ikl4DjJN8Ius+K43Y0900XCUoTTTwdlwjJYc
UzPdpIPLjHtf0ZLdWc2NVF3rUJ8vG5y9VH07pI06WudLabygOoQziZz6jvxWKQmYbYLZh2hTRFDIQyCyAns+gLq3Njr+hcacsIx+g2simjtV0J7NcmbV6CVX
xR3Q0c4gcq2vAGCiZCjLDAZE9yjYt1kmMAVSysDGERDIi84DiwGINC0w0yKstEyTIEKIQCFEbwB3EFti5/KFnIMvlKpTmkKtswhcoyW4KXc9wYbTIa3sKglE
GyzCwEVbZ7C4xciRi5yy+DRGKRBK4YQbj8IUWsAzlsAuvHc0MFxW+RmSroZMEJlYAFgPkb2i4x75pIJT4WdkcLkrMps0VaZye6NtenhFbpHTl5u79c2NE5cJ
nR0dcq4YkPxGPsglZHPKNMxn19XdVGS5RzztWYsraOPODhNpnOu/NXENARCRmuhiLATDILwWUiwIQhAKYITBYAyEWDpvYRNgLbIimRAGiyOMo/MsEKLwWkUm
TIBpBoV3BqQDojYy2M8Ww08AOchmnq7pdz4M8Myexspbity4xemlYSE26itbdyOb1HVS7+yMmkuTnubfLOkjh107EtZUn8wmeuin8KycwNGsZ9N/8yX6Ao9S
in8pzi0i+T26kepVt75Roq1lU/zo4eEU9uCeT09JGUXummBqq++mRwqdRZXJKMmkzu0W+ppvi5ZnqOnHX1xWsPcFodesWSX1EN7nJ3lTA6mORSWTZpobkU6N
LaDjRuaoV5iFGvBFwquvDRoUYzXbJZyRQHaarutS5yyRHK6h0e6qCurg5VSWcrwcWyDR9VhTFURrlFNYxg8z1z8OpZv0q28wNM68XKLBNNkGm01hoRJFUVUs
SNK3RiTwzbVvBfYophwKaItgGIOItMOLIoyZByQAiiiZIKkCWwPJRYMnsG+BcgrPdNJGb1HkbqGxUIp7iqPv2JGtt7hwgmx6ikhgCMO1AWTwOk0omaUcsjKK
zCK9RtlOGwVdW+StGw4CwFGOEEo5CF9paj9B0YNjI1NhCFXt9QNNH+v9jb6L7W/oYqn2qcgnToeqoLImes9jDKcpMOEJS8HWR5rRzvnJ8gxlNvk01aKUudjd
To64LdZKyHRybhu8la2vbuwbIVxi9tgtRSrqnHz4M105cRBI2fy6f6kT+XWZ+ZGK76yoI1rptniSC/l1v6okw1jQRq/l1v6kRdPt90MNZSGz+X2e6J/L7fMo
kNYmCzdLp1r4lEB9Lvf54A1gsfwmWUjr2dJva+aH7iH0XUN7OH7hdczIyqPfNI2vouqX6P3Cq6XqIWxbUMJ77hHT1Gkrur7ZR38MwQ6TZKbi5rC4eOTs5y8D
YRSDOvLajS26aWJxaXh+GIeT191cLIuMkmn4ObPpFTm2pOK9uSrriJMKJ1V0+FU1ibl90K1WknK7NUcprf6A1kiEn3PCGR0lucNYG06OasTljC+oNNo0/bH6
sDWOca3GtPP0R0NoxFSlBvY3zHLquFHRXWtuSa+46HTZeWdVYCzBeUdHKxzY9NXmQf8ALq/1M2StgvzL9wfVg+JImmMv8sr/AFyBl0yKe02bVOL/ADIvK90X
Vxzn072kV/LZPiSR08r3RMomnlxp6G1NYWTpaaEoUpS5Q9JN7hdhLdakxxtT/ekJUW2a9ZHF2BKWDnXefioxNumjwIhHJt00DLTdXH4Qkty618IUUZEUTf0u
juucvCRjjBykordt4O/o9P6FCTXxPkrPVaMlNZRZDTlXnut9AhapXaaPxeUeM1OnlVOUZxcWvc+qeDi9e6NVrNNOdcVG5LbHkNc185awzTpp8xK1GnnRa4WR
aaFQl2TT8FbbHyUXs0CiA0EgUEgokWDktBVkIQAWgcBkwADAkh2AZR2CuZNymLWYmuMEmR1JvOCqzwnLI71Hgt1qPALRBcW2M7dgYR3HduUDGd4yXGWCTrak
Nr07aWQKUx9W5a0yHU0Y8BBQgOjWMhXlGzS6Kdzwtse5kZI1ZTwvByL6ZVysjJYfJ7fTdNjDDluzlfiHRRr1VU0ko2LDePJZ+sdV5/T6buw3sjfXVCCAssjQ
sMxX67O0djtrz46E766+WIl1KK2Ry3OU3u8hQrzyhq+XQj1Kblsgpa62X0MkIJMaoozrc5pq1Nv62EtTd+tiki0ZdcOWqvXFjL/itR/5GKRaIYb/ABWo/wDI
yfxV/wCtgImAYNa3ULiZf8w1K/Ov2F4RTigYaupajzNfsR9S1H6l+xmcRckwY0z6vqYr5l+wMOsalrmP7GC2LwKri3LBUx1ZdZ1K/R+wD63qH4h+xz7INAKP
uQx0V1jU92fh/Y2UdbTSVsWvqjjJIKKCY9HX1TTS5k1/oufUqGvhk3/o8/HYdFZLhjprURsbaZU9VKG0V+5l0uFak+Gb7dJ3LZERkessXsB/GT8lW1OMsMW6
2XDBXaubrayzC9TavLNE63jcX6ZqVm8Wky1Nr2cmB3yf5pfuNnVl8A+izWs3+dCsvy/3Ci2vLCjXjkfCmqWE20zUsY8UqM5e7DVsl+ZmhaBNZjav9hfy2z9a
ZdjPnqM/rT/UwZ6ixfmY96CzAi3TWRXA2H0zR6qfqruy0dmE+9Jo4WlranwdmlNIx03zrHrVm9mdRH6ne5lQjuc69U/B1QN1ENhNcODZVHETCnJbBxjkBGzQ
1epdH2W7IluNfT9JhqyaeVujpAwSisIs0426shRCospkKCxx+t9Hr1tM5RilbznyeD1ulnp7HCS3X0PqmTldZ6PX1Gpyikrktn7hdfPqZ5j2vlDStZpLtLd2
2QcJRZUG5Ry+StjT3DTFBxIoy0CmWmFGQosCMhCwKKZZTRBkwEkUEkVdU45K7NxiiGoEXS4wGRiMjAbGsBKqT8D4V7cDo1D4wSQQiFLkdHT9PlKtScWl9wao
L+Hb/wCWDsUrGmj9glrnwpjDbCbOroopUbJI57+ZnS0ixQiM1oSMnVNH/F6SS8x3RrQXgrFfM+puat4azsY4Qy9z0P4r08KeoQUFhSjlr65OIlg1KYkYJDYo
FLYNBuQcUGkBEOLCiwTBaLIqItERYERZRAIURsrJBGLmwmxcmAue6YmC7Zj5NJC3hsoa45iZ5wwaYLMQZwyRWdBIGS7WRMqGxY2M8CEw0EaFM9DorFqaIvZN
LDR5uJ0em6hU24k8RfJUP6hBKzZrgwj9Tb32yeds7GfIVU45iLcGh2SmgE9mUTsG4KLoX2Fdm4wmBpgYykuGaIaqcedzPgmCamNj1y8xDhdXasYw/qc/tZEm
nlF1PLr10R5UUHavThkx6XVuOFKOcG5uOph2ous+XLeZzbwNrgXKl12OLX2HVxMV1g64bo0rgXBYGIyo4na6ZBKhyxu2cWJ39AsaWJGOvxpRCizbkhCEAopl
lMCEIUBg6r0unqNXxLFiW0jxGs6dfoNQ4WxxF8P3Poxl12kr1dTjZBS2x9gsr520EkdLqPSbtFNtRcq/Dwc9RYblVgsvtZO1hrUQSKSZYVZETBeCCEwEkXgD
CoMZGJcdw0gmoohJFIvITTEOqSkzMmadNwymtC2CQKDQNaK/8b/2OrX/AI8f+pzIf4yX/I6kP8eP/UDG/mOppf8AHict/MdTS/2IkQ5FlIsMvE/iybl1ftfE
YLBxUdv8WQa6r3b/ABQRxEitQS4DQC4DQXRINMWhiKo0wkAgkRRZLBJkAsg5I2D3AXkpspyFymQE5ATewHfkVOzLwGlznnZCnkZFbl2R22Aqq5xeHwa000Yu
zbOS1ZOtLHAD7IZM72ZphYpx3BsqzugyVF5GJimnFhRkUPixkZYERYxMqHqQSFRYxMAuCu4psoAmymyiBRF4KRYA4J27B4JjYAFEJRLUdxqgAMIMfBzg04vg
uEBvaiaYelDU1/8APx9BPa4PEkDHNc1KJr+G+GeJEoUmWmBhxk0/AcFkg0VrJ3tMsUROJp4OUkvdo70FiKS8BjqmEKRZXJCEIFVkjZZQFEIQCFMspgDZCNke
2STTOJrugQm3PTS7ZfpfB3SFa14a/RW6efbZBr642E+ke7uqjdBxmk0/dHPt6TRJfDFL/RFleUdeClXnwegt6Ps+3kxT6fbB4wGtc308FqBulo7F4K/hJ+wN
Y+wvtN8en3S3Udhkel2t7rANefgEXCthemysaEvASgwo1soDBs0y+AQqm3wbKoYjgC0g0glEvBFOh/YX3Z1kv6Mf+py4r+jD7s6j2qX2IsYn8x09N/ZRzfzH
So2qj9iFPRCkWGXnfxZpHbTVqI79jw/seT7cH0nU0R1OnnVNbSWDw3Uun2aK9xksxfD9yxY56CRMFpFVaCQKQS5C6NMtSBIFH3F5F5JkKNsW5YBnPBnstYDL
LkhSm5MVhyfI6EcAHFbCZpqY5Swil8UgsLUsMY3mBLIJEa7YYDUK7tik3IJLLCjFJkB1Ywh+cIxNuEtuApWTawgzWicO7gRKEojq89qzyHhMqM0ZYGqRJUpg
OEovYIfGQamZlNrlYGRsQDu4JMSpJhJlUwgCkEmAaCQtPcNMA0GlkCLGxICjBDoxQtSj5YXrQiuckDoxRbwjHZq98RFu2UuWFxrssjwiq7XF5TM0WOrRB0Iu
N0M5+IkIYZnhCUV3QeJHT0lDvazt7hm3GjptLy5tbeDpoCuKhFJINFcrdWWUWVlCZIQipkhCAUQhAIUQsIohGUFRghMoKguVcZPdBkIF+jD9KK9Gv9KGEKAV
aXASikQhFeJhDYPsIQ2J2BKJCAEkOgiEAMhCEWNK/s1/7OlL+2vsQhKrH+Y6dP8Abj9iEIlOXBCEDNQza7RV62h1zW/h+xCFI8brOm2aOxxsXnZ+6MvpPwQg
aC4YIkQhVFgp7EIGgORTmiEARbckZ8uyX0IQK0VQG9uxCALmi6tmQgWDtw8C5ttEIRoMCSfbIhAqp/FBPG4VONskIGK07IhCFRaDSRCAVOqMkJena4ZCAA67
FwV3zjyiEAv12uUFHUIhCg1cglciEID/AIhLyT+Jb4IQCd9jCjFvdshCA0giEAZE0VeCEI01we6Ox02a7XHG/OSEDHToIhCFcKsshCiyEIRUKIQCEIQCFEIE
RlEIFQpkIQUQhAqiEIBRCEA//9k=
]==] },
    { name = "MeleeRNG_UI_BG_Frame_018.jpg", data = [==[
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
QgAIQgEIQgQAEIAGAhCKhCECgQhAAQhAP//Z
]==] },
    { name = "MeleeRNG_UI_BG_Frame_019.jpg", data = [==[
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
]==] },
    { name = "MeleeRNG_UI_BG_Frame_020.jpg", data = [==[
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
]==] },
    { name = "MeleeRNG_UI_BG_Frame_021.jpg", data = [==[
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
ICWAASAAFAgABMQAQPwSAAAAAV//2Q==
]==] },
    { name = "MeleeRNG_UI_BG_Frame_022.jpg", data = [==[
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
AD//2Q==
]==] },
    { name = "MeleeRNG_UI_BG_Frame_023.jpg", data = [==[
/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAA0JCgwKCA0MCwwPDg0QFCIWFBISFCkdHxgiMSszMjArLy42PE1CNjlJOi4vQ1xESVBSV1dXNEFfZl5UZU1VV1P/
2wBDAQ4PDxQSFCcWFidTNy83U1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1P/wAARCAFoAoADASIAAhEBAxEB/8QA
GwAAAgMBAQEAAAAAAAAAAAAAAAECAwQFBgf/xAA4EAACAgEDAwIEBAUDBAMBAAAAAQIDEQQhMQUSQTJREyJhcQYUIzM0QnKBkSRSYhWCscFDodHh/8QAGAEB
AQEBAQAAAAAAAAAAAAAAAAECAwT/xAAdEQEBAQEBAQEAAwAAAAAAAAAAARECEjEhA0FR/9oADAMBAAIRAxEAPwDITiQJxMKmAAFAvIwwFWR4DAR4GAHVo/jK
f+05WTp1WRhrYOXEUn/9BWzXeSrp8lHVLuePlZl6j1OuLwmmzi29TtlL5H2+w0x7G/qFFCzOa+xzdT16OMVpHlp3znvKTZX3v3C+Xc1HWLrFhS7fsY5aqUnl
ybfuYFOXkl3si40z1En5IfGaM7mxd7YxcaXe2L4pnyDK3i/4iD4hQgyDF0rMkG2yKJILhYZFk2yDZBEjImtwnBpZYVSydUslbJVJ9xUXJZaWcb8nuOm6eD6b
Gvu74uPJ4tQ9z0v4a1E2p0uWYRWy9hGOnO1ujlXa2o7p7mTs5x/g9nqtHG5dyXzefqcHVaB1zbS2Z2lZcBVPT6jv/klsyi+p6fVd38s+DtW6dOLjJcme/TfH
0bj/APLW8x+pOmpVEHmKJYKtNlwxL1eUXnKt6g0RktibIy4MiqSyQcMloFFSrLYw2JIYVTKpN7koxUVhIsDBdTEMZRDsw8otwRZNMZ7dkcPqMu5tHcv4Z5/W
yzZsajNbel9qpa2TN6OV05vtwdVcCswMcRDRlpIWBgURwLBMMAQwC2ZJkHyFWp7AQUh9xESFgXcPLAMDSAYAJsYpALId2ERE+AJfED4hWGCI0wtL4WswR5NE
GDHSo1Tg8p4Z29B1TLULHseXjI0VTaDOPbxnGazF5Gea0PUJ1SSnJuJ6Gm6NsU4sjKxlbLCEuQjxZOJAnE2iYAAANCAKsiDeCvviuWZNRqstxQWNE9QotpMz
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
2Q==
]==] },
    { name = "MeleeRNG_UI_BG_Frame_024.jpg", data = [==[
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
]==] },
    { name = "MeleeRNG_UI_BG_Frame_025.jpg", data = [==[
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
]==] },
    { name = "MeleeRNG_UI_BG_Frame_026.jpg", data = [==[
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
hCCAIQCAIQCEIQD/2Q==
]==] },
    { name = "MeleeRNG_UI_BG_Frame_027.jpg", data = [==[
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
]==] },
    { name = "MeleeRNG_UI_BG_Frame_028.jpg", data = [==[
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
]==] },
    { name = "MeleeRNG_UI_BG_Frame_029.jpg", data = [==[
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
dgkIHKoQhCIj4FIQCNZ5ElUmQgVW6cC+iIQD/9k=
]==] },
    { name = "MeleeRNG_UI_BG_Frame_030.jpg", data = [==[
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
2Q==
]==] },
    { name = "MeleeRNG_UI_BG_Frame_031.jpg", data = [==[
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
oNFPNcfwQhXLpsAQhXNCEIACEIQQhCAf/9k=
]==] },
    { name = "MeleeRNG_UI_BG_Frame_032.jpg", data = [==[
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
ER//2Q==
]==] },
}

local function uiBgTrySet(inst, prop, value)
    pcall(function() inst[prop] = value end)
end

local function uiBgFileExists(path)
    if type(isfile) ~= "function" then return false end
    local ok, exists = pcall(isfile, path)
    return ok and exists == true
end

local function uiBgLooksLikeMp4(data)
    if type(data) ~= "string" or #data < 20000 then return false end
    return data:sub(5, 8) == "ftyp" or data:sub(1, 128):find("ftyp", 1, true) ~= nil
end

local function uiBgEnsureVideoDownloaded(forceRefresh)
    if not forceRefresh and uiBgFileExists(UI_BG_VIDEO_FILE) then
        UI_BG_LAST_STATUS = "local MP4 ready"
        return true
    end
    if type(writefile) ~= "function" then
        UI_BG_LAST_STATUS = "writefile missing"
        return false
    end
    if type(UI_BG_GITHUB_RAW_URL) ~= "string" or UI_BG_GITHUB_RAW_URL == "" then
        UI_BG_LAST_STATUS = "GitHub URL empty"
        return false
    end

    local ok, data = pcall(function()
        return game:HttpGet(UI_BG_GITHUB_RAW_URL)
    end)
    if not ok or type(data) ~= "string" then
        UI_BG_LAST_STATUS = "MP4 download failed"
        return false
    end
    if not uiBgLooksLikeMp4(data) then
        UI_BG_LAST_STATUS = "download was not an MP4 — check raw URL"
        return false
    end

    local wrote, err = pcall(function()
        writefile(UI_BG_VIDEO_FILE, data)
    end)
    if not wrote then
        UI_BG_LAST_STATUS = "MP4 write failed: " .. tostring(err)
        return false
    end

    UI_BG_LAST_STATUS = "MP4 downloaded from GitHub"
    return uiBgFileExists(UI_BG_VIDEO_FILE)
end

local function uiBgGetCustomAsset(path)
    local fn = nil
    if type(getcustomasset) == "function" then
        fn = getcustomasset
    elseif type(getsynasset) == "function" then
        fn = getsynasset
    end
    if not fn then return nil end
    local ok, asset = pcall(fn, path)
    if ok and type(asset) == "string" and asset ~= "" then
        return asset
    end
    return nil
end

local function uiBgLocalFramePath(i)
    return string.format("%s/frame_%04d.png", UI_BG_LOCAL_FRAME_FOLDER, i)
end

local function uiBgEnsureLocalPngFrames()
    if _uiBgCachedLocalAssets and #_uiBgCachedLocalAssets > 0 then
        return _uiBgCachedLocalAssets
    end

    local firstPath = uiBgLocalFramePath(1)
    if not uiBgFileExists(firstPath) then
        UI_BG_LAST_STATUS = "local PNG frames missing at " .. firstPath
        return nil
    end

    local assets = {}
    for i = 1, UI_BG_LOCAL_FRAME_COUNT do
        local path = uiBgLocalFramePath(i)
        if not uiBgFileExists(path) then
            UI_BG_LAST_STATUS = string.format("local PNG sequence stopped at frame %04d", i)
            break
        end

        local asset = uiBgGetCustomAsset(path)
        if not asset then
            UI_BG_LAST_STATUS = "local PNG frames need getcustomasset/getsynasset"
            return nil
        end
        assets[#assets + 1] = asset
    end

    if #assets == 0 then
        UI_BG_LAST_STATUS = "local PNG frames found but no assets loaded"
        return nil
    end

    _uiBgCachedLocalAssets = assets
    UI_BG_LAST_STATUS = string.format("using local PNG frames (%d/%d at %d FPS)", #assets, UI_BG_LOCAL_FRAME_COUNT, UI_BG_LOCAL_FRAME_FPS)
    return assets
end

local function uiBgGetVideoSource()
    if type(UI_BG_ASSET_ID) == "string" and UI_BG_ASSET_ID ~= "" then
        UI_BG_LAST_STATUS = "using Roblox video asset id"
        return "rbxassetid://" .. UI_BG_ASSET_ID
    end

    uiBgEnsureVideoDownloaded(false)

    if uiBgFileExists(UI_BG_VIDEO_FILE) then
        local asset = uiBgGetCustomAsset(UI_BG_VIDEO_FILE)
        if asset then
            UI_BG_LAST_STATUS = UI_BG_LAST_STATUS .. " + VideoFrame attempt"
            return asset
        end
        UI_BG_LAST_STATUS = "local MP4 ready, but getcustomasset/getsynasset is missing or blocked"
    end
    return nil
end

local function uiBgDecodeB64(data)
    if type(data) ~= "string" then return "" end

    local crypt = rawget(getgenv and getgenv() or _G, "crypt")
    if type(crypt) == "table" and type(crypt.base64) == "table" and type(crypt.base64.decode) == "function" then
        local ok, out = pcall(crypt.base64.decode, data)
        if ok and type(out) == "string" then return out end
    end
    if type(base64_decode) == "function" then
        local ok, out = pcall(base64_decode, data)
        if ok and type(out) == "string" then return out end
    end
    if type(syn) == "table" and type(syn.crypt) == "table" and type(syn.crypt.base64) == "table" and type(syn.crypt.base64.decode) == "function" then
        local ok, out = pcall(syn.crypt.base64.decode, data)
        if ok and type(out) == "string" then return out end
    end

    local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    data = data:gsub("%s+", ""):gsub("[^" .. b .. "=]", "")
    local bits = data:gsub(".", function(x)
        if x == "=" then return "" end
        local r, f = "", (b:find(x, 1, true) or 1) - 1
        for i = 6, 1, -1 do
            r = r .. ((f % 2 ^ i - f % 2 ^ (i - 1) > 0) and "1" or "0")
        end
        return r
    end)
    return bits:gsub("%d%d%d%d%d%d%d%d", function(x)
        local c = 0
        for i = 1, 8 do
            if x:sub(i, i) == "1" then
                c = c + 2 ^ (8 - i)
            end
        end
        return string.char(c)
    end)
end

local function uiBgEnsureEmbeddedFrames()
    if _uiBgCachedAssets and #_uiBgCachedAssets > 0 then
        return _uiBgCachedAssets
    end
    if type(writefile) ~= "function" then
        UI_BG_LAST_STATUS = "fallback frames need writefile"
        return nil
    end

    local assets = {}
    for _, frame in ipairs(UI_BG_EMBEDDED_FRAMES) do
        local path = frame.name
        if not uiBgFileExists(path) then
            local decoded = uiBgDecodeB64(frame.data)
            if type(decoded) ~= "string" or #decoded < 1000 then
                UI_BG_LAST_STATUS = "fallback frame decode failed"
                return nil
            end
            local ok = pcall(function()
                writefile(path, decoded)
            end)
            if not ok then
                UI_BG_LAST_STATUS = "fallback frame write failed"
                return nil
            end
        end
        local asset = uiBgGetCustomAsset(path)
        if not asset then
            UI_BG_LAST_STATUS = "fallback frames need getcustomasset/getsynasset"
            return nil
        end
        assets[#assets + 1] = asset
    end

    _uiBgCachedAssets = assets
    UI_BG_LAST_STATUS = "using embedded animated MP4 frames"
    return assets
end

local function uiBgFindRoot()
    local pg = LP and LP:FindFirstChildOfClass("PlayerGui")
    if not pg then return nil end
    if _uiBgRoot and _uiBgRoot.Parent == pg then return _uiBgRoot end

    local best, bestScore = nil, -1
    for _, sg in ipairs(pg:GetChildren()) do
        if sg:IsA("ScreenGui") and sg.Name ~= MOUSE_UNLOCK_GUI_NAME then
            local score = 0
            local n = tostring(sg.Name):lower()
            if n:find("nexus", 1, true) then score = score + 8 end
            if n:find("melee", 1, true) or n:find("rng", 1, true) then score = score + 8 end
            for _, d in ipairs(sg:GetDescendants()) do
                if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
                    local t = tostring(d.Text or "")
                    if t:find("Melee RNG", 1, true) then score = score + 40 end
                    if t:find("Auto Upgrade", 1, true) then score = score + 8 end
                    if t:find("Sacrifice", 1, true) then score = score + 5 end
                end
            end
            if score > bestScore then
                bestScore = score
                best = sg
            end
        end
    end
    if bestScore >= 8 then
        _uiBgRoot = best
        return best
    end
    return nil
end

local function uiBgFindWindowFrame(root)
    if not root then return nil end
    local best, bestArea = nil, 0
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("Frame") then
            local sx, sy = d.AbsoluteSize.X, d.AbsoluteSize.Y
            local area = sx * sy
            if sx >= 520 and sy >= 320 and area > bestArea then
                bestArea = area
                best = d
            end
        end
    end
    return best
end

local function uiBgIsOwnObject(obj)
    return obj and (
        obj.Name == UI_BG_LAYER_NAME or
        obj.Name == UI_BG_VIDEO_NAME or
        obj.Name == UI_BG_IMAGE_NAME or
        obj.Name == UI_BG_DIM_NAME
    )
end

local function uiBgSoftenLargePanel(obj)
    if not obj or uiBgIsOwnObject(obj) then return end
    if not (obj:IsA("Frame") or obj:IsA("ScrollingFrame")) then return end

    local sx, sy = obj.AbsoluteSize.X, obj.AbsoluteSize.Y
    if sx < 220 or sy < 120 then return end

    obj:SetAttribute(UI_BG_SCREEN_ATTR, true)
    obj:SetAttribute(UI_BG_PANEL_ALPHA_ATTR, UI_BG_PANEL_TRANSPARENCY)
    obj.BackgroundColor3 = obj.BackgroundColor3:Lerp(Color3.fromRGB(8, 10, 19), 0.18)
    obj.BackgroundTransparency = math.max(obj.BackgroundTransparency, UI_BG_PANEL_TRANSPARENCY)

    if obj:IsA("ScrollingFrame") then
        uiBgTrySet(obj, "ScrollBarImageTransparency", 0.02)
    end
end

local function uiBgSoftenPanels(root)
    if not root then return end
    task.defer(function()
        task.wait(0.15)
        if GEN ~= _G.MeleeRNG_Gen or not root.Parent then return end
        for _, d in ipairs(root:GetDescendants()) do
            uiBgSoftenLargePanel(d)
        end
        if _uiBgPanelConn then pcall(function() _uiBgPanelConn:Disconnect() end) end
        _uiBgPanelConn = root.DescendantAdded:Connect(function(d)
            task.defer(function()
                task.wait(0.05)
                if GEN ~= _G.MeleeRNG_Gen then return end
                uiBgSoftenLargePanel(d)
            end)
        end)
        addConn(_uiBgPanelConn)
    end)
end

local function uiBgStartFrameAnimation(img, assets)
    _uiBgAnimToken = _uiBgAnimToken + 1
    local token = _uiBgAnimToken
    if not img or not assets or #assets == 0 then return end
    img.Visible = true
    img.ImageTransparency = 0
    img.Image = assets[1]
    local delay = UI_BG_FRAME_SECONDS / math.max(1, #assets)
    if #assets >= 120 then
        delay = 1 / math.max(1, UI_BG_LOCAL_FRAME_FPS)
    end
    task.spawn(function()
        local i = 1
        while GEN == _G.MeleeRNG_Gen and token == _uiBgAnimToken and img and img.Parent do
            i = i + 1
            if i > #assets then i = 1 end
            img.Image = assets[i]
            task.wait(delay)
        end
    end)
end

local function meleeApplyOldGuiMp4Background(enabled)
    local root = uiBgFindRoot()
    if not root then return false end
    root.ResetOnSpawn = false
    root.IgnoreGuiInset = true
    uiBgTrySet(root, "ZIndexBehavior", Enum.ZIndexBehavior.Sibling)

    local window = uiBgFindWindowFrame(root) or root
    local layer = window:FindFirstChild(UI_BG_LAYER_NAME)

    if enabled == false then
        _uiBgAnimToken = _uiBgAnimToken + 1
        if layer then layer:Destroy() end
        UI_BG_LAST_STATUS = "background off"
        return true
    end

    if not layer then
        layer = Instance.new("Frame")
        layer.Name = UI_BG_LAYER_NAME
        layer.Size = UDim2.new(1, 0, 1, 0)
        layer.Position = UDim2.new(0, 0, 0, 0)
        layer.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        layer.BackgroundTransparency = 0
        layer.BorderSizePixel = 0
        layer.ZIndex = 0
        layer.ClipsDescendants = true
        layer.Parent = window
    end
    layer.Visible = true
    layer.Size = UDim2.new(1, 0, 1, 0)
    layer.Position = UDim2.new(0, 0, 0, 0)
    layer.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    layer.BackgroundTransparency = 0

    -- Stop the game world from bleeding through the old GUI.
    -- The MP4/fallback frame sits on top of this black base; if a client blocks local assets,
    -- the UI becomes solid black instead of transparent gray.
    uiBgTrySet(window, "BackgroundColor3", Color3.fromRGB(0, 0, 0))
    uiBgTrySet(window, "BackgroundTransparency", 0)

    local img = layer:FindFirstChild(UI_BG_IMAGE_NAME)
    if not img then
        img = Instance.new("ImageLabel")
        img.Name = UI_BG_IMAGE_NAME
        img.Size = UDim2.new(1, 0, 1, 0)
        img.Position = UDim2.new(0, 0, 0, 0)
        img.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        img.BackgroundTransparency = 0
        img.BorderSizePixel = 0
        img.ZIndex = 0
        img.Parent = layer
    end
    img.Visible = false
    img.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    img.BackgroundTransparency = 0
    img.ImageTransparency = 0
    uiBgTrySet(img, "ScaleType", Enum.ScaleType.Crop)

    local video = layer:FindFirstChild(UI_BG_VIDEO_NAME)
    if not video then
        video = Instance.new("VideoFrame")
        video.Name = UI_BG_VIDEO_NAME
        video.Size = UDim2.new(1, 0, 1, 0)
        video.Position = UDim2.new(0, 0, 0, 0)
        video.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        video.BackgroundTransparency = 0
        video.BorderSizePixel = 0
        video.ZIndex = 0
        video.Parent = layer
    end
    video.Visible = false
    uiBgTrySet(video, "ScaleType", Enum.ScaleType.Crop)
    uiBgTrySet(video, "Looped", true)
    uiBgTrySet(video, "Volume", 0)
    uiBgTrySet(video, "VideoTransparency", 0)

    local dim = layer:FindFirstChild(UI_BG_DIM_NAME)
    if not dim then
        dim = Instance.new("Frame")
        dim.Name = UI_BG_DIM_NAME
        dim.Size = UDim2.new(1, 0, 1, 0)
        dim.Position = UDim2.new(0, 0, 0, 0)
        dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        dim.BackgroundTransparency = UI_BG_DIM_TRANSPARENCY
        dim.BorderSizePixel = 0
        dim.ZIndex = 0
        dim.Parent = layer
    end
    dim.Visible = true
    dim.BackgroundTransparency = UI_BG_DIM_TRANSPARENCY

    -- Use a real VideoFrame only when a Roblox video asset id is explicitly provided.
    -- Otherwise local PNG frames are preferred and no network download is needed.
    local src = nil
    local useRealRobloxVideo = false
    if type(UI_BG_ASSET_ID) == "string" and UI_BG_ASSET_ID ~= "" then
        src = uiBgGetVideoSource()
        useRealRobloxVideo = src ~= nil
    end

    if useRealRobloxVideo then
        uiBgTrySet(video, "Video", src)
        video.Visible = true
        img.Visible = false
        pcall(function() video:Play() end)
    else
        video.Visible = false
        local assets = uiBgEnsureLocalPngFrames() or uiBgEnsureEmbeddedFrames()
        if assets and #assets > 0 then
            uiBgStartFrameAnimation(img, assets)
            if assets == _uiBgCachedLocalAssets then
                UI_BG_LAST_STATUS = string.format("using visible local PNG frames (%d/%d at %d FPS)", #assets, UI_BG_LOCAL_FRAME_COUNT, UI_BG_LOCAL_FRAME_FPS)
            else
                UI_BG_LAST_STATUS = "using visible embedded fallback frames"
            end
        else
            -- No asset support: stay opaque instead of showing the game through the GUI.
            img.Visible = true
            img.Image = ""
            img.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
            img.BackgroundTransparency = 0
            UI_BG_LAST_STATUS = tostring(UI_BG_LAST_STATUS) .. " — using solid black fallback"
        end
    end

    uiBgSoftenPanels(root)
    return true
end

local function uiBgStatusText()
    return states.uiVideoBackground and ("Local PNG background: ON - " .. tostring(UI_BG_LAST_STATUS)) or "Local PNG background: OFF"
end

local function getAscendAfterTpCFrame()
    local x = tonumber(states.ascendAfterTpX) or DEF_ASCEND_TP_X
    local y = tonumber(states.ascendAfterTpY) or DEF_ASCEND_TP_Y
    local z = tonumber(states.ascendAfterTpZ) or DEF_ASCEND_TP_Z
    x = math.clamp(x, -500000, 500000)
    y = math.clamp(y, -50000, 500000)
    z = math.clamp(z, -500000, 500000)
    return CFrame.new(x, y, z)
end

-- Post-ascend TP: retry until HRP is within tolerance of saved spot at least once (or timeout).
local ASCEND_TP_NEAR_STUDS   = 20   -- count as "arrived" when HRP is this close to target
local ASCEND_TP_RETRY_SEC    = 0.12 -- how often to re-apply CFrame while not there yet
local ASCEND_TP_MAX_CHASE    = 90   -- stop retrying after this many seconds (avoid hanging forever)
local ASCEND_STAT_WAIT_ITER  = 60  -- 60×0.1s = up to 6s for Ascends stat to replicate

local function getAscendAfterTpWorldPos()
    return (getAscendAfterTpCFrame() * CFrame.new(0, 3, 0)).Position
end

local function hrpNearAscendTp()
    local root = getRoot()
    if not root then return false end
    local tgt = getAscendAfterTpWorldPos()
    return (root.Position - tgt).Magnitude <= ASCEND_TP_NEAR_STUDS
end

-- Post-ascend aura roll (AuraRollUI.Options.ConfirmBtn = KEEP AURA) — dump AuraRollController
local _getconnections = rawget(_G, "getconnections")
local AURA_KEEP_POLL_SEC      = 0.2
local AURA_KEEP_MAX_WAIT_SEC  = 90
-- Ascend roll UI can appear late; too short a skip exits before KEEP can run
local AURA_NO_ROLL_SKIP_SEC   = 22

local function fireGuiSignal(sig)
    if not sig then return false end
    local fs = rawget(_G, "firesignal")
    if type(fs) == "function" and pcall(fs, sig) then
        return true
    end
    if type(_getconnections) == "function" then
        local ok, conns = pcall(_getconnections, sig)
        if ok and type(conns) == "table" then
            for _, c in ipairs(conns) do
                if type(c) == "table" and type(c.Function) == "function" then
                    pcall(c.Function)
                    return true
                end
            end
        end
    end
    return false
end

local function fireGuiButtonClick(btn)
    if not btn then return false end
    return fireGuiSignal(btn.MouseButton1Click)
end

--- MobsClientController: only MouseButton1Click toggles local Auto Raid state (dump).
local function meleeFireAutoRaidClick()
    pcall(function()
        local btn = LP.PlayerGui.MainGUI.OptionsList.AutoRaidBtn
        firesignal(btn.MouseButton1Click)
    end)
end

local function meleeResolveAutoRaidBtn()
    local pg = LP:FindFirstChild("PlayerGui")
    if not pg then return nil end
    local main = pg:FindFirstChild("MainGUI")
    if not main then return nil end
    local ol = main:FindFirstChild("OptionsList")
    if not ol then return nil end
    return ol:FindFirstChild("AutoRaidBtn")
end

--- nil if label missing / unrecognized; true/false from "AUTO RAID: ON|OFF"
local function meleeAutoRaidBtnLabelIsOn(btn)
    if not btn then return nil end
    local t
    local tl = btn:FindFirstChild("TextLabel")
    if tl and type(tl.Text) == "string" then
        t = tl.Text
    elseif (btn:IsA("TextButton") or btn:IsA("TextLabel")) and type(btn.Text) == "string" then
        t = btn.Text
    end
    if type(t) ~= "string" then return nil end
    t = (t:gsub("^%s+", ""):gsub("%s+$", ""))
    if string.find(t, ": ON", 1, true) then return true end
    if string.find(t, ": OFF", 1, true) then return false end
    return nil
end

--- Farm handoff: one click only when label explicitly says ON. Never click on "?" — that can toggle OFF→ON.
local function meleeEnsureAutoRaidOffForFarm()
    local btn = meleeResolveAutoRaidBtn()
    if btn then
        pcall(function()
            btn.Visible = true
        end)
    end
    if meleeAutoRaidBtnLabelIsOn(btn) ~= true then
        return
    end
    meleeFireAutoRaidClick()
    task.wait(0.5)
end

--- Toggle Auto Raid via firesignal only; wait between tries so the label can update (double fire = OFF again).
local function meleeSetGameAutoRaidEnabled(wantOn)
    wantOn = wantOn == true
    if wantOn and meleeAutoFarmStatus.raidPhaseActive ~= true then
        return meleeResolveAutoRaidBtn() ~= nil
    end

    if not wantOn then
        meleeEnsureAutoRaidOffForFarm()
        return meleeResolveAutoRaidBtn() ~= nil
    end

    local maxAttempts = 6
    for _ = 1, maxAttempts do
        local btn = meleeResolveAutoRaidBtn()
        if btn then
            pcall(function()
                btn.Visible = true
            end)
        end
        local cur = meleeAutoRaidBtnLabelIsOn(btn)
        if cur == true then
            break
        end
        if btn then
            meleeFireAutoRaidClick()
            task.wait(0.5)
        else
            break
        end
    end
    return meleeResolveAutoRaidBtn() ~= nil
end

local function meleeNudgeAutoRaidOnIfUiOff()
    if meleeAutoFarmStatus.raidPhaseActive ~= true then return end
    if meleeAutoFarmStatus.farmPhaseActive == true then return end
    if meleeAutoRaidUiShort() ~= "OFF" then return end
    meleeFireAutoRaidClick()
    task.wait(0.4)
end

local function meleeAutoRaidUiShort()
    local cur = meleeAutoRaidBtnLabelIsOn(meleeResolveAutoRaidBtn())
    if cur == true then return "ON" end
    if cur == false then return "OFF" end
    return "?"
end

local function manualAuraRollUiClose(main, roll)
    local general = main and main:FindFirstChild("GeneralUI")
    pcall(function()
        roll.Visible = false
        if general then general.Visible = true end
        local ch = LP.Character
        local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
        if hrp then hrp.Anchored = false end
        local ar = workspace:FindFirstChild("AuraRollArea")
        if ar and ar.Parent == workspace then
            ar.Parent = RS
        end
        workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
    end)
    return true
end

--- One-shot: when Options + ConfirmBtn are visible, fire KEEP (or mirror client cleanup). Returns true if keep was triggered.
local function tryFireAuraKeepOnce(main)
    if not main then return false end
    local roll = main:FindFirstChild("AuraRollUI")
    if not roll then return false end
    local opts = roll:FindFirstChild("Options")
    if not roll.Visible then
        if opts then pcall(function() opts:SetAttribute("_MeleeKeptAura", nil) end) end
        return false
    end
    if not opts or not opts.Visible then return false end
    if opts:GetAttribute("_MeleeKeptAura") then return false end
    local confirm = opts:FindFirstChild("ConfirmBtn")
    if not confirm then return false end
    local ok = fireGuiButtonClick(confirm)
    if not ok then
        ok = manualAuraRollUiClose(main, roll)
    end
    if ok then
        pcall(function() opts:SetAttribute("_MeleeKeptAura", true) end)
    end
    return ok
end

local function waitAscendAuraKeepIfNeeded()
    if not states.ascendAuraKeepBeforeTp then return end
    local t0 = os.clock()
    local seenRoll = false
    local noRollSince = nil
    while os.clock() - t0 < AURA_KEEP_MAX_WAIT_SEC do
        if GEN ~= _G.MeleeRNG_Gen then return end
        local pg = LP:FindFirstChild("PlayerGui")
        local main = pg and pg:FindFirstChild("MainGUI")
        local roll = main and main:FindFirstChild("AuraRollUI")
        if roll and roll.Visible then
            seenRoll = true
            noRollSince = nil
        else
            if not noRollSince then noRollSince = os.clock() end
            if not seenRoll and (os.clock() - noRollSince) >= AURA_NO_ROLL_SKIP_SEC then
                return
            end
        end
        if main and tryFireAuraKeepOnce(main) then
            task.wait(0.35)
            return
        end
        task.wait(AURA_KEEP_POLL_SEC)
    end
end

-- Forward declaration: teleportAfterAscendIfConfirmed spawns a thread that calls these; bodies assigned below.
local maintainPreferredAuraSelection
local forceSelectPreferredAuraNow

--- Wait for Ascends to increase, then keep TPing until local HRP reaches saved position once (or chase timeout).
local function teleportAfterAscendIfConfirmed(beforeAscends)
    beforeAscends = tonumber(beforeAscends) or 0
    local ascended = false
    for _ = 1, ASCEND_STAT_WAIT_ITER do
        if GEN ~= _G.MeleeRNG_Gen then return false end
        task.wait(0.1)
        local now = tonumber(getAscends()) or 0
        if now > beforeAscends then
            ascended = true
            break
        end
    end
    if not ascended then return false end

    waitAscendAuraKeepIfNeeded()
    -- Re-equip saved preferred aura (e.g. after ascend) even if "Keep selected aura on" is OFF
    pcall(forceSelectPreferredAuraNow)
    task.spawn(function()
        task.wait(0.75)
        pcall(forceSelectPreferredAuraNow)
        maintainPreferredAuraSelection(true)
    end)

    local deadline = os.clock() + ASCEND_TP_MAX_CHASE
    while os.clock() < deadline do
        if GEN ~= _G.MeleeRNG_Gen then return false end
        if hrpNearAscendTp() then
            return true
        end
        local root = getRoot()
        if root then
            pcall(function()
                root.CFrame = getAscendAfterTpCFrame() * CFrame.new(0, 3, 0)
            end)
        end
        task.wait(ASCEND_TP_RETRY_SEC)
    end
    return hrpNearAscendTp()
end

local function formatAscendTpSaved()
    return string.format("X=%.2f Y=%.2f Z=%.2f",
        tonumber(states.ascendAfterTpX) or DEF_ASCEND_TP_X,
        tonumber(states.ascendAfterTpY) or DEF_ASCEND_TP_Y,
        tonumber(states.ascendAfterTpZ) or DEF_ASCEND_TP_Z)
end

--- MainGUI: GeneralUI (HUD) + NotifFrame (stacked toasts — NotifUIManager, Remotes.SendNotification).
local function applyMeleeGameUiHiding(force)
    local anyHide = states.uiHideHud or states.uiHideManaKills or states.uiHideMiniRoll or states.uiHideNotifications
    if not force and not anyHide then
        return
    end
    pcall(function()
        local pg = LP:FindFirstChild("PlayerGui")
        if not pg then return end
        local main = pg:FindFirstChild("MainGUI")
        if not main then return end

        local notif = main:FindFirstChild("NotifFrame")
        if notif and notif:IsA("GuiObject") then
            if states.uiHideNotifications then
                notif.Visible = false
            elseif force then
                notif.Visible = true
            end
        end

        local gen = main:FindFirstChild("GeneralUI")
        if not gen or not gen:IsA("GuiObject") then return end
        if states.uiHideHud then
            gen.Visible = false
            return
        end
        -- Never force gen.Visible = true here — the game sets it during rolls/menus; that caused HUD flashing every 2s.

        local mf = gen:FindFirstChild("ManaFrame")
        local kf = gen:FindFirstChild("KillsFrame")
        local mrf = gen:FindFirstChild("MiniRollFrame")
        local st = gen:FindFirstChild("StageProgress")
        local showMK = not states.uiHideManaKills
        if mf and mf:IsA("GuiObject") then mf.Visible = showMK end
        if kf and kf:IsA("GuiObject") then kf.Visible = showMK end
        if st and st:IsA("GuiObject") then st.Visible = showMK end
        local showMini = not states.uiHideMiniRoll
        if mrf and mrf:IsA("GuiObject") then mrf.Visible = showMini end
    end)
end

addConn(RunService.Heartbeat:Connect(function()
    if GEN ~= _G.MeleeRNG_Gen then return end
    if states.uiHideHud or states.uiHideManaKills or states.uiHideMiniRoll or states.uiHideNotifications then
        applyMeleeGameUiHiding()
    end
end))

-- ── Aura (SelectedAura attribute + GetUnlockedAuras / SelectAura) ───────────
local function getEquippedAuraName()
    local ch = LP.Character
    if not ch then return nil end
    local a = ch:GetAttribute("SelectedAura")
    return (type(a) == "string" and a ~= "") and a or nil
end

local function getRolledAuraNameFromRollUi()
    local pg = LP:FindFirstChild("PlayerGui")
    local main = pg and pg:FindFirstChild("MainGUI")
    local roll = main and main:FindFirstChild("AuraRollUI")
    if not roll or not roll.Visible then return nil end
    local lastText = nil
    for _, ch in ipairs(roll:GetChildren()) do
        local an = ch:FindFirstChild("AuraName")
        if an and an:IsA("TextLabel") and an.Text ~= "" then
            lastText = an.Text
        end
    end
    return lastText
end

local function fetchUnlockedAuraNamesSorted()
    local raw = invokeR("GetUnlockedAuras")
    if type(raw) ~= "table" then return {} end
    local keys = {}
    for k in pairs(raw) do
        if type(k) == "string" and k ~= "" then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    return keys
end

local function buildAuraDropdownOptions(names)
    local o = { { text = "(none)", value = "" } }
    for _, n in ipairs(names) do
        o[#o + 1] = { text = n, value = n }
    end
    return o
end

local _auraMaintainLastFire = 0
local AURA_MAINTAIN_COOLDOWN = 2.5

-- Only FireServer SelectAura when Character.SelectedAura ≠ preferred (no redundant re-equip).
maintainPreferredAuraSelection = function(forceNow)
    if not states.auraMaintainSelection then return end
    local want = states.auraPreferredName
    if type(want) ~= "string" or want == "" then return end
    if not R("SelectAura") then return end
    if getEquippedAuraName() == want then return end
    local now = os.clock()
    if not forceNow and (now - _auraMaintainLastFire) < AURA_MAINTAIN_COOLDOWN then return end
    local raw = invokeR("GetUnlockedAuras")
    if type(raw) ~= "table" or raw[want] == nil then return end
    _auraMaintainLastFire = now
    fireR("SelectAura", want)
end

--- "fired" = remote sent; "already" = SelectedAura already matches; "fail" = bad name / locked / no remote
forceSelectPreferredAuraNow = function()
    local name = states.auraPreferredName
    if type(name) ~= "string" or name == "" then return "fail" end
    if not R("SelectAura") then return "fail" end
    if getEquippedAuraName() == name then return "already" end
    local raw = invokeR("GetUnlockedAuras")
    if type(raw) ~= "table" or raw[name] == nil then return "fail" end
    _auraMaintainLastFire = os.clock()
    fireR("SelectAura", name)
    return "fired"
end

-- Misc → Aura block in its own function (Luau ~200 local register limit in the main UI IIFE).
local function meleeGuiMountMiscAuraSection(MiscTab, SLbl, C)
    MiscTab:Section("Aura (SelectedAura + remotes)")
    MiscTab:Label("Equipped aura = Character:GetAttribute(\"SelectedAura\"). Unlock list = GetUnlockedAuras; equip = SelectAura(name).")
    local auraPreferredDropdown = MiscTab:Dropdown(
        "Preferred aura",
        "Choose one unlocked aura to equip. Tap Refresh if you just unlocked a new one — saved to settings.",
        buildAuraDropdownOptions({}),
        1,
        function(_, val)
            states.auraPreferredName = (type(val) == "string" and val) or ""
            saveSettings()
        end
    )
    local auraMaintainToggle = MiscTab:Toggle(
        "Keep selected aura on",
        "Every ~4s (and after respawn / post-ascend keep): if equipped ≠ preferred, fires SelectAura(preferred).",
        states.auraMaintainSelection,
        function(on)
            states.auraMaintainSelection = on == true
            saveSettings()
            SLbl.Text = on and "Aura: maintain ON" or "Aura: maintain OFF"
        end
    )
    MiscTab:Button("↻", "Refresh aura list", "GetUnlockedAuras → repopulates dropdown", C.sub, function()
        local names = fetchUnlockedAuraNamesSorted()
        auraPreferredDropdown.Refresh(buildAuraDropdownOptions(names), states.auraPreferredName)
        SLbl.Text = (#names > 0) and ("✓ Aura list: " .. tostring(#names)) or "⚠ GetUnlockedAuras failed or empty"
    end)
    MiscTab:Button("✓", "Equip preferred now", "SelectAura only if equipped ≠ preferred and aura is unlocked", C.accent, function()
        local r = forceSelectPreferredAuraNow()
        if r == "fired" then
            SLbl.Text = "✓ SelectAura → " .. tostring(states.auraPreferredName)
        elseif r == "already" then
            SLbl.Text = "✓ Aura already equipped: " .. tostring(states.auraPreferredName)
        else
            SLbl.Text = "⚠ Equip failed — set preferred, Refresh list, ensure unlocked"
        end
    end)
    task.defer(function()
        pcall(function()
            local names = fetchUnlockedAuraNamesSorted()
            auraPreferredDropdown.Refresh(buildAuraDropdownOptions(names), states.auraPreferredName)
            if auraMaintainToggle and auraMaintainToggle.Set then
                auraMaintainToggle.Set(states.auraMaintainSelection)
            end
        end)
    end)
end

-- Misc → Ascend + farm cycle toggles + TP buttons (Luau ~200 locals in main UI IIFE).
local function meleeGuiMountMiscAscendSection(MiscTab, SLbl, C)
    MiscTab:Section("Ascend")
    local autoFarmCycleStatusLbl = MiscTab:Label("🔁 Farm cycle: OFF")
    local autoAscendToggle = MiscTab:Toggle("⬆️ Auto Ascend", "When kills ≥ (2 + Ascends) × 1M — ConfirmAscend + saved TP chase. Pair with Auto Farm cycle for full loop; cycle never calls ascend.", states.autoAscend, function(on)
        states.autoAscend = on == true
        saveSettings()
        SLbl.Text = states.autoAscend and "Auto Ascend ON" or "Auto Ascend OFF"
    end)
    MiscTab:Label(
        "Notes — Auto Ascend: runs in its own loop. When kills ≥ (2 + Ascends) × 1M, it InvokeServer(ConfirmAscend) if your area has NextPortal, then runs the saved post-ascend TP chase (same as Ascend Now on success). Works while Auto Farm cycle is ON.")
    MiscTab:Label(
        "Notes — together: Auto Farm cycle never calls ConfirmAscend. After the cycle reaches the kill gate it waits until your Ascends stat increases, then runs the TP chase and starts the next loop. For hands-off play, turn Auto Farm cycle ON and Auto Ascend ON.")
    local autoCycleFarmToggle = MiscTab:Toggle(
        "🔁 Auto Farm cycle",
        "TP → upgrades/raid if needed → raid off → farm to ascend kills → wait for ascend (use ⬆️ Auto Ascend ON for auto).",
        states.autoCycleFarm,
        function(on)
            states.autoCycleFarm = on == true
            if not on then
                meleeAutoFarmStatus.raidPhaseActive = false
                meleeAutoFarmStatus.farmPhaseActive = false
            end
            saveSettings()
            SLbl.Text = on and "Auto Farm cycle ON" or "Auto Farm cycle OFF"
            meleeAutoFarmStatus.line = on and "🔁 Farm cycle: ON (waiting tick…)" or "🔁 Farm cycle: OFF"
            pcall(function()
                if autoFarmCycleStatusLbl and autoFarmCycleStatusLbl.Set then
                    autoFarmCycleStatusLbl.Set(meleeAutoFarmStatus.line)
                end
            end)
        end
    )

    MiscTab:Label("Notes — Auto Farm cycle (order of operations)")
    MiscTab:Label(
        "Step 1 — Teleport to saved Ascend TP (below: Set Ascend TP Here). Each full loop begins with this TP.")
    MiscTab:Label(
        "Step 2 — Evaluate upgrade targets: in Ordered Chain mode, Upgrades-tab rows that are ON with a target level are completed top-to-bottom in your custom order. Rows with no target are skipped.")
    MiscTab:Label(
        "Step 3 — Raid + upgrades (only if step 2 needs SP): if Auto Raid shows OFF, the script turns it ON. Auto Upgrade is forced ON until the target chain/queue is satisfied, then Auto Raid is turned OFF if it still shows ON.")
    MiscTab:Label(
        "Step 4 — Farm at the saved TP until kills ≥ (2 + current Ascends) × 1 million (same formula as ⬆️ Auto Ascend).")
    MiscTab:Label(
        "Step 5 — Ascend is not done by the cycle. Leave ⬆️ Auto Ascend ON to call ConfirmAscend when the game allows (NextPortal in current area, server accepts). Or use Ascend Now / the game UI. The cycle detects when Ascends goes up, runs post-ascend TP to the saved spot, then goes back to Step 1.")
    MiscTab:Label(
        "Raid line “X/Y below target”: X = ON rows still under their target; Y = how many ON rows have targets. If Y = 0 you see “targets —”; Ordered Chain skips rows with no target.")
    MiscTab:Label(
        "Tips: use “Show Auto Raid Button” in Misc if OptionsList hides the button. Raid step can run up to ~45 minutes then time out if SP, targets, or queue block progress. If only the cycle is ON at the kill gate, you stay on “waiting for ascend” until you ascend manually or enable Auto Ascend.")

    task.defer(function()
        pcall(function()
            if autoAscendToggle and autoAscendToggle.Set then
                autoAscendToggle.Set(states.autoAscend)
            end
            if autoCycleFarmToggle and autoCycleFarmToggle.Set then
                autoCycleFarmToggle.Set(states.autoCycleFarm)
            end
        end)
    end)

    MiscTab:Label("Post-ascend teleport: stand where you want, tap Set — used by ⬆️ Auto Ascend, Ascend Now, and the farm cycle after it sees Ascends increase.")
    local ascendTpLbl = MiscTab:Label("")
    local function refreshAscendTpLbl()
        ascendTpLbl.Set("Saved TP (+3 studs Y): " .. formatAscendTpSaved())
    end
    refreshAscendTpLbl()

    local ascendAuraKeepToggle = MiscTab:Toggle("✨ Keep aura before Ascend TP", "Waits for AuraRollUI, fires KEEP (ConfirmBtn), then chases saved TP. Off = TP immediately after ascend. Needs firesignal/getconnections or falls back to UI cleanup.", states.ascendAuraKeepBeforeTp, function(on)
        states.ascendAuraKeepBeforeTp = on == true
        saveSettings()
        SLbl.Text = on and "Ascend: keep aura before TP ON" or "Ascend: keep aura before TP OFF"
    end)
    task.defer(function()
        pcall(function()
            if ascendAuraKeepToggle and ascendAuraKeepToggle.Set then
                ascendAuraKeepToggle.Set(states.ascendAuraKeepBeforeTp)
            end
        end)
    end)

    MiscTab:Button("📍", "Set Ascend TP Here", "Saves HumanoidRootPart position as after-ascend teleport target", C.green, function()
        local root = getRoot()
        if not root then SLbl.Text = "⚠ No character"; return end
        local p = root.Position
        states.ascendAfterTpX = p.X
        states.ascendAfterTpY = p.Y
        states.ascendAfterTpZ = p.Z
        saveSettings()
        refreshAscendTpLbl()
        SLbl.Text = "✓ Ascend TP saved — " .. formatAscendTpSaved()
    end)
    MiscTab:Button("↩", "Reset Ascend TP to Default", "Forgotten Valley coords (496.9, 222.1, -7380.4)", C.sub, function()
        states.ascendAfterTpX = DEF_ASCEND_TP_X
        states.ascendAfterTpY = DEF_ASCEND_TP_Y
        states.ascendAfterTpZ = DEF_ASCEND_TP_Z
        saveSettings()
        refreshAscendTpLbl()
        SLbl.Text = "✓ Ascend TP reset to default"
    end)

    MiscTab:Button("⬆️", "Ascend Now", "ConfirmAscend — then TP only if Ascends stat increases", C.gold, function()
        local beforeA = tonumber(getAscends()) or 0
        local ok = invokeR("ConfirmAscend")
        if not ok then
            SLbl.Text = "⚠ Not ready (kill requirement not met)"
            return
        end
        if teleportAfterAscendIfConfirmed(beforeA) then
            SLbl.Text = "✓ Ascended — TP " .. formatAscendTpSaved()
        else
            SLbl.Text = "⚠ Ascends unchanged — no TP (server did not apply ascend?)"
        end
    end)
    MiscTab:Button("🎯", "Check Ascend Status", "Shows (2+Ascends)×1M kill gate vs your kills + next portal", C.accent, function()
        local req = getAscendKillsRequired()
        local have = tonumber(getKills()) or 0
        local more = math.max(0, req - have)
        local dest = nil
        pcall(function()
            local area = invokeR("GetArea")
            if not area then return end
            local np = area:FindFirstChild("NextPortal")
            if not np then return end
            dest = np:GetAttribute("Destination")
        end)
        SLbl.Text = string.format(
            "Ascend: %s / %s kills (%s more) | ascends=%s | next → %s",
            tostring(have), tostring(req), tostring(more), tostring(getAscends()), tostring(dest or "?"))
    end)

    return {
        autoFarmCycleStatusLbl = autoFarmCycleStatusLbl,
        autoAscendToggle = autoAscendToggle,
        autoCycleFarmToggle = autoCycleFarmToggle,
        ascendAuraKeepToggle = ascendAuraKeepToggle,
        refreshAscendTpLbl = refreshAscendTpLbl,
    }
end

-- Misc → Stats labels + KPM thread + Ascend block + Aura (own function — main UI IIFE hits Luau’s ~200 local limit).
local function meleeGuiMountMiscStatsLabelsAscendAura(MiscTab, SLbl, C, guildApGetter, getKillRate, getAscendETA, fmtTime)
    MiscTab:Section("Stats & Kill Rate")
    local StatsLbl = MiscTab:Label("Kills: — | Mana: — | SP: — | Ascends: —")
    local KPMLbl   = MiscTab:Label("KPM: — | ETA ascend: —")
    local ETALbl   = MiscTab:Label("Ascend: — / — kills —")
    local AuraStatLbl = MiscTab:Label("Aura: equipped — | roll UI —")

    local miscAscendGui = meleeGuiMountMiscAscendSection(MiscTab, SLbl, C)
    meleeGuiMountMiscAuraSection(MiscTab, SLbl, C)

    addThread(task.spawn(function()
        while true do
            if GEN ~= _G.MeleeRNG_Gen then break end
            task.wait(1)
            local kpm = getKillRate()
            pcall(function()
                StatsLbl.Set(string.format("Kills: %s | Mana: %s | SP: %s | Ascends: %s",
                    tostring(getKills()), tostring(getMana()), tostring(getSP()), tostring(getAscends())))
                local guildStatusLbl, apStatusLbl = guildApGetter()
                if guildStatusLbl and guildStatusLbl.Set then
                    local g = fetchGuildState()
                    if g then
                        local own = tostring(g.Owner) == tostring(LP.UserId)
                        guildStatusLbl.Set(string.format(
                            "Guild: %s | GP: %s | %s",
                            tostring(g.Name or "?"),
                            tostring(g.GuildPoints or 0),
                            own and "owner" or "member"))
                    else
                        guildStatusLbl.Set("Guild: — (join/create in game)")
                    end
                end
                if apStatusLbl and apStatusLbl.Set then
                    local ap = parseAscendPoints(invokeR("GetAscendPoints"))
                    apStatusLbl.Set(string.format("Ascend Points: %s (castle statue upgrades)", tostring(ap)))
                end
                local dest, killsNeeded, req = getAscendETA()
                if req then
                    local etaSecs = (kpm>0 and killsNeeded>0) and (killsNeeded/kpm*60) or nil
                    local etaStr  = etaSecs and fmtTime(etaSecs) or (killsNeeded==0 and "READY" or "—")
                    local destStr = dest and tostring(dest) or "?"
                    KPMLbl.Set(string.format("KPM: %.1f | ETA ascend → %s: %s", kpm, destStr, etaStr))
                    ETALbl.Set(string.format("Ascend: %s / %s kills (%s more) → %s",
                        tostring(getKills()), tostring(req), tostring(killsNeeded), destStr))
                else
                    KPMLbl.Set(string.format("KPM: %.1f | Ascend: —", kpm))
                    ETALbl.Set("Ascend: —")
                end
                local eqA = getEquippedAuraName()
                local rollA = getRolledAuraNameFromRollUi()
                AuraStatLbl.Set(string.format(
                    "Aura: equipped %s | roll UI %s | preferred %s",
                    eqA or "—",
                    rollA or "—",
                    (states.auraPreferredName ~= "" and states.auraPreferredName) or "—"))
                local fc = miscAscendGui and miscAscendGui.autoFarmCycleStatusLbl
                if fc and fc.Set then
                    if states.autoCycleFarm then
                        fc.Set(meleeAutoFarmStatus.line)
                    else
                        fc.Set("🔁 Farm cycle: OFF")
                    end
                end
            end)
        end
    end))

    return miscAscendGui
end

-- Guild / AP tab UI in separate functions (Luau: `do` does not reduce locals; only nested functions do).
local function meleeGuiMountGuildTab(GuildTab, SLbl, C)
    GuildTab:Section("Status")
    local guildStatusLbl = GuildTab:Label("Guild: — (join/create in game)")
    GuildTab:Label("Remotes: BuyGP(spAmount) · BuyGuildBuff(guildId, buff). Buffs match GuildConstants.")

    GuildTab:Section("SP → GP")
    local guildSpToGpToggle = GuildTab:Toggle("💠 Auto SP → GP", "In a guild as member: calls BuyGP with (SP − reserve) ~2/s. Same as Add GP page SP box — saved.", states.autoGuildSpToGp, function(on)
        states.autoGuildSpToGp = on == true
        saveSettings()
        SLbl.Text = on and "Guild: Auto SP→GP ON" or "Guild: Auto SP→GP OFF"
    end)
    GuildTab:Slider("Reserve SP", "Never spend below this much SP when Auto SP→GP runs (saved)", {
        min = 0, max = 100000000, default = math.clamp(states.guildSpReserve, 0, 100000000),
        format = function(v) return string.format("keep %s SP", tostring(math.floor(v))) end,
    }, function(v)
        states.guildSpReserve = math.clamp(math.floor(v), 0, 100000000)
        saveSettings()
    end)
    GuildTab:Button("➕", "SP → GP once", "BuyGP(current SP minus reserve) one shot", C.accent, function()
        if not R("BuyGP") then SLbl.Text = "⚠ BuyGP remote missing"; return end
        local g = fetchGuildState()
        if not g or not guildPlayerIsMember(g) then SLbl.Text = "⚠ Not in a guild"; return end
        local sp = tonumber(getSP()) or 0
        local reserve = math.max(0, math.floor(tonumber(states.guildSpReserve) or 0))
        local spend = math.floor(sp - reserve)
        if spend <= 0 then SLbl.Text = "⚠ No SP to spend (check reserve)"; return end
        invokeR("BuyGP", spend)
        _cachedStats["SP"] = nil
        SLbl.Text = "✓ BuyGP(" .. tostring(spend) .. " SP)"
    end)

    GuildTab:Section("Buff upgrades")
    local guildBuffAutoToggle = GuildTab:Toggle("⚔️ Auto guild buff upgrades", "Guild owner only. Each tick buys the cheapest affordable buff among the toggles below — saved.", states.autoGuildBuffs, function(on)
        states.autoGuildBuffs = on == true
        saveSettings()
        SLbl.Text = on and "Guild: Auto buffs ON" or "Guild: Auto buffs OFF"
    end)
    GuildTab:Label("Buff targets (ON = included; auto picks cheapest):")
    local guildBuffToggles = {}
    for _, gn in ipairs(GUILD_BUFF_ORDER) do
        guildBuffToggles[gn] = GuildTab:Toggle(gn, "Allow auto guild upgrade to buy this buff — saved", guildBuffSelected[gn] == true, function(on)
            guildBuffSelected[gn] = (on == true)
            saveSettings()
        end)
    end
    GuildTab:Button("✅", "Buffs: all / none", "Flip every guild buff target on or off at once — saved", C.green, function()
        local anyOff = false
        for _, n in ipairs(GUILD_BUFF_ORDER) do
            if not guildBuffSelected[n] then anyOff = true; break end
        end
        local turnOn = anyOff
        for _, n in ipairs(GUILD_BUFF_ORDER) do
            guildBuffSelected[n] = turnOn
            local tr = guildBuffToggles[n]
            if tr and tr.Set then pcall(function() tr.Set(turnOn) end) end
        end
        saveSettings()
        SLbl.Text = turnOn and "Guild buffs: all ON" or "Guild buffs: all OFF"
    end)

    task.defer(function()
        pcall(function()
            if guildSpToGpToggle and guildSpToGpToggle.Set then guildSpToGpToggle.Set(states.autoGuildSpToGp) end
            if guildBuffAutoToggle and guildBuffAutoToggle.Set then guildBuffAutoToggle.Set(states.autoGuildBuffs) end
            for _, gn in ipairs(GUILD_BUFF_ORDER) do
                local tr = guildBuffToggles[gn]
                if tr and tr.Set then tr.Set(guildBuffSelected[gn] == true) end
            end
        end)
    end)

    return {
        guildStatusLbl = guildStatusLbl,
        guildSpToGpToggle = guildSpToGpToggle,
        guildBuffAutoToggle = guildBuffAutoToggle,
        guildBuffToggles = guildBuffToggles,
    }
end

local function meleeGuiMountApTab(ApTab, SLbl, C)
    ApTab:Section("Ascend Points upgrades")
    local apStatusLbl = ApTab:Label("Ascend Points: —")
    ApTab:Label("SharedConstants.AscendUpgrades · Remotes: GetAscendPoints, GetAscendUpgrades, UpgradeAscend(name). Max L10.")
    local apAutoToggle = ApTab:Toggle("⚡ Auto AP upgrades", "Buys the cheapest affordable upgrade among toggled rows (~1.2s). Saved.", states.autoApUpgrades, function(on)
        states.autoApUpgrades = on == true
        saveSettings()
        SLbl.Text = on and "Ascend AP: auto ON" or "Ascend AP: auto OFF"
    end)
    ApTab:Label("Include in auto (cheapest among ON):")
    local apUpgradeToggles = {}
    for _, an in ipairs(ASCEND_AP_ORDER) do
        apUpgradeToggles[an] = ApTab:Toggle(an, "Allow auto to purchase this AP statue upgrade — saved", apUpgradeSelected[an] == true, function(on)
            apUpgradeSelected[an] = (on == true)
            saveSettings()
        end)
    end
    ApTab:Button("✅", "AP upgrades: all / none", "Flip every AP upgrade toggle — saved", C.green, function()
        local anyOff = false
        for _, n in ipairs(ASCEND_AP_ORDER) do
            if not apUpgradeSelected[n] then anyOff = true; break end
        end
        local turnOn = anyOff
        for _, n in ipairs(ASCEND_AP_ORDER) do
            apUpgradeSelected[n] = turnOn
            local tr = apUpgradeToggles[n]
            if tr and tr.Set then pcall(function() tr.Set(turnOn) end) end
        end
        saveSettings()
        SLbl.Text = turnOn and "AP upgrades: all ON" or "AP upgrades: all OFF"
    end)
    ApTab:Button("⬆️", "Upgrade once (cheapest)", "Single UpgradeAscend for cheapest affordable row that is toggled ON", C.accent, function()
        if not R("UpgradeAscend") then SLbl.Text = "⚠ UpgradeAscend missing"; return end
        local levels = invokeR("GetAscendUpgrades")
        if type(levels) ~= "table" then SLbl.Text = "⚠ GetAscendUpgrades failed"; return end
        local ap = parseAscendPoints(invokeR("GetAscendPoints"))
        local rows = {}
        for _, name in ipairs(ASCEND_AP_ORDER) do
            if apUpgradeSelected[name] ~= true then continue end
            local lvl = tonumber(levels[name]) or 0
            if lvl >= ASCEND_AP_MAX_LEVEL then continue end
            local cost = ascendApNextCost(name, lvl)
            if type(cost) == "number" and cost == cost and cost > 0 and cost < math.huge then
                rows[#rows + 1] = { name = name, cost = cost }
            end
        end
        table.sort(rows, function(a, b) return a.cost < b.cost end)
        for _, row in ipairs(rows) do
            if ap < row.cost then SLbl.Text = string.format("⚠ Need %d AP for %s", row.cost, row.name); return end
            local ok, newLevel = invokeR2("UpgradeAscend", row.name)
            if ok and type(newLevel) == "number" then
                SLbl.Text = "✓ " .. row.name .. " → L" .. tostring(newLevel)
                return
            end
        end
        SLbl.Text = "⚠ No upgrade bought (maxed or server rejected)"
    end)
    task.defer(function()
        pcall(function()
            if apAutoToggle and apAutoToggle.Set then apAutoToggle.Set(states.autoApUpgrades) end
            for _, an in ipairs(ASCEND_AP_ORDER) do
                local tr = apUpgradeToggles[an]
                if tr and tr.Set then tr.Set(apUpgradeSelected[an] == true) end
            end
        end)
    end)
    return {
        apStatusLbl = apStatusLbl,
        apAutoToggle = apAutoToggle,
        apUpgradeToggles = apUpgradeToggles,
    }
end

-- KPM / ETA helpers in their own closure (main UI IIFE was exceeding Luau’s ~200 local registers on fmtTime).
local function meleeKillRateModule()
    local _killHistory  = {}
    local _KILL_WINDOW  = 60
    local _lastKillCount = 0

    local function recordKills()
        local now   = os.clock()
        local kills = getKills()
        if kills ~= _lastKillCount then
            _lastKillCount = kills
            _killHistory[#_killHistory+1] = {t=now, k=kills}
        end
        local cutoff = now - _KILL_WINDOW
        local i = 1
        while i <= #_killHistory and _killHistory[i].t < cutoff do i = i+1 end
        if i > 1 then
            for j = 1, #_killHistory-i+1 do _killHistory[j] = _killHistory[j+i-1] end
            for j = #_killHistory-i+2, #_killHistory do _killHistory[j] = nil end
        end
    end

    local function getKillRate()
        if #_killHistory < 2 then return 0 end
        local oldest = _killHistory[1]; local newest = _killHistory[#_killHistory]
        local dt = newest.t - oldest.t
        if dt < 1 then return 0 end
        return (newest.k - oldest.k) / dt * 60
    end

    local function fmtTime(secs)
        if secs <= 0 or secs ~= secs then return "—" end
        if secs > 86400*30 then return ">30 days" end
        local d=math.floor(secs/86400); local h=math.floor((secs%86400)/3600)
        local m=math.floor((secs%3600)/60); local s=math.floor(secs%60)
        if d>0 then return string.format("%dd %dh %dm",d,h,m) end
        if h>0 then return string.format("%dh %dm %ds",h,m,s) end
        if m>0 then return string.format("%dm %ds",m,s) end
        return string.format("%ds",s)
    end

    local function getAscendETA()
        local req = getAscendKillsRequired()
        local killsNeeded = math.max(0, req - (tonumber(getKills()) or 0))
        local dest
        pcall(function()
            local area = invokeR("GetArea"); if not area then return end
            local np = area:FindFirstChild("NextPortal"); if not np then return end
            dest = np:GetAttribute("Destination")
        end)
        return dest, killsNeeded, req
    end

    return {
        recordKills = recordKills,
        getKillRate = getKillRate,
        fmtTime = fmtTime,
        getAscendETA = getAscendETA,
    }
end

local KR = meleeKillRateModule()

addThread(task.spawn(function()
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        KR.recordKills()
        task.wait(0.5)
    end
end))

-- Noclip / GodMode / Fly / FullBright / WalkSpeed / ESP / CharacterAdded — own scope (Luau ~200 local cap).
local function meleeInitMovementEspCharAdded()
    local noclipParts, noclipConns = {}, {}
    local function clearNoclipConns()
        for _, c in ipairs(noclipConns) do pcall(function() c:Disconnect() end) end
        noclipConns = {}
    end
    local function rebuildNoclipParts(char)
        table.clear(noclipParts); clearNoclipConns()
        if not char then return end
        for _, d in ipairs(char:GetDescendants()) do
            if d:IsA("BasePart") then noclipParts[#noclipParts+1] = d end
        end
        noclipConns[#noclipConns+1] = char.DescendantAdded:Connect(function(d)
            if d:IsA("BasePart") then noclipParts[#noclipParts+1] = d end
        end)
    end
    rebuildNoclipParts(getChar())

    local _lastNoclipPrune = 0
    addConn(RunService.Stepped:Connect(function()
        if GEN ~= _G.MeleeRNG_Gen then return end
        if not states.noclip then return end
        local now = os.clock()
        if now - _lastNoclipPrune > 5 then
            _lastNoclipPrune = now
            for i=#noclipParts,1,-1 do
                if not (noclipParts[i] and noclipParts[i].Parent) then
                    table.remove(noclipParts, i)
                end
            end
        end
        for _, p in ipairs(noclipParts) do
            if p and p.Parent then p.CanCollide = false end
        end
    end))

    local _lastGod = 0
    addConn(RunService.Heartbeat:Connect(function()
        if GEN ~= _G.MeleeRNG_Gen then return end
        if not states.godMode then return end
        local now = os.clock(); if now - _lastGod < 0.5 then return end
        _lastGod = now
        local h = getHuman()
        if h then
            if h.MaxHealth ~= math.huge then h.MaxHealth = math.huge end
            if h.Health    ~= math.huge then h.Health    = math.huge end
        end
    end))

    addConn(RunService.Heartbeat:Connect(function()
        if GEN ~= _G.MeleeRNG_Gen then return end
        if states.fly then
            local root = getRoot(); if not root then return end
            if not flyBV then
                flyBV = Instance.new("BodyVelocity", root)
                flyBV.MaxForce = Vector3.new(1e5,1e5,1e5); flyBV.Velocity = Vector3.zero
            end
            if not flyBG then
                flyBG = Instance.new("BodyGyro", root)
                flyBG.MaxTorque = Vector3.new(1e5,1e5,1e5); flyBG.D = 100
            end
            local cam = workspace.CurrentCamera; local spd = 60; local mv = Vector3.zero
            if UserInputService:IsKeyDown(Enum.KeyCode.W) then mv = mv + cam.CFrame.LookVector  end
            if UserInputService:IsKeyDown(Enum.KeyCode.S) then mv = mv - cam.CFrame.LookVector  end
            if UserInputService:IsKeyDown(Enum.KeyCode.A) then mv = mv - cam.CFrame.RightVector end
            if UserInputService:IsKeyDown(Enum.KeyCode.D) then mv = mv + cam.CFrame.RightVector end
            if UserInputService:IsKeyDown(Enum.KeyCode.E) then mv = mv + Vector3.new(0,1,0) end
            if UserInputService:IsKeyDown(Enum.KeyCode.Q) then mv = mv - Vector3.new(0,1,0) end
            if mv.Magnitude > 0 then mv = mv.Unit end
            flyBV.Velocity = mv * spd; flyBG.CFrame = cam.CFrame
            local h = getHuman(); if h then h:ChangeState(Enum.HumanoidStateType.Physics) end
        else
            if flyBV then flyBV:Destroy(); flyBV = nil end
            if flyBG then flyBG:Destroy(); flyBG = nil end
        end
    end))

    local _fb = {
        applied = false,
        orig = {
            Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
            Brightness = Lighting.Brightness, FogEnd = Lighting.FogEnd, FogStart = Lighting.FogStart,
        }
    }
    addConn(RunService.Heartbeat:Connect(function()
        if GEN ~= _G.MeleeRNG_Gen then return end
        if states.fullBright then
            if _fb.applied then return end; _fb.applied = true
            Lighting.Ambient = Color3.fromRGB(255,255,255)
            Lighting.OutdoorAmbient = Color3.fromRGB(255,255,255)
            Lighting.Brightness = 10; Lighting.FogEnd = 1e6; Lighting.FogStart = 1e6
        elseif _fb.applied then
            _fb.applied = false
            Lighting.Ambient = _fb.orig.Ambient; Lighting.OutdoorAmbient = _fb.orig.OutdoorAmbient
            Lighting.Brightness = _fb.orig.Brightness
            Lighting.FogEnd = _fb.orig.FogEnd; Lighting.FogStart = _fb.orig.FogStart
        end
    end))

    local _speedConn = nil
    local function enforceSpeed()
        local h = getHuman(); if not h then return end
        h.WalkSpeed = walkSpeedVal
        if _speedConn then _speedConn:Disconnect() end
        _speedConn = h:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
            if GEN ~= _G.MeleeRNG_Gen then if _speedConn then _speedConn:Disconnect() end return end
            if h.WalkSpeed ~= walkSpeedVal then h.WalkSpeed = walkSpeedVal end
        end)
        addConn(_speedConn)
    end
    do local h = getHuman(); if h then h.WalkSpeed = walkSpeedVal end end
    enforceSpeed()

    local function makeBillboard(parent, text, color, yOff)
        local bb = Instance.new("BillboardGui", parent)
        bb.Size = UDim2.new(0,120,0,24); bb.StudsOffset = Vector3.new(0, yOff or 3, 0)
        bb.AlwaysOnTop = true; bb.MaxDistance = 200
        local lbl = Instance.new("TextLabel", bb)
        lbl.Size = UDim2.new(1,0,1,0); lbl.BackgroundTransparency = 1
        lbl.Text = text; lbl.TextColor3 = color or Color3.fromRGB(255,70,70)
        lbl.Font = Enum.Font.GothamBold; lbl.TextSize = 11; lbl.TextStrokeTransparency = 0.2
        return bb
    end

    addThread(task.spawn(function()
        while true do
            if GEN ~= _G.MeleeRNG_Gen then break end
            task.wait(0.6)
            if states.espMobs then
                local mobs = workspace:FindFirstChild("Mobs")
                if mobs then
                    for model, bb in pairs(espBillboards) do
                        if not isMobAlive(model) then
                            bb:Destroy(); espBillboards[model] = nil
                        end
                    end
                    for _, model in pairs(mobs:GetChildren()) do
                        if model:IsA("Model") and isMobAlive(model) and not espBillboards[model] then
                            local anchor = model:FindFirstChild("Head")
                                        or model:FindFirstChild("UpperTorso")
                                        or model:FindFirstChild("HumanoidRootPart")
                            if anchor then
                                local isBoss  = model:GetAttribute("Boss") == true
                                local isMega  = model:GetAttribute("MegaBoss") == true
                                local col     = isMega and Color3.fromRGB(255,70,70) or isBoss and Color3.fromRGB(255,210,50) or Color3.fromRGB(255,160,30)
                                local tag     = isMega and " [MEGA]" or isBoss and " [BOSS]" or ""
                                local label   = model.Name .. tag
                                local bb = makeBillboard(anchor, label, col, 2.5)
                                espBillboards[model] = bb
                            end
                        end
                    end
                end
            elseif next(espBillboards) then
                for _, bb in pairs(espBillboards) do pcall(function() bb:Destroy() end) end
                espBillboards = {}
            end
        end
    end))

    addConn(LP.CharacterAdded:Connect(function(c)
        if GEN ~= _G.MeleeRNG_Gen then return end
        task.wait(0.5)
        rebuildNoclipParts(c)
        local h = c:WaitForChild("Humanoid", 5)
        if h then h.WalkSpeed = walkSpeedVal end
        if flyBV then flyBV:Destroy(); flyBV = nil end
        if flyBG then flyBG:Destroy(); flyBG = nil end
        enforceSpeed()
        _hitboxCacheDirty = true
        task.defer(function()
            task.wait(1)
            if GEN ~= _G.MeleeRNG_Gen then return end
            maintainPreferredAuraSelection(true)
        end)
    end))

    return _fb
end

-- Anti-AFK in its own scope (keeps main UI IIFE under Luau's ~200-local register cap).
local function meleeInitAntiAfk()
    -- Kill the game's AFK LocalScript (no getrawmetatable / newcclosure). Stops its RenderStepped / TP kick path.
    local function disableGameAfkScript()
        pcall(function()
            local ps = LP:FindFirstChild("PlayerScripts")
            if not ps then return end
            local s = ps:FindFirstChild("AFKScript")
            if s and s:IsA("LocalScript") then
                s.Disabled = true
            end
        end)
    end

    -- Optional backup: game AFK sometimes keys off InputBegan; VIM click path + VirtualUser fallback.
    -- VirtualUser:ClickButton2 is camera-side and skips that path.
    local function sendAntiAfkInput()
        local vx, vy = 1, 1
        local cam = workspace.CurrentCamera
        if cam then
            local vs = cam.ViewportSize
            vx = math.max(0, math.floor(vs.X * 0.5))
            vy = math.max(0, math.floor(vs.Y * 0.5))
        end
        local okVim = pcall(function()
            local vim = game:GetService("VirtualInputManager")
            vim:SendMouseButtonEvent(vx, vy, 0, true)  -- 0 = left, down
            task.wait()
            vim:SendMouseButtonEvent(vx, vy, 0, false)
        end)
        if okVim then return end
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton1(Vector2.new(vx, vy))
        end)
    end

    addThread(task.spawn(function()
        local ps = LP:WaitForChild("PlayerScripts", 45)
        if GEN ~= _G.MeleeRNG_Gen or not ps then return end
        disableGameAfkScript()
        addConn(ps.ChildAdded:Connect(function(child)
            if GEN ~= _G.MeleeRNG_Gen then return end
            if child.Name == "AFKScript" and child:IsA("LocalScript") then
                child.Disabled = true
            end
        end))
        while GEN == _G.MeleeRNG_Gen do
            task.wait(8)
            disableGameAfkScript()
        end
    end))

    addThread(task.spawn(function()
        while true do
            if GEN ~= _G.MeleeRNG_Gen then break end
            task.wait(60)
            if states.antiAfk then
                sendAntiAfkInput()
            end
        end
    end))
end

-- Luau ~200 locals: window UI + return SLbl live in this IIFE; heavy Misc blocks use meleeGuiMountMisc* helpers (Stats+Ascend+Aura is its own function); re-exec init stays outside below.
local SLbl = (function()
-- --------------------------------------------------------------------------
-- UI — Build window (tabs: Move → ESP → Areas → Upgrades → Sacrifice → Misc)
-- --------------------------------------------------------------------------
local Win  = Lib:Window({ title = "⚔️  Melee RNG  v1.1.2 Local PNG UI" })
local SLbl = Win._status

-- Shared palette / status cards (used by every tab)
local C = {
    bg=Color3.fromRGB(7,9,14), card=Color3.fromRGB(12,15,22),
    border=Color3.fromRGB(35,48,64), accent=Color3.fromRGB(65,210,190),
    accentD=Color3.fromRGB(25,130,145), text=Color3.fromRGB(232,238,244),
    sub=Color3.fromRGB(112,130,148), green=Color3.fromRGB(56,205,122),
    purple=Color3.fromRGB(170,120,255), red=Color3.fromRGB(255,86,94),
    orange=Color3.fromRGB(255,174,72), gold=Color3.fromRGB(255,220,92),
}
local function makeStatusCard(page, lo, titleStr, accentCol)
    accentCol = accentCol or C.accent
    local Card = Instance.new("Frame", page)
    Card.Size = UDim2.new(1,-10,0,88)
    Card.BackgroundColor3 = C.card; Card.BorderSizePixel = 0; Card.LayoutOrder = lo
    Instance.new("UICorner", Card).CornerRadius = UDim.new(0,10)
    local stroke = Instance.new("UIStroke", Card); stroke.Color = C.border; stroke.Thickness = 1

    local function lbl(txt, xOff, yOff, h, col, font, size)
        local L = Instance.new("TextLabel", Card)
        L.Text = txt; L.Size = UDim2.new(1,-110,0,h)
        L.Position = UDim2.new(0, xOff or 14, 0, yOff or 8)
        L.BackgroundTransparency = 1; L.TextColor3 = col or C.text
        L.Font = font or Enum.Font.GothamBold; L.TextSize = size or 12
        L.TextXAlignment = Enum.TextXAlignment.Left
        return L
    end
    local Title  = lbl(titleStr, 14, 8,  18, C.text, Enum.Font.GothamBold, 13)
    local Status = lbl("OFF · Idle", 14, 28, 13, C.sub,  Enum.Font.Code, 9)
    local Info1  = lbl("",          14, 44, 12, C.sub,  Enum.Font.Code, 9)
    local Info2  = lbl("",          14, 58, 12, accentCol, Enum.Font.Code, 9)

    local Pill = Instance.new("Frame", Card)
    Pill.Size = UDim2.new(0,44,0,24); Pill.Position = UDim2.new(1,-50,0.5,-12)
    Pill.BackgroundColor3 = C.border; Pill.BorderSizePixel = 0
    Instance.new("UICorner", Pill).CornerRadius = UDim.new(1,0)
    local Thumb = Instance.new("Frame", Pill)
    Thumb.Size = UDim2.new(0,18,0,18); Thumb.Position = UDim2.new(0,3,0.5,-9)
    Thumb.BackgroundColor3 = C.sub; Thumb.BorderSizePixel = 0
    Instance.new("UICorner", Thumb).CornerRadius = UDim.new(1,0)
    local PBtn = Instance.new("TextButton", Pill)
    PBtn.Size = UDim2.new(1,0,1,0); PBtn.BackgroundTransparency = 1
    PBtn.Text = ""; PBtn.ZIndex = 3

    local ti = TweenInfo.new(0.18, Enum.EasingStyle.Quad)
    local function setState(on)
        if on then
            TweenService:Create(Pill,  ti, {BackgroundColor3 = accentCol}):Play()
            TweenService:Create(Thumb, ti, {Position = UDim2.new(0,23,0.5,-9), BackgroundColor3 = accentCol}):Play()
            stroke.Color = accentCol; Title.TextColor3 = accentCol
        else
            TweenService:Create(Pill,  ti, {BackgroundColor3 = C.border}):Play()
            TweenService:Create(Thumb, ti, {Position = UDim2.new(0,3,0.5,-9), BackgroundColor3 = C.sub}):Play()
            stroke.Color = C.border; Title.TextColor3 = C.text
            Status.Text = "OFF · Idle"
        end
    end
    return { Card=Card, Title=Title, Status=Status, Info1=Info1, Info2=Info2,
             Pill=Pill, PBtn=PBtn, stroke=stroke, setState=setState }
end

-- Tabs: Move → ESP → Areas → Upgrades → Sacrifice → Guild → Ascend AP → (later) Misc
local MoveTab = Win:Tab("🚀",  "Move")
local ESPTab  = Win:Tab("👁️",  "ESP")
local AreaTab = Win:Tab("🗺️",  "Areas")
local UpgTab  = Win:Tab("⬆️",  "Upgrades")
local SacTab  = Win:Tab("🕯️", "Sacrifice")
local GuildTab = Win:Tab("🏰", "Guild")
local ApTab    = Win:Tab("🔱", "Ascend AP")
local guildStatusLbl -- assigned via meleeGuiMountGuildTab; refreshed in Misc → Stats loop
local apStatusLbl
local guildSpToGpToggle, guildBuffAutoToggle, guildBuffToggles
local apAutoToggle, apUpgradeToggles
local manaToSpToggle

-- Auto upgrade: SP, GetUnlockedUpgrades / GetUpgradeLevel / BuyUpgrade (prices = SharedConstants client copy)

-- Price functions — exact copies from SharedConstants.Upgrades (dump lines 3601-3690)
local UPGRADE_PRICES = {
    ["Weapons Equipped"]       = function(p) return 1 + p^2 * p end,
    ["Damage Multiplier"]      = function(p) return p^4 + 5 end,
    ["Enemy Spawn Rate"]       = function(p) return math.floor(p^1.5 + 10) end,
    ["Enemy Limit"]            = function(p) return math.round(p^1.1 + 1) end,
    ["Mana Multiplier"]        = function(p) return math.round(8 + p^2.35 * p) end,
    ["Spin Speed"]             = function(p) return p^4 + 5 end,
    ["RNG Luck"]               = function(p) return p^4 + 5 end,
    ["Kill Multiplier"]        = function(p) return math.round(p^3.9 + 100) end,
    ["Skill Point Multiplier"] = function(p) return math.round(p^4.5) + 1 end,
    ["Boss Spawn Chance"]      = function(p) return math.round(p^4) + 150 end,
}

local UPGRADE_DESCRIPTIONS = {
    ["Weapons Equipped"]       = "More weapons can be equipped/used at the same time.",
    ["Damage Multiplier"]      = "Raises your damage per hit, which helps kill stronger mobs faster.",
    ["Enemy Spawn Rate"]       = "Makes enemies spawn faster so the farm has more targets.",
    ["Enemy Limit"]            = "Allows more enemies to exist at once; useful for large hitboxes/farming.",
    ["Mana Multiplier"]        = "Increases mana gained from normal gameplay.",
    ["Spin Speed"]             = "Speeds up the game’s spin/roll timing for weapons.",
    ["RNG Luck"]               = "Improves luck-related rolls.",
    ["Kill Multiplier"]        = "Increases kill-stat gain per kill.",
    ["Skill Point Multiplier"] = "Increases SP gain, making later upgrades easier to afford.",
    ["Boss Spawn Chance"]      = "Raises the chance that bosses spawn.",
}

-- Server SP cost if the game exposes it (more accurate than SharedConstants clone). Cleared after a buy.
local _upgPriceCache = {}
local UPG_PRICE_CACHE_TTL = 2.5
local UPG_PRICE_REMOTE_NAMES = {
    "GetUpgradePrice", "GetNextUpgradePrice", "GetUpgradeCost", "CalculateUpgradePrice",
}

local function upgInvalidatePriceCache()
    _upgPriceCache = {}
end

-- GetUpgradeLevel sometimes returns a table/wrapped value; raw table breaks p^4 math → no price → row dropped from queue.
local function upgCoerceLevel(raw)
    if raw == nil or raw == false then return 0 end
    if type(raw) == "number" then
        if raw ~= raw or raw < 0 then return 0 end
        return math.min(math.floor(raw), 1e9)
    end
    if type(raw) == "string" then
        local n = tonumber(raw)
        return n and upgCoerceLevel(n) or 0
    end
    if type(raw) == "table" then
        local n = tonumber(raw[1])
            or tonumber(raw.Level) or tonumber(raw.level)
            or tonumber(raw.L) or tonumber(raw.Lvl) or tonumber(raw.Value) or tonumber(raw.value)
        return n and upgCoerceLevel(n) or 0
    end
    return 0
end

local function upgReadUpgradeLevel(name)
    local raw = nil
    pcall(function() raw = invokeR("GetUpgradeLevel", name) end)
    return upgCoerceLevel(raw)
end

local function upgCoercePrice(raw)
    if type(raw) == "number" and raw == raw and raw > 0 and raw < 1e18 then return raw end
    if type(raw) == "string" then
        local n = tonumber(raw)
        if n then return upgCoercePrice(n) end
    end
    if type(raw) == "table" then
        local n = tonumber(raw[1])
            or tonumber(raw.Price) or tonumber(raw.price)
            or tonumber(raw.Cost) or tonumber(raw.cost)
            or tonumber(raw.SP) or tonumber(raw.sp)
        if n then return upgCoercePrice(n) end
    end
    return nil
end

-- Prefer (name, level) first — many handlers ignore `name` when level is omitted and return a wrong/default cost.
local function upgTryRemotePrice(name, lvl)
    local li = math.floor(tonumber(lvl) or 0)
    if li < 0 then li = 0 end
    for _, rn in ipairs(UPG_PRICE_REMOTE_NAMES) do
        local v = nil
        pcall(function() v = invokeR(rn, name, li) end)
        local p = upgCoercePrice(v)
        if p then return p end
        pcall(function() v = invokeR(rn, name) end)
        p = upgCoercePrice(v)
        if p then return p end
    end
    return nil
end

--- Next-tier SP: cached remote (if any), else formula with pcall (lvl+1, then lvl fallback).
local function upgGetNextPrice(name, lvl)
    local now = os.clock()
    local ck = name .. "#" .. tostring(lvl)
    local ent = _upgPriceCache[ck]
    if ent and (now - ent.t) < UPG_PRICE_CACHE_TTL then return ent.p end
    local rp = upgTryRemotePrice(name, lvl)
    if rp then
        _upgPriceCache[ck] = { t = now, p = rp }
        return rp
    end
    local priceFn = UPGRADE_PRICES[name]
    if not priceFn then return nil end
    local price = nil
    local ok, p1 = pcall(priceFn, lvl + 1)
    if ok and type(p1) == "number" and p1 == p1 and p1 > 0 and p1 < math.huge then price = p1 end
    if not price then
        local ok2, p2 = pcall(priceFn, lvl)
        if ok2 and type(p2) == "number" and p2 == p2 and p2 > 0 and p2 < math.huge then price = p2 end
    end
    if price then _upgPriceCache[ck] = { t = now, p = price } end
    return price
end

local function upgGetTarget(name)
    local capN = upgradeLevelCap[name]
    if type(capN) == "number" and capN >= 1 then
        return math.floor(capN)
    end
    return nil
end

local function upgCountTargetRows()
    local n = 0
    for _, name in ipairs(UPGRADE_ORDER) do
        if upgradeSelected[name] == true and upgGetTarget(name) ~= nil then
            n = n + 1
        end
    end
    return n
end

--- Legacy behavior: every ON row is eligible; sorted by next SP cost (cheapest first).
-- Empty target = no stop in this mode. Target set = stop once current level reaches target.
local function upgBuildCheapestCandidates()
    local list = {}
    for _, name in ipairs(UPGRADE_ORDER) do
        if upgradeSelected[name] == true then
            local lvl = upgReadUpgradeLevel(name)
            local capN = upgGetTarget(name)
            if capN and lvl >= capN then continue end
            local price = upgGetNextPrice(name, lvl)
            if type(price) == "number" and price == price and price < math.huge then
                list[#list + 1] = { name = name, price = price, lvl = lvl, target = capN, mode = "cheapest" }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.price ~= b.price then return a.price < b.price end
        return a.name < b.name
    end)
    return list
end

--- Ordered Chain behavior: use UI order, buy only the first ON row that is below its target.
-- Rows with no target are intentionally skipped so the script can move through a clean level plan.
local function upgBuildSequentialCandidates()
    local targetTotal = upgCountTargetRows()
    local targetIndex = 0
    for _, name in ipairs(UPGRADE_ORDER) do
        if upgradeSelected[name] == true and upgGetTarget(name) ~= nil then
            targetIndex = targetIndex + 1
            local lvl = upgReadUpgradeLevel(name)
            local capN = upgGetTarget(name)
            if lvl < capN then
                local price = upgGetNextPrice(name, lvl)
                if not (type(price) == "number" and price == price and price > 0 and price < math.huge) then
                    price = math.huge
                end
                return { { name = name, price = price, lvl = lvl, target = capN, mode = "chain", targetIndex = targetIndex, targetTotal = targetTotal } }
            end
        end
    end
    return {}
end

--- Main auto-buy queue. Ordered Chain is locked ON: one active target at a time, top-to-bottom.
local function upgBuildSortedCandidates()
    return upgBuildSequentialCandidates()
end

local function upgFormatTargetChain()
    local parts = {}
    local skippedNoTarget = 0
    local markedCurrent = false
    for _, name in ipairs(UPGRADE_ORDER) do
        if upgradeSelected[name] ~= true then continue end
        local lvl = upgReadUpgradeLevel(name)
        local capN = upgGetTarget(name)
        if capN then
            local prefix = ""
            if not markedCurrent and lvl < capN then
                prefix = "→ "
                markedCurrent = true
            elseif lvl >= capN then
                prefix = "✓ "
            end
            parts[#parts + 1] = string.format("%s%s L%d/%d", prefix, name, lvl, capN)
        else
            skippedNoTarget = skippedNoTarget + 1
        end
    end
    if #parts == 0 then
        if skippedNoTarget > 0 then return "set target levels for ON rows" end
        return "—"
    end
    if skippedNoTarget > 0 then
        parts[#parts + 1] = string.format("%d ON row(s) skipped: no target", skippedNoTarget)
    end
    return table.concat(parts, " · ")
end

--- Status summary: Ordered Chain shows the level plan.
local function upgFormatAllToggled(candidates)
    if states.upgradeSequentialMode then
        return upgFormatTargetChain()
    end
    local priceByName = {}
    for _, r in ipairs(candidates) do
        priceByName[r.name] = r.price
    end
    local parts = {}
    for _, name in ipairs(UPGRADE_ORDER) do
        if upgradeSelected[name] ~= true then continue end
        local p = priceByName[name]
        if type(p) == "number" and p == p and p < math.huge then
            parts[#parts + 1] = string.format("%s:%.0f", name, p)
        else
            local lvl = upgReadUpgradeLevel(name)
            local capN = upgGetTarget(name)
            if capN and lvl >= capN then
                parts[#parts + 1] = string.format("%s:target L%d", name, lvl)
            else
                parts[#parts + 1] = name .. ":?"
            end
        end
    end
    if #parts == 0 then return "—" end
    return table.concat(parts, " · ")
end

local function upgCountSelectedToggles()
    local n = 0
    for _, name in ipairs(UPGRADE_ORDER) do
        if upgradeSelected[name] == true then n = n + 1 end
    end
    return n
end

local function upgFormatSp(sp)
    local n = tonumber(sp)
    if not n then return tostring(sp) end
    return tostring(math.floor(n + 1e-6))
end

local upgStatusLbl  = UpgTab:Label("Status: OFF")
local upgInfoLbl    = UpgTab:Label("SP: — | Next: —")

local function upgModeName()
    return "Ordered Chain"
end

local function setAutoUpgrade(on)
    states.autoUpgradeOn = on == true
    upgStatusLbl.Set(on and ("Status: ON — " .. upgModeName() .. " is running") or ("Status: OFF — Mode: " .. upgModeName()))
end

UpgTab:Label("Mode: Ordered Chain buys upgrades top-to-bottom in your priority order. It finishes the first ON row's target level before moving to the next ON target.")
setAutoUpgrade(states.autoUpgradeOn)

UpgTab:Button("⚡", "Auto Upgrade ON / OFF", "Starts or stops SP spending. Uses the mode shown below and saves automatically.", C.gold, function()
    setAutoUpgrade(not states.autoUpgradeOn)
    saveSettings()
end)

UpgTab:Button("🎯", "Ordered Upgrade Mode", "Locked to top-to-bottom order. Pressing this just re-enables Ordered Chain if old settings changed it.", C.purple, function()
    states.upgradeSequentialMode = true
    setAutoUpgrade(states.autoUpgradeOn)
    saveSettings()
    SLbl.Text = "Upgrade mode: " .. upgModeName()
end)

UpgTab:Label("Ordered Chain: rows are read top to bottom. Turn a row ON, enter a target level, and Auto Upgrade buys only that row until it reaches the target. Then it moves to the next ON row with a target.")
UpgTab:Label("Current order: Skill Point Multiplier → Mana Multiplier → Enemy Limit → Enemy Spawn Rate → Weapons Equipped → Damage Multiplier → Spin Speed → Kill Multiplier.")
UpgTab:Section("Upgrade Targets (SP)")
UpgTab:Label("Example: Skill Point Multiplier ON + Target 150 means buy Skill Point Multiplier to L150 first, then continue to Mana Multiplier if it is ON with a target.")

-- Build upgrade selection list using NexusLib toggles
local upgToggles = {}

local function parseUpgradeCapInput(text)
    local s = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    local n = tonumber(s)
    if not n or n < 1 then return nil end
    return math.min(math.floor(n), 999999)
end

-- Build toggles immediately with no remote calls (instant, no blocking)
-- Level/price info is fetched async and shown in the status label
for _, name in ipairs(UPGRADE_ORDER) do
    local isSel = upgradeSelected[name] == true
    local n2    = name
    upgToggles[name] = UpgTab:Toggle(name, ((UPGRADE_DESCRIPTIONS[n2] or "SP upgrade.") .. " Ordered Chain: ON + target level = buy this before moving to the next target."), isSel, function(on)
        upgradeSelected[n2] = (on == true)
        saveSettings()
    end)
    local capDefault = ""
    if type(upgradeLevelCap[n2]) == "number" and upgradeLevelCap[n2] >= 1 then
        capDefault = tostring(upgradeLevelCap[n2])
    end
    UpgTab:Input(
        "Target level",
        n2 .. " — Ordered Chain stops here before the next row. Empty = skipped in Ordered Chain. Saved.",
        "target level",
        capDefault,
        function(txt)
            upgradeLevelCap[n2] = parseUpgradeCapInput(txt)
            saveSettings()
        end
    )
end

UpgTab:Button("✅", "Select All / None", "Turns every upgrade row ON or OFF. Target levels stay saved.", C.green, function()
    local anyOff = false
    for _, n in ipairs(UPGRADE_ORDER) do
        if not upgradeSelected[n] then anyOff = true; break end
    end
    for _, n in ipairs(UPGRADE_ORDER) do
        upgradeSelected[n] = anyOff
        if upgToggles[n] then
            pcall(function() upgToggles[n].Set(anyOff) end)
        end
    end
    saveSettings()
end)

UpgTab:Section("Live status (updates every ~2.5s)")
local upgLevelLbls = {}
for _, un in ipairs(UPGRADE_ORDER) do
    upgLevelLbls[un] = UpgTab:Label(un .. ": …")
end

local function upgFormatLiveRowText(name)
    local lvl = upgReadUpgradeLevel(name)
    local capN = upgGetTarget(name)
    local capSet = capN ~= nil
    local atCap = capSet and lvl >= capN
    local price = upgGetNextPrice(name, lvl)
    local mid
    if atCap then
        mid = string.format("Lv %d/%d · TARGET DONE", lvl, capN)
    elseif type(price) == "number" and price == price and price < math.huge then
        mid = string.format("Lv %d · next %.0f SP", lvl, price)
    else
        mid = string.format("Lv %d · next ? SP", lvl)
    end
    local tail
    if capSet and not atCap then
        tail = string.format(" · target %d", capN)
    elseif not capSet and states.upgradeSequentialMode then
        tail = " · no target set (skipped in Ordered Chain)"
    elseif not capSet then
        tail = " · no cap"
    else
        tail = ""
    end
    return name .. " — " .. (UPGRADE_DESCRIPTIONS[name] or "SP upgrade") .. " | " .. mid .. tail
end

addThread(task.spawn(function()
    task.wait(2)
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        for _, un in ipairs(UPGRADE_ORDER) do
            local lbl = upgLevelLbls[un]
            if lbl and lbl.Set then
                pcall(function() lbl.Set(upgFormatLiveRowText(un)) end)
            end
        end
        task.wait(2.5)
    end
end))

-- Async level info — updates status label without blocking toggle creation
addThread(task.spawn(function()
    task.wait(2)  -- wait for game to load
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        local sp = getSP()
        local candidates = upgBuildSortedCandidates()
        if not states.autoUpgradeOn then
            upgInfoLbl.Set(string.format("SP: %s | %s | %d ON | targets: %s",
                upgFormatSp(sp), upgModeName(), upgCountSelectedToggles(), upgFormatAllToggled(candidates)))
            task.wait(1)
            continue
        end
        if states.upgradeSequentialMode then
            local row = candidates[1]
            if row then
                local priceText = row.price == math.huge and "?" or tostring(math.floor(row.price))
                upgInfoLbl.Set(string.format("SP: %s | Target %d/%d: %s L%d→%d | next %s SP | %s",
                    upgFormatSp(sp), row.targetIndex or 1, row.targetTotal or upgCountTargetRows(),
                    row.name, row.lvl, row.target or row.lvl, priceText, upgFormatAllToggled(candidates)))
            else
                upgInfoLbl.Set(string.format("SP: %s | Ordered Chain complete / no target below level | %s",
                    upgFormatSp(sp), upgFormatAllToggled(candidates)))
            end
        else
            local nextName, nextPrice = "none", math.huge
            if #candidates > 0 then
                nextName = candidates[1].name
                nextPrice = candidates[1].price
            end
            upgInfoLbl.Set(string.format("SP: %s | %d ON | cheapest:%s (%s SP) | %s",
                upgFormatSp(sp), upgCountSelectedToggles(), nextName,
                nextPrice == math.huge and "?" or tostring(math.floor(nextPrice)),
                upgFormatAllToggled(candidates)))
        end
        task.wait(1.2)
    end
end))

-- ── Auto Upgrade Loop ─────────────────────────────────────────────────────
-- Burst-buy: Ordered Chain buys one active target at a time, top-to-bottom.
local UPGRADE_BURST_MAX = 32
local UPGRADE_LOOP_AFTER_BUY = 0.06
local UPGRADE_LOOP_IDLE = 0.22
addThread(task.spawn(function()
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        if not states.autoUpgradeOn then
            task.wait(0.45)
            continue
        end

        local sp = getSP()
        local boughtAny = false
        local lastCand = nil

        for _ = 1, UPGRADE_BURST_MAX do
            local candidates = upgBuildSortedCandidates()
            lastCand = candidates
            local spNum = tonumber(sp) or 0
            local boughtThisRound = false
            for _, row in ipairs(candidates) do
                local name, price, lvl = row.name, row.price, row.lvl
                if spNum >= price then
                    local ok = invokeR("BuyUpgrade", name)
                    if ok then
                        boughtThisRound = true
                        boughtAny = true
                        upgInvalidatePriceCache()
                        _cachedStats["SP"] = nil
                        sp = getSP()
                        spNum = tonumber(sp) or 0
                        if row.target then
                            upgStatusLbl.Set(string.format("✓ Bought: %s Lv%d→Lv%d / target %d | SP: %s", name, lvl, lvl + 1, row.target, upgFormatSp(sp)))
                        else
                            upgStatusLbl.Set(string.format("✓ Bought: %s Lv%d→Lv%d | SP: %s", name, lvl, lvl + 1, upgFormatSp(sp)))
                        end
                        SLbl.Text = "⬆️ Upgraded: " .. name
                        task.wait(UPGRADE_LOOP_AFTER_BUY)
                        break
                    end
                end
            end
            if not boughtThisRound then break end
        end

        if not boughtAny then
            local candidates = lastCand or upgBuildSortedCandidates()
            if states.upgradeSequentialMode then
                local row = candidates[1]
                if row then
                    local priceText = row.price == math.huge and "?" or tostring(math.floor(row.price))
                    upgStatusLbl.Set(string.format("⏳ Target %d/%d: %s Lv%d/%d | need %s SP | have %s",
                        row.targetIndex or 1, row.targetTotal or upgCountTargetRows(), row.name, row.lvl,
                        row.target or row.lvl, priceText, upgFormatSp(sp)))
                else
                    upgStatusLbl.Set("✓ Ordered Chain complete — no ON target is below its level")
                end
            else
                local nextName, nextPrice = "none", math.huge
                if #candidates > 0 then
                    nextName = candidates[1].name
                    nextPrice = candidates[1].price
                end
                upgStatusLbl.Set(string.format("⏳ Cheapest next:%s (%s SP) | Have %s | On:%s",
                    nextName, nextPrice == math.huge and "?" or tostring(math.floor(nextPrice)), upgFormatSp(sp),
                    upgFormatAllToggled(candidates)))
            end
            task.wait(UPGRADE_LOOP_IDLE)
        else
            task.wait(UPGRADE_LOOP_AFTER_BUY)
        end
    end
end))

-- ── Guild: SP → GP (BuyGP) + auto buffs (BuyGuildBuff) ────────────────────
addThread(task.spawn(function()
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        task.wait(0.55)
        if not states.autoGuildSpToGp then continue end
        if not R("BuyGP") then continue end
        local g = fetchGuildState()
        if not g or not guildPlayerIsMember(g) then continue end
        local sp = tonumber(getSP()) or 0
        local reserve = math.max(0, math.floor(tonumber(states.guildSpReserve) or 0))
        local spend = math.floor(sp - reserve)
        if spend <= 0 then continue end
        invokeR("BuyGP", spend)
        _cachedStats["SP"] = nil
    end
end))

addThread(task.spawn(function()
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        task.wait(1.15)
        if not states.autoGuildBuffs then continue end
        if not R("BuyGuildBuff") then continue end
        local g = fetchGuildState()
        if not g or not g.GuildID then continue end
        if tostring(g.Owner) ~= tostring(LP.UserId) then continue end

        local buffs = type(g.GuildBuffs) == "table" and g.GuildBuffs or {}
        local gp = tonumber(g.GuildPoints) or 0
        local rows = {}
        for _, name in ipairs(GUILD_BUFF_ORDER) do
            if guildBuffSelected[name] ~= true then continue end
            local lvl = tonumber(buffs[name]) or 0
            local cost = guildBuffNextCost(name, lvl)
            if type(cost) == "number" and cost == cost and cost > 0 and cost < math.huge then
                rows[#rows + 1] = { name = name, cost = cost, lvl = lvl }
            end
        end
        table.sort(rows, function(a, b) return a.cost < b.cost end)

        for _, row in ipairs(rows) do
            if gp < row.cost then continue end
            local ok, newLevel, newGP = invokeR2("BuyGuildBuff", g.GuildID, row.name)
            if ok and type(newLevel) == "number" then
                gp = tonumber(newGP) or (gp - row.cost)
                break
            end
        end
    end
end))

-- ── Ascend AP statue upgrades (UpgradeAscend) ─────────────────────────────
addThread(task.spawn(function()
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        task.wait(1.2)
        if not states.autoApUpgrades then continue end
        if not R("UpgradeAscend") or not R("GetAscendUpgrades") then continue end

        local levels = invokeR("GetAscendUpgrades")
        if type(levels) ~= "table" then continue end

        local ap = parseAscendPoints(invokeR("GetAscendPoints"))
        local rows = {}
        for _, name in ipairs(ASCEND_AP_ORDER) do
            if apUpgradeSelected[name] ~= true then continue end
            local lvl = tonumber(levels[name]) or 0
            if lvl >= ASCEND_AP_MAX_LEVEL then continue end
            local cost = ascendApNextCost(name, lvl)
            if type(cost) == "number" and cost == cost and cost > 0 and cost < math.huge then
                rows[#rows + 1] = { name = name, cost = cost, lvl = lvl }
            end
        end
        table.sort(rows, function(a, b) return a.cost < b.cost end)

        for _, row in ipairs(rows) do
            if ap < row.cost then continue end
            local ok, newLevel = invokeR2("UpgradeAscend", row.name)
            if ok and type(newLevel) == "number" then
                break
            end
        end
    end
end))

-- --------------------------------------------------------------------------
-- UI — Sacrifice tab (OneIn / RS.Assets.Weapons rarity colors)
-- --------------------------------------------------------------------------

-- OneIn max per tier (Fountain color cap; auto picks highest eligible OneIn ≤ cap)
local SAC_TIERS = {
    { emoji = "⬜", name = "Common",     maxOneIn = 5 },
    { emoji = "🟩", name = "Uncommon",   maxOneIn = 50 },
    { emoji = "🟦", name = "Rare",       maxOneIn = 200 },
    { emoji = "🟣", name = "Epic",       maxOneIn = 5000 },
    { emoji = "🟠", name = "Legendary",  maxOneIn = 50000 },
    { emoji = "🩷", name = "Mythic",     maxOneIn = 1000000 },
    { emoji = "🟤", name = "Galactic",   maxOneIn = 7000000 },
    { emoji = "🩵", name = "Godly",      maxOneIn = 11000000 },
    { emoji = "⬛", name = "Omnipotent", maxOneIn = 99000000 },
}

local _sacInv = {}
local _sacAssetCache = {}

local function sacWeaponsFolder()
    local a = RS:FindFirstChild("Assets")
    return a and a:FindFirstChild("Weapons")
end

local function sacLookupAsset(weaponName)
    if _sacAssetCache[weaponName] ~= nil then
        local c = _sacAssetCache[weaponName]
        return c ~= false and c or nil
    end
    local folder = sacWeaponsFolder()
    local asset = nil
    if folder then
        asset = folder:FindFirstChild(weaponName)
        if not asset then
            local nl = weaponName:lower()
            for _, ch in ipairs(folder:GetChildren()) do
                if ch.Name:lower() == nl then asset = ch; break end
            end
        end
    end
    _sacAssetCache[weaponName] = asset or false
    return asset
end

local function sacTierFromOneIn(oneIn)
    local o = tonumber(oneIn)
    if not o then return "?", "?" end
    for _, t in ipairs(SAC_TIERS) do
        if o <= t.maxOneIn then
            return t.emoji .. " " .. t.name, t
        end
    end
    return "✴ Above Omnipotent", nil
end

local function sacCapOneInForDropdownIdx(idx)
    local t = SAC_TIERS[math.clamp(math.floor(tonumber(idx) or 1), 1, #SAC_TIERS)]
    return t and t.maxOneIn or 5
end

local function normSacWeapon(e)
    if type(e) ~= "table" then return nil end
    local name = e.Name or e.name or e.WepName or e.WeaponName or e.Weapon
    if not name or name == "" then return nil end
    local wtype = e.Type or e.WeaponType or e.type or e.Category or "Unknown"
    return {
        name   = tostring(name),
        type   = tostring(wtype),
        qty    = math.max(0, math.floor(tonumber(e.Quantity or e.Qty or e.Count or e.amount or e.Amount or 1) or 0)),
        oneIn  = nil,
        rank   = math.floor(tonumber(e.Rank or e.rank or e.Tier or 0) or 0),
        damage = tonumber(e.Damage or e.damage or e.DPS or e.BaseDamage or 0) or 0,
    }
end

local function sacEnrichFromAssets()
    for _, w in ipairs(_sacInv) do
        local asset = sacLookupAsset(w.name)
        if asset then
            w.oneIn = tonumber(asset:GetAttribute("OneIn"))
            w.rank = math.floor(tonumber(asset:GetAttribute("Rank")) or w.rank or 0)
            w.damage = tonumber(asset:GetAttribute("Damage")) or w.damage or 0
        end
        if w.oneIn == nil then
            w.oneIn = math.huge
        end
    end
end

local SAC_DROPDOWN_LABELS = {}
for i, t in ipairs(SAC_TIERS) do
    SAC_DROPDOWN_LABELS[i] = string.format("%s %s · highest available OneIn≤%s", t.emoji, t.name, tostring(t.maxOneIn))
end

-- Totem: exact tier band only (Fountain still uses “up through” caps above).
local SAC_TOTEM_DROPDOWN_LABELS = {}
for i, t in ipairs(SAC_TIERS) do
    if i == 1 then
        SAC_TOTEM_DROPDOWN_LABELS[i] = string.format("%s %s · Totem only: OneIn ≤ %s", t.emoji, t.name, tostring(t.maxOneIn))
    else
        local prev = SAC_TIERS[i - 1].maxOneIn
        SAC_TOTEM_DROPDOWN_LABELS[i] = string.format(
            "%s %s · Totem only: OneIn > %s and ≤ %s",
            t.emoji,
            t.name,
            tostring(prev),
            tostring(t.maxOneIn)
        )
    end
end

local function sacAnyFilterOn()
    return states.sacFilterColor or states.sacFilterName
end

local function sacWeaponPasses(w)
    if states.sacFilterName then
        return _sacNameSelected[w.name] == true
    end
    if states.sacFilterColor then
        local cap = sacCapOneInForDropdownIdx(states.sacRarityCapIdx)
        local oi = tonumber(w.oneIn)
        if not oi or oi == math.huge then return false end
        return oi <= cap
    end
    return false
end

--- Fountain Auto Sacrifice priority:
--- Pick the highest real OneIn that is currently available under the selected cap.
--- Example: Godly cap (≤11M) tries the best owned/extra weapon below 11M first;
--- if none / server rejects / keep qty blocks it, it falls to the next-highest candidate.
local function sacBuildHighestEligibleCandidates(keep)
    keep = math.max(0, math.floor(tonumber(keep) or 0))
    local candidates = {}
    for _, w in ipairs(_sacInv) do
        if sacWeaponPasses(w) and (tonumber(w.qty) or 0) > keep then
            candidates[#candidates + 1] = w
        end
    end
    table.sort(candidates, function(a, b)
        local oa = tonumber(a.oneIn) or -math.huge
        local ob = tonumber(b.oneIn) or -math.huge
        if oa ~= ob then return oa > ob end -- highest/rarest under cap first
        local ra = tonumber(a.rank) or 0
        local rb = tonumber(b.rank) or 0
        if ra ~= rb then return ra > rb end
        local da = tonumber(a.damage) or 0
        local db = tonumber(b.damage) or 0
        if da ~= db then return da > db end
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    return candidates
end

-- ── Totem of Fortune (TotemConfirm) — rarity by OneIn color; highest Rank first (luck = Rank/10% per slot)
local TOTEM_AP_UPGRADE_NAME = "Totem Of Fortune Sacrifices"
local TOTEM_CYCLE_SEC       = 3600
local TOTEM_BASE_MAX        = 25
local TOTEM_ACTION_DELAY_SEC = 30 -- one-time settle delay right after hourly CD ends
local TOTEM_REJECT_BACKOFF_SEC = 45 -- after server false: don't spam InvokeServer (fewer red toasts)
local TOTEM_AUTO_TICK_SEC      = 0.35 -- how often Auto Totem retries (gap still applies between invokes)
local TOTEM_MIN_INVOKE_GAP_SEC = 2.75 -- min seconds between TotemConfirm invokes (lower = faster; too low may ERROR spam)
local TOTEM_SKIP_AFTER_REJECT_SEC = 180 -- server false for this weapon name: try other picks for a few minutes
local TOTEM_CONFIRM_WINDOW_SEC = 1.2 -- only count if no red ERROR arrives in this window
local _totemLastConfirmClock = 0
local _totemRejectUntil = {} -- [weaponName] = os.clock() until skip expires
local _totemRoundRobin = 1 -- cycles through all Totem-color weapons; each InvokeServer uses that row's real name
local _totemPendingToken = 0 -- increments per invoke; delayed confirmer checks latest token
local _totemPendingReject = false
local _totemApCache         = { t = 0, lvl = 0 }
local _totemNextActionAt    = 0   -- os.clock() time gate (session only)
local _totemActionsThisRun  = 0   -- number of successful totem sacrifices this run
local _totemWasOnCooldown   = (states.totemCapHitUnix ~= nil)
-- Server-confirmed cap: states.totemSavedServerCap (persisted) + SendNotification parse

-- Totem CD keys are often missing from default `states` (nil fields), so merge loop skips them — load from LS here.
-- Remaining CD = TOTEM_CYCLE_SEC - (os.time() - savedUnix). Roblox os.time() is real UTC wall clock: works after
-- disconnect/rejoin as long as meleernq_settings.json was saved (Auto Save or cap triggered save).
states.totemCapHitUnix = tonumber(LS.totemCapHitUnix)
states.totemSavedServerCap = tonumber(LS.totemSavedServerCap)
states.totemCapFromServerNotify = LS.totemCapFromServerNotify == true

local function totemSanitizeLoadedCooldown()
    local hit = states.totemCapHitUnix
    if not hit then return end
    local now = os.time()
    local elapsed = now - hit
    if elapsed < 0 then
        states.totemCapHitUnix = nil
        forceSave()
        return
    end
    if elapsed >= TOTEM_CYCLE_SEC then
        states.totemCapHitUnix = nil
        states.totemDoneThisCycle = 0
        states.totemCapFromServerNotify = false
        states.totemSavedServerCap = nil
        forceSave()
    end
end
totemSanitizeLoadedCooldown()

local function totemParseMaxFromNotification(msg)
    if type(msg) ~= "string" then return nil end
    -- "You can only sacrifice max 40 weapons every hour!"
    local nmax = msg:match("[Mm]ax%s+(%d+)")
    if nmax then
        local n = tonumber(nmax)
        if n and n >= 1 and n <= 999 then return math.floor(n) end
    end
    local _, mx = msg:match("(%d+)%s*/%s*(%d+)")
    if mx then
        local n = tonumber(mx)
        if n then return math.floor(n) end
    end
    _, mx = msg:match("(%d+)%s+of%s+(%d+)")
    if mx then
        local n = tonumber(mx)
        if n then return math.floor(n) end
    end
    local best = nil
    for n in msg:gmatch("%d+") do
        local v = math.floor(tonumber(n) or 0)
        if v >= 1 and v <= 500 then
            if not best or v > best then best = v end
        end
    end
    return best
end

local function totemNotificationLooksLikeCap(msg)
    if type(msg) ~= "string" then return false end
    local m = msg:lower()
    -- Server string has no "totem" — e.g. "sacrifice max 40 ... every hour!"
    if m:find("sacrifice", 1, true) and m:find("every hour", 1, true) then return true end
    if m:find("totem", 1, true) == nil and m:find("fortune", 1, true) == nil then return false end
    if m:find("max", 1, true) or m:find("limit", 1, true) or m:find("reached", 1, true)
        or m:find("cap", 1, true) or m:find("full", 1, true) or m:find("cannot", 1, true)
        or m:find("already", 1, true) then
        return true
    end
    local a, b = msg:match("(%d+)%s*/%s*(%d+)")
    if a and b and tonumber(a) and tonumber(b) and tonumber(a) >= tonumber(b) then
        return true
    end
    return false
end

--- ERROR notifications we treat as Totem hourly cap (message text varies; may omit "totem")
local function totemSendNotificationIsRelevant(message)
    if type(message) ~= "string" then return false end
    local m = message:lower()
    if m:find("totem", 1, true) or m:find("fortune", 1, true) then return true end
    if m:find("sacrifice", 1, true) and m:find("every hour", 1, true) then return true end
    return false
end

local function getTotemApLevel()
    local now = os.clock()
    if now - _totemApCache.t < 12 then
        return _totemApCache.lvl
    end
    _totemApCache.t = now
    local lvl = 0
    pcall(function()
        local u = invokeR("GetAscendUpgrades")
        if type(u) == "table" then
            lvl = math.floor(tonumber(u[TOTEM_AP_UPGRADE_NAME]) or 0)
            if lvl == 0 then
                for k, v in pairs(u) do
                    if type(k) == "string" and k:find("Totem", 1, true) and k:find("Fortune", 1, true) then
                        local nv = tonumber(v)
                        if nv then lvl = math.floor(nv); break end
                    end
                end
            end
        end
        if lvl == 0 then
            local alt = invokeR("GetAscendUpgradeLevel", TOTEM_AP_UPGRADE_NAME)
            lvl = math.floor(tonumber(alt) or 0)
        end
    end)
    _totemApCache.lvl = lvl
    return lvl
end

local function getTotemMaxPerCycle()
    local calc = TOTEM_BASE_MAX + getTotemApLevel() * 5
    local srv = tonumber(states.totemSavedServerCap)
    if srv and srv > 0 then
        return srv
    end
    return calc
end

--- Returns isOnCooldown, secondsRemaining (0 if not on CD). Clears cycle when CD elapsed.
local function totemInCooldown()
    local hit = states.totemCapHitUnix
    if not hit then
        _totemWasOnCooldown = false
        return false, 0
    end
    local now = os.time()
    local elapsed = now - hit
    if elapsed >= TOTEM_CYCLE_SEC then
        states.totemCapHitUnix = nil
        states.totemDoneThisCycle = 0
        states.totemCapFromServerNotify = false
        states.totemSavedServerCap = nil
        -- CD just reached zero: wait a bit so stale cap text / delayed notifications don't instantly re-lock.
        if _totemWasOnCooldown then
            _totemNextActionAt = math.max(_totemNextActionAt, os.clock() + TOTEM_ACTION_DELAY_SEC)
        end
        _totemWasOnCooldown = false
        if states.autoSave then saveSettings() else forceSave() end
        return false, 0
    end
    _totemWasOnCooldown = true
    return true, TOTEM_CYCLE_SEC - elapsed
end

local function totemWeaponPassesColor(w)
    if not states.totemFilterColor then return false end
    local idx = math.clamp(math.floor(tonumber(states.totemRarityCapIdx) or 1), 1, #SAC_TIERS)
    local oi = tonumber(w.oneIn)
    if not oi or oi == math.huge then return false end
    local maxCap = SAC_TIERS[idx].maxOneIn
    if idx == 1 then
        return oi > 0 and oi <= maxCap
    end
    local minCap = SAC_TIERS[idx - 1].maxOneIn
    return oi > minCap and oi <= maxCap
end

local function formatTotemCd(secs)
    secs = math.max(0, math.floor(secs))
    local m = math.floor(secs / 60)
    local s = secs % 60
    return string.format("%dm%ds", m, s)
end

local function totemActionWaitRemaining()
    local remain = _totemNextActionAt - os.clock()
    if remain <= 0 then return 0 end
    return math.floor(remain + 0.5)
end

local totemStatusLbl
local function updateTotemStatusLbl()
    if not totemStatusLbl then return end
    local maxC = getTotemMaxPerCycle()
    local onCd, remain = totemInCooldown()
    local done = math.min(math.max(0, states.totemDoneThisCycle), maxC)
    local cdStr = onCd and formatTotemCd(remain) or "ready"
    local waitSec = totemActionWaitRemaining()
    if states.totemCapFromServerNotify and onCd then
        totemStatusLbl.Set(string.format("Cap hit | Max=%d (server confirmed) · CD: %s | this run: %d", maxC, cdStr, _totemActionsThisRun))
    elseif waitSec > 0 then
        totemStatusLbl.Set(string.format("Totem: %d/%d done | wait: %ds | this run: %d | AP max: %d", done, maxC, waitSec, _totemActionsThisRun, maxC))
    else
        totemStatusLbl.Set(string.format("Totem: %d/%d done | CD: %s | this run: %d | AP max: %d", done, maxC, cdStr, _totemActionsThisRun, maxC))
    end
end

local function totemPassesNameTickGate(w)
    if not states.totemOnlyTickedNames then return true end
    return _sacNameSelected[w.name] == true
end

local function totemRemoteWeaponName(fullName)
    local n = tostring(fullName or ""):match("^%s*(.-)%s*$") or ""
    if n == "" then return n end
    local low = n:lower()
    for _, t in ipairs(SAC_TIERS) do
        local pref = (t.name .. " "):lower()
        if low:sub(1, #pref) == pref then
            local stripped = n:sub(#pref + 1):match("^%s*(.-)%s*$") or ""
            if stripped ~= "" then return stripped end
            break
        end
    end
    return n
end

local function totemEligibleCountCached()
    local keep = math.max(0, math.floor(tonumber(states.totemKeepQty) or 0))
    local n = 0
    for _, w in ipairs(_sacInv) do
        if totemWeaponPassesColor(w) and w.qty > keep and totemPassesNameTickGate(w) then
            n = n + 1
        end
    end
    return n
end

local function onTotemSendNotification(message, msgType)
    if GEN ~= _G.MeleeRNG_Gen then return end
    if type(message) ~= "string" then return end
    local mt = type(msgType) == "string" and msgType:upper() or ""
    if mt ~= "ERROR" then return end
    if not totemSendNotificationIsRelevant(message) then return end
    -- A relevant red ERROR during pending window means this attempt should NOT count.
    _totemPendingReject = true

    local parsedMax = totemParseMaxFromNotification(message)
    if not parsedMax or parsedMax < 1 then return end

    states.totemSavedServerCap = parsedMax
    _totemApCache.t = 0

    if not totemNotificationLooksLikeCap(message) then
        saveSettings()
        updateTotemStatusLbl()
        return
    end

    -- Ignore stale/replayed cap text until our local progress reached cap.
    -- This prevents CD from restarting early at 0:00 when old text re-fires.
    local localDone = math.max(0, math.floor(tonumber(states.totemDoneThisCycle) or 0))
    if localDone < parsedMax then
        local eligibleNow = totemEligibleCountCached()
        if eligibleNow > 0 then
            updateTotemStatusLbl()
            return
        end
        -- Even if no eligible weapon right now, do not start hourly CD from text alone.
        -- User can refresh/retarget filters; CD starts only after true cap usage.
        updateTotemStatusLbl()
        return
    end

    states.totemDoneThisCycle = math.max(localDone, parsedMax)
    if not states.totemCapHitUnix then
        states.totemCapHitUnix = os.time()
    end
    states.totemCapFromServerNotify = true
    saveSettings()
    updateTotemStatusLbl()
end

SacTab:Section("Sacrifice")
SacTab:Label("All options below save to meleernq_settings.json (with Auto Save on). Weapon name ticks save too.")
SacTab:Label("Refresh ties each weapon to RS.Assets.Weapons for OneIn (color tier). Auto-refresh ~2s after load.")
SacTab:Label("By color: auto chooses the highest available OneIn ≤ dropdown cap, then goes lower only if needed. By Name ignores color. Keep qty always applies.")
local sacStatusLbl = SacTab:Label("Auto: OFF · idle")
local sacLastLbl   = SacTab:Label("Last: —")

local sacInvLbl
local sacWeaponScroll

local function rebuildSacWeaponRows()
    if not sacWeaponScroll then return end
    for _, c in ipairs(sacWeaponScroll:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    table.sort(_sacInv, function(a, b) return a.name:lower() < b.name:lower() end)
    for i, w in ipairs(_sacInv) do
        local row = Instance.new("TextButton", sacWeaponScroll)
        row.Size = UDim2.new(1, -8, 0, 26)
        row.LayoutOrder = i
        row.BackgroundColor3 = _sacNameSelected[w.name] and Color3.fromRGB(0, 45, 25) or Color3.fromRGB(12, 16, 24)
        row.BorderSizePixel = 0
        row.Text = ""
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 4)
        local lbl = Instance.new("TextLabel", row)
        lbl.Size = UDim2.new(1, -28, 1, 0)
        lbl.Position = UDim2.new(0, 6, 0, 0)
        lbl.BackgroundTransparency = 1
        lbl.Font = Enum.Font.GothamBold
        lbl.TextSize = 10
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.TextTruncate = Enum.TextTruncate.AtEnd
        lbl.TextColor3 = _sacNameSelected[w.name] and C.green or C.text
        local tierLbl = select(1, sacTierFromOneIn(w.oneIn))
        local oiDisp = (w.oneIn and w.oneIn < 1e15) and tostring(math.floor(w.oneIn)) or "?"
        lbl.Text = string.format("%s  OneIn=%s  ×%d  R%d  dmg %.0f  %s", tierLbl, oiDisp, w.qty, w.rank, w.damage, w.name)
        local chk = Instance.new("Frame", row)
        chk.Size = UDim2.new(0, 14, 0, 14)
        chk.Position = UDim2.new(1, -20, 0.5, -7)
        chk.BackgroundColor3 = _sacNameSelected[w.name] and C.green or C.border
        chk.BorderSizePixel = 0
        Instance.new("UICorner", chk).CornerRadius = UDim.new(0, 3)
        local tick = Instance.new("TextLabel", chk)
        tick.Size = UDim2.new(1, 0, 1, 0)
        tick.BackgroundTransparency = 1
        tick.Text = "✓"
        tick.TextColor3 = Color3.new(1, 1, 1)
        tick.Font = Enum.Font.GothamBold
        tick.TextSize = 9
        tick.Visible = _sacNameSelected[w.name] == true
        row.MouseButton1Click:Connect(function()
            _sacNameSelected[w.name] = not _sacNameSelected[w.name]
            rebuildSacWeaponRows()
            saveSettings()
        end)
    end
end

local function refreshSacInventory()
    _sacAssetCache = {}
    local raw = invokeR("GetWeaponsInv")
    _sacInv = {}
    if type(raw) == "table" then
        local function pushEntry(e)
            local w = normSacWeapon(e)
            if w and w.qty > 0 then _sacInv[#_sacInv + 1] = w end
        end
        if raw[1] ~= nil then
            for _, e in ipairs(raw) do pushEntry(e) end
        else
            for _, e in pairs(raw) do pushEntry(e) end
        end
    end
    sacEnrichFromAssets()
    local totalQty = 0
    for _, w in ipairs(_sacInv) do totalQty = totalQty + w.qty end
    if sacInvLbl then
        sacInvLbl.Set(string.format("Inv: %d types | %d total qty", #_sacInv, totalQty))
    end
    for _, w in ipairs(_sacInv) do
        local tl = select(1, sacTierFromOneIn(w.oneIn))
        local oi = (w.oneIn and w.oneIn < 1e15) and math.floor(w.oneIn) or -1
        vprint(string.format("[MeleeRNG/Sac] [OK] %-32s x%-4d  Rank=%-3s  Dmg=%-8s  OneIn=%-10s  %s  | %s",
            w.name, w.qty, tostring(w.rank), tostring(w.damage), oi >= 0 and tostring(oi) or "?", w.type, tl))
    end
    rebuildSacWeaponRows()
    SLbl.Text = string.format("Sacrifice: %d weapon types (OneIn from Assets)", #_sacInv)
end

--- One TotemConfirm call: Totem color = OneIn range (e.g. Galactic). Every matching weapon is a candidate;
--- we cycle round-robin and pass each row's actual w.name (same as Cobalt string).
local function totemExecuteNext()
    if totemActionWaitRemaining() > 0 then
        return false, "wait"
    end
    local gapLeft = TOTEM_MIN_INVOKE_GAP_SEC - (os.clock() - _totemLastConfirmClock)
    if gapLeft > 0 then
        return false, "throttle"
    end
    local onCd = select(1, totemInCooldown())
    if onCd then return false, "cd" end
    local maxC = getTotemMaxPerCycle()
    if states.totemDoneThisCycle >= maxC then
        -- Orphan save: count at max but no hour anchor → was showing "CD: ready" while server still locks
        if not states.totemCapHitUnix then
            states.totemCapHitUnix = os.time()
            saveSettings()
        end
        return false, "local_cap"
    end
    refreshSacInventory()
    local keep = math.max(0, math.floor(tonumber(states.totemKeepQty) or 0))
    local nowClk = os.clock()
    local candidates = {}
    for _, w in ipairs(_sacInv) do
        if totemWeaponPassesColor(w) and w.qty > keep and totemPassesNameTickGate(w) then
            local skipT = _totemRejectUntil[w.name]
            if not skipT or nowClk >= skipT then
                candidates[#candidates + 1] = w
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        local oa = tonumber(a.oneIn) or math.huge
        local ob = tonumber(b.oneIn) or math.huge
        if oa ~= ob then return oa < ob end
        return a.name:lower() < b.name:lower()
    end)
    local nCand = #candidates
    if nCand == 0 then
        if states.totemOnlyTickedNames then
            local hasInColor = false
            local tickInColor = false
            for _, ww in ipairs(_sacInv) do
                if totemWeaponPassesColor(ww) and ww.qty > keep then
                    hasInColor = true
                    if _sacNameSelected[ww.name] then tickInColor = true break end
                end
            end
            if hasInColor and not tickInColor then
                return false, "no_totem_tick"
            end
        end
        return false, "no_weapon"
    end
    local idx = ((_totemRoundRobin - 1) % nCand) + 1
    local w = candidates[idx]
    local function advanceTotemRoundRobin()
        _totemRoundRobin = (idx % nCand) + 1
    end
    local tr = R("TotemConfirm")
    if not tr then return false, "fail" end
    _totemLastConfirmClock = os.clock()
    -- Cobalt-style: one string = that row's inventory weapon name.
    local remoteName = totemRemoteWeaponName(w.name)
    local bandIdx = math.clamp(math.floor(tonumber(states.totemRarityCapIdx) or 7), 1, #SAC_TIERS)
    local bandName = SAC_TIERS[bandIdx].name
    local oneInTierStr = select(1, sacTierFromOneIn(w.oneIn))
    vprint(string.format(
        "[MeleeRNG/Totem] %s band · %d/%d · OneIn tier %s · inv=%q -> send=%q",
        bandName,
        idx,
        nCand,
        oneInTierStr,
        w.name,
        remoteName
    ))
    local invokeOk, res = pcall(function() return tr:InvokeServer(remoteName) end)
    if not invokeOk then
        invokeOk, res = pcall(function() return tr:InvokeServer(remoteName, w.type) end)
    end
    if not invokeOk then
        advanceTotemRoundRobin()
        return false, "fail"
    end
    -- Server returns false = rejected (cap or transient); don't force-start 1h CD from this alone.
    if res == false then
        _totemRejectUntil[w.name] = os.clock() + TOTEM_SKIP_AFTER_REJECT_SEC
        states.totemSavedServerCap = maxC
        _totemNextActionAt = math.max(_totemNextActionAt, os.clock() + TOTEM_REJECT_BACKOFF_SEC)
        saveSettings()
        advanceTotemRoundRobin()
        return false, "server_reject"
    end
    -- Count only if no relevant red ERROR appears shortly after this invoke.
    _totemPendingToken = _totemPendingToken + 1
    local myTok = _totemPendingToken
    _totemPendingReject = false
    task.delay(TOTEM_CONFIRM_WINDOW_SEC, function()
        if GEN ~= _G.MeleeRNG_Gen then return end
        if myTok ~= _totemPendingToken then return end
        if _totemPendingReject then return end
        states.totemDoneThisCycle = states.totemDoneThisCycle + 1
        _totemActionsThisRun = _totemActionsThisRun + 1
        -- Last sacrifice of the cycle starts the same 1h window the server uses
        if states.totemDoneThisCycle >= maxC then
            if not states.totemCapHitUnix then
                states.totemCapHitUnix = os.time()
            end
        end
        saveSettings()
        updateTotemStatusLbl()
    end)
    advanceTotemRoundRobin()
    local okMsg = string.format(
        '%s (selected band) · inv "%s" → TotemConfirm("%s") · %s',
        bandName,
        w.name,
        remoteName,
        oneInTierStr
    )
    return true, okMsg
end

-- Fix JSON that has totemDoneThisCycle >= max but no totemCapHitUnix (never showed hourly CD)
addThread(task.spawn(function()
    task.wait(1.5)
    if GEN ~= _G.MeleeRNG_Gen then return end
    pcall(function()
        local maxC = getTotemMaxPerCycle()
        if states.totemDoneThisCycle >= maxC and not states.totemCapHitUnix then
            states.totemCapHitUnix = os.time()
            forceSave()
            updateTotemStatusLbl()
        end
    end)
end))

SacTab:Button("🔄", "Refresh Inventory", "GetWeaponsInv:InvokeServer() — list + console print", C.accent, function()
    refreshSacInventory()
end)

sacInvLbl = SacTab:Label("Inv: 0 types | 0 total — tap Refresh")

SacTab:Section("Filters (color + name only)")
local sacFilterColorToggle = SacTab:Toggle("By color (OneIn)", "Auto sacrifices the highest available weapon with OneIn ≤ cap, then falls lower only if needed — saved", states.sacFilterColor, function(on)
    states.sacFilterColor = on == true; saveSettings()
end)
local sacFilterNameToggle = SacTab:Toggle("By Name", "Only ticked rows in list — ignores color filter — saved", states.sacFilterName, function(on)
    states.sacFilterName = on == true; saveSettings()
end)

local sacRarityDropdown = SacTab:Dropdown(
    "Sacrifice up through this color",
    "Max OneIn cap for auto-sac. It picks the highest available weapon under this cap first, then falls lower if needed.",
    SAC_DROPDOWN_LABELS,
    math.clamp(states.sacRarityCapIdx, 1, #SAC_TIERS),
    function(_, _, idx)
        states.sacRarityCapIdx = math.clamp(math.floor(tonumber(idx) or 1), 1, #SAC_TIERS)
        saveSettings()
    end
)

SacTab:Label("Tier caps (OneIn): ⬜≤5 · 🟩≤50 · 🟦≤200 · 🟣≤5k · 🟠≤50k · 🩷≤1M · 🟤≤7M · 🩵≤11M · ⬛≤99M")

SacTab:Section("Always keep")
local sacKeepSlider = SacTab:Slider("Always keep qty", "Per weapon type: keep at least this many; sacrifice the rest (saved)", {
    min = 0, max = 999, default = math.clamp(states.sacKeepQty, 0, 999),
    format = function(v) return "keep " .. tostring(math.floor(v)) end,
}, function(v)
    states.sacKeepQty = math.floor(v); saveSettings()
end)

local sacAutoToggle = SacTab:Toggle("Toggle Auto Sacrifice", "Every 1.5s: inventory, filters, FountainSacrifice — saved", states.autoSacrifice, function(on)
    states.autoSacrifice = on == true
    saveSettings()
    sacStatusLbl.Set(on and "Auto: ON · every 1.5s" or "Auto: OFF · idle")
    SLbl.Text = on and "Auto Sacrifice ON" or "Auto Sacrifice OFF"
end)

SacTab:Section("Totem of Fortune")
SacTab:Label("Separate from Fountain: own color cap + keep below. Remote: TotemConfirm(weaponName). Luck ~Rank/10% per slot.")
SacTab:Label("Cap: 25 + AP×5. ERROR notifications update max; 1h CD starts only after local done reaches max (prevents stale text resets).")
SacTab:Label("CD timer uses device os.time() vs saved start — time keeps passing offline; needs settings saved (Auto Save or after cap).")
local totemFilterColorToggle = SacTab:Toggle("Totem: By color (OneIn)", "Totem only — weapons in that tier’s OneIn band only (not “up through”) — saved", states.totemFilterColor, function(on)
    states.totemFilterColor = on == true
    saveSettings()
end)
local totemOnlyTickedToggle = SacTab:Toggle("Totem: only ✓ list names", "ON = TotemConfirm only weapons you tick in the list below that also pass Totem color + keep (same idea as typing one Cobalt name) — saved", states.totemOnlyTickedNames, function(on)
    states.totemOnlyTickedNames = on == true
    saveSettings()
end)
local totemRarityDropdown = SacTab:Dropdown(
    "Totem — only this color tier",
    "Totem matches OneIn inside this band only. Fountain dropdown above still uses “up through” caps.",
    SAC_TOTEM_DROPDOWN_LABELS,
    math.clamp(states.totemRarityCapIdx, 1, #SAC_TIERS),
    function(_, _, idx)
        states.totemRarityCapIdx = math.clamp(math.floor(tonumber(idx) or 1), 1, #SAC_TIERS)
        saveSettings()
    end
)
SacTab:Label("Totem bands: Common ≤5 · Uncommon (5,50] · Rare (50,200] · Epic (200,5k] · Leg (5k,50k] · Mythic (50k,1M] · Galactic (1M,7M] · Godly (7M,11M] · Omni (11M,99M]")
local totemKeepSlider = SacTab:Slider("Totem — always keep qty", "Per weapon type for Totem only; independent of Fountain keep (saved)", {
    min = 0, max = 999, default = math.clamp(states.totemKeepQty, 0, 999),
    format = function(v) return "keep " .. tostring(math.floor(v)) end,
}, function(v)
    states.totemKeepQty = math.floor(v)
    saveSettings()
end)
SacTab:Label("Default tier = Galactic (dropdown). Only weapons whose OneIn falls in that band are used; status shows inv name vs string sent to TotemConfirm.")
totemStatusLbl = SacTab:Label("Totem: —")
local totemLastLbl = SacTab:Label("Totem last: —")
SacTab:Label("Totem auto safety: waits 30s once when hourly CD reaches 0 to avoid stale re-lock text.")
SacTab:Button("📊", "Totem Status", "Refresh progress / cooldown / AP max", C.accent, function()
    updateTotemStatusLbl()
    SLbl.Text = "Totem status updated"
end)
SacTab:Button("🕯️", "Totem: sacrifice 1 (next in color)", "Cycles all weapons in Totem color + keep; uses each inventory name on the remote", C.gold, function()
    local ok, why = totemExecuteNext()
    updateTotemStatusLbl()
    if ok then
        totemLastLbl.Set("Totem last: " .. tostring(why))
        SLbl.Text = "Totem: " .. tostring(why)
    else
        local msg = ({
            cd = "On cooldown",
            local_cap = "At cycle cap (wait CD or refresh)",
            no_weapon = "No weapon (enable Totem By color or refresh inv)",
            no_totem_tick = "Tick weapon(s) in the list that pass Totem color — or turn off Totem only ✓ names",
            server_reject = "Server rejected this weapon — skipped 3m; try others (Cobalt name may differ from auto pick)",
            throttle = string.format("Min %.1fs between TotemConfirm calls (wait)", TOTEM_MIN_INVOKE_GAP_SEC),
            fail = "TotemConfirm error (remote missing or InvokeServer threw)",
        })[why] or tostring(why)
        totemLastLbl.Set("Totem last: " .. msg)
        SLbl.Text = "Totem: " .. msg
    end
end)
local totemAutoToggle = SacTab:Toggle("Auto Totem", "Fast tick + gap between invokes; Totem color tier (default Galactic), keep, Rank sort, TotemConfirm — saved", states.autoTotem, function(on)
    states.autoTotem = on == true
    saveSettings()
    SLbl.Text = on and "Auto Totem ON" or "Auto Totem OFF"
end)

SacTab:Section("By Name — tick rows")
SacTab:Label("Selections are saved. Empty list until Refresh.")

local function sacNextLayoutOrder()
    local m = 0
    for _, ch in ipairs(SacTab._page:GetChildren()) do
        if ch:IsA("GuiObject") and ch.LayoutOrder > m then m = ch.LayoutOrder end
    end
    return m + 1
end

local sacListCard = Instance.new("Frame", SacTab._page)
sacListCard.BackgroundColor3 = C.card
sacListCard.BorderSizePixel = 0
sacListCard.Size = UDim2.new(1, -10, 0, 0)
sacListCard.AutomaticSize = Enum.AutomaticSize.Y
sacListCard.LayoutOrder = sacNextLayoutOrder()
Instance.new("UICorner", sacListCard).CornerRadius = UDim.new(0, 10)
Instance.new("UIStroke", sacListCard).Color = C.border
local sacCardPad = Instance.new("UIPadding", sacListCard)
sacCardPad.PaddingBottom = UDim.new(0, 8)

sacWeaponScroll = Instance.new("ScrollingFrame", sacListCard)
sacWeaponScroll.BackgroundColor3 = Color3.fromRGB(12, 16, 24)
sacWeaponScroll.Size = UDim2.new(1, -16, 0, 140)
sacWeaponScroll.Position = UDim2.new(0, 8, 0, 8)
sacWeaponScroll.BorderSizePixel = 0
sacWeaponScroll.ScrollBarThickness = 3
sacWeaponScroll.ScrollBarImageColor3 = C.accent
sacWeaponScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
sacWeaponScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
Instance.new("UICorner", sacWeaponScroll).CornerRadius = UDim.new(0, 6)
local sacListLayout = Instance.new("UIListLayout", sacWeaponScroll)
sacListLayout.Padding = UDim.new(0, 2)
sacListLayout.SortOrder = Enum.SortOrder.LayoutOrder
sacListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    local inner = math.min(sacListLayout.AbsoluteContentSize.Y + 6, 240)
    sacWeaponScroll.Size = UDim2.new(1, -16, 0, math.max(120, inner))
end)

task.defer(function()
    pcall(function()
        if sacFilterColorToggle and sacFilterColorToggle.Set then
            sacFilterColorToggle.Set(states.sacFilterColor)
        end
        if sacFilterNameToggle and sacFilterNameToggle.Set then
            sacFilterNameToggle.Set(states.sacFilterName)
        end
        if sacRarityDropdown and sacRarityDropdown.Set then
            sacRarityDropdown.Set(states.sacRarityCapIdx)
        end
        if sacKeepSlider and sacKeepSlider.Set then
            sacKeepSlider.Set(math.clamp(states.sacKeepQty, 0, 999), true)
        end
        if sacAutoToggle and sacAutoToggle.Set then
            sacAutoToggle.Set(states.autoSacrifice)
        end
        if totemAutoToggle and totemAutoToggle.Set then
            totemAutoToggle.Set(states.autoTotem)
        end
        if totemFilterColorToggle and totemFilterColorToggle.Set then
            totemFilterColorToggle.Set(states.totemFilterColor)
        end
        if totemOnlyTickedToggle and totemOnlyTickedToggle.Set then
            totemOnlyTickedToggle.Set(states.totemOnlyTickedNames)
        end
        if totemRarityDropdown and totemRarityDropdown.Set then
            totemRarityDropdown.Set(states.totemRarityCapIdx)
        end
        if totemKeepSlider and totemKeepSlider.Set then
            totemKeepSlider.Set(math.clamp(states.totemKeepQty, 0, 999), true)
        end
        sacStatusLbl.Set(states.autoSacrifice and "Auto: ON · every 1.5s" or "Auto: OFF · idle")
        updateTotemStatusLbl()
    end)
end)

task.defer(function()
    task.wait(2)
    if GEN ~= _G.MeleeRNG_Gen then return end
    pcall(refreshSacInventory)
end)

addThread(task.spawn(function()
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        if not states.autoSacrifice then task.wait(1); continue end
        task.wait(1.5)
        if not sacAnyFilterOn() then
            sacStatusLbl.Set("Auto: ON — enable ≥1 filter")
            continue
        end
        local sacrificed, skipped = 0, 0
        pcall(function()
            _sacAssetCache = {}
            local raw = invokeR("GetWeaponsInv")
            _sacInv = {}
            if type(raw) == "table" then
                local function pushEntry(e)
                    local w = normSacWeapon(e)
                    if w and w.qty > 0 then _sacInv[#_sacInv + 1] = w end
                end
                if raw[1] ~= nil then
                    for _, e in ipairs(raw) do pushEntry(e) end
                else
                    for _, e in pairs(raw) do pushEntry(e) end
                end
            end
            sacEnrichFromAssets()
            rebuildSacWeaponRows()
            local totalQty = 0
            for _, w in ipairs(_sacInv) do totalQty = totalQty + w.qty end
            sacInvLbl.Set(string.format("Inv: %d types | %d total qty", #_sacInv, totalQty))

            local keep = math.max(0, math.floor(tonumber(states.sacKeepQty) or 0))
            local candidates = sacBuildHighestEligibleCandidates(keep)
            skipped = math.max(0, #_sacInv - #candidates)

            if #candidates == 0 then
                if states.sacFilterColor and not states.sacFilterName then
                    local cap = sacCapOneInForDropdownIdx(states.sacRarityCapIdx)
                    sacLastLbl.Set("Last: no extra weapon with OneIn ≤ " .. tostring(cap))
                else
                    sacLastLbl.Set("Last: no eligible extra weapon")
                end
            else
                -- Sacrifice only the best current candidate per tick. If the server rejects it,
                -- fall down to the next-highest eligible OneIn in the same inventory snapshot.
                for _, w in ipairs(candidates) do
                    local toSac = math.max(0, (tonumber(w.qty) or 0) - keep)
                    if toSac > 0 then
                        local res = invokeR("FountainSacrifice", w.name, w.type, toSac)
                        if res == false then
                            skipped = skipped + 1
                        else
                            sacrificed = 1
                            local oi = (w.oneIn and w.oneIn < 1e15) and tostring(math.floor(w.oneIn)) or "?"
                            sacLastLbl.Set("Last: highest ≤ cap → " .. w.name .. " ×" .. tostring(toSac) .. " (OneIn=" .. oi .. ")")
                            break
                        end
                    else
                        skipped = skipped + 1
                    end
                end
            end
        end)
        sacStatusLbl.Set(string.format("Auto: ON · sacrificed highest %d type · skipped %d · next 1.5s", sacrificed, skipped))
    end
end))

addThread(task.spawn(function()
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        task.wait(1)
        updateTotemStatusLbl()
    end
end))

addThread(task.spawn(function()
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        if not states.autoTotem then task.wait(1); continue end
        task.wait(TOTEM_AUTO_TICK_SEC)
        if not states.totemFilterColor then
            if totemLastLbl then totemLastLbl.Set("Totem auto: turn on Totem: By color (OneIn)") end
            continue
        end
        local ok, why = totemExecuteNext()
        if totemLastLbl then
            if ok then
                totemLastLbl.Set("Totem last: " .. tostring(why))
            elseif why == "no_weapon" or why == "no_totem_tick" or why == "fail" or why == "wait" or why == "server_reject" or why == "throttle" then
                totemLastLbl.Set("Totem auto: " .. tostring(why))
            end
        end
        updateTotemStatusLbl()
    end
end))

-- Totem: server cap + max from RS.Remotes.SendNotification (message, "ERROR")
addThread(task.spawn(function()
    local remotesFolder = RS:WaitForChild("Remotes", 60)
    if not remotesFolder then return end
    local sn = remotesFolder:WaitForChild("SendNotification", 90)
    if not sn then return end
    pcall(function()
        if sn:IsA("RemoteEvent") or sn.ClassName == "UnreliableRemoteEvent" then
            addConn(sn.OnClientEvent:Connect(onTotemSendNotification))
        end
    end)
end))

local MiscTab = Win:Tab("⚙️", "Misc")

-- --------------------------------------------------------------------------
-- Misc tab — Hitbox pulse (cache parts; Touched-only, no HitMob batch)
-- BIG 500 ≫ 100k (~5.5x KPM); tiny 0.01. Data-driven constants below.
-- Tiny 0.01 ≫ 0.05 (~4x KPM, Test 9). CanTouch must stay true (Test 7). Combined ~40k+ KPM vs ~22k before tuning.
local HITBOX_BIG_DEFAULT  = 500   -- map-tuned BIG (vs 100k+ = overlap hell)
local HITBOX_BIG_LIGHT    = 350   -- low-lag preset: smaller BIG footprint
local HITBOX_TINY_STUDS   = 0.01
local hitboxExpanded  = false
local hitboxOrigSizes = {}
local _pulseConn      = nil
local _TINY_V         = Vector3.new(HITBOX_TINY_STUDS, HITBOX_TINY_STUDS, HITBOX_TINY_STUDS)
local _pulseActive    = false
local _pulsePhase     = false
local _hitboxCache    = {}
-- Reused every pulse (avoids Vector3.new + table churn)
local _pulseBigVec    = Vector3.new(hitboxSize, hitboxSize, hitboxSize)
local HITBOX_DUTY_MAX    = 12

MoveTab:Section("Hitbox Pulse")
MoveTab:Label("Summary (map-tested): BIG ≈500 studs ≫ 100k for KPM (less physics overlap). Tiny = 0.01 studs ≫ 0.05. CanTouch must stay on. Design target ~40k+ KPM vs ~22k before tuning.")
MoveTab:Label("How it works:")
MoveTab:Label("• Kills: client Touched when Hitbox size changes — this script does not spam HitMob.")
MoveTab:Label("• Duty N: 1 Heartbeat BIG, then N−1 tiny. Lower N = more flips = more Touched (and more work when BIG).")
MoveTab:Label("• Slider = BIG edge length (studs). Tiny size is fixed in code at 0.01 (not slider).")
MoveTab:Label("• Hitbox list rebuilds only when needed: weapon-folder child count changes (watcher ~2s) or a cached part loses Parent — no periodic full rescan.")
MoveTab:Label("Lag: raise duty and/or use 🐢 preset; avoid cranking BIG past what the map needs. Off in menus.")

local hitboxDutySlider, hitboxRadiusSlider

hitboxDutySlider = MoveTab:Slider("Big phase duty (1 big / N heartbeats)", "One frame BIG per cycle, rest tiny. N=2 ≈ half the Heartbeats BIG. Higher N = calmer physics, fewer Touched edges.",
    {min=2, max=HITBOX_DUTY_MAX, default=math.clamp(math.floor(tonumber(states.hitboxDutyCycle) or 2), 2, HITBOX_DUTY_MAX),
     format=function(v) return "1 big / "..tostring(math.floor(v)) end},
    function(v)
        states.hitboxDutyCycle = math.clamp(math.floor(v), 2, HITBOX_DUTY_MAX)
        saveSettings()
    end)

hitboxRadiusSlider = MoveTab:Slider("BIG size (studs)", "Edge length of the huge box each duty BIG frame. ~500 matches tested sweet spot; very large values often hurt KPM here (overlap pairs).",
    {min=10, max=100000, default=hitboxSize,
     format=function(v) return math.floor(v).." studs" end},
    function(v)
        hitboxSize = math.floor(v)
        _pulseBigVec = Vector3.new(hitboxSize, hitboxSize, hitboxSize)
        saveSettings()
    end)

local function applyHitboxPulsePreset(title, duty, radius)
    local d = math.clamp(math.floor(duty), 2, HITBOX_DUTY_MAX)
    local r = math.clamp(math.floor(radius), 10, 100000) -- max still 100k if you override via slider
    if hitboxDutySlider and type(hitboxDutySlider.Set) == "function"
        and hitboxRadiusSlider and type(hitboxRadiusSlider.Set) == "function" then
        hitboxDutySlider.Set(d)
        hitboxRadiusSlider.Set(r)
    else
        states.hitboxDutyCycle = d
        hitboxSize = r
        _pulseBigVec = Vector3.new(r, r, r)
    end
    saveSettings()
    SLbl.Text = "⚡ Preset: " .. title
end

MoveTab:Label("Presets — tap to save duty + BIG size (tiny stays 0.01):")
MoveTab:Button("⚡", "Max farm — duty 2", "BIG 500 · highest flip rate + map-tuned reach", C.green, function()
    applyHitboxPulsePreset("Max farm — duty 2", 2, HITBOX_BIG_DEFAULT)
end)
MoveTab:Button("⚖️", "Balanced — duty 5", "BIG 500 · same reach as ⚡, BIG only 1/5 Heartbeats (lighter physics)", C.accent, function()
    applyHitboxPulsePreset("Balanced — duty 5", 5, HITBOX_BIG_DEFAULT)
end)
MoveTab:Button("🐢", "Low lag — duty 10", "BIG 350 · smaller BIG footprint + rare BIG frames", C.sub, function()
    applyHitboxPulsePreset("Low lag — duty 10", 10, HITBOX_BIG_LIGHT)
end)

-- workspace.[PlayerName] holds the player's equipped weapon models
-- Each weapon model contains a BasePart named "Hitbox"
local function getPlayerWeaponFolder()
    return workspace:FindFirstChild(LP.Name)
end

local function restoreHitboxes()
    for hb, origSize in pairs(hitboxOrigSizes) do
        pcall(function()
            if hb and hb.Parent then hb.Size = origSize end
        end)
    end
    hitboxOrigSizes = {}
end

local function rebuildHitboxCache()
    _hitboxCache = {}
    local folder = getPlayerWeaponFolder()
    if not folder then return end
    for _, weapon in ipairs(folder:GetChildren()) do
        if weapon:IsA("Model") then
            for _, desc in pairs(weapon:GetDescendants()) do
                if desc:IsA("BasePart") and desc.Name == "Hitbox" then
                    if not hitboxOrigSizes[desc] then
                        hitboxOrigSizes[desc] = desc.Size
                    end
                    desc.CanTouch = true -- Test 7: false ~8.8k vs true ~37.6k KPM — required for Touched
                    _hitboxCache[#_hitboxCache+1] = desc
                end
            end
        end
    end
    _hitboxCacheDirty = false
end

-- ── Performance (client): hide spinning weapon models + workspace VFX ───────
-- Game puts equipped weapon clones under workspace[Player.Name] (see hitbox cache above).
-- Dump references WeaponsClientController.ToggleWeaponVisibility but bytecode didn’t decompile.
local _perfPartLTM = {} -- [BasePart] = prior LocalTransparencyModifier while hidden
local _perfEffOn = {}   -- [ParticleEmitter|Trail|Beam] = prior Enabled while hidden
local _perfLastEffectsHidden = false
local _perfFxAcc = 0    -- throttle workspace:GetDescendants() sweeps (~every 5×0.12s)
local _perfLootLTM = {} -- loot drop parts (separate from weapon LTM map)
local _perfMobManaLTM = {} -- mob mana pickup models (workspace; MobsClientController Mana template)
local _perfMobManaFx = {} -- ParticleEmitter|Trail|Beam etc. under mana models — prior Enabled
local _perfHitboxVisLTM = {} -- Hitbox BaseParts under your weapon folder — prior LocalTransparencyModifier
local _perfSoundVol = {} -- [Sound] = prior Volume
local _perfSoundAcc = 0
local _perfSavedGlobalShadows = nil -- bool | nil
local _perfSavedTechnology = nil    -- Enum.Technology | nil
local _perfSavedQualityLevel = nil          -- Enum.SavedQualitySetting | nil
local _perfSavedGraphicsQualityLevel = nil  -- number | nil
local _perfCharLTM = {} -- [BasePart] = prior LTM for other players’ characters

local function perfApplyLowGraphicsQuality(on)
    local ok, ugs = pcall(function()
        return UserSettings():GetService("UserGameSettings")
    end)
    if not ok or ugs == nil then return end
    if on then
        if _perfSavedQualityLevel == nil then
            pcall(function() _perfSavedQualityLevel = ugs.SavedQualityLevel end)
        end
        if _perfSavedGraphicsQualityLevel == nil then
            pcall(function()
                local v = ugs.GraphicsQualityLevel
                if type(v) == "number" then _perfSavedGraphicsQualityLevel = v end
            end)
        end
        -- Roblox uses QualityLevel01 … QualityLevel21 (01 = lowest). Some builds omit leading zero.
        pcall(function()
            local e = Enum.SavedQualitySetting
            local low = e.QualityLevel01 or e.QualityLevel02 or e.QualityLevel03
            if low then ugs.SavedQualityLevel = low end
        end)
        pcall(function() ugs.GraphicsQualityLevel = 1 end)
    else
        if _perfSavedQualityLevel ~= nil then
            local v = _perfSavedQualityLevel
            _perfSavedQualityLevel = nil
            pcall(function() ugs.SavedQualityLevel = v end)
        end
        if _perfSavedGraphicsQualityLevel ~= nil then
            local v = _perfSavedGraphicsQualityLevel
            _perfSavedGraphicsQualityLevel = nil
            pcall(function() ugs.GraphicsQualityLevel = v end)
        end
    end
end

local function perfCleanupStaleCharKeys()
    for p in pairs(_perfCharLTM) do
        if not (p and p.Parent) then _perfCharLTM[p] = nil end
    end
end

local function perfSweepOtherCharacters(hide)
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then
            local ch = plr.Character
            if ch then
                for _, d in ipairs(ch:GetDescendants()) do
                    if d:IsA("BasePart") then
                        if hide then
                            if _perfCharLTM[d] == nil then
                                _perfCharLTM[d] = d.LocalTransparencyModifier
                            end
                            d.LocalTransparencyModifier = 1
                        else
                            local prev = _perfCharLTM[d]
                            if prev ~= nil then
                                d.LocalTransparencyModifier = prev
                                _perfCharLTM[d] = nil
                            end
                        end
                    end
                end
            end
        end
    end
end

local function perfApplyShadows(disable)
    if disable then
        if _perfSavedGlobalShadows == nil then
            _perfSavedGlobalShadows = Lighting.GlobalShadows
        end
        Lighting.GlobalShadows = false
    else
        if _perfSavedGlobalShadows ~= nil then
            Lighting.GlobalShadows = _perfSavedGlobalShadows
            _perfSavedGlobalShadows = nil
        end
    end
end

local function perfApplyCompatLighting(on)
    if on then
        if _perfSavedTechnology == nil then
            _perfSavedTechnology = Lighting.Technology
        end
        pcall(function()
            Lighting.Technology = Enum.Technology.Compatibility
        end)
    else
        if _perfSavedTechnology ~= nil then
            local t = _perfSavedTechnology
            _perfSavedTechnology = nil
            pcall(function() Lighting.Technology = t end)
        end
    end
end

local function perfCleanupStaleLootKeys()
    for p in pairs(_perfLootLTM) do
        if not (p and p.Parent) then _perfLootLTM[p] = nil end
    end
end

local function perfSweepLootDrops(hide)
    local loot = workspace:FindFirstChild("Loot")
    if not loot then return end
    local function applyPart(d)
        if not d:IsA("BasePart") then return end
        if hide then
            if _perfLootLTM[d] == nil then
                _perfLootLTM[d] = d.LocalTransparencyModifier
            end
            d.LocalTransparencyModifier = 1
        else
            local prev = _perfLootLTM[d]
            if prev ~= nil then
                d.LocalTransparencyModifier = prev
                _perfLootLTM[d] = nil
            end
        end
    end
    for _, ch in ipairs(loot:GetChildren()) do
        if ch:IsA("Model") then
            for _, d in ipairs(ch:GetDescendants()) do applyPart(d) end
        else
            applyPart(ch)
        end
    end
end

local function perfRestoreAllLoot()
    perfSweepLootDrops(false)
    perfCleanupStaleLootKeys()
end

local function perfCleanupStaleMobManaKeys()
    for p in pairs(_perfMobManaLTM) do
        if not (p and p.Parent) then _perfMobManaLTM[p] = nil end
    end
    for inst in pairs(_perfMobManaFx) do
        if not (inst and inst.Parent) then _perfMobManaFx[inst] = nil end
    end
end

local function perfCleanupStaleHitboxVisKeys()
    for p in pairs(_perfHitboxVisLTM) do
        if not (p and p.Parent) then _perfHitboxVisLTM[p] = nil end
    end
end

-- MobsClientController clones script.Mana to workspace (Main part + Attachment.Shadow / Trail under Main).
local function isMobManaPickupModel(m)
    if not m:IsA("Model") then return false end
    if m.Parent ~= workspace then return false end
    local main = m:FindFirstChild("Main")
    if not main or not main:IsA("BasePart") then return false end
    if m.Name == "Mana" then
        return true
    end
    local att = main:FindFirstChild("Attachment")
    if att and att:FindFirstChild("Shadow") then
        return true
    end
    return main:FindFirstChild("Shadow") ~= nil
end

local function perfMobManaFxDisable(inst, hide)
    if hide then
        if _perfMobManaFx[inst] == nil then
            _perfMobManaFx[inst] = inst.Enabled
        end
        inst.Enabled = false
    else
        local was = _perfMobManaFx[inst]
        if was ~= nil then
            pcall(function() inst.Enabled = was end)
            _perfMobManaFx[inst] = nil
        end
    end
end

local function perfSweepMobManaOrbs(hide)
    for _, ch in ipairs(workspace:GetChildren()) do
        if ch:IsA("Model") and isMobManaPickupModel(ch) then
            for _, d in ipairs(ch:GetDescendants()) do
                if d:IsA("BasePart") then
                    if hide then
                        if _perfMobManaLTM[d] == nil then
                            _perfMobManaLTM[d] = d.LocalTransparencyModifier
                        end
                        d.LocalTransparencyModifier = 1
                    else
                        local prev = _perfMobManaLTM[d]
                        if prev ~= nil then
                            d.LocalTransparencyModifier = prev
                            _perfMobManaLTM[d] = nil
                        end
                    end
                elseif d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam")
                    or d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles") then
                    perfMobManaFxDisable(d, hide)
                end
            end
        end
    end
end

local function perfRestoreMobManaOrbs()
    perfSweepMobManaOrbs(false)
    perfCleanupStaleMobManaKeys()
end

-- White “rings” / range visuals: weapon models use a BasePart named Hitbox (still needs Touched — only hide rendering).
local function perfSweepHitboxVisuals(hide)
    local folder = workspace:FindFirstChild(LP.Name)
    if not folder then return end
    for _, weapon in ipairs(folder:GetChildren()) do
        if weapon:IsA("Model") then
            for _, d in ipairs(weapon:GetDescendants()) do
                if d:IsA("BasePart") and d.Name == "Hitbox" then
                    if hide then
                        if _perfHitboxVisLTM[d] == nil then
                            _perfHitboxVisLTM[d] = d.LocalTransparencyModifier
                        end
                        d.LocalTransparencyModifier = 1
                    else
                        local prev = _perfHitboxVisLTM[d]
                        if prev ~= nil then
                            d.LocalTransparencyModifier = prev
                            _perfHitboxVisLTM[d] = nil
                        end
                    end
                end
            end
        end
    end
end

local function perfRestoreHitboxVisuals()
    perfSweepHitboxVisuals(false)
    perfCleanupStaleHitboxVisKeys()
end

local function perfRestoreAllWorldSounds()
    for snd, vol in pairs(_perfSoundVol) do
        pcall(function()
            if snd.Parent then snd.Volume = vol end
        end)
    end
    for k in pairs(_perfSoundVol) do _perfSoundVol[k] = nil end
end

local function perfSweepWorldSoundsMute()
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("Sound") then
            if _perfSoundVol[d] == nil then
                _perfSoundVol[d] = d.Volume
            end
            d.Volume = 0
        end
    end
end

local function perfCleanupStalePartKeys()
    for p in pairs(_perfPartLTM) do
        if not (p and p.Parent) then _perfPartLTM[p] = nil end
    end
end

local function perfSweepWeaponFolder(folder, hide)
    if not folder then return end
    for _, m in ipairs(folder:GetChildren()) do
        if m:IsA("Model") then
            for _, d in ipairs(m:GetDescendants()) do
                if d:IsA("BasePart") then
                    if hide then
                        if _perfPartLTM[d] == nil then
                            _perfPartLTM[d] = d.LocalTransparencyModifier
                        end
                        d.LocalTransparencyModifier = 1
                    else
                        local prev = _perfPartLTM[d]
                        if prev ~= nil then
                            d.LocalTransparencyModifier = prev
                            _perfPartLTM[d] = nil
                        end
                    end
                end
            end
        end
    end
end

local function perfSweepEffectsHide()
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") then
            if _perfEffOn[d] == nil then
                _perfEffOn[d] = d.Enabled
            end
            d.Enabled = false
        end
    end
end

local function perfRestoreEffects()
    for inst, was in pairs(_perfEffOn) do
        pcall(function()
            if inst and inst.Parent then inst.Enabled = was end
        end)
    end
    for k in pairs(_perfEffOn) do _perfEffOn[k] = nil end
end

local function perfRestoreAllWeaponFolders()
    perfSweepWeaponFolder(workspace:FindFirstChild(LP.Name), false)
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= LP then
            perfSweepWeaponFolder(workspace:FindFirstChild(pl.Name), false)
        end
    end
    perfCleanupStalePartKeys()
end

local _perfLastSoundsMuted = false
local _perfLastOwnWeaponsHidden = false
local _perfLastOtherWeaponsHidden = false
local _perfLastLootHidden = false
local _perfLastMobManaHidden = false
local _perfLastHitboxHidden = false
local _perfLastCharsHidden = false
local _perfLootAcc = 0
local _perfMobManaAcc = 0
local _perfCharAcc = 0
local _perfHitboxAcc = 0

addThread(task.spawn(function()
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        local ow = states.perfHideOtherWeapons
        local sw = states.perfHideOwnWeapons
        local ef = states.perfHideAllEffects
        local lo = states.perfHideLootDrops
        local mm = states.perfHideMobManaOrbs
        local hv = states.perfHideHitboxVisuals
        local ws = states.perfMuteWorldSounds
        local oc = states.perfHideOtherCharacters
        local playersNow = Players:GetPlayers()
        local hadWeaponHide = _perfLastOwnWeaponsHidden or _perfLastOtherWeaponsHidden

        if not ow and not sw and not ef and not lo and not mm and not hv and not ws and not oc then
            if _perfLastEffectsHidden then
                perfRestoreEffects()
                _perfLastEffectsHidden = false
            end
            if _perfLastOwnWeaponsHidden then
                perfSweepWeaponFolder(workspace:FindFirstChild(LP.Name), false)
                _perfLastOwnWeaponsHidden = false
            end
            if _perfLastOtherWeaponsHidden then
                for _, plr in ipairs(playersNow) do
                    if plr ~= LP then
                        perfSweepWeaponFolder(workspace:FindFirstChild(plr.Name), false)
                    end
                end
                _perfLastOtherWeaponsHidden = false
            end
            if hadWeaponHide then
                perfCleanupStalePartKeys()
            end
            if _perfLastLootHidden then
                perfRestoreAllLoot()
                _perfLastLootHidden = false
            end
            if _perfLastMobManaHidden then
                perfRestoreMobManaOrbs()
                _perfLastMobManaHidden = false
            end
            if _perfLastHitboxHidden then
                perfRestoreHitboxVisuals()
                _perfLastHitboxHidden = false
            end
            if _perfLastCharsHidden then
                perfSweepOtherCharacters(false)
                perfCleanupStaleCharKeys()
                _perfLastCharsHidden = false
            end
            if _perfLastSoundsMuted then
                perfRestoreAllWorldSounds()
                _perfLastSoundsMuted = false
            end
            _perfFxAcc = 0
            _perfSoundAcc = 0
            _perfLootAcc = 0
            _perfMobManaAcc = 0
            _perfCharAcc = 0
            _perfHitboxAcc = 0
            task.wait(0.5)
            continue
        end

        if ow or sw or (hv and not sw) then
            RunService.Heartbeat:Wait()
        else
            task.wait(0.12)
        end

        if sw then
            perfSweepWeaponFolder(workspace:FindFirstChild(LP.Name), true)
            _perfLastOwnWeaponsHidden = true
        elseif _perfLastOwnWeaponsHidden then
            perfSweepWeaponFolder(workspace:FindFirstChild(LP.Name), false)
            _perfLastOwnWeaponsHidden = false
        end

        if ow then
            for _, plr in ipairs(playersNow) do
                if plr ~= LP then
                    perfSweepWeaponFolder(workspace:FindFirstChild(plr.Name), true)
                end
            end
            _perfLastOtherWeaponsHidden = true
        elseif _perfLastOtherWeaponsHidden then
            for _, plr in ipairs(playersNow) do
                if plr ~= LP then
                    perfSweepWeaponFolder(workspace:FindFirstChild(plr.Name), false)
                end
            end
            _perfLastOtherWeaponsHidden = false
        end

        if sw or ow or _perfLastOwnWeaponsHidden or _perfLastOtherWeaponsHidden then
            perfCleanupStalePartKeys()
        end

        if ef then
            _perfFxAcc = _perfFxAcc + 1
            if _perfFxAcc >= 8 then
                _perfFxAcc = 0
                perfSweepEffectsHide()
            end
            _perfLastEffectsHidden = true
        elseif _perfLastEffectsHidden then
            _perfFxAcc = 0
            perfRestoreEffects()
            _perfLastEffectsHidden = false
        end

        if lo then
            _perfLootAcc = _perfLootAcc + 1
            if _perfLootAcc >= 2 then
                _perfLootAcc = 0
                perfSweepLootDrops(true)
                perfCleanupStaleLootKeys()
            end
            _perfLastLootHidden = true
        elseif _perfLastLootHidden then
            _perfLootAcc = 0
            perfRestoreAllLoot()
            _perfLastLootHidden = false
        end

        if mm then
            _perfMobManaAcc = _perfMobManaAcc + 1
            if _perfMobManaAcc >= 2 then
                _perfMobManaAcc = 0
                perfSweepMobManaOrbs(true)
                perfCleanupStaleMobManaKeys()
            end
            _perfLastMobManaHidden = true
        elseif _perfLastMobManaHidden then
            _perfMobManaAcc = 0
            perfRestoreMobManaOrbs()
            _perfLastMobManaHidden = false
        end

        if hv and not sw then
            _perfHitboxAcc = _perfHitboxAcc + 1
            if _perfHitboxAcc >= 3 then
                _perfHitboxAcc = 0
                perfSweepHitboxVisuals(true)
                perfCleanupStaleHitboxVisKeys()
            end
            _perfLastHitboxHidden = true
        elseif _perfLastHitboxHidden then
            _perfHitboxAcc = 0
            perfRestoreHitboxVisuals()
            _perfLastHitboxHidden = false
        end

        if ws then
            _perfSoundAcc = _perfSoundAcc + 1
            if _perfSoundAcc >= 15 then
                _perfSoundAcc = 0
                perfSweepWorldSoundsMute()
            end
            _perfLastSoundsMuted = true
        elseif _perfLastSoundsMuted then
            perfRestoreAllWorldSounds()
            _perfLastSoundsMuted = false
            _perfSoundAcc = 0
        end

        if oc then
            _perfCharAcc = _perfCharAcc + 1
            if _perfCharAcc >= 3 then
                _perfCharAcc = 0
                perfSweepOtherCharacters(true)
                perfCleanupStaleCharKeys()
            end
            _perfLastCharsHidden = true
        elseif _perfLastCharsHidden then
            _perfCharAcc = 0
            perfSweepOtherCharacters(false)
            perfCleanupStaleCharKeys()
            _perfLastCharsHidden = false
        end
    end
end))

-- Equip/unequip: child count changes → dirty → next Heartbeat rebuildHitboxCache
addThread(task.spawn(function()
    local lastCount = 0
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        task.wait(2)
        local folder = getPlayerWeaponFolder()
        local count = folder and #folder:GetChildren() or 0
        if count ~= lastCount then
            lastCount = count
            _hitboxCacheDirty = true
        end
    end
end))

local function setHitboxPulse(on)
    _pulseActive = on
    hitboxExpanded = on
    if on then
        _pulseBigVec = Vector3.new(hitboxSize, hitboxSize, hitboxSize)
        _hitboxCacheDirty = true
        if _pulseConn then _pulseConn:Disconnect() end

        local _dutyTick = 0

        _pulseConn = RunService.Heartbeat:Connect(function()
            if GEN ~= _G.MeleeRNG_Gen or not _pulseActive then
                if _pulseConn then _pulseConn:Disconnect(); _pulseConn = nil end
                return
            end

            if _hitboxCacheDirty then
                rebuildHitboxCache()
            end

            -- Duty cycle: BIG only 1 frame per N (rest TINY). Touched fires on size change.
            _dutyTick = _dutyTick + 1
            local duty = math.clamp(math.floor(tonumber(states.hitboxDutyCycle) or 2), 2, HITBOX_DUTY_MAX)
            _pulsePhase = ((_dutyTick - 1) % duty) == 0
            local newSize = _pulsePhase and _pulseBigVec or _TINY_V
            local hCache = _hitboxCache
            local nh = #hCache
            for i = 1, nh do
                local hb = hCache[i]
                if hb and hb.Parent then
                    if hb.Size ~= newSize then hb.Size = newSize end
                else
                    _hitboxCacheDirty = true
                end
            end
        end)
        addConn(_pulseConn)
        rebuildHitboxCache()
        SLbl.Text = string.format("⚡ Pulse ON | %.0f studs | %d hitboxes | duty 1/%d (Touched only)", hitboxSize, #_hitboxCache, math.clamp(math.floor(tonumber(states.hitboxDutyCycle) or 2), 2, HITBOX_DUTY_MAX))
    else
        if _pulseConn then _pulseConn:Disconnect(); _pulseConn = nil end
        for i = 1, #_hitboxCache do
            local hb = _hitboxCache[i]
            if hb and hb.Parent and hitboxOrigSizes[hb] then
                hb.Size = hitboxOrigSizes[hb]
            end
        end
        _hitboxCache = {}
        SLbl.Text = "Pulse OFF — hitboxes restored"
    end
end

local hitboxPulseToggle = MoveTab:Toggle("⚡ Hitbox Pulse", "BIG/tiny duty cycle on weapon Hitboxes (tiny = 0.01). Kills via Touched — no HitMob batch in this loop.", states.hitboxPulse, function(on)
    states.hitboxPulse = on
    setHitboxPulse(on)
    saveSettings()
end)

task.defer(function()
    if states.hitboxPulse then
        setHitboxPulse(true)
        pcall(function()
            if hitboxPulseToggle and hitboxPulseToggle.Set then
                hitboxPulseToggle.Set(true)
            end
        end)
    end
end)

MoveTab:Button("🔍", "Print Hitbox Sizes", "Lists all weapons and current Hitbox sizes", C.sub, function()
    local folder = getPlayerWeaponFolder()
    if not folder then SLbl.Text = "⚠ workspace." .. LP.Name .. " not found"; return end
    local count = 0
    for _, weapon in ipairs(folder:GetChildren()) do
        if weapon:IsA("Model") then
            for _, desc in pairs(weapon:GetDescendants()) do
                if desc:IsA("BasePart") and desc.Name == "Hitbox" then
                    count = count + 1
                    print(string.format("[MeleeRNG] Hitbox: %-30s  Size: %.1f x %.1f x %.1f",
                        weapon.Name, desc.Size.X, desc.Size.Y, desc.Size.Z))
                end
            end
        end
    end
    if count == 0 then print("[MeleeRNG] No Hitbox parts found in workspace." .. LP.Name) end
    SLbl.Text = count .. " hitboxes found — check output"
end)

MoveTab:Section("Walk Speed")
MoveTab:Slider("Walk Speed", "Default 16 · Max 250", {min=0, max=250, default=walkSpeedVal}, function(v)
    walkSpeedVal = math.floor(v); saveSettings()
    local h = getHuman(); if h then h.WalkSpeed = walkSpeedVal end
end)

MoveTab:Section("Hacks")
MoveTab:Toggle("🚀 Infinite Jump", "Jump while airborne", states.infJump, function(on)
    states.infJump = on; saveSettings()
end)
MoveTab:Toggle("👻 No Clip", "Walk through walls", states.noclip, function(on)
    states.noclip = on; saveSettings()
end)
MoveTab:Toggle("🛡️ God Mode", "Lock health at max", states.godMode, function(on)
    states.godMode = on; saveSettings()
end)
MoveTab:Toggle("🦅 Fly", "WASD + E/Q to go up/down", states.fly, function(on)
    states.fly = on; saveSettings()
    if not on then
        if flyBV then flyBV:Destroy(); flyBV = nil end
        if flyBG then flyBG:Destroy(); flyBG = nil end
    end
end)
MoveTab:Toggle("⏱️ Anti AFK", "Game AFKScript is disabled on load (no kick timer). Optional: every 60s synthetic click if you still want input-based backup.", states.antiAfk, function(on)
    states.antiAfk = on; saveSettings()
end)
MoveTab:Toggle("💡 Full Bright", "Max ambient light, remove fog", states.fullBright, function(on)
    states.fullBright = on; saveSettings()
end)
local autoEquipBestToggle = MoveTab:Toggle("⚔️ Auto Equip Best", "Remotes.EquipBest:FireServer() every 10s while ON — same as the in-game Equip Best button (Weapons UI)", states.autoEquipBest, function(on)
    states.autoEquipBest = on == true
    saveSettings()
    SLbl.Text = on and "Auto Equip Best ON (every 10s)" or "Auto Equip Best OFF"
end)
task.defer(function()
    pcall(function()
        if autoEquipBestToggle and autoEquipBestToggle.Set then
            autoEquipBestToggle.Set(states.autoEquipBest)
        end
    end)
end)

MoveTab:Section("Actions")
MoveTab:Button("📋", "Print Position", "Prints XYZ + current area to output", C.accent, function()
    local r = getRoot(); if not r then SLbl.Text = "No character"; return end
    local p = r.Position
    local area = invokeR("GetArea")
    local areaName = area and area.Name or "Unknown"
    local msg = string.format("X=%.1f Y=%.1f Z=%.1f | Area: %s | Kills: %s",
        p.X, p.Y, p.Z, areaName, tostring(getKills()))
    print("[MeleeRNG] " .. msg); SLbl.Text = msg
end)
MoveTab:Button("🔄", "Respawn", "Kills character", C.red, function()
    local h = getHuman(); if h then h.Health = 0 end
end)
MoveTab:Button("🌀", "Fire Nearest Machine", "Fires nearest workspace.Machines ProximityPrompt (no teleport — executor fireproximityprompt)", C.green, function()
    local root = getRoot(); if not root then SLbl.Text = "No character"; return end
    local machines = workspace:FindFirstChild("Machines")
    if not machines then SLbl.Text = "⚠ workspace.Machines not found"; return end
    -- ProximityPrompt is a DIRECT child of each machine model (confirmed from explorer image)
    -- Structure: workspace.Machines.[MachineName].ProximityPrompt
    local best, bestDist, bestPrompt = nil, math.huge, nil
    for _, machine in pairs(machines:GetChildren()) do
        -- Direct child ProximityPrompt
        local prompt = machine:FindFirstChild("ProximityPrompt")
        if prompt and prompt:IsA("ProximityPrompt") then
            local hrp = machine:FindFirstChild("HumanoidRootPart")
                     or machine.PrimaryPart
            local pos
            if hrp then
                pos = hrp.Position
            else
                local ok, bb = pcall(function() return machine:GetBoundingBox() end)
                if ok then pos = bb.Position end
            end
            if pos then
                local d = (root.Position - pos).Magnitude
                if d < bestDist then
                    bestDist = d; bestPrompt = prompt; best = machine
                end
            end
        end
    end
    if bestPrompt then
        pcall(function() fireproximityprompt(bestPrompt) end)
        SLbl.Text = string.format("Fired prompt: %s (%.0f studs)", best.Name, bestDist)
    else
        SLbl.Text = "⚠ No direct ProximityPrompt found in workspace.Machines children"
    end
end)

-- --------------------------------------------------------------------------
-- UI — ESP tab
-- --------------------------------------------------------------------------
ESPTab:Section("Mob ESP")
ESPTab:Toggle("👹 Mob ESP", "Billboard tags on all mobs in workspace.Mobs", states.espMobs, function(on)
    states.espMobs = on; saveSettings()
    if not on then
        for _, bb in pairs(espBillboards) do pcall(function() bb:Destroy() end) end
        espBillboards = {}
    end
end)

ESPTab:Section("Info")
ESPTab:Label("Mob ESP attaches BillboardGui to Head/UpperTorso. Loot ESP attaches to PrimaryPart. All removed on Stop.")

-- --------------------------------------------------------------------------
-- UI — Areas tab
-- --------------------------------------------------------------------------
AreaTab:Section("Teleport to Area")
AreaTab:Label("Areas discovered live from workspace.Areas.\nAreas require MinimumKills to unlock.")

local AreaListFrame = Instance.new("Frame", AreaTab._page)
AreaListFrame.Size = UDim2.new(1,-10,0,280); AreaListFrame.BackgroundColor3 = C.card
AreaListFrame.BorderSizePixel = 0; AreaListFrame.LayoutOrder = 5; AreaListFrame.ClipsDescendants = true
Instance.new("UICorner", AreaListFrame).CornerRadius = UDim.new(0,10)
Instance.new("UIStroke", AreaListFrame).Color = C.border

local AreaScroll = Instance.new("ScrollingFrame", AreaListFrame)
AreaScroll.Size = UDim2.new(1,-6,1,-4); AreaScroll.Position = UDim2.new(0,3,0,4)
AreaScroll.BackgroundTransparency = 1; AreaScroll.BorderSizePixel = 0
AreaScroll.ScrollBarThickness = 3; AreaScroll.ScrollBarImageColor3 = C.accent
AreaScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y; AreaScroll.CanvasSize = UDim2.new(0,0,0,0)
local AreaLayout = Instance.new("UIListLayout", AreaScroll)
AreaLayout.Padding = UDim.new(0,3); AreaLayout.SortOrder = Enum.SortOrder.LayoutOrder

local function buildAreaList()
    for _, c in pairs(AreaScroll:GetChildren()) do
        if c:IsA("TextButton") or c:IsA("Frame") then c:Destroy() end
    end
    local areasFolder = workspace:FindFirstChild("Areas")
    if not areasFolder then return end
    local areas = areasFolder:GetChildren()
    table.sort(areas, function(a,b)
        return (tonumber(a:GetAttribute("MinimumKills")) or 0) <
               (tonumber(b:GetAttribute("MinimumKills")) or 0)
    end)
    for i, area in ipairs(areas) do
        local minKills   = tonumber(area:GetAttribute("MinimumKills")) or 0
        local minAscends = tonumber(area:GetAttribute("MinAscends")) or 0
        local myKills    = getKills()
        local myAscends  = getAscends()
        local unlocked   = myKills >= minKills and myAscends >= minAscends
        local btn = Instance.new("TextButton", AreaScroll)
        btn.Size = UDim2.new(1,-4,0,36); btn.LayoutOrder = i
        btn.BackgroundColor3 = unlocked and Color3.fromRGB(0,30,15) or C.card
        btn.BorderSizePixel = 0; btn.Text = ""
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0,7)
        local bStroke = Instance.new("UIStroke", btn)
        bStroke.Color = unlocked and C.green or C.border; bStroke.Thickness = 1

        local nLbl = Instance.new("TextLabel", btn)
        nLbl.Text = area.Name; nLbl.Size = UDim2.new(0.55,0,1,0); nLbl.Position = UDim2.new(0,10,0,0)
        nLbl.BackgroundTransparency = 1; nLbl.TextColor3 = unlocked and C.green or C.sub
        nLbl.Font = Enum.Font.GothamBold; nLbl.TextSize = 10; nLbl.TextXAlignment = Enum.TextXAlignment.Left

        local reqLbl = Instance.new("TextLabel", btn)
        local reqStr = minAscends > 0
            and string.format("⚔%s | 🌟%d", tostring(minKills), minAscends)
            or  string.format("⚔ %s kills", tostring(minKills))
        reqLbl.Text = reqStr; reqLbl.Size = UDim2.new(0.45,-10,1,0); reqLbl.Position = UDim2.new(0.55,0,0,0)
        reqLbl.BackgroundTransparency = 1; reqLbl.TextColor3 = C.sub
        reqLbl.Font = Enum.Font.Code; reqLbl.TextSize = 8; reqLbl.TextXAlignment = Enum.TextXAlignment.Right

        local aName = area.Name
        btn.MouseButton1Click:Connect(function()
            local root = getRoot(); if not root then SLbl.Text = "No character"; return end
            local areaRef = areasFolder:FindFirstChild(aName)
            if not areaRef then SLbl.Text = "⚠ Area not found"; return end
            -- Teleport confirmed from dump: HumanoidRootPart.CFrame = area.SafeAreaSpawn.CFrame
            local spawn = areaRef:FindFirstChild("SafeAreaSpawn")
            if spawn then
                local ok = pcall(function()
                    root.CFrame = spawn.CFrame * CFrame.new(0,3,0)
                end)
                SLbl.Text = ok and ("TP → " .. aName) or "⚠ Teleport failed"
            else
                SLbl.Text = "⚠ No SafeAreaSpawn in " .. aName
            end
        end)
    end
end

AreaTab:Button("🔄", "Refresh Area List", "Re-scans workspace.Areas", C.accent, function()
    buildAreaList(); SLbl.Text = "Area list refreshed"
end)
task.defer(buildAreaList)

AreaTab:Section("Current Area")
local CurAreaLbl = AreaTab:Label("Current area: checking...")
task.spawn(function()
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        task.wait(3)
        pcall(function()
            local area = invokeR("GetArea")
            if area then
                CurAreaLbl.Set("Current area: " .. area.Name ..
                    " | Kills: " .. tostring(getKills()) ..
                    " | Ascends: " .. tostring(getAscends()))
            end
        end)
    end
end)

-- --------------------------------------------------------------------------
-- Feature loops (same IIFE as UI — shares states / GEN)
-- --------------------------------------------------------------------------

-- ── Auto Equip Best (WeaponsUI EquipBestBtn → Remotes.EquipBest:FireServer) ──
addThread(task.spawn(function()
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        task.wait(10)
        if not states.autoEquipBest then continue end
        pcall(function()
            fireR("EquipBest")
        end)
    end
end))

-- ── Infinite Jump ─────────────────────────────────────────────
addConn(UserInputService.JumpRequest:Connect(function()
    if GEN ~= _G.MeleeRNG_Gen then return end
    if states.infJump then
        local h = getHuman(); if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end))

-- ── Auto Mana → SP (CalculateManaPrice / ConvertMana — 1 unit, throttled) ──
-- invokeR() maps server `false` to nil, so we call InvokeServer here: on false = cap / can't afford → backoff (stops notification spam).
local _manaConvLast = 0
local _manaConvBackoffUntil = 0
addConn(RunService.Heartbeat:Connect(function()
    if GEN ~= _G.MeleeRNG_Gen then return end
    if not states.autoManaToSP then return end
    local now = os.clock()
    if now < _manaConvBackoffUntil then return end
    if now - _manaConvLast < 0.12 then return end
    _manaConvLast = now
    pcall(function()
        local rConv = R("ConvertMana")
        local rPrice = R("CalculateManaPrice")
        if not rConv or not rPrice then return end

        _cachedStats["Mana"] = nil
        local okPrice, cost = pcall(function() return rPrice:InvokeServer(1) end)
        if not okPrice or cost == nil then return end
        local c = (typeof(cost) == "number" and cost) or tonumber(cost)
        if c == nil or c ~= c or c < 0 then return end
        c = math.ceil(c)

        local m = tonumber(getMana()) or 0
        if m < c then return end

        local okConv, serverRes = pcall(function() return rConv:InvokeServer(1) end)
        if not okConv then
            _manaConvBackoffUntil = now + 2.5
            return
        end
        if serverRes == false then
            _manaConvBackoffUntil = now + 5
            _cachedStats["Mana"] = nil
            _cachedStats["SP"] = nil
            return
        end
        _cachedStats["Mana"] = nil
        _cachedStats["SP"] = nil
    end)
end))

-- ── Movement / combat / ESP / CharacterAdded — own init function (Luau ~200 local cap) ──
local _fb = meleeInitMovementEspCharAdded()
meleeInitAntiAfk()

-- ── Auto Ascend loop (ConfirmAscend; gate = (2 + ascends)×1M, not area MinimumKills) ──
addThread(task.spawn(function()
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        if not states.autoAscend then task.wait(2); continue end
        pcall(function()
            local need = getAscendKillsRequired()
            if (tonumber(getKills()) or 0) < need then return end
            local area = invokeR("GetArea"); if not area then return end
            local nextPortal = area:FindFirstChild("NextPortal"); if not nextPortal then return end
            local dest = nextPortal:GetAttribute("Destination")
            local beforeA = tonumber(getAscends()) or 0
            local ok = invokeR("ConfirmAscend")
            if not ok then return end
            if teleportAfterAscendIfConfirmed(beforeA) then
                SLbl.Text = "✓ Ascended → " .. tostring(dest or "?") .. " | TP " .. formatAscendTpSaved()
            end
        end)
        task.wait(5)
    end
end))

-- ── Auto cycle (infinite loop): (1) TP Ascend spot → (2) check upgrades → (3) raid spend if needed → raid OFF →
--    (4) farm until ascend kill gate → (5) wait for ⬆️ Auto Ascend / manual ascend → post-ascend TP → repeat.
addThread(task.spawn(function()
    local RAID_POLL_SEC = 1.25
    local RAID_MAX_SEC = 2700
    local FARM_POLL_SEC = 1.5
    local FARM_TP_LEASH_STUDS = 5
    local function tpAscendSaved()
        local root = getRoot()
        if not root then return false end
        return select(1, pcall(function()
            root.CFrame = getAscendAfterTpCFrame() * CFrame.new(0, 3, 0)
        end))
    end
    local function setGameAutoRaid(on)
        return meleeSetGameAutoRaidEnabled(on == true)
    end
    --- True when no raid SP spend is needed: Ordered Chain has no unfinished target.
    -- Ordered Chain intentionally skips ON rows with no target level so it can move through a clean top-to-bottom plan.
    local function raidSpendPhaseDone()
        for _, name in ipairs(UPGRADE_ORDER) do
            if upgradeSelected[name] then
                local capN = upgradeLevelCap[name]
                if type(capN) == "number" and capN >= 1 then
                    if upgReadUpgradeLevel(name) < capN then return false end
                end
            end
        end
        return #upgBuildSortedCandidates() == 0
    end
    --- Count upgrade rows that are ON + have a target; `need` = how many are still below that target.
    local function raidCappedUpgradesPending()
        local need, tracked = 0, 0
        for _, name in ipairs(UPGRADE_ORDER) do
            if upgradeSelected[name] then
                local capN = upgradeLevelCap[name]
                if type(capN) == "number" and capN >= 1 then
                    tracked = tracked + 1
                    if upgReadUpgradeLevel(name) < capN then
                        need = need + 1
                    end
                end
            end
        end
        return need, tracked
    end
    local function raidCappedStatusFragment()
        local need, tracked = raidCappedUpgradesPending()
        if tracked == 0 then
            return "targets — (no ON+target on Upgrades tab)"
        end
        return string.format("%d/%d below target", need, tracked)
    end
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        if not states.autoCycleFarm then
            task.wait(2)
            continue
        end
        pcall(function()
            meleeAutoFarmStatus.raidPhaseActive = false
            meleeAutoFarmStatus.farmPhaseActive = false
            meleeAutoFarmStatus.line = "🔁 TP → saved Ascend spot"
            SLbl.Text = "🔄 Cycle: TP → saved Ascend spot"
            tpAscendSaved()
            task.wait(0.65)
            if not states.autoCycleFarm or GEN ~= _G.MeleeRNG_Gen then return end

            -- (2)(3) After TP: if anything still needs raid SP, turn Auto Raid ON and wait until fully capped / done.
            local needsRaidSpend = not raidSpendPhaseDone()
            local prevAU = states.autoUpgradeOn
            local tRaid = os.clock()

            if needsRaidSpend then
                states.autoUpgradeOn = true
                meleeAutoFarmStatus.raidPhaseActive = true
                if not setGameAutoRaid(true) then
                    meleeAutoFarmStatus.raidPhaseActive = false
                    states.autoUpgradeOn = prevAU
                    meleeAutoFarmStatus.line = "⚠ No AutoRaidBtn (MainGUI.OptionsList) — check PlayerGui"
                    SLbl.Text = "⚠ Cycle: AutoRaidBtn missing — enable Auto Raid in game UI"
                    task.wait(6)
                    return
                end

                meleeAutoFarmStatus.line = string.format(
                    "🔁 Raid + auto upgrade | Auto Raid: %s | %s | until targets done / queue empty",
                    meleeAutoRaidUiShort(),
                    raidCappedStatusFragment())
                SLbl.Text = "🔄 Cycle: Auto Raid ON + Auto Upgrade (until targets / queue done)"
                local lastRaidUiNudge = 0.0
                while states.autoCycleFarm and GEN == _G.MeleeRNG_Gen and os.clock() - tRaid < RAID_MAX_SEC do
                    local elapsed = os.clock() - tRaid
                    local done = raidSpendPhaseDone()
                    if not done and meleeAutoRaidUiShort() == "OFF" then
                        if elapsed - lastRaidUiNudge >= 3.5 then
                            lastRaidUiNudge = elapsed
                            meleeNudgeAutoRaidOnIfUiOff()
                        end
                    end
                    meleeAutoFarmStatus.line = string.format(
                        "🔁 Raid + upgrade | Auto Raid UI: %s | %dm %02ds | %s | %s",
                        meleeAutoRaidUiShort(),
                        math.floor(elapsed / 60),
                        math.floor(elapsed % 60),
                        raidCappedStatusFragment(),
                        done and "targets done → raid OFF → farm" or "buying…")
                    if done then break end
                    task.wait(RAID_POLL_SEC)
                end

                meleeAutoFarmStatus.raidPhaseActive = false
                states.autoUpgradeOn = prevAU

                if not states.autoCycleFarm or GEN ~= _G.MeleeRNG_Gen then return end
                if os.clock() - tRaid >= RAID_MAX_SEC then
                    meleeAutoFarmStatus.line = "⚠ Raid phase timeout — check SP / upgrade targets"
                    SLbl.Text = "⚠ Cycle: raid phase timeout — check targets / SP"
                end
            else
                meleeAutoFarmStatus.raidPhaseActive = false
                meleeAutoFarmStatus.line = string.format(
                    "🔁 Upgrades satisfied — skip raid | %s",
                    raidCappedStatusFragment())
                SLbl.Text = "🔄 Cycle: upgrades satisfied — skip raid → farm"
            end

            -- If Auto Raid is ON, one click OFF before farm (covers skip-raid path too).
            setGameAutoRaid(false)

            meleeAutoFarmStatus.line = string.format("🔁 Farm kills (raid OFF) | Auto Raid UI: %s", meleeAutoRaidUiShort())
            SLbl.Text = "🔄 Cycle: farm kills at saved spot"
            tpAscendSaved()
            task.wait(0.5)
            local farmStartAscends = tonumber(getAscends()) or 0
            meleeAutoFarmStatus.farmPhaseActive = true
            while states.autoCycleFarm and GEN == _G.MeleeRNG_Gen do
                local k = tonumber(getKills()) or 0
                local req = getAscendKillsRequired()
                local dest, killsNeeded = KR.getAscendETA()
                local kpm = KR.getKillRate()
                local root = getRoot()
                local driftDist = 0
                if root then
                    local tgt = getAscendAfterTpWorldPos()
                    driftDist = (root.Position - tgt).Magnitude
                    if driftDist > FARM_TP_LEASH_STUDS then
                        tpAscendSaved()
                    end
                end
                meleeAutoFarmStatus.line = string.format(
                    "🔁 Farm | %s / %s kills (%s left) → %s | ~%.1f KPM | %.0f studs",
                    tostring(k),
                    tostring(req),
                    tostring(killsNeeded),
                    dest and tostring(dest) or "?",
                    kpm,
                    driftDist)
                if k >= req then break end
                task.wait(FARM_POLL_SEC)
            end
            meleeAutoFarmStatus.farmPhaseActive = false

            if not states.autoCycleFarm or GEN ~= _G.MeleeRNG_Gen then return end

            -- ConfirmAscend is only fired from ⬆️ Auto Ascend (or Ascend Now / game UI). Cycle waits for Ascends↑ then TP chase.
            local beforeA = farmStartAscends
            local nowAAtGate = tonumber(getAscends()) or 0
            if nowAAtGate > beforeA then
                if teleportAfterAscendIfConfirmed(beforeA) then
                    meleeAutoFarmStatus.line = "🔁 Ascended during farm handoff — next loop: TP → raid/farm"
                    SLbl.Text = "🔄 Cycle: ascended — continuing"
                else
                    meleeAutoFarmStatus.line = "🔁 Ascend detected during handoff — TP chase timeout or unclear"
                    SLbl.Text = "🔄 Cycle: ascend detected — check TP / Ascends"
                end
                return
            end
            meleeAutoFarmStatus.line =
                "🔁 Kills met — turn ON ⬆️ Auto Ascend (or ascend manually); cycle continues after Ascends increases"
            SLbl.Text = "🔄 Cycle: waiting for ascend (Auto Ascend / manual)"
            while states.autoCycleFarm and GEN == _G.MeleeRNG_Gen do
                local nowA = tonumber(getAscends()) or 0
                if nowA > beforeA then
                    if teleportAfterAscendIfConfirmed(beforeA) then
                        meleeAutoFarmStatus.line = "🔁 Ascended — next loop: TP → raid/farm"
                        SLbl.Text = "🔄 Cycle: ascended — continuing"
                    else
                        meleeAutoFarmStatus.line = "🔁 Ascend detected — TP chase timeout or unclear"
                        SLbl.Text = "🔄 Cycle: ascend detected — check TP / Ascends"
                    end
                    break
                end
                task.wait(1)
            end
        end)
        task.wait(2)
    end
end))

-- ── Periodic DMG multiplier refresh ──────────────────────────
addThread(task.spawn(function()
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        task.wait(30)
        pcall(getDmgMulti)
    end
end))

-- ── Re-apply preferred aura if game clears SelectedAura ───────
addThread(task.spawn(function()
    while true do
        if GEN ~= _G.MeleeRNG_Gen then break end
        task.wait(4)
        pcall(maintainPreferredAuraSelection, false)
    end
end))

local miscAscendGui = meleeGuiMountMiscStatsLabelsAscendAura(MiscTab, SLbl, C, function()
    return guildStatusLbl, apStatusLbl
end, KR.getKillRate, KR.getAscendETA, KR.fmtTime)

-- `;` required before `(` here: otherwise Luau parses `(function` as a call on task.defer's return value.
;(function()
    MiscTab:Section("Machines (workspace.Machines)")
    MiscTab:Label("Open via ProximityPrompt only — no teleport (needs executor fireproximityprompt).")

    local MACHINE_NAMES = { "Fountain Of Skill", "Fusion Machine", "Totem Of Fortune", "Weapon Crafter" }
    for _, mn in ipairs(MACHINE_NAMES) do
        MiscTab:Button("🔧", mn, "Fire " .. mn .. " ProximityPrompt from range (no TP)", C.accent, function()
            local machines = workspace:FindFirstChild("Machines")
            local machine = machines and machines:FindFirstChild(mn)
            if not machine then SLbl.Text = "⚠ " .. mn .. " not found in workspace.Machines"; return end
            local prompt = machine:FindFirstChild("ProximityPrompt")
            if prompt then
                local ok = pcall(function() fireproximityprompt(prompt) end)
                SLbl.Text = ok and ("✓ Opened: " .. mn) or ("⚠ fireproximityprompt failed — " .. mn)
            else
                SLbl.Text = "⚠ No ProximityPrompt on " .. mn
            end
        end)
    end

    MiscTab:Section("Game UI")
    MiscTab:Toggle("👁️ Show AutoRaid Button", "Keeps AutoRaidBtn visible — saved & applied on load", states.showAutoRaid, function(on)
        states.showAutoRaid = on; saveSettings()
        pcall(function()
            LP.PlayerGui:WaitForChild("MainGUI", 3)
                :WaitForChild("OptionsList", 3)
                :WaitForChild("AutoRaidBtn", 3).Visible = on
        end)
        SLbl.Text = on and "✓ AutoRaidBtn shown" or "AutoRaidBtn hidden"
    end)
    MiscTab:Toggle("🙈 Show HideMobs Button", "Keeps HideMobsBtn visible — saved & applied on load", states.showHideMobs, function(on)
        states.showHideMobs = on; saveSettings()
        pcall(function()
            LP.PlayerGui:WaitForChild("MainGUI", 3)
                :WaitForChild("OptionsList", 3)
                :WaitForChild("HideMobsBtn", 3).Visible = on
        end)
        SLbl.Text = on and "✓ HideMobsBtn shown" or "HideMobsBtn hidden"
    end)

    MiscTab:Label("Hide main-game UI (local only; Heartbeat reapplies while any hide is on — avoids fighting roll UI).")
    MiscTab:Toggle("🙈 Hide Mana / Kills", "Hides ManaFrame, KillsFrame, StageProgress (combat kill bar) — saved", states.uiHideManaKills, function(on)
        states.uiHideManaKills = on == true
        saveSettings()
        applyMeleeGameUiHiding(true)
        SLbl.Text = on and "Game UI: Mana/Kills hidden" or "Game UI: Mana/Kills visible"
    end)
    MiscTab:Toggle("🎰 Hide Mini-Roll Animations", "Hides MainGUI.GeneralUI.MiniRollFrame — saved", states.uiHideMiniRoll, function(on)
        states.uiHideMiniRoll = on == true
        saveSettings()
        applyMeleeGameUiHiding(true)
        SLbl.Text = on and "Game UI: Mini-Roll hidden" or "Game UI: Mini-Roll visible"
    end)
    MiscTab:Toggle("📵 Hide HUD", "Hides all of MainGUI.GeneralUI (includes mana/kills/mini-roll while ON) — saved", states.uiHideHud, function(on)
        states.uiHideHud = on == true
        saveSettings()
        if on ~= true then
            pcall(function()
                local main = LP.PlayerGui:FindFirstChild("MainGUI")
                local gen = main and main:FindFirstChild("GeneralUI")
                if gen and gen:IsA("GuiObject") then
                    gen.Visible = true
                end
            end)
        end
        applyMeleeGameUiHiding(true)
        SLbl.Text = on and "Game UI: GeneralUI (HUD) hidden" or "Game UI: GeneralUI (HUD) visible"
    end)
    MiscTab:Toggle("🔕 Hide game notifications", "Hides MainGUI.NotifFrame (SP wins, sacrifice, limits, etc.) — local only — saved", states.uiHideNotifications, function(on)
        states.uiHideNotifications = on == true
        saveSettings()
        if on ~= true then
            pcall(function()
                local main = LP.PlayerGui:FindFirstChild("MainGUI")
                local nf = main and main:FindFirstChild("NotifFrame")
                if nf and nf:IsA("GuiObject") then
                    nf.Visible = true
                end
            end)
        end
        applyMeleeGameUiHiding(true)
        SLbl.Text = on and "Game UI: notifications hidden" or "Game UI: notifications visible"
    end)
    task.defer(function()
        pcall(function() applyMeleeGameUiHiding(true) end)
    end)

    MiscTab:Section("Performance")
    MiscTab:Label("Client-only FPS helpers. Does not change server / combat hitboxes.")
    local perfUi = {}
    perfUi.other = MiscTab:Toggle("Hide Other Players' Weapons", "LocalTransparencyModifier on models under workspace[their name] — saved", states.perfHideOtherWeapons, function(on)
        states.perfHideOtherWeapons = on == true
        saveSettings()
        SLbl.Text = on and "Perf: others’ weapons hidden" or "Perf: others’ weapons shown"
    end)
    perfUi.own = MiscTab:Toggle("Hide Own Weapons", "Hides models under your workspace player folder (same place as hitbox pulse) — saved", states.perfHideOwnWeapons, function(on)
        states.perfHideOwnWeapons = on == true
        saveSettings()
        SLbl.Text = on and "Perf: your weapons hidden" or "Perf: your weapons shown"
    end)
    perfUi.fx = MiscTab:Toggle("Hide All Effects", "Disables ParticleEmitter, Trail, Beam under workspace (restores prior Enabled when off) — saved", states.perfHideAllEffects, function(on)
        states.perfHideAllEffects = on == true
        saveSettings()
        if on == true then
            pcall(perfSweepEffectsHide)
            _perfLastEffectsHidden = true
            _perfFxAcc = 0
        end
        SLbl.Text = on and "Perf: workspace VFX off" or "Perf: workspace VFX restored"
    end)
    perfUi.loot = MiscTab:Toggle("Hide Loot Drops", "Hides dropped weapons under workspace.Loot (client visibility only) — saved", states.perfHideLootDrops, function(on)
        states.perfHideLootDrops = on == true
        saveSettings()
        if on == true then pcall(function() perfSweepLootDrops(true) end) end
        SLbl.Text = on and "Perf: loot hidden" or "Perf: loot visible"
    end)
    perfUi.mobmana = MiscTab:Toggle("Hide mob mana orbs", "Hides pink mana pickups in workspace + their Trail/Beam/particles (purple streaks). Not weapon loot — client-only — saved", states.perfHideMobManaOrbs, function(on)
        states.perfHideMobManaOrbs = on == true
        saveSettings()
        if on == true then pcall(function() perfSweepMobManaOrbs(true) end) end
        SLbl.Text = on and "Perf: mob mana orbs hidden" or "Perf: mob mana orbs visible"
    end)
    perfUi.hitbox = MiscTab:Toggle("Hide Hitbox visuals", "LocalTransparencyModifier on parts named Hitbox under your weapon folder (stops white range rings; Touched unchanged). Off if “Hide Own Weapons” is on — saved", states.perfHideHitboxVisuals, function(on)
        states.perfHideHitboxVisuals = on == true
        saveSettings()
        if on == true and not states.perfHideOwnWeapons then pcall(function() perfSweepHitboxVisuals(true) end) end
        SLbl.Text = on and "Perf: Hitbox parts hidden" or "Perf: Hitbox visuals restored"
    end)
    perfUi.sound = MiscTab:Toggle("Mute World Sounds", "Sets workspace Sound.Volume to 0 (restores when off). Throttled rescans for new sounds — saved", states.perfMuteWorldSounds, function(on)
        states.perfMuteWorldSounds = on == true
        saveSettings()
        if on == true then
            pcall(perfSweepWorldSoundsMute)
            _perfLastSoundsMuted = true
            _perfSoundAcc = 0
        end
        SLbl.Text = on and "Perf: world sounds muted" or "Perf: world sounds restored"
    end)
    perfUi.shadow = MiscTab:Toggle("Disable Global Shadows", "Lighting.GlobalShadows = false while ON (restores prior when off) — saved", states.perfDisableShadows, function(on)
        states.perfDisableShadows = on == true
        saveSettings()
        perfApplyShadows(on == true)
        SLbl.Text = on and "Perf: shadows OFF" or "Perf: shadows restored"
    end)
    perfUi.tech = MiscTab:Toggle("Compatibility Lighting", "Lighting.Technology → Compatibility (older/cheaper pipeline; restores when off) — saved", states.perfCompatLighting, function(on)
        states.perfCompatLighting = on == true
        saveSettings()
        perfApplyCompatLighting(on == true)
        SLbl.Text = on and "Perf: Compatibility lighting" or "Perf: lighting tech restored"
    end)
    perfUi.lowq = MiscTab:Toggle("Low graphics quality", "UserSettings → UserGameSettings: SavedQualityLevel (lowest enum) + GraphicsQualityLevel=1 if present. Some executors ignore this — saved", states.perfLowGraphicsQuality, function(on)
        states.perfLowGraphicsQuality = on == true
        saveSettings()
        perfApplyLowGraphicsQuality(on == true)
        SLbl.Text = on and "Perf: low quality applied" or "Perf: graphics quality restored"
    end)
    perfUi.hidechars = MiscTab:Toggle("Hide other players’ characters", "INTRUSIVE: LocalTransparencyModifier on every other player’s Character BasePart (you see nobody). Yours unchanged — saved", states.perfHideOtherCharacters, function(on)
        states.perfHideOtherCharacters = on == true
        saveSettings()
        if on == true then pcall(function() perfSweepOtherCharacters(true) end) end
        SLbl.Text = on and "Perf: other characters hidden" or "Perf: other characters visible"
    end)
    task.defer(function()
        pcall(function()
            local p = perfUi
            if p.other and p.other.Set then p.other.Set(states.perfHideOtherWeapons) end
            if p.own and p.own.Set then p.own.Set(states.perfHideOwnWeapons) end
            if p.fx and p.fx.Set then p.fx.Set(states.perfHideAllEffects) end
            if p.loot and p.loot.Set then p.loot.Set(states.perfHideLootDrops) end
            if p.mobmana and p.mobmana.Set then p.mobmana.Set(states.perfHideMobManaOrbs) end
            if p.hitbox and p.hitbox.Set then p.hitbox.Set(states.perfHideHitboxVisuals) end
            if p.sound and p.sound.Set then p.sound.Set(states.perfMuteWorldSounds) end
            if p.shadow and p.shadow.Set then p.shadow.Set(states.perfDisableShadows) end
            if p.tech and p.tech.Set then p.tech.Set(states.perfCompatLighting) end
            if p.lowq and p.lowq.Set then p.lowq.Set(states.perfLowGraphicsQuality) end
            if p.hidechars and p.hidechars.Set then p.hidechars.Set(states.perfHideOtherCharacters) end
            if states.perfDisableShadows then perfApplyShadows(true) end
            if states.perfCompatLighting then perfApplyCompatLighting(true) end
            if states.perfLowGraphicsQuality then perfApplyLowGraphicsQuality(true) end
            if states.perfMuteWorldSounds then
                pcall(perfSweepWorldSoundsMute)
                _perfLastSoundsMuted = true
                _perfSoundAcc = 0
            end
            if states.perfHideLootDrops then pcall(function() perfSweepLootDrops(true) end) end
            if states.perfHideMobManaOrbs then pcall(function() perfSweepMobManaOrbs(true) end) end
            if states.perfHideHitboxVisuals and not states.perfHideOwnWeapons then pcall(function() perfSweepHitboxVisuals(true) end) end
            if states.perfHideAllEffects then
                pcall(perfSweepEffectsHide)
                _perfLastEffectsHidden = true
                _perfFxAcc = 0
            end
            if states.perfHideOtherCharacters then pcall(function() perfSweepOtherCharacters(true) end) end
        end)
    end)

    MiscTab:Section("Upgrades (debug)")
    local UPGRADE_NAMES = {
        "Skill Point Multiplier",
        "Mana Multiplier",
        "Enemy Limit",
        "Enemy Spawn Rate",
        "Weapons Equipped",
        "Damage Multiplier",
        "Spin Speed",
        "Kill Multiplier",
    }
    MiscTab:Button("📊", "Print Upgrade Levels", "Fetches all upgrade levels via GetUnlockedUpgrades", C.accent, function()
        local upgrades = invokeR("GetUnlockedUpgrades")
        if not upgrades then SLbl.Text = "⚠ GetUnlockedUpgrades returned nil"; return end
        for _, name in ipairs(UPGRADE_NAMES) do
            local level = upgReadUpgradeLevel(name)
            local val = invokeR("GetUpgradeValue", name) or 0
            print(string.format("[MeleeRNG] %-30s  Lv%d  Value: %s", name, level, tostring(val)))
        end
        SLbl.Text = "Upgrade levels printed to output"
    end)

    MiscTab:Section("Mana → SP")
    local toggle = MiscTab:Toggle("⚡ Auto Mana → SP", "Requires mana ≥ CalculateManaPrice(1). If ConvertMana returns false (cap / can’t afford more SP), waits ~5s before retry — avoids spam toasts.", states.autoManaToSP, function(on)
        states.autoManaToSP = on == true
        saveSettings()
        SLbl.Text = on and "Auto Mana→SP ON" or "Auto Mana→SP OFF"
    end)
    task.defer(function()
        pcall(function()
            if toggle and toggle.Set then toggle.Set(states.autoManaToSP) end
        end)
    end)
    manaToSpToggle = toggle

    local g = meleeGuiMountGuildTab(GuildTab, SLbl, C)
    guildStatusLbl = g.guildStatusLbl
    guildSpToGpToggle = g.guildSpToGpToggle
    guildBuffAutoToggle = g.guildBuffAutoToggle
    guildBuffToggles = g.guildBuffToggles
    local a = meleeGuiMountApTab(ApTab, SLbl, C)
    apStatusLbl = a.apStatusLbl
    apAutoToggle = a.apAutoToggle
    apUpgradeToggles = a.apUpgradeToggles
end)()

MiscTab:Section("Community")
MiscTab:Button("💬", "Join Discord", "Opens discord.gg/ErGUHtVK in browser", C.purple, function()
    if setclipboard then
        setclipboard("https://discord.gg/ErGUHtVK")
        SLbl.Text = "Discord link copied to clipboard!"
    end
    if syn and syn.openUrl then syn.openUrl("https://discord.gg/ErGUHtVK")
    elseif (function() local ok, _ = pcall(function() return game:GetService("GuiService"):OpenBrowserWindow("https://discord.gg/ErGUHtVK") end) return ok end)() then
    end
    SLbl.Text = "discord.gg/ErGUHtVK — link copied!"
end)

MiscTab:Section("Script")
MiscTab:Toggle("🔁 Auto Rejoin", "Queues script on server teleport / disconnect hop only; throttled so executors cannot spam re-exec", states.autoReExec, function(on)
    states.autoReExec = on
    saveSettings()
    SLbl.Text = on and "Auto Rejoin ON" or "Auto Rejoin OFF"
    if on then
        pcall(function()
            local f = _G.MeleeRNG_ArmReexecQueue
            if f then f("toggle_ui") end
        end)
    end
end)
MiscTab:Toggle("💾 Auto Save", "Automatically saves all toggle/slider states to disk", states.autoSave, function(on)
    states.autoSave = on
    forceSave()  -- always save the autoSave state itself
    SLbl.Text = on and "✓ Auto Save ON — settings saved on every change" or "Auto Save OFF"
end)
MiscTab:Button("🛑", "Stop All Loops", "Disconnects all connections and cancels all threads", C.red, function()
    states.autoAscend  = false
    states.autoCycleFarm = false
    meleeAutoFarmStatus.raidPhaseActive = false
    meleeAutoFarmStatus.farmPhaseActive = false
    meleeAutoFarmStatus.line = "🔁 Farm cycle: OFF (Stop All)"
    pcall(function()
        local fc = miscAscendGui and miscAscendGui.autoFarmCycleStatusLbl
        if fc and fc.Set then
            fc.Set(meleeAutoFarmStatus.line)
        end
    end)
    states.autoSacrifice = false
    states.autoTotem   = false
    states.autoManaToSP  = false
    states.autoGuildSpToGp = false
    states.autoGuildBuffs = false
    states.autoApUpgrades = false
    states.autoEquipBest = false
    pcall(function() setMouseUnlockN(false) end)
    pcall(function()
        if sacAutoToggle and sacAutoToggle.Set then sacAutoToggle.Set(false) end
    end)
    pcall(function()
        if totemAutoToggle and totemAutoToggle.Set then totemAutoToggle.Set(false) end
    end)
    pcall(function()
        if manaToSpToggle and manaToSpToggle.Set then manaToSpToggle.Set(false) end
    end)
    pcall(function()
        if guildSpToGpToggle and guildSpToGpToggle.Set then guildSpToGpToggle.Set(false) end
    end)
    pcall(function()
        if guildBuffAutoToggle and guildBuffAutoToggle.Set then guildBuffAutoToggle.Set(false) end
    end)
    pcall(function()
        if apAutoToggle and apAutoToggle.Set then apAutoToggle.Set(false) end
    end)
    pcall(function()
        local g = miscAscendGui
        if g and g.autoCycleFarmToggle and g.autoCycleFarmToggle.Set then g.autoCycleFarmToggle.Set(false) end
    end)
    pcall(function()
        local g = miscAscendGui
        if g and g.autoAscendToggle and g.autoAscendToggle.Set then g.autoAscendToggle.Set(false) end
    end)
    pcall(function()
        if autoEquipBestToggle and autoEquipBestToggle.Set then autoEquipBestToggle.Set(false) end
    end)
    states.noclip    = false; states.godMode   = false
    states.fly       = false; states.antiAfk   = false
    states.fullBright= false; states.espMobs   = false
    cleanupAll()
    -- Restore lighting
    if _fb.applied then
        Lighting.Ambient = _fb.orig.Ambient; Lighting.OutdoorAmbient = _fb.orig.OutdoorAmbient
        Lighting.Brightness = _fb.orig.Brightness
        Lighting.FogEnd = _fb.orig.FogEnd; Lighting.FogStart = _fb.orig.FogStart
        _fb.applied = false
    end
    -- Remove ESP
    for _, bb in pairs(espBillboards) do pcall(function() bb:Destroy() end) end
    espBillboards = {}
    -- Remove fly
    if flyBV then flyBV:Destroy(); flyBV = nil end
    if flyBG then flyBG:Destroy(); flyBG = nil end
    -- Restore hitboxes on stop
    hitboxExpanded = false
    _pulseActive   = false
    if _pulseConn then pcall(function() _pulseConn:Disconnect() end); _pulseConn = nil end
    pcall(restoreHitboxes)
    SLbl.Text = "All loops stopped. Re-execute to restart."
end)

MiscTab:Button("💾", "Save Settings", "Force-saves current toggle/slider state", C.green, function()
    saveSettings()
    SLbl.Text = "Settings saved to " .. SETTINGS_FILE
end)

MiscTab:Section("Local PNG Background")
MiscTab:Label("Old logic kept. The background is local-only in PlayerGui and uses the labeled PNG frame folder at 60 FPS when getcustomasset/getsynasset can read it.")
local uiBgStatusLbl = MiscTab:Label(uiBgStatusText())
MiscTab:Toggle("🎥 Local PNG Background", "ON = animate MeleeRNG_UI_Background_manifest/extracted_frames behind this UI for only your client.", states.uiVideoBackground, function(on)
    states.uiVideoBackground = on == true
    saveSettings()
    meleeApplyOldGuiMp4Background(states.uiVideoBackground)
    if uiBgStatusLbl and uiBgStatusLbl.Set then uiBgStatusLbl.Set(uiBgStatusText()) end
    SLbl.Text = uiBgStatusText()
end)
MiscTab:Button("↻", "Reload Local Frames", "Clears the cached local PNG assets and reapplies the client-only background.", C.accent, function()
    _uiBgCachedLocalAssets = nil
    local ok = uiBgEnsureLocalPngFrames() ~= nil
    meleeApplyOldGuiMp4Background(states.uiVideoBackground)
    if uiBgStatusLbl and uiBgStatusLbl.Set then uiBgStatusLbl.Set(uiBgStatusText()) end
    SLbl.Text = ok and ("✓ Local PNG frames ready - " .. tostring(UI_BG_LAST_STATUS)) or ("⚠ Local PNG frames not ready - " .. tostring(UI_BG_LAST_STATUS))
end)

task.defer(function()
    task.wait(0.4)
    meleeApplyOldGuiMp4Background(states.uiVideoBackground)
    if uiBgStatusLbl and uiBgStatusLbl.Set then uiBgStatusLbl.Set(uiBgStatusText()) end
end)

MiscTab:Section("Mouse Unlock (N)")
MiscTab:Label("Press N to toggle mouse unlock. When ON, an invisible GuiButton with Modal=true is kept visible, which is the Roblox-native way to release the cursor while fully scrolled in / first-person without changing zoom.")
mouseUnlockStatusLbl = MiscTab:Label(mouseUnlockStatusText())
mouseUnlockToggle = MiscTab:Toggle("🖱️ Unlock Mouse with N", "Hotkey: N. ON enables an invisible Modal GuiButton so the cursor is free in forced first person; OFF restores normal lock.", states.mouseUnlockN, function(on)
    setMouseUnlockN(on == true)
    SLbl.Text = states.mouseUnlockN and "Mouse unlock ON — press N to turn it off" or "Mouse unlock OFF — press N to turn it on"
end)
MiscTab:Button("N", "Toggle Mouse Unlock", "Same as pressing the N keybind", C.accent, function()
    setMouseUnlockN(not states.mouseUnlockN)
    SLbl.Text = states.mouseUnlockN and "Mouse unlock ON — press N to turn it off" or "Mouse unlock OFF — press N to turn it on"
end)
task.defer(mouseUnlockRefreshUi)

return SLbl
end)()

-- ── Auto re-exec (own function = avoids Luau 200 locals in UI IIFE) ───────────
local function meleeReexecArmInit()
    local reexecUrl = SCRIPT_URL
    local queueMinInterval = 12
    if _G.MeleeRNG_AutoRejoin and not states.autoReExec then
        states.autoReExec = true
        saveSettings()
    end
    local function syncMeleeRejoinFlag()
        _G.MeleeRNG_AutoRejoin = states.autoReExec
    end
    syncMeleeRejoinFlag()
    local function armQueue(_reason)
        if not queue_on_teleport or not states.autoReExec then return end
        local now = os.clock()
        local last = _G.MeleeRNG_QueueLastClock
        if type(last) == "number" and (now - last) < queueMinInterval then
            return
        end
        _G.MeleeRNG_QueueLastClock = now
        pcall(function()
            queue_on_teleport('loadstring(game:HttpGet("' .. reexecUrl .. '",true))()')
        end)
    end
    pcall(function()
        LP.OnTeleport:Connect(function(teleportState)
            if teleportState ~= Enum.TeleportState.RequestedByServer then return end
            if GEN ~= _G.MeleeRNG_Gen then return end
            syncMeleeRejoinFlag()
            armQueue("teleport")
        end)
    end)
    if states.autoReExec then
        armQueue("load")
    end
    task.spawn(function()
        local wasOn = states.autoReExec == true
        while true do
            if GEN ~= _G.MeleeRNG_Gen then break end
            task.wait(2)
            syncMeleeRejoinFlag()
            if states.autoReExec and not wasOn then
                armQueue("toggle_on")
            end
            wasOn = states.autoReExec == true
        end
    end)
    _G.MeleeRNG_ArmReexecQueue = armQueue
end
meleeReexecArmInit()

-- --------------------------------------------------------------------------
-- Boot complete — walk speed, deferred PlayerGui, status line
-- --------------------------------------------------------------------------
do local h = getHuman(); if h then h.WalkSpeed = walkSpeedVal end end
-- Apply saved UI button visibility on load
task.defer(function()
    if states.showAutoRaid then
        pcall(function()
            LP.PlayerGui:WaitForChild("MainGUI",5):WaitForChild("OptionsList",5):WaitForChild("AutoRaidBtn",5).Visible = true
        end)
    end
    if states.showHideMobs then
        pcall(function()
            LP.PlayerGui:WaitForChild("MainGUI",5):WaitForChild("OptionsList",5):WaitForChild("HideMobsBtn",5).Visible = true
        end)
    end
end)
vprint(string.format("[MeleeRNG] Loaded v1.0 | Gen=%d | DMGx=%d%%", GEN, _dmgMulti))
SLbl.Text = string.format("MeleeRNG v1.0 ready | Gen=%d | Kills: %s", GEN, tostring(getKills()))
