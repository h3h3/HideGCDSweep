# HideGCDSweep

Hides the distracting GCD sweep animation on icons displayed by Blizzard's built-in Cooldown Manager — without touching real cooldown sweeps.

---

## Before / After

| Before | After |
|--------|-------|
| ![Before](before.gif) | ![After](after.gif) |

---

## What it does

Every time your Global Cooldown fires, Blizzard's Cooldown Manager icons play a brief swipe/sweep animation. When you have many abilities tracked, this creates constant visual noise on every single GCD.

**HideGCDSweep** hooks each icon's cooldown frame and suppresses the swipe and edge-flash animations for any `SetCooldown` call with a duration at or below the GCD threshold (default **2 seconds**). Real cooldowns above that threshold are left completely untouched and continue to show their sweep normally.

---

## Compatibility

- **Blizzard Cooldown Manager** — the default UI included with the game
- **[Cooldown Manager Centered](https://www.curseforge.com/wow/addons/cooldown-manager-centered)** 
- **[BetterCooldownManager](https://www.curseforge.com/wow/addons/bettercooldownmanager)**

No configuration required — install and forget.

---

## Installation

1. Download the latest release from [CurseForge](https://www.curseforge.com/wow/addons/hidegcdsweep)
2. Extract the `HideGCDSweep` folder into your `World of Warcraft\_retail_\Interface\AddOns\` directory.
3. Reload or log in — the addon activates automatically.

---

## Configuration

There are two settings at the top of `HideGCDSweep.lua` that can be adjusted manually:

```lua
local HIDE_EDGE     = true  -- Also hide the bright edge line on the GCD sweep
local GCD_THRESHOLD = 2.0   -- Durations (seconds) at or below this are treated as GCD
```

| Setting | Default | Description |
|---------|---------|-------------|
| `HIDE_EDGE` | `true` | Suppresses the bright edge flash that accompanies the sweep |
| `GCD_THRESHOLD` | `2.0` | Any `SetCooldown` call with `duration <= threshold` is considered a GCD and has its sweep hidden |

---

## How it works

On load and on relevant events (`PLAYER_ENTERING_WORLD`, `PLAYER_SPECIALIZATION_CHANGED`, entering/leaving combat), the addon iterates over Blizzard's three Cooldown Manager viewer frames:

- `EssentialCooldownViewer`
- `UtilityCooldownViewer`
- `BuffIconCooldownViewer`

For each icon found, it attaches a secure hook to `SetCooldown`. Blizzard resets draw flags on every `SetCooldown` call, so the hook reapplies them immediately after:

- **GCD call** (`duration <= 2.0 s`) → `SetDrawSwipe(false)`, `SetDrawEdge(false)`
- **Real cooldown** (`duration > 2.0 s`) → `SetDrawSwipe(true)`, `SetDrawEdge(true)`
