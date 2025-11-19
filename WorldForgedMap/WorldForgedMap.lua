-- WorldForgedMap.lua (Ascension 3.3.5, UI 30300)
-- Logic for WorldForgedMap
-- Version: 2.1

local ADDON_NAME = "WorldForgedMap"
local ADDON_VERSION = "2.1"

-- Load data from external file (WorldForgedMap_Data.lua)
if not WorldForgedMap_Data then
    print("|cffff0000WorldForgedMap ERROR: data file missing (WorldForgedMap_Data.lua)!|r")
    WorldForgedMap_Data = {}
end
local data = WorldForgedMap_Data

-- SavedVariablesPerCharacter
if not WorldForgedMapDB then WorldForgedMapDB = {} end
WorldForgedMapDB.collected = WorldForgedMapDB.collected or {}
WorldForgedMapDB.showCollected = WorldForgedMapDB.showCollected or false
WorldForgedMapDB.invertY = WorldForgedMapDB.invertY or false
WorldForgedMapDB.opacity = WorldForgedMapDB.opacity or 100 -- 0..100
WorldForgedMapDB.showMinimapPins = WorldForgedMapDB.showMinimapPins ~= nil and WorldForgedMapDB.showMinimapPins or true
WorldForgedMapDB.maxMinimapPins = WorldForgedMapDB.maxMinimapPins or 5 -- default 5

-- Utility
local function GetCurrentMapArea()
    if GetCurrentMapAreaID then
        local ok, id = pcall(GetCurrentMapAreaID)
        if ok and id and id ~= 0 then return id end
    end
    return 0
end

function IsCollected(id)
    if not id or id == "" then return nil end
    return WorldForgedMapDB.collected and WorldForgedMapDB.collected[id]
end

function ToggleCollected(id)
    if not id or id == "" then return end
    if IsCollected(id) then
        WorldForgedMapDB.collected[id] = nil
    else
        WorldForgedMapDB.collected[id] = true
    end
end

-- Pin management
local pinPool = {}
local minimapPinPool = {}
local activeMinimapPins = {}
local lastPlayerPosition = { 0, 0, 0, 0 } -- C, Z, x, y

-- Performance optimization variables
local lastUpdateX, lastUpdateY = 0, 0
local MOVEMENT_THRESHOLD = 0.001 -- Only update if moved 0.1% of map
local lastFacing = 0
local cachedSin, cachedCos = 0, 1
local FACING_THRESHOLD = 0.01 -- radians

-- Choose best map canvas / parent (used for sizing & origin)
local function ChooseMapParent()
    if WorldMapDetailFrame and WorldMapDetailFrame:IsShown() then return WorldMapDetailFrame end
    
    if WorldMapFrame and WorldMapFrame:IsShown() and WorldMapFrame.GetCanvas then
        local ok, canvas = pcall(function() return WorldMapFrame:GetCanvas() end)
        if ok and canvas then return canvas end
    end
    if WorldMapButton then return WorldMapButton end
    if WorldMapScrollFrame then return WorldMapScrollFrame end
    return UIParent
end

