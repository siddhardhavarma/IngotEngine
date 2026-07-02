//
//  KeychainStore.swift
//  IngotEngine
//
//  Minimal Keychain wrapper for API keys.
//
//  API keys are credentials — they never belong in source code or in
//  plain-text preference files. This stores them as generic-password
//  items in the user's login keychain, scoped to one service name, so
//  they survive app reinstalls and never appear in project files,
//  exports, or version control.
//

import Foundation
import Security

enum KeychainStore {

    /// One service name for all Ingot Engine secrets.
    private static let service = "com.ingot.engine.keys"

    /// Saves (or replaces) a secret string under an account key.
    /// An empty value deletes the entry.
    static func set(_ value: String, forKey key: String) {
        guard !value.isEmpty else {
            delete(key)
            return
        }

        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // Try to update an existing item first; add if none exists.
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            // Accessible after first unlock — the editor may run scripts
            // or exports without the user re-authenticating.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Reads a secret string, or nil if not stored.
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes a secret.
    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
