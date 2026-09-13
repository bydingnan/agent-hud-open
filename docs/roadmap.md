# Roadmap

Updated 2026-09-13. What is being built, what comes next, and what is not scheduled.

## Now

- Grid glow styles for the notch — halftone dots, ASCII characters, shade blocks, Braille and binary digits — with breathe, flow, scan, ripple, shimmer and boot effects, animated only while an agent is running.
- Quota exhaustion as its own alert: a window that reaches zero notifies once, even after the earlier at-risk warning (`QuotaAlertTracker.Update.exhaustedAgentIDs`).

## Next

- Running and terminal turn evidence for Cursor, Antigravity and OpenCode. Their providers supply usage observations only; Cursor and Antigravity finish turns through [completion hooks](session-lifecycle.md#completion-hooks), and OpenCode's persisted messages carry no lifecycle signal.
- Keep `CFBundleShortVersionString` in `scripts/build-app.sh` equal to the release tag, checked before tagging.
- A CI step that fails when `THIRD_PARTY_NOTICES.txt` and `Sources/AgentHUDDesktop/Resources/THIRD_PARTY_NOTICES.txt` differ, and that checks the notices file is present in the built bundle.

## Later

Not scheduled.

- ChatGPT chat quota; the first-launch screen lists it as not available yet.
- Grok team accounts; the credits proxy does not report their quota.
- VS Code and GitHub Copilot.

## Delivered

Released versions and their host-visible API changes are recorded in the [changelog](../CHANGELOG.md).

## Invariants

The acceptance criteria every change must keep — integer precision, deterministic record identities, millisecond date round-trips, tests without credentials or network, isolated sources, no invented lifecycle, bundled notices, source boundaries — are listed under [architecture → Design invariants](architecture.md#design-invariants).
