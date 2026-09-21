import Foundation
import XCTest
@testable import AgentHUDCore

final class ZenMuxProviderTests: XCTestCase, @unchecked Sendable {
    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URLRequest] = []
        var values: [URLRequest] { lock.withLock { storage } }
        func record(_ request: URLRequest) { lock.withLock { storage.append(request) } }
    }

    func testManagementKeyPrefersOfficialEnvNamesAndIgnoresInferenceKey() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("ZENMUX_MGMT_API_KEY=from-file\n".utf8)
            .write(to: home.appendingPathComponent(".config/api-tokens.env"))

        XCTAssertEqual(
            ZenMuxCredentials.managementKey(environment: [
                "ZENMUX_API_KEY": "inference-only",
                "ZENMUX_MGMT_API_KEY": "mgmt-b",
                "ZENMUX_MANAGEMENT_API_KEY": "mgmt-a",
            ], home: home, saved: nil),
            "mgmt-a"
        )
        XCTAssertEqual(
            ZenMuxCredentials.managementKey(environment: ["ZENMUX_API_KEY": "inference-only"], home: home, saved: nil),
            "from-file"
        )
        XCTAssertEqual(
            ZenMuxCredentials.managementKey(environment: ["ZENMUX_MANAGEMENT_API_KEY": "from-env"], home: home, saved: "from-settings"),
            "from-settings"
        )
        try Data("export ZENMUX_MANAGEMENT_API_KEY=\"from-export\"\n".utf8)
            .write(to: home.appendingPathComponent(".config/api-tokens.env"))
        XCTAssertEqual(
            ZenMuxCredentials.managementKey(environment: [:], home: home, saved: nil),
            "from-export"
        )
        XCTAssertNil(ZenMuxCredentials.managementKey(environment: ["ZENMUX_API_KEY": "inference-only"], home: home.appendingPathComponent("empty"), saved: nil))
    }

    func testParseSubscriptionMapsFlowsWindowsAndSkipsMonthlyUsed() throws {
        let root = try ProviderJSON.read(Data(#"""
        {"success":true,"data":{
          "plan":{"tier":"ultra","amount_usd":200,"interval":"month","expires_at":"2026-04-12T08:26:56.000Z"},
          "account_status":"healthy",
          "quota_5_hour":{"usage_percentage":0.0715,"resets_at":"2026-03-24T08:35:09.000Z",
            "max_flows":800,"used_flows":57.2,"remaining_flows":742.8,"used_value_usd":1.88,"max_value_usd":26.27},
          "quota_7_day":{"usage_percentage":0.0673,"resets_at":"2026-03-26T02:15:05.000Z",
            "max_flows":6182,"used_flows":416.11,"remaining_flows":5765.89,"used_value_usd":13.66,"max_value_usd":202.99},
          "quota_monthly":{"max_flows":34560,"max_value_usd":1134.33}
        }}
        """#.utf8))
        let quota = try ZenMuxClient.parseSubscription(root, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(quota.plan, "ultra")
        XCTAssertEqual(Set(quota.windows.map(\.id)), ["zenmux:5h", "zenmux:7d"])
        let five = quota.windows.first { $0.id == "zenmux:5h" }!
        XCTAssertEqual(five.remaining, 92.85, accuracy: 0.01)
        XCTAssertEqual(five.duration, 5 * 3600)
        XCTAssertFalse(quota.windows.contains { $0.id.contains("month") })
        XCTAssertNil(quota.notice, "healthy monthly-cap metadata is not an alert")
    }

    func testParseSubscriptionRejectsMissingSuccess() throws {
        let root = try ProviderJSON.read(Data(#"{"success":false}"#.utf8))
        XCTAssertThrowsError(try ZenMuxClient.parseSubscription(root, now: Date()))
    }

    func testParseUsageTokensByTypeBuildsDailyBuckets() throws {
        let root = try ProviderJSON.read(Data(#"""
        {"success":true,"data":{
          "tokensByTokenType":[
            {"bizTime":"20260903","tokenType":"prompt","tokens":"1000","requestCounts":null},
            {"bizTime":"20260903","tokenType":"completion","tokens":"250","requestCounts":null},
            {"bizTime":"20260904","tokenType":"prompt","tokens":"10","requestCounts":null}
          ]
        }}
        """#.utf8))
        let buckets = try ZenMuxClient.parseUsageTokensByType(root, agentId: "zenmux", account: "pool:test")
        XCTAssertEqual(buckets.count, 2)
        let day = try XCTUnwrap(buckets.first { Calendar.current.component(.day, from: $0.start) == 3 })
        XCTAssertEqual(day.start, Calendar.current.startOfDay(for: day.start))
        XCTAssertEqual(day.start.timeIntervalSince1970.truncatingRemainder(dividingBy: UsageBucket.duration), 0)
        XCTAssertEqual(day.tokensIn, 1000)
        XCTAssertEqual(day.tokensOut, 250)
        XCTAssertEqual(day.agentId, "zenmux")
        XCTAssertEqual(day.account, "pool:test")
    }

    func testFetchUsageHistoryUsesOneMonthlyRequestPerMonthAndFiltersDays() async throws {
        let requests = Requests()
        let response = Data(#"""
        {"success":true,"data":{"tokensByTokenType":[
          {"bizTime":"20260830","tokenType":"prompt","tokens":"1"},
          {"bizTime":"20260831","tokenType":"prompt","tokens":"2"},
          {"bizTime":"20260901","tokenType":"completion","tokens":"3"},
          {"bizTime":"20260903","tokenType":"prompt","tokens":"4"}
        ]}}
        """#.utf8)
        let client = ZenMuxClient(http: ProviderHTTP(send: {
            requests.record($0)
            return response
        }), key: { "secret" })
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12)))

        let buckets = try await client.fetchUsageHistory(days: 3, now: now)

        XCTAssertEqual(buckets.map(\.total), [2, 3])
        XCTAssertEqual(requests.values.count, 2)
        XCTAssertEqual(Set(requests.values.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "query_time" }?.value }), ["202608", "202609"])
        XCTAssertTrue(requests.values.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret"
        })
    }

    func testFetchCostHistoryMapsDailyModelCostsToUSDBuckets() async throws {
        let requests = Requests()
        let response = Data(#"""
        {"success":true,"data":{"analysis":{"costByModel":[
          {"bizTime":"20260903","modelSlug":"openai/gpt-5","billAmount":"12.3456000000"},
          {"bizTime":"20260903","modelSlug":"anthropic/claude","billAmount":"0.1000000000"},
          {"bizTime":"20260904","modelSlug":"openai/gpt-5","billAmount":"2"}
        ]}}}
        """#.utf8)
        let client = ZenMuxClient(http: ProviderHTTP(send: {
            requests.record($0)
            return response
        }), key: { "secret" })
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 12)))

        let buckets = try await client.fetchCostHistory(days: 2, now: now)

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].amounts["usd"], Decimal(string: "12.4456000000"))
        XCTAssertEqual(buckets[1].amounts["usd"], Decimal(2))
        let components = try XCTUnwrap(URLComponents(url: requests.values[0].url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/v1/management/cost")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) }), [
            "type": "cost", "query_dimension": "BIZ_MTH", "query_time": "202609",
        ])
    }

    func testHistoryFetchesRejectMissingManagementKey() async {
        let client = ZenMuxClient(key: { nil })
        await XCTAssertThrowsErrorAsync(try await client.fetchUsageHistory(days: 1, now: Date()))
        await XCTAssertThrowsErrorAsync(try await client.fetchCostHistory(days: 1, now: Date()))
    }

    func testProviderEmitsSnapshotsAndSurvivesMissingKey() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = UsageBucket(start: now.addingTimeInterval(-900), agentId: "zenmux",
                                tokensIn: 100, tokensOut: 25)
        let cost = CostBucket(start: usage.start, amounts: ["usd": Decimal(string: "0.42")!])
        let provider = ZenMuxUsageProvider(
            readQuota: {
                ProviderQuota(windows: [
                    .init(id: "zenmux:5h", label: "5h", remaining: 80, reset: nil, duration: 5 * 3600),
                ], plan: "pro", notice: "Monthly cap 34560 Flows (no live used amount)")
            },
            readUsage: { [usage] },
            readCosts: { [cost] },
            hasKey: { true },
            clock: { now }
        )

        await provider.refreshAccountUsage(historyHours: 168)
        let report = try await provider.fetchUsage(agents: [], historyHours: 168)

        XCTAssertEqual(report.subscriptions["ZenMux"], "pro")
        XCTAssertEqual(report.snapshots.map(\.agentId), ["zenmux:5h"])
        XCTAssertEqual(report.snapshots.first?.remainingPct, 80)
        XCTAssertTrue(report.sourceNotices.isEmpty, "healthy monthly-cap information is not a source failure")
        XCTAssertEqual(report.usage, [usage])
        XCTAssertEqual(report.billing.first?.vendor, "ZenMux")
        XCTAssertEqual(report.billing.first?.costs, [cost])
        XCTAssertNil(provider.watchedDirectories, "account-only ZenMux must be polled, not an empty watch list")
        XCTAssertFalse(provider.seesLocalWork)

        let empty = ZenMuxUsageProvider(
            readQuota: { fatalError("must not call") },
            readUsage: { fatalError("must not call") },
            readCosts: { fatalError("must not call") },
            hasKey: { false },
            clock: { now }
        )
        let quiet = try await empty.fetchUsage(agents: [], historyHours: 168)
        XCTAssertNotNil(quiet.sourceNotices["ZenMux"])
        XCTAssertFalse((quiet.sourceNotices["ZenMux"] ?? "").contains("sk-"))
    }

    func testFailedCostFetchLeavesBillingTimestampNilForRetention() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = ZenMuxUsageProvider(
            readQuota: { ProviderQuota(windows: [], plan: "pro") },
            readUsage: { [] },
            readCosts: { throw UsageProviderError("rate limited") },
            hasKey: { true },
            clock: { now }
        )

        await provider.refreshAccountUsage(historyHours: 168)
        let report = try await provider.fetchUsage(agents: [], historyHours: 168)

        XCTAssertNil(report.billing.first?.updatedAt)
        XCTAssertEqual(report.billing.first?.notice, "rate limited")
    }

    func testCombinedStandardRegistersZenMuxAsAccountSource() {
        let provider = CombinedUsageProvider.standard(ledger: .inMemory())
        let source = provider.sources.first { $0.name == "ZenMux" }
        XCTAssertNotNil(source)
        XCTAssertNil(source?.directories, "ZenMux has no local logs and must be polled")
        XCTAssertEqual(source?.accountSteps.count, 1)
    }

    @MainActor
    func testZenMuxPlaceholderMigratesToSubscriptionWindows() {
        let name = "ZenMuxProviderTests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let placeholder = AgentDescriptor(id: "zenmux", vendor: "ZenMux", model: "Plan",
            source: L10n.sourceNotConnected, enabled: true, connected: false)
        let settings = SettingsStore(defaults: defaults, defaultAgents: [placeholder])
        let windows = ["zenmux:5h", "zenmux:7d"].map {
            AgentDescriptor(id: $0, vendor: "ZenMux", model: $0, source: "ZenMux", enabled: false, connected: true)
        }
        settings.mergeDiscovered(windows)
        settings.mergeDiscovered(windows)
        XCTAssertEqual(settings.agents.map(\.id), ["zenmux:5h", "zenmux:7d"])
        XCTAssertTrue(settings.agents.allSatisfy(\.enabled))
        XCTAssertTrue(settings.agents.allSatisfy(\.connected))
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
