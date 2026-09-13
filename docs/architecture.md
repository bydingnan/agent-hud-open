# Architecture

What the packages are, how a host application embeds them, and the invariants every change must keep. Read this before adding a provider, a host integration, or a release.

## Modules

The executable creates local preferences, a `CombinedUsageProvider`, and a `UsageStore`, then passes them to `DesktopApplication`.

- `AgentHUDSupport` has no dependency on application services or UI: `JSONValue` and `RecordCoding`.
- `AgentHUDCore` owns provider-specific data access and normalizes it into `UsageReport`. Local cache files contain reports and indexing metadata.
- `AgentHUDDesktop` observes the supplied store and owns native windows, menu items, and local presentation. Its resource bundle contains all interface assets.
- `AgentHUDOpenApp` selects live or sample data, handles the [command line](command-line.md), and manages process lifetime.

Shared token events live in `Models/UsageEvent.swift`, usage calculations in `Logic/UsageAnalytics.swift`, and quota history persistence in `Store/QuotaHistoryStore.swift`. The original `TranscriptSession.UsageEvent` spelling remains a type alias for existing library hosts; provider parsers use the shared model.

## Host integration

A host can supply its own `UsageProvider`, observe reports, add menu actions and settings pages, or present quota and session-completion events. It owns its additional service lifecycle. The shared UI does not initialize account services or data transports.

### Providers and refresh

