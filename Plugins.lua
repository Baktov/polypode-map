-- Polypode Map: Plugins — repères d'autres addons sur la carte (TomTom / HereBeDragons, HandyNotes, Naowh Forever...)

local _, ns = ...

-- Chaque intégration est facultative : rien ne se passe si l'addon manque.
--   * HereBeDragons-Pins (librairie embarquée par TomTom, entre autres) : ses repères de la carte du
--     monde sont des icônes uniques (un seul parent à la fois). Un fournisseur copié du sien
--     (même code, pointé sur notre carte) les reprend quand la carte du monde est fermée ; elle les
--     récupère d'elle-même à son ouverture, et nous les rendons à sa fermeture.
--   * TomTom : Alt + clic droit sur la carte = nouveau point à cet endroit.
--   * HandyNotes : son fournisseur de carte du monde (HandyNotes.WorldMapDataProvider), copié.
--   * Naowh Forever : chemin du trajet en cours (Journeys), redessiné par notre propre repère.
-- RareScanner (12.1) n'est pas repris : ses repères sont liés en dur à la carte du monde
-- (RSWorldMap) ; les rares visibles en jeu restent montrés par les vignettes de Blizzard.

local HBD_TEMPLATE = "HereBeDragonsPinsTemplate"

local hbdFactory, handyNotesFactory -- fonctions → { fournisseur } (nil : addon absent)

-- HEREBEDRAGONS (TOMTOM) ----------------------------------------------------------------------

local function SetupHereBeDragons(map)
	if not LibStub then
		return
	end
	local ok, pins = pcall(LibStub, "HereBeDragons-Pins-2.0", true)
	if not ok or type(pins) ~= "table" or not pins.worldmapProvider or not pins.worldmapProviderPin then
		return
	end
	if not ns.RegisterPinPool(map, HBD_TEMPLATE, pins.worldmapProviderPin) then
		return
	end
	-- Copie prise avant les accroches ci-dessous : nos rafraîchissements ne les déclenchent pas.
	local template = CreateFromMixins(pins.worldmapProvider)
	local current

	local pending = false
	local function RefreshSoon()
		if pending then
			return
		end
		pending = true
		C_Timer.After(0, function()
			pending = false
			if current and current:GetMap() and map:IsVisible() and not (WorldMapFrame and WorldMapFrame:IsShown()) then
				pcall(current.RefreshAllData, current)
			end
		end)
	end
	-- Un point ajouté ou retiré passe par le fournisseur de la carte du monde, même fermée (qui
	-- prend alors l'icône) : nous la reprenons à l'image suivante.
	for _, method in ipairs({ "RefreshAllData", "HandlePin", "RemovePinByIcon", "RemovePinsByRef" }) do
		if type(pins.worldmapProvider[method]) == "function" then
			hooksecurefunc(pins.worldmapProvider, method, RefreshSoon)
		end
	end
	if WorldMapFrame then
		WorldMapFrame:HookScript("OnHide", RefreshSoon)
	end
	map:HookScript("OnShow", RefreshSoon)

	hbdFactory = function()
		current = CreateFromMixins(template)
		return { current }
	end
end

-- Alt + clic droit sur la carte : point TomTom à cet endroit (clic droit seul en interface
-- manette, ns.IsGamepad de Map.lua).
local function OnTomTomClick(button, cursorX, cursorY)
	if button ~= "RightButton" or not (IsAltKeyDown() or ns.IsGamepad()) or not (TomTom and TomTom.AddWaypoint) then
		return false
	end
	local mapID = ns.GetMapID()
	if not mapID then
		return false
	end
	pcall(TomTom.AddWaypoint, TomTom, mapID, cursorX, cursorY, {
		title = string.format("%.1f, %.1f", cursorX * 100, cursorY * 100),
		from = "Polypode Map",
	})
	return true
end

-- HANDYNOTES ----------------------------------------------------------------------------------

local function SetupHandyNotes()
	local handyNotes = _G.HandyNotes
	if type(handyNotes) ~= "table" or type(handyNotes.WorldMapDataProvider) ~= "table" then
		return
	end
	local template = handyNotes.WorldMapDataProvider
	local current
	local function Refresh(_, pluginName)
		if current and current:GetMap() then
			if pluginName and current.RefreshPlugin then
				pcall(current.RefreshPlugin, current, pluginName)
			else
				pcall(current.RefreshAllData, current)
			end
		end
	end
	if type(handyNotes.UpdateWorldMapPlugin) == "function" then
		hooksecurefunc(handyNotes, "UpdateWorldMapPlugin", Refresh)
	end
	if type(handyNotes.UpdateWorldMap) == "function" then
		hooksecurefunc(handyNotes, "UpdateWorldMap", function()
			Refresh()
		end)
	end
	handyNotesFactory = function()
		current = CreateFromMixins(template)
		return { current }
	end
end

-- NAOWH FOREVER (JOURNEYS) --------------------------------------------------------------------

-- Chemin du trajet en cours de Naowh Forever (module Journeys de NaowhForever_Utilities, WoW
-- Forever), en pointillés comme sur sa carte du monde : la marche depuis le joueur, puis chaque
-- étape (vol, bateau, portail...) de sa couleur. Son fournisseur est local à son fichier : on
-- reprend ce qu'il publie dans NaowhForever.Journeys (Guide.Points, World.Player, RouteDots,
-- RouteTint) et on dessine sur notre propre repère. Le point de navigation de l'étape est celui du
-- jeu, déjà montré par la carte. Redessiné à chaque changement du trajet, au zoom, et toutes les
-- NAOWH_TICK secondes (le joueur avance) quand un trajet est en cours.
local NAOWH_TEMPLATE = "PolypodeMapNaowhRoutePinTemplate"
local NAOWH_WALK_SIZE, NAOWH_LEG_SIZE = 5, 4 -- pixels à l'écran (tailles de sa mini-carte)
local NAOWH_WALK_GAP, NAOWH_LEG_GAP = 10, 9
local NAOWH_WALK_ALPHA, NAOWH_LEG_ALPHA = 0.95, 0.6
local NAOWH_ACCENT = { r = 0, g = 0.57, b = 0.93 } -- bleu de Naowh, si son thème manque
local NAOWH_TICK = 0.5 -- secondes

