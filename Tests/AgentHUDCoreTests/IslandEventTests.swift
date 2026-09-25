import XCTest
@testable import AgentHUDCore

final class IslandEventTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_788_850_000)
    private let visibleAgents = [
        AgentDescriptor(id: "codex", vendor: "Codex", model: "5h", source: "", enabled: true),
        AgentDescriptor(id: "deepseek", vendor: "DeepSeek", model: "API", source: "", enabled: true),
    ]

    func testPollingKeepsFastTurnsDeduplicatesAndDoesNotReplayAtStartupOrAfterToggle() {
        var tracker = IslandEventTracker(startedAt: start)
        let old = completion("old", at: start.addingTimeInterval(-1))
        let one = completion("one", at: start.addingTimeInterval(1)), two = completion("two", at: start.addingTimeInterval(2))
        let now = start.addingTimeInterval(3)
        let update = tracker.update(report: report(completions: [old, one, two, one]), agents: visibleAgents, now: now)
        XCTAssertEqual(update.completions.map(\.id), [one.id, two.id])
        XCTAssertTrue(tracker.update(report: report(completions: [one, two]), agents: visibleAgents, now: now).completions.isEmpty)
        let three = completion("three", at: now)
        XCTAssertEqual(tracker.update(report: report(completions: [three]), agents: [], now: now).completions.count, 1)
        XCTAssertTrue(tracker.update(report: report(completions: [three]), agents: visibleAgents, now: now).completions.isEmpty)
        var restarted = IslandEventTracker(startedAt: now.addingTimeInterval(1))
        XCTAssertTrue(restarted.update(report: report(completions: [old, one, two, three]), agents: visibleAgents,
                                       now: now.addingTimeInterval(2)).completions.isEmpty)
    }

    func testSuppressedCompletionsDoNotReplayWhenLiveStatusIsEnabled() {
        let now = start.addingTimeInterval(60)
        for disabled in SessionSource.agentVendors {
            var tracker = IslandEventTracker(startedAt: start)
            let settings = Settings().with { $0.setLiveStatus(for: disabled, enabled: false) }
            let completed = report(completions: SessionSource.agentVendors.map { completion("one", vendor: $0, at: now) }, at: now)
            let update = tracker.update(report: completed, agents: [], now: now, settings: settings)
            XCTAssertEqual(update.completions.count, SessionSource.agentVendors.count - 1)
            XCTAssertFalse(update.completions.contains { $0.vendor == disabled })
            XCTAssertTrue(tracker.update(report: completed, agents: [], now: now).completions.isEmpty)
            // The next successful turn has a distinct identity.
            let next = completion("two", vendor: disabled, at: now.addingTimeInterval(1))
            XCTAssertEqual(tracker.update(report: report(completions: [next], at: next.completedAt), agents: [], now: next.completedAt).completions, [next])
        }
    }

    func testHiddenAndWindowlessAgentsReceiveCompletionsWithoutReplay() {
        var tracker = IslandEventTracker(startedAt: start)
        var agents = [AgentDescriptor(id: "codex", vendor: "Codex", model: "5h", source: "", enabled: false),
                      AgentDescriptor(id: "claude", vendor: "Claude", model: "5h", source: "", enabled: true)]
        func update(_ events: [SessionCompletion], _ seconds: Double) -> IslandEventTracker.Update {
            let now = start.addingTimeInterval(seconds)
            return tracker.update(report: report(completions: events, at: now), agents: agents, now: now)
        }
        let old = completion("1", vendor: "Codex", at: start.addingTimeInterval(1))
        let other = completion("2", vendor: "Claude", at: start.addingTimeInterval(2))
        let windowless = completion("2.5", vendor: "Pi", at: start.addingTimeInterval(2.5))
        XCTAssertEqual(update([old, other, windowless], 3).completions.map(\.vendor), ["Codex", "Claude", "Pi"])
        agents = agents.map { $0.with(enabled: true) }
        let fresh = completion("4", vendor: "Codex", at: start.addingTimeInterval(4))
        XCTAssertEqual(update([old, other, fresh], 5).completions.map(\.id), [fresh.id])
    }

    func testResetAndCriticalEventsShareTheQuotaBaseline() {
        var tracker = IslandEventTracker(startedAt: start)
        let agent = AgentDescriptor(id: "codex", vendor: "Codex", model: "5h", source: "", enabled: true)
        func update(_ remaining: Double, _ seconds: Double, deadline: Double = 1000) -> IslandEventTracker.Update {
            let now = start.addingTimeInterval(seconds)
            return tracker.update(report: report(snapshots: [reading(agent, remaining, at: now, deadline: deadline)], at: now),
                                  agents: [agent], now: now)
        }
        XCTAssertEqual(summary(update(50, 0)), [])
        let critical = update(5, 120)
        XCTAssertEqual(summary(critical), ["exhaustion codex", "critical codex"])
        XCTAssertEqual(critical.criticalWindows.first?.snapshot.remainingPct, 5)
        XCTAssertEqual(summary(update(5, 120)), [])
        XCTAssertEqual(summary(update(4, 1100)), [], "deadline alone does not confirm a reset")
        XCTAssertEqual(summary(update(95, 1200, deadline: 2000)), ["reset codex"])
        XCTAssertEqual(summary(update(95, 1200, deadline: 2000)), [])
    }

    func testExhaustionCrossesOnceAfterCriticalAndSupersedesCriticalWhenBothLandTogether() {
        let agent = AgentDescriptor(id: "claude-weekly", vendor: "Claude", model: "weekly", source: "", enabled: true)
        func update(_ tracker: inout IslandEventTracker, _ remaining: Double, _ seconds: Double) -> [String] {
            let now = start.addingTimeInterval(seconds)
            return summary(tracker.update(report: report(snapshots: [reading(agent, remaining, at: now, deadline: 5000)], at: now),
                                          agents: [agent], now: now))
        }
        var tracker = IslandEventTracker(startedAt: start)
        XCTAssertEqual(update(&tracker, 20, 0), [])
        XCTAssertEqual(update(&tracker, 5, 120), ["exhaustion claude-weekly", "critical claude-weekly"])
        XCTAssertEqual(update(&tracker, 0, 240), ["exhaustion claude-weekly", "exhausted claude-weekly"])
        XCTAssertEqual(update(&tracker, 0, 360), [])
        var sudden = IslandEventTracker(startedAt: start)
        XCTAssertEqual(update(&sudden, 50, 0), [])
        XCTAssertEqual(update(&sudden, 0, 120), ["exhaustion claude-weekly", "exhausted claude-weekly"],
                       "a healthy-to-empty jump is one exhaustion, not a critical crossing as well")
    }

    func testDisplayChangesDoNotAffectQuotaEvents() {
        var tracker = IslandEventTracker(startedAt: start)
        let agent = AgentDescriptor(id: "codex", vendor: "Codex", model: "5h", source: "", enabled: true)
        var agents = [agent.with(enabled: false)]
        func update(_ remaining: Double, _ seconds: Double) -> [String] {
            let now = start.addingTimeInterval(seconds)
            return summary(tracker.update(report: report(snapshots: [reading(agent, remaining, at: now, deadline: 1000)], at: now),
                                          agents: agents, now: now))
        }
        XCTAssertEqual(update(50, 0), [])
        XCTAssertEqual(update(5, 1), ["exhaustion codex", "critical codex"])
        agents = agents.map { $0.with(enabled: true) }
        XCTAssertEqual(update(5, 2), [])
        XCTAssertEqual(update(50, 3), [])
        XCTAssertEqual(update(5, 4), ["exhaustion codex", "critical codex"])
        agents[0] = agent.with(enabled: false)
        XCTAssertEqual(update(100, 5), ["reset codex"])
    }

    func testInterruptionReportsAStopOfInFlightWorkOnceAndOnlyWhenTheClientRecordedIt() {
        var tracker = IslandEventTracker(startedAt: start)
        let agents = [AgentDescriptor(id: "codex", vendor: "Codex", model: "5h", source: "", enabled: true)]
        let session = LiveSession(id: "codex:s", agentId: "codex", task: "Fix the parser", terminal: nil,
                                  startedAt: start, pctOfWindow: nil, tokensIn: 0, tokensOut: 0)
        func update(_ state: SessionTurn.State, observed seconds: Double, at now: Double) -> IslandEventTracker.Update {
            let turn = SessionTurn(provider: "codex", sessionID: "codex:s", turnID: "t", state: state,
                                   startedAtMs: 1_788_850_000_000, observedAtMs: 1_788_850_000_000 + Int64(seconds * 1000))
            return tracker.update(report: report(sessions: [session], turns: [turn], at: start.addingTimeInterval(now)),
                                  agents: agents, now: start.addingTimeInterval(now))
        }
        XCTAssertEqual(update(.running, observed: 0, at: 1).interruptions, [], "the first look establishes a baseline")
        let stopped = update(.ended, observed: 2, at: 3).interruptions
        XCTAssertEqual(stopped.map(\.vendor), ["Codex"], "the vendor is resolved the way the panel resolves a session")
        XCTAssertEqual(stopped.map(\.task), ["Fix the parser"])
        XCTAssertEqual(update(.ended, observed: 2, at: 4).interruptions, [], "one stop is one event")
        update(.running, observed: 5, at: 6)
        let again = update(.ended, observed: 7, at: 8).interruptions
        XCTAssertEqual(again.count, 1, "the next turn that stops is its own event")
        XCTAssertNotEqual(again.first?.id, stopped.first?.id)
        // A turn a quiet source parked keeps its old observation time, so it never reads as the client stopping it.
        update(.running, observed: 10, at: 11)
        XCTAssertEqual(update(.ended, observed: 10, at: 131).interruptions, [])
    }

    func testInterruptionCoversApprovalBlocksNotCompletionsAndConsumesSuppressedStops() {
        var tracker = IslandEventTracker(startedAt: start)
        let agents = [AgentDescriptor(id: "codex", vendor: "Codex", model: "5h", source: "", enabled: true)]
        func update(_ state: SessionTurn.State, at now: Double, settings: Settings = Settings()) -> IslandEventTracker.Update {
            let turn = SessionTurn(provider: "codex", sessionID: "codex:s", turnID: "t", state: state,
                                   startedAtMs: 1_788_850_000_000, observedAtMs: 1_788_850_000_000 + Int64(now * 1000))
            return tracker.update(report: report(turns: [turn], at: start.addingTimeInterval(now)),
                                  agents: agents, now: start.addingTimeInterval(now), settings: settings)
        }
        update(.waitingForApproval, at: 1)
        XCTAssertEqual(update(.ended, at: 2).interruptions.count, 1, "a blocked turn that stops was interrupted")
        update(.running, at: 3)
        XCTAssertEqual(update(.completed, at: 4).interruptions, [], "a completion is the completion event, not an interruption")
        let suppressed = Settings().with { $0.setLiveStatus(for: "Codex", enabled: false) }
        update(.running, at: 5, settings: suppressed)
        XCTAssertEqual(update(.ended, at: 6, settings: suppressed).interruptions, [])
        XCTAssertEqual(update(.ended, at: 7).interruptions, [], "a suppressed stop is consumed, never replayed")
    }

    private func completion(_ turn: String, vendor: String = "Codex", at: Date) -> SessionCompletion {
        SessionCompletion(sessionID: vendor, vendor: vendor, turnID: turn, task: "Task", model: "Model", startedAt: nil, completedAt: at)
    }

    private func reading(_ agent: AgentDescriptor, _ remaining: Double, at: Date, deadline: Double) -> UsageSnapshot {
        UsageSnapshot(agentId: agent.id, remainingPct: remaining, resetAt: start.addingTimeInterval(deadline), updatedAt: at)
    }

    private func report(completions: [SessionCompletion] = [], snapshots: [UsageSnapshot] = [], sessions: [LiveSession] = [],
                        turns: [SessionTurn] = [], at: Date? = nil) -> UsageReport {
        UsageReport(generatedAt: at ?? start, snapshots: snapshots, sessions: sessions,
                    completions: completions, turns: turns)
    }

    /// Island alerts by kind, then threshold crossings, each with the window id.
    private func summary(_ update: IslandEventTracker.Update) -> [String] {
        update.quotaAlerts.map { "\($0.kind.rawValue) \($0.agent.id)" }
            + update.exhaustedWindows.map { "exhausted \($0.agent.id)" }
            + update.criticalWindows.map { "critical \($0.agent.id)" }
    }
}
