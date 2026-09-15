import Foundation

/// Providers that write their token events to the usage ledger themselves.
protocol LedgerRecording {}

/// Joins independent vendors, reading them one after another into one ledger pass. A missing or signed-out source
/// does not suppress another vendor's data, and a failing source keeps the usage it recorded before.
public struct CombinedUsageProvider: UsageProvider {
    public struct Source: Sendable {
        public let vendor: String
        public let provider: any UsageProvider
        public init(_ vendor: String, _ provider: any UsageProvider) { self.vendor = vendor; self.provider = provider }
    }
    private let sources: [Source]
    private let ledger: UsageLedger
    public init(_ sources: [Source], ledger: UsageLedger = .inMemory()) {
        self.sources = sources
        self.ledger = ledger
    }

    public static func standard(ledger: UsageLedger = .open()) -> CombinedUsageProvider {
        removeLegacyCaches(in: AppSupport.directory)
        return CombinedUsageProvider([
            Source("Claude", ClaudeCodeProvider.standard(ledger: ledger)),
            Source("Codex", CodexUsageProvider.standard(ledger: ledger)),
            Source("DeepSeek", DeepSeekUsageProvider.standard(ledger: ledger)),
        ] + AdditionalSource.allCases.map { Source($0.vendor, AdditionalUsageProvider.standard($0, ledger: ledger)) }
          + [Source("Open agents", OpenAgentUsageProvider.standard(ledger: ledger))], ledger: ledger)
    }

    public func refreshAccountUsage(historyHours: Int) async {
        for step in accountRefreshSteps { await step(historyHours) }
    }

    public var accountRefreshSteps: [AccountRefreshStep] { sources.flatMap(\.provider.accountRefreshSteps) }

    public var watchedDirectories: [URL]? {
        var directories: [URL] = []
        for source in sources {
            guard let watched = source.provider.watchedDirectories else { return nil }
            directories += watched
        }
        return directories
    }

