# Providers

Per-client reference for the data sources implemented in `agent-hud-open` (`Sources/AgentHUDCore/Providers/`): where each provider reads, which credentials and environment variables it honors, which endpoints it calls, how it counts and deduplicates, how billing pools are formed, which cache files it writes, and which tests cover it. Written for maintainers of the providers; the code is authoritative where the two disagree.

Boundaries and privacy rules: [data access](data-access.md). Counting rules: [usage semantics](usage-semantics.md). Running and terminal turns, completion hooks: [session lifecycle](session-lifecycle.md). Launch switches and probes: [command line](command-line.md). This document contains field names and rules only, no account readings.

## Coverage

Cache files live in the data directory (`~/Library/Application Support/Agent HUD Open`, or the host's `AgentHUDDataDirectory`). Quota histories keep 30 days.

| Client | Local data | Account queries | Turns | Completion evidence | Cache files |
| --- | --- | --- | --- | --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl`, `~/.config/claude/projects/**/*.jsonl`; `~/.claude.json` for the plan tier | Claude Code engine `get_usage` | Yes | Assistant `stop_reason` `end_turn` / `stop_sequence` | `transcripts-cache-v5.json`, `quota-history.json`, `engine/` |
| Codex Desktop / CLI | `$CODEX_HOME/sessions`, `archived_sessions` (`rollout-*.jsonl`), `session_index.jsonl` | Codex app-server `account/rateLimits/read` | Yes | `task_complete` | `codex-transcripts-v5.json`, `codex-quota-history.json` |
| DeepSeek Harness | `$DSH_HOME/sessions/**/session.jsonl[.zstd]`, `profiles/*/cordis.yml` (process evidence only), `settings.yaml`, `.credentials.yaml` | `GET https://api.deepseek.com/user/balance` | Yes | `turn/end` with `reason.kind` `completed` | `deepseek-transcripts-v2.json` |
| Antigravity | `$GEMINI_CLI_HOME/antigravity-cli/conversations/*.db`, `antigravity/*.db`, `antigravity/conversations/*.db` | Running local language server (`RetrieveUserQuotaSummary`, `GetUserStatus`) | No | `Stop` hook | `antigravity-quota-history.json`, `turn-completions/antigravity/` |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (token only) | `cursor.com/api/usage-summary`, `cursor.com/api/dashboard/get-filtered-usage-events` | No | `stop` hook | `cursor-quota-history.json`, `turn-completions/cursor/` |
| Grok CLI | `$GROK_HOME/auth.json`, `sessions/**/updates.jsonl`, `logs/unified.jsonl` | `cli-chat-proxy.grok.com/v1/billing`, `/v1/settings` | Yes | `turn_completed` with `stop_reason` `end_turn` | `grok-quota-history.json` |
| OpenCode (+ Go) | `$XDG_DATA_HOME/opencode/opencode.db`, `storage/message/**/*.json`, `auth.json`; `$XDG_CONFIG_HOME/opencode/opencode.json[c]` | `opencode.ai/zen/go/v1/usage` when a Go credential exists | No | — | `open-agent-quota-history.json`, `open-agent-identities.json` |
| Kimi | `$KIMI_CODE_HOME/sessions/**/agents/*/wire.jsonl`, `~/.kimi/sessions/**/wire.jsonl`, `credentials/*.json`, `device_id` | `api.kimi.com` / `api.kimi.ai` `/coding/v1/usages` and `/coding/v1/me` | Yes | `turn.ended` `completed` on the main agent | same as OpenCode |
| GLM | None; usage comes from the client that used the service | `open.bigmodel.cn` / `api.z.ai` `/api/monitor/usage/quota/limit` | n/a | n/a | same as OpenCode |
| Pi | `$PI_CODING_AGENT_DIR/sessions/**/*.jsonl`, `agent-hud/turns/*.json`, `auth.json`, `models.json` | Through Kimi, GLM and Go credentials found in Pi's files | Yes (observer) | `agent_settled` after a `stop` response | same as OpenCode |

Every network request goes through `ProviderHTTP` (Antigravity, Cursor, Grok, Kimi, GLM, Go) or a short-lived Node helper (DeepSeek): ephemeral session, no cookies, no cache, no redirects, 12 s default timeout, 16 MiB response cap. SQLite is opened read-only inside one read transaction (`ReadOnlySQLite`), which sees committed WAL pages; rows are capped at 10 000 and 64 MiB, 3 s per database.

## Claude Code

Code: `Providers/Claude/`.

- **Engine.** `ClaudeEngineLocator` tries `~/.local/bin/claude`, `~/.claude/local/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, then the newest entry of `~/.local/share/claude/versions`. `ClaudeEngineUsageClient` runs `claude -p --input-format stream-json --output-format stream-json --verbose --settings {"disableAllHooks":true}` in the `engine/` working directory with `CLAUDE_CODE_ENTRYPOINT=agent-hud` and a fixed PATH, writes one `control_request` of subtype `get_usage`, and stops at the first `control_response` (40 s timeout). No prompt is sent, so nothing is billed.
- **Windows.** `rate_limits.five_hour` and `seven_day` (`utilization`, `resets_at`), `seven_day_opus` / `seven_day_sonnet`, and `limits[]` entries of kind `weekly_scoped` (`percent`, model scope) become the rows `claude-session`, `claude-weekly` and `claude-weekly-<family>` (families: opus, sonnet, haiku, fable, mythos). `rate_limits_available == false` (API key or third-party login) keeps local data and shows a notice instead of rows.
- **Plan.** `subscription_type` `max` is refined to `max_5x` / `max_20x` from `oauthAccount.userRateLimitTier` (or `organizationRateLimitTier`) in `~/.claude.json` (`CLAUDE_CONFIG_DIR` honored) when `organizationType` is `claude_max`.
- **Transcripts.** `FastTranscriptParser` extracts fields with byte searches; only the `usage` object is JSON-decoded. Usage is counted once per `message.id` (fallback `requestId`); In = `input_tokens` + `cache_creation_input_tokens`. Consumers are exact model ids (`claude-model:<id>`, `Unknown` when missing, `<synthetic>` ignored). Sub-agent transcripts (`agent-*.jsonl`, `subagents/`) and `isSidechain` lines never start or complete a turn. The session title is the first real prompt, one line, at most 60 characters; the `entrypoint` field labels the client (CLI, Desktop, IDE extension, Agent SDK).
- **Liveness.** A session is running while its current turn is running and the log was written within 120 s. Indexing is cooperative: newest files first, 1.5 s per poll, cache saved at most every 30 s; a file idle for a day drops its deduplication set and old completions.
- **Share.** `pctOfWindow` is the session's share of tokens in the current 5 h window times the window's utilization; Claude is the only client with a per-session share.
- Tests: `ClaudeEngineTests`, `ISO8601FastTests`, `ClaudeUsageParseTests`, `ClaudeTranscriptTests`, `AccumulatorCompactionTests`, `CooperativeIndexingTests`, `ClaudeCodeProviderTests`, `SubscriptionTests`.

## Codex Desktop / CLI

Code: `Providers/Codex/`.

- **Engine.** `CodexLocator` prefers the self-contained Desktop engine (`Codex.app` or `ChatGPT.app` → `Contents/Resources/codex` in `/Applications` and `~/Applications`), then `~/.bun/bin/codex`, `~/.local/bin/codex`, `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, then `PATH`. Either Desktop or CLI alone is enough. `CODEX_HOME` (default `~/.codex`) is passed to the engine; Desktop and CLI pointing at the same home share one set of windows, and separate homes are not merged.
- **Handshake.** `codex app-server --listen stdio://` over stdin/stdout: `initialize` (clientInfo `agent_hud`) → `initialized` → `account/rateLimits/read`, 30 s timeout. No thread, no turn, no `auth.json` read, no reset credit consumed.
- **Windows.** `rateLimitsByLimitId` is authoritative when present, including an empty map; the legacy `rateLimits` object is used only when it is absent. Buckets sort with `codex` first. Each bucket's `primary` and `secondary` windows become rows; the period label comes from `windowDurationMins` (10080 → Weekly; a multiple of 60 → "Nh"; otherwise "Nm"; unknown → Primary / Secondary). The shared primary row keeps the id `codex` so saved preferences survive; other rows are `codex:<bucket>:<slot>`. The weekly reading is whichever window has 10080 minutes. `primary` can be the weekly window; nothing assumes 5 hours. `planType` becomes the plan badge (`prolite` → "Pro x5", `pro` → "Pro x20").
- **Reset credits.** `rateLimitResetCredits.availableCount` is the count; `credits[]` (`id`, `expiresAt`) may be missing or capped and is sorted by expiry for display. Stored on the report as `codexResetCredits` with the query time.
- **Rollouts.** `rollout-*.jsonl` under `sessions/` and `archived_sessions/`; a line is decoded only when its envelope is `session_meta`, `turn_context` or `event_msg`. `session_meta` supplies id, cwd, `source` and `originator`: `source` `cli` / `exec` / `vscode` decides the client, and `originator == "Codex Desktop"` counts only when `source` says nothing, because a CLI launched from Desktop inherits the Desktop originator. `subagent` marks sub-agents; `other == "guardian"` marks internal sessions, excluded from sessions, turns and completions. `turn_context.model` names the model. `token_count` totals are differenced (`total_token_usage`, with `last_token_usage` after a reset); cached input is subtracted from input and reasoning is already in output. Events older than the session start are a fork's inherited history: they set the baseline and are not counted. `task_started` (`turn_id`) starts a turn, `task_complete` completes it and records a completion for non-internal sessions, `turn_aborted` ends it; the last 32 turns per transcript are kept. `user_message` supplies the fallback title; `session_index.jsonl` (`thread_name`) supplies the real one.
- **Liveness.** Last turn running and file modified within 120 s. Indexing budget 1.5 s per poll; a partial last line is retried; one session id counts once even when its rollout was archived. `pctOfWindow` is nil and shows as "—".
- Tests: `CodexProviderTests`; cross-vendor: `CombinedProviderTests`.

## DeepSeek Harness

Code: `Providers/DeepSeek/`.

- **Location.** `DSH_HOME` (with `~` expansion), default `~/.dsh`; installed when `profiles/` or `sessions/` exists. Node.js is required (`PATH`, `/opt/homebrew/bin/node`, `/usr/local/bin/node`).
- **Logs.** `session.jsonl` or `session.jsonl.zstd`. Harness appends one Zstandard frame per write; the helper decodes frame after frame using `engine.bytesWritten` from `zstdDecompressSync`. Only complete lines up to the last newline are indexed; a changed or truncated file replays from offset 0. The `session` header must be version 0. `seedLength` marks inherited history: lines before it set the model but contribute no tokens or liveness. Packed `text-chunks` / `reasoning-chunks` / `tool-call-chunks` rows only refresh the running turn's observation time. `request/header` and `request/context` set model and provider. `assistant/chunk` usage and the following `assistant/message` usage describe one attempt (same turn and step) and replace each other; `llm/retry-started` opens a new attempt. In = `inputTokens` + `cacheWriteTokens`, Cache = `cacheReadTokens`, Out = `outputTokens`. `turn/start` starts a turn and `turn/end` finishes it; only `reason.kind == completed` records a completion, and only for non-sub-agent sessions (`origin == subagent` or `delegationDepth > 0` marks a sub-agent). `session/end-seed` clears turns; `session/title` and the first user message provide the title.
- **Liveness.** Last turn running and either a Node process that predates the turn holds `profiles/*/cordis.yml` (`lsof`, same uid, executable named `node`) or the file changed within 120 s.
- **Balance.** A Node helper loads Harness's own `@deepseek-ai/dsh-credentials-local` package (`/opt/homebrew/lib/node_modules`, `/usr/local/lib/node_modules`, `~/.bun/install/global/node_modules`, newest `~/.npm/_npx/*/node_modules`) and calls `parseCredentialsDocument` on `.credentials.yaml`; `settings.yaml` section `llm-deepseek` supplies `apiKeyEnv` (default `DEEPSEEK_API_KEY`) and `baseURL` (`DEEPSEEK_BASE_URL` also honored). The environment variable wins over the stored reference. Any origin other than `https://api.deepseek.com` returns "custom endpoint" without a request. The request uses a 15 s timeout and no redirects; `NODE_OPTIONS` and `NODE_PATH` are stripped; the key never leaves the helper. Balance strings decode as `Decimal`. Interval 120 s.
- **Costs.** `DeepSeekPricing` prices each request of provider `deepseek-official` per model in CNY and USD from the official price list (check date recorded in the file); peak pricing (×2) applies to requests started Monday to Friday 09:00–12:00 and 14:00–18:00 Beijing time. Unpriced models or non-official routes have no estimate rather than zero. Estimates are per request, never an invoice, and never converted between currencies. DeepSeek rows are API-billed: balance and cost, no quota percentage.
- Tests: `DeepSeekProviderTests`.

## Antigravity

Code: `Providers/Antigravity/`, `Providers/Additional/`.

- **Quota.** Candidates come from `ps -U <uid> -o pid=,command=`: `antigravity-cli` / `agy` processes, or a `language_server` under the Antigravity application with a `--csrf_token`. Listening ports come from `lsof`. For each candidate (at most 6, 8 endpoints each, 20 s overall) the client POSTs to `https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary` with `Connect-Protocol-Version: 1` and `X-Codeium-Csrf-Token`, falling back to `GetUserStatus`. A self-signed certificate is accepted only for 127.0.0.1. Summary buckets (`bucketId`, `remainingFraction`, `resetTime`; disabled buckets skipped) become rows `antigravity:<bucketId>`; the period is inferred from "weekly" / "five_hour" in the id. The legacy status response yields one row per model family (Gemini; Claude + GPT) using the lowest remaining fraction; `userTier.name` or `planStatus.planInfo.planName` is the plan. No running service means a notice, never a login attempt.
- **Sessions.** SQLite `gen_metadata` (and `steps` when a usage row lacks a timestamp) in the roots above; only `.db` files, with the `-wal` file in the change signature. `AntigravityProtoReader` (adapted from CodexBar) decodes the recorded protobuf layout. A usage row is accepted only with a recorded timestamp or a unique join to a `steps` row through `botID` or `stepUUID`; opaque timestamps and file modification times are never used, and unverifiable rows are excluded with a notice. In = system prompt + new input, Out = output + reasoning, Cache = cache read; identity is the response id or the row index. Same-named databases in different roots are the same conversation. Client label "Antigravity CLI" for `antigravity-cli/` paths.
- **Completion.** `Stop` hook in `~/.gemini/config/hooks.json`; see session lifecycle. `GEMINI_CLI_HOME` overrides `~/.gemini`.
- Tests: `AdditionalProviderTests`, `CompletionHooksTests`.

## Cursor

Code: `Providers/Cursor/CursorClient.swift`.

- **Token.** `ItemTable` key `cursorAuth/accessToken` in `state.vscdb`, read in a normal SQLite read transaction (which sees the WAL) and decoded as UTF-8 or UTF-16LE. The JWT's `exp` must be at least 60 s in the future and `sub` supplies the user id; the `WorkosCursorSessionToken` cookie is built in memory. Nothing is refreshed or written; an expired token is a "sign in" notice until Cursor refreshes it.
- **Quota.** `GET https://cursor.com/api/usage-summary`: `membershipType` (plan), `individualUsage.plan` (`totalPercentUsed` or `used` / `limit`, `autoPercentUsed`, `apiPercentUsed`), `individualUsage.overall`, `teamUsage.pooled`, `individualUsage.onDemand`; rows `cursor`, `cursor:models`, `cursor:third-party`, `cursor:personal`, `cursor:team`, `cursor:extra`, period from `billingCycleStart` / `billingCycleEnd`. Percentages are already percent (0.5 means 0.5%). Interval 120 s.
- **Usage events.** `POST https://cursor.com/api/dashboard/get-filtered-usage-events` from the start of the day `max(168, history hours)` hours ago, pages of 1000 up to 200 pages within 25 s; `totalUsageEventsCount` must agree between pages and page overlaps are removed only when proven by identical boundary rows. Rows without `tokenUsage` are skipped. Identity = hash(account, `conversationId`, timestamp ms, model, input, output, cache read, cache write) plus an occurrence ordinal, so real duplicate requests survive and the same rows observed from another Mac merge. In = `inputTokens` + `cacheWriteTokens`. Events with a `conversationId` group into `cursor-account:<account>:<conversationId>`; others stay unassigned. These sessions are account-wide: never running, not attributed to this Mac. Cached 300 s per account and day boundary, failures included.
- **Completion.** `stop` hook in `~/.cursor/hooks.json`; see session lifecycle.
- Tests: `AdditionalProviderTests`, `CompletionHooksTests`.

## Grok CLI

Code: `Providers/Grok/`.

- **Credential.** `$GROK_HOME/auth.json` (default `~/.grok`): entries keyed `https://auth.x.ai::…` (preferred) or `https://accounts.x.ai/sign-in`, with a non-empty `key` and an unexpired `expires_at`. A `principal_type` of `team` is rejected with a notice. Browser and web cookies are never imported.
- **Quota.** `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` with `Authorization: Bearer` and `x-xai-token-auth: xai-grok-cli`; `config.creditUsagePercent` and `currentPeriod` (`USAGE_PERIOD_TYPE_WEEKLY` / `MONTHLY`) make the `grok` row; `onDemandCap` / `onDemandUsed` make the separate `grok:extra` row, never a substitute for the subscription. `/v1/settings` (2 s) supplies `subscription_tier_display`. Interval 120 s.
- **Logs.** `sessions/**/updates.jsonl`: `session/update` and `_x.ai/session/update` whose `params.sessionId` matches the directory; `_meta.agentTimestampMs` is the time, `_meta.eventId` deduplicates, `_meta.promptId` (or the first event id) identifies the turn. `turn_completed` carries `usage.inputTokens`, `outputTokens`, `cachedReadTokens` / `cacheReadTokens` (subtracted from input; must not exceed it) and `stop_reason`. `logs/unified.jsonl`: `shell.turn.inference_done` with `prompt_tokens`, `completion_tokens`, `cached_prompt_tokens`; the model is scoped to the exact session and process (`pid` plus an `AuthManager::new` generation), never inherited across processes; identity is `event_id` or a hash of the line. The unified log owns usage for sessions it covers (origin priority 2 over 1); the legacy log keeps titles, workspaces, turns and completions, and a notice says older history may be incomplete. Legacy `totalTokens` / `signals` context counters are not consumption.
- Tests: `AdditionalProviderTests`, `CompletionHooksTests`.

## OpenCode and OpenCode Go

Code: `Providers/OpenAgents/`.

- **Sessions.** `opencode.db` first (`session_message` or `message`; `session_v2` or `session` for titles and directories): assistant rows with a `tokens` object created inside the history window; then `storage/message/**/*.json`. Both produce the event id `opencode:<message id>`, so a message present in both is counted once. In = `tokens.input` + `tokens.cache.write`, Out = `tokens.output` + `tokens.reasoning`, Cache = `tokens.cache.read`; `cost` becomes `estimatedUSD` metadata. A persisted message end is not an agent end, so OpenCode has no running or terminal turns.
- **Credentials.** `auth.json` entries of type `api` with providers `opencode-go` (Go), `kimi-for-coding` / `kimi-coding` / `kimi-code` (Kimi CN), `zai-coding-plan` (GLM global), `zhipuai-coding-plan` (GLM CN). A `provider.<id>.options.baseURL` in `opencode.json` / `opencode.jsonc` overrides the provider name and must be an official coding endpoint to count; anything else is an API endpoint or proxy, not a plan. OpenCode's own `zai` provider is not mapped to a Coding Plan. `OPENCODE_GO_API_KEY` in the environment is Go; plain `opencode` / Zen keys are not.
- **Go quota.** `GET https://opencode.ai/zen/go/v1/usage`: `usage.rolling` (5 h), `weekly` (7 d), `monthly` with `percent` (already 0–100), `resetInSec` or `resetTime`.
- **API services.** Keys for known API hosts (Anthropic, OpenAI, DeepSeek, Google, xAI, OpenRouter, Groq, Mistral, Moonshot, GLM) found in `auth.json` become `AgentService` rows of product `api`; no balance is queried for them.
- Tests: `OpenAgentProviderTests`.

## Kimi

- **Sessions.** Modern layout `sessions/<workspace>/<session>/agents/<agent>/wire.jsonl` (`KIMI_CODE_HOME`, default `~/.kimi-code`) and legacy `~/.kimi/sessions/<workspace>/<session>/wire.jsonl`. Modern: `usage.record` with `usageScope == turn` counts (`inputOther` + `inputCacheCreation`, `output`, `inputCacheRead`); duplicate `step.end` summaries are ignored; the model comes from the latest `llm.request`; `context.append_loop_event` on the `main` agent starts a turn at its first `step.begin` and refreshes it; `turn.ended` with `reason == completed` and no `error` completes it, and child agents never finish the parent. The workspace path comes from `workspaces.json` next to the session tree. Legacy: `StatusUpdate` messages with `token_usage` are cumulative per `message_id`, so the larger value replaces the earlier one.
- **Credentials.** `KIMI_CODE_API_KEY` (CN unless `KIMI_CODE_BASE_URL` is the official global base); native OAuth slots `credentials/kimi-code.json` (CN) and `credentials/kimi-code-env-0e4f99c69cc27850.json` (global; the suffix is the first 16 hex characters of the SHA-256 of the official toolkit's environment JSON), each with an unexpired `access_token`; `device_id` is sent as `X-Msh-Device-Id`. A custom `KIMI_CODE_BASE_URL` or `KIMI_CODE_OAUTH_HOST` / `KIMI_OAUTH_HOST` disables the native slots. Pi's `KIMI_API_KEY` and its `kimi-coding` OAuth login (unexpired `access`, no custom OAuth host) are also read. Tokens are never refreshed or written.
- **Quota.** `GET /coding/v1/usages` on `api.kimi.com` (CN) or `api.kimi.ai` (global): `usage` is the weekly window; `limits[]` entries are windows of `window.duration` × `timeUnit`, each with `detail.limit` and `used` (or `remaining`) and `resetTime`; `membership.level` is the plan.
- **Identity.** `GET /coding/v1/me` (8 s): `user_id`, `domain` (null → 0) and `region` hash into the pool scope with evidence `account`, so an API key and an OAuth token of the same account share one pool. Failure keeps the credential-scoped pool with an "identity unconfirmed" notice. Confirmed identities are cached as hashes in `open-agent-identities.json`.
- Tests: `OpenAgentProviderTests`, `KimiQuotaIdentityTests`.

## GLM

- **Credentials.** `Z_AI_API_KEY` is global unless `Z_AI_REGION=bigmodel-cn`; `Z_AI_USAGE_SCOPE=team` requires `Z_AI_ORGANIZATION` and `Z_AI_PROJECT`, sent as `Bigmodel-Organization` / `Bigmodel-Project` headers with `?type=2`. `BIGMODEL_API_KEY`, `ZHIPU_API_KEY`, `ZHIPUAI_API_KEY` and `GLM_API_KEY` are CN. `ANTHROPIC_BASE_URL` (environment or `~/.claude/settings.json` `env`) pointing at `api.z.ai` or `open.bigmodel.cn` `/api/coding/paas/v4` or `/api/anthropic` with `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` counts as the same plan.
- **Quota.** `GET /api/monitor/usage/quota/limit` on `api.z.ai` or `open.bigmodel.cn`: `data.limits[]` of type `TOKENS_LIMIT`, `CREDIT_LIMIT` or `TIME_LIMIT`; period = `number` × `unit` (1 day, 3 hour, 5 minute, 6 week); used from `percentage` or `usage` / `remaining` / `currentValue`; `nextResetTime` in ms (a 5 h window's reset more than 5 h away is dropped). `TIME_LIMIT` is the MCP window, labelled "MCP", and never stands in for model quota. `data.planName` is the plan. Different keys stay different pools ("Credential"); no cross-key identity protocol exists.
- **Usage.** GLM is a billing service only: tokens come from the OpenCode, Pi or Claude logs that used it, with their original provider id.
- Tests: `OpenAgentProviderTests`.

## Pi

- **Sessions.** `sessions/**/*.jsonl` under `PI_CODING_AGENT_DIR` (default `~/.pi/agent`): `session` (id, cwd), `session_info` (name), `model_change`, and assistant `message` lines with `usage` (`input`, `output`, `cacheRead`, `cacheWrite`, `cost.total`). In = `input` + `cacheWrite`; Out already includes reasoning. Identity is `pi:response:<hash(provider, responseId)>`, or `pi:entry:<hash(entry id, timestamp, provider, model)>` for older lines, so forks that keep the original entries collapse to one request. `cost.total` becomes `estimatedUSD` metadata — a client-side list-price estimate, not a bill.
- **Lifecycle.** The observer extension (`extensions/agent-hud.ts`) writes `agent-hud/turns/*.json`; see session lifecycle.
- **Credentials.** `auth.json` entries of type `api_key` (a value starting with `!` is an executable resolver and is skipped; a value naming an environment variable is resolved from the environment) with `models.json` `providers.<id>.baseUrl` overrides. The provider names `zai` (GLM global) and `zai-coding-cn` (GLM CN) have this meaning only in Pi; `kimi-coding` / `kimi-for-coding` / `kimi-code` are Kimi CN. `ZAI_API_KEY`, `ZAI_CODING_CN_API_KEY` and `KIMI_API_KEY` in the environment are Pi's. Other `api_key` entries for known API hosts become API service rows.
- Tests: `OpenAgentProviderTests`, `PiSessionObserverTests`.

## Billing pools

`BillingPool` (`Models/BillingPool.swift`) identifies who pays, independently of the program that made the request.

| Field | Values | Meaning |
| --- | --- | --- |
| `provider` | `Kimi`, `GLM`, `OpenCode Go`, … | The billing service |
| `realm` | `CN`, `International` | Deployment |
| `product` | `plan`, `api`, `unknown` | Subscription plan, pay-as-you-go API, or unresolved |
| `scope` | hash | Account id (Kimi `/me`) or credential hash; never the credential itself |
| `evidence` | `account`, `credential`, `unresolved` | How the scope was established |
| `organization`, `project` | hashes | Team scope (GLM) |
| `entitlement` | `kimi-code`, `glm-coding-plan`, `opencode-go` | The quota product |

Rules:

- `id` is `pool:` + hash of all fields; a window's row id is `<pool id>:<window>`. Windows of one pool (5 h, 7 d, monthly) are separate rows and are never added together.
- Identical credentials found in Kimi, OpenCode, Pi or Claude configuration merge into one pool with several clients; a different key stays a different pool until the provider's own identity protocol proves otherwise, and only Kimi has one. Same plan name, same reset time or same percentage never merge pools.
- Historical usage carries the attribution recorded at the time (`UsageAttribution`: client, provider id, pool if known, `estimatedUSD`); events without a pool show "billing unconfirmed" and are never re-attributed from today's login.
- Each pool's quota is fetched once per 120 s using any of its credentials; when every credential is rejected with 401 / 403 the pool is inactive, and `UsageReport.activeQuotaPoolIDs` (an empty set means "scan complete, nothing usable") retires its rows, cached readings and display settings. A temporary failure keeps the last reading.
- API balances and costs (DeepSeek) have their own pool identity; balances use the latest observation, costs deduplicate per request; nothing is summed with a subscription percentage or converted between currencies.
- Claude and Codex plan quotas are read only from their own engines; no copy of a Claude or Codex percentage is created for OpenCode or Pi sessions.

## Tests and probes

Run from the package root: `swift test --filter <ClassName>`. Fixtures are synthetic; no test needs credentials or network.

| Area | Tests |
| --- | --- |
| Claude Code | `ClaudeEngineTests`, `ISO8601FastTests`, `ClaudeUsageParseTests`, `ClaudeTranscriptTests`, `AccumulatorCompactionTests`, `CooperativeIndexingTests`, `ClaudeCodeProviderTests`, `SubscriptionTests` |
| Codex | `CodexProviderTests` |
| DeepSeek | `DeepSeekProviderTests` |
| Antigravity, Cursor, Grok | `AdditionalProviderTests`, `CompletionHooksTests` |
| OpenCode, Kimi, GLM, Pi | `OpenAgentProviderTests`, `KimiQuotaIdentityTests`, `PiSessionObserverTests` |
| Cross-provider | `CombinedProviderTests`, `RetainedUsageProviderTests`, `UsageRefreshTests`, `LiveStatusTests`, `SessionSourceTests`, `QuotaHistoryStoreTests`, `UsageAnalyticsTests` |

Read-only probes against the local machine: `--probe`, `--probe-open-agents`, and `AGENT_HUD_PROBE_ADDITIONAL=1 swift test --filter AdditionalProviderTests/testInstalledSourcesReadOnlyProbe`; see command line.

## Upstream references

Pinned commits the parsers were checked against. "Adapted" means code was derived and the license is reproduced in `THIRD_PARTY_NOTICES.txt`; "informed" means field names or protocol details were taken from the source and the project is listed in the notices; "reference-only" means the source was read to confirm names and fields, no code was adapted, and it is therefore not listed in the notices.

| Project | Commit | License | Use |
| --- | --- | --- | --- |
| [CodexBar](https://github.com/steipete/CodexBar/tree/05bb0e694afa93e234991bbd5eaab6afcd1b9e7d/Sources/CodexBarCore/Providers), plus [928166f](https://github.com/steipete/CodexBar/tree/928166f899471bbdcb72210641cdec91324d0154) for Go, Kimi and GLM parsing | `05bb0e69…`, `928166f8…` | MIT | Adapted: `AntigravityProtoReader.swift`. Informed: Antigravity service discovery and quota schema, Cursor authentication and dashboard protocol, Grok credits proxy, Go / Kimi / GLM quota parsing |
| [Tokscale](https://github.com/junhoyeo/tokscale/tree/15516420f2b106750760f6e182559899f814e2dc/crates/tokscale-core/src) | `15516420…` | MIT | Adapted: Grok log parsing and fixtures. Informed: OpenCode SQLite schema, Pi and Kimi storage and token fields, Antigravity token layout, Cursor session identity |
| [Kimi Code](https://github.com/MoonshotAI/kimi-code/tree/0b67511291a0dbf6781d4bce63cab3f228ea6fe1) (`packages/oauth`, `packages/agent-core-v2/docs/wire-manifest.d.ts`) | `0b675112…` | MIT | Informed: regional endpoints, `/me` profile, OAuth storage naming, wire protocol |
| [Pi](https://github.com/earendil-works/pi/tree/6160683a4a8012f0d1cd30c145df18b4ca6f5176) (`packages/ai/src/providers/zai.ts`, `zai-coding-cn.ts`, `packages/ai/src/auth/oauth/kimi-coding.ts`) | `6160683a…` | MIT | Reference-only: provider naming, environment variables, OAuth credential fields |
| [zai-coding-plugins](https://github.com/zai-org/zai-coding-plugins/blob/0446d0bb0bc537d97d3ab3664c4b8b9c4a0e1254/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs) | `0446d0bb…` | Apache-2.0 | Reference-only: `/api/anthropic` ↔ monitor endpoint mapping |

Official protocol documents: [Antigravity hooks](https://antigravity.google/docs/hooks/), [Cursor hooks](https://cursor.com/docs/hooks), [Antigravity CLI `/resume`](https://antigravity.google/docs/cli/commands/resume/) (a desktop import clones the CLI history rather than sharing one record), [Codex app-server](https://learn.chatgpt.com/docs/app-server), [DeepSeek balance](https://api-docs.deepseek.com/api/get-user-balance/) and [pricing](https://api-docs.deepseek.com/quick_start/pricing/).
