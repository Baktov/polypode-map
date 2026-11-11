-- Polypode Map: Button — bouton rond de la minicarte et entrée du compartiment d'addons (Retail)

local _, ns = ...
local P = ns.P
local L = ns.L

-- Bouton au bord de la minicarte, sans librairie (même dessin que LibDBIcon : bordure ronde de
-- suivi, fond, icône de carte), déplaçable autour d'elle (angle gardé dans minimapAngle). Affiché
-- selon l'option minimapButton : par défaut seulement quand Polypode n'est pas là (avec lui, le
-- bouton « Map » de sa barre de titre fait le même travail). Clic gauche : afficher / masquer la
-- carte ; Maj + clic gauche : la recentrer ; clic droit : options.
-- Le compartiment d'addons de Retail (## AddonCompartmentFunc du .toc) appelle les mêmes actions.

local ICON = "Interface\\Icons\\INV_Misc_Map_01"
local button

local DB = ns.Settings

-- owner nil (compartiment d'addons, dont le menu se ferme) : panneau d'options de Blizzard.
local function OnClick(owner, mouseButton)
	if mouseButton == "RightButton" then
		if owner then
			ns.ShowOptions(owner)
		elseif ns.settingsCategory and Settings and Settings.OpenToCategory then
			Settings.OpenToCategory(ns.settingsCategory:GetID())
		end
	elseif IsShiftKeyDown() then
		ns.ResetMap()
	else
		P.ToggleMap()
	end
end

local function ShowTooltip(owner)
	GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
	GameTooltip:AddLine(L["Polypode Map"])
	GameTooltip:AddLine(L["Clic gauche : afficher / masquer la carte"], 1, 1, 1, true)
	GameTooltip:AddLine(L["Maj + clic gauche : recentrer la carte"], 1, 1, 1, true)
	GameTooltip:AddLine(L["Clic droit : options de la carte"], 1, 1, 1, true)
	if owner == button then
		GameTooltip:AddLine(L["Glisser : déplacer le bouton autour de la minicarte"], 1, 1, 1, true)
	end
	if P.ShowTooltip then
		P.ShowTooltip()
	else
		GameTooltip:Show()
	end
end

-- Position sur le bord de la minicarte (ronde ; carrée : le bouton reste sur le cercle inscrit).
local function Place()
	local angle = math.rad(DB().minimapAngle or 215)
	local radius = (Minimap:GetWidth() / 2) + 5
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
	local mx, my = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local cx, cy = GetCursorPosition()
	DB().minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx)) % 360
	Place()
end

local function Build()
	button = CreateFrame("Button", "PolypodeMapMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetSize(20, 20)
	background:SetPoint("TOPLEFT", 7, -5)
	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(ICON)
	icon:SetSize(17, 17)
	icon:SetPoint("TOPLEFT", 7, -6)
	icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")

	button:SetScript("OnClick", OnClick)
	button:SetScript("OnEnter", ShowTooltip)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	button:SetScript("OnDragStart", function(self)
		GameTooltip:Hide()
		self:SetScript("OnUpdate", OnDragUpdate)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	Place()
end

-- Bouton affiché ou masqué selon l'option (appelé à la connexion et quand l'option change).
function ns.ApplyMinimapButton()
	if DB().minimapButton then
		if not button then
			Build()
		end
		button:Show()
	elseif button then
		button:Hide()
	end
end

-- Compartiment d'addons (Retail) : fonctions globales nommées dans le .toc.
function PolypodeMap_OnAddonCompartmentClick(_, mouseButton)
	OnClick(nil, mouseButton)
end
function PolypodeMap_OnAddonCompartmentEnter(_, menuButton)
	ShowTooltip(menuButton)
end
function PolypodeMap_OnAddonCompartmentLeave()
	GameTooltip:Hide()
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
	ns.ApplyMinimapButton()
end)
