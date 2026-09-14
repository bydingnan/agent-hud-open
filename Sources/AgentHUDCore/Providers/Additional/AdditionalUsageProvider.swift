import AgentHUDSupport
import Foundation

actor AdditionalUsageProvider: UsageProvider {
    let source: AdditionalSource
    private let readQuota: @Sendable () async throws -> ProviderQuota
    private let readSessions: @Sendable (Date) async -> ProviderSessions
    private let refreshSessions: @Sendable (Int) async -> Void
    private let readCompletions: @Sendable (Date) throws -> [SessionCompletion]
    private let history: QuotaHistoryStore
    private let clock: @Sendable () -> Date
    /// A change of this value (such as a consent toggle) refreshes quota without waiting for the interval.
    private let quotaKey: @Sendable () -> String
    private var lastQuota: (at: Date, key: String, result: Result<ProviderQuota, UsageProviderError>)?

    init(source: AdditionalSource, readQuota: @escaping @Sendable () async throws -> ProviderQuota,
         readSessions: @escaping @Sendable (Date) async -> ProviderSessions,
         history: QuotaHistoryStore,
         readCompletions: @escaping @Sendable (Date) throws -> [SessionCompletion] = { _ in [] },
         clock: @escaping @Sendable () -> Date = { Date() },
         quotaKey: @escaping @Sendable () -> String = { "" },
         refreshSessions: @escaping @Sendable (Int) async -> Void = { _ in }) {
        self.source = source; self.readQuota = readQuota; self.readSessions = readSessions
        self.readCompletions = readCompletions
        self.refreshSessions = refreshSessions
        self.history = history; self.clock = clock; self.quotaKey = quotaKey
    }

    static func standard(_ source: AdditionalSource, persistHistory: Bool = true) -> AdditionalUsageProvider {
        let local = AdditionalLocalStore(source: source)
        let cursor = CursorClient()
        return AdditionalUsageProvider(source: source, readQuota: {
            switch source {
            case .antigravity: return try await AntigravityClient().fetch()
            case .cursor: return try await cursor.quota()
            case .grok: return try await GrokClient().fetch()
            case .copilot: return try await CopilotClient().fetch()
            case .openclaw, .hermes, .zcode, .codebuddy, .workbuddy: return ProviderQuota()
            }
        }, readSessions: { since in
            if source == .cursor { return await cursor.savedSessions }
            return await local.index(since: since)
        }, history: QuotaHistoryStore(fileURL: persistHistory ? AppSupport.directory.appendingPathComponent("\(source.rawValue)-quota-history.json") : nil),
        readCompletions: { since in
            guard let hook = CompletionHooks.Source(rawValue: source.rawValue) else { return [] }
            return try CompletionHooks.read(source: hook, since: since)
        }, quotaKey: { source == .copilot ? String(CopilotClient.consented()) : "" }, refreshSessions: { hours in
            if source == .cursor {
                _ = await cursor.sessions(since: Date().addingTimeInterval(-Double(max(168, hours)) * 3600))
            }
        })
    }

    func refreshAccountUsage(historyHours: Int) async {
        async let sessions: Void = refreshSessions(historyHours)
        let now = clock(), key = quotaKey()
        if lastQuota == nil || lastQuota!.key != key || now.timeIntervalSince(lastQuota!.at) >= 120 {
            do {
                let result = try await readQuota()
                try Task.checkCancellation()
                lastQuota = (now, key, .success(result))
                if result.forgetAccounts { await history.removeAll() }
                await history.append(result.scopedWindows(source).map { .init(agentId: $0.id, timestamp: now, remainingPct: $0.remaining) }, now: now)
            } catch {
                if Task.isCancelled { return }
                lastQuota = (now, key, .failure(UsageProviderError(error.localizedDescription)))
            }
        }
        await sessions
    }

    func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport {
        let now = clock(), weekAgo = now.addingTimeInterval(-7 * 86400)
        let since = min(weekAgo, now.addingTimeInterval(-Double(historyHours) * 3600))
        var local = await readSessions(since)
        var hookCompletions: [SessionCompletion] = [], hookNotice: String?
        do { hookCompletions = try readCompletions(since) }
        catch { hookNotice = L10n.text("完成提醒记录读取失败", "Turn completion records could not be read") }
        // A stop hook finishes the running turn it follows when the client's own log records no end.
        let finished = Dictionary(hookCompletions.map { ($0.sessionID, RecordCoding.milliseconds($0.completedAt)) }, uniquingKeysWith: max)
        for index in local.sessions.indices {
            guard let done = finished[local.sessions[index].id] else { continue }
            local.sessions[index].turns = local.sessions[index].turns.map { turn in
                guard turn.state == .running, done >= turn.observedAtMs else { return turn }
                return SessionTurn(provider: turn.provider, sessionID: turn.sessionID, turnID: turn.turnID, state: .completed,
                                   startedAtMs: turn.startedAtMs, observedAtMs: done)
            }
        }
        let quota: ProviderQuota, quotaNotice: String?
        let observedAt = lastQuota?.at ?? now
        switch lastQuota?.result {
        case .success(let value): (quota, quotaNotice) = (value, value.notice)
        case .failure(let error): (quota, quotaNotice) = (ProviderQuota(), error.message)
        case nil: (quota, quotaNotice) = (ProviderQuota(), nil)
        }
        let account = quota.resolvedAccount(source)
        let windows = quota.scopedWindows(source)
        let allEvents = local.sessions.flatMap(\.events)
        let events = allEvents.filter { $0.timestamp >= since && $0.timestamp <= now }.map { $0.usage(source: source) }
        let consumers = Set(allEvents.map(\.model)).sorted().map {
            AgentDescriptor(id: "\(source.rawValue)-model:\($0)", vendor: source.vendor, model: $0,
                            source: L10n.sourceAdditionalUsage, enabled: true)
        }
        let sessions = local.sessions.compactMap { item -> LiveSession? in
            guard let start = item.startedAt ?? item.events.map(\.timestamp).min(),
                  let end = item.lastActivity ?? item.events.map(\.timestamp).max(), end >= since else { return nil }
            let model = item.events.max { $0.timestamp < $1.timestamp }?.model ?? "Unknown"
            let turn = item.turns.max { $0.observedAtMs < $1.observedAtMs }
            let isRunning = turn.map { $0.state == .running && now.timeIntervalSince1970 - Double($0.observedAtMs) / 1000 < 120 } ?? false
            return LiveSession(id: item.id, agentId: "\(source.rawValue)-model:\(model)", task: item.title,
                               terminal: item.workspace.map { URL(fileURLWithPath: $0).lastPathComponent },
                               startedAt: start, endedAt: isRunning ? nil : end, pctOfWindow: nil,
                               tokensIn: item.events.reduce(0) { $0 + $1.input }, tokensOut: item.events.reduce(0) { $0 + $1.output },
                               client: item.client, transcriptPath: item.path,
                               cacheReadTokens: item.events.reduce(0) { $0 + $1.cacheRead }, accountWide: item.accountWide, observedAt: now)
        }
        let snapshots = windows.map {
            UsageSnapshot(agentId: $0.id, remainingPct: $0.remaining, resetAt: $0.reset, windowDuration: $0.duration, updatedAt: observedAt)
        }
        var samples: [HistorySample] = [], insights: [String: UsageInsights] = [:]
        for snapshot in snapshots {
            let readings = await history.samples(agentId: snapshot.agentId, since: min(since, snapshot.cycle?.start ?? since))
            if let first = readings.first {
                samples += UsageAnalytics.hourlyHistory(agentId: snapshot.agentId, quota: readings, usage: [],
                    hours: min(historyHours, max(1, Int(now.timeIntervalSince(first.timestamp) / 3600) + 1)),
                    now: now, calendar: .current, fallbackRemaining: nil)
            }
            let burn = UsageAnalytics.burnRate(samples: readings, cycle: snapshot.cycle, now: now)
            let caps = UsageAnalytics.capStats(samples: readings.filter { $0.timestamp >= weekAgo }, now: now)
            insights[snapshot.agentId] = UsageInsights(burnRatePctPerHour: burn?.pctPerHour,
                timeToExhaust: burn?.timeToExhaust(remainingPct: snapshot.remainingPct), weeklyCapHits: caps.hits,
                weeklyWaitTotal: caps.totalWait, weeklyWaitLongest: caps.longestWait, weeklyWaitLongestAt: caps.longestAt,
                weeklyShare: [:], windowSessionCount: sessions.count, windowUsedPct: 100 - snapshot.remainingPct)
        }
        let notice = [quotaNotice, local.notice, hookNotice].compactMap { $0 }.joined(separator: " · ")
        let descriptors = windows.map {
            AgentDescriptor(id: $0.id, vendor: source.vendor, model: $0.label, source: L10n.sourceAdditionalUsage, enabled: true, account: account)
        }
        let consumerIDs = Set(consumers.map(\.id))
        let quotaIDs = Set(windows.map(\.id) + agents.filter { $0.vendor == source.vendor }.map(\.id))
        return UsageReport(generatedAt: now, snapshots: snapshots, sessions: sessions, history: samples,
            activity: UsageAnalytics.activityGrid(usage: events, since: weekAgo, calendar: .current), insights: .empty,
            notice: notice.isEmpty ? nil : notice, discoveredAgents: descriptors, consumers: consumers, consumption: events,
            indexing: local.indexing, insightsByAgent: insights, subscriptions: quota.plan.map { [source.vendor: $0] } ?? [:],
            sourceNotices: notice.isEmpty ? [:] : [source.vendor: notice],
            consumerIdsByQuota: Dictionary(uniqueKeysWithValues: quotaIDs.map { ($0, consumerIDs) }),
            completions: local.sessions.flatMap(\.completions) + hookCompletions, turns: local.sessions.flatMap(\.turns),
            accounts: quota.isSignedIn ? [source.vendor: [AccountObservation(account: account, label: quota.label, plan: quota.plan, observedAt: observedAt)]] : nil,
            forgottenAccountProviders: quota.forgetAccounts ? [source.vendor] : nil)
    }
}
