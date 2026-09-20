import Foundation

public enum ZenMuxCredentials {
    public static func managementKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        for name in ["ZENMUX_MANAGEMENT_API_KEY", "ZENMUX_MGMT_API_KEY"] {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        let file = home.appendingPathComponent(".config/api-tokens.env")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for name in ["ZENMUX_MANAGEMENT_API_KEY", "ZENMUX_MGMT_API_KEY"] {
            for line in text.split(whereSeparator: \.isNewline) {
                let raw = line.trimmingCharacters(in: .whitespaces)
                guard !raw.hasPrefix("#"), let eq = raw.firstIndex(of: "=") else { continue }
                let key = String(raw[..<eq]).trimmingCharacters(in: .whitespaces)
                var value = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                if key == name, !value.isEmpty { return value }
            }
        }
        return nil
    }
}