-- AcquirePin: create/reuse pins as children of the map canvas
local function AcquirePin(parent)
    local pin = table.remove(pinPool)
    if pin then
        pin:SetParent(parent)
        pin:Show()
        pin.wf_id = nil
        pin.wf_name = nil
        pin.wf_coords = nil
        pin.texture:SetTexture("Interface\\ICONS\\INV_Misc_Map_01")
        pin.texture:SetVertexColor(1, 1, 1)
        pin.texture:SetAlpha((WorldForgedMapDB.opacity or 100) / 100)
        return pin
    end

    local frame = CreateFrame("Button", nil, parent)
    frame:SetSize(20, 20)
    frame:EnableMouse(true)
    frame:SetHitRectInsets(-6, -6, -6, -6)
    frame:SetFrameStrata("TOOLTIP")
    frame:SetFrameLevel(9999)

    frame.texture = frame:CreateTexture(nil, "ARTWORK")
    frame.texture:SetAllPoints()
    frame.texture:SetTexture("Interface\\ICONS\\INV_Misc_Map_01")
    frame.texture:SetAlpha((WorldForgedMapDB.opacity or 100) / 100)

    frame:SetScript("OnEnter", function(self)
        if GameTooltip then
            GameTooltip:ClearLines()
            
            local mapWidth = WorldMapFrame and WorldMapFrame:GetWidth() or UIParent:GetWidth()
            local screenWidth = UIParent:GetWidth()
            local isFullscreen = mapWidth and screenWidth and (mapWidth / screenWidth) > 0.8

            if isFullscreen and WorldMapFrame then
                GameTooltip:SetOwner(WorldMapFrame, "ANCHOR_CURSOR")
            else
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            end

            GameTooltip:SetText(self.wf_name and self.wf_name ~= "" and self.wf_name or "WorldForged")
            local collected = IsCollected(self.wf_id)
            GameTooltip:AddLine(collected and "Collected" or "Not collected")
            if self.wf_coords then
                GameTooltip:AddLine(string.format("Coords: %.2f, %.2f", self.wf_coords.x * 100, self.wf_coords.y * 100), 1, 1, 0)
            end
            GameTooltip:Show()
        end

        local baseAlpha = (WorldForgedMapDB.opacity or 100) / 100
        self.texture:SetAlpha(math.max(0, baseAlpha * 0.25))
    end)

    frame:SetScript("OnLeave", function(self)
        if GameTooltip then GameTooltip:Hide() end

        local baseAlpha = (WorldForgedMapDB.opacity or 100) / 100
        local collected = IsCollected(self.wf_id)
        local mul = collected and 0.6 or 1
        self.texture:SetVertexColor(collected and 0.6 or 1, collected and 0.6 or 1, collected and 0.6 or 1)
        self.texture:SetAlpha(baseAlpha * mul)
    end)

    frame:SetScript("OnClick", function(self, button)
        if not self.wf_id or self.wf_id == "" then
            return
        end

        if button == "LeftButton" then
            ToggleCollected(self.wf_id)
            local collected = IsCollected(self.wf_id)
            local baseAlpha = (WorldForgedMapDB.opacity or 100) / 100
            local mul = collected and 0.6 or 1
            self.texture:SetVertexColor(collected and 0.6 or 1, collected and 0.6 or 1, collected and 0.6 or 1)
            self.texture:SetAlpha(baseAlpha * mul)

            if UpdateMinimapPins then pcall(UpdateMinimapPins) end
        elseif button == "RightButton" then
            print(ADDON_NAME .. ": id=" .. tostring(self.wf_id) .. " name=" .. tostring(self.wf_name))
        end
    end)

    return frame
end

local function ReleaseAllPins()
    if WorldForgedMapFrame._activePins then
        for _, pin in ipairs(WorldForgedMapFrame._activePins) do
            if pin then
                pin:Hide()
                pin.wf_id = nil
                pin.wf_name = nil
                pin.wf_coords = nil
                table.insert(pinPool, pin)
            end
        end
    end
    WorldForgedMapFrame._activePins = {}
end

local function PlacePinOnFrame(pin, entry, parentFrame)
    parentFrame = parentFrame or ChooseMapParent()
    local width = parentFrame:GetWidth() or 1024
    local height = parentFrame:GetHeight() or 768
    local ynorm = WorldForgedMapDB.invertY and (1 - entry.y) or entry.y

    pin:ClearAllPoints()
    local px = entry.x * width
    local py = -ynorm * height
    pin:SetPoint("CENTER", parentFrame, "TOPLEFT", px, py)
end

local function DrawPinsForMap(mapAreaID)
    ReleaseAllPins()
    if not mapAreaID or mapAreaID == 0 then return end
    local points = data[mapAreaID]
    if not points then return end

    WorldForgedMapFrame._activePins = {}
    local parentFrame = ChooseMapParent()
    local baseAlpha = (WorldForgedMapDB.opacity or 100) / 100

    for _, entry in ipairs(points) do
        if entry and entry.x and entry.y then
            if not (IsCollected(entry.id) and not WorldForgedMapDB.showCollected) then
                local pin = AcquirePin(parentFrame)
                pin.wf_id = entry.id
                pin.wf_name = entry.name
                pin.wf_coords = { x = entry.x, y = entry.y }

                local collected = IsCollected(entry.id)
                local mul = collected and 0.6 or 1
                pin.texture:SetVertexColor(collected and 0.6 or 1, collected and 0.6 or 1, collected and 0.6 or 1)
                pin.texture:SetAlpha(baseAlpha * mul)

                PlacePinOnFrame(pin, entry, parentFrame)
                table.insert(WorldForgedMapFrame._activePins, pin)
            end
        end
    end
