local _, ns = ...

-- The panel is resizable; its size is saved in ManaMasterDB.panelWidth/panelHeight.
local PANEL_WIDTH, PANEL_HEIGHT = 680, 420 -- default size
local MIN_WIDTH, MIN_HEIGHT = 560, 300
local MAX_WIDTH, MAX_HEIGHT = 1600, 1200
local LIST_SHARE = 0.4 -- share of the panel width given to the fight list...
-- ...within these limits. The list stops growing at 320 (an 800-wide panel); any width beyond that goes
-- to the details pane, which is where long spell names and labels need the room.
local LIST_MIN_WIDTH, LIST_MAX_WIDTH = 240, 320
local ROW_HEIGHT = 42
local ROW_GAP = 2 -- space between fight rows
local ROW_PAD_X = 12 -- inner padding of fight rows
local ROW_PAD_Y = 7
local SPELL_ROW_HEIGHT = 20
local SPELL_ICON_SIZE = 16
local UNKNOWN_ICON = 134400 -- question mark
local SPELL_NAME_LEFT = 4 + SPELL_ICON_SIZE + 6 -- name starts after the icon
local BAR_LEFT = 4 + SPELL_ICON_SIZE + 1 -- bars start just after the icon, like the meter window's
local ROW_FONT = "GameFontHighlight" -- same as the meter window's rows
local ACCENT_R, ACCENT_G, ACCENT_B = 0.25, 0.66, 0.96
local GAIN_R, GAIN_G, GAIN_B = 0.3, 0.85, 0.7 -- green-teal for mana gained, apart from the blue spend bars
local GAIN_HEX = "4dd9b3"
local GAIN_ICON = "Interface\\Icons\\Spell_Magic_ManaGain"
local WASTED_R, WASTED_G, WASTED_B = 0.6, 0.6, 0.6 -- grey for regen that was lost, not gained
local WASTED_HEX = "999999"
local WASTED_ICON = "Interface\\Icons\\Spell_Magic_ManaGain"
local DRAIN_R, DRAIN_G, DRAIN_B = 0.9, 0.3, 0.3 -- red for mana burned or drained by enemies
local DRAIN_HEX = "e64d4d"
local SPEND_HEX = "40a8f5" -- matches ACCENT
local SAVED_R, SAVED_G, SAVED_B = 0.7, 0.45, 0.95 -- purple for mana saved by cost-reducing procs
local SAVED_HEX = "b373f2"
local BUFF_R, BUFF_G, BUFF_B = 0.95, 0.8, 0.3 -- gold for buff uptime, on its own 0-100% scale
local BUFF_HEX = "f2cc4d"
local SECTION_HEADER_HEIGHT = 18
local SECTION_GAP = 12 -- space above each section after the first

local BUTTON_AREA = 40 -- space under the scroll areas for the Clear/Delete buttons
local LIVE_REFRESH_INTERVAL = 1 -- seconds between refreshes while in combat with the panel open

local panel, listScroll, listContent, detailScroll, detailContent, detail, clearButton, deleteButton, selectAllButton
local listWidth, detailWidth = 0, 0 -- set by UpdateLayout from the panel's current width
local rows, entryRows, sectionHeaders = {}, {}, {}
-- Selected fights, as a set of fight tables (so the selection survives new fights being added).
-- Click selects one; Ctrl+click toggles one; Shift+click selects the range from selectionAnchor.
local selected = {}
local selectionAnchor
local animateBars = false -- when true, the next refresh animates detail bars (set by selection changes)

local function ResultText(fight)
    if fight.success == true then
        return " |cff40ff40kill|r"
    elseif fight.success == false then
        return " |cffff4040wipe|r"
    end
    return ""
end

local function IndexOf(fight)
    for i, f in ipairs(ns.char.fights) do
        if f == fight then return i end
    end
end

-- Selected fights in history order (oldest first).
-- The running fight (ns.current) is listed at the top of the panel and can be selected too; it comes last
-- here, being the newest. includeCurrent = false leaves it out (e.g. for deleting).
local function SelectedFights(includeCurrent)
    local list = {}
    for _, fight in ipairs(ns.char.fights) do
        if selected[fight] then table.insert(list, fight) end
    end
    if includeCurrent ~= false and ns.current and selected[ns.current] then
        table.insert(list, ns.current)
    end
    return list
end

local function SelectOnly(fight)
    wipe(selected)
    if fight then selected[fight] = true end
    selectionAnchor = fight
end

local function OnRowClick(fight)
    -- Shift ranges only cover saved fights; for the running fight Shift acts like a plain click.
    if IsShiftKeyDown() and selectionAnchor and IndexOf(selectionAnchor) and IndexOf(fight) then
        local from, to = IndexOf(selectionAnchor), IndexOf(fight)
        if from > to then from, to = to, from end
        wipe(selected)
        for i = from, to do selected[ns.char.fights[i]] = true end
        -- The anchor stays put, so further Shift+clicks extend from the same fight.
    elseif IsControlKeyDown() then
        selected[fight] = not selected[fight] or nil
        selectionAnchor = fight
    else
        SelectOnly(fight)
    end
    animateBars = true
    ns.RefreshHistory()
end

