# Session lifecycle

## Overview

Which clients expose running and terminal turns, what evidence each provider accepts, and how completion hooks work. Usage records and running turns are separate observations: a token counter or a recent file modification never establishes that a whole agent turn is running or complete, and a quota response or a single model response never ends a turn.

## Model

`UsageReport.turns` carries `SessionTurn` observations: provider, session id, turn id, state (`running`, `completed` or `ended`), the source start time when known, and the time of the latest source event — reading a cached transcript does not advance it. `UsageReport.completions` carries `SessionCompletion` records (id = hash of vendor, session and turn; task, model, completion time) parsed from logs or received from hooks. `LiveSession.observedAt` records when the collector last checked desktop activity, including process evidence.

| Client | Running turns | Terminal turns | Evidence |
| --- | --- | --- | --- |
| Claude Code | Yes | Yes | A prompt line starts the turn; an assistant `stop_reason` of `end_turn` or `stop_sequence` completes it; a `[Request interrupted` user line ends it; `tool_use` keeps it running. `isSidechain` lines, `<synthetic>` messages (API errors) and sub-agent transcripts never start or finish a turn. |
| Codex Desktop / CLI | Yes | Yes | `task_started` (`turn_id`) starts the turn and later events refresh it; `task_complete` completes it; `turn_aborted` ends it. Guardian and sub-agent rollouts report none. |
| DeepSeek Harness | Yes | Yes | `turn/start`, streaming and tool events, `turn/end`; only `reason.kind == completed` is a completion, and sub-agent sessions record none. A quiet turn stays active while a Node process that predates it holds the Harness profile. |
| Grok CLI | Yes | Yes | Session updates keyed by `promptId`; `turn_completed` with `stop_reason` `end_turn` completes, other outcomes end without a completion. Older unified logs carry usage only. |
| Kimi | Yes | Yes | On the `main` agent the first `step.begin` starts the turn and loop events refresh it; `turn.ended` with `reason == completed` and no `error` completes it; child agents never finish the parent. Older status logs carry usage only. |
| Pi | Yes, with the observer | Yes, with the observer | `agent_start`, `agent_settled` and `session_shutdown` from the Agent HUD extension; an assistant stop alone does not finish a run. |
| Antigravity | No | Through the `Stop` hook | Local records supply usage only. |
| Cursor | No | Through the `stop` hook | Local records supply usage only. |
| OpenCode | No | No | A persisted message end is not an agent end. |
| GLM | n/a | n/a | Billing service; execution state belongs to the client using it. |

## Rules

### Live status

- Every execution client has Settings → Agents → [Agent] → Live status; billing-only services have none. `Settings.liveStatusEnabled(for:)` controls running indicators only: turning it off changes nothing in collection, session history, token statistics or quota windows, and installs or removes no adapter.
- The switch permits available observations; it never manufactures lifecycle support for a source whose logs only provide usage.
- A running observation older than 120 s leaves the running indicator and stays in history without an invented end time; a failed read never creates a completion or an artificial end.
- Process evidence is separate from the last recorded observation: a quiet process does not manufacture a transcript event, and a disappeared process does not prove completion.
- Hosts apply the same preference in their reminder, relay or synchronization services. The standalone application presents no reminders; a host that does decides which records are new — completions that happened before it started are history, not events.

### Pi observer

- The standalone host installs or updates its extension under the Pi directory (`PI_CODING_AGENT_DIR`, default `~/.pi/agent`) whenever that directory exists; existing Pi processes need one `/reload`, new ones load it automatically. A same-named file that is not Agent HUD's is left alone.
- The observer writes metadata-only turn snapshots, keeps retries, compaction and queued continuations inside one run until `agent_settled`, and reports a completion only for a successful final response; errors, cancellation and shutdown end activity without claiming success. A run with no shutdown event stops being live 120 s after its last snapshot; snapshots are kept 7 days.
- Token totals still come only from Pi's message transcripts; installing the observer replays no reminders and creates no usage events.

### Completion hooks

Antigravity and Cursor do not expose turn lifecycle in local records, so their completions come from the clients' own stop hooks. `CompletionHooks` owns the configuration, the callback and the local record.

| Source | Configuration | Accepted as a completion when |
| --- | --- | --- |
| Antigravity | `agent-hud` entry (`Stop` array) of `~/.gemini/config/hooks.json`; `GEMINI_CLI_HOME` overrides `~/.gemini` | `terminationReason` is `model_stop`, `fullyIdle` is true, `error` is absent or empty, and `executionNum` and `conversationId` are present |
| Cursor | Handler appended to `hooks.stop` of a version-1 `~/.cursor/hooks.json`; only commands ending in ` --completion-hook cursor` are Agent HUD's | `hook_event_name` is `stop`, `status` is `completed`, and `conversation_id` and `generation_id` are present |

- The handler command is `'<executable path>' --completion-hook <source>` with a 5-second timeout. Other hooks in the file are preserved, and a file that already contains the identical configuration is not rewritten.
- Automatic setup never replaces a handler that points at a different executable: the existing installation keeps the hook and the conflict is logged. Moving or reinstalling the application does not update the path; `--install-completion-hook antigravity|cursor` takes ownership explicitly ([command line](command-line.md#adapter-commands)). Installing a hook never starts, restarts or interrupts the client and consumes no quota.
- The handler reads the payload from standard input and writes one JSON record per completion to `turn-completions/<source>/<id>.json` in the data directory: id, `sessionID` (`antigravity:<conversationId>` or `cursor:<conversation_id>`), vendor, task (vendor plus workspace folder name), model when the payload names one, and receipt time. No prompt, tool argument, credential or e-mail address is stored.
- An existing record for the same id is left untouched, so repeated callbacks create no duplicates; records older than 30 days are deleted on the next write.
- The handler prints `{"decision":"stop"}` for Antigravity and `{}` for Cursor and exits 0 even when recording fails, so status tracking can never block the agent.
- Providers read the inbox for the report's history window and merge those records with completions parsed from logs.

## Code map

| Concept | Code |
| --- | --- |
| Turn, completion and session models | `Sources/AgentHUDCore/Models/SessionTurn.swift`, `SessionCompletion.swift`, `LiveSession.swift` |
| Live status preference and desktop liveness | `Sources/AgentHUDCore/Models/Settings.swift`, `Sources/AgentHUDCore/Store/UsageStore.swift` |
| Adapter setup | `Sources/AgentHUDCore/Providers/SessionObservers.swift` |
| Completion hooks and handler entry | `Sources/AgentHUDCore/Providers/Additional/CompletionHooks.swift`, `Sources/AgentHUDOpenApp/main.swift` |
| Pi observer and its extension script | `Sources/AgentHUDCore/Providers/OpenAgents/PiSessionObserver.swift` |
| Per-client turn parsing | `Sources/AgentHUDCore/Providers/Claude/ClaudeTranscripts.swift`, `Codex/CodexTranscripts.swift`, `DeepSeek/DeepSeekTranscript.swift`, `Grok/GrokSessions.swift`, `OpenAgents/OpenAgentSessions.swift` |

## Related

[providers.md](providers.md) per-client reads and counting · [command-line.md](command-line.md) adapter commands · [architecture.md](architecture.md) host integration and hook ownership
