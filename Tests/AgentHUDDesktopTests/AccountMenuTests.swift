import AppKit
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class AccountMenuTests: XCTestCase {
    @MainActor
    func testMenuGroupsAccountsAndDistinguishesPendingFromHistoricalReadings() throws {
        _ = NSApplication.shared
        let suite = "AccountMenuTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); L10n.setLanguage(.system) }
        let now = Date()
        let current = ProviderAccount.identified(provider: "Codex", user: "current@example.com", workspace: "a")!
        let old = ProviderAccount.identified(provider: "Codex", user: "old@example.com", workspace: "b")!
        let agents = [current, old].map {
            AgentDescriptor(id: $0.windowID("codex"), vendor: "Codex", model: "Weekly", source: "", enabled: true, account: $0)
        }
        let settings = SettingsStore(defaults: defaults, defaultAgents: agents)
        settings.update { $0.language = .en }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        store.replace(report: UsageReport(generatedAt: now, snapshots: agents.map {
            .init(agentId: $0.id, remainingPct: 0, resetAt: now.addingTimeInterval(-1), updatedAt: now)
        }, sessions: [], discoveredAgents: agents, accounts: ["Codex": [
            .init(account: current, label: "current@example.com", plan: "pro", observedAt: now),
            .init(account: old, label: "old@example.com", plan: "plus", observedAt: now.addingTimeInterval(-3600), isCurrent: false)
        ]]))
        let controller = StatusItemController(store: store, settings: settings)
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(Array(menu.items.prefix(5)).map(\.title), ["Codex", "current@example.com", "Weekly", "old@example.com", "Weekly"])
        XCTAssertTrue(menu.items[1].view?.accessibilityLabel()?.contains("Current account") == true)
        XCTAssertTrue(menu.items[2].view?.accessibilityLabel()?.contains("Pending update") == true)
        XCTAssertTrue(menu.items[3].view?.accessibilityLabel()?.contains("Last read 1h ago") == true)
        XCTAssertTrue(menu.items[4].view?.accessibilityLabel()?.hasSuffix("100% · —") == true)
        XCTAssertNil(store.rows[0].level, "a past deadline cannot show a confirmed exhaustion status")
        let future = UsageReport(generatedAt: now, snapshots: [.init(agentId: agents[0].id, remainingPct: 50,
            resetAt: now.addingTimeInterval(20), updatedAt: now)], sessions: [], discoveredAgents: [agents[0]])
        store.replace(report: future)
        XCTAssertEqual(store.rows[0].resetLabel(now: now), "<1m")
    }
}
