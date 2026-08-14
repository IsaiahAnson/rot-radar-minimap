# Rot Radar Minimap

**R.E.P.O.-style toggleable minimap for Grain Rot.**

Grain Rot gives you one map on a table back at the elevator. Rot Radar draws
a live, floating minimap on your screen instead: rooms and corridors of the
actual generated dungeon, the spawn elevator marked in green, your position
and facing as an arrow, and your teammates as squares in their own player
colors.

The whole map auto-rotates so the spawn elevator's opening faces up — the
direction you walked out of it is always "up" on the map, every run.

## Controls

| Key | Action |
|---|---|
| **M** | Toggle the minimap |
| **Numpad + / -** | Resize |
| **Home / End / Delete / Insert** | Nudge map position on screen |
| **F9** | Debug info dump (UE4SS console) |
| **F8** | Dungeon grid dump (for bug reports) |

## Installation (manual)

1. Install [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) — an
   **experimental** build (v3.0.1-1021 or newer) — into
   `Grain Rot\Helden\Binaries\Win64\`.
2. Copy this package's `UE4SS_Signatures` folder into the `ue4ss` folder
   (next to `UE4SS.dll`). **Required** — without these signature files UE4SS
   crashes at startup on this game's engine version (UE 5.7).
3. Copy `Mods\MiniMap` into `ue4ss\Mods\`.

The included `enabled.txt` activates the mod — no `mods.txt` editing needed.

## Multiplayer

Works as **host or joining client** — the map is built from replicated
dungeon data, so you get the real layout either way. Purely visual and
local: friends don't need the mod, and nothing in the game files is
modified.

## How it works

- The map is self-rendered from the dungeon generator's own room grid
  (rooms, corridors, and attached sub-dungeon actors), not from a texture —
  one pooled UMG image per room rect, seams inset so the layout reads
  clearly.
- Rooms that only report a bounding box (no per-tile data) are drawn as a
  dim mid-tone "hint" layer; they're real rooms, just imprecise.
- The active run is identified via the game's replicated current-run state,
  and per-run data resets on the run seed changing — the dungeon actor
  itself is reused between runs.
- Per-frame work rides a hook on the player's animation update; there are no
  timers and no key-state APIs (both crash this UE4SS/UE 5.7 combination).

## Tuning

Colors, sizes, and layout knobs live at the top of
`Mods/MiniMap/Scripts/main.lua`. UE4SS hot reload (Ctrl+R, only while idle —
never during a level transition) applies changes without restarting.

## Credits

Runs on [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS). Signature fixes
from UE4SS issue #1228.
