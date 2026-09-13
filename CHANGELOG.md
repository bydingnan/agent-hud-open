# Changelog

Releases of Agent HUD Open. A version is a git tag `vX.Y.Z` on `main`; `CFBundleShortVersionString` in `scripts/build-app.sh` carries the same number. Each entry lists what changed for people using the application and, under **Host API**, what changed for applications that embed `AgentHUDCore` and `AgentHUDDesktop`. Dates are tag dates.

## 0.4.5 — 2026-09-13

- Notch glow styles: besides the blurred band, a halftone dot grid, ASCII characters, shade blocks, Braille and binary digits (`GlowStyle`), with grid pitch, density and spread controls in Settings → Display.
- Motion effects for the grid styles while an agent is running — breathe, flow, scan, ripple, shimmer and boot (`GlowEffect`) — drawn at 24 fps from a display link and eased in and out.
- Running out of quota is its own alert: a window that reaches zero notifies once, even after the earlier at-risk warning.
- Source comments cite `THIRD_PARTY_NOTICES.txt`.
- Host API: `GlowStyle`, `GlowEffect`, `GlowPattern`, `GlowMatrix` and `GlowMotion` in AgentHUDCore; `Settings.glowStyle`, `glowGridPitch`, `glowGridSpread`, `glowGridDensity` and `glowEffect` (an unknown stored value falls back to the blurred glow instead of failing the decode); `QuotaAlertTracker.Update.exhaustedAgentIDs`.

## 0.4.4 — 2026-09-13

- Settings pages supplied by the host appear in the settings sidebar; the window widens to fit the widest page.
- Account refresh is separated from local activity: cached readings stay visible next to a refresh error, liveness follows source observation times, and a slow quota query no longer delays local polling.
- Live status can be switched off per agent in Settings → Agents without affecting collection, history or quota windows.
- The Pi lifecycle observer (`extensions/agent-hud.ts`) is installed automatically when a Pi directory exists; `--install-pi-observer` installs it by hand.
- A completion hook that belongs to another installation is preserved and reported instead of overwritten; `--install-completion-hook` takes ownership explicitly.
- Expired, removed or rejected Kimi / GLM / OpenCode Go credentials retire their quota rows; verified Kimi account identities survive restarts through a hashed local cache.
- Display sliders are debounced; the README shows the animated preview and a statistics screenshot.
- Host API: `DesktopSettingsPage` and `DesktopApplication(options:settings:store:additionalMenuActions:additionalSettingsPages:)`; `DesktopApplication.showSettings(pageID:)`; `UsageProvider.refreshAccountUsage(historyHours:)` with a no-op default; `RetainedUsageProvider` rethrows a failed fetch instead of returning the cached report (`UsageStore.lastError` carries the message while the previous report stays visible); `SessionObservers.configure(executable:)` replaces implicit adapter setup; `CompletionHooks.configure(_:enabled:executable:home:replacingExisting:)`; `PiSessionObserver`; `Settings.liveStatusEnabled(for:)` and `setLiveStatus(for:enabled:)`; `UsageEvent` moved to `Models/` with `TranscriptSession.UsageEvent` kept as an alias; `UsageAnalytics` moved to `Logic/` and `QuotaHistoryStore` to `Store/`; `UsageReport.services` and `activeQuotaPoolIDs`; `LiveSession.observedAt` and `isLive(at:)`; `AgentSettingsGroup.hasLiveStatus`; an `Equatable` overload of `observeChanges`; the `AgentHUDDesktopTests` target.
- Known: `scripts/build-app.sh` still stamped `0.4.3` at this tag.

## 0.4.3 — 2026-09-10

- Kimi turn identifiers taken from loop events match the identifiers reported at turn end, so a finished Kimi turn is recognised as the one that started.

## 0.4.2 — 2026-09-10

- DeepSeek Harness reports explicit running and terminal turn observations (`SessionTurn`) instead of relying on log freshness alone.
- Kimi turns are tracked from the main agent's loop events: `step.begin` starts a turn, `turn.ended` finishes it, and child agents cannot finish the parent.
- New document: session lifecycle coverage.

## 0.4.1 — 2026-09-10

- A quiet DeepSeek turn stays active while a Node process that predates the turn still holds the Harness profile; process inspection reads only executable identity and start time.

## 0.4.0 — 2026-09-10

- Continuous integration: source-boundary check (`scripts/check-source-boundaries.py`, `make check`), unit tests, release build, signature and resource verification.
- Demo mode seeds its preferences with the sample agents.

## 0.3.0 — 2026-09-10

- Native macOS application (`AgentHUDDesktop`, `AgentHUDOpen`): menu bar item, notch glow and hover panel, quota and completion alert views, onboarding, settings (General, Agents, Display), statistics window, snapshot rendering, and the `⌘⌥H` shortcut.
- `Makefile` and `scripts/build-app.sh` produce an ad-hoc signed `build/Agent HUD Open.app` with the bundled logos, `LobeIcons-LICENSE.txt` and `THIRD_PARTY_NOTICES.txt`.
- New document: architecture.
- Host API: `DesktopApplication(options:settings:store:additionalMenuActions:)`, `DesktopMenuAction`, `DesktopLaunchOptions`, `observeChanges`, `SnapshotRunner`.

## 0.2.0 — 2026-09-10

- `AgentHUDCore`: providers for Claude Code, Codex Desktop / CLI, DeepSeek Harness, Antigravity, Cursor, Grok CLI, OpenCode, Kimi, GLM and Pi; usage models, local caches, quota history, alerts, forecasts, chart data, localization and demo data.
- `THIRD_PARTY_NOTICES.txt` and the data-access document.
- Host API: `UsageProvider`, `CombinedUsageProvider`, `RetainedUsageProvider`, `UsageStore`, `SettingsStore`, `UsageReport` and the model types.

## 0.1.0 — 2026-09-10

- `AgentHUDSupport`: `JSONValue` (integer-preserving JSON) and `RecordCoding` (deterministic encoding, millisecond dates, hashed identities).
- Apache-2.0 license and the roadmap.
