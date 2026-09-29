local _, ns = ...

-- TBC Anniversary (interface 20506): the player's mana is readable, so the shared core measures spent,
-- recovered and lowest mana directly from UNIT_POWER_FREQUENT deltas. The combat log is available too,
-- so mana gains (potions, Mana Spring, Water Shield, ...) and drains aimed at the player are recorded per
-- source with exact amounts. Nothing is estimated.
-- Implements the ns.Mana hooks called by ManaMaster.lua.
-- Never load this file on WoW Forever: registering COMBAT_LOG_EVENT_UNFILTERED there is blocked.

local MANA = ns.MANA

local ENERGIZE_EVENTS = { SPELL_ENERGIZE = true, SPELL_PERIODIC_ENERGIZE = true }
local DRAIN_EVENTS = {
    SPELL_DRAIN = true, SPELL_PERIODIC_DRAIN = true,
    SPELL_LEECH = true, SPELL_PERIODIC_LEECH = true,
}

local playerGUID

-- Adds an amount to a per-source entry (same shape as fight.spells, so the panel can list it).
local function AddEntry(entries, spellID, spellName, amount, rank)
    local key = spellID or spellName
    local entry = entries[key]
    if not entry then
        entry = { casts = 0, mana = 0, spellID = spellID, name = spellName or tostring(spellID), rank = rank }
        entries[key] = entry
    end
    entry.casts = entry.casts + 1
    entry.mana = entry.mana + amount
    return entry
end

-- Combat log fields after the 11 base ones (timestamp ... destRaidFlags):
--   ENERGIZE:     spellId, spellName, spellSchool, amount, overEnergize, powerType, alternatePowerType
--   DRAIN/LEECH:  spellId, spellName, spellSchool, amount, powerType, extraAmount
local function OnCombatLogEvent()
    playerGUID = playerGUID or UnitGUID("player")
    local _, subevent, _, _, sourceName, _, _, destGUID, _, _, _, spellID, spellName, _, amount, arg16, arg17 =
        CombatLogGetCurrentEventInfo()
    if destGUID ~= playerGUID then return end

    -- The core uses every mana gain (in or out of a fight) to correct a cast's mana drop for mana saved.
    if ENERGIZE_EVENTS[subevent] and arg17 == MANA then
        ns.NoteEnergize(amount)
    end

    local fight = ns.current
    if not fight then return end

    if ENERGIZE_EVENTS[subevent] then
        local overEnergize, powerType = arg16 or 0, arg17
        -- Rage and energy gains (e.g. Bloodrage, Thistle Tea) go to that power's entry, overflow as wasted.
        local otherToken = ns.POWER_TOKEN_BY_TYPE[powerType]
        if otherToken then
            local power = ns.PowerEntry(fight, otherToken)
            local entry = AddEntry(power.gains, spellID, spellName, amount)
            entry.periodic = entry.periodic or subevent == "SPELL_PERIODIC_ENERGIZE"
            power.wasted = power.wasted + overEnergize
            ns.Debug("energize", otherToken, spellName, amount)
            return
        end
        if powerType ~= MANA then return end
        -- amount is what was gained; overEnergize is what didn't fit under max mana.
        local entry = AddEntry(fight.gains, spellID, spellName, amount)
        -- Periodic ticks (e.g. Mana Spring) are a buff's whole regen, so the panel's passive-regen breakdown
        -- leaves that buff out; one-off energizes (e.g. Water Shield orbs) don't cover its passive mp5.
        -- Stored as true/false (nil only in fights saved before this was tracked).
        entry.periodic = entry.periodic or subevent == "SPELL_PERIODIC_ENERGIZE"
        fight.wastedFull = fight.wastedFull + overEnergize
        ns.Debug("energize", spellName, amount, overEnergize > 0 and ("(" .. overEnergize .. " over)") or "")
    elseif DRAIN_EVENTS[subevent] then
        local powerType = arg16
        if powerType ~= MANA then return end
        -- Same spell from different casters is kept together; the rank shows the latest caster's name.
        AddEntry(fight.drains, spellID, spellName, amount, sourceName)
        ns.Debug("drain", spellName, "from", sourceName or "?", amount)
    end
end

local combatLogFrame = CreateFrame("Frame")
combatLogFrame:SetScript("OnEvent", OnCombatLogEvent)

ns.Mana = {}
ns.Mana.logsPowerGains = true -- rage/energy gains come from the combat log, so the core doesn't estimate them

function ns.Mana.Init()
    playerGUID = UnitGUID("player")
    combatLogFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
end

function ns.Mana.OnFightStart(fight, now)
    local mana = ns.GetMana()
    fight.startMana = mana or UnitPowerMax("player", MANA)
    fight.startManaAssumed = not mana or nil
    ns.Debug("start mana", fight.startMana, mana and "(read)" or "(not readable, assumed full)")

    fight.gainsMeasured = true -- gains and drains come from the combat log, not estimates
    fight.gains = {} -- energize sources: potions, Mana Spring, Water Shield, ...
    fight.drains = {} -- mana drained or burned from the player
    fight.wastedFull = 0 -- overEnergize: gains that didn't fit under max mana
    fight.wastedBlocked = 0 -- not tracked on TBC
end

function ns.Mana.OnFightEnd(fight, now)
end

-- Potions and the like are measured from the combat log, so casts need no special handling.
function ns.Mana.OnSpellCast(spellID, now)
    return false
end

function ns.Mana.OnManaSpend(cost, now)
end

function ns.Mana.OnPowerEvent(mana)
end

function ns.Mana.OnAuras(fight, now)
end

function ns.Mana.OnCombatEnd()
end
