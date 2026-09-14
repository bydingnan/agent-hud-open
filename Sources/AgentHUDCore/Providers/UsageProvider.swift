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
}

public typealias AccountRefreshStep = @Sendable (_ historyHours: Int) async -> Void

extension UsageProvider {
    public func refreshAccountUsage(historyHours: Int) async {}
    public var accountRefreshSteps: [AccountRefreshStep] { [{ await self.refreshAccountUsage(historyHours: $0) }] }
    public var watchedDirectories: [URL]? { nil }
}

/// The collection pipeline's cadence. Reads never run in parallel: one account step or one local poll at a time.
public enum UsageRefresh {
    /// Quota and balance readings of every provider, and the fallback poll of local logs.
    public static let accountInterval: TimeInterval = 300
    /// A provider never repeats an account request sooner than this, whoever asks.
    public static let accountRequestSpacing: TimeInterval = 60
    /// Local logs while a turn runs or after a watched directory changed.
    public static let pollInterval: TimeInterval = 5
    /// Local logs while the first index is still being built.
    public static let indexingInterval: TimeInterval = 2
    /// Account steps run back to back for at most this long before local logs get their turn.
    static let accountStepBudget: TimeInterval = 1
    /// A running turn keeps local polls going while its latest source observation is this recent.
    static let activeTurnFreshness: TimeInterval = 300
}

public struct UsageProviderError: Error, Hashable, Sendable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
