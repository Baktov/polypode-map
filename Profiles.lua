-- Polypode Map: Profiles — dispositions partagées entre personnages (copier, disposition par défaut, synchro)

local _, ns = ...
local P = ns.P
local L = ns.L

-- Les réglages de la carte sont par personnage (PolypodeMapDB). Pour les copier d'un personnage à
-- l'autre, chaque personnage dépose une copie de sa disposition (position, taille, options) dans
-- PolypodeMapSharedDB, sauvegarde du compte : 2 s après chaque changement et à la déconnexion.
--   PolypodeMapSharedDB = {
--     profiles = { [clé du personnage] = { label, class, updated, data = { champ = valeur } } },
--     default = { label, class, updated, data } ou { updated, removed = true },
--   }
-- updated = heure serveur ; la plus récente l'emporte. La position est gardée aussi en
-- pourcentage de l'écran (data.left, data.top : coin haut-gauche), appliquée ainsi quand elle
-- existe : une carte en haut à droite d'une grande fenêtre de jeu reste en haut à droite d'une petite.
-- Copier : tout, la position et la taille, ou les options d'affichage ; la dernière copie
-- s'annule pendant la session. Disposition par défaut : appliquée d'office à un personnage qui
-- n'a encore aucun réglage de la carte, et proposée en tête des copies.
-- Accès : menu « Disposition de la carte » (ns.ShowLayoutMenu), par trois lignes en tête des
-- options (panneau et petite fenêtre du clic droit) et par le menu manette du bouton Map.
-- SYNCHRO (avec Polypode seulement) : sur Retail les comptes partagent souvent un seul dossier de
-- sauvegardes, pas sur WoW Forever ; chaque client chuchote sa disposition (et celle par défaut)
-- aux clients connectés à chaque changement et à chaque client qui s'annonce, et garde celles
-- reçues. Message découpé pour tenir dans P.MAX_MESSAGE_LENGTH :
--   MAPPROF:token:clé:version:n°:total:fragment   (clé « * » = disposition par défaut)
-- fragment = suite « champ=valeur;... » (valeur préfixée b, n ou s : booléen, nombre, texte),
-- plus _label, _class, ou _removed pour une disposition par défaut effacée.

local PROF_TYPE = "MAPPROF"
local DEFAULT_KEY = "*"
local SAVE_DELAY = 2 -- secondes après un changement
local POSITION_FIELDS = { "point", "relativePoint", "x", "y", "width", "height", "scale", "locked" }
local EXCLUDED = { shown = true, zoom = true, minimapAngle = true, strataDialog = true }

