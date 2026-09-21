import Foundation
import Security

public enum ZenMuxCredentials {
    /// Settings → Agents → ZenMux stores the Management API key here. It is not written to preferences or the usage ledger.
    public static let keychainService = "app.agenthud.open.zenmux.management-key"

    /// A key saved in Settings wins, then the process environment, then `~/.config/api-tokens.env`.
    /// `ZENMUX_API_KEY` (inference) is never used.
    public static func managementKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        saved: String? = keychainManagementKey()
    ) -> String? {
        if let saved = clean(saved) { return saved }
        for name in ["ZENMUX_MANAGEMENT_API_KEY", "ZENMUX_MGMT_API_KEY"] {
            if let value = clean(environment[name]) { return value }
        }
        return fileKey(home)
    }

    public static func keychainManagementKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "management",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return clean(String(data: data, encoding: .utf8))
    }

    /// Empty or whitespace clears the saved key.
    public static func saveManagementKey(_ raw: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "management",
        ]
        SecItemDelete(base as CFDictionary)
        guard let token = clean(raw) else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func fileKey(_ home: URL) -> String? {
        let file = home.appendingPathComponent(".config/api-tokens.env")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for name in ["ZENMUX_MANAGEMENT_API_KEY", "ZENMUX_MGMT_API_KEY"] {
            for line in text.split(whereSeparator: \.isNewline) {
                let raw = line.trimmingCharacters(in: .whitespaces)
                guard !raw.hasPrefix("#"), let eq = raw.firstIndex(of: "=") else { continue }
                var key = String(raw[..<eq]).trimmingCharacters(in: .whitespaces)
                if key.hasPrefix("export ") {
                    key = String(key.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
                }
                var value = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                if key == name, let value = clean(value) { return value }
            }
        }
        return nil
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
