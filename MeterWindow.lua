local _, ns = ...

-- Meter window: a compact, damage-meter-style bar window for the active fight (the running fight live in
-- combat, otherwise the last one). It shows one section of the history panel's details at a time (Mana
-- spent, Mana gained, Regen buff uptime, Mana saved, Mana drained, and Rage/Energy spent and gained for
-- characters with those), chosen by clicking the title. It's
-- movable (drag the title), resizable (corner grip), scalable (Ctrl + mouse wheel) and semi-transparent.
-- Its state is saved in ManaMasterDB.meter. Toggle with /mm meter or by right-clicking the minimap button.

local DEFAULT_WIDTH, DEFAULT_HEIGHT = 240, 150
local MIN_WIDTH, MIN_HEIGHT = 160, 60
local MAX_WIDTH, MAX_HEIGHT = 700, 700
local MIN_SCALE, MAX_SCALE, SCALE_STEP = 0.5, 2, 0.05
local TITLE_HEIGHT = 18
local ROW_HEIGHT = 20 -- same as the history panel's detail rows
local ROW_FONT = "GameFontHighlight"
local ROW_GAP = 1
local ICON_SIZE = ROW_HEIGHT
local CONTENT_INSET = 2 -- the rows area's inset from the window's edges
local BAR_TEXT_PAD = 3 -- row text starts this far inside the bar
-- Where row text starts, from the window's left edge; the title's section selector lines up with it.
local TEXT_LEFT = CONTENT_INSET + ICON_SIZE + 1 + BAR_TEXT_PAD
local CHILD_INDENT = 10
local BACKGROUND_ALPHA = 0.7
local UPDATE_INTERVAL = 0.5
local BAR_ANIM_DURATION = 0.3
local BAR_TEXTURE = "Interface\\Buttons\\WHITE8x8" -- flat colour, no gradient
local UNKNOWN_ICON = 134400
local ADDON_ICON = "Interface\\Icons\\INV_Elemental_Mote_Mana" -- same as the minimap button and the TOCs
local ICON_COORDS = { 0.08, 0.92, 0.08, 0.92 }

-- The sections per power, in the history panel's order; titles match BuildSections in HistoryPanel.lua.
local POWER_SECTIONS = {
    { power = "MANA", titles = { "Mana spent", "Mana gained", "Regen buff uptime", "Mana saved", "Mana drained" } },
    { power = "RAGE", titles = { "Rage spent", "Rage generated" } },
    { power = "ENERGY", titles = { "Energy spent", "Energy gained" } },
}
local SECTION_POWER = {} -- section title -> power token
for _, group in ipairs(POWER_SECTIONS) do
    for _, title in ipairs(group.titles) do SECTION_POWER[title] = group.power end
end

-- The sections this character can use: all of them for druids, otherwise the main power's and mana's
-- (if the character has mana), the main power first.
local function AvailableSections()
    local _, class = UnitClass("player")
    local _, mainPower = UnitPowerType("player")
    if not ns.IsReadable(mainPower) then mainPower = nil end
    local maxMana = UnitPowerMax("player", Enum.PowerType.Mana)
    local hasMana = ns.IsReadable(maxMana) and maxMana > 0
    local list = {}
    local function AddPower(token)
        for _, group in ipairs(POWER_SECTIONS) do
            if group.power == token then
                for _, title in ipairs(group.titles) do table.insert(list, title) end
            end
        end
    end
    if class == "DRUID" then
        AddPower("MANA"); AddPower("RAGE"); AddPower("ENERGY")
        return list
    end
    if mainPower == "RAGE" or mainPower == "ENERGY" then AddPower(mainPower) end
    if hasMana or #list == 0 then AddPower("MANA") end
    return list
end

-- The chosen section, or the first available one if the choice doesn't apply to this character.
local function CurrentSection()
    local chosen = ns.db.meter.section
    local available = AvailableSections()
    for _, title in ipairs(available) do
        if title == chosen then return chosen end
    end
    return available[1]
end
local MAX_MENU_ITEMS = 9

local frame, titleButton, titleText, totalText, menu, content
local rows = {}
local ticker

local function Settings()
    return ns.db.meter
end

