local addonName, ns = ...

local MANA = Enum.PowerType.Mana
local MAX_HISTORY = 50
local PRECOMBAT_WINDOW = 3 -- seconds before combat whose casts count toward the fight
local FIVE_SECOND_RULE = 5 -- seconds after spending mana that regen stays at the reduced casting rate
local REGEN_UPDATE_INTERVAL = 1 -- seconds between mana pool estimate updates
local FULL_QUIET_MIN = 2 -- seconds without a mana event (outside the five-second rule) that mean mana is full
local FULL_QUIET_MANA = 3 -- ...or the time to regen this much mana, if that's longer (slow regen fires events rarely)
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

-- Fallback mana restore ranges by spell ID, used when a spell's description can't be read.
local KNOWN_MANA_RESTORES = {
    [437] = { 140, 180 }, -- Restore Mana (Minor Mana Potion), confirmed in game
}

local defaults = {
    enabled = true,
    showMinimapButton = true,
    minimapAngle = 225, -- bottom-left of the minimap
}

local frame = CreateFrame("Frame")
local current -- the fight being tracked, nil when out of combat
local encounterActive = false
local recentCasts = {} -- mana casts made out of combat, within PRECOMBAT_WINDOW
local regenRates -- last readable GetManaRegen() values: { inactive, active } in mana per second
local lastManaSpend = 0 -- GetTime() of the last cast that cost mana, for the five-second rule
-- Estimated mana pool, kept running in and out of combat since the real value is secret on WoW Forever.
-- mana is nil until the pool is initialised (max mana readable). confirmed turns true once the estimate
-- has been anchored to a known value: a readable reading, or full mana detected from mana events going quiet.
local pool = { mana = nil, max = 0, clock = 0, confirmed = false }
local lastPowerEvent = 0 -- GetTime() of the last mana UNIT_POWER_FREQUENT, for detecting full mana

-- Retail can hide combat values from addons ("secret values"); skip anything we can't read.
local function IsReadable(value)
    return value ~= nil and not (issecretvalue and issecretvalue(value))
end

local debugMode = false -- not saved; turn on with /mm debug

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

-- Total estimated mana from potions, runes and gems (fight.gains); 0 for fights saved before they were tracked.
local function RestoredTotal(fight)
    local total = 0
    for _, entry in pairs(fight.gains or {}) do
        total = total + entry.mana
    end
    return total
end

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
    if not debugMode then return end
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

-- Adds estimated regen to the pool from pool.clock up to now. Time within FIVE_SECOND_RULE of the last
-- mana spend regens at the "active" (casting) rate, the rest at the full "inactive" rate. Regen past max
-- mana is wasted. During a fight the amounts are also booked to it: gained regen, wasted at full mana,
-- or all of it as blocked while a regen-blocking debuff is up.
-- Call before changing lastManaSpend, the pool or current.regenBlocked, so the interval uses the old state.
local function AdvancePool(now)
    local from = pool.clock
    pool.clock = now
    if not pool.mana or not regenRates or now <= from then return end
    local ruleEnd = lastManaSpend + FIVE_SECOND_RULE
    local activeTime = math.max(0, math.min(now, ruleEnd) - from)
    local inactiveTime = (now - from) - activeTime
    local amount = activeTime * regenRates.active + inactiveTime * regenRates.inactive

    if current and current.regenBlocked then
        current.wastedBlocked = current.wastedBlocked + amount
        return
    end
    local gained = math.min(amount, math.max(0, pool.max - pool.mana))
    pool.mana = pool.mana + gained
    if current then
        current.wastedFull = current.wastedFull + (amount - gained)
        current.regen = current.regen + gained
    end
end

-- Sets the pool to a known value (a readable mana reading, or max when full mana is detected).
local function AnchorPool(mana, reason)
    AdvancePool(GetTime())
    if debugMode and (not pool.confirmed or math.abs((pool.mana or 0) - mana) >= 1) then
        Debug("mana pool anchored:", reason, "| estimate was", pool.mana and math.floor(pool.mana + 0.5) or "unset",
            "now", mana)
    end
    pool.mana = mana
    pool.confirmed = true
end

-- Starts the pool once max mana is readable. It assumes full until something anchors it.
local function InitPool()
    local maxMana = UnitPowerMax("player", MANA)
    if not IsReadable(maxMana) or maxMana <= 0 then return end
    pool.max = maxMana
    pool.clock = GetTime()
    local mana = GetMana()
    pool.mana = mana or maxMana
    pool.confirmed = mana ~= nil
