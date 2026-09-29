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
-- Seconds before combat whose mana casts count toward the fight. Long enough for a pre-pull setup, e.g. a
-- shaman dropping four totems on the global cooldown before the pull cast.
local PRECOMBAT_WINDOW = 15
local LARGE_GAIN_DEBUG = 100 -- /mm debug prints single mana increases at least this big (readable mana only)
-- Winning or finishing an arena match refills mana just before the match-complete event ends the fight.
-- A jump to full mana of at least this share of max, this close to the end, is taken as that refill.
local ARENA_REFILL_MIN_SHARE = 0.1
local ARENA_REFILL_WINDOW = 10 -- seconds before the fight ends
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
    -- Drinking, e.g. between arena fights. Descriptions like "Restores 4410 mana over 30 sec" are also
    -- detected by RegenMP5; the names are a fallback if the description can't be read.
    ["Drink"] = true,
    ["Food & Drink"] = true,
    ["Refreshment"] = true,
}

local defaults = {
    enabled = true,
    showMinimapButton = true,
    minimapAngle = 225, -- bottom-left of the minimap
}

local frame = CreateFrame("Frame")
local encounterActive = false
-- In an arena the whole match is one fight: it starts at the first combat and stays open between bursts
-- (drinking, resetting) until the match ends or the player leaves the arena.
local arenaActive = false
local arenaMatchOver = false -- set when the match ends, cleared on leaving the arena

local function InArena()
    local _, instanceType = GetInstanceInfo()
    return instanceType == "arena"
end
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

-- Mana per 5 seconds a buff gives, parsed from its English spell description, or nil. Recognises
-- "N mana per M sec" and "N mana every M sec" (e.g. "15 mana per 5 sec", "Gain 20 mana every 2 seconds"),
-- and drinks: "N mana over M sec" (e.g. "Restores 4410 mana over 30 sec"). This lets set bonuses, trinket
-- procs, consumables and drinks count as regen buffs without being listed in REGEN_BUFFS.
-- Also returns whether it's a drink ("over"): drinking isn't part of GetManaRegen's rates.
-- Cached per spell ID; an empty or unreadable description isn't cached, so a later scan can retry.
local regenMP5Cache = {}

local function RegenMP5(spellID)
    local cached = regenMP5Cache[spellID]
    if cached ~= nil then
        if not cached then return nil end
        return cached.mp5, cached.isDrink
    end
    local description = C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(spellID)
    if not IsReadable(description) or description == "" then return nil end

    description = description:lower()
    -- "N mana every/per/over M sec", with or without "restores"/"gain" in front, scaled to 5 seconds.
    local mp5, isDrink
    local amount, seconds = description:match("(%d+) mana every (%d+) sec")
    if not amount then
        amount, seconds = description:match("(%d+) mana per (%d+) sec")
    end
    if not amount then
        amount, seconds = description:match("(%d+) mana over (%d+) sec")
        isDrink = amount ~= nil
    end
    if amount and tonumber(seconds) > 0 then
        mp5 = tonumber(amount) * 5 / tonumber(seconds)
    end
    regenMP5Cache[spellID] = mp5 and { mp5 = mp5, isDrink = isDrink } or false
    return mp5, isDrink
end
ns.RegenMP5 = RegenMP5