`UsageProvider.fetchUsage(agents:historyHours:)` reads local activity and assembles it with the latest account results. `refreshAccountUsage(historyHours:)` performs the slower quota, balance, and account-wide usage requests; the protocol supplies a no-op default. `UsageStore` runs account refreshes on their own task, independently of its local polling loop, and providers keep their own request intervals ([usage semantics](usage-semantics.md#account-request-intervals)). Hosts that wrap a provider forward both operations. A one-shot probe awaits the account refresh before fetching its report.

`RetainedUsageProvider` restores the saved report (`last-usage-report.json`) immediately and merges missing readings after partial failures. A full refresh failure propagates to `UsageStore`, which keeps the previous report and exposes `lastError`. `LiveSession.observedAt` records the last activity check; cached running observations age out of the running indicator without inventing an end time or deleting session history.

### DesktopApplication

`DesktopApplication(options:settings:store:additionalMenuActions:additionalSettingsPages:)` takes the parsed `DesktopLaunchOptions`, a `SettingsStore`, a `UsageStore`, and two optional lists:

- `[DesktopMenuAction]` — `title` and `action` closures added to the status-item menu.
- `[DesktopSettingsPage]` — host pages shown in the settings sidebar next to the built-in General, Agents and Display pages.

`DesktopSettingsPage` fields:

| Field | Meaning |
| --- | --- |
| `id` | Stable page identifier, also accepted by `showSettings(pageID:)`. The built-in ids are `general`, `sources` and `display`. |
| `title` | Sidebar label, as a closure so it follows language changes. |
| `heading` | Optional page heading; the title is used when it is nil. |
| `subtitle` | Text under the heading. |
| `symbol`, `color` | SF Symbol name and tint of the sidebar icon. |
| `preferredContentWidth` | Maximum content width in points; the built-in pages use 640. |
| `content` | A `@ViewBuilder` closure producing the page. |

The settings window opens at 760 × 720 points (minimum 680 × 560, sidebar 212). When any host page declares `preferredContentWidth`, the initial window width becomes `max(760, largest preferredContentWidth + 212 + 40)`, so the widest page fits without horizontal scrolling.

`showSettings(pageID:)` selects that page before showing the window; an unknown id keeps the current page. `showStats()`, `showOnboarding()`, `toggleGlow()`, `present(_ alert: QuotaAlert)` and `present(_ completion: SessionCompletion)` are the other host entry points. The standalone application never calls `present`: deciding that a quota alert or a completion reminder is due — `QuotaAlertTracker` supplies the baseline and deduplication logic — is a host responsibility.

Hosts must apply the same Live status preference as the desktop (`Settings.liveStatusEnabled(for:)`) in any relay, reminder or synchronization service they add; see [session lifecycle](session-lifecycle.md).

### Session observers and hook ownership

Hosts opt into adapter setup by calling `SessionObservers.configure(executable:)` with their callback executable, after creating the store and before `DesktopApplication.start()`. Automatic setup installs the Pi observer when the Pi directory exists and the Antigravity and Cursor stop hooks when those clients are installed; it preserves a completion hook owned by another installation and reports the conflict. The standalone `--install-completion-hook` command explicitly transfers that ownership. Creating a `DesktopApplication` does not install adapters. Details: [Completion hooks](session-lifecycle.md#completion-hooks).

## Storage and process identity

The standalone application's bundle identifier is `app.agenthud.open`. Its data directory is `~/Library/Application Support/Agent HUD Open`. Demo preferences and snapshot preferences have separate domains. Hosts can set `AgentHUDDataDirectory` in their Info.plist to choose their own cache directory.

Files in the data directory: `last-usage-report.json`; `transcripts-cache-v5.json` and `quota-history.json` (Claude); `codex-transcripts-v5.json` and `codex-quota-history.json`; `deepseek-transcripts-v2.json`; `antigravity-quota-history.json`, `cursor-quota-history.json` and `grok-quota-history.json`; `open-agent-quota-history.json` and `open-agent-identities.json`; the `turn-completions/` inbox; and the Claude engine's working directory `engine/`. Quota histories keep 30 days. None of these files contains conversation text or credentials.

SwiftPM resources are located through `AppResources`. App bundles include `AgentHUDOpen_AgentHUDDesktop.bundle` under `Contents/Resources`; command-line SwiftPM builds use the generated module bundle.

## Design invariants

Acceptance criteria for every change:

- **Integer precision.** `JSONValue` decodes whole numbers as `Int64` before trying `Double`; token counts are never rounded or interpolated (`ChartData.tokenBars`).
- **Deterministic identities.** Record ids are SHA-256 hashes of length-prefixed components (`RecordCoding.hash`), so `SessionCompletion`, `SessionTurn`, `BillingPool` and account-wide event ids are identical in every process and on every machine.
- **Millisecond dates.** Persisted dates round-trip through `RecordCoding.milliseconds` / `RecordCoding.date` and the `millisecondsSince1970` coding strategy.
- **Tests without credentials or network.** `swift test` uses synthetic fixtures and fake engines; the only probe that touches installed clients is opt-in (`AGENT_HUD_PROBE_ADDITIONAL`).
- **Isolated sources.** A missing, signed-out or failing client never hides another (`CombinedUsageProvider`).
- **No invented lifecycle.** Inactivity is never a completion, and a passed reset deadline is not a confirmed reset ([usage semantics](usage-semantics.md#reading-retention)).
- **Resources and notices.** The resource bundle carries every logo, `LobeIcons-LICENSE.txt` and `THIRD_PARTY_NOTICES.txt`. The root `THIRD_PARTY_NOTICES.txt` and the bundled copy must stay byte-identical — `cmp THIRD_PARTY_NOTICES.txt Sources/AgentHUDDesktop/Resources/THIRD_PARTY_NOTICES.txt` before tagging — and source comments cite the `.txt` file.
- **Source boundaries.** `scripts/check-source-boundaries.py` (`make check`) rejects signing material (`.p8`, `.p12`, `.pfx`, `.key`, `.pem`, provisioning profiles, entitlements), the private directories `signing/`, `Sync/` and `AgentHUDServices/`, CloudKit and UserNotifications imports and identifiers, secret-shaped strings, external package dependencies, and missing ignore rules.

## Dependencies and CI

There are no third-party Swift package dependencies. Frameworks and system libraries come from the macOS SDK. Provider clients are discovered on the user's Mac. Install and sign into the clients you want to monitor; unavailable providers are reported independently.

Continuous integration (`.github/workflows/ci.yml`, macOS runner) runs the boundary check, `swift test`, a release build through `scripts/build-app.sh`, `codesign --verify --deep --strict` on the result, a check that the resource bundle contains the logos, and a check that no provisioning profile was embedded. It does not publish binaries. Notices consistency is a manual `cmp` (see the [roadmap](roadmap.md)).

## Versioning

A release is a tag `vX.Y.Z` on `main`. `CFBundleShortVersionString` in `scripts/build-app.sh` must equal `X.Y.Z` at that tag, and the [changelog](../CHANGELOG.md) must have a matching entry that lists host-visible API changes. `CFBundleVersion` stays `1`; the standalone build has no separate build number. Hosts pin the package by tag or commit.
