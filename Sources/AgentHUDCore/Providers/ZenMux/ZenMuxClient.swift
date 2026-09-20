import Foundation

struct ZenMuxClient: Sendable {
    var http = ProviderHTTP()
    var key: @Sendable () -> String? = { ZenMuxCredentials.managementKey() }

    func fetchSubscription(now: Date = Date()) async throws -> ProviderQuota {
        guard let token = key(), !token.isEmpty else {
            throw UsageProviderError(L10n.text(
                "请设置 ZENMUX_MANAGEMENT_API_KEY 后刷新额度",
                "Set ZENMUX_MANAGEMENT_API_KEY, then refresh quota"))
        }
        let url = URL(string: "https://zenmux.ai/api/v1/management/subscription/detail")!
        let json = try await http.json(url, headers: ["Authorization": "Bearer \(token)"])
        return try Self.parseSubscription(json, now: now)
    }

    static func parseSubscription(_ root: ProviderJSON, now: Date) throws -> ProviderQuota {
        guard root["success"].boolValue == true, root["data"].objectValue != nil else {
            throw ProviderFailure.format
        }
        let data = root["data"]
        var quota = ProviderQuota()
        quota.plan = data["plan"]["tier"].stringValue
        func window(key: String, id: String, label: String, duration: TimeInterval) throws {
            let node = data[key]
            guard node.objectValue != nil,
                  let used = node["usage_percentage"].numberValue, used.isFinite, used >= 0 else {
                throw ProviderFailure.format
            }
            let remaining = max(0, (1 - used) * 100)
            quota.windows.append(.init(
                id: id, label: label, remaining: remaining,
                reset: ProviderDate.iso(node["resets_at"].stringValue), duration: duration))
        }
        try window(key: "quota_5_hour", id: "zenmux:5h",
                   label: L10n.text("5 小时", "5h"), duration: 5 * 3600)
        try window(key: "quota_7_day", id: "zenmux:7d",
                   label: L10n.text("7 天", "7d"), duration: 7 * 86400)
        if let maxFlows = data["quota_monthly"]["max_flows"].numberValue {
            quota.notice = L10n.text(
                "月度上限 \(Int(maxFlows)) Flows（无实时已用量）",
                "Monthly cap \(Int(maxFlows)) Flows (no live used amount)")
        }
        guard !quota.windows.isEmpty else { throw ProviderFailure.format }
        return quota
    }
}