end

-- Out of combat, mana events fire continuously while mana regenerates and stop once it's full. So a quiet
-- spell outside the five-second rule (when regen is near zero and events also stop) means mana is full.
local function CheckFullMana(now)
    if current or not pool.mana or not regenRates or regenRates.inactive <= 0 then return end
    if UnitIsDeadOrGhost("player") then return end
    local quiet = math.max(FULL_QUIET_MIN, FULL_QUIET_MANA / regenRates.inactive)
    if now - lastPowerEvent >= quiet and now - quiet >= lastManaSpend + FIVE_SECOND_RULE then
        if pool.mana < pool.max or not pool.confirmed then
            AnchorPool(pool.max, "mana events quiet, so mana is full")
        end
    end
end

-- Per-spell spending uses the spell's listed mana cost, since mana changes can't be tied to a cast directly.
-- The same costs drive the total when the game hides the player's mana.
-- inPool: the cost was already taken out of the pool when it was cast (pre-combat casts), so don't take
-- it out again.
local function AddCast(fight, spellID, cost, inPool)
    fight.castSpent = fight.castSpent + cost
    if not inPool and pool.mana then
        pool.mana = math.max(0, pool.mana - cost)
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

-- Mana restored by a spell the player uses (potions, runes, gems), as { min, max }, or nil if it doesn't
-- restore mana. Parsed from the English description ("Restores 140 to 180 mana."), anchored at the start
-- so spells like Mana Spring ("Summons a totem that restores...") don't match. Cached per spell ID.
local restoreCache = {}

local function GetManaRestore(spellID)
    local cached = restoreCache[spellID]
    if cached ~= nil then return cached or nil end

    local description = C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(spellID)
    if not IsReadable(description) or description == "" then
        -- Description hidden or not loaded yet: use the fallback, and don't cache so a later cast can retry.
        return KNOWN_MANA_RESTORES[spellID]
    end
    local low, high = description:match("^Restores (%d+) to (%d+) mana")
    if not low then
        low = description:match("^Restores (%d+) mana")
        high = low
    end
    -- Drinks ("Restores 1344 mana over 18 sec.") restore over time and aren't one-off gains.
    if low and description:find(" over [%d%.]+ sec") then
        low, high = nil, nil
    end
    local restore = low and { tonumber(low), tonumber(high) } or KNOWN_MANA_RESTORES[spellID] or false
    restoreCache[spellID] = restore
    return restore or nil
end

