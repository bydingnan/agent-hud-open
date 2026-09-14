# Providers

## Overview

A provider is the `AgentHUDCore` component that turns one client's local records and account queries into a `UsageReport`: sessions, usage events, quota windows, balances, turns and completions. Common rules: a provider reads only what the client already stores on this Mac; it uses the client's existing sign-in or configured key for metadata requests only, never sending a model message or consuming a reset credit; credentials never enter reports or caches; network requests follow no redirects and share no cookies; SQLite databases are opened read-only in one read transaction, which sees committed WAL pages; a missing, signed-out or failing client never hides another. Counting conventions and request intervals: [usage semantics](usage-semantics.md); running and terminal turns: [session lifecycle](session-lifecycle.md); boundaries: [data access](data-access.md); probes: [command line](command-line.md).

| Client | Reads | Quota source | Balance or cost | Running / terminal turns |
| --- | --- | --- | --- | --- |
| Claude Code | Transcripts, account profile | Claude Code engine `get_usage` | — | Yes / Yes |
| Codex Desktop / CLI | Rollouts, session index | Codex app-server `account/rateLimits/read` | — | Yes / Yes |
| DeepSeek Harness | Session logs, profile lock evidence, settings, credentials | — | Account balance, per-request cost estimate | Yes / Yes |
| Antigravity | Conversation databases | Running local language server | — | No / `Stop` hook |
| Cursor | Session token | Cursor usage summary and usage events | — | No / `stop` hook |
| Grok CLI | Credentials, session updates, unified log | Grok CLI credits proxy | — | Yes / Yes |
| OpenCode (+ Go) | Database, message store, credentials, config | OpenCode Go usage | Per-request cost from the log | No / No |
| Kimi | Wire logs, OAuth slots, device id | Kimi coding usages | — | Yes / Yes |
| GLM | None | GLM monitor quota | — | n/a |
| Pi | Session logs, observer turn files, credentials, model config | Kimi, GLM and Go pools | Per-request cost from the log | Yes / Yes, with the observer |

## Claude Code
- **Reads** — `~/.claude/projects/**/*.jsonl` and `~/.config/claude/projects/**/*.jsonl`; `~/.claude.json` (`CLAUDE_CONFIG_DIR` honored) for the Max tier.
- **Credentials & env** — The installed engine's existing sign-in; nothing is read from the keychain. `rate_limits_available == false` (API key or third-party login) keeps local data and shows a notice instead of rows.
- **Endpoints** — A headless `claude -p` with hooks disabled and `CLAUDE_CODE_ENTRYPOINT=agent-hud` answers one `get_usage` control request; no prompt is sent, nothing is billed. `five_hour`, `seven_day` and per-family weekly windows become rows `claude-session`, `claude-weekly` and `claude-weekly-<family>`; `subscription_type` `max` is refined to `max_5x` / `max_20x` from the profile's rate-limit tier.
- **Counting & dedup** — One event per `message.id` (fallback `requestId`); In = `input_tokens` + `cache_creation_input_tokens`, Cache = `cache_read_input_tokens`; consumers are exact model ids, `<synthetic>` messages are ignored, and sub-agent transcripts (`agent-*.jsonl`, `subagents/`) and `isSidechain` lines never start or finish a turn. The session share is the session's share of the current 5 h window times its utilization; `entrypoint` labels CLI, Desktop, IDE or SDK.

## Codex Desktop / CLI
- **Reads** — `rollout-*.jsonl` under `$CODEX_HOME/sessions` and `archived_sessions` (default `~/.codex`), decoding only `session_meta`, `turn_context` and `event_msg` lines; `session_index.jsonl` for thread names.
- **Credentials & env** — The engine's own sign-in; `auth.json` is never read. Desktop and CLI on one `CODEX_HOME` share one set of windows; separate homes are not merged.
- **Endpoints** — `codex app-server --listen stdio://` (the Desktop-bundled engine or an installed CLI): `initialize`, `initialized`, `account/rateLimits/read`, never a thread or turn. `rateLimitsByLimitId` is authoritative even when empty; each bucket's `primary` / `secondary` window is a row labelled by `windowDurationMins` (10080 → Weekly, multiples of 60 → "Nh", else "Nm", unknown → Primary / Secondary), the shared primary row keeps the id `codex`, `planType` is the plan badge and `rateLimitResetCredits.availableCount` the reset-credit count.
- **Counting & dedup** — `token_count` totals are differenced (`total_token_usage`, `last_token_usage` after a reset); cached input is subtracted from input, reasoning is already in output, and events older than the session start are inherited fork history that only sets the baseline. `source` (`cli` / `exec` / `vscode`) decides the client, `originator == "Codex Desktop"` counts only when `source` is silent, `subagent` and `guardian` sessions are excluded, and one session id counts once even after archiving.