-- Deletes fights from history. If the selection ends up empty, it moves to the next older fight after
-- the deleted ones (the next row down in the list), or the newest.
local function DeleteFights(targets)
    local fights = ns.char.fights
    local lowest
    for _, target in ipairs(targets) do
        local i = IndexOf(target)
        if i then
            table.remove(fights, i)
            selected[target] = nil
            lowest = math.min(lowest or i, i)
        end
    end
    if not next(selected) and lowest then
        SelectOnly(fights[lowest - 1] or fights[lowest] or fights[#fights])
    end
    animateBars = true
    ns.RefreshHistory()
end

-- Adds per-spell entry tables together (fight.spells, gains, drains), keyed the same way.
local function MergeEntries(target, source)
    for key, data in pairs(source or {}) do
        local entry = target[key]
        if not entry then
            entry = { casts = 0, mana = 0, spellID = data.spellID, name = data.name or key, rank = data.rank,
                estimated = data.estimated }
            target[key] = entry
        end
        entry.casts = entry.casts + (data.casts or 0)
        entry.mana = entry.mana + (data.mana or 0)
    end
end

-- Builds one fight-shaped table that adds several fights together, for the details pane. A field is only
-- kept if every fight has it (e.g. recovered), so fights saved by older versions can't skew the totals.
local function CombineFights(fights)
    local combined = {
        isCombined = true,
        count = #fights,
        name = #fights .. " fights",
        date = fights[1].date,
        lastDate = fights[#fights].date,
        duration = 0,
        spent = 0,
        spells = {}, gains = {}, drains = {}, buffs = {}, saved = {},
        maxMana = 100, -- lowestMana below is a percentage, so the panel's lowest % works unchanged
    }
    local all = { recovered = true, regen = true, wastedFull = true, wastedBlocked = true,
        gainsMeasured = true, buffs = true, lowestMana = true, saved = true, regenSplit = true }
    local matchRefill = 0
    local zones, zoneList = {}, {}

    for _, fight in ipairs(fights) do
        combined.duration = combined.duration + (fight.duration or 0)
        combined.spent = combined.spent + (fight.spent or 0)
        for field in pairs(all) do
            if not fight[field] then all[field] = false end
        end
        for _, field in ipairs({ "recovered", "regen", "wastedFull", "wastedBlocked" }) do
            if fight[field] then combined[field] = (combined[field] or 0) + fight[field] end
        end
        if fight.lowestMana and fight.maxMana and fight.maxMana > 0 then
            local pct = fight.lowestMana / fight.maxMana * 100
            combined.lowestMana = math.min(combined.lowestMana or pct, pct)
        end
        matchRefill = matchRefill + (fight.matchRefill or 0)
        if fight.regenSplit then
            combined.regenSplit = combined.regenSplit
                or { castingTime = 0, fullTime = 0, castingRegen = 0, fullRegen = 0 }
            for field, value in pairs(fight.regenSplit) do
                combined.regenSplit[field] = combined.regenSplit[field] + value
            end
        end
        MergeEntries(combined.spells, fight.spells)
        MergeEntries(combined.gains, fight.gains)
        MergeEntries(combined.drains, fight.drains)
        -- Mana saved is grouped by buff, with the spells that used it inside; merge both levels.
        for key, source in pairs(fight.saved or {}) do
            if source.spells then
                local target = combined.saved[key]
                if not target then
                    target = { name = source.name, spellID = source.spellID, icon = source.icon,
                        talent = source.talent, casts = 0, mana = 0, spells = {} }
                    combined.saved[key] = target
                end
                target.casts = target.casts + source.casts
                target.mana = target.mana + source.mana
                MergeEntries(target.spells, source.spells)
            end
        end
        for name, data in pairs(fight.buffs or {}) do
            local entry = combined.buffs[name]
            if not entry then
                entry = { uptime = 0, spellID = data.spellID, icon = data.icon }
                combined.buffs[name] = entry
            end
            entry.uptime = entry.uptime + (data.uptime or 0)
            entry.mp5 = entry.mp5 or data.mp5
        end
        -- Rage/energy: sums per power; gained is kept only if it's known in every fight that has the power.
        for token, source in pairs(fight.powers or {}) do
            combined.powers = combined.powers or {}
            local target = combined.powers[token]
            if not target then
                target = { spent = 0, gained = 0, castSpent = 0, spells = {}, gains = {}, wasted = 0,
                    cappedTime = 0, wastedCap = 0 }
                combined.powers[token] = target
            end
            target.spent = target.spent + (source.spent or source.castSpent or 0)
            if source.gained == nil then target.hidden = true end
            target.gained = target.gained + (source.gained or 0)
            target.wasted = target.wasted + (source.wasted or 0)
            target.cappedTime = target.cappedTime + (source.cappedTime or 0)
            target.wastedCap = target.wastedCap + (source.wastedCap or 0)
            MergeEntries(target.spells, source.spells)
            MergeEntries(target.gains, source.gains)
        end
        if combined.primaryPower == nil then
            combined.primaryPower = fight.primaryPower
        elseif combined.primaryPower ~= fight.primaryPower then
            combined.primaryPower = false -- mixed; ResolvePower picks the first power the fights have
        end
        if fight.zone and fight.zone ~= "" and not zones[fight.zone] then
            zones[fight.zone] = true
            table.insert(zoneList, fight.zone)
        end
    end

    for field, everyFight in pairs(all) do
        if not everyFight then combined[field] = nil end
    end
    combined.gainsMeasured = all.gainsMeasured or nil
    combined.matchRefill = matchRefill > 0 and matchRefill or nil
    combined.zone = table.concat(zoneList, ", ")
    for _, power in pairs(combined.powers or {}) do
        if power.hidden then power.gained = nil end
    end
    combined.primaryPower = combined.primaryPower or nil
    return combined
end

local function GetRow(i)
    if rows[i] then return rows[i] end

    local row = CreateFrame("Button", nil, listContent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * (ROW_HEIGHT + ROW_GAP))
    row:SetPoint("TOPRIGHT", 0, -(i - 1) * (ROW_HEIGHT + ROW_GAP))
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.selected = row:CreateTexture(nil, "BACKGROUND")
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 0.3)

    row.spent = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.spent:SetPoint("TOPRIGHT", -ROW_PAD_X, -ROW_PAD_Y)
    row.spent:SetJustifyH("RIGHT")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("TOPLEFT", ROW_PAD_X, -ROW_PAD_Y)
    row.name:SetPoint("RIGHT", row.spent, "LEFT", -10, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.info:SetPoint("BOTTOMLEFT", ROW_PAD_X, ROW_PAD_Y)
    row.info:SetPoint("BOTTOMRIGHT", -ROW_PAD_X, ROW_PAD_Y)
    row.info:SetJustifyH("LEFT")
    row.info:SetWordWrap(false)

    row:SetScript("OnClick", function(self)
        OnRowClick(self.fight)
    end)

    rows[i] = row
    return row
end

local function GetSectionHeader(i)
    if sectionHeaders[i] then return sectionHeaders[i] end

    local header = CreateFrame("Frame", nil, detail.sections)
    header:SetHeight(SECTION_HEADER_HEIGHT) -- width follows the panel, set in ShowSections

    header.manaLabel = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header.manaLabel:SetPoint("RIGHT", -4, 0)
    header.manaLabel:SetText("Mana")

    header.countLabel = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header.countLabel:SetPoint("RIGHT", -98, 0)

    header.title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header.title:SetPoint("LEFT", 4, 0)

    sectionHeaders[i] = header
    return header
end

-- Shifts a detail row's bar, icon and name right by indent (child rows, e.g. spells under a buff in
-- Mana saved). Rows are pooled, so every row is re-anchored each time it's shown.
local function SetRowIndent(row, indent)
    if row.indent == indent then return end
    row.indent = indent
    row.bar:ClearAllPoints()
    row.bar:SetPoint("TOPLEFT", indent + BAR_LEFT, 0)
    row.bar:SetPoint("BOTTOMLEFT", indent + BAR_LEFT, 0)
    row.track:ClearAllPoints()
    row.track:SetPoint("TOPLEFT", indent + BAR_LEFT, 0)
    row.track:SetPoint("BOTTOMRIGHT")
    row.icon:ClearAllPoints()
    row.icon:SetPoint("LEFT", 4 + indent, 0)
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", SPELL_NAME_LEFT + indent, 0)
    row.name:SetPoint("RIGHT", row.casts, "LEFT", -4, 0)
end

-- Tooltip for a detail row's icon button: the game's own tooltip for its spell, or the row's name and
-- description when there's no spell (or the client can't show it).
local function ShowRowTooltip(button)
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    if button.spellID and pcall(GameTooltip.SetSpellByID, GameTooltip, button.spellID) then
        GameTooltip:Show()
        return
    end
    GameTooltip:ClearLines()
    GameTooltip:AddLine(button.title or "")
    if button.text then
        GameTooltip:AddLine(button.text, 1, 1, 1, true)
    end
    GameTooltip:Show()
end

local function GetEntryRow(i)
    if entryRows[i] then return entryRows[i] end

    local row = CreateFrame("Frame", nil, detail.sections)
    row:SetHeight(SPELL_ROW_HEIGHT) -- width follows the panel, set in ShowSections

    -- Bar length shows the entry's mana relative to the largest entry in any section. Flat colour on a faint
    -- full-width track, starting after the icon (anchored by SetRowIndent), like the meter window.
    row.track = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    row.track:SetColorTexture(1, 1, 1, 0.06)
    row.bar = row:CreateTexture(nil, "BACKGROUND")

    row.mana = row:CreateFontString(nil, "OVERLAY", ROW_FONT)
    row.mana:SetPoint("RIGHT", -4, 0)
    row.mana:SetWidth(90)
    row.mana:SetJustifyH("RIGHT")

    row.casts = row:CreateFontString(nil, "OVERLAY", ROW_FONT)
    row.casts:SetPoint("RIGHT", row.mana, "LEFT", -4, 0)
    row.casts:SetWidth(40)
    row.casts:SetJustifyH("RIGHT")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(SPELL_ICON_SIZE, SPELL_ICON_SIZE)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- trim the icon's built-in border

    -- Hovering the icon shows the spell's tooltip (abilities, auras, potion effects). Rows without a spell,
    -- like "Full regen", show their name and description instead. A button over the icon, since textures
    -- can't take the mouse; it follows the icon when SetRowIndent moves it.
    row.iconButton = CreateFrame("Button", nil, row)
    row.iconButton:SetAllPoints(row.icon)
    row.iconButton:SetScript("OnEnter", ShowRowTooltip)
    row.iconButton:SetScript("OnLeave", GameTooltip_Hide)

    row.name = row:CreateFontString(nil, "OVERLAY", ROW_FONT)
    row.name:SetPoint("LEFT", SPELL_NAME_LEFT, 0)
    row.name:SetPoint("RIGHT", row.casts, "LEFT", -4, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    entryRows[i] = row
    return row
end

-- Rows for the Mana saved section. fight.saved is grouped by the buff that reduced the cost (see
-- RecordSaving in ManaMaster.lua): each buff gets a row with its own icon and the talent behind it
-- (e.g. "Clearcasting  Elemental Focus"), followed by indented rows for the spells that used it and what
-- each saved per cast. Spell rows are a breakdown, so they don't add to the section total.
local CHILD_INDENT = 18

local function BuildSavedEntries(saved)
    local sources = {}
    for _, source in pairs(saved) do
        -- Skip entries in the shape used by earlier development builds (keyed by spell, no spells table).
        if source.spells then table.insert(sources, source) end
    end
    table.sort(sources, function(a, b) return a.mana > b.mana end)

    local entries = {}
    for _, source in ipairs(sources) do
        table.insert(entries, {
            name = source.name,
            rank = source.talent,
            icon = source.icon or (source.spellID and C_Spell.GetSpellTexture(source.spellID)),
            spellID = source.spellID,
            casts = source.casts,
            mana = source.mana,
        })

        local spells = {}
        for _, spell in pairs(source.spells) do table.insert(spells, spell) end
        table.sort(spells, function(a, b) return a.mana > b.mana end)
        for _, spell in ipairs(spells) do
            local perCast = spell.casts > 0 and spell.mana / spell.casts or 0
            table.insert(entries, {
                name = spell.name,
                rank = string.format("%s~%d per cast", spell.rank and (spell.rank .. "  ·  ") or "", perCast + 0.5),
                spellID = spell.spellID,
                casts = spell.casts,
                mana = spell.mana,
                child = true,
            })
        end
    end
    return entries
end

-- Passive regen broken into Mana gained rows of their own: each regen buff with a known mana per 5 sec
-- (estimated over its uptime, marked "passive"), and the rest split into "Regen while casting" and "Full regen"
-- by the five-second rule (or "Spirit and base regen" for fights without that data). With nothing to break it
-- into, it's one "Passive regen" row. Buffs whose regen arrives as logged periodic ticks (e.g. Mana Spring on
-- TBC) already have their own gain row, so they're left out; one-off logged gains (e.g. Water Shield orbs)
-- don't cover a buff's passive mp5, so those buffs stay in. The buff estimates ignore regen lost at full
-- mana, so if they add up to more than the passive total they're scaled down, keeping the parts equal to it.
local function PassiveRegenGroup(fight, passive, passiveRank)
    local coveredByTicks = {}
    for _, entry in pairs(fight.gains or {}) do
        -- periodic: logged ticks (TBC) or the Forever drink estimate. On TBC, nil means a fight saved before
        -- ticks were told apart; treat it as covered to avoid double counting.
        if entry.periodic == true or (fight.gainsMeasured and entry.periodic == nil) then
            coveredByTicks[entry.name] = true
        end
    end

    local children, estimated = {}, 0
    for name, data in pairs(fight.buffs or {}) do
        if data.mp5 and (data.uptime or 0) > 0 and not coveredByTicks[name] then
            local mana = data.mp5 / 5 * data.uptime
            estimated = estimated + mana
            table.insert(children, { name = name, icon = data.icon, spellID = data.spellID,
                rank = "passive " .. ns.FormatNumber(data.mp5) .. " mp5  ·  estimated", mana = mana })
        end
    end

    local scale = estimated > passive and passive / estimated or 1
    for _, child in ipairs(children) do child.mana = child.mana * scale end
    local buffTotal = estimated * scale
    local rest = passive - buffTotal

    -- Regen by the five-second rule, from the game's rates times the time spent in each window
    -- (fight.regenSplit, from ManaMaster.lua). mp5 buffs apply in both windows, so their share (by time)
    -- is taken out of each prediction first.
    local split = fight.regenSplit
    local totalTime = split and (split.castingTime + split.fullTime) or 0
    local predCasting, predFull = 0, 0
    if totalTime > 0 then
        predCasting = math.max(0, split.castingRegen - buffTotal * split.castingTime / totalTime)
        predFull = math.max(0, split.fullRegen - buffTotal * split.fullTime / totalTime)
    end
    local predicted = predCasting + predFull
    if rest >= 1 and predicted > 0 then
        local casting, full, unaccounted
        if fight.gainsMeasured then
            -- TBC: recovery is measured, so show the windows at their predicted values and what nothing explains
            -- as "Unaccounted", instead of hiding it inside the windows. If the predictions exceed the measured
            -- rest (regen lost at full mana), scale them down to fit.
            local fit = predicted > rest and rest / predicted or 1
            casting, full = predCasting * fit, predFull * fit
            unaccounted = rest - casting - full
        else
            -- WoW Forever: the rest is itself an estimate from the same rates, so split it in proportion.
            casting = rest * predCasting / predicted
            full, unaccounted = rest - casting, 0
        end

        -- Average rates the game reported (including mp5 buffs), to compare with the character sheet.
        local FormatDuration = ns.FormatDuration
        local function Rate(regen, seconds)
            return seconds > 0 and string.format("%.1f/s", regen / seconds) or "no time"
        end
        if casting >= 1 then
            table.insert(children, { name = "Regen while casting", icon = GAIN_ICON, mana = casting,
                rank = string.format("%s within the 5-second rule  ·  %s", FormatDuration(split.castingTime),
                    Rate(split.castingRegen, split.castingTime)) })
        end
        if full >= 1 then
            table.insert(children, { name = "Full regen", icon = GAIN_ICON, mana = full,
                rank = string.format("%s outside the 5-second rule  ·  %s", FormatDuration(split.fullTime),
                    Rate(split.fullRegen, split.fullTime)) })
        end
        if unaccounted >= 1 then
            table.insert(children, { name = "Unaccounted", icon = UNKNOWN_ICON, mana = unaccounted,
                rank = "measured recovery not explained by regen or logged gains" })
        end
    elseif rest >= 1 and #children > 0 then
        table.insert(children, { name = "Spirit and base regen", rank = "the rest", mana = rest, icon = GAIN_ICON })
    end

    -- Without anything to break it into (e.g. fights saved before the split), keep one Passive regen row.
    if #children == 0 then
        return { { name = "Passive regen", rank = passiveRank, mana = passive, icon = GAIN_ICON } }
    end
    return children
end

------------------------------------------------------------------------------------------------------------
-- Power types. Mana has the full set of sections; rage and energy (fight.powers, see ManaMaster.lua) have
-- spent and gained. The panel shows the fight's main power unless another is picked with the power button.

local POWER_LABELS = { MANA = "Mana", RAGE = "Rage", ENERGY = "Energy" }
local POWER_ORDER = { "MANA", "RAGE", "ENERGY" }
local POWER_GAIN_ICONS = {
    RAGE = "Interface\\Icons\\Ability_Racial_BloodRage",
    ENERGY = "Interface\\Icons\\INV_Drink_Milk_05", -- Thistle Tea
}
local selectedPower -- the power picked with the power button; nil = each fight's main power

-- The powers a fight has data for, in POWER_ORDER.
local function PowersOf(fight)
    local list = {}
    for _, token in ipairs(POWER_ORDER) do
        local has
        if token == "MANA" then
            -- Combined fights always carry maxMana = 100, so they go by what was recorded instead.
            has = (not fight.isCombined and (fight.maxMana or 0) > 0) or next(fight.spells or {}) ~= nil
                or (fight.spent or 0) > 0 or (fight.recovered or 0) > 0
        else
            has = fight.powers and fight.powers[token] ~= nil
        end
        if has then table.insert(list, token) end
    end
    return list
end

-- The power to show for a fight: the picked one if the fight has it, else the fight's main power.
local function ResolvePower(fight)
    local powers = PowersOf(fight)
    for _, token in ipairs(powers) do
        if token == selectedPower then return token end
    end
    for _, token in ipairs(powers) do
        if token == fight.primaryPower then return token end
    end
    return powers[1] or "MANA"
end

-- The fight's spending in its main power, for the fight list: rage for a warrior rather than mana.
local function PrimarySpent(fight)
    local entry = fight.powers and fight.primaryPower and fight.powers[fight.primaryPower]
    if entry then return entry.spent or entry.castSpent or 0 end
    return fight.spent or 0
end

local function PowerColor(token)
    local color = PowerBarColor and PowerBarColor[token]
    if color then return color.r, color.g, color.b end
    return ACCENT_R, ACCENT_G, ACCENT_B
end

-- Sections for rage or energy: spent per ability, and gained (logged sources, the measured rest, and grey
-- wasted rows). Where the value is hidden (e.g. rage on WoW Forever) only spending is known.
local function BuildPowerSections(fight, token)
    local entry = fight.powers and fight.powers[token]
    local label = POWER_LABELS[token] or token
    local r, g, b = PowerColor(token)
    local hex = string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
    local gainIcon = POWER_GAIN_ICONS[token] or GAIN_ICON

    local gained, emptyText, note = {}, nil, nil
    if entry then
        -- Logged (TBC) or estimated from the ability's description (Charge, Bloodrage, potions).
        gained = ns.SortedEntries(entry.gains)
        for _, gain in ipairs(gained) do
            if gain.estimated then gain.rank = (gain.rank and (gain.rank .. ", ") or "") .. "estimated" end
        end
    end
    if not entry then
        emptyText = "No " .. label:lower() .. " tracked for this fight"
    elseif entry.gained == nil then
        -- Hidden: only the known sources above; the rest (e.g. rage from damage) can't be seen.
        local rest = token == "RAGE" and "rage from damage dealt and taken" or "energy regeneration"
        emptyText = label .. " is hidden on this client; " .. rest .. " isn't known"
        note = #gained > 0 and ("Only known sources; " .. rest .. " is hidden") or nil
    else
        local logged = 0
        for _, gain in ipairs(gained) do logged = logged + gain.mana end
        local rest = entry.gained - logged
        if rest >= 1 then
            table.insert(gained, {
                name = token == "RAGE" and "From damage dealt and taken" or (label .. " regeneration"),
                rank = "measured, not from a known source", mana = rest, icon = gainIcon,
            })
        end
        table.sort(gained, function(a, c) return a.mana > c.mana end)
        if (entry.wasted or 0) >= 1 then
            table.insert(gained, { name = "Overflow (past max)", mana = entry.wasted, icon = WASTED_ICON,
                excluded = true })
        end
    end
    if entry and (entry.wastedCap or 0) >= 1 then
        table.insert(gained, { name = "Wasted at max " .. label:lower(),
            rank = ns.FormatDuration(entry.cappedTime or 0) .. " at max  ·  estimated",
            mana = entry.wastedCap, icon = WASTED_ICON, excluded = true })
    end

    return {
        { title = label .. " spent", hex = hex, r = r, g = g, b = b, sign = "", countLabel = "Casts",
          valueLabel = label, entries = entry and ns.SortedEntries(entry.spells) or {},
          emptyText = not entry and emptyText or nil },
        { title = token == "RAGE" and "Rage generated" or (label .. " gained"), hex = GAIN_HEX,
          r = GAIN_R, g = GAIN_G, b = GAIN_B, sign = "+", countLabel = "Count", valueLabel = label,
          entries = gained, emptyText = emptyText, note = note },
    }
end

-- The sections for a fight, top to bottom: spent, gained, regen buff uptime, saved, drained (mana), or
-- spent and gained for rage/energy (power, default mana).
local function BuildSections(fight, power)
    if power and power ~= "MANA" then
        return BuildPowerSections(fight, power)
    end
    -- Mana gained comes in three flavours:
    --  * gainsMeasured (TBC, combat log): each energize source is exact; passive regen is what the measured
    --    recovery has left over after those.
    --  * recovered only (mana readable, no per-source data): one "All mana recovered" row.
    --  * otherwise (WoW Forever): potions and passive regen are estimates.
    local gained, passive, passiveRank
    if fight.gainsMeasured then
        gained = ns.SortedEntries(fight.gains)
        passive = (fight.recovered or 0) - ns.RestoredTotal(fight)
        passiveRank = "recovered mana not from a logged source"
    elseif fight.recovered then
        gained = {}
        if fight.recovered > 0 then
            table.insert(gained, { name = "All mana recovered", mana = fight.recovered, icon = GAIN_ICON })
        end
    else
        gained = ns.SortedEntries(fight.gains)
        for _, entry in ipairs(gained) do
            entry.rank = entry.rank and (entry.rank .. ", estimated") or "estimated"
        end
        passive = fight.regen
        passiveRank = "estimated"
    end
    table.sort(gained, function(a, b) return a.mana > b.mana end)

    -- Passive regen goes in as its parts (buffs, regen while casting, full regen), each a row of its own,
    -- sorted with the other gains so the biggest source is at the top.
    if passive and passive >= 1 then
        for _, entry in ipairs(PassiveRegenGroup(fight, passive, passiveRank)) do
            table.insert(gained, entry)
        end
        table.sort(gained, function(a, b) return a.mana > b.mana end)
    end

    -- Wasted mana goes last, in grey, and isn't counted in the section total since it was never gained.
    -- Fights saved before wasted regen was tracked have no wastedFull.
    if fight.wastedFull then
        if fight.wastedFull >= 1 then
            local name = fight.gainsMeasured and "Overenergized (past max mana)" or "Wasted at full mana"
            table.insert(gained, { name = name, rank = not fight.gainsMeasured and "estimated" or nil,
                mana = fight.wastedFull, icon = WASTED_ICON, excluded = true })
        end
        if fight.wastedBlocked >= 1 then
            table.insert(gained, { name = "Wasted while regen blocked", rank = "estimated", mana = fight.wastedBlocked,
                icon = WASTED_ICON, excluded = true })
        end
    end

    -- The arena's end-of-match refill: shown for completeness, but not mana recovered during the match.
    if fight.matchRefill then
        table.insert(gained, { name = "Match-end refill", rank = "arena refills mana as the match ends; not counted",
            mana = fight.matchRefill, icon = GAIN_ICON, excluded = true })
    end

    local sections = {
        { title = "Mana spent", hex = SPEND_HEX, r = ACCENT_R, g = ACCENT_G, b = ACCENT_B, sign = "",
          countLabel = "Casts", valueLabel = "Mana", entries = ns.SortedEntries(fight.spells) },
        { title = "Mana gained", hex = GAIN_HEX, r = GAIN_R, g = GAIN_G, b = GAIN_B, sign = "+",
          countLabel = "Count", valueLabel = "Mana", entries = gained },
    }

    -- Regen buff uptime sits right under Mana gained, since the buffs explain much of the gains.
    -- Fights saved before buff tracking have no buffs table; skip the section for those.
    if fight.buffs then
        -- Mana logged from the combat log (TBC) per source name, to show next to buffs of the same name.
        local loggedByName = {}
        if fight.gainsMeasured then
            for _, entry in pairs(fight.gains or {}) do
                loggedByName[entry.name] = (loggedByName[entry.name] or 0) + entry.mana
            end
        end

        local buffs = {}
        for name, data in pairs(fight.buffs) do
            local fraction = fight.duration > 0 and math.min(1, data.uptime / fight.duration) or 0
            -- What the buff was worth: an estimate from its mana per 5 sec over its uptime (regen past max
            -- mana isn't subtracted), and/or the exact mana logged under its name (e.g. Mana Spring ticks,
            -- Water Shield orbs). Both can apply: Water Shield's passive mp5 isn't logged, its orbs are.
            local parts = {}
            if data.mp5 then
                table.insert(parts, string.format("%s mp5  ·  ~%s est.", ns.FormatNumber(data.mp5),
                    ns.FormatNumber(data.mp5 / 5 * data.uptime)))
            end
            if loggedByName[name] then
                table.insert(parts, "+" .. ns.FormatNumber(loggedByName[name]) .. " logged")
            end
            local worth = #parts > 0 and table.concat(parts, "  ·  ") or nil
            table.insert(buffs, {
                name = name,
                rank = worth,
                spellID = data.spellID,
                icon = data.icon,
                casts = ns.FormatDuration(data.uptime),
                valueText = string.format("%d%%", fraction * 100 + 0.5),
                fraction = fraction,
            })
        end
        table.sort(buffs, function(a, b) return a.fraction > b.fraction end)
        table.insert(sections, { title = "Regen buff uptime", hex = BUFF_HEX, r = BUFF_R, g = BUFF_G, b = BUFF_B,
            countLabel = "Time", valueLabel = "Uptime", isUptime = true, entries = buffs })
    end

    -- Fights saved before mana-saved tracking have no saved table; skip the section for those.
    if fight.saved then
        local savedEntries = BuildSavedEntries(fight.saved)
        table.insert(sections, { title = "Mana saved", hex = SAVED_HEX, r = SAVED_R, g = SAVED_G, b = SAVED_B,
            sign = "", countLabel = "Casts", valueLabel = "Mana", entries = savedEntries })
    end

    table.insert(sections, { title = "Mana drained", hex = DRAIN_HEX, r = DRAIN_R, g = DRAIN_G, b = DRAIN_B,
        sign = "-", countLabel = "Count", valueLabel = "Mana", entries = ns.SortedEntries(fight.drains) })

    return sections
end
ns.BuildSections = BuildSections -- also used by the meter window (MeterWindow.lua)

-- Bar animation: when the selection changes, each detail bar slides from its current width to its new one.
-- Resizing the panel sets widths instantly instead, since it re-lays out every frame while dragging.
local BAR_ANIM_DURATION = 0.25 -- seconds
local animatingRows = {}
local animFrame = CreateFrame("Frame")
animFrame:Hide()
animFrame:SetScript("OnUpdate", function()
    local now = GetTime()
    for row in pairs(animatingRows) do
        local t = (now - row.animStart) / BAR_ANIM_DURATION
        if t >= 1 then
            row.bar:SetWidth(row.animTo)
            animatingRows[row] = nil
        else
            local eased = 1 - (1 - t) ^ 3 -- ease-out: fast start, gentle stop
            row.bar:SetWidth(row.animFrom + (row.animTo - row.animFrom) * eased)
        end
    end
    if not next(animatingRows) then animFrame:Hide() end
end)

-- Sets a row's bar width, animated from its current width if requested. wasVisible: whether the bar
-- was on screen before this update; bars that weren't grow from zero.
local function SetBarWidth(row, width, wasVisible)
    if not animateBars then
        animatingRows[row] = nil
        row.bar:SetWidth(width)
        return
    end
    row.animFrom = wasVisible and row.bar:GetWidth() or 1
    row.animTo = width
    row.animStart = GetTime()
    row.bar:SetWidth(row.animFrom)
    animatingRows[row] = true
    animFrame:Show()
end

-- Lays out section headings and rows top to bottom; returns the total height used.
local function ShowSections(fight, power)
    local FormatNumber = ns.FormatNumber
    local sections = BuildSections(fight, power)

    -- One scale for every mana bar, so gained, spent and drained lengths compare directly.
    -- Uptime bars use their own 0-100% scale.
    local top = 0
    for _, section in ipairs(sections) do
        if not section.isUptime then
            for _, entry in ipairs(section.entries) do
                top = math.max(top, entry.mana)
            end
        end
    end

    local y, rowIndex = 0, 0
    for s, section in ipairs(sections) do
        if s > 1 then y = y + SECTION_GAP end

        local header = GetSectionHeader(s)
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", 0, -y)
        header:SetWidth(detailWidth)
        local total = 0
        if section.isUptime then
            header.title:SetText("|cff" .. section.hex .. section.title .. "|r")
        else
            for _, entry in ipairs(section.entries) do
                -- Wasted (excluded) rows were never gained; child rows break down their parent row.
                if not entry.excluded and not entry.child then total = total + entry.mana end
            end
            header.title:SetText(string.format("|cff%s%s|r  |cffffffff%s%s|r",
                section.hex, section.title, total > 0 and section.sign or "", FormatNumber(total)))
        end
        header.countLabel:SetText(section.countLabel)
        header.manaLabel:SetText(section.valueLabel)
        header:Show()
        y = y + SECTION_HEADER_HEIGHT + 2

        local entries = section.entries
        local counted = 0
        for _, entry in ipairs(entries) do
            if not entry.excluded and not entry.child then counted = counted + 1 end
        end
        for _, entry in ipairs(entries) do
            rowIndex = rowIndex + 1
            local row = GetEntryRow(rowIndex)
            local wasVisible = row:IsShown() and row.bar:IsShown()
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -y)
            row:SetWidth(detailWidth)
            local indent = entry.child and CHILD_INDENT or 0
            SetRowIndent(row, indent)
            row.name:SetText(entry.name .. (entry.rank and ("  |cff999999" .. entry.rank .. "|r") or ""))
            -- Fights saved before spell IDs were stored only have the name, which finds the icon for known spells.
            row.icon:SetTexture(entry.icon or C_Spell.GetSpellTexture(entry.spellID or entry.name) or UNKNOWN_ICON)
            row.icon:SetDesaturated(entry.excluded == true)
            row.icon:Show()
            row.iconButton.spellID = type(entry.spellID) == "number" and entry.spellID or nil
            row.iconButton.title = entry.name
            row.iconButton.text = entry.rank
            row.iconButton:Show()
            row.casts:SetText(entry.casts or "")
            local fraction
            if section.isUptime then
                row.mana:SetText(entry.valueText)
                fraction = entry.fraction
            elseif entry.excluded then
                row.mana:SetText("|cff" .. WASTED_HEX .. "~" .. FormatNumber(entry.mana) .. "|r")
                fraction = entry.mana / top
            elseif entry.child then
                row.mana:SetText(section.sign .. FormatNumber(entry.mana))
                fraction = entry.mana / top
            else
                -- Share of the section total, only when there's more than one counted entry to compare.
                local share = counted > 1 and string.format(" (%d%%)", entry.mana / total * 100) or ""
                row.mana:SetText(section.sign .. FormatNumber(entry.mana) .. share)
                fraction = entry.mana / top
            end
            if entry.excluded then
                row.bar:SetColorTexture(WASTED_R, WASTED_G, WASTED_B, 0.6)
            else
                -- Child rows get a fainter bar, so the parent row reads as the total.
                row.bar:SetColorTexture(section.r, section.g, section.b, entry.child and 0.45 or 0.7)
            end
            row.track:Show()
            SetBarWidth(row, math.max(1, (detailWidth - indent - BAR_LEFT) * fraction), wasVisible)
            row.bar:Show()
            row:Show()
            y = y + SPELL_ROW_HEIGHT
        end

        -- A grey text row: why the section is empty, or a note under its rows (e.g. hidden rage).
        local message = #entries == 0 and (section.emptyText or "None recorded") or section.note
        if message then
            rowIndex = rowIndex + 1
            local row = GetEntryRow(rowIndex)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -y)
            row:SetWidth(detailWidth)
            SetRowIndent(row, 0)
            row.name:SetText("|cff888888" .. message .. "|r")
            row.icon:Hide()
            row.iconButton:Hide()
            row.casts:SetText("")
            row.mana:SetText("")
            row.bar:Hide()
            row.track:Hide()
            row:Show()
            y = y + SPELL_ROW_HEIGHT
        end
    end

    for i = #sections + 1, #sectionHeaders do sectionHeaders[i]:Hide() end
    for i = rowIndex + 1, #entryRows do entryRows[i]:Hide() end
    return y