end

-- MINIMAP TRACKING LOGIC START
local twoPi = math.pi * 2
local sin = math.sin
local cos = math.cos
local sqrt = math.sqrt
local abs = math.abs
local Minimap = Minimap

local function GetCurrentPlayerPosition()
    local x, y = GetPlayerMapPosition("player")
    if x and y and x > 0 and y > 0 then
        return { GetCurrentMapContinent(), GetCurrentMapAreaID(), x, y }
    end
    return nil
end

-- OPTIMIZED: Fallback for when C_WorldMap is slow/unavailable
local function ComputeDistance(C1, Z1, x1, y1, C2, Z2, x2, y2)
    if C1 ~= C2 or Z1 ~= Z2 then return nil end

    -- Check if C_WorldMap exists before using pcall
    if not C_WorldMap or not C_WorldMap.GetWorldPosition then
        -- Fallback to simple euclidean distance
        local xDelta = x2 - x1
        local yDelta = y2 - y1
        return sqrt(xDelta*xDelta + yDelta*yDelta) * 1000, xDelta * 1000, yDelta * 1000
    end

    local ok1, worldX1, worldY1 = pcall(C_WorldMap.GetWorldPosition, Z1, x1, y1)
    local ok2, worldX2, worldY2 = pcall(C_WorldMap.GetWorldPosition, Z2, x2, y2)
    
    if not ok1 or not ok2 or not worldX1 or not worldY1 or not worldX2 or not worldY2 then
        -- Fallback
        local xDelta = x2 - x1
        local yDelta = y2 - y1
        return sqrt(xDelta*xDelta + yDelta*yDelta) * 1000, xDelta * 1000, yDelta * 1000
    end

    local xDelta = worldX2 - worldX1
    local yDelta = worldY2 - worldY1
    local dist = sqrt(xDelta*xDelta + yDelta*yDelta)
    
    return dist, xDelta, yDelta
end

-- OPTIMIZED: Cache trig calculations
local function placeIconOnMinimap(icon, dist, xDist, yDist)
    local mapRadius = Minimap:GetWidth() / 2
    local iconDiameter = (icon:GetWidth() / 2) + 3
    local mapScale = Minimap:GetScale()
    
    local enableRotation = GetCVar("rotateMinimap") == "1"

    if enableRotation then
        local facing = GetPlayerFacing()
        
        -- OPTIMIZATION: Only recalculate trig if facing changed significantly
        if abs(facing - lastFacing) > FACING_THRESHOLD then
            cachedSin = sin(facing)
            cachedCos = cos(facing)
            lastFacing = facing
        end
        
        local dx, dy = xDist, yDist
        xDist = (dx * cachedSin) - (dy * cachedCos)
        yDist = (dx * cachedCos) + (dy * cachedSin)
    end

    if dist > mapRadius then
        local factor = (mapRadius - ((icon:GetWidth() / 2) + 3)) / dist
        xDist = xDist * factor
        yDist = yDist * factor
    end

    local finalX = -yDist / mapScale
    local finalY = xDist / mapScale

    icon:ClearAllPoints()
    icon:SetPoint("CENTER", Minimap, "CENTER", finalX, finalY)
    icon:Show()
end

-- ===== Forward declare UpdateMinimapPins so earlier closures can call it safely =====
local UpdateMinimapPins

