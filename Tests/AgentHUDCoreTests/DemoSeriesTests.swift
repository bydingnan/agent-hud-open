import XCTest
@testable import AgentHUDCore

final class SeededRandomTests: XCTestCase {
    func testMatchesPrototypeLCG() {
        var r = SeededRandom(seed: 11)
        XCTAssertEqual(r.next(), 0.6498971193415638, accuracy: 1e-12)
        XCTAssertEqual(r.next(), 0.9044281550068587, accuracy: 1e-12)
        XCTAssertEqual(r.next(), 0.297590877914952, accuracy: 1e-12)
    }

    func testIsDeterministic() {
        var a = SeededRandom(seed: 5), b = SeededRandom(seed: 5)
        for _ in 0..<50 { XCTAssertEqual(a.next(), b.next()) }
    }
}

final class DemoSeriesTests: XCTestCase {
    func testHourlyTokensShapeAndScale() {
        let t = DemoSeries.hourlyTokens(agentCount: 4, hours: 48)
        XCTAssertEqual(t.count, 48)
        XCTAssertEqual(t[0].count, 4)
        XCTAssertLessThanOrEqual(t.flatMap { $0 }.max() ?? 0, 40)
        XCTAssertGreaterThan(t.flatMap { $0 }.reduce(0, +), 0)
    }

    func testActivityGridIsSevenByTwentyFour() {
        let grid = DemoSeries.activity()
        XCTAssertEqual(grid.rows.count, 7)
        XCTAssertTrue(grid.rows.allSatisfy { $0.count == 24 })
        XCTAssertTrue(grid.rows.flatMap { $0 }.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertEqual(grid.rows.flatMap { $0 }.max() ?? 0, 1, accuracy: 1e-9)
    }
}

final class DemoUsageProviderTests: XCTestCase {
    func testReportCoversEnabledAgentsAndHours() async throws {
        let report = try await DemoUsageProvider().fetchUsage(agents: DemoData.agents, historyHours: 48)
        XCTAssertEqual(report.snapshots.count, DemoData.agents.count)
        XCTAssertEqual(report.sessions.filter(\.isLive).count, 2)
        XCTAssertEqual(report.snapshot(for: "codex")?.remainingPct, 7)
    }

    func testDifferentRangesProduceDifferentLengths() async throws {
        let short = try await DemoUsageProvider().fetchUsage(agents: DemoData.agents, historyHours: 48)
        let long = try await DemoUsageProvider().fetchUsage(agents: DemoData.agents, historyHours: 168)
        func earliest(_ report: UsageReport) -> Date? { report.usage.filter { $0.agentId == "codex" }.map(\.start).min() }
        XCTAssertLessThan(try XCTUnwrap(earliest(long)), try XCTUnwrap(earliest(short)))
    }
}
