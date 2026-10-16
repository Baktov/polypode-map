-- Polypode Map: Members — personnages de Polypode sur la carte (positions échangées, repères nommés, ping)

local _, ns = ...
local P = Polypode

-- Repère de chaque personnage de l'équipe sélectionnée (ou de tout le roster, option showAll),
-- soi excepté (flèche de Blizzard) : point en couleur de classe, nom au-dessus, couronne du leader.
-- Position :
--   * personnage groupé : lue en direct par C_Map.GetPlayerMapPosition (comme la carte de Blizzard,
--     qui dessine aussi son point dessous) ;
--   * sinon : envoyée par son propre client. Chaque client lit sa position (toutes les 0,5 s), la
--     convertit en coordonnées du monde (continent, x, y : valables quelle que soit la carte
--     affichée chez le destinataire) et la chuchote par Polypode (P.WhisperOnline, message MAPPOS)
--     aux personnages connectés qui ne sont pas dans son groupe : au plus toutes les 2 s en
--     mouvement, toutes les 30 s immobile. Les chuchotements addon hors instance ne sont pas limités
--     par préfixe ; en instance, WoW ne donne pas de position (repère masqué, « position inconnue »).
--   Position reçue il y a plus de 75 s : repère estompé ; plus de 5 min : retiré.
-- Ping (clic sur la carte, option ping) : signal animé de 5 s à cet endroit, chuchoté aux clients
-- connectés (message MAPPING, coordonnées du monde) et montré sur leur carte.
-- Messages (token vérifié par Polypode, expéditeur par P.IsSender) :
--   MAPPOS:token:continent:x:y:uiMapID:nom-royaume (champs de position vides = position inconnue)
--   MAPPING:token:continent:x:y:nom-royaume

local POS_TYPE, PING_TYPE = "MAPPOS", "MAPPING"
local MEMBER_TEMPLATE, PING_TEMPLATE = "PolypodeMapMemberPin", "PolypodeMapPingPin"
local SEND_TICK = 0.5 -- secondes entre deux lectures de sa propre position
local SEND_MIN_INTERVAL = 2 -- secondes entre deux envois en mouvement
local SEND_HEARTBEAT = 30 -- secondes : envoi même immobile
local MOVE_THRESHOLD = 3 -- mètres (unités du monde) avant un nouvel envoi
local UPDATE_INTERVAL = 0.2 -- secondes entre deux mises à jour des repères
local STALE_AFTER = 75 -- secondes : repère estompé
local FORGET_AFTER = 300 -- secondes : repère retiré
local PING_DURATION = 5 -- secondes
local PING_COOLDOWN = 0.5 -- secondes entre deux pings envoyés
local MEMBER_PIN_SIZE = 12

local IsSecret = ns.IsSecret
local positions = {} -- [nom-royaume] = { continent, x, y, mapID, at } (at = GetTime(), continent nil = inconnue)
local pings = {} -- { key, continent, x, y, expires }
local memberProvider, pingProvider

local function Settings()
	return ns.Settings()
end

local function Tooltip()
	if P.ShowTooltip then
		P.ShowTooltip()
	else
		GameTooltip:Show()
	end
end

-- POSITIONS -----------------------------------------------------------------------------------

-- Position du joueur en coordonnées du monde : continent, x, y, uiMapID ; nil si inconnue.
local function OwnWorldPosition()
	local mapID = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	if not mapID then
		return nil
	end
	local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
	if not ok or not pos then
		return nil
	end
	local continent, world
	ok, continent, world = pcall(C_Map.GetWorldPosFromMapPos, mapID, pos)
	if not ok or not continent or not world then
		return nil
	end
	local x, y = world:GetXY()
	if IsSecret(continent) or IsSecret(x) or IsSecret(y) then
		return nil
	end
	return continent, x, y, mapID
end

-- Coordonnées du monde → position normalisée sur la carte mapID (nil si hors de la carte).
local worldVector = CreateVector2D(0, 0)
local function WorldToMap(continent, x, y, mapID)
	if not (continent and mapID) then
		return nil
	end
	worldVector:SetXY(x, y)
	local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, continent, worldVector, mapID)
	if not ok or not pos then
		return nil
	end
	local mapX, mapY = pos:GetXY()
	if mapX and mapY and mapX >= 0 and mapX <= 1 and mapY >= 0 and mapY <= 1 then
		return mapX, mapY
	end
