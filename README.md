# FFA Radar HUD

**Author:** goddot  
**Game:** Beyond All Reason (BAR)  
**File:** `ffa_radar_hud.lua`  
**Type:** Spectator / FFA overlay

---

## Overview

FFA Radar HUD is a spectator widget that renders a real-time **hexagon radar chart** comparing the top active players in a Free-For-All match across six key performance dimensions. At a glance you can see who is winning the economy, who has the most military presence, and where each player is strong or weak relative to the field.

The chart updates every second and is fully draggable so it can be placed anywhere on screen.

---

## Installation

1. Copy `ffa_radar_hud.lua` into your BAR widgets folder:
   ```
   Beyond All Reason/LuaUI/Widgets/ffa_radar_hud.lua
   ```
2. Launch BAR and open the widget list with **F11**.
3. Find **FFA Radar HUD** and enable it.

The widget is only meaningful when spectating or playing an FFA. It will show a waiting message if fewer than 2 non-dead players are detected.

---

## What it shows

The chart has **six axes** arranged as a hexagon, evenly spaced clockwise starting from the top:

| Axis | Label | Description |
|------|-------|-------------|
| Top | **M/s** | Metal income per second |
| Top-right | **E/s** | Energy income per second |
| Bottom-right | **BP** | Total build power (sum of `buildSpeed` across all constructors and factories) |
| Bottom | **MP** | Current metal stored |
| Bottom-left | **AV** | Army value — total metal cost of mobile combat units, health-weighted |
| Top-left | **DV** | Defense value — total metal cost of static defense structures, health-weighted |

**Health weighting** means a unit at 50% HP contributes half its metal cost to AV or DV. This gives a more accurate picture of actual combat strength than a raw cost sum.

---

## How the chart is scaled

Each axis is **independently normalised** to the maximum value held by any of the displayed players at that moment. The player who leads on a given axis always reaches the outer ring at 100%. Every other player is drawn proportionally to that leader.

This means:
- A player dominant across all six axes fills the hexagon completely.
- A player who leads only on economy but has no army will show a large M/s and E/s reach but a collapsed AV and DV.
- The chart shape is what matters — it reveals each player's strategic profile, not just their absolute numbers.

Because each axis scales independently, you **cannot** compare the absolute magnitude of M/s against AV by looking at spoke length — only the relative comparison between players on the same axis is meaningful.

---

## Scale labels

Tiny silver labels are drawn along each spoke at the 25%, 50%, 75% and 100% ring intersections, showing the actual value that ring represents on that axis. Labels are nudged slightly off the spoke line so they remain legible. Values are formatted as:

- `0.5` for small decimals
- `42` for integers above 10
- `1.2k` for thousands
- `14k` for large thousands

---

## Player display

Up to **6 players** are shown simultaneously. Players are sorted by army value descending — the strongest army claims the first slot. If fewer than 5 players are active, all remaining players are shown. The display never drops below 2 players.

Each player is rendered as:
- A **semi-transparent filled polygon** in their colour
- A **coloured outline** at 85% opacity
- **Small dots** at each of the six axis vertices

Player **names** are placed in their colour around the outer perimeter of the chart, evenly distributed with the author credit **goddot** occupying one additional equidistant slot in silver-gray.

Player colours are taken from `Spring.GetTeamColor` where available, falling back to a built-in palette of blue, teal, purple, gold, red and green.

---

## Controls

| Action | Effect |
|--------|--------|
| **Click and drag** anywhere on the chart | Moves the chart to a new position on screen |

The chart defaults to the **mid-right** of the screen, centred 180 pixels from the right edge. On screen resize it re-anchors to this default position.

---

## Configuration

Open `ffa_radar_hud.lua` and find the `CFG` table near the top to adjust the following:

```lua
local CFG = {
    radius       = 220,    -- outer ring radius in pixels
    rings        = 4,      -- number of concentric grid rings
    maxPlayers   = 6,      -- maximum players to display
    minPlayers   = 2,      -- minimum before the chart shows
    bgAlpha      = 0.55,   -- background fill opacity
    lineAlpha    = 0.85,   -- player polygon outline opacity
    fontSize     = 14,     -- axis label font size
    labelOffset  = 28,     -- gap between outer ring and axis labels
    updateInterval = 1.0,  -- seconds between data refresh
}
```

To adjust the default screen position, find these lines in `widget:Initialize` and `widget:ViewResize`:

```lua
CFG.cx = screenW - 180   -- horizontal centre: pixels from the right edge
CFG.cy = screenH * 0.50  -- vertical centre: 0.0 = bottom, 1.0 = top
```

---

## Performance notes

- Unit classification (`classifyUnitDefs`) runs **once at startup** and is cached. No per-frame work on `UnitDefs`.
- The data refresh (`refreshData`) runs at most once per `updateInterval` second, not every frame.
- Drawing uses native Spring `gl.*` calls with no external libraries.
- The widget is self-contained and has no dependencies on other widgets.

---

## Compatibility

- Requires **Beyond All Reason** on the Spring engine with **Lua 5.1**
- All Spring API calls use the numeric argument forms required by BAR — no deprecated string flags
- Does not reference the deprecated `isCommander` field
- Compatible with both spectator and player modes (though most useful when spectating FFA)