-- Plain Button AcquireMinimapPin with pooling flag
local function AcquireMinimapPin(entry)
    local pin = table.remove(minimapPinPool)
    if pin then
        pin:SetParent(Minimap)
        pin._pooled = nil
        pin:Show()
    else
        pin = CreateFrame("Button", nil, Minimap)
        pin:SetSize(16, 16)
        pin:SetFrameStrata("LOW")
        pin:SetFrameLevel(1)

        pin.texture = pin:CreateTexture(nil, "OVERLAY")
        pin.texture:SetAllPoints()
        pin.texture:SetTexture("Interface\\ICONS\\INV_Misc_Map_01")
        pin.texture:SetVertexColor(1,1,1)

        pin:EnableMouse(true)
        pin:SetScript("OnEnter", function(self)
            if GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                GameTooltip:SetText(self.wf_name or "WorldForged Pin")
                GameTooltip:Show()
            end
        end)
        pin:SetScript("OnLeave", function(self)
            if GameTooltip then GameTooltip:Hide() end
        end)
        pin:SetScript("OnMouseDown", function() end)
        pin:SetScript("OnMouseUp", function() end)

        pin:SetScript("OnHide", function(self)
            self._pooled = true
            self.texture:SetVertexColor(1,1,1)
            self.texture:SetAlpha((WorldForgedMapDB.opacity or 100)/100)
            self.wf_id = nil
            self.wf_name = nil
            self.wf_coords = nil
            for id, p in pairs(activeMinimapPins) do
                if p == self then
                    activeMinimapPins[id] = nil
                    break
                end
            end
        end)
    end

    pin.wf_id = entry.id
    pin.wf_name = entry.name or ("wf_" .. tostring(entry.x) .. "_" .. tostring(entry.y))
    pin.wf_coords = entry.wf_coords or { x = entry.x, y = entry.y }

    pin:SetScript("OnClick", function(self, button)
        if not self.wf_id or self.wf_id == "" then return end
        if button == "LeftButton" then
            ToggleCollected(self.wf_id)
            if UpdateMinimapPins then pcall(UpdateMinimapPins) end
        elseif button == "RightButton" then
            print(ADDON_NAME .. ": id=" .. tostring(self.wf_id) .. " name=" .. tostring(self.wf_name))
        end
    end)

    pin:SetParent(Minimap)
    pin:Show()
    pin._pooled = nil
    return pin
end

