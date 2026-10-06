import XCTest
@testable import AgentHUDCore

final class OpenCodeSessionObserverTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCodeObserverTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func observation(_ state: SessionTurn.State) -> OpenCodeSessionObserver.Observation {
        .init(version: 1, sessionID: "opencode:session", workspace: "/workspace", title: "OpenCode task",
              model: "gpt", providerID: "openai", turnID: "turn", state: state,
              startedAtMs: Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1000),
              observedAtMs: Int64(now.timeIntervalSince1970 * 1000), message: "done")
    }

    func testSnapshotMergesWithOpenCodeUsageSession() async throws {
        let home = try temporaryHome()
        let dataRoot = home.appendingPathComponent("data")
        let paths = OpenAgentPaths(home: home, environment: ["XDG_DATA_HOME": dataRoot.path])
        let file = paths.openCodeTurns.appendingPathComponent("turn.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(observation(.running)).write(to: file, options: .atomic)

        let local = await OpenAgentLocalStore(paths: paths).index(since: now.addingTimeInterval(-86400))
        let session = try XCTUnwrap(local.sessions.first)
        XCTAssertEqual(session.id, "opencode:session")
        XCTAssertEqual(session.client, .opencode)
        XCTAssertEqual(session.title, "OpenCode task")
        XCTAssertEqual(session.turns.first?.state, .running)
        XCTAssertEqual(session.turns.first?.provider, "OpenCode")
        XCTAssertEqual(session.currentModel?.name, "gpt")
    }

    func testCompletedSnapshotProducesCompletionAndRejectsMalformedData() throws {
        let completed = try OpenCodeSessionObserver.read(JSONEncoder().encode(observation(.completed)))
        XCTAssertEqual(completed.session.completions.first?.vendor, "OpenCode")
        XCTAssertEqual(completed.session.completions.first?.model, "gpt")
        XCTAssertThrowsError(try OpenCodeSessionObserver.read(Data("{}".utf8)))
    }
}
