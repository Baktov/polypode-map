-- Polypode Map: Map — petite carte de zone permanente (fenêtre, moteur de carte de Blizzard, options)

local ADDON_NAME, ns = ...
local P = Polypode -- dépendance obligatoire (## Dependencies: Polypode), chargée avant nous

-- La carte est une instance du moteur commun aux cartes de Blizzard (MapCanvasMixin, celui de la
-- carte du monde et de la carte de zone Maj + M), construite par l'addon sans toucher aux cadres de
-- Blizzard : mêmes images de carte, mêmes fournisseurs de repères (quêtes, points d'intérêt,
-- groupe...), aucun hook sur BattlefieldMapFrame ni WorldMapFrame. La fenêtre (PolypodeMapFrame)
-- se déplace par son en-tête (affiché au survol), se redimensionne par la poignée bas-droite, se
-- fige ; la molette zoome (plus de niveaux que Blizzard : CreateZoomLevels), le glisser déplace la
-- vue ; hors survol, la carte suit le joueur (carte de sa zone, centrée sur lui) et peut être
-- estompée. Clic gauche = ping (Members.lua), Alt + clic droit = point TomTom (Plugins.lua).
-- Réglages par personnage dans PolypodeMapDB (panneau Options → AddOns → Polypode → Map, et petite
-- fenêtre du clic droit sur le bouton « Map » ou sur l'en-tête).

local MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT = 160, 120, 1600, 1200
local HEADER_HEIGHT = 18
local TICK = 0.1 -- secondes : survol, coordonnées
local FOLLOW_INTERVAL = 0.2 -- secondes : suivi du joueur
local ZOOM_STEPS_PER_LAYER = 8 -- niveaux de zoom par couche de carte (Blizzard en donne 2 ou 3)
local ZOOM_STEP_FACTOR = 1.25
local PLAYER_PIN_SIZE, PARTY_PIN_SIZE, RAID_PIN_SIZE = 16, 10, 8 -- repères de groupe de Blizzard

-- Réglages par personnage (PolypodeMapDB), complétés à ADDON_LOADED.
local DEFAULTS = {
	shown = true, -- fenêtre affichée
	locked = false, -- ni déplacement ni redimensionnement
	point = "TOPRIGHT", relativePoint = "TOPRIGHT", x = -230, y = -230,
	width = 300, height = 220,
	scale = 100, -- % taille de la fenêtre
	opacity = 100, -- % opacité hors survol
	strata = "DIALOG", -- plan le plus haut utilisable (les fenêtres d'options restent devant : Raise)
	followPlayer = true, -- hors survol : carte du joueur, centrée sur lui
	headerAlways = false, -- en-tête (zone, coordonnées) affiché même hors survol
	autoFit = false, -- cadre ajusté aux proportions de chaque nouvelle carte (comme le clic sur l'en-tête)
	borderSize = 1, -- épaisseur du cadre autour de la carte (pixels, 0 = aucun)
	borderColor = "black", -- couleur du cadre (BORDER_COLORS)
	pinScale = 70, -- % taille des icônes de Blizzard (quêtes, points d'intérêt...)
	memberScale = 100, -- % taille des repères des personnages
	showNames = true, -- nom au-dessus des repères des personnages
	showAll = false, -- tous les personnages du roster au lieu de l'équipe sélectionnée
	showQuests = true, -- quêtes, objectifs bonus, suivi de contenu
	showWorldQuests = true, -- expéditions
	showHereBeDragons = true, -- points TomTom (et autres addons HereBeDragons)
	showHandyNotes = true,
	showBtWQuests = true, -- quêtes disponibles et objectifs de BtWQuests
	showMidnightRoutine = true, -- point de navigation de MidnightRoutine
	ping = true, -- clic gauche = ping montré aux autres clients
	zoom = 0, -- 0 à 1 : niveau de zoom gardé d'une carte à l'autre
}
ns.DEFAULTS = DEFAULTS

function ns.Settings()
	return PolypodeMapDB or DEFAULTS
end
local Settings_ = ns.Settings

local function IsSecret(value)
	return issecretvalue ~= nil and issecretvalue(value)
end
ns.IsSecret = IsSecret

local frame, canvas, header, zoneText, coordText, grip, lockButton
local hovered = false
local providers = {} -- [groupe] = { fournisseur, ... } ajoutés à la carte

-- REPÈRES DES MODULES -------------------------------------------------------------------------

-- Le moteur crée chaque repère depuis un modèle XML (CreateFramePool) ; les repères de ce module
-- et ceux de HereBeDragons n'ont pas de modèle : leur réserve est déclarée à l'avance, le cadre
-- recevant son mixin à la création (même principe que HereBeDragons-Pins sur la carte du monde).
function ns.RegisterPinPool(map, template, mixin)
	if map.pinPools[template] or not CreateUnsecuredRegionPoolInstance then
		return map.pinPools[template] ~= nil
	end
	local function Create()
		local pin = CreateFrame("Frame", nil, map:GetCanvas())
		pin:SetSize(1, 1)
		Mixin(pin, mixin)
		-- Lu par AcquirePin avant OnLoad : survol (infobulle) sans capter les clics.
		pin:SetMouseMotionEnabled(mixin.mouseMotion == true)
		pin:SetMouseClickEnabled(false)
		return pin
	end
	local function Reset(_, pin)
		local owner = pin:GetMap()
		if owner and owner.UnregisterPin then
			owner:UnregisterPin(pin)
		end
		pin:Hide()
		pin:ClearAllPoints()
		pin:OnReleased()
		pin.pinTemplate = nil
		pin:SetOwningMap(nil)
	end
	map.pinPools[template] = CreateUnsecuredRegionPoolInstance(template, Create, Reset)
	return true
end

-- CARTE ---------------------------------------------------------------------------------------

-- Niveaux de couches des repères (ordre de la carte du monde), plus ceux de ce module au-dessus
-- des membres du groupe.
local FRAME_LEVELS = {
	"PIN_FRAME_LEVEL_MAP_EXPLORATION", "PIN_FRAME_LEVEL_EVENT_OVERLAY", "PIN_FRAME_LEVEL_FOG_OF_WAR",
	"PIN_FRAME_LEVEL_QUEST_BLOB", "PIN_FRAME_LEVEL_SCENARIO_BLOB", "PIN_FRAME_LEVEL_MAP_HIGHLIGHT",
	"PIN_FRAME_LEVEL_DIG_SITE", "PIN_FRAME_LEVEL_DUNGEON_ENTRANCE", "PIN_FRAME_LEVEL_DELVE_ENTRANCE",
	"PIN_FRAME_LEVEL_FLIGHT_POINT", "PIN_FRAME_LEVEL_INVASION", "PIN_FRAME_LEVEL_PET_TAMER",
	"PIN_FRAME_LEVEL_SELECTABLE_GRAVEYARD", "PIN_FRAME_LEVEL_DRAGONRIDING_RACE", "PIN_FRAME_LEVEL_AREA_POI",
	"PIN_FRAME_LEVEL_GOSSIP", "PIN_FRAME_LEVEL_MAP_LINK", "PIN_FRAME_LEVEL_ENCOUNTER",
	{ "PIN_FRAME_LEVEL_VIGNETTE", 200 }, "PIN_FRAME_LEVEL_QUEST_OFFER", "PIN_FRAME_LEVEL_SCENARIO",
	"PIN_FRAME_LEVEL_BONUS_OBJECTIVE", { "PIN_FRAME_LEVEL_WORLD_QUEST", 500 }, "PIN_FRAME_LEVEL_AREA_POI_EVENT",
	"PIN_FRAME_LEVEL_QUEST_PING", "PIN_FRAME_LEVEL_TRACKED_CONTENT", "PIN_FRAME_LEVEL_ACTIVE_QUEST",
	"PIN_FRAME_LEVEL_SUPER_TRACKED_CONTENT", "PIN_FRAME_LEVEL_SUPER_TRACKED_QUEST",
	"PIN_FRAME_LEVEL_VEHICLE_BELOW_GROUP_MEMBER", "PIN_FRAME_LEVEL_BATTLEFIELD_FLAG",
	"PIN_FRAME_LEVEL_WAYPOINT_LOCATION", "PIN_FRAME_LEVEL_GROUP_MEMBER", "PIN_FRAME_LEVEL_POLYPODE_MEMBER",
	"PIN_FRAME_LEVEL_VEHICLE_ABOVE_GROUP_MEMBER", "PIN_FRAME_LEVEL_CORPSE", "PIN_FRAME_LEVEL_POLYPODE_PING",
	"PIN_FRAME_LEVEL_AREA_POI_BANNER",
}
-- Un niveau inconnu retombe sur le niveau par défaut ; TOPMOST (MidnightRoutine) est géré par le moteur.
table.insert(FRAME_LEVELS, 1, "PIN_FRAME_LEVEL_STORY_LINE") -- objectifs de BtWQuests, sous le reste

-- Fournisseurs de Blizzard par groupe (chacun testé : WoW Forever n'a pas tout) ; l'ordre suit la
-- carte du monde. « base » est toujours présent, les autres suivent les options.
local PROVIDER_GROUPS = {
	base = {
		"MapExplorationDataProviderMixin", "MapHighlightDataProviderMixin", "BattlefieldFlagDataProviderMixin",
		"VehicleDataProviderMixin", "EncounterJournalDataProviderMixin", "FogOfWarDataProviderMixin",
		"DeathMapDataProviderMixin", "ScenarioDataProviderMixin", "VignetteDataProviderMixin",
		"InvasionDataProviderMixin", "GossipDataProviderMixin", "FlightPointDataProviderMixin",
		"PetTamerDataProviderMixin", "DigSiteDataProviderMixin", "DungeonEntranceDataProviderMixin",
		"DelveEntranceDataProviderMixin", "MapLinkDataProviderMixin", "SelectableGraveyardDataProviderMixin",
		"AreaPOIDataProviderMixin", "AreaPOIEventDataProviderMixin", "QuestSessionDataProviderMixin",
		"DragonridingRaceDataProviderMixin",
	},
	quests = {
		"QuestOfferDataProviderMixin", "BonusObjectiveDataProviderMixin", "QuestDataProviderMixin",
		"ContentTrackingDataProviderMixin", "WaypointLocationDataProviderMixin",
		"SuperTrackWaypointDataProviderMixin",
	},
}

local function CreateProvider(mixinName)
	local mixin = _G[mixinName]
	if type(mixin) ~= "table" then
		return nil
	end
	local ok, provider = pcall(CreateFromMixins, mixin)
	return ok and provider or nil
end

local function CreateWorldQuestProvider()
	local provider = CreateProvider("WorldMap_WorldQuestDataProviderMixin")
	if provider then
		pcall(provider.SetMatchWorldMapFilters, provider, true)
		pcall(provider.SetUsesSpellEffect, provider, true)
		pcall(provider.SetCheckBounties, provider, true)
	end
	return provider
end

local function CreateGroupMembersProvider()
	local provider = CreateProvider("GroupMembersDataProviderMixin")
	if provider then
		local scale = Settings_().memberScale / 100
		provider:SetUnitPinSize("player", PLAYER_PIN_SIZE * scale)
		provider:SetUnitPinSize("party", PARTY_PIN_SIZE * scale)
		provider:SetUnitPinSize("raid", RAID_PIN_SIZE * scale)
		ns.groupMembersProvider = provider
	end
	return provider
end

-- Ajoute (wanted) ou retire les fournisseurs d'un groupe. Carte masquée pendant l'opération :
-- plusieurs fournisseurs (expéditions) démarrent un minuteur dans OnShow et l'arrêtent dans
-- OnHide, que RemoveDataProvider n'appelle pas.
local function SetProviderGroup(group, wanted, factory)
	local present = providers[group] ~= nil
	if present == (wanted == true) then
		return
	end
	local shown = canvas:IsShown()
	if shown then
		canvas:Hide()
	end
	if wanted then
		providers[group] = {}
		for _, item in ipairs(factory()) do
			local ok = pcall(canvas.AddDataProvider, canvas, item)
			if ok then
				table.insert(providers[group], item)
			end
		end
	else
		for _, item in ipairs(providers[group]) do
			pcall(canvas.RemoveDataProvider, canvas, item)
		end
		providers[group] = nil
	end
	if shown then
		canvas:Show()
	end
end

local function ProvidersFromNames(names)
	return function()
		local list = {}
		for _, name in ipairs(names) do
			list[#list + 1] = CreateProvider(name)
		end
		return list
	end
end

-- Fournisseurs optionnels selon les réglages (appelé aussi par les options et Plugins.lua).
function ns.ApplyProviders()
	if not canvas then
		return
	end
	local db = Settings_()
	SetProviderGroup("quests", db.showQuests, ProvidersFromNames(PROVIDER_GROUPS.quests))
	SetProviderGroup("worldQuests", db.showWorldQuests, function()
		return { CreateWorldQuestProvider() }
	end)
	if ns.ApplyPluginProviders then
		ns.ApplyPluginProviders(SetProviderGroup)
	end
end

-- Zoom : plus de niveaux que Blizzard (×1,25 par cran, sans dépasser la couche suivante).
local function ExtendZoomLevels(scroll)
	local baseCreate = scroll.CreateZoomLevels
	function scroll:CreateZoomLevels()
		baseCreate(self)
		local levels, extended = self.zoomLevels, {}
		for index, level in ipairs(levels) do
			extended[#extended + 1] = level
			local nextLevel = levels[index + 1]
			if not nextLevel or nextLevel.layerIndex ~= level.layerIndex then
				local count = 0
				for back = #extended, 1, -1 do
					if extended[back].layerIndex ~= level.layerIndex then
						break
					end
					count = count + 1
				end
				while count < ZOOM_STEPS_PER_LAYER do
					local scale = extended[#extended].scale * ZOOM_STEP_FACTOR
					if nextLevel and scale >= nextLevel.scale then
						break
					end
					extended[#extended + 1] = { scale = scale, layerIndex = level.layerIndex }
					count = count + 1
				end
			end
		end
		self.zoomLevels = extended
	end
end

-- Molette : zoom progressif (×1,2 par cran, pas d'un niveau à l'autre) qui garde fixe le point
-- sous le curseur, au lieu du zoom de Blizzard qui recentre la vue sur le curseur et, en zoom
-- avant, déplace la vue avant d'agrandir. Le moteur anime l'échelle ; après chacune de ses images,
-- la vue est recalée pour que le point visé reste sous le curseur (centre = p + (c0 - p) × s0 / s).
local WHEEL_ZOOM_FACTOR = 1.2
local ZOOM_LERP = 0.25 -- vitesse d'animation (Blizzard : 0,15)

local function SmoothWheelZoom(map, scroll, onZoom)
	scroll:SetScalingMode("SCALING_MODE_LINEAR")
	scroll.normalizedZoomLerpAmount = ZOOM_LERP
	scroll.normalizedPanXLerpAmount = ZOOM_LERP
	scroll.normalizedPanYLerpAmount = ZOOM_LERP
	local anchor -- { px, py, cx, cy, s0 } : point visé, centre et échelle au début du zoom

	scroll:SetScript("OnMouseWheel", function(self, delta)
		if not (self.zoomLevels and #self.zoomLevels > 0) then
			return
		end
		local minScale, maxScale = self:GetScaleForMinZoom(), self:GetScaleForMaxZoom()
		local current = self:GetCanvasScale()
		local target = Clamp((self.targetScale or current) * WHEEL_ZOOM_FACTOR ^ delta, minScale, maxScale)
		if target == self.targetScale then
			return
		end
		local px, py = self:GetNormalizedCursorPosition()
		anchor = { px = px, py = py, cx = self:GetCurrentScrollX() or 0.5, cy = self:GetCurrentScrollY() or 0.5, s0 = current }
		self:SetZoomTarget(target)
		onZoom()
	end)

	scroll:HookScript("OnUpdate", function(self)
		if not anchor or not self.currentScale then
			return
		end
		local ratio = anchor.s0 / self.currentScale
		local x = anchor.px + (anchor.cx - anchor.px) * ratio
		local y = anchor.py + (anchor.cy - anchor.py) * ratio
		local minX, maxX, minY, maxY = self:CalculateScrollExtentsAtScale(self.currentScale)
		x = minX <= maxX and Clamp(x, minX, maxX) or 0.5
		y = minY <= maxY and Clamp(y, minY, maxY) or 0.5
		self.targetScrollX, self.currentScrollX = x, x
		self.targetScrollY, self.currentScrollY = y, y
		self:SetNormalizedHorizontalScroll(x)
		self:SetNormalizedVerticalScroll(y)
		map:OnCanvasPanChanged()
		if self.currentScale == self.targetScale then
			anchor = nil
		end
	end)

	-- Glisser la vue pendant l'animation : le point visé est abandonné.
	scroll:HookScript("OnMouseDown", function()
		anchor = nil
	end)
	scroll:HookScript("OnHide", function()
		anchor = nil
	end)
end

local function PlayerMapID()
	return MapUtil and MapUtil.GetDisplayableMapForPlayer and MapUtil.GetDisplayableMapForPlayer()
end

-- Niveau de zoom gardé (0 à 1), appliqué à la carte affichée.
local function ApplyZoom()
	local scroll = canvas.ScrollContainer
	if not (scroll.zoomLevels and #scroll.zoomLevels > 0) then
		return
	end
	local scale = Lerp(scroll:GetScaleForMinZoom(), scroll:GetScaleForMaxZoom(), Settings_().zoom or 0)
	scroll:SetZoomTarget(scale)
end

local function SaveZoom()
	local scroll = canvas.ScrollContainer
	if scroll.zoomLevels and scroll.targetScale and #scroll.zoomLevels > 0 then
		local minScale, maxScale = scroll:GetScaleForMinZoom(), scroll:GetScaleForMaxZoom()
		Settings_().zoom = maxScale > minScale and PercentageBetween(scroll.targetScale, minScale, maxScale) or 0
	end
end

local function SetMap(mapID)
	if mapID and mapID ~= canvas:GetMapID() then
		canvas:SetMapID(mapID)
		ApplyZoom()
	end
end

-- Vue centrée sur le joueur (bornée aux extrémités de la carte).
local function CenterOnPlayer()
	local scroll = canvas.ScrollContainer
	if not scroll.zoomLevels then
		return
	end
	local ok, pos = pcall(C_Map.GetPlayerMapPosition, canvas:GetMapID(), "player")
	if not ok or not pos then
		return
	end
	local x, y = pos:GetXY()
	if IsSecret(x) or IsSecret(y) then
		return
	end
	local minX, maxX, minY, maxY = scroll:CalculateScrollExtentsAtScale(scroll.targetScale or scroll:GetCanvasScale())
	x = minX <= maxX and Clamp(x, minX, maxX) or 0.5
	y = minY <= maxY and Clamp(y, minY, maxY) or 0.5
	scroll:SetPanTarget(x, y)
end

local function CreateCanvas(parent)
	-- Équivalent du modèle MapCanvasFrameTemplate, construit en Lua : le conteneur défilant doit
	-- exister avant MapCanvasMixin.OnLoad.
	local map = CreateFrame("Frame", "PolypodeMapCanvas", parent)
	map:Hide()
	map:EnableMouse(true)
	local scroll = CreateFrame("ScrollFrame", nil, map, "MapCanvasFrameScrollContainerTemplate")
	scroll:ClearAllPoints()
	scroll:SetAllPoints(map)
	map.ScrollContainer = scroll
	ExtendZoomLevels(scroll)
	-- Cadre de bordure attendu par MapCanvasMixin (EvaluateLockReasons, dès OnLoad) : sur les
	-- cartes de Blizzard, il bloque la souris quand la carte est verrouillée. Transparent ici.
	local border = CreateFrame("Frame", nil, map)
	border:SetAllPoints(map)
	border:EnableMouse(false)
	map.BorderFrame = border

	Mixin(map, MapCanvasMixin)
	map:OnLoad()
	map:SetScript("OnUpdate", map.OnUpdate)
	map:SetScript("OnEvent", map.OnEvent)
	map:SetScript("OnHide", map.OnHide)
	map:SetScript("OnShow", function(self)
		local mapID = PlayerMapID() or self.mapID
		if mapID then
			self:SetMapID(mapID)
		end
		MapCanvasMixin.OnShow(self)
		ApplyZoom()
	end)

	map:SetShouldZoomInOnClick(false)
	map:SetShouldPanOnClick(false)
	map:SetShouldNavigateOnClick(false)
	map:SetShouldZoomInstantly(false)
	map:SetGlobalPinScale(Settings_().pinScale / 100)

	local levels = map:GetPinFrameLevelsManager()
	for _, level in ipairs(FRAME_LEVELS) do
		if type(level) == "table" then
			levels:AddFrameLevel(level[1], level[2])
		elseif level == "PIN_FRAME_LEVEL_ACTIVE_QUEST" and C_QuestLog and C_QuestLog.GetMaxNumQuests then
			levels:AddFrameLevel(level, C_QuestLog.GetMaxNumQuests())
		else
			levels:AddFrameLevel(level)
		end
	end

	-- Clics sur la carte (pas les glissers) : ping, point TomTom... (handlers des autres fichiers).
	map:AddCanvasClickHandler(function(_, button, cursorX, cursorY)
		for _, handler in ipairs(ns.clickHandlers) do
			if handler(button, cursorX, cursorY) then
				return true
			end
		end
		return false
	end)

	SmoothWheelZoom(map, scroll, SaveZoom)
	return map
end

ns.clickHandlers = {} -- fonctions(bouton, x, y) → true si le clic est traité ; x, y normalisés

-- Carte affichée (uiMapID).
function ns.GetMapID()
	return canvas and canvas:GetMapID()
end

-- FENÊTRE -------------------------------------------------------------------------------------

local function SavePosition()
	local db = Settings_()
	local point, _, relativePoint, x, y = frame:GetPoint(1)
	db.point, db.relativePoint, db.x, db.y = point, relativePoint, x, y
	db.width, db.height = frame:GetSize()
end

-- Couleurs du cadre : { valeur, libellé, r, g, b } ; "class" = couleur de classe du personnage joué.
local BORDER_COLORS = {
	{ "black", "Noir", 0, 0, 0 }, { "grey", "Gris", 0.5, 0.5, 0.5 }, { "white", "Blanc", 1, 1, 1 },
	{ "gold", "Doré", 1, 0.82, 0 }, { "blue", "Bleu", 0.3, 0.65, 1 }, { "class", "Couleur de classe" },
}

local function BorderColor()
	local value = Settings_().borderColor
	if value == "class" then
		local _, class = UnitClass("player")
		local color = class and (C_ClassColor and C_ClassColor.GetClassColor(class) or RAID_CLASS_COLORS[class])
		if color then
			return color.r, color.g, color.b
		end
	end
	for _, choice in ipairs(BORDER_COLORS) do
		if choice[1] == value and choice[3] then
			return choice[3], choice[4], choice[5]
		end
	end
	return 0, 0, 0
end

-- Cadre de la carte : bordure de borderSize pixels (0 = aucune) ; carte, en-tête et poignée
-- posés à l'intérieur.
local function ApplyBorder()
	local size = Settings_().borderSize or 1
	frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
		edgeFile = size > 0 and "Interface\\Buttons\\WHITE8x8" or nil, edgeSize = size })
	frame:SetBackdropColor(0, 0, 0, 0.6)
	frame:SetBackdropBorderColor(BorderColor())
	canvas:ClearAllPoints()
	canvas:SetPoint("TOPLEFT", size, -size)
	canvas:SetPoint("BOTTOMRIGHT", -size, size)
	header:ClearAllPoints()
	header:SetPoint("TOPLEFT", size, -size)
	header:SetPoint("TOPRIGHT", -size, -size)
	grip:ClearAllPoints()
	grip:SetPoint("BOTTOMRIGHT", -size, size)
end

local function ApplyLayout()
	local db = Settings_()
	ApplyBorder()
	frame:SetScale(db.scale / 100)
	frame:SetSize(Clamp(db.width, MIN_WIDTH, MAX_WIDTH), Clamp(db.height, MIN_HEIGHT, MAX_HEIGHT))
	frame:ClearAllPoints()
	frame:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y)
	frame:SetFrameStrata(db.strata)
	header:SetFrameLevel(frame:GetFrameLevel() + 5000)
	grip:SetFrameLevel(frame:GetFrameLevel() + 5000)
	canvas:SetGlobalPinScale(db.pinScale / 100)
	canvas:OnFrameSizeChanged()
	ApplyZoom()
end
ns.ApplyLayout = function()
	if frame then
		ApplyLayout()
	end
end

local function UpdateLockButton()
	local locked = Settings_().locked
	lockButton:SetNormalTexture(locked and "Interface\\Buttons\\LockButton-Locked-Up"
		or "Interface\\Buttons\\LockButton-Unlocked-Up")
	grip:SetShown(hovered and not locked)
end

function ns.SetLocked(locked)
	Settings_().locked = locked
	if frame then
		UpdateLockButton()
	end
end

-- Couleur du nom de zone selon le statut JcJ (comme la carte de zone).
local PVP_COLORS = {
	sanctuary = { 0.41, 0.8, 0.94 }, arena = { 1, 0.1, 0.1 }, friendly = { 0.1, 1, 0.1 },
	hostile = { 1, 0.1, 0.1 }, contested = { 1, 0.7, 0 },
}

local function UpdateZoneText()
	local text = GetMinimapZoneText and GetMinimapZoneText() or ""
	local mapID = canvas:GetMapID()
	if mapID ~= PlayerMapID() then
		local info = mapID and C_Map.GetMapInfo(mapID)
		text = info and info.name or text
	end
	zoneText:SetText(text)
	local getPvPInfo = C_PvP and C_PvP.GetZonePVPInfo or GetZonePVPInfo
	local pvpType = getPvPInfo and getPvPInfo()
	local color = mapID == PlayerMapID() and PVP_COLORS[pvpType or ""] or { 1, 0.82, 0 }
	zoneText:SetTextColor(color[1], color[2], color[3])
end

local function FormatCoords(x, y)
	return string.format("%.1f, %.1f", x * 100, y * 100)
end

local function UpdateCoords()
	if hovered and canvas.ScrollContainer.zoomLevels then
		local x, y = canvas.ScrollContainer:GetNormalizedCursorPosition()
		coordText:SetText("|cff8cc8ff" .. FormatCoords(x, y) .. "|r")
		return
	end
	local ok, pos = pcall(C_Map.GetPlayerMapPosition, canvas:GetMapID(), "player")
	local x, y
	if ok and pos then
		x, y = pos:GetXY()
	end
	if x and not IsSecret(x) and not IsSecret(y) then
		coordText:SetText(FormatCoords(x, y))
	else
		coordText:SetText("")
	end
end

local function UpdateHover(isOver)
	hovered = isOver
	local db = Settings_()
	frame:SetAlpha(hovered and 1 or db.opacity / 100)
	header:SetShown(hovered or db.headerAlways)
	grip:SetShown(hovered and not db.locked)
	if hovered then
		UpdateZoneText()
	end
end
ns.RefreshHover = function()
	if frame then
		UpdateHover(hovered)
	end
end

local function ShowOptions(owner)
	if P.ToggleOptionsPopup and ns.settingsPopup then
		P.ToggleOptionsPopup(owner, ns.settingsPopup)
	elseif ns.settingsCategory and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(ns.settingsCategory:GetID())
	end
end

local function ShowHeaderTooltip(owner)
	GameTooltip:SetOwner(owner, "ANCHOR_TOP")
	GameTooltip:AddLine("Polypode Map")
	GameTooltip:AddLine("Glisser l'en-tête : déplacer la carte (sauf si elle est figée)", 1, 1, 1, true)
	GameTooltip:AddLine("Clic gauche sur l'en-tête : ajuster le cadre aux proportions de la carte affichée",
		1, 1, 1, true)
	GameTooltip:AddLine("Clic droit sur l'en-tête : options", 1, 1, 1, true)
	GameTooltip:AddLine("Molette : zoom ; glisser sur la carte : déplacer la vue", 1, 1, 1, true)
	if Settings_().ping then
		GameTooltip:AddLine("Clic sur la carte : ping montré aux autres personnages", 1, 1, 1, true)
	end
	if TomTom and TomTom.AddWaypoint then
		GameTooltip:AddLine("Alt + clic droit sur la carte : point TomTom", 1, 1, 1, true)
	end
	if P.ShowTooltip then
		P.ShowTooltip()
	else
		GameTooltip:Show()
	end
end

local function Build()
	frame = CreateFrame("Frame", "PolypodeMapFrame", UIParent, "BackdropTemplate")
	frame:Hide()
	frame:SetMovable(true)
	frame:SetResizable(true)
	frame:SetClampedToScreen(true)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)
	end
	-- Cadre (bordure) posé par ApplyBorder, depuis ApplyLayout.

	canvas = CreateCanvas(frame)
	canvas:SetPoint("TOPLEFT", 1, -1)
	canvas:SetPoint("BOTTOMRIGHT", -1, 1)
	ns.canvas = canvas

	-- En-tête posé sur la carte (aucune place perdue), affiché au survol.
	header = CreateFrame("Frame", nil, frame)
	header:SetPoint("TOPLEFT", 1, -1)
	header:SetPoint("TOPRIGHT", -1, -1)
	header:SetHeight(HEADER_HEIGHT)
	header:EnableMouse(true)
	header:RegisterForDrag("LeftButton")
	local background = header:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	background:SetColorTexture(0, 0, 0, 0.65)
	header:SetScript("OnDragStart", function(self)
		self.dragged = true -- le relâchement qui suit n'est pas un clic
		if not Settings_().locked then
			frame:StartMoving()
		end
	end)
	header:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		SavePosition()
	end)
	header:SetScript("OnMouseDown", function(self)
		self.dragged = false
	end)
	header:SetScript("OnMouseUp", function(self, button)
		if button == "RightButton" then
			ShowOptions(self)
		elseif button == "LeftButton" and not self.dragged then
			ns.FitToMap()
		end
		self.dragged = false
	end)
	header:SetScript("OnEnter", ShowHeaderTooltip)
	header:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	local close = CreateFrame("Button", nil, header, "UIPanelCloseButton")
	close:SetSize(20, 20)
	close:SetPoint("RIGHT", 2, 0)
	close:SetScript("OnClick", function()
		P.ToggleMap(false)
	end)

	lockButton = CreateFrame("Button", nil, header)
	lockButton:SetSize(14, 14)
	lockButton:SetPoint("RIGHT", close, "LEFT", 0, 0)
	lockButton:SetScript("OnClick", function()
		ns.SetLocked(not Settings_().locked)
	end)
	lockButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(Settings_().locked and "Carte figée" or "Carte libre")
		GameTooltip:AddLine("Clic : figer / libérer (déplacement et taille)", 1, 1, 1, true)
		if P.ShowTooltip then
			P.ShowTooltip()
		else
			GameTooltip:Show()
		end
	end)
	lockButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	coordText = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	coordText:SetPoint("RIGHT", lockButton, "LEFT", -4, 0)
	coordText:SetJustifyH("RIGHT")
	zoneText = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	zoneText:SetPoint("LEFT", 5, 0)
	zoneText:SetPoint("RIGHT", coordText, "LEFT", -6, 0)
	zoneText:SetJustifyH("LEFT")
	zoneText:SetWordWrap(false)

	-- Poignée de redimensionnement (bas-droite), affichée au survol si la carte n'est pas figée.
	grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -1, 1)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetScript("OnMouseDown", function()
		if not Settings_().locked then
			frame:StartSizing("BOTTOMRIGHT")
		end
	end)
	grip:SetScript("OnMouseUp", function()
		frame:StopMovingOrSizing()
		SavePosition()
		canvas:OnFrameSizeChanged() -- niveaux de zoom recalculés pour la nouvelle taille
		ApplyZoom()
	end)

	-- Survol, coordonnées et suivi du joueur.
	local elapsedTick, elapsedFollow = 0, 0
	frame:SetScript("OnUpdate", function(_, elapsed)
		elapsedTick = elapsedTick + elapsed
		if elapsedTick < TICK then
			return
		end
		elapsedFollow = elapsedFollow + elapsedTick
		elapsedTick = 0
		local isOver = frame:IsMouseOver()
		if isOver ~= hovered then
			UpdateHover(isOver)
		end
		if header:IsShown() then
			UpdateCoords()
		end
		if elapsedFollow >= FOLLOW_INTERVAL then
			elapsedFollow = 0
			if Settings_().followPlayer and not hovered then
				local before = canvas:GetMapID()
				SetMap(PlayerMapID())
				if before ~= canvas:GetMapID() and header:IsShown() then
					UpdateZoneText()
				end
				CenterOnPlayer()
			end
		end
	end)

	-- Fournisseurs de Blizzard, puis ceux des réglages, puis ceux des autres fichiers : ajoutés
	-- carte masquée (avant le premier affichage).
	providers.base = {}
	for _, name in ipairs(PROVIDER_GROUPS.base) do
		local provider = CreateProvider(name)
		if provider and pcall(canvas.AddDataProvider, canvas, provider) then
			table.insert(providers.base, provider)
		end
	end
	local labels = CreateProvider("AreaLabelDataProviderMixin") -- nom des sous-zones au survol
	if labels then
		pcall(labels.SetOffsetY, labels, -10)
		if pcall(canvas.AddDataProvider, canvas, labels) then
			table.insert(providers.base, labels)
		end
	end
	local group = CreateGroupMembersProvider() -- flèche du joueur, points du groupe
	if group and pcall(canvas.AddDataProvider, canvas, group) then
		table.insert(providers.base, group)
	end
	if ns.InitMembers then
		ns.InitMembers(canvas)
	end
	ns.ApplyProviders()
	if ns.InitPlugins then
		ns.InitPlugins(canvas)
	end

	-- Option autoFit : chaque changement de carte (zone, suivi du joueur, lien de carte) ajuste le
	-- cadre, à l'image suivante (la carte finit de se mettre en place dans SetMapID).
	local fitPending = false
	hooksecurefunc(canvas, "OnMapChanged", function()
		if not Settings_().autoFit or fitPending then
			return
		end
		fitPending = true
		C_Timer.After(0, function()
			fitPending = false
			ns.FitToMap()
		end)
	end)

	ApplyLayout()
	UpdateLockButton()
	UpdateHover(false)
	canvas:Show()
	P.ui.mapFrame = frame
end

-- Cadre ajusté aux proportions de la carte affichée (clic gauche sur l'en-tête) : largeur gardée,
-- hauteur recalculée ; si elle sort des bornes, c'est la largeur qui s'adapte. Rien si la carte
-- est figée. Vue dézoomée, la carte remplit alors tout le cadre.
function ns.FitToMap()
	if not (frame and canvas) or Settings_().locked then
		return
	end
	local layers = C_Map.GetMapArtLayers(canvas:GetMapID())
	local layer = layers and layers[1]
	if not (layer and layer.layerWidth and layer.layerWidth > 0 and layer.layerHeight > 0) then
		return
	end
	local ratio = layer.layerHeight / layer.layerWidth
	local border = 2 * (Settings_().borderSize or 1) -- cadre des deux côtés
	local width = frame:GetWidth()
	local height = (width - border) * ratio + border
	if height < MIN_HEIGHT or height > MAX_HEIGHT then
		height = Clamp(height, MIN_HEIGHT, MAX_HEIGHT)
		width = Clamp((height - border) / ratio + border, MIN_WIDTH, MAX_WIDTH)
	end
	frame:SetSize(width, height)
	SavePosition()
	canvas:OnFrameSizeChanged() -- niveaux de zoom recalculés pour la nouvelle taille
	ApplyZoom()
end

-- Taille des repères du groupe (Blizzard) et de ceux de Polypode.
function ns.ApplyMemberScale()
	local provider = ns.groupMembersProvider
	if provider then
		local scale = Settings_().memberScale / 100
		provider:SetUnitPinSize("player", PLAYER_PIN_SIZE * scale)
		provider:SetUnitPinSize("party", PARTY_PIN_SIZE * scale)
		provider:SetUnitPinSize("raid", RAID_PIN_SIZE * scale)
		if provider.pin then
			provider.pin:SynchronizePinSizes()
		end
	end
	if ns.RefreshMembers then
		ns.RefreshMembers()
	end
end

-- Affiche / masque la carte (bouton « Map », /poly map) ; show nil = bascule.
local built = false
function P.ToggleMap(show)
	if not built then
		-- Construction précédente interrompue par une erreur : cadre vide écarté, on recommence.
		if frame then
			frame:Hide()
			frame = nil
		end
		Build()
		built = true
	end
	if show == nil then
		show = not frame:IsShown()
	end
	Settings_().shown = show
	frame:SetShown(show)
end

-- OPTIONS -------------------------------------------------------------------------------------

local function BuildSettingsPanel()
	if not (Settings and Settings.RegisterProxySetting) then
		return
	end
	local category
	if P.optionsCategory and Settings.RegisterVerticalLayoutSubcategory then
		category = Settings.RegisterVerticalLayoutSubcategory(P.optionsCategory, "Map")
	else
		category = Settings.RegisterVerticalLayoutCategory("Polypode Map")
	end
	-- Chaque réglage est aussi rappelé dans la petite fenêtre du clic droit (P.ToggleOptionsPopup).
	local popupItems = {}
	local function Color(text)
		return P.ColorClicks and P.ColorClicks(text) or text
	end
	local function Register(field, varType, label, onChange)
		return Settings.RegisterProxySetting(category, "POLYPODE_MAP_" .. field:upper(), varType, label,
			DEFAULTS[field],
			function()
				return Settings_()[field]
			end,
			function(value)
				Settings_()[field] = value
				if onChange then
					onChange(value)
				end
			end)
	end
	local function AddCheck(field, label, tooltip, onChange)
		local setting = Register(field, Settings.VarType.Boolean, label, onChange)
		tooltip = Color(tooltip)
		Settings.CreateCheckbox(category, setting, tooltip)
		popupItems[#popupItems + 1] = { kind = "check", setting = setting, tooltip = tooltip }
	end
	local function PercentText(value)
		return string.format("%d %%", value)
	end
	-- formatter : texte de la valeur (pourcentage par défaut).
	local function AddSlider(field, label, min, max, step, tooltip, onChange, formatter)
		formatter = formatter or PercentText
		local setting = Register(field, Settings.VarType.Number, label, onChange)
		tooltip = Color(tooltip)
		local options = Settings.CreateSliderOptions(min, max, step)
		if MinimalSliderWithSteppersMixin then
			options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, formatter)
		end
		Settings.CreateSlider(category, setting, options, tooltip)
		popupItems[#popupItems + 1] = { kind = "slider", setting = setting, min = min, max = max, step = step,
			format = formatter, tooltip = tooltip }
	end
	local function AddDropdown(field, label, values, tooltip, onChange)
		local setting = Register(field, Settings.VarType.String, label, onChange)
		tooltip = Color(tooltip)
		Settings.CreateDropdown(category, setting, function()
			local container = Settings.CreateControlTextContainer()
			for _, value in ipairs(values) do
				container:Add(value[1], value[2])
			end
			return container:GetData()
		end, tooltip)
		popupItems[#popupItems + 1] = { kind = "dropdown", setting = setting, values = values, tooltip = tooltip }
	end

	AddCheck("shown", "Afficher la carte",
		"Petite carte de zone permanente. Même effet que le bouton « Map » de Polypode et /poly map.",
		function(value)
			P.ToggleMap(value)
		end)
	AddCheck("locked", "Figer la carte",
		"Empêche de déplacer (glisser l'en-tête) et de redimensionner (poignée bas-droite) la carte. "
		.. "Même effet que le cadenas de l'en-tête.",
		function(value)
			ns.SetLocked(value)
		end)
	AddCheck("followPlayer", "Suivre le joueur",
		"Quand la souris n'est pas sur la carte : affiche la carte de votre zone, centrée sur vous.")
	AddCheck("autoFit", "Ajuster le cadre à chaque carte",
		"À chaque changement de carte (zone, suivi du joueur, lien de carte), le cadre prend les proportions "
		.. "de la nouvelle carte, comme au clic gauche sur l'en-tête : largeur gardée, hauteur recalculée. "
		.. "Sans effet si la carte est figée.",
		function(value)
			if value then
				ns.FitToMap()
			end
		end)
	AddCheck("headerAlways", "En-tête toujours visible",
		"Affiche en permanence le nom de la zone et vos coordonnées en haut de la carte (sinon : au survol).",
		ns.RefreshHover)
	AddSlider("opacity", "Opacité hors survol", 10, 100, 5,
		"Opacité de la carte quand la souris n'est pas dessus (100 % = opaque).", ns.RefreshHover)
	AddSlider("scale", "Taille de la fenêtre", 50, 200, 5,
		"Échelle de toute la fenêtre de la carte.", ns.ApplyLayout)
	AddSlider("borderSize", "Épaisseur du cadre", 0, 10, 1,
		"Cadre autour de la carte, en pixels (0 = aucun, 1 = fin trait noir par défaut).", ns.ApplyLayout,
		function(value)
			return string.format("%d px", value)
		end)
	local borderValues = {}
	for _, choice in ipairs(BORDER_COLORS) do
		borderValues[#borderValues + 1] = { choice[1], choice[2] }
	end
	AddDropdown("borderColor", "Couleur du cadre", borderValues,
		"Couleur du cadre autour de la carte (avec une épaisseur d'au moins 1 pixel).", ns.ApplyLayout)
	AddSlider("pinScale", "Taille des icônes", 30, 150, 5,
		"Taille des icônes de Blizzard sur la carte (quêtes, points d'intérêt, maîtres de vol...).",
		ns.ApplyLayout)
	AddSlider("memberScale", "Taille des personnages", 50, 250, 10,
		"Taille de votre flèche, des points du groupe et des repères des personnages de Polypode.",
		ns.ApplyMemberScale)
	AddCheck("showNames", "Noms des personnages",
		"Affiche le nom de chaque personnage de Polypode au-dessus de son repère.",
		function()
			if ns.RefreshMembers then
				ns.RefreshMembers()
			end
		end)
	AddCheck("showAll", "Tous les personnages",
		"Montre tous les personnages du roster de Polypode, et non seulement ceux de l'équipe sélectionnée.",
		function()
			if ns.RefreshMembers then
				ns.RefreshMembers()
			end
		end)
	AddCheck("showQuests", "Quêtes",
		"Quêtes en cours, quêtes disponibles, objectifs bonus et contenu suivi.", ns.ApplyProviders)
	AddCheck("showWorldQuests", "Expéditions", "Expéditions (quêtes mondiales) de la zone.", ns.ApplyProviders)
	AddCheck("showHereBeDragons", "Points TomTom",
		"Points de TomTom (et des autres addons qui passent par HereBeDragons) sur la carte. "
		.. "Alt + clic droit sur la carte : nouveau point TomTom.", ns.ApplyProviders)
	AddCheck("showHandyNotes", "HandyNotes", "Notes des modules de HandyNotes, si l'addon est installé.",
		ns.ApplyProviders)
	AddCheck("showBtWQuests", "BtWQuests",
		"Quêtes disponibles des chaînes de BtWQuests et objectifs des quêtes suivies, si l'addon est installé "
		.. "(ses propres options d'affichage sur la carte restent valables). Clic sur un repère : point de navigation.",
		ns.ApplyProviders)
	AddCheck("showMidnightRoutine", "MidnightRoutine",
		"Point de navigation de la routine en cours de MidnightRoutine, si l'addon est installé.", ns.ApplyProviders)
	AddCheck("ping", "Ping au clic",
		"Clic sur la carte : signal animé à cet endroit, montré aussi sur la carte des autres personnages "
		.. "(qui ont Polypode Map).")
	AddDropdown("strata", "Plan de la fenêtre", {
		{ "FULLSCREEN_DIALOG", "7 - Plein écran (dialogue)" }, { "FULLSCREEN", "6 - Plein écran" },
		{ "DIALOG", "5 - Dialogue (défaut)" }, { "HIGH", "4 - Haut" }, { "MEDIUM", "3 - Moyen" },
		{ "LOW", "2 - Bas" }, { "BACKGROUND", "1 - Arrière-plan" },
	}, "Plan d'affichage de la carte par rapport au reste de l'interface, du plus haut (7) au plus bas (1). "
		.. "Par défaut « Dialogue » : devant les barres d'action et la plupart des fenêtres ; descendre si la "
		.. "carte cache quelque chose. Au-dessus de « Dialogue », elle peut passer devant les menus.",
		ns.ApplyLayout)

	Settings.RegisterAddOnCategory(category)
	ns.settingsCategory = category
	ns.settingsPopup = { key = "Map", title = "Options de la carte", items = popupItems, category = category }
end

-- INTÉGRATION À POLYPODE ----------------------------------------------------------------------

if P.AddTitleButton then
	P.AddTitleButton({
		text = "Map",
		width = 50,
		rightClick = true,
		onClick = function(button, mouseButton)
			if mouseButton == "RightButton" then
				ShowOptions(button)
			elseif IsShiftKeyDown() then
				ns.ResetMap()
			else
				P.ToggleMap()
			end
		end,
		tooltip = {
			"Polypode Map",
			"Clic gauche : afficher / masquer la petite carte de zone (personnages de l'équipe, quêtes, TomTom).",
			"Maj + clic gauche : recentrer la carte (position, taille et plan par défaut), comme /poly map reset",
			"Clic droit : options de la carte",
		},
		onCreate = function(button)
			P.ui.mapButton = button
		end,
	})
end

-- Carte remise au centre de l'écran, à sa taille et à son plan par défaut, et affichée.
function ns.ResetMap()
	local db = Settings_()
	for _, field in ipairs({ "point", "relativePoint", "x", "y", "width", "height", "scale", "strata" }) do
		db[field] = DEFAULTS[field]
	end
	db.point, db.relativePoint, db.x, db.y = "CENTER", "CENTER", 0, 0
	db.locked = false
	P.ToggleMap(true)
	ApplyLayout()
	UpdateLockButton()
end

-- /poly map : bascule ; /poly map reset : carte recentrée.
local function SlashMap(args)
	if args and args[1] and args[1]:lower() == "reset" then
		ns.ResetMap()
	else
		P.ToggleMap()
	end
end

if P.RegisterSlashCommand then
	P.RegisterSlashCommand("map", SlashMap, "afficher / masquer la petite carte de zone (map reset : la recentrer)")
	P.RegisterSlashCommand("carte", SlashMap) -- alias
end

-- Équipe sélectionnée, roster changés : les repères suivent.
if P.RefreshUI then
	hooksecurefunc(P, "RefreshUI", function()
		if ns.RefreshMembers then
			ns.RefreshMembers()
		end
	end)
end

-- ÉVÉNEMENTS ----------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:RegisterEvent("ZONE_CHANGED")
events:RegisterEvent("ZONE_CHANGED_INDOORS")
events:SetScript("OnEvent", function(_, event, addonName)
	if event == "ADDON_LOADED" then
		if addonName == ADDON_NAME then
			PolypodeMapDB = PolypodeMapDB or {}
			for key, value in pairs(DEFAULTS) do
				if PolypodeMapDB[key] == nil then
					PolypodeMapDB[key] = value
				end
			end
			-- 1.2.0 : plan par défaut passé de « Bas » à « Dialogue », repris une fois.
			if not PolypodeMapDB.strataDialog then
				PolypodeMapDB.strata = DEFAULTS.strata
				PolypodeMapDB.strataDialog = true
			end
		end
	elseif event == "PLAYER_LOGIN" then
		C_Timer.After(0, BuildSettingsPanel) -- Polypode crée P.optionsCategory à son PLAYER_LOGIN
		if Settings_().shown then
			P.ToggleMap(true)
		end
	elseif frame and frame:IsShown() then
		-- Nouvelle zone : carte du joueur (même sans suivi), nom de zone à jour.
		if event ~= "ZONE_CHANGED" and event ~= "ZONE_CHANGED_INDOORS" then
			SetMap(PlayerMapID())
		end
		UpdateZoneText()
	end
end)