-- OPTIMIZED: Movement throttling + nearest N pins only
UpdateMinimapPins = function()
    if not WorldForgedMapDB.showMinimapPins then
        for _, pin in pairs(activeMinimapPins) do if pin then pin:Hide() end end
        activeMinimapPins = {}
        return
    end
    
    local playerPos = GetCurrentPlayerPosition()
    if not playerPos then
        for _, pin in pairs(activeMinimapPins) do pin:Hide() end
        activeMinimapPins = {}
        return
    end

    local C, Z, x, y = playerPos[1], playerPos[2], playerPos[3], playerPos[4]
    
    -- OPTIMIZATION: Skip update if player hasn't moved much
    local deltaX = abs(x - lastUpdateX)
    local deltaY = abs(y - lastUpdateY)
    if deltaX < MOVEMENT_THRESHOLD and deltaY < MOVEMENT_THRESHOLD then
        return -- Don't update if movement is negligible
    end
    lastUpdateX, lastUpdateY = x, y
    
    local currentMapID = GetCurrentMapArea()
    local points = data[currentMapID]
    if not points then return end

    -- OPTIMIZATION: Calculate distances and sort to get nearest N
    local distanceTable = {}
    
    for _, entry in ipairs(points) do
        if entry and entry.x and entry.y then
            if not (IsCollected(entry.id) and not WorldForgedMapDB.showCollected) then
                local dist, xDist, yDist = ComputeDistance(C, Z, x, y, C, Z, entry.x, entry.y)
                
                if dist and dist < 1000 then
                    table.insert(distanceTable, {
                        entry = entry,
                        dist = dist,
                        xDist = xDist,
                        yDist = yDist
                    })
                end
            end
        end
    end
    
    -- Sort by distance (closest first)
    table.sort(distanceTable, function(a, b) return a.dist < b.dist end)
    
    -- Only show the nearest N pins (configurable)
    local maxPins = WorldForgedMapDB.maxMinimapPins or 5
    local newActivePins = {}
    local baseAlpha = (WorldForgedMapDB.opacity or 100) / 100
    
    for i = 1, math.min(maxPins, #distanceTable) do
        local data = distanceTable[i]
        local entry = data.entry
        
        local pin = activeMinimapPins[entry.id]
        if not pin then
            pin = AcquireMinimapPin(entry)
        else
            pin.wf_name = (entry.name and entry.name ~= "") and entry.name or ("WorldForged Pin")
            pin.wf_coords = entry.wf_coords or { x = entry.x, y = entry.y }
        end
        
        local collected = IsCollected(entry.id)
        local mul = collected and 0.6 or 1
        pin.texture:SetVertexColor(collected and 0.6 or 1, collected and 0.6 or 1, collected and 0.6 or 1)
        pin.texture:SetAlpha(baseAlpha * mul)

        placeIconOnMinimap(pin, data.dist, data.xDist, data.yDist)
        newActivePins[entry.id] = pin
    end
    
    -- Hide all pins that aren't in the nearest N
    for id, pin in pairs(activeMinimapPins) do
        if not newActivePins[id] then
            if pin and not pin._pooled then
                pin:Hide()
                pin._pooled = true
                table.insert(minimapPinPool, pin)
            elseif pin then
                pin:Hide()
            end
        end
    end
    activeMinimapPins = newActivePins
    lastPlayerPosition = playerPos
end

-- OPTIMIZED: Changed from 60s to 0.5s update frequency
local minimapFrame = CreateFrame("Frame")
minimapFrame:SetScript("OnUpdate", function(self, elapsed)
    self.timeSinceLastUpdate = (self.timeSinceLastUpdate or 0) + elapsed
    if self.timeSinceLastUpdate > 0.5 then
        if UpdateMinimapPins then pcall(UpdateMinimapPins) end
        self.timeSinceLastUpdate = 0
    end
end)

-- Map update handler
local function OnWorldMapEvent(self, event, ...)
    local mapAreaID = GetCurrentMapArea()
    if mapAreaID and mapAreaID ~= 0 then
        DrawPinsForMap(mapAreaID)
    else
        ReleaseAllPins()
    end
    
    if UpdateMinimapPins then pcall(UpdateMinimapPins) end
end

-- Frame events
WorldForgedMapFrame = WorldForgedMapFrame or CreateFrame("Frame", "WorldForgedMapFrame")
WorldForgedMapFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
WorldForgedMapFrame:RegisterEvent("WORLD_MAP_UPDATE")
WorldForgedMapFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
WorldForgedMapFrame:SetScript("OnEvent", OnWorldMapEvent)

-- Hook map show/resize so pins reposition correctly
if WorldMapFrame then
    WorldMapFrame:HookScript("OnShow", function() OnWorldMapEvent(WorldForgedMapFrame, "WORLD_MAP_UPDATE") end)
    local ok, canvas = pcall(function() return WorldMapFrame.GetCanvas and WorldMapFrame:GetCanvas() end)
    if ok and canvas and canvas.HookScript then
        canvas:HookScript("OnSizeChanged", function() OnWorldMapEvent(WorldForgedMapFrame, "WORLD_MAP_UPDATE") end)
    elseif WorldMapDetailFrame and WorldMapDetailFrame.HookScript then
        WorldMapDetailFrame:HookScript("OnSizeChanged", function() OnWorldMapEvent(WorldForgedMapFrame, "WORLD_MAP_UPDATE") end)
    end
end

-- ===== Debug: print current map / player map info =====
local function PrintCurrentMapDebug()
    local okArea, areaID = pcall(function() return GetCurrentMapAreaID and GetCurrentMapAreaID() or nil end)
    areaID = okArea and areaID or nil

    local okCont, contID = pcall(function() return GetCurrentMapContinent and GetCurrentMapContinent() or nil end)
    contID = okCont and contID or nil

    local okPos, px, py = pcall(function() return GetPlayerMapPosition and GetPlayerMapPosition("player") end)
    if not okPos or not px or not py then px, py = nil, nil end

    local zoneText = (GetRealZoneText and GetRealZoneText()) or (GetZoneText and GetZoneText()) or "unknown"

    local mapName = nil
    if areaID and GetMapNameByID then
        local okName, name = pcall(GetMapNameByID, areaID)
        mapName = okName and name or nil
    end

    print(("|cff33ff99%s|r: Map debug:"):format(ADDON_NAME))
    print("  MapAreaID: " .. tostring(areaID))
    print("  ContinentID: " .. tostring(contID))
    print("  MapName (GetMapNameByID): " .. tostring(mapName or "n/a"))
    print("  ZoneText: " .. tostring(zoneText))
    if px and py then
        print(string.format("  PlayerMapPos: %.4f, %.4f", px, py))
    else
        print("  PlayerMapPos: n/a")
    end

    if lastPlayerPosition then
        local lp = lastPlayerPosition
        print(string.format("  lastPlayerPosition (C,Z,x,y): %s, %s, %.4f, %.4f",
            tostring(lp[1] or "nil"), tostring(lp[2] or "nil"), tonumber(lp[3] or 0), tonumber(lp[4] or 0)))
    end

    print("  Tip: use the numeric MapAreaID (above) as the key in your data table (e.g., [44] = {...})")
end

-- Slash commands (single /wfmap with mapid debug)
SLASH_WORLDFORGED1 = "/wfmap"
SlashCmdList["WORLDFORGED"] = function(msg)
    msg = msg and msg:lower() or ""
    if msg == "minimap" or msg == "mm" then
        WorldForgedMapDB.showMinimapPins = not WorldForgedMapDB.showMinimapPins
        print(ADDON_NAME .. ": Minimap pins " .. (WorldForgedMapDB.showMinimapPins and "shown" or "hidden"))
        if UpdateMinimapPins then pcall(UpdateMinimapPins) end
        return
    end
    if msg == "toggle collected" then
        WorldForgedMapDB.showCollected = not WorldForgedMapDB.showCollected
        print(ADDON_NAME .. ": showCollected = " .. tostring(WorldForgedMapDB.showCollected))
        OnWorldMapEvent(WorldForgedMapFrame, "WORLD_MAP_UPDATE")
    elseif msg == "list" then
        print(ADDON_NAME .. ": Collected items:")
        for id in pairs(WorldForgedMapDB.collected) do print(" - " .. id) end
    elseif msg == "reset" then
        WorldForgedMapDB.collected = {}
        print(ADDON_NAME .. ": cleared collected list.")
        OnWorldMapEvent(WorldForgedMapFrame, "WORLD_MAP_UPDATE")
    elseif msg == "inverty" then
        WorldForgedMapDB.invertY = not WorldForgedMapDB.invertY
        print(ADDON_NAME .. ": invertY = " .. tostring(WorldForgedMapDB.invertY))
        OnWorldMapEvent(WorldForgedMapFrame, "WORLD_MAP_UPDATE")
    elseif msg == "mapid" or msg == "debugmap" or msg == "debug" then
        PrintCurrentMapDebug()
    elseif msg:match("^force%s+%d+") then
        local id = tonumber(msg:match("^force%s+(%d+)"))
        if id then DrawPinsForMap(id) end
    elseif msg:match("^opacity%s+%d+") then
        local pct = tonumber(msg:match("^opacity%s+(%d+)"))
        if pct and pct >= 0 and pct <= 100 then
            WorldForgedMapDB.opacity = pct
            print(ADDON_NAME .. ": default pin opacity set to " .. pct .. "%")
            OnWorldMapEvent(WorldForgedMapFrame, "WORLD_MAP_UPDATE")
        end
    elseif msg:match("^maxpins%s+%d+") then
        local num = tonumber(msg:match("^maxpins%s+(%d+)"))
        if num and num >= 1 and num <= 50 then
            WorldForgedMapDB.maxMinimapPins = num
            print(ADDON_NAME .. ": max minimap pins set to " .. num)
            if UpdateMinimapPins then pcall(UpdateMinimapPins) end
        else
            print(ADDON_NAME .. ": maxpins must be between 1 and 50")
        end
    else
        print("|cff33ff99WorldForgedMap|r commands:")
        print("  /wfmap toggle collected")
        print("  /wfmap list")
        print("  /wfmap reset")
        print("  /wfmap inverty")
        print("  |cff00ff00/wfmap mapid|r  ← show current map ID")
        print("  /wfmap force <id>")
        print("  /wfmap opacity <0-100>")
        print("  /wfmap minimap  ← toggle minimap pins")
        print("  |cff00ff00/wfmap maxpins <1-50>|r  ← set max minimap pins (default: 5)")
    end
end

print(ADDON_NAME .. " v" .. ADDON_VERSION .. " loaded. Use /wfmap for commands.")