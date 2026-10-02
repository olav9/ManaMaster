local addonName, ns = ...

-- Details! plugin: shows ManaMaster's resource spent per spell inside a Details window: mana, rage and energy,
-- each power in its own colour (a druid's fights can have all three). It's a "RAID" plugin
-- (like Details' own Tiny Threat): picked from the plugin menu (orange cogwheel), it takes over the window
-- and draws its own bars with the window's row style. It shows the running fight live, or the last fight
-- when out of combat. Only active when Details is loaded (an optional dependency in the TOCs).

local Details = _G.Details
if not (Details and Details.NewPluginObject and Details.InstallPlugin) then return end

local PLUGIN_NAME = "ManaMaster: Resource Spent"
local PLUGIN_ID = "DETAILS_PLUGIN_MANAMASTER" -- Details' absolute plugin name; also becomes a global
local FRAME_NAME = "Details_ManaMaster"
local PLUGIN_ICON = "Interface\\Icons\\INV_Elemental_Mote_Mana"
local UPDATE_INTERVAL = 0.5 -- seconds between refreshes while the plugin is shown
local UNKNOWN_ICON = 134400
local ICON_COORDS = { 0.08, 0.92, 0.08, 0.92 }

local plugin = Details:NewPluginObject(FRAME_NAME)
local frame = plugin.Frame
plugin:SetPluginDescription("Mana, rage or energy spent per ability, from ManaMaster: the current fight live, or the last fight.")
plugin.Rows = {}
plugin.canShow = 0

local instance -- the Details window the plugin is shown in
-- The Details window whose segment was changed most recently (this one or another), so choosing a segment in
-- e.g. the main damage window also switches this plugin. nil means follow the plugin's own window.
-- Remembered across reloads in ManaMasterDB.detailsFollowWindow (a window id, or false for the plugin's own).
local followInstance

-- The window to follow when the plugin is shown: the one remembered from last time, else the first enabled
-- Details window showing normal data (not a plugin, mode 4), else the plugin's own (nil). Without this, a
-- reload followed the plugin's own window (on the current fight) while the main window was on Overall.
local function DefaultFollow()
    local function Usable(inst)
        return inst and inst ~= instance and inst.IsEnabled and inst:IsEnabled() and inst.modo ~= 4
    end
    local saved = ns.db and ns.db.detailsFollowWindow
    if saved == false then return nil end
    if saved and Details.GetInstance then
        local inst = Details:GetInstance(saved)
        if Usable(inst) then return inst end
    end
    if Details.ListInstances then
        for _, inst in Details:ListInstances() do
            if Usable(inst) then return inst end
        end
    end
end
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

local DAY = 86400
local OVERALL_LIST_CAP = 40 -- Details keeps only the latest 40 entries in segments_added
local lastOverallSummary -- the last "details overall" debug line, so it's only logged on change

-- a - b for two times of day, across midnight: in -12 h .. +12 h.
local function ClockOffset(a, b)
    local diff = (a - b) % DAY
    return diff > DAY / 2 and diff - DAY or diff
end

-- The ManaMaster fights in Details' Overall segment, oldest first. Details records each fight it adds to
-- Overall in combat.segments_added ({ name, elapsed, clock = "HH:MM:SS" start }, newest first). Each entry
-- is matched to the saved fight whose time span overlaps it most. Not by start time alone: Details starts
-- a fight at the first combat event, which can come seconds after ManaMaster's (combat start), and with
-- back-to-back pulls that missed a fight (seen in game: 19 listed, 18 matched). Fights from other days can
-- share the time of day, so only the newest day with an overlapping fight counts.
-- Details keeps only the latest 40 entries, so with a full list the older fights in Overall are taken by
-- time instead: every saved fight since Overall's own start (GetDate, set from the first fight added) up to
-- the oldest matched one, within a day of it. The running fight is included while in combat.
local function OverallFights(combat)
    local saved = ns.char and ns.char.fights or {}
    local result, included = {}, {}
    local function Add(fight)
        if not included[fight] then
            included[fight] = true
            table.insert(result, fight)
        end
    end

    local added = combat.segments_added
    local oldestMatch
    for _, segment in ipairs(added) do
        local clock = ClockSeconds(segment.clock)
        if clock then
            local length = tonumber(segment.elapsed) or 0
            local best, bestOverlap
            for i = #saved, 1, -1 do -- newest first
                local fight = saved[i]
                local start = not included[fight] and FightSpan(fight, "day")
                -- Stop at an older day once the newest day with a match has been searched.
                if best and fight.date and best.date and best.date - fight.date > DAY / 2 then break end
                if start then
                    -- Both spans relative to the Details entry's start, with the usual slack at both ends.
                    local from = ClockOffset(start, clock)
                    local to = from + (fight.duration or 0)
                    local overlap = math.min(to, length + MATCH_TOLERANCE) - math.max(from, -MATCH_TOLERANCE)
                    if overlap > 0 and (not bestOverlap or overlap > bestOverlap) then
                        best, bestOverlap = fight, overlap
                    end
                end
            end
            if best then
                Add(best)
                if not oldestMatch or (best.date or 0) < (oldestMatch.date or 0) then oldestMatch = best end
            end
        end
    end

    if #added >= OVERALL_LIST_CAP and oldestMatch and oldestMatch.date then
        local firstClock = ClockSeconds((combat:GetDate()))
        for _, fight in ipairs(saved) do
            local start = FightSpan(fight, "day")
            if fight.date and start and fight.date < oldestMatch.date and oldestMatch.date - fight.date < DAY
                and (not firstClock or start >= firstClock - MATCH_TOLERANCE) then
                Add(fight)
            end
        end
    end

    if ns.current then Add(ns.current) end
    table.sort(result, function(a, b) return (a.date or 0) < (b.date or 0) end)
    -- Logged only when the counts change, since this runs on every refresh.
    local summary = #added .. " listed by Details, " .. #result .. " matched"
    if summary ~= lastOverallSummary then
        lastOverallSummary = summary
        ns.Debug("details overall:", summary)
    end
    return result
end

------------------------------------------------------------------------------------------------------------
-- Keeping the history in step with Details' segments.
-- DETAILS_DATA_SEGMENTREMOVED says segments were removed but not which (Details trims beyond its segment
-- limit, 25 by default, resets Overall or a combat type, or collects destroyed ones). So fights are marked
-- fight.detailsMatched once a Details segment overlaps them, and on removal a marked fight that no longer
-- overlaps any segment is deleted. Fights Details never recorded (very short, before it was installed) are
-- never marked, so they're never deleted. A full reset (DETAILS_DATA_RESET) asks instead.
-- Settings: ManaMasterDB.detailsMirrorRemovals (true/false), detailsResetAction ("ask", "clear", "keep").

-- Whether a saved fight overlaps a Details combat: by game clock, confirmed by time of day where both
-- exist (the game clock restarts with the computer, so an old segment could collide with a new fight).
local function FightInCombat(fight, combat)
    local okStart, gameStart = pcall(combat.GetStartTime, combat)
    local okEnd, gameEnd = pcall(combat.GetEndTime, combat)
    local okDate, dateStart, dateEnd = pcall(combat.GetDate, combat)
    local dayStart = okDate and ClockSeconds(dateStart)
    local dayEnd = okDate and ClockSeconds(dateEnd) or dayStart
    local fightDayStart, fightDayEnd = FightSpan(fight, "day")
    local dayMatch = dayStart and fightDayStart and Overlaps(fightDayStart, fightDayEnd, dayStart, dayEnd)

    local fightStart, fightEnd = FightSpan(fight, "game")
    if okStart and okEnd and (gameStart or 0) > 0 and (gameEnd or 0) > 0 and fightStart then
        return Overlaps(fightStart, fightEnd, gameStart, gameEnd) and (dayMatch or not dayStart)
    end
    return dayMatch or false
end

local function InAnySegment(fight, segments)
    for _, combat in ipairs(segments) do
        if FightInCombat(fight, combat) then return true end
    end
    return false
end

local function DetailsSegments()
    local ok, segments = pcall(Details.GetCombatSegments, Details)
    return ok and type(segments) == "table" and segments or {}
end

-- Marks saved fights that a Details segment overlaps. Run after Details finishes a fight, and at login.
local function MarkDetailsMatches()
    if not (ns.char and ns.char.fights) then return end
    local segments = DetailsSegments()
    for _, fight in ipairs(ns.char.fights) do
        if not fight.detailsMatched and InAnySegment(fight, segments) then fight.detailsMatched = true end
    end
end

-- Details removed segments: delete the marked fights that lost theirs.
local function MirrorRemovals()
    if not (ns.char and ns.char.fights) or ns.db.detailsMirrorRemovals == false then return end
    local segments = DetailsSegments()
    local removed = {}
    for _, fight in ipairs(ns.char.fights) do
        if fight.detailsMatched and not InAnySegment(fight, segments) then table.insert(removed, fight) end
    end
    if #removed > 0 then
        ns.Debug("details removed segments: deleting", #removed, "fights to match")
        ns.DeleteFights(removed)
    end
end

StaticPopupDialogs["MANAMASTER_DETAILS_RESET"] = {
    text = "Details! data was reset.\n\nAlso clear ManaMaster's fight history for %s (%d fights)?",
    button1 = YES,
    button2 = NO,
    OnAccept = function() ns.ClearHistory() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Details' data was reset. The fights are unlinked from Details first (their segments are all gone), so a
-- later removal can't delete them; then the history is cleared, kept, or the player is asked.
local lastResetTime
local function OnDetailsReset()
    lastResetTime = GetTime()
    if not (ns.char and ns.char.fights) then return end
    for _, fight in ipairs(ns.char.fights) do fight.detailsMatched = nil end
    local action = ns.db.detailsResetAction or "ask"
    ns.Debug("details data reset:", action)
    if action == "clear" then
        ns.ClearHistory()
    elseif action == "ask" and #ns.char.fights > 0 then
        StaticPopup_Show("MANAMASTER_DETAILS_RESET", ns.charName or "", #ns.char.fights)
    end
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

    -- "Overall" (segment -1) isn't matched by time span: its start time is made up (Details sets it to the
    -- last fight's start minus the combat time so far, so it skips the idle time between fights), and
    -- Details only adds fights that pass its Overall filter. So match the fights Details lists as added to
    -- it (OverallFights). Details versions without that list fall back to every fight since its start time.
    local isOverall = (inst.GetSegment and inst:GetSegment() == -1)
        or (Details.tabela_overall and combat == Details.tabela_overall)
    if isOverall and type(combat.segments_added) == "table" and #combat.segments_added > 0 then
        return OverallFights(combat)
    end
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

-- The fights and power the window shows (set by Update), for opening the history panel on a click.
local shownFights, shownPower

local function NewRow(i)
    local row = Details.gump:NewBar(frame, nil, "DetailsManaMasterRow" .. i, nil, 300, 14)
    row.fontsize = 9.9
    row.fontface = "GameFontHighlightSmall"
    row.rowId = i
    -- Hovering shows the spell's tooltip with its rank, like the meter window. Event-driven, like Details'
    -- own bars: hooks run as hook(frame, bar), and row.entry is the spell the row shows (set in Update).
    -- Only mouse motion is enabled; clicks fall through to the window (right-click for Details' menu).
    row:SetHook("OnEnter", function(bar) ns.ShowBarTooltip(bar, row.entry) end)
    row:SetHook("OnLeave", function(bar)
        if GameTooltip:IsOwned(bar) then GameTooltip:Hide() end
    end)
    -- Clicks, handled like Details' own bars (lineScript_Onmousedown/up in Details' window_main.lua):
    -- right-click opens Details' menu, a left press moves the window (unless locked), and a left click
    -- without moving opens the history panel on this segment's fights, in the bar's power (a rage bar opens
    -- rage). Returning true skips the bar's default handling.
    row:SetHook("OnMouseDown", function(_, button)
        local inst = plugin:GetPluginInstance()
        if button == "RightButton" then
            if inst and Details.switch and Details.switch.ShowMe then Details.switch:ShowMe(inst) end
        elseif button == "LeftButton" then
            row.pressX, row.pressY = GetCursorPosition()
            local startMove = inst and inst.baseframe:GetScript("OnMouseDown")
            if startMove then startMove(inst.baseframe, "LeftButton") end
        end
        return true
    end)
    row:SetHook("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return true end
        local inst = plugin:GetPluginInstance()
        local stopMove = inst and inst.baseframe:GetScript("OnMouseUp")
        if stopMove then stopMove(inst.baseframe, "LeftButton") end
        -- A click, not a drag: the cursor stayed within a few pixels of where it was pressed.
        local x, y = GetCursorPosition()
        if row.pressX and math.abs(x - row.pressX) < 5 and math.abs(y - row.pressY) < 5 then
            ns.OpenHistory(shownFights, row.power or shownPower)
        end
        row.pressX, row.pressY = nil, nil
        return true
    end)
    row:Hide()
    plugin.Rows[i] = row
    return row
end

-- Puts the rows above the Details window's right-click catcher (windowSwitchButton, a mouse-enabled button
-- covering the whole window at its base level + 4), which otherwise takes the hover: seen in game, with our
-- rows at the same level. Details' own bars sit above it the same way.
local function RaiseRows(inst)
    local catcher = inst and inst.windowSwitchButton
    local strata = catcher and catcher:GetFrameStrata() or frame:GetFrameStrata()
    local level = (catcher and catcher:GetFrameLevel() or frame:GetFrameLevel()) + 1
    for _, row in ipairs(plugin.Rows) do
        row.statusbar:SetFrameStrata(strata)
        row.statusbar:SetFrameLevel(level)
    end
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
    RaiseRows(inst)
end

-- Bar animation: each row slides from its current value to the new one, like the history panel's bars,
-- so bars grow as mana is spent and new spells' bars grow in from zero.
local BAR_ANIM_DURATION = 0.3 -- seconds
local animatingRows = {}
local animFrame = CreateFrame("Frame")
animFrame:Hide()
animFrame:SetScript("OnUpdate", function()
    local now = GetTime()
    for row in pairs(animatingRows) do
        local t = (now - row.animStart) / BAR_ANIM_DURATION
        if t >= 1 then
            row.animValue = row.animTo
            animatingRows[row] = nil
        else
            local eased = 1 - (1 - t) ^ 3 -- ease-out: fast start, gentle stop
            row.animValue = row.animFrom + (row.animTo - row.animFrom) * eased
        end
        row:SetValue(row.animValue)
    end
    if not next(animatingRows) then animFrame:Hide() end
end)

-- Sets a row's bar value (0-100), sliding from where it is. wasShown: rows that weren't visible grow from 0.
local function SetRowValue(row, value, wasShown)
    local from = wasShown and (row.animValue or 0) or 0
    if math.abs(from - value) < 0.1 then
        animatingRows[row] = nil
        row.animValue = value
        row:SetValue(value)
        return
    end
    row.animFrom, row.animTo, row.animStart = from, value, GetTime()
    animatingRows[row] = true
    animFrame:Show()
end

-- Fills the rows with the spells of the fights matching the window's segment: every power's spending
-- (ns.SpentGroups), grouped by power with the current form's or main power first, most spent first within
-- each. Each power has its own colour (mana blue, the game's rage and energy colours) and bar scale (its top
-- spell is a full bar), and percentages are of that power's total. There are no header rows, since Details
-- windows are often short; the tooltip names the power. Reads the window's segment each time, so switching
-- segments shows up at the next refresh.
local function Update()
    local ok, fights = pcall(FightsForSegment)
    if not ok then fights = DefaultFights() end -- a Details version with different segment data
    local groups = ns.SpentGroups(fights)
    shownFights, shownPower = fights, groups[1] and groups[1].token
    local list = ns.SpentRows(groups, plugin.canShow or 0, false)

    for i, row in ipairs(plugin.Rows) do
        local item = list[i]
        local spell = item and item.entry
        if i == 1 and not spell and plugin.canShow > 0 then
            -- Say why the window is empty rather than showing nothing.
            row:SetLeftText(#fights == 0 and "No ManaMaster fight in this segment" or "No resources spent")
            row:SetRightText("")
            if GameTooltip:IsOwned(row.statusbar) then GameTooltip:Hide() end
            row.entry, row.entryKey, row.power = nil, nil, nil
            animatingRows[row] = nil
            row.animValue = 0
            row:SetValue(0)
            row:SetIcon(UNKNOWN_ICON, ICON_COORDS)
            row:Show()
        elseif spell and i <= plugin.canShow then
            local group = item.group
            local pct = spell.mana / group.total * 100
            -- Same compact text as the meter window: "Frostbolt" and "×8  200 (73%)"; the rank is in the tooltip.
            row.entry, row.power = spell, item.group.token
            -- Rows reorder as mana is spent: if the hovered row now shows another spell, update its tooltip.
            local key = spell.spellID or spell.name
            if row.entryKey ~= key and GameTooltip:IsOwned(row.statusbar) then
                ns.ShowBarTooltip(row.statusbar, spell)
            end
            row.entryKey = key
            row:SetLeftText(ns.BarLabel(spell))
            row:SetRightText(string.format("%s%s (%.0f%%)", ns.BarCount(spell), ns.FormatNumber(spell.mana), pct))
            -- A row that showed a different spell before (spells reorder as mana changes) slides from there too.
            SetRowValue(row, spell.mana / group.entries[1].mana * 100, row.statusbar:IsShown())
            row:SetIcon(C_Spell.GetSpellTexture(spell.spellID or spell.name) or UNKNOWN_ICON, ICON_COORDS)
            row:SetColor(group.r, group.g, group.b)
            row:Show()
        else
            if GameTooltip:IsOwned(row.statusbar) then GameTooltip:Hide() end
            row.entry, row.entryKey, row.power = nil, nil, nil
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
    for _, row in ipairs(plugin.Rows) do
        if GameTooltip:IsOwned(row.statusbar) then GameTooltip:Hide() end
        row:Hide()
    end
end

function plugin:OnDetailsEvent(event, ...)
    if event == "SHOW" then
        instance = plugin:GetInstance(plugin.instance_id)
        followInstance = DefaultFollow()
        ns.Debug("details follows window", followInstance and followInstance:GetId() or "own",
            "| segment", (followInstance or instance) and (followInstance or instance):GetSegment())
        SizeChanged()
        StartUpdates()
    elseif event == "DETAILS_INSTANCE_CHANGESEGMENT" then
        -- A segment was chosen in some Details window: follow that window from now on.
        local changedInstance = ...
        if changedInstance then
            followInstance = changedInstance ~= instance and changedInstance or nil
            if ns.db then ns.db.detailsFollowWindow = followInstance and followInstance:GetId() or false end
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
        -- Back into the window's own layer (Details puts the plugin there), with the rows above its
        -- right-click catcher again.
        if instance then
            frame:SetFrameStrata(instance.baseframe:GetFrameStrata())
            RaiseRows(instance)
        end
    end
end

-- Details sends the plugin frame's PLAYER_LOGIN to OnEvent as "ADDON_LOADED" with the frame name, once
-- Details itself is ready; that's when the plugin is installed.
function plugin:OnEvent(_, event, name)
    if event ~= "ADDON_LOADED" or name ~= FRAME_NAME then return end

    local version = C_AddOns and C_AddOns.GetAddOnMetadata(addonName, "Version") or "v0.1"
    local installed = Details:InstallPlugin("RAID", PLUGIN_NAME, PLUGIN_ICON, plugin, PLUGIN_ID, 1, "olav9", version)
    if type(installed) == "table" and installed.error then
        print(ns.PREFIX .. "Details plugin: " .. tostring(installed.error))
        return
    end

    for _, detailsEvent in ipairs({ "DETAILS_INSTANCE_ENDRESIZE", "DETAILS_INSTANCE_SIZECHANGED",
        "DETAILS_INSTANCE_STARTSTRETCH", "DETAILS_INSTANCE_ENDSTRETCH", "DETAILS_OPTIONS_MODIFIED",
        "DETAILS_INSTANCE_CHANGESEGMENT" }) do
        Details:RegisterEvent(plugin, detailsEvent)
    end

    -- Keeping the history in step with Details' segments. Through an event listener, not the plugin: Details
    -- only sends a plugin its events while it's shown in a window, and this has to work regardless.
    -- Listener callbacks are called as func(event, ...).
    if Details.CreateEventListener then
        local listener = Details:CreateEventListener()
        listener:RegisterEvent("DETAILS_DATA_RESET", OnDetailsReset)
        listener:RegisterEvent("DETAILS_DATA_SEGMENTREMOVED", function()
            -- A reset sends this right after DETAILS_DATA_RESET, in the same frame; the reset is handled there.
            if lastResetTime ~= GetTime() then MirrorRemovals() end
        end)
        listener:RegisterEvent("COMBAT_PLAYER_LEAVE", function()
            -- Details finished a fight; ours ends at the same moment, so link them once both are saved.
            C_Timer.After(2, MarkDetailsMatches)
        end)
    end
    -- Link the saved fights to Details' segments once both have loaded.
    C_Timer.After(5, MarkDetailsMatches)
end
