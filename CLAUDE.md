# CLAUDE.md — Polypode Map (Addon WoW)

Conventions communes et procédure de documentation de tous les modules Polypode (chargées
automatiquement, quel que soit le dossier ouvert) :

@../Polypode/MODULES.md

Addon compagnon de **Polypode** (dossier voisin `../Polypode`, dépôt séparé) : petite carte de zone
permanente qui montre les personnages de l'équipe (même hors du groupe), les quêtes et les repères
d'autres addons ; remplace EnhanceBattlefieldMinimap (dépendant de la librairie Scorpio). Rester
**simple** : on n'ajoute une fonctionnalité que si elle sert directement ce rôle.

## Principe

La carte (`PolypodeMapCanvas`) est une **instance du moteur de carte de Blizzard** (`MapCanvasMixin`,
celui de `WorldMapFrame` et `BattlefieldMapFrame`), construite en Lua : le conteneur défilant
(`MapCanvasFrameScrollContainerTemplate`) est créé **avant** `MapCanvasMixin.OnLoad`, qui en a besoin.
Aucun hook ni réécriture des cadres de Blizzard (ce qui cassait EBFM à chaque patch) : les
fournisseurs de repères de Blizzard (`*DataProviderMixin` de `Blizzard_SharedMapDataProviders` et
`WorldMap_WorldQuestDataProviderMixin`) sont instanciés sur notre carte, chacun testé (`_G[nom]`,
`pcall`) car WoW Forever n'a pas tout. Les repères sans modèle XML (ceux du module, ceux de
HereBeDragons) ont une réserve déclarée à l'avance (`ns.RegisterPinPool` :
`CreateUnsecuredRegionPoolInstance`, mixin posé à la création, `SetMouseMotionEnabled` avant
`AcquirePin`, remise à zéro calquée sur celle du moteur).

Pièges connus :
- Un fournisseur qui démarre un minuteur dans `OnShow` (expéditions : `assert(self.ticker == nil)`)
  doit être ajouté ou retiré **carte masquée** (`SetProviderGroup` masque puis réaffiche) :
  `RemoveDataProvider` n'appelle pas `OnHide`.
- Positions : `C_Map.GetPlayerMapPosition` ne marche que pour soi et le groupe, et ne renvoie rien
  en instance ; valeurs secrètes écartées par `issecretvalue` (`ns.IsSecret`).
- Les icônes de HereBeDragons n'ont qu'un parent : la carte du monde les reprend à son ouverture,
  nous les reprenons à l'image suivante de chaque modification et à sa fermeture.

## Architecture

