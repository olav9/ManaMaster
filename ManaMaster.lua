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
--   OnDeathChanged(dead, now)  optional: the player is about to die or come back to life (the state
--                              changes right after this call, so regen can be settled up to now)

local MANA = Enum.PowerType.Mana
-- Fights kept per character: ManaMasterDB.maxFights, set with /mm keep N (a fight is ~2 KB saved).
local DEFAULT_MAX_FIGHTS = 200
local MIN_MAX_FIGHTS, MAX_MAX_FIGHTS = 10, 2000
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
    maxFights = DEFAULT_MAX_FIGHTS,
    -- Details! integration (DetailsPlugin.lua): delete fights whose Details segment was removed, and what
    -- to do when Details' data is reset: "ask", "clear" or "keep".
    detailsMirrorRemovals = true,
    detailsResetAction = "ask",
}

local frame = CreateFrame("Frame")
local encounterActive = false
-- In an arena the whole match is one fight: it starts at the first combat and stays open between bursts
-- (drinking, resetting) until the match ends or the player leaves the arena.
local arenaActive = false
local arenaMatchOver = false -- set when the match ends, cleared on leaving the arena

-- Death. A fight in a group can go on after the player dies (it ends when the whole group is out of
-- combat, see FightShouldContinue), but nothing counts while dead: no regen (Forever's estimate or the
-- regen split), no mana or rage/energy changes (TBC's measured deltas), no buff uptime. The mana a
-- resurrection gives back isn't regen either, so changes are ignored for RES_GRACE seconds after coming
-- back to life. Set from PLAYER_DEAD / PLAYER_ALIVE / PLAYER_UNGHOST (OnDeathChanged).
local RES_GRACE = 2
local playerDead = false
local aliveAt = 0 -- GetTime() when the player last came back to life

-- True while dead, and briefly after a resurrection (see above).
local function IgnoringPowerChanges()
    return playerDead or GetTime() - aliveAt < RES_GRACE
end
function ns.IsPlayerDead() return playerDead end

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

-- Debug lines also go to ManaMasterDB.debugLog, so they can be read from the SavedVariables file after a
-- /reload or logout (addons can't write other files). Capped to the newest DEBUG_LOG_MAX lines.
local DEBUG_LOG_MAX = 5000

local function AppendDebugLog(...)
    local log = ns.db and ns.db.debugLog
    if not log then return end
    local parts = {}
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        -- Secret values can't be turned into text here; print renders them, the log can't.
        parts[i] = (issecretvalue and issecretvalue(value)) and "SECRET" or tostring(value)
    end
    table.insert(log, string.format("%s %.3f %s", date("%H:%M:%S"), GetTime(), table.concat(parts, " ")))
    while #log > DEBUG_LOG_MAX do table.remove(log, 1) end
end

local function Debug(...)
    if ns.debugMode then
        print("|cff888888MM debug:|r", ...)
        AppendDebugLog(...)
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
            estimated = data.estimated, -- rage/energy gains estimated from a description
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

------------------------------------------------------------------------------------------------------------
-- Rage and energy. Tracked beside mana (which keeps its own, richer model) in fight.powers[token]:
--   { spent, gained, castSpent, spells, gains, wasted, hidden, max, cappedTime, regenRate }
-- spent/gained are measured from UNIT_POWER_FREQUENT deltas when the value is readable; if it's hidden
-- (secret), spent falls back to listed ability costs (castSpent) and gained is unknown. gains holds logged
-- energize sources (TBC combat log) and wasted their overflow past max. For energy, time spent at max
-- (cappedTime) times the regen rate is the energy wasted by capping.

local OTHER_POWERS = { RAGE = Enum.PowerType.Rage, ENERGY = Enum.PowerType.Energy }
local POWER_TOKEN_BY_TYPE = {}
for token, powerType in pairs(OTHER_POWERS) do POWER_TOKEN_BY_TYPE[powerType] = token end
ns.OTHER_POWERS = OTHER_POWERS
ns.POWER_TOKEN_BY_TYPE = POWER_TOKEN_BY_TYPE

-- Listed rage/energy costs of a spell: token -> cost (only readable, positive costs).
local function GetOtherPowerCosts(spellID)
    local costs = {}
    for _, powerCost in ipairs(C_Spell.GetSpellPowerCost(spellID) or {}) do
        local token = IsReadable(powerCost.type) and POWER_TOKEN_BY_TYPE[powerCost.type]
        if token and IsReadable(powerCost.cost) and powerCost.cost > 0 then
            costs[token] = (costs[token] or 0) + powerCost.cost
        end
    end
    return costs
end

local function ReadPower(token)
    local value = UnitPower("player", OTHER_POWERS[token])
    if IsReadable(value) then return value end
end

-- Starts or stops the at-max timer for energy (energy regen is wasted while capped).
local function UpdateEnergyCap(entry, value, now)
    local maxValue = UnitPowerMax("player", OTHER_POWERS.ENERGY)
    if not IsReadable(maxValue) or maxValue <= 0 then return end
    entry.max = maxValue
    if value >= maxValue then
        if not entry.capSince then
            entry.capSince = now
            -- The regen rate while capped, for the wasted estimate (energy's GetPowerRegen is per second).
            local _, active = GetPowerRegen()
            if IsReadable(active) and active > 0 then entry.regenRate = active end
        end
    elseif entry.capSince then
        entry.cappedTime = entry.cappedTime + (now - entry.capSince)
        entry.capSince = nil
    end
end

-- The fight's entry for a power, created on first use (a druid's fight may gain rage or energy mid-fight).
local function PowerEntry(fight, token)
    fight.powers = fight.powers or {}
    local entry = fight.powers[token]
    if entry then return entry end
    local maxValue = UnitPowerMax("player", OTHER_POWERS[token])
    entry = { spent = 0, gained = 0, castSpent = 0, spells = {}, gains = {}, wasted = 0, cappedTime = 0,
        max = IsReadable(maxValue) and maxValue or nil }
    local value = ReadPower(token)
    if value then
        entry.last = value
        if token == "ENERGY" then UpdateEnergyCap(entry, value, GetTime()) end
    else
        entry.hidden = true
    end
    fight.powers[token] = entry
    return entry
end
ns.PowerEntry = PowerEntry

-- An ability's rage/energy cost toward the fight, per spell like mana's spells.
local function AddPowerCast(fight, token, spellID, cost)
    local entry = PowerEntry(fight, token)
    entry.castSpent = entry.castSpent + cost
    local spell = entry.spells[spellID]
    if not spell then
        spell = { casts = 0, mana = 0, spellID = spellID, name = C_Spell.GetSpellName(spellID) or tostring(spellID),
            rank = GetSpellRank(spellID) }
        entry.spells[spellID] = spell
    end
    spell.casts = spell.casts + 1
    spell.mana = spell.mana + cost -- "mana" is the shared amount field used by SortedEntries and the UI
end

-- Rage/energy that abilities and potions give (Charge, Bloodrage, Rage Potion, Thistle Tea, ...), estimated
-- from the spell's English description like mana potions. Used where gains aren't logged (WoW Forever); on
-- TBC the combat log measures them (ns.Mana.logsPowerGains). Rage from damage dealt and taken, and passive
-- procs, can't be seen this way.
-- Patterns are tried in order on the lower-cased description; the first match wins, and a Bloodrage-style
-- "an additional N rage" is added on top.
local POWER_GAIN_PATTERNS = {
    { "RAGE", "rage by (%d+) to (%d+)" }, -- Rage Potion: "Increases Rage by 20 to 40."
    { "RAGE", "rage by (%d+)" },
    { "RAGE", "generat%a* (%d+) rage" }, -- Charge: "generate 9 rage"; Bloodrage: "Generates 10 rage"
    { "RAGE", "gain (%d+) rage" },
    { "ENERGY", "energy by (%d+) to (%d+)" },
    { "ENERGY", "restores (%d+) energy" }, -- Thistle Tea: "Instantly restores 100 energy."
    { "ENERGY", "energy by (%d+)" },
    { "ENERGY", "generat%a* (%d+) energy" },
    { "ENERGY", "gain (%d+) energy" },
}
-- Fallback when the description can't be read: spell ID -> { token, low, high }.
local KNOWN_POWER_GAINS = {
    [2687] = { "RAGE", 20, 20 }, -- Bloodrage: 10 at once, 10 more over 10 sec
    [100] = { "RAGE", 9, 9 }, [6178] = { "RAGE", 12, 12 }, [11578] = { "RAGE", 15, 15 }, -- Charge ranks 1-3
}
local powerGainCache = {} -- spell ID -> { token, low, high } or false

local function GetPowerGain(spellID)
    local cached = powerGainCache[spellID]
    if cached ~= nil then return cached or nil end
    local description = C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(spellID)
    if not IsReadable(description) or description == "" then
        return KNOWN_POWER_GAINS[spellID] -- not loaded yet or hidden: don't cache, retry next cast
    end
    description = description:lower()
    local gain
    for _, pattern in ipairs(POWER_GAIN_PATTERNS) do
        local low, high = description:match(pattern[2])
        if low then
            local token = pattern[1]
            low, high = tonumber(low), tonumber(high or low)
            local extra = tonumber(description:match("additional (%d+) " .. token:lower()))
            if extra then low, high = low + extra, high + extra end
            gain = { token, low, high }
            break
        end
    end
    gain = gain or KNOWN_POWER_GAINS[spellID] or false
    powerGainCache[spellID] = gain
    return gain or nil
end

-- Books an estimated rage/energy gain (average of the range) as a gain entry of the fight's power.
local function AddPowerGain(fight, spellID, gain)
    local token, low, high = gain[1], gain[2], gain[3]
    local power = PowerEntry(fight, token)
    local entry = power.gains[spellID]
    if not entry then
        entry = { casts = 0, mana = 0, spellID = spellID, estimated = true,
            name = C_Spell.GetSpellName(spellID) or tostring(spellID),
            rank = low == high and tostring(low) or (low .. "-" .. high) }
        power.gains[spellID] = entry
    end
    entry.casts = entry.casts + 1
    entry.mana = entry.mana + (low + high) / 2
    Debug("estimated", token, "gain", entry.name, (low + high) / 2)
end

-- A rage/energy UNIT_POWER_FREQUENT during a fight: measure spent and gained from the change.
local function OnOtherPowerChanged(token)
    local fight = ns.current
    if not fight then return end
    local entry = PowerEntry(fight, token)
    local value = ReadPower(token)
    if not value then
        if not entry.hiddenLogged then
            Debug(token, "is hidden: spent comes from listed costs, gains only from known sources")
            entry.hiddenLogged = true
        end
        entry.hidden = true
        return
    end
    -- While dead (rage and energy reset) and just after a resurrection: follow the value, count nothing.
    if IgnoringPowerChanges() then
        if entry.capSince then
            entry.cappedTime = entry.cappedTime + (GetTime() - entry.capSince)
            entry.capSince = nil
        end
        entry.last = value
        return
    end
    if entry.last then
        local delta = value - entry.last
        if delta < 0 then
            entry.spent = entry.spent - delta
            Debug(token, delta, "to", value)
        elseif delta > 0 then
            entry.gained = entry.gained + delta
            -- Energy regenerates continuously, so only log jumps (e.g. Thistle Tea); every rage gain is a hit.
            if token == "RAGE" or delta >= 20 then Debug(token, "+" .. delta, "to", value) end
        end
    end
    entry.last = value
    if token == "ENERGY" then UpdateEnergyCap(entry, value, GetTime()) end
end

-- Closes a fight's rage/energy entries: hidden values fall back to listed costs, and energy's time at max
-- becomes an estimate of energy wasted.
local function FinishPowers(fight, now)
    for token, entry in pairs(fight.powers or {}) do
        if entry.capSince then
            entry.cappedTime = entry.cappedTime + (now - entry.capSince)
            entry.capSince = nil
        end
        if token == "ENERGY" and entry.regenRate and entry.cappedTime > 0 then
            entry.wastedCap = entry.cappedTime * entry.regenRate
        end
        if entry.hidden then
            entry.spent, entry.gained = entry.castSpent, nil
        end
        local known = 0
        for _, gain in pairs(entry.gains) do known = known + gain.mana end
        Debug("fight end", token, "spent", entry.spent, entry.hidden and "(listed costs)" or "(measured)",
            "| gained", entry.gained or "hidden", "| known sources", known,
            entry.wastedCap and ("| wasted at max ~" .. math.floor(entry.wastedCap + 0.5)) or "")
        entry.last, entry.hiddenLogged = nil, nil
    end
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
                    auraInstanceID = IsReadable(aura.auraInstanceID) and aura.auraInstanceID or nil,
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

-- Whether the player has mana; warriors and rogues have max mana 0, so debug output leaves mana out.
local function HasMana()
    local maxMana = UnitPowerMax("player", MANA)
    return IsReadable(maxMana) and maxMana > 0
end

-- Debug text for a cast's rage/energy costs and the player's current rage/energy (SECRET where hidden),
-- e.g. "rage cost 15 | rage SECRET". Empty for casters without rage or energy.
local function OtherPowerDebugText(otherCosts)
    local parts = {}
    for token, cost in pairs(otherCosts or {}) do
        table.insert(parts, token:lower() .. " cost " .. cost)
    end
    local _, primary = UnitPowerType("player")
    if IsReadable(primary) and OTHER_POWERS[primary] then
        table.insert(parts, primary:lower() .. " " .. Describe(UnitPower("player", OTHER_POWERS[primary])))
    end
    return table.concat(parts, " | ")
end

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
        otherCosts = GetOtherPowerCosts(spellID), -- rage/energy, read before the cast consumes any proc
    }
    castSnapshots[IsReadable(castGUID) and castGUID or spellID] = snap
    if ns.debugMode then
        local parts = {}
        if HasMana() then
            table.insert(parts, "mana cost " .. tostring(snap.cost) .. " | mana " .. Describe(snap.mana)
                .. " | reducer: " .. (FirstReducer(snap.reducers) or "none"))
        end
        local other = OtherPowerDebugText(snap.otherCosts)
        if other ~= "" then table.insert(parts, other) end
        Debug("cast start", C_Spell.GetSpellName(spellID) or spellID, table.concat(parts, " | "))
    end
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
-- Books a saving worked out by RecordSaving into the fight.
local function ApplySaving(fight, spellID, saving)
    local saved, normal, paid = saving.saved, saving.normal, saving.paid
    local sourceName, info = saving.sourceName, saving.info

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

-- Works out the saving on a cast (normal cost minus paid, and the reducer buff to credit) and books it.
-- Before combat it's kept with the pre-pull casts and booked when the fight starts, like their costs:
-- a pull cast on a Clearcasting proc still counts as saved. That includes casts that end up free, which
-- aren't kept as mana casts (they cost nothing).
local function RecordSaving(fight, spellID, paid, snap, reducersAfter)
    local normal = NormalCost(spellID, snap, reducersAfter)
    if not normal or paid >= normal then return end
    local saved = normal - paid
    local sourceName, info = FirstReducer(snap and snap.reducers or {})
    if not sourceName then
        sourceName, info = FirstReducer(reducersAfter)
    end
    if not sourceName then
        if saved < math.max(5, normal * 0.1) then return end
        sourceName, info = "Other reduction", {}
    end

    local saving = { saved = saved, normal = normal, paid = paid, sourceName = sourceName, info = info }
    if fight then
        ApplySaving(fight, spellID, saving)
    else
        Debug("mana saved before combat", C_Spell.GetSpellName(spellID) or spellID, saved, "via", sourceName)
        local now = GetTime()
        table.insert(recentCasts, { time = now, spellID = spellID, saving = saving })
        while #recentCasts > 0 and now - recentCasts[1].time > PRECOMBAT_WINDOW do
            table.remove(recentCasts, 1)
        end
    end
end

ns.ScanAuras = ScanAuras
ns.RestoredTotal = RestoredTotal
ns.FormatNumber = FormatNumber
ns.FormatDuration = FormatDuration
ns.SortedEntries = SortedEntries

-- Functions called with the new fight when one starts (the history panel and Details plugin use this to
-- switch to the live fight).
ns.fightStartListeners = {}

-- The running fight as a finished-fight-shaped copy, for showing live: duration so far, buff uptime
-- including buffs still up, and spent from spell costs when mana is hidden (as EndFight would set).
-- Tables like spells are shared, not copied, so the view stays cheap; don't modify it.
function ns.LiveFightView()
    local fight = ns.current
    if not fight then return end
    local now = GetTime()
    local view = {}
    for key, value in pairs(fight) do view[key] = value end
    view.duration = now - fight.startClock
    view.isLive = true
    if fight.manaHidden then
        view.spent, view.recovered, view.lowestMana = fight.castSpent, nil, nil
    end
    view.buffs = {}
    for name, data in pairs(fight.buffs or {}) do
        local copy = {}
        for key, value in pairs(data) do copy[key] = value end
        if data.since then copy.uptime = data.uptime + (now - data.since) end
        view.buffs[name] = copy
    end
    -- Rage/energy as they'd look finished: hidden values fall back to costs, time at max so far.
    view.powers = {}
    for token, entry in pairs(fight.powers or {}) do
        local copy = {}
        for key, value in pairs(entry) do copy[key] = value end
        if entry.capSince then copy.cappedTime = entry.cappedTime + (now - entry.capSince) end
        if token == "ENERGY" and copy.regenRate and copy.cappedTime > 0 then
            copy.wastedCap = copy.cappedTime * copy.regenRate
        end
        if entry.hidden then copy.spent, copy.gained = entry.castSpent, nil end
        view.powers[token] = copy
    end
    return view
end

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
-- Whether a buff a scan didn't find is still up. In combat some aura slots can't be read, so a scan can miss
-- a buff that's still there (seen with Blessing of Wisdom: 0.4 s uptime in a fight where it never dropped).
-- So a buff only ends when the game confirms its aura instance is gone; if that can't be read, it's still up.
local function StillUp(entry, hiddenSlots)
    local id = entry.auraInstanceID
    if id and C_UnitAuras.GetAuraDataByAuraInstanceID then
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", id)
        if not ok then return true end -- unreadable, not gone
        return aura ~= nil
    end
    return hiddenSlots > 0 -- no instance ID: trust the scan only if it read every slot
end

local function UpdateAuras(fight, now)
    if playerDead then return end -- buff uptime stopped at death (OnDeathChanged) and resumes after
    ns.Mana.OnAuras(fight, now)

    -- Listed regen buffs, plus any buff whose description gives mana per 5 sec (e.g. set bonuses).
    local active, hiddenSlots = ScanAuras("HELPFUL", REGEN_BUFFS, RegenMP5)
    for name, info in pairs(active) do
        local entry = fight.buffs[name]
        if not entry then
            entry = { uptime = 0, spellID = info.spellID, icon = info.icon }
            fight.buffs[name] = entry
        end
        entry.mp5 = entry.mp5 or info.mp5
        entry.isDrink = entry.isDrink or info.isDrink
        entry.auraInstanceID = info.auraInstanceID or entry.auraInstanceID
        entry.since = entry.since or now
    end
    for name, entry in pairs(fight.buffs) do
        if entry.since and not active[name] then
            if StillUp(entry, hiddenSlots) then
                Debug("buff", name, "not found by the scan but still up | unreadable slots", hiddenSlots)
            else
                Debug("buff ended", name, "| unreadable slots", hiddenSlots)
                entry.uptime = entry.uptime + (now - entry.since)
                entry.since = nil
                entry.auraInstanceID = nil
            end
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
    if playerDead then return end -- no regen while dead; the dead time counts toward neither window
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
    if ns.debugMode then
        local _, primary = UnitPowerType("player")
        local powerText = IsReadable(primary) and OTHER_POWERS[primary]
            and (primary:lower() .. " " .. Describe(UnitPower("player", OTHER_POWERS[primary]))
                .. " of " .. Describe(UnitPowerMax("player", OTHER_POWERS[primary])))
            or ("mana " .. Describe(UnitPower("player", MANA)) .. " of " .. Describe(maxMana))
        Debug("fight start", encounterName or "Combat", powerText, "target", Describe(UnitName("target")))
    end
    -- Characters without mana (warriors, rogues) have max mana 0; their fights are tracked for rage/energy.
    if not IsReadable(maxMana) then return end

    local now = GetTime()
    local mana = GetMana()
    local targetName = GetHostileTargetName()
    local _, powerToken = UnitPowerType("player")
    local fight = {
        -- The power the character was using at the start ("MANA", "RAGE", "ENERGY"), shown by default.
        primaryPower = IsReadable(powerToken) and powerToken or "MANA",
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
    if OTHER_POWERS[fight.primaryPower] then
        PowerEntry(fight, fight.primaryPower) -- start from the current rage/energy, before any change
    end
    ShowDisplay()

    -- Pre-combat casts count toward the fight. Their mana was spent before combat's own mana tracking
    -- began, so add them to spent. The client file already saw them through OnManaSpend.
    for _, cast in ipairs(recentCasts) do
        if now - cast.time <= PRECOMBAT_WINDOW then
            if not cast.gain and not cast.saving then
                Debug("pre-combat cast", cast.spellID, cast.power or "MANA", "cost", cast.cost)
            end
            if cast.saving then
                ApplySaving(fight, cast.spellID, cast.saving) -- e.g. a pull cast on a Clearcasting proc
            elseif cast.gain then
                AddPowerGain(fight, cast.spellID, cast.gain) -- e.g. the Charge that started the fight
            elseif cast.power then
                AddPowerCast(fight, cast.power, cast.spellID, cast.cost)
                local entry = fight.powers[cast.power]
                if not entry.hidden then entry.spent = entry.spent + cast.cost end
            else
                fight.spent = fight.spent + cast.cost
                AddCast(fight, cast.spellID, cast.cost)
            end
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

    for _, listener in ipairs(ns.fightStartListeners) do
        listener(fight)
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
        entry.auraInstanceID = nil -- only needed while the fight runs
    end

    -- An arena match refills mana as it ends. If the last gain was that refill, it isn't mana recovered during
    -- the match: take it out of recovered and keep it as matchRefill (not shown in the panel).
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
    FinishPowers(fight, now)
    HideDisplayLater()

    local fights = ns.char.fights
    table.insert(fights, fight)
    -- Oldest fights go first once over the limit (a lowered limit takes effect here, at the next fight end).
    while #fights > (ns.db.maxFights or DEFAULT_MAX_FIGHTS) do
        table.remove(fights, 1)
    end

    -- The end-of-fight chat summary is debug output; /mm last still prints it on request.
    if ns.debugMode and (fight.maxMana or 0) > 0 then -- mana summary; rage/energy are logged by FinishPowers
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

    -- While dead, and the resurrection's mana just after: follow the value, but count nothing.
    if IgnoringPowerChanges() then
        current.lastMana = mana
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
    -- Rage and energy costs, from cast start when there's a snapshot.
    local otherCosts = snap and snap.otherCosts or GetOtherPowerCosts(spellID)
    if ns.debugMode then
        local parts = {}
        if HasMana() then
            table.insert(parts, "paid " .. tostring(cost) .. " mana | reducer: "
                .. (FirstReducer(reducersAfter) or "none"))
        end
        local other = OtherPowerDebugText(otherCosts)
        if other ~= "" then table.insert(parts, other) end
        Debug("cast done ", C_Spell.GetSpellName(spellID) or spellID, "(spell " .. spellID .. ")",
            table.concat(parts, " | "), ns.current and "" or "(before combat)")
    end

    for token, powerCost in pairs(otherCosts) do
        if ns.current then
            AddPowerCast(ns.current, token, spellID, powerCost)
        else
            -- e.g. a rogue's Sap before the pull: counted toward the fight that follows, like mana pull casts.
            table.insert(recentCasts, { time = now, spellID = spellID, cost = powerCost, power = token })
            while #recentCasts > 0 and now - recentCasts[1].time > PRECOMBAT_WINDOW do
                table.remove(recentCasts, 1)
            end
        end
    end
    -- Rage/energy the cast gives (Charge, Bloodrage, potions), estimated where gains aren't logged.
    local gain = not ns.Mana.logsPowerGains and GetPowerGain(spellID)
    if gain then
        if ns.current then
            AddPowerGain(ns.current, spellID, gain)
        else
            -- A Charge usually lands just before combat starts; keep it for the fight that follows.
            table.insert(recentCasts, { time = now, spellID = spellID, gain = gain })
        end
    end
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
    ns.InitMeter()
    ns.Mana.Init()

    -- Handles /reload mid-combat.
    if InCombatLockdown() then
        StartFight()
    end
end

-- Whether the arena match has been decided. The fight ends then, not when the arena closes: during the
-- scoreboard the panel kept adding regen and Water Shield mp5 (seen on TBC), which isn't part of the match.
-- GetBattlefieldWinner (classic API) returns the winning team once decided; C_PvP.GetActiveMatchState
-- (newer API) moves to PostRound or Complete. Either may be missing on a client, so both are optional.
------------------------------------------------------------------------------------------------------------
-- Ending fights the way Details! does (core/parser.lua PLAYER_REGEN_ENABLED, functions/util.lua
-- combatTicker), so fights line up with its segments:
--  * solo: the fight ends when the player leaves combat, unless a rogue's Vanish is up;
--  * in a group: it ends only when no group member is in combat, checked every second
--    (FIGHT_END_CHECK_INTERVAL), so dying or dropping out early doesn't split the fight.
-- Boss encounters (ENCOUNTER_END) and arenas (match decided) end the fight their own way, as before.
local FIGHT_END_CHECK_INTERVAL = 1
local VANISH_BUFFS = { 11327, 11329, 26888 } -- the buffs of Vanish ranks 1-3
local fightEnding = false -- the player left combat, but the group or Vanish keeps the fight open
-- Resurrection during a fight (a druid's Rebirth, a soulstone, a shaman's Reincarnation/Ankh): dying
-- takes the player out of combat, but the fight shouldn't end while they can still get up and fight on.
local RES_OFFER_TIMEOUT = 60 -- a resurrection offer expires after a minute
local RES_COMBAT_GRACE = 5 -- seconds after coming back to life to re-enter combat before the fight ends
local resOfferedAt -- GetTime() of the last RESURRECT_REQUEST while dead

-- Read directly rather than from playerDead: leaving combat can come just before PLAYER_DEAD.
local function IsDeadNotReleased()
    local okDead, dead = pcall(UnitIsDead, "player")
    local okGhost, ghost = pcall(UnitIsGhost, "player")
    return okDead and dead == true and not (okGhost and ghost == true)
end

-- Why a dead (not released) player might still get back up in this fight, or nil.
local function PendingResurrection(now)
    if HasSoulstone then
        local ok, option = pcall(HasSoulstone) -- the self-resurrect option, e.g. "Use Soulstone", "Reincarnate"
        if ok and option then return "self-resurrection available" end
    end
    if resOfferedAt and now - resOfferedAt < RES_OFFER_TIMEOUT then return "resurrection offered" end
end

local function Affecting(unit)
    local ok, inCombat = pcall(UnitAffectingCombat, unit)
    return ok and inCombat == true
end

local function GroupInCombat()
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            if Affecting("raid" .. i) then return true end
        end
    elseif IsInGroup() then
        for i = 1, 4 do
            if UnitExists("party" .. i) and Affecting("party" .. i) then return true end
        end
    end
    return false
end

local function VanishUp()
    local _, class = UnitClass("player")
    if class ~= "ROGUE" or not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return false end
    for _, spellID in ipairs(VANISH_BUFFS) do
        local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
        if ok and aura then return true end
    end
    return false
end

-- Whether the running fight should go on although the player left combat, and why.
local function FightShouldContinue()
    local now = GetTime()
    if Affecting("player") then return true, "back in combat" end
    if GroupInCombat() then return true, "group still in combat" end
    if VanishUp() then return true, "Vanish is up" end
    -- Dead but able to get back up (soulstone, Ankh, a battle resurrection offered): wait. Releasing to a
    -- ghost ends the wait.
    if IsDeadNotReleased() then
        local pending = PendingResurrection(now)
        if pending then return true, pending end
    end
    -- Just resurrected: time to re-enter combat before the fight counts as over.
    if not playerDead and now - aliveAt < RES_COMBAT_GRACE then return true, "just resurrected" end
    return false
end

-- Ends the fight unless something keeps it open; then the ticker below checks again every second.
local function TryEndFight()
    local keep, why = FightShouldContinue()
    if keep then
        if not fightEnding then Debug("left combat, fight continues:", why) end
        fightEnding = true
        return
    end
    fightEnding = false
    EndFight()
end

local OnDeathChanged -- defined below; the ticker needs it

C_Timer.NewTicker(FIGHT_END_CHECK_INTERVAL, function()
    -- While dead, re-read the state each second in case a resurrect event was missed.
    if playerDead then OnDeathChanged() end
    if not fightEnding then return end
    if not ns.current or encounterActive or arenaActive then
        fightEnding = false -- ended some other way, or an encounter/arena took over
        return
    end
    TryEndFight()
end)

-- Death started or ended (PLAYER_DEAD, PLAYER_ALIVE, which also fires on becoming a ghost, and
-- PLAYER_UNGHOST). Regen is settled up to now under the old state first: the regen split here, the
-- client's own estimate through ns.Mana.OnDeathChanged. Buff uptime stops at death and resumes after.
function OnDeathChanged() -- the local declared above the ticker
    local ok, dead = pcall(UnitIsDeadOrGhost, "player")
    dead = ok and dead == true
    if dead == playerDead then return end
    local now = GetTime()
    local fight = ns.current
    if fight then AccumulateRegenSplit(fight, now) end
    if ns.Mana.OnDeathChanged then ns.Mana.OnDeathChanged(dead, now) end
    playerDead = dead

    if dead then
        Debug("player died: regen, mana changes and buff uptime paused")
        for _, entry in pairs(fight and fight.buffs or {}) do
            if entry.since then
                entry.uptime = entry.uptime + (now - entry.since)
                entry.since, entry.auraInstanceID = nil, nil
            end
        end
    else
        aliveAt = now
        resOfferedAt = nil
        Debug("player alive: counting resumes in", RES_GRACE, "s")
        if fight then
            fight.splitClock = now
            UpdateAuras(fight, now)
        end
    end
end

local function ArenaMatchDecided()
    if GetBattlefieldWinner then
        local ok, winner = pcall(GetBattlefieldWinner)
        if ok and winner ~= nil then return true, "winner " .. tostring(winner) end
    end
    if C_PvP and C_PvP.GetActiveMatchState and Enum.PvPMatchState then
        local ok, state = pcall(C_PvP.GetActiveMatchState)
        if ok and (state == Enum.PvPMatchState.PostRound or state == Enum.PvPMatchState.Complete) then
            return true, "match state " .. tostring(state)
        end
    end
    return false
end

-- Ends the arena fight (once) and stops a new one starting in the post-match wait.
local function EndArenaFight(reason)
    if not arenaActive then return end
    Debug("arena fight ends:", reason)
    arenaActive = false
    arenaMatchOver = true
    EndFight()
end

-- Events that may mean the match was decided: check, and end the fight if so. Logged in debug mode with
-- their time, to see which signal comes first on each client.
local ARENA_STATE_EVENTS = { UPDATE_BATTLEFIELD_STATUS = true, PVP_MATCH_STATE_CHANGED = true,
    UPDATE_BATTLEFIELD_SCORE = true }

frame:SetScript("OnEvent", function(self, event, ...)
    if ARENA_STATE_EVENTS[event] then
        if arenaActive then
            local decided, how = ArenaMatchDecided()
            Debug("arena event", event, decided and ("-> decided (" .. how .. ")") or "-> not decided")
            if decided then EndArenaFight(event .. ", " .. how) end
        end
        return
    end
    if event == "ADDON_LOADED" then
        if ... == addonName then
            OnAddonLoaded()
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        if InArena() and not arenaMatchOver then
            arenaActive = true
        end
        fightEnding = false -- back in combat: a fight kept open by the group just continues
        StartFight()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- During a boss encounter, wait for ENCOUNTER_END so dying or a brief drop out of combat doesn't split
        -- the fight; in an arena, keep the whole match as one fight. Otherwise end it like Details: now if
        -- solo, or once the whole group is out of combat (TryEndFight).
        if not encounterActive and not arenaActive then
            TryEndFight()
        elseif arenaActive then
            -- Leaving combat as the last enemy dies: end the match here if it's already decided.
            local decided, how = ArenaMatchDecided()
            if decided then EndArenaFight("left combat, " .. how) end
        end
        ns.Mana.OnCombatEnd()
    elseif event == "PVP_MATCH_COMPLETE" then
        EndArenaFight("PVP_MATCH_COMPLETE") -- fallback: comes after the scoreboard's refill
    elseif event == "PLAYER_DEAD" or event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        OnDeathChanged()
    elseif event == "RESURRECT_REQUEST" then
        -- Someone offers a resurrection (e.g. a druid's Rebirth mid-fight): keep the fight open meanwhile.
        resOfferedAt = GetTime()
        Debug("resurrection offered by", Describe((...)))
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        if event == "PLAYER_ENTERING_WORLD" then OnDeathChanged() end -- e.g. logged in dead
        if not InArena() then
            -- Left the arena without the match being decided first (e.g. left early). Reset the flag after,
            -- since ending the fight sets it: the next arena match must start a new arena fight.
            EndArenaFight("left the arena")
            arenaMatchOver = false
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
        elseif OTHER_POWERS[powerType] then
            OnOtherPowerChanged(powerType)
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
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("PLAYER_ALIVE")
frame:RegisterEvent("PLAYER_UNGHOST")
frame:RegisterEvent("RESURRECT_REQUEST")
frame:RegisterEvent("ENCOUNTER_START")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
-- Not every client may have this event; registering an unknown event errors, so guard it.
pcall(frame.RegisterEvent, frame, "PVP_MATCH_COMPLETE")
for arenaEvent in pairs(ARENA_STATE_EVENTS) do
    pcall(frame.RegisterEvent, frame, arenaEvent) -- not every client has all of them
end
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
    elseif msg == "meter" then
        ns.ToggleMeter()
    elseif msg == "minimap" then
        ns.SetMinimapButtonShown(not ns.db.showMinimapButton)
        print(PREFIX .. "minimap button " .. (ns.db.showMinimapButton and "shown" or "hidden"))
    elseif msg == "debug" then
        ns.debugMode = not ns.debugMode
        print(PREFIX .. "debug " .. (ns.debugMode and "on" or "off"))
        ns.db.debugLog = ns.db.debugLog or {}
        local _, class = UnitClass("player")
        local _, powerToken = UnitPowerType("player")
        AppendDebugLog("=== debug", ns.debugMode and "on" or "off", "|", ns.charName, class, powerToken,
            "| build", select(4, GetBuildInfo()), "| version",
            C_AddOns and C_AddOns.GetAddOnMetadata("ManaMaster", "Version"))
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
    elseif msg == "log clear" then
        ns.db.debugLog = {}
        print(PREFIX .. "debug log cleared")
    elseif msg:match("^keep") then
        -- /mm keep shows the limit; /mm keep N sets how many fights each character keeps.
        local count = tonumber(msg:match("^keep%s+(%d+)$"))
        if count then
            count = math.min(MAX_MAX_FIGHTS, math.max(MIN_MAX_FIGHTS, count))
            ns.db.maxFights = count
            local extra = #ns.char.fights - count
            print(PREFIX .. "keeping the last " .. count .. " fights per character"
                .. (extra > 0 and (" (the oldest " .. extra .. " go when the next fight ends)") or ""))
        else
            print(PREFIX .. "keeping the last " .. (ns.db.maxFights or DEFAULT_MAX_FIGHTS)
                .. " fights per character (" .. #ns.char.fights .. " stored). Change with /mm keep <"
                .. MIN_MAX_FIGHTS .. "-" .. MAX_MAX_FIGHTS .. ">")
        end
    elseif msg == "clear" then
        ns.ClearHistory()
    else
        print(PREFIX .. "commands: /mm (history panel) | meter | last | minimap | toggle | debug | log clear"
            .. " | keep [n] | clear")
    end
end