local naowhFactory

local function SetupNaowhRoute()
	local naowh = _G.NaowhForever
	local journeys = type(naowh) == "table" and naowh.Journeys
	if type(journeys) ~= "table" or type(journeys.On) ~= "function" or type(journeys.RouteDots) ~= "function"
		or type(journeys.Guide) ~= "table" or type(journeys.Guide.Points) ~= "function"
		or type(journeys.World) ~= "table" or type(journeys.World.Player) ~= "function" then
		return
	end
	local guide, world = journeys.Guide, journeys.World
	local tints = type(journeys.RouteTint) == "table" and journeys.RouteTint or {}
	local style = type(naowh.Shared) == "table" and naowh.Shared.Style
	local dotTexture = type(style) == "table" and style.ROUND
	local accent = type(naowh.THEME) == "table" and naowh.THEME.accent or NAOWH_ACCENT

	-- Points du trajet (coordonnées du monde) : le joueur, puis ceux de Naowh ; nil sans trajet.
	local function CollectPoints()
		local ahead = guide.Points()
		if not ahead then
			return nil
		end
		local list = {}
		local here = world.Player()
		if here then
			list[1] = { c = here.c, x = here.x, y = here.y, walk = true }
		end
		for _, point in ipairs(ahead) do
			list[#list + 1] = point
		end
		return list
	end

	local pinMixin = CreateFromMixins(MapCanvasPinMixin)
	pinMixin.SetPassThroughButtons = function() end -- aucun clic (combat), comme nos autres repères
	pinMixin.CheckMouseButtonPassthrough = function() end

	function pinMixin:OnLoad()
		self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
		self:SetIgnoreGlobalPinScale(true)
		self.dots = {}
		self.count = 0
		self.place = function(x, y)
			self:Place(x, y)
		end
	end

	function pinMixin:Place(x, y)
		self.count = self.count + 1
		local dot = self.dots[self.count]
		if not dot then
			dot = self:CreateTexture(nil, "OVERLAY")
			if dotTexture then
				dot:SetTexture(dotTexture, nil, nil, "TRILINEAR")
			else
				dot:SetAtlas("WhiteCircle-RaidBlips")
			end
			self.dots[self.count] = dot
		end
		dot:ClearAllPoints()
		dot:SetPoint("CENTER", self, "TOPLEFT", x, -y)
		dot:SetSize(self.size, self.size)
		local tint = self.tint
		if tint then
			dot:SetVertexColor(tint[1], tint[2], tint[3], self.alpha)
		else
			dot:SetVertexColor(accent.r, accent.g, accent.b, self.alpha)
		end
		dot:Show()
	end

	-- Le repère couvre toute la carte ; ses points gardent la même taille à l'écran quel que soit le zoom.
	function pinMixin:DrawDots()
		local map = self:GetMap()
		local mapID = map and map:GetMapID()
		local list = mapID and CollectPoints()
		if not list then
			return
		end
		local w, h = map:GetCanvas():GetSize()
		self:SetSize(w, h)
		self:SetPosition(0.5, 0.5)
		local continent = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0.5, 0.5))
		local scale = 1 / map:GetCanvasScale()
		local last, carry
		for _, point in ipairs(list) do
			local u, v
			if continent and point.c == continent then
				local _, pos = C_Map.GetMapPosFromWorldPos(point.c, CreateVector2D(point.x, point.y), mapID)
				if pos then
					u, v = pos.x, pos.y
				end
			end
			if u and last then
				self.size = (point.walk and NAOWH_WALK_SIZE or NAOWH_LEG_SIZE) * scale
				self.alpha = point.walk and NAOWH_WALK_ALPHA or NAOWH_LEG_ALPHA
				self.tint = not point.walk and tints[point.mode] or nil
				carry = journeys.RouteDots(last[1] * w, last[2] * h, u * w, v * h,
					(point.walk and NAOWH_WALK_GAP or NAOWH_LEG_GAP) * scale, carry, self.place)
			else
				carry = nil
			end
			last = u and { u, v } or nil
		end
	end

	function pinMixin:Draw()
		self.count = 0
		pcall(self.DrawDots, self) -- code de Naowh et positions (instances) : jamais d'erreur ici
		for i = self.count + 1, #self.dots do
			self.dots[i]:Hide()
		end
	end

	function pinMixin:OnAcquired()
		self:Draw()
	end

	function pinMixin:OnCanvasScaleChanged()
		self:Draw()
	end

	local providerMixin = CreateFromMixins(MapCanvasDataProviderMixin)

	function providerMixin:OnAdded(map)
		MapCanvasDataProviderMixin.OnAdded(self, map)
		ns.RegisterPinPool(map, NAOWH_TEMPLATE, pinMixin)
		self.ticker = C_Timer.NewTicker(NAOWH_TICK, function()
			local owner = self:GetMap()
			if self.pin and owner and owner:IsVisible() then
				self.pin:Draw()
			end
		end)
	end

	function providerMixin:OnRemoved(map)
		if self.ticker then
			self.ticker:Cancel()
			self.ticker = nil
		end
		MapCanvasDataProviderMixin.OnRemoved(self, map)
	end

	function providerMixin:RemoveAllData()
		self.pin = nil
		local map = self:GetMap()
		if map then
			map:RemoveAllPinsByTemplate(NAOWH_TEMPLATE)
		end
	end

	function providerMixin:RefreshAllData()
		self:RemoveAllData()
		local map = self:GetMap()
		local ok, on = pcall(journeys.On)
		local okCurrent, journey = pcall(guide.Current)
		if map and ok and on and okCurrent and journey then
			self.pin = map:AcquirePin(NAOWH_TEMPLATE)
		end
	end

	local current
	local function Refresh()
		if current and current:GetMap() then
			pcall(current.RefreshAllData, current)
		end
	end
	if type(guide.OnChange) == "function" then
		pcall(guide.OnChange, Refresh)
	end
	if type(journeys.Settings) == "table" and type(journeys.Settings.OnChange) == "function" then
		pcall(journeys.Settings.OnChange, Refresh)
	end

	naowhFactory = function()
		current = CreateFromMixins(providerMixin)
		return { current }
	end