end

local function ShowDetail(fight)
    local FormatNumber = ns.FormatNumber

    if not fight then
        detail.powerButton:Hide()
        detail.title:SetText("No fights recorded yet.")
        detail.info:SetText("")
        detail.stats:SetText("")
        detail.sections:Hide()
        detailContent:SetHeight(1)
        return
    end

    if fight.isCombined then
        detail.title:SetText(fight.name .. " |cff999999combined|r")
        detail.info:SetText(string.format("%s – %s  ·  %s total  ·  %s",
            date("%m/%d %H:%M", fight.date), date("%m/%d %H:%M", fight.lastDate),
            ns.FormatDuration(fight.duration), fight.zone))
    else
        detail.title:SetText(fight.name .. (fight.isLive and "  |cff40ff40in combat|r" or ResultText(fight)))
        detail.info:SetText(string.format("%s  ·  %s  ·  %s",
            date("%m/%d %H:%M", fight.date), ns.FormatDuration(fight.duration), fight.zone or ""))
    end

    -- One summary line: Spent, Regen and Start mana. The breakdowns (net, potions, estimates) are in the
    -- sections below. Regen is the measured recovery where mana was readable (TBC), otherwise the estimate.
    -- Rage and energy: spent and gained, or only spent where the value is hidden.
    local power = ResolvePower(fight)
    local parts = { "Spent " .. FormatNumber(fight.spent) }
    if power ~= "MANA" then
        local entry = fight.powers and fight.powers[power]
        parts = { "Spent " .. FormatNumber(entry and (entry.spent or entry.castSpent) or 0) }
        local verb = power == "RAGE" and "Generated " or "Gained "
        if entry and entry.gained then
            table.insert(parts, verb .. FormatNumber(entry.gained))
        elseif entry and next(entry.gains or {}) then
            -- Hidden: only the estimated known sources (Charge, Bloodrage, potions).
            local known = 0
            for _, gain in pairs(entry.gains) do known = known + (gain.mana or 0) end
            table.insert(parts, verb .. "~" .. FormatNumber(known) .. " from known sources")
        end
    elseif fight.recovered then
        table.insert(parts, "Regen " .. FormatNumber(fight.recovered))
    elseif fight.regen then
        table.insert(parts, "Regen ~" .. FormatNumber(fight.regen))
    end
    -- Combined fights have no single start mana; fights saved before it was tracked have none either.
    if power == "MANA" and fight.startMana and fight.maxMana and fight.maxMana > 0 and not fight.isCombined then
        local pct = fight.startMana / fight.maxMana * 100 + 0.5
        if fight.startManaAssumed then
            table.insert(parts, "Start mana assumed full")
        elseif fight.gainsMeasured then
            table.insert(parts, string.format("Start mana %d%%", pct)) -- TBC: read directly
        else
            table.insert(parts, string.format("Start mana ~%d%% (est.)", pct))
        end
    end
    detail.stats:SetText(table.concat(parts, "   "))

    detail.sections:Show()
    -- The power button cycles through the fight's powers; it's only shown when there's more than one.
    local powers = PowersOf(fight)
    if #powers > 1 then
        local r, g, b = PowerColor(power)
        detail.powerButton:SetText(string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255,
            POWER_LABELS[power] or power))
        detail.powerButton.powers, detail.powerButton.power = powers, power
        detail.powerButton:Show()
    else
        detail.powerButton:Hide()
    end

    local sectionsHeight = ShowSections(fight, power)

    local height = detail.title:GetStringHeight() + 4 + detail.info:GetStringHeight() + 8
        + detail.stats:GetStringHeight() + 14 + sectionsHeight
    detailContent:SetHeight(height)
