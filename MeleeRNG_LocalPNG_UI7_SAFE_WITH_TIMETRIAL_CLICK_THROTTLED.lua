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
local ContentProvider  = game:GetService("ContentProvider")
local GuiService       = game:GetService("GuiService")

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
    uiPngBackground = false, -- old GUI only: local PNG background behind NexusLib window (heavy; opt-in)
    -- MainGUI.GeneralUI (client visibility only; see applyMeleeGameUiHiding)
    uiHideManaKills = false, -- ManaFrame + KillsFrame + StageProgress (combat bar)
    uiHideMiniRoll  = false, -- MiniRollFrame (mini-roll animations UI)
    uiHideHud       = false, -- entire GeneralUI (hides all of the above while ON)
    uiHideNotifications = false, -- MainGUI.NotifFrame (NotifUIManager / SP & sacrifice toasts)
    autoReExec     = false,
    hitboxPulse    = false,
    hitboxDutyCycle  = 2,  -- BIG on 1 frame per N heartbeats (2 = half the frames big, old behavior; 6+ = mostly tiny, less physics lag)
    autoEquipBestInterval = 60, -- seconds between EquipBest calls; higher = less weapon rebuild hitch
    dungeonAutoTpNew = false, -- GeneratedDungeon: TP to each newly created Room_N BASE + 1 stud
    dungeonAutoTpEntered = false, -- GeneratedDungeon: keep chasing entered Room_N when it exists
    dungeonTargetRoomNumber = 1, -- GeneratedDungeon room number input
    mobSpawnOnMe = false, -- local mob positioning helper: move workspace.Mobs roots to your HRP
    mobHardHide = false, -- hard-hide mob visuals but keep roots alive
    timeTrialAutoStart = false, -- auto-fire StartTimeTrial on a slow timer
    timeTrialAutoClickStartRun = true, -- auto-click the Time Trials Lobby Start Run button when it appears
    timeTrialAutoLeaveRestart = false, -- leave/restart Time Trial when target Room_N exists
    timeTrialLeaveAtRoom = 50, -- Time Trial room threshold for auto leave/restart
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
        t.uiPngBackgroundLagSafeMigrated = true
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
if LS.uiPngBackgroundLagSafeMigrated ~= true then
    states.uiPngBackground = false
end
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
states.uiPngBackground = states.uiPngBackground == true
states.autoEquipBestInterval = math.clamp(math.floor(tonumber(states.autoEquipBestInterval) or 60), 15, 600)
states.dungeonAutoTpNew = states.dungeonAutoTpNew == true
states.dungeonAutoTpEntered = states.dungeonAutoTpEntered == true
states.dungeonTargetRoomNumber = math.clamp(math.floor(tonumber(states.dungeonTargetRoomNumber) or 1), 1, 1000000)
states.mobSpawnOnMe = states.mobSpawnOnMe == true
states.mobHardHide = states.mobHardHide == true
states.timeTrialAutoStart = states.timeTrialAutoStart == true
if LS.timeTrialAutoClickStartRun ~= nil then
    states.timeTrialAutoClickStartRun = LS.timeTrialAutoClickStartRun == true
else
    states.timeTrialAutoClickStartRun = states.timeTrialAutoClickStartRun ~= false
end
states.timeTrialAutoLeaveRestart = states.timeTrialAutoLeaveRestart == true
states.timeTrialLeaveAtRoom = math.clamp(math.floor(tonumber(states.timeTrialLeaveAtRoom) or 50), 1, 1000000)
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
-- window skin/background inside LocalPlayer.PlayerGui. It uses only local PNGs.

local UI_BG_LAST_STATUS = "not checked"
local UI_BG_SCREEN_ATTR = "MeleeRNG_LocalPngBackground"
local UI_BG_LAYER_NAME = "MeleeRNG_OldGui_BG_Layer"
local UI_BG_IMAGE_NAME = "MeleeRNG_OldGui_Animated_Frame"
local UI_BG_BUFFER_NAME = "MeleeRNG_OldGui_Animated_Buffer"
local UI_BG_ICON_IMAGE_NAME = "MeleeRNG_ToggleIcon_Animated_Frame"
local UI_BG_DIM_NAME = "MeleeRNG_OldGui_BG_Dim"
local UI_BG_STATUS_NAME = "MeleeRNG_LocalPng_Status"
local UI_BG_PANEL_ALPHA_ATTR = "MeleeRNG_OldGuiBgPanelAlphaFixed"
-- Lower = more solid panels. 0.26 lets the background show without making text unreadable.
local UI_BG_PANEL_TRANSPARENCY = 0.68
-- Higher = less black over the background. 0.28 is dark enough for readability.
local UI_BG_DIM_TRANSPARENCY = 0.92
local UI_BG_WARM_TRANSPARENCY = 0.99
local UI_BG_LOCAL_FRAME_COUNT = 630
local UI_BG_LOCAL_FRAME_FPS = 24
local UI_BG_FRAME_W, UI_BG_FRAME_H = 240, 426
local UI_BG_SHEET_COLS, UI_BG_SHEET_ROWS = 12, 9
local UI_BG_SHEET_FRAMES = UI_BG_SHEET_COLS * UI_BG_SHEET_ROWS
local UI_BG_SHEET_COUNT = math.ceil(UI_BG_LOCAL_FRAME_COUNT / UI_BG_SHEET_FRAMES)
local UI_BG_LOCAL_FRAME_FOLDERS = {
    "MeleeRNG_UI_Background_manifest/extracted_frames",
    "./MeleeRNG_UI_Background_manifest/extracted_frames",
    "C:/Users/Pizza/Documents/yesGPT/MeleeRNG_UI_Background_manifest/extracted_frames",
    "C:\\Users\\Pizza\\Documents\\yesGPT\\MeleeRNG_UI_Background_manifest\\extracted_frames",
}
local UI_BG_SHEET_FOLDERS = {
    "MeleeRNG_UI_Background_manifest/sheets",
    "./MeleeRNG_UI_Background_manifest/sheets",
    "C:/Users/Pizza/Documents/yesGPT/MeleeRNG_UI_Background_manifest/sheets",
    "C:\\Users\\Pizza\\Documents\\yesGPT\\MeleeRNG_UI_Background_manifest\\sheets",
}
local _uiBgRoot = nil
local _uiBgPanelConn = nil
local _uiBgAnimToken = 0
local _uiBgCachedLocalAssets = nil
local _uiBgCachedSheets = nil

local function uiBgTrySet(inst, prop, value)
    pcall(function() inst[prop] = value end)
end

local function uiBgFileExists(path)
    if type(isfile) ~= "function" then return false end
    local ok, exists = pcall(isfile, path)
    return ok and exists == true
end

local uiBgPathVariants

local function uiBgGetCustomAsset(path)
    local fn = nil
    if type(getcustomasset) == "function" then
        fn = getcustomasset
    elseif type(getsynasset) == "function" then
        fn = getsynasset
    end
    if not fn then
        UI_BG_LAST_STATUS = "getcustomasset/getsynasset is missing"
        return nil
    end

    for _, p in ipairs(uiBgPathVariants(path)) do
        local ok, asset = pcall(fn, p)
        if ok and type(asset) == "string" and asset ~= "" then
            return asset
        end
    end

    UI_BG_LAST_STATUS = "asset API rejected path variants for " .. tostring(path)
    return nil
end

