# Changelog

Releases of Agent HUD Open. A version is a git tag `vX.Y.Z` on `main`; `CFBundleShortVersionString` in `scripts/build-app.sh` carries the same number. Each entry lists what changed for people using the application and, under **Host API**, what changed for applications that embed `AgentHUDCore` and `AgentHUDDesktop`. Dates are tag dates.

## Unreleased

## 0.4.12 — 2026-09-18

- DeepSeek Harness sessions in formats 2 and 3 are read instead of reported as unsupported, including the generations Harness keeps beside an upgraded log, which count once from the newest readable one. Each settled message and each failed attempt counts as one attempt, taking its usage from the embedded stream, and a seeded fork's history is cut at its own tagged marker rather than at one copied from an ancestor.
- A Codex session is named after its first own prompt again. Current rollouts record a prompt only as a completed `UserMessage` item, so sessions that had no thread name showed their folder instead; rollouts already read are read again for it.

## 0.4.11 — 2026-09-17

- A running turn keeps the running indicator however quiet its log goes: one tool call can take minutes without writing a line, so only an end recorded by the client, an interruption, evidence that the client is gone, or thirty minutes of silence ends it. A source that never says what its turn is doing keeps the 120-second freshness rule, and DeepSeek keeps its process-table evidence.
- The island's session line answers what is running rather than what a range contains: every running session, three at most with the rest as a count, and the three that ended most recently when none is running. A turn blocked on the user is a running turn and wears the warning colour in both session lists.
- Quota is read when a client's own work moves it rather than every five minutes: every minute while one of its turns runs, every three minutes while a session of its is live between turns, once more for work that finished since its last reading, and when one of its windows resets. A client nobody is using is not asked at all. A window whose reset has passed, a reading that names no window, and a client whose usage is the account's from every device it signs in on keep the five-minute interval, since quiet says nothing about those.
- Opening the panel, the menu bar menu or the statistics window reads every account, so a sign-in made while a client sat quiet shows as soon as someone looks instead of waiting for the next sweep. A provider still never repeats an account request within 60 s, and every local source is still read every five minutes, which catches a file event the directory watch missed.
- Host API: `UsageRefresh.abandonedTurnTimeout`, `runningAccountInterval` and `liveAccountInterval`; `LiveSession.isLive(at:)`; `UsageStore.sessionState(_:)`, `isSessionWaiting(_:)` and `refreshAccounts()`; `UsageProvider.accountChecks(since:now:)` and `seesLocalWork`, both with defaults that keep the five-minute interval for a provider that says nothing.

## 0.4.10 — 2026-09-16

- Claude Code's notification hook is installed only for the notification types that mean the agent needs the user (`permission_prompt`, `agent_needs_input`), so a sign-in or quota notice never reads as a pending approval. Which kind of attention it is still comes from the transcript, and the transcript is still what says the request was answered.

## 0.4.9 — 2026-09-16

- Collection waits for signals instead of polling: a client's logs are read when a file under its data directories changes, when a live session or running turn ages past 120 s or 5 minutes, or after its account step, and a read covers only the clients that signalled. Nothing is read while every client is quiet, apart from the five-minute account sweep.
- A session says what it is waiting for and what the agent last answered. The turn's message is the latest visible assistant text, read up to 2 KB, kept only while the application runs and never written to the ledger; Claude Code's notification hook reports a turn blocked on the user. Whether that is a pending approval or an unanswered prompt comes from the transcript, never from the wording of a message, and a request is answered as soon as a newer transcript line arrives.
- Agent HUD installs Claude Code's notification hook in `~/.claude/settings.json` when Claude Code is present, the same way it installs the other clients' stop hooks; a machine without Claude Code is left untouched, and `--attention-hook claude` is the handler it registers.
- A Claude Code that is signed out says so beside its stale quota rows instead of showing only how long ago they were read. Its engine reports no plan limits both when signed out and when running on an API key, and `claude auth status` tells the two apart.
- Host API: `UsageSource`, `UsageProvider.sources`, `fetchUsage(agents:historyHours:sources:)` and `sourceChecks()` with defaults for a provider that does not split itself; `UsageRefresh.readSpacing` and `liveThreshold`; `UsageStore.observeChanges(_:)` with `UsageChanges` and `UsageChangeObservation`; `UsageRefresh.pollInterval` now applies only to sources without directories; `SessionTurn` gains the `waitingForApproval` state and a `message`; `AttentionHooks` with `Source`, `Event`, `record`, `read`, `configure` and `isActive`; `ClaudeDataError.signedOut`; `ClaudeEngineUsageClient.isSignedIn()`.

## 0.4.8 — 2026-09-15

