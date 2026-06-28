import Foundation
import Security

/// Stores the LLM API key in the macOS Keychain (`kSecClassGenericPassword`).
///
/// The key is NEVER written to UserDefaults, a plist, or any config file, and is
/// never printed to a log. Passing an empty string deletes the stored key, which
/// is how the Settings UI supports fully clearing the field.
enum KeychainStore {

    static let service = "com.voiceinput.app.llm"
    static let account = "llm-api-key"

    /// Stores `key`, replacing any existing value. An empty/whitespace-only key
    /// deletes the item so the user can clear their credential.
    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteAPIKey()
            return true
        }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Delete-then-add keeps the attribute set clean and avoids duplicate items.
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Returns the stored key, or nil if none is set.
    static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static var hasAPIKey: Bool {
        guard let key = readAPIKey() else { return false }
        return !key.isEmpty
    }
}
