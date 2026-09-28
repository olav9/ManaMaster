local addonName, ns = ...

-- Shared core: fight lifecycle, per-spell spending, buff uptime, history, display and commands.
-- Where mana numbers come from differs per client, so that lives in a client file (Mana_Forever.lua)
-- that provides the ns.Mana hooks called below:
--   Init()                     addon loaded, saved variables ready
--   OnFightStart(fight, now)   before the fight becomes current; set the client's mana fields on it
--   OnFightEnd(fight, now)     while the fight is still current; close out the client's mana fields
--   OnSpellCast(spellID, now)  any successful player cast; return true if it was handled (e.g. a potion)
--   OnManaSpend(cost, now)     a cast that cost mana, in or out of combat
--   OnPowerEvent(mana)         a mana UNIT_POWER_FREQUENT; mana is the readable value or nil
--   OnAuras(fight, now)        the player's auras changed during a fight
--   OnCombatEnd()              the player left combat

local MANA = Enum.PowerType.Mana
local MAX_HISTORY = 50
local PRECOMBAT_WINDOW = 3 -- seconds before combat whose casts count toward the fight
local MAX_AURA_SCAN = 64 -- buff slots to check; a slot that errors doesn't tell us whether more follow
local PREFIX = "|cff3fa9f5ManaMaster|r "

-- Buffs whose uptime is tracked per fight, by English name so every rank matches. Add names here to track more.
local REGEN_BUFFS = {
    ["Mana Spring"] = true,
    ["Mana Tide Totem"] = true,
    ["Blessing of Wisdom"] = true,
    ["Greater Blessing of Wisdom"] = true,
    ["Innervate"] = true,
    ["Water Shield"] = true,
    ["Mage Armor"] = true,
    ["Evocation"] = true,
    ["Spirit Tap"] = true,
    ["Divine Spirit"] = true,
    ["Prayer of Spirit"] = true,
    ["Replenishment"] = true,
    ["Aspect of the Viper"] = true,
    ["Mana Regeneration"] = true, -- Mageblood Potion, Nightfin Soup and similar consumables
}

local defaults = {
    enabled = true,
    showMinimapButton = true,
    minimapAngle = 225, -- bottom-left of the minimap
}

local frame = CreateFrame("Frame")
local encounterActive = false
local recentCasts = {} -- mana casts made out of combat, within PRECOMBAT_WINDOW
ns.current = nil -- the fight being tracked, nil when out of combat
ns.debugMode = false -- not saved; turn on with /mm debug
ns.MANA = MANA
ns.PREFIX = PREFIX

-- Retail can hide combat values from addons ("secret values"); skip anything we can't read.
local function IsReadable(value)
    return value ~= nil and not (issecretvalue and issecretvalue(value))
end

local function Debug(...)
    if ns.debugMode then
        print("|cff888888MM debug:|r", ...)
    end
end

-- Describes a value without doing math on it, since secret values can't be compared or added.
local function Describe(value)
    if value == nil then return "nil" end
    if issecretvalue and issecretvalue(value) then return "SECRET" end
    return tostring(value)
end

local function GetMana()
    local mana = UnitPower("player", MANA)
    if IsReadable(mana) then return mana end
end

-- Name of the player's target if it's something they can attack, nil otherwise or if it's hidden.
local function GetHostileTargetName()
    if not UnitExists("target") then return end
    local canAttack = UnitCanAttack("player", "target")
    if not IsReadable(canAttack) or not canAttack then return end
    local name = UnitName("target")
    if IsReadable(name) then return name end
end

local function FormatNumber(n)
    return BreakUpLargeNumbers(math.floor(n + 0.5))
end

local function FormatDuration(seconds)
    return string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
end

-- A table of per-spell entries (fight.spells, fight.gains, fight.drains) as a list, most mana first.
local function SortedEntries(entries)
    local list = {}
    for key, data in pairs(entries or {}) do
        -- Older saved fights are keyed by spell name and don't store the name or rank on the entry.
        table.insert(list, {
            name = data.name or key,
            rank = data.rank,
            casts = data.casts,
            mana = data.mana,
            spellID = data.spellID,
        })
    end
    table.sort(list, function(a, b) return a.mana > b.mana end)
    return list
end

-- Total mana from potions, runes and gems (fight.gains); 0 for fights saved before they were tracked.
local function RestoredTotal(fight)
    local total = 0
    for _, entry in pairs(fight.gains or {}) do
        total = total + entry.mana
    end
    return total
end

