local addonName, ns = ...

-- Details! plugin: shows ManaMaster's "Mana spent" per spell inside a Details window. It's a "RAID" plugin
-- (like Details' own Tiny Threat): picked from the plugin menu (orange cogwheel), it takes over the window
-- and draws its own bars with the window's row style. It shows the running fight live, or the last fight
-- when out of combat. Only active when Details is loaded (an optional dependency in the TOCs).

local Details = _G.Details
if not (Details and Details.NewPluginObject and Details.InstallPlugin) then return end

local PLUGIN_NAME = "ManaMaster: Mana Spent"
local PLUGIN_ID = "DETAILS_PLUGIN_MANAMASTER" -- Details' absolute plugin name; also becomes a global
local FRAME_NAME = "Details_ManaMaster"
local PLUGIN_ICON = "Interface\\Icons\\INV_Elemental_Mote_Mana"
local UPDATE_INTERVAL = 0.5 -- seconds between refreshes while the plugin is shown
local BAR_R, BAR_G, BAR_B = 0.25, 0.66, 0.96 -- the history panel's Mana spent blue
local UNKNOWN_ICON = 134400
local ICON_COORDS = { 0.08, 0.92, 0.08, 0.92 }

local plugin = Details:NewPluginObject(FRAME_NAME)
local frame = plugin.Frame
plugin:SetPluginDescription("Mana spent per spell, from ManaMaster: the current fight live, or the last fight.")
plugin.Rows = {}
plugin.canShow = 0

local instance -- the Details window the plugin is shown in
-- The Details window whose segment was changed most recently (this one or another), so choosing a segment in
-- e.g. the main damage window also switches this plugin. nil means follow the plugin's own window.
local followInstance
-- True from the moment a fight starts until a segment is chosen or the fight ends: show the live fight, the
-- way Details jumps to the current segment when combat starts (even if this window wasn't on it).
local liveOverride = false

table.insert(ns.fightStartListeners, function()
    liveOverride = true
end)
local ticker

local MATCH_TOLERANCE = 2 -- seconds of slack when matching fight times to a Details segment

-- The running fight, or the last saved one: shown when the window's segment can't be matched.
local function DefaultFights()
    if ns.current then return { ns.current } end
    local fights = ns.char and ns.char.fights
    local last = fights and fights[#fights]
    return last and { last } or {}
end

-- "HH:MM:SS" to seconds since midnight.
local function ClockSeconds(text)
    local h, m, s = tostring(text or ""):match("^(%d+):(%d+):(%d+)")
    return h and (tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s))
end

-- Start and end of a fight on the given clock: "game" (GetTime) or "day" (seconds since midnight, a fallback
-- for fights saved before game times were stored). nil if the fight lacks that data.
local function FightSpan(fight, clock)
    if clock == "game" then
        if fight == ns.current then return fight.startClock, GetTime() end
        return fight.gameStart, fight.gameEnd
    end
    if not fight.date then return end
    local t = date("*t", fight.date)
    local start = t.hour * 3600 + t.min * 60 + t.sec
    return start, start + (fight.duration or 0)
end

local function Overlaps(aStart, aEnd, bStart, bEnd)
    return aStart <= bEnd + MATCH_TOLERANCE and aEnd >= bStart - MATCH_TOLERANCE
end

-- The ManaMaster fights that overlap the followed window's selected Details segment. Details' "Overall"
-- segment spans everything since its last reset, so it matches every fight in that time. Falls back to
-- DefaultFights when the segment has no usable times (e.g. Details built on Blizzard's meter).
local function FightsForSegment()
    if liveOverride then
        if ns.current then return { ns.current } end
        liveOverride = false -- the fight ended: go back to the followed segment (now the finished fight)
    end
    local inst = followInstance or instance or plugin:GetPluginInstance()
    local combat = inst and inst.GetShowingCombat and inst:GetShowingCombat()
    if not combat or type(combat.GetStartTime) ~= "function" then return DefaultFights() end

    -- The segment on both clocks. Game-clock times convert to time of day by their distance from now, so
    -- fights saved before game times were stored can still be compared.
    local gameStart, gameEnd = combat:GetStartTime(), combat:GetEndTime()
    if gameStart == 0 then gameStart = nil end

    -- "Overall" (segment -1) keeps growing and may have no end time, so it isn't an overlap: it's every fight
    -- since Details last reset it, up to now, including the running fight. Without a usable start time,
    -- every saved fight.
    local isOverall = (inst.GetSegment and inst:GetSegment() == -1)
        or (Details.tabela_overall and combat == Details.tabela_overall)
    if isOverall then
        local list = {}
        for _, fight in ipairs(ns.char and ns.char.fights or {}) do table.insert(list, fight) end
        if ns.current then table.insert(list, ns.current) end
        if not gameStart then return list end

        local now, t = GetTime(), date("*t")
        local dayStart = t.hour * 3600 + t.min * 60 + t.sec - (now - gameStart)
        local since = {}
        for _, fight in ipairs(list) do
            local fightStart = FightSpan(fight, "game")
            local after
            if fightStart then
                after = fightStart >= gameStart - MATCH_TOLERANCE
            else
                fightStart = FightSpan(fight, "day")
                after = fightStart and fightStart >= dayStart - MATCH_TOLERANCE
            end
            if after then table.insert(since, fight) end
        end
        return since
    end
    if gameStart and not gameEnd then
        -- The segment is still running: that's the current fight.
        if ns.current then return { ns.current } end
        gameEnd = GetTime()
    end
    local dayStart, dayEnd
    if gameStart then
        local now, t = GetTime(), date("*t")
        local dayNow = t.hour * 3600 + t.min * 60 + t.sec
        dayStart, dayEnd = dayNow - (now - gameStart), dayNow - (now - gameEnd)
    else
        local startText, endText = combat:GetDate()
        dayStart, dayEnd = ClockSeconds(startText), ClockSeconds(endText)
        if not dayStart then return DefaultFights() end
        dayEnd = dayEnd or dayStart
    end

    local matched = {}
    local candidates = {}
    for _, fight in ipairs(ns.char and ns.char.fights or {}) do table.insert(candidates, fight) end
    if ns.current then table.insert(candidates, ns.current) end
    for _, fight in ipairs(candidates) do
        local fightStart, fightEnd = FightSpan(fight, "game")
        local match
        if gameStart and fightStart then
            match = Overlaps(fightStart, fightEnd, gameStart, gameEnd)
        else
            fightStart, fightEnd = FightSpan(fight, "day")
            match = fightStart and Overlaps(fightStart, fightEnd, dayStart, dayEnd)
        end
        if match then table.insert(matched, fight) end
    end
    return matched
end

-- Per-spell spending of several fights added together, most mana first.
local function MergedSpells(fights)
    if #fights == 1 then return ns.SortedEntries(fights[1].spells) end
    local merged = {}
    for _, fight in ipairs(fights) do
        for key, data in pairs(fight.spells or {}) do
            local entry = merged[key]
            if not entry then
                entry = { casts = 0, mana = 0, spellID = data.spellID, name = data.name or key, rank = data.rank }
                merged[key] = entry
            end
            entry.casts = entry.casts + (data.casts or 0)
            entry.mana = entry.mana + (data.mana or 0)
        end
    end
    return ns.SortedEntries(merged)
end

local function NewRow(i)
    local row = Details.gump:NewBar(frame, nil, "DetailsManaMasterRow" .. i, nil, 300, 14)
    row.fontsize = 9.9
    row.fontface = "GameFontHighlightSmall"
    row.rowId = i
    row:Hide()
    plugin.Rows[i] = row
    return row
end

-- Matches a row to the window's bar style (font, texture, height) and stacks it.
local function LayoutRow(row)
    local inst = plugin:GetPluginInstance()
    if not inst then return end
    local info = inst.row_info
    local SharedMedia = LibStub and LibStub("LibSharedMedia-3.0", true)
    row.textsize = info.font_size
    row.textfont = SharedMedia and SharedMedia:Fetch("font", info.font_face, true) or info.font_face
    row.texture = info.texture
    row.shadow = info.textL_outline
    row.height = info.height
    local y = -((row.rowId - 1) * (info.height + 1))
    row:ClearAllPoints()
    row:SetPoint("topleft", frame, "topleft", 1, y)
    row:SetPoint("topright", frame, "topright", -1, y)
end

local function SizeChanged()
    local inst = plugin:GetPluginInstance()
    if not inst then return end
    local width, height = inst:GetSize()
    frame:SetSize(width, height)
    plugin.canShow = math.floor(height / (inst.row_info.height + 1))
    for i = #plugin.Rows + 1, plugin.canShow do NewRow(i) end
    for _, row in ipairs(plugin.Rows) do LayoutRow(row) end
end

-- Fills the rows with the spells of the fights matching the window's segment, most mana first; bars are
-- relative to the top spell. Reads the window's segment each time, so switching segments shows up at the
-- next refresh.
local function Update()
    local ok, fights = pcall(FightsForSegment)
    if not ok then fights = DefaultFights() end -- a Details version with different segment data
    local spells = MergedSpells(fights)
    local total = 0
    for _, spell in ipairs(spells) do total = total + spell.mana end
    local top = spells[1] and spells[1].mana or 0

    for i, row in ipairs(plugin.Rows) do
        local spell = spells[i]
        if i == 1 and not spell and plugin.canShow > 0 then
            -- Say why the window is empty rather than showing nothing.
            row:SetLeftText(#fights == 0 and "No ManaMaster fight in this segment" or "No mana spent")
            row:SetRightText("")
            row:SetValue(0)
            row:SetIcon(UNKNOWN_ICON, ICON_COORDS)
            row:Show()
        elseif spell and i <= plugin.canShow then
            local pct = total > 0 and spell.mana / total * 100 or 0
            row:SetLeftText(spell.name .. (spell.rank and (" (" .. spell.rank .. ")") or ""))
            row:SetRightText(string.format("%s (%.0f%%)", ns.FormatNumber(spell.mana), pct))
            row:SetValue(top > 0 and spell.mana / top * 100 or 0)
            row:SetIcon(C_Spell.GetSpellTexture(spell.spellID or spell.name) or UNKNOWN_ICON, ICON_COORDS)
            row:SetColor(BAR_R, BAR_G, BAR_B)
            row:Show()
        else
            row:Hide()
        end
    end
end

local function StartUpdates()
    if ticker then ticker:Cancel() end
    Update()
    ticker = C_Timer.NewTicker(UPDATE_INTERVAL, Update)
end

local function StopUpdates()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
    for _, row in ipairs(plugin.Rows) do row:Hide() end
end

function plugin:OnDetailsEvent(event, ...)
    if event == "SHOW" then
        instance = plugin:GetInstance(plugin.instance_id)
        followInstance = nil -- start by following this window's own segment
        SizeChanged()
        StartUpdates()
    elseif event == "DETAILS_INSTANCE_CHANGESEGMENT" then
        -- A segment was chosen in some Details window: follow that window from now on.
        local changedInstance = ...
        if changedInstance then
            followInstance = changedInstance ~= instance and changedInstance or nil
            liveOverride = false -- a segment the player chose wins over the live fight
            Update()
        end
    elseif event == "HIDE" then
        StopUpdates()
    elseif event == "DETAILS_INSTANCE_ENDRESIZE" or event == "DETAILS_INSTANCE_SIZECHANGED"
        or event == "DETAILS_OPTIONS_MODIFIED" then
        if ... == instance then
            SizeChanged()
            Update()
        end
    elseif event == "DETAILS_INSTANCE_STARTSTRETCH" then
        -- Stay on top of the window while it's being stretched, as Details' own plugins do.
        if instance then
            frame:SetFrameStrata("TOOLTIP")
            frame:SetFrameLevel(instance.baseframe:GetFrameLevel() + 1)
        end
    elseif event == "DETAILS_INSTANCE_ENDSTRETCH" then
        frame:SetFrameStrata("MEDIUM")
    end
end

-- Details sends the plugin frame's PLAYER_LOGIN to OnEvent as "ADDON_LOADED" with the frame name, once
-- Details itself is ready; that's when the plugin is installed.
function plugin:OnEvent(_, event, name)
    if event ~= "ADDON_LOADED" or name ~= FRAME_NAME then return end

    local version = C_AddOns and C_AddOns.GetAddOnMetadata(addonName, "Version") or "v0.1"
    local installed = Details:InstallPlugin("RAID", PLUGIN_NAME, PLUGIN_ICON, plugin, PLUGIN_ID, 1, "olsen", version)
    if type(installed) == "table" and installed.error then
        print(ns.PREFIX .. "Details plugin: " .. tostring(installed.error))
        return
    end

    for _, detailsEvent in ipairs({ "DETAILS_INSTANCE_ENDRESIZE", "DETAILS_INSTANCE_SIZECHANGED",
        "DETAILS_INSTANCE_STARTSTRETCH", "DETAILS_INSTANCE_ENDSTRETCH", "DETAILS_OPTIONS_MODIFIED",
        "DETAILS_INSTANCE_CHANGESEGMENT" }) do
        Details:RegisterEvent(plugin, detailsEvent)
    end
end
