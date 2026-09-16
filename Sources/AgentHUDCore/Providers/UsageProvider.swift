import Foundation

/// Local activity plus the latest available account readings.
/// Never depends on AppKit.
public protocol UsageProvider: Sendable {
    /// Refresh slow account APIs independently of local activity. Providers own their request cadence
    /// and expose account failures in the next report's notices.
    func refreshAccountUsage(historyHours: Int) async

    /// The account refresh as independent steps, such as one per vendor. The store runs them one at a time
    /// between local polls, so a slow account request never overlaps another read.
    var accountRefreshSteps: [AccountRefreshStep] { get }

    /// - agents: the user's ordered agent list; the provider fills what it knows and skips the rest.
    /// - historyHours: how many hourly buckets to load, including the current partial hour.
    func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport

    /// Directories whose changes can alter the next local report. Nil when the provider cannot tell,
    /// so every poll reads its local data.
    var watchedDirectories: [URL]? { get }

    /// The parts of this provider that can be read on their own, each with what signals that it has new data.
    /// The collector reads a source only when one of its signals fires.
    var sources: [UsageSource] { get }

    /// Reads the named sources again and keeps every other source's last result; nil reads every source.
    func fetchUsage(agents: [AgentDescriptor], historyHours: Int, sources: Set<String>?) async throws -> UsageReport

    /// When each source's last result changes with time alone, such as a live session that stops being live after a quiet
    /// interval. The collector reads a source again when one of its times passes; a source without times is left alone.
    func sourceChecks() async -> [String: [Date]]
}

public typealias AccountRefreshStep = @Sendable (_ historyHours: Int) async -> Void

/// A part of a provider that is read on its own, and the signals that it has new data: changes under its directories,
/// its account steps, and the checks it asks for. Whatever a source does inside, the collector sees only these signals.
public struct UsageSource: Sendable {
    public let name: String
    /// Directories whose file changes need a read of this source. Nil when the source cannot tell, so it is read every
    /// poll interval instead.
    public let directories: [URL]?
    /// This source's account refresh, run by the account sweep. A finished step signals a read of this source.
    public let accountSteps: [AccountRefreshStep]

    public init(name: String, directories: [URL]?, accountSteps: [AccountRefreshStep]) {
        self.name = name
        self.directories = directories
        self.accountSteps = accountSteps
    }
}

extension UsageProvider {
    public func refreshAccountUsage(historyHours: Int) async {}
    public var accountRefreshSteps: [AccountRefreshStep] { [{ await self.refreshAccountUsage(historyHours: $0) }] }
    public var watchedDirectories: [URL]? { nil }
    /// A provider that does not split itself is one source; the collector derives its checks from the report it returned.
    public var sources: [UsageSource] { [UsageSource(name: "", directories: watchedDirectories, accountSteps: accountRefreshSteps)] }
    public func fetchUsage(agents: [AgentDescriptor], historyHours: Int, sources: Set<String>?) async throws -> UsageReport {
        try await fetchUsage(agents: agents, historyHours: historyHours)
    }
    public func sourceChecks() async -> [String: [Date]] { [:] }
}

/// The collection pipeline's cadence. Reads never run in parallel: one account step or one source read at a time.
public enum UsageRefresh {
    /// Quota and balance readings of every provider, and the fallback read of every local source.
    public static let accountInterval: TimeInterval = 300
    /// A provider never repeats an account request sooner than this, whoever asks.
    public static let accountRequestSpacing: TimeInterval = 60
    /// A source that cannot name its directories is read this often.
    public static let pollInterval: TimeInterval = 5
    /// Local logs while the first index is still being built.
    public static let indexingInterval: TimeInterval = 2
    /// Local reads start at most this often; changes arriving sooner are read together.
    public static let readSpacing: TimeInterval = 2
    /// A live session stops being live this long after its latest observation.
    public static let liveThreshold: TimeInterval = 120
    /// Account steps run back to back for at most this long before local logs get their turn.
    static let accountStepBudget: TimeInterval = 1
    /// A running turn counts as current work while its latest source observation is this recent.
    static let activeTurnFreshness: TimeInterval = 300
}

public struct UsageProviderError: Error, Hashable, Sendable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
