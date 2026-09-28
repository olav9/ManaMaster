local _, ns = ...

local PANEL_WIDTH = 680
local PANEL_HEIGHT = 420
local LIST_WIDTH = 260
local DETAIL_LEFT = 12 + LIST_WIDTH + 38 -- leaves room for the list's scroll bar
local DETAIL_WIDTH = PANEL_WIDTH - DETAIL_LEFT - 34
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

local panel, listContent, detailContent, detail, clearButton, deleteButton
local rows, entryRows, sectionHeaders = {}, {}, {}
local selectedFight -- kept as a table reference so it survives new fights being added

local function ResultText(fight)
    if fight.success == true then
        return " |cff40ff40kill|r"
    elseif fight.success == false then
        return " |cffff4040wipe|r"
    end
    return ""
end

local function DeleteFight(target)
    local fights = ns.db.fights
    for i, fight in ipairs(fights) do
        if fight == target then
            table.remove(fights, i)
            if target == selectedFight then
                -- Select the next row down in the list (the next older fight), or the new last row.
                selectedFight = fights[i - 1] or fights[i]
            end
            break
        end
    end
    ns.RefreshHistory()
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
        DeleteFight(row.fight)
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
        selectedFight = self.fight
        ns.RefreshHistory()
    end)

    rows[i] = row
    return row
end

local function GetSectionHeader(i)
    if sectionHeaders[i] then return sectionHeaders[i] end

    local header = CreateFrame("Frame", nil, detail.sections)
    header:SetSize(DETAIL_WIDTH, SECTION_HEADER_HEIGHT)

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
    row:SetSize(DETAIL_WIDTH, SPELL_ROW_HEIGHT)

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
    -- Mana gained: measured recovery when mana was readable (all sources combined), otherwise the regen estimate.
    local gained = ns.SortedEntries(fight.gains)
    local gain = fight.recovered or fight.regen or 0
    if gain > 0 then
        table.insert(gained, 1, {
            name = fight.recovered and "All mana recovered" or "Passive regen",
            rank = not fight.recovered and "estimated" or nil,
            mana = gain,
            icon = GAIN_ICON,
        })
        table.sort(gained, function(a, b) return a.mana > b.mana end)
    end

    -- Wasted regen goes last, in grey, and isn't counted in the section total since it was never gained.
    -- Fights saved before wasted regen was tracked have no wastedFull.
    if fight.wastedFull then
        if fight.wastedFull >= 1 then
            table.insert(gained, { name = "Wasted at full mana", rank = "estimated", mana = fight.wastedFull,
                icon = WASTED_ICON, excluded = true })
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
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -y)
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
            row.bar:SetWidth(math.max(1, DETAIL_WIDTH * fraction))
            row.bar:Show()
            row:Show()
            y = y + SPELL_ROW_HEIGHT
        end

        if #entries == 0 then
            rowIndex = rowIndex + 1
            local row = GetEntryRow(rowIndex)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -y)
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

    detail.title:SetText(fight.name .. ResultText(fight))
    detail.info:SetText(string.format("%s  ·  %s  ·  %s",
        date("%m/%d %H:%M", fight.date), ns.FormatDuration(fight.duration), fight.zone or ""))

    if fight.recovered then
        local net = fight.recovered - fight.spent
        local lowestPct = fight.maxMana > 0 and (fight.lowestMana or 0) / fight.maxMana * 100 or 0
        detail.stats:SetText(string.format("Spent %s   Recovered %s   Net %s%s   Lowest %d%%",
            FormatNumber(fight.spent), FormatNumber(fight.recovered),
            net >= 0 and "+" or "-", FormatNumber(math.abs(net)), lowestPct))
    elseif fight.regen then
        -- Mana was hidden: spent is from spell costs and regen is estimated.
        local net = fight.regen - fight.spent
        detail.stats:SetText(string.format("Spent %s   Regen ~%s   Net %s%s\n|cff888888Spent from spell costs, regen estimated|r",
            FormatNumber(fight.spent), FormatNumber(fight.regen), net >= 0 and "+" or "-", FormatNumber(math.abs(net))))
    else
        detail.stats:SetText("Spent " .. FormatNumber(fight.spent) .. "  |cff888888(from spell costs)|r")
    end

    -- Starting mana drives the wasted-regen estimate, so show where it came from.
    if fight.startMana and fight.wastedFull then
        local startText = fight.startManaAssumed and "assumed full (not readable)"
            or string.format("%d%%", fight.startMana / fight.maxMana * 100 + 0.5)
        detail.stats:SetText(detail.stats:GetText() .. "\n|cff888888Start mana " .. startText .. "|r")
    end

    detail.sections:Show()
    local sectionsHeight = ShowSections(fight)

    local height = detail.title:GetStringHeight() + 4 + detail.info:GetStringHeight() + 8
        + detail.stats:GetStringHeight() + 14 + sectionsHeight
    detailContent:SetHeight(height)
