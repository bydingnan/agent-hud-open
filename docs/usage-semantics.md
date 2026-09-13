# Usage semantics

How Agent HUD Open counts tokens, names quota windows, colors status, throttles account requests, and keeps readings. These rules are shared by every provider and by the desktop. Where each client's data comes from is in [data access](data-access.md); running and terminal turn evidence is in [session lifecycle](session-lifecycle.md).

## Token dimensions

Three additive dimensions (`TokenDimensions`): **In**, **Out** and **Cache**. They never overlap.

| Dimension | Contains | Excludes |
| --- | --- | --- |
| In | Fresh input: prompt tokens plus cache writes (cache creation) | Cache reads |
| Out | Output tokens; reasoning or thinking is already part of the output count and is never added a second time | — |
| Cache | Cache reads only | — |

- Charts, the heat map, model shares and session rows follow the selected dimensions. The default selection is In + Out (`TokenDimensions.fresh`); `all` adds Cache.
- Records written before the Cache dimension existed decode with `cacheReadTokens = 0`.
- Bar buckets are 15 min, 30 min, 1 h or 1 d. Sub-day buckets start on local quarter-hour or hour boundaries inside the exact, half-open range. 1 d buckets are local calendar days: they start at local midnight and last 23 or 25 hours across a daylight-saving change. Events outside the selected range are not counted, empty buckets keep their position, and counts stay integers — never rounded or interpolated.
- One API response is counted once whatever the client's log layout: Claude by message id, Codex by deltas of its cumulative totals, DeepSeek by (turn, step) attempt, Cursor by a stable event identity, Grok by event and prompt id, Pi by response id, OpenCode by message id, Kimi by turn-scoped usage records. Copies of the same event from two files or two Macs merge in `UsageAggregation.usageUnion`; distinct requests with identical counts are kept.

Source fields per client:

| Client | In | Out | Cache |
| --- | --- | --- | --- |
| Claude Code | `input_tokens` + `cache_creation_input_tokens` | `output_tokens` | `cache_read_input_tokens` |
| Codex | delta of `input_tokens` minus delta of `cached_input_tokens` | delta of `output_tokens` (reasoning included) | delta of `cached_input_tokens` |
| DeepSeek Harness | `inputTokens` + `cacheWriteTokens` (Harness already excludes cache hits from `inputTokens`) | `outputTokens` (reasoning included) | `cacheReadTokens` |
| Antigravity | system prompt + new input | output + thinking (separate counters, added) | cache read |
| Cursor | `inputTokens` + `cacheWriteTokens` | `outputTokens` | `cacheReadTokens` |
| Grok CLI | prompt tokens minus cached tokens | completion tokens (reasoning included) | cached tokens |
| OpenCode | `tokens.input` + `tokens.cache.write` | `tokens.output` + `tokens.reasoning` (separate counters, added) | `tokens.cache.read` |
| Kimi | `inputOther` + `inputCacheCreation` | `output` | `inputCacheRead` |
| Pi | `usage.input` + `usage.cacheWrite` | `usage.output` (reasoning included) | `usage.cacheRead` |

The panel's per-session token figure is In + Out of that session.

## Percentages and window naming

