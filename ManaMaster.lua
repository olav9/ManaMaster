local addonName, ns = ...

local MANA = Enum.PowerType.Mana
local MAX_HISTORY = 50
local PRECOMBAT_WINDOW = 3 -- seconds before combat whose casts count toward the fight
local FIVE_SECOND_RULE = 5 -- seconds after spending mana that regen stays at the reduced casting rate
local REGEN_UPDATE_INTERVAL = 1 -- seconds between regen estimate updates during a fight
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

-- Debuffs (English names) that stop mana regen. While one is on the player, the regen they would have
-- had counts as blocked (wasted) instead of gained. Add names here as they're found in game.
local REGEN_BLOCKERS = {
}

local defaults = {
    enabled = true,
    printSummary = true,
    showMinimapButton = true,
    minimapAngle = 225, -- bottom-left of the minimap
}

local frame = CreateFrame("Frame")
local current -- the fight being tracked, nil when out of combat
local encounterActive = false
local recentCasts = {} -- mana casts made out of combat, within PRECOMBAT_WINDOW
local regenRates -- last readable GetManaRegen() values: { inactive, active } in mana per second
local lastManaSpend = 0 -- GetTime() of the last cast that cost mana, for the five-second rule
local regenTicker
-- Last readable out-of-combat mana: { value, time }. Cleared when a later reading is hidden,
-- so it's only used as the fight's starting mana while it's still current.
local lastSeenMana

-- Retail can hide combat values from addons ("secret values"); skip anything we can't read.
local function IsReadable(value)
    return value ~= nil and not (issecretvalue and issecretvalue(value))
end

local debugMode = false -- not saved; turn on with /mm debug
local lastPowerDebugState -- "hidden" or "readable", so power-event debug lines only print on a change

local function Debug(...)
    if debugMode then
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

-- A table of per-spell entries (fight.spells, and later fight.gains/fight.drains) as a list, most mana first.
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

local displayGeneration = 0 -- lets a pending hide from an old fight skip a newer one

local function UpdateDisplay(spent)
    displayText:SetText(FormatNumber(spent))
end

local function ShowDisplay()
    displayGeneration = displayGeneration + 1
    UpdateDisplay(0)
    display:Show()
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
        -- Mana was hidden: spent is from spell costs and regen is estimated.
        local net = fight.regen - fight.spent
        print(string.format("  Spent %s | Regen ~%s (est.) | Net %s%s",
            FormatNumber(fight.spent), FormatNumber(fight.regen), net >= 0 and "+" or "-", FormatNumber(math.abs(net))))
    else
        -- Fights saved before regen was estimated.
        print(string.format("  Spent %s (from spell costs)", FormatNumber(fight.spent)))
    end

    -- Fights saved before wasted regen was tracked have no wastedFull.
    if fight.wastedFull then
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

local function GetManaCost(spellID)
    local cost = 0
    for _, powerCost in ipairs(C_Spell.GetSpellPowerCost(spellID) or {}) do
        Debug("  cost type", Describe(powerCost.type), "cost", Describe(powerCost.cost))
        if powerCost.type == MANA and IsReadable(powerCost.cost) then
            cost = cost + powerCost.cost
        end
    end
    return cost
end

-- The spell's subtext, e.g. "Rank 2"; nil when it has none.
local function GetSpellRank(spellID)
    if not C_Spell.GetSpellSubtext then return end
    local subtext = C_Spell.GetSpellSubtext(spellID)
    if IsReadable(subtext) and subtext ~= "" then return subtext end
end

-- Keeps the last readable regen rates (mana per second), since they may be hidden in combat.
local function ReadManaRegen()
    if not GetManaRegen then return end
    local inactive, active = GetManaRegen()
    if IsReadable(inactive) and IsReadable(active) then
        regenRates = { inactive = inactive, active = active }
    end
end

local function NoteOutOfCombatMana()
    local mana = GetMana()
    lastSeenMana = mana and { value = mana, time = GetTime() } or nil
end

