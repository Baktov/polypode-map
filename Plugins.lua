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
end

-- Appelé par Map.lua à la construction de la carte (avant son premier affichage).
function ns.InitPlugins(map)
	SetupHereBeDragons(map)
	SetupHandyNotes()
	table.insert(ns.clickHandlers, OnTomTomClick)
	ns.ApplyProviders()
end