## DeepSeek Harness
- **Reads** — `$DSH_HOME/sessions/**/session.jsonl[.zstd]` (default `~/.dsh`); `profiles/*/cordis.yml` only as process evidence; `settings.yaml` and `.credentials.yaml` for the balance key. Node.js is required for Zstandard frames and the balance helper.
- **Credentials & env** — `settings.yaml` section `llm-deepseek` names `apiKeyEnv` (default `DEEPSEEK_API_KEY`) and `baseURL` (`DEEPSEEK_BASE_URL` also honored), and the environment wins over the stored reference. The key is resolved by Harness's own credentials package inside a short-lived Node helper and never leaves it; any origin other than `https://api.deepseek.com` reports a custom endpoint without a request.
- **Endpoints** — `GET https://api.deepseek.com/user/balance`; balances decode as `Decimal` and keep their currency. Requests of provider `deepseek-official` are priced per model in CNY and USD from the official price list, ×2 in peak hours (Monday–Friday 09:00–12:00 and 14:00–18:00 Beijing time); unpriced models or other routes have no estimate rather than zero.
- **Counting & dedup** — `assistant/chunk` usage and the following `assistant/message` usage describe one attempt (turn, step) and replace each other; `llm/retry-started` opens a new attempt. In = `inputTokens` + `cacheWriteTokens`, Cache = `cacheReadTokens`, Out = `outputTokens` (reasoning included); lines before `seedLength` are inherited history that only sets the model.

## Antigravity
- **Reads** — SQLite `gen_metadata` (and `steps`) in `$GEMINI_CLI_HOME/antigravity-cli/conversations/*.db`, `antigravity/*.db` and `antigravity/conversations/*.db` (default `~/.gemini`); same-named databases in different roots are one conversation.
- **Credentials & env** — None read. The running language server's CSRF token is taken from its command line; no login is attempted, and a self-signed certificate is accepted only for 127.0.0.1.
- **Endpoints** — `POST https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary` (Connect protocol) on the user's `antigravity-cli` / `agy` or application `language_server` process, falling back to `GetUserStatus`. Buckets (`bucketId`, `remainingFraction`, `resetTime`) become rows `antigravity:<bucketId>` with the period inferred from "weekly" / "five_hour" in the id; the legacy status yields one row per model family, and the plan is `userTier.name` or `planStatus.planInfo.planName`.
- **Counting & dedup** — The recorded protobuf layout is decoded; a usage row counts only with a recorded timestamp or a unique join to a `steps` row via `botID` / `stepUUID`; file times are never usage times, and unverifiable rows are excluded with a notice. In = system prompt + new input, Out = output + thinking, Cache = cache read; identity is the response id or the row index.

## Cursor
- **Reads** — `ItemTable` key `cursorAuth/accessToken` in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`; nothing else local.
- **Credentials & env** — The JWT must stay valid for at least 60 s; `sub` supplies the user id and the `WorkosCursorSessionToken` cookie is built in memory. Nothing is refreshed or written; an expired token is a sign-in notice until Cursor renews it.
- **Endpoints** — `GET https://cursor.com/api/usage-summary` → rows `cursor`, `cursor:models`, `cursor:third-party`, `cursor:personal`, `cursor:team` and `cursor:extra` with the period from `billingCycleStart` / `billingCycleEnd` and `membershipType` as the plan. `POST https://cursor.com/api/dashboard/get-filtered-usage-events` from the start of the day at least 7 days back, paged, with `totalUsageEventsCount` required to agree between pages.
- **Counting & dedup** — Rows without `tokenUsage` are skipped; In = `inputTokens` + `cacheWriteTokens`; identity = hash(account, `conversationId`, timestamp, model, counts) plus an occurrence ordinal, so true duplicates survive and rows seen from another Mac merge. Events group into `cursor-account:<account>:<conversationId>` sessions that are account-wide, never running and not attributed to this Mac.

