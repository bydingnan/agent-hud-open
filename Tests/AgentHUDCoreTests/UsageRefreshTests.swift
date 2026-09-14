import XCTest
@testable import AgentHUDCore

final class UsageRefreshTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testSlowAccountQueryDoesNotBlockLocalRefreshOrStartDuplicateQueries() async throws {
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let started = expectation(description: "account request started")
        started.assertForOverFulfill = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codex = CodexUsageProvider(readLimits: {
            started.fulfill()
            for await _ in gate.stream { break }
            throw UsageProviderError("account offline")
        }, transcripts: CodexTranscriptStore(roots: [directory]), history: QuotaHistoryStore(fileURL: nil))
        let combined = CombinedUsageProvider([.init("Codex", codex), .init("Local", DemoUsageProvider())])
        let suite = "UsageRefreshTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(provider: RetainedUsageProvider(provider: combined), settings: SettingsStore(defaults: defaults))
        defer { store.stop() }
        let local = expectation(description: "two local polls finish while account query is pending")
        let refresh = Task { @MainActor in
            await store.refresh()
            await store.refresh()
            local.fulfill()
        }
        await fulfillment(of: [started, local], timeout: 2)
        gate.continuation.finish()
        await refresh.value
        XCTAssertFalse(store.sessions.isEmpty)
        XCTAssertTrue(store.hasLiveSession)
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
        }, readSessions: { _ in .init() }, history: QuotaHistoryStore(fileURL: nil), clock: { now })
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
            readSessions: { _ in ProviderSessions() }, history: QuotaHistoryStore(fileURL: nil),
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
        let state = State(), history = QuotaHistoryStore(fileURL: nil)
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
                history: QuotaHistoryStore(fileURL: nil), readCompletions: { _ in hooks }, clock: { now }).fetchUsage(agents: [], historyHours: 24)
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
