local _, ns = ...

-- TBC Anniversary (interface 20506): the player's mana is readable, so the shared core measures spent,
-- recovered and lowest mana directly from UNIT_POWER_FREQUENT deltas. Nothing needs estimating, so most
-- hooks do nothing. Potions, Mana Spring and other gains are already part of the measured recovery.
-- Implements the ns.Mana hooks called by ManaMaster.lua.
-- Planned: combat log parsing for exact per-source gains and drains (the combat log is available here).

local MANA = ns.MANA

ns.Mana = {}

function ns.Mana.Init()
end

function ns.Mana.OnFightStart(fight, now)
    local mana = ns.GetMana()
    fight.startMana = mana or UnitPowerMax("player", MANA)
    fight.startManaAssumed = not mana or nil
    ns.Debug("start mana", fight.startMana, mana and "(read)" or "(not readable, assumed full)")
end

function ns.Mana.OnFightEnd(fight, now)
end

-- No estimates needed: a potion's gain shows up in the measured recovery.
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
