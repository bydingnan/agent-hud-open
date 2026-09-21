import Foundation

/// Joins observed account information to the existing ordered display windows.
public struct AgentSettingsGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: SourceStatus?
    public let agents: [AgentDescriptor]
    public let plans: [String]
    public let apiProviders: [String]
    /// Accounts the client has been signed in to, current first; pool accounts appear through `plans`.
    public let accounts: [AccountObservation]

    public var displayedCount: Int { agents.filter(\.enabled).count }
    public var hasLiveStatus: Bool { SessionSource.agentVendors.contains(id) }

    public static func make(sources: [SourceStatus], agents: [AgentDescriptor], report: UsageReport? = nil) -> [Self] {
        let agents = agents.filter { agent in
            guard let pool = agent.billingPool, pool.product == .plan,
                  let active = report?.activeQuotaPoolIDs?[pool.provider] else { return true }
            return active.contains(pool.id)
        }
        func vendor(_ source: SourceStatus) -> String {
            source.id == "chatgpt" ? "ChatGPT" : source.name
        }
        /// OpenCode Go plan rows share the OpenCode settings card (key + login guide).
        func groupID(_ raw: String) -> String { raw == "OpenCode Go" ? "OpenCode" : raw }
        let existing = agents.agentGroups
        var ids = existing.map(\.id)
        for raw in sources.map(vendor) + agents.map(\.vendor) + (report?.services ?? []).map(\.client) {
            let id = groupID(raw)
            if !ids.contains(id) { ids.append(id) }
        }
        // Always list vendors that need a Settings key or login guide, even before they are installed.
        for id in ["OpenCode", "Kimi", "GLM"] where !ids.contains(id) { ids.append(id) }
        // Keep key-entry vendors near the top so distribution installs can find them without scrolling.
        let pinned = ["ZenMux", "OpenCode", "Kimi", "GLM"]
        ids = pinned.filter(ids.contains) + ids.filter { !pinned.contains($0) }
        return ids.map { id in
            let source = sources.first { vendor($0) == id }
            let windows = existing.first { $0.id == id }?.agents ?? []
            let services = (report?.services ?? []).filter { groupID($0.client) == id }
            // Observations retain client-home history; display one summary per account, as quota rows do.
            var accountRows = report?.accounts?[id] ?? []
            if id == "OpenCode" { accountRows += report?.accounts?["OpenCode Go"] ?? [] }
            let accountIDs = Set(accountRows.map(\.account.id))
            let accounts = accountIDs.compactMap { report?.observation(accountID: $0) }
                .filter { !$0.account.id.hasPrefix("pool:") }
                .sorted { ($0.isCurrent ? 1 : 0, $0.observedAt) > ($1.isCurrent ? 1 : 0, $1.observedAt) }
            var plans = accounts.isEmpty ? source?.planLabel.map { [$0] } ?? [] : []
            for service in services where service.product == .plan {
                guard let plan = report?.subscriptions[service.accountID ?? service.provider], !plan.isEmpty else { continue }
                let label = groupID(service.provider) == id ? plan.capitalized : service.provider + " · " + plan.capitalized
                plans.append(label)
            }
            for window in windows {
                guard let pool = window.billingPool, pool.product == .plan,
                      let plan = report?.subscriptions[pool.id], !plan.isEmpty else { continue }
                plans.append(plan.capitalized)
            }
            var api = services.filter { $0.product == .api }.map(\.provider)
            api += agents.filter { groupID($0.vendor) == id && $0.billingPool?.product == .api }.compactMap { $0.billingPool?.provider }
            api += windows.compactMap { $0.billingPool?.product == .api ? $0.billingPool?.provider : nil }
            api += (report?.billing ?? []).filter {
                groupID($0.billingPool?.provider ?? $0.vendor) == id && !$0.balances.isEmpty
            }.map { $0.billingPool?.provider ?? $0.vendor }
            return Self(id: id, source: source, agents: windows, plans: Array(Set(plans)).sorted(),
                        apiProviders: Array(Set(api)).sorted(), accounts: accounts)
        }
    }

    /// Rows name their account once a client has been signed in to more than one.
    public func accountName(for agent: AgentDescriptor) -> String? {
        guard accounts.count > 1, let id = agent.account?.id else { return nil }
        return accounts.first { $0.account.id == id }?.displayName
    }
}
