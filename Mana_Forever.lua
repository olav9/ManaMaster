local _, ns = ...

-- WoW Forever: the player's mana is secret in and out of combat, and addons can't use the combat log.
-- So mana is estimated: a running pool advanced by regen (GetManaRegen and the five-second rule), lowered
-- by spell costs, raised by potion estimates, and anchored to full when mana events go quiet.
-- Implements the ns.Mana hooks called by ManaMaster.lua.

local MANA = ns.MANA
local IsReadable, Debug = ns.IsReadable, ns.Debug

local FIVE_SECOND_RULE = 5 -- seconds after spending mana that regen stays at the reduced casting rate
local POOL_UPDATE_INTERVAL = 1 -- seconds between mana pool estimate updates
local FULL_QUIET_MIN = 2 -- seconds without a mana event (outside the five-second rule) that mean mana is full
local FULL_QUIET_MANA = 3 -- ...or the time to regen this much mana, if that's longer (slow regen fires events rarely)

-- Debuffs (English names) that stop mana regen. While one is on the player, the regen they would have
-- had counts as blocked (wasted) instead of gained. Add names here as they're found in game.
local REGEN_BLOCKERS = {
}

-- Fallback mana restore ranges by spell ID, used when a spell's description can't be read.
local KNOWN_MANA_RESTORES = {
    [437] = { 140, 180 }, -- Restore Mana (Minor Mana Potion), confirmed in game
}

local regenRates -- last readable GetManaRegen() values: { inactive, active } in mana per second
local lastManaSpend = 0 -- GetTime() of the last cast that cost mana, for the five-second rule
-- Estimated mana pool, kept running in and out of combat. mana is nil until the pool is initialised (max
-- mana readable). confirmed turns true once the estimate has been anchored to a known value: a readable
-- reading, or full mana detected from mana events going quiet.
local pool = { mana = nil, max = 0, clock = 0, confirmed = false }
local lastPowerEvent = 0 -- GetTime() of the last mana UNIT_POWER_FREQUENT, for detecting full mana
-- The drink buff currently up, if any: { key, name, spellID, rate } with rate in mana per second.
-- Updated on aura changes during a fight (e.g. drinking between arena bursts).
local drink

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
    if not pool.mana or now <= from then return end
    local current = ns.current

    if regenRates then
        local ruleEnd = lastManaSpend + FIVE_SECOND_RULE
        local activeTime = math.max(0, math.min(now, ruleEnd) - from)
        local inactiveTime = (now - from) - activeTime
        local amount = activeTime * regenRates.active + inactiveTime * regenRates.inactive

        if current and current.regenBlocked then
            current.wastedBlocked = current.wastedBlocked + amount
        else
            local gained = math.min(amount, math.max(0, pool.max - pool.mana))
            pool.mana = pool.mana + gained
            if current then
                -- Regen lost at full mana only counts once the fight has spent mana: being full while the
                -- pull cast is still casting is unavoidable, not waste.
                if current.manaSpentInFight then
                    current.wastedFull = current.wastedFull + (amount - gained)
                end
                current.regen = current.regen + gained
            end
        end
    end

    -- Drinking isn't part of GetManaRegen's rates, so it's added separately from the drink buff's
    -- "N mana over M sec", and booked during a fight as an estimated "Drink" gain.
    if drink then
        local amount = drink.rate * (now - from)
        local gained = math.min(amount, math.max(0, pool.max - pool.mana))
        pool.mana = pool.mana + gained
        if current and current.gains then
            current.wastedFull = current.wastedFull + (amount - gained)
            local entry = current.gains[drink.key]
            if not entry then
                -- periodic: the drink's whole restore is this row, so the passive-regen breakdown skips the buff.
                entry = { casts = 0, mana = 0, spellID = drink.spellID, name = drink.name, periodic = true }
                current.gains[drink.key] = entry
            end
            entry.mana = entry.mana + gained
        end
    end
end

-- Sets the pool to a known value (a readable mana reading, or max when full mana is detected).
local function AnchorPool(mana, reason)
    AdvancePool(GetTime())
    if ns.debugMode and (not pool.confirmed or math.abs((pool.mana or 0) - mana) >= 1) then
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
    local mana = ns.GetMana()
    pool.mana = mana or maxMana
    pool.confirmed = mana ~= nil
end

-- Out of combat, mana events fire continuously while mana regenerates and stop once it's full. So a quiet
-- spell outside the five-second rule (when regen is near zero and events also stop) means mana is full.
local function CheckFullMana(now)
    if ns.current or not pool.mana or not regenRates or regenRates.inactive <= 0 then return end
    if UnitIsDeadOrGhost("player") then return end
    local quiet = math.max(FULL_QUIET_MIN, FULL_QUIET_MANA / regenRates.inactive)
    if now - lastPowerEvent >= quiet and now - quiet >= lastManaSpend + FIVE_SECOND_RULE then
        if pool.mana < pool.max or not pool.confirmed then
            AnchorPool(pool.max, "mana events quiet, so mana is full")
        end
    end
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

