import AgentHUDSupport
import Foundation

/// The hook a client runs when it is about to ask its user whether a tool may run.
///
/// The notification hook only says a session needs its user; this one is answered. The client waits on the hook's own
/// output and acts on what it says, so a request can be approved from the HUD instead of the terminal. Saying nothing
/// is always available and always safe: the client then behaves exactly as it would with no hook installed.
public enum PermissionHooks {
    /// Clients that ship Claude Code's hook schema unchanged, so one payload shape and one answer shape serve all of
    /// them; they differ only in where their settings live. Each is offered only on a machine that has it.
    public enum Source: String, CaseIterable, Sendable {
        case claude
        case qoder
        case qoderCN
        case qoderWork

        public var vendor: String {
            switch self {
            case .claude: return "Claude"
            case .qoder: return "Qoder"
            case .qoderCN: return "Qoder CN"
            case .qoderWork: return "QoderWork"
            }
        }

        var event: String { "PermissionRequest" }
        /// Matched against the tool name; empty is every tool.
        var matcher: String { "" }
        /// How long the client waits for an answer. A request stays on the HUD until it is answered or the client
        /// withdraws it, so this only has to outlast a user who walked away. A client that cancels the hook first
        /// closes the connection, which takes the request off the HUD.
        var timeout: Int { 86_400 }

        var directory: String {
            switch self {
            case .claude: return ".claude"
            case .qoder: return ".qoder"
            case .qoderCN: return ".qoder-cn"
            case .qoderWork: return ".qoderwork"
            }
        }

        func home(_ base: URL) -> URL {
            // Claude Code's configuration directory moves with CLAUDE_CONFIG_DIR; the forks have no such variable.
            if case .claude = self, let configured = ClaudeSubscription.configDirectory { return configured }
            return base.appendingPathComponent(directory, isDirectory: true)
        }

        func configuration(home base: URL) -> URL { home(base).appendingPathComponent("settings.json") }

        /// Whether the client is here at all. A machine without it keeps its home untouched.
        public func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                fileManager: FileManager = .default) -> Bool {
            switch self {
            case .claude:
                return ClaudeEngineLocator.find(home: home, fileManager: fileManager) != nil
                    || fileManager.fileExists(atPath: home.appendingPathComponent(".claude/projects").path)
            case .qoder, .qoderCN, .qoderWork:
                return fileManager.fileExists(atPath: self.home(home).path)
            }
        }
    }

    // MARK: Installation

    static func configuration(_ source: Source, home: URL) throws -> [String: ProviderJSON] {
        let url = source.configuration(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024 else { throw ProviderFailure.limit }
        guard !data.isEmpty else { return [:] }
        guard let object = try ProviderJSON.read(data).objectValue else { throw ProviderFailure.format }
        return object
    }

    static func ownsCommand(_ command: String?, source: Source) -> Bool {
        command?.hasSuffix(" --permission-hook " + source.rawValue) == true
    }

    public static func isActive(_ source: Source, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let object = try? configuration(source, home: home) else { return false }
        return !commands(in: object, source: source).isEmpty
    }

    static func commands(in configuration: [String: ProviderJSON], source: Source) -> [String] {
        (configuration["hooks"]?[source.event].arrayValue ?? []).flatMap { $0["hooks"].arrayValue ?? [] }
            .compactMap { $0["command"].stringValue }.filter { ownsCommand($0, source: source) }
    }

    /// Adds or removes Agent HUD's handler, leaving every other hook in the file alone. An unrecognized layout throws
    /// rather than being rewritten.
    public static func configure(_ source: Source, enabled: Bool, executable: URL,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 replacingExisting: Bool = false) throws {
        let object = try configuration(source, home: home)
        let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = quoted + " --permission-hook " + source.rawValue
        if !replacingExisting && commands(in: object, source: source).contains(where: { $0 != command }) {
            throw UsageProviderError(L10n.text("批准回调由另一安装管理，请手动重新安装以切换",
                                               "The permission hook belongs to another installation; reinstall it explicitly to switch"))
        }
        let updated = try updating(object, source: source, command: enabled ? command : nil)
        guard updated != object else { return }
        let url = source.configuration(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(ProviderJSON.object(updated)).write(to: url, options: .atomic)
    }

    static func updating(_ configuration: [String: ProviderJSON], source: Source, command: String?) throws -> [String: ProviderJSON] {
        var object = configuration
        guard object["hooks"] == nil || object["hooks"]?.objectValue != nil else { throw ProviderFailure.format }
        var hooks = object["hooks"]?.objectValue ?? [:]
        guard hooks[source.event] == nil || hooks[source.event]?.arrayValue != nil else { throw ProviderFailure.format }
        var groups = (hooks[source.event]?.arrayValue ?? []).compactMap { group -> ProviderJSON? in
            guard var fields = group.objectValue, let handlers = fields["hooks"]?.arrayValue else { return group }
            let kept = handlers.filter { !ownsCommand($0["command"].stringValue, source: source) }
            if kept.count == handlers.count { return group }
            if kept.isEmpty { return nil }
            fields["hooks"] = .array(kept)
            return .object(fields)
        }
        if let command {
            groups.append(.object(["matcher": .string(source.matcher),
                                   "hooks": .array([.object(["type": .string("command"), "command": .string(command),
                                                             "timeout": .integer(Int64(source.timeout))])])]))
        }
        hooks[source.event] = groups.isEmpty ? nil : .array(groups)
        object["hooks"] = hooks.isEmpty && configuration["hooks"] == nil ? nil : .object(hooks)
        return object
    }
}