-- The running fight (as a live view) or the last saved fight.
local function ActiveFight()
    local live = ns.LiveFightView()
    if live then return live end
    local fights = ns.char and ns.char.fights
    return fights and fights[#fights]
end

------------------------------------------------------------------------------------------------------------
-- Bar animation: rows slide from their current value to the new one; new rows grow from zero.

local animatingRows = {}
local animFrame = CreateFrame("Frame")
animFrame:Hide()
animFrame:SetScript("OnUpdate", function()
    local now = GetTime()
    for row in pairs(animatingRows) do
        local t = (now - row.animStart) / BAR_ANIM_DURATION
        if t >= 1 then
            row.value = row.animTo
            animatingRows[row] = nil
        else
            row.value = row.animFrom + (row.animTo - row.animFrom) * (1 - (1 - t) ^ 3) -- ease-out
        end
        row.bar:SetValue(row.value)
    end
    if not next(animatingRows) then animFrame:Hide() end
end)

local function SetRowValue(row, value, wasShown)
    local from = wasShown and (row.value or 0) or 0
    if math.abs(from - value) < 0.001 then
        animatingRows[row] = nil
        row.value = value
        row.bar:SetValue(value)
        return
    end
    row.animFrom, row.animTo, row.animStart = from, value, GetTime()
    animatingRows[row] = true
    animFrame:Show()
end

------------------------------------------------------------------------------------------------------------
-- Rows

local function ShowRowTooltip(row)
    local entry = row.entry
    if not entry then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if type(entry.spellID) == "number" and pcall(GameTooltip.SetSpellByID, GameTooltip, entry.spellID) then
        GameTooltip:Show()
        return
    end
    GameTooltip:ClearLines()
    GameTooltip:AddLine(entry.name or "")
    if entry.rank then GameTooltip:AddLine(entry.rank, 1, 1, 1, true) end
    GameTooltip:Show()
end

local function GetRow(i)
    if rows[i] then return rows[i] end
    local row = CreateFrame("Frame", nil, content)
    row:SetHeight(ROW_HEIGHT)
    row:EnableMouse(true)
    row:SetScript("OnEnter", ShowRowTooltip)
    row:SetScript("OnLeave", GameTooltip_Hide)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON_SIZE, ICON_SIZE)
    row.icon:SetTexCoord(unpack(ICON_COORDS))

    row.bar = CreateFrame("StatusBar", nil, row)
    row.bar:SetStatusBarTexture(BAR_TEXTURE)
    row.bar:SetMinMaxValues(0, 1)
    row.bar:SetPoint("TOPRIGHT")
    row.bar:SetPoint("BOTTOMRIGHT")

    row.barBackground = row.bar:CreateTexture(nil, "BACKGROUND")
    row.barBackground:SetAllPoints()
    row.barBackground:SetColorTexture(1, 1, 1, 0.06)

    row.rightText = row.bar:CreateFontString(nil, "OVERLAY", ROW_FONT)
    row.rightText:SetPoint("RIGHT", -3, 0)
    row.rightText:SetJustifyH("RIGHT")

    row.leftText = row.bar:CreateFontString(nil, "OVERLAY", ROW_FONT)
    row.leftText:SetPoint("LEFT", BAR_TEXT_PAD, 0)
    row.leftText:SetPoint("RIGHT", row.rightText, "LEFT", -4, 0)
    row.leftText:SetJustifyH("LEFT")
    row.leftText:SetWordWrap(false)

    rows[i] = row
    return row
end

-- Positions a row, indenting child rows (e.g. spells under a proc in Mana saved).
-- Row height and row-to-row step in whole screen pixels at the window's current scale. The window is
-- scalable (and the UI scale is rarely 1), so 20 + 1 units don't land on whole pixels; rounding each row
-- separately made the 1-unit gaps show as 0, 1 or 2 pixels. Snapping both to pixels keeps every gap equal.
local function RowMetrics()
    local height, gap = ROW_HEIGHT, ROW_GAP
    if PixelUtil and PixelUtil.GetNearestPixelSize then
        local scale = content:GetEffectiveScale()
        height = PixelUtil.GetNearestPixelSize(ROW_HEIGHT, scale, 1)
        gap = PixelUtil.GetNearestPixelSize(ROW_GAP, scale, 1) -- at least one pixel
    end
    return height, height + gap
end

local function PlaceRow(row, i, indent)
    local height, step = RowMetrics()
    local y = -((i - 1) * step)
    row:SetHeight(height)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
    row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, y)
    row.icon:SetSize(height, height)
    row.icon:ClearAllPoints()
    row.icon:SetPoint("LEFT", indent, 0)
    row.bar:SetPoint("LEFT", row.icon, "RIGHT", 1, 0)
end

------------------------------------------------------------------------------------------------------------
-- Update

local function FindSection(sections, title)
    for _, section in ipairs(sections) do
        if section.title == title then return section end
    end
end

local function ShowMessage(text)
    local row = GetRow(1)
    PlaceRow(row, 1, 0)
    row.entry = nil
    row.icon:SetTexture(UNKNOWN_ICON)
    row.leftText:SetText("|cff999999" .. text .. "|r")
    row.rightText:SetText("")
    animatingRows[row] = nil
    row.value = 0
    row.bar:SetValue(0)
    row:Show()
    for i = 2, #rows do rows[i]:Hide() end
end

