# Command line

Launch options, read-only probes, and adapter commands of the standalone application, for developers and for anyone diagnosing a source. The same switches work on `build/Agent HUD Open.app/Contents/MacOS/Agent HUD Open` (after `make build`), on `swift run AgentHUDOpen`, and through Launch Services as `open "build/Agent HUD Open.app" --args …`. Applications that embed the libraries document their own parameters.

Switches are parsed by `DesktopLaunchOptions` (AgentHUDDesktop); unknown switches are ignored. The standalone commands under *Read-only probes* and *Adapter commands* are handled in `main.swift` before the application object exists, so they never show a window.

## Launch and display

| Switch | Effect |
| --- | --- |
| `--demo` | Use the design's sample data (`DemoUsageProvider`, `DemoData.agents`) instead of installed clients. Preferences live in the separate `app.agenthud.open.demo` defaults domain, no report cache is written, and no adapters are installed. |
| `--lang zh\|en\|system` | Force the interface language for this launch (`zh`, `zh-hans` and `cn` select Simplified Chinese). The choice is saved to the preferences in use. |
| `--show-settings` | Open the settings window after start. |
| `--show-stats` | Open the statistics window after start. |
| `--open-panel` | Start with the notch panel expanded. |
| `--show-onboarding` | Show the first-launch window even when onboarding is complete. |
| `--reset-defaults` | Remove the application's stored preferences before starting. |
| `--snapshot <dir>` | Render every screen at 2× to PNG files in `<dir>` from sample data, then quit. `AGENTHUD_SNAPSHOT_PREFIX=<name>` limits rendering, and the built-in island animation, hover and agent-settings checks, to snapshots whose name starts with the prefix, for example `settings-`. |

`make demo` runs `--demo --show-settings`; `make snapshot` runs `--snapshot build/snapshots` (override the directory with `SNAPSHOT_DIR=…`).

## Read-only probes

| Command | Output |
| --- | --- |
| `--probe` | One real account refresh (48 h of history) followed by one report; prints `Quota windows: n; sessions: n; live: n; billing accounts: n` and exits 0, or prints the error and exits 1. It issues the same provider requests as the running application and nothing else. |
| `--probe-open-agents` | Indexes the last seven days of local OpenCode, Kimi and Pi sessions (up to 40 indexing rounds) and prints, per client, the session count, running count, distinct usage events, In / Out / Cache totals and the read status. No network requests, no transcript text, no credentials in the output. |
| `AGENT_HUD_PROBE_ADDITIONAL=1 swift test --filter AdditionalProviderTests/testInstalledSourcesReadOnlyProbe` | Read-only probe of the installed Antigravity, Cursor and Grok sources from the test suite; the test is skipped unless the variable is set. |

## Adapter commands

| Command | Effect |
| --- | --- |
| `--install-pi-observer` | Write or update the Agent HUD extension `extensions/agent-hud.ts` under the Pi directory (`PI_CODING_AGENT_DIR`, default `~/.pi/agent`), then exit. Existing Pi sessions need `/reload` once. A same-named file that is not Agent HUD's is left alone and the command fails. |
| `--install-completion-hook antigravity\|cursor` | Register this executable as the client's stop-hook handler, replacing a handler that belongs to another installation. Other hooks in the client's configuration are preserved. |
| `--completion-hook antigravity\|cursor` | The handler the clients invoke: reads the hook payload from standard input (at most 1 MiB), stores a completion record when the payload describes a successful stop, prints `{"decision":"stop"}` for Antigravity or `{}` for Cursor, and exits 0 even when recording fails. It never initializes the interface or queries an account. |

Normal start-up already runs `SessionObservers.configure(executable:)` for installed clients. The install commands exist for a first setup without launching the application and for taking a hook over from another installation; see [Completion hooks](session-lifecycle.md#completion-hooks).

## Environment

- `SWIFT_SCRATCH_PATH` — passed to `swift build` as `--scratch-path` by `scripts/build-app.sh`.
- `AGENTHUD_SNAPSHOT_PREFIX` — see `--snapshot`.
- `AGENT_HUD_PROBE_ADDITIONAL` — see the probe table.
- Client home overrides such as `CODEX_HOME`, `DSH_HOME` and `PI_CODING_AGENT_DIR`, and provider keys read from the environment, come from the process environment. An application started from Finder or Launch Services inherits the login session's environment, not the exports of a terminal shell.
