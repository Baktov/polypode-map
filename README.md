# Polypode Map

Petite carte de zone **permanente** (redimensionnable, zoomable, estompable) qui montre où sont
les **personnages de votre équipe Polypode**, même hors du groupe, avec les quêtes, les points
d'intérêt, les points TomTom et les notes HandyNotes. Elle remplace **EnhanceBattlefieldMinimap**
et la librairie Scorpio, sans aucune librairie. Addon compagnon de
[Polypode](https://github.com/Baktov/polypode), séparé : chargé ou non depuis la liste des AddOns
de WoW, par personnage.

Nécessite **Polypode 2.5.0** ou plus récent.

---

## Installation

1. Installer d'abord **Polypode** (dépendance obligatoire).
2. Placer le dossier `Polypode_Map` dans `World of Warcraft/_retail_/Interface/AddOns/`
   (et, pour **WoW Forever**, dans `World of Warcraft/_classic_beta_/Interface/AddOns/`, par
   exemple par une jonction `mklink /J`).
3. Cocher « Polypode Map » dans la liste des AddOns **sur chaque personnage** : chacun envoie sa
   position aux autres.
4. Désactiver **EnhanceBattlefieldMinimap** (et Scorpio s'il ne sert plus à rien d'autre) : les
   deux cartes peuvent cohabiter, mais font double emploi.

---

## Utilisation

Le bouton **Map** (barre de titre de la fenêtre Polypode, clic gauche) ou `/poly map`
(`/poly carte`) affiche ou masque la carte. Clic droit sur le bouton ou sur l'en-tête de la carte :
options.

| Geste | Effet |
|---|---|
| Survol | En-tête (nom de la zone, coordonnées du curseur), poignée de taille, carte opaque |
| Glisser l'en-tête | Déplacer la carte |
| Poignée bas-droite | Redimensionner la carte |
| Cadenas de l'en-tête | Figer / libérer la carte (ni déplacement ni redimensionnement) |
| Molette | Zoom (plus de niveaux que la carte de Blizzard), gardé d'une zone à l'autre |
| Glisser sur la carte | Déplacer la vue |
| Clic sur la carte | **Ping** : signal animé de 5 s, montré aussi sur la carte de vos autres personnages |
| Alt + clic droit | Point **TomTom** à cet endroit (si TomTom est installé) |
| Croix de l'en-tête | Masquer la carte |

Quand la souris n'est pas sur la carte, elle **suit le joueur** : carte de sa zone, centrée sur
lui (option). L'en-tête affiche alors vos propres coordonnées.

### Personnages de l'équipe

Chaque personnage de l'**équipe sélectionnée** dans Polypode (ou de tout le roster, option) a un
repère : point en couleur de classe, **nom** au-dessus, **couronne** pour le leader de l'équipe.
Infobulle : nom complet, leader, origine de la position et son âge, zone.

- Personnage **dans votre groupe** : position en direct (la carte de Blizzard l'aurait aussi).
- Personnage **hors du groupe** : sa position est envoyée par son propre client (Polypode Map
  doit y être installé), toutes les 2 s quand il bouge, toutes les 30 s sinon. Une position
  reçue il y a plus de 75 s est estompée, plus de 5 min retirée.
- En **instance**, WoW ne donne aucune position aux addons : le repère disparaît.

Votre propre position reste la flèche de Blizzard ; les membres du groupe gardent aussi leur
point de Blizzard sous le repère.

### Autres données sur la carte

- Blizzard : exploration, points d'intérêt, maîtres de vol, entrées de donjon et de gouffre,
  vignettes (rares, trésors visibles), événements, champs de bataille, tombe du joueur...
- **Quêtes** (option) : quêtes en cours et disponibles, objectifs bonus, contenu suivi, point de
  navigation ; **expéditions** (option).
- **TomTom** (option) : les points de TomTom et des autres addons qui passent par la librairie
  HereBeDragons. Quand la grande carte (M) est ouverte, ils y sont ; ils reviennent sur la petite
  carte à sa fermeture.
- **HandyNotes** (option) : notes de ses modules, si l'addon est installé.
- **RareScanner** n'est pas repris : ses repères sont liés à la grande carte. Les rares visibles en
  jeu apparaissent par les vignettes de Blizzard.

---

## Options

Dans **Options → AddOns → Polypode → Map**, et dans la petite fenêtre du clic droit (réglages
propres à chaque personnage) :

| Option | Défaut | Effet |
|---|---|---|
| Afficher la carte | Oui | Comme le bouton **Map** et `/poly map` |
| Figer la carte | Non | Ni déplacement ni redimensionnement (comme le cadenas) |
| Suivre le joueur | Oui | Hors survol : carte de votre zone, centrée sur vous |
| En-tête toujours visible | Non | Nom de la zone et coordonnées affichés en permanence |
| Opacité hors survol | 100 % | Carte estompée quand la souris n'est pas dessus |
| Taille de la fenêtre | 100 % | Échelle de toute la fenêtre |
| Taille des icônes | 70 % | Icônes de Blizzard (quêtes, points d'intérêt...) |
| Taille des personnages | 100 % | Votre flèche, les points du groupe et les repères de Polypode |
| Noms des personnages | Oui | Nom au-dessus de chaque repère |
| Tous les personnages | Non | Tout le roster au lieu de l'équipe sélectionnée |
| Quêtes | Oui | Quêtes, objectifs bonus, contenu suivi |
| Expéditions | Oui | Quêtes mondiales de la zone |
| Points TomTom | Oui | Points TomTom / HereBeDragons ; Alt + clic droit pour en créer |
| HandyNotes | Oui | Notes de HandyNotes |
| Ping au clic | Oui | Clic sur la carte : ping chez vous et vos autres personnages |
| Plan de la fenêtre | Bas | Plan d'affichage par rapport au reste de l'interface |

---

## Fonctionnement

- La carte est une instance du moteur commun aux cartes de Blizzard (celui de la grande carte et
  de la carte de zone Maj + M) créée par l'addon : mêmes images, mêmes repères de Blizzard, sans
  modifier ni accrocher les cartes de Blizzard (c'est ce qui rendait EnhanceBattlefieldMinimap
  fragile à chaque mise à jour).
- Positions et pings passent par la synchronisation de Polypode (token, comptes autorisés), en
  chuchotement addon entre vos clients ; ils ne sont pas sauvegardés.
- Un personnage supprimé dans Polypode (Maj + clic) : sa position est oubliée.

---

## Version

`1.0.0` : première version (carte permanente, personnages de l'équipe synchronisés, quêtes,
expéditions, TomTom, HandyNotes, ping).
