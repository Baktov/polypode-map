# Polypode Map

*Version française : [README.md](README.md)*

Small **permanent** zone map (resizable, zoomable, fadable) showing where the **characters of your
Polypode team** are, even outside the group, with quests, points of interest, TomTom waypoints and
HandyNotes notes. It replaces **EnhanceBattlefieldMinimap** and the Scorpio library, with no
library at all. Separate companion addon of [Polypode](https://github.com/Baktov/polypode): enabled
or not in the WoW AddOns list, per character.

Requires **Polypode 2.5.0** or later.

> **Languages**: French, English, German, Spanish, Italian and Brazilian Portuguese, following the
> language chosen in Polypode (option "Langue / Language"). The translations were made with the help
> of Claude, Anthropic's AI: feedback from native speakers is very welcome
> ([GitHub issue](https://github.com/Baktov/polypode-map/issues)).

---

## Installation

1. Install **Polypode** first (required dependency).
2. Put the `Polypode_Map` folder in `World of Warcraft/_retail_/Interface/AddOns/`
   (and, for **WoW Forever**, in `World of Warcraft/_forever_/Interface/AddOns/`).
3. Enable "Polypode Map" in the AddOns list **on each character**: each one sends its position to
   the others.
4. Disable **EnhanceBattlefieldMinimap** (and Scorpio if nothing else uses it): both maps can live
   together, but they do the same job.

---

## Usage

The **Map** button (title bar of the Polypode window, left-click) or `/poly map` (`/poly carte`)
shows or hides the map; `/poly map reset` puts it back in the middle of the screen, at its default
size and layer (map lost). Right-click on the button or on the map header: options. **Shift +
left-click** on the button (Polypode window or module column of the floating bar): same as
`/poly map reset`.

| Gesture | Effect |
|---|---|
| Hover | Header (zone name, cursor coordinates), size grip, opaque map |
| Drag the header | Move the map |
| Left-click the header | Fit the frame to the proportions of the shown map (width kept, height recomputed; no effect if the map is locked) |
| Bottom-right grip | Resize the map |
| Header padlock | Lock / unlock the map (no moving or resizing) |
| Mouse wheel | Smooth zoom (×1.2 per notch) toward the point under the cursor, deeper than Blizzard's map, kept from one zone to the next |
| Drag on the map | Move the view |
| Click on the map | **Ping**: animated 5 s signal, also shown on the map of your other characters |
| Alt + right-click | **TomTom** waypoint at this spot (if TomTom is installed) |
| Header close button | Hide the map |

When the mouse is not over the map, it **follows the player**: map of their zone, centered on them
(option). The header then shows your own coordinates.

### Team characters

Each character of the **team selected** in Polypode (or of the whole roster, option) has a marker:
dot in class color, **name** above, **crown** for the team leader. Tooltip: full name, leader,
origin of the position and its age, zone.

- Character **in your group**: live position (Blizzard's map would have it too).
- Character **outside the group**: its position is sent by its own client (Polypode Map must be
  installed there), every 2 s when it moves, every 30 s otherwise. A position received more than
  75 s ago is faded, more than 5 min ago removed.
- In an **instance**, WoW gives addons no position at all: the marker disappears.

Your own position stays Blizzard's arrow; group members also keep their Blizzard dot under the
marker.

### Other data on the map

- Blizzard: exploration, points of interest, flight masters, dungeon and delve entrances, vignettes
  (rares, visible treasures), events, battlegrounds, player's corpse...
- **Quests** (option): current and available quests, bonus objectives, tracked content, waypoint;
  **world quests** (option).
- **TomTom** (option): the waypoints of TomTom and of other addons going through the HereBeDragons
  library. When the big map (M) is open, they are on it; they come back on the small map when it
  closes.
- **HandyNotes** (option): notes of its modules, if the addon is installed.
- **BtWQuests** (option): available quests of its quest chains and objectives of the tracked
  quests (its own map display options still apply); click on a marker: waypoint.
- **MidnightRoutine** (option): waypoint of the current routine.
- Markers placed by other addons through HereBeDragons (shown with the TomTom waypoints):
  **RXPGuides** (steps, treasures and vendors), **APR**, **WaypointUI**, **HomeDecor**...
- **All The Things**: right-click on a group of its list = TomTom waypoints, so they are shown.
- **RareScanner** is not taken over: its markers are tied to the big map. Rares visible in game
  appear through Blizzard's vignettes.

---

## Options

In **Options > AddOns > Polypode > Map**, and in the small right-click window (per-character
settings):

| Option | Default | Effect |
|---|---|---|
| Show the map | Yes | Like the **Map** button and `/poly map` |
| Lock the map | No | No moving or resizing (like the padlock) |
| Follow the player | Yes | When not hovered: map of your zone, centered on you |
| Fit the frame to each map | No | On each map change, the frame takes the proportions of the new map (like left-clicking the header); no effect if the map is locked |
| Header always visible | No | Zone name and coordinates always shown |
| Border thickness | 1 px | Border around the map, from 0 (none) to 10 pixels |
| Border color | Black | Black, grey, white, gold, blue or class color of the current character |
| Opacity when not hovered | 100% | Map faded when the mouse is not over it |
| Window size | 100% | Scale of the whole window |
| Icon size | 70% | Blizzard icons (quests, points of interest...) |
| Character size | 100% | Your arrow, the group dots and the Polypode markers |
| Character names | Yes | Name above each marker |
| All characters | No | The whole roster instead of the selected team |
| Quests | Yes | Quests, bonus objectives, tracked content |
| World quests | Yes | World quests of the zone |
| TomTom waypoints | Yes | TomTom / HereBeDragons waypoints; Alt + right-click to create one |
| HandyNotes | Yes | HandyNotes notes |
| BtWQuests | Yes | Available quests and objectives of BtWQuests |
| MidnightRoutine | Yes | MidnightRoutine waypoint |
| Ping on click | Yes | Click on the map: ping for you and your other characters |
| Window layer | 5 - Dialog (default) | Display layer, from the highest (7 - Fullscreen (dialog)) to the lowest (1 - Background); "Dialog" goes in front of the action bars and most windows, go lower if the map hides something |

---

## How it works

- The map is an instance of the engine shared by Blizzard's maps (that of the big map and of the
  Shift + M zone map) created by the addon: same images, same Blizzard markers, without changing
  or hooking Blizzard's maps (which is what made EnhanceBattlefieldMinimap fragile at each update).
- Positions and pings go through Polypode's synchronization (token, allowed accounts), as addon
  whispers between your clients; they are not saved.
- A character deleted in Polypode (Shift + click): its position is forgotten.

---

## Languages

Polypode Map follows the language chosen in Polypode ("Langue / Language" option,
`/poly language`), by default the game's: French, English, German, Spanish, Italian or Brazilian
Portuguese (English for any other language). Choosing the language requires Polypode 2.9; with an
older Polypode, the module stays in French. The `/poly map` command keeps its name.

---

## Versions

The full version history is in the [French README](README.md#version).
