import AgentHUDSupport
import Foundation

/// Cursor Agent CLI lifecycle observations written by `~/.cursor/hooks/cursor-lifecycle.sh`.
/// Complements account-wide Cursor usage: these records establish local running / terminal turns.
public enum CursorLifecycleObserver {
    public static var directory: URL { AppSupport.directory.appendingPathComponent("lifecycle/cursor") }
    private static let retention: TimeInterval = 7 * 86400
    private static let marker = "agent-hud-cursor-lifecycle"
    private static let scriptName = "cursor-lifecycle.sh"

    struct Observation: Codable, Sendable {
        let version: Int
        let sessionID: String
        let workspace: String?
        let title: String
        let model: String?
        let turnID: String
        let state: SessionTurn.State
        let startedAtMs: Int64
        let observedAtMs: Int64

        var turn: SessionTurn {
            .init(provider: "Cursor", sessionID: sessionID, turnID: turnID, state: state,
                  startedAtMs: startedAtMs, observedAtMs: observedAtMs)
        }

        var session: ProviderSession {
            var value = ProviderSession(id: sessionID, title: title, workspace: workspace, client: "Cursor",
                                        startedAt: RecordCoding.date(startedAtMs), lastActivity: RecordCoding.date(observedAtMs),
                                        turns: [turn])
            if state == .completed {
                value.completions = [.init(sessionID: sessionID, vendor: "Cursor", turnID: turnID,
                    task: title, model: model ?? "Cursor",
                    startedAt: RecordCoding.date(startedAtMs), completedAt: RecordCoding.date(observedAtMs))]
            }
            return value
        }
    }

    static func read(_ data: Data) throws -> Observation {
        guard data.count <= 64 * 1024 else { throw ProviderFailure.limit }
        let value = try JSONDecoder().decode(Observation.self, from: data)
        guard value.version == 1, value.sessionID.hasPrefix("cursor:"), value.sessionID.count > 7,
              !value.turnID.isEmpty, value.startedAtMs > 0, value.observedAtMs >= value.startedAtMs else {
            throw ProviderFailure.format
        }
        return value
    }

    /// Local lifecycle sessions newer than `since`.
    static func sessions(since: Date, directory: URL = directory, now: Date = Date()) throws -> [ProviderSession] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var byID: [String: ProviderSession] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        where file.pathExtension == "json" {
            let data = try Data(contentsOf: file)
            guard data.count <= 64 * 1024 else { continue }
            guard let observation = try? read(data) else { continue }
            if observation.observedAtMs < RecordCoding.milliseconds(since) { continue }
            if Double(observation.observedAtMs) / 1000 < now.timeIntervalSince1970 - retention {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let session = observation.session
            if var prior = byID[session.id] {
                prior.turns = (prior.turns + session.turns).sorted {
                    ($0.startedAtMs ?? $0.observedAtMs) < ($1.startedAtMs ?? $1.observedAtMs)
                }
                prior.completions += session.completions
                prior.lastActivity = [prior.lastActivity, session.lastActivity].compactMap { $0 }.max()
                prior.startedAt = [prior.startedAt, session.startedAt].compactMap { $0 }.min()
                if let workspace = session.workspace { prior.workspace = workspace }
                if !session.title.isEmpty { prior.title = session.title }
                byID[session.id] = prior
            } else {
                byID[session.id] = session
            }
        }
        return byID.keys.sorted().compactMap { byID[$0] }
    }

    static func merge(account: ProviderSessions, lifecycle: [ProviderSession]) -> ProviderSessions {
        guard !lifecycle.isEmpty else { return account }
        var byID = Dictionary(uniqueKeysWithValues: account.sessions.map { ($0.id, $0) })
        for item in lifecycle {
            if var prior = byID[item.id] {
                prior.turns = (prior.turns + item.turns).sorted {
                    ($0.startedAtMs ?? $0.observedAtMs) < ($1.startedAtMs ?? $1.observedAtMs)
                }
                prior.completions += item.completions
                prior.lastActivity = [prior.lastActivity, item.lastActivity].compactMap { $0 }.max()
                prior.startedAt = [prior.startedAt, item.startedAt].compactMap { $0 }.min()
                if let workspace = item.workspace { prior.workspace = workspace }
                if !item.title.isEmpty { prior.title = item.title }
                byID[item.id] = prior
            } else {
                byID[item.id] = item
            }
        }
        var result = account
        result.sessions = byID.keys.sorted().compactMap { byID[$0] }
        return result
    }

