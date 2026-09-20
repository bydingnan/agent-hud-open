# The HUD on screen

## Overview

The HUD sits at the top of every attached display, and each display carries its own. A Mac with a notch keeps the island around it; a display without one shows the watched agents' own logos in a row. Both are backed by the same glow, which reads as a rim around the island and as a backdrop behind the logos. Every display is configured on its own, so a laptop and the monitor beside it need not agree on anything.

## Model

| Concept | Meaning |
|---|---|
| HUD | One display's presentation: a collapsed shape at the screen's top edge, the panel it opens into, and the glow behind both |
| Notch mode | The island: the physical notch on a Mac that has one, or a bar standing in for it on a display that does not |
| Logo queue | A row of marks, one per watched vendor, centred at the screen's top edge with no shape behind them |
| Glow | Colour drawn from the enabled windows' levels — a rim around the island, a curtain falling from the top edge behind a queue |
| Placement | What one display shows and how large: mode, logo size, logo spacing, whether the marks are drawn |

## Rules

### Placement

- A display with a notch defaults to notch mode; a display without one defaults to the logo queue, so no screen draws a bar pretending to have a notch.
- Either mode can be chosen for any display, including a notched one; a queue on a notched Mac is centred on the screen, so the notch covers the marks behind it.
- A display keeps its own placement, keyed by the display's UUID, and a newly attached display needs no setup.
- The queue runs along the top edge, centred. Logo size is 12–24 pt and spacing is 0.1–0.6 of the logo; the number of marks that fit is an outcome, never a setting.
- The marks can be hidden, which leaves the backdrop alone, still where they would have been and as wide.

### What the queue shows

- One mark per vendor among the enabled, non-API-billed agents, in the order the agents are watched in: two Claude windows are one Claude.
- A mark is drawn whether or not that agent has ever reported anything; an enabled vendor always has one.
- A mark bobs while any session of its vendor is live, including a turn blocked on the user, and holds still otherwise, so motion means exactly one thing.
- A queue with nothing to show — no enabled agent — falls back to the screen's notch shape.
- Marks keep their own artwork at full strength with a hairline outline; a single-colour mark is drawn white. Status colour is carried by the glow behind them, never by the logos.

### Hovering and events

- A collapsed queue takes no mouse events, so clicks reach the menu bar and whatever window is under it; the pointer is followed by an event monitor instead.
- Hovering opens the panel, inward from the edge the HUD sits on. Hovering can be asked to take Option as well, which leaves an accidental pass over the HUD closed.
- An event is shown once, on the display the pointer is on: repeating it on every screen would mean dismissing the same thing several times.
- A queue's glow is a backdrop, never a rim: once the panel opens or an event widens the island, the field stops rather than following the new shape around. Only a notch is rimmed.
- The marks ride over the panel while it is open, so opening the HUD never makes the agents disappear.

### The glow

- Every display has its own glow: style, effect, speed, reach and density are set per screen, and a display with none of its own follows the default.
- The falloff is two settings, both counted in rows: how many keep full strength, and how many the glow fades away over. The fade is Gaussian, so it leaves the solid rows level instead of dropping at once.
- The effect plays at the working period while any agent runs and at the idle period otherwise; the glow never stops, it only slows down, so a resting HUD still reads as alive.
- Every effect takes the period, not only breathing. Grid styles are dithered by each cell's place in the Bayer matrix, which keeps the average density and breaks up the stripes a distance-only level would produce.
- The whole HUD shares one drawing budget across displays, so a second screen costs frames rather than processor. A blurred glow never enters the frame loop; an idle one is sampled at 8 frames a second.
- Reduce Motion holds the resting frame and turns the island's geometry changes into a cross-fade.

## Interfaces and configuration

| Setting | Values | Default |
|---|---|---|
| `screens[<display UUID>].mode` | `notch`, `logos` | By hardware: `notch` with a notch, `logos` without |
| `screens[…].logoSize` / `gapScale` | 12–24 pt / 0.1–0.6 of the logo | 20 pt / 0.4 |
| `screens[…].showsLogos` | Draw the marks, or the backdrop alone | `true` |
| `screenGlow[<display UUID>].style` | `blur`, `dots`, `ascii`, `blocks`, `braille`, `binary` | `blur` |
| `screenGlow[…].effect` | `breathe`, `flow`, `scan`, `ripple`, `shimmer`, `boot` | `breathe` |
| `screenGlow[…].breathSeconds` / `idleBreathSeconds` | 1–24 s, the period every effect plays at | 3 s / 7 s |
| `screenGlow[…].gridCore` / `gridFade` | 0–8 rows at full strength / 0–8 rows to fade over | 0 / 5 |
| `screenGlow[…].gridPitch` / `gridDensity` | 4–12 pt between cells / 50–150% of a cell filled | 10 pt / 100% |
| `screenGlow[…].range` / `blur` | 0–36 pt reach / 0–36 pt feather, for the blurred style | 14 pt / 8 pt |
| `screenGlow[…].brightness` / `breathAmplitude` | 20–100% / how deep the breath dips | 90% / 60% |
| `requiresOptionToOpen` | Hovering alone leaves the panel closed | `false` |

`Settings.placement(on:hasNotch:)` and `glow(on:)` answer what one display uses, falling back to the default when it has none of its own. Both are keyed by the string `ScreenIdentity.key(for:)` returns for a display.

## Code map

| Concept | Where |
|---|---|
| Per-display placement and glow | `Sources/AgentHUDCore/Models/ScreenPlacement.swift`, `GlowSettings.swift`, `Settings.swift` |
| One HUD per screen, and what they share | `Sources/AgentHUDDesktop/Notch/ScreenHUD.swift`, `IslandController.swift`, `ScreenIdentity.swift` |
| Where a HUD sits on its screen | `Sources/AgentHUDDesktop/Notch/NotchGeometry.swift` |
| The marks and their motion | `Sources/AgentHUDDesktop/Notch/LogoQueueView.swift`, `LogoImages.swift` |
| Glow geometry, falloff and frames | `Sources/AgentHUDCore/Logic/GlowGeometry.swift`, `GlowMatrix.swift`, `GlowMotion.swift`; `Sources/AgentHUDDesktop/Notch/GlowWindowController.swift`, `GlowFrameRenderer.swift`, `GlowAnimator.swift` |
| Collapsed shape, panel and events | `Sources/AgentHUDDesktop/Notch/IslandRootView.swift`, `IslandWindowController.swift` |
| Settings for both | `Sources/AgentHUDDesktop/Settings/ScreensPane.swift`, `GlowPane.swift`, `DisplayPane.swift` |

## Related

[architecture.md](architecture.md) package layout and host integration · [usage-semantics.md](usage-semantics.md) what the levels behind the colour mean · [session-lifecycle.md](session-lifecycle.md) when a session counts as live · [command-line.md](command-line.md) launch options