end

-- Position d'un personnage sur la carte mapID : x, y, source ("live" ou "sync"), âge en secondes.
local function MemberMapPosition(key, mapID)
	local unit = P.FindGroupUnit and P.FindGroupUnit(key)
	if unit and unit ~= "player" then
		local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, unit)
		if ok and pos then
			local x, y = pos:GetXY()
			if x and not IsSecret(x) and not IsSecret(y) and (x ~= 0 or y ~= 0)
				and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
				return x, y, "live", 0
			end
		end
	end
	local known = positions[key]
	if known and known.continent then
		local x, y = WorldToMap(known.continent, known.x, known.y, mapID)
		if x then
			return x, y, "sync", GetTime() - known.at
		end
	end
end

-- Personnages connectés hors de notre groupe : destinataires de notre position.
local function Recipients()
	local list = {}
	local own = P.GetCharKey()
	for key, entry in pairs(P.db.roster or {}) do
		if key ~= own and not entry.removed and entry.name and entry.realm
			and P.IsCharacterOnline and P.IsCharacterOnline(key)
			and not (P.FindGroupUnit and P.FindGroupUnit(key)) then
			list[#list + 1] = P.GetTargetName(entry)
		end
	end
	return list
end

local function PositionMessage(token, continent, x, y, mapID)
	if continent then
		return string.format("%s:%s:%d:%.1f:%.1f:%d:%s", POS_TYPE, token, continent, x, y, mapID or 0, P.GetCharKey())
	end
	return string.format("%s:%s:::::%s", POS_TYPE, token, P.GetCharKey())
end

local lastSent = { at = -math.huge }

-- Envoie sa position si elle a changé (ou au battement), aux destinataires ; target = un seul
-- destinataire, envoi forcé (nouveau client).
local function SendPosition(target)
	local token = P.GetTeamToken and P.GetTeamToken()
	if not token or not P.WhisperOnline then
		return
	end
	local continent, x, y, mapID = OwnWorldPosition()
	if target then
		P.WhisperOnline(PositionMessage(token, continent, x, y, mapID), target)
		return
	end
	local now = GetTime()
	local moved
	if continent then
		moved = continent ~= lastSent.continent
			or (x - lastSent.x) ^ 2 + (y - lastSent.y) ^ 2 >= MOVE_THRESHOLD ^ 2
	else
		moved = lastSent.continent ~= nil
	end
	if not ((moved and now - lastSent.at >= SEND_MIN_INTERVAL) or now - lastSent.at >= SEND_HEARTBEAT) then
		return
	end
	local recipients = Recipients()
	if #recipients == 0 then
		return -- rien d'envoyé : un personnage qui quitte le groupe recevra au prochain tour
	end
	local message = PositionMessage(token, continent, x, y, mapID)
	for _, to in ipairs(recipients) do
		P.WhisperOnline(message, to)
	end
	lastSent = { continent = continent, x = x, y = y, at = now }
end

local function OnPositionMessage(rest, sender)
	local continent, x, y, mapID, key = strsplit(":", rest or "", 5)
	if not key or not (P.IsSender and P.IsSender(sender, key)) then
		return
	end
	continent, x, y = tonumber(continent), tonumber(x), tonumber(y)
	if continent and x and y then
		positions[key] = { continent = continent, x = x, y = y, mapID = tonumber(mapID), at = GetTime() }
	else
		positions[key] = { at = GetTime() }
	end
end

-- REPÈRES DES PERSONNAGES ---------------------------------------------------------------------

local function ClassColor(key)
	local entry = P.GetCharacter and P.GetCharacter(key)
	local class = entry and entry.class
	local color = class and (C_ClassColor and C_ClassColor.GetClassColor(class) or RAID_CLASS_COLORS[class])
	if color then
		return color.r, color.g, color.b
	end
	return 0.8, 0.8, 0.8
end

local function SelectedLeader()
	local team = P.GetSelectedTeam and P.GetSelectedTeam()
	return team and P.GetTeamLeader and P.GetTeamLeader(team)
end

local function FormatAge(seconds)
	if seconds < 60 then
		return string.format("%d s", seconds)
	end
	return string.format("%d min", seconds / 60)
end

local MemberPinMixin = CreateFromMixins(MapCanvasPinMixin)
MemberPinMixin.mouseMotion = true

function MemberPinMixin:OnLoad()
	self:SetSize(MEMBER_PIN_SIZE, MEMBER_PIN_SIZE)
	self:UseFrameLevelType("PIN_FRAME_LEVEL_POLYPODE_MEMBER")
	self:SetIgnoreGlobalPinScale(true)

	self.Border = self:CreateTexture(nil, "BORDER")
	self.Border:SetAtlas("WhiteCircle-RaidBlips")
	self.Border:SetPoint("CENTER")
	self.Border:SetSize(MEMBER_PIN_SIZE + 4, MEMBER_PIN_SIZE + 4)
	self.Border:SetVertexColor(0, 0, 0, 0.9)
	self.Dot = self:CreateTexture(nil, "ARTWORK")
	self.Dot:SetAtlas("WhiteCircle-RaidBlips")
	self.Dot:SetAllPoints()
	self.Leader = self:CreateTexture(nil, "OVERLAY")
	self.Leader:SetAtlas("groupfinder-icon-leader")
	self.Leader:SetSize(12, 8)
	self.Leader:SetPoint("BOTTOM", self, "TOP", 0, 0)
	self.Name = self:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	local font, size = self.Name:GetFont()
	self.Name:SetFont(font, size, "OUTLINE")
	self.Name:SetShadowOffset(0, 0)
end

function MemberPinMixin:OnAcquired(key)
	self.key = key
	local scale = Settings().memberScale / 100
	self:SetScalingLimits(1, scale, scale) -- taille constante à l'écran, quel que soit le zoom
	local r, g, b = ClassColor(key)
	self.Dot:SetVertexColor(r, g, b)
	local entry = P.GetCharacter and P.GetCharacter(key)
	self.Name:SetText(entry and entry.name or key)
	self.Name:SetTextColor(r, g, b)
	self.Name:SetShown(Settings().showNames)
	local isLeader = key == SelectedLeader()
	self.Leader:SetShown(isLeader)
	self.Name:ClearAllPoints()
	self.Name:SetPoint("BOTTOM", self, "TOP", 0, isLeader and 8 or 1)
	self.lastX, self.lastY = nil, nil
	self:ApplyCurrentScale()
end

function MemberPinMixin:OnReleased()
	MapCanvasPinMixin.OnReleased(self)
	self.key = nil
	if GameTooltip:GetOwner() == self then
		GameTooltip:Hide()
	end
end

-- Place le repère (seulement s'il a bougé) et l'estompe si la position est ancienne.
function MemberPinMixin:Place(x, y, stale)
	if x ~= self.lastX or y ~= self.lastY then
		self.lastX, self.lastY = x, y
		self:SetPosition(x, y)
	end
	self:SetAlpha(stale and 0.45 or 1)
	self:Show()
end

function MemberPinMixin:OnMouseEnter()
	local key = self.key
	if not key then
		return
	end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine(P.GetDisplayName and P.GetDisplayName(key, true) or key, ClassColor(key))
	if key == SelectedLeader() then
		GameTooltip:AddLine("Leader de l'équipe", 1, 0.82, 0)
	end
	local _, _, source, age = MemberMapPosition(key, self:GetMap():GetMapID())
	if source == "live" then
		GameTooltip:AddLine("Dans votre groupe : position en direct", 1, 1, 1)
	elseif source == "sync" then
		GameTooltip:AddLine("Position reçue il y a " .. FormatAge(age), 1, 1, 1)
	end
	local status = P.GetCharacterStatus and P.GetCharacterStatus(key)
	if status and status.zone and status.zone ~= "" then
		GameTooltip:AddLine(status.zone, 0.7, 0.7, 0.7)
	end
	Tooltip()
end

function MemberPinMixin:OnMouseLeave()
	GameTooltip:Hide()
end

-- Personnages montrés : équipe sélectionnée (ou tout le roster), soi excepté.
local function ShownKeys()
	local keys = {}
	local team = not Settings().showAll and P.GetSelectedTeam and P.GetSelectedTeam()
	if team then
		for key in pairs(P.GetTeamMembers(team) or {}) do
			keys[key] = true
		end
	else
		for key, entry in pairs(P.db.roster or {}) do
			if not entry.removed then
				keys[key] = true
			end
		end
	end
	keys[P.GetCharKey()] = nil
	return keys
end

local MemberProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function MemberProviderMixin:OnAdded(map)
	MapCanvasDataProviderMixin.OnAdded(self, map)
	self.pins = {}
	ns.RegisterPinPool(map, MEMBER_TEMPLATE, MemberPinMixin)
end

function MemberProviderMixin:RemoveAllData()
	self:GetMap():RemoveAllPinsByTemplate(MEMBER_TEMPLATE)
	wipe(self.pins)
end

function MemberProviderMixin:RefreshAllData()
	self:RemoveAllData()
	for key in pairs(ShownKeys()) do
		self.pins[key] = self:GetMap():AcquirePin(MEMBER_TEMPLATE, key)
	end
	self:UpdatePositions()
end

function MemberProviderMixin:UpdatePositions()
	local map = self:GetMap()
	local mapID = map and map:GetMapID()
	for key, pin in pairs(self.pins) do
		local x, y, source, age = MemberMapPosition(key, mapID)
		if x and age < FORGET_AFTER then
			pin:Place(x, y, source ~= "live" and age > STALE_AFTER)
		else
			pin:Hide()
		end
	end
end

function MemberProviderMixin:OnShow()
	if not self.ticker then
		self.ticker = C_Timer.NewTicker(UPDATE_INTERVAL, function()
			self:UpdatePositions()
		end)
	end
end

function MemberProviderMixin:OnHide()
	if self.ticker then
		self.ticker:Cancel()
		self.ticker = nil
	end
end

function MemberProviderMixin:OnMapChanged()
	self:UpdatePositions()
end

-- Équipe, roster ou options changés : repères reconstruits.
function ns.RefreshMembers()
	if memberProvider and memberProvider:GetMap() then
		memberProvider:RefreshAllData()
	end
end

-- PING ----------------------------------------------------------------------------------------

local PingPinMixin = CreateFromMixins(MapCanvasPinMixin)

function PingPinMixin:OnLoad()
	self:SetSize(32, 32)
	self:UseFrameLevelType("PIN_FRAME_LEVEL_POLYPODE_PING")
	self:SetIgnoreGlobalPinScale(true)
	self:SetScalingLimits(1, 1, 1)

	self.Center = self:CreateTexture(nil, "ARTWORK")
	self.Center:SetTexture("Interface\\Minimap\\UI-Minimap-Ping-Center")
	self.Center:SetSize(32, 32)
	self.Center:SetPoint("CENTER")
	self.Expand = self:CreateTexture(nil, "BACKGROUND")
	self.Expand:SetTexture("Interface\\Minimap\\UI-Minimap-Ping-Expand")
	self.Expand:SetSize(32, 32)
	self.Expand:SetPoint("CENTER")
	self.Rotate = self:CreateTexture(nil, "OVERLAY")
	self.Rotate:SetTexture("Interface\\Minimap\\UI-Minimap-Ping-Rotate")
	self.Rotate:SetSize(56, 56)
	self.Rotate:SetPoint("CENTER")
	self.Label = self:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	self.Label:SetPoint("TOP", self, "BOTTOM", 0, -2)

	self.ScaleAnimation = self.Expand:CreateAnimationGroup()
	self.ScaleAnimation:SetLooping("REPEAT")
	local grow = self.ScaleAnimation:CreateAnimation("Scale")
	grow:SetScaleFrom(0.5, 0.5)
	grow:SetScaleTo(1.6, 1.6)
	grow:SetDuration(0.6)
	self.RotateAnimation = self.Rotate:CreateAnimationGroup()
	self.RotateAnimation:SetLooping("REPEAT")
	local spin = self.RotateAnimation:CreateAnimation("Rotation")
	spin:SetDegrees(-360)
	spin:SetDuration(6)
end

function PingPinMixin:OnAcquired(ping, x, y)
	self:SetPosition(x, y)
	self:ApplyCurrentScale()
	local key = ping.key
	local entry = key and P.GetCharacter and P.GetCharacter(key)
	self.Label:SetText(entry and entry.name or "")
	self.Label:SetTextColor(ClassColor(key))
	self.ScaleAnimation:Play()
	self.RotateAnimation:Play()
end

function PingPinMixin:OnReleased()
	MapCanvasPinMixin.OnReleased(self)
	self.ScaleAnimation:Stop()
	self.RotateAnimation:Stop()
end

local PingProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function PingProviderMixin:OnAdded(map)
	MapCanvasDataProviderMixin.OnAdded(self, map)
	ns.RegisterPinPool(map, PING_TEMPLATE, PingPinMixin)
end

function PingProviderMixin:RemoveAllData()
	self:GetMap():RemoveAllPinsByTemplate(PING_TEMPLATE)
end

function PingProviderMixin:RefreshAllData()
	self:RemoveAllData()
	local now = GetTime()
	local mapID = self:GetMap():GetMapID()
	for index = #pings, 1, -1 do
		local ping = pings[index]
		if ping.expires <= now then
			table.remove(pings, index)
		else
			local x, y = WorldToMap(ping.continent, ping.x, ping.y, mapID)
			if x then
				self:GetMap():AcquirePin(PING_TEMPLATE, ping, x, y)
			end
		end
	end
end

local function AddPing(key, continent, x, y)
	pings[#pings + 1] = { key = key, continent = continent, x = x, y = y, expires = GetTime() + PING_DURATION }
	if pingProvider and pingProvider:GetMap() and pingProvider:GetMap():IsVisible() then
		pingProvider:RefreshAllData()
		if SOUNDKIT and SOUNDKIT.MAP_PING then
			PlaySound(SOUNDKIT.MAP_PING)
		end
	end
	C_Timer.After(PING_DURATION + 0.1, function()
		if pingProvider and pingProvider:GetMap() then
			pingProvider:RefreshAllData()
		end
	end)
end

local lastPing = -math.huge

-- Clic gauche sur la carte (sans touche de modification) : ping local et chez les autres clients.
local function OnCanvasClick(button, cursorX, cursorY)
	if button ~= "LeftButton" or not Settings().ping or IsModifierKeyDown() then
		return false
	end
	local now = GetTime()
	if now - lastPing < PING_COOLDOWN then
		return true
	end
	local mapID = ns.GetMapID()
	worldVector:SetXY(cursorX, cursorY)
	local ok, continent, world = pcall(C_Map.GetWorldPosFromMapPos, mapID, worldVector)
	if not ok or not continent or not world then
		return false
	end
	lastPing = now
	local x, y = world:GetXY()
	AddPing(P.GetCharKey(), continent, x, y)
	local token = P.GetTeamToken and P.GetTeamToken()
	if token and P.WhisperOnline then
		P.WhisperOnline(string.format("%s:%s:%d:%.1f:%.1f:%s", PING_TYPE, token, continent, x, y, P.GetCharKey()))
	end
	return true
end

local function OnPingMessage(rest, sender)
	local continent, x, y, key = strsplit(":", rest or "", 4)
	continent, x, y = tonumber(continent), tonumber(x), tonumber(y)
	if continent and x and y and key and P.IsSender and P.IsSender(sender, key) and Settings().ping then
		AddPing(key, continent, x, y)
	end
end

-- INITIALISATION ------------------------------------------------------------------------------

-- Appelé par Map.lua à la construction de la carte (avant son premier affichage).
function ns.InitMembers(map)
	memberProvider = CreateFromMixins(MemberProviderMixin)
	map:AddDataProvider(memberProvider)
	pingProvider = CreateFromMixins(PingProviderMixin)
	map:AddDataProvider(pingProvider)
	table.insert(ns.clickHandlers, OnCanvasClick)
end

if P.RegisterMessageHandler then
	P.RegisterMessageHandler(POS_TYPE, OnPositionMessage)
	P.RegisterMessageHandler(PING_TYPE, OnPingMessage)
	P.RegisterPeerCallback(function(sender)
		SendPosition(sender) -- un client s'annonce : il reçoit notre position tout de suite
	end)
end

-- Personnage supprimé dans Polypode : sa position est oubliée.
if P.RegisterCharacterData then
	P.RegisterCharacterData({
		name = "Polypode Map",
		describe = function()
			return nil -- position gardée en mémoire seulement (session) : rien à signaler
		end,
		remove = function(key)
			positions[key] = nil
			ns.RefreshMembers()
		end,
	})
end

-- Envoi de sa position, que la carte soit affichée ou non (les autres en ont besoin).
C_Timer.NewTicker(SEND_TICK, function()
	if P.db then
		SendPosition()
	end
end)
