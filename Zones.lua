-- Polypode Map: Zones.lua — zones inexplorées (calques de ZoneData.lua) et niveau des zones dans l'en-tête
-- Dessin des zones inexplorées calqué sur reveal.lua de MapUtils de D4KiR (GPL-3.0) : les parties
-- non explorées de la carte sont posées, teintées, sur le repère d'exploration de Blizzard
-- (MapExplorationPinTemplate) de notre carte, à chaque fois qu'il redessine ses calques.
local _, ns = ...

local PIN_TEMPLATE = "MapExplorationPinTemplate"
local ZONE_MAP_TYPE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
local TINT = { 0.6, 0.6, 1, 1 } -- teinte bleutée des parties inexplorées (défaut de MapUtils)

-- ZONES INEXPLORÉES ---------------------------------------------------------------------------

local overlayCache = {} -- [artID] = { { width, height, offsetX, offsetY, files }, ... }
local states = {} -- [repère d'exploration] = { textures, count }

local function GetOverlays(artID)
	if overlayCache[artID] ~= nil then
		return overlayCache[artID] or nil
	end
	local data = ns.REVEAL_DATA[artID]
	if not data then
		overlayCache[artID] = false
		return nil
	end
	local overlays = {}
	for entry in data:gmatch("[^;]+") do
		local width, height, offsetX, offsetY, files = entry:match("^(%d+):(%d+):(%d+):(%d+)=(.+)$")
		if width then
			local fileIDs = {}
			for fileID in files:gmatch("%d+") do
				fileIDs[#fileIDs + 1] = tonumber(fileID)
			end
			overlays[#overlays + 1] = {
				width = tonumber(width), height = tonumber(height),
				offsetX = tonumber(offsetX), offsetY = tonumber(offsetY), files = fileIDs,
			}
		end
	end
	overlayCache[artID] = overlays
	return overlays
end

local function ClearPin(pin)
	local state = states[pin]
	for i = 1, state.count do
		state.textures[i]:Hide()
	end
	state.count = 0
end

local function AcquireTexture(pin, state)
	state.count = state.count + 1
	local texture = state.textures[state.count]
	if not texture then
		texture = pin:CreateTexture(nil, "ARTWORK")
		state.textures[state.count] = texture
	end
	return texture
end

-- Taille du fichier (puissance de 2) qui contient une tuile de `pixels`.
local function FileSize(pixels)
	local size = 16
	while size < pixels do
		size = size * 2
	end
	return size
end

-- Taille affichée et taille du fichier de la tuile `index` sur `count` (la dernière est plus petite).
local function TileSize(total, tile, index, count)
	if index < count then
		return tile, tile
	end
	local pixels = total % tile
	if pixels == 0 then
		pixels = tile
	end
	return pixels, FileSize(pixels)
end

local function DrawOverlay(pin, state, overlay, layer, drawLayer, subLevel)
	local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
	local wide = math.ceil(overlay.width / tileWidth)
	local tall = math.ceil(overlay.height / tileHeight)
	for row = 1, tall do
		local pixelHeight, fileHeight = TileSize(overlay.height, tileHeight, row, tall)
		for col = 1, wide do
			local fileID = overlay.files[(row - 1) * wide + col]
			if fileID then
				local pixelWidth, fileWidth = TileSize(overlay.width, tileWidth, col, wide)
				local texture = AcquireTexture(pin, state)
				texture:SetDrawLayer(drawLayer, subLevel)
				texture:SetSize(pixelWidth, pixelHeight)
				texture:SetTexCoord(0, pixelWidth / fileWidth, 0, pixelHeight / fileHeight)
				texture:ClearAllPoints()
				texture:SetPoint("TOPLEFT", pin, "TOPLEFT", overlay.offsetX + tileWidth * (col - 1),
					-(overlay.offsetY + tileHeight * (row - 1)))
				texture:SetTexture(fileID, nil, nil, "TRILINEAR")
				texture:SetVertexColor(TINT[1], TINT[2], TINT[3], TINT[4])
				texture:Show()
			end
		end
	end
end

-- Couche de dessin juste sous celle des parties explorées (posée par le fournisseur de Blizzard).
local function DrawLayer(pin)
	local drawLayer, subLevel = "ARTWORK", 0
	if pin.dataProvider and pin.dataProvider.GetDrawLayer then
		drawLayer, subLevel = pin.dataProvider:GetDrawLayer()
	end
	return drawLayer, math.max(-8, (subLevel or 0) - 1)
end

local function RefreshPin(pin)
	ClearPin(pin)
	if not ns.Settings().revealMap then
		return
	end
	local map = pin:GetMap()
	local mapID = map and map:GetMapID()
	local info = mapID and C_Map.GetMapInfo(mapID)
	if not info or info.mapType ~= ZONE_MAP_TYPE then
		return
	end
	local artID = C_Map.GetMapArtID(mapID)
	local overlays = artID and GetOverlays(artID)
	local container = map:GetCanvasContainer()
	if not overlays or not container or type(container.zoomLevels) ~= "table" or not container.zoomLevels[1] then
		return
	end
	local layers = C_Map.GetMapArtLayers(mapID)
	local layer = layers and layers[container:GetCurrentLayerIndex()]
	if not layer then
		return
	end
	local explored = {}
	for _, texture in ipairs(C_MapExplorationInfo.GetExploredMapTextures(mapID) or {}) do
		explored[texture.offsetX .. ":" .. texture.offsetY] = true
	end
	local state = states[pin]
	local drawLayer, subLevel = DrawLayer(pin)
	for _, overlay in ipairs(overlays) do
		if not explored[overlay.offsetX .. ":" .. overlay.offsetY] then
			DrawOverlay(pin, state, overlay, layer, drawLayer, subLevel)
		end
	end
end

-- Option revealMap changée : calques redessinés.
function ns.RefreshReveal()
	for pin in pairs(states) do
		pcall(RefreshPin, pin)
	end
end

-- Appelé par Map.lua une fois les fournisseurs de Blizzard ajoutés (le repère d'exploration est
-- unique et permanent) ; rien hors de WoW Forever (pas de données).
function ns.InitReveal(map)
	if not ns.REVEAL_DATA or not C_MapExplorationInfo or not C_MapExplorationInfo.GetExploredMapTextures
		or not map.EnumeratePinsByTemplate then
		return
	end
	for pin in map:EnumeratePinsByTemplate(PIN_TEMPLATE) do
		if not states[pin] then
			states[pin] = { textures = {}, count = 0 }
			hooksecurefunc(pin, "RefreshOverlays", function(self)
				pcall(RefreshPin, self)
			end)
			hooksecurefunc(pin, "RemoveAllData", ClearPin)
			pcall(RefreshPin, pin)
		end
	end
end

-- NIVEAU DES ZONES ----------------------------------------------------------------------------

local levelCache = {} -- [uiMapID] = { min, max } ou false (niveaux du jeu, C_Map.GetMapLevels)

local function GameLevels(mapID)
	if levelCache[mapID] == nil then
		local ok, minLevel, maxLevel = false, nil, nil
		if C_Map.GetMapLevels then
			ok, minLevel, maxLevel = pcall(C_Map.GetMapLevels, mapID)
		end
		levelCache[mapID] = ok and type(minLevel) == "number" and type(maxLevel) == "number" and minLevel > 0
			and maxLevel > 0 and { minLevel, maxLevel } or false
	end
	return levelCache[mapID] or nil
end

-- Couleur d'une tranche pour ce personnage (comme MapUtils) : en dessous, couleur du niveau minimum ;
-- au-dessus, du maximum - 2 (gris, vert) ; dedans, « difficile » (orange).
local function ColorCode(minLevel, maxLevel)
	local level = UnitLevel("player") or 0
	local color
	if GetQuestDifficultyColor and level < minLevel then
		color = GetQuestDifficultyColor(minLevel)
	elseif GetQuestDifficultyColor and level > maxLevel then
		color = GetQuestDifficultyColor(maxLevel - 2)
	elseif QuestDifficultyColors then
		color = QuestDifficultyColors.difficult
	end
	if not color or not color.r then
		return "|cffffffff"
	end
	return string.format("|cff%02x%02x%02x", color.r * 255, color.g * 255, color.b * 255)
end

local function RangeText(range)
	local text = range[1] == range[2] and tostring(range[1]) or string.format("%d-%d", range[1], range[2])
	return ColorCode(range[1], range[2]) .. text .. "|r"
end

-- « (10-20) » en couleur, ou « (25-38, 41-47) » pour plusieurs tranches ; "" sans niveaux connus ou
-- option coupée. WoW Forever : tableau de ZoneData.lua d'abord (comme MapUtils), sinon le jeu.
function ns.ZoneLevelText(mapID)
	if not mapID or not ns.Settings().showZoneLevels then
		return ""
	end
	local levels = ns.ZONE_LEVELS and ns.ZONE_LEVELS[mapID] or GameLevels(mapID)
	if not levels then
		return ""
	end
	if type(levels[1]) ~= "table" then
		levels = { levels }
	end
	local parts = {}
	for _, range in ipairs(levels) do
		parts[#parts + 1] = RangeText(range)
	end
	return " (" .. table.concat(parts, ", ") .. ")"
end