## Grok CLI
- **Reads** — `$GROK_HOME/auth.json` (default `~/.grok`), `sessions/**/updates.jsonl` with `summary.json` / `signals.json`, and `logs/unified.jsonl`.
- **Credentials & env** — An `auth.json` entry keyed `https://auth.x.ai::…` (preferred) or `https://accounts.x.ai/sign-in` with a non-empty `key` and an unexpired `expires_at`; `principal_type` `team` is rejected with a notice. Browser cookies are never imported.
- **Endpoints** — `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` (Bearer token, `x-xai-token-auth: xai-grok-cli`): `creditUsagePercent` and `currentPeriod` (weekly / monthly) make the `grok` row, `onDemandCap` / `onDemandUsed` the separate `grok:extra` row; `/v1/settings` supplies `subscription_tier_display`.
- **Counting & dedup** — `updates.jsonl`: `session/update` events whose `sessionId` matches the directory, deduplicated by `_meta.eventId`, turn from `_meta.promptId`, usage from `turn_completed` (cached reads subtracted from input). `unified.jsonl`: `shell.turn.inference_done` with `prompt_tokens`, `completion_tokens` and `cached_prompt_tokens`, model scoped to session and process, identity `event_id` or a line hash; it owns usage for sessions it covers, the legacy log keeps titles, turns and completions, and legacy `totalTokens` context counters are not consumption.

## OpenCode and OpenCode Go
- **Reads** — `opencode.db` (`session_message` / `message`, `session_v2` / `session`) then `storage/message/**/*.json` under `$XDG_DATA_HOME/opencode` (default `~/.local/share/opencode`); `auth.json`; `$XDG_CONFIG_HOME/opencode/opencode.json[c]` for `provider.<id>.options.baseURL`.
- **Credentials & env** — `auth.json` entries of type `api`: `opencode-go` (Go), `kimi-for-coding` / `kimi-coding` / `kimi-code` (Kimi CN), `zai-coding-plan` (GLM global), `zhipuai-coding-plan` (GLM CN); a configured `baseURL` must be an official coding endpoint to count as a plan, and OpenCode's own `zai` provider is not one. `OPENCODE_GO_API_KEY` is Go; keys for known API hosts become API service rows without a balance query.
- **Endpoints** — `GET https://opencode.ai/zen/go/v1/usage` per pool: `rolling` (5 h), `weekly` (7 d) and `monthly` with `percent` and `resetInSec` or `resetTime`.
- **Counting & dedup** — Assistant messages with a `tokens` object: In = `tokens.input` + `tokens.cache.write`, Out = `tokens.output` + `tokens.reasoning`, Cache = `tokens.cache.read`, `cost` → `estimatedUSD`. Both stores yield the id `opencode:<message id>`, so a message present in both counts once.

## Kimi
- **Reads** — `$KIMI_CODE_HOME/sessions/<workspace>/<session>/agents/<agent>/wire.jsonl` (default `~/.kimi-code`) and legacy `~/.kimi/sessions/**/wire.jsonl`; `workspaces.json` for workspace paths; `credentials/*.json` and `device_id`.
- **Credentials & env** — `KIMI_CODE_API_KEY` (CN unless `KIMI_CODE_BASE_URL` is the official global base); native OAuth slots `credentials/kimi-code.json` (CN) and `kimi-code-env-<hash>.json` (global) with an unexpired `access_token`, disabled by a custom `KIMI_CODE_BASE_URL` or OAuth host; Pi's `KIMI_API_KEY` and `kimi-coding` OAuth login are read too. Tokens are never refreshed or written.
- **Endpoints** — `GET /coding/v1/usages` on `api.kimi.com` (CN) or `api.kimi.ai` (global) with `device_id` as `X-Msh-Device-Id`: `usage` is the weekly window, `limits[]` are windows of `window.duration` × `timeUnit`, `membership.level` is the plan. `GET /coding/v1/me`: `user_id`, `domain` (null → 0) and `region` hash into the pool scope with evidence `account`, so a key and a token of one account share a pool; a failed lookup keeps the credential-scoped pool with an identity-unconfirmed notice.
- **Counting & dedup** — Modern logs: `usage.record` with `usageScope == turn` (`inputOther` + `inputCacheCreation`, `output`, `inputCacheRead`), `step.end` summaries ignored, model from the latest `llm.request`. Legacy `StatusUpdate` `token_usage` is cumulative per `message_id`, so the larger value replaces the earlier one.

