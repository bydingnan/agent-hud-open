import XCTest
@testable import AgentHUDCore

final class UsageLedgerTests: XCTestCase, @unchecked Sendable {
    private let base = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 900))

    private func event(_ key: String, minute: Double, agent: String = "claude-model:opus", input: Int, output: Int = 0,
                       cache: Int = 0, costs: [String: Decimal]? = nil) -> UsageLedger.Event {
        UsageLedger.Event(key: key, timestamp: base.addingTimeInterval(minute * 60), agentId: agent, tokensIn: input, tokensOut: output,
                          cacheReadTokens: cache, billingID: costs == nil ? nil : "DeepSeek", costs: costs)
    }

    func testCorrectionsAndRepeatsKeepBucketsExact() async throws {
        let ledger = UsageLedger.inMemory(), now = base.addingTimeInterval(3600)
        try await ledger.write { try $0.upsert(source: "claude", contribution: "a.jsonl", events: [
            self.event("m1", minute: 1, input: 100, output: 10), self.event("m2", minute: 16, input: 50, cache: 7),
        ]) }
        try await ledger.write { try $0.upsert(source: "claude", contribution: "a.jsonl", events: [self.event("m1", minute: 1, input: 100, output: 10)]) }
        var buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.map(\.tokensIn), [100, 50], "a repeated event counts once")
        XCTAssertEqual(buckets.map(\.start), [base, base.addingTimeInterval(900)])
        // A later line corrects an earlier attempt and can move it into another period.
        try await ledger.write { try $0.upsert(source: "claude", contribution: "a.jsonl", events: [self.event("m1", minute: 20, input: 120, output: 12)]) }
        buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.tokensIn, 170)
        XCTAssertEqual(buckets.first?.tokensOut, 12)
        XCTAssertEqual(buckets.first?.cacheReadTokens, 7)
        let tokens = try await ledger.tokens(source: "claude", since: base.addingTimeInterval(18 * 60))
        XCTAssertEqual(tokens, ["a.jsonl": 132])
        _ = now
    }

    func testReplacingAContributionOnlyWritesChanges() async throws {
        let ledger = UsageLedger.inMemory()
        let first = [event("e1", minute: 2, agent: "copilot-model:gpt", input: 10), event("e2", minute: 3, agent: "copilot-model:gpt", input: 5)]
        try await ledger.write { try $0.replace(source: "copilot", contribution: "s", events: first) }
        let revision = await ledger.bucketRevision
        try await ledger.write { try $0.replace(source: "copilot", contribution: "s", events: first.reversed()) }
        let unchanged = await ledger.bucketRevision
        XCTAssertEqual(unchanged, revision, "an identical contribution is not rewritten")
        try await ledger.write { try $0.replace(source: "copilot", contribution: "s", events: [self.event("e1", minute: 2, agent: "copilot-model:gpt", input: 12)]) }
        let replaced = try await ledger.buckets(since: base)
        XCTAssertEqual(replaced.map(\.tokensIn), [12])
        try await ledger.write { try $0.remove(source: "copilot", contribution: "s") }
        let removed = try await ledger.buckets(since: base)
        XCTAssertTrue(removed.isEmpty)
        let keys = try await ledger.write { try $0.contributions(source: "copilot") }
        XCTAssertTrue(keys.isEmpty)
    }

    func testUncountedCopiesStayOutOfBuckets() async throws {
        let ledger = UsageLedger.inMemory()
        try await ledger.write { writer in
            try writer.upsert(source: "codex", contribution: "sessions/a.jsonl", events: [self.event("u1", minute: 1, agent: "codex-model:gpt", input: 10)])
            try writer.upsert(source: "codex", contribution: "archived/a.jsonl", counted: false,
                              events: [self.event("u1", minute: 1, agent: "codex-model:gpt", input: 10)])
        }
        var buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.map(\.tokensIn), [10], "only the counted copy of a moved log adds up")
        try await ledger.write { writer in
            try writer.setCounted(source: "codex", contribution: "sessions/a.jsonl", counted: false)
            try writer.setCounted(source: "codex", contribution: "archived/a.jsonl", counted: true)
            try writer.upsert(source: "codex", contribution: "archived/a.jsonl", events: [self.event("u2", minute: 2, agent: "codex-model:gpt", input: 5)])
        }
        buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.map(\.tokensIn), [15])
        try await ledger.write { try $0.remove(source: "codex", contribution: "sessions/a.jsonl") }
        buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.map(\.tokensIn), [15], "removing the uncounted copy changes nothing")
    }

    func testWindowedReplacementKeepsOlderEvents() async throws {
        let ledger = UsageLedger.inMemory(), since = base.addingTimeInterval(3600)
        try await ledger.write { try $0.replace(source: "hermes", contribution: "s", events: [
            self.event("old", minute: 10, agent: "hermes-model:m", input: 7), self.event("new", minute: 70, agent: "hermes-model:m", input: 5),
        ]) }
        // A reader whose window starts at `since` no longer returns the older event, and corrects the newer one.
        try await ledger.write { try $0.replace(source: "hermes", contribution: "s", events: [
            self.event("new", minute: 70, agent: "hermes-model:m", input: 6),
        ], since: since) }
        let buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.map(\.tokensIn), [7, 6])
    }

    func testAccountImportsKeepTheirOwnBuckets() async throws {
        let ledger = UsageLedger.inMemory()
        try await ledger.write { writer in
            try writer.replace(source: "cursor", contribution: "conversation", account: "account:abc",
                               events: [self.event("c1", minute: 1, agent: "cursor-model:auto", input: 30)])
            try writer.upsert(source: "claude", contribution: "b.jsonl", events: [self.event("m", minute: 2, agent: "cursor-model:auto", input: 4)])
        }
        let buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.map(\.account), [nil, "account:abc"])
        XCTAssertEqual(buckets.map(\.tokensIn), [4, 30])
    }

    func testCostsStayUnknownWhereAnEventHadNoPrice() async throws {
        let ledger = UsageLedger.inMemory()
        try await ledger.write { try $0.upsert(source: "deepseek", contribution: "s1", events: [
            self.event("r1", minute: 1, agent: "deepseek-model:flash", input: 1000, costs: ["CNY": Decimal(string: "0.0015")!, "USD": Decimal(string: "0.00022")!]),
            self.event("r2", minute: 2, agent: "deepseek-model:flash", input: 2000, costs: ["CNY": Decimal(string: "0.003")!]),
            self.event("r3", minute: 20, agent: "deepseek-model:flash", input: 10, costs: ["CNY": Decimal(string: "0.000015")!]),
        ]) }
        let costs = try await ledger.costBuckets(since: base)
        XCTAssertEqual(costs["DeepSeek"]?.map(\.amounts), [["CNY": Decimal(string: "0.0045")!], ["CNY": Decimal(string: "0.000015")!]],
                       "USD is missing where one event had no USD price")
        let sessions = try await ledger.contributionCosts(source: "deepseek")
        XCTAssertEqual(sessions["s1"], ["CNY": Decimal(string: "0.004515")!])
        try await ledger.write { try $0.upsert(source: "deepseek", contribution: "s1", events: [
            self.event("r2", minute: 2, agent: "deepseek-model:flash", input: 2000, costs: ["CNY": Decimal(string: "0.003")!, "USD": Decimal(string: "0.00044")!]),
        ]) }
        let corrected = try await ledger.costBuckets(since: base)
        XCTAssertEqual(corrected["DeepSeek"]?.first?.amounts["USD"], Decimal(string: "0.00066")!)
    }

    func testFailedPassRollsBackAndSignalsProviders() async throws {
        let ledger = UsageLedger.inMemory()
        await ledger.beginPass()
        try await ledger.write { try $0.setFile(source: "claude", path: "/a.jsonl", state: .init(signature: "1:2", state: Data("{}".utf8))) }
        do {
            try await ledger.write { writer -> Void in
                try writer.upsert(source: "claude", contribution: "/a.jsonl", events: [self.event("m", minute: 1, input: 1)])
                throw UsageProviderError("parse failed")
            }
            XCTFail("the write should throw")
        } catch {}
        await ledger.commitPass()
        let files = try await ledger.fileStates(source: "claude")
        XCTAssertEqual(files["/a.jsonl"]?.signature, "1:2", "writes before a failed provider still commit")
        let buckets = try await ledger.buckets(since: base)
        XCTAssertTrue(buckets.isEmpty, "the failed provider's writes roll back to its savepoint")
    }

    func testExpiryDeletesWholeBucketsAndPersistsAcrossLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.sqlite")
        let now = Date()
        let old = now.addingTimeInterval(-UsageLedger.retention - 3600), recent = now.addingTimeInterval(-3600)
        do {
            let ledger = try UsageLedger(url: url, expires: true)
            try await ledger.write { writer in
                try writer.upsert(source: "codex", contribution: "s", events: [
                    UsageLedger.Event(key: "old", timestamp: old, agentId: "codex-model:gpt", tokensIn: 5, tokensOut: 1),
                    UsageLedger.Event(key: "new", timestamp: recent, agentId: "codex-model:gpt", tokensIn: 7, tokensOut: 2),
                ])
                try writer.appendSamples([QuotaSample(agentId: "codex", timestamp: recent, remainingPct: 40)], scope: "codex")
            }
            try await ledger.expire(now: now)
        }
        let reopened = try UsageLedger(url: url)
        let buckets = try await reopened.buckets(since: .distantPast)
        XCTAssertEqual(buckets.map(\.tokensIn), [7])
        let samples = try await reopened.samples(scope: "codex", windowID: "codex", since: .distantPast)
        XCTAssertEqual(samples.map(\.remainingPct), [40])
    }
}
