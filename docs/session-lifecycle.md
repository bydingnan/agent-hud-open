# Session lifecycle coverage

Which clients expose running and terminal turns, what evidence each provider accepts, and how completion hooks work. For provider maintainers and for hosts that build reminders or relays on `UsageReport`.

Usage records and running turns are separate observations. A token counter or a recent file modification does not establish that a whole agent turn is running or complete.

`UsageReport.turns` carries explicit `SessionTurn` observations. Each observation has a stable session and turn identity, a source start time when known, a state (`running`, `completed`, or `ended`), and the timestamp of the latest source event. Reading a cached transcript does not advance that timestamp. Consumers decide how long an observation remains fresh.

Every execution client uses **Settings → Agents → [Agent] → Live status**. The shared `Settings.liveStatusEnabled(for:)` policy controls desktop running indicators. Turning it off takes effect without changing the collector, session history, token statistics or quota windows. Billing-only services do not have a live-status switch. Hosts that add completion reminders, live-status relay, or device-settings synchronization apply this same preference in their own services; those services are not part of the standalone open application.

Collectors normalize their own formats into the same `LiveSession`, `SessionTurn`, `SessionCompletion` and usage-event models. The desktop and optional host services consume those models. The switch permits available status observations; it does not manufacture lifecycle support for sources whose logs only provide usage.

| Client / source | Running turns | Terminal turns | Evidence |
| --- | --- | --- | --- |
| Claude Code | Yes | Yes | A prompt line starts the turn; an assistant line whose `stop_reason` is `end_turn` or `stop_sequence` completes it; a `[Request interrupted` user line ends it. A `tool_use` response keeps it running. `isSidechain` lines, `<synthetic>` messages and sub-agent transcripts (`agent-*.jsonl`, `subagents/`) never start or finish a turn. The v5 transcript index (`transcripts-cache-v5.json`) rebuilds the current turn, including its start time, from the log. |
| Codex Desktop / CLI | Yes | Yes | `task_started` with its `turn_id` starts the turn and later events refresh it; `task_complete` completes it and `turn_aborted` ends it. Each transcript keeps its last 32 turn observations; guardian and sub-agent rollouts report none. |
| DeepSeek Harness v0 | Yes | Yes | `turn/start`, streaming/tool events, `turn/end` |
| Grok CLI session updates | Yes | Yes | User/agent/tool updates and `turn_completed` |
| Kimi Code `agents/main/wire.jsonl` | Yes | Yes | First `step.begin`, loop events and `turn.ended` |
| Cursor | No | No | Current provider supplies usage observations; completions come from the stop hook below |
| Antigravity | No | No | Current provider supplies usage observations; completions come from the stop hook below |
| OpenCode | No | No | Current provider supplies message usage observations |
| Pi with Agent HUD observer | Yes | Yes | Native `agent_start`, `agent_settled` and `session_shutdown`; assistant stops alone do not finish a run |
| GLM billing services | Not applicable | Not applicable | Execution state belongs to the client using the service |

Claude Code writes one line per content block and every line carries the message's stop reason, so a completion is identified by the message id (or the timestamp when the id is missing) and counted once; each transcript keeps its 32 most recent completions and drops the deduplication set once the file has been idle for a day. An API error is a `<synthetic>` message without a stop reason and never completes a turn.

Older Grok unified logs and older Kimi status logs supply usage information without complete turn lifecycle evidence. Completion-hook records are independent of the provider's running-turn records.

DeepSeek packed text, reasoning, and tool-call rows update observation times using their recorded timestamps. Their content is not retained by the transcript index. Inherited history and subagent turns do not become parent running turns. Kimi child-agent events likewise cannot start or finish the main conversation's turn.

Desktop session liveness may additionally use process evidence. It is separate from a turn's last recorded observation: a quiet process does not manufacture a fresh transcript event, and a disappeared process does not prove successful completion.

The standalone host prepares required observers when monitoring starts. For Pi, it installs or updates its own extension when the Pi directory exists; existing Pi processes need a one-time `/reload` after installation. New Pi processes load the extension automatically. Changing **Live status** does not install or remove extensions and needs no reload. Manual setup remains available as `AgentHUDOpen --install-pi-observer`. Both the installer and reader honor `PI_CODING_AGENT_DIR` (default `~/.pi/agent`).