    public func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport {
        await ledger.beginPass()
        var results: [(Int, UsageReport?, String?)] = []
        for (index, source) in sources.enumerated() {
            do { results.append((index, try await source.provider.fetchUsage(agents: agents, historyHours: historyHours), nil)) }
            catch { results.append((index, nil, error.localizedDescription)) }
        }
        await ledger.commitPass()
        let reports = results.compactMap { $0.1 }
        var notices: [String: String] = [:]
        for (index, report, error) in results {
            if let report { notices.merge(report.sourceNotices, uniquingKeysWith: { _, new in new }) }
            if let message = error ?? (report?.sourceNotices.isEmpty == true ? report?.notice : nil) { notices[sources[index].vendor] = message }
        }
        guard !reports.isEmpty else { throw UsageProviderError(notices.keys.sorted().map { "\($0): \(notices[$0]!)" }.joined(separator: " · ")) }
        let now = reports.map(\.generatedAt).max() ?? Date()
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        // The ledger holds every recorded source, including one whose refresh just failed; other providers report periods themselves.
        let usage = ((try? await ledger.buckets(since: min(weekAgo, now.addingTimeInterval(-Double(historyHours) * 3600)))) ?? [])
            + results.filter { !(sources[$0.0].provider is any LedgerRecording) }.flatMap { $0.1?.usage ?? [] }
        let week = usage.filter { $0.overlaps(DateInterval(start: weekAgo, end: now)) }
        var totals: [String: Int] = [:]
        for bucket in week {
            totals[bucket.agentId, default: 0] += bucket.total
        }
        let sum = totals.values.reduce(0, +)
        let progress = reports.compactMap(\.indexing)
        return UsageReport(generatedAt: now, snapshots: Dictionary(grouping: reports.flatMap(\.snapshots), by: \.agentId).values.compactMap { $0.max { $0.updatedAt < $1.updatedAt } }.sorted { $0.agentId < $1.agentId },
                           sessions: reports.flatMap(\.sessions).sorted { a, b in
                               if a.isLive != b.isLive { return a.isLive }
                               return (a.endedAt ?? a.startedAt) > (b.endedAt ?? b.startedAt)
                           },
                           activity: UsageAnalytics.activityGrid(usage: week, since: weekAgo, calendar: .current),
                           insights: UsageInsights(burnRatePctPerHour: nil, timeToExhaust: nil, weeklyCapHits: 0,
                                                  weeklyWaitTotal: 0, weeklyWaitLongest: 0, weeklyWaitLongestAt: nil,
                                                  weeklyShare: sum > 0 ? totals.mapValues { Double($0) / Double(sum) } : [:],
                                                  windowSessionCount: reports.reduce(0) { $0 + $1.insights.windowSessionCount }, windowUsedPct: 0),
                           notice: notices.isEmpty ? nil : notices.keys.sorted().map { "\($0): \(notices[$0]!)" }.joined(separator: " · "),
                           discoveredAgents: UsageAggregation.consumersUnion(reports.map(\.discoveredAgents)), consumers: UsageAggregation.consumersUnion(reports.map(\.consumers)),
                           usage: usage.sorted { ($0.start, $0.account ?? "", $0.agentId) < ($1.start, $1.account ?? "", $1.agentId) },
                           indexing: progress.isEmpty ? nil : IndexProgress(done: progress.reduce(0) { $0 + $1.done }, total: progress.reduce(0) { $0 + $1.total }),
                           insightsByAgent: reports.reduce(into: [:]) { $0.merge($1.insightsByAgent, uniquingKeysWith: { _, new in new }) },
                           subscriptions: reports.reduce(into: [:]) { $0.merge($1.subscriptions, uniquingKeysWith: { _, new in new }) }, sourceNotices: notices,
                           consumerIdsByQuota: reports.reduce(into: [:]) { $0.merge($1.consumerIdsByQuota, uniquingKeysWith: { $0.union($1) }) },
                           billing: Self.mergeBilling(reports.flatMap(\.billing)), codexResetCredits: reports.first { $0.codexResetCredits != nil }?.codexResetCredits,
                           codexResetCreditsObservedAt: reports.first { $0.codexResetCredits != nil }?.codexResetCreditsObservedAt,
                           completions: reports.flatMap(\.completions),
                           turns: reports.flatMap(\.turns), services: AgentService.merge(reports.map { $0.services ?? [] }),
                           activeQuotaPoolIDs: reports.compactMap(\.activeQuotaPoolIDs).reduce(into: [String: Set<String>]()) {
                               $0.merge($1, uniquingKeysWith: { $0.union($1) })
                           },
                           accounts: reports.compactMap(\.accounts).reduce(into: [String: [AccountObservation]]()) {
                               $0.merge($1, uniquingKeysWith: +)
                           },
                           forgottenAccountProviders: reports.compactMap(\.forgottenAccountProviders).reduce(nil) { ($0 ?? []).union($1) })
    }
    /// Parse caches and report copies of earlier versions, replaced by the usage ledger.
    static func removeLegacyCaches(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".json") && ["transcripts-cache", "codex-transcripts-", "deepseek-transcripts-"].contains(where: name.hasPrefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func mergeBilling(_ values: [APIBilling]) -> [APIBilling] {
        Dictionary(grouping: values, by: \.id).values.compactMap { observations in
            guard let latest = observations.max(by: { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }) else { return nil }
            // Costs come from the ledger; the newest observation that carries them is the most complete.
            let costs = observations.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                .first { !$0.costs.isEmpty || !$0.sessionCosts.isEmpty } ?? latest
            return APIBilling(vendor: latest.billingPool?.provider ?? latest.vendor, balances: latest.balances, isAvailable: latest.isAvailable,
                updatedAt: latest.updatedAt, costs: costs.costs, sessionCosts: costs.sessionCosts,
                notice: latest.notice, billingPool: latest.billingPool)
        }.sorted { $0.id < $1.id }
    }

}
