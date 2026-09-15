import XCTest
@testable import AgentHUDCore

final class UsageRefreshTests: XCTestCase, @unchecked Sendable {
    private actor CountingProvider: UsageProvider {
        private(set) var fetches = 0
        private(set) var hours: (fetch: [Int], account: [Int]) = ([], [])
        func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport {
            fetches += 1
            hours.fetch.append(historyHours)
            return DemoUsageProvider.report(agents: agents, historyHours: historyHours, now: Date())
        }
        func refreshAccountUsage(historyHours: Int) async { hours.account.append(historyHours) }
    }

    @MainActor
    private func store(_ provider: CountingProvider, hooks: UsageCollectionHooks) -> UsageStore {
        let suite = "UsageRefreshTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return UsageStore(provider: provider, settings: SettingsStore(defaults: defaults), hooks: hooks)
    }

    @MainActor
    func testPublishAndMergeHooksFinishInsideThePass() async throws {
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let published = expectation(description: "publish started")
        var publishes: [UsageReport] = [], merges: [UsageReport] = []
        let provider = CountingProvider()
        let store = store(provider, hooks: UsageCollectionHooks(publish: { report in
            publishes.append(report)
            if publishes.count == 1 { published.fulfill(); for await _ in gate.stream { break } }
        }, merge: { report in
            merges.append(report)
            return UsageReport(generatedAt: report.generatedAt, snapshots: report.snapshots, sessions: report.sessions,
                               activity: .empty, insights: .empty, notice: "merged", discoveredAgents: report.discoveredAgents)
        }))
        let pass = Task { @MainActor in await store.refresh() }
        await fulfillment(of: [published], timeout: 2)
        await store.refresh()
        await store.remerge()
        let during = await provider.fetches
        XCTAssertEqual(during, 1, "a refresh while the publish hook runs waits for the next pass")
        XCTAssertTrue(merges.isEmpty, "a remerge requested during the pass is served by the pass's own merge")
        XCTAssertNil(store.report, "nothing is displayed before the hooks return")
        gate.continuation.finish()
        await pass.value
        XCTAssertEqual(merges.count, 1)
        XCTAssertNil(merges[0].notice, "the merge hook receives the provider's report")
        XCTAssertEqual(store.report?.notice, "merged")
        await store.refresh()
        let after = await provider.fetches
        XCTAssertEqual(after, 2)
        XCTAssertEqual(publishes.count, 2)
    }

    @MainActor
    func testRemergeRunsOnlyTheMergeHookOnTheLastProviderReport() async throws {
        var label = "first", publishes = 0
        let provider = CountingProvider()
        let store = store(provider, hooks: UsageCollectionHooks(publish: { _ in publishes += 1 }, merge: { report in
            UsageReport(generatedAt: report.generatedAt, snapshots: [], sessions: [], activity: .empty, insights: .empty,
                        notice: (report.notice ?? "") + label)
        }))
        await store.remerge()
        XCTAssertNil(store.report, "no provider report yet")
        await store.refresh()
        label = "second"
        await store.remerge()
        let fetches = await provider.fetches
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(store.report?.notice, "second", "the merge starts again from the provider's report")
        store.replace(report: UsageReport(generatedAt: Date(), snapshots: [], sessions: [], activity: .empty, insights: .empty))
        await store.remerge()
        XCTAssertNil(store.report?.notice, "an installed report is not merged over")
    }

    @MainActor
    func testHostChoosesTheHistoryWindow() async throws {
        var hours = 24
        let provider = CountingProvider()
        let store = store(provider, hooks: UsageCollectionHooks(historyHours: { hours }))
        await store.refresh()
        hours = 721
        await store.refresh()
        let asked = await provider.hours
        XCTAssertEqual(asked.fetch, [24, 721])
        XCTAssertEqual(asked.account, [24], "the account step runs in the first pass")
        XCTAssertEqual(UsageCollectionHooks().historyHours(), UsageStore.historyHours)
    }

