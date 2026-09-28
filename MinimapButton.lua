local _, ns = ...

local ICON = "Interface\\Icons\\INV_Elemental_Mote_Mana" -- Mote of Mana; keep in sync with IconTexture in the .toc

local button

-- Places the button on the minimap's edge at the saved angle (degrees, 0 = right, counterclockwise).
local function UpdatePosition()
    local angle = math.rad(ns.db.minimapAngle)
    local radius = Minimap:GetWidth() / 2 + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
    local centerX, centerY = Minimap:GetCenter()
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    ns.db.minimapAngle = math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX))
    UpdatePosition()
end

-- Called once saved variables are loaded, since the position lives in ManaMasterDB.
function ns.CreateMinimapButton()
    button = CreateFrame("Button", "ManaMasterMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("AnyUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Same layering as the default minimap tracking button: dark disc, icon, gold ring.
    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -6)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    button:SetScript("OnClick", function()
        ns.ToggleHistory()
    end)
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", OnDragUpdate)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("ManaMaster")
        GameTooltip:AddLine("Click to open fight history", 1, 1, 1)
        GameTooltip:AddLine("Drag to move", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)

    UpdatePosition()
    button:SetShown(ns.db.showMinimapButton)
end

function ns.SetMinimapButtonShown(shown)
    ns.db.showMinimapButton = shown
    button:SetShown(shown)
end