local function Update()
    if not frame or not frame:IsShown() then return end
    local title = CurrentSection()
    titleText:SetText(title)
    totalText:SetText("")

    local fight = ActiveFight()
    if not fight then
        ShowMessage("No fights recorded yet")
        return
    end
    local section = FindSection(ns.BuildSections(fight, SECTION_POWER[title]), title)
    if not section then
        ShowMessage("Not tracked for this fight")
        return
    end

    local entries = section.entries
    local total, counted, top = 0, 0, 0
    for _, entry in ipairs(entries) do
        if not section.isUptime then
            top = math.max(top, entry.mana)
            if not entry.excluded and not entry.child then
                total = total + entry.mana
                counted = counted + 1
            end
        end
    end
    if not section.isUptime then
        totalText:SetText((total > 0 and section.sign or "") .. ns.FormatNumber(total))
    end
    if #entries == 0 then
        ShowMessage(section.emptyText or "None recorded")
        return
    end

    local _, step = RowMetrics()
    local capacity = math.max(1, math.floor(content:GetHeight() / step))
    for i = 1, math.max(#rows, math.min(#entries, capacity)) do
        local entry = i <= capacity and entries[i]
        local row = (entry or rows[i]) and GetRow(i)
        if row and entry then
            local wasShown = row:IsShown()
            PlaceRow(row, i, entry.child and CHILD_INDENT or 0)
            row.entry = entry
            row.icon:SetTexture(entry.icon or C_Spell.GetSpellTexture(entry.spellID or entry.name) or UNKNOWN_ICON)
            row.icon:SetDesaturated(entry.excluded == true)
            row.leftText:SetText(entry.name .. (entry.rank and ("  |cffaaaaaa" .. entry.rank .. "|r") or ""))

            local value, r, g, b, a
            if section.isUptime then
                row.rightText:SetText(entry.valueText)
                value = entry.fraction
            else
                local share = (counted > 1 and not entry.excluded and not entry.child)
                    and string.format(" (%d%%)", entry.mana / total * 100) or ""
                local prefix = entry.excluded and "~" or section.sign
                row.rightText:SetText(prefix .. ns.FormatNumber(entry.mana) .. share)
                value = top > 0 and entry.mana / top or 0
            end
            if entry.excluded then
                r, g, b, a = 0.6, 0.6, 0.6, 0.6
            else
                r, g, b, a = section.r, section.g, section.b, entry.child and 0.45 or 0.7
            end
            row.bar:SetStatusBarColor(r, g, b, a)
            SetRowValue(row, value, wasShown)
            row:Show()
        elseif row then
            row:Hide()
        end
    end
end

------------------------------------------------------------------------------------------------------------
-- Section menu

local function ToggleMenu()
    if menu:IsShown() then
        menu:Hide()
        return
    end
    -- The menu lists only the sections for this character's powers.
    local available, current = AvailableSections(), CurrentSection()
    for i, button in ipairs(menu.buttons) do
        local section = available[i]
        button.section = section
        if section then
            button.text:SetText((section == current and "|cffffd100" or "") .. section)
            button:Show()
        else
            button:Hide()
        end
    end
    menu:SetHeight(math.min(#available, #menu.buttons) * 18 + 4)
    menu:Show()
end

local function CreateMenu()
    menu = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    menu:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1 })
    menu:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    menu:SetBackdropBorderColor(0, 0, 0, 1)
    menu:SetPoint("TOPLEFT", titleButton, "BOTTOMLEFT", 0, -1)
    menu:SetFrameStrata("DIALOG")
    menu:SetSize(140, 4)
    menu:Hide()
    menu.buttons = {}
    for i = 1, MAX_MENU_ITEMS do
        local button = CreateFrame("Button", nil, menu)
        button:SetSize(136, 18)
        button:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 18)
        button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.text:SetPoint("LEFT", 6, 0)
        button:SetScript("OnClick", function(self)
            Settings().section = self.section
            menu:Hide()
            wipe(animatingRows)
            for _, row in ipairs(rows) do row:Hide() end -- new section: bars grow in fresh
            Update()
        end)
        menu.buttons[i] = button
    end
end

------------------------------------------------------------------------------------------------------------
-- Window

local function SavePosition()
    local point, _, relativePoint, x, y = frame:GetPoint()
    local settings = Settings()
    settings.point, settings.relativePoint, settings.x, settings.y = point, relativePoint, x, y
end