local OPTION_FIELDS = {}
do
	local isPosition = {}
	for _, field in ipairs(POSITION_FIELDS) do
		isPosition[field] = true
	end
	for field in pairs(ns.DEFAULTS) do
		if not isPosition[field] and not EXCLUDED[field] then
			OPTION_FIELDS[#OPTION_FIELDS + 1] = field
		end
	end
	table.sort(OPTION_FIELDS)
end

local shared -- PolypodeMapSharedDB
local undoData -- réglages d'avant la dernière copie (session)
local defaultAppliedAtLoad = false

local function OwnKey()
	if P.GetCharKey then
		return P.GetCharKey()
	end
	local realm = GetNormalizedRealmName and GetNormalizedRealmName() or (GetRealmName() or ""):gsub("%s", "")
	return UnitName("player") .. "-" .. realm
end

local function OwnLabel()
	if P.GetDisplayName then
		return P.GetDisplayName(OwnKey())
	end
	return UnitName("player")
end

local function Message(text, isError)
	if isError then
		UIErrorsFrame:AddMessage(text, 1, 0.1, 0.1)
	else
		UIErrorsFrame:AddMessage(text, 1, 0.82, 0)
	end
end

-- ENCODAGE -------------------------------------------------------------------------------------

local function EncodeValue(value)
	if type(value) == "boolean" then
		return value and "b1" or "b0"
	elseif type(value) == "number" then
		return "n" .. string.format("%.6g", value)
	end
	return "s" .. tostring(value):gsub("[;=:]", "")
end

local function DecodeValue(text)
	local kind, value = text:sub(1, 1), text:sub(2)
	if kind == "b" then
		return value == "1"
	elseif kind == "n" then
		return tonumber(value)
	elseif kind == "s" then
		return value
	end
end

-- « champ=valeur;... », champs triés (même texte pour les mêmes réglages).
local function Encode(data)
	local fields = {}
	for field in pairs(data) do
		fields[#fields + 1] = field
	end
	table.sort(fields)
	local parts = {}
	for _, field in ipairs(fields) do
		parts[#parts + 1] = field .. "=" .. EncodeValue(data[field])
	end
	return table.concat(parts, ";")
end

local function Decode(text)
	local data = {}
	for field, value in (text or ""):gmatch("([^;=]+)=([^;]*)") do
		data[field] = DecodeValue(value)
	end
	return data
end

-- INSTANTANÉ ET APPLICATION --------------------------------------------------------------------

-- Disposition actuelle de ce personnage ; coin haut-gauche en fraction de l'écran si la fenêtre
-- est placée.
local function Snapshot()
	local db = ns.Settings()
	local data = {}
	for _, field in ipairs(POSITION_FIELDS) do
		data[field] = db[field]
	end
	for _, field in ipairs(OPTION_FIELDS) do
		data[field] = db[field]
	end
	local frame = P.ui and P.ui.mapFrame
	local left, top = frame and frame:GetLeft(), frame and frame:GetTop()
	local width, height = UIParent:GetWidth(), UIParent:GetHeight()
	if left and top and width > 0 and height > 0 then
		local ratio = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
		data.left = left * ratio / width
		data.top = top * ratio / height
	end
	return data
end

-- Copie data dans les réglages db : what = "all", "position" ou "options" ; raw : position telle
-- quelle (annulation), sans passer par le pourcentage de l'écran.
local function ApplyData(db, data, what, raw)
	if what ~= "position" then
		for _, field in ipairs(OPTION_FIELDS) do
			if data[field] ~= nil then
				db[field] = data[field]
			end
		end
	end
	if what ~= "options" then
		for _, field in ipairs({ "width", "height", "scale", "locked" }) do
			if data[field] ~= nil then
				db[field] = data[field]
			end
		end
		if not raw and data.left and data.top then
			local scale = (db.scale or 100) / 100
			db.point, db.relativePoint = "TOPLEFT", "BOTTOMLEFT"
			db.x = data.left * UIParent:GetWidth() / scale
			db.y = data.top * UIParent:GetHeight() / scale
		elseif data.point then
			db.point, db.relativePoint, db.x, db.y = data.point, data.relativePoint, data.x, data.y
		end
	end
end

local function RawCopy()
	local db = ns.Settings()
	local data = {}
	for _, field in ipairs(POSITION_FIELDS) do
		data[field] = db[field]
	end
	for _, field in ipairs(OPTION_FIELDS) do
		data[field] = db[field]
	end
	return data
end

-- Carte, repères, bouton de la minicarte et fenêtres d'options suivent les nouveaux réglages.
local function RefreshAll()
	ns.ApplyLayout()
	ns.ApplyProviders()
	ns.ApplyMemberScale()
	ns.SetLocked(ns.Settings().locked)
	if ns.ApplyMinimapButton then
		ns.ApplyMinimapButton()
	end
	if ns.RefreshHover then
		ns.RefreshHover()
	end
	if P.RefreshOptionsPopups then
		P.RefreshOptionsPopups()
	end
end

-- SAUVEGARDE ET SYNCHRO ------------------------------------------------------------------------

local SendProfile -- défini plus bas

-- Range sa propre disposition si elle a changé (version = heure serveur) et la chuchote.
local function SaveOwn(silent)
	if not shared then
		return
	end
	local key = OwnKey()
	local data = Snapshot()
	local profile = shared.profiles[key]
	if profile and profile.data and Encode(profile.data) == Encode(data) then
		return
	end
	local _, class = UnitClass("player")
	shared.profiles[key] = { label = OwnLabel(), class = class, updated = GetServerTime(), data = data }
	if not silent then
		SendProfile(key)
	end
end

local saveScheduled = false
-- Appelé par Map.lua à chaque changement de position ou de réglage.
function ns.OnLayoutChanged()
	if saveScheduled then
		return
	end
	saveScheduled = true
	C_Timer.After(SAVE_DELAY, function()
		saveScheduled = false
		SaveOwn()
	end)
end

local function ProfileFor(key)
	if not shared then
		return nil
	end
	return key == DEFAULT_KEY and shared.default or shared.profiles[key]
end

-- Chuchote une disposition (clé, ou DEFAULT_KEY) aux clients connectés, ou à target.
SendProfile = function(key, target)
	local profile = ProfileFor(key)
	local token = P.GetTeamToken and P.GetTeamToken()
	if not (profile and profile.updated and token and P.WhisperOnline) then
		return
	end
	local payload
	if profile.removed then
		payload = "_removed=b1"
	else
		payload = Encode(profile.data or {}) .. ";_label=" .. EncodeValue(profile.label or "")
			.. ";_class=" .. EncodeValue(profile.class or "")
	end
	local header = string.format("%s:%s:%s:%d:", PROF_TYPE, token, key, profile.updated)
	local budget = (P.MAX_MESSAGE_LENGTH or 255) - #header - 8 -- place de « n°:total: »
	local chunks = {}
	for start = 1, #payload, budget do
		chunks[#chunks + 1] = payload:sub(start, start + budget - 1)
	end
	for index, chunk in ipairs(chunks) do
		P.WhisperOnline(header .. index .. ":" .. #chunks .. ":" .. chunk, target)
	end
end

local pending = {} -- [clé:version] = { count, parts }
local UpdateDefaultRow -- infobulle de la ligne « Disposition par défaut » (plus bas)

local function OnProfileMessage(rest, sender)
	local key, updated, index, count, chunk = strsplit(":", rest or "", 5)
	updated, index, count = tonumber(updated), tonumber(index), tonumber(count)
	if not (shared and key and updated and index and count and chunk) or count < 1 or count > 20 then
		return
	end
	-- La disposition d'un personnage ne vient que de lui ; celle par défaut, de tout compte accepté
	-- (token déjà vérifié par Polypode).
	if key ~= DEFAULT_KEY and not (P.IsSender and P.IsSender(sender, key)) then
		return
	end
	local current = ProfileFor(key)
	if current and current.updated and current.updated >= updated then
		return
	end
	local id = key .. ":" .. updated
	local entry = pending[id] or { count = count, parts = {}, received = 0 }
	pending[id] = entry
	if not entry.parts[index] then
		entry.parts[index] = chunk
		entry.received = entry.received + 1
	end
	if entry.received < entry.count then
		return
	end
	pending[id] = nil
	local data = Decode(table.concat(entry.parts))
	local profile
	if data._removed then
		profile = { updated = updated, removed = true }
	else
		local label, class = data._label, data._class
		data._label, data._class = nil, nil
		profile = { label = label, class = class ~= "" and class or nil, updated = updated, data = data }
	end
	if key == DEFAULT_KEY then
		shared.default = profile
	else
		shared.profiles[key] = profile
	end
	UpdateDefaultRow()
end

if P.RegisterMessageHandler then
	P.RegisterMessageHandler(PROF_TYPE, OnProfileMessage)
	P.RegisterPeerCallback(function(sender)
		-- Un client s'annonce : il reçoit notre disposition et celle par défaut.
		SendProfile(OwnKey(), sender)
		SendProfile(DEFAULT_KEY, sender)
	end)
end

-- ACTIONS --------------------------------------------------------------------------------------

local function ProfileLabel(key, profile)
	local name = profile.label or key
	if key ~= DEFAULT_KEY and P.GetCharacter and P.GetCharacter(key) and P.GetDisplayName then
		name = P.GetDisplayName(key)
	end
	local color = profile.class and C_ClassColor and C_ClassColor.GetClassColor(profile.class)
	return color and color:WrapTextInColorCode(name) or name
end

local function DateText(profile)
	return profile.updated and date("%d/%m/%Y %H:%M", profile.updated) or ""
end

-- « Enregistrée par <personnage> le <date>. » pour la disposition par défaut (nom en couleur de
-- classe, celui du personnage qui l'a enregistrée), sinon « aucune ».
local function DefaultOrigin()
	local default = shared and shared.default
	if not (default and not default.removed and default.data) then
		return L["Aucune disposition par défaut pour l'instant."]
	end
	local name = default.label or "?"
	local color = default.class and C_ClassColor and C_ClassColor.GetClassColor(default.class)
	return L["Enregistrée par %s le %s."]:format(color and color:WrapTextInColorCode(name) or name,
		DateText(default))
end

local defaultRowItem -- ligne « Disposition par défaut » de la petite fenêtre (infobulle à jour)
local DEFAULT_ROW_TOOLTIP -- texte fixe de cette ligne, rempli par ns.AddLayoutSettings

-- Infobulle de la ligne mise à jour (enregistrée, effacée, reçue d'un autre client).
UpdateDefaultRow = function()
	if defaultRowItem then
		defaultRowItem.tooltip = DEFAULT_ROW_TOOLTIP .. "|n|n" .. DefaultOrigin()
	end
	if P.RefreshOptionsPopups then
		P.RefreshOptionsPopups()
	end
end

-- Applique une disposition (copie) : réglages d'avant gardés pour l'annulation.
local function ApplyProfile(profile, what, sourceLabel)
	if not (profile and profile.data) then
		return
	end
	undoData = RawCopy()
	ApplyData(ns.Settings(), profile.data, what)
	RefreshAll()
	Message(L["Disposition de %s appliquée."]:format(sourceLabel))
	ns.OnLayoutChanged()
end

local function SaveDefault()
	if not shared then
		return
	end
	local _, class = UnitClass("player")
	shared.default = { label = OwnLabel(), class = class, updated = GetServerTime(), data = Snapshot() }
	Message(L["Disposition par défaut enregistrée."])
	SendProfile(DEFAULT_KEY)
	UpdateDefaultRow()
end

local function ClearDefault()
	if not shared then
		return
	end
	shared.default = { updated = GetServerTime(), removed = true }
	Message(L["Disposition par défaut effacée."])
	SendProfile(DEFAULT_KEY)
	UpdateDefaultRow()
end

local function Undo()
	if not undoData then
		Message(L["Aucune copie à annuler."], true)
		return
	end
	ApplyData(ns.Settings(), undoData, "all", true)
	undoData = nil
	RefreshAll()
	Message(L["Dernière copie annulée."])
	ns.OnLayoutChanged()
end

local WHAT = {
	{ "all", L["Tout"] },
	{ "position", L["Position et taille"] },
	{ "options", L["Options d'affichage"] },
}

-- Ligne « source » du menu : sous-menu Tout / Position et taille / Options d'affichage.
local function AddSource(parent, key, profile, text)
	local entry = parent:CreateButton(text .. "  |cff999999" .. DateText(profile) .. "|r")
	if key == DEFAULT_KEY and entry.SetTooltip then
		entry:SetTooltip(function(tooltip)
			tooltip:SetText(L["Disposition par défaut"])
			tooltip:AddLine(DefaultOrigin(), 1, 1, 1, true)
		end)
	end
	local source = key == DEFAULT_KEY and L["la disposition par défaut"] or ProfileLabel(key, profile)
	for _, choice in ipairs(WHAT) do
		entry:CreateButton(choice[2], function()
			ApplyProfile(profile, choice[1], source)
		end)
	end
end

-- Menu « Disposition de la carte » : copier depuis un autre personnage ou la disposition par
-- défaut, enregistrer / effacer la disposition par défaut, annuler la dernière copie.
function ns.ShowLayoutMenu(owner)
	if not (MenuUtil and shared) then
		return
	end
	SaveOwn(true) -- sa propre disposition à jour (la liste ne la montre pas)
	MenuUtil.CreateContextMenu(owner or UIParent, function(_, root)
		root:CreateTitle(L["Disposition de la carte"])
		local copy = root:CreateButton(L["Copier depuis"])
		local any = false
		local default = shared.default
		if default and not default.removed and default.data then
			AddSource(copy, DEFAULT_KEY, default, L["Disposition par défaut"])
			any = true
		end
		local own, keys = OwnKey(), {}
		for key, profile in pairs(shared.profiles) do
			if key ~= own and profile.data then
				keys[#keys + 1] = key
			end
		end
		table.sort(keys, function(a, b)
			return (shared.profiles[a].label or a):lower() < (shared.profiles[b].label or b):lower()
		end)
		for _, key in ipairs(keys) do
			local profile = shared.profiles[key]
			AddSource(copy, key, profile, ProfileLabel(key, profile))
			any = true
		end
		if not any then
			copy:CreateTitle(L["Aucune autre disposition enregistrée"])
		end
		root:CreateButton(L["Enregistrer comme disposition par défaut"], SaveDefault)
		if default and not default.removed then
			root:CreateButton(L["Effacer la disposition par défaut"], ClearDefault)
		end
		if undoData then
			root:CreateButton(L["Annuler la dernière copie"], Undo)
		end
	end)
end

-- Lignes en tête des options (panneau, et petite fenêtre si Polypode accepte les boutons).
function ns.AddLayoutSettings(category, layout, popupItems)
	local rows = {
		{ L["Copier une disposition"], L["Choisir..."], function(button)
			ns.ShowLayoutMenu(button)
		end, L["Applique la position, la taille et les options de la carte d'un autre personnage, ou la "
			.. "disposition par défaut : tout, la position et la taille, ou les options d'affichage. La "
			.. "position suit la taille de l'écran (en pourcentage)."] },
		{ L["Disposition par défaut"], L["Enregistrer celle-ci"], SaveDefault,
			L["Enregistre la disposition de ce personnage comme disposition par défaut : appliquée "
			.. "d'office à un personnage qui ouvre la carte pour la première fois, et proposée dans "
			.. "« Copier une disposition »."], true },
		{ L["Annuler la dernière copie"], L["Annuler"], Undo,
			L["Revient à la disposition d'avant la dernière copie (pendant cette session)."] },
	}
	for index, row in ipairs(rows) do
		local label, buttonText, onClick, tooltip, isDefaultRow = row[1], row[2], row[3], row[4], row[5]
		if layout and CreateSettingsButtonInitializer then
			local ok, initializer = pcall(CreateSettingsButtonInitializer, label, buttonText, function()
				onClick(nil)
			end, tooltip, true)
			if ok and initializer then
				layout:AddInitializer(initializer)
			end
		end
		if popupItems and P.OPTIONS_POPUP_BUTTONS then
			local item = {
				kind = "button",
				setting = { GetName = function() return label end },
				text = buttonText,
				onClick = onClick,
				tooltip = tooltip,
			}
			table.insert(popupItems, index, item)
			if isDefaultRow then
				defaultRowItem, DEFAULT_ROW_TOOLTIP = item, tooltip
				item.tooltip = tooltip .. "|n|n" .. DefaultOrigin()
			end
		end
	end
end

-- CHARGEMENT -----------------------------------------------------------------------------------

-- Appelé par Map.lua à ADDON_LOADED, réglages complétés ; isNew : aucun réglage de la carte
-- jusque-là sur ce personnage (la disposition par défaut s'applique alors d'office).
function ns.OnSettingsLoaded(isNew)
	PolypodeMapSharedDB = PolypodeMapSharedDB or {}
	shared = PolypodeMapSharedDB
	shared.profiles = shared.profiles or {}
	local default = shared.default
	if isNew and default and not default.removed and default.data then
		ApplyData(PolypodeMapDB, default.data, "all")
		defaultAppliedAtLoad = true
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_LOGOUT")
events:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		if defaultAppliedAtLoad then
			C_Timer.After(3, function()
				Message(L["Polypode Map : disposition par défaut appliquée à ce nouveau personnage."])
			end)
		end
		C_Timer.After(5, function()
			SaveOwn()
		end)
	else
		SaveOwn(true)
	end
end)