- Every percentage shown is **used**, the same convention as Claude Code's `/usage`. Providers store the remaining share; the desktop converts.
- Each row is one quota window the service actually reports, with that window's own reset time and period. Rows come from the response, never from a template. Claude reports a session (5 h) window, a weekly all-models window and weekly per-family windows. Codex reports one or more buckets, each with primary and secondary windows named by `windowDurationMins` ("Weekly", "5h", "30m"; "Primary" / "Secondary" when the period is unknown) — the primary window can be the weekly one. Cursor reports plan, model-category, personal, team and extra-usage percentages. Grok reports weekly or monthly subscription credits and an extra usage budget. Antigravity reports the service's named buckets. Kimi, GLM and OpenCode Go report their own windows labelled by period (minutes, "7d", rolling / weekly / monthly, or "MCP" for GLM's time limit).
- One account's windows are shown once even when two programs share the account (Codex Desktop and CLI). Usage recorded by one client is never duplicated into another client's account.
- Money keeps its currency and is never converted or turned into a percentage. An API balance has no fixed denominator, so API-billed clients (DeepSeek) show balance and estimated cost instead of quota rows. Estimates are labelled as estimates; they are not invoices.
- Codex reset credits show the service's `availableCount`. The per-credit expiry list is supplementary and is never used to derive the count.
- A missing reading is "—", not 0. Zero is shown only when the service reported zero.

## Status levels

Fixed policy in `AlertPolicy`. Nothing is stored, synchronized or configurable, and hosts and companion surfaces must use the same numbers.

| Reading | OK | Warning | Critical |
| --- | --- | --- | --- |
| Quota window | used < 70% | used ≥ 70% | used ≥ 90% |
| API balance in CNY | > 10 | ≤ 10 | ≤ 0 |
| API balance in USD | > 2 | ≤ 2 | ≤ 0 |
| API balance in another currency | > 0 | — | ≤ 0 |
| Account reported unavailable (`isAvailable == false`) | — | — | always |

Colors come from `StatusPalette` (dark: `#3ddc84`, `#ffd23f`, `#ff453a`; light: `#30d158`, `#ffcc00`, `#ff3b30`, with a darker warning text color on light surfaces; idle grey `#9a9aa0`). The glow shows one segment per enabled window that has a reading; windows without a reading stay out of the glow, and a paused or hidden glow is grey. A color describes the resource state of one reading. Readings of different windows are never combined into one health score, and a color never indicates task progress.

Alerts derive from these levels (`QuotaAlertTracker`): the first reading of a window is a silent baseline; crossing 90% used, reaching zero, a forecast of exhaustion before the reset, and a confirmed reset each notify once.

## Account request intervals

Local activity is polled about every 5 seconds, every 2 seconds while an index is still building. Account requests run on their own task, so a slow account query never delays local polling, and each provider keeps its own cadence:

| Request | Minimum interval |
| --- | --- |
| Claude Code engine `get_usage` | 120 s, also after a failure, so completion polling never respawns a broken engine |
| Codex `account/rateLimits/read` | 120 s |
| DeepSeek balance | 120 s |
| Antigravity, Cursor and Grok quota | 120 s |
| Kimi, GLM and OpenCode Go quota | 120 s per billing pool; Kimi account identity is re-checked at most every 120 s until it is confirmed |
| Cursor account usage events | 300 s; a failed fetch is cached for the same interval |

Failures are cached for the same interval as successes and reported as a source notice; the other sources keep working. Every account request is a metadata read: no model message is sent and no reset credit is consumed.

## Reading retention

- The last successful reading of every window, balance and reset-credit count is kept together with its observation time. A failed refresh keeps it and exposes the failure; a restart restores it from `last-usage-report.json` before the first poll.
- When a window's reset time has passed, the row keeps showing the last reading and its time. A passed deadline does not mean the quota is back: a reset is confirmed only by a new reading whose reset time moved forward or that shows the window full again, and alert evaluation treats a passed deadline as pending confirmation.
- Readings older than 30 minutes stay visible but no longer generate alerts.
- A window the service stops reporting keeps its stored history while it is enabled. Kimi, GLM and OpenCode Go rows are retired — readings, cached rows and display settings — once a completed credential scan finds their credentials expired, removed or rejected; a temporary network failure retires nothing.
- A running session leaves the running indicator 120 seconds after its last source observation ("Status out of date"); the session stays in history without an invented end time.
- History for a newly connected window starts at its first observation; earlier hours are not back-filled.

## Presentation constraints

1. Desktop and CLI of the same account share one group of quota rows; model token spend is shown separately from quota windows.
2. Rows follow the windows and periods the service returns; `primary` is not assumed to mean 5 hours.
3. Clients without a per-session quota share (every client except Claude Code) show "—" in the session's share column. Tokens are never converted into quota.
4. Input excludes the cache reads already counted in the source's input total; output already includes reasoning and is not added twice.
5. A newly connected source draws only the history it has observed; a few minutes of data are never stretched into a full day.
