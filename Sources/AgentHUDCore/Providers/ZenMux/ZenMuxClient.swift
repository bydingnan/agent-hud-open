import Foundation

struct ZenMuxClient: Sendable {
    var http = ProviderHTTP()
    var key: @Sendable () -> String? = { ZenMuxCredentials.managementKey() }

    func fetchUsageHistory(days: Int, now: Date) async throws -> [UsageBucket] {
        let token = try managementToken()
        let interval = Self.historyInterval(days: days, now: now)
        guard interval.start < interval.end else { return [] }
        var buckets: [UsageBucket] = []
        for month in Self.months(overlapping: interval) {
            let json = try await historyJSON(path: "usage", type: "usage", month: month, token: token)
            buckets += try Self.parseUsageTokensByType(json, agentId: "zenmux", account: nil)
                .filter { Calendar.current.isDate($0.start, equalTo: month, toGranularity: .month) }
        }
        return buckets.filter { $0.start >= interval.start && $0.start < interval.end }.sorted { $0.start < $1.start }
    }

    func fetchCostHistory(days: Int, now: Date) async throws -> [CostBucket] {
        let token = try managementToken()
        let interval = Self.historyInterval(days: days, now: now)
        guard interval.start < interval.end else { return [] }
        var buckets: [CostBucket] = []
        for month in Self.months(overlapping: interval) {
            let json = try await historyJSON(path: "cost", type: "cost", month: month, token: token)
            buckets += try Self.parseCostsByModel(json)
                .filter { Calendar.current.isDate($0.start, equalTo: month, toGranularity: .month) }
        }
        return buckets.filter { $0.start >= interval.start && $0.start < interval.end }.sorted { $0.start < $1.start }
    }

    func fetchSubscription(now: Date = Date()) async throws -> ProviderQuota {
        let token = try managementToken()
        let url = URL(string: "https://zenmux.ai/api/v1/management/subscription/detail")!
        let json = try await http.json(url, headers: ["Authorization": "Bearer \(token)"])
        return try Self.parseSubscription(json, now: now)
    }

    static func parseUsageTokensByType(
        _ root: ProviderJSON,
        agentId: String,
        account: String?
    ) throws -> [UsageBucket] {
        guard root["success"].boolValue == true,
              root["data"].objectValue != nil,
              let entries = root["data"]["tokensByTokenType"].arrayValue else {
            throw ProviderFailure.format
        }
        var totals: [Date: (input: Int, output: Int)] = [:]
        for entry in entries {
            guard let start = day(entry["bizTime"].stringValue),
                  let type = entry["tokenType"].stringValue else {
                throw ProviderFailure.format
            }
            guard entry["tokens"] != .null else { continue }
            guard let text = entry["tokens"].stringValue, let tokens = Int(text), tokens >= 0 else {
                throw ProviderFailure.format
            }
            var total = totals[start] ?? (0, 0)
            switch type {
            case "prompt":
                let (value, overflow) = total.input.addingReportingOverflow(tokens)
                guard !overflow else { throw ProviderFailure.format }
                total.input = value
            case "completion":
                let (value, overflow) = total.output.addingReportingOverflow(tokens)
                guard !overflow else { throw ProviderFailure.format }
                total.output = value
            default:
                continue
            }
            totals[start] = total
        }
        return totals.map {
            UsageBucket(start: $0.key, agentId: agentId, tokensIn: $0.value.input,
                        tokensOut: $0.value.output, account: account)
        }.sorted { $0.start < $1.start }
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
                   label: Countdown.windowPeriod(5 * 3600), duration: 5 * 3600)
        try window(key: "quota_7_day", id: "zenmux:7d",
                   label: Countdown.windowPeriod(7 * 86400), duration: 7 * 86400)
        guard !quota.windows.isEmpty else { throw ProviderFailure.format }
        return quota
    }

    private func managementToken() throws -> String {
        guard let token = key(), !token.isEmpty else {
            throw UsageProviderError(L10n.text(
                "请设置 ZENMUX_MANAGEMENT_API_KEY 后刷新额度",
                "Set ZENMUX_MANAGEMENT_API_KEY, then refresh quota"))
        }
        return token
    }

    private func historyJSON(path: String, type: String, month: Date, token: String) async throws -> ProviderJSON {
        var components = URLComponents(string: "https://zenmux.ai/api/v1/management/\(path)")!
        components.queryItems = [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "query_dimension", value: "BIZ_MTH"),
            URLQueryItem(name: "query_time", value: Self.monthText(month)),
        ]
        return try await http.json(components.url!, headers: ["Authorization": "Bearer \(token)"])
    }

    private static func parseCostsByModel(_ root: ProviderJSON) throws -> [CostBucket] {
        guard root["success"].boolValue == true,
              root["data"].objectValue != nil,
              root["data"]["analysis"].objectValue != nil,
              let entries = root["data"]["analysis"]["costByModel"].arrayValue else {
            throw ProviderFailure.format
        }
        var totals: [Date: Decimal] = [:]
        var incomplete: Set<Date> = []
        for entry in entries {
            guard let start = day(entry["bizTime"].stringValue) else { throw ProviderFailure.format }
            guard entry["billAmount"] != .null else {
                incomplete.insert(start)
                continue
            }
            guard let text = entry["billAmount"].stringValue,
                  let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
                  amount >= 0 else {
                throw ProviderFailure.format
            }
            totals[start, default: 0] += amount
        }
        return Set(totals.keys).union(incomplete).map { start in
            CostBucket(start: start, amounts: incomplete.contains(start) ? [:] : ["usd": totals[start, default: 0]])
        }.sorted { $0.start < $1.start }
    }

    private static func day(_ text: String?) -> Date? {
        guard let text, text.count == 8 else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        formatter.isLenient = false
        return formatter.date(from: text).map { Calendar.current.startOfDay(for: $0) }
    }

    private static func historyInterval(days: Int, now: Date) -> DateInterval {
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        guard days > 0 else { return DateInterval(start: end, end: end) }
        let start = calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: now))!
        return DateInterval(start: start, end: end)
    }

    private static func months(overlapping interval: DateInterval) -> [Date] {
        let calendar = Calendar.current
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: interval.start))!
        var result: [Date] = []
        var month = first
        while month < interval.end {
            result.append(month)
            month = calendar.date(byAdding: .month, value: 1, to: month)!
        }
        return result
    }

    private static func monthText(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d%02d", components.year!, components.month!)
    }
}
