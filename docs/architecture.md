# Architecture

## Overview

Agent HUD Open is a Swift package with three libraries and one executable. `AgentHUDCore` reads agent activity and account usage on this Mac and normalizes it into a `UsageReport`; `AgentHUDDesktop` presents that report in the menu bar, the notch and the settings and statistics windows; the standalone application wires the two together. A host application can embed the libraries, supply its own provider, and add menu actions and settings pages. Account services, synchronization and notifications are outside the package.

## Model

| Module | Responsibility | Depends on |
| --- | --- | --- |
| `AgentHUDSupport` | `JSONValue` (integer-preserving JSON) and `RecordCoding` (deterministic encoding, millisecond dates, hashed identities) | — |
| `AgentHUDCore` | Providers, usage models, calculations, local caches, quota history, the settings and usage stores | Support |
| `AgentHUDDesktop` | Menu bar item, notch glow and panel, alerts, onboarding, settings and statistics windows; its resource bundle holds every logo and notice | Core |
| `AgentHUDOpenApp` (product `AgentHUDOpen`) | Launch options, live or sample data, adapter setup, process lifetime | Desktop, Core |

`CombinedUsageProvider` runs one provider per client and merges their reports; `RetainedUsageProvider` restores the saved report at start and fills readings a partial refresh could not supply; `UsageStore` polls local activity, runs account refreshes on their own task, and publishes the report the desktop observes. A report carries quota windows, sessions, turns, completions, usage events, history, services and billing.

## Rules

### Host integration

- A host creates a `SettingsStore` and a `UsageStore` around any `UsageProvider`, then a `DesktopApplication`; it owns every additional service and its lifecycle. The shared UI never initializes account services or transports.
- `fetchUsage(agents:historyHours:)` assembles local activity with the latest account results; `refreshAccountUsage(historyHours:)` performs the slower quota, balance and account-wide requests and has a no-op default. A provider that wraps another forwards both.
- A failed full refresh keeps the previous report and exposes `UsageStore.lastError`; a partial failure keeps the missing readings from the saved report.
- The standalone application never calls `present(_:)`. Deciding that a quota alert or a completion reminder is due is a host responsibility; `QuotaAlertTracker` supplies the baseline and deduplication logic.
- Hosts apply the same Live status preference as the desktop, `Settings.liveStatusEnabled(for:)`, in any relay, reminder or synchronization service they add ([session lifecycle](session-lifecycle.md)).

### Session observers and hook ownership