| Fichier | Rôle |
|---|---|
| `Polypode_Map.toc` | `## Dependencies: Polypode`, `## OptionalDeps: TomTom, HandyNotes` (chargés avant), SavedVariables par personnage `PolypodeMapDB` (`DEFAULTS` complétés à `ADDON_LOADED`) ; ordre `Map → Members → Plugins` |
| `Map.lua` | Réglages (`ns.Settings`, `ns.DEFAULTS` : `shown`, `locked`, position/taille `point`/`relativePoint`/`x`/`y`/`width`/`height`, `scale`, `opacity`, `strata`, `followPlayer`, `headerAlways`, `pinScale`, `memberScale`, `showNames`, `showAll`, `showQuests`, `showWorldQuests`, `showHereBeDragons`, `showHandyNotes`, `ping`, `zoom` 0-1) ; `ns.RegisterPinPool` ; carte (`CreateCanvas` : niveaux de repères `FRAME_LEVELS` de la carte du monde + `PIN_FRAME_LEVEL_POLYPODE_MEMBER` / `_PING`, pas de navigation ni de zoom au clic, zoom progressif, `ExtendZoomLevels` = jusqu'à 8 niveaux ×1,25 par couche, `AddCanvasClickHandler` → `ns.clickHandlers`, zoom gardé `SaveZoom` / `ApplyZoom` en pourcentage) ; fournisseurs `PROVIDER_GROUPS.base` (toujours), `quests`, `worldQuests` (`ns.ApplyProviders`, `SetProviderGroup`), `AreaLabelDataProviderMixin`, `GroupMembersDataProviderMixin` (`ns.groupMembersProvider`, tailles × `memberScale`, `ns.ApplyMemberScale`) ; fenêtre `PolypodeMapFrame` (`P.ui.mapFrame`, `BackdropTemplate`, bornes 160×120 à 1600×1200) : en-tête posé sur la carte (zone colorée selon `C_PvP.GetZonePVPInfo`, coordonnées curseur / joueur, cadenas `ns.SetLocked`, croix), affiché au survol ou toujours (`headerAlways`), glisser = déplacer, clic droit = options ; poignée bas-droite ; `OnUpdate` à 0,1 s : survol (`UpdateHover` : opacité, en-tête, poignée), coordonnées, suivi du joueur toutes les 0,2 s hors survol (`SetMap(PlayerMapID())`, `CenterOnPlayer`) ; `P.ToggleMap(show)` ; options (`BuildSettingsPanel` à `PLAYER_LOGIN` + 1 image : sous-catégorie « Map » de `P.optionsCategory`, `ns.settingsPopup` pour `P.ToggleOptionsPopup`) ; bouton `P.ui.mapButton` (`P.AddTitleButton`, clic droit = options), `/poly map` et alias `/poly carte` ; `P.RefreshUI` accroché → `ns.RefreshMembers` ; événements de zone → carte du joueur et nom de zone |
| `Members.lua` | Positions : `OwnWorldPosition` (carte du joueur → coordonnées du monde, `C_Map.GetWorldPosFromMapPos`), `WorldToMap` (`C_Map.GetMapPosFromWorldPos` sur la carte affichée, bornée 0-1), `MemberMapPosition` (groupé : `C_Map.GetPlayerMapPosition` en direct ; sinon position reçue) ; envoi `SendPosition` toutes les 0,5 s (minuteur permanent, carte affichée ou non) : à `Recipients()` = personnages connectés (`P.IsCharacterOnline`) hors du groupe, si déplacement ≥ 3 et ≥ 2 s depuis le dernier envoi, ou toutes les 30 s ; message `MAPPOS:token:continent:x:y:uiMapID:nom-royaume` (position vide = inconnue) par `P.WhisperOnline`, envoi forcé au client qui s'annonce (`P.RegisterPeerCallback`) ; réception `OnPositionMessage` (`P.IsSender`) → `positions[clé]` (mémoire, session). Repères `PolypodeMapMemberPin` (`MemberPinMixin` : point `WhiteCircle-RaidBlips` en couleur de classe, bordure, nom, couronne `groupfinder-icon-leader` du leader de l'équipe sélectionnée, taille constante à l'écran, estompé après 75 s, masqué après 5 min ; infobulle) gérés par `MemberProviderMixin` (`ShownKeys` : équipe sélectionnée ou roster si `showAll` / pas d'équipe, soi exclu ; mise à jour toutes les 0,2 s carte affichée) ; `ns.RefreshMembers`. Ping : clic gauche sans modificateur (`OnCanvasClick`, 0,5 s entre deux) → `AddPing` local + `MAPPING:token:continent:x:y:nom-royaume` à tous les clients connectés ; repère `PolypodeMapPingPin` animé 5 s (`PingProviderMixin`). `P.RegisterCharacterData` (personnage supprimé → position oubliée) |
| `Plugins.lua` | HereBeDragons-Pins (`LibStub`, TomTom...) : réserve `HereBeDragonsPinsTemplate` avec `pins.worldmapProviderPin`, fournisseur copié de `pins.worldmapProvider` **avant** les accroches (`RefreshAllData`, `HandlePin`, `RemovePinByIcon`, `RemovePinsByRef`, fermeture de `WorldMapFrame`, affichage de la carte → `RefreshSoon`, image suivante, carte du monde fermée) ; Alt + clic droit → `TomTom:AddWaypoint(mapID, x, y, { title, from })` ; HandyNotes : copie de `HandyNotes.WorldMapDataProvider`, accroches `UpdateWorldMapPlugin` / `UpdateWorldMap` (non testé : HandyNotes absent du poste de développement) ; `ns.ApplyPluginProviders(setGroup)` (groupes `hereBeDragons`, `handyNotes`), `ns.InitPlugins` |

## Dépendances vers Polypode (API publique utilisée)

`P.AddTitleButton`, `P.RegisterSlashCommand`, `P.optionsCategory`, `P.ToggleOptionsPopup`,
`P.ColorClicks`, `P.ShowTooltip` (ces trois si présentes), `P.RegisterMessageHandler`,
`P.RegisterPeerCallback`, `P.WhisperOnline`, `P.IsSender`, `P.GetTeamToken`, `P.GetCharKey`,
`P.GetCharacter`, `P.GetDisplayName`, `P.GetTargetName`, `P.IsCharacterOnline`, `P.FindGroupUnit`,
`P.GetSelectedTeam`, `P.GetTeamMembers`, `P.GetTeamLeader`, `P.GetCharacterStatus`, `P.db.roster`,
`P.RegisterCharacterData`, `P.RefreshUI` (accroche), `P.ui`. Toute évolution de ces fonctions dans
Polypode doit rester compatible, ou ce fichier doit suivre.

## Pistes

- RareScanner : non repris (repères liés en dur à `WorldMapFrame` / `RSWorldMap` dans sa 12.1.5).
- Questie, minimap intégrée à la carte (fonctions d'EBFM) : écartées pour rester simple.
- Raccourci clavier pour afficher / masquer la carte (`Bindings.xml`) si le besoin se présente.

## Après chaque modification

Appliquer la procédure de `../Polypode/MODULES.md` (« Après chaque modification d'un module »),
sans attendre qu'on le demande : version du `.toc` et du commit, ligne en tête de la section
« Version » du `README.md` et sections d'utilisation, ce fichier (architecture, dépendances),
Polypode si le périmètre change, puis commit et push sur `origin` (https://github.com/Baktov/polypode-map).