-- Returns the player's auras (filter "HELPFUL" or "HARMFUL") whose names are in `names`, as
-- name -> { spellID, icon, mp5 }, plus how many auras couldn't be read. With `detect` (a function of the
-- aura's spell ID and aura data, e.g. RegenMP5), auras it returns a value for also count; a number is
-- stored as mp5. In combat on WoW Forever, GetAuraDataByIndex throws on auras the game marks secret (e.g. Blood Fury)
-- instead of returning them, so each slot is read in a pcall and skipped on error.
local function ScanAuras(filter, names, detect)
    local found, hidden = {}, 0
    for i = 1, MAX_AURA_SCAN do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, filter)
        if not ok then
            hidden = hidden + 1
        elseif not aura then
            break -- past the last buff
        else
            local name = aura.name
            local spellID = IsReadable(aura.spellId) and aura.spellId or nil
            local detected, isDrink
            if detect and spellID then
                detected, isDrink = detect(spellID, aura)
            end
            if not IsReadable(name) then
                hidden = hidden + 1
            elseif names[name] or detected then
                found[name] = {
                    spellID = spellID,
                    icon = IsReadable(aura.icon) and aura.icon or nil,
                    mp5 = type(detected) == "number" and detected or nil,
                    isDrink = isDrink or nil,
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
-- Mana saved: buffs that temporarily reduce spell costs, in the order a saving is credited to them when
-- several are up. Permanent talent reductions (e.g. Convection) are part of the normal cost, not savings.
local COST_REDUCERS = { "Clearcasting", "Elemental Mastery", "Inner Focus", "Surge of Light", "Power Infusion" }
local COST_REDUCER_SET = {}
for _, name in ipairs(COST_REDUCERS) do COST_REDUCER_SET[name] = true end

-- Buffs not in COST_REDUCERS still count as cost reducers if their English description says so, so new
-- procs (trinkets, set bonuses, other classes) are credited by name instead of "Other reduction".
local REDUCER_PHRASES = {
    "reduces the mana cost", "reduce the mana cost", "mana cost reduced", "mana cost of your next",
    "costs no mana", "cost no mana", "no mana cost", "reduces the cost of your next",
}
local reducerCache = {}

-- True if an aura's spell description describes a mana cost reduction. Only temporary auras (with a
-- duration) qualify: a permanent aura would be "active" on every cast and stop normal costs being learned.
local function IsCostReducer(spellID, aura)
    local duration = aura and aura.duration
    if not IsReadable(duration) or duration <= 0 then return false end
    local cached = reducerCache[spellID]
    if cached ~= nil then return cached end
    local description = C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(spellID)
    if not IsReadable(description) or description == "" then return false end -- not cached: retry later
    description = description:lower()
    local found = false
    for _, phrase in ipairs(REDUCER_PHRASES) do
        if description:find(phrase, 1, true) then
            found = true
            break
        end
    end
    reducerCache[spellID] = found
    return found
end
local SNAPSHOT_MAX_AGE = 30 -- seconds; a cast-start snapshot older than this is stale