    // MARK: Installation

    private static func scriptURL(home: URL) -> URL {
        home.appendingPathComponent(".cursor/hooks/\(scriptName)")
    }

    private static func configurationURL(home: URL) -> URL {
        home.appendingPathComponent(".cursor/hooks.json")
    }

    private static func owns(_ handler: ProviderJSON) -> Bool {
        let command = handler["command"].stringValue ?? ""
        return command.contains(marker) || command.contains(scriptName)
    }

    private static func command(for event: String, script: URL) -> String {
        "HOOK_MARK=\(marker) bash '\(script.path.replacingOccurrences(of: "'", with: "'\\''"))' \(event)"
    }

    public static func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let script = scriptURL(home: home)
        guard FileManager.default.isExecutableFile(atPath: script.path) else { return false }
        guard let object = try? configuration(home: home) else { return false }
        let hooks = object["hooks"]?.objectValue ?? [:]
        return ["beforeSubmitPrompt", "stop"].allSatisfy { event in
            (hooks[event]?.arrayValue ?? []).contains(where: owns)
        }
    }

    private static func configuration(home: URL) throws -> [String: ProviderJSON] {
        let url = configurationURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return ["version": .integer(1), "hooks": .object([:])] }
        guard let object = try ProviderFiles.json(url).objectValue else { throw ProviderFailure.format }
        return object
    }

    /// Ensures the lifecycle script exists and appends owned handlers without removing Orca / Herdr / completion hooks.
    public static func configure(enabled: Bool,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 scriptSource: URL? = nil) throws {
        let script = scriptURL(home: home)
        if enabled {
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let scriptSource, FileManager.default.fileExists(atPath: scriptSource.path) {
                if FileManager.default.fileExists(atPath: script.path) { try FileManager.default.removeItem(at: script) }
                try FileManager.default.copyItem(at: scriptSource, to: script)
            } else if !FileManager.default.fileExists(atPath: script.path) {
                throw UsageProviderError(L10n.text("缺少 Cursor lifecycle 脚本", "Cursor lifecycle script is missing"))
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }

        var object = try configuration(home: home)
        guard object["version"] == nil || object["version"] == .integer(1),
              object["hooks"] == nil || object["hooks"]?.objectValue != nil else { throw ProviderFailure.format }
        var hooks = object["hooks"]?.objectValue ?? [:]
        let events = ["beforeSubmitPrompt", "preToolUse", "postToolUse", "afterAgentResponse", "stop", "sessionEnd"]
        for event in events {
            guard hooks[event] == nil || hooks[event]?.arrayValue != nil else { throw ProviderFailure.format }
            var handlers = (hooks[event]?.arrayValue ?? []).filter { !owns($0) }
            if enabled {
                handlers.append(.object(["command": .string(command(for: event, script: script)), "timeout": .integer(5)]))
            }
            hooks[event] = handlers.isEmpty ? nil : .array(handlers)
        }
        object["hooks"] = .object(hooks)
        object["version"] = .integer(1)
        let url = configurationURL(home: home)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(ProviderJSON.object(object)).write(to: url, options: .atomic)
    }

    public static func configureIfAvailable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                            scriptSource: URL? = nil) throws {
        let cursorHome = home.appendingPathComponent(".cursor")
        guard FileManager.default.fileExists(atPath: cursorHome.path) else { return }
        let source = scriptSource ?? scriptURL(home: home)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try configure(enabled: true, home: home, scriptSource: source.path == scriptURL(home: home).path ? nil : source)
    }
}