end

-- Selects the newest fight and scrolls both panes to the top. Used when the panel opens, and when a
-- fight ends while it's open so the new segment is shown straight away. Does nothing while it's closed.
function ns.ShowNewestFight()
    if not panel or not panel:IsShown() then return end
    local fights = ns.char.fights
    SelectOnly(fights[#fights])
    animateBars = true
    listScroll:SetVerticalScroll(0)
    detailScroll:SetVerticalScroll(0)
    ns.RefreshHistory()
end

function ns.RefreshHistory()
    if not panel or not panel:IsShown() then return end
    local fights = ns.char.fights

    -- Drop selected fights that were pruned or deleted; fall back to the newest if nothing is left.
    local present = {}
    for _, fight in ipairs(fights) do present[fight] = true end
    if ns.current then present[ns.current] = true end
    for fight in pairs(selected) do
        if not present[fight] then selected[fight] = nil end
    end
    if selectionAnchor and not present[selectionAnchor] then selectionAnchor = nil end
    if not next(selected) then
        SelectOnly(fights[#fights])
    end
    local selectedList = SelectedFights()
    local deletable = #SelectedFights(false)

    -- The list: the running fight first (live), then saved fights, newest first.
    local live = ns.LiveFightView()
    local listed = {}
    if live then table.insert(listed, ns.current) end
    for i = #fights, 1, -1 do table.insert(listed, fights[i]) end

    for i, fight in ipairs(listed) do
        local row = GetRow(i)
        row.fight = fight
        local isLive = fight == ns.current
        local shown = isLive and live or fight
        row.name:SetText(shown.name .. (isLive and "  |cff40ff40in combat|r" or ResultText(shown)))
        row.spent:SetText(ns.FormatNumber(PrimarySpent(shown)))
        row.info:SetText(string.format("%s  ·  %s  ·  %s", isLive and "Now" or date("%m/%d %H:%M", shown.date),
            ns.FormatDuration(shown.duration), shown.zone or ""))
        row.selected:SetShown(selected[fight] == true)
        row:Show()
    end
    for i = #listed + 1, #rows do
        rows[i]:Hide()
    end
    listContent:SetHeight(math.max(1, #listed * (ROW_HEIGHT + ROW_GAP)))

    local count = #fights
    clearButton:SetEnabled(count > 0)
    selectAllButton:SetEnabled(count > 1 and #selectedList < #listed)
    deleteButton:SetEnabled(deletable > 0)
    deleteButton:SetText(deletable > 1 and ("Delete " .. deletable .. " segments") or "Delete segment")

    -- The running fight is shown through a live view (duration so far, uptime of buffs still up).
    for i, fight in ipairs(selectedList) do
        if fight == ns.current then selectedList[i] = live end
    end
    if #selectedList > 1 then
        ShowDetail(CombineFights(selectedList))
    else
        ShowDetail(selectedList[1])
    end
    animateBars = false -- only the refresh right after a selection change animates
end

-- While in combat with the panel open, refresh every second so the running fight updates live.
C_Timer.NewTicker(LIVE_REFRESH_INTERVAL, function()
    if ns.current and panel and panel:IsShown() then
        animateBars = true -- bars slide as mana is spent, and new spells' bars grow in
        ns.RefreshHistory()
    end
end)

-- When a fight starts with the panel open, switch to it, like a new segment in a damage meter.
table.insert(ns.fightStartListeners, function(fight)
    if not panel or not panel:IsShown() then return end
    SelectOnly(fight)
    animateBars = true
    listScroll:SetVerticalScroll(0)
    ns.RefreshHistory()
end)

-- Deletes the selected fights; asks first when there's more than one.
local function DeleteSelected()
    local list = SelectedFights(false)
    if #list > 1 then
        StaticPopup_Show("MANAMASTER_DELETE_SELECTED", #list)
    else
        DeleteFights(list)
    end
end

StaticPopupDialogs["MANAMASTER_DELETE_SELECTED"] = {
    text = "Delete the %d selected fights? This can't be undone.",
    button1 = YES,
    button2 = NO,
    OnAccept = function() DeleteFights(SelectedFights(false)) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["MANAMASTER_CLEAR_HISTORY"] = {
    text = "Delete all %d saved fights? This can't be undone.",
    button1 = YES,
    button2 = NO,
    OnAccept = function() ns.ClearHistory() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Splits the panel's width between the fight list and the details pane, and resizes both.
local function UpdateLayout()
    local width = panel:GetWidth()
    listWidth = math.floor(math.min(LIST_MAX_WIDTH, math.max(LIST_MIN_WIDTH, width * LIST_SHARE)))
    local detailLeft = 12 + listWidth + 38 -- leaves room for the list's scroll bar
    detailWidth = math.floor(width - detailLeft - 34)

    listScroll:SetWidth(listWidth)
    listContent:SetWidth(listWidth)
    detailScroll:ClearAllPoints()
    detailScroll:SetPoint("TOPLEFT", detailLeft, -32)
    detailScroll:SetPoint("BOTTOMLEFT", detailLeft, BUTTON_AREA)
    detailScroll:SetWidth(detailWidth)
    detailContent:SetWidth(detailWidth)
    detail.sections:SetWidth(detailWidth)
end

local function CreatePanel()
    panel = CreateFrame("Frame", "ManaMasterHistoryFrame", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(ns.db.panelWidth or PANEL_WIDTH, ns.db.panelHeight or PANEL_HEIGHT)
    panel:SetPoint("CENTER")
    panel:SetResizable(true)
    if panel.SetResizeBounds then
        panel:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)
    else
        panel:SetMinResize(MIN_WIDTH, MIN_HEIGHT) -- older clients
        panel:SetMaxResize(MAX_WIDTH, MAX_HEIGHT)
    end
    panel:SetFrameStrata("HIGH") -- below DIALOG so the clear confirmation shows on top
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:Hide()
    panel.TitleText:SetText("ManaMaster - Fight History - " .. (ns.charName or "")) -- fights are per character
    tinsert(UISpecialFrames, panel:GetName()) -- close with Escape

    -- Widths are set by UpdateLayout once everything exists.
    listScroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", 12, -32)
    listScroll:SetPoint("BOTTOMLEFT", 12, BUTTON_AREA)
    listContent = CreateFrame("Frame", nil, listScroll)
    listContent:SetHeight(1)
    listScroll:SetScrollChild(listContent)

    detailScroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    detailContent = CreateFrame("Frame", nil, detailScroll)
    detailContent:SetHeight(1)
    detailScroll:SetScrollChild(detailContent)

    -- Always open on the newest fight, scrolled to the top, rather than whatever was viewed last time.
    panel:SetScript("OnShow", ns.ShowNewestFight)

    detail = {}
    detail.title = detailContent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    detail.title:SetPoint("TOPLEFT")
    detail.title:SetPoint("TOPRIGHT", -80, 0) -- room for the power button
    detail.title:SetJustifyH("LEFT")

    -- Cycles the shown power (Mana / Rage / Energy) for fights with more than one, e.g. a druid's.
    -- The pick sticks across fights; fights without that power show their main one.
    detail.powerButton = CreateFrame("Button", nil, detailContent, "UIPanelButtonTemplate")
    detail.powerButton:SetSize(72, 20)
    detail.powerButton:SetPoint("TOPRIGHT", 0, 2)
    detail.powerButton:SetScript("OnClick", function(self)
        local powers, index = self.powers or {}, 1
        for i, token in ipairs(powers) do
            if token == self.power then index = i end
        end
        selectedPower = powers[index % #powers + 1]
        animateBars = true
        ns.RefreshHistory()
    end)
    detail.powerButton:Hide()

    detail.info = detailContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    detail.info:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -4)
    detail.info:SetPoint("TOPRIGHT", detail.title, "BOTTOMRIGHT", 0, -4)
    detail.info:SetJustifyH("LEFT")

    detail.stats = detailContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    detail.stats:SetPoint("TOPLEFT", detail.info, "BOTTOMLEFT", 0, -8)
    detail.stats:SetPoint("TOPRIGHT", detail.info, "BOTTOMRIGHT", 0, -8)
    detail.stats:SetJustifyH("LEFT")

    -- Section headings and entry rows are laid out inside this frame, top to bottom.
    detail.sections = CreateFrame("Frame", nil, detailContent)
    detail.sections:SetHeight(1)
    detail.sections:SetPoint("TOPLEFT", detail.stats, "BOTTOMLEFT", 0, -14)

    clearButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    clearButton:SetSize(120, 22)
    clearButton:SetText("Clear history")
    clearButton:SetScript("OnClick", function()
        StaticPopup_Show("MANAMASTER_CLEAR_HISTORY", #ns.char.fights)
    end)

    -- Selects every saved fight, so the details pane combines them all.
    selectAllButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    selectAllButton:SetSize(120, 22)
    -- Select all sits in the corner, with Clear history to its right.
    selectAllButton:SetPoint("BOTTOMLEFT", 12, 12)
    clearButton:SetPoint("LEFT", selectAllButton, "RIGHT", 8, 0)
    selectAllButton:SetText("Select all")
    selectAllButton:SetScript("OnClick", function()
        local fights = ns.char.fights
        wipe(selected)
        for _, fight in ipairs(fights) do selected[fight] = true end
        selectionAnchor = fights[#fights] -- Shift+click then extends from the newest fight
        animateBars = true
        ns.RefreshHistory()
    end)

    deleteButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    deleteButton:SetSize(150, 22) -- room for "Delete 12 segments"
    deleteButton:SetPoint("BOTTOMRIGHT", -28, 12) -- leaves the corner for the resize grip
    deleteButton:SetText("Delete segment")
    deleteButton:SetScript("OnClick", DeleteSelected)

    -- Resize grip in the bottom-right corner, like the chat windows'.
    local grip = CreateFrame("Button", nil, panel)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -6, 6)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        panel:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        panel:StopMovingOrSizing()
        ns.db.panelWidth, ns.db.panelHeight = math.floor(panel:GetWidth()), math.floor(panel:GetHeight())
    end)

    -- Re-lay out both panes whenever the size changes, including while dragging the grip.
    panel:SetScript("OnSizeChanged", function()
        UpdateLayout()
        ns.RefreshHistory()
    end)
    UpdateLayout()
end

function ns.ToggleHistory()
    if not panel then CreatePanel() end
    panel:SetShown(not panel:IsShown())
end