uiBgPathVariants = function(path)
    local tries, seen = {}, {}
    local function add(p)
        if type(p) == "string" and p ~= "" and not seen[p] then
            seen[p] = true
            tries[#tries + 1] = p
        end
    end

    add(path)
    add(path:gsub("^%./", ""))
    add(path:gsub("^%.\\", ""))
    add(path:gsub("\\", "/"))
    add(path:gsub("/", "\\"))
    add((path:gsub("^%./", "")):gsub("\\", "/"))
    add((path:gsub("^%./", "")):gsub("/", "\\"))

    return tries
end

local function uiBgPreloadAssets(assetList)
    if not assetList or #assetList == 0 then return true end
    local ok = pcall(function()
        ContentProvider:PreloadAsync(assetList)
    end)
    return ok
end

local function uiBgLocalFramePath(folder, i)
    local sep = folder:find("\\", 1, true) and "\\" or "/"
    return string.format("%s%sframe_%04d.png", folder, sep, i)
end

local function uiBgSheetPath(folder, i)
    local sep = folder:find("\\", 1, true) and "\\" or "/"
    return string.format("%s%ssheet_%04d.png", folder, sep, i)
end

local function uiBgExistingPath(path)
    for _, p in ipairs(uiBgPathVariants(path)) do
        if uiBgFileExists(p) then return p end
    end

    return nil
end

local function uiBgResolveCustomAsset(path)
    local existing = uiBgExistingPath(path)
    if existing then
        local asset = uiBgGetCustomAsset(existing)
        if asset then return existing, asset end
    end

    -- Some executors can resolve getcustomasset() paths even when isfile() is
    -- unavailable or scoped differently, so do not let isfile() be the gate.
    for _, p in ipairs(uiBgPathVariants(path)) do
        local asset = uiBgGetCustomAsset(p)
        if asset then return p, asset end
    end

    return nil, nil
end

local function uiBgExistingFramePath(folder, i)
    return uiBgExistingPath(uiBgLocalFramePath(folder, i))
end

local function uiBgExistingSheetPath(folder, i)
    return uiBgExistingPath(uiBgSheetPath(folder, i))
end

local function uiBgSheetFrameCount(sheetIndex)
    local usedBefore = (sheetIndex - 1) * UI_BG_SHEET_FRAMES
    return math.max(0, math.min(UI_BG_SHEET_FRAMES, UI_BG_LOCAL_FRAME_COUNT - usedBefore))
end

local function uiBgEnsureSpriteSheets()
    if _uiBgCachedSheets and #_uiBgCachedSheets > 0 then
        return _uiBgCachedSheets
    end

    local lastProblem = "local PNG sprite sheets missing"
    for _, folder in ipairs(UI_BG_SHEET_FOLDERS) do
        local firstPath, firstAsset = uiBgResolveCustomAsset(uiBgSheetPath(folder, 1))
        if firstPath then
            if firstAsset then
                uiBgPreloadAssets({ firstAsset })
                local sheets = { { asset = firstAsset, frames = uiBgSheetFrameCount(1) } }
                _uiBgCachedSheets = sheets
                UI_BG_LAST_STATUS = string.format("using PNG sprite sheets from %s (1/%d loaded)", folder, UI_BG_SHEET_COUNT)
                vprint("[MeleeRNG PNG BG] " .. UI_BG_LAST_STATUS)
                task.spawn(function()
                    local batch = {}
                    local batchAssets = {}
                    for i = 2, UI_BG_SHEET_COUNT do
                        if _uiBgCachedSheets ~= sheets then return end
                        local path, asset = uiBgResolveCustomAsset(uiBgSheetPath(folder, i))
                        if not asset then
                            UI_BG_LAST_STATUS = string.format("sprite sheet folder %s stopped at sheet %04d", folder, i)
                            vprint("[MeleeRNG PNG BG] " .. UI_BG_LAST_STATUS)
                            return
                        end
                        batch[#batch + 1] = { asset = asset, frames = uiBgSheetFrameCount(i) }
                        batchAssets[#batchAssets + 1] = asset
                        if #batch >= 2 or i == UI_BG_SHEET_COUNT then
                            uiBgPreloadAssets(batchAssets)
                            if _uiBgCachedSheets ~= sheets then return end
                            for _, readySheet in ipairs(batch) do
                                sheets[#sheets + 1] = readySheet
                            end
                            batch = {}
                            batchAssets = {}
                            UI_BG_LAST_STATUS = string.format("using PNG sprite sheets from %s (%d/%d loaded)", folder, #sheets, UI_BG_SHEET_COUNT)
                            task.wait()
                        end
                    end
                    UI_BG_LAST_STATUS = string.format("using PNG sprite sheets from %s (%d/%d loaded, %d FPS, looping)", folder, #sheets, UI_BG_SHEET_COUNT, UI_BG_LOCAL_FRAME_FPS)
                    vprint("[MeleeRNG PNG BG] " .. UI_BG_LAST_STATUS)
                end)
                return sheets
            end
            lastProblem = "sprite sheet folder found, but asset API rejected " .. firstPath
            vprint("[MeleeRNG PNG BG] " .. lastProblem)
        end
    end

    UI_BG_LAST_STATUS = lastProblem .. " (copy the manifest/sheets folder into the executor workspace)"
    return nil
end

local function uiBgEnsureLocalPngFrames()
    if _uiBgCachedLocalAssets and #_uiBgCachedLocalAssets > 0 then
        return _uiBgCachedLocalAssets
    end

    local lastProblem = "local PNG frames missing"
    for _, folder in ipairs(UI_BG_LOCAL_FRAME_FOLDERS) do
        local firstPath, firstAsset = uiBgResolveCustomAsset(uiBgLocalFramePath(folder, 1))
        if firstPath then
            if firstAsset then
                uiBgPreloadAssets({ firstAsset })
                local assets = { firstAsset }
                _uiBgCachedLocalAssets = assets
                UI_BG_LAST_STATUS = string.format("showing PNG frame 1 from %s; loading rest", folder)
                vprint("[MeleeRNG PNG BG] " .. UI_BG_LAST_STATUS)
                task.spawn(function()
                    local batch = {}
                    for i = 2, UI_BG_LOCAL_FRAME_COUNT do
                        if _uiBgCachedLocalAssets ~= assets then return end
                        local path, asset = uiBgResolveCustomAsset(uiBgLocalFramePath(folder, i))
                        if not asset then
                            UI_BG_LAST_STATUS = string.format("PNG folder %s stopped at frame %04d", folder, i)
                            vprint("[MeleeRNG PNG BG] " .. UI_BG_LAST_STATUS)
                            return
                        end
                        batch[#batch + 1] = asset
                        if #batch >= 12 or i == UI_BG_LOCAL_FRAME_COUNT then
                            uiBgPreloadAssets(batch)
                            if _uiBgCachedLocalAssets ~= assets then return end
                            for _, readyAsset in ipairs(batch) do
                                assets[#assets + 1] = readyAsset
                            end
                            batch = {}
                            UI_BG_LAST_STATUS = string.format("using local PNG frames from %s (%d/%d loaded, looping)", folder, #assets, UI_BG_LOCAL_FRAME_COUNT)
                            task.wait()
                        end
                    end
                    UI_BG_LAST_STATUS = string.format("using local PNG frames from %s (%d/%d at %d FPS, looping)", folder, #assets, UI_BG_LOCAL_FRAME_COUNT, UI_BG_LOCAL_FRAME_FPS)
                    vprint("[MeleeRNG PNG BG] " .. UI_BG_LAST_STATUS)
                end)
                return assets
            end

            lastProblem = "PNG folder found, but getcustomasset/getsynasset could not load " .. firstPath
            vprint("[MeleeRNG PNG BG] " .. lastProblem)
        end
    end

    UI_BG_LAST_STATUS = lastProblem .. " (tried relative and C:/Users/Pizza/Documents/yesGPT paths)"
    vprint("[MeleeRNG PNG BG] " .. UI_BG_LAST_STATUS)
    return nil
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
                    if t:find("Melee RNG", 1, true) or t == "Melee" then score = score + 40 end
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
        obj.Name == UI_BG_IMAGE_NAME or
        obj.Name == UI_BG_BUFFER_NAME or
        obj.Name == UI_BG_ICON_IMAGE_NAME or
        obj.Name == UI_BG_DIM_NAME or
        obj.Name == UI_BG_STATUS_NAME
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

local function uiBgShowStaticLocalFrame(img, assets)
    _uiBgAnimToken = _uiBgAnimToken + 1
    if not img or not assets or not assets[1] then return end
    img.Visible = true
    img.ImageTransparency = 0
    img.BackgroundTransparency = 1
    img.ZIndex = 1
    img.Image = assets[1]
    img.ImageRectOffset = Vector2.new(0, 0)
    img.ImageRectSize = Vector2.new(0, 0)

    local buffer = img.Parent and img.Parent:FindFirstChild(UI_BG_BUFFER_NAME)
    if buffer and buffer:IsA("ImageLabel") then
        buffer.Visible = false
        buffer.ImageTransparency = 1
    end
end

local function uiBgSetSheetFrame(img, sheet, slot)
    if not img or not sheet then return end
    slot = slot or 0
    local col = slot % UI_BG_SHEET_COLS
    local row = math.floor(slot / UI_BG_SHEET_COLS)
    if img.Image ~= sheet.asset then
        img.Image = sheet.asset
    end
    img.ImageRectSize = Vector2.new(UI_BG_FRAME_W, UI_BG_FRAME_H)
    img.ImageRectOffset = Vector2.new(col * UI_BG_FRAME_W, row * UI_BG_FRAME_H)
end

local function uiBgSheetBufferFor(active, standbyZ)
    if not active or not active.Parent then return nil end
    local buffer = active.Parent:FindFirstChild(UI_BG_BUFFER_NAME)
    if buffer and not buffer:IsA("ImageLabel") then
        buffer:Destroy()
        buffer = nil
    end
    if buffer == active then
        buffer = nil
    end
    if not buffer then
        local primary = active.Parent:FindFirstChild(UI_BG_IMAGE_NAME) or active.Parent:FindFirstChild(UI_BG_ICON_IMAGE_NAME)
        if primary and primary:IsA("ImageLabel") and primary ~= active then
            buffer = primary
        end
    end
    if not buffer then
        buffer = Instance.new("ImageLabel")
        buffer.Name = UI_BG_BUFFER_NAME
        buffer.BorderSizePixel = 0
        buffer.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        buffer.BackgroundTransparency = 1
        buffer.Parent = active.Parent
    end
    buffer.Size = active.Size
    buffer.Position = active.Position
    buffer.BackgroundTransparency = 1
    buffer.ImageTransparency = UI_BG_WARM_TRANSPARENCY
    buffer.Visible = true
    buffer.ZIndex = standbyZ or 0
    uiBgTrySet(buffer, "ScaleType", Enum.ScaleType.Crop)
    return buffer
end

local function uiBgWarmSheetBuffer(active, sheet, token, standbyZ)
    local buffer = uiBgSheetBufferFor(active, standbyZ)
    if not buffer or not sheet then return nil end

    uiBgSetSheetFrame(buffer, sheet, 0)
    buffer.Visible = true
    buffer.ZIndex = standbyZ or 0
    buffer.ImageTransparency = UI_BG_WARM_TRANSPARENCY
    uiBgPreloadAssets({ sheet.asset })

    local deadline = os.clock() + 0.6
    while GEN == _G.MeleeRNG_Gen and token == _uiBgAnimToken and buffer.Parent and os.clock() < deadline do
        local ok, loaded = pcall(function() return buffer.IsLoaded end)
        if ok and loaded == true then
            break
        end
        task.wait(0.01)
    end
    task.wait()
    return buffer
end

local function uiBgNextSheetIndex(current, count)
    if count <= 1 then return 1 end
    local nextIndex = current + 1
    if nextIndex > count then nextIndex = 1 end
    return nextIndex
end

local function uiBgStartSheetAnimation(img, sheets, sharedToken, baseZ)
    if not sharedToken then
        _uiBgAnimToken = _uiBgAnimToken + 1
    end
    local token = sharedToken or _uiBgAnimToken
    if not img or not sheets or #sheets == 0 then return end

    local activeZ = baseZ or 1
    local standbyZ = math.max(0, activeZ - 1)
    local active = img
    local standby = uiBgSheetBufferFor(active, standbyZ)

    active.Visible = true
    active.ImageTransparency = 0
    active.BackgroundTransparency = 1
    active.ZIndex = activeZ
    uiBgSetSheetFrame(active, sheets[1], 0)

    local delay = 1 / math.max(1, UI_BG_LOCAL_FRAME_FPS)
    task.spawn(function()
        local sheetIndex = 1
        local slot = 0
        local preparedIndex = nil
        while GEN == _G.MeleeRNG_Gen and token == _uiBgAnimToken and active and active.Parent do
            local sheet = sheets[sheetIndex]
            if not sheet then
                sheetIndex = 1
                slot = 0
                sheet = sheets[1]
            end
            if sheet then
                local frameCount = sheet.frames or UI_BG_SHEET_FRAMES
                uiBgSetSheetFrame(active, sheet, slot)

                if #sheets > 1 and slot >= math.max(1, frameCount - 10) then
                    local nextIndex = uiBgNextSheetIndex(sheetIndex, #sheets)
                    if preparedIndex ~= nextIndex then
                        standby = uiBgWarmSheetBuffer(active, sheets[nextIndex], token, standbyZ)
                        preparedIndex = standby and nextIndex or nil
                    end
                end

                slot = slot + 1
                if slot >= frameCount then
                    local nextIndex = uiBgNextSheetIndex(sheetIndex, #sheets)
                    if nextIndex ~= sheetIndex and sheets[nextIndex] then
                        if preparedIndex ~= nextIndex then
                            standby = uiBgWarmSheetBuffer(active, sheets[nextIndex], token, standbyZ)
                            preparedIndex = standby and nextIndex or nil
                        end

                        if standby and standby.Parent and preparedIndex == nextIndex then
                            standby.Size = active.Size
                            standby.Position = active.Position
                            standby.Visible = true
                            standby.ZIndex = activeZ
                            standby.ImageTransparency = 0

                            active.ZIndex = standbyZ
                            active.ImageTransparency = UI_BG_WARM_TRANSPARENCY

                            local oldActive = active
                            active = standby
                            standby = oldActive
                            sheetIndex = nextIndex
                            slot = 1
                            preparedIndex = nil
                        else
                            slot = math.max(0, frameCount - 1)
                        end
                    else
                        sheetIndex = nextIndex
                        slot = 0
                    end
                end
            end
            task.wait(delay)
        end
    end)
end

local function uiBgFindToggleIcon(root, window)
    if not root then return nil end
    local best, bestScore = nil, -1
    for _, d in ipairs(root:GetDescendants()) do
        if (d:IsA("ImageButton") or d:IsA("TextButton")) and (not window or not d:IsDescendantOf(window)) then
            local sx, sy = d.AbsoluteSize.X, d.AbsoluteSize.Y
            if sx <= 0 then sx = d.Size.X.Offset end
            if sy <= 0 then sy = d.Size.Y.Offset end
            if sx >= 24 and sx <= 72 and sy >= 24 and sy <= 72 then
                local score = 0
                if d:IsA("ImageButton") then score = score + 20 end
                if d.Parent == root then score = score + 12 end
                if math.abs(sx - sy) <= 8 then score = score + 8 end
                if tostring(d.Name):lower():find("icon", 1, true) then score = score + 10 end
                if d:IsA("ImageButton") and tostring(d.Image or ""):find("3117561276", 1, true) then
                    score = score + 50
                end
                if score > bestScore then
                    bestScore = score
                    best = d
                end
            end
        end
    end
    return best
end

local function uiBgFindWindowDotButton(window)
    if not window then return nil end
    local wx, wy = window.AbsolutePosition.X, window.AbsolutePosition.Y
    local ww = window.AbsoluteSize.X
    local best, bestScore = nil, -1
    for _, d in ipairs(window:GetDescendants()) do
        if d:IsA("ImageButton") or d:IsA("TextButton") then
            local sx, sy = d.AbsoluteSize.X, d.AbsoluteSize.Y
            if sx <= 0 then sx = d.Size.X.Offset end
            if sy <= 0 then sy = d.Size.Y.Offset end
            if sx >= 18 and sx <= 44 and sy >= 18 and sy <= 44 then
                local ax, ay = d.AbsolutePosition.X, d.AbsolutePosition.Y
                local score = 0
                if ax >= wx + ww - 80 then score = score + 35 end
                if ay <= wy + 70 then score = score + 35 end
                if math.abs(sx - sy) <= 8 then score = score + 8 end
                if d:IsA("TextButton") then
                    local t = tostring(d.Text or ""):lower()
                    if t == "x" or #t <= 3 then score = score + 12 end
                end
                if score > bestScore then
                    bestScore = score
                    best = d
                end
            end
        end
    end
    return best
end

local function uiBgClearButtonBackground(button)
    if not button then return end
    for _, name in ipairs({ UI_BG_ICON_IMAGE_NAME, UI_BG_BUFFER_NAME }) do
        local child = button:FindFirstChild(name)
        if child then child:Destroy() end
    end
end

local function uiBgClearToggleIconBackground(root, window)
    uiBgClearButtonBackground(uiBgFindToggleIcon(root, window))
    uiBgClearButtonBackground(uiBgFindWindowDotButton(window))
end

local function uiBgApplyButtonBackground(icon, sheets, token)
    if not icon or not sheets or #sheets == 0 then return end

    icon.ClipsDescendants = true
    icon.BackgroundTransparency = math.max(icon.BackgroundTransparency, 0.16)

    local bg = icon:FindFirstChild(UI_BG_ICON_IMAGE_NAME)
    if bg and not bg:IsA("ImageLabel") then
        bg:Destroy()
        bg = nil
    end
    if not bg then
        bg = Instance.new("ImageLabel")
        bg.Name = UI_BG_ICON_IMAGE_NAME
        bg.BorderSizePixel = 0
        bg.BackgroundTransparency = 1
        bg.Parent = icon
    end
    bg.Size = UDim2.new(1, 0, 1, 0)
    bg.Position = UDim2.new(0, 0, 0, 0)
    bg.BackgroundTransparency = 1
    bg.ImageTransparency = 0
    bg.Visible = true
    bg.ZIndex = icon.ZIndex + 1
    uiBgTrySet(bg, "ScaleType", Enum.ScaleType.Crop)

    for _, child in ipairs(icon:GetChildren()) do
        if child:IsA("GuiObject") and child ~= bg and child.Name ~= UI_BG_BUFFER_NAME then
            child.ZIndex = math.max(child.ZIndex, icon.ZIndex + 3)
        end
    end

    uiBgStartSheetAnimation(bg, sheets, token, icon.ZIndex + 1)
end

local function uiBgApplyToggleIconBackground(root, window, sheets, token)
    uiBgApplyButtonBackground(uiBgFindToggleIcon(root, window), sheets, token)
    uiBgApplyButtonBackground(uiBgFindWindowDotButton(window), sheets, token)
end

local function uiBgSetInlineStatus(root, text, visible)
    if not root then return end
    local lbl = root:FindFirstChild(UI_BG_STATUS_NAME)
    if not lbl then
        lbl = Instance.new("TextLabel")
        lbl.Name = UI_BG_STATUS_NAME
        lbl.AnchorPoint = Vector2.new(0.5, 1)
        lbl.Position = UDim2.new(0.5, 0, 1, -10)
        lbl.Size = UDim2.new(1, -24, 0, 32)
        lbl.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        lbl.BackgroundTransparency = 0.2
        lbl.BorderSizePixel = 0
        lbl.TextColor3 = Color3.fromRGB(255, 220, 92)
        lbl.TextSize = 11
        lbl.Font = Enum.Font.Code
        lbl.TextWrapped = true
        lbl.TextXAlignment = Enum.TextXAlignment.Center
        lbl.ZIndex = 999
        lbl.Parent = root
    end
    lbl.Text = tostring(text or "")
    lbl.Visible = visible == true
end

local function meleeApplyLocalPngBackground(enabled)
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
        uiBgClearToggleIconBackground(root, window)
        uiBgSetInlineStatus(root, "", false)
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
    -- The PNG frame sits on top of this black base; if local assets are blocked,
    -- the UI stays readable instead of becoming transparent gray.
    uiBgTrySet(window, "BackgroundColor3", Color3.fromRGB(0, 0, 0))
    uiBgTrySet(window, "BackgroundTransparency", 0.04)

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
    img.BackgroundTransparency = 1
    img.ImageTransparency = 0
    img.ZIndex = 1
    img.ImageRectOffset = Vector2.new(0, 0)
    img.ImageRectSize = Vector2.new(0, 0)
    uiBgTrySet(img, "ScaleType", Enum.ScaleType.Crop)

    local buffer = layer:FindFirstChild(UI_BG_BUFFER_NAME)
    if buffer and buffer:IsA("ImageLabel") then
        buffer.Size = img.Size
        buffer.Position = img.Position
        buffer.BackgroundTransparency = 1
        buffer.ImageTransparency = 1
        buffer.Visible = false
        buffer.ZIndex = 2
        uiBgTrySet(buffer, "ScaleType", Enum.ScaleType.Crop)
    end

    local dim = layer:FindFirstChild(UI_BG_DIM_NAME)
    if not dim then
        dim = Instance.new("Frame")
        dim.Name = UI_BG_DIM_NAME
        dim.Size = UDim2.new(1, 0, 1, 0)
        dim.Position = UDim2.new(0, 0, 0, 0)
        dim.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        dim.BackgroundTransparency = UI_BG_DIM_TRANSPARENCY
        dim.BorderSizePixel = 0
        dim.ZIndex = 3
        dim.Parent = layer
    end
    dim.Visible = true
    dim.ZIndex = 3
    dim.BackgroundTransparency = UI_BG_DIM_TRANSPARENCY

    local sheets = uiBgEnsureSpriteSheets()
    if sheets and #sheets > 0 then
        _uiBgAnimToken = _uiBgAnimToken + 1
        local animToken = _uiBgAnimToken
        uiBgStartSheetAnimation(img, sheets, animToken, 1)
        uiBgApplyToggleIconBackground(root, window, sheets, animToken)
        UI_BG_LAST_STATUS = string.format("using visible PNG sprite sheets (%d/%d loaded at %d FPS, looping)", #sheets, UI_BG_SHEET_COUNT, UI_BG_LOCAL_FRAME_FPS)
        uiBgSetInlineStatus(root, "", false)
    else
        uiBgClearToggleIconBackground(root, window)
        local assets = uiBgEnsureLocalPngFrames()
        if assets and #assets > 0 then
            uiBgShowStaticLocalFrame(img, assets)
            UI_BG_LAST_STATUS = "sprite sheets missing; showing first PNG only to prevent black flashing"
            uiBgSetInlineStatus(root, "", false)
        else
            -- No asset support: stay opaque instead of showing the game through the GUI.
            img.Visible = true
            img.Image = ""
            img.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
            img.BackgroundTransparency = 0
            UI_BG_LAST_STATUS = tostring(UI_BG_LAST_STATUS) .. " - using solid black fallback"
            uiBgSetInlineStatus(root, "PNG background failed: " .. tostring(UI_BG_LAST_STATUS), true)
        end
    end

    uiBgSoftenPanels(root)
    return true
end

local function uiBgStatusText()
    return states.uiPngBackground and ("Local PNG background: ON - " .. tostring(UI_BG_LAST_STATUS)) or "Local PNG background: OFF"
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


-- ── Time Trials lobby Start Run / Leave robust auto-click ────────────────
-- The game's TimeTrialsUI.StartBtn / MainGUI.GeneralUI.LeaveTimeTrialBtn are
-- not always GuiButtons in every build; some are Frames with Input handlers.
-- So this uses the exact paths first, then falls back to GUI-center mouse input.
local _ttStartRunBurstUntil = 0
local _ttStartRunBurstActive = false
-- Anti-spam guard: Start/Leave UI objects are custom frames; clicking too often
-- can hammer input callbacks and cause lag or double-start behavior.
local TT_START_CLICK_COOLDOWN_SEC = 2.75
local TT_LEAVE_CLICK_COOLDOWN_SEC = 3.50
local _ttNextStartClickAllowed = 0
local _ttNextLeaveClickAllowed = 0

local function meleeTTIsManualReason(reason)
    local r = tostring(reason or ""):lower()
    return r:find("manual", 1, true) ~= nil or r:find("now", 1, true) ~= nil
end

local function meleeTTStartClickAllowed(reason)
    if meleeTTIsManualReason(reason) then return true end
    local now = os.clock()
    if now < _ttNextStartClickAllowed then return false end
    _ttNextStartClickAllowed = now + TT_START_CLICK_COOLDOWN_SEC
    return true
end

local function meleeTTLeaveClickAllowed(reason)
    if meleeTTIsManualReason(reason) then return true end
    local now = os.clock()
    if now < _ttNextLeaveClickAllowed then return false end
    _ttNextLeaveClickAllowed = now + TT_LEAVE_CLICK_COOLDOWN_SEC
    return true
end

local function meleeGuiIsActuallyVisible(obj)
    if not obj then return false end
    local cur = obj
    while cur do
        if cur:IsA("GuiObject") and cur.Visible == false then
            return false
        end
        if cur:IsA("LayerCollector") and cur.Enabled == false then
            return false
        end
        cur = cur.Parent
    end
    local ok, size = pcall(function() return obj.AbsoluteSize end)
    return (not ok) or (size.X > 0 and size.Y > 0)
end

local function meleeTextFromGuiObject(obj)
    local text = ""
    pcall(function()
        if obj:IsA("TextButton") or obj:IsA("TextLabel") or obj:IsA("TextBox") then
            text = tostring(obj.Text or "")
        end
    end)
    if text == "" then
        pcall(function()
            local lbl = obj:FindFirstChildWhichIsA("TextLabel", true)
            if lbl then text = tostring(lbl.Text or "") end
        end)
    end
    return text
end

local function meleeGuiCenter(obj)
    local ok, pos, size = pcall(function()
        return obj.AbsolutePosition, obj.AbsoluteSize
    end)
    if not ok or not pos or not size or size.X <= 0 or size.Y <= 0 then return nil end
    return math.floor(pos.X + size.X * 0.5), math.floor(pos.Y + size.Y * 0.5)
end

local function meleeFindClickableDescendant(obj)
    if not obj then return nil end
    if obj:IsA("TextButton") or obj:IsA("ImageButton") then return obj end
    return obj:FindFirstChildWhichIsA("TextButton", true) or obj:FindFirstChildWhichIsA("ImageButton", true)
end

local function meleeGetConnectionsFn()
    local gc = rawget(_G, "getconnections")
    if type(gc) ~= "function" and type(getconnections) == "function" then gc = getconnections end
    return type(gc) == "function" and gc or nil
end

local function meleeFireSignal(sig, ...)
    if not sig then return false end
    local okAny = false
    local fs = rawget(_G, "firesignal")
    if type(fs) ~= "function" and type(firesignal) == "function" then fs = firesignal end
    if type(fs) == "function" then
        local args = table.pack(...)
        local ok = pcall(function() fs(sig, table.unpack(args, 1, args.n)) end)
        okAny = okAny or ok
    end

    local gc = meleeGetConnectionsFn()
    if gc then
        local ok, conns = pcall(gc, sig)
        if ok and type(conns) == "table" then
            local args = table.pack(...)
            for _, c in ipairs(conns) do
                local fn = nil
                if type(c) == "table" then
                    fn = c.Function or c.function_ or c[1]
                elseif type(c) == "function" then
                    fn = c
                end
                if type(fn) == "function" then
                    local callOk = pcall(fn, table.unpack(args, 1, args.n))
                    okAny = okAny or callOk
                elseif type(c) == "table" and type(c.Fire) == "function" then
                    local callOk = pcall(function() c:Fire(table.unpack(args, 1, args.n)) end)
                    okAny = okAny or callOk
                end
            end
        end
    end
    return okAny
end

local function meleeMakeFakeInput(x, y, state)
    return {
        UserInputType = Enum.UserInputType.MouseButton1,
        UserInputState = state or Enum.UserInputState.Begin,
        KeyCode = Enum.KeyCode.Unknown,
        Position = Vector3.new(tonumber(x) or 0, tonumber(y) or 0, 0),
        Delta = Vector3.new(0, 0, 0),
    }
end

local function meleeFireGuiObjectInputSignals(obj)
    if not obj or not obj:IsA("GuiObject") then return false end
    local x, y = meleeGuiCenter(obj)
    x, y = x or 0, y or 0
    local inputBegan = meleeMakeFakeInput(x, y, Enum.UserInputState.Begin)
    local inputEnded = meleeMakeFakeInput(x, y, Enum.UserInputState.End)

    local okAny = false
    okAny = meleeFireSignal(obj.InputBegan, inputBegan, false) or okAny
    okAny = meleeFireSignal(obj.InputEnded, inputEnded, false) or okAny

    if obj:IsA("GuiButton") then
        pcall(function() obj:Activate() okAny = true end)
        okAny = meleeFireSignal(obj.Activated) or okAny
        okAny = meleeFireSignal(obj.MouseButton1Down, x, y) or okAny
        okAny = meleeFireSignal(obj.MouseButton1Up, x, y) or okAny
        okAny = meleeFireSignal(obj.MouseButton1Click) or okAny
        if fireGuiButtonClick and fireGuiButtonClick(obj) then okAny = true end
    end

    return okAny
end

local function meleeFireButtonSignals(btn)
    if not btn then return false end
    return meleeFireGuiObjectInputSignals(btn)
end

local function meleeVirtualClickGuiObject(obj, repeats)
    if not obj or not obj:IsA("GuiObject") or not meleeGuiIsActuallyVisible(obj) then return false end
    local x, y = meleeGuiCenter(obj)
    if not x or not y then return false end

    repeats = math.clamp(math.floor(tonumber(repeats) or 1), 1, 2)
    local coords = { {x, y} }
    pcall(function()
        local inset = GuiService:GetGuiInset()
        coords[#coords + 1] = { x + inset.X, y + inset.Y }
        coords[#coords + 1] = { math.max(0, x - inset.X), math.max(0, y - inset.Y) }
    end)

    local ok = false
    local vim
    local okSvc = pcall(function() vim = game:GetService("VirtualInputManager") end)
    if okSvc and vim then
        for _, xy in ipairs(coords) do
            local cx, cy = xy[1], xy[2]
            for _ = 1, repeats do
                local thisOk = pcall(function()
                    vim:SendMouseMoveEvent(cx, cy, game)
                    task.wait(0.02)
                    vim:SendMouseButtonEvent(cx, cy, 0, true, game, 1)
                    task.wait(0.06)
                    vim:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
                end)
                ok = ok or thisOk
                task.wait(0.045)
            end
        end
    end

    if not ok then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton1(Vector2.new(x, y))
            ok = true
        end)
    end
    return ok
end

local function meleeRobustClickGuiTarget(obj, reason)
    if not obj or not obj:IsA("GuiObject") or not meleeGuiIsActuallyVisible(obj) then return false end

    local candidates, seen = {}, {}
    local function addCandidate(x)
        if x and x:IsA("GuiObject") and not seen[x] and meleeGuiIsActuallyVisible(x) then
            seen[x] = true
            candidates[#candidates + 1] = x
        end
    end

    addCandidate(obj)
    addCandidate(meleeFindClickableDescendant(obj))

    for _, d in ipairs(obj:GetDescendants()) do
        if d:IsA("GuiObject") then
            local n = tostring(d.Name):lower()
            local t = meleeTextFromGuiObject(d):lower()
            if d:IsA("GuiButton") or n:find("button") or n:find("btn") or t:find("start") or t:find("leave") or t:find("run") then
                addCandidate(d)
            end
        end
    end

    local p = obj.Parent
    for _ = 1, 2 do
        if p and p:IsA("GuiObject") then addCandidate(p) end
        p = p and p.Parent
    end

    local signaled, clickedCenter = false, false
    local tried = 0
    for _, target in ipairs(candidates) do
        tried = tried + 1
        if tried > 4 then break end -- enough candidates; avoid input spam on wrappers/children
        signaled = meleeFireGuiObjectInputSignals(target) or signaled
        clickedCenter = meleeVirtualClickGuiObject(target, 1) or clickedCenter
        task.wait(0.08)
    end

    if signaled or clickedCenter then
        vprint("[MeleeRNG/TimeTrial] clicked", tostring(obj:GetFullName()), tostring(reason or ""), "candidates", #candidates)
        return true
    end
    return false
end

local function meleeFindTimeTrialStartRunButton()
    local pg = LP and LP:FindFirstChildOfClass("PlayerGui")
    if not pg then return nil end

    -- Exact live path from your Explorer screenshot:
    -- PlayerGui.MainGUI.GeneralUI.TimeTrialsLobbyFrame.StartBtn
    -- Check this FIRST so we do not accidentally click the older TimeTrialsUI clone.
    local main = pg:FindFirstChild("MainGUI") or (LP and LP:FindFirstChild("MainGUI"))
    local general = main and main:FindFirstChild("GeneralUI")
    local lobbyFrame = general and general:FindFirstChild("TimeTrialsLobbyFrame")
    local exactStart = lobbyFrame and lobbyFrame:FindFirstChild("StartBtn")
    if exactStart and exactStart:IsA("GuiObject") and meleeGuiIsActuallyVisible(exactStart) then
        return exactStart
    end

    -- Fallback: some builds place/copy a StartBtn under TimeTrialsUI.
    local ttGui = pg:FindFirstChild("TimeTrialsUI")
    local direct = ttGui and ttGui:FindFirstChild("StartBtn", true)
    if direct and direct:IsA("GuiObject") and meleeGuiIsActuallyVisible(direct) then
        return direct
    end

    -- Last structured fallback under the lobby frame.
    if lobbyFrame then
        local byName = lobbyFrame:FindFirstChild("StartBtn", true)
        if byName and byName:IsA("GuiObject") and meleeGuiIsActuallyVisible(byName) then
            return byName
        end
    end

    local best, bestScore = nil, -1
    for _, d in ipairs(pg:GetDescendants()) do
        if d:IsA("GuiObject") then
            local text = meleeTextFromGuiObject(d)
            local blob = (tostring(d.Name) .. " " .. text):lower()
            local isStartRun = blob:find("start%s*run") ~= nil or (blob:find("start") ~= nil and blob:find("run") ~= nil)
            if isStartRun and meleeGuiIsActuallyVisible(d) then
                local score = 90
                local p = d.Parent
                while p and p ~= pg do
                    local pn = tostring(p.Name):lower()
                    if pn:find("timetrial") or pn:find("time") or pn:find("lobby") then score = score + 20 end
                    if pn:find("nexus") or pn:find("meleerng") then score = score - 60 end
                    p = p.Parent
                end
                if score > bestScore then
                    best, bestScore = d, score
                end
            end
        end
    end
    return best
end

function meleeTimeTrialClickStartRun(reason)
    local target = meleeFindTimeTrialStartRunButton()
    if not target then return false end
    if not meleeTTStartClickAllowed(reason) then return false end
    return meleeRobustClickGuiTarget(target, reason or "StartRun")
end

local function meleeFindTimeTrialLeaveButton()
    local pg = LP and LP:FindFirstChildOfClass("PlayerGui")
    if not pg then return nil end

    -- Exact live path from your Explorer screenshot:
    -- PlayerGui.MainGUI.GeneralUI.LeaveTimeTrialBtn
    local main = pg:FindFirstChild("MainGUI") or (LP and LP:FindFirstChild("MainGUI"))
    local general = main and main:FindFirstChild("GeneralUI")
    local direct = general and general:FindFirstChild("LeaveTimeTrialBtn")
    if direct and direct:IsA("GuiObject") and meleeGuiIsActuallyVisible(direct) then
        return direct
    end

    -- Recursive fallback in case the button gets wrapped by another frame later.
    direct = general and general:FindFirstChild("LeaveTimeTrialBtn", true)
    if direct and direct:IsA("GuiObject") and meleeGuiIsActuallyVisible(direct) then
        return direct
    end

    local best, bestScore = nil, -1
    for _, d in ipairs(pg:GetDescendants()) do
        if d:IsA("GuiObject") then
            local text = meleeTextFromGuiObject(d)
            local blob = (tostring(d.Name) .. " " .. text):lower()
            local isLeave = blob:find("leave") ~= nil and (blob:find("trial") ~= nil or blob:find("time") ~= nil)
            if isLeave and meleeGuiIsActuallyVisible(d) then
                local score = 80
                local p = d.Parent
                while p and p ~= pg do
                    local pn = tostring(p.Name):lower()
                    if pn:find("timetrial") or pn:find("time") or pn:find("generalui") then score = score + 20 end
                    if pn:find("nexus") or pn:find("meleerng") then score = score - 60 end
                    p = p.Parent
                end
                if score > bestScore then
                    best, bestScore = d, score
                end
            end
        end
    end
    return best
end

function meleeTimeTrialClickLeave(reason)
    local target = meleeFindTimeTrialLeaveButton()
    if not target then return false end
    if not meleeTTLeaveClickAllowed(reason) then return false end
    return meleeRobustClickGuiTarget(target, reason or "LeaveTimeTrial")
end

function meleeTimeTrialClickStartRunBurst(seconds, interval, reason)
    _ttStartRunBurstUntil = math.max(_ttStartRunBurstUntil, os.clock() + (tonumber(seconds) or 6))
    if _ttStartRunBurstActive then return end
    _ttStartRunBurstActive = true
    task.spawn(function()
        local waitTime = math.max(tonumber(interval) or 1.35, 1.25)
        while GEN == _G.MeleeRNG_Gen and os.clock() < _ttStartRunBurstUntil do
            if meleeTimeTrialClickStartRun(reason or "burst") then
                task.wait(TT_START_CLICK_COOLDOWN_SEC)
            else
                task.wait(waitTime)
            end
        end
        _ttStartRunBurstActive = false
    end)
end

-- ── Safe add-ons mounted from one call (keeps the large UI IIFE from gaining many locals) ──
function meleeMountSafeDungeonMobTimeTrialAddons(MiscTab, SLbl, C)
    local function safeSet(lbl, txt)
        pcall(function()
            if lbl and lbl.Set then lbl.Set(txt) end
        end)
    end

    local function hrp()
        return getRoot()
    end

    local function dungeonFolder()
        return workspace:FindFirstChild("GeneratedDungeon")
    end

    local function parseRoomNumber(raw)
        local s = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local n = tonumber(s) or tonumber(s:match("Room[_%s%-]*(%d+)"))
        n = math.clamp(math.floor(tonumber(n) or tonumber(states.dungeonTargetRoomNumber) or 1), 1, 1000000)
        return n
    end

    local function roomName(n)
        return "Room_" .. tostring(parseRoomNumber(n))
    end

    local function findRoom(n)
        local f = dungeonFolder()
        return f and f:FindFirstChild(roomName(n)) or nil
    end

    local function roomIndex(model)
        if not model then return nil end
        return tonumber(tostring(model.Name):match("^Room_(%d+)$"))
    end

    local function roomBase(model)
        if not model then return nil end
        local b = model:FindFirstChild("BASE", true)
        if b and b:IsA("BasePart") then return b end
        if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then return model.PrimaryPart end
        return nil
    end

    local function tpToBase(base)
        local r = hrp()
        if not r or not base then return false end
        local y = (base.Size and base.Size.Y or 0) * 0.5 + 1
        r.CFrame = CFrame.new(base.Position + Vector3.new(0, y, 0))
        return true
    end

    local dungeonStatus = nil
    local function updateDungeonStatus(msg)
        safeSet(dungeonStatus, msg or ("Dungeon room target: " .. roomName(states.dungeonTargetRoomNumber)))
    end

    local function tpRoomNumber(n, why)
        local room = findRoom(n)
        local base = roomBase(room)
        if base and tpToBase(base) then
            updateDungeonStatus("TP " .. room.Name .. " BASE +1" .. (why and (" · " .. why) or ""))
            return true
        end
        updateDungeonStatus("Waiting for " .. roomName(n) .. " with BASE")
        return false
    end

    local function latestRoom()
        local f = dungeonFolder()
        if not f then return nil end
        local best, bestN = nil, -1
        for _, m in ipairs(f:GetChildren()) do
            local n = roomIndex(m)
            if n and n > bestN then best, bestN = m, n end
        end
        return best, bestN
    end

    local function onDungeonChild(ch)
        if GEN ~= _G.MeleeRNG_Gen then return end
        if not states.dungeonAutoTpNew then return end
        if not (ch and ch:IsA("Model") and roomIndex(ch)) then return end
        task.defer(function()
            for _ = 1, 20 do
                if GEN ~= _G.MeleeRNG_Gen then return end
                local b = roomBase(ch)
                if b then
                    tpToBase(b)
                    updateDungeonStatus("Auto TP new " .. ch.Name .. " BASE +1")
                    return
                end
                task.wait(0.05)
            end
        end)
    end

    MiscTab:Section("GeneratedDungeon")
    dungeonStatus = MiscTab:Label("Dungeon room target: " .. roomName(states.dungeonTargetRoomNumber))
    MiscTab:Toggle("Auto TP new rooms", "When GeneratedDungeon creates Room_N, TP to its BASE + 1 stud.", states.dungeonAutoTpNew, function(on)
        states.dungeonAutoTpNew = on == true
        saveSettings()
        updateDungeonStatus(states.dungeonAutoTpNew and "Auto TP new rooms ON" or "Auto TP new rooms OFF")
    end)
    MiscTab:Input("Room number", "Enter 1, 2, 958, or Room_958. Saved.", "Room_N", tostring(states.dungeonTargetRoomNumber), function(txt)
        states.dungeonTargetRoomNumber = parseRoomNumber(txt)
        saveSettings()
        updateDungeonStatus("Target set to " .. roomName(states.dungeonTargetRoomNumber))
    end)
    MiscTab:Toggle("Auto TP entered Room_N", "Keeps checking your entered Room_N and teleports when it exists.", states.dungeonAutoTpEntered, function(on)
        states.dungeonAutoTpEntered = on == true
        saveSettings()
        updateDungeonStatus(states.dungeonAutoTpEntered and ("Auto TP entered " .. roomName(states.dungeonTargetRoomNumber) .. " ON") or "Auto TP entered Room_N OFF")
    end)
    MiscTab:Button("🏯", "TP entered Room_N now", "Teleports to the entered real GeneratedDungeon.Room_N BASE +1 if it exists.", C.accent, function()
        tpRoomNumber(states.dungeonTargetRoomNumber, "manual")
    end)
    MiscTab:Button("⏭️", "TP latest room now", "Finds the highest existing Room_N and teleports to BASE +1.", C.green, function()
        local m, n = latestRoom()
        local b = roomBase(m)
        if b and tpToBase(b) then
            states.dungeonTargetRoomNumber = n or states.dungeonTargetRoomNumber
            saveSettings()
            updateDungeonStatus("TP latest " .. m.Name .. " BASE +1")
        else
            updateDungeonStatus("No GeneratedDungeon Room_N with BASE found")
        end
    end)

    addThread(task.spawn(function()
        local lastFolder = nil
        while true do
            if GEN ~= _G.MeleeRNG_Gen then break end
            local f = dungeonFolder()
            if f and f ~= lastFolder then
                lastFolder = f
                addConn(f.ChildAdded:Connect(onDungeonChild))
            end
            if states.dungeonAutoTpEntered then
                tpRoomNumber(states.dungeonTargetRoomNumber, "auto")
            end
            task.wait(states.dungeonAutoTpEntered and 0.35 or 1.25)
        end
    end))

    -- Mob anti-lag: hide non-root visuals and optionally keep roots on you.
    local mobHidden = {}
    local mobFx = {}
    local function mobRoot(model)
        if not model then return nil end
        local r = model:FindFirstChild("HumanoidRootPart")
        if r and r:IsA("BasePart") then return r end
        if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then return model.PrimaryPart end
        return nil
    end
    local function applyMobHardHide(model, hide)
        local root = mobRoot(model)
        if not model then return end
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") then
                if d ~= root then
                    if hide then
                        if mobHidden[d] == nil then mobHidden[d] = d.LocalTransparencyModifier end
                        d.LocalTransparencyModifier = 1
                        pcall(function() d.CastShadow = false end)
                    else
                        local old = mobHidden[d]
                        if old ~= nil then
                            d.LocalTransparencyModifier = old
                            mobHidden[d] = nil
                        end
                    end
                end
            elseif d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam")
                or d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles") then
                if hide then
                    if mobFx[d] == nil then mobFx[d] = d.Enabled end
                    d.Enabled = false
                else
                    local old = mobFx[d]
                    if old ~= nil then
                        pcall(function() d.Enabled = old end)
                        mobFx[d] = nil
                    end
                end
            end
        end
    end
    local function moveMobToMe(model)
        local r = hrp()
        local mr = mobRoot(model)
        if r and mr and model and model.Parent then
            pcall(function()
                model:PivotTo(r.CFrame * CFrame.new(0, 0, -3))
            end)
        end
    end
    local function sweepMobs(limit)
        local f = workspace:FindFirstChild("Mobs")
        if not f then return 0 end
        local n = 0
        for _, m in ipairs(f:GetChildren()) do
            if m:IsA("Model") then
                n = n + 1
                if states.mobSpawnOnMe then moveMobToMe(m) end
                if states.mobHardHide then applyMobHardHide(m, true) end
                if limit and n >= limit then break end
            end
        end
        return n
    end
    local mobStatus = nil
    MiscTab:Section("Extra Anti-Lag / Mobs")
    mobStatus = MiscTab:Label("Mobs: idle")
    MiscTab:Slider("Auto Equip Best interval", "Seconds between EquipBest calls. Higher = fewer weapon rebuild lag spikes.", {min=15, max=600, default=states.autoEquipBestInterval, format=function(v) return tostring(math.floor(v)) .. "s" end}, function(v)
        states.autoEquipBestInterval = math.clamp(math.floor(tonumber(v) or 60), 15, 600)
        saveSettings()
        safeSet(mobStatus, "Auto Equip Best interval: " .. tostring(states.autoEquipBestInterval) .. "s")
    end)
    MiscTab:Toggle("Mobs spawn/move on me", "When workspace.Mobs gets a mob, moves its root to your character locally.", states.mobSpawnOnMe, function(on)
        states.mobSpawnOnMe = on == true
        saveSettings()
        safeSet(mobStatus, states.mobSpawnOnMe and "Mob move ON" or "Mob move OFF")
    end)
    MiscTab:Toggle("Hard-hide mob visuals", "Hides non-root mob parts/effects but keeps HumanoidRootPart/PrimaryPart active.", states.mobHardHide, function(on)
        states.mobHardHide = on == true
        saveSettings()
        if not states.mobHardHide then
            for part, old in pairs(mobHidden) do pcall(function() if part and part.Parent then part.LocalTransparencyModifier = old end end); mobHidden[part] = nil end
            for fx, old in pairs(mobFx) do pcall(function() if fx and fx.Parent then fx.Enabled = old end end); mobFx[fx] = nil end
            safeSet(mobStatus, "Mob hard-hide OFF")
        else
            safeSet(mobStatus, "Mob hard-hide ON")
        end
    end)
    MiscTab:Button("🧲", "Move all mobs to me now", "One-time local PivotTo for current workspace.Mobs models.", C.green, function()
        local n = sweepMobs(nil)
        safeSet(mobStatus, "Moved/swept " .. tostring(n) .. " mobs")
    end)

    addThread(task.spawn(function()
        local lastFolder = nil
        while true do
            if GEN ~= _G.MeleeRNG_Gen then break end
            local f = workspace:FindFirstChild("Mobs")
            if f and f ~= lastFolder then
                lastFolder = f
                addConn(f.ChildAdded:Connect(function(ch)
                    if GEN ~= _G.MeleeRNG_Gen then return end
                    if ch:IsA("Model") then
                        task.defer(function()
                            if states.mobSpawnOnMe then moveMobToMe(ch) end
                            if states.mobHardHide then applyMobHardHide(ch, true) end
                        end)
                    end
                end))
            end
            if states.mobSpawnOnMe or states.mobHardHide then
                local n = sweepMobs(40)
                safeSet(mobStatus, "Mobs swept: " .. tostring(n) .. " · move=" .. tostring(states.mobSpawnOnMe) .. " · hide=" .. tostring(states.mobHardHide))
                -- stale cleanup prevents late lag from dead references
                for p in pairs(mobHidden) do if not (p and p.Parent) then mobHidden[p] = nil end end
                for fx in pairs(mobFx) do if not (fx and fx.Parent) then mobFx[fx] = nil end end
            end
            task.wait((states.mobSpawnOnMe or states.mobHardHide) and 0.75 or 1.5)
        end
    end))

    -- Time Trials goes last in Misc.
    local ttCur, ttReq = 0, 0
    local ttLabel = nil
    local function ttText()
        return "Time Trial kills: " .. tostring(ttCur) .. " / " .. tostring(ttReq)
    end
    local function parseTT(...)
        local args = table.pack(...)
        if args.n == 1 and type(args[1]) == "number" then
            ttReq = args[1]
        elseif args.n >= 2 and type(args[1]) == "number" and type(args[2]) == "number" then
            ttCur, ttReq = args[1], args[2]
        elseif args.n >= 1 and type(args[1]) == "table" then
            local t = args[1]
            ttCur = tonumber(t.CurrentKills or t.Kills or t.current or t.kills or ttCur) or ttCur
            ttReq = tonumber(t.RequiredKills or t.Required or t.Needed or t.required or t.needed or ttReq) or ttReq
        end
        safeSet(ttLabel, ttText())
    end

    MiscTab:Section("Time Trials")
    ttLabel = MiscTab:Label(ttText())
    MiscTab:Toggle("Auto Start Time Trial", "Fires StartTimeTrial on a slow timer while ON.", states.timeTrialAutoStart, function(on)
        states.timeTrialAutoStart = on == true
        saveSettings()
        safeSet(ttLabel, states.timeTrialAutoStart and "Auto Start Time Trial ON" or ttText())
        if states.timeTrialAutoStart and states.timeTrialAutoClickStartRun then
            meleeTimeTrialClickStartRunBurst(6, 1.35, "auto-start toggle")
        end
    end)
    MiscTab:Toggle("Auto click Start Run popup", "Clicks the green Start Run button slowly with a cooldown, not spam.", states.timeTrialAutoClickStartRun, function(on)
        states.timeTrialAutoClickStartRun = on == true
        saveSettings()
        safeSet(ttLabel, states.timeTrialAutoClickStartRun and "Auto-click Start Run ON" or "Auto-click Start Run OFF")
        if states.timeTrialAutoClickStartRun then
            meleeTimeTrialClickStartRunBurst(5, 1.35, "toggle")
        end
    end)
    MiscTab:Input("Leave/restart at Room_N", "When this room exists during a run, click LeaveTimeTrialBtn, then StartTimeTrial again.", "Room number", tostring(states.timeTrialLeaveAtRoom), function(txt)
        states.timeTrialLeaveAtRoom = math.clamp(math.floor(tonumber(tostring(txt):match("%d+") or txt) or 50), 1, 1000000)
        saveSettings()
        safeSet(ttLabel, "Auto leave target: Room_" .. tostring(states.timeTrialLeaveAtRoom))
    end)
    MiscTab:Toggle("Auto leave + restart at room", "Uses MainGUI.GeneralUI.LeaveTimeTrialBtn when your target Room_N appears, then starts another run.", states.timeTrialAutoLeaveRestart, function(on)
        states.timeTrialAutoLeaveRestart = on == true
        saveSettings()
        safeSet(ttLabel, states.timeTrialAutoLeaveRestart and ("Auto leave/restart at Room_" .. tostring(states.timeTrialLeaveAtRoom)) or "Auto leave/restart OFF")
    end)
    MiscTab:Button("🚪", "Click Leave Time Trial now", "Clicks PlayerGui.MainGUI.GeneralUI.LeaveTimeTrialBtn if visible.", C.red or C.sub, function()
        local ok = meleeTimeTrialClickLeave("manual")
        safeSet(ttLabel, ok and "Clicked Leave Time Trial" or "LeaveTimeTrialBtn not visible")
    end)
    MiscTab:Button("🖱️", "Click Start Run now", "Looks for the Time Trials Lobby Start Run button and clicks it.", C.green, function()
        local ok = meleeTimeTrialClickStartRun("manual")
        if not ok then meleeTimeTrialClickStartRunBurst(4, 1.25, "manual wait") end
        safeSet(ttLabel, ok and "Clicked Start Run" or "Waiting for Start Run popup...")
    end)
    MiscTab:Button("▶️", "Start Time Trial once", "Calls the existing StartTimeTrial remote once, then auto-clicks Start Run if the lobby opens.", C.green, function()
        local ok = fireR("StartTimeTrial")
        if states.timeTrialAutoClickStartRun then
            meleeTimeTrialClickStartRunBurst(8, 1.35, "start once")
        end
        safeSet(ttLabel, ok and "StartTimeTrial fired · waiting for Start Run" or "StartTimeTrial remote missing/failed")
    end)
    MiscTab:Button("🔄", "Refresh Time Trial info", "Invokes time-left and possible-spawn-position remotes if present; prints results.", C.accent, function()
        local tl = invokeR("GetUpdateTimeLeft")
        local pos = invokeR("GetPossibleSpawnPositionsForTimeTrial")
        print("[MeleeRNG/TimeTrial] timeLeft=", tl, " possibleSpawnPositions=", typeof(pos), pos)
        safeSet(ttLabel, ttText() .. " · refresh printed")
    end)
    MiscTab:Button("🧪", "Print Time Trial remotes", "Prints the classes of the known Time Trial remotes.", C.sub, function()
        local names = {"StartTimeTrial", "SpawnMob", "UpdateTimeTrialKills", "GetUpdateTimeLeft", "GetPossibleSpawnPositionsForTimeTrial", "UpdateStartPage", "UpdateTimeTrialLobby"}
        for _, name in ipairs(names) do
            local r = R(name)
            print("[MeleeRNG/TimeTrial]", name, r and r.ClassName or "MISSING")
        end
        safeSet(ttLabel, "Printed Time Trial remotes")
    end)
    task.defer(function()
        local r = R("UpdateTimeTrialKills")
        if r and (r:IsA("RemoteEvent") or r.ClassName == "UnreliableRemoteEvent") then
            addConn(r.OnClientEvent:Connect(parseTT))
        end
        local lobby = R("UpdateTimeTrialLobby")
        if lobby and (lobby:IsA("RemoteEvent") or lobby.ClassName == "UnreliableRemoteEvent") then
            addConn(lobby.OnClientEvent:Connect(function()
                if states.timeTrialAutoClickStartRun then
                    meleeTimeTrialClickStartRunBurst(5, 1.35, "lobby event")
                end
            end))
        end
    end)
    addThread(task.spawn(function()
        while true do
            if GEN ~= _G.MeleeRNG_Gen then break end
            if states.timeTrialAutoStart then
                pcall(function() fireR("StartTimeTrial") end)
                if states.timeTrialAutoClickStartRun then
                    meleeTimeTrialClickStartRunBurst(8, 1.50, "auto loop")
                end
                task.wait(6)
            else
                task.wait(1)
            end
        end
    end))
    addThread(task.spawn(function()
        local lastLeaveModel = nil
        local nextLeaveAllowed = 0
        while true do
            if GEN ~= _G.MeleeRNG_Gen then break end
            if states.timeTrialAutoLeaveRestart then
                local target = math.clamp(math.floor(tonumber(states.timeTrialLeaveAtRoom) or 50), 1, 1000000)
                local room = findRoom(target)
                local newest, newestN = latestRoom()
                if not room and newestN and newestN >= target then
                    room = newest
                end
                if room and room ~= lastLeaveModel and os.clock() >= nextLeaveAllowed and meleeFindTimeTrialLeaveButton() then
                    lastLeaveModel = room
                    nextLeaveAllowed = os.clock() + 10
                    safeSet(ttLabel, "Room target hit (" .. tostring(room.Name) .. ") · leaving/restarting")
                    if meleeTimeTrialClickLeave("auto room target") then
                        task.delay(1.25, function()
                            if GEN ~= _G.MeleeRNG_Gen then return end
                            pcall(function() fireR("StartTimeTrial") end)
                            if states.timeTrialAutoClickStartRun then
                                meleeTimeTrialClickStartRunBurst(8, 1.50, "auto restart after leave")
                            end
                        end)
                    end
                end
                task.wait(0.35)
            else
                task.wait(1.25)
            end
        end
    end))
    addThread(task.spawn(function()
        while true do
            if GEN ~= _G.MeleeRNG_Gen then break end
            if states.timeTrialAutoClickStartRun then
                meleeTimeTrialClickStartRun("watch")
                task.wait(2.25)
            else
                task.wait(2.5)
            end
        end
    end))
end



-- Luau ~200 locals: window UI + return SLbl live in this IIFE; heavy Misc blocks use meleeGuiMountMisc* helpers (Stats+Ascend+Aura is its own function); re-exec init stays outside below.
local SLbl = (function()
-- --------------------------------------------------------------------------
-- UI — Build window (tabs: Move → ESP → Areas → Upgrades → Sacrifice → Misc)
-- --------------------------------------------------------------------------

local Win  = Lib:Window({ title = "Melee" })
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

local function meleeUiAddCorner(obj, r)
    if not obj or obj:FindFirstChildOfClass("UICorner") then return end
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 6)
    c.Parent = obj
end

local function meleeUiAddStroke(obj, color, alpha, thickness)
    if not obj then return end
    local s = obj:FindFirstChild("MeleeRNG_NewUIStroke")
    if not s then
        s = Instance.new("UIStroke")
        s.Name = "MeleeRNG_NewUIStroke"
        s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        s.Parent = obj
    end
    s.Color = color or C.border
    s.Transparency = alpha or 0.35
    s.Thickness = thickness or 1
end

local function meleeUiRestyleObject(obj)
    if not obj or uiBgIsOwnObject(obj) or obj:GetAttribute("MeleeRNG_NewUIStyled") then return end
    obj:SetAttribute("MeleeRNG_NewUIStyled", true)

    if obj:IsA("Frame") then
        if obj.BackgroundTransparency < 1 then
            local sx, sy = obj.AbsoluteSize.X, obj.AbsoluteSize.Y
            if sx >= 500 and sy >= 300 then
                obj.BackgroundColor3 = Color3.fromRGB(6, 8, 12)
                obj.BackgroundTransparency = math.max(obj.BackgroundTransparency, 0.08)
                meleeUiAddCorner(obj, 8)
                meleeUiAddStroke(obj, C.accentD, 0.55, 1)
            elseif sx >= 160 and sy >= 30 then
                obj.BackgroundColor3 = obj.BackgroundColor3:Lerp(C.card, 0.72)
                obj.BackgroundTransparency = math.max(obj.BackgroundTransparency, 0.16)
                meleeUiAddCorner(obj, 6)
                meleeUiAddStroke(obj, C.border, 0.55, 1)
            end
        end
    elseif obj:IsA("ScrollingFrame") then
        obj.BackgroundColor3 = Color3.fromRGB(8, 11, 16)
        obj.BackgroundTransparency = math.max(obj.BackgroundTransparency, 0.18)
        obj.ScrollBarThickness = math.clamp(obj.ScrollBarThickness > 0 and obj.ScrollBarThickness or 4, 3, 5)
        obj.ScrollBarImageColor3 = C.accent
        meleeUiAddCorner(obj, 6)
        meleeUiAddStroke(obj, C.border, 0.55, 1)
    elseif obj:IsA("TextLabel") then
        obj.BackgroundTransparency = math.max(obj.BackgroundTransparency, 0.78)
        obj.Font = (obj.TextSize >= 13) and Enum.Font.GothamMedium or Enum.Font.Gotham
        if obj.TextColor3 == Color3.new(1, 1, 1) or obj.TextColor3 == Color3.fromRGB(255, 255, 255) then
            obj.TextColor3 = C.text
        end
        obj.TextWrapped = obj.TextWrapped or obj.AbsoluteSize.X > 220
    elseif obj:IsA("TextButton") then
        obj.AutoButtonColor = false
        obj.Font = Enum.Font.GothamMedium
        if obj.TextColor3 == Color3.new(1, 1, 1) or obj.TextColor3 == Color3.fromRGB(255, 255, 255) then
            obj.TextColor3 = C.text
        end
        if obj.BackgroundTransparency < 1 then
            obj.BackgroundColor3 = obj.BackgroundColor3:Lerp(Color3.fromRGB(18, 23, 33), 0.68)
            obj.BackgroundTransparency = math.max(obj.BackgroundTransparency, 0.04)
            meleeUiAddCorner(obj, 6)
            meleeUiAddStroke(obj, C.border, 0.5, 1)
        end
    elseif obj:IsA("TextBox") then
        obj.Font = Enum.Font.Gotham
        obj.TextColor3 = C.text
        obj.PlaceholderColor3 = C.sub
        obj.BackgroundColor3 = Color3.fromRGB(8, 11, 16)
        obj.BackgroundTransparency = 0.04
        meleeUiAddCorner(obj, 6)
        meleeUiAddStroke(obj, C.border, 0.45, 1)
    end
end

local function meleeApplyNewUiSkin()
    task.defer(function()
        task.wait(0.35)
        local root = uiBgFindRoot()
        if not root then return end

        local window = uiBgFindWindowFrame(root) or root
        if window and window:IsA("GuiObject") then
            window.ClipsDescendants = true
            window.BackgroundColor3 = Color3.fromRGB(6, 8, 12)
            window.BackgroundTransparency = 0.08
            meleeUiAddCorner(window, 8)
            meleeUiAddStroke(window, C.accent, 0.42, 1)

            if not window:FindFirstChild("MeleeRNG_NewUIAccent") then
                local accent = Instance.new("Frame")
                accent.Name = "MeleeRNG_NewUIAccent"
                accent.Size = UDim2.new(1, 0, 0, 2)
                accent.Position = UDim2.new(0, 0, 0, 0)
                accent.BackgroundColor3 = C.accent
                accent.BorderSizePixel = 0
                accent.ZIndex = 999
                accent.Parent = window
            end
        end

        for _, d in ipairs(root:GetDescendants()) do
            meleeUiRestyleObject(d)
        end
        addConn(root.DescendantAdded:Connect(function(d)
            task.defer(function()
                task.wait(0.03)
                if GEN ~= _G.MeleeRNG_Gen then return end
                meleeUiRestyleObject(d)
            end)
        end))
    end)
end

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
-- Safe pulse batching: avoids resizing every sword every Heartbeat.
-- More swords now spread over several BIG frames instead of all spiking physics at once.
local HITBOX_BATCH_MAX = 24
local HITBOX_HOLD_FRAMES = 2
local _hitboxCursor = 1
local _hitboxLastBig = {}
local _hitboxHold = 0
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
                    if _pulseActive and desc.Size ~= _TINY_V then
                        pcall(function() desc.Size = _TINY_V end)
                    end
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

local function perfApplyWeaponVisualDesc(d, hide)
    if not d then return end
    if d:IsA("BasePart") then
        -- Do not hide/compress combat hitboxes. Hide Own Weapons should hide visuals only.
        if d.Name == "Hitbox" then return end
        if hide then
            if _perfPartLTM[d] == nil then
                _perfPartLTM[d] = d.LocalTransparencyModifier
            end
            d.LocalTransparencyModifier = 1
            pcall(function() d.CastShadow = false end)
        else
            local prev = _perfPartLTM[d]
            if prev ~= nil then
                d.LocalTransparencyModifier = prev
                _perfPartLTM[d] = nil
            end
        end
    elseif d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") then
        if hide then
            if _perfEffOn[d] == nil then
                _perfEffOn[d] = d.Enabled
            end
            d.Enabled = false
        else
            local was = _perfEffOn[d]
            if was ~= nil then
                d.Enabled = was
                _perfEffOn[d] = nil
            end
        end
    end
end

local function perfSweepWeaponFolder(folder, hide)
    if not folder then return end
    for _, m in ipairs(folder:GetChildren()) do
        if m:IsA("Model") then
            for _, d in ipairs(m:GetDescendants()) do
                perfApplyWeaponVisualDesc(d, hide)
            end
        end
    end
end

-- Event watcher prevents the “hidden weapon randomly reappears” flash without
-- constantly scanning the whole weapon folder. The slow sweep remains as backup.
local _perfOwnWeaponWatchedFolder = nil
local _perfOwnWeaponDescConn = nil
local function perfUnwatchOwnWeaponFolder()
    if _perfOwnWeaponDescConn then
        pcall(function() _perfOwnWeaponDescConn:Disconnect() end)
        _perfOwnWeaponDescConn = nil
    end
    _perfOwnWeaponWatchedFolder = nil
end

local function perfWatchOwnWeaponFolderIfNeeded()
    local folder = workspace:FindFirstChild(LP.Name)
    if folder == _perfOwnWeaponWatchedFolder then return end
    perfUnwatchOwnWeaponFolder()
    _perfOwnWeaponWatchedFolder = folder
    if folder then
        _perfOwnWeaponDescConn = folder.DescendantAdded:Connect(function(d)
            if GEN ~= _G.MeleeRNG_Gen then return end
            if states.perfHideOwnWeapons then
                task.defer(function()
                    if GEN ~= _G.MeleeRNG_Gen or not (d and d.Parent) then return end
                    perfApplyWeaponVisualDesc(d, true)
                end)
            end
            _hitboxCacheDirty = true
        end)
        addConn(_perfOwnWeaponDescConn)
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
local _perfWeaponAcc = 0

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
                perfUnwatchOwnWeaponFolder()
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

        -- Never sweep weapon folders every Heartbeat; that becomes a late-game lag source.
        task.wait((ow or sw or (hv and not sw)) and 0.35 or 0.20)
        _perfWeaponAcc = _perfWeaponAcc + 1
        local doWeaponSweep = false
        if _perfWeaponAcc >= 6 then
            _perfWeaponAcc = 0
            doWeaponSweep = true
        end

        if sw then
            perfWatchOwnWeaponFolderIfNeeded()
            if doWeaponSweep then
                perfSweepWeaponFolder(workspace:FindFirstChild(LP.Name), true)
            end
            _perfLastOwnWeaponsHidden = true
        elseif _perfLastOwnWeaponsHidden then
            perfSweepWeaponFolder(workspace:FindFirstChild(LP.Name), false)
            perfUnwatchOwnWeaponFolder()
            _perfLastOwnWeaponsHidden = false
        end

        if ow then
            if doWeaponSweep then
                for _, plr in ipairs(playersNow) do
                    if plr ~= LP then
                        perfSweepWeaponFolder(workspace:FindFirstChild(plr.Name), true)
                    end
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

            -- Duty cycle with batching: only a small rolling batch goes BIG.
            -- This keeps Touched size edges, but avoids "more swords = every sword resized every frame" lag.
            _dutyTick = _dutyTick + 1
            local duty = math.clamp(math.floor(tonumber(states.hitboxDutyCycle) or 2), 2, HITBOX_DUTY_MAX)
            _pulsePhase = ((_dutyTick - 1) % duty) == 0
            local hCache = _hitboxCache
            local nh = #hCache

            if _pulsePhase and nh > 0 then
                for i = 1, #_hitboxLastBig do
                    local hb = _hitboxLastBig[i]
                    if hb and hb.Parent and hb.Size ~= _TINY_V then
                        hb.Size = _TINY_V
                    end
                    _hitboxLastBig[i] = nil
                end

                local batch = math.min(HITBOX_BATCH_MAX, nh)
                for _ = 1, batch do
                    if _hitboxCursor > nh then _hitboxCursor = 1 end
                    local hb = hCache[_hitboxCursor]
                    _hitboxCursor = _hitboxCursor + 1
                    if hb and hb.Parent then
                        if hb.Size ~= _pulseBigVec then hb.Size = _pulseBigVec end
                        _hitboxLastBig[#_hitboxLastBig + 1] = hb
                    else
                        _hitboxCacheDirty = true
                    end
                end
                _hitboxHold = HITBOX_HOLD_FRAMES
            elseif #_hitboxLastBig > 0 then
                _hitboxHold = _hitboxHold - 1
                if _hitboxHold <= 0 then
                    for i = 1, #_hitboxLastBig do
                        local hb = _hitboxLastBig[i]
                        if hb and hb.Parent and hb.Size ~= _TINY_V then
                            hb.Size = _TINY_V
                        end
                        _hitboxLastBig[i] = nil
                    end
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
        _hitboxLastBig = {}
        _hitboxCursor = 1
        _hitboxHold = 0
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

MoveTab:Section("Movement / Local Utilities")
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
local autoEquipBestToggle = MoveTab:Toggle("⚔️ Auto Equip Best", "Remotes.EquipBest:FireServer() on a configurable interval — higher interval = fewer weapon rebuild spikes", states.autoEquipBest, function(on)
    states.autoEquipBest = on == true
    saveSettings()
    SLbl.Text = on and ("Auto Equip Best ON (every " .. tostring(states.autoEquipBestInterval) .. "s)") or "Auto Equip Best OFF"
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
        if states.autoEquipBest then
            pcall(function()
                fireR("EquipBest")
            end)
            task.wait(math.clamp(math.floor(tonumber(states.autoEquipBestInterval) or 60), 15, 600))
        else
            task.wait(1)
        end
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
MiscTab:Label("Old logic kept. The background is local-only in PlayerGui. It loops through PNG sprite sheets first; raw frames are static fallback only.")
local uiBgStatusLbl = MiscTab:Label(uiBgStatusText())
MiscTab:Toggle("Local PNG Background", "ON = loop MeleeRNG_UI_Background_manifest/sheets behind this UI for only your client.", states.uiPngBackground, function(on)
    states.uiPngBackground = on == true
    saveSettings()
    meleeApplyLocalPngBackground(states.uiPngBackground)
    if uiBgStatusLbl and uiBgStatusLbl.Set then uiBgStatusLbl.Set(uiBgStatusText()) end
    SLbl.Text = uiBgStatusText()
end)
MiscTab:Button("↻", "Reload PNG BG", "Clears cached PNG sheets/frames and reapplies the client-only background.", C.accent, function()
    _uiBgCachedSheets = nil
    _uiBgCachedLocalAssets = nil
    local ok = (uiBgEnsureSpriteSheets() ~= nil) or (uiBgEnsureLocalPngFrames() ~= nil)
    meleeApplyLocalPngBackground(states.uiPngBackground)
    if uiBgStatusLbl and uiBgStatusLbl.Set then uiBgStatusLbl.Set(uiBgStatusText()) end
    SLbl.Text = ok and ("Local PNG ready - " .. tostring(UI_BG_LAST_STATUS)) or ("Local PNG not ready - " .. tostring(UI_BG_LAST_STATUS))
end)

task.defer(function()
    task.wait(0.4)
    meleeApplyLocalPngBackground(states.uiPngBackground)
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

-- Safe add-ons are mounted at the very bottom of Misc.
meleeMountSafeDungeonMobTimeTrialAddons(MiscTab, SLbl, C)

meleeApplyNewUiSkin()

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