    @MainActor
    func testAccountRequestNeverOverlapsLocalReadsOrRepeats() async throws {
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let started = expectation(description: "account request started")
        started.assertForOverFulfill = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codex = CodexUsageProvider(readLimits: {
            started.fulfill()
            for await _ in gate.stream { break }
            throw UsageProviderError("account offline")
        }, transcripts: CodexTranscriptStore(roots: [directory]), history: QuotaHistoryStore())
        let local = CountingProvider()
        let combined = CombinedUsageProvider([.init("Codex", codex), .init("Local", local)])
        let suite = "UsageRefreshTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(provider: RetainedUsageProvider(provider: combined), settings: SettingsStore(defaults: defaults))
        defer { store.stop() }
        let pass = Task { @MainActor in await store.refresh() }
        await fulfillment(of: [started], timeout: 2)
        let before = await local.fetches
        XCTAssertEqual(before, 1, "the pass reads local logs before its account step")
        await store.refresh()
        let during = await local.fetches
        XCTAssertEqual(during, before, "a refresh requested during the account step waits for the next pass")
        gate.continuation.finish()
        await pass.value
        await store.refresh()
        let after = await local.fetches
        XCTAssertEqual(after, before + 1)
        XCTAssertFalse(store.sessions.isEmpty)
    }

