# Roadmap

## Overview

What is being built, what comes next, and what is not scheduled. Released versions and their host-visible API changes are recorded in the [changelog](../CHANGELOG.md); the acceptance criteria every change must keep are listed under [architecture → Design invariants](architecture.md#design-invariants).

## Now

- Grid glow styles for the notch — halftone dots, ASCII characters, shade blocks, Braille and binary digits — with breathe, flow, scan, ripple, shimmer and boot effects, animated only while an agent is running.
- Quota exhaustion as its own alert: a window that reaches zero notifies once, even after the earlier at-risk warning.

## Next

- Running and terminal turn evidence for Antigravity and OpenCode. Cursor now has a local lifecycle inbox via `CursorLifecycleObserver` + `~/.cursor/hooks/cursor-lifecycle.sh`; Antigravity still finishes through [completion hooks](session-lifecycle.md#completion-hooks), and OpenCode's persisted messages carry no lifecycle signal.
- Keep the bundle's `CFBundleShortVersionString` equal to the release tag, checked before tagging.
- A CI step that fails when the root `THIRD_PARTY_NOTICES.txt` and the bundled copy differ, and that checks the notices file is present in the built bundle.

## Later

Not scheduled.

- ChatGPT chat quota.
- Grok team accounts; the credits proxy does not report their quota.
- VS Code and GitHub Copilot.
