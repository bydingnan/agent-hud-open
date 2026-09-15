import Foundation

/// Errors surfaced to the UI when Claude Code data cannot be read.
public enum ClaudeDataError: Error, Hashable, Sendable, LocalizedError {
    case engineNotFound
    case engineFailed(String)
    case planLimitsUnavailable
    case malformedUsage
    case accountChanged

    public var errorDescription: String? {
        switch self {
        case .engineNotFound:
            return L10n.text("未找到 Claude Code 引擎（claude 命令）", "Claude Code engine (claude command) not found")
        case .engineFailed(let reason):
            return L10n.text("Claude Code 引擎查询失败：\(reason)", "Claude Code engine query failed: \(reason)")
        case .planLimitsUnavailable:
            return L10n.text("当前登录方式没有订阅额度（API key 或第三方平台）", "No plan limits for this login (API key or third-party platform)")
        case .malformedUsage:
            return L10n.text("Claude Code 引擎返回了无法识别的额度数据", "The Claude Code engine returned unrecognised usage data")
        case .accountChanged:
            return L10n.text("读取额度时 Claude 登录账户发生了变化，稍后自动重试", "The Claude account changed during the quota query; retrying shortly")
        }
    }
}

/// Finds the Claude Code engine binary. GUI apps get a minimal PATH, so well-known install locations are checked
/// directly; the desktop app's Code tab installs the same engine under `~/.local/share/claude/versions`.
public enum ClaudeEngineLocator {
    public static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var list = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        let versions = home.appendingPathComponent(".local/share/claude/versions", isDirectory: true)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: versions.path) {
            let sorted = names.filter { !$0.hasPrefix(".") }.sorted { lhs, rhs in
                lhs.compare(rhs, options: .numeric) == .orderedDescending
            }
            list += sorted.map { versions.appendingPathComponent($0) }
        }
        return list
    }

    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) -> URL? {
        candidates(home: home).first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

/// Payload of the engine's `get_usage` control response.
public struct ClaudeEngineUsage: Hashable, Sendable {
    public let usage: ClaudeUsage
    public let subscriptionType: String?
    public let rateLimitsAvailable: Bool

    public init(usage: ClaudeUsage, subscriptionType: String?, rateLimitsAvailable: Bool) {
        self.usage = usage
        self.subscriptionType = subscriptionType
        self.rateLimitsAvailable = rateLimitsAvailable
    }

    /// Parses one `control_response` line. Returns nil for other stream lines; throws when the engine reports an error.
    public static func parse(line: String) throws -> ClaudeEngineUsage? {
        guard line.contains("\"control_response\""),
              let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "control_response",
              let envelope = root["response"] as? [String: Any]
        else { return nil }
        if envelope["subtype"] as? String == "error" {
            throw ClaudeDataError.engineFailed(envelope["error"] as? String ?? "unknown error")
        }
        guard let payload = envelope["response"] as? [String: Any] else {
            throw ClaudeDataError.engineFailed("empty get_usage response")
        }
        let available = (payload["rate_limits_available"] as? Bool) ?? false
        let subscription = payload["subscription_type"] as? String
        guard available, let limits = payload["rate_limits"] as? [String: Any] else {
            return ClaudeEngineUsage(usage: ClaudeUsage(fiveHour: nil, sevenDay: nil), subscriptionType: subscription, rateLimitsAvailable: false)
        }
        let limitsData = try JSONSerialization.data(withJSONObject: limits)
        return ClaudeEngineUsage(usage: try ClaudeUsage.parse(limitsData), subscriptionType: subscription, rateLimitsAvailable: true)
    }
}

/// Asks a headless engine process for the plan usage via the SDK control protocol (`get_usage`).
/// No prompt is ever sent, so nothing is billed; the engine uses its own login to fetch the numbers.
public struct ClaudeEngineUsageClient: Sendable {
    public let executable: URL
    public let workingDirectory: URL
    public let timeout: TimeInterval

    public init(executable: URL, workingDirectory: URL, timeout: TimeInterval = 40) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    public static var defaultWorkingDirectory: URL {
        AppSupport.directory.appendingPathComponent("engine", isDirectory: true)
    }

    public static let request = #"{"type":"control_request","request_id":"agent-hud-usage","request":{"subtype":"get_usage"}}"#

    public func fetch() async throws -> ClaudeEngineUsage {
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["CLAUDE_CODE_ENTRYPOINT"] = "agent-hud"
        let engine = try ChildProcess(executable, [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--settings", #"{"disableAllHooks":true}"#,
        ], environment: environment, directory: workingDirectory, input: true, stdoutLimit: 8 * 1024 * 1024)
        defer { engine.stop() }
        try? engine.write(Data((Self.request + "\n").utf8))

        let deadline = Date().addingTimeInterval(timeout)
        while let line = try await engine.line(before: deadline) {
            if let usage = try ClaudeEngineUsage.parse(line: line) { return usage }
        }
        let stderr = String(decoding: engine.output.stderr, as: UTF8.self)
        throw ClaudeDataError.engineFailed(stderr.isEmpty ? L10n.text("引擎没有在 \(Int(timeout)) 秒内返回用量", "The engine returned no usage within \(Int(timeout)) s") : String(stderr.prefix(200)))
    }
}
