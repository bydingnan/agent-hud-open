# Architecture

## Overview

Agent HUD Open is a Swift package with three libraries and one executable. `AgentHUDCore` reads agent activity and account usage on this Mac and normalizes it into a `UsageReport`; `AgentHUDDesktop` presents that report in the menu bar, the notch and the settings and statistics windows; the standalone application wires the two together. A host application can embed the libraries, supply its own provider, add settings pages, and relay the island's alerts. Account services, synchronization and any relay of alerts are outside the package.

## Model

| Module | Responsibility | Depends on |
| --- | --- | --- |
| `AgentHUDSupport` | `JSONValue` (integer-preserving JSON) and `RecordCoding` (deterministic encoding, millisecond dates, hashed identities) | — |
| `AgentHUDCore` | Providers, usage models, calculations, alert decisions, the usage ledger, the settings and usage stores | Support |
| `AgentHUDDesktop` | Menu bar item, notch glow and panel, island alerts, onboarding, settings and statistics windows; its resource bundle holds every logo and notice | Core |
| `AgentHUDOpenApp` (product `AgentHUDOpen`) | Launch options, live or sample data, adapter setup, process lifetime | Desktop, Core |

`CombinedUsageProvider` reads one provider per client, one after another, and merges their reports; `UsageLedger` is the local SQLite store where providers keep parse positions, token events and quota readings, and from which the 15-minute usage and cost totals are read; `RetainedUsageProvider` restores the saved report at start and fills readings a partial refresh could not supply; `UsageCollector` runs the collection pipeline, one local poll or account step at a time, and hands each report to `UsageStore`, which publishes the report the desktop observes. A report carries quota windows, sessions, turns, completions, 15-minute usage buckets, history, services, billing and the account inventory (`ProviderAccount`, `AccountObservation`); every quota row belongs to one account.

## Rules

### Host integration

- A host creates a `SettingsStore` and a `UsageStore` around any `UsageProvider`, then a `DesktopApplication`; it owns every additional service and its lifecycle. The shared UI never initializes account services or transports.
- `fetchUsage(agents:historyHours:)` assembles local activity with the latest account results; `refreshAccountUsage(historyHours:)` performs the slower quota, balance and account-wide requests and has a no-op default; `accountRefreshSteps` splits it into steps the store runs between polls, and `watchedDirectories` names the directories whose changes need a poll (nil polls every time). A provider that wraps another forwards all of them.
- A provider that does not write the ledger reports its periods in `UsageReport.usage`; `CombinedUsageProvider` adds them to the ledger's totals.
- A failed full refresh keeps the previous report and exposes `UsageStore.lastError`; a partial failure keeps the missing readings from the saved report.
- `DesktopApplication` decides and presents island alerts itself: one `IslandEventTracker` checks every change of the report, the agent list or the Live status preference while the store is neither paused nor failing, and the island shows the new quota events and completed turns. Every host, the standalone application included, gets the same alerts without extra wiring.
- A host that relays alerts elsewhere passes `onIslandEvents`. It receives every check after the island has presented it, including checks that found nothing, with the report and time the check used; the host maps that update and never runs a second tracker or presents again.
- Completions in an update already honor `Settings.liveStatusEnabled(for:)`; hosts apply the same preference in any other relay or synchronization service they add ([session lifecycle](session-lifecycle.md)).

### Collection hooks

- A host passes `UsageCollectionHooks` to `UsageStore`; every hook is optional, and without them the store displays the provider's report and loads `UsageStore.historyHours` hours, the seven-day range plus the partial hour.
- `historyHours` is asked before every local poll and account step, so a host can widen the window providers read.
- `publish` receives each report the provider returned and `merge` turns it into the displayed report, for example to add other data. Both are awaited inside the pass, after the provider fetch and before the report is displayed; no provider reads and nothing writes the ledger meanwhile, so a hook that reads the ledger stays serial with collection.
- The merged report keeps the provider's discovered agents, accounts, active quota pools, completions and turns: the agent list and island events read them from `UsageStore.report`.
- `UsageStore.remerge()` runs only `merge` again on the provider's last report, for data the host merges that changed since the pass. It never overlaps a local poll: a poll in progress merges for it, or merges again when its own merge had already started. A report installed with `replace(report:)` is not merged over.