-- Snapshots taken at UNIT_SPELLCAST_SENT, keyed by cast GUID (or spell ID if the GUID isn't readable).
-- Mana is paid when a cast finishes, and a proc landing mid-cast can still discount it, so the price is
-- worked out at UNIT_SPELLCAST_SUCCEEDED from these plus the state then.
local castSnapshots = {}
-- Running total of logged mana gains (TBC combat log, via ns.NoteEnergize), so gains during a cast don't
-- make the cast's mana drop look smaller than its price.
local energizeTotal = 0

function ns.NoteEnergize(amount)
    energizeTotal = energizeTotal + amount
end

-- The first reducer buff found (in COST_REDUCERS order): its name and { spellID, icon } from ScanAuras.
local function FirstReducer(found)
    for _, name in ipairs(COST_REDUCERS) do
        if found[name] then return name, found[name] end
    end
    -- Detected from descriptions: take the alphabetically first, so the choice is stable.
    local first
    for name in pairs(found) do
        if not first or name < first then first = name end
    end
    if first then return first, found[first] end
end

-- Several classes' procs share the buff name "Clearcasting"; the buff's spell ID tells them apart.
-- These IDs are the classic-era ones and not yet confirmed on these clients; an unknown ID just shows
-- the buff name without the talent.
local REDUCER_TALENTS = {
    [16246] = "Elemental Focus", -- shaman
    [12536] = "Arcane Concentration", -- mage
    [16870] = "Omen of Clarity", -- druid
}

local function OnCastSent(castGUID, spellID)
    local now = GetTime()
    for key, snap in pairs(castSnapshots) do
        if now - snap.time > SNAPSHOT_MAX_AGE then castSnapshots[key] = nil end
    end
    local snap = {
        time = now,
        cost = GetManaCost(spellID),
        mana = GetMana(), -- readable on TBC, nil on WoW Forever
        energize = energizeTotal,
        reducers = ScanAuras("HELPFUL", COST_REDUCER_SET, IsCostReducer),
    }
    castSnapshots[IsReadable(castGUID) and castGUID or spellID] = snap
    Debug("cast start", C_Spell.GetSpellName(spellID) or spellID, "cost", snap.cost,
        "| reducer:", FirstReducer(snap.reducers) or "none", "| mana", Describe(snap.mana))
end

-- The mana a finished cast actually cost, and the reducer buffs up when it finished.
-- The real price is always one of the listed costs: the one at cast start, or the discounted one after
-- it if a proc landed mid-cast (or 0). On TBC the mana drop since cast start, plus logged gains in between,
-- picks the nearest of those. The drop itself isn't used as the price, since regen during a cast makes it
-- smaller (a 150-mana Lightning Bolt measured 129). WoW Forever: the listed cost at cast start.
local function PaidCost(castGUID, spellID)
    local key = IsReadable(castGUID) and castGUID or spellID
    local snap = castSnapshots[key]
    castSnapshots[key] = nil
    local costAfter = GetManaCost(spellID)
    local reducersAfter = ScanAuras("HELPFUL", COST_REDUCER_SET, IsCostReducer)
    if not snap then return costAfter, nil, reducersAfter end

    local paid = snap.cost
    local manaNow = GetMana()
    if snap.mana and manaNow then
        local drop = snap.mana - manaNow + (energizeTotal - snap.energize)
        local nearest = snap.cost
        for _, candidate in ipairs({ costAfter, 0 }) do
            if math.abs(drop - candidate) < math.abs(drop - nearest) then
                nearest = candidate
            end
        end
        -- Only trust the drop if it's close to a listed price. Mana can rise during a cast for reasons that
        -- aren't logged (a pull cast saw -650), and "nearest" would then wrongly pick 0.
        local tolerance = math.max(10, 0.25 * math.max(snap.cost, costAfter))
        if math.abs(drop - nearest) <= tolerance then
            paid = nearest
        end
    end
    return paid, snap, reducersAfter
end

-- Learns a spell's normal cost from casts with no reducer buff up at start or finish, and returns it.
-- Stored per spell ID (so per rank) and per character across sessions in ns.char.normalCosts.
local function NormalCost(spellID, snap, reducersAfter)
    local costs = ns.char.normalCosts
    if snap and snap.cost > 0 and not next(snap.reducers) and not next(reducersAfter) then
        costs[spellID] = math.max(costs[spellID] or 0, snap.cost)
    end
    return costs[spellID]
end

-- Records mana saved on a cast during a fight: normal cost minus what was paid, credited to the reducer
-- buff that was up. Without a reducer buff, small differences are ignored as regen noise.
-- fight.saved is keyed by reducer buff ("Clearcasting#16246", "Inner Focus#14751", "Other reduction"):
--   { name, spellID, icon, talent, casts, mana, spells = { [spellID] = { name, rank, casts, mana, normalCost } } }
local function RecordSaving(fight, spellID, paid, snap, reducersAfter)
    local normal = NormalCost(spellID, snap, reducersAfter)
    if not fight or not normal or paid >= normal then return end
    local saved = normal - paid
    local sourceName, info = FirstReducer(snap and snap.reducers or {})
    if not sourceName then
        sourceName, info = FirstReducer(reducersAfter)
    end
    if not sourceName then
        if saved < math.max(5, normal * 0.1) then return end
        sourceName, info = "Other reduction", {}
    end

    local key = sourceName .. (info.spellID and ("#" .. info.spellID) or "")
    local source = fight.saved[key]
    if not source then
        source = {
            name = sourceName,
            spellID = info.spellID,
            icon = info.icon,
            talent = info.spellID and REDUCER_TALENTS[info.spellID],
            casts = 0,
            mana = 0,
            spells = {},
        }
        fight.saved[key] = source
    end
    source.casts = source.casts + 1
    source.mana = source.mana + saved

    local entry = source.spells[spellID]
    if not entry then
        entry = {
            casts = 0,
            mana = 0,
            spellID = spellID,
            name = C_Spell.GetSpellName(spellID) or tostring(spellID),
            rank = GetSpellRank(spellID),
        }
        source.spells[spellID] = entry
    end
    entry.casts = entry.casts + 1
    entry.mana = entry.mana + saved
    entry.normalCost = normal
    Debug("mana saved", entry.name, saved, "via", sourceName, info.spellID or "", "| normal", normal, "paid", paid)
end

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
        local restoredText = restored > 0 and (" | Potions/drinks ~" .. FormatNumber(restored)) or ""
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

    -- Fights saved before mana-saved tracking have no saved table.
    local savedTotal = 0
    for _, entry in pairs(fight.saved or {}) do savedTotal = savedTotal + entry.mana end
    if savedTotal >= 1 then
        print(string.format("  Mana saved by procs %s", FormatNumber(savedTotal)))
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

    -- Listed regen buffs, plus any buff whose description gives mana per 5 sec (e.g. set bonuses).
    local active = ScanAuras("HELPFUL", REGEN_BUFFS, RegenMP5)
    for name, info in pairs(active) do
        local entry = fight.buffs[name]
        if not entry then
            entry = { uptime = 0, spellID = info.spellID, icon = info.icon }
            fight.buffs[name] = entry
        end
        entry.mp5 = entry.mp5 or info.mp5
        entry.isDrink = entry.isDrink or info.isDrink
        entry.since = entry.since or now
    end
    for name, entry in pairs(fight.buffs) do
        if entry.since and not active[name] then
            entry.uptime = entry.uptime + (now - entry.since)
            entry.since = nil
        end
    end
end

-- Regen split by the five-second rule, for both clients: how long each fight spent within 5 s of a mana
-- spend (regen at the reduced casting rate) versus outside it (full regen), and the regen GetManaRegen's
-- rates predict for each. The panel uses the ratio to split passive regen into "while casting" and "full".
local FIVE_SECOND_RULE = 5
local SPLIT_UPDATE_INTERVAL = 1
local lastSpendTime = 0 -- GetTime() of the last cast that cost mana, in or out of combat
local splitRates -- last readable GetManaRegen() values: { inactive, active }

local function ReadSplitRates()
    if not GetManaRegen then return end
    local inactive, active = GetManaRegen()
    if IsReadable(inactive) and IsReadable(active) then
        splitRates = { inactive = inactive, active = active }
    end
end

-- Adds the time since fight.splitClock to the casting or full window. Call before changing lastSpendTime.
local function AccumulateRegenSplit(fight, now)
    local from = fight.splitClock
    fight.splitClock = now
    if not from or not splitRates or now <= from then return end
    local castingTime = math.max(0, math.min(now, lastSpendTime + FIVE_SECOND_RULE) - from)
    local fullTime = (now - from) - castingTime
    local split = fight.regenSplit
    split.castingTime = split.castingTime + castingTime
    split.fullTime = split.fullTime + fullTime
    split.castingRegen = split.castingRegen + castingTime * splitRates.active
    split.fullRegen = split.fullRegen + fullTime * splitRates.inactive
end

C_Timer.NewTicker(SPLIT_UPDATE_INTERVAL, function()
    if not ns.current then return end
    ReadSplitRates()
    AccumulateRegenSplit(ns.current, GetTime())
end)

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
        name = encounterName or (arenaActive and ("Arena: " .. GetRealZoneText())) or targetName or "Combat",
        isEncounter = encounterName ~= nil,
        isArena = arenaActive or nil,
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
        saved = {}, -- mana saved by cost reducers, keyed by buff: see RecordSaving
        buffs = {}, -- regen buff name -> { uptime, spellID, icon, since }
        -- Time and predicted regen within the five-second rule (casting) and outside it (full regen).
        regenSplit = { castingTime = 0, fullTime = 0, castingRegen = 0, fullRegen = 0 },
        splitClock = now,
    }
    ReadSplitRates()
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
        local found, hidden = ScanAuras("HELPFUL", REGEN_BUFFS, RegenMP5)
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
    AccumulateRegenSplit(fight, now)
    fight.splitClock = nil
    ns.current = nil

    -- Close any buff still running when the fight ends.
    for _, entry in pairs(fight.buffs) do
        if entry.since then
            entry.uptime = entry.uptime + (now - entry.since)
            entry.since = nil
        end
    end

    -- An arena match refills mana as it ends. If the last gain was that refill, it isn't mana recovered during
    -- the match: take it out of recovered and keep it as matchRefill, shown greyed out in the panel.
    local lastGain = fight.lastGain
    fight.lastGain = nil
    if fight.isArena and lastGain and lastGain.toMax and fight.recovered
        and now - lastGain.time <= ARENA_REFILL_WINDOW
        and lastGain.amount >= fight.maxMana * ARENA_REFILL_MIN_SHARE then
        fight.recovered = fight.recovered - lastGain.amount
        fight.matchRefill = lastGain.amount
        Debug("arena match-end refill", lastGain.amount, "not counted as recovered")
    end

    fight.duration = now - fight.startClock
    -- Game-clock (GetTime) start and end, kept so other addons' segments can be matched to this fight, e.g.
    -- the Details plugin. GetTime runs from computer boot, so it stays comparable across reloads until a reboot.
    fight.gameStart, fight.gameEnd = fight.startClock, now
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

    local fights = ns.char.fights
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
            -- Remembered so an arena's match-end refill can be taken back out at the end (see EndFight).
            local maxMana = UnitPowerMax("player", MANA)
            current.lastGain = { amount = delta, time = GetTime(),
                toMax = IsReadable(maxMana) and mana >= maxMana }
            -- Debug aid for "Unaccounted" recovery: large single jumps point at an unlogged mana source.
            if delta >= LARGE_GAIN_DEBUG then
                Debug(date("%H:%M:%S"), "mana +" .. delta, "to", mana)
            end
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
    if not current or current.isEncounter or current.isArena or current.targetName then return end
    local targetName = GetHostileTargetName()
    if targetName then
        current.targetName = targetName
        current.name = targetName
    end
