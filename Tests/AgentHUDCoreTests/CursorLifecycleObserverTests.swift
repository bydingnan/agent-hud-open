import XCTest
@testable import AgentHUDCore

final class CursorLifecycleObserverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_300_000)

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CursorLifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.resolvingSymlinksInPath()
    }

    func testReadRunningAndCompletedMerge() throws {
        let dir = try temporaryHome().appendingPathComponent("lifecycle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let running = CursorLifecycleObserver.Observation(
            version: 1, sessionID: "cursor:abc", workspace: "/tmp/demo", title: "Cursor · demo",
            model: "composer", turnID: "gen-1", state: .running,
            startedAtMs: Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1000),
            observedAtMs: Int64(now.addingTimeInterval(-5).timeIntervalSince1970 * 1000))
        try JSONEncoder().encode(running).write(to: dir.appendingPathComponent("a.json"))
        let sessions = try CursorLifecycleObserver.sessions(since: now.addingTimeInterval(-3600), directory: dir, now: now)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.turns.first?.state, .running)

        let completed = CursorLifecycleObserver.Observation(
            version: 1, sessionID: "cursor:abc", workspace: "/tmp/demo", title: "Cursor · demo",
            model: "composer", turnID: "gen-1", state: .completed,
            startedAtMs: running.startedAtMs, observedAtMs: Int64(now.timeIntervalSince1970 * 1000))
        try JSONEncoder().encode(completed).write(to: dir.appendingPathComponent("a.json"))
        let done = try CursorLifecycleObserver.sessions(since: now.addingTimeInterval(-3600), directory: dir, now: now)
        XCTAssertEqual(done.first?.turns.last?.state, .completed)
        XCTAssertEqual(done.first?.completions.count, 1)
    }

    func testConfigureAppendsOwnedHandlersWithoutRemovingOthers() throws {
        let home = try temporaryHome()
        let cursor = home.appendingPathComponent(".cursor")
        let hooksDir = cursor.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let script = hooksDir.appendingPathComponent("cursor-lifecycle.sh")
        try "#!/bin/sh\necho '{}'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let hooks = cursor.appendingPathComponent("hooks.json")
        try """
        {"version":1,"hooks":{"stop":[{"command":"other-stop","timeout":5}],"beforeSubmitPrompt":[{"command":"other","timeout":5}]}}
        """.write(to: hooks, atomically: true, encoding: .utf8)
        try CursorLifecycleObserver.configure(enabled: true, home: home)
        let object = try ProviderJSON.read(Data(contentsOf: hooks)).objectValue!
        let stop = object["hooks"]?["stop"].arrayValue ?? []
        XCTAssertEqual(stop.count, 2)
        XCTAssertTrue(stop.contains { ($0["command"].stringValue ?? "").contains("cursor-lifecycle.sh") })
        XCTAssertTrue(stop.contains { $0["command"].stringValue == "other-stop" })
        XCTAssertTrue(CursorLifecycleObserver.isInstalled(home: home))
        try CursorLifecycleObserver.configure(enabled: false, home: home)
        let after = try ProviderJSON.read(Data(contentsOf: hooks)).objectValue!
        let stopAfter = after["hooks"]?["stop"].arrayValue ?? []
        XCTAssertEqual(stopAfter.count, 1)
        XCTAssertEqual(stopAfter.first?["command"].stringValue, "other-stop")
    }
}