### Session observers and hook ownership

- `SessionObservers.configure(executable:)`, called after creating the store and before `start()`, installs the Pi observer when the Pi directory exists and the Antigravity, Cursor, GitHub Copilot CLI and CodeBuddy stop hooks when those clients are installed. Creating a `DesktopApplication` installs nothing.
- A completion hook that points at another executable is preserved and the conflict is reported; `--install-completion-hook` transfers ownership explicitly ([completion hooks](session-lifecycle.md#completion-hooks)).

### Storage

- The standalone bundle identifier is `app.agenthud.open`; preferences live in its UserDefaults domain, with separate domains for demo and snapshot runs.
- The usage ledger, the restart copy of the report (including account labels), hashed Kimi identities and completion records live in the data directory ([storage](providers.md#storage)); token events keep 31 days and quota readings 30 days. No file contains conversation text or credentials.
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
| `UsageStore(provider:settings:accessAllowed:hooks:)` | AgentHUDCore | Any `UsageProvider`, the settings store, an access closure (false pauses collection) and `UsageCollectionHooks` |
| `UsageCollectionHooks(historyHours:publish:merge:)` | AgentHUDCore | `@MainActor () -> Int`; `@MainActor (UsageReport) async -> Void`; `@MainActor (UsageReport) async -> UsageReport` |
| `start()`, `stop()`, `refresh()`, `remerge()`, `replace(report:)`, `pause(for:)`, `resume()` | `UsageStore` | Collection lifecycle; `refresh` polls now unless a pass is running; `replace` installs a report without the provider |
| `DesktopApplication(options:settings:store:additionalSettingsPages:onIslandEvents:)` | AgentHUDDesktop | Parsed `DesktopLaunchOptions`, the two stores, `[DesktopSettingsPage]` and an optional `(IslandEventTracker.Update, UsageReport, Date) -> Void` relay hook |
| `start()`, `stop()`, `showSettings(pageID:)`, `showStats()`, `showOnboarding()`, `toggleGlow()` | `DesktopApplication` | Host entry points. `showSettings` selects a page by id (built-in `general`, `sources`, `display`; an unknown id keeps the current page) |
| `IslandEventTracker.Update` | AgentHUDCore | `completions` (new, Live status on, oldest first), `quotaAlerts` (warnings, exhaustion, resets), `exhaustedWindows` and `criticalWindows` (threshold crossings with the reading that crossed; reaching zero supersedes critical in the same reading) |
| `DesktopSettingsPage` | AgentHUDDesktop | `id`; `title` closure (follows language changes, also the page heading); `subtitle`; `symbol` and `color` for the sidebar icon; `preferredContentWidth` in points (built-in pages use 640); `@ViewBuilder` `content` |
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
| Collection pipeline and hooks | `Sources/AgentHUDCore/Store/UsageCollector.swift` |
| Stores and data directory | `Sources/AgentHUDCore/Store/UsageStore.swift`, `SettingsStore.swift`, `QuotaHistoryStore.swift`, `AppSupport.swift` |
| Application object, launch options, host pages | `Sources/AgentHUDDesktop/App/DesktopApplication.swift`, `LaunchOptions.swift`, `Settings/DesktopSettingsPage.swift` |
| Island alerts: decision and presentation | `Sources/AgentHUDCore/Logic/IslandEvents.swift`, `QuotaAlerts.swift`; `Sources/AgentHUDDesktop/Notch/IslandController.swift`, `IslandAlert.swift` |
| Standalone entry and commands | `Sources/AgentHUDOpenApp/main.swift` |
| Build, boundary check, CI | `scripts/build-app.sh`, `scripts/check-source-boundaries.py`, `.github/workflows/ci.yml` |

## Related

[providers.md](providers.md) per-client data sources · [usage-semantics.md](usage-semantics.md) counting and alert rules · [session-lifecycle.md](session-lifecycle.md) turn evidence and hooks · [data-access.md](data-access.md) boundaries · [../CHANGELOG.md](../CHANGELOG.md) host-visible API changes
