import AgentHUDSupport
import Darwin
import Foundation
import XCTest
@testable import AgentHUDCore

/// A client asking whether a tool may run, and the answer travelling back to it.
final class PermissionHookTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func payload(session: String = "s", tool: String = "Bash",
                         input: [String: Any] = ["command": "rm -rf node_modules",
                                                 "description": "Remove node_modules"]) -> [String: Any] {
        ["session_id": session, "hook_event_name": "PermissionRequest", "cwd": "/Users/me/agent-hud",
         "tool_name": tool, "tool_input": input]
    }

    func testTheHookIsInstalledBesideWhateverElseTheSettingsHold() throws {
        let home = try directory()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = ["model": "opus",
                                       "hooks": ["PermissionRequest": [["hooks": [["type": "command", "command": "say hi"]]]]]]
        try JSONSerialization.data(withJSONObject: existing).write(to: settings)

        let executable = URL(fileURLWithPath: "/Applications/Agent HUD.app/Contents/MacOS/Agent HUD")
        XCTAssertFalse(PermissionHooks.isActive(.claude, home: home))
        try PermissionHooks.configure(.claude, enabled: true, executable: executable, home: home)
        XCTAssertTrue(PermissionHooks.isActive(.claude, home: home))

        let updated = try XCTUnwrap(try ProviderJSON.read(Data(contentsOf: settings)).objectValue)
        XCTAssertEqual(updated["model"]?.stringValue, "opus", "nothing else in the file is touched")
        let groups = updated["hooks"]?["PermissionRequest"].arrayValue ?? []
        let commands = groups.flatMap { $0["hooks"].arrayValue ?? [] }.compactMap { $0["command"].stringValue }
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.contains("say hi"))
        let ours = try XCTUnwrap(groups.first { group in
            (group["hooks"].arrayValue ?? []).contains { $0["command"].stringValue?.hasSuffix(" --permission-hook claude") == true }
        })
        XCTAssertEqual(ours["matcher"].stringValue, "", "every tool the client would ask about")
        XCTAssertEqual(ours["hooks"].arrayValue?.first?["timeout"].numberValue, 86_400,
                       "the client must keep waiting while the request sits on the HUD")

        try PermissionHooks.configure(.claude, enabled: false, executable: executable, home: home)
        XCTAssertFalse(PermissionHooks.isActive(.claude, home: home))
        let removed = try XCTUnwrap(try ProviderJSON.read(Data(contentsOf: settings)).objectValue)
        XCTAssertEqual((removed["hooks"]?["PermissionRequest"].arrayValue ?? []).count, 1, "the other handler stays")
    }

    func testEachForkIsFoundInItsOwnHome() throws {
        let home = try directory()
        for source in PermissionHooks.Source.allCases {
            XCTAssertFalse(source.isInstalled(home: home), "a machine without the client keeps its home untouched")
        }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".qoder"), withIntermediateDirectories: true)
        XCTAssertTrue(PermissionHooks.Source.qoder.isInstalled(home: home))
        XCTAssertFalse(PermissionHooks.Source.qoderCN.isInstalled(home: home), "the CN build has its own home")

        try PermissionHooks.configure(.qoder, enabled: true, executable: URL(fileURLWithPath: "/tmp/hud"), home: home)
        let settings = try ProviderJSON.read(Data(contentsOf: home.appendingPathComponent(".qoder/settings.json")))
        let commands = (settings["hooks"]["PermissionRequest"].arrayValue ?? [])
            .flatMap { $0["hooks"].arrayValue ?? [] }.compactMap { $0["command"].stringValue }
        XCTAssertEqual(commands, ["'/tmp/hud' --permission-hook qoderCN".replacingOccurrences(of: "qoderCN", with: "qoder")],
                       "the fork ships Claude Code's schema unchanged, so one handler serves it")
    }

    func testAnUnreadableSettingsLayoutIsNeverRewritten() throws {
        let home = try directory()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"hooks": "everything off"}"#.utf8).write(to: settings)
        XCTAssertThrowsError(try PermissionHooks.configure(.claude, enabled: true,
            executable: URL(fileURLWithPath: "/tmp/hud"), home: home))
        XCTAssertEqual(try Data(contentsOf: settings), Data(#"{"hooks": "everything off"}"#.utf8))
    }

    func testTheRequestSaysWhatTheCallIsAbout() throws {
        let bash = try XCTUnwrap(try PermissionRequest.parse(
            JSONSerialization.data(withJSONObject: payload()), source: .claude, id: "1", now: now))
        XCTAssertEqual(bash.summary, "Remove node_modules", "the tool's own description reads better than its command")
        XCTAssertEqual(bash.detail, "rm -rf node_modules", "and the command itself is what is being approved")
        XCTAssertEqual(bash.project, "agent-hud", "the folder is how two sessions are told apart")

        let edit = try XCTUnwrap(try PermissionRequest.parse(
            JSONSerialization.data(withJSONObject: payload(tool: "Edit", input: ["file_path": "/Users/me/agent-hud/README.md"])),
            source: .claude, id: "2", now: now))
        XCTAssertEqual(edit.summary, "README.md")
        XCTAssertEqual(edit.detail, "/Users/me/agent-hud/README.md")

        let mcp = try XCTUnwrap(try PermissionRequest.parse(
            JSONSerialization.data(withJSONObject: payload(tool: "mcp__linear__create_issue", input: [:])),
            source: .claude, id: "3", now: now))
        XCTAssertEqual(mcp.summary, "linear · create_issue")

        XCTAssertNil(try PermissionRequest.parse(JSONSerialization.data(withJSONObject: ["tool_name": "Bash"]),
                                                 source: .claude, id: "4", now: now),
                     "a request that names no session cannot be shown beside one")
    }

    func testTheAnswerIsTheOneTheClientReads() throws {
        let allow = try XCTUnwrap(try ProviderJSON.read(PermissionDecision.allow.response).objectValue)
        let output = try XCTUnwrap(allow["hookSpecificOutput"]?.objectValue)
        XCTAssertEqual(output["hookEventName"]?.stringValue, "PermissionRequest")
        XCTAssertEqual(output["decision"]?["behavior"].stringValue, "allow")
        XCTAssertEqual(try ProviderJSON.read(PermissionDecision.deny.response)["hookSpecificOutput"]["decision"]["behavior"].stringValue,
                       "deny")
        XCTAssertTrue(PermissionDecision.noDecision.isEmpty, "saying nothing leaves the client's own prompt alone")
    }

    // MARK: The channel

    /// Connects the way the hook does and returns the descriptor, or nil when nothing is listening.
    private func connect(to path: String) -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let size = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: size) { strlcpy($0, path, size) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(descriptor); return nil }
        return descriptor
    }

    /// The listener comes up on the main queue, so the first connection waits for it the way a hook would retry.
    private func ask(_ path: String, _ body: [String: Any], source: PermissionHooks.Source = .claude) async throws -> Int32 {
        var opened = connect(to: path)
        for _ in 0..<200 where opened == nil {
            try await Task.sleep(for: .milliseconds(10))
            opened = connect(to: path)
        }
        let descriptor = try XCTUnwrap(opened, "the HUD is listening")
        var payload = body
        payload[PermissionHookClient.sourceKey] = source.rawValue
        let data = try JSONSerialization.data(withJSONObject: payload)
        _ = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        shutdown(descriptor, SHUT_WR)
        return descriptor
    }

    /// Waits for the requests on the HUD to become `count`, so the test follows the channel rather than a delay.
    @MainActor private func waitForPending(_ count: Int, _ message: String) async throws {
        for _ in 0..<200 where PermissionRequests.shared.pending.count != count {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(PermissionRequests.shared.pending.count, count, message)
    }

    @MainActor
    func testAClientWaitsOnTheChannelUntilItIsAnsweredOrGivesUp() async throws {
        let path = try directory().appendingPathComponent("permission.sock").path
        let requests = PermissionRequests.shared
        requests.start(path: path)
        addTeardownBlock { Task { @MainActor in requests.stop() } }

        let client = try await ask(path, payload())
        try await waitForPending(1, "the request reaches the HUD")
        let request = try XCTUnwrap(requests.pending.first)
        XCTAssertEqual(request.summary, "Remove node_modules")
        XCTAssertEqual(request.sessionID, "s")

        requests.resolve(request.id, .allow)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let read = recv(client, &buffer, buffer.count, 0)
        close(client)
        XCTAssertGreaterThan(read, 0, "the client is waiting for exactly this")
        XCTAssertEqual(try ProviderJSON.read(Data(buffer[..<max(0, read)]))["hookSpecificOutput"]["decision"]["behavior"].stringValue,
                       "allow")
        XCTAssertTrue(requests.pending.isEmpty, "an answered request leaves the HUD")

        // A client that gives up — answered in its own terminal, timed out, killed — takes its request with it.
        let abandoned = try await ask(path, payload(session: "t"))
        try await waitForPending(1, "the second request reaches the HUD")
        close(abandoned)
        try await waitForPending(0, "a request nobody is waiting for is no longer a question")
    }
}
