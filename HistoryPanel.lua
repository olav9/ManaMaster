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
local DELETE_SIZE = 14
local SPELL_ROW_HEIGHT = 20
local SPELL_ICON_SIZE = 16
local UNKNOWN_ICON = 134400 -- question mark
local SPELL_NAME_LEFT = 4 + SPELL_ICON_SIZE + 6 -- name starts after the icon
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
local BUFF_R, BUFF_G, BUFF_B = 0.95, 0.8, 0.3 -- gold for buff uptime, on its own 0-100% scale
local BUFF_HEX = "f2cc4d"
local SECTION_HEADER_HEIGHT = 18
local SECTION_GAP = 12 -- space above each section after the first

local BUTTON_AREA = 40 -- space under the scroll areas for the Clear/Delete buttons

local panel, listScroll, listContent, detailScroll, detailContent, detail, clearButton, deleteButton
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
    for i, f in ipairs(ns.db.fights) do
        if f == fight then return i end
    end
end

-- Selected fights in history order (oldest first).
local function SelectedFights()
    local list = {}
    for _, fight in ipairs(ns.db.fights) do
        if selected[fight] then table.insert(list, fight) end
    end
    return list
end

local function SelectOnly(fight)
    wipe(selected)
    if fight then selected[fight] = true end
    selectionAnchor = fight
end