-- Adds an estimated mana gain (average of the restore range) to the pool and, during a fight, to the fight.
-- Whatever doesn't fit under max mana counts as wasted at full mana, like the game's "Overenergized".
local function AddRestore(fight, spellID, restore, now)
    AdvancePool(now) -- settle regen up to now so the cap applies in the right order
    local amount = (restore[1] + restore[2]) / 2
    local gained = amount
    if pool.mana then
        gained = math.min(amount, math.max(0, pool.max - pool.mana))
        pool.mana = pool.mana + gained
    end
    if not fight then return end
    fight.wastedFull = fight.wastedFull + (amount - gained)

    local entry = fight.gains[spellID]
    if not entry then
        local range = restore[1] == restore[2] and tostring(restore[1]) or (restore[1] .. "-" .. restore[2])
        entry = {
            casts = 0,
            mana = 0,
            spellID = spellID,
            name = C_Spell.GetSpellName(spellID) or tostring(spellID),
            rank = range, -- shown next to the name; several potion sizes share the name "Restore Mana"
        }
        fight.gains[spellID] = entry
    end
    entry.casts = entry.casts + 1
    entry.mana = entry.mana + gained
    Debug("mana restore", entry.name, "estimated", amount, "gained", gained)
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
        AdvancePool(now) -- close the interval under the old state first
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

    -- Starting mana comes from the running pool estimate, brought up to date with out-of-combat regen.
    -- If nothing has anchored it since login/reload, it's still the initial "assume full".
    local now = GetTime()
    if not pool.mana then InitPool() end
    pool.max = maxMana
    if mana then
        AnchorPool(mana, "readable at fight start")
    else
        AdvancePool(now)
    end
    local startMana = math.min(pool.mana or maxMana, maxMana)
    local startManaAssumed = not pool.confirmed or nil
    Debug("start mana", math.floor(startMana + 0.5), startManaAssumed and "(assumed full, never anchored)" or "(estimated)")

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
        spells = {},
        gains = {}, -- estimated mana restores from potions, runes and gems, keyed by spell ID
        buffs = {}, -- regen buff name -> { uptime, spellID, icon, since }
    }
    ShowDisplay()

    -- Pre-combat casts count toward the fight. Their mana was spent before combat's own mana tracking
    -- began, so add them to spent. The pool already took their cost out when they were cast.
    for _, cast in ipairs(recentCasts) do
        if now - cast.time <= PRECOMBAT_WINDOW then
            Debug("pre-combat cast", cast.spellID, "cost", cast.cost)
            current.spent = current.spent + cast.cost
            AddCast(current, cast.spellID, cast.cost, true)
        end
    end

    UpdateAuras(current, current.startClock)
    if debugMode then
        local found, hidden = ScanAuras("HELPFUL", REGEN_BUFFS)
        local names = {}
        for name in pairs(found) do table.insert(names, name) end
        Debug("regen buffs", #names > 0 and table.concat(names, ", ") or "none", "| unreadable buffs", hidden)
    end
    wipe(recentCasts)
    if not current.manaHidden then
        UpdateDisplay(current.spent)
    end
end

local function EndFight(success)
    if not current then return end
    AdvancePool(GetTime()) -- book the last stretch of regen to the fight while it's still current
    local fight = current
    current = nil

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

    -- The end-of-fight chat summary is debug output; /mm last still prints it on request.
    if debugMode then
        PrintSummary(fight)
    end
    ns.ShowNewestFight() -- if the history panel is open, switch it to the fight that just ended
end

local function OnManaChanged()
    lastPowerEvent = GetTime()
    local mana = GetMana()
    if mana then
        AnchorPool(mana, "readable mana event") -- never seen on WoW Forever, but use it if it happens
    end
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
    if not current or current.isEncounter or current.targetName then return end
    local targetName = GetHostileTargetName()
    if targetName then
        current.targetName = targetName
        current.name = targetName
    end
end

local function OnSpellCast(spellID)
    if not IsReadable(spellID) then return end

    -- Potions, runes and gems: the actual gain is hidden, so add an estimate from the spell's description.
    -- Out of combat this only updates the pool estimate.
    local restore = GetManaRestore(spellID)
    if restore then
        AddRestore(current, spellID, restore, GetTime())
        return
    end

    local cost = GetManaCost(spellID)
    if cost <= 0 then return end

    local now = GetTime()
    AdvancePool(now)
    lastManaSpend = now

    if current then
        AddCast(current, spellID, cost)
    else
        if pool.mana then
            pool.mana = math.max(0, pool.mana - cost)
        end
        ReadManaRegen() -- out of combat the rates are more likely readable; cache them for the pull
        -- The pull cast usually lands before combat starts; keep it for the fight that follows.
        table.insert(recentCasts, { time = GetTime(), spellID = spellID, cost = cost })
        while #recentCasts > 0 and GetTime() - recentCasts[1].time > PRECOMBAT_WINDOW do
            table.remove(recentCasts, 1)
        end
    end
end

-- Runs every REGEN_UPDATE_INTERVAL: refreshes regen rates and max mana, advances the pool, and out of
-- combat checks whether mana is full.
local function OnPoolTick()
    local now = GetTime()
    if not pool.mana then
        InitPool()
        if not pool.mana then return end
    end
    -- While regen is blocked, keep the rates from before the debuff: they're what the player would
    -- have regenerated, whether or not the game's own reading drops to 0.
    if not (current and current.regenBlocked) then
        ReadManaRegen() -- picks up spirit/MP5 changes when readable
    end
    AdvancePool(now)

    local maxNow = UnitPowerMax("player", MANA)
    if IsReadable(maxNow) and maxNow > 0 then
        pool.max = maxNow
        pool.mana = math.min(pool.mana, maxNow)
        if current then current.maxMana = maxNow end
    end

    CheckFullMana(now)
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

    -- Keep the mana pool estimate running all the time, in and out of combat.
    lastPowerEvent = GetTime() -- give regen events a moment to arrive before calling mana full
    ReadManaRegen()
    InitPool()
    C_Timer.NewTicker(REGEN_UPDATE_INTERVAL, OnPoolTick)

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
        ReadManaRegen()
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
        debugMode = not debugMode
        print(PREFIX .. "debug " .. (debugMode and "on" or "off"))
        if debugMode then
            -- Show the on-screen display right away if a fight is already running.
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