end

function ns.RefreshHistory()
    if not panel or not panel:IsShown() then return end
    local fights = ns.db.fights

    -- Fall back to the newest fight if the selected one was pruned or history was reset.
    local found = false
    for _, fight in ipairs(fights) do
        if fight == selectedFight then
            found = true
            break
        end
    end
    if not found then
        selectedFight = fights[#fights]
    end

    local count = #fights
    for i = 1, count do
        local fight = fights[count - i + 1]
        local row = GetRow(i)
        row.fight = fight
        row.name:SetText(fight.name .. ResultText(fight))
        row.spent:SetText(ns.FormatNumber(fight.spent))
        row.info:SetText(string.format("%s  ·  %s  ·  %s",
            date("%m/%d %H:%M", fight.date), ns.FormatDuration(fight.duration), fight.zone or ""))
        row.selected:SetShown(fight == selectedFight)
        row:Show()
    end
    for i = count + 1, #rows do
        rows[i]:Hide()
    end
    listContent:SetHeight(math.max(1, count * (ROW_HEIGHT + ROW_GAP)))

    clearButton:SetEnabled(count > 0)
    deleteButton:SetEnabled(selectedFight ~= nil)
    ShowDetail(selectedFight)
end

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

local function CreatePanel()
    panel = CreateFrame("Frame", "ManaMasterHistoryFrame", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
    panel:SetPoint("CENTER")
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

    local listScroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", 12, -32)
    listScroll:SetPoint("BOTTOMLEFT", 12, BUTTON_AREA)
    listScroll:SetWidth(LIST_WIDTH)
    listContent = CreateFrame("Frame", nil, listScroll)
    listContent:SetSize(LIST_WIDTH, 1)
    listScroll:SetScrollChild(listContent)

    local detailScroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    detailScroll:SetPoint("TOPLEFT", DETAIL_LEFT, -32)
    detailScroll:SetPoint("BOTTOMLEFT", DETAIL_LEFT, BUTTON_AREA)
    detailScroll:SetWidth(DETAIL_WIDTH)
    detailContent = CreateFrame("Frame", nil, detailScroll)
    detailContent:SetSize(DETAIL_WIDTH, 1)
    detailScroll:SetScrollChild(detailContent)

    -- Always open on the newest fight, scrolled to the top, rather than whatever was viewed last time.
    panel:SetScript("OnShow", function()
        local fights = ns.db.fights
        selectedFight = fights[#fights]
        listScroll:SetVerticalScroll(0)
        detailScroll:SetVerticalScroll(0)
        ns.RefreshHistory()
    end)

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
    detail.sections:SetSize(DETAIL_WIDTH, 1)
    detail.sections:SetPoint("TOPLEFT", detail.stats, "BOTTOMLEFT", 0, -14)

    clearButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    clearButton:SetSize(120, 22)
    clearButton:SetPoint("BOTTOMLEFT", 12, 12)
    clearButton:SetText("Clear history")
    clearButton:SetScript("OnClick", function()
        StaticPopup_Show("MANAMASTER_CLEAR_HISTORY", #ns.db.fights)
    end)

    deleteButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    deleteButton:SetSize(120, 22)
    deleteButton:SetPoint("BOTTOMRIGHT", -12, 12)
    deleteButton:SetText("Delete segment")
    deleteButton:SetScript("OnClick", function()
        DeleteFight(selectedFight)
    end)
end

function ns.ToggleHistory()
    if not panel then CreatePanel() end
    panel:SetShown(not panel:IsShown())
end
