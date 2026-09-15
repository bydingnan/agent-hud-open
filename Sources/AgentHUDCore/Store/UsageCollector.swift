import Foundation

/// A host's extension points in the collection pipeline. Every hook runs on the main actor inside the pass that fetched
/// the report, while no provider reads and nothing writes the usage ledger, so a hook may read the ledger itself.
public struct UsageCollectionHooks {
    /// Hourly buckets providers load, including the current partial hour; asked before every local poll and account step.
    public var historyHours: @MainActor () -> Int
    /// Receives each report the provider returned, before it is displayed. The pass, and so the next pass, waits for it.
    public var publish: (@MainActor (UsageReport) async -> Void)?
    /// Turns the provider's report into the displayed report, for example to add other data. The result must keep the
    /// provider's discovered agents, accounts, active quota pools, completions and turns, which drive the agent list and
    /// the island.
    public var merge: (@MainActor (UsageReport) async -> UsageReport)?

    public init(historyHours: @escaping @MainActor () -> Int = { UsageStore.historyHours },
                publish: (@MainActor (UsageReport) async -> Void)? = nil,
                merge: (@MainActor (UsageReport) async -> UsageReport)? = nil) {
        self.historyHours = historyHours
        self.publish = publish
        self.merge = merge
    }
}

/// The collection pipeline: one local poll or account step at a time, each pass handing its report to the store.
@MainActor
final class UsageCollector {
    weak var store: UsageStore?
    private let provider: any UsageProvider
    private let settings: SettingsStore
    private let hooks: UsageCollectionHooks
    private var pollTask: Task<Void, Never>?
    /// One pass of the pipeline runs at a time; a request during a pass is served by the next one.
    private var isCollecting = false
    /// Account steps left in the current sweep, run one at a time between local polls.
    private var accountSteps: [AccountRefreshStep] = []
    private var accountSweepAt: Date?
    /// Consent to read an account starts a sweep at once instead of at the next interval.
    private var sweptWithCopilotQuota: Bool?
    private var fetchedAt: Date?
    private var fetchedAgents: [AgentDescriptor]?
    /// Something the watched directories cannot show changed: a finished account step, a language switch, a failed poll.
    private var needsFetch = true
    private var changes: FileChangeMonitor?
    /// The provider's last report before the merge hook, numbered so a slower merge never replaces a newer one.
    private var local: (report: UsageReport, generation: Int)?
    private var generation = 0
    private var isMerging = false
    private var mergeRequested = false

    init(provider: any UsageProvider, settings: SettingsStore, hooks: UsageCollectionHooks) {
        self.provider = provider
        self.settings = settings
        self.hooks = hooks
    }

    func start() {
        stop()
        changes = provider.watchedDirectories.map { FileChangeMonitor(directories: $0) }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pause = await self.collect(force: false)
                try? await Task.sleep(for: .seconds(pause))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        changes = nil
        if !accountSteps.isEmpty {
            accountSteps = []
            accountSweepAt = nil
        }
    }

    func refresh() async {
        needsFetch = true
        _ = await collect(force: true)
    }

    /// A report installed directly is not the provider's; merging must not replace it.
    func forgetLocalReport() {
        local = nil
    }

    /// Merges the last provider report again without collecting. A local poll in progress merges for it, or merges again
    /// once it returns when its own merge had already started.
    func remerge() async {
        guard hooks.merge != nil else { return }
        mergeRequested = true
        guard let store, !isMerging, !store.isRefreshing else { return }
        isMerging = true
        defer { isMerging = false }
        while mergeRequested, !store.isRefreshing, let merge = hooks.merge, let local {
            mergeRequested = false
            let merged = await merge(local.report)
            guard local.generation == self.local?.generation, store.isAccessAllowed else { continue }
            store.report = merged
        }
    }

    /// One pass of the collection pipeline: the local poll when it is due, then account steps within their budget.
    /// Returns how long to wait before the next pass.
    private func collect(force: Bool) async -> TimeInterval {
        guard let store, store.isAccessAllowed, !isCollecting else { return UsageRefresh.pollInterval }
        if let pausedUntil = store.pausedUntil, pausedUntil > Date() { return UsageRefresh.pollInterval }
        store.pausedUntil = nil
        isCollecting = true
        defer { isCollecting = false }
        let started = Date()
        let consent = settings.settings.readCopilotQuota
        if accountSteps.isEmpty, sweptWithCopilotQuota != consent
            || accountSweepAt.map({ started.timeIntervalSince($0) >= UsageRefresh.accountInterval }) ?? true {
            accountSweepAt = started
            sweptWithCopilotQuota = consent
            accountSteps = provider.accountRefreshSteps
            // The sweep doubles as the fallback poll and picks up directories created since the last one.
            changes?.update()
            needsFetch = true
        }
        let localInterval = store.isIndexing ? UsageRefresh.indexingInterval : UsageRefresh.pollInterval
        if force || fetchedAt.map({ started.timeIntervalSince($0) >= localInterval }) ?? true {
            if shouldFetch(at: started, report: store.report) {
                await fetch(at: started, into: store)
                if mergeRequested { await remerge() }
            } else if started.timeIntervalSince(store.dataDate) >= 60 {
                store.checkedAt = started
            }
        }
        guard !accountSteps.isEmpty, !Task.isCancelled else { return localInterval }
        let stepsStarted = Date()
        repeat {
            let step = accountSteps.removeFirst()
            await step(hooks.historyHours())
        } while !accountSteps.isEmpty && !Task.isCancelled && Date().timeIntervalSince(stepsStarted) < UsageRefresh.accountStepBudget
        needsFetch = true
        let untilLocal = (fetchedAt ?? .distantPast).addingTimeInterval(localInterval).timeIntervalSinceNow
        return max(0, min(accountSteps.isEmpty ? localInterval : 1, untilLocal))
    }

    /// Polls stay idle while nothing changed and no turn is running.
    private func shouldFetch(at date: Date, report: UsageReport?) -> Bool {
        let changed = changes?.consumeChanges() ?? true
        guard let report, !changed, !needsFetch, report.indexing == nil, fetchedAgents == settings.agents else { return true }
        return report.hasActiveWork(at: date)
    }

    /// The publish and merge hooks run here, before the pass can end.
    private func fetch(at date: Date, into store: UsageStore) async {
        needsFetch = false
        store.isRefreshing = true
        defer { store.isRefreshing = false }
        do {
            let fetched = try await provider.fetchUsage(agents: settings.agents, historyHours: hooks.historyHours())
            await hooks.publish?(fetched)
            mergeRequested = false
            let report = await hooks.merge?(fetched) ?? fetched
            guard store.isAccessAllowed, !Task.isCancelled else { needsFetch = true; return }
            settings.mergeDiscovered(report.discoveredAgents, activeQuotaPoolIDs: report.activeQuotaPoolIDs, accounts: report.accounts)
            generation += 1
            local = (fetched, generation)
            store.collected(report)
            fetchedAt = date
            fetchedAgents = settings.agents
        } catch {
            needsFetch = true
            guard store.isAccessAllowed, !Task.isCancelled else { return }
            fetchedAt = date
            store.lastError = error.localizedDescription
        }
        store.now = Date()
    }
}