-- Adds estimated regen from fight.regenClock up to now. Time within FIVE_SECOND_RULE of the last
-- mana spend regens at the "active" (casting) rate, the rest at the full "inactive" rate.
-- The regen is applied to the simulated mana pool (fight.simMana): anything past max mana is wasted,
-- and all of it is wasted while a regen-blocking debuff is up.
-- Call before updating lastManaSpend or fight.regenBlocked so the interval uses the previous state.
local function AccumulateRegen(fight, now)
    local from = fight.regenClock
    fight.regenClock = now
    if not regenRates or now <= from then return end
    local ruleEnd = lastManaSpend + FIVE_SECOND_RULE
    local activeTime = math.max(0, math.min(now, ruleEnd) - from)
    local inactiveTime = (now - from) - activeTime
    local amount = activeTime * regenRates.active + inactiveTime * regenRates.inactive

    if fight.regenBlocked then
        fight.wastedBlocked = fight.wastedBlocked + amount
        return
    end
    local gained = math.min(amount, math.max(0, fight.maxMana - fight.simMana))
    fight.wastedFull = fight.wastedFull + (amount - gained)
    fight.simMana = fight.simMana + gained
    fight.regen = fight.regen + gained
end

-- Per-spell spending uses the spell's listed mana cost, since mana changes can't be tied to a cast directly.
-- The same costs drive the total when the game hides the player's mana.
-- inStartMana: the cost was already taken out of the fight's starting mana (a pre-combat cast made
-- before the starting mana was read), so the simulated pool shouldn't be lowered again.
local function AddCast(fight, spellID, cost, inStartMana)
    fight.castSpent = fight.castSpent + cost
    if not inStartMana then
        fight.simMana = math.max(0, fight.simMana - cost)
    end
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

-- Returns the player's auras (filter "HELPFUL" or "HARMFUL") whose names are in `names`, as
-- name -> { spellID, icon }, plus how many auras couldn't be read. In combat, GetAuraDataByIndex throws
-- on auras the game marks secret (e.g. Blood Fury) instead of returning them, so each slot is read in a
-- pcall and skipped on error.
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