end

local function OnSpellCast(spellID, castGUID)
    if not IsReadable(spellID) then return end
    local now = GetTime()

    -- The client file may handle the cast itself (e.g. estimating a potion on WoW Forever).
    if ns.Mana.OnSpellCast(spellID, now) then return end

    -- What the cast actually cost; the cost listed after the cast already reflects procs from it.
    local cost, snap, reducersAfter = PaidCost(castGUID, spellID)
    Debug("cast done ", C_Spell.GetSpellName(spellID) or spellID, "(spell " .. spellID .. ") paid", cost,
        "| reducer:", FirstReducer(reducersAfter) or "none")
    -- Record savings before the zero-cost check, so free casts (e.g. Elemental Mastery) still count.
    RecordSaving(ns.current, spellID, cost, snap, reducersAfter)
    if cost <= 0 then return end
    ns.Mana.OnManaSpend(cost, now)
    -- Close the regen-split interval under the old five-second-rule state, then restart the rule.
    if ns.current then AccumulateRegenSplit(ns.current, now) end
    lastSpendTime = now

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
    -- Fights and learned costs are per character: ManaMasterDB.characters["Name-Realm"] = { fights,
    -- normalCosts } (costs depend on talents and ranks). Settings like panel size stay account-wide.
    ManaMasterDB.characters = ManaMasterDB.characters or {}
    local charKey = UnitName("player") .. "-" .. GetRealmName()
    local char = ManaMasterDB.characters[charKey]
    if not char then
        char = {}
        ManaMasterDB.characters[charKey] = char
    end
    -- Fights saved before this were account-wide, with no record of the character. Hand them to the first
    -- character that logs in (each client keeps its own saved variables, so that's usually the main one).
    if ManaMasterDB.fights then
        char.fights = char.fights or ManaMasterDB.fights
        char.normalCosts = char.normalCosts or ManaMasterDB.normalCosts
        ManaMasterDB.fights, ManaMasterDB.normalCosts = nil, nil
    end
    char.fights = char.fights or {}
    char.normalCosts = char.normalCosts or {} -- learned per spell ID, for mana saved
    ns.db = ManaMasterDB
    ns.char = char
    ns.charName = UnitName("player")
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
        if InArena() and not arenaMatchOver then
            arenaActive = true
        end
        StartFight()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- During a boss encounter, wait for ENCOUNTER_END so dying or a brief drop out of combat doesn't split
        -- the fight; in an arena, keep the whole match as one fight.
        if not encounterActive and not arenaActive then
            EndFight()
        end
        ns.Mana.OnCombatEnd()
    elseif event == "PVP_MATCH_COMPLETE" then
        if arenaActive then
            arenaActive = false
            arenaMatchOver = true -- don't start a new arena fight in the post-match wait
            EndFight()
        end
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        if not InArena() then
            arenaMatchOver = false
            if arenaActive then
                -- Left the arena without a match-complete event (e.g. left early).
                arenaActive = false
                EndFight()
            end
        end
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
    elseif event == "UNIT_SPELLCAST_SENT" then
        local _, _, castGUID, spellID = ...
        if IsReadable(spellID) then
            OnCastSent(castGUID, spellID)
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, castGUID, spellID = ...
        OnSpellCast(spellID, castGUID)
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
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
-- Not every client may have this event; registering an unknown event errors, so guard it.
pcall(frame.RegisterEvent, frame, "PVP_MATCH_COMPLETE")
frame:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
frame:RegisterUnitEvent("UNIT_AURA", "player")
frame:RegisterUnitEvent("UNIT_MAXPOWER", "player")

function ns.ClearHistory()
    wipe(ns.char.fights)
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
        local fights = ns.char.fights
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