-- The spell's subtext, e.g. "Rank 2"; nil when it has none.
local function GetSpellRank(spellID)
    if not C_Spell.GetSpellSubtext then return end
    local subtext = C_Spell.GetSpellSubtext(spellID)
    if IsReadable(subtext) and subtext ~= "" then return subtext end
end

local function GetManaCost(spellID)
    local cost = 0
    for _, powerCost in ipairs(C_Spell.GetSpellPowerCost(spellID) or {}) do
        if powerCost.type == MANA and IsReadable(powerCost.cost) then
            cost = cost + powerCost.cost
        end
    end
    return cost
end

-- Returns the player's auras (filter "HELPFUL" or "HARMFUL") whose names are in `names`, as
-- name -> { spellID, icon }, plus how many auras couldn't be read. In combat on WoW Forever,
-- GetAuraDataByIndex throws on auras the game marks secret (e.g. Blood Fury) instead of returning them,
-- so each slot is read in a pcall and skipped on error.
local function ScanAuras(filter, names)
    local found, hidden = {}, 0
    for i = 1, MAX_AURA_SCAN do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, filter)
        if not ok then
            hidden = hidden + 1
        elseif not aura then
            break -- past the last buff
        else
            local name = aura.name
            if not IsReadable(name) then
                hidden = hidden + 1
            elseif names[name] then
                found[name] = {
                    spellID = IsReadable(aura.spellId) and aura.spellId or nil,
                    icon = IsReadable(aura.icon) and aura.icon or nil,
                }
            end
        end
    end
    return found, hidden
end

ns.IsReadable = IsReadable
ns.Debug = Debug
ns.Describe = Describe
ns.GetMana = GetMana
ns.ScanAuras = ScanAuras
ns.RestoredTotal = RestoredTotal
ns.FormatNumber = FormatNumber
ns.FormatDuration = FormatDuration
ns.SortedEntries = SortedEntries

local DISPLAY_LINGER = 5 -- seconds the final number stays up after a fight

local display = CreateFrame("Frame", nil, UIParent)
display:SetSize(1, 1)
display:SetPoint("CENTER")
display:SetFrameStrata("HIGH")
display:Hide()

local displayText = display:CreateFontString(nil, "OVERLAY")
displayText:SetFont(STANDARD_TEXT_FONT, 64, "OUTLINE")
displayText:SetTextColor(0.25, 0.66, 0.96)
displayText:SetPoint("CENTER")

-- Live mana bar under the spent number. The player's mana is secret on WoW Forever, so it can't be read,
-- but secret values can be handed straight to StatusBar:SetValue and FontString:SetText (via
-- AbbreviateNumbers) and the client renders them. Never do math or comparisons on the value here.
local MANA_BAR_WIDTH, MANA_BAR_HEIGHT = 220, 16

local manaBar = CreateFrame("StatusBar", nil, display)
manaBar:SetSize(MANA_BAR_WIDTH, MANA_BAR_HEIGHT)
manaBar:SetPoint("TOP", displayText, "BOTTOM", 0, -6)
manaBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
manaBar:SetStatusBarColor(0.0, 0.44, 0.87)

local manaBarBackground = manaBar:CreateTexture(nil, "BACKGROUND")
manaBarBackground:SetAllPoints()
manaBarBackground:SetColorTexture(0, 0, 0, 0.6)

-- Current and max are separate font strings, since a secret value can't be joined into one string.
local manaBarValue = manaBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
manaBarValue:SetPoint("RIGHT", manaBar, "CENTER", -2, 0)
local manaBarMax = manaBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
manaBarMax:SetPoint("LEFT", manaBar, "CENTER", 2, 0)

local manaBarUnavailable = false -- set if the client refuses the secret value, so we stop trying

local function UpdateManaBar()
    if manaBarUnavailable or not display:IsShown() then return end
    local ok, err = pcall(function()
        local maxMana = UnitPowerMax("player", MANA)
        local mana = UnitPower("player", MANA)
        manaBar:SetMinMaxValues(0, maxMana)
        manaBar:SetValue(mana)
        manaBarValue:SetText(AbbreviateNumbers(mana))
        manaBarMax:SetText(IsReadable(maxMana) and ("/ " .. BreakUpLargeNumbers(maxMana)) or "")
    end)
    if not ok then
        manaBarUnavailable = true
        manaBar:Hide()
        Debug("mana bar unavailable:", tostring(err))
    end
end

local displayGeneration = 0 -- lets a pending hide from an old fight skip a newer one

local function UpdateDisplay(spent)
    displayText:SetText(FormatNumber(spent))
