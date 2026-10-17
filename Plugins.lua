-- Polypode Map: Plugins — repères d'autres addons sur la carte (TomTom / HereBeDragons, HandyNotes)

local _, ns = ...

-- Chaque intégration est facultative : rien ne se passe si l'addon manque.
--   * HereBeDragons-Pins (librairie embarquée par TomTom, entre autres) : ses repères de la carte du
--     monde sont des icônes uniques (un seul parent à la fois). Un fournisseur copié du sien
--     (même code, pointé sur notre carte) les reprend quand la carte du monde est fermée ; elle les
--     récupère d'elle-même à son ouverture, et nous les rendons à sa fermeture.
--   * TomTom : Alt + clic droit sur la carte = nouveau point à cet endroit.
--   * HandyNotes : son fournisseur de carte du monde (HandyNotes.WorldMapDataProvider), copié.
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

-- Alt + clic droit sur la carte : point TomTom à cet endroit.
local function OnTomTomClick(button, cursorX, cursorY)
	if button ~= "RightButton" or not IsAltKeyDown() or not (TomTom and TomTom.AddWaypoint) then
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
	SetupExternal()
	table.insert(ns.clickHandlers, OnTomTomClick)
	ns.ApplyProviders()
end