-- Starts or stops uptime timers for each tracked buff, and the regen-blocked state, to match what
-- the player has now.
local function UpdateAuras(fight, now)
    local blockers = ScanAuras("HARMFUL", REGEN_BLOCKERS) -- keep only the first return; the second is a count
    local blocked = next(blockers) ~= nil
    if blocked ~= fight.regenBlocked then
        AccumulateRegen(fight, now) -- close the interval under the old state first
        fight.regenBlocked = blocked
    end

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

    ReadManaRegen()
    Debug("regen per second", regenRates and regenRates.inactive or "unknown", "while casting",
        regenRates and regenRates.active or "unknown")

    local mana = GetMana()
    local targetName = GetHostileTargetName()

    -- Starting mana for the simulated pool: a reading now if it's visible, else the last out-of-combat
    -- reading if it's still current, else assume full. manaReadAt is when that value was taken, so
    -- pre-combat casts after it can still be subtracted.
    local now = GetTime()
    local startMana, manaReadAt, startManaAssumed
    if mana then
        startMana, manaReadAt = mana, now
    elseif lastSeenMana then
        startMana, manaReadAt = math.min(lastSeenMana.value, maxMana), lastSeenMana.time
    else
        startMana, manaReadAt, startManaAssumed = maxMana, -math.huge, true
    end
    Debug("start mana", startMana, startManaAssumed and "(assumed full)" or "")

    current = {
        name = encounterName or targetName or "Combat",
        isEncounter = encounterName ~= nil,
        targetName = targetName,
        zone = GetRealZoneText(),
        date = time(),
        startClock = GetTime(),
        maxMana = maxMana,
        startMana = startMana,
        startManaAssumed = startManaAssumed,
        simMana = startMana, -- simulated mana pool, since the real value is hidden in combat
        wastedFull = 0, -- regen lost to being at max mana
        wastedBlocked = 0, -- regen lost to REGEN_BLOCKERS debuffs
        regenBlocked = false,
        lastMana = mana,
        lowestMana = mana,
        spent = 0,
        recovered = 0,
        castSpent = 0, -- sum of listed spell costs, used when mana is hidden
        manaHidden = mana == nil,
        regen = 0, -- estimated passive regen, from GetManaRegen and the five-second rule
        regenClock = GetTime(),
        spells = {},
        buffs = {}, -- regen buff name -> { uptime, spellID, icon, since }
    }
    ShowDisplay()

    -- Pre-combat casts count toward the fight. Their mana was spent before combat's own mana tracking
    -- began, so add them to spent; only lower the simulated pool for casts after manaReadAt.
    for _, cast in ipairs(recentCasts) do
        if now - cast.time <= PRECOMBAT_WINDOW then
            Debug("pre-combat cast", cast.spellID, "cost", cast.cost)
            current.spent = current.spent + cast.cost
            AddCast(current, cast.spellID, cast.cost, cast.time <= manaReadAt)
        end
    end

    UpdateAuras(current, current.startClock)
    if debugMode then
        local found, hidden = ScanAuras("HELPFUL", REGEN_BUFFS)
        local names = {}
        for name in pairs(found) do table.insert(names, name) end
        Debug("regen buffs", #names > 0 and table.concat(names, ", ") or "none", "| unreadable buffs", hidden)
    end
    regenTicker = C_Timer.NewTicker(REGEN_UPDATE_INTERVAL, function()
        if not current then return end
        -- While regen is blocked, keep the rates from before the debuff: they're what the player would
        -- have regenerated, whether or not the game's own reading drops to 0.
        if not current.regenBlocked then
            ReadManaRegen() -- picks up spirit/MP5 changes mid-fight when readable
        end
        AccumulateRegen(current, GetTime())
        local maxNow = UnitPowerMax("player", MANA)
        if IsReadable(maxNow) and maxNow > 0 then
            current.maxMana = maxNow
            current.simMana = math.min(current.simMana, maxNow)
        end
    end)
    wipe(recentCasts)
    if not current.manaHidden then
        UpdateDisplay(current.spent)
    end
end

local function EndFight(success)
    if not current then return end
    local fight = current
    current = nil

    regenTicker:Cancel()
    regenTicker = nil
    AccumulateRegen(fight, GetTime())
    fight.regenClock = nil

    -- Close any buff still running when the fight ends.
    local now = GetTime()
    for _, entry in pairs(fight.buffs) do
        if entry.since then
            entry.uptime = entry.uptime + (now - entry.since)
            entry.since = nil
        end
    end

    fight.duration = GetTime() - fight.startClock
    fight.endMana = fight.lastMana
    fight.success = success
    fight.startClock = nil
    fight.lastMana = nil
    fight.simMana = nil
    fight.regenBlocked = nil
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

    if ns.db.printSummary then
        PrintSummary(fight)
    end
    ns.RefreshHistory()
end

local function OnManaChanged()
    if not current then return end
    local mana = GetMana()
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
    if not current or current.isEncounter or current.targetName then return end
    local targetName = GetHostileTargetName()
    if targetName then
        current.targetName = targetName
        current.name = targetName
    end
end

local function OnSpellCast(spellID)
    if not IsReadable(spellID) then return end
    local cost = GetManaCost(spellID)
    if cost <= 0 then return end

    local now = GetTime()
    if current then
        AccumulateRegen(current, now)
    end
    lastManaSpend = now

    if current then
        AddCast(current, spellID, cost)
    else
        ReadManaRegen() -- out of combat the rates are more likely readable; cache them for the pull
        -- The pull cast usually lands before combat starts; keep it for the fight that follows.
        table.insert(recentCasts, { time = GetTime(), spellID = spellID, cost = cost })
        while #recentCasts > 0 and GetTime() - recentCasts[1].time > PRECOMBAT_WINDOW do
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

    -- Handles /reload mid-combat.
    if InCombatLockdown() then
        StartFight()
    else
        NoteOutOfCombatMana()
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
        ReadManaRegen()
        NoteOutOfCombatMana()
    elseif event == "ENCOUNTER_START" then
        local _, encounterName = ...
        encounterActive = true
        StartFight(encounterName)
    elseif event == "ENCOUNTER_END" then
        local success = select(5, ...)
        encounterActive = false
        EndFight(success == 1)
    elseif event == "UNIT_POWER_FREQUENT" then
        local unit, powerType = ...
        -- These fire several times a second, so only log when mana switches between hidden and readable.
        local manaState = Describe(UnitPower("player", MANA)) == "SECRET" and "hidden" or "readable"
        if manaState ~= lastPowerDebugState then
            lastPowerDebugState = manaState
            Debug(event, Describe(unit), Describe(powerType), "mana now", manaState,
                "tracking", current and "yes" or "no")
        end
        if powerType == "MANA" then
            if current then
                OnManaChanged()
            else
                NoteOutOfCombatMana()
            end
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        Debug(event, "spell", Describe(spellID))
        OnSpellCast(spellID)
    elseif event == "UNIT_AURA" then
        if current then
            UpdateAuras(current, GetTime())
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

-- Debug-only test: addons can't register for the combat log, but can they read the lines Blizzard's
-- Combat Log chat tab prints? Post-hooks only observe, so they don't taint the tab.
-- Reports once whenever lines switch between readable and hidden, and echoes readable lines that
-- mention mana. Hooks are set when debug is turned on, since Blizzard_CombatLog loads on demand
-- and may not exist yet when this file loads.
local COMBAT_TAB_SAMPLE_LINES = 3 -- lines echoed per method after debug is turned on, to show the wording
local combatTabState = {} -- per "frame:method": last reported "readable"/"hidden", and lines echoed so far
local hookedFrames = {}

local function OnCombatTabMessage(frameName, method, text)
    if not debugMode then return end
    local key = frameName .. ":" .. method
    local info = combatTabState[key]
    if not info then
        info = { echoed = 0 }
        combatTabState[key] = info
    end

    local readable = IsReadable(text) and type(text) == "string"
    local state = readable and "readable" or "hidden"
    if state ~= info.state then
        info.state = state
        Debug("combat log tab lines are", state, "(" .. key .. ")")
    end
    if not readable then return end

    if info.echoed < COMBAT_TAB_SAMPLE_LINES then
        info.echoed = info.echoed + 1
        Debug("combat log tab sample (" .. method .. "):", text)
    elseif text:find("[Mm]ana") then
        Debug("combat log tab:", text)
    end
end

local function HookCombatTab()
    local frames = {}
    if COMBATLOG then frames[COMBATLOG] = true end
    if ChatFrame2 then frames[ChatFrame2] = true end

    Debug("COMBATLOG is", COMBATLOG and (COMBATLOG:GetName() or "unnamed frame") or "nil",
        "| Blizzard_CombatLog loaded:", tostring(C_AddOns and C_AddOns.IsAddOnLoaded("Blizzard_CombatLog")))
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local name, _, _, _, _, _, shown = GetChatWindowInfo(i)
        if name and name ~= "" then
            Debug("chat window", i, name, shown and "(shown)" or "")
        end
    end

    for chatFrame in pairs(frames) do
        if not hookedFrames[chatFrame] then
            hookedFrames[chatFrame] = true
            local frameName = chatFrame:GetName() or "unnamed"
            for _, method in ipairs({ "AddMessage", "BackFillMessage" }) do
                if chatFrame[method] then
                    hooksecurefunc(chatFrame, method, function(_, text)
                        OnCombatTabMessage(frameName, method, text)
                    end)
                end
            end
            Debug("watching", frameName, "for combat log lines")
        end
    end
end

function ns.ClearHistory()
    wipe(ns.db.fights)
    print(PREFIX .. "fight history cleared")
    ns.RefreshHistory()
end

SLASH_MANAMASTER1 = "/manamaster"
SLASH_MANAMASTER2 = "/mm"
SlashCmdList.MANAMASTER = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "" or msg == "history" then
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
    elseif msg == "history" then
        PrintHistory()
    elseif msg == "summary" then
        ns.db.printSummary = not ns.db.printSummary
        print(PREFIX .. "end-of-fight summary " .. (ns.db.printSummary and "on" or "off"))
    elseif msg == "minimap" then
        ns.SetMinimapButtonShown(not ns.db.showMinimapButton)
        print(PREFIX .. "minimap button " .. (ns.db.showMinimapButton and "shown" or "hidden"))
    elseif msg == "debug" then
        debugMode = not debugMode
        print(PREFIX .. "debug " .. (debugMode and "on" or "off"))
        if debugMode then
            wipe(combatTabState)
            HookCombatTab()
        end
    elseif msg == "reset" then
        ns.ClearHistory()
    else
        print(PREFIX .. "commands: /mm (history panel) | last | summary | minimap | toggle | debug | reset")
    end
end
