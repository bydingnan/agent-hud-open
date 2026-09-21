import Foundation
import Security

/// API keys saved in Settings → Agents for OpenCode Go / Kimi / GLM.
/// Stored in the Keychain only; never written to preferences, the usage ledger or reports.
public enum OpenAgentSettingsKeys {
    public enum Slot: String, CaseIterable, Sendable {
        case openCodeGo = "opencode-go"
        case kimiChina = "kimi"
        case kimiGlobal = "kimi-global"
        case glmGlobal = "glm-global"
        case glmChina = "glm-china"

        public var vendor: String {
            switch self {
            case .openCodeGo: "OpenCode"
            case .kimiChina, .kimiGlobal: "Kimi"
            case .glmGlobal, .glmChina: "GLM"
            }
        }

        var service: OpenAgentCredential.Service {
            switch self {
            case .openCodeGo: .go
            case .kimiChina: .kimi
            case .kimiGlobal: .kimiGlobal
            case .glmGlobal: .glmGlobal
            case .glmChina: .glmChina
            }
        }

        var clientLabel: String { vendor }

        public var placeholder: String {
            switch self {
            case .openCodeGo: "OPENCODE_GO_API_KEY"
            case .kimiChina, .kimiGlobal: "KIMI_CODE_API_KEY"
            case .glmGlobal: "Z_AI_API_KEY"
            case .glmChina: "GLM_API_KEY"
            }
        }
    }

    public static let keychainService = "app.agenthud.open.openagent.api-key"

    public static func load(_ slot: Slot) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: slot.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return clean(String(data: data, encoding: .utf8))
    }

    /// Empty or whitespace clears the saved key for that slot.
    public static func save(_ slot: Slot, _ raw: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: slot.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard let token = clean(raw) else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func hasSavedKey(vendor: String) -> Bool {
        Slot.allCases.contains { $0.vendor == vendor && load($0) != nil }
    }

    static func savedCredentials() -> [OpenAgentCredential] {
        Slot.allCases.compactMap { slot in
            guard let key = load(slot) else { return nil }
            return OpenAgentCredentials.credential(slot.service, token: key, client: slot.clientLabel)
        }
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
