import Foundation
import Observation

/// Persists `Settings`, the ordered agent list and onboarding state in UserDefaults as JSON.
@MainActor
@Observable
public final class SettingsStore {
    public private(set) var settings: Settings
    public private(set) var agents: [AgentDescriptor]
    public private(set) var hasCompletedOnboarding: Bool

    public enum Change { case settings, agents, discovery }
    /// Invoked after preferences are persisted and local state is updated.
    @ObservationIgnored public var onChange: ((Change) -> Void)?

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public enum Keys {
        public static let settings = "settings.v1"
        public static let agents = "agents.v5"
        public static let onboarding = "onboarding.completed.v1"
    }

    public init(defaults: UserDefaults = .standard, defaultAgents: [AgentDescriptor] = DefaultAgents.list) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: Keys.settings), let stored = try? decoder.decode(Settings.self, from: data) {
            settings = stored
        } else {
            settings = Settings()
        }
        if let data = defaults.data(forKey: Keys.agents), let stored = try? decoder.decode([AgentDescriptor].self, from: data), !stored.isEmpty {
            // Only observed subscriptions belong in the agent catalog.
            agents = Self.withKeyEntryPlaceholders(stored.map { agent in
                guard agent.id == "chatgpt", agent.vendor == "ChatGPT", agent.model == "Plus",
                      agent.source == L10n.sourceBrowserAuth else { return agent }
                return AgentDescriptor(id: agent.id, vendor: agent.vendor, model: "ChatGPT", source: agent.source,
                    enabled: agent.enabled, connected: agent.connected, billingPool: agent.billingPool)
            })
        } else {
            agents = defaultAgents.groupedAgentOrder
        }
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
    }

    public var enabledAgents: [AgentDescriptor] { agents.filter(\.enabled) }

    /// Whether any row for this settings/glow group is shown on the HUD.
    public func isVendorDisplayed(_ vendor: String) -> Bool {
        let rows = agents.filter { Self.matchesDisplayVendor($0, vendor) }
        return !rows.isEmpty && rows.contains(where: \.enabled)
    }

    /// Turns every window in a vendor group on or off. Empty key-entry groups get a placeholder so the choice persists.
    public func setVendorDisplayed(_ vendor: String, enabled: Bool) {
        updateAgents { list in
            var list = list
            let indices = list.indices.filter { Self.matchesDisplayVendor(list[$0], vendor) }
            if indices.isEmpty {
                guard enabled, let placeholder = DefaultAgents.keyEntryPlaceholder(for: vendor)
                    ?? (vendor == "ZenMux"
                        ? AgentDescriptor(id: "zenmux", vendor: "ZenMux", model: L10n.text("订阅", "Plan"),
                                          source: L10n.sourceNotConnected, enabled: true, connected: false)
                        : nil) else { return list }
                list.insert(placeholder.with(enabled: true), at: 0)
                return list
            }
            for index in indices {
                list[index] = list[index].with(enabled: enabled)
            }
            return list
        }
    }

    /// OpenCode Go quota windows share the OpenCode settings/glow group.
    public static func matchesDisplayVendor(_ agent: AgentDescriptor, _ vendor: String) -> Bool {
        agent.displayVendor == vendor
    }

    /// Ensures OpenCode / Kimi / GLM placeholders exist so Settings can show a display switch before windows arrive.
    public static func withKeyEntryPlaceholders(_ agents: [AgentDescriptor]) -> [AgentDescriptor] {
        var list = agents
        for placeholder in DefaultAgents.keyEntryPlaceholders {
            let covered = list.contains { matchesDisplayVendor($0, placeholder.vendor) }
            if !covered { list.append(placeholder) }
        }
        return list.groupedAgentOrder
    }

    public func update(_ change: (inout Settings) -> Void) {
        let next = settings.with(change)
        guard next != settings else { return }
        // Views can render as soon as settings change; translations must already match.
        if next.language != settings.language {
            L10n.setLanguage(next.language)
        }
        settings = next
        persist(next, key: Keys.settings)
        onChange?(.settings)
    }

    public func updateAgents(_ transform: ([AgentDescriptor]) -> [AgentDescriptor]) {
        saveAgents(transform(agents), change: .agents)
    }

    private func saveAgents(_ list: [AgentDescriptor], change: Change) {
        // Quota discovery can retire every pool row for a vendor; put the Settings key-entry
        // placeholders back so Kimi / GLM / OpenCode never disappear from Agents.
        let next = Self.withKeyEntryPlaceholders(list)
        guard next != agents else { return }
        agents = next
        persist(next, key: Keys.agents)
        onChange?(change)
    }

    public func setAgent(id: String, enabled: Bool) {
        updateAgents { list in list.map { $0.id == id ? $0.with(enabled: enabled) : $0 } }
    }

    /// Applies a vendor preset without removing discovered rows or replacing any other preference.
    public func enableOnlyVendors(_ vendors: Set<String>) {
        updateAgents { list in
            list.map { $0.with(enabled: vendors.contains($0.displayVendor)) }
        }
    }

    public func moveAgent(id: String, to index: Int) {
        updateAgents { $0.moving(id: id, to: index) }
    }

    public func moveAgentGroup(id: String, to targetID: String) {
        updateAgents { $0.movingGroup(id: id, to: targetID) }
    }

    /// Adds rows a provider discovered (in the order given) and refreshes model names of known rows.
    /// New rows for a vendor go right after that vendor's last existing row, or at the top when the vendor is new,
    /// so the user's manual order is preserved.
    /// Account rows: the first identified account takes over an unscoped row's position and switch, a further account's
    /// window inherits the switch of the same window on another account, and rows of accounts absent from a provider's
    /// inventory are removed.
    /// Full retained reports can retire Codex windows; incremental discovery keeps existing preferences.
    public func mergeDiscovered(_ discovered: [AgentDescriptor], activeQuotaPoolIDs: [String: Set<String>]? = nil,
                                accounts: [String: [AccountObservation]]? = nil, replaceQuotaWindows: Bool = false) {
        guard !discovered.isEmpty || activeQuotaPoolIDs != nil || accounts != nil else { return }
        let merged: [AgentDescriptor] = {
            var list = agents.filter { agent in
                if let account = agent.account, agent.billingPool == nil, let known = accounts?[account.provider] {
                    if replaceQuotaWindows, account.provider == "Codex", known.contains(where: { $0.account.id == account.id && $0.isCurrent && $0.quotaNotice == nil }) {
                        return discovered.contains { $0.id == agent.id }
                    }
                    return known.contains { $0.account.id == account.id }
                }
                guard let pool = agent.billingPool, pool.product == .plan,
                      let active = activeQuotaPoolIDs?[pool.provider] else { return true }
                return active.contains(pool.id)
            }
            for found in discovered where found.account != nil && found.billingPool == nil && !list.contains(where: { $0.id == found.id }) {
                if let index = list.firstIndex(where: { $0.account == nil && $0.billingPool == nil && $0.vendor == found.vendor && $0.id == found.windowKey }) {
                    let unscoped = list.remove(at: index)
                    list.insert(found.with(enabled: unscoped.enabled), at: index)
                } else if let sibling = list.last(where: { $0.vendor == found.vendor && $0.account != nil && $0.windowKey == found.windowKey }) {
                    let anchor = list.lastIndex { $0.vendor == found.vendor }
                    list.insert(found.with(enabled: sibling.enabled), at: anchor.map { $0 + 1 } ?? 0)
                }
            }
            if discovered.contains(where: { $0.vendor == "DeepSeek" && $0.id.hasPrefix("deepseek-model:") }),
               let index = list.firstIndex(where: { $0.id == "deepseek" }) {
                let placeholder = list.remove(at: index)
                let replacements = discovered.filter { found in found.vendor == "DeepSeek" && !list.contains(where: { $0.id == found.id }) }
                    .map { $0.with(enabled: placeholder.enabled) }
                list.insert(contentsOf: replacements, at: index)
            }
            // Replace the old disconnected Antigravity placeholder when real quota buckets arrive.
            if discovered.contains(where: { $0.vendor == "Antigravity" && $0.windowKey.hasPrefix("antigravity:") }),
               let index = list.firstIndex(where: { $0.id == "antigravity" && $0.source == L10n.sourceNotConnected }) {
                let placeholder = list.remove(at: index)
                let replacements = discovered.filter { found in found.vendor == "Antigravity" && !list.contains(where: { $0.id == found.id }) }.map {
                    $0.with(enabled: placeholder.enabled)
                }
                list.insert(contentsOf: replacements, at: index)
            }
            // Replace the ZenMux API placeholder when 5h / 7d subscription windows arrive.
            if discovered.contains(where: { $0.vendor == "ZenMux" && $0.id.hasPrefix("zenmux:") }),
               let index = list.firstIndex(where: { $0.id == "zenmux" }) {
                let placeholder = list.remove(at: index)
                let replacements = discovered.filter { found in found.vendor == "ZenMux" && !list.contains(where: { $0.id == found.id }) }.map {
                    $0.with(enabled: placeholder.enabled)
                }
                list.insert(contentsOf: replacements, at: index)
            }
            // Replace OpenCode / Kimi / GLM plan placeholders when real windows arrive.
            for placeholder in DefaultAgents.keyEntryPlaceholders {
                let arrivals = discovered.filter { found in
                    found.billingPool?.product == .plan && found.displayVendor == placeholder.vendor
                        && !list.contains(where: { row in row.id == found.id })
                }
                guard !arrivals.isEmpty, let index = list.firstIndex(where: { $0.id == placeholder.id }) else { continue }
                let existing = list.remove(at: index)
                // A not-connected placeholder has never been shown; turn the real windows on so pasting
                // a key immediately surfaces quota. An explicit Show preference is kept.
                let enabled = existing.source == L10n.sourceNotConnected ? true : existing.enabled
                list.insert(contentsOf: arrivals.map { $0.with(enabled: enabled) }, at: index)
            }
            // Unscoped rows of a provider that now identifies accounts have been taken over or no longer exist.
            list.removeAll { agent in
                agent.account == nil && agent.billingPool == nil && accounts?[agent.vendor]?.isEmpty == false
                    && !discovered.contains { $0.id == agent.id }
            }
            for found in discovered {
                if let index = list.firstIndex(where: { $0.id == found.id }) {
                    let existing = list[index]
                    if existing.model != found.model || existing.source != found.source || existing.connected != found.connected
                        || existing.billingPool != found.billingPool || existing.account != found.account {
                        list[index] = AgentDescriptor(
                            id: existing.id, vendor: existing.vendor, model: found.model, source: found.source,
                            enabled: existing.enabled, connected: found.connected, billingPool: found.billingPool, account: found.account
                        )
                    }
                    continue
                }
                let anchor = list.lastIndex { $0.displayVendor == found.displayVendor }
                let keyEntry = DefaultAgents.keyEntryPlaceholder(for: found.displayVendor) != nil
                let enabled = anchor.map { list[$0].enabled } ?? (
                    PreferredVendors.personal.contains(found.displayVendor)
                        || PreferredVendors.personal.contains(found.vendor)
                        || keyEntry
                )
                list.insert(found.with(enabled: enabled), at: anchor.map { $0 + 1 } ?? 0)
            }
            return list
        }()
        saveAgents(merged, change: .discovery)
    }

    public func markOnboardingComplete() {
        hasCompletedOnboarding = true
        defaults.set(true, forKey: Keys.onboarding)
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
