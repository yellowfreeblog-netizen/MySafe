import Foundation
import Security

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

/// Accesso minimale ad Apple Keychain.
/// Gli elementi sono sincronizzabili con il Portachiavi iCloud (kSecAttrSynchronizable),
/// così la chiave arriva anche sugli altri dispositivi dell'utente.
enum KeychainStore {
    private static let service = "app.mysafe.keys"

    private static func query(_ account: String, synchronizable: Any) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable
        ]
    }

    static func save(_ data: Data, account: String) throws {
        SecItemDelete(query(account, synchronizable: kSecAttrSynchronizableAny) as CFDictionary)
        var q = query(account, synchronizable: kCFBooleanTrue as Any)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    static func load(account: String) -> Data? {
        var q = query(account, synchronizable: kSecAttrSynchronizableAny)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        SecItemDelete(query(account, synchronizable: kSecAttrSynchronizableAny) as CFDictionary)
    }
}
