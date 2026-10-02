import Foundation
import Security

/// Small secrets that must survive a relaunch and stay off disk in plain text:
/// the install ID and the owner links of finished books.
enum Keychain {
    private static let service = "com.photocore.trip"

    static func data(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func set(_ data: Data, for account: String) -> Bool {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(match as CFDictionary, update as CFDictionary) == errSecSuccess { return true }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// A random ID for this install, kept in the Keychain so the server can give
/// each phone one free book. It identifies nothing about the person, and the
/// server stores only a hash of it.
enum InstallIdentity {
    static var id: UUID {
        if let data = Keychain.data("install-id"), let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) {
            return id
        }
        let id = UUID()
        Keychain.set(Data(id.uuidString.utf8), for: "install-id")
        return id
    }
}
