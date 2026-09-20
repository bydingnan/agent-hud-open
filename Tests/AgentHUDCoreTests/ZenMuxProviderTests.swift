import XCTest
@testable import AgentHUDCore

final class ZenMuxProviderTests: XCTestCase {
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
            ], home: home),
            "mgmt-a"
        )
        XCTAssertEqual(
            ZenMuxCredentials.managementKey(environment: ["ZENMUX_API_KEY": "inference-only"], home: home),
            "from-file"
        )
        XCTAssertNil(ZenMuxCredentials.managementKey(environment: ["ZENMUX_API_KEY": "inference-only"], home: home.appendingPathComponent("empty")))
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
        XCTAssertTrue(quota.notice?.contains("34560") == true || quota.notice?.contains("monthly") == true
                      || quota.notice?.contains("月") == true)
    }

    func testParseSubscriptionRejectsMissingSuccess() throws {
        let root = try ProviderJSON.read(Data(#"{"success":false}"#.utf8))
        XCTAssertThrowsError(try ZenMuxClient.parseSubscription(root, now: Date()))
    }
}