    func testPollsWaitForChangesWhileNoTurnRuns() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), ms = Int64(1_800_000_000_000)
        func report(sessions: [LiveSession] = [], turns: [SessionTurn] = []) -> UsageReport {
            UsageReport(generatedAt: now, snapshots: [], sessions: sessions, activity: .empty, insights: .empty, turns: turns)
        }
        func turn(_ state: SessionTurn.State, observedAgo seconds: Int64) -> SessionTurn {
            SessionTurn(provider: "codex", sessionID: "s", turnID: "t", state: state, startedAtMs: ms - 900_000, observedAtMs: ms - seconds * 1000)
        }
        let finished = LiveSession(id: "s", agentId: "codex-model:gpt", task: "Task", terminal: nil, startedAt: now.addingTimeInterval(-600),
                                   endedAt: now.addingTimeInterval(-300), pctOfWindow: nil, tokensIn: 1, tokensOut: 1)
        let running = LiveSession(id: "s", agentId: "codex-model:gpt", task: "Task", terminal: nil, startedAt: now.addingTimeInterval(-600),
                                  pctOfWindow: nil, tokensIn: 1, tokensOut: 1, observedAt: now)
        XCTAssertFalse(report(sessions: [finished], turns: [turn(.completed, observedAgo: 30)]).hasActiveWork(at: now))
        XCTAssertTrue(report(sessions: [running]).hasActiveWork(at: now))
        XCTAssertTrue(report(turns: [turn(.running, observedAgo: 60)]).hasActiveWork(at: now), "a quiet tool call keeps polling")
        XCTAssertFalse(report(turns: [turn(.running, observedAgo: 600)]).hasActiveWork(at: now), "an abandoned turn stops polling")
    }

    func testWatchedDirectoryReportsEachChangeOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("sessions")
        let monitor = FileChangeMonitor(directories: [directory, missing])
        XCTAssertTrue(monitor.consumeChanges(), "a new monitor has not seen the directories before")
        XCTAssertFalse(monitor.consumeChanges())
        try Data("{}\n".utf8).write(to: directory.appendingPathComponent("session.jsonl"))
        var changed = false
        for _ in 0..<50 where !changed {
            try await Task.sleep(for: .milliseconds(100))
            changed = monitor.consumeChanges()
        }
        XCTAssertTrue(changed)
        XCTAssertFalse(monitor.consumeChanges())
    }

    func testAccountResultAppearsOnNextLocalPollWithItsObservationTime() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let started = expectation(description: "quota started")
        let provider = AdditionalUsageProvider(source: .grok, readQuota: {
            started.fulfill()
            for await _ in gate.stream { break }
            return ProviderQuota(windows: [.init(id: "grok", label: "Credits", remaining: 80)])
        }, readSessions: { _ in .init() }, history: QuotaHistoryStore(), clock: { now })
        let request = Task { await provider.refreshAccountUsage(historyHours: 24) }
        await fulfillment(of: [started], timeout: 2)
        let local = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertTrue(local.snapshots.isEmpty)
        gate.continuation.finish()
        await request.value
        let updated = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(updated.snapshots.first?.remainingPct, 80)
        XCTAssertEqual(updated.snapshots.first?.updatedAt, now)
    }

    func testRemoteSessionStatisticsDoNotBlockLocalHooks() async throws {
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let started = expectation(description: "remote session request started")
        let completion = SessionCompletion(sessionID: "cursor:s", vendor: "Cursor", turnID: "t",
            task: "Task", model: "model", startedAt: nil, completedAt: Date())
        let provider = AdditionalUsageProvider(source: .cursor, readQuota: { ProviderQuota() },
            readSessions: { _ in ProviderSessions() }, history: QuotaHistoryStore(),
            readCompletions: { _ in [completion] }, refreshSessions: { hours in
                XCTAssertEqual(hours, 169)
                started.fulfill()
                for await _ in gate.stream { break }
            })
        let request = Task { await provider.refreshAccountUsage(historyHours: 169) }
        await fulfillment(of: [started], timeout: 2)
        let local = try await provider.fetchUsage(agents: [], historyHours: 169)
        XCTAssertEqual(local.completions, [completion])
        gate.continuation.finish()
        await request.value
    }

    func testQuotaKeyChangeRefreshesBeforeTheInterval() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        final class State: @unchecked Sendable { var consented = false; var reads = 0 }
        let state = State(), history = QuotaHistoryStore()
        let provider = AdditionalUsageProvider(source: .copilot, readQuota: {
            state.reads += 1
            return state.consented ? ProviderQuota(windows: [.init(id: "copilot:chat", label: "Chat", remaining: 40)]) : ProviderQuota(forgetAccounts: true)
        }, readSessions: { _ in .init() }, history: history, clock: { now }, quotaKey: { String(state.consented) })
        await provider.refreshAccountUsage(historyHours: 24)
        await provider.refreshAccountUsage(historyHours: 24)
        XCTAssertEqual(state.reads, 1)
        state.consented = true
        await provider.refreshAccountUsage(historyHours: 24)
        XCTAssertEqual(state.reads, 2)
        let report = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(report.snapshots.first?.remainingPct, 40)
        XCTAssertNil(report.forgottenAccountProviders)
        let recorded = await history.count
        XCTAssertEqual(recorded, 1)
        state.consented = false
        await provider.refreshAccountUsage(historyHours: 24)
        let withdrawn = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertTrue(withdrawn.snapshots.isEmpty)
        XCTAssertEqual(withdrawn.forgottenAccountProviders, ["GitHub Copilot"])
        let cleared = await history.count
        XCTAssertEqual(cleared, 0, "withdrawn consent deletes the quota history")
    }

    func testStopHookFinishesTheRunningTurnItFollows() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), ms = Int64(1_800_000_000_000)
        var session = ProviderSession(id: "copilot:s", title: "Task", client: "Copilot CLI", startedAt: now.addingTimeInterval(-30), lastActivity: now.addingTimeInterval(-10))
        session.turns = [SessionTurn(provider: "GitHub Copilot", sessionID: "copilot:s", turnID: "t", state: .running, startedAtMs: ms - 30_000, observedAtMs: ms - 10_000)]
        let local = ProviderSessions(sessions: [session])
        func report(completedAt: Date?) async throws -> UsageReport {
            let hooks = completedAt.map { [SessionCompletion(sessionID: "copilot:s", vendor: "GitHub Copilot", turnID: "stop", task: "Task", model: "m", startedAt: nil, completedAt: $0)] } ?? []
            return try await AdditionalUsageProvider(source: .copilot, readQuota: { ProviderQuota() }, readSessions: { _ in local },
                history: QuotaHistoryStore(), readCompletions: { _ in hooks }, clock: { now }).fetchUsage(agents: [], historyHours: 24)
        }
        let running = try await report(completedAt: nil)
        XCTAssertEqual(running.turns.first?.state, .running)
        XCTAssertNil(running.sessions.first?.endedAt)
        let earlier = try await report(completedAt: now.addingTimeInterval(-20))
        XCTAssertEqual(earlier.turns.first?.state, .running, "A completion before the turn's latest activity belongs to an earlier turn")
        let finished = try await report(completedAt: now.addingTimeInterval(-5))
        XCTAssertEqual(finished.turns.first?.state, .completed)
        XCTAssertEqual(finished.turns.first?.observedAtMs, ms - 5_000)
        XCTAssertNotNil(finished.sessions.first?.endedAt)
    }
}