end

-- The on-screen spent number and mana bar are a debug aid: only shown while debug mode is on.
local function ShowDisplay()
    displayGeneration = displayGeneration + 1
    UpdateDisplay(0)
    if not ns.debugMode then return end
    display:Show()
    UpdateManaBar()
end

local function HideDisplayLater()
    local generation = displayGeneration
    C_Timer.After(DISPLAY_LINGER, function()
        if generation == displayGeneration then
            display:Hide()
        end
    end)
end

local function PrintSummary(fight)
    local result = ""
    if fight.success == true then
        result = " (kill)"
    elseif fight.success == false then
        result = " (wipe)"
    end
    print(PREFIX .. fight.name .. result .. " - " .. FormatDuration(fight.duration))

    if fight.recovered then
        local net = fight.recovered - fight.spent
        local netText = (net >= 0 and "+" or "-") .. FormatNumber(math.abs(net))
        local lowestPct = fight.maxMana > 0 and (fight.lowestMana or 0) / fight.maxMana * 100 or 0
        print(string.format("  Spent %s | Recovered %s | Net %s | Lowest %d%%",
            FormatNumber(fight.spent), FormatNumber(fight.recovered), netText, lowestPct))
    elseif fight.regen then
        -- Mana was hidden: spent is from spell costs, regen and potions are estimated.
        local restored = RestoredTotal(fight)
        local net = fight.regen + restored - fight.spent
        local restoredText = restored > 0 and (" | Potions ~" .. FormatNumber(restored)) or ""
        print(string.format("  Spent %s | Regen ~%s%s (est.) | Net %s%s",
            FormatNumber(fight.spent), FormatNumber(fight.regen), restoredText,
            net >= 0 and "+" or "-", FormatNumber(math.abs(net))))
    else
        -- Fights saved before regen was estimated.
        print(string.format("  Spent %s (from spell costs)", FormatNumber(fight.spent)))
    end

    -- Fights saved before wasted regen was tracked have no wastedFull.
    if fight.gainsMeasured then
        -- TBC: exact per-source gains and drains from the combat log.
        local drained = 0
        for _, entry in pairs(fight.drains or {}) do drained = drained + entry.mana end
        print(string.format("  From logged sources %s | Overenergized %s | Drained %s",
            FormatNumber(RestoredTotal(fight)), FormatNumber(fight.wastedFull), FormatNumber(drained)))
    elseif fight.wastedFull then
        local wasted = fight.wastedFull + fight.wastedBlocked
        if wasted >= 1 then
            print(string.format("  Wasted regen ~%s (at full mana %s, blocked %s)%s", FormatNumber(wasted),
                FormatNumber(fight.wastedFull), FormatNumber(fight.wastedBlocked),
                fight.startManaAssumed and " - start mana assumed full" or ""))
        end
    end

    local spells = SortedEntries(fight.spells)
    for i = 1, math.min(3, #spells) do
        local s = spells[i]
        local rank = s.rank and (" (" .. s.rank .. ")") or ""
        print(string.format("  %d. %s%s - %s (%d casts)", i, s.name, rank, FormatNumber(s.mana), s.casts))
    end
end

-- Per-spell spending uses the spell's listed mana cost, since mana changes can't be tied to a cast directly.
-- The same costs drive the total when the game hides the player's mana.
local function AddCast(fight, spellID, cost)
    fight.castSpent = fight.castSpent + cost
    if fight.manaHidden then
        UpdateDisplay(fight.castSpent)
    end

    -- Keyed by spell ID so each rank of a spell gets its own entry.
    local entry = fight.spells[spellID]
    if not entry then
        entry = {
            casts = 0,
            mana = 0,
            spellID = spellID,
            name = C_Spell.GetSpellName(spellID) or tostring(spellID),
            rank = GetSpellRank(spellID),
        }
        fight.spells[spellID] = entry
    end
    entry.casts = entry.casts + 1
    entry.mana = entry.mana + cost
end

-- Starts or stops uptime timers for each tracked buff to match what the player has now, then lets the
-- client file react to the change (e.g. regen-blocking debuffs).
local function UpdateAuras(fight, now)
    ns.Mana.OnAuras(fight, now)

    local active = ScanAuras("HELPFUL", REGEN_BUFFS)
    for name, info in pairs(active) do
        local entry = fight.buffs[name]
        if not entry then
            entry = { uptime = 0, spellID = info.spellID, icon = info.icon }
            fight.buffs[name] = entry
        end
        entry.since = entry.since or now
    end
    for name, entry in pairs(fight.buffs) do
        if entry.since and not active[name] then
            entry.uptime = entry.uptime + (now - entry.since)
            entry.since = nil
        end
    end
end

local function StartFight(encounterName)
    local current = ns.current
    if current then
        -- Combat started before the boss pull; label the fight with the encounter.
        if encounterName then
            current.name = encounterName
            current.isEncounter = true
        end
        return
    end
    if not ns.db.enabled then return end

    local maxMana = UnitPowerMax("player", MANA)
    Debug("fight start", encounterName or "Combat", "max mana", Describe(maxMana), "mana", Describe(UnitPower("player", MANA)),
        "target", Describe(UnitName("target")))
    if not IsReadable(maxMana) or maxMana == 0 then return end

    local now = GetTime()
    local mana = GetMana()
    local targetName = GetHostileTargetName()
    local fight = {
        name = encounterName or targetName or "Combat",
        isEncounter = encounterName ~= nil,
        targetName = targetName,
        zone = GetRealZoneText(),
        date = time(),
        startClock = now,
        maxMana = maxMana,
        lastMana = mana,
        lowestMana = mana,
        spent = 0,
        recovered = 0,
        castSpent = 0, -- sum of listed spell costs, used when mana is hidden
        manaHidden = mana == nil,
        spells = {},
        buffs = {}, -- regen buff name -> { uptime, spellID, icon, since }
    }
    -- The client file sets its mana fields before the fight becomes current, so anything it settles up to
    -- now (like out-of-combat regen) isn't counted toward this fight.
    ns.Mana.OnFightStart(fight, now)
    ns.current = fight
    ShowDisplay()

    -- Pre-combat casts count toward the fight. Their mana was spent before combat's own mana tracking
    -- began, so add them to spent. The client file already saw them through OnManaSpend.
    for _, cast in ipairs(recentCasts) do
        if now - cast.time <= PRECOMBAT_WINDOW then
            Debug("pre-combat cast", cast.spellID, "cost", cast.cost)
            fight.spent = fight.spent + cast.cost
            AddCast(fight, cast.spellID, cast.cost)
        end
    end

    UpdateAuras(fight, now)
    if ns.debugMode then
        local found, hidden = ScanAuras("HELPFUL", REGEN_BUFFS)
        local names = {}
        for name in pairs(found) do table.insert(names, name) end
        Debug("regen buffs", #names > 0 and table.concat(names, ", ") or "none", "| unreadable buffs", hidden)
    end
    wipe(recentCasts)
    if not fight.manaHidden then
        UpdateDisplay(fight.spent)
    end
end

local function EndFight(success)
    local fight = ns.current
    if not fight then return end
    local now = GetTime()
    ns.Mana.OnFightEnd(fight, now) -- while the fight is still current, so the last stretch is booked to it
    ns.current = nil

    -- Close any buff still running when the fight ends.
    for _, entry in pairs(fight.buffs) do
        if entry.since then
            entry.uptime = entry.uptime + (now - entry.since)
            entry.since = nil
        end
    end

    fight.duration = now - fight.startClock
    fight.endMana = fight.lastMana
    fight.success = success
    fight.startClock = nil
    fight.lastMana = nil
    -- If mana was hidden at any point, the delta totals are incomplete; fall back to listed spell costs.
    if fight.manaHidden then
        fight.spent = fight.castSpent
        fight.recovered = nil
        fight.lowestMana = nil
    end
    fight.castSpent = nil
    HideDisplayLater()

    local fights = ns.db.fights
    table.insert(fights, fight)
    while #fights > MAX_HISTORY do
        table.remove(fights, 1)
    end

    -- The end-of-fight chat summary is debug output; /mm last still prints it on request.
    if ns.debugMode then
        PrintSummary(fight)
    end
    ns.ShowNewestFight() -- if the history panel is open, switch it to the fight that just ended
end

-- Tracks spent/recovered from actual mana changes when mana is readable (not on WoW Forever).
local function OnManaChanged()
    local mana = GetMana()
    ns.Mana.OnPowerEvent(mana)

    local current = ns.current
    if not current then return end
    if not mana then
        if not current.manaHidden then
            current.manaHidden = true
            UpdateDisplay(current.castSpent)
        end
        return
    end

    if current.lastMana then
        local delta = mana - current.lastMana
        if delta < 0 then
            current.spent = current.spent - delta
            if not current.manaHidden then
                UpdateDisplay(current.spent)
            end
        elseif delta > 0 then
            current.recovered = current.recovered + delta
        end
    end
    current.lastMana = mana
    if not current.lowestMana or mana < current.lowestMana then
        current.lowestMana = mana
    end
end

-- Names a fight after the first hostile target if the player had none when combat started.
local function OnTargetChanged()
    local current = ns.current
    if not current or current.isEncounter or current.targetName then return end
    local targetName = GetHostileTargetName()
    if targetName then
        current.targetName = targetName
        current.name = targetName
    end
end

local function OnSpellCast(spellID)
    if not IsReadable(spellID) then return end
    local now = GetTime()

    -- The client file may handle the cast itself (e.g. estimating a potion on WoW Forever).
    if ns.Mana.OnSpellCast(spellID, now) then return end

    local cost = GetManaCost(spellID)
    if cost <= 0 then return end
    ns.Mana.OnManaSpend(cost, now)

    if ns.current then
        AddCast(ns.current, spellID, cost)
    else
        -- The pull cast usually lands before combat starts; keep it for the fight that follows.
        table.insert(recentCasts, { time = now, spellID = spellID, cost = cost })
        while #recentCasts > 0 and now - recentCasts[1].time > PRECOMBAT_WINDOW do
            table.remove(recentCasts, 1)
        end
    end
end

local function OnAddonLoaded()
    ManaMasterDB = ManaMasterDB or {}
    for key, value in pairs(defaults) do
        if ManaMasterDB[key] == nil then
            ManaMasterDB[key] = value
        end
    end
    ManaMasterDB.fights = ManaMasterDB.fights or {}
    ns.db = ManaMasterDB
    ns.CreateMinimapButton()
    ns.Mana.Init()

    -- Handles /reload mid-combat.
    if InCombatLockdown() then
        StartFight()
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == addonName then
            OnAddonLoaded()
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        StartFight()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- During a boss encounter, wait for ENCOUNTER_END so dying or a brief drop out of combat doesn't split the fight.
        if not encounterActive then
            EndFight()
        end
        ns.Mana.OnCombatEnd()
    elseif event == "ENCOUNTER_START" then
        local _, encounterName = ...
        encounterActive = true
        StartFight(encounterName)
    elseif event == "ENCOUNTER_END" then
        local success = select(5, ...)
        encounterActive = false
        EndFight(success == 1)
    elseif event == "UNIT_POWER_FREQUENT" then
        local _, powerType = ...
        if powerType == "MANA" then
            UpdateManaBar()
            OnManaChanged()
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        Debug(event, "spell", Describe(spellID))
        OnSpellCast(spellID)
    elseif event == "UNIT_MAXPOWER" then
        UpdateManaBar()
    elseif event == "UNIT_AURA" then
        if ns.current then
            UpdateAuras(ns.current, GetTime())
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        OnTargetChanged()
    end
end)

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("ENCOUNTER_START")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:RegisterUnitEvent("UNIT_AURA", "player")
frame:RegisterUnitEvent("UNIT_MAXPOWER", "player")

function ns.ClearHistory()
    wipe(ns.db.fights)
    print(PREFIX .. "fight history cleared")
    ns.RefreshHistory()
end

SLASH_MANAMASTER1 = "/manamaster"
SLASH_MANAMASTER2 = "/mm"
SlashCmdList.MANAMASTER = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "" then
        ns.ToggleHistory()
    elseif msg == "toggle" then
        ns.db.enabled = not ns.db.enabled
        print(PREFIX .. (ns.db.enabled and "enabled" or "disabled"))
    elseif msg == "last" then
        local fights = ns.db.fights
        if #fights > 0 then
            PrintSummary(fights[#fights])
        else
            print(PREFIX .. "No fights recorded yet.")
        end
    elseif msg == "minimap" then
        ns.SetMinimapButtonShown(not ns.db.showMinimapButton)
        print(PREFIX .. "minimap button " .. (ns.db.showMinimapButton and "shown" or "hidden"))
    elseif msg == "debug" then
        ns.debugMode = not ns.debugMode
        print(PREFIX .. "debug " .. (ns.debugMode and "on" or "off"))
        if ns.debugMode then
            -- Show the on-screen display right away if a fight is already running.
            local current = ns.current
            if current then
                ShowDisplay()
                UpdateDisplay(current.manaHidden and current.castSpent or current.spent)
            end
        else
            display:Hide()
        end
    elseif msg == "clear" then
        ns.ClearHistory()
    else
        print(PREFIX .. "commands: /mm (history panel) | last | minimap | toggle | debug | clear")
    end
end
