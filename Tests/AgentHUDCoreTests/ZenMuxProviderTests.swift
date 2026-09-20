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
}
