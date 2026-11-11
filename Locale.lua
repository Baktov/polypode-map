-- Polypode Map: Locale — Polypode présent ou non, table de textes du module (traductions :
-- Locales/*.lua), voir Polypode/MODULES.md (« Langues »)

local _, ns = ...

-- Polypode est facultatif (## OptionalDeps : chargé avant nous s'il est installé et activé).
-- Sans lui, ns.P est une table locale (pas de variable globale Polypode, que d'autres addons
-- pourraient prendre pour le vrai) : les appels gardés « if P.X then » ne font rien, et la carte
-- s'ouvre par /pmap et son bouton de la minicarte (Button.lua). Les personnages de Polypode
-- (Members.lua) ne sont alors pas chargés.
ns.hasPolypode = type(Polypode) == "table"
ns.P = ns.hasPolypode and Polypode or { ui = {} }
local P = ns.P

if ns.hasPolypode then
	-- L[texte français] → texte dans la langue choisie dans Polypode ; avec un Polypode trop ancien
	-- (sans traductions), le texte français.
	ns.L = P.NewLocale and P.NewLocale() or setmetatable({}, {
		__index = function(_, key)
			return key
		end,
	})
else
	-- Seul : langue du jeu, langue voisine (esMX : esES), sinon anglais, sinon la clé (français).
	-- P.AddTranslations (posée sur la table locale) sert aux fichiers Locales/*.lua.
	local language = GetLocale()
	local NEIGHBOUR = { esMX = "esES", enGB = "enUS" }
	local byLanguage = {}
	ns.L = setmetatable({}, {
		__index = function(_, key)
			if language == "frFR" then
				return key
			end
			local texts = byLanguage[language] or byLanguage[NEIGHBOUR[language]] or byLanguage.enUS
			local text = texts and texts[key]
			if text == nil and byLanguage.enUS then
				text = byLanguage.enUS[key]
			end
			return text or key
		end,
	})
	function P.AddTranslations(_, locale, strings)
		byLanguage[locale] = byLanguage[locale] or {}
		for key, text in pairs(strings) do
			byLanguage[locale][key] = text
		end
	end
end

-- Appelle fn quand la langue d'affichage est connue : textes rangés au chargement (bouton de la
-- barre de titre, aide de /poly map...). Tout de suite sans Polypode ou avec un Polypode ancien.
function ns.OnLanguageApplied(fn)
	if P.OnLanguageApplied then
		P.OnLanguageApplied(fn)
	else
		fn()
	end
end