- Lower idle CPU: clock ticks that change nothing on the island skip its layout, and the statistics window and forecast hover popups are created the first time they are shown.
- A poll reads less of the ledger: the hourly quota history, which no screen used, is gone, and the heatmap and weekly token share are derived from the stored usage buckets.
- Chinese interface: the notch is called 灵动岛 throughout, and vendor plan badges and descriptions say 套餐 / Plan instead of 订阅 / Subscription.
- `--snapshot` no longer runs the built-in island animation, hover and agent settings checks, which are XCTests now, and no longer writes the island forecast hover images.
- The restart cache written by 0.4.8 cannot be read by earlier versions; after a downgrade the first launch starts without the previous report until collection completes.
- Host API: `UsageStore(provider:settings:accessAllowed:hooks:)` with `UsageCollectionHooks(historyHours:publish:merge:)` and `UsageStore.remerge()`, collection scheduling moves into an internal collector; `DesktopMenuAction`, the `additionalMenuActions:` parameter and `DesktopSettingsPage.heading` are removed; `SettingsSection`, `Theme`, `Font.ui`, `Font.tabular`, `HostedWindowController` and `SourceDetector` become internal; `HistorySample`, `UsageReport.history`, `history(for:)`, `activity`, `insights` and `subscriptionType`, `UsageInsights.weeklyShare`, `windowSessionCount`, `windowUsedPct` and `empty`, and `ActivityGrid.empty` with its `Codable` conformance are removed; `UsageAnalytics.hourlyHistory`, `hourStart` and `weeklyShare`, `UsageAggregation.historyUnion` and `eventUnion`, `ChartData.remainingPath`, `usedPath` and `bucketed`, `BurnRate.estimate`, the `DemoSeries` candle, series, line seed and activity members, the `calendar:` parameter of `ClaudeCodeProvider.init`, `UsageLedger.bucketRevision`, `TranscriptSession.UsageEvent`, `L10n.vendorLabel`, `UsageStore.primaryRow`, `quotaUpdatedAt`, `weeklyByVendor`, `minRemainingPct` and `primaryInsights`, `SettingsStore.resetOnboarding()`, `Countdown.updatedLabel`, `GlowGeometry.visibleHeight`, `SourceStatus.isReady` and `ClaudeModelInfo.isSubagentModel` are removed; `AgentHUDDesktop` and `AgentHUDOpenApp` build in the Swift 6 language mode.

## 0.4.7 — 2026-09-15

- The application decides and shows island alerts itself: quota alerts and a reminder for each completed turn, for clients whose Live status is on. Baselines start again at every launch, nothing is checked while collection is paused or failing, and turns that finished while Live status was off are not replayed.
- Every subprocess runs under a deadline — the Claude Code engine 40 s, the Codex app-server 30 s, the DeepSeek Harness helper 10 s for a log and 30 s for the balance, `ps` and `lsof` 3 s — and is sent SIGTERM, then SIGKILL after two seconds. A stuck child, or a grandchild holding its pipes, no longer stalls collection.
- Local logs of every client are read through shared ledger-backed file stores. A file missing from its client's listing removes what it recorded, also when its directory is unreadable or gone; a listed file that cannot be read keeps it; after a pass that could not be saved, each source writes back what the ledger lost.
- Host API: `IslandEventTracker` with `Update` and `Crossing`; `DesktopApplication(..., onIslandEvents:)` receives every check with the report and time it used; the public `DesktopApplication.present(_:)` overloads and `IslandAlert.isPreview` are removed; `ClaudeTranscriptParser.title(from:)` becomes `SessionTitle.from(_:)`; `DateParsing` and `ISO8601Fast` move to `Providers/Shared`.

## 0.4.6 — 2026-09-15

- Sessions and token usage from GitHub Copilot CLI, OpenClaw, Hermes Agent, ZCode, CodeBuddy and WorkBuddy, with their logos. GitHub Copilot quota is read only after Settings → Agents → GitHub Copilot → Read quota is confirmed.
- Quota readings belong to the provider account they were read from; readings, history, alert baselines and display settings of different accounts never mix, and Settings → Agents lists the accounts each client has used.
- Usage is collected one source at a time into `usage-ledger.sqlite`: a local poll every 5 s (2 s while indexing) that skips when nothing changed, and an account sweep every 5 minutes. Token charts add up 15-minute totals.
- The unused poll interval setting is removed.
- Host API: `ProviderAccount`, `AccountObservation`, `ClientHome`, `AccountSection` and `UsageStore.accountSections(_:)`; `AgentDescriptor.account` and `windowKey`; `UsageReport.accounts`, `forgottenAccountProviders`, `observation(accountID:)` and `isCurrent(_:)`; `SettingsStore.mergeDiscovered(_:activeQuotaPoolIDs:accounts:)`; `UsageLedger`, `LedgerWriter`, `UsageRefresh`, `AccountRefreshStep`, `UsageBucket` and `CostBucket`; `PollInterval` is removed.
- Known: `scripts/build-app.sh` still stamped `0.4.5` at this tag.

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