-- Runs every POOL_UPDATE_INTERVAL: refreshes regen rates and max mana, advances the pool, and out of
-- combat checks whether mana is full.
local function OnPoolTick()
    local now = GetTime()
    if not pool.mana then
        InitPool()
        if not pool.mana then return end
    end
    local current = ns.current
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

ns.Mana = {}

function ns.Mana.Init()
    -- Keep the mana pool estimate running all the time, in and out of combat.
    lastPowerEvent = GetTime() -- give regen events a moment to arrive before calling mana full
    ReadManaRegen()
    InitPool()
    C_Timer.NewTicker(POOL_UPDATE_INTERVAL, OnPoolTick)
end

-- Called before the fight becomes current, so regen settled up to now isn't booked to it.
function ns.Mana.OnFightStart(fight, now)
    if fight.maxMana <= 0 then
        -- No mana (warrior, rogue): nothing to estimate. Mana reads as a plain 0 for them, so skip the pool.
        fight.startMana = 0
    else
        ReadManaRegen()
        Debug("regen per second", regenRates and regenRates.inactive or "unknown", "while casting",
            regenRates and regenRates.active or "unknown")

        -- Starting mana comes from the running pool estimate, brought up to date with out-of-combat regen.
        -- If nothing has anchored it since login/reload, it's still the initial "assume full".
        if not pool.mana then InitPool() end
        pool.max = fight.maxMana
        local mana = ns.GetMana()
        if mana then
            AnchorPool(mana, "readable at fight start")
        else
            AdvancePool(now)
        end
        fight.startMana = math.min(pool.mana or fight.maxMana, fight.maxMana)
        fight.startManaAssumed = not pool.confirmed or nil
        Debug("start mana", math.floor(fight.startMana + 0.5),
            fight.startManaAssumed and "(assumed full, never anchored)" or "(estimated)")
    end

    fight.wastedFull = 0 -- regen lost to being at max mana
    fight.wastedBlocked = 0 -- regen lost to REGEN_BLOCKERS debuffs
    fight.regenBlocked = false
    fight.regen = 0 -- estimated passive regen, from GetManaRegen and the five-second rule
    fight.gains = {} -- estimated mana restores from potions, runes and gems, keyed by spell ID
end

-- Called while the fight is still current, so the last stretch of regen is booked to it.
function ns.Mana.OnFightEnd(fight, now)
    AdvancePool(now)
    fight.regenBlocked = nil
    fight.manaSpentInFight = nil -- only needed while the fight runs
    drink = nil -- auras aren't tracked out of combat; full-mana detection catches drinking to full there
end

-- Potions, runes and gems: the actual gain is hidden, so add an estimate from the spell's description.
-- Out of combat this only updates the pool estimate.
function ns.Mana.OnSpellCast(spellID, now)
    local restore = GetManaRestore(spellID)
    if not restore then return false end
    AddRestore(ns.current, spellID, restore, now)
    return true
end

function ns.Mana.OnManaSpend(cost, now)
    AdvancePool(now)
    lastManaSpend = now
    if ns.current then ns.current.manaSpentInFight = true end
    if pool.mana then
        pool.mana = math.max(0, pool.mana - cost)
    end
    if not ns.current then
        ReadManaRegen() -- out of combat the rates are more likely readable; cache them for the pull
    end
end

function ns.Mana.OnPowerEvent(mana)
    lastPowerEvent = GetTime()
    if mana then
        AnchorPool(mana, "readable mana event") -- never seen on WoW Forever, but use it if it happens
    end
end

-- Updates the regen-blocked state from REGEN_BLOCKERS debuffs.
function ns.Mana.OnAuras(fight, now)
    local blockers = ns.ScanAuras("HARMFUL", REGEN_BLOCKERS) -- keep only the first return; the second is a count
    local blocked = next(blockers) ~= nil

    -- The drink buff, if one is up: description "N mana over M sec" (RegenMP5 flags it as a drink).
    local newDrink
    for name, info in pairs(ns.ScanAuras("HELPFUL", {}, ns.RegenMP5)) do
        if info.isDrink and info.mp5 then
            newDrink = { key = "drink:" .. (info.spellID or name), name = name, spellID = info.spellID,
                rate = info.mp5 / 5 }
            break
        end
    end

    local drinkChanged = (drink and drink.key) ~= (newDrink and newDrink.key)
    if blocked ~= fight.regenBlocked or drinkChanged then
        AdvancePool(now) -- close the interval under the old state first
        fight.regenBlocked = blocked
        if drinkChanged then
            drink = newDrink
            if drink then
                local entry = fight.gains[drink.key]
                if entry then entry.casts = entry.casts + 1 else
                    fight.gains[drink.key] = { casts = 1, mana = 0, spellID = drink.spellID, name = drink.name,
                        periodic = true }
                end
                Debug("drinking", drink.name, "~" .. math.floor(drink.rate * 5 + 0.5), "mp5")
            end
        end
    end
end

function ns.Mana.OnCombatEnd()
    ReadManaRegen()
end