end

-- FOURNISSEURS STANDARD D'AUTRES ADDONS ---------------------------------------------------------

-- Addons qui ajoutent à la carte du monde un fournisseur standard (MapCanvasDataProviderMixin) dont
-- le mixin est global et les modèles de repères en XML : une copie du mixin sur notre carte suffit.
-- Rafraîchie quand notre carte change de zone (moteur), et en plus :
--   events : événements qui changent ses données (regroupés, 1 s après le dernier) ;
--   hook   : rafraîchissement de l'addon sur la carte du monde, répercuté sur la nôtre.
--   * BtWQuests : quêtes disponibles de ses chaînes (BtWQuestsQuestDataProviderMixin) et objectifs
--     des quêtes suivies (BtWQuestsQuestPOIDataProviderMixin, seulement si le jeu n'en donne pas) ;
--     ses propres options (Afficher les repères...) restent respectées. Son fournisseur « guide »
--     (fenêtre de BtWQuests) n'est pas repris.
--   * MidnightRoutine : point de navigation de la routine en cours (une variable interne commune à
--     toutes les copies du fournisseur) ; son RefreshAllData est accroché.
local EXTERNAL = {
	{
		group = "btwQuests", setting = "showBtWQuests",
		mixins = { "BtWQuestsQuestDataProviderMixin", "BtWQuestsQuestPOIDataProviderMixin" },
		events = { "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED" },
	},
	{
		group = "midnightRoutine", setting = "showMidnightRoutine",
		mixins = { "MidnightRoutineMapWaypointDataProviderMixin" },
		hook = true,
	},
}
local EXTERNAL_REFRESH_DELAY = 1 -- secondes

local externalCurrent = {} -- [groupe] = { fournisseur, ... } sur notre carte
local externalOurs = {} -- [fournisseur] = true (les nôtres, pour ne pas reboucler par l'accroche)
local externalPending = {}

local function RefreshExternal(group, delay)
	if externalPending[group] then
		return
	end
	externalPending[group] = true
	C_Timer.After(delay or 0, function()
		externalPending[group] = nil
		for _, provider in ipairs(externalCurrent[group] or {}) do
			local map = provider:GetMap()
			if map and map:IsVisible() then
				pcall(provider.RefreshAllData, provider)
			end
		end
	end)
end

local externalFactories = {} -- [groupe] = fabrique (addon présent)

local function SetupExternal()
	local events = CreateFrame("Frame")
	local byEvent = {}
	for _, spec in ipairs(EXTERNAL) do
		local present = {}
		for _, name in ipairs(spec.mixins) do
			if type(_G[name]) == "table" then
				present[#present + 1] = _G[name]
			end
		end
		if #present > 0 then
			externalFactories[spec.group] = function()
				local list = {}
				for _, mixin in ipairs(present) do
					local ok, provider = pcall(CreateFromMixins, mixin)
					if ok and provider then
						externalOurs[provider] = true
						list[#list + 1] = provider
					end
				end
				externalCurrent[spec.group] = list
				return list
			end
			for _, event in ipairs(spec.events or {}) do
				byEvent[event] = byEvent[event] or {}
				table.insert(byEvent[event], spec.group)
				events:RegisterEvent(event)
			end
			if spec.hook then
				for _, mixin in ipairs(present) do
					if type(mixin.RefreshAllData) == "function" then
						hooksecurefunc(mixin, "RefreshAllData", function(self)
							if not externalOurs[self] then
								RefreshExternal(spec.group)
							end
						end)
					end
				end
			end
		end
	end
	events:SetScript("OnEvent", function(_, event)
		for _, group in ipairs(byEvent[event] or {}) do
			RefreshExternal(group, EXTERNAL_REFRESH_DELAY)
		end
	end)
end

-- INITIALISATION ------------------------------------------------------------------------------

-- Appelé par ns.ApplyProviders (Map.lua) : fournisseurs selon les réglages.
function ns.ApplyPluginProviders(setGroup)
	local db = ns.Settings()
	if hbdFactory then
		setGroup("hereBeDragons", db.showHereBeDragons, hbdFactory)
	end
	if handyNotesFactory then
		setGroup("handyNotes", db.showHandyNotes, handyNotesFactory)
	end
	if naowhFactory then
		setGroup("naowhRoute", db.showNaowhRoute, naowhFactory)
	end
	for _, spec in ipairs(EXTERNAL) do
		if externalFactories[spec.group] then
			setGroup(spec.group, db[spec.setting], externalFactories[spec.group])
			if not db[spec.setting] then
				externalCurrent[spec.group] = nil
			end
		end
	end
end

-- Appelé par Map.lua à la construction de la carte (avant son premier affichage).
function ns.InitPlugins(map)
	SetupHereBeDragons(map)
	SetupHandyNotes()
	SetupNaowhRoute()
	SetupExternal()
	table.insert(ns.clickHandlers, OnTomTomClick)
	ns.ApplyProviders()
end