local function CreateWindow()
    local settings = Settings()
    frame = CreateFrame("Frame", "ManaMasterMeterFrame", UIParent, "BackdropTemplate")
    frame:SetSize(settings.width or DEFAULT_WIDTH, settings.height or DEFAULT_HEIGHT)
    frame:SetScale(settings.scale or 1)
    frame:SetPoint(settings.point or "CENTER", UIParent, settings.relativePoint or "CENTER",
        settings.x or 300, settings.y or 0)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)
    else
        frame:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
        frame:SetMaxResize(MAX_WIDTH, MAX_HEIGHT)
    end
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1 })
    frame:SetBackdropColor(0, 0, 0, BACKGROUND_ALPHA)
    frame:SetBackdropBorderColor(0, 0, 0, 0.8)
    frame:Hide()

    -- Ctrl + mouse wheel scales the whole window, text included.
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        if not IsControlKeyDown() then return end
        local scale = math.min(MAX_SCALE, math.max(MIN_SCALE, frame:GetScale() + delta * SCALE_STEP))
        frame:SetScale(scale)
        Settings().scale = scale
    end)

    -- Title bar: drag to move; click the section name to choose a section.
    local titleBar = CreateFrame("Frame", nil, frame)
    titleBar:SetPoint("TOPLEFT")
    titleBar:SetPoint("TOPRIGHT")
    titleBar:SetHeight(TITLE_HEIGHT)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        SavePosition()
    end)
    local titleBackground = titleBar:CreateTexture(nil, "BACKGROUND")
    titleBackground:SetAllPoints()
    titleBackground:SetColorTexture(0, 0, 0, 0.6)

    local close = CreateFrame("Button", nil, titleBar)
    close:SetSize(12, 12)
    close:SetPoint("RIGHT", -3, 0)
    close:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    close:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")
    close:SetScript("OnClick", function() ns.ToggleMeter(false) end)

    totalText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    totalText:SetPoint("RIGHT", close, "LEFT", -6, 0)

    -- The addon's icon (Mote of Mana, as on the minimap button and in the AddOns list) before the selector.
    local addonIcon = titleBar:CreateTexture(nil, "ARTWORK")
    -- Centred over the column of row icons.
    local addonIconSize = TITLE_HEIGHT - 4
    addonIcon:SetSize(addonIconSize, addonIconSize)
    addonIcon:SetPoint("LEFT", CONTENT_INSET + (ICON_SIZE - addonIconSize) / 2, 0)
    addonIcon:SetTexture(ADDON_ICON)
    addonIcon:SetTexCoord(unpack(ICON_COORDS))

    -- The section selector starts where the rows' text does.
    titleButton = CreateFrame("Button", nil, titleBar)
    titleButton:SetPoint("LEFT", TEXT_LEFT, 0)
    titleButton:SetHeight(TITLE_HEIGHT)
    titleText = titleButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    titleText:SetPoint("LEFT")
    local arrow = titleButton:CreateTexture(nil, "OVERLAY")
    arrow:SetSize(10, 10)
    arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
    arrow:SetRotation(-math.pi / 2) -- point down: "click for a menu"
    arrow:SetPoint("LEFT", titleText, "RIGHT", 3, 0)
    titleButton:SetScript("OnClick", ToggleMenu)
    titleButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Click to choose a section")
        GameTooltip:AddLine("Drag the title bar to move, the corner to resize, Ctrl + mouse wheel to scale",
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    titleButton:SetScript("OnLeave", GameTooltip_Hide)
    -- Size the title button to its text so dragging the rest of the bar still moves the window.
    hooksecurefunc(titleText, "SetText", function()
        titleButton:SetWidth(titleText:GetStringWidth() + 16)
    end)

    content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", CONTENT_INSET, -(TITLE_HEIGHT + CONTENT_INSET))
    content:SetPoint("BOTTOMRIGHT", -CONTENT_INSET, CONTENT_INSET)
    content:SetClipsChildren(true)

    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(12, 12)
    grip:SetPoint("BOTTOMRIGHT", -1, 1)
    grip:SetFrameLevel(content:GetFrameLevel() + 5)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        Settings().width, Settings().height = math.floor(frame:GetWidth()), math.floor(frame:GetHeight())
        SavePosition()
    end)
    frame:SetScript("OnSizeChanged", Update)

    CreateMenu()
end

-- Shows or hides the meter window (show: true/false, or nil to toggle). Remembered across sessions.
function ns.ToggleMeter(show)
    if not frame then CreateWindow() end
    if show == nil then show = not frame:IsShown() end
    Settings().shown = show
    if show then
        frame:Show()
        Update()
        if not ticker then ticker = C_Timer.NewTicker(UPDATE_INTERVAL, Update) end
    else
        frame:Hide()
        menu:Hide()
        if ticker then
            ticker:Cancel()
            ticker = nil
        end
    end
end

-- Called from OnAddonLoaded once ManaMasterDB exists: sets defaults and reopens the window if it was open.
function ns.InitMeter()
    ns.db.meter = ns.db.meter or {}
    local settings = ns.db.meter
    -- No stored default: CurrentSection falls back to the character's main power's spent section.
    if settings.shown then ns.ToggleMeter(true) end
end
