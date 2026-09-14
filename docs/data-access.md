# Data access

## Overview

Agent HUD Open reads agent activity and usage metadata on your Mac. It has no Agent HUD account, cloud synchronization or push service. Building it requires no developer account, product credential, provisioning profile or signing certificate; local builds use ad-hoc signing.

## Providers

| Client | Local data | Quota or balance queries |
| --- | --- | --- |
| Claude Code | Session records and account profile | Installed Claude engine usage interface |
| Codex Desktop / CLI | Session records, including `CODEX_HOME` | Installed Codex app-server account rate limits |
| DeepSeek Harness | Session records and profile-owning Node process metadata, including `DSH_HOME` | Official DeepSeek balance endpoint with the configured Harness API key |
| Antigravity | Local application process and conversation metadata | Running application's local language server |
| Cursor | Local application database and session metadata | Official Cursor usage endpoints with the installed client's session token |
| Grok CLI | Local session records and credential file | Official Grok CLI billing endpoint |
| OpenCode, Kimi, GLM, Pi | Local JSON/SQLite session records and supported provider configuration; automatically prepared Pi lifecycle observer | Official Kimi, GLM, and OpenCode Go quota endpoints where configured |

Per-client fields, endpoints and caches: [providers](providers.md). Token counts, percentages, alert levels, request intervals and reading retention: [usage semantics](usage-semantics.md).

## Credentials

- A provider that needs a key or token reads it from the client's own configuration, environment variables or local credential files, uses it only for that provider's usage request, and never includes it in reports or caches.
- Claude and Codex quota queries use the installed clients' existing sign-in; Codex `auth.json` is not read. No request sends a model message or consumes a usage-reset credit.
- Account identity comes only from data a provider already reads or a response it already requests: the Claude profile, Codex `account/read`, Cursor's local database, the Grok login record and Antigravity's local server. Provider user and workspace ids are stored as hashes; the account's email or name is kept locally to label its rows.
- Custom endpoints are not assumed to share official billing accounts, and executable key resolvers are never run.
- Kimi account identity is confirmed through the official profile endpoint, separately for each deployment; only hashed credential-to-account associations are cached, and accounts are never merged from matching quota values, reset times or unverified token claims.
- DeepSeek process inspection reads executable identity and start time only, not profile contents or browser credentials.

## Local storage

- Preferences use the application's UserDefaults domain; cached reports, quota observations and session indexes live in `~/Library/Application Support/Agent HUD Open`. Local metadata can include session titles and workspace paths; raw conversation bodies and authentication secrets are never copied into these caches.
- Quota, balance and account-wide usage requests run separately from local activity polling with their own request intervals; a missing or signed-out client does not prevent other sources from reporting.
- Saved readings appear immediately after a restart with their original observation times; a failed refresh keeps them and reports the failure. Unavailable quotas are never inferred from token counts.
- Readings of an account a client is no longer signed in to stay until the account has not been seen for 30 days.
- A completed credential scan retires expired, removed or rejected OpenCode Go, Kimi and GLM quota rows, including cached rows and saved display settings.
- Optional completion hooks write one small local record per finished turn (session and turn identity, model, workspace folder name and time) and nothing else; they send no notifications and upload nothing ([completion hooks](session-lifecycle.md#completion-hooks)).

## Related

[providers.md](providers.md) per-client details · [usage-semantics.md](usage-semantics.md) counting and retention · [session-lifecycle.md](session-lifecycle.md) turn evidence · [../THIRD_PARTY_NOTICES.txt](../THIRD_PARTY_NOTICES.txt) provider protocol references and licenses