## GLM
- **Reads** — None; tokens come from the OpenCode, Pi or Claude logs that used the service, under their original provider id.
- **Credentials & env** — `Z_AI_API_KEY` (global unless `Z_AI_REGION=bigmodel-cn`; `Z_AI_USAGE_SCOPE=team` needs `Z_AI_ORGANIZATION` and `Z_AI_PROJECT`, sent as `Bigmodel-Organization` / `Bigmodel-Project`); `BIGMODEL_API_KEY`, `ZHIPU_API_KEY`, `ZHIPUAI_API_KEY` and `GLM_API_KEY` (CN). `ANTHROPIC_BASE_URL` (environment or `~/.claude/settings.json` `env`) at `api.z.ai` / `open.bigmodel.cn` `/api/coding/paas/v4` or `/api/anthropic` with `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` is the same plan.
- **Endpoints** — `GET /api/monitor/usage/quota/limit` on `api.z.ai` or `open.bigmodel.cn` (`?type=2` for team scope): `data.limits[]` of type `TOKENS_LIMIT`, `CREDIT_LIMIT` or `TIME_LIMIT`, period = `number` × `unit`, used from `percentage` or `usage` / `remaining`, `nextResetTime` in milliseconds, `data.planName` as the plan. `TIME_LIMIT` is the MCP window, labelled MCP, and never stands in for model quota.
- **Counting & dedup** — Not applicable. Different keys stay different pools because no cross-key identity protocol exists.

## Pi
- **Reads** — `sessions/**/*.jsonl` under `$PI_CODING_AGENT_DIR` (default `~/.pi/agent`); `agent-hud/turns/*.json` written by the observer; `auth.json` and `models.json`.
- **Credentials & env** — `auth.json` entries of type `api_key` (a value starting with `!` is an executable resolver and is skipped; a value naming an environment variable is resolved from it) with `models.json` `providers.<id>.baseUrl`; `zai` (GLM global) and `zai-coding-cn` (GLM CN) have this meaning only in Pi, `kimi-coding` / `kimi-for-coding` / `kimi-code` are Kimi CN, `ZAI_API_KEY`, `ZAI_CODING_CN_API_KEY` and `KIMI_API_KEY` are Pi's, and a `kimi-coding` OAuth login with an unexpired `access` counts when no custom OAuth host is set; other keys for known API hosts become API service rows.
- **Endpoints** — None of its own; quota comes through the Kimi, GLM and Go pools.
- **Counting & dedup** — Assistant `message` lines with `usage`: In = `input` + `cacheWrite`, Out = `output` (reasoning included), Cache = `cacheRead`, `cost.total` → `estimatedUSD` (a list-price estimate). Identity is `pi:response:<hash(provider, responseId)>`, or `pi:entry:<hash(entry id, timestamp, provider, model)>` for older lines, so forks that keep the original entries collapse to one request.

## Billing pools

`BillingPool` identifies who pays, independently of the program that made the request: `provider` (Kimi, GLM, OpenCode Go), `realm` (CN, International), `product` (plan, api, unknown), `scope` (account id from Kimi `/me` or a credential hash, never the credential), `evidence` (account, credential, unresolved), `organization` / `project` (GLM team) and `entitlement` (`kimi-code`, `glm-coding-plan`, `opencode-go`). `id` is `pool:` plus a hash of all fields; a window row is `<pool id>:<window>`, and windows of one pool are never added together.

- Identical credentials found in Kimi, OpenCode, Pi or Claude configuration merge into one pool with several clients; a different key stays a different pool until the provider's own identity protocol proves otherwise, and only Kimi has one. Same plan name, reset time or percentage never merge pools.
- Each pool's quota is fetched once per interval with any of its credentials; when every credential is rejected the pool is inactive and `UsageReport.activeQuotaPoolIDs` retires its rows, readings and display settings, while a temporary failure keeps the last reading.
- Historical usage keeps the attribution recorded at the time (`UsageAttribution`); events without a pool are shown as billing unconfirmed and never re-attributed from today's login. Claude and Codex quotas are read only from their own engines; no copy is created for OpenCode or Pi sessions.

## Caches