local function OnRowClick(fight)
    if IsShiftKeyDown() and selectionAnchor and IndexOf(selectionAnchor) then
        local from, to = IndexOf(selectionAnchor), IndexOf(fight)
        if from > to then from, to = to, from end
        wipe(selected)
        for i = from, to do selected[ns.db.fights[i]] = true end
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
    local fights = ns.db.fights
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
            entry = { casts = 0, mana = 0, spellID = data.spellID, name = data.name or key, rank = data.rank }
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
        spells = {}, gains = {}, drains = {}, buffs = {},
        maxMana = 100, -- lowestMana below is a percentage, so the panel's lowest % works unchanged
    }
    local all = { recovered = true, regen = true, wastedFull = true, wastedBlocked = true,
        gainsMeasured = true, buffs = true, lowestMana = true }
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
        MergeEntries(combined.spells, fight.spells)
        MergeEntries(combined.gains, fight.gains)
        MergeEntries(combined.drains, fight.drains)
        for name, data in pairs(fight.buffs or {}) do
            local entry = combined.buffs[name]
            if not entry then
                entry = { uptime = 0, spellID = data.spellID, icon = data.icon }
                combined.buffs[name] = entry
            end
            entry.uptime = entry.uptime + (data.uptime or 0)
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
    combined.zone = table.concat(zoneList, ", ")
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

    row.delete = CreateFrame("Button", nil, row)
    row.delete:SetSize(DELETE_SIZE, DELETE_SIZE)
    row.delete:SetPoint("RIGHT", -ROW_PAD_X, 0)
    row.delete:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    row.delete:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")
    row.delete:SetAlpha(0.5)
    row.delete:SetScript("OnEnter", function(self)
        self:SetAlpha(1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Delete segment")
        GameTooltip:Show()
    end)
    row.delete:SetScript("OnLeave", function(self)
        self:SetAlpha(0.5)
        GameTooltip:Hide()
    end)
    row.delete:SetScript("OnClick", function()
        DeleteFights({ row.fight })
    end)

    row.spent = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local textRight = ROW_PAD_X + DELETE_SIZE + 10 -- keeps text clear of the delete button
    row.spent:SetPoint("TOPRIGHT", -textRight, -ROW_PAD_Y)
    row.spent:SetJustifyH("RIGHT")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("TOPLEFT", ROW_PAD_X, -ROW_PAD_Y)
    row.name:SetPoint("RIGHT", row.spent, "LEFT", -10, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.info:SetPoint("BOTTOMLEFT", ROW_PAD_X, ROW_PAD_Y)
    row.info:SetPoint("BOTTOMRIGHT", -textRight, ROW_PAD_Y)
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

local function GetEntryRow(i)
    if entryRows[i] then return entryRows[i] end

    local row = CreateFrame("Frame", nil, detail.sections)
    row:SetHeight(SPELL_ROW_HEIGHT) -- width follows the panel, set in ShowSections

    -- Bar length shows the entry's mana relative to the largest entry in any section.
    row.bar = row:CreateTexture(nil, "BACKGROUND")
    row.bar:SetPoint("TOPLEFT")
    row.bar:SetPoint("BOTTOMLEFT")

    row.mana = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.mana:SetPoint("RIGHT", -4, 0)
    row.mana:SetWidth(90)
    row.mana:SetJustifyH("RIGHT")

    row.casts = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.casts:SetPoint("RIGHT", row.mana, "LEFT", -4, 0)
    row.casts:SetWidth(40)
    row.casts:SetJustifyH("RIGHT")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(SPELL_ICON_SIZE, SPELL_ICON_SIZE)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- trim the icon's built-in border

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", SPELL_NAME_LEFT, 0)
    row.name:SetPoint("RIGHT", row.casts, "LEFT", -4, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    entryRows[i] = row
    return row
end

-- The sections for a fight: spent, gained and drained (sorted by mana), then regen buff uptime.
local function BuildSections(fight)
    -- Mana gained comes in three flavours:
    --  * gainsMeasured (TBC, combat log): each energize source is exact; passive regen is what the measured
    --    recovery has left over after those.
    --  * recovered only (mana readable, no per-source data): one "All mana recovered" row.
    --  * otherwise (WoW Forever): potions and passive regen are estimates.
    local gained
    if fight.gainsMeasured then
        gained = ns.SortedEntries(fight.gains)
        local regen = (fight.recovered or 0) - ns.RestoredTotal(fight)
        if regen >= 1 then
            table.insert(gained, { name = "Passive regen", rank = "recovered mana not from a logged source",
                mana = regen, icon = GAIN_ICON })
        end
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
        if (fight.regen or 0) > 0 then
            table.insert(gained, { name = "Passive regen", rank = "estimated", mana = fight.regen, icon = GAIN_ICON })
        end
    end
    table.sort(gained, function(a, b) return a.mana > b.mana end)

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

    local sections = {
        { title = "Mana spent", hex = SPEND_HEX, r = ACCENT_R, g = ACCENT_G, b = ACCENT_B, sign = "",
          countLabel = "Casts", valueLabel = "Mana", entries = ns.SortedEntries(fight.spells) },
        { title = "Mana gained", hex = GAIN_HEX, r = GAIN_R, g = GAIN_G, b = GAIN_B, sign = "+",
          countLabel = "Count", valueLabel = "Mana", entries = gained },
        { title = "Mana drained", hex = DRAIN_HEX, r = DRAIN_R, g = DRAIN_G, b = DRAIN_B, sign = "-",
          countLabel = "Count", valueLabel = "Mana", entries = ns.SortedEntries(fight.drains) },
    }

    -- Fights saved before buff tracking have no buffs table; skip the section for those.
    if fight.buffs then
        local buffs = {}
        for name, data in pairs(fight.buffs) do
            local fraction = fight.duration > 0 and math.min(1, data.uptime / fight.duration) or 0
            table.insert(buffs, {
                name = name,
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

    return sections
end

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
local function ShowSections(fight)
    local FormatNumber = ns.FormatNumber
    local sections = BuildSections(fight)

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
                if not entry.excluded then total = total + entry.mana end
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
            if not entry.excluded then counted = counted + 1 end
        end
        for _, entry in ipairs(entries) do
            rowIndex = rowIndex + 1
            local row = GetEntryRow(rowIndex)
            local wasVisible = row:IsShown() and row.bar:IsShown()
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -y)
            row:SetWidth(detailWidth)
            row.name:SetText(entry.name .. (entry.rank and ("  |cff999999" .. entry.rank .. "|r") or ""))
            -- Fights saved before spell IDs were stored only have the name, which finds the icon for known spells.
            row.icon:SetTexture(entry.icon or C_Spell.GetSpellTexture(entry.spellID or entry.name) or UNKNOWN_ICON)
            row.icon:SetDesaturated(entry.excluded == true)
            row.icon:Show()
            row.casts:SetText(entry.casts or "")
            local fraction
            if section.isUptime then
                row.mana:SetText(entry.valueText)
                fraction = entry.fraction
            elseif entry.excluded then
                row.mana:SetText("|cff" .. WASTED_HEX .. "~" .. FormatNumber(entry.mana) .. "|r")
                fraction = entry.mana / top
            else
                -- Share of the section total, only when there's more than one counted entry to compare.
                local share = counted > 1 and string.format(" (%d%%)", entry.mana / total * 100) or ""
                row.mana:SetText(section.sign .. FormatNumber(entry.mana) .. share)
                fraction = entry.mana / top
            end
            if entry.excluded then
                row.bar:SetColorTexture(WASTED_R, WASTED_G, WASTED_B, 0.3)
            else
                row.bar:SetColorTexture(section.r, section.g, section.b, 0.3)
            end
            SetBarWidth(row, math.max(1, detailWidth * fraction), wasVisible)
            row.bar:Show()
            row:Show()
            y = y + SPELL_ROW_HEIGHT
        end

        if #entries == 0 then
            rowIndex = rowIndex + 1
            local row = GetEntryRow(rowIndex)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -y)
            row:SetWidth(detailWidth)
            row.name:SetText("|cff888888None recorded|r")
            row.icon:Hide()
            row.casts:SetText("")
            row.mana:SetText("")
            row.bar:Hide()
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
        detail.title:SetText(fight.name .. ResultText(fight))
        detail.info:SetText(string.format("%s  ·  %s  ·  %s",
            date("%m/%d %H:%M", fight.date), ns.FormatDuration(fight.duration), fight.zone or ""))
    end

    if fight.recovered then
        local net = fight.recovered - fight.spent
        local lowestPct = fight.maxMana > 0 and (fight.lowestMana or 0) / fight.maxMana * 100 or 0
        detail.stats:SetText(string.format("Spent %s   Recovered %s   Net %s%s   Lowest %d%%",
            FormatNumber(fight.spent), FormatNumber(fight.recovered),
            net >= 0 and "+" or "-", FormatNumber(math.abs(net)), lowestPct))
    elseif fight.regen then
        -- Mana was hidden: spent is from spell costs, regen and potions are estimated.
        local restored = ns.RestoredTotal(fight)
        local net = fight.regen + restored - fight.spent
        local restoredText = restored > 0 and ("   Potions ~" .. FormatNumber(restored)) or ""
        detail.stats:SetText(string.format("Spent %s   Regen ~%s%s   Net %s%s\n|cff888888Spent from spell costs, regen and potions estimated|r",
            FormatNumber(fight.spent), FormatNumber(fight.regen), restoredText,
            net >= 0 and "+" or "-", FormatNumber(math.abs(net))))
    else
        detail.stats:SetText("Spent " .. FormatNumber(fight.spent) .. "  |cff888888(from spell costs)|r")
    end

    -- Starting mana drives the wasted-regen estimate, so show where it came from.
    if fight.startMana and fight.wastedFull then
        local startText = fight.startManaAssumed and "assumed full (not confirmed since login)"
            or string.format("~%d%% (estimated)", fight.startMana / fight.maxMana * 100 + 0.5)
        detail.stats:SetText(detail.stats:GetText() .. "\n|cff888888Start mana " .. startText .. "|r")
    end

    detail.sections:Show()
    local sectionsHeight = ShowSections(fight)

    local height = detail.title:GetStringHeight() + 4 + detail.info:GetStringHeight() + 8
        + detail.stats:GetStringHeight() + 14 + sectionsHeight
    detailContent:SetHeight(height)
end

-- Selects the newest fight and scrolls both panes to the top. Used when the panel opens, and when a
-- fight ends while it's open so the new segment is shown straight away. Does nothing while it's closed.
function ns.ShowNewestFight()
    if not panel or not panel:IsShown() then return end
    local fights = ns.db.fights
    SelectOnly(fights[#fights])
    animateBars = true
    listScroll:SetVerticalScroll(0)
    detailScroll:SetVerticalScroll(0)
    ns.RefreshHistory()
end

function ns.RefreshHistory()
    if not panel or not panel:IsShown() then return end
    local fights = ns.db.fights

    -- Drop selected fights that were pruned or deleted; fall back to the newest if nothing is left.
    local present = {}
    for _, fight in ipairs(fights) do present[fight] = true end
    for fight in pairs(selected) do
        if not present[fight] then selected[fight] = nil end
    end
    if selectionAnchor and not present[selectionAnchor] then selectionAnchor = nil end
    if not next(selected) then
        SelectOnly(fights[#fights])
    end
    local selectedList = SelectedFights()

    local count = #fights
    for i = 1, count do
        local fight = fights[count - i + 1]
        local row = GetRow(i)
        row.fight = fight
        row.name:SetText(fight.name .. ResultText(fight))
        row.spent:SetText(ns.FormatNumber(fight.spent))
        row.info:SetText(string.format("%s  ·  %s  ·  %s",
            date("%m/%d %H:%M", fight.date), ns.FormatDuration(fight.duration), fight.zone or ""))
        row.selected:SetShown(selected[fight] == true)
        row:Show()
    end
    for i = count + 1, #rows do
        rows[i]:Hide()
    end
    listContent:SetHeight(math.max(1, count * (ROW_HEIGHT + ROW_GAP)))

    clearButton:SetEnabled(count > 0)
    deleteButton:SetEnabled(#selectedList > 0)
    deleteButton:SetText(#selectedList > 1 and ("Delete " .. #selectedList .. " segments") or "Delete segment")
    if #selectedList > 1 then
        ShowDetail(CombineFights(selectedList))
    else
        ShowDetail(selectedList[1])
    end
    animateBars = false -- only the refresh right after a selection change animates
end

-- Deletes the selected fights; asks first when there's more than one.
local function DeleteSelected()
    local list = SelectedFights()
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
    OnAccept = function() DeleteFights(SelectedFights()) end,
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
    panel.TitleText:SetText("ManaMaster - Fight History")
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
    detail.title:SetPoint("TOPRIGHT")
    detail.title:SetJustifyH("LEFT")

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
    clearButton:SetPoint("BOTTOMLEFT", 12, 12)
    clearButton:SetText("Clear history")
    clearButton:SetScript("OnClick", function()
        StaticPopup_Show("MANAMASTER_CLEAR_HISTORY", #ns.db.fights)
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
