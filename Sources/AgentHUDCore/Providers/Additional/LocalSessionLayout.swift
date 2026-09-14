import Foundation

/// One client's on-disk session layout. The client owns its paths and parser; `AdditionalLocalStore` owns scanning,
/// change detection, caching and merging.
protocol LocalSessionLayout {
    /// Paths relative to the home directory whose presence means the client is installed.
    static var installPaths: [String] { get }
    static func roots(home: URL, environment: [String: String]) -> [URL]
    /// A file whose parse yields sessions.
    static func accepts(_ url: URL) -> Bool
    /// A directory the scan does not descend into.
    static func skips(_ url: URL) -> Bool
    /// Files whose changes also invalidate a parsed file, such as a SQLite WAL.
    static func related(_ url: URL) -> [URL]
    static func read(_ url: URL) throws -> ProviderSessions
    /// Reconciles sessions parsed from different files before identical session ids merge.
    static func merge(_ sessions: [ProviderSession]) -> [ProviderSession]
}

extension LocalSessionLayout {
    static func skips(_ url: URL) -> Bool { false }
    static func related(_ url: URL) -> [URL] { [] }
    static func merge(_ sessions: [ProviderSession]) -> [ProviderSession] { sessions }
}

extension AdditionalSource {
    var layout: (any LocalSessionLayout.Type)? {
        switch self {
        case .antigravity, .cursor, .grok: nil
        case .copilot: CopilotSessions.self
        case .openclaw: OpenClawSessions.self
        case .hermes: HermesSessions.self
        case .zcode: ZCodeSessions.self
        case .codebuddy: CodeBuddySessions.self
        case .workbuddy: WorkBuddySessions.self
        }
    }
}