Files in the data directory ([architecture](architecture.md#storage)); quota histories keep 30 days, and no file contains conversation text or credentials.

| File | Owner |
| --- | --- |
| `last-usage-report.json` | The retained report, restored at start; rewritten at most once a minute |
| `transcripts-cache-v5.json`, `quota-history.json`, `engine/` | Claude Code transcript index, quota history and engine working directory |
| `codex-transcripts-v5.json`, `codex-quota-history.json`; `deepseek-transcripts-v2.json` | Codex; DeepSeek Harness |
| `antigravity-quota-history.json`, `cursor-quota-history.json`, `grok-quota-history.json`, `turn-completions/<source>/` | Antigravity, Cursor, Grok and the completion-hook inbox |
| `open-agent-quota-history.json`, `open-agent-identities.json` | OpenCode, Kimi, GLM and Pi pools; confirmed Kimi identities as hashes |

## Code map and tests

| Area | Code | Tests (`swift test --filter <ClassName>`; synthetic fixtures, no credentials or network) |
| --- | --- | --- |
| Claude Code | `Sources/AgentHUDCore/Providers/Claude/` | `ClaudeEngineTests`, `ISO8601FastTests`, `ClaudeUsageParseTests`, `ClaudeTranscriptTests`, `AccumulatorCompactionTests`, `CooperativeIndexingTests`, `ClaudeCodeProviderTests`, `SubscriptionTests` |
| Codex, DeepSeek | `Sources/AgentHUDCore/Providers/Codex/`, `DeepSeek/` | `CodexProviderTests`, `DeepSeekProviderTests` |
| Antigravity, Cursor, Grok | `Sources/AgentHUDCore/Providers/Antigravity/`, `Cursor/`, `Grok/`; shared HTTP, SQLite and hooks in `Additional/` | `AdditionalProviderTests`, `CompletionHooksTests` |
| OpenCode, Kimi, GLM, Pi | `Sources/AgentHUDCore/Providers/OpenAgents/` | `OpenAgentProviderTests`, `KimiQuotaIdentityTests`, `PiSessionObserverTests` |
| Cross-provider | `Sources/AgentHUDCore/Providers/CombinedUsageProvider.swift`, `RetainedUsageProvider.swift`, `Sources/AgentHUDCore/Models/BillingPool.swift` | `CombinedProviderTests`, `RetainedUsageProviderTests`, `UsageRefreshTests`, `LiveStatusTests`, `SessionSourceTests`, `QuotaHistoryStoreTests`, `UsageAnalyticsTests` |

## Upstream references

| Project | Commit | License | Use (adapted: code derived, license reproduced in `THIRD_PARTY_NOTICES.txt`; informed: names or protocol details taken, project listed there; reference-only: read to confirm names, not listed) |
| --- | --- | --- | --- |
| [CodexBar](https://github.com/steipete/CodexBar/tree/05bb0e694afa93e234991bbd5eaab6afcd1b9e7d/Sources/CodexBarCore/Providers) | `05bb0e69…`; [`928166f8…`](https://github.com/steipete/CodexBar/tree/928166f899471bbdcb72210641cdec91324d0154) for Go, Kimi and GLM parsing | MIT | Adapted: the Antigravity protobuf reader. Informed: Antigravity service discovery and quota schema, Cursor authentication and dashboard protocol, Grok credits proxy, Go / Kimi / GLM quota parsing |
| [Tokscale](https://github.com/junhoyeo/tokscale/tree/15516420f2b106750760f6e182559899f814e2dc/crates/tokscale-core/src) | `15516420…` | MIT | Adapted: Grok log parsing and fixtures. Informed: OpenCode SQLite schema, Pi and Kimi storage and token fields, Antigravity token layout, Cursor session identity |
| [Kimi Code](https://github.com/MoonshotAI/kimi-code/tree/0b67511291a0dbf6781d4bce63cab3f228ea6fe1) | `0b675112…` | MIT | Informed: regional endpoints, `/me` profile, OAuth storage naming, wire protocol |
| [Pi](https://github.com/earendil-works/pi/tree/6160683a4a8012f0d1cd30c145df18b4ca6f5176), [zai-coding-plugins](https://github.com/zai-org/zai-coding-plugins/blob/0446d0bb0bc537d97d3ab3664c4b8b9c4a0e1254/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs) | `6160683a…`, `0446d0bb…` | MIT, Apache-2.0 | Reference-only: Pi provider naming, environment variables and OAuth credential fields; the `/api/anthropic` ↔ monitor endpoint mapping |

Official protocol documents: [Antigravity hooks](https://antigravity.google/docs/hooks/), [Antigravity CLI `/resume`](https://antigravity.google/docs/cli/commands/resume/), [Cursor hooks](https://cursor.com/docs/hooks), [Codex app-server](https://learn.chatgpt.com/docs/app-server), [DeepSeek balance](https://api-docs.deepseek.com/api/get-user-balance/) and [pricing](https://api-docs.deepseek.com/quick_start/pricing/).