`LiveSession.observedAt` records when the collector last checked desktop activity, including any process evidence. Retaining or decoding the session does not advance it. A running observation older than 120 seconds remains in the session history with a status awaiting refresh; it no longer drives the running indicator. A failed read does not create a successful completion or an artificial session end.

The observer writes metadata-only snapshots to `agent-hud/turns/` inside that directory, including turns whose first response has not yet been persisted. It keeps retries, compaction and queued continuations running until `agent_settled`. Only a successful final response emits a completion reminder; errors, cancellation and shutdown end activity without claiming success. While a run remains active, the observer reports its state every 15 seconds. If Pi exits without a shutdown event, the last observation stops being considered live after 120 seconds. Re-reading a file does not refresh that timestamp. Observer files are retained for seven days.

Token totals continue to come exclusively from Pi's message transcripts, with the existing fork/request deduplication. Installing the observer does not replay old completion reminders or create extra usage events. Without the observer, Pi still supplies historical sessions and token usage.

## Completion hooks

Antigravity and Cursor do not expose turn lifecycle in local records, so their completions come from the clients' own stop hooks. `CompletionHooks` (AgentHUDCore) owns the configuration, the callback and the local record; the desktop and hosts receive the resulting `SessionCompletion` values through `UsageReport.completions`.

### Accepted stop conditions

| Source | Signal | Accepted as a completion when |
| --- | --- | --- |
| Antigravity | `Stop` hook in `~/.gemini/config/hooks.json` | `terminationReason` is `model_stop`, `fullyIdle` is `true`, `error` is absent or empty, and `executionNum` and `conversationId` are present |
| Cursor | `stop` hook in `~/.cursor/hooks.json` | `hook_event_name` is `stop`, `status` is `completed`, and `conversation_id` and `generation_id` are present |
| Grok CLI | `turn_completed` in `sessions/**/updates.jsonl` (no hook) | `stop_reason` is `end_turn`; cancelled, failed and unknown outcomes end the turn without a completion |

A quota response or a single model response never counts as the end of a turn.

### Configuration and ownership

The handler command is `'<executable path>' --completion-hook <source>` with a 5-second timeout. For Antigravity it is written as the `agent-hud` entry (`Stop` array) of `hooks.json`. For Cursor it is appended to `hooks.stop` of a version-1 `hooks.json`, and only handlers whose command ends with ` --completion-hook cursor` are treated as Agent HUD's. Other hooks in either file are preserved, and a file that already contains the identical configuration is not rewritten.

Automatic setup (`SessionObservers.configure(executable:)`, run by the standalone host at start-up for installed clients) never replaces a handler that points at a different executable: the existing installation keeps the hook and the conflict is logged. Moving or reinstalling the application therefore does not update the path by itself; run `--install-completion-hook antigravity` (or `cursor`) from the new location to take ownership explicitly ([command line](command-line.md#adapter-commands)). Installing a hook does not start, restart or interrupt the client and consumes no quota.

### Local record

`--completion-hook <source>` reads the payload from standard input (at most 1 MiB), evaluates the conditions above and writes one JSON file per completion to `turn-completions/<source>/<id>.json` in the data directory (directory mode 0700, file mode 0600). The record is a `SessionCompletion`: the id (hash of vendor, session and turn), `sessionID` (`antigravity:<conversationId>` or `cursor:<conversation_id>`), the vendor, `task` ("<Vendor> · <workspace folder name>", or the vendor alone), the model when the payload names one, and the receipt time. No prompt, tool argument, credential or e-mail address is stored. Files older than 30 days are deleted on the next write. An existing file for the same id is left untouched, so repeated callbacks do not create duplicates.

The handler prints `{"decision":"stop"}` for Antigravity and `{}` for Cursor and exits 0 even when recording fails, so local status tracking can never block the agent.

### Presentation

Providers read the inbox for the report's history window and merge those records with completions parsed from logs, so `UsageReport.completions` lists every known completion, old and new. The standalone application does not present reminders itself; a host that does (`DesktopApplication.present(_:)`) decides which records are new — completions that happened before it started are history, not events — and applies the same **Live status** preference as the running indicators.