- `SessionObservers.configure(executable:)`, called after creating the store and before `start()`, installs the Pi observer when the Pi directory exists and the Antigravity and Cursor stop hooks when those clients are installed. Creating a `DesktopApplication` installs nothing.
- A completion hook that points at another executable is preserved and the conflict is reported; `--install-completion-hook` transfers ownership explicitly ([completion hooks](session-lifecycle.md#completion-hooks)).

### Storage

- The standalone bundle identifier is `app.agenthud.open`; preferences live in its UserDefaults domain, with separate domains for demo and snapshot runs.
- Cached reports, transcript indexes, quota histories, hashed Kimi identities and completion records live in the data directory ([caches](providers.md#caches)); quota histories keep 30 days. No file contains conversation text or credentials.
- SwiftPM resources are located through `AppResources`; the app bundle carries `AgentHUDOpen_AgentHUDDesktop.bundle` under `Contents/Resources`.

### Design invariants

- Integer precision: whole numbers decode as `Int64` before `Double`; token counts are never rounded or interpolated.
- Deterministic identities: record ids are SHA-256 hashes of length-prefixed components, identical on every machine.
- Millisecond dates: persisted dates round-trip through milliseconds since 1970.
- Tests need no credentials or network; the only probe that touches installed clients is opt-in.
- Isolated sources: a missing, signed-out or failing client never hides another.
- No invented lifecycle: inactivity is never a completion, and a passed reset deadline is not a confirmed reset.
- Resources and notices: the root `THIRD_PARTY_NOTICES.txt` and the bundled copy stay byte-identical, and source comments cite the file.
- Source boundaries: `make check` rejects signing material, private service directories and imports, secret-shaped strings, external package dependencies and missing ignore rules.

### Versioning

- A release is a tag `vX.Y.Z` on `main`; the bundle's `CFBundleShortVersionString` equals `X.Y.Z` at that tag, `CFBundleVersion` stays `1`, and the [changelog](../CHANGELOG.md) has a matching entry that lists host-visible API changes. Hosts pin the package by tag or commit.
- There are no third-party Swift package dependencies; frameworks come from the macOS SDK.
- Continuous integration runs the boundary check, `swift test`, a release build, `codesign --verify --deep --strict`, a check that the resource bundle contains the logos, and a check that no provisioning profile was embedded. It publishes no binaries.

## Interfaces and configuration

| Item | Source | Meaning |
| --- | --- | --- |
| `DesktopApplication(options:settings:store:additionalMenuActions:additionalSettingsPages:)` | AgentHUDDesktop | Parsed `DesktopLaunchOptions`, the two stores, `[DesktopMenuAction]` (title and action closures added to the status-item menu) and `[DesktopSettingsPage]` |
| `start()`, `stop()`, `showSettings(pageID:)`, `showStats()`, `showOnboarding()`, `toggleGlow()`, `present(_:)` | `DesktopApplication` | Host entry points. `showSettings` selects a page by id (built-in `general`, `sources`, `display`; an unknown id keeps the current page); `present` shows a `QuotaAlert` or a `SessionCompletion` |
| `DesktopSettingsPage` | AgentHUDDesktop | `id`; `title` closure (follows language changes); optional `heading`; `subtitle`; `symbol` and `color` for the sidebar icon; `preferredContentWidth` in points (built-in pages use 640); `@ViewBuilder` `content` |
| Settings window | AgentHUDDesktop | 760 × 720 points, minimum 680 × 560, sidebar 212; the initial width grows to fit the widest host page |
| `SessionObservers.configure(executable:)` | AgentHUDCore | Adapter setup with the executable that handles hook callbacks |
| `AgentHUDDataDirectory` | Host `Info.plist` | Name of the data directory under `~/Library/Application Support`; default `Agent HUD Open` |
| Launch switches and probes | Standalone executable | [Command line](command-line.md) |

## Code map

| Concept | Code |
| --- | --- |
| JSON values, record coding | `Sources/AgentHUDSupport/JSONValue.swift`, `RecordCoding.swift` |
| Provider protocol, combination, retention, observers | `Sources/AgentHUDCore/Providers/UsageProvider.swift`, `CombinedUsageProvider.swift`, `RetainedUsageProvider.swift`, `SessionObservers.swift` |
| Per-client providers | `Sources/AgentHUDCore/Providers/<Client>/` |
| Models and calculations | `Sources/AgentHUDCore/Models/`, `Sources/AgentHUDCore/Logic/` |
| Stores and data directory | `Sources/AgentHUDCore/Store/UsageStore.swift`, `SettingsStore.swift`, `QuotaHistoryStore.swift`, `AppSupport.swift` |
| Application object, launch options, host pages | `Sources/AgentHUDDesktop/App/DesktopApplication.swift`, `LaunchOptions.swift`, `Settings/DesktopSettingsPage.swift` |
| Standalone entry and commands | `Sources/AgentHUDOpenApp/main.swift` |
| Build, boundary check, CI | `scripts/build-app.sh`, `scripts/check-source-boundaries.py`, `.github/workflows/ci.yml` |

## Related

[providers.md](providers.md) per-client data sources · [usage-semantics.md](usage-semantics.md) counting and alert rules · [session-lifecycle.md](session-lifecycle.md) turn evidence and hooks · [data-access.md](data-access.md) boundaries · [../CHANGELOG.md](../CHANGELOG.md) host-visible API changes
