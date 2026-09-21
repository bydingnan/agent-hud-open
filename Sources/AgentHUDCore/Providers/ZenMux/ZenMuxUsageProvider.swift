import Foundation

/// ZenMux exposes account-wide subscription quota and token usage without a local session source.
/// Cost / billing history is not shown — only plan windows stay on the HUD.
public actor ZenMuxUsageProvider: UsageProvider {
    private typealias HistoryReader<Value: Sendable> = @Sendable (Int, Date) async throws -> Value

    private let readQuota: @Sendable () async throws -> ProviderQuota
    private let readUsage: HistoryReader<[UsageBucket]>
    private let hasKey: @Sendable () -> Bool
    private let clock: @Sendable () -> Date
    private var lastRefreshAt: Date?
    private var quota: Result<ProviderQuota, UsageProviderError>?
    private var usage: Result<[UsageBucket], UsageProviderError>?

    init(
        readQuota: @escaping @Sendable () async throws -> ProviderQuota,
        readUsage: @escaping @Sendable () async throws -> [UsageBucket],
        hasKey: @escaping @Sendable () -> Bool,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.readQuota = readQuota
        self.readUsage = { _, _ in try await readUsage() }
        self.hasKey = hasKey
        self.clock = clock
    }

    private init(
        readQuota: @escaping @Sendable () async throws -> ProviderQuota,
        readUsage: @escaping HistoryReader<[UsageBucket]>,
        hasKey: @escaping @Sendable () -> Bool,
        clock: @escaping @Sendable () -> Date
    ) {
        self.readQuota = readQuota
        self.readUsage = readUsage
        self.hasKey = hasKey
        self.clock = clock
    }

    /// Test helper that ignores cost readers — subscription quota only.
    init(
        readQuota: @escaping @Sendable () async throws -> ProviderQuota,
        readUsage: @escaping @Sendable () async throws -> [UsageBucket],
        readCosts: @escaping @Sendable () async throws -> [CostBucket],
        hasKey: @escaping @Sendable () -> Bool,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        _ = readCosts
        self.init(readQuota: readQuota, readUsage: readUsage, hasKey: hasKey, clock: clock)
    }

    public static func standard(ledger: UsageLedger) -> ZenMuxUsageProvider {
        _ = ledger
        let client = ZenMuxClient()
        return ZenMuxUsageProvider(
            readQuota: { try await client.fetchSubscription() },
            readUsage: { hours, now in
                try await client.fetchUsageHistory(days: Self.historyDays(hours), now: now)
            },
            hasKey: { ZenMuxCredentials.managementKey() != nil },
            clock: { Date() }
        )
    }

    /// `nil` (not `[]`) so the collector polls this account-only source; an empty list would never be read.
    public nonisolated var watchedDirectories: [URL]? { nil }
    public nonisolated var seesLocalWork: Bool { false }

    public func refreshAccountUsage(historyHours: Int) async {
        _ = historyHours
        guard hasKey() else {
            lastRefreshAt = nil
            quota = nil
            usage = nil
            return
        }
        let now = clock()
        guard lastRefreshAt.map({ now.timeIntervalSince($0) >= UsageRefresh.accountRequestSpacing }) ?? true else {
            return
        }
        lastRefreshAt = now
        // Island only needs quota. Token history is filled on a later poll.
        quota = await capture { try await readQuota() }
        usage = nil
    }

    public func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport {
        let now = clock()
        guard hasKey() else {
            let message = L10n.text(
                "请设置 ZENMUX_MANAGEMENT_API_KEY 后刷新额度",
                "Set ZENMUX_MANAGEMENT_API_KEY, then refresh quota")
            return UsageReport(generatedAt: now, snapshots: [], sessions: [],
                               notice: message, sourceNotices: ["ZenMux": message])
        }
        if quota == nil {
            // First paint: quota alone. History waits for the next poll.
            await refreshAccountUsage(historyHours: historyHours)
        } else if usage == nil {
            usage = await capture { try await readUsage(historyHours, now) }
        }
        return makeReport(now: now)
    }

    private func makeReport(now: Date) -> UsageReport {
        let observedAt = lastRefreshAt ?? now
        let quotaValue = try? quota?.get()
        let usageValue = (try? usage?.get()) ?? []
        let windows = quotaValue?.windows ?? []
        let snapshots = windows.map {
            UsageSnapshot(agentId: $0.id, remainingPct: $0.remaining, resetAt: $0.reset,
                          windowDuration: $0.duration, updatedAt: observedAt)
        }
        let quotaAgents = windows.map {
            AgentDescriptor(id: $0.id, vendor: "ZenMux", model: $0.label,
                            source: L10n.text("ZenMux 账户用量", "ZenMux account usage"), enabled: true)
        }
        let consumer = AgentDescriptor(id: "zenmux", vendor: "ZenMux", model: L10n.text("订阅", "Plan"),
                                       source: L10n.text("ZenMux 账户用量", "ZenMux account usage"), enabled: true)
        let notices = [failureMessage(quota), failureMessage(usage)].compactMap { $0 }
        let notice = notices.isEmpty ? nil : notices.joined(separator: " · ")
        return UsageReport(
            generatedAt: now,
            snapshots: snapshots,
            sessions: [],
            notice: notice,
            discoveredAgents: quotaAgents,
            consumers: [consumer],
            usage: usageValue,
            subscriptions: quotaValue?.plan.map { ["ZenMux": $0] } ?? [:],
            sourceNotices: notice.map { ["ZenMux": $0] } ?? [:],
            consumerIdsByQuota: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, ["zenmux"]) })
        )
    }

    private func capture<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async -> Result<Value, UsageProviderError> {
        do {
            let value = try await operation()
            try Task.checkCancellation()
            return .success(value)
        } catch {
            return .failure(UsageProviderError(error.localizedDescription))
        }
    }

    private func failureMessage<Value>(_ result: Result<Value, UsageProviderError>?) -> String? {
        guard case .failure(let error) = result else { return nil }
        return error.message
    }

    private static func historyDays(_ hours: Int) -> Int {
        max(1, Int(ceil(Double(max(0, hours)) / 24)))
    }
}
